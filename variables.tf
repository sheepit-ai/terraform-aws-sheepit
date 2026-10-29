# Inputs. Everything environment-specific is an input with no default; a default is where one
# install's shape leaks into the next. Cross-variable rules live as preconditions next to the
# resource they protect (variable validations may reference only their own variable on the
# oldest supported Terraform).

# ── Naming and tagging ────────────────────────────────────────────────────────────────────────

variable "name_prefix" {
  description = "Prefix for every resource name (services, task families, target groups, roles). Target group names are capped at 32 characters, so keep it short."
  type        = string
  default     = "sheepit"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{0,19}$", var.name_prefix))
    error_message = "name_prefix must be 1-20 characters of lowercase letters, digits and hyphens, starting with a letter."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource and propagated to tasks. Your audited tag schema goes here; there is deliberately no default."
  type        = map(string)
}

# ── The platform this runs on (all bring-your-own) ────────────────────────────────────────────

variable "ecs_cluster" {
  description = "ARN or name of the existing ECS cluster."
  type        = string

  validation {
    condition     = length(var.ecs_cluster) > 0
    error_message = "ecs_cluster must be set."
  }
}

variable "capacity_provider_name" {
  description = "Name of the cluster's EC2 capacity provider the services place on."
  type        = string

  validation {
    condition     = length(var.capacity_provider_name) > 0
    error_message = "capacity_provider_name must be set."
  }
}

variable "cpu_architecture" {
  description = "CPU architecture of the container instances. Tasks are constrained to instances with this ecs.cpu-architecture attribute."
  type        = string
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "cluster_instance_count" {
  description = "How many container instances the capacity provider keeps available to this install at minimum. The edge service places one task per instance (distinctInstance) and a rolling upgrade runs up to floor(edge_desired_count x edge_deployment_maximum_percent / 100) edge tasks at once (4 at the defaults), so this must be at least that, or the upgrade cannot place its new tasks and stalls. The worker is a separate task group and may share an instance. The module cannot read this from the cluster; you declare it."
  type        = number

  validation {
    condition     = var.cluster_instance_count >= 1 && floor(var.cluster_instance_count) == var.cluster_instance_count
    error_message = "cluster_instance_count must be a whole number of at least 1."
  }
}

variable "cluster_blocks_task_imds" {
  description = "Declare that every container instance in the cluster runs the ECS agent with ECS_AWSVPC_BLOCK_IMDS=true. Without it, any container in an awsvpc task can read the instance role's credentials from the instance metadata service. The setting lives on your instances (in /etc/ecs/ecs.config), outside this module, so the module cannot apply it; it refuses to plan until you confirm it."
  type        = bool

  validation {
    condition     = var.cluster_blocks_task_imds == true
    error_message = "Set ECS_AWSVPC_BLOCK_IMDS=true in /etc/ecs/ecs.config on every container instance (and restart the agent), then set cluster_blocks_task_imds = true. Until then any Sheepit container could use the instance role's credentials."
  }
}

variable "vpc_id" {
  description = "VPC of the subnets and of the load balancer the target groups attach to."
  type        = string

  validation {
    condition     = can(regex("^vpc-[0-9a-f]+$", var.vpc_id))
    error_message = "vpc_id must look like vpc-<hex>."
  }
}

variable "subnet_ids" {
  description = "Private subnets for the task ENIs (awsvpc). Use subnets in at least two Availability Zones; the edge service spreads across them."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 1 && alltrue([for s in var.subnet_ids : can(regex("^subnet-[0-9a-f]+$", s))])
    error_message = "subnet_ids must hold at least one subnet-<hex> id."
  }
}

variable "security_group_ids" {
  description = "Security groups for the task ENIs. They must admit the load balancer on TCP 8080 and 8081 and allow egress to Postgres, Redis, your SMTP relay and the registry."
  type        = list(string)

  validation {
    condition     = length(var.security_group_ids) >= 1 && alltrue([for s in var.security_group_ids : can(regex("^sg-[0-9a-f]+$", s))])
    error_message = "security_group_ids must hold at least one sg-<hex> id."
  }
}

