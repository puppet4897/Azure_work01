locals {
  is_developer_bastion = var.bastion_sku == "Developer"

  # Developer SKU は専用サブネットを持たず、Azure プラットフォーム IP
  # 168.63.129.16 から RDP が着信する。Basic SKU は AzureBastionSubnet から着信する。
  rdp_source_address = local.is_developer_bastion ? "168.63.129.16" : var.bastion_subnet_prefix

  admin_password = coalesce(var.admin_password, random_password.admin.result)

  name_prefix = "${var.prefix}-${var.environment}"
  suffix      = random_string.suffix.result

  tags = merge(var.tags, {
    environment = var.environment
    managed_by  = "terraform"
    # Azure のタグ値では "/" が使えないため "-" に置換する
    repository = replace(var.repository_name, "/", "-")
  })
}

resource "random_string" "suffix" {
  length  = 5
  special = false
  upper   = false
}

resource "random_password" "admin" {
  length           = 24
  special          = true
  min_upper        = 2
  min_lower        = 2
  min_numeric      = 2
  min_special      = 2
  override_special = "!#$%*()-_=+[]"
}

# ---------------------------------------------------------------------------
# リソースグループ
# ---------------------------------------------------------------------------

resource "azurerm_resource_group" "this" {
  name     = "rg-${local.name_prefix}-${local.suffix}"
  location = var.location
  tags     = local.tags
}

# ---------------------------------------------------------------------------
# ネットワーク
# ---------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "vnet-${local.name_prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "vm" {
  name                 = "snet-${local.name_prefix}-vm"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.vm_subnet_prefix]
}

# Basic SKU のときだけ必要（名前は AzureBastionSubnet 固定）
resource "azurerm_subnet" "bastion" {
  count                = local.is_developer_bastion ? 0 : 1
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = [var.bastion_subnet_prefix]
}

