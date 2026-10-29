# One log group for every container; streams are <service>/<container>/<task id>.
# Bring your own with log_group_name, or the module creates /sheepit/<name_prefix>.

resource "aws_cloudwatch_log_group" "this" {
  count = var.log_group_name == null ? 1 : 0

  name              = "/sheepit/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_cloudwatch_log_group" "existing" {
  count = var.log_group_name == null ? 0 : 1

  name = var.log_group_name
}

locals {
  log_group_name = var.log_group_name == null ? aws_cloudwatch_log_group.this[0].name : data.aws_cloudwatch_log_group.existing[0].name
  log_group_arn  = var.log_group_name == null ? aws_cloudwatch_log_group.this[0].arn : data.aws_cloudwatch_log_group.existing[0].arn

  # The awslogs driver needs the region. Read it from the log group's own ARN
  # (arn:<partition>:logs:<region>:<account>:log-group:<name>) rather than from aws_region,
  # whose region attribute is named differently on the two provider majors this module accepts.
  log_region = split(":", local.log_group_arn)[3]
}
