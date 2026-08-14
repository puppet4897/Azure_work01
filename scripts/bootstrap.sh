#!/usr/bin/env bash
#
# GitHub Actions から Terraform を実行するための初期セットアップ。
#
#  1. tfstate 保管用のストレージアカウント / コンテナーを作成
#  2. Entra ID アプリ + サービスプリンシパルを作成
#  3. GitHub OIDC のフェデレーション資格情報を登録（クライアントシークレット不要）
#  4. 必要なロールを割り当て
#  5. GitHub の Secrets / ラベル / Environment を設定（gh CLI がある場合）
#
# 前提: az CLI にログイン済みで、対象サブスクリプションの Owner 権限があること。
#
# 使い方:
#   ./scripts/bootstrap.sh [<github-org>/<repo>] [environment]
#   既定値: puppet4897/Azure_work01 dev
#
set -euo pipefail

REPO="${1:-puppet4897/Azure_work01}"
ENVIRONMENT="${2:-dev}"

if [[ -z "$REPO" ]]; then
  echo "使い方: $0 [<github-org>/<repo>] [environment]  (既定: puppet4897/Azure_work01 dev)" >&2
  exit 1
fi

LOCATION="${LOCATION:-japaneast}"
STATE_RG="${STATE_RG:-rg-tfstate}"
STATE_CONTAINER="${STATE_CONTAINER:-tfstate}"
APP_NAME="${APP_NAME:-gh-actions-azure-work01}"

SUBSCRIPTION_ID="$(az account show --query id -o tsv)"
TENANT_ID="$(az account show --query tenantId -o tsv)"
# ランダムサフィックス生成。
# NOTE: macOS の BSD 版 tr は `tr -dc 'a-z0-9' </dev/urandom` でロケール依存の
#       "Illegal byte sequence" を起こすため、openssl を第一候補にしている。
#       openssl が無い環境向けに LC_ALL=C 付きの tr をフォールバックとして残す。
random_suffix() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  else
    LC_ALL=C tr -dc 'a-z0-9' </dev/urandom 2>/dev/null | head -c 8
  fi
}

RANDOM_SUFFIX="$(random_suffix)"
STATE_SA="${STATE_SA:-sttfstate${RANDOM_SUFFIX}}"

# ストレージアカウント名は 3〜24 文字の小文字英数字のみ
STATE_SA="$(printf '%s' "$STATE_SA" | tr '[:upper:]' '[:lower:]' | cut -c1-24)"

echo "==> サブスクリプション: ${SUBSCRIPTION_ID}"
echo "==> テナント:           ${TENANT_ID}"
echo "==> リポジトリ:         ${REPO}"
echo "==> 環境:               ${ENVIRONMENT}"
echo

# ---------------------------------------------------------------------------
# 1. tfstate バックエンド
# ---------------------------------------------------------------------------
echo "==> [1/5] tfstate 用ストレージを作成中..."
az group create --name "$STATE_RG" --location "$LOCATION" --output none

# 再実行時に別のストレージアカウントを作ってしまわないよう、
# 既存の sttfstate* があればそれを再利用する。
EXISTING_SA="$(az storage account list --resource-group "$STATE_RG" \
  --query "[?starts_with(name, 'sttfstate')].name | [0]" -o tsv 2>/dev/null || true)"
if [[ -n "$EXISTING_SA" && "$EXISTING_SA" != "None" ]]; then
  STATE_SA="$EXISTING_SA"
  echo "    既存のストレージアカウントを再利用: ${STATE_SA}"
fi

az storage account create \
  --name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --location "$LOCATION" \
  --sku Standard_LRS \
  --kind StorageV2 \
  --min-tls-version TLS1_2 \
  --allow-blob-public-access false \
  --allow-shared-key-access false \
  --output none

STATE_SA_ID="$(az storage account show --name "$STATE_SA" --resource-group "$STATE_RG" --query id -o tsv)"

