# Contract tests for the sheepit-app module, run with a mocked AWS provider: no account, no
# credentials, no network beyond the provider download. scripts/check.sh runs this file under
# both OpenTofu and Terraform. The values below are placeholders (documentation account, .invalid
# hosts), never a real install's.

mock_provider "aws" {
  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }
  mock_data "aws_lb_listener" {
    defaults = {
      load_balancer_arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:loadbalancer/app/platform/0123456789abcdef"
    }
  }
  mock_data "aws_lb" {
    defaults = {
      load_balancer_type         = "application"
      xff_header_processing_mode = "append"
    }
  }
  mock_data "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:platform-logs"
    }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:111122223333:log-group:/sheepit/sheepit"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::111122223333:role/sheepit-mock"
    }
  }
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:us-east-1:111122223333:targetgroup/sheepit-mock/0123456789abcdef"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:111122223333:task-definition/sheepit-mock:1"
    }
  }
}

variables {
  tags                   = { workload = "sheepit" }
  ecs_cluster            = "platform-ec2"
  capacity_provider_name = "platform-ec2-x86"
  vpc_id                 = "vpc-0123456789abcdef0"
  subnet_ids             = ["subnet-0123456789abcdef0", "subnet-0fedcba9876543210"]
  security_group_ids     = ["sg-0123456789abcdef0"]
  trusted_proxies        = ["10.20.30.0/27", "10.20.31.0/27"]

  cluster_instance_count   = 4
  cluster_blocks_task_imds = true

  dashboard_listener_arn  = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/platform/0123456789abcdef/0123456789abcdef"
  dashboard_listener_rule = { priority = 100, host_headers = ["sheepit.example.invalid"] }
  sdk_listener_arn        = "arn:aws:elasticloadbalancing:us-east-1:111122223333:listener/app/platform/0123456789abcdef/fedcba9876543210"
  sdk_listener_rule       = { priority = 101, host_headers = ["sdk.sheepit.example.invalid"] }

  db_host          = "db.example.invalid"
  db_ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nUExBQ0VIT0xERVI=\n-----END CERTIFICATE-----\n"

  secret_arns = {
    database_url            = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/database-url-AbCdEf"
    database_url_bypass_rls = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/database-url-owner-AbCdEf"
    postgres_app_password   = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/app-password-AbCdEf"
    redis_url               = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/redis-url-AbCdEf"
    jwt_access_secret       = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/jwt-AbCdEf"
    sdk_directory_hmac_key  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/sdk-hmac-AbCdEf"
    api_key_encryption_key  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/api-key-enc-AbCdEf"
    internal_service_token  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/internal-AbCdEf"
    monitoring_scrape_token = "arn:aws:ssm:us-east-1:111122223333:parameter/sheepit/monitoring-scrape-token"
  }

  image_registry = "registry.example.invalid/mirror"
  image_version  = "0.6.0"
  public_url     = "https://sheepit.example.invalid"
}

# ── (2) image references, (3) worker singleton, (4) rollout shape, (5) secrets by ARN ─────────

