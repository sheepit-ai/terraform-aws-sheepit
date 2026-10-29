# Two services, two task definitions.
#
#   <prefix>-edge    desired edge_desired_count (2), rolling 100/edge_deployment_maximum_percent (200),
#                    circuit breaker with rollback,
#                    spread across AZs, one task per instance.
#                    task = postgres-ca -> migrate -> api -> (web) -> proxy
#   <prefix>-worker  desired exactly 1 (no input raises it), stop-then-start 0/100.
#                    task = postgres-ca -> migrate -> api[SHEEPIT_ROLE=worker]
#
# `migrate` is the first application container of every new task. It is non-essential and the
# api container starts only when it exits 0, so a failed migration stops the task, the
# deployment circuit breaker counts it, and ECS rolls the service back to the previous task
# definition. Concurrent migrators (two edge tasks and the worker starting together) serialise
# on the schema chain's own advisory lock; the later ones find nothing pending.
#
# Start and stop timing, per the ECS ContainerDefinition reference:
#   - `startTimeout` is set on the container being WAITED FOR, and bounds how long the
#     containers that depend on it wait for it to reach the required state. So migrate's
#     startTimeout (migrate_timeout_seconds) is what api waits for SUCCESS, and api's and web's
#     (migrate + api boot) are what proxy waits for HEALTHY. proxy has no dependents, so a
#     startTimeout on it would bound nothing. The agent's ECS_CONTAINER_START_TIMEOUT (3 min
#     by default) is separate: it bounds starting a container, not waiting on a dependency.
#   - "When a dependency is defined for container startup, for container shutdown it is
#     reversed": proxy depends on api and web, so on stop ECS signals proxy first, and api and
#     web only once proxy has exited. The whole stop sequence is: the load balancer
#     deregisters the task and drains it for deregistration_delay_seconds (ECS waits for the
#     target to reach `unused` before stopping the task), then proxy gets SIGTERM and finishes
#     its in-flight requests (up to proxy_stop_timeout), then api gets SIGTERM, flips
#     /health/serving to 503, waits shutdown_drain_delay_ms and drains within 25 s
#     (api_stop_timeout_seconds before SIGKILL).
#
# `postgres-ca` writes db_ca_bundle_pem to a task-scoped volume so the connection strings can
# say sslmode=verify-full&sslrootcert=/etc/sheepit/postgres-ca.pem, the same contract as
# compose.managed.yml. It runs the migrate image's shell and exits.

