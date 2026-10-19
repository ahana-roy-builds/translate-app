#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <bootstrap|service> <backend.hcl> <variables.tfvars> <output.tfplan>" >&2
  exit 2
fi

stack="$1"
backend_config="$2"
variables="$3"
output="$4"

[[ "$stack" == "bootstrap" || "$stack" == "service" ]] || { echo "stack must be bootstrap or service" >&2; exit 2; }
[[ -f "$backend_config" && ! -L "$backend_config" ]] || { echo "backend config must be a non-symlink file" >&2; exit 2; }
[[ -f "$variables" && ! -L "$variables" ]] || { echo "variable file must be a non-symlink file" >&2; exit 2; }
[[ -f "$root/infra/$stack/.terraform.lock.hcl" ]] || { echo "reviewed provider lock is missing" >&2; exit 2; }
[[ "$output" = /* ]] || { echo "output.tfplan must be an absolute path in the private artifact root" >&2; exit 2; }
[[ ! -e "$output" && ! -L "$output" && ! -e "$output.provenance.json" && ! -L "$output.provenance.json" ]] || { echo "plan/provenance output already exists and will not be replaced" >&2; exit 2; }
command -v terraform >/dev/null || { echo "Terraform 1.15.7 is required" >&2; exit 2; }
while IFS='=' read -r name _value; do
  case "$name" in
    TF_VAR_*|TF_CLI_ARGS*) echo "release planning forbids $name overrides" >&2; exit 2 ;;
    TF_WORKSPACE|TF_REATTACH_PROVIDERS|TF_CLI_CONFIG_FILE|TF_PLUGIN_CACHE_DIR|TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE|TERRAFORM_CONFIG|GOOGLE_*_CUSTOM_ENDPOINT|GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_CONFIG|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_*|GIT_CONFIG_VALUE_*) echo "release planning forbids $name provider/workspace/repository overrides" >&2; exit 2 ;;
  esac
done < <(env)

original_backend_config="$(realpath "$backend_config")"
original_variables="$(realpath "$variables")"
/usr/bin/python3 -I "$root/scripts/validate-terraform-backend.py" "$original_backend_config" >/dev/null
tf_data_dir="$(mktemp -d "${TMPDIR:-/tmp}/locallingo-terraform-plan.XXXXXXXX")"
cleanup() {
  rm -rf "$tf_data_dir"
}
trap cleanup EXIT
tf_data_dir="$(realpath "$tf_data_dir")"
private_plan="$tf_data_dir/reviewed.tfplan"
private_provenance="$private_plan.provenance.json"
private_cli_config="$tf_data_dir/terraform.rc"
printf 'provider_installation {\n  direct {}\n}\n' > "$private_cli_config"
export TF_CLI_CONFIG_FILE="$private_cli_config"
export TF_DATA_DIR="$tf_data_dir"
snapshot_root="$tf_data_dir/reviewed-inputs"
input_identity="$(/usr/bin/python3 -I "$root/scripts/snapshot-terraform-inputs.py" \
  --root "$root" --stack "$stack" --backend "$original_backend_config" --variables "$original_variables" \
  --destination "$snapshot_root")"
snapshot_stack="$snapshot_root/stack"
backend_config="$snapshot_root/backend.hcl"
variables="$snapshot_root/variables.tfvars"

terraform -chdir="$snapshot_stack" version | rg -q '^Terraform v1\.15\.7$' || {
  echo "Terraform 1.15.7 is required by the reviewed lock" >&2
  exit 2
}
terraform -chdir="$snapshot_stack" init \
  -reconfigure \
  -input=false \
  -lockfile=readonly \
  -backend-config="$backend_config"

/usr/bin/python3 -I "$root/scripts/validate-terraform-backend.py" \
  "$backend_config" --initialized-state "$TF_DATA_DIR/terraform.tfstate" >/dev/null

terraform -chdir="$snapshot_stack" plan \
  -input=false \
  -lock=true \
  -var-file="$variables" \
  -out="$private_plan"

post_plan_identity="$(/usr/bin/python3 -I "$root/scripts/terraform-input-identity.py" \
  --root "$root" --stack "$stack" --backend "$original_backend_config" --variables "$original_variables")"
if [[ "$post_plan_identity" != "$input_identity" ]]; then
  echo "Terraform inputs changed during init/plan; discarded the untrusted saved plan" >&2
  exit 2
fi

/usr/bin/python3 -I - "$root" "$stack" "$backend_config" "$variables" "$private_plan" "$input_identity" "$snapshot_stack" <<'PY'
import hashlib
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

root, stack, backend, variables, plan = map(Path, sys.argv[1:6])
input_identity = json.loads(sys.argv[6])
stack_root = Path(sys.argv[7])

def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()

shown = subprocess.run(
    ["terraform", f"-chdir={stack_root}", "show", "-json", str(plan)],
    check=True, capture_output=True, text=True,
)
document = json.loads(shown.stdout)

def resources(module):
    rows = list(module.get("resources", []))
    for child in module.get("child_modules", []):
        rows.extend(resources(child))
    return rows

cloud_run = next(
    (row["values"] for row in resources(document["planned_values"]["root_module"])
     if row.get("type") == "google_cloud_run_v2_service" and row.get("name") == "api"),
    None,
)
project_id = None
environment = None
if cloud_run:
    project_id = cloud_run.get("project")
    rows = cloud_run["template"][0]["containers"][0].get("env", [])
    environment = next((row.get("value") for row in rows if row.get("name") == "RUNTIME_MODE"), None)

provenance = {
    "schema_version": "1.0",
    "stack": str(stack),
    "app_commit": input_identity["source_commit"],
    "terraform_version": "1.15.7",
    "configuration_sha256": input_identity["configuration_sha256"],
    "backend_config_sha256": input_identity["backend_config_sha256"],
    "variables_sha256": input_identity["variables_sha256"],
    "plan_sha256": digest(plan.resolve()),
    "project_id": project_id,
    "environment": environment,
    "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
provenance_path = Path(str(plan) + ".provenance.json")
with provenance_path.open("x", encoding="utf-8") as handle:
    handle.write(json.dumps(provenance, indent=2, sort_keys=True) + "\n")
print(f"Wrote plan provenance to {provenance_path}")
PY

trusted_plan_sha256="$(/usr/bin/python3 -I - "$private_plan" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)"
echo "Trusted plan SHA-256 (record out of band): $trusted_plan_sha256"

/usr/bin/python3 -I "$root/scripts/copy-exclusive-file.py" "$private_plan" "$output"
/usr/bin/python3 -I "$root/scripts/copy-exclusive-file.py" "$private_provenance" "$output.provenance.json"

echo "Wrote reviewed-input $stack plan to $output"