run "defaults" {
  command = apply

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => c.image
      } == {
      "postgres-ca" = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "migrate"     = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "api"         = "registry.example.invalid/mirror/sheepit-api:0.6.0"
      "web"         = "registry.example.invalid/mirror/sheepit-web-byoc:0.6.0"
      "proxy"       = "registry.example.invalid/mirror/sheepit-proxy:0.6.0"
    }
    error_message = "edge images must be exactly <image_registry>/<repository>:<image_version>"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.worker.container_definitions) : c.name => c.image
      } == {
      "postgres-ca" = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "migrate"     = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "api"         = "registry.example.invalid/mirror/sheepit-api:0.6.0"
    }
    error_message = "worker images must be exactly <image_registry>/<repository>:<image_version>"
  }

  assert {
    condition     = aws_ecs_service.worker.desired_count == 1 && aws_ecs_service.worker.deployment_minimum_healthy_percent == 0 && aws_ecs_service.worker.deployment_maximum_percent == 100
    error_message = "worker must be exactly one task, stop-then-start (0/100)"
  }

  assert {
    condition     = aws_ecs_service.edge.desired_count == 2 && aws_ecs_service.edge.deployment_minimum_healthy_percent == 100 && aws_ecs_service.edge.deployment_maximum_percent == 200
    error_message = "edge must default to 2 tasks rolling at 100/200"
  }

  assert {
    condition     = aws_ecs_service.edge.deployment_circuit_breaker[0].enable && aws_ecs_service.edge.deployment_circuit_breaker[0].rollback && aws_ecs_service.worker.deployment_circuit_breaker[0].enable && aws_ecs_service.worker.deployment_circuit_breaker[0].rollback
    error_message = "both services need the deployment circuit breaker with rollback"
  }

  assert {
    condition     = [for p in aws_ecs_service.edge.placement_constraints : p.type] == ["distinctInstance"] && [for s in aws_ecs_service.edge.ordered_placement_strategy : "${s.type}:${s.field}"] == ["spread:attribute:ecs.availability-zone"]
    error_message = "edge must spread across AZs with one task per instance"
  }

  assert {
    condition = alltrue([
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) :
      c.essential == contains(["api", "web", "proxy"], c.name)
    ])
    error_message = "only api, web and proxy are essential; postgres-ca and migrate run to completion"
  }

  assert {
    condition = alltrue([
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) :
      c.name != "api" || (c.stopTimeout >= 35 && c.dependsOn == [{ containerName = "migrate", condition = "SUCCESS" }])
    ])
    error_message = "api must wait for migrate to succeed and get at least 35 s to drain"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => {
        for s in try(c.secrets, []) : s.name => s.valueFrom
      } if c.name == "migrate"
      }["migrate"] == {
      DATABASE_URL          = var.secret_arns.database_url_bypass_rls
      POSTGRES_APP_PASSWORD = var.secret_arns.postgres_app_password
    }
    error_message = "migrate runs as the owner and receives the app role's password, both by ARN"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => {
        for s in try(c.secrets, []) : s.name => s.valueFrom
      } if c.name == "api"
      }["api"] == {
      DATABASE_URL            = var.secret_arns.database_url
      DATABASE_URL_BYPASS_RLS = var.secret_arns.database_url_bypass_rls
      REDIS_URL               = var.secret_arns.redis_url
      JWT_ACCESS_SECRET       = var.secret_arns.jwt_access_secret
      SDK_DIRECTORY_HMAC_KEY  = var.secret_arns.sdk_directory_hmac_key
      API_KEY_ENCRYPTION_KEY  = var.secret_arns.api_key_encryption_key
      INTERNAL_SERVICE_TOKEN  = var.secret_arns.internal_service_token
      MONITORING_SCRAPE_TOKEN = var.secret_arns.monitoring_scrape_token
    }
    error_message = "api secrets must be exactly the supplied ARNs"
  }

  assert {
    condition = alltrue(flatten([
      for td in [aws_ecs_task_definition.edge, aws_ecs_task_definition.worker] : [
        for c in jsondecode(td.container_definitions) : [
          for e in try(c.environment, []) : !can(regex("(SECRET|PASSWORD|PASS|TOKEN|_KEY|DATABASE_URL|REDIS_URL)", e.name))
        ]
      ]
    ]))
    error_message = "no secret-bearing variable may be passed as a plain environment value"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => {
        for e in try(c.environment, []) : e.name => e.value
      } if c.name == "api"
    }["api"]["SHEEPIT_ROLE"] == "api"
    error_message = "the edge api container runs SHEEPIT_ROLE=api"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.worker.container_definitions) : c.name => {
        for e in try(c.environment, []) : e.name => e.value
      } if c.name == "api"
    }["api"]["SHEEPIT_ROLE"] == "worker"
    error_message = "the worker container runs SHEEPIT_ROLE=worker"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => {
        for e in try(c.environment, []) : e.name => e.value
      } if c.name == "api"
    }["api"]["SHEEPIT_RUNTIME"] == "ecs"
    error_message = "api must carry SHEEPIT_RUNTIME=ecs"
  }

  assert {
    condition = !contains(flatten([
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : [for e in try(c.environment, []) : e.name]
    ]), "SHEEPIT_MAINTENANCE_ACK")
    error_message = "no maintenance ack unless one is given"
  }

  assert {
    condition     = aws_lb_target_group.dashboard.health_check[0].path == "/api/health/serving" && aws_lb_target_group.dashboard.health_check[0].port == "traffic-port" && aws_lb_target_group.dashboard.port == 8080
    error_message = "dashboard target group: proxy 8080, health /api/health/serving"
  }

  assert {
    condition     = aws_lb_target_group.sdk[0].health_check[0].path == "/_sheepit/proxy-health" && aws_lb_target_group.sdk[0].health_check[0].port == "traffic-port" && aws_lb_target_group.sdk[0].port == 8081
    error_message = "SDK target group: proxy 8081, health /_sheepit/proxy-health on 8081 itself (a public SDK load balancer must never need 8080)"
  }

  assert {
    condition     = aws_lb_target_group.dashboard.deregistration_delay >= 11
    error_message = "deregistration must outlast the 6 s drain delay plus margin"
  }

  assert {
    condition     = length(aws_iam_role.execution) == 1 && length(aws_iam_role.task) == 1 && length(aws_iam_role_policy.execution) == 1
    error_message = "roles are created when none are supplied"
  }

  # Substring, not element equality: "secret:*" or "parameter/sheepit/*" must fail too. The
  # one wildcard a non-ECR install may hold is the log-stream suffix of its own log group.
  assert {
    condition = alltrue(flatten([
      for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : [
        for r in s.Resource : !strcontains(r, "*") && !strcontains(r, "?") || (s.Sid == "WriteContainerLogs" && endswith(r, ":log-stream:*") && length(regexall("[*?]", r)) == 1)
      ]
    ]))
    error_message = "a non-ECR registry needs no wildcard grant beyond its own log streams"
  }

  assert {
    condition = jsondecode(aws_iam_role.task[0].assume_role_policy).Statement[0].Condition == {
      ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:us-east-1:111122223333:*" }
      StringEquals = { "aws:SourceAccount" = "111122223333" }
    }
    error_message = "the task role carries the task-role page's SourceArn + SourceAccount conditions"
  }

  assert {
    condition = jsondecode(aws_iam_role.execution[0].assume_role_policy).Statement[0].Condition == {
      StringEquals = { "aws:SourceAccount" = "111122223333" }
    }
    error_message = "the execution role carries SourceAccount only (no documented SourceArn for execution-role assumption)"
  }

  assert {
    condition     = aws_ecs_service.edge.health_check_grace_period_seconds == 1020
    error_message = "the default grace covers migrate (600) + api boot (300) + 120"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => [try(c.startTimeout, null), try(c.stopTimeout, null)]
      } == {
      "postgres-ca" = [60, null]
      "migrate"     = [600, 120]
      "api"         = [900, 35]
      "web"         = [900, null]
      "proxy"       = [null, 30]
    }
    error_message = "startTimeout sits on each waited-for container (migrate 600 for api; api and web 900 for proxy); proxy stops in 30 s, api in 35"
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.worker.container_definitions) : c.name => try(c.startTimeout, null)
    } == { "postgres-ca" = 60, "migrate" = 600, "api" = 900 }
    error_message = "the worker task gets the same start timeouts"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.dependsOn if c.name == "proxy"
    ][0] == [{ containerName = "api", condition = "HEALTHY" }, { containerName = "web", condition = "HEALTHY" }]
    error_message = "proxy depends on api and web, so ECS stops proxy first and api last"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : { for e in c.environment : e.name => e.value }["TRUST_PROXY_HOPS"] if c.name == "api"
    ] == ["2"]
    error_message = "an appending ALB gets two hops"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : [
        for k in ["TRUSTED_PROXIES", "SHEEPIT_SDK_FRONT", "SDK_TRUSTED_PROXIES"] : { for e in c.environment : e.name => e.value }[k]
      ] if c.name == "proxy"
    ][0] == ["10.20.30.0/27 10.20.31.0/27", "custom", "10.20.30.0/27 10.20.31.0/27"]
    error_message = "an appending ALB gets trust narrowed to trusted_proxies on both listeners"
  }

  assert {
    condition     = !aws_ecs_service.edge.wait_for_steady_state && !aws_ecs_service.worker.wait_for_steady_state
    error_message = "an ordinary apply does not block on steady state"
  }

  assert {
    condition = sort(flatten([
      for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Resource if contains(s.Action, "secretsmanager:GetSecretValue") || contains(s.Action, "ssm:GetParameters")
    ])) == sort(distinct([for k, v in var.secret_arns : v if v != null]))
    error_message = "the execution role reads exactly the listed secrets"
  }
}

