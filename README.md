# sheepit-app — Sheepit on ECS with EC2 capacity (Terraform / OpenTofu)

Runs Sheepit as two ECS services on a cluster you already operate. It provisions the application
only. The cluster, capacity provider, VPC, subnets, security groups, load balancer and listeners,
Postgres, Redis, secrets, KMS keys, WAF, VPC endpoints and backups are yours, and enter as inputs.

Requires Terraform or OpenTofu 1.6 or newer and the `hashicorp/aws` provider 5.x or 6.x. Both
binaries and both provider majors are checked in CI (`scripts/check.sh`).

> 🔴 **Not yet proven on a real AWS account.** Every check in this directory runs against a
> mocked provider. The first apply against a real cluster is the T-C rehearsal; until it has
> passed, treat this module as a preview.

## Using this module

The module is published on its own, with no other Sheepit source, at
[`sheepit-ai/terraform-aws-sheepit`](https://github.com/sheepit-ai/terraform-aws-sheepit), tagged
`v<version>` for every Sheepit release. Pin the tag of the release you run, the same version you
pass as `image_version`. A published tag is never moved or deleted.

```hcl
module "sheepit" {
  source = "git::https://github.com/sheepit-ai/terraform-aws-sheepit.git?ref=v0.6.0"
  # inputs below
}
```

## What it creates

```
            your ALB listener (dashboard host)       your ALB listener (SDK host, optional)
                     | rule -> TG <prefix>-dashboard            | rule -> TG <prefix>-sdk
                     v   HTTP 8080, health /api/health/serving   v   HTTP 8081, health /_sheepit/proxy-health
 ┌─ service <prefix>-edge ── desired 2, rolling 100/200 (max adjustable), circuit breaker ────┐
 │  task (awsvpc, one per instance, spread across AZs)                                        │
 │    postgres-ca ─> migrate ─> api[SHEEPIT_ROLE=api] ─┐                                      │
 │                                    web ─────────────┴─> proxy :8080 / :8081                │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
 ┌─ service <prefix>-worker ── desired exactly 1, stop-then-start 0/100, circuit breaker ─────┐
 │    postgres-ca ─> migrate ─> api[SHEEPIT_ROLE=worker]                                      │
 └────────────────────────────────────────────────────────────────────────────────────────────┘
   + log group /sheepit/<prefix> (unless you pass one)
   + execution role and an empty task role (unless you pass them)
```

- **`postgres-ca`** writes `db_ca_bundle_pem` to a task-scoped volume at
  `/etc/sheepit/postgres-ca.pem` and exits, so every connection can use `sslmode=verify-full`.
- **`migrate`** applies pending schema stages and exits. It is non-essential, and `api` starts only
  when it exits 0. A failed migration stops the task, the circuit breaker counts it, and ECS rolls
  the service back to the previous task definition. Concurrent migrators (two edge tasks and the
  worker start together) serialise on the schema chain's advisory lock; the later ones find nothing
  to do.
- **`api`** gets 35 seconds between SIGTERM and SIGKILL (`api_stop_timeout_seconds`); it drains
  within 25.
- **`proxy`** is the `sheepit-proxy` image: the bundle's Caddyfile, baked in. Its upstreams are
  `127.0.0.1`, because containers in one `awsvpc` task share a network namespace. Only the proxy
  publishes ports.
- **The worker runs the schedulers.** There is no input that raises it above one task. Every
  recurring job also holds a cross-instance lock, so the brief overlap of a stop-then-start or a
  rollback is safe.

The module never creates `aws_lb`, `aws_lb_listener`, a database, a cache, a VPC or any network
resource, a WAF, a KMS key, a VPC endpoint or a backup plan, and it has no data source that reads a
secret. A test enforces each of those.

## Before you apply

1. **Images in your registry.** Mirror `sheepit-proxy`, `sheepit-web-byoc`, `sheepit-api` and
   `sheepit-migrate` at the release you run, under one prefix: `image_registry`. **Pin all four
   with `image_digests`** (the digests are in the release manifest): a tag can be moved, and these
   containers start holding every secret below. A private ECR mirror gets a pull grant scoped to
   those four repositories; any other registry gets no IAM from this module.
2. **Postgres 17** with TLS, an owner role holding `CREATEROLE` and `CREATEDB` (no superuser or
   `BYPASSRLS` needed), and the regional CA bundle for `db_ca_bundle_pem` (the regional one: the
   global bundle does not fit in a task definition).
3. **Redis** with TLS (`rediss://`), persistence, and `maxmemory-policy noeviction`. The API refuses
   to start on a BYOC install without it.
4. **Secrets**, as Secrets Manager secrets or SSM SecureString parameters, passed by full ARN.
   See [Secrets](#secrets).
5. **Security groups** on the tasks that admit each load balancer on the port its target group
   uses: the dashboard load balancer on TCP 8080, the SDK one on 8081 (each target group
   health-checks its own port, so a public SDK load balancer never needs 8080), and allow egress to Postgres, Redis, your SMTP relay and the
   registry (or the VPC endpoints that serve it).
6. **Capacity: `cluster_instance_count`.** `distinctInstance` puts each edge task on its own
   instance, and a rolling upgrade runs the new edge tasks beside the old ones (up to
   `edge_deployment_maximum_percent`, 200 by default), so the capacity provider must keep at least
   `floor(edge_desired_count × edge_deployment_maximum_percent / 100)` instances available (4 at the
   defaults; 3 with 150, which replaces one task at a time). The worker is a different task group and may share an instance. A shortfall does not
   fail the upgrade: the new tasks are never placed, the circuit breaker never sees a failure, and
   the deployment stalls. You declare the number; the plan refuses one that is too small. Each
   task also takes one ENI (`awsvpc`), so check the instance type's ENI limit or turn on ENI
   trunking.
7. **Block the instance metadata service from tasks: `cluster_blocks_task_imds`.** In `awsvpc`
   mode any container can read the instance role's credentials from the instance metadata service
   unless the ECS agent on that instance runs with `ECS_AWSVPC_BLOCK_IMDS=true` (its default is
   `false`). Add the line to `/etc/ecs/ecs.config` in your instances' launch template, restart the
   agent, then set `cluster_blocks_task_imds = true`. The module cannot reach your instances, so it
   refuses to plan until you have declared this.
8. **The load balancer's `X-Forwarded-For` mode.** The module reads
   `routing.http.xff_header_processing.mode` from the load balancer behind each listener. On
   `append` (the ALB default) the proxy believes the header only from `trusted_proxies` and the API
   peels two hops. On `preserve` or `remove` the client address cannot be recovered safely, so the
   proxy trusts nothing and every request resolves to the load balancer's own address: per-IP
   limits then apply to everyone at once (install runbook section 3). Only an Application Load
   Balancer is accepted. When the dashboard and SDK listeners sit on **different** load
   balancers, `trusted_proxies` must list both load balancers' subnets, and each listener then
   also trusts the other load balancer's addresses (one list serves both today).
9. **The apply identity** needs `ecs:RegisterTaskDefinition`, `ecs:CreateService`,
   `ecs:UpdateService`, `ecs:DescribeServices`, `elasticloadbalancing:*TargetGroup*` and
   `*Rule*` on your listeners, `elasticloadbalancing:DescribeListeners`,
   `DescribeLoadBalancers` and `DescribeLoadBalancerAttributes`, `logs:CreateLogGroup` and
   `logs:PutRetentionPolicy` (unless you pass a log group), `iam:CreateRole` / `iam:PutRolePolicy`
   (unless you pass both roles), and `iam:PassRole` on the two roles, conditioned on
   `iam:PassedToService = ecs-tasks.amazonaws.com`. A created task role trusts
   `ecs-tasks.amazonaws.com` only under `aws:SourceAccount` and `aws:SourceArn`
   (`arn:<partition>:ecs:<region>:<account>:*`), as AWS documents for task roles; a created
   execution role only under `aws:SourceAccount`, because AWS documents no `aws:SourceArn` for
   execution-role assumption. To use a stricter execution-role trust, create the role yourself and
   pass it as `execution_role_arn`. `kms:Decrypt` is allowed only via Secrets Manager and
   Parameter Store. Every secret ARN must be in the install's region (the listener's region).

## Secrets

`secret_arns` takes ARNs only; ECS resolves each at task start, and no value ever passes through
Terraform state. A Secrets Manager ARN must be the full ARN (with its random suffix) and no
JSON-key suffix; the secret holds a plain string.

| Input key                 | Variable on the container | Holds                                                  | Class |
| ------------------------- | ------------------------- | ------------------------------------------------------ | ----- |
| `database_url`            | `DATABASE_URL` (api)      | app-role connection string, see `database_url_formats` | C     |
| `database_url_bypass_rls` | `DATABASE_URL_BYPASS_RLS` | owner connection string                                | C     |
| `migrate_database_url`    | `DATABASE_URL` (migrate)  | owner connection string; defaults to the one above     | C     |
| `postgres_app_password`   | `POSTGRES_APP_PASSWORD`   | the password migrate gives `goatech_app_login`         | C     |
| `redis_url`               | `REDIS_URL`               | `rediss://…` (it can carry an AUTH token)              | B     |
| `jwt_access_secret`       | `JWT_ACCESS_SECRET`       | signing key; rotating it signs everyone out            | B     |
| `sdk_directory_hmac_key`  | `SDK_DIRECTORY_HMAC_KEY`  | **never rotate, never lose**                           | A     |
| `api_key_encryption_key`  | `API_KEY_ENCRYPTION_KEY`  | **never rotate, never lose**                           | A     |
| `internal_service_token`  | `INTERNAL_SERVICE_TOKEN`  | internal diagnostics token                             | B     |
| `monitoring_scrape_token` | `MONITORING_SCRAPE_TOKEN` | `/health/operability` and Prometheus scrape token      | B     |

- **Class A** cannot be rotated: a changed `SDK_DIRECTORY_HMAC_KEY` voids every erasure tombstone
  (the API refuses to boot on a mismatch, which presents as a crash-looping service), and losing
  `API_KEY_ENCRYPTION_KEY` loses every stored API key. Turn automatic rotation off, protect the
  secret from deletion, and keep your own copy.
- **Class B** rotates by updating the secret and forcing a new deployment.
- **Class C** rotates the same way. ECS reads secrets only at task start, so a managed rotation of a
  database password is an outage until the next deployment. Do not enable one without testing.
- `kms_key_arn`: when your secrets use a customer-managed key, the created execution role gets
  `kms:Decrypt` on it, and the key policy must allow that role too. Without both, tasks fail to
  start with an error that does not mention KMS.

`optional_secret_arns` adds `SMTP_USER`, `SMTP_PASS`, `SHEEPIT_SSO_CLIENT_SECRET`,
`SHEEPIT_SSO_REFRESH_TOKEN_KEY`, `MFA_ENCRYPTION_KEY`, `SHEEPIT_ALERT_WEBHOOK_URL` or
`SHEEPIT_LICENCE`. `api_environment` takes the non-secret optional settings the install runbook
documents (SMTP host and sender, SSO issuer and client id, retention, alert sinks, signup policy,
`SHEEPIT_UPDATE_CHECK=off` to keep the install from ever contacting the vendor); anything else is
refused at plan time.

The two connection strings must take exactly the shape output `database_url_formats` prints:
`?sslmode=verify-full&sslrootcert=/etc/sheepit/postgres-ca.pem`, with the password
percent-encoded.

## Upgrading

Every release states whether it is **zero-downtime eligible** (`upgrade-plan.json`, and the
release notes). The flow differs.

**An eligible release is one change:** bump `image_version` (and `image_digests`, if you pin) in
one pull request to your infrastructure repository. On apply, ECS starts new edge tasks beside the
old ones; each runs its migration and boots, joins the target groups once healthy, and only then
are old tasks drained and stopped. The worker stops, then starts on the new version. A failure
rolls back on its own.

**A release that is not eligible is two changes, with downtime between them:**

1. Set `maintenance_stop = true`. Both services scale to 0, and the apply waits for both to reach
   a steady state. That is not yet "no task": a task that is still deactivating or stopping no
   longer counts as running but still holds database connections. **Do not merge step two until
   both checks below come back empty for both services** (`<prefix>-edge` and `<prefix>-worker`):

   ```sh
   # No task that ECS still wants running.
   aws ecs list-tasks --cluster <cluster> --service-name <service> --desired-status RUNNING
   # No stopped-or-stopping task that has not actually reached STOPPED.
   aws ecs describe-tasks --cluster <cluster> --tasks $(aws ecs list-tasks --cluster <cluster> \
     --service-name <service> --desired-status STOPPED --query 'taskArns[]' --output text) \
     --query "tasks[?lastStatus!='STOPPED'].[taskArn,lastStatus]" --output text
   ```

   (Skip the second command when the inner `list-tasks` prints nothing; `describe-tasks` takes at
   most 100 tasks at a time.)

2. Set `image_version` to the new release, set `maintenance_ack_version` to the same value, and
   set `maintenance_stop = false`. The new tasks migrate with no old version running, then serve.

`maintenance_ack_version` reaches the migrate container as `SHEEPIT_MAINTENANCE_ACK`. It must equal
`image_version` (the plan refuses a stale one), so clear it or bump it with the next release.

> The migrate image does not yet refuse an ineligible release that arrives without the
> acknowledgement; until it does, following the two-step flow is on you.

## ECS-specific notes

- **One task per service, or more?** Many platforms run every long-lived service at one task. This
  module runs the edge service at two (`edge_desired_count`), which is what keeps the install up
  through a host loss and a rolling upgrade. One works and is supported; it gives up both.
- **WAF.** Allow, on the SDK and dashboard hostnames: `POST /v1/ingest` bodies up to **1 MiB**
  (a default 8 KB body inspection limit blocks real batches), `/v1/config`,
  `/v1/devices/register`, `/v1/devices/*/identify`, `/v1/crashes/report`,
  `/v1/performance/ingest`, `/v1/feedback/sdk` (multipart, up to **3300 KiB** with screenshots), and `/api/auth/*` on the dashboard host (sign-in posts credentials
  and tokens a managed rule set can flag).
  A WAF with the AWS-managed `SizeRestrictions_BODY` rule (8 KB) or any other body-size rule
  will block `POST /v1/feedback/sdk`, whose body reaches about 3.2 MB; give that one route an
  exception.
- **Internal load balancer by default.** People reach the dashboard over your VPN. Expose only the
  SDK hostname publicly, if your apps need it, through its own listener rule.
- **Load balancer timeouts** must be at least 120 seconds (the proxy's upstream budget).
- **X-Forwarded-For.** `trusted_proxies` must be your load balancer's subnet CIDRs and nothing
  wider. On an `append` load balancer the module sets `TRUST_PROXY_HOPS=2` (load balancer, then
  proxy); on `preserve` or `remove` it sets one hop and trusts nothing (item 8 above).
- **How a task stops.** ECS first deregisters the task from the target groups and waits for the
  load balancer to finish draining it (`deregistration_delay_seconds`). Then the containers stop
  in reverse dependency order: `proxy` depends on `api` and `web`, so `proxy` gets SIGTERM first
  and finishes its in-flight requests (30 seconds before SIGKILL), and only then do `api` and
  `web` get SIGTERM. `api` flips `/health/serving` to 503, waits `shutdown_drain_delay_ms`, and
  drains its jobs and connections within 25 seconds (`api_stop_timeout_seconds`, 35, before
  SIGKILL). The plan refuses a deregistration delay shorter than the drain delay plus 5 seconds.
- **How a task starts.** `postgres-ca`, then `migrate` (`api` waits up to
  `migrate_timeout_seconds` for it to exit 0), then `api` and `web`, then `proxy` (which waits up
  to `migrate_timeout_seconds + api_boot_timeout_seconds` for both to be healthy). In ECS a
  container's `startTimeout` bounds how long the containers depending on it wait, so the module
  sets it on `migrate`, `api` and `web`.
- **First install.** The first tasks build the schema from nothing. `migrate_timeout_seconds` and
  `health_check_grace_period_seconds` (at least `migrate_timeout_seconds + api_boot_timeout_seconds + 120`)
  are sized for that and for slow upgrades; raise them together for a large database.
- **Logs** go to one log group: `edge/<container>/<task>` and `worker/<container>/<task>`.
- **No backup sidecar.** Use your platform's database backups.
- **Nothing calls home.** No container needs outbound access to Sheepit.

## Inputs

| Name                                | Required | Default   | Description                                                            |
| ----------------------------------- | -------- | --------- | ---------------------------------------------------------------------- |
| `tags`                              | yes      |           | Tags on every resource, propagated to tasks.                           |
| `ecs_cluster`                       | yes      |           | Cluster ARN or name.                                                   |
| `capacity_provider_name`            | yes      |           | The cluster's EC2 capacity provider.                                   |
| `vpc_id`                            | yes      |           | VPC of the subnets and the load balancer.                              |
| `subnet_ids`                        | yes      |           | Private subnets for the tasks, in two or more AZs.                     |
| `security_group_ids`                | yes      |           | Task security groups.                                                  |
| `trusted_proxies`                   | yes      |           | The load balancer's subnet CIDRs.                                      |
| `dashboard_listener_arn`            | yes      |           | Listener for the dashboard hostname.                                   |
| `dashboard_listener_rule`           | yes      |           | `{ priority, host_headers, path_patterns, http_headers }`.             |
| `sdk_listener_arn`                  | no       | `null`    | Listener for the SDK hostname.                                         |
| `sdk_listener_rule`                 | no       | `null`    | Required with `sdk_listener_arn`.                                      |
| `db_host`                           | yes      |           | Postgres hostname (for `database_url_formats`).                        |
| `db_port`                           | no       | `5432`    |                                                                        |
| `db_name`                           | no       | `sheepit` |                                                                        |
| `db_ca_bundle_pem`                  | yes      |           | CA bundle for `sslmode=verify-full`.                                   |
| `secret_arns`                       | yes      |           | See [Secrets](#secrets).                                               |
| `optional_secret_arns`              | no       | `{}`      | Optional secrets by variable name.                                     |
| `api_environment`                   | no       | `{}`      | Optional documented settings.                                          |
| `kms_key_arn`                       | no       | `null`    | Key the execution role may decrypt with.                               |
| `execution_role_arn`                | no       | `null`    | Bring your own; it needs `execution_role_policy_json`.                 |
| `task_role_arn`                     | no       | `null`    | Bring your own; it needs no permissions.                               |
| `permissions_boundary_arn`          | no       | `null`    | Boundary on created roles.                                             |
| `role_name_prefix`                  | no       | `""`      | Prefix for created role names.                                         |
| `iam_role_path`                     | no       | `/`       | Path for created roles.                                                |
| `log_group_name`                    | no       | `null`    | Existing log group; otherwise `/sheepit/<prefix>` is created.          |
| `log_retention_days`                | no       | `30`      | For a created log group.                                               |
| `image_registry`                    | yes      |           | Registry host and path prefix of your mirror.                          |
| `image_version`                     | yes      |           | Release to run.                                                        |
| `image_digests`                     | no       | `{}`      | `proxy`, `web`, `api`, `migrate` → `sha256:…`.                         |
| `cpu_architecture`                  | no       | `X86_64`  | `X86_64` or `ARM64`.                                                   |
| `public_url`                        | yes      |           | `https://` dashboard origin.                                           |
| `name_prefix`                       | no       | `sheepit` | Prefix for every name.                                                 |
| `edge_desired_count`                | no       | `2`       | Edge tasks, at least 1.                                                |
| `edge_deployment_maximum_percent`   | no       | `200`     | 101–200; must leave room for one new task (ECS rounds down).           |
| `maintenance_stop`                  | no       | `false`   | Scale both services to 0 (step 1 of an ineligible release).            |
| `maintenance_ack_version`           | no       | `null`    | Step 2 of an ineligible release; must equal `image_version`.           |
| `container_sizes`                   | no       | see file  | `cpu` and `memory` per container.                                      |
| `shutdown_drain_delay_ms`           | no       | `6000`    | 0–10000.                                                               |
| `deregistration_delay_seconds`      | no       | `30`      | At least the drain delay plus 5 s.                                     |
| `api_stop_timeout_seconds`          | no       | `35`      | 35–120.                                                                |
| `migrate_timeout_seconds`           | no       | `600`     | How long `api` waits for `migrate`.                                    |
| `api_boot_timeout_seconds`          | no       | `300`     | API boot after migration; with the row above, how long `proxy` waits.  |
| `health_check_grace_period_seconds` | no       | `1020`    | At least `migrate_timeout_seconds` + `api_boot_timeout_seconds` + 120. |
| `cluster_instance_count`            | yes      |           | Instances available; at least the rollout's edge task count (4).       |
| `cluster_blocks_task_imds`          | yes      |           | Must be `true`: every agent runs with `ECS_AWSVPC_BLOCK_IMDS=true`.    |

## Outputs

| Name                                                     | Description                                           |
| -------------------------------------------------------- | ----------------------------------------------------- |
| `edge_service_name`, `worker_service_name`               | The two services.                                     |
| `edge_task_definition_arn`, `worker_task_definition_arn` | The revisions this apply registered.                  |
| `dashboard_target_group_arn`, `sdk_target_group_arn`     | The target groups (SDK is null without a listener).   |
| `log_group_name`                                         | Where every container logs.                           |
| `execution_role_arn`, `task_role_arn`                    | The roles in use.                                     |
| `execution_role_policy_json`                             | What a supplied execution role must grant.            |
| `database_url_formats`                                   | The exact shape of the two connection-string secrets. |

A complete caller is in [`examples/complete`](examples/complete/main.tf).
