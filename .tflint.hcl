# tflint for the Sheepit ECS module (scripts/check.sh). The terraform ruleset ships inside tflint,
# so nothing is downloaded at lint time.
config {
  call_module_type = "local"
}

plugin "terraform" {
  enabled = true
  preset  = "all"
}

# The module is split by concern (ecs.tf, tg.tf, iam.tf, logs.tf, secrets.tf, environment.tf),
# per the reference layout in the BYOC-on-AWS architecture, and has no main.tf by design.
rule "terraform_standard_module_structure" {
  enabled = false
}
