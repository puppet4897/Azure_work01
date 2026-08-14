# dev 環境の変数定義。機密情報は含めないこと（このファイルは Git 管理対象）。
environment = "dev"
prefix      = "testwin"
location    = "japaneast"

# --- Bastion ---------------------------------------------------------------
# "Developer" : 無料。ただし接続元 IP 制限は不可。
# "Basic"     : 有料。指定した単一 IP からのみ接続を許可できる。
bastion_sku = "Developer"

# allowed_source_ip はここに書かない。
# リポジトリが Public のため、接続元 IP は外部から注入する:
#   CI      : GitHub Secrets の ALLOWED_SOURCE_IP
#   ローカル : secrets.auto.tfvars（.gitignore 済み）

# --- ネットワーク ----------------------------------------------------------
vnet_address_space    = ["10.10.0.0/16"]
bastion_subnet_prefix = "10.10.0.0/26"
vm_subnet_prefix      = "10.10.1.0/24"

# --- VM --------------------------------------------------------------------
vm_size         = "Standard_B2s"
os_disk_type    = "Standard_LRS"
os_disk_size_gb = 127
image_sku       = "2022-datacenter-azure-edition"
admin_username  = "azureadmin"
# admin_password は指定しない。自動生成され Key Vault に格納される。

# --- コスト削減 ------------------------------------------------------------
enable_auto_shutdown   = true
auto_shutdown_time     = "1900"
auto_shutdown_timezone = "Tokyo Standard Time"

# ソフトウェアアシュアランス付きライセンスを保有している場合のみ true
enable_hybrid_benefit = false

tags = {
  purpose    = "temporary-test-vm"
  cost_owner = "naoyuki"
}
