#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v terraform >/dev/null; then
  echo "terraform is required" >&2
  exit 2
fi

for stack in bootstrap service; do
  lock="$root/infra/$stack/.terraform.lock.hcl"
  [[ -f "$lock" ]] || { echo "$lock is required; generate it through a reviewed provider update" >&2; exit 2; }
  rg -q 'backend "gcs"' "$root/infra/$stack/versions.tf" || { echo "$stack must declare the partial GCS backend" >&2; exit 2; }
  terraform -chdir="$root/infra/$stack" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="$root/infra/$stack" validate
done