variable "trusted_proxies" {
  description = "CIDRs of the load balancer's own subnets. When the load balancer appends to X-Forwarded-For (routing.http.xff_header_processing.mode = append, the ALB default, read by the module), the bundled proxy believes the header only from these and the API peels two hops (load balancer + proxy). In any other mode they are unused and the proxy trusts nothing. Never a /0. See section 3 of the release bundle's README.md."
  type        = list(string)

  validation {
    condition = length(var.trusted_proxies) >= 1 && alltrue([
      for c in var.trusted_proxies : can(cidrhost(c, 0)) && !can(regex("/0$", c))
    ])
    error_message = "trusted_proxies must hold at least one valid CIDR, and none may be a /0."
  }
}

# ── Load balancer attachment (listener rules only; the load balancer is yours) ────────────────

variable "dashboard_listener_arn" {
  description = "ARN of the existing ALB listener that serves the dashboard hostname. The module adds one rule forwarding to the dashboard target group (proxy port 8080)."
  type        = string

  validation {
    condition     = can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]+:listener/app/", var.dashboard_listener_arn))
    error_message = "dashboard_listener_arn must be an Application Load Balancer listener ARN."
  }
}

variable "dashboard_listener_rule" {
  description = "Priority and match conditions of the dashboard listener rule. At least one condition is required. http_headers maps a header name to its accepted values."
  type = object({
    priority      = number
    host_headers  = optional(list(string), [])
    path_patterns = optional(list(string), [])
    http_headers  = optional(map(list(string)), {})
  })

  validation {
    condition     = var.dashboard_listener_rule.priority >= 1 && var.dashboard_listener_rule.priority <= 50000
    error_message = "dashboard_listener_rule.priority must be between 1 and 50000."
  }

  validation {
    condition     = length(var.dashboard_listener_rule.host_headers) + length(var.dashboard_listener_rule.path_patterns) + length(var.dashboard_listener_rule.http_headers) > 0
    error_message = "dashboard_listener_rule needs at least one of host_headers, path_patterns or http_headers."
  }
}

variable "sdk_listener_arn" {
  description = "ARN of the ALB listener that serves the SDK hostname, or null for an install with no separate SDK hostname. When set, the module adds an SDK target group (proxy port 8081) and a rule forwarding to it."
  type        = string
  default     = null

  validation {
    condition     = var.sdk_listener_arn == null || can(regex("^arn:[^:]+:elasticloadbalancing:[^:]+:[0-9]+:listener/app/", var.sdk_listener_arn))
    error_message = "sdk_listener_arn must be an Application Load Balancer listener ARN or null."
  }
}

variable "sdk_listener_rule" {
  description = "Priority and match conditions of the SDK listener rule. Required exactly when sdk_listener_arn is set."
  type = object({
    priority      = number
    host_headers  = optional(list(string), [])
    path_patterns = optional(list(string), [])
    http_headers  = optional(map(list(string)), {})
  })
  default = null

  validation {
    condition     = var.sdk_listener_rule == null || try(var.sdk_listener_rule.priority >= 1 && var.sdk_listener_rule.priority <= 50000, false)
    error_message = "sdk_listener_rule.priority must be between 1 and 50000."
  }

  validation {
    condition     = var.sdk_listener_rule == null || try(length(var.sdk_listener_rule.host_headers) + length(var.sdk_listener_rule.path_patterns) + length(var.sdk_listener_rule.http_headers) > 0, false)
    error_message = "sdk_listener_rule needs at least one of host_headers, path_patterns or http_headers."
  }
}

