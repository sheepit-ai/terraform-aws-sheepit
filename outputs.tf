output "edge_service_name" {
  description = "Name of the edge ECS service (proxy + web + api)."
  value       = aws_ecs_service.edge.name
}

output "worker_service_name" {
  description = "Name of the worker ECS service (schedulers; always one task)."
  value       = aws_ecs_service.worker.name
}

output "edge_task_definition_arn" {
  description = "ARN (family:revision) of the edge task definition this apply registered."
  value       = aws_ecs_task_definition.edge.arn
}

output "worker_task_definition_arn" {
  description = "ARN (family:revision) of the worker task definition this apply registered."
  value       = aws_ecs_task_definition.worker.arn
}

output "dashboard_target_group_arn" {
  description = "Target group behind the dashboard listener rule (proxy port 8080)."
  value       = aws_lb_target_group.dashboard.arn
}

output "sdk_target_group_arn" {
  description = "Target group behind the SDK listener rule (proxy port 8081), or null when sdk_listener_arn is null."
  value       = local.create_sdk ? aws_lb_target_group.sdk[0].arn : null
}

output "log_group_name" {
  description = "CloudWatch log group every container writes to."
  value       = local.log_group_name
}

output "execution_role_arn" {
  description = "Task execution role in use (created or supplied)."
  value       = local.execution_role_arn
}

output "task_role_arn" {
  description = "Task role in use (created or supplied)."
  value       = local.task_role_arn
}

output "execution_role_policy_json" {
  description = "The least-privilege policy the execution role needs. Attach it yourself when you supply execution_role_arn."
  value       = local.execution_policy_json
}

output "database_url_formats" {
  description = "The exact connection-string shape each database secret must hold. Replace <...> with the real value, percent-encoding any character a URL reserves."
  value = {
    database_url            = "postgresql://goatech_app_login:<POSTGRES_APP_PASSWORD>@${var.db_host}:${var.db_port}/${var.db_name}?sslmode=verify-full&sslrootcert=${local.ca_file}"
    database_url_bypass_rls = "postgresql://<owner user>:<owner password>@${var.db_host}:${var.db_port}/${var.db_name}?sslmode=verify-full&sslrootcert=${local.ca_file}"
  }
}
