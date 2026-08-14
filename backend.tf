terraform {
  # 部分構成 (partial configuration)。
  # 実際の値は init 時に -backend-config で注入する:
  #   terraform init -backend-config=env/dev.backend.hcl
  #
  # use_azuread_auth = true により、ストレージアカウントキーではなく
  # Entra ID (OIDC) で Blob にアクセスする。GitHub Secrets にキーを置かずに済む。
  backend "azurerm" {
    use_azuread_auth = true
  }
}