# 自分自身に Blob データ権限を付与（コンテナー作成に必要）
CURRENT_USER_OID="$(az ad signed-in-user show --query id -o tsv)"
az role assignment create \
  --assignee-object-id "$CURRENT_USER_OID" \
  --assignee-principal-type User \
  --role "Storage Blob Data Contributor" \
  --scope "$STATE_SA_ID" --output none || true

echo "    ロール伝播を待機中 (30秒)..."
sleep 30

az storage container create \
  --name "$STATE_CONTAINER" \
  --account-name "$STATE_SA" \
  --auth-mode login \
  --output none

# バージョニングを有効化（state 破損時のリカバリ用）
az storage account blob-service-properties update \
  --account-name "$STATE_SA" \
  --resource-group "$STATE_RG" \
  --enable-versioning true \
  --output none

echo "    ストレージアカウント: ${STATE_SA}"

# ---------------------------------------------------------------------------
# 2. Entra ID アプリ + サービスプリンシパル
# ---------------------------------------------------------------------------
echo "==> [2/5] Entra ID アプリを作成中..."
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [[ -z "$APP_ID" || "$APP_ID" == "null" ]]; then
  APP_ID="$(az ad app create --display-name "$APP_NAME" --query appId -o tsv)"
  echo "    アプリを作成: ${APP_ID}"
else
  echo "    既存アプリを再利用: ${APP_ID}"
fi

SP_OID="$(az ad sp list --filter "appId eq '${APP_ID}'" --query '[0].id' -o tsv)"
if [[ -z "$SP_OID" || "$SP_OID" == "null" ]]; then
  SP_OID="$(az ad sp create --id "$APP_ID" --query id -o tsv)"
fi
echo "    サービスプリンシパル: ${SP_OID}"

# ---------------------------------------------------------------------------
# 3. OIDC フェデレーション資格情報
# ---------------------------------------------------------------------------
echo "==> [3/5] フェデレーション資格情報を登録中..."
add_federated_credential() {
  local name="$1" subject="$2"
  if az ad app federated-credential list --id "$APP_ID" --query "[?name=='${name}']" -o tsv | grep -q .; then
    echo "    スキップ (既存): ${name}"
    return
  fi
  az ad app federated-credential create --id "$APP_ID" --parameters "{
    \"name\": \"${name}\",
    \"issuer\": \"https://token.actions.githubusercontent.com\",
    \"subject\": \"${subject}\",
    \"audiences\": [\"api://AzureADTokenExchange\"]
  }" --output none
  echo "    登録: ${name} -> ${subject}"
}

add_federated_credential "gh-main"        "repo:${REPO}:ref:refs/heads/main"
add_federated_credential "gh-pr"          "repo:${REPO}:pull_request"
add_federated_credential "gh-env-${ENVIRONMENT}" "repo:${REPO}:environment:${ENVIRONMENT}"

# ---------------------------------------------------------------------------
# 4. ロール割り当て
# ---------------------------------------------------------------------------
echo "==> [4/5] ロールを割り当て中..."
assign_role() {
  local role="$1" scope="$2"
  az role assignment create \
    --assignee-object-id "$SP_OID" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" --scope "$scope" --output none 2>/dev/null \
    && echo "    付与: ${role}" \
    || echo "    スキップ (既存): ${role}"
}

SUB_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"
# リソース作成用
assign_role "Contributor" "$SUB_SCOPE"
# Terraform が Key Vault のロール割り当てを作るために必要
assign_role "Role Based Access Control Administrator" "$SUB_SCOPE"
# tfstate の読み書き（ストレージキーを使わないため）
assign_role "Storage Blob Data Contributor" "$STATE_SA_ID"
# 週次コストリマインドで課金額を参照するため
assign_role "Cost Management Reader" "$SUB_SCOPE"

# ---------------------------------------------------------------------------
# 5. GitHub 側の設定（一人運用向け）
# ---------------------------------------------------------------------------
echo "==> [5/5] GitHub 側を設定中..."

