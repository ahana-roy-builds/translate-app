#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 5 ]]; then
  echo "usage: $0 <bootstrap|service> <backend.hcl> <variables.tfvars> <saved.tfplan> <trusted-plan-sha256>" >&2
  exit 2
fi
stack="$1"
backend_config="$2"
variables="$3"
plan="$4"
trusted_plan_sha256="$5"
provenance="$plan.provenance.json"
[[ "$stack" == "bootstrap" || "$stack" == "service" ]] || { echo "stack must be bootstrap or service" >&2; exit 2; }
[[ -f "$backend_config" && -f "$variables" && -f "$plan" && -f "$provenance" ]] || { echo "backend, variables, saved plan, and provenance are required" >&2; exit 2; }
[[ ! -L "$backend_config" && ! -L "$variables" && ! -L "$plan" && ! -L "$provenance" ]] || { echo "backend, variables, saved plan, and provenance may not be symlinks" >&2; exit 2; }
command -v terraform >/dev/null || { echo "Terraform 1.15.7 is required" >&2; exit 2; }
[[ "$trusted_plan_sha256" =~ ^[a-f0-9]{64}$ ]] || { echo "trusted-plan-sha256 must be an out-of-band lowercase SHA-256" >&2; exit 2; }
while IFS='=' read -r name _value; do
  case "$name" in
    TF_VAR_*|TF_CLI_ARGS*) echo "saved-plan apply forbids $name overrides" >&2; exit 2 ;;
    TF_WORKSPACE|TF_REATTACH_PROVIDERS|TF_CLI_CONFIG_FILE|TF_PLUGIN_CACHE_DIR|TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE|TERRAFORM_CONFIG|GOOGLE_*_CUSTOM_ENDPOINT|GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_CONFIG|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) echo "saved-plan apply forbids $name provider/workspace/repository overrides" >&2; exit 2 ;;
  esac
done < <(env)
original_backend="$(realpath "$backend_config")"
original_variables="$(realpath "$variables")"
original_plan="$(realpath "$plan")"
original_provenance="$(realpath "$provenance")"
tf_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/locallingo-terraform-apply.XXXXXXXX")"
trap 'rm -rf "$tf_data_dir"' EXIT
tf_data_dir="$(realpath "$tf_data_dir")"
export TF_DATA_DIR="$tf_data_dir"
private_cli_config="$tf_data_dir/terraform.rc"
printf 'provider_installation {\n  direct {}\n}\n' > "$private_cli_config"
export TF_CLI_CONFIG_FILE="$private_cli_config"
snapshot_root="$tf_data_dir/reviewed-inputs"
input_identity="$(/usr/bin/python3 -I "$root/scripts/snapshot-terraform-inputs.py" \
  --root "$root" --stack "$stack" --backend "$original_backend" --variables "$original_variables" \
  --destination "$snapshot_root")"
snapshot_stack="$snapshot_root/stack"
backend_config="$snapshot_root/backend.hcl"
variables="$snapshot_root/variables.tfvars"
plan="$tf_data_dir/verified.tfplan"
provenance="$tf_data_dir/verified.tfplan.provenance.json"
/usr/bin/python3 -I "$root/scripts/copy-exclusive-file.py" "$original_plan" "$plan"
/usr/bin/python3 -I "$root/scripts/copy-exclusive-file.py" "$original_provenance" "$provenance"
actual_plan_sha256="$(/usr/bin/python3 -I - "$plan" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
[[ "$actual_plan_sha256" == "$trusted_plan_sha256" ]] || { echo "saved plan does not match the out-of-band trusted digest" >&2; exit 2; }
# `terraform show -json` does not expose the planning mode. Trust only the digest
# captured from terraform-plan.sh's protected stdout; it authenticates that
# wrapper's fixed normal-plan command, not merely bytes rehashed in the artifact root.
/usr/bin/python3 -I "$root/scripts/validate-terraform-backend.py" "$backend_config" >/dev/null

/usr/bin/python3 -I - "$root" "$stack" "$backend_config" "$plan" "$provenance" "$input_identity" <<'PY'
import hashlib
import json
import subprocess
import sys
from pathlib import Path

root, stack, backend, plan, provenance = sys.argv[1:6]
input_identity = json.loads(sys.argv[6])
root_path, backend_path, plan_path, provenance_path = map(Path, (root, backend, plan, provenance))
document = json.loads(provenance_path.read_text(encoding="utf-8"))
def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()
expected = {
    "schema_version": "1.0", "stack": stack, "app_commit": input_identity["source_commit"],
    "terraform_version": "1.15.7", "backend_config_sha256": digest(backend_path),
    "variables_sha256": input_identity["variables_sha256"],
    "plan_sha256": digest(plan_path), "configuration_sha256": input_identity["configuration_sha256"],
}
for name, value in expected.items():
    if document.get(name) != value:
        raise SystemExit(f"saved plan provenance {name} does not match the apply input")
PY

terraform -chdir="$snapshot_stack" version | rg -q '^Terraform v1\.15\.7$'
terraform -chdir="$snapshot_stack" init -reconfigure -input=false -lockfile=readonly -backend-config="$backend_config"
/usr/bin/python3 -I "$root/scripts/validate-terraform-backend.py" \
  "$backend_config" --initialized-state "$TF_DATA_DIR/terraform.tfstate" >/dev/null
post_init_identity="$(/usr/bin/python3 -I "$root/scripts/terraform-input-identity.py" \
  --root "$root" --stack "$stack" --backend "$original_backend" --variables "$original_variables")"
[[ "$post_init_identity" == "$input_identity" ]] || {
  echo "Terraform configuration/backend changed during apply initialization" >&2
  exit 2
}
/usr/bin/python3 -I - "$snapshot_stack" "$plan" "$provenance" <<'PY'
import json, subprocess, sys
stack, plan, provenance = sys.argv[1:]
shown = subprocess.run(["terraform", f"-chdir={stack}", "show", "-json", plan], check=True, capture_output=True, text=True)
document = json.loads(shown.stdout)
if document.get("errored") is not False or document.get("applyable") is not True or document.get("complete") is not True:
    raise SystemExit("saved plan is not a complete applyable normal plan")
for row in document.get("resource_changes", []):
    actions = row.get("change", {}).get("actions", []) if isinstance(row, dict) else []
    if "delete" in actions:
        raise SystemExit("saved plan contains a forbidden destructive action")
PY
terraform -chdir="$snapshot_stack" apply -input=false -lock=true "$plan"
