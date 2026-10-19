from __future__ import annotations

import copy
import hashlib
import importlib.util
import itertools
import json
import math
import struct
import tempfile
import unittest
import wave
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "validate_release_evidence", ROOT / "scripts" / "validate_release_evidence.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseEvidenceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.criteria = json.loads((ROOT / "acceptance-criteria.json").read_bytes())
        profile = cls.criteria["profiles"]["release_language_direction"]
        profile["automated_text"].update({"min_case_count": 1, "min_mean_chrf2": 0, "min_critical_check_pass_rate": 0})
        profile["corpus_coverage"].update({
            "min_speakers": 1,
            "min_audio_minutes": 0.001,
            "required_domains": ["transit"],
            "required_strata": ["question"],
        })
        cls.criteria_bytes = json.dumps(cls.criteria, sort_keys=True, separators=(",", ":")).encode("utf-8")
        cls.criteria_digest = hashlib.sha256(cls.criteria_bytes).hexdigest()

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.artifact_root = Path(self.temporary.name)
        (self.artifact_root / "reports").mkdir()
        (self.artifact_root / "inputs").mkdir()
        now = datetime.now(timezone.utc).replace(microsecond=0)
        self.release_time = (now - timedelta(hours=3)).isoformat().replace("+00:00", "Z")
        self.report_time = (now - timedelta(hours=2)).isoformat().replace("+00:00", "Z")
        self.review_time = (now - timedelta(hours=1)).isoformat().replace("+00:00", "Z")
        self.signoff_time = now.isoformat().replace("+00:00", "Z")
        self.registry = {
            "schema_version": "1.0",
            "generated_at": self.release_time,
            "tiers": {
                "minimum": {"marketing_name": "iPhone 15 Pro", "model_identifier": "iPhone16,1", "soc": "A17 Pro", "memory_gib": 8, "os_version": "26.0", "os_build": "23A100"},
                "mid_tier": {"marketing_name": "iPhone 16 Pro", "model_identifier": "iPhone17,1", "soc": "A18 Pro", "memory_gib": 8, "os_version": "26.0", "os_build": "23A100"},
                "current": {"marketing_name": "iPhone 17 Pro", "model_identifier": "iPhone18,1", "soc": "A19 Pro", "memory_gib": 12, "os_version": "26.0", "os_build": "23A100"},
            },
        }
        self.config = {
            "schema_version": "1.0",
            "configuration": "Release",
            "APP_BUNDLE_IDENTIFIER": "org.acme.locallingo",
            "DEVELOPMENT_TEAM": "ABCDE12345",
            "APP_ATTEST_ENVIRONMENT": "production",
            "APP_RUNTIME_ENVIRONMENT": "production",
            "API_BASE_URL": "https://api.acme.test-domain.com",
            "STOREKIT_MONTHLY_PRODUCT_ID": "org.acme.locallingo.pro.monthly",
            "STOREKIT_ANNUAL_PRODUCT_ID": "org.acme.locallingo.pro.annual",
            "PRIVACY_POLICY_URL": "https://acme.test-domain.com/privacy",
            "TERMS_URL": "https://acme.test-domain.com/terms",
            "SUPPORT_URL": "https://acme.test-domain.com/support",
            "MARKETING_VERSION": "1.0.0",
            "CURRENT_PROJECT_VERSION": "1",
            "RELEASE_BUILD_ID": "release-build-00000001",
            "LOCAL_LLM_EXPERIMENT": "0",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "RELEASE",
            "OTHER_SWIFT_FLAGS": "",
            "backend_contract": {
                "APPLE_BUNDLE_ID": "org.acme.locallingo",
                "APPLE_TEAM_ID": "ABCDE12345",
                "APP_ATTEST_ENVIRONMENT": "production",
                "ALLOWED_PRODUCT_IDS": "org.acme.locallingo.pro.monthly,org.acme.locallingo.pro.annual",
                "ALLOWED_APP_BUNDLE_VERSIONS": "1",
                "API_DOMAIN": "api.acme.test-domain.com",
            },
        }
        self.testflight_config = copy.deepcopy(self.config)
        self.testflight_config.update({
            "configuration": "TestFlight",
            "APP_RUNTIME_ENVIRONMENT": "testflight",
            "APP_BUNDLE_IDENTIFIER": "org.acme.locallingo.testflight",
            "API_BASE_URL": "https://testflight-api.acme.test-domain.com",
            "STOREKIT_MONTHLY_PRODUCT_ID": "org.acme.locallingo.testflight.pro.monthly",
            "STOREKIT_ANNUAL_PRODUCT_ID": "org.acme.locallingo.testflight.pro.annual",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "TESTFLIGHT",
            "backend_contract": {
                "APPLE_BUNDLE_ID": "org.acme.locallingo.testflight",
                "APPLE_TEAM_ID": "ABCDE12345",
                "APP_ATTEST_ENVIRONMENT": "production",
                "ALLOWED_PRODUCT_IDS": "org.acme.locallingo.testflight.pro.monthly,org.acme.locallingo.testflight.pro.annual",
                "ALLOWED_APP_BUNDLE_VERSIONS": "1",
                "API_DOMAIN": "testflight-api.acme.test-domain.com",
            },
        })
        self.registry_path = self.write_json("inputs/device-registry.json", self.registry)
        self.config_path = self.write_json("inputs/resolved-config.json", self.config)
        self.testflight_config_path = self.write_json("inputs/testflight-resolved-config.json", self.testflight_config)
        with wave.open(str(self.artifact_root / "inputs/audio.wav"), "wb") as handle:
            handle.setnchannels(1)
            handle.setsampwidth(2)
            handle.setframerate(16000)
            handle.writeframes(b"".join(
                struct.pack("<h", round(8_000 * math.sin(2 * math.pi * 440 * index / 16_000)))
                for index in range(1600)
            ))

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def write_json(self, uri: str, value: object) -> Path:
        path = self.artifact_root / uri
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        return path

    def digest(self, uri: str) -> str:
        return hashlib.sha256((self.artifact_root / uri).read_bytes()).hexdigest()

    def artifact_ref(self, uri: str) -> dict[str, str]:
        return {"artifact_uri": uri, "sha256": self.digest(uri)}

    def metrics(self, category: str, direction: str, route: str) -> dict:
        if category == "automated_text":
            coverage = self.criteria["profiles"]["release_language_direction"]["corpus_coverage"]
            return {
                "case_count": 1,
                "mean_chrf2": 1.0,
                "critical_check_pass_rate": 1.0,
                "missing_predictions": 0,
                "extra_predictions": 0,
                "speaker_count": 1,
                "audio_minutes": 0.001667,
                "domains": coverage["required_domains"],
                "strata": coverage["required_strata"],
            }
        if category == "human_quality":
            return {
                "bilingual_raters_per_critical_case": 2,
                "median_adequacy_1_to_5": 4.5,
                "minimum_required_stratum_adequacy_1_to_5": 4.0,
                "known_severity_1_meaning_inversions": 0,
                "emergency_allergy_preservation_or_flag_rate": 1.0,
            }
        if category == "speech_quality":
            japanese_source = direction.startswith("ja->")
            return {
                "asr_wer": None if japanese_source else 0.1,
                "language_approved_cer": 0.1 if japanese_source else None,
                "critical_entity_deletion_rate": 0.01,
                "silence_noise_hallucination_rate": 0,
                "wrong_language_rate": 0,
                "tts_bilingual_intelligibility_reviewed": True,
            }
        if category == "runtime":
            local = route in {"local_only", "auto_local"}
            auto = route.startswith("auto_")
            return {
                "endpoint_to_visible_p50_ms": 1000,
                "endpoint_to_visible_p95_ms": 2000,
                "conversation_content_egress_bytes": 0 if local else None,
                "provider_error_rate": None if local else 0,
                "endpoint_allowlist_documented": None if local else True,
                "pre_turn_route_indicator_match_rate": 1.0 if auto else None,
                "local_only_lock_violation_count": 0 if auto else None,
                "fallback_race_failure_count": 0 if auto else None,
            }
        if category == "privacy_security":
            return {name: 0 for name in self.criteria["profiles"]["release_language_direction"]["privacy_security"]}
        if category == "stability":
            return {
                "crashes_or_watchdog_terminations_in_suite": 0,
                "old_turn_playback_failures": 0,
                "peak_memory_device_budget_passed": True,
                "thermal_energy_storage_budgets_passed": True,
            }
        raise AssertionError(category)

    def manifest(self) -> tuple[dict, dict[str, object]]:
        registry_digest = hashlib.sha256(self.registry_path.read_bytes()).hexdigest()
        config_digest = hashlib.sha256(self.config_path.read_bytes()).hexdigest()
        testflight_config_digest = hashlib.sha256(self.testflight_config_path.read_bytes()).hexdigest()
        release = {
            "app_commit": "b" * 40,
            "app_version": "1.0.0",
            "build_number": "1",
            "release_build_id": "release-build-00000001",
            "xcode_version": "26.4",
            "backend_base_image": "node:22-bookworm-slim@sha256:" + "e" * 64,
            "backend_image": "us-central1-docker.pkg.dev/project/repo/api@sha256:" + "c" * 64,
            "backend_build_metadata_sha256": "0" * 64,
            "terraform_plan_sha256": "d" * 64,
            "testflight_terraform_plan_sha256": "f" * 64,
            "terraform_backend_config_sha256": "1" * 64,
            "testflight_terraform_backend_config_sha256": "2" * 64,
            "terraform_variables_sha256": "5" * 64,
            "testflight_terraform_variables_sha256": "6" * 64,
            "terraform_plan_provenance_sha256": "3" * 64,
            "testflight_terraform_plan_provenance_sha256": "4" * 64,
            "ios_resolved_config_sha256": config_digest,
            "testflight_resolved_config_sha256": testflight_config_digest,
            "device_registry_sha256": registry_digest,
            "generated_at": self.release_time,
            "configuration": "Release",
            "local_llm_experiment": False,
        }
        release_digest = MODULE._canonical_digest(release)
        config = self.criteria["release_matrix"]
        matrix = []
        report_index = 0
        audio_ref = self.artifact_ref("inputs/audio.wav")
        for direction, route, device, environment in itertools.product(config["directions"], config["routes"], config["device_tiers"], config["environments"]):
            report_index += 1
            cell_index = report_index
            source_language, target_language = direction.split("->")
            corpus_uri = f"inputs/corpus-{source_language}-{target_language}.jsonl"
            prediction_uri = f"inputs/predictions-{cell_index:03d}.jsonl"
            run_uri = f"inputs/run-{cell_index:03d}.json"
            case_id = f"release-{source_language}-{target_language}-canonical"
            case = {
                "id": case_id,
                "source_language": source_language,
                "target_language": target_language,
                "source": "hello",
                "references": ["translated"],
                "domain": "transit",
                "tags": ["question"],
                "risk": "standard",
                "critical_checks": [{"name": "meaning", "accepted": ["translated"], "required": True}],
                "provenance": {"kind": "synthetic-original", "author": "unit-test-author", "license": "CC0-1.0"},
                "audio": {
                    "path": "inputs/audio.wav", "sha256": audio_ref["sha256"],
                    "speaker_id": "speaker-1", "duration_ms": 100,
                    "environment": "quiet", "consent_record": "synthetic-unit-test", "kind": "speech",
                },
            }
            if not (self.artifact_root / corpus_uri).exists():
                (self.artifact_root / corpus_uri).write_text(json.dumps(case) + "\n", encoding="utf-8")
            model_identifier = self.registry["tiers"][device]["model_identifier"]
            prediction = {
                "id": case_id, "prediction": "translated", "latency_ms": 100,
                "model_build": "unit-engine-1", "device": model_identifier, "processing_mode": route,
                "run_id": f"release-run-{cell_index:03d}",
            }
            (self.artifact_root / prediction_uri).write_text(json.dumps(prediction) + "\n", encoding="utf-8")
            selected_config = self.testflight_config if environment == "testflight" else self.config
            run = {
                "schema_version": "1.0", "run_id": f"release-run-{cell_index:03d}",
                "release_identity_sha256": release_digest, "direction": direction, "route": route,
                "device_tier": device, "deployment_environment": environment,
                "app_commit": release["app_commit"], "app_version": selected_config["MARKETING_VERSION"],
                "build_number": selected_config["CURRENT_PROJECT_VERSION"],
                "app_bundle_id": selected_config["APP_BUNDLE_IDENTIFIER"],
                "api_domain": selected_config["backend_contract"]["API_DOMAIN"],
                "device_model_identifier": model_identifier,
                "device_os_version": self.registry["tiers"][device]["os_version"],
                "device_os_build": self.registry["tiers"][device]["os_build"],
                "engine_build": "unit-engine-1", "generated_at": self.report_time,
            }
            self.write_json(run_uri, run)
            row_evidence = {}
            for category in config["required_evidence"]:
                report_index += 1
                uri = f"reports/cell-{report_index:03d}-{category}.json"
                support_uri = f"inputs/support-{report_index:03d}.json"
                self.write_json(support_uri, {"category": category, "cell": cell_index, "reviewed": True})
                report = {
                    "schema_version": "1.0",
                    "category": category,
                    "status": "passed",
                    "scope": {"kind": "cell", "direction": direction, "route": route, "device_tier": device, "environment": environment},
                    "bindings": {
                        "release_identity_sha256": release_digest,
                        "criteria_sha256": self.criteria_digest,
                        "device_registry_sha256": registry_digest,
                        "corpus": self.artifact_ref(corpus_uri),
                        "run_identity": self.artifact_ref(run_uri),
                    },
                    "metrics": self.metrics(category, direction, route),
                    "checks": {},
                    "attachments": [self.artifact_ref(prediction_uri if category == "automated_text" else support_uri)],
                    "generated_at": self.report_time,
                    "tool": "locallingo-score-predictions/1.0" if category == "automated_text" else f"locallingo-reviewed-{category}/1.0",
                }
                self.write_json(uri, report)
                row_evidence[category] = {
                    "status": "passed", **self.artifact_ref(uri),
                    "reviewed_by": "unit-test-reviewer", "reviewed_at": self.review_time,
                }
            matrix.append({"direction": direction, "route": route, "device_tier": device, "environment": environment, "evidence": row_evidence})
        global_evidence = {}
        for category in config["global_evidence"]:
            report_index += 1
            uri = f"reports/global-{report_index:03d}-{category}.json"
            checks = {name: True for name in config["global_checks"][category]}
            support_uri = f"inputs/support-global-{report_index:03d}.json"
            self.write_json(support_uri, {"category": category, "global": True, "reviewed": True})
            report = {
                "schema_version": "1.0", "category": category, "status": "passed",
                "scope": {"kind": "global"},
                "bindings": {"release_identity_sha256": release_digest, "criteria_sha256": self.criteria_digest, "device_registry_sha256": registry_digest, "corpus": None, "run_identity": None},
                "metrics": {}, "checks": checks,
                "attachments": [self.artifact_ref(support_uri)],
                "generated_at": self.report_time, "tool": f"locallingo-reviewed-{category}/1.0",
            }
            self.write_json(uri, report)
            global_evidence[category] = {"status": "passed", **self.artifact_ref(uri), "reviewed_by": "unit-test-reviewer", "reviewed_at": self.review_time}
        manifest = {
            "schema_version": "1.0", "criteria_sha256": self.criteria_digest, "release": release,
            "signoffs": {name: {"reviewer": f"{name}-reviewer", "approved_at": self.signoff_time} for name in ("quality", "security", "privacy", "operations")},
            "global_evidence": global_evidence, "matrix": matrix,
        }
        live = {name: value for name, value in release.items() if name != "generated_at"}
        return manifest, live

    def validate(self, manifest: dict, live: dict[str, object]) -> list[str]:
        bootstrap_errors: list[str] = []
        store = MODULE.ArtifactStore(self.artifact_root, bootstrap_errors)
        self.assertEqual(bootstrap_errors, [])
        return MODULE.validate_manifest(
            manifest, self.criteria, self.criteria_digest,
            artifact_store=store,
            device_registry=self.registry,
            device_registry_sha256=self.digest("inputs/device-registry.json"),
            resolved_config=self.config,
            resolved_config_sha256=self.digest("inputs/resolved-config.json"),
            testflight_resolved_config=self.testflight_config,
            testflight_resolved_config_sha256=self.digest("inputs/testflight-resolved-config.json"),
            live_release=live,
        )

    def rewrite_report(self, evidence: dict, mutation) -> None:
        path = self.artifact_root / evidence["artifact_uri"]
        report = json.loads(path.read_text(encoding="utf-8"))
        mutation(report)
        path.write_text(json.dumps(report, sort_keys=True) + "\n", encoding="utf-8")
        evidence["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()

    def test_complete_real_artifact_manifest_passes(self) -> None:
        manifest, live = self.manifest()
        self.assertEqual(self.validate(manifest, live), [])

    def test_nonexistent_report_fails(self) -> None:
        manifest, live = self.manifest()
        manifest["matrix"][0]["evidence"]["runtime"]["artifact_uri"] = "reports/missing.json"
        self.assertTrue(any("does not exist" in error for error in self.validate(manifest, live)))

    def test_forged_report_digest_fails(self) -> None:
        manifest, live = self.manifest()
        manifest["matrix"][0]["evidence"]["runtime"]["sha256"] = "a" * 64
        self.assertTrue(any("digest mismatch" in error for error in self.validate(manifest, live)))

    def test_traversal_uri_fails(self) -> None:
        manifest, live = self.manifest()
        manifest["matrix"][0]["evidence"]["runtime"]["artifact_uri"] = "../escape.json"
        self.assertTrue(any("without traversal" in error for error in self.validate(manifest, live)))

    def test_noncanonical_uri_alias_fails(self) -> None:
        manifest, live = self.manifest()
        evidence = manifest["matrix"][0]["evidence"]["runtime"]
        evidence["artifact_uri"] = evidence["artifact_uri"].replace("reports/", "reports//")
        self.assertTrue(any("normalized relative path" in error for error in self.validate(manifest, live)))

    def test_report_scope_mismatch_fails(self) -> None:
        manifest, live = self.manifest()
        evidence = manifest["matrix"][0]["evidence"]["runtime"]
        self.rewrite_report(evidence, lambda report: report["scope"].update(direction="ja->en"))
        self.assertTrue(any("does not match the manifest evidence cell" in error for error in self.validate(manifest, live)))

    def test_per_cell_threshold_failure_fails(self) -> None:
        manifest, live = self.manifest()
        evidence = manifest["matrix"][0]["evidence"]["automated_text"]
        self.rewrite_report(evidence, lambda report: report["metrics"].update(case_count=199))
        self.assertTrue(any("independently recomputed" in error for error in self.validate(manifest, live)))

    def test_report_reuse_across_cells_fails(self) -> None:
        manifest, live = self.manifest()
        manifest["matrix"][1]["evidence"]["runtime"] = copy.deepcopy(manifest["matrix"][0]["evidence"]["runtime"])
        self.assertTrue(any("already used" in error for error in self.validate(manifest, live)))

    def test_copied_attachment_bytes_cannot_evade_reuse_check(self) -> None:
        manifest, live = self.manifest()
        first = manifest["matrix"][0]["evidence"]["runtime"]
        second = manifest["matrix"][1]["evidence"]["runtime"]
        first_report = json.loads((self.artifact_root / first["artifact_uri"]).read_text(encoding="utf-8"))
        source_uri = first_report["attachments"][0]["artifact_uri"]
        copy_uri = "inputs/copied-support.json"
        (self.artifact_root / copy_uri).write_bytes((self.artifact_root / source_uri).read_bytes())
        copied_ref = self.artifact_ref(copy_uri)
        self.rewrite_report(second, lambda report: report.update(attachments=[copied_ref]))
        self.assertTrue(any("attachment bytes must be unique" in error for error in self.validate(manifest, live)))

    def test_tampered_corpus_fails(self) -> None:
        manifest, live = self.manifest()
        corpus_uri = manifest["matrix"][0]["evidence"]["runtime"]["artifact_uri"]
        report = json.loads((self.artifact_root / corpus_uri).read_text(encoding="utf-8"))
        bound_corpus = report["bindings"]["corpus"]["artifact_uri"]
        (self.artifact_root / bound_corpus).write_text("tampered\n", encoding="utf-8")
        self.assertTrue(any("digest mismatch" in error for error in self.validate(manifest, live)))

    def test_live_release_identity_mismatch_fails(self) -> None:
        manifest, live = self.manifest()
        live["app_commit"] = "f" * 40
        self.assertTrue(any("does not match live release input" in error for error in self.validate(manifest, live)))

    def test_missing_matrix_cell_fails(self) -> None:
        manifest, live = self.manifest()
        manifest["matrix"].pop()
        self.assertTrue(any("missing direction/route/device/environment" in error for error in self.validate(manifest, live)))

    def test_negative_count_cannot_pass_maximum_gate(self) -> None:
        manifest, live = self.manifest()
        evidence = manifest["matrix"][0]["evidence"]["privacy_security"]
        self.rewrite_report(evidence, lambda report: report["metrics"].update(local_only_content_egress_bytes=-1))
        self.assertTrue(any("must be nonnegative" in error for error in self.validate(manifest, live)))

    def test_run_identity_cannot_be_reused_across_cells(self) -> None:
        manifest, live = self.manifest()
        first = manifest["matrix"][0]["evidence"]["runtime"]
        second = manifest["matrix"][1]["evidence"]["runtime"]
        first_report = json.loads((self.artifact_root / first["artifact_uri"]).read_text(encoding="utf-8"))
        self.rewrite_report(second, lambda report: report["bindings"].update(run_identity=first_report["bindings"]["run_identity"]))
        self.assertTrue(any("cannot be reused across matrix cells" in error for error in self.validate(manifest, live)))

    def test_run_id_string_cannot_be_reused_via_different_files(self) -> None:
        manifest, live = self.manifest()
        first_evidence = manifest["matrix"][0]["evidence"]["runtime"]
        first_report = json.loads((self.artifact_root / first_evidence["artifact_uri"]).read_text(encoding="utf-8"))
        first_run = json.loads((self.artifact_root / first_report["bindings"]["run_identity"]["artifact_uri"]).read_text(encoding="utf-8"))
        second_row = manifest["matrix"][1]
        sample = next(iter(second_row["evidence"].values()))
        sample_report = json.loads((self.artifact_root / sample["artifact_uri"]).read_text(encoding="utf-8"))
        second_run_uri = sample_report["bindings"]["run_identity"]["artifact_uri"]
        second_run = json.loads((self.artifact_root / second_run_uri).read_text(encoding="utf-8"))
        second_run["run_id"] = first_run["run_id"]
        self.write_json(second_run_uri, second_run)
        second_run_ref = self.artifact_ref(second_run_uri)
        for evidence in second_row["evidence"].values():
            self.rewrite_report(evidence, lambda report, ref=second_run_ref: report["bindings"].update(run_identity=ref))
        self.assertTrue(any("run IDs must be unique" in error for error in self.validate(manifest, live)))

    def test_reused_audio_bytes_cannot_inflate_coverage(self) -> None:
        manifest, live = self.manifest()
        evidence = manifest["matrix"][0]["evidence"]["automated_text"]
        report = json.loads((self.artifact_root / evidence["artifact_uri"]).read_text(encoding="utf-8"))
        corpus_path = self.artifact_root / report["bindings"]["corpus"]["artifact_uri"]
        case = json.loads(corpus_path.read_text(encoding="utf-8"))
        duplicate = copy.deepcopy(case)
        duplicate["id"] = case["id"] + "-copy"
        duplicate["audio"]["speaker_id"] = "invented-second-speaker"
        corpus_path.write_text(json.dumps(case) + "\n" + json.dumps(duplicate) + "\n", encoding="utf-8")
        self.assertTrue(any("audio bytes are reused" in error for error in self.validate(manifest, live)))

    def test_release_and_testflight_identifiers_must_be_isolated(self) -> None:
        errors: list[str] = []
        duplicate = copy.deepcopy(self.config)
        duplicate["configuration"] = "TestFlight"
        duplicate["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "TESTFLIGHT"
        MODULE.validate_environment_isolation(self.config, duplicate, errors)
        self.assertTrue(any("must be distinct" in error for error in errors))

    def test_backend_contract_must_match_resolved_app_config(self) -> None:
        config = copy.deepcopy(self.config)
        config["backend_contract"]["APPLE_BUNDLE_ID"] = "org.acme.some-other-app"
        errors: list[str] = []
        MODULE.validate_resolved_config(config, errors)
        self.assertTrue(any("APPLE_BUNDLE_ID" in error and "does not match" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