run "digests_pin_images" {
  command = apply

  variables {
    image_digests = {
      api   = "sha256:1111111111111111111111111111111111111111111111111111111111111111"
      proxy = "sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => c.image
      } == {
      "postgres-ca" = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "migrate"     = "registry.example.invalid/mirror/sheepit-migrate:0.6.0"
      "api"         = "registry.example.invalid/mirror/sheepit-api@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      "web"         = "registry.example.invalid/mirror/sheepit-web-byoc:0.6.0"
      "proxy"       = "registry.example.invalid/mirror/sheepit-proxy@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    }
    error_message = "a digest replaces the tag for exactly that image"
  }
}

run "ecr_mirror_scopes_pull" {
  command = apply

  variables {
    image_registry = "111122223333.dkr.ecr.us-east-1.amazonaws.com/mirror"
  }

  assert {
    condition = sort(one([
      for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Resource if s.Sid == "EcrPullSheepitImages"
      ])) == sort([
      for r in ["sheepit-api", "sheepit-migrate", "sheepit-proxy", "sheepit-web-byoc"] :
      "arn:aws:ecr:us-east-1:111122223333:repository/mirror/${r}"
    ])
    error_message = "an ECR mirror is pulled from exactly the four Sheepit repositories"
  }

  # trivy cannot evaluate this policy (it holds values known only after apply), so the
  # no-wildcard rule is asserted here: the one "*" is GetAuthorizationToken, which IAM
  # accepts with no narrower resource.
  assert {
    condition = sort(flatten([
      for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : [for r in s.Resource : "${s.Sid}=${r}" if strcontains(r, "*") || strcontains(r, "?")]
      ])) == sort([
      "EcrAuthorizationToken=*",
      "WriteContainerLogs=arn:aws:logs:us-east-1:111122223333:log-group:/sheepit/sheepit:log-stream:*",
    ])
    error_message = "the only wildcards are ecr:GetAuthorizationToken (which accepts nothing narrower) and the module's own log streams"
  }
}

run "maintenance_release_step_one" {
  command = apply

  variables {
    maintenance_stop = true
  }

  assert {
    condition     = aws_ecs_service.edge.desired_count == 0 && aws_ecs_service.worker.desired_count == 0
    error_message = "maintenance_stop scales both services to zero"
  }

  assert {
    condition     = aws_ecs_service.edge.wait_for_steady_state && aws_ecs_service.worker.wait_for_steady_state
    error_message = "the stop apply waits until no task is running"
  }
}

run "maintenance_release_step_two" {
  command = apply

  variables {
    image_version           = "0.7.0"
    maintenance_ack_version = "0.7.0"
  }

  assert {
    condition = alltrue([
      for td in [aws_ecs_task_definition.edge, aws_ecs_task_definition.worker] :
      [for c in jsondecode(td.container_definitions) : { for e in try(c.environment, []) : e.name => e.value } if c.name == "migrate"][0]["SHEEPIT_MAINTENANCE_ACK"] == "0.7.0"
    ])
    error_message = "the migrate container carries the acknowledgement"
  }

  assert {
    condition     = aws_ecs_service.edge.desired_count == 2 && aws_ecs_service.worker.desired_count == 1
    error_message = "step two restores the services"
  }
}

run "stale_ack_is_refused" {
  command = plan

  variables {
    image_version           = "0.8.0"
    maintenance_ack_version = "0.7.0"
  }

  expect_failures = [aws_ecs_service.edge]
}

run "supplied_roles_are_not_created" {
  command = apply

  variables {
    execution_role_arn = "arn:aws:iam::111122223333:role/platform-ecs-execution"
    task_role_arn      = "arn:aws:iam::111122223333:role/platform-sheepit-task"
  }

  assert {
    condition     = length(aws_iam_role.execution) == 0 && length(aws_iam_role.task) == 0 && aws_ecs_task_definition.edge.execution_role_arn == var.execution_role_arn
    error_message = "a supplied role is used, never created"
  }
}

run "no_sdk_listener" {
  command = apply

  variables {
    sdk_listener_arn  = null
    sdk_listener_rule = null
  }

  assert {
    condition     = length(aws_lb_target_group.sdk) == 0 && length(aws_ecs_service.edge.load_balancer) == 1
    error_message = "without an SDK listener there is no SDK target group"
  }
}

run "edge_count_cannot_be_zero" {
  command = plan

  variables {
    edge_desired_count = 0
  }

  expect_failures = [var.edge_desired_count]
}

run "world_is_not_a_trusted_proxy" {
  command = plan

  variables {
    trusted_proxies = ["0.0.0.0/0"]
  }

  expect_failures = [var.trusted_proxies]
}

run "secret_must_be_an_arn" {
  command = plan

  variables {
    secret_arns = {
      database_url            = "sheepit/database-url"
      database_url_bypass_rls = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/database-url-owner-AbCdEf"
      postgres_app_password   = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/app-password-AbCdEf"
      redis_url               = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/redis-url-AbCdEf"
      jwt_access_secret       = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/jwt-AbCdEf"
      sdk_directory_hmac_key  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/sdk-hmac-AbCdEf"
      api_key_encryption_key  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/api-key-enc-AbCdEf"
      internal_service_token  = "arn:aws:secretsmanager:us-east-1:111122223333:secret:sheepit/internal-AbCdEf"
      monitoring_scrape_token = "arn:aws:ssm:us-east-1:111122223333:parameter/sheepit/monitoring-scrape-token"
    }
  }

  expect_failures = [var.secret_arns]
}

run "short_deregistration_is_refused" {
  command = plan

  variables {
    shutdown_drain_delay_ms      = 10000
    deregistration_delay_seconds = 10
  }

  expect_failures = [aws_lb_target_group.dashboard]
}

# ── X-Forwarded-For handling follows the load balancer's mode (the release bundle's README.md §3) ─

run "xff_preserve_trusts_nothing" {
  command = apply

  override_data {
    target = data.aws_lb.dashboard
    values = { load_balancer_type = "application", xff_header_processing_mode = "preserve" }
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : { for e in c.environment : e.name => e.value }["TRUST_PROXY_HOPS"] if c.name == "api"
    ] == ["1"]
    error_message = "preserve: one hop"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : { for e in c.environment : e.name => e.value }["TRUSTED_PROXIES"] if c.name == "proxy"
    ] == [""]
    error_message = "preserve: the proxy trusts no X-Forwarded-For on the dashboard listener"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : { for e in c.environment : e.name => e.value }["SHEEPIT_SDK_FRONT"] if c.name == "proxy"
    ] == ["custom"]
    error_message = "the SDK listener follows its own (appending) load balancer"
  }
}

