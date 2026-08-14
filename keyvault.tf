# ---------------------------------------------------------------------------
# Key Vault
#   VM の管理者パスワードを保管する。
#   これにより GitHub Actions のログにも terraform output にも平文が出ない。
# ---------------------------------------------------------------------------

resource "azurerm_key_vault" "this" {
  # Key Vault 名はグローバル一意 / 3〜24 文字 / 英数字とハイフンのみ
  name                = substr("kv-${replace(local.name_prefix, "-", "")}-${local.suffix}", 0, 24)
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"
  tags                = local.tags

  # アクセスポリシーではなく Azure RBAC で権限管理する（Microsoft 推奨）
  #
  # NOTE: 旧名 `enable_rbac_authorization` は azurerm v4 系で非推奨となり、
  #       v5.0 で削除される。新名の `rbac_authorization_enabled` を使用する。
  #       v5.0 ではこの属性は Required になるため、明示指定しておくと移行時も無変更で済む。
  rbac_authorization_enabled = true

  # テスト用途: destroy を妨げないよう最小値かつパージ保護なし
  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  public_network_access_enabled = true

  network_acls {
    bypass         = "AzureServices"
    default_action = "Allow"
  }
}

# 実行プリンシパル（CI の SP / ローカルのユーザー）にシークレット書き込み権限を付与
resource "azurerm_role_assignment" "kv_deployer" {
  count                = var.grant_deployer_kv_access ? 1 : 0
  scope                = azurerm_key_vault.this.id
  role_definition_name = "Key Vault Secrets Officer"
  principal_id         = data.azurerm_client_config.current.object_id
}

# RBAC の伝播待ち。これがないと直後の secret 作成が 403 で失敗することがある。
resource "time_sleep" "kv_rbac_propagation" {
  count           = var.grant_deployer_kv_access ? 1 : 0
  depends_on      = [azurerm_role_assignment.kv_deployer]
  create_duration = var.kv_role_propagation_delay
}

resource "azurerm_key_vault_secret" "vm_admin_password" {
  name         = "vm-admin-password"
  value        = local.admin_password
  key_vault_id = azurerm_key_vault.this.id
  content_type = "password"
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac_propagation]

  lifecycle {
    ignore_changes = [value]
  }
}

resource "azurerm_key_vault_secret" "vm_admin_username" {
  name         = "vm-admin-username"
  value        = var.admin_username
  key_vault_id = azurerm_key_vault.this.id
  content_type = "username"
  tags         = local.tags

  depends_on = [time_sleep.kv_rbac_propagation]
}
