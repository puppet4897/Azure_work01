# Azure テスト用 Windows VM (Terraform + GitHub Actions)

[![Terraform Plan](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-plan.yml/badge.svg)](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-plan.yml)
[![Terraform Apply](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-apply.yml/badge.svg)](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-apply.yml)
[![Security Scan](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-security.yml/badge.svg)](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-security.yml)

リポジトリ: <https://github.com/puppet4897/Azure_work01>

Bastion 経由でのみ接続できる、コスト最小構成の Windows Server テスト VM を
GitHub で構成管理し、GitHub Actions からデプロイします。

| 項目 | 値 |
|---|---|
| リポジトリ | `puppet4897/Azure_work01` |
| デフォルトブランチ | `main` |
| Terraform コードの位置 | リポジトリ直下 |
| tfstate のキー | `Azure_work01/dev.tfstate` |
| Entra ID アプリ名 | `gh-actions-azure-work01` |
| 公開設定 | **Public**（Environment 保護ルールを Free で使うため） |
| **運用体制** | **一人運用**（レビュアーなし前提の設計） |

## 一人運用としての設計方針

レビュー相手がいないため、**人によるチェックの代わりを自動化で埋める**設計にしています。

| チームでの一般的なやり方 | 本リポジトリでの代替 |
|---|---|
| PR を他人がレビューして承認 | **Environment の自己承認**。main マージ後に apply が止まり、Plan を見てから承認する |
| CODEOWNERS による必須レビュー | 無効化（自分の PR を自分で承認できず詰むため） |
| Require approvals ≧ 1 | 0 のまま。代わりに **status checks を必須**にして機械的に検証 |
| 他人が構成のズレに気づく | **Drift Detection**（毎日）が差分を検出して Issue で通知 |
| 誰かが「まだ立ってるよ」と指摘 | **Cost Reminder**（毎週）が稼働中リソースと課金額を Issue で通知 |
| PR でコスト影響を議論 | PR テンプレートを「自分への申し送り」チェックリストとして使う |

### Public リポジトリとしての注意点

Environment の保護ルールは Private + GitHub Free では使えないため、
このリポジトリは **Public** で運用します。それに伴い以下の対策を入れています。

| リスク | 対策 |
|---|---|
| Actions ログに ID 類が平文で出る | Variables ではなく **Secrets** に格納（Secrets は自動でマスクされる） |
| fork からの PR で CI が失敗し続ける | Plan ジョブに fork 判定を入れて同一リポジトリの PR のみ実行 |
| 見知らぬ人の PR でワークフローが動く | Settings > Actions > General で **Require approval for all external contributors** を設定 |
| 認証情報の漏洩 | OIDC のためシークレット自体が存在しない。トークンは `repo:puppet4897/Azure_work01:*` の subject でしか発行されない |
| 接続元 IP がコードから読める | `allowed_source_ip` を **Secrets から注入**。`sensitive = true` なので plan 出力にも出ない |

> **公開されるもの**: Terraform コード、`env/dev.tfvars`、ワークフロー定義。
> パスワード・tfstate・接続元 IP は含まれません。

## リポジトリ構成

```
Azure_work01/
├── .github/
│   ├── workflows/
│   │   ├── terraform-plan.yml      # PR / 作業ブランチ push で plan（fork は除外）
│   │   ├── terraform-apply.yml     # main へ push で apply（自己承認ゲート付き）
│   │   ├── terraform-destroy.yml   # 手動実行での破棄
│   │   ├── terraform-security.yml  # Checkov + tflint
│   │   ├── terraform-drift.yml     # 毎日 drift 検知 → Issue 通知
│   │   └── cost-reminder.yml       # 毎週 稼働リソースと課金額を Issue 通知
│   ├── CODEOWNERS                  # 一人運用のため全行コメントアウト
│   ├── dependabot.yml
│   └── pull_request_template.md    # 自分への申し送りチェックリスト
├── env/
│   ├── dev.tfvars                  # 環境別の変数（機密なし・コミット対象）
│   └── dev.backend.hcl             # tfstate バックエンド設定
├── secrets.auto.tfvars.example     # 接続元 IP のテンプレート（実体は gitignore）
├── scripts/
│   └── bootstrap.sh                # 初期セットアップ（OIDC / state ストレージ）
├── backend.tf                      # リモート state（部分構成）
├── providers.tf
├── main.tf                         # ネットワーク / NSG / Bastion / VM
├── keyvault.tf                     # 管理者パスワードの保管
├── variables.tf
├── outputs.tf
├── Makefile                        # -backend-config 等の付け忘れ防止ラッパー
├── .tflint.hcl
└── vscode-settings/                # .vscode/ にコピーして使う
```

