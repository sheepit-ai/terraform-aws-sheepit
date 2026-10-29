# Sheepit on ECS-on-EC2 (T2). Provisions the application only: two ECS services, their task
# definitions, two target groups and their listener rules, a log group and (when not supplied)
# two IAM roles. Every piece of platform it runs on is an input. See README.md.
#
# The provider range spans 5.x and 6.x so a platform repository on either major can adopt the
# module without a provider upgrade. CI validates the module against both majors.
terraform {
  required_version = ">= 1.6"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 7.0"
    }
  }
}