run "xff_remove_on_both_trusts_nothing" {
  command = apply

  override_data {
    target = data.aws_lb.dashboard
    values = { load_balancer_type = "application", xff_header_processing_mode = "remove" }
  }

  override_data {
    target = data.aws_lb.sdk
    values = { load_balancer_type = "application", xff_header_processing_mode = "remove" }
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : [
        for k in ["TRUSTED_PROXIES", "SHEEPIT_SDK_FRONT", "SDK_TRUSTED_PROXIES"] : { for e in c.environment : e.name => e.value }[k]
      ] if c.name == "proxy"
    ][0] == ["", "none", ""]
    error_message = "remove on both: trust nothing on either listener"
  }

  assert {
    condition = [
      for c in jsondecode(aws_ecs_task_definition.worker.container_definitions) : { for e in c.environment : e.name => e.value }["TRUST_PROXY_HOPS"] if c.name == "api"
    ] == ["1"]
    error_message = "remove: one hop on the worker too"
  }
}

run "network_load_balancer_is_refused" {
  command = plan

  override_data {
    target = data.aws_lb.dashboard
    values = { load_balancer_type = "network", xff_header_processing_mode = null }
  }

  expect_failures = [aws_lb_listener_rule.dashboard]
}

# ── Platform preconditions the module cannot apply itself ────────────────────────────────────

