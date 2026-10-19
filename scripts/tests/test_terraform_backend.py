from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "validate_terraform_backend", ROOT / "scripts" / "validate-terraform-backend.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
IDENTITY_SPEC = importlib.util.spec_from_file_location(
    "terraform_input_identity", ROOT / "scripts" / "terraform-input-identity.py"
)
assert IDENTITY_SPEC and IDENTITY_SPEC.loader
IDENTITY = importlib.util.module_from_spec(IDENTITY_SPEC)
IDENTITY_SPEC.loader.exec_module(IDENTITY)
COPY_SPEC = importlib.util.spec_from_file_location(
    "copy_exclusive_file", ROOT / "scripts" / "copy-exclusive-file.py"
)
assert COPY_SPEC and COPY_SPEC.loader
COPY = importlib.util.module_from_spec(COPY_SPEC)
COPY_SPEC.loader.exec_module(COPY)


class TerraformBackendTests(unittest.TestCase):
    def test_initialized_backend_must_match_both_literals(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            config = root / "backend.hcl"
            state = root / "terraform.tfstate"
            config.write_text('bucket = "prod-state"\nprefix = "service"\n', encoding="utf-8")
            expected = MODULE.parse_backend(config)
            state.write_text(json.dumps({"backend": {"type": "gcs", "config": expected}}), encoding="utf-8")
            MODULE.verify_initialized(state, expected)
            state.write_text(json.dumps({"backend": {"type": "gcs", "config": {"bucket": "test-state", "prefix": "service"}}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "backend mismatch"):
                MODULE.verify_initialized(state, expected)
            state.write_text(json.dumps({"backend": {"type": "gcs", "config": {
                **expected, "storage_custom_endpoint": "https://attacker.invalid",
            }}}), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "custom storage endpoint"):
                MODULE.verify_initialized(state, expected)

    def test_plan_and_apply_use_distinct_private_data_directories(self) -> None:
        plan = (ROOT / "scripts" / "terraform-plan.sh").read_text(encoding="utf-8")
        apply = (ROOT / "scripts" / "terraform-apply.sh").read_text(encoding="utf-8")
        self.assertIn("locallingo-terraform-plan", plan)
        self.assertIn("locallingo-terraform-apply", apply)
        self.assertIn('tf_data_dir="$(realpath "$tf_data_dir")"', plan)
        self.assertIn('tf_data_dir="$(realpath "$tf_data_dir")"', apply)
        self.assertIn('export TF_DATA_DIR="$tf_data_dir"', plan)
        self.assertIn('export TF_DATA_DIR="$tf_data_dir"', apply)
        self.assertNotIn('infra/$stack/.terraform/terraform.tfstate', plan)
        self.assertIn("post_plan_identity", plan)
        self.assertIn("post_init_identity", apply)
        self.assertIn('plan="$tf_data_dir/verified.tfplan"', apply)
        self.assertIn('-out="$private_plan"', plan)
        self.assertIn("snapshot-terraform-inputs.py", plan)
        self.assertIn("snapshot-terraform-inputs.py", apply)
        self.assertIn('variables="$snapshot_root/variables.tfvars"', apply)
        self.assertIn("out-of-band trusted digest", apply)
        for wrapper in (plan, apply):
            self.assertIn("TF_REATTACH_PROVIDERS", wrapper)
            self.assertIn('export TF_CLI_CONFIG_FILE="$private_cli_config"', wrapper)
            self.assertIn("provider_installation", wrapper)
            self.assertIn("direct {}", wrapper)
            self.assertIn("GOOGLE_*_CUSTOM_ENDPOINT", wrapper)
            self.assertIn("TF_PLUGIN_CACHE_MAY_BREAK_DEPENDENCY_LOCK_FILE", wrapper)
            self.assertIn("GIT_INDEX_FILE", wrapper)
            self.assertNotIn("|GIT_*)", wrapper)

    def test_ignored_override_and_auto_tfvars_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stack = root / "infra" / "service"
            stack.mkdir(parents=True)
            (stack / "main.tf").write_text('terraform {}\n', encoding="utf-8")
            (stack / ".terraform.lock.hcl").write_text("# lock\n", encoding="utf-8")
            backend = root / "backend.hcl"
            backend.write_text('bucket = "prod-state"\nprefix = "service"\n', encoding="utf-8")
            (root / ".gitignore").write_text("override.tf\n*.auto.tfvars\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Unit Test"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)
            with mock.patch.dict("os.environ", {"GIT_DIR": str(root / "attacker.git")}):
                identity = IDENTITY.capture(root, "service", backend, None)
            self.assertRegex(identity["source_commit"], r"^[0-9a-f]{40}$")
            (stack / "override.tf").write_text('resource "null_resource" "attack" {}\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "tracked"):
                IDENTITY.capture(root, "service", backend, None)
            (stack / "override.tf").unlink()
            (stack / "attack.auto.tfvars").write_text('project_id = "attacker"\n', encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "auto-loaded tfvars"):
                IDENTITY.capture(root, "service", backend, None)

    def test_exclusive_snapshot_rejects_symlink_and_survives_source_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            # macOS spells its trusted temporary root through /var, which is a
            # symlink to /private/var. Mirror the wrappers' canonicalization.
            root = Path(temporary).resolve()
            source = root / "plan.tfplan"
            source.write_bytes(b"reviewed-plan")
            snapshot = root / "snapshot.tfplan"
            COPY.copy_exclusive(source, snapshot)
            source.write_bytes(b"replacement")
            self.assertEqual(snapshot.read_bytes(), b"reviewed-plan")
            link = root / "link.tfplan"
            link.symlink_to(source)
            with self.assertRaises(OSError):
                COPY.copy_exclusive(link, root / "rejected.tfplan")

    def test_exclusive_snapshot_does_not_follow_destination_parent_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "source.tfplan"
            source.write_bytes(b"reviewed-plan")
            outside = root / "outside"
            outside.mkdir()
            redirect = root / "redirect"
            redirect.symlink_to(outside, target_is_directory=True)
            with self.assertRaises(OSError):
                COPY.copy_exclusive(source, redirect / "published.tfplan")
            self.assertFalse((outside / "published.tfplan").exists())


if __name__ == "__main__":
    unittest.main()