## アーキテクチャ

```
push / PR ──[plan]───┐
                    │  OIDC フェデレーション認証（クライアントシークレットなし）
main マージ ─[apply]─┤  ← Environment "dev" の承認ゲートで停止
                    ▼
              Azure Subscription
              ├── rg-tfstate / Blob (tfstate, バージョニング有効)
              └── rg-testwin-dev-xxxxx
                  ├── VNet 10.10.0.0/16
                  │   ├── AzureBastionSubnet 10.10.0.0/26  ← Basic SKU 時のみ
                  │   │   └── NSG: 受信443 を許可 IP /32 のみ（Secrets 注入）
                  │   └── snet-vm 10.10.1.0/24
                  │       └── NSG: 受信3389 は Bastion のみ / Internet 全拒否
                  ├── Key Vault (VM 管理者パスワード)
                  └── vm-testwin-dev (B2s / WS2022 / パブリック IP なし)
```

## ⚠️ 重要: 接続元 IP 制限と Bastion SKU

**Developer SKU（無料）では「接続元グローバル IP を単一アドレスに制限する」要件は満たせません。**

Developer SKU は専用サブネットもパブリック IP も持たず、Azure プラットフォームの共有 IP
(168.63.129.16) 経由で通信するため、NSG で接続元 IP を絞る対象がそもそも存在しません。

| | Developer | Basic |
|---|---|---|
| Bastion 自体の料金 | **無料** | 従量課金（東日本で概ね月 2 万円前後、常時稼働時） |
| AzureBastionSubnet / Public IP | 不要 | 必須 |
| NSG による接続元 IP 制限 | **不可** | **可** |
| VNet ピアリング | 非対応 | 対応 |

- **コスト最優先** → `bastion_sku = "Developer"`（既定）。IP 制限は Entra ID 条件付きアクセスの
  「場所」条件で代替する（Entra ID P1 以上が必要）。
- **IP 制限が必須要件** → `env/dev.tfvars` の `bastion_sku` を `"Basic"` に変更して PR を出す。
  併せて GitHub Secrets の `ALLOWED_SOURCE_IP` と、ローカルの `secrets.auto.tfvars` を設定する。

## ライセンスについて

- 採用イメージ: `MicrosoftWindowsServer / WindowsServer / 2022-datacenter-azure-edition`
- **従量課金の VM 単価に Windows Server ライセンス料が含まれる**ため、別途調達は不要です。
- Windows 10/11 などのクライアント OS は別問題で、Multi-tenant Hosting Rights、Windows VDA、
  または対象の M365 ライセンスが必要です。テスト用途なら Windows Server が確実です。
- SA 付きの Windows Server ライセンスを保有している場合のみ `enable_hybrid_benefit = true`。
  **保有していない場合に true にするとライセンス違反になります。**

---

## セットアップ手順

### 1. リポジトリへ push

このディレクトリの中身を **リポジトリ直下** に置きます。

```bash
cd azure-test-vm
mkdir -p .vscode && cp vscode-settings/*.json .vscode/

git init -b main
git remote add origin https://github.com/puppet4897/Azure_work01.git
git add .
git commit -m "feat: Azure テスト用 Windows VM を Terraform + GitHub Actions で構築"
git push -u origin main
```

既にリポジトリを clone 済みの場合は、その中にファイルをコピーしてから commit / push してください。

```bash
git clone https://github.com/puppet4897/Azure_work01.git
cp -r azure-test-vm/. Azure_work01/
cd Azure_work01 && git add . && git commit -m "feat: ..." && git push
```

