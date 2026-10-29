# A root module calling sheepit-app the way a platform team's workload repository would.
# Every value is a placeholder: reserved documentation account and address ranges, and .invalid
# hostnames. Copy this into your repository, replace the values, and pin the module source to a
# released tag rather than a relative path.

terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}

variable "region" {
  description = "Region the install runs in."
  type        = string
}

provider "aws" {
  region = var.region
}

locals {
  account  = "111122223333"
  arn_base = "arn:aws:secretsmanager:${var.region}:${local.account}:secret:sheepit"

  # Stands in for your database provider's regional CA bundle. In your repository, read the
  # real one instead: file("${path.module}/postgres-ca.pem").
  placeholder_ca = <<-EOT
    -----BEGIN CERTIFICATE-----
    UExBQ0VIT0xERVIgLSByZXBsYWNlIHdpdGggeW91ciBkYXRhYmFzZSBwcm92aWRlcidz
    IHJlZ2lvbmFsIENBIGJ1bmRsZQ==
    -----END CERTIFICATE-----
  EOT
}

module "sheepit" {
  source = "../.."

  tags = {
    workload    = "sheepit"
    environment = "production"
  }

  ecs_cluster            = "platform-ec2"
  capacity_provider_name = "platform-ec2-x86"
  vpc_id                 = "vpc-0123456789abcdef0"
  subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  security_group_ids     = ["sg-0123456789abcdef0"]

  # Declarations about the cluster the module cannot read or change (see the module README,
  # "Before you apply"): four instances keep a rolling upgrade of two edge tasks placeable, and
  # every instance's agent runs with ECS_AWSVPC_BLOCK_IMDS=true.
  cluster_instance_count   = 4
  cluster_blocks_task_imds = true

  # The internal ALB's own subnets: the only peers the proxy believes about X-Forwarded-For.
  trusted_proxies = ["10.20.30.0/27", "10.20.31.0/27"]

  dashboard_listener_arn = "arn:aws:elasticloadbalancing:${var.region}:${local.account}:listener/app/platform-internal/0123456789abcdef/0123456789abcdef"
  dashboard_listener_rule = {
    priority     = 100
    host_headers = ["sheepit.example.invalid"]
  }

  sdk_listener_arn = "arn:aws:elasticloadbalancing:${var.region}:${local.account}:listener/app/platform-internal/0123456789abcdef/fedcba9876543210"
  sdk_listener_rule = {
    priority     = 101
    host_headers = ["sdk.sheepit.example.invalid"]
  }

  db_host          = "sheepit.cluster-example.invalid"
  db_ca_bundle_pem = local.placeholder_ca

  secret_arns = {
    database_url            = "${local.arn_base}/database-url-AbCdEf"
    database_url_bypass_rls = "${local.arn_base}/database-url-owner-AbCdEf"
    postgres_app_password   = "${local.arn_base}/postgres-app-password-AbCdEf"
    redis_url               = "${local.arn_base}/redis-url-AbCdEf"
    jwt_access_secret       = "${local.arn_base}/jwt-access-secret-AbCdEf"
    sdk_directory_hmac_key  = "${local.arn_base}/sdk-directory-hmac-key-AbCdEf"
    api_key_encryption_key  = "${local.arn_base}/api-key-encryption-key-AbCdEf"
    internal_service_token  = "${local.arn_base}/internal-service-token-AbCdEf"
    monitoring_scrape_token = "arn:aws:ssm:${var.region}:${local.account}:parameter/sheepit/monitoring-scrape-token"
  }

  optional_secret_arns = {
    SMTP_PASS = "${local.arn_base}/smtp-pass-AbCdEf"
  }

  api_environment = {
    SMTP_HOST           = "smtp.example.invalid"
    SMTP_PORT           = "587"
    SMTP_FROM           = "Sheepit <sheepit@example.invalid>"
    SHEEPIT_ALERT_SINKS = "stderr"
  }

  # Your mirror (N4: images are mirrored into your own registry). A private ECR registry gets an
  # execution-role grant scoped to the four Sheepit repositories; any other registry gets none.
  image_registry = "${local.account}.dkr.ecr.${var.region}.amazonaws.com/sheepit"
  image_version  = "0.6.0"

  # Pin every image by digest (from the release manifest). A tag can be moved, and these
  # containers start with every secret above.
  image_digests = {
    proxy   = "sha256:0000000000000000000000000000000000000000000000000000000000000001"
    web     = "sha256:0000000000000000000000000000000000000000000000000000000000000002"
    api     = "sha256:0000000000000000000000000000000000000000000000000000000000000003"
    migrate = "sha256:0000000000000000000000000000000000000000000000000000000000000004"
  }

  public_url = "https://sheepit.example.invalid"
}

output "sheepit" {
  description = "Everything the module exposes."
  value       = module.sheepit
}
