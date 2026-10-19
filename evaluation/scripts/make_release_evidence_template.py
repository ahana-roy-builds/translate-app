#!/usr/bin/env python3
"""Create an exhaustive, deliberately non-passing release-evidence template."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--criteria", type=Path, default=Path(__file__).resolve().parents[1] / "acceptance-criteria.json")
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def blank_evidence() -> dict[str, str]:
    return {
        "status": "missing",
        "artifact_uri": "REPLACE",
        "sha256": "",
        "reviewed_by": "REPLACE",
        "reviewed_at": "",
    }


def main() -> int:
    args = parse_args()
    criteria_bytes = args.criteria.read_bytes()
    criteria = json.loads(criteria_bytes)
    config = criteria["release_matrix"]
    matrix = []
    for direction, route, device, environment in itertools.product(
        config["directions"], config["routes"], config["device_tiers"], config["environments"]
    ):
        matrix.append({
            "direction": direction,
            "route": route,
            "device_tier": device,
            "environment": environment,
            "evidence": {name: blank_evidence() for name in config["required_evidence"]},
        })
    manifest = {
        "schema_version": "1.0",
        "criteria_sha256": hashlib.sha256(criteria_bytes).hexdigest(),
        "release": {
            "app_commit": "REPLACE",
            "app_version": "0.0.0",
            "build_number": "0",
            "release_build_id": "REPLACE",
            "xcode_version": "26.4",
            "backend_base_image": "REPLACE",
            "backend_image": "REPLACE",
            "backend_build_metadata_sha256": "",
            "terraform_plan_sha256": "",
            "testflight_terraform_plan_sha256": "",
            "terraform_backend_config_sha256": "",
            "testflight_terraform_backend_config_sha256": "",
            "terraform_variables_sha256": "",
            "testflight_terraform_variables_sha256": "",
            "terraform_plan_provenance_sha256": "",
            "testflight_terraform_plan_provenance_sha256": "",
            "ios_resolved_config_sha256": "",
            "testflight_resolved_config_sha256": "",
            "device_registry_sha256": "",
            "generated_at": "",
            "configuration": "Release",
            "local_llm_experiment": False,
        },
        "signoffs": {
            role: {"reviewer": "REPLACE", "approved_at": ""}
            for role in ("quality", "security", "privacy", "operations")
        },
        "global_evidence": {name: blank_evidence() for name in config["global_evidence"]},
        "matrix": matrix,
    }
    with args.output.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    print(f"Wrote non-passing template to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