> リポジトリに既存ファイルがある場合は上書きに注意してください。

### 2. ブートストラップ（1 回だけ）

Owner 権限のあるアカウントで `az login` した状態で実行します。引数を省略すると
`puppet4897/Azure_work01` / `dev` が使われます。

```bash
az login
az account set --subscription "<subscription-id>"
make bootstrap
```

> `./scripts/bootstrap.sh` と直接実行して `permission denied` になる場合は実行権限が
> 付いていません。`make bootstrap` なら `bash` 経由で呼ぶので権限に関係なく動きます。
> Git に実行ビットを記録しておく場合は以下を実行してください。
>
> ```bash
> chmod +x scripts/bootstrap.sh
> git update-index --chmod=+x scripts/bootstrap.sh
> ```

このスクリプトが行うこと:

1. tfstate 用のストレージアカウント作成（共有キー無効化・バージョニング有効）
2. Entra ID アプリ + サービスプリンシパル作成
3. **GitHub OIDC のフェデレーション資格情報を登録**（クライアントシークレット不要）
   - `repo:puppet4897/Azure_work01:ref:refs/heads/main`
   - `repo:puppet4897/Azure_work01:pull_request`
   - `repo:puppet4897/Azure_work01:environment:dev`
4. ロール割り当て
   - `Contributor`（リソース作成）
   - `Role Based Access Control Administrator`（Key Vault のロール割り当て作成用）
   - `Storage Blob Data Contributor`（tfstate 用、ストレージキーを使わないため）
   - `Cost Management Reader`（週次コストリマインドの課金額参照用）
5. GitHub 側の設定（`gh` CLI がある場合のみ自動。無ければ手順を表示）
   - Secrets 3 つ
   - Issue ラベル `drift` / `cost`
   - Environment `dev`（自分を承認者に設定）
   - `env/dev.backend.hcl` の更新

完了後、更新された `env/dev.backend.hcl` をコミットしてください。

### 3. 接続元 IP の設定（ローカル）

`allowed_source_ip` はコードに含めていません。ローカルで `bastion_sku = "Basic"` を
使う場合のみ、以下を用意してください（`.gitignore` 済みでコミットされません）。

```bash
cp secrets.auto.tfvars.example secrets.auto.tfvars
# secrets.auto.tfvars を開いて自分の IP に書き換える
```

`*.auto.tfvars` は terraform が自動で読み込むため、`-var-file` の指定は不要です。
環境変数で渡すこともできます。

```bash
export TF_VAR_allowed_source_ip="203.0.113.10"
```

`bastion_sku = "Developer"`（既定）のままなら、この値は使われないので未設定で構いません。

### 4. GitHub 側の設定

**Secrets**（<https://github.com/puppet4897/Azure_work01/settings/secrets/actions>）

| 名前 | 内容 |
|---|---|
| `AZURE_CLIENT_ID` | Entra ID アプリのアプリケーション ID |
| `AZURE_TENANT_ID` | テナント ID |
| `AZURE_SUBSCRIPTION_ID` | サブスクリプション ID |
| `ALLOWED_SOURCE_IP` | Bastion への接続を許可する外部グローバル IP（例: `203.0.113.10`） |

> `AZURE_*` は認証情報そのものではありません（OIDC の subject 検証があるため、値を知っていても
> 他人はトークンを取得できません）。ただし Public リポジトリではログにマスクされる方が
> 安全なので、Variables ではなく Secrets を使います。

**Environment**（<https://github.com/puppet4897/Azure_work01/settings/environments>）

- 名前: `dev`（ワークフローの `environment: dev` と一致させること）
- **Required reviewers**: `puppet4897`（自分）→ 設定後に **Save protection rules** を押す
- **Prevent self-review: オフのまま** ← オンにすると自分で承認できず apply が詰みます
- Deployment branches: `main` のみに制限

**Actions の設定**（<https://github.com/puppet4897/Azure_work01/settings/actions>）

Public リポジトリなので、Fork pull request workflows を
**Require approval for all external contributors** にしてください。