# ---------------------------------------------------------------------------
# NSG : VM サブネット
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "vm" {
  name                = "nsg-${local.name_prefix}-vm"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # Bastion からの RDP のみ許可
  security_rule {
    name                       = "Allow-RDP-From-Bastion"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefix      = local.rdp_source_address
    destination_address_prefix = "*"
  }

  # インターネットからの受信は全拒否（既定の AllowVnetInBound より前で明示的に遮断）
  security_rule {
    name                       = "Deny-Internet-Inbound"
    priority                   = 4000
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "Internet"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "vm" {
  subnet_id                 = azurerm_subnet.vm.id
  network_security_group_id = azurerm_network_security_group.vm.id
}

# ---------------------------------------------------------------------------
# NSG : AzureBastionSubnet（Basic SKU 時のみ）
#   ここで接続元グローバル IP を単一アドレスに限定する。
#   実際の IP は var.allowed_source_ip（Secrets 経由で注入）から取得する。
# ---------------------------------------------------------------------------

resource "azurerm_network_security_group" "bastion" {
  count               = local.is_developer_bastion ? 0 : 1
  name                = "nsg-${local.name_prefix}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  # --- Inbound ---
  # 指定した外部 IP からの HTTPS(443) のみ許可
  security_rule {
    name                       = "Allow-HttpsInbound-From-AllowedIp"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "${var.allowed_source_ip}/32"
    destination_address_prefix = "*"
  }

  # Azure のコントロールプレーンからの管理通信（必須）
  security_rule {
    name                       = "Allow-GatewayManagerInbound"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "GatewayManager"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "Allow-AzureLoadBalancerInbound"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Bastion ホスト間のデータプレーン通信（必須）
  security_rule {
    name                       = "Allow-BastionHostCommunication"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Deny-AllInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }

  # --- Outbound ---
  security_rule {
    name                       = "Allow-SshRdpOutbound"
    priority                   = 100
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefix      = "*"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-AzureCloudOutbound"
    priority                   = 110
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "443"
    source_address_prefix      = "*"
    destination_address_prefix = "AzureCloud"
  }

  security_rule {
    name                       = "Allow-BastionCommunicationOutbound"
    priority                   = 120
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_ranges    = ["8080", "5701"]
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "VirtualNetwork"
  }

  security_rule {
    name                       = "Allow-GetSessionInformation"
    priority                   = 130
    direction                  = "Outbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = "Internet"
  }
}

resource "azurerm_subnet_network_security_group_association" "bastion" {
  count                     = local.is_developer_bastion ? 0 : 1
  subnet_id                 = azurerm_subnet.bastion[0].id
  network_security_group_id = azurerm_network_security_group.bastion[0].id
}

# ---------------------------------------------------------------------------
# Azure Bastion
# ---------------------------------------------------------------------------

resource "azurerm_public_ip" "bastion" {
  count               = local.is_developer_bastion ? 0 : 1
  name                = "pip-${local.name_prefix}-bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}

resource "azurerm_bastion_host" "this" {
  name                = "bas-${local.name_prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = var.bastion_sku
  tags                = local.tags

  # Developer SKU: VNet 指定のみ（専用サブネット・PIP 不要 / 無料）
  virtual_network_id = local.is_developer_bastion ? azurerm_virtual_network.this.id : null

  # Basic SKU: AzureBastionSubnet + Standard Public IP が必須
  dynamic "ip_configuration" {
    for_each = local.is_developer_bastion ? [] : [1]
    content {
      name                 = "configuration"
      subnet_id            = azurerm_subnet.bastion[0].id
      public_ip_address_id = azurerm_public_ip.bastion[0].id
    }
  }

  depends_on = [azurerm_subnet_network_security_group_association.bastion]
}

# ---------------------------------------------------------------------------
# VM（パブリック IP なし。アクセスは Bastion 経由のみ）
# ---------------------------------------------------------------------------

resource "azurerm_network_interface" "vm" {
  name                = "nic-${local.name_prefix}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = local.tags

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.vm.id
    private_ip_address_allocation = "Dynamic"
    # public_ip_address_id は意図的に未設定（コスト削減 + 攻撃面の削減）
  }
}

resource "azurerm_windows_virtual_machine" "this" {
  name                = "vm-${local.name_prefix}"
  computer_name       = "vm-${substr(var.prefix, 0, 6)}-${var.environment}"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  size                = var.vm_size
  admin_username      = var.admin_username
  admin_password      = local.admin_password
  network_interface_ids = [azurerm_network_interface.vm.id]
  tags                  = local.tags

  # Azure Hybrid Benefit（SA 付きライセンス保有時のみ）
  license_type = var.enable_hybrid_benefit ? "Windows_Server" : "None"

  # コスト削減: 追加課金のないプロビジョニング設定
  provision_vm_agent         = true
  allow_extension_operations = true
  patch_mode                 = "AutomaticByOS"
  encryption_at_host_enabled = false

  os_disk {
    name                 = "osdisk-${local.name_prefix}"
    caching              = "ReadWrite"
    storage_account_type = var.os_disk_type
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = var.image_sku
    version   = "latest"
  }

  # マネージド ブート診断（ストレージアカウント不要 = 追加コストなし）
  boot_diagnostics {}

  lifecycle {
    ignore_changes = [admin_password]
  }
}

# ---------------------------------------------------------------------------
# 自動シャットダウン（最大のコスト削減）
# ---------------------------------------------------------------------------

resource "azurerm_dev_test_global_vm_shutdown_schedule" "this" {
  count              = var.enable_auto_shutdown ? 1 : 0
  virtual_machine_id = azurerm_windows_virtual_machine.this.id
  location           = azurerm_resource_group.this.location
  enabled            = true
  daily_recurrence_time = var.auto_shutdown_time
  timezone              = var.auto_shutdown_timezone
  tags                  = local.tags

  notification_settings {
    enabled = false
  }
}
