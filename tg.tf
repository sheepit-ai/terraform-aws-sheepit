# Target groups and listener rules. The load balancer and its listeners are the platform's; this
# module never creates either, only rules on listeners it is handed.
#
# The dashboard target group health-checks the API's routing probe through the in-task proxy:
# /api/health/serving on port 8080 (the proxy strips /api). It is 200 between the end of boot
# work and the first shutdown signal and checks no dependency, so a database blip never pulls
# every task at once. The SDK listener (8081) answers only the SDK routes and the proxy's own
# /_sheepit/proxy-health, so its target group checks that on 8081 itself: a probe on 8080 would
# force the task security group to admit a public SDK load balancer on the dashboard port. The
# proxy container starts only once api and web are HEALTHY, and on stop the task leaves the
# target groups before the proxy is signalled, so the proxy's answer covers boot and drain. An
# api that hangs later fails its container health check and ECS replaces the task, except inside
# health_check_grace_period_seconds of the task's start, when ECS ignores that check and this
# target group keeps routing to it (the dashboard target group, which probes the api, does not).

locals {
  health_check_path     = "/api/health/serving"
  sdk_health_check_path = "/_sheepit/proxy-health"
  create_sdk            = var.sdk_listener_arn != null
  drain_seconds         = ceil(var.shutdown_drain_delay_ms / 1000)
}

# How the client address reaches the proxy depends on the load balancer's
# routing.http.xff_header_processing.mode, so read it rather than assume it. Both provider
# majors export it on the aws_lb data source. The apply identity needs
# elasticloadbalancing:DescribeListeners, DescribeLoadBalancers and
# DescribeLoadBalancerAttributes; nothing is changed on the load balancer.
data "aws_lb_listener" "dashboard" {
  arn = var.dashboard_listener_arn
}

data "aws_lb" "dashboard" {
  arn = data.aws_lb_listener.dashboard.load_balancer_arn
}

data "aws_lb_listener" "sdk" {
  count = local.create_sdk ? 1 : 0

  arn = var.sdk_listener_arn
}

data "aws_lb" "sdk" {
  count = local.create_sdk ? 1 : 0

  arn = data.aws_lb_listener.sdk[0].load_balancer_arn
}

locals {
  # Section 3 of the release bundle's README.md. Only `append` (the ALB default) adds the
  # address the load balancer saw, so only then may the proxy believe X-Forwarded-For from the
  # load balancer's subnets and the API peel two hops. `preserve` forwards a header only the
  # client wrote, and `remove` strips it: in both the client address is unrecoverable, and the
  # least-bad setting is to trust nothing (every request resolves to the load balancer's
  # address, which no caller can choose).
  dashboard_xff_mode = data.aws_lb.dashboard.xff_header_processing_mode
  sdk_xff_mode       = local.create_sdk ? data.aws_lb.sdk[0].xff_header_processing_mode : local.dashboard_xff_mode
  dashboard_appends  = local.dashboard_xff_mode == "append"
  sdk_appends        = local.sdk_xff_mode == "append"
}

resource "aws_lb_target_group" "dashboard" {
  name                 = "${var.name_prefix}-dashboard"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    path                = local.health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.deregistration_delay_seconds >= local.drain_seconds + 5
      error_message = "deregistration_delay_seconds must be at least shutdown_drain_delay_ms (in seconds) plus 5."
    }
    precondition {
      condition     = var.sdk_listener_rule == null || var.sdk_listener_arn != null
      error_message = "sdk_listener_rule is set but sdk_listener_arn is null; set both or neither."
    }
  }
}

resource "aws_lb_target_group" "sdk" {
  count = local.create_sdk ? 1 : 0

  name                 = "${var.name_prefix}-sdk"
  port                 = 8081
  protocol             = "HTTP"
  target_type          = "ip"
  vpc_id               = var.vpc_id
  deregistration_delay = var.deregistration_delay_seconds

  health_check {
    enabled             = true
    path                = local.sdk_health_check_path
    port                = "traffic-port"
    protocol            = "HTTP"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_listener_rule" "dashboard" {
  listener_arn = var.dashboard_listener_arn
  priority     = var.dashboard_listener_rule.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.dashboard.arn
  }

  dynamic "condition" {
    for_each = length(var.dashboard_listener_rule.host_headers) > 0 ? [var.dashboard_listener_rule.host_headers] : []
    content {
      host_header {
        values = condition.value
      }
    }
  }

  dynamic "condition" {
    for_each = length(var.dashboard_listener_rule.path_patterns) > 0 ? [var.dashboard_listener_rule.path_patterns] : []
    content {
      path_pattern {
        values = condition.value
      }
    }
  }

  dynamic "condition" {
    for_each = var.dashboard_listener_rule.http_headers
    content {
      http_header {
        http_header_name = condition.key
        values           = condition.value
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = data.aws_lb.dashboard.load_balancer_type == "application"
      error_message = "dashboard_listener_arn must belong to an Application Load Balancer; the proxy's client-address handling assumes an L7 front."
    }
  }
}

resource "aws_lb_listener_rule" "sdk" {
  count = local.create_sdk ? 1 : 0

  listener_arn = var.sdk_listener_arn
  priority     = try(var.sdk_listener_rule.priority, null)

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.sdk[0].arn
  }

  dynamic "condition" {
    for_each = length(try(var.sdk_listener_rule.host_headers, [])) > 0 ? [var.sdk_listener_rule.host_headers] : []
    content {
      host_header {
        values = condition.value
      }
    }
  }

  dynamic "condition" {
    for_each = length(try(var.sdk_listener_rule.path_patterns, [])) > 0 ? [var.sdk_listener_rule.path_patterns] : []
    content {
      path_pattern {
        values = condition.value
      }
    }
  }

  dynamic "condition" {
    for_each = try(var.sdk_listener_rule.http_headers, {})
    content {
      http_header {
        http_header_name = condition.key
        values           = condition.value
      }
    }
  }

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.sdk_listener_rule != null
      error_message = "sdk_listener_rule is required when sdk_listener_arn is set."
    }
    precondition {
      condition     = data.aws_lb.sdk[0].load_balancer_type == "application"
      error_message = "sdk_listener_arn must belong to an Application Load Balancer; the proxy's client-address handling assumes an L7 front."
    }
  }
}