**ブランチ保護**（<https://github.com/puppet4897/Azure_work01/settings/rules>）

一人運用では以下のようにしてください。

| 設定 | 値 | 理由 |
|---|---|---|
| Require status checks | **有効** | `Plan (dev)` と `Checkov + tflint` を必須に |
| Require approvals | **0** | 1 以上にすると自分の PR を自分で承認できずマージ不能になる |
| Require review from Code Owners | **無効** | 同上。`.github/CODEOWNERS` は全行コメントアウト済み |
| Block force pushes | 有効 | state と履歴の保護 |

> 将来チームで運用する場合は `.github/CODEOWNERS` のコメントを外し、
> Require approvals を 1 以上に変更してください。

**Issue ラベル**

`drift` と `cost` の 2 つを bootstrap.sh が作成します（Drift Detection と
Cost Reminder が使用）。手動なら Issues > Labels から作成してください。

---

## 運用フロー

```
作業ブランチで *.tf / env/dev.tfvars を編集して push
   ↓
[Terraform Plan] 自動実行 → Job Summary / PR に plan 結果
[Checkov + tflint] 自動実行
   ↓
main にマージ（PR 経由でも直接 push でも可）
   ↓
[Terraform Apply] 起動 → Environment "dev" で承認待ちで停止 ★
   ↓
Plan を確認して「Review deployments」→ Approve and deploy
   ↓
apply 実行 → Job Summary に接続情報が出力される
```

★ ここが一人運用における唯一の人手チェックポイントです。承認画面から
そのまま Plan のログを確認できるので、意図しない `destroy` がないか見てから
承認してください。

### 自動で回る監視

| ワークフロー | 頻度 | 動作 |
|---|---|---|
| Drift Detection | 毎日 08:00 JST | コードと実環境に差分があれば `drift` ラベルの Issue を作成／更新。解消したら自動クローズ |
| Cost Reminder | 毎週月曜 09:00 JST | リソースが残っていれば稼働状態と直近30日の課金額を `cost` ラベルの Issue で通知。破棄済みなら自動クローズ |
| Security Scan | PR / push / 毎週月曜 | Checkov（Code scanning へ SARIF 送信）+ tflint |
| Dependabot | 毎週月曜 | Actions と Terraform プロバイダーの更新 PR |

Issue が立つと GitHub から通知が飛ぶので、放置に気づけます。

### 手動操作