if command -v gh >/dev/null 2>&1; then
  # --- Secrets ---
  # ID 類は認証情報そのものではないが、Public リポジトリでは Actions のログに
  # マスクされずに出る可能性があるため Variables ではなく Secrets に格納する。
  gh secret set AZURE_CLIENT_ID       --repo "$REPO" --body "$APP_ID"
  gh secret set AZURE_TENANT_ID       --repo "$REPO" --body "$TENANT_ID"
  gh secret set AZURE_SUBSCRIPTION_ID --repo "$REPO" --body "$SUBSCRIPTION_ID"
  echo "    Secrets を設定"

  # --- Issue ラベル (drift 検知 / コストリマインド用) ---
  gh label create drift --repo "$REPO" --color 'D93F0B' \
    --description 'コードと実環境の乖離' --force >/dev/null 2>&1 || true
  gh label create cost --repo "$REPO" --color 'FBCA04' \
    --description 'コスト関連の通知' --force >/dev/null 2>&1 || true
  echo "    ラベル (drift / cost) を作成"

  # --- Environment を作成し、自分を承認者に設定 ---
  # 一人運用でも GitHub の Environment は「自分のデプロイを自分で承認」できる。
  # これが apply 前に Plan を見直すためのブレーキになる。
  # NOTE: 保護ルールは Public リポジトリか有料プランでのみ有効。
  OWNER_ID="$(gh api user --jq .id 2>/dev/null || echo '')"
  if [[ -n "$OWNER_ID" ]]; then
    gh api -X PUT "repos/${REPO}/environments/${ENVIRONMENT}" \
      -F "prevent_self_review=false" \
      -f "reviewers[][type]=User" \
      -F "reviewers[][id]=${OWNER_ID}" >/dev/null 2>&1 \
      && echo "    Environment '${ENVIRONMENT}' を作成 (承認者: 自分)" \
      || echo "    Environment の自動作成に失敗。手動で作成してください。"
  fi
else
  echo "    gh CLI が見つかりません。以下を手動で設定してください。"
  echo
  echo "    [Secrets] Settings > Secrets and variables > Actions > Secrets"
  echo "      AZURE_CLIENT_ID       = ${APP_ID}"
  echo "      AZURE_TENANT_ID       = ${TENANT_ID}"
  echo "      AZURE_SUBSCRIPTION_ID = ${SUBSCRIPTION_ID}"
  echo
  echo "    [Environment] Settings > Environments > New environment"
  echo "      名前: ${ENVIRONMENT}"
  echo "      Required reviewers: 自分自身を追加"
  echo "      Prevent self-review: オフのままにする（一人運用のため）"
  echo
  echo "    [Labels] Issues > Labels で 'drift' と 'cost' を作成"
fi

# ---------------------------------------------------------------------------
# バックエンド設定ファイルを更新
# ---------------------------------------------------------------------------
BACKEND_FILE="env/${ENVIRONMENT}.backend.hcl"
cat > "$BACKEND_FILE" <<EOF
resource_group_name  = "${STATE_RG}"
storage_account_name = "${STATE_SA}"
container_name       = "${STATE_CONTAINER}"
key                  = "Azure_work01/${ENVIRONMENT}.tfstate"
EOF

cat <<EOF

===========================================================================
セットアップ完了（一人運用モード）

  ${BACKEND_FILE} を更新しました。コミットしてください。

  git add env/${ENVIRONMENT}.backend.hcl
  git commit -m "chore: tfstate バックエンド設定を更新"
  git push

--- リポジトリ設定について -----------------------------------------------
[Environment の承認ゲート]
  Public リポジトリなら GitHub Free でも Required reviewers が使えます。
  Settings > Environments > ${ENVIRONMENT} で自分を承認者に設定し、
  "Prevent self-review" はオフのままにしてください。
  main にマージすると Actions が承認待ちで止まります。

[ブランチ保護] Settings > Rules > Rulesets
    [x] Require status checks to pass
          - Plan (dev)
          - Checkov + tflint
    [ ] Require approvals            <- 0 のままにする（自分で承認できないため）
    [ ] Require review from Code Owners  <- 有効にしない

[Public リポジトリのため要確認] Settings > Actions > General
    Fork pull request workflows:
    (o) Require approval for all external contributors
---------------------------------------------------------------------------
===========================================================================
EOF