locals {
  edge_max_tasks = floor(var.edge_desired_count * var.edge_deployment_maximum_percent / 100)

  images = {
    for k, repo in local.repositories :
    k => lookup(var.image_digests, k, null) == null ? "${var.image_registry}/${repo}:${var.image_version}" : "${var.image_registry}/${repo}@${var.image_digests[k]}"
  }

  app_start_timeout  = var.migrate_timeout_seconds + var.api_boot_timeout_seconds
  proxy_stop_timeout = 30

  ca_volume   = "postgres-ca"
  ca_dir      = "/etc/sheepit"
  ca_file     = "/etc/sheepit/postgres-ca.pem"
  instance_os = lower(var.cpu_architecture) # the ecs.cpu-architecture attribute: x86_64 or arm64

  log_options = {
    for svc in ["edge", "worker"] : svc => {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = local.log_group_name
        "awslogs-region"        = local.log_region
        "awslogs-stream-prefix" = svc
      }
    }
  }

  ca_mount_rw = [{ sourceVolume = local.ca_volume, containerPath = local.ca_dir, readOnly = false }]
  ca_mount_ro = [{ sourceVolume = local.ca_volume, containerPath = local.ca_dir, readOnly = true }]

  to_env = {
    api_edge   = [for k in sort(keys(local.api_environment_edge)) : { name = k, value = local.api_environment_edge[k] }]
    api_worker = [for k in sort(keys(local.api_environment_worker)) : { name = k, value = local.api_environment_worker[k] }]
    web        = [for k in sort(keys(local.web_environment)) : { name = k, value = local.web_environment[k] }]
    proxy      = [for k in sort(keys(local.proxy_environment)) : { name = k, value = local.proxy_environment[k] }]
    migrate    = [for k in sort(keys(local.migrate_environment)) : { name = k, value = local.migrate_environment[k] }]
  }

  # The two containers every task starts with. `svc` picks the log stream prefix.
  schema_containers = {
    for svc in ["edge", "worker"] : svc => [
      {
        name             = "postgres-ca"
        image            = local.images.migrate
        essential        = false
        cpu              = 0
        memory           = 64
        startTimeout     = 60
        entryPoint       = ["/bin/sh", "-c"]
        command          = ["umask 022 && printf '%s\\n' '${trimspace(var.db_ca_bundle_pem)}' > ${local.ca_file}"]
        mountPoints      = local.ca_mount_rw
        logConfiguration = local.log_options[svc]
      },
      {
        name         = "migrate"
        image        = local.images.migrate
        essential    = false
        cpu          = var.container_sizes.migrate.cpu
        memory       = var.container_sizes.migrate.memory
        environment  = local.to_env.migrate
        secrets      = local.migrate_secrets
        mountPoints  = local.ca_mount_ro
        startTimeout = var.migrate_timeout_seconds
        dependsOn    = [{ containerName = "postgres-ca", condition = "SUCCESS" }]
        # Let a running migration finish its current statement rather than being killed
        # mid-stage when a rollout is cancelled.
        stopTimeout      = 120
        logConfiguration = local.log_options[svc]
      },
    ]
  }

  api_health_check = {
    command     = ["CMD-SHELL", "wget --quiet --tries=1 --spider http://127.0.0.1:3001/health/serving || exit 1"]
    interval    = 10
    timeout     = 5
    retries     = 3
    startPeriod = 120
  }

  edge_containers = concat(local.schema_containers.edge, [
    {
      name             = "api"
      image            = local.images.api
      essential        = true
      cpu              = var.container_sizes.api.cpu
      memory           = var.container_sizes.api.memory
      environment      = local.to_env.api_edge
      secrets          = local.api_secrets
      mountPoints      = local.ca_mount_ro
      startTimeout     = local.app_start_timeout
      stopTimeout      = var.api_stop_timeout_seconds
      dependsOn        = [{ containerName = "migrate", condition = "SUCCESS" }]
      healthCheck      = local.api_health_check
      logConfiguration = local.log_options.edge
    },
    {
      name         = "web"
      image        = local.images.web
      essential    = true
      cpu          = var.container_sizes.web.cpu
      memory       = var.container_sizes.web.memory
      environment  = local.to_env.web
      startTimeout = local.app_start_timeout
      healthCheck = {
        command     = ["CMD-SHELL", "wget --quiet --tries=1 --spider http://127.0.0.1:3000/ || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }
      logConfiguration = local.log_options.edge
    },
    {
      name        = "proxy"
      image       = local.images.proxy
      essential   = true
      cpu         = var.container_sizes.proxy.cpu
      memory      = var.container_sizes.proxy.memory
      environment = local.to_env.proxy
      stopTimeout = local.proxy_stop_timeout
      portMappings = [
        { containerPort = 8080, protocol = "tcp" },
        { containerPort = 8081, protocol = "tcp" },
      ]
      dependsOn = [
        { containerName = "api", condition = "HEALTHY" },
        { containerName = "web", condition = "HEALTHY" },
      ]
      healthCheck = {
        command     = ["CMD-SHELL", "wget --quiet --tries=1 --spider http://127.0.0.1:8080/_sheepit/proxy-health || exit 1"]
        interval    = 15
        timeout     = 5
        retries     = 3
        startPeriod = 15
      }
      logConfiguration = local.log_options.edge
    },
  ])

  worker_containers = concat(local.schema_containers.worker, [
    {
      name             = "api"
      image            = local.images.api
      essential        = true
      cpu              = var.container_sizes.worker.cpu
      memory           = var.container_sizes.worker.memory
      environment      = local.to_env.api_worker
      secrets          = local.api_secrets
      mountPoints      = local.ca_mount_ro
      startTimeout     = local.app_start_timeout
      stopTimeout      = var.api_stop_timeout_seconds
      dependsOn        = [{ containerName = "migrate", condition = "SUCCESS" }]
      healthCheck      = local.api_health_check
      logConfiguration = local.log_options.worker
    },
  ])
}

resource "aws_ecs_task_definition" "edge" {
  family                   = "${var.name_prefix}-edge"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn
  container_definitions    = jsonencode(local.edge_containers)

  volume {
    name = local.ca_volume
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.cpu-architecture == ${local.instance_os}"
  }

  tags = var.tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.name_prefix}-worker"
  network_mode             = "awsvpc"
  requires_compatibilities = ["EC2"]
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn
  container_definitions    = jsonencode(local.worker_containers)

  volume {
    name = local.ca_volume
  }

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:ecs.cpu-architecture == ${local.instance_os}"
  }

  tags = var.tags
}

