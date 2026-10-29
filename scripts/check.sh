#!/bin/sh
# The whole gate for the Sheepit ECS module, local and CI alike (the "BYOC Terraform module" lane
# and the public-module publish lane run exactly this file). Every tool runs from a container
# image pinned by digest, so nothing is installed on the host:
#
#   1. fmt -check                          OpenTofu and Terraform
#   2. init -backend=false + validate      module and example, OpenTofu and Terraform
#   3. test (mocked AWS provider)          OpenTofu and Terraform, on AWS provider 6.x
#   4. validate + test on AWS provider 5.x OpenTofu (the module's range spans both majors)
#   5. tflint                              module and example
#   6. trivy config, HIGH and CRITICAL     the example (which evaluates the module with an ECR
#                                          mirror); justified exceptions in ../.trivyignore.yaml
#
# Needs: docker, and network on the first run (provider downloads, cached afterwards under
# $SHEEPIT_TF_CACHE, default ~/.cache/sheepit-terraform). The Docker daemon may be shared with
# other work: every container is --rm with a unique name, and nothing is pruned.
#
# It runs in either of the two layouts this module exists in, picked by what is on disk:
#   monorepo  the module in modules/sheepit-app, tests in tests/
#   public    the published repository root: the module at the root, tests in tests/
#
# Usage: scripts/check.sh (from either root)
set -eu

TOFU_IMAGE="ghcr.io/opentofu/opentofu:1.13.1@sha256:1df996fca13806a20d5a3d3ad54acdcf76bcb1aa4ac30b5ba169b9e4cecdbcc8"
TERRAFORM_IMAGE="hashicorp/terraform:1.16.5@sha256:c7926feace05d0f7e73542842bf3945924e955a1f782cf000ccbb8d18fa42d77"
TFLINT_IMAGE="ghcr.io/terraform-linters/tflint:v0.64.0@sha256:1c595f42d794c32c45a6ea8b58655fd66433d4ca3b1bc631c574a48d120bd19f"
TRIVY_IMAGE="aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa"

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
if [ -d "$root/modules/sheepit-app" ]; then
	module=modules/sheepit-app
elif [ -f "$root/versions.tf" ] && [ -f "$root/variables.tf" ]; then
	module=.
else
	echo "check.sh: $root holds neither modules/sheepit-app nor a module at its root" >&2
	exit 1
fi
cache=${SHEEPIT_TF_CACHE:-$HOME/.cache/sheepit-terraform}
mkdir -p "$cache/tofu" "$cache/terraform"

# Two checks sharing the provider cache could interleave a download; serialise on a lock
# directory, and take over one left by a run that died more than 30 minutes ago.
lock="$cache/.lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
	if [ -n "$(find "$lock" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
		echo "check.sh: removing a stale cache lock" >&2
		rmdir "$lock" 2>/dev/null || true
		continue
	fi
	if [ "$waited" -ge 900 ]; then
		echo "check.sh: gave up waiting 15 min for $lock" >&2
		exit 1
	fi
	sleep 5
	waited=$((waited + 5))
done

work=$(mktemp -d "${TMPDIR:-/tmp}/sheepit-tfcheck.XXXXXX")
cleanup() {
	rm -rf "$work"
	rmdir "$lock" 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM

uid_gid="$(id -u):$(id -g)"
tag="sheepit-tfcheck-$$"

# Each tool gets its own copy of the tree: OpenTofu and Terraform write different provider
# addresses into the lock file and must not share a .terraform directory. In the monorepo the
# tests live in ../tests so the module directory holds no test fixtures (and the literal-ID gate
# over modules/ stays strict); Terraform only runs tests from inside the module, so the copy puts
# them there. In the public layout the module root already holds tests/.
copy() {
	mkdir -p "$work/$1"
	(cd "$root" && tar cf - --exclude .git --exclude .terraform --exclude .terraform.lock.hcl .) | (cd "$work/$1" && tar xf -)
	if [ "$module" != "." ]; then
		cp -R "$work/$1/tests" "$work/$1/$module/tests"
	fi
}

# run <label> <image> <workdir under /src> <args...>
run() {
	label=$1 image=$2 dir=$3
	shift 3
	docker run --rm --name "$tag-$label" --user "$uid_gid" \
		-e HOME=/tmp -e TF_IN_AUTOMATION=1 -e TF_INPUT=0 \
		-e TF_PLUGIN_CACHE_DIR=/cache \
		-v "$work/$label:/src" -v "$cache/$cache_sub:/cache" \
		-w "/src/$dir" "$image" "$@"
}

step() { printf '\n== %s\n' "$*"; }

cli() { # cli <label> <image> <cache subdir>
	label=$1 image=$2 cache_sub=$3
	copy "$label"
	step "$label: fmt"
	run "$label" "$image" . fmt -check -recursive -diff
	for dir in "$module" examples/complete; do
		step "$label: init + validate $dir"
		run "$label" "$image" "$dir" init -backend=false -input=false -no-color >/dev/null
		run "$label" "$image" "$dir" validate -no-color
	done
	step "$label: test (mocked provider)"
	run "$label" "$image" "$module" test -no-color
}

cli tofu "$TOFU_IMAGE" tofu
cli terraform "$TERRAFORM_IMAGE" terraform

# The module accepts AWS provider 5.x too. Re-run validate and the tests against it.
copy tofu-aws5
cat >"$work/tofu-aws5/$module/aws5_override.tf" <<'EOF'
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
EOF
cache_sub=tofu
step "tofu-aws5: init + validate + test on AWS provider 5.x"
run tofu-aws5 "$TOFU_IMAGE" "$module" init -backend=false -input=false -no-color >/dev/null
run tofu-aws5 "$TOFU_IMAGE" "$module" validate -no-color
run tofu-aws5 "$TOFU_IMAGE" "$module" test -no-color

copy lint
step "tflint"
docker run --rm --name "$tag-tflint" --user "$uid_gid" -e HOME=/tmp \
	-v "$work/lint:/src" -w /src "$TFLINT_IMAGE" \
	--recursive --config=/src/.tflint.hcl --format=compact

step "trivy config (HIGH, CRITICAL)"
docker run --rm --name "$tag-trivy" --user "$uid_gid" -e HOME=/tmp \
	-v "$work/lint:/src:ro" "$TRIVY_IMAGE" \
	config --cache-dir /tmp/trivy --skip-check-update --quiet \
	--severity HIGH,CRITICAL --exit-code 1 \
	--ignorefile /src/.trivyignore.yaml \
	--tf-vars /src/examples/complete/example.tfvars /src/examples/complete

printf '\ncheck.sh: all checks passed\n'
