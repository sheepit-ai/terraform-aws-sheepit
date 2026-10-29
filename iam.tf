# Two roles, created only when not supplied:
#   execution role — what the ECS agent needs to START a task: pull images, write logs, resolve
#                    the listed secrets (and decrypt them with kms_key_arn). Nothing else.
#   task role      — what the running application may call. Empty: a BYOC install calls no AWS API.
# Every created role honours permissions_boundary_arn, role_name_prefix and iam_role_path.

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {}

locals {
  # The install's region and account, from inputs and the caller's identity rather than
  # aws_region (whose region attribute is named differently on the two provider majors).
  region     = split(":", var.dashboard_listener_arn)[3]
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  create_execution_role = var.execution_role_arn == null
  create_task_role      = var.task_role_arn == null

  repositories = {
    proxy   = "sheepit-proxy"
    web     = "sheepit-web-byoc"
    api     = "sheepit-api"
    migrate = "sheepit-migrate"
  }

  # When the mirror is a private ECR registry, scope the pull to exactly these repositories.
  # Any other registry needs no IAM from this role.
  ecr_registry    = try(regex("^([0-9]{12})\\.dkr\\.ecr\\.([a-z0-9-]+)\\.amazonaws\\.com(?:\\.cn)?(/.*)?$", var.image_registry), null)
  ecr_path_prefix = local.ecr_registry == null ? "" : trimprefix(try(coalesce(local.ecr_registry[2], ""), ""), "/")
  ecr_repository_arns = local.ecr_registry == null ? [] : [
    for repo in values(local.repositories) :
    "arn:${local.partition}:ecr:${local.ecr_registry[1]}:${local.ecr_registry[0]}:repository/${join("/", compact([local.ecr_path_prefix, repo]))}"
  ]

  # Each group is filtered with a `for ... if` so groups of different shapes can be
  # concatenated (a conditional would need both branches to have one type).
  execution_policy_statements = concat(
    [for st in [
      {
        Sid    = "EcrAuthorizationToken"
        Effect = "Allow"
        # GetAuthorizationToken is registry-wide and accepts no resource narrower than "*".
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "EcrPullSheepitImages"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage"]
        Resource = local.ecr_repository_arns
      },
    ] : st if local.ecr_registry != null],
    [
      {
        Sid      = "WriteContainerLogs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${local.log_group_arn}:log-stream:*"]
      },
    ],
    [for st in [
      {
        Sid      = "ReadListedSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = local.secretsmanager_arns
      },
    ] : st if length(local.secretsmanager_arns) > 0],
    [for st in [
      {
        Sid      = "ReadListedParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameters"]
        Resource = local.ssm_parameter_arns
      },
    ] : st if length(local.ssm_parameter_arns) > 0],
    [for st in [
      {
        Sid      = "DecryptListedSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
        # Only when Secrets Manager or Parameter Store decrypts on this role's behalf, never a
        # direct Decrypt call with the role's credentials.
        Condition = {
          StringEquals = {
            "kms:ViaService" = ["secretsmanager.${local.region}.amazonaws.com", "ssm.${local.region}.amazonaws.com"]
          }
        }
      },
    ] : st if var.kms_key_arn != null],
  )

  execution_policy_json = jsonencode({
    Version   = "2012-10-17"
    Statement = local.execution_policy_statements
  })

  # The two trust policies differ on purpose. "Amazon ECS task IAM role" (developer guide,
  # task-iam-roles) documents aws:SourceArn = arn:<p>:ecs:<region>:<account>:* plus
  # aws:SourceAccount for the TASK role, and says a per-cluster SourceArn is not supported.
  # "Amazon ECS task execution IAM role" (task_execution_IAM_role) shows no condition and says
  # nothing about SourceArn, so the EXECUTION role keeps only aws:SourceAccount (same
  # ecs-tasks principal): a SourceArn ECS may not supply there would stop every task from
  # starting. Whether it does is a T-C follow-up. A platform that wants a different
  # execution-role trust passes its own role in execution_role_arn.
  execution_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
      },
    ]
  })

  task_trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ecs-tasks.amazonaws.com" }
        Action    = "sts:AssumeRole"
        Condition = {
          ArnLike      = { "aws:SourceArn" = "arn:${local.partition}:ecs:${local.region}:${local.account_id}:*" }
          StringEquals = { "aws:SourceAccount" = local.account_id }
        }
      },
    ]
  })

  execution_role_arn = local.create_execution_role ? aws_iam_role.execution[0].arn : var.execution_role_arn
  task_role_arn      = local.create_task_role ? aws_iam_role.task[0].arn : var.task_role_arn
}

resource "aws_iam_role" "execution" {
  count = local.create_execution_role ? 1 : 0

  name                 = "${var.role_name_prefix}${var.name_prefix}-execution"
  path                 = var.iam_role_path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = local.execution_trust_policy
  tags                 = var.tags
}

resource "aws_iam_role_policy" "execution" {
  count = local.create_execution_role ? 1 : 0

  name   = "sheepit-task-start"
  role   = aws_iam_role.execution[0].id
  policy = local.execution_policy_json
}

resource "aws_iam_role" "task" {
  count = local.create_task_role ? 1 : 0

  name                 = "${var.role_name_prefix}${var.name_prefix}-task"
  path                 = var.iam_role_path
  permissions_boundary = var.permissions_boundary_arn
  assume_role_policy   = local.task_trust_policy
  tags                 = var.tags
}