run "imds_must_be_blocked" {
  command = plan

  variables {
    cluster_blocks_task_imds = false
  }

  expect_failures = [var.cluster_blocks_task_imds]
}

run "too_few_instances_for_a_rolling_upgrade" {
  command = plan

  variables {
    cluster_instance_count = 3
  }

  expect_failures = [aws_ecs_service.edge]
}

run "one_at_a_time_rollout_fits_three_instances" {
  command = plan

  variables {
    edge_deployment_maximum_percent = 150
    cluster_instance_count          = 3
  }

  assert {
    condition     = aws_ecs_service.edge.deployment_minimum_healthy_percent == 100 && aws_ecs_service.edge.deployment_maximum_percent == 150
    error_message = "edge rolls at 100/150 when asked"
  }
}

run "one_at_a_time_rollout_needs_three_instances" {
  command = plan

  variables {
    edge_deployment_maximum_percent = 150
    cluster_instance_count          = 2
  }

  expect_failures = [aws_ecs_service.edge]
}

run "maximum_that_rounds_to_desired_is_refused" {
  command = plan

  variables {
    edge_desired_count              = 1
    edge_deployment_maximum_percent = 150 # floor(1 x 1.5) = 1: no room to start a new task
  }

  expect_failures = [aws_ecs_service.edge]
}