resource "aws_ecs_service" "edge" {
  name            = "${var.name_prefix}-edge"
  cluster         = var.ecs_cluster
  task_definition = aws_ecs_task_definition.edge.arn
  desired_count   = var.maintenance_stop ? 0 : var.edge_desired_count

  # Step one of a maintenance release only succeeds once every task has actually stopped, so
  # "0 running" is a fact before anyone merges step two.
  wait_for_steady_state = var.maintenance_stop

  # Rolling: start the new tasks before stopping the old, never dropping below desired. ECS
  # rounds the maximum down, so local.edge_max_tasks is how many edge tasks a rollout may run.
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = var.edge_deployment_maximum_percent

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  health_check_grace_period_seconds = var.health_check_grace_period_seconds

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  ordered_placement_strategy {
    type  = "spread"
    field = "attribute:ecs.availability-zone"
  }

  placement_constraints {
    type = "distinctInstance"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.dashboard.arn
    container_name   = "proxy"
    container_port   = 8080
  }

  dynamic "load_balancer" {
    for_each = local.create_sdk ? [aws_lb_target_group.sdk[0].arn] : []
    content {
      target_group_arn = load_balancer.value
      container_name   = "proxy"
      container_port   = 8081
    }
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
  tags                    = var.tags

  # A target group must be attached to a load balancer before a service can register into it.
  depends_on = [aws_lb_listener_rule.dashboard, aws_lb_listener_rule.sdk]

  lifecycle {
    precondition {
      condition     = var.health_check_grace_period_seconds >= local.app_start_timeout + 120
      error_message = "health_check_grace_period_seconds must be at least migrate_timeout_seconds + api_boot_timeout_seconds + 120 (proxy start and two healthy load balancer checks), or ECS can stop a new task in the middle of its migration."
    }
    precondition {
      # Repeated from the variable's validation so the refusal also names the resource it guards.
      condition     = var.cluster_blocks_task_imds
      error_message = "The tasks would be able to read the instance role's credentials: set ECS_AWSVPC_BLOCK_IMDS=true on every container instance, then cluster_blocks_task_imds = true."
    }
    precondition {
      condition     = alltrue([for a in local.all_secret_arns : split(":", a)[3] == local.region])
      error_message = "Every secret and parameter ARN must be in the install's region (the region of dashboard_listener_arn); ECS resolves them from the task's region."
    }
    precondition {
      condition     = local.edge_max_tasks > var.edge_desired_count
      error_message = "edge_deployment_maximum_percent leaves no room for a new task: ECS rounds edge_desired_count x edge_deployment_maximum_percent / 100 down, and with the minimum at 100 a rollout must start a task before it stops one. Raise the percentage (200 always works)."
    }
    precondition {
      condition     = var.cluster_instance_count >= local.edge_max_tasks
      error_message = "cluster_instance_count must be at least floor(edge_desired_count x edge_deployment_maximum_percent / 100) (4 at the defaults): each edge task needs its own instance (distinctInstance) and a rolling upgrade runs old and new side by side. A placement shortfall stalls the deployment without tripping the circuit breaker."
    }
    precondition {
      condition     = var.maintenance_ack_version == null || var.maintenance_ack_version == var.image_version
      error_message = "maintenance_ack_version acknowledges one release: it must equal image_version, or be null."
    }
  }
}

resource "aws_ecs_service" "worker" {
  name            = "${var.name_prefix}-worker"
  cluster         = var.ecs_cluster
  task_definition = aws_ecs_task_definition.worker.arn

  # Exactly one scheduler process in steady state, by construction: there is no input that
  # raises this. Stop the old task before starting the new one.
  desired_count                      = var.maintenance_stop ? 0 : 1
  wait_for_steady_state              = var.maintenance_stop
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  deployment_controller {
    type = "ECS"
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  capacity_provider_strategy {
    capacity_provider = var.capacity_provider_name
    weight            = 1
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  propagate_tags          = "SERVICE"
  enable_ecs_managed_tags = true
  tags                    = var.tags
}