variable "deregistration_delay_seconds" {
  description = "How long the load balancer drains a stopping task before ECS signals it. Must cover shutdown_drain_delay_ms plus a margin."
  type        = number
  default     = 30

  validation {
    condition     = var.deregistration_delay_seconds >= 0 && var.deregistration_delay_seconds <= 3600
    error_message = "deregistration_delay_seconds must be between 0 and 3600."
  }
}

# ── Data tier (yours; the module only references it) ──────────────────────────────────────────

variable "db_host" {
  description = "Postgres endpoint hostname. Used only to print the exact connection-string shapes your secrets must hold (output database_url_formats); the module never connects to it."
  type        = string

  validation {
    condition     = length(var.db_host) > 0 && !can(regex("[/:@?]", var.db_host))
    error_message = "db_host must be a bare hostname."
  }
}

variable "db_port" {
  description = "Postgres port."
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Postgres database name."
  type        = string
  default     = "sheepit"
}

variable "db_ca_bundle_pem" {
  description = "PEM bundle of the CA that signed your Postgres server certificate (for RDS: your region's bundle, not the global one, which exceeds the task-definition size limit). Public data, not a secret. Written into each task at /etc/sheepit/postgres-ca.pem for sslmode=verify-full."
  type        = string

  validation {
    condition     = can(regex("-----BEGIN CERTIFICATE-----", var.db_ca_bundle_pem)) && can(regex("-----END CERTIFICATE-----", var.db_ca_bundle_pem)) && length(var.db_ca_bundle_pem) <= 24576 && !can(regex("'", var.db_ca_bundle_pem))
    error_message = "db_ca_bundle_pem must be a PEM certificate bundle (BEGIN and END CERTIFICATE markers) of at most 24 KiB with no single quotes."
  }
}

# ── Secrets: ARNs only. The module never reads a secret value into state. ─────────────────────

variable "secret_arns" {
  description = "Secrets Manager secret ARNs or SSM Parameter Store parameter ARNs (SecureString) for the required secrets. ECS resolves them at task start. The database_url values are whole connection strings; see output database_url_formats for their exact shape."
  type = object({
    database_url            = string
    database_url_bypass_rls = string
    migrate_database_url    = optional(string)
    postgres_app_password   = string
    redis_url               = string
    jwt_access_secret       = string
    sdk_directory_hmac_key  = string
    api_key_encryption_key  = string
    internal_service_token  = string
    monitoring_scrape_token = string
  })

  validation {
    condition = alltrue([
      for k, v in var.secret_arns : v == null || can(regex("^arn:[^:]+:(secretsmanager:[^:]+:[0-9]+:secret:[^:*?]+|ssm:[^:]+:[0-9]+:parameter/[^*?]+)$", v))
    ])
    error_message = "Every secret_arns value must be a full Secrets Manager secret ARN (no JSON-key suffix) or an SSM parameter ARN, with no wildcard (* or ?)."
  }
}

variable "optional_secret_arns" {
  description = "Optional secrets, keyed by the environment variable they fill on the api and worker containers. Same ARN rules as secret_arns."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.optional_secret_arns) : contains([
        "SMTP_USER", "SMTP_PASS", "SHEEPIT_SSO_CLIENT_SECRET", "SHEEPIT_SSO_REFRESH_TOKEN_KEY",
        "MFA_ENCRYPTION_KEY", "SHEEPIT_ALERT_WEBHOOK_URL", "SHEEPIT_LICENCE",
      ], k)
    ])
    error_message = "optional_secret_arns keys must be one of SMTP_USER, SMTP_PASS, SHEEPIT_SSO_CLIENT_SECRET, SHEEPIT_SSO_REFRESH_TOKEN_KEY, MFA_ENCRYPTION_KEY, SHEEPIT_ALERT_WEBHOOK_URL, SHEEPIT_LICENCE."
  }

  validation {
    condition = alltrue([
      for v in values(var.optional_secret_arns) : can(regex("^arn:[^:]+:(secretsmanager:[^:]+:[0-9]+:secret:[^:*?]+|ssm:[^:]+:[0-9]+:parameter/[^*?]+)$", v))
    ])
    error_message = "Every optional_secret_arns value must be a full Secrets Manager secret ARN or an SSM parameter ARN, with no wildcard (* or ?)."
  }
}