| 目的 | 操作 |
|---|---|
| plan だけ実行 | [Actions > Terraform Plan](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-plan.yml) > Run workflow |
| デプロイ | main にマージ（または Run workflow）→ 承認 |
| 破棄（コスト停止） | [Actions > Terraform Destroy](https://github.com/puppet4897/Azure_work01/actions/workflows/terraform-destroy.yml) > Run workflow → 環境名 `dev` を 2 回入力 |

### VM への接続

```bash
# 管理者パスワードを Key Vault から取得（Key Vault Secrets User 以上の権限が必要）
az keyvault secret show --vault-name <kv-name> --name vm-admin-password --query value -o tsv
```

Key Vault 名と接続 URL は Apply ワークフローの Job Summary に出力されます。
Azure Portal で VM を開き、「接続 > Bastion」から RDP してください。

---

## ローカルでの実行

`backend.tf` は**部分構成**なので、`terraform init` には必ず `-backend-config` が必要です。
付け忘れると `container_name  Enter a value:` のように対話入力を求められます。

付け忘れ防止に Makefile を用意しています。

```bash
az login
make init      # terraform init -backend-config=env/dev.backend.hcl
make plan      # terraform plan  -var-file=env/dev.tfvars
make apply
make password  # 管理者パスワードを Key Vault から取得
make destroy
```

素の terraform コマンドを使う場合:

```bash
terraform init -backend-config=env/dev.backend.hcl
terraform plan  -var-file=env/dev.tfvars
terraform apply -var-file=env/dev.tfvars
```

ローカルから apply する場合、実行ユーザーに `Contributor` と
`Role Based Access Control Administrator`（または `Owner`）が必要です。

### よくあるエラー

| 症状 | 原因と対処 |
|---|---|
| `container_name Enter a value:` と聞かれる | `-backend-config` の付け忘れ。`Ctrl+C` で中断し `make init` |
| `storage account ... was not found` | `scripts/bootstrap.sh` 未実行。実行して `env/dev.backend.hcl` を更新する |
| init 済みで backend 設定を変えたい | `rm -rf .terraform` してから `make init` |
| プロバイダーのバージョンを上げたい | `make upgrade`（`terraform init -upgrade` 相当） |
| `permission denied: ./scripts/bootstrap.sh` | 実行権限なし。`make bootstrap` を使うか `chmod +x scripts/bootstrap.sh` |

## コスト最適化ポイント

| 施策 | 内容 |
|---|---|
| VM サイズ | `Standard_B2s`（バースト可能・2vCPU/4GB）。Windows で実用に耐える最小クラス |
| OS ディスク | `Standard_LRS`（HDD, 127GB）。最安 |
| パブリック IP | VM には付与しない（Standard Public IP の固定費を回避） |
| ブート診断 | マネージド診断を使用（ストレージアカウント不要＝追加課金なし） |
| Bastion | Developer SKU なら無料 |
| Key Vault | Standard SKU。シークレット数個なら月数十円 |
| tfstate ストレージ | Standard_LRS。月数円 |
| **自動シャットダウン** | 毎日 19:00 JST に自動停止。**これが最大の削減策** |
| 破棄 | Terraform Destroy ワークフローで即座に片付け可能 |

> 停止中の課金はディスク分（月数百円）のみ。長期間使わないなら Destroy が最安です。

## セキュリティ上の設計判断

| 項目 | 対応 |
|---|---|
| GitHub → Azure 認証 | OIDC フェデレーション（クライアントシークレットを保存しない） |
| tfstate へのアクセス | Entra ID 認証（`use_azuread_auth = true`）。ストレージ共有キーは無効化 |
| VM パスワード | 自動生成 → Key Vault に格納。`output` に出さないので Actions ログに残らない |
| 意図しない apply | Environment の自己承認ゲート（一人運用でも機能する唯一の承認手段） |
| 意図しない destroy | 手動ワークフロー + 環境名の二重入力 |
| 構成のズレ | Drift Detection が毎日検出して Issue 化 |
| 静的解析 | Checkov（SARIF を Code scanning に送信）+ tflint |

一人運用ではレビューによる牽制が効かないため、**「承認ゲート」と「事後検知」の
二段構え**にしています。承認を押し間違えても、翌朝の Drift Detection と
週次の Cost Reminder で気づけます。

> `random_password` の値は仕組み上 tfstate に平文で残ります。tfstate は Azure Blob 上にあり
> RBAC でアクセス制御されていますが、閲覧権限は最小限に絞ってください。

## 注意事項

- **プロバイダーバージョン**: `azurerm ~> 4.75` を要求しています。既に `terraform init` 済みの場合は
  `terraform init -upgrade` でロックファイルを更新してください。
  Key Vault の `rbac_authorization_enabled`（旧 `enable_rbac_authorization`）を使うためです。
  旧名は v4 系で非推奨、v5.0 で削除されます。
- Bastion のプロビジョニングには 5〜10 分ほどかかります。
- Key Vault の RBAC 伝播待ちのため、初回 apply で `time_sleep` により 60 秒待機します。
  403 で失敗する場合は `kv_role_propagation_delay` を延ばしてください。
- Key Vault 名はグローバル一意です。衝突した場合は `prefix` を変更してください。

## 出典

- [Choose the right Azure Bastion SKU](https://learn.microsoft.com/en-us/azure/bastion/bastion-sku-comparison)
- [Configure NSG rules for Azure Bastion](https://learn.microsoft.com/en-us/azure/bastion/bastion-nsg)
- [Azure Bastion Developer 対応リージョン](https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/bastion-developer-regions.md)
- [Use GitHub Actions to connect to Azure (OIDC)](https://learn.microsoft.com/en-us/azure/developer/github/connect-from-azure-openid-connect)
- [Terraform azurerm backend](https://developer.hashicorp.com/terraform/language/backend/azurerm)