run "maximum_at_or_below_100_is_refused" {
  command = plan

  variables {
    edge_deployment_maximum_percent = 100
  }

  expect_failures = [var.edge_deployment_maximum_percent]
}

run "update_check_and_licence_are_accepted" {
  command = plan

  variables {
    api_environment = { SHEEPIT_UPDATE_CHECK = "off", SHEEPIT_UPDATE_MANIFEST_URL = "https://updates.example.invalid/manifest.json" }
    optional_secret_arns = {
      SHEEPIT_LICENCE = "arn:aws:ssm:us-east-1:111122223333:parameter/sheepit/licence"
    }
  }

  assert {
    condition = {
      for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c.name => { for e in c.environment : e.name => e.value } if c.name == "api"
    }["api"]["SHEEPIT_UPDATE_CHECK"] == "off"
    error_message = "SHEEPIT_UPDATE_CHECK reaches the api container"
  }

  assert {
    condition = contains([
      for x in [for c in jsondecode(aws_ecs_task_definition.edge.container_definitions) : c if c.name == "api"][0].secrets : x.name
    ], "SHEEPIT_LICENCE")
    error_message = "SHEEPIT_LICENCE reaches the api container as a secret"
  }
}

run "grace_without_margin_is_refused" {
  command = plan

  variables {
    health_check_grace_period_seconds = 900 # exactly migrate + api boot: no room for proxy start and ALB checks
  }

  expect_failures = [aws_ecs_service.edge]
}

run "secret_in_another_region_is_refused" {
  command = plan

  variables {
    optional_secret_arns = {
      SMTP_PASS = "arn:aws:secretsmanager:eu-west-1:111122223333:secret:sheepit/smtp-pass-AbCdEf"
    }
  }

  expect_failures = [aws_ecs_service.edge]
}

# ── Input hardening ──────────────────────────────────────────────────────────────────────────

run "wildcard_secret_is_refused" {
  command = plan

  variables {
    optional_secret_arns = {
      SMTP_PASS = "arn:aws:secretsmanager:us-east-1:111122223333:secret:*"
    }
  }

  expect_failures = [var.optional_secret_arns]
}

run "wildcard_parameter_is_refused" {
  command = plan

  variables {
    optional_secret_arns = {
      SMTP_PASS = "arn:aws:ssm:us-east-1:111122223333:parameter/sheepit/*"
    }
  }

  expect_failures = [var.optional_secret_arns]
}

run "ca_without_end_marker_is_refused" {
  command = plan

  variables {
    db_ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nUExBQ0VIT0xERVI=\n"
  }

  expect_failures = [var.db_ca_bundle_pem]
}

run "task_role_must_be_a_role_arn" {
  command = plan

  variables {
    task_role_arn = "platform-sheepit-task"
  }

  expect_failures = [var.task_role_arn]
}

run "kms_decrypt_only_via_secret_services" {
  command = apply

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111122223333:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution[0].policy).Statement : s.Condition if s.Sid == "DecryptListedSecrets"
    ] == [{ StringEquals = { "kms:ViaService" = ["secretsmanager.us-east-1.amazonaws.com", "ssm.us-east-1.amazonaws.com"] } }]
    error_message = "kms:Decrypt is limited to Secrets Manager and Parameter Store"
  }
}
