# Secrets by ARN. ECS resolves each `valueFrom` at task start, so a value never passes through
# Terraform and never lands in state. There is deliberately no data source here: reading a
# secret's value (or even its metadata) is the platform's business, not this module's.

locals {
  # Environment variable -> ARN, for the api container (edge) and the worker.
  api_secret_arns = merge(
    {
      DATABASE_URL            = var.secret_arns.database_url
      DATABASE_URL_BYPASS_RLS = var.secret_arns.database_url_bypass_rls
      REDIS_URL               = var.secret_arns.redis_url
      JWT_ACCESS_SECRET       = var.secret_arns.jwt_access_secret
      SDK_DIRECTORY_HMAC_KEY  = var.secret_arns.sdk_directory_hmac_key
      API_KEY_ENCRYPTION_KEY  = var.secret_arns.api_key_encryption_key
      INTERNAL_SERVICE_TOKEN  = var.secret_arns.internal_service_token
      MONITORING_SCRAPE_TOKEN = var.secret_arns.monitoring_scrape_token
    },
    var.optional_secret_arns,
  )

  # The migrator runs as the schema owner, exactly as compose.byoc.yml's `migrate` service does.
  # It defaults to the same owner connection string the API's bypass pool uses.
  migrate_secret_arns = {
    DATABASE_URL          = coalesce(var.secret_arns.migrate_database_url, var.secret_arns.database_url_bypass_rls)
    POSTGRES_APP_PASSWORD = var.secret_arns.postgres_app_password
  }

  all_secret_arns = distinct(concat(values(local.api_secret_arns), values(local.migrate_secret_arns)))

  # IAM needs the two services split: Secrets Manager reads are secretsmanager:GetSecretValue,
  # Parameter Store reads are ssm:GetParameters.
  secretsmanager_arns = [for a in local.all_secret_arns : a if split(":", a)[2] == "secretsmanager"]
  ssm_parameter_arns  = [for a in local.all_secret_arns : a if split(":", a)[2] == "ssm"]

  # ECS `secrets` arrays, sorted by name so a plan never shows a reorder as a change.
  api_secrets     = [for k in sort(keys(local.api_secret_arns)) : { name = k, valueFrom = local.api_secret_arns[k] }]
  migrate_secrets = [for k in sort(keys(local.migrate_secret_arns)) : { name = k, valueFrom = local.migrate_secret_arns[k] }]
}
