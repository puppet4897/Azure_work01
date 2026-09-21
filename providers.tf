terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azurerm = {
      source = "hashicorp/azurerm"
      # 4.75 以降を要求する理由:
      #   azurerm_key_vault の `rbac_authorization_enabled`（旧 enable_rbac_authorization）
      #   を使用しているため。v5.0 には破壊的変更があるので上限を切っている。
      version = "~> 5.6"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}

provider "azurerm" {
  # CI では以下の環境変数から自動的に解決される (azure/login アクションが設定):
  #   ARM_USE_OIDC / ARM_CLIENT_ID / ARM_TENANT_ID / ARM_SUBSCRIPTION_ID
  # ローカルでは `az login` の資格情報が使われる。
  subscription_id = var.subscription_id

  features {
    virtual_machine {
      # テスト用途: destroy 時に OS ディスクを確実に削除してコストを残さない
      delete_os_disk_on_deletion = true
    }
    resource_group {
      prevent_deletion_if_contains_resources = false
    }
    key_vault {
      # テスト用途: destroy 後に論理削除された Key Vault を残さない
      purge_soft_delete_on_destroy    = true
      recover_soft_deleted_key_vaults = true
    }
  }
}

provider "random" {}

provider "time" {}

data "azurerm_client_config" "current" {}
