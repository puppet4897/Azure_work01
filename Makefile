# terraform コマンドのラッパー。
# -backend-config / -var-file の付け忘れを防ぐために用意しています。
#
#   make init     ... バックエンド設定を渡して初期化
#   make plan     ... 差分確認
#   make apply    ... 適用
#   make destroy  ... 破棄
#   make password ... 管理者パスワードを Key Vault から取得
#
# 環境を切り替える場合: make plan ENV=stg

ENV  ?= dev
REPO ?= puppet4897/Azure_work01

BACKEND := env/$(ENV).backend.hcl
TFVARS  := env/$(ENV).tfvars

.PHONY: help bootstrap init upgrade fmt validate plan apply destroy output password check

help:
	@echo "使い方: make <target> [ENV=dev]"
	@echo ""
	@echo "  bootstrap 初期セットアップ（state ストレージ / OIDC / GitHub 設定）"
	@echo "  init      バックエンド設定を渡して terraform init"
	@echo "  upgrade   プロバイダーを更新して init"
	@echo "  fmt       terraform fmt -recursive"
	@echo "  validate  構文チェック"
	@echo "  plan      差分確認"
	@echo "  apply     適用"
	@echo "  destroy   破棄（コスト停止）"
	@echo "  output    出力値の一覧"
	@echo "  password  管理者パスワードを Key Vault から取得"
	@echo "  check     fmt + validate + plan をまとめて実行"

# 初期セットアップ。
# bash 経由で呼ぶため、スクリプトに実行権限が無くても動く。
bootstrap:
	@chmod +x scripts/bootstrap.sh 2>/dev/null || true
	bash scripts/bootstrap.sh $(REPO) $(ENV)

# バックエンド設定が未整備なら止める
_guard:
	@test -f $(BACKEND) || { echo "ERROR: $(BACKEND) がありません"; exit 1; }
	@grep -q 'CHANGEME' $(BACKEND) && { \
		echo "ERROR: $(BACKEND) が未設定です。先に ./scripts/bootstrap.sh を実行してください。"; \
		exit 1; } || true

init: _guard
	terraform init -backend-config=$(BACKEND) -input=false

upgrade: _guard
	terraform init -upgrade -backend-config=$(BACKEND) -input=false

fmt:
	terraform fmt -recursive

validate:
	terraform validate

plan:
	terraform plan -var-file=$(TFVARS) -lock-timeout=5m

apply:
	terraform apply -var-file=$(TFVARS) -lock-timeout=5m

destroy:
	terraform destroy -var-file=$(TFVARS) -lock-timeout=5m

output:
	terraform output

password:
	@az keyvault secret show \
		--vault-name "$$(terraform output -raw key_vault_name)" \
		--name vm-admin-password --query value -o tsv

check: fmt validate plan
