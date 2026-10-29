# Every plain environment variable the module sets, in one file. Each name must exist in the
# Compose runtime contract (compose.byoc.yml in the release bundle), the API's env schema or the
# image's own Dockerfile ENV; Sheepit's release CI enforces it. Two names are agreed interfaces
# not yet parsed by the images: SHEEPIT_RUNTIME (the update screen reads it) and
# SHEEPIT_MAINTENANCE_ACK (the migrate entrypoint's ineligible-release refusal reads it). Unknown variables are ignored by
# the API's env schema, so setting them ahead of the parser is safe.

locals {
  # Shared by the api container on the edge task and the worker. Mirrors compose.byoc.yml's
  # `api` service; values the bundle derives from .env are derived here from inputs.
  api_common_environment = merge(var.api_environment, {
    SHEEPIT_DISTRIBUTION        = "byoc"
    SHEEPIT_RUNTIME             = "ecs"
    SHEEPIT_VERSION             = var.image_version
    INGEST_ACCEPTANCE           = "postgres"
    INGEST_STREAM_MAXLEN        = "100000"
    DLQ_MAXLEN                  = "10000"
    PAYMENT_PROVIDER            = "none"
    FRONTEND_URL                = var.public_url
    OAUTH_ENDUSER_CALLBACK_BASE = "${var.public_url}/api"
    # Derived from the dashboard load balancer's X-Forwarded-For mode (tg.tf). With `append`
    # the load balancer adds the client and the in-task proxy adds the load balancer, so two
    # hops, and only together with TRUSTED_PROXIES narrowed to trusted_proxies below: section 3
    # (a1) of the release bundle's README.md, where the two settings are one decision. Any other
    # mode is section 3's "no safe configuration": one hop, trust nothing.
    TRUST_PROXY_HOPS        = local.dashboard_appends ? "2" : "1"
    SHUTDOWN_DRAIN_DELAY_MS = tostring(var.shutdown_drain_delay_ms)
  })

  api_environment_edge   = merge(local.api_common_environment, { SHEEPIT_ROLE = "api" })
  api_environment_worker = merge(local.api_common_environment, { SHEEPIT_ROLE = "worker" })

  # Containers in one awsvpc task share a network namespace, so the upstreams are loopback.
  web_environment = {
    API_BACKEND_URL = "http://127.0.0.1:3001"
    # The web image sets this too (its Dockerfile). Next.js binds to HOSTNAME, and a
    # container runtime that fills it with the container's own hostname would stop the
    # server answering on 127.0.0.1; pinning it in the task removes the dependency.
    HOSTNAME = "0.0.0.0"
  }

  proxy_environment = {
    SITE_ADDRESS        = ":8080"
    SDK_SITE_ADDRESS    = ":8081"
    API_UPSTREAM        = "127.0.0.1:3001"
    WEB_UPSTREAM        = "127.0.0.1:3000"
    TRUSTED_PROXIES     = local.dashboard_appends ? join(" ", var.trusted_proxies) : ""
    SHEEPIT_SDK_FRONT   = local.sdk_appends ? "custom" : "none"
    SDK_TRUSTED_PROXIES = local.sdk_appends ? join(" ", var.trusted_proxies) : ""
  }

  migrate_environment = merge(
    { SHEEPIT_DISTRIBUTION = "byoc" },
    var.maintenance_ack_version == null ? {} : { SHEEPIT_MAINTENANCE_ACK = var.maintenance_ack_version },
  )
}
