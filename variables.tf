variable "subscription_id" {
  description = "デプロイ先サブスクリプション ID。null の場合は ARM_SUBSCRIPTION_ID 環境変数 / az CLI の既定値を使用"
  type        = string
  default     = null
}

variable "environment" {
  description = "環境名。リソース名とタグに使用"
  type        = string
  default     = "dev"

  validation {
    condition     = can(regex("^[a-z0-9]{2,8}$", var.environment))
    error_message = "environment は小文字英数字 2〜8 文字で指定してください。"
  }
}

variable "repository_name" {
  description = "管理元の GitHub リポジトリ（タグに記録される）。CI では TF_VAR_repository_name で自動設定"
  type        = string
  default     = "puppet4897/Azure_work01"
}

variable "prefix" {
  description = "全リソース名の接頭辞（小文字英数字）"
  type        = string
  default     = "testwin"

  validation {
    condition     = can(regex("^[a-z0-9]{3,10}$", var.prefix))
    error_message = "prefix は小文字英数字 3〜10 文字で指定してください。"
  }
}

variable "location" {
  description = "デプロイ先リージョン"
  type        = string
  default     = "japaneast"
}

# ---------------------------------------------------------------------------
# Bastion
# ---------------------------------------------------------------------------

variable "bastion_sku" {
  description = <<-EOT
    Azure Bastion の SKU。
      Developer : 無料。ただし専用サブネット/パブリック IP を持たないため、
                  NSG による「接続元グローバル IP の制限」ができない。
      Basic     : AzureBastionSubnet + Public IP を作成し、NSG で受信 443 を
                  allowed_source_ip のみに制限できる（要件を満たす構成）。
  EOT
  type        = string
  default     = "Developer"

  validation {
    condition     = contains(["Developer", "Basic"], var.bastion_sku)
    error_message = "bastion_sku は Developer または Basic を指定してください。"
  }
}

variable "allowed_source_ip" {
  description = <<-EOT
    Bastion への接続を許可する外部グローバル IP（bastion_sku = Basic のときのみ有効）。

    リポジトリが Public のため、この値はコードに書かず外部から注入する。
      CI    : GitHub Secrets の ALLOWED_SOURCE_IP を TF_VAR_allowed_source_ip として渡す
      ローカル: secrets.auto.tfvars（.gitignore 済み）に記述するか
                export TF_VAR_allowed_source_ip=x.x.x.x で渡す
  EOT
  type        = string
  default     = null
  sensitive   = true

  # NOTE: 変数間を参照する validation は Terraform 1.9 以降で利用可能。
  validation {
    condition = (
      var.bastion_sku != "Basic" ||
      (var.allowed_source_ip != null && can(cidrhost("${var.allowed_source_ip}/32", 0)))
    )
    error_message = <<-EOT
      bastion_sku = "Basic" のときは allowed_source_ip（単一の IPv4 アドレス）が必須です。
      ローカルでは secrets.auto.tfvars に記述するか TF_VAR_allowed_source_ip を設定してください。
    EOT
  }
}

# ---------------------------------------------------------------------------
# ネットワーク
# ---------------------------------------------------------------------------

variable "vnet_address_space" {
  description = "VNet のアドレス空間"
  type        = list(string)
  default     = ["10.10.0.0/16"]
}

variable "bastion_subnet_prefix" {
  description = "AzureBastionSubnet の CIDR（/26 以上が必須）"
  type        = string
  default     = "10.10.0.0/26"
}

variable "vm_subnet_prefix" {
  description = "VM を配置するサブネットの CIDR"
  type        = string
  default     = "10.10.1.0/24"
}

# ---------------------------------------------------------------------------
# VM
# ---------------------------------------------------------------------------

variable "vm_size" {
  description = "VM サイズ。テスト用の最安クラスは B シリーズ"
  type        = string
  default     = "Standard_B2s"
}

variable "os_disk_type" {
  description = "OS ディスク種別。Standard_LRS(HDD) が最安"
  type        = string
  default     = "Standard_LRS"

  validation {
    condition     = contains(["Standard_LRS", "StandardSSD_LRS", "Premium_LRS"], var.os_disk_type)
    error_message = "Standard_LRS / StandardSSD_LRS / Premium_LRS のいずれかを指定してください。"
  }
}

variable "os_disk_size_gb" {
  description = "OS ディスクサイズ(GB)。Windows Server の最小は 127GB"
  type        = number
  default     = 127
}

variable "image_sku" {
  description = "Windows Server イメージ SKU（従量課金にライセンス込み）"
  type        = string
  default     = "2022-datacenter-azure-edition"
}

variable "admin_username" {
  description = "ローカル管理者ユーザー名（administrator 等の予約語は不可）"
  type        = string
  default     = "azureadmin"
}

variable "admin_password" {
  description = "管理者パスワード。null の場合は random_password で自動生成し、Key Vault に格納する"
  type        = string
  default     = null
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Key Vault
# ---------------------------------------------------------------------------

variable "grant_deployer_kv_access" {
  description = <<-EOT
    実行プリンシパル（CI のサービスプリンシパル / ローカルのユーザー）に
    Key Vault Secrets Officer ロールを Terraform 側で付与するか。
    ブートストラップスクリプトで既にサブスクリプションスコープの権限を
    付与済みの場合は false にできる。
  EOT
  type        = bool
  default     = true
}

variable "kv_role_propagation_delay" {
  description = "Key Vault の RBAC ロール付与が伝播するまでの待機時間"
  type        = string
  default     = "60s"
}

# ---------------------------------------------------------------------------
# コスト削減
# ---------------------------------------------------------------------------

variable "enable_auto_shutdown" {
  description = "自動シャットダウンを有効にする（停止時間分の課金を止める最大のコスト削減策）"
  type        = bool
  default     = true
}

variable "auto_shutdown_time" {
  description = "自動シャットダウン時刻 (HHmm, 24時間表記)"
  type        = string
  default     = "1900"
}

variable "auto_shutdown_timezone" {
  description = "自動シャットダウンのタイムゾーン"
  type        = string
  default     = "Tokyo Standard Time"
}

variable "enable_hybrid_benefit" {
  description = <<-EOT
    Azure Hybrid Benefit を使う場合のみ true。
    ソフトウェアアシュアランス付きの Windows Server ライセンスを保有している場合に限り
    使用でき、Windows のライセンス料が課金対象外になる。保有していない場合は必ず false。
  EOT
  type        = bool
  default     = false
}

variable "tags" {
  description = "全リソースに付与する追加タグ（environment / managed_by は自動付与）"
  type        = map(string)
  default = {
    purpose = "temporary-test-vm"
  }
}
