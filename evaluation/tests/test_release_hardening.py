from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_release_hardening", ROOT / "scripts" / "validate_release_evidence.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class LiveInputTests(unittest.TestCase):
    def test_untracked_swift_source_blocks_release_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            required = [
                "Makefile", "backend/Dockerfile", "backend/package.json", "backend/package-lock.json",
                "backend/tsconfig.json", "ios/project.yml", "ios/Sources/App.swift",
            ]
            for relative in required:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)
            (root / "ios/Sources/Evil.swift").write_text("untracked\n", encoding="utf-8")
            errors: list[str] = []
            MODULE._verify_clean_build_inputs(root, errors)
            self.assertTrue(any("untracked/ignored build input" in error and "Evil.swift" in error for error in errors))

    def test_generated_directory_name_cannot_hide_untracked_swift(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            required = [
                "Makefile", "backend/Dockerfile", "backend/package.json", "backend/package-lock.json",
                "backend/tsconfig.json", "ios/project.yml", "ios/Sources/App.swift",
            ]
            for relative in required:
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("tracked\n", encoding="utf-8")
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
            subprocess.run(["git", "config", "user.name", "Test"], cwd=root, check=True)
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)
            hidden = root / "ios/Sources/dist/Evil.swift"
            hidden.parent.mkdir(parents=True)
            hidden.write_text("untracked\n", encoding="utf-8")
            errors: list[str] = []
            MODULE._verify_clean_build_inputs(root, errors)
            self.assertTrue(any("untracked/ignored build input" in error and "dist/Evil.swift" in error for error in errors))

    def plan(self) -> tuple[dict, list[dict]]:
        project = "locallingo-production"
        direct = {
            **MODULE.FIXED_RUNTIME_LIMITS,
            "ALLOWED_APP_BUNDLE_VERSIONS": "1",
            "ALLOWED_PRODUCT_IDS": "org.acme.app.monthly,org.acme.app.annual",
            "APPLE_APP_ID_PREFIX": "ABCDE12345", "APPLE_APP_STORE_ID": "123456",
            "APPLE_BUNDLE_ID": "org.acme.app",
            "APPLE_IAP_ISSUER_ID": "00000000-0000-4000-8000-000000000000",
            "APPLE_IAP_KEY_ID": "ABCDEFGHIJ", "APPLE_STOREKIT_ENVIRONMENT": "Production",
            "APP_ATTEST_ENVIRONMENT": "production", "APPLE_TEAM_ID": "ABCDE12345",
            "FIRESTORE_DATABASE": "(default)", "FIRESTORE_PROJECT": project,
            "GOOGLE_CLOUD_PROJECT": project, "GOOGLE_STT_LOCATION": "us",
            "GOOGLE_TRANSLATION_LOCATION": "us-central1", "ONLINE_ENABLED": "true",
            "RUNTIME_MODE": "production", "RELEASE_BUILD_ID": "release-build-00000001",
            "BACKEND_OCI_DIGEST": "sha256:" + "a" * 64,
        }
        env = [{"name": name, "value": value} for name, value in direct.items()]
        env.extend(
            {"name": name, "value_source": [{"secret_key_ref": [{"secret": secret, "version": "1"}]}]}
            for name, secret in MODULE.REVIEWED_SECRET_IDS.items()
        )
        image = "registry/api@sha256:" + "a" * 64
        channel = "projects/p/notificationChannels/1"
        route_expression = "!(" + " || ".join(f"request.path == '{path}'" for path in MODULE.EDGE_ALLOWED_PATHS) + ")"
        resources = [
            {"type": "google_cloud_run_v2_service", "name": "api", "values": {
                "project": project, "location": "us-central1", "name": "api", "ingress": "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER",
                "deletion_protection": True, "template": [{
                    "timeout": "20s", "max_instance_request_concurrency": 8,
                    "service_account": f"runtime@{project}.iam.gserviceaccount.com",
                    "scaling": [{"min_instance_count": 1, "max_instance_count": 3}],
                    "containers": [{"image": image, "env": env,
                        "resources": [{"limits": {"cpu": "1", "memory": "1Gi"}}],
                        "startup_probe": [{"initial_delay_seconds": 1, "timeout_seconds": 2, "period_seconds": 2, "failure_threshold": 10, "http_get": [{"path": "/livez", "port": 8080}]}],
                        "liveness_probe": [{"timeout_seconds": 2, "period_seconds": 10, "failure_threshold": 3, "http_get": [{"path": "/livez", "port": 8080}]}],
                    }],
                }],
            }},
            {"mode": "data", "type": "google_project", "name": "current", "values": {"project_id": project}},
            {"mode": "data", "type": "google_service_account", "name": "runtime", "values": {"project": project}},
            *[{"mode": "data", "type": "google_secret_manager_secret", "name": "runtime", "values": {"project": project}} for _ in range(3)],
            {"type": "google_compute_managed_ssl_certificate", "name": "api", "values": {"id": "certificate-id", "project": project, "managed": [{"domains": ["api.acme.dev"]}]}},
            {"type": "google_compute_ssl_policy", "name": "api", "values": {"id": "ssl-policy-id", "project": project, "min_tls_version": "TLS_1_2", "profile": "MODERN"}},
            {"type": "google_compute_security_policy", "name": "api", "values": {"id": "armor-id", "project": project, "rule": [
                {"priority": 100, "action": "deny(400)", "match": [{"expr": [{"expression": "request.query != ''"}]}]},
                {"priority": 200, "action": "deny(404)", "match": [{"expr": [{"expression": route_expression}]}]},
                {"priority": 1000, "action": "rate_based_ban", "match": [{"expr": [{"expression": "request.path == '/v2/app-attest/challenge' || request.path == '/v2/app-attest/register'"}]}], "rate_limit_options": [{"conform_action": "allow", "exceed_action": "deny(429)", "enforce_on_key": "IP", "rate_limit_threshold": [{"count": 60, "interval_sec": 60}], "ban_duration_sec": 600, "ban_threshold": [{"count": 120, "interval_sec": 60}]}]},
                {"priority": 2000, "action": "throttle", "match": [{"versioned_expr": "SRC_IPS_V1", "config": [{"src_ip_ranges": ["*"]}]}], "rate_limit_options": [{"conform_action": "allow", "exceed_action": "deny(429)", "enforce_on_key": "IP", "rate_limit_threshold": [{"count": 600, "interval_sec": 60}]}]},
                {"priority": 2147483647, "action": "allow"},
            ]}},
            {"type": "google_logging_project_exclusion", "name": "query_strings", "values": {"filter": "httpRequest.requestUrl =~ \"[?].+\""}},
            {"type": "google_compute_region_network_endpoint_group", "name": "api", "values": {"id": "neg-id", "project": project, "region": "us-central1", "cloud_run": [{"service": "api"}]}},
            {"type": "google_compute_backend_service", "name": "api", "values": {"id": "backend-id", "project": project, "security_policy": "armor-id", "timeout_sec": 20, "backend": [{"group": "neg-id"}]}},
            {"type": "google_compute_url_map", "name": "api", "values": {"id": "https-map-id", "default_service": "backend-id"}},
            {"type": "google_compute_target_https_proxy", "name": "api", "values": {"id": "https-proxy-id", "url_map": "https-map-id", "ssl_policy": "ssl-policy-id", "ssl_certificates": ["certificate-id"]}},
            {"type": "google_compute_global_address", "name": "api", "values": {"address": "203.0.113.10"}},
            {"type": "google_compute_global_forwarding_rule", "name": "https", "values": {"target": "https-proxy-id", "ip_address": "203.0.113.10", "port_range": "443"}},
            {"type": "google_compute_url_map", "name": "redirect", "values": {"id": "redirect-map-id", "default_url_redirect": [{"https_redirect": True, "strip_query": True}]}},
            {"type": "google_compute_target_http_proxy", "name": "redirect", "values": {"id": "http-proxy-id", "url_map": "redirect-map-id"}},
            {"type": "google_compute_global_forwarding_rule", "name": "http", "values": {"target": "http-proxy-id", "ip_address": "203.0.113.10", "port_range": "80"}},
            {"type": "google_cloud_run_v2_service_iam_member", "name": "public_edge", "values": {"role": "roles/run.invoker", "member": "allUsers"}},
            {"type": "google_logging_project_bucket_config", "name": "default", "values": {"retention_days": 30}},
            {"type": "google_monitoring_uptime_check_config", "name": "ready", "values": {"http_check": [{"path": "/readyz", "port": 443, "use_ssl": True, "validate_ssl": True}], "monitored_resource": [{"type": "uptime_url", "labels": {"host": "api.acme.dev"}}]}},
            {"type": "google_billing_budget", "name": "project", "values": {"billing_account": "billingAccounts/1", "budget_filter": [{"projects": ["projects/123456"]}], "amount": [{"specified_amount": [{"currency_code": "USD", "units": "100"}]}], "threshold_rules": [{"threshold_percent": value} for value in (0.5, 0.9, 1.0)], "all_updates_rule": [{"monitoring_notification_channels": [channel]}]}},
        ]
        resources.extend({"type": "google_logging_metric", "name": name, "values": {"project": project}} for name in ("edge_query_rejections", "security_rejections", "unexpected_secret_access", "iam_changes"))
        resources.extend({"type": "google_monitoring_alert_policy", "name": "security_events", "values": {"notification_channels": [channel]}} for _ in range(4))
        resources.extend({"type": "google_monitoring_alert_policy", "name": name, "values": {"notification_channels": [channel]}} for name in ("uptime", "server_errors", "latency", "memory", "instance_saturation"))
        return {
            "terraform_version": "1.15.7", "resource_changes": [],
            "planned_values": {"root_module": {"resources": resources}},
        }, env

    def test_plan_contract_passes_reviewed_shape(self) -> None:
        plan, _ = self.plan()
        errors: list[str] = []
        MODULE._plan_contract(plan, label="production", expected_mode="production", errors=errors)
        self.assertEqual(errors, [])

    def test_plan_contract_rejects_delete_and_mode_swap(self) -> None:
        plan, env = self.plan()
        plan["resource_changes"] = [{"address": "google_cloud_run_v2_service.api", "change": {"actions": ["delete"]}}]
        next(row for row in env if row.get("name") == "RUNTIME_MODE")["value"] = "testflight"
        errors: list[str] = []
        MODULE._plan_contract(plan, label="production", expected_mode="production", errors=errors)
        self.assertTrue(any("destructive action" in error for error in errors))
        self.assertTrue(any("RUNTIME_MODE" in error for error in errors))

    def test_plan_contract_rejects_route_name_hidden_outside_match(self) -> None:
        plan, _ = self.plan()
        armor = next(row["values"] for row in plan["planned_values"]["root_module"]["resources"] if row["type"] == "google_compute_security_policy")
        route_rule = next(row for row in armor["rule"] if row["priority"] == 200)
        route_rule["description"] = "/v2/devices/replace-oldest"
        route_rule["match"][0]["expr"][0]["expression"] = "false"
        errors: list[str] = []
        MODULE._plan_contract(plan, label="production", expected_mode="production", errors=errors)
        self.assertTrue(any("route allowlist differs" in error for error in errors))

    def test_plan_provenance_binds_live_variables_digest(self) -> None:
        provenance = {
            "schema_version": "1.0", "stack": "service", "app_commit": "a" * 40,
            "terraform_version": "1.15.7", "configuration_sha256": "b" * 64,
            "backend_config_sha256": "c" * 64, "variables_sha256": "d" * 64,
            "plan_sha256": "e" * 64, "project_id": "locallingo-production",
            "environment": "production", "generated_at": "2026-07-12T00:00:00Z",
        }
        errors: list[str] = []
        MODULE._validate_plan_provenance(
            provenance, label="production", expected_mode="production", commit="a" * 40,
            configuration_sha256="b" * 64, backend_sha256="c" * 64,
            variables_sha256="f" * 64, plan_sha256="e" * 64,
            project_id="locallingo-production", errors=errors,
        )
        self.assertTrue(any("variables_sha256" in error and "live release input" in error for error in errors))

    def test_backend_build_metadata_binds_base_app_commit_and_context(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            backend = root / "backend"
            (backend / "src").mkdir(parents=True)
            (backend / "scripts").mkdir(parents=True)
            for relative in ("Dockerfile", "package.json", "package-lock.json", "tsconfig.json", "src/app.ts", "scripts/apply-storekit-ocsp-patch.mjs"):
                (backend / relative).write_text(relative + "\n", encoding="utf-8")
            (backend / ".dockerignore").write_text(
                "**\n!Dockerfile\n!package.json\n!package-lock.json\n!tsconfig.json\n"
                "!src/\n!src/**\n!scripts/\n!scripts/apply-storekit-ocsp-patch.mjs\n",
                encoding="utf-8",
            )
            (backend / "Dockerfile").write_text("ARG NODE_IMAGE\nFROM ${NODE_IMAGE} AS build\nFROM ${NODE_IMAGE}\n", encoding="utf-8")
            base = "node:22@sha256:" + "b" * 64
            image = "registry/api@sha256:" + "a" * 64
            metadata = {
                "containerimage.digest": "sha256:" + "a" * 64,
                "buildx.build.provenance": {"materials": [{"uri": base, "digest": {"sha256": "b" * 64}}]},
                "locallingo.release": {
                    "schema_version": "1.0", "source_commit": "c" * 40,
                    "base_image": base, "application_image_digest": "sha256:" + "a" * 64,
                    "oci_index_digest": "sha256:" + "a" * 64,
                    "runnable_manifest_digest": "sha256:" + "d" * 64,
                    "platform": "linux/amd64",
                    "backend_context_sha256": MODULE._backend_context_digest(root),
                },
            }
            errors: list[str] = []
            MODULE._validate_backend_build_metadata(
                metadata, commit="c" * 40, backend_base_image=base,
                backend_image=image, repository_root=root, errors=errors,
            )
            self.assertEqual(errors, [])
            metadata["locallingo.release"]["base_image"] = "node:22@sha256:" + "d" * 64
            errors = []
            MODULE._validate_backend_build_metadata(
                metadata, commit="c" * 40, backend_base_image=base,
                backend_image=image, repository_root=root, errors=errors,
            )
            self.assertTrue(any("base_image" in error for error in errors))

    def test_recursive_provenance_digest_string_is_not_a_material(self) -> None:
        provenance = {"invocation": {"parameters": {"comment": "sha256:" + "b" * 64}}, "materials": []}
        self.assertFalse(MODULE._provenance_binds_material(provenance, "node@sha256:" + "b" * 64))

    def test_build_script_requests_max_metadata_provenance(self) -> None:
        script = (ROOT.parent / "scripts" / "build-backend-image.sh").read_text(encoding="utf-8")
        self.assertIn("BUILDX_METADATA_PROVENANCE=max docker buildx build", script)
        self.assertIn('document.get("bomFormat") != "CycloneDX"', script)
        self.assertIn('document.get("specVersion") != "1.5"', script)


if __name__ == "__main__":
    unittest.main()