variable "api_environment" {
  description = "Optional non-secret settings for the api and worker containers, keyed by variable name. Only the documented optional variables are accepted; the ones this module derives are not."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k in keys(var.api_environment) : contains([
        "SMTP_HOST", "SMTP_PORT", "SMTP_FROM", "OPS_ALERT_EMAIL", "LOG_LEVEL",
        "SHEEPIT_RATE_LIMIT_RPM", "SHEEPIT_DEVICE_REGISTER_IP_LIMIT", "SHEEPIT_DEVICE_REQUEST_LIMIT_RPM",
        "MAX_DEVICES_PER_ENVIRONMENT", "SHEEPIT_EXTRA_CORS_ORIGINS", "SHEEPIT_SIGNUP", "SHEEPIT_SIGNUP_ALLOWLIST",
        "SHEEPIT_SSO_ISSUER", "SHEEPIT_SSO_CLIENT_ID", "SHEEPIT_SSO_REDIRECT_URI", "SHEEPIT_SSO_DISCOVERY_URL",
        "SHEEPIT_SSO_ENTRA_TENANT_ID", "SHEEPIT_SSO_ORGANIZATION_ID", "SHEEPIT_SSO_LIVENESS",
        "SHEEPIT_INSTALL_ORGANIZATION_ID", "SHEEPIT_SDK_PUBLIC_URL", "SHEEPIT_SDK_DIAGNOSTICS",
        "SHEEPIT_RETENTION_DAYS", "SHEEPIT_RETENTION_DAYS_EVENTS_RAW", "SHEEPIT_RETENTION_DAYS_CRASH_REPORTS",
        "SHEEPIT_RETENTION_DAYS_PERFORMANCE_METRICS", "SHEEPIT_RETENTION_DAYS_END_USER_SESSIONS",
        "SHEEPIT_RETENTION_DAYS_RELEASE_HEALTH", "SHEEPIT_ALERT_SINKS", "SHEEPIT_INGEST_LAG_THRESHOLD",
        "SHEEPIT_SERVER_ERROR_THRESHOLD", "SHEEPIT_SERVER_ERROR_WINDOW_MINUTES",
        "SHEEPIT_UPDATE_CHECK", "SHEEPIT_UPDATE_MANIFEST_URL",
      ], k)
    ])
    error_message = "api_environment accepts only the documented optional variables (see the module README). Secrets go in optional_secret_arns."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key that encrypts the secrets, or null. When set, the created execution role may kms:Decrypt with it. The module never creates a key."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:[^:]+:kms:[^:]+:[0-9]+:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN or null."
  }
}

# ── IAM ───────────────────────────────────────────────────────────────────────────────────────

variable "execution_role_arn" {
  description = "Existing task execution role, or null to create one. A supplied role must already grant what output execution_role_policy_json lists."
  type        = string
  default     = null

  validation {
    condition     = var.execution_role_arn == null || can(regex("^arn:[^:]+:iam::[0-9]+:role/[^*?]+$", var.execution_role_arn))
    error_message = "execution_role_arn must be an IAM role ARN or null."
  }
}

variable "task_role_arn" {
  description = "Existing task role, or null to create one with no permissions (the application calls no AWS API on a BYOC install)."
  type        = string
  default     = null

  validation {
    condition     = var.task_role_arn == null || can(regex("^arn:[^:]+:iam::[0-9]+:role/[^*?]+$", var.task_role_arn))
    error_message = "task_role_arn must be an IAM role ARN or null."
  }
}

