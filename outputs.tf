# 注意: パスワードは output に出しません。
# GitHub Actions のログや terraform output に平文が残るのを防ぐため、
# 認証情報は Key Vault からのみ取得します。

output "resource_group_name" {
  description = "作成されたリソースグループ名"
  value       = azurerm_resource_group.this.name
}

output "vm_name" {
  description = "VM 名"
  value       = azurerm_windows_virtual_machine.this.name
}

output "vm_private_ip" {
  description = "VM のプライベート IP（Bastion 接続先）"
  value       = azurerm_network_interface.vm.private_ip_address
}

output "key_vault_name" {
  description = "認証情報を格納した Key Vault 名"
  value       = azurerm_key_vault.this.name
}

output "get_credentials_command" {
  description = "管理者パスワードを取得する az CLI コマンド"
  value       = "az keyvault secret show --vault-name ${azurerm_key_vault.this.name} --name vm-admin-password --query value -o tsv"
}

output "bastion_name" {
  description = "Bastion ホスト名"
  value       = azurerm_bastion_host.this.name
}

output "bastion_sku" {
  description = "Bastion の SKU"
  value       = azurerm_bastion_host.this.sku
}

output "bastion_public_ip" {
  description = "Bastion のパブリック IP（Basic SKU 時のみ）"
  value       = local.is_developer_bastion ? null : azurerm_public_ip.bastion[0].ip_address
}

output "source_ip_restriction" {
  description = "接続元 IP 制限の適用状況（IP そのものは伏せる）"
  # Public リポジトリのため、Actions のログに残る output には実際の IP を出さない。
  value = local.is_developer_bastion ? "未適用: Developer SKU は NSG による接続元 IP 制限に対応していません。要件を満たすには bastion_sku = \"Basic\" にしてください。" : "適用済み: Secrets で指定した単一 IP からの 443 のみ許可"
}

output "portal_connect_url" {
  description = "Azure Portal で VM に接続する URL（Bastion タブを選択）"
  value       = "https://portal.azure.com/#@/resource${azurerm_windows_virtual_machine.this.id}/bastionHost"
}

output "deployment_summary" {
  description = "デプロイ結果のサマリ（PR コメント用）"
  value = {
    environment   = var.environment
    location      = var.location
    vm_size       = var.vm_size
    bastion_sku   = var.bastion_sku
    auto_shutdown = var.enable_auto_shutdown ? "${var.auto_shutdown_time} ${var.auto_shutdown_timezone}" : "無効"
  }
}