variable "permissions_boundary_arn" {
  description = "Permissions boundary attached to every role the module creates, or null."
  type        = string
  default     = null

  validation {
    condition     = var.permissions_boundary_arn == null || can(regex("^arn:[^:]+:iam::([0-9]+|aws):policy/[^*?]+$", var.permissions_boundary_arn))
    error_message = "permissions_boundary_arn must be an IAM policy ARN or null."
  }
}

variable "role_name_prefix" {
  description = "Prefix for the names of roles the module creates, to fit a naming convention your SCPs enforce."
  type        = string
  default     = ""
}

variable "iam_role_path" {
  description = "IAM path for roles the module creates."
  type        = string
  default     = "/"

  validation {
    condition     = can(regex("^/([^/]+/)*$", var.iam_role_path))
    error_message = "iam_role_path must start and end with a slash."
  }
}

# ── Logs ──────────────────────────────────────────────────────────────────────────────────────

variable "log_group_name" {
  description = "Existing CloudWatch log group to write to, or null to create /sheepit/<name_prefix>."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the log group the module creates. Ignored for an existing log group."
  type        = number
  default     = 30

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs retention value."
  }
}

# ── Images ────────────────────────────────────────────────────────────────────────────────────

variable "image_registry" {
  description = "Registry host and optional path prefix your mirror serves the Sheepit images from, without a scheme or trailing slash. Images resolve to <image_registry>/<repository>:<image_version>."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]*(:[0-9]+)?(/[a-z0-9._-]+)*$", var.image_registry))
    error_message = "image_registry must be a registry host with an optional port and path, with no scheme and no trailing slash."
  }
}

variable "image_version" {
  description = "The Sheepit release to run. Bumping it is the whole of an eligible upgrade."
  type        = string

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$", var.image_version))
    error_message = "image_version must be a semantic version such as 0.6.0."
  }
}

variable "image_digests" {
  description = "Optional per-image digests (keys: proxy, web, api, migrate). An image with a digest is referenced as <image_registry>/<repository>@<digest>, which pins it even if the tag moves."
  type        = map(string)
  default     = {}

  validation {
    condition = alltrue([
      for k, v in var.image_digests : contains(["proxy", "web", "api", "migrate"], k) && can(regex("^sha256:[0-9a-f]{64}$", v))
    ])
    error_message = "image_digests keys must be proxy, web, api or migrate, and each value a sha256:<64 hex> digest."
  }
}

# ── Application settings ──────────────────────────────────────────────────────────────────────

variable "public_url" {
  description = "The HTTPS origin users reach the dashboard on, without a trailing slash."
  type        = string

  validation {
    condition     = can(regex("^https://[^/]+$", var.public_url))
    error_message = "public_url must be an https:// origin with no path and no trailing slash."
  }
}

variable "shutdown_drain_delay_ms" {
  description = "How long a stopping API keeps serving with /health/serving already 503, so the in-task proxy stops routing to it. 0-10000."
  type        = number
  default     = 6000

  validation {
    condition     = var.shutdown_drain_delay_ms >= 0 && var.shutdown_drain_delay_ms <= 10000 && floor(var.shutdown_drain_delay_ms) == var.shutdown_drain_delay_ms
    error_message = "shutdown_drain_delay_ms must be a whole number between 0 and 10000."
  }
}

# ── Capacity and rollout ──────────────────────────────────────────────────────────────────────

variable "edge_desired_count" {
  description = "Running edge tasks (proxy + web + api). Two keep the install serving through a task or host loss and through a rolling upgrade. The worker service is always exactly one task and has no such input."
  type        = number
  default     = 2

  validation {
    condition     = var.edge_desired_count >= 1 && floor(var.edge_desired_count) == var.edge_desired_count
    error_message = "edge_desired_count must be a whole number of at least 1. To stop the install for a maintenance release, set maintenance_stop instead."
  }
}

variable "edge_deployment_maximum_percent" {
  description = "The edge service's deployment maximum percent. 200 (the default) starts a whole new set of edge tasks before stopping the old; a lower value replaces them a few at a time and needs fewer instances, e.g. 150 with edge_desired_count 2 runs at most 3 tasks, one replacement at a time. ECS rounds the result down, and it must stay above edge_desired_count or a rollout cannot start."
  type        = number
  default     = 200

  validation {
    condition     = var.edge_deployment_maximum_percent > 100 && var.edge_deployment_maximum_percent <= 200 && floor(var.edge_deployment_maximum_percent) == var.edge_deployment_maximum_percent
    error_message = "edge_deployment_maximum_percent must be a whole number above 100 and at most 200."
  }
}

variable "maintenance_stop" {
  description = "Stops every Sheepit task (edge and worker desired 0). Step one of a release that is not zero-downtime eligible; see the README."
  type        = bool
  default     = false
}

variable "maintenance_ack_version" {
  description = "Set to image_version in step two of a release that is not zero-downtime eligible, acknowledging the downtime. Passed to the migrate container as SHEEPIT_MAINTENANCE_ACK. Leave null otherwise."
  type        = string
  default     = null
}

variable "container_sizes" {
  description = "CPU units and hard memory limit (MiB) per container."
  type = object({
    proxy   = optional(object({ cpu = number, memory = number }), { cpu = 128, memory = 128 })
    web     = optional(object({ cpu = number, memory = number }), { cpu = 256, memory = 256 })
    api     = optional(object({ cpu = number, memory = number }), { cpu = 512, memory = 512 })
    worker  = optional(object({ cpu = number, memory = number }), { cpu = 512, memory = 512 })
    migrate = optional(object({ cpu = number, memory = number }), { cpu = 256, memory = 256 })
  })
  default = {}

  validation {
    condition = alltrue([
      for k, v in var.container_sizes : v.cpu >= 0 && v.memory >= 64
    ])
    error_message = "Every container size needs cpu >= 0 and memory >= 64 MiB."
  }
}

variable "api_stop_timeout_seconds" {
  description = "Seconds ECS waits between SIGTERM and SIGKILL for the api and worker containers. The API drains within 25 seconds; at least 35 leaves room."
  type        = number
  default     = 35

  validation {
    condition     = var.api_stop_timeout_seconds >= 35 && var.api_stop_timeout_seconds <= 120
    error_message = "api_stop_timeout_seconds must be between 35 and 120."
  }
}

variable "migrate_timeout_seconds" {
  description = "How long the api container waits for migrate to exit 0 before the task gives up. In ECS a container's startTimeout bounds how long the containers that depend on it wait for it, so this is set as migrate's startTimeout. Size it for your slowest expected schema upgrade."
  type        = number
  default     = 600

  validation {
    condition     = var.migrate_timeout_seconds >= 60 && var.migrate_timeout_seconds <= 3600
    error_message = "migrate_timeout_seconds must be between 60 and 3600."
  }
}

variable "api_boot_timeout_seconds" {
  description = "How long the API may take from the end of migration to answering /health/serving (boot DDL included). The api and web containers' startTimeout, which bounds how long the proxy waits for them, is migrate_timeout_seconds plus this."
  type        = number
  default     = 300

  validation {
    condition     = var.api_boot_timeout_seconds >= 60 && var.api_boot_timeout_seconds <= 900
    error_message = "api_boot_timeout_seconds must be between 60 and 900."
  }
}

variable "health_check_grace_period_seconds" {
  description = "How long ECS ignores load balancer health checks on a new edge task. Must cover migrate_timeout_seconds plus api_boot_timeout_seconds plus 120 s for the proxy to start and the load balancer to see two healthy checks, or ECS stops a task mid-migration."
  type        = number
  default     = 1020

  validation {
    condition     = var.health_check_grace_period_seconds >= 0 && var.health_check_grace_period_seconds <= 7200
    error_message = "health_check_grace_period_seconds must be between 0 and 7200."
  }
}
