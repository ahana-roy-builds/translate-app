from __future__ import annotations

import copy
import hashlib
import importlib.util
import itertools
import json
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "verify_trusted_release_test", ROOT / "scripts" / "verify_trusted_release.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

EVIDENCE_SPEC = importlib.util.spec_from_file_location(
    "test_release_evidence_fixture", ROOT / "tests" / "test_release_evidence.py"
)
assert EVIDENCE_SPEC and EVIDENCE_SPEC.loader
EVIDENCE_TESTS = importlib.util.module_from_spec(EVIDENCE_SPEC)
EVIDENCE_SPEC.loader.exec_module(EVIDENCE_TESTS)


class FakeStore:
    def __init__(self, json_documents: dict[str, object]) -> None:
        self.json_documents = json_documents
        self.store = self

    def artifact(self, value: object, path: str) -> Path | None:
        if not isinstance(value, dict) or set(value) != {"path", "sha256", "size_bytes", "media_type"}:
            return None
        return Path(str(value["path"]))

    def json(self, path: Path, label: str) -> object | None:
        return self.json_documents.get(str(path))

    def verify_ref(self, value: object, path: str, errors: list[str], *, load_json: bool = False) -> object | None:
        if not isinstance(value, dict) or set(value) != {"artifact_uri", "sha256"}:
            errors.append(f"{path}: invalid v1 artifact reference")
            return None
        digest = value.get("sha256")
        if not isinstance(digest, str) or len(digest) != 64:
            errors.append(f"{path}.sha256: invalid digest")
            return None
        return self.json_documents.get(str(value.get("artifact_uri"))) if load_json else digest


class TrustedReleaseTests(unittest.TestCase):
    def setUp(self) -> None:
        now = datetime.now(timezone.utc).replace(microsecond=0)
        self.candidate_time = now - timedelta(hours=2)
        self.run_time = now - timedelta(hours=1)
        self.preflight_time = now - timedelta(minutes=10)
        self.commit = "a" * 40
        self.tree = "b" * 40
        self.candidate_id = "release-build-00000001"
        self.image = "sha256:" + "c" * 64
        self.runnable_manifest = "sha256:" + "d" * 64
        self.counter = 0
        self.documents: dict[str, dict] = {}
        self.file_json: dict[str, object] = {}
        self.candidate = self.make_candidate()

    def timestamp(self, value: datetime) -> str:
        return value.isoformat().replace("+00:00", "Z")

    def artifact(self, name: str, *, digest: str | None = None) -> dict:
        self.counter += 1
        return {
            "path": f"artifacts/{name}-{self.counter}.json",
            "sha256": digest or f"{self.counter:064x}",
            "size_bytes": 1,
            "media_type": "application/json",
        }

    def signed(self, name: str, predicate: str) -> dict:
        return {
            "artifact": self.artifact(name),
            "bundle": self.artifact(name + "-bundle"),
            "predicate_type": predicate,
        }

    def add(self, name: str, predicate: str, document: dict) -> dict:
        reference = self.signed(name, predicate)
        self.documents[name] = document
        return reference

    def sha(self, character: str = "d") -> str:
        return character * 64

    def make_candidate(self) -> dict:
        criteria_file = self.artifact("criteria-file", digest=self.sha("1"))
        self.file_json[criteria_file["path"]] = {
            "release_matrix": {
                "directions": ["en->es", "es->en", "en->ja", "ja->en"],
                "routes": ["local_only", "online_quality", "auto_local", "auto_online"],
                "device_tiers": ["minimum", "mid_tier", "current"],
                "environments": ["testflight", "production"],
                "required_evidence": ["automated_text"], "global_evidence": [], "global_checks": {},
            },
            "profiles": {"release_language_direction": {}},
        }
        preflight_report = self.artifact("preflight-report", digest=self.sha("2"))
        release_manifest_ref = self.artifact("release-manifest", digest=self.sha("4"))
        resolved_config_ref = self.artifact("resolved-release")
        testflight_config_ref = self.artifact("resolved-testflight")
        resolved_config_json = {
            "configuration": "Release", "APP_BUNDLE_IDENTIFIER": "org.acme.release",
            "DEVELOPMENT_TEAM": "ABCDE12345", "APP_ATTEST_ENVIRONMENT": "production",
            "API_BASE_URL": "https://production.acme.dev",
            "backend_contract": {
                "APPLE_BUNDLE_ID": "org.acme.release", "APPLE_TEAM_ID": "ABCDE12345",
                "APP_ATTEST_ENVIRONMENT": "production",
                "ALLOWED_PRODUCT_IDS": "org.acme.production.monthly,org.acme.production.annual",
                "ALLOWED_APP_BUNDLE_VERSIONS": "1", "API_DOMAIN": "production.acme.dev",
            },
        }
        testflight_config_json = {
            "configuration": "TestFlight", "APP_BUNDLE_IDENTIFIER": "org.acme.testflight",
            "DEVELOPMENT_TEAM": "ABCDE12345", "APP_ATTEST_ENVIRONMENT": "production",
            "API_BASE_URL": "https://testflight.acme.dev",
            "backend_contract": {
                "APPLE_BUNDLE_ID": "org.acme.testflight", "APPLE_TEAM_ID": "ABCDE12345",
                "APP_ATTEST_ENVIRONMENT": "production",
                "ALLOWED_PRODUCT_IDS": "org.acme.testflight.monthly,org.acme.testflight.annual",
                "ALLOWED_APP_BUNDLE_VERSIONS": "1", "API_DOMAIN": "testflight.acme.dev",
            },
        }
        self.file_json[resolved_config_ref["path"]] = resolved_config_json
        self.file_json[testflight_config_ref["path"]] = testflight_config_json
        preflight_report_json = {
            "preflight_status": "passed", "release_decision": False, "schema_version": "1.0",
            "release_identity_sha256": self.sha("3"), "criteria_sha256": criteria_file["sha256"],
            "release_manifest_sha256": release_manifest_ref["sha256"], "release_build_id": self.candidate_id,
            "matrix_cells": 96, "verified_reports": 586,
        }
        self.file_json[preflight_report["path"]] = preflight_report_json
        preflight = self.add("preflight", MODULE.CANDIDATE_REF_TYPES["preflight"], {
            "kind": "preflight", "schema_version": "2.0", "candidate_id": self.candidate_id,
            "source_commit": self.commit, "source_tree": self.tree, "report": preflight_report,
            "release_manifest": release_manifest_ref, "resolved_ios_config": resolved_config_ref,
            "testflight_resolved_ios_config": testflight_config_ref,
            "status": "passed", "release_decision": False, "generated_at": self.timestamp(self.preflight_time),
        })
        criteria = self.add("criteria", MODULE.CANDIDATE_REF_TYPES["criteria"], {
            "kind": "criteria", "schema_version": "2.0", "source_commit": self.commit,
            "criteria": criteria_file, "generated_at": self.timestamp(self.run_time),
        })
        direction_corpus_digests = {
            direction: f"{4000 + index:064x}"
            for index, direction in enumerate(("en->es", "es->en", "en->ja", "ja->en"))
        }
        corpus = self.add("corpus", MODULE.CANDIDATE_REF_TYPES["corpus"], {
            "kind": "corpus-manifest", "schema_version": "2.0", "corpus_id": "hidden-corpus-0001",
            "cases_sha256": MODULE._canonical_digest(direction_corpus_digests),
            "direction_corpora": direction_corpus_digests,
            "stimuli_sha256": self.sha("6"), "answers_sha256": self.sha("7"),
            "rights_manifest_sha256": self.sha("8"), "audio_validation_sha256": self.sha("9"),
            "vad_tool_digest": "sha256:" + self.sha("a"), "fingerprint_tool_digest": "sha256:" + self.sha("b"),
            "directions": ["en->es", "es->en", "en->ja", "ja->en"], "generated_at": self.timestamp(self.run_time),
        })
        tiers = {
            "minimum": {"marketing_name": "iPhone 15 Pro", "model_identifier": "iPhone16,1", "soc": "A17 Pro", "memory_gib": 8, "os_version": "26.0", "os_build": "23A100"},
            "mid_tier": {"marketing_name": "iPhone 16 Pro", "model_identifier": "iPhone17,1", "soc": "A18 Pro", "memory_gib": 8, "os_version": "26.0", "os_build": "23A100"},
            "current": {"marketing_name": "iPhone 17 Pro", "model_identifier": "iPhone18,1", "soc": "A19 Pro", "memory_gib": 12, "os_version": "26.0", "os_build": "23A100"},
        }
        registry = self.add("device_registry", MODULE.CANDIDATE_REF_TYPES["device-registry"], {
            "schema_version": "1.0", "generated_at": self.timestamp(self.run_time), "tiers": tiers,
        })
        ios_refs = {}
        for key, configuration, marker in (("release", "Release", "e"), ("testflight", "TestFlight", "f")):
            ios_refs[key] = self.add(f"ios_builds.{key}", MODULE.CANDIDATE_REF_TYPES["ios-release"], {
                "kind": "ios-build", "schema_version": "1.0", "configuration": configuration,
                "source_commit": self.commit, "source_tree": self.tree, "archive": self.artifact(f"{key}-archive"),
                "ipa": self.artifact(f"{key}-ipa"), "executable_sha256": self.sha(marker),
                "code_directory_hash": marker * 40, "bundle_id": f"org.acme.{key}", "app_version": "1.0.0",
                "build_number": "1", "embedded_build_id": self.candidate_id, "entitlements_sha256": self.sha("1"),
                "provisioning_profile_sha256": self.sha("2"), "provisioning_profile_uuid": f"profile-{key}",
                "team_id": "ABCDE12345", "application_identifier": f"ABCDE12345.org.acme.{key}",
                "signing_certificate_sha256": self.sha("3"), "xcode_version": "26.4.1", "sdk_version": "26.4",
                "resolved_config_sha256": (
                    resolved_config_ref["sha256"] if configuration == "Release" else testflight_config_ref["sha256"]
                ), "generated_at": self.timestamp(self.run_time),
            })
        backend = {
            "image_name": "us-central1-docker.pkg.dev/locallingo-production/locallingo/api",
            "environment_image_names": {
                "production": "us-central1-docker.pkg.dev/locallingo-production/locallingo/api",
                "testflight": "us-central1-docker.pkg.dev/locallingo-testflight/locallingo/api",
            },
            "image_digest": self.image,
            "runnable_manifest_digest": self.runnable_manifest,
        }
        build_metadata = self.artifact("v1-build-metadata")
        self.file_json[build_metadata["path"]] = {
            "containerimage.digest": self.image,
            "buildx.build.provenance": {"materials": []},
            "locallingo.release": {
                "schema_version": "1.0", "source_commit": self.commit,
                "base_image": "node:22-bookworm-slim@sha256:" + self.sha("5"),
                "application_image_digest": self.image, "oci_index_digest": self.image,
                "runnable_manifest_digest": self.runnable_manifest, "platform": "linux/amd64",
                "backend_context_sha256": self.sha("6"),
            },
        }
        backend["provenance"] = self.add("backend.provenance", MODULE.CANDIDATE_REF_TYPES["backend-provenance"], {
            "kind": "backend-provenance", "schema_version": "1.0", "source_commit": self.commit,
            "source_tree": self.tree, "image_name": backend["image_name"], "image_digest": self.image,
            "runnable_manifest_digest": self.runnable_manifest,
            "base_image_digest": "sha256:" + self.sha("5"), "v1_build_metadata": build_metadata,
            "build_context_sha256": self.sha("6"),
            "dockerfile_sha256": self.sha("7"), "builder_id": "github-actions/release-build",
            "generated_at": self.timestamp(self.run_time),
        })
        sbom_document = self.artifact("sbom-document")
        self.file_json[sbom_document["path"]] = {
            "bomFormat": "CycloneDX", "specVersion": "1.5", "components": [],
        }
        backend["sbom"] = self.add("backend.sbom", MODULE.CANDIDATE_REF_TYPES["backend-sbom"], {
            "kind": "backend-sbom", "schema_version": "1.0", "image_digest": self.image,
            "document": sbom_document, "format": "CycloneDX-1.5",
            "generator_digest": "sha256:" + self.sha("8"), "generated_at": self.timestamp(self.run_time),
        })
        for key, kind, predicate in (("vulnerability_scan", "vulnerability-scan", "backend-vulnerability"), ("secret_scan", "secret-scan", "backend-secret")):
            backend[key] = self.add(f"backend.{key}", MODULE.CANDIDATE_REF_TYPES[predicate], {
                "kind": kind, "schema_version": "1.0", "image_digest": self.image,
                "report": self.artifact(key + "-report"), "scanner_digest": "sha256:" + self.sha("9"),
                "database_digest": "sha256:" + self.sha("a") if key == "vulnerability_scan" else None,
                "policy_sha256": self.sha("b"), "status": "passed", "generated_at": self.timestamp(self.run_time),
            })
        environments = {}
        receipts = {}
        for environment in ("production", "testflight"):
            project = f"locallingo-{environment}"
            suffix = "1" if environment == "production" else "2"
            service = f"locallingo-api-{environment}"
            unique_id = suffix * 21
            environment_variables = {
                **MODULE.FIXED_RUNTIME_LIMITS,
                "ALLOWED_APP_BUNDLE_VERSIONS": "1",
                "ALLOWED_PRODUCT_IDS": f"org.acme.{environment}.monthly,org.acme.{environment}.annual",
                "APPLE_APP_ID_PREFIX": "ABCDE12345",
                "APPLE_APP_STORE_ID": "1234567890",
                "APPLE_BUNDLE_ID": "org.acme.release" if environment == "production" else "org.acme.testflight",
                "APPLE_IAP_ISSUER_ID": "00000000-0000-0000-0000-000000000001",
                "APPLE_IAP_KEY_ID": "KEYID12345",
                "APPLE_STOREKIT_ENVIRONMENT": "Production" if environment == "production" else "Sandbox",
                "APP_ATTEST_ENVIRONMENT": "production",
                "APPLE_TEAM_ID": "ABCDE12345",
                "FIRESTORE_DATABASE": "(default)",
                "FIRESTORE_PROJECT": project,
                "GOOGLE_CLOUD_PROJECT": project,
                "GOOGLE_STT_LOCATION": "us",
                "GOOGLE_TRANSLATION_LOCATION": "us-central1",
                "ONLINE_ENABLED": "true",
                "RUNTIME_MODE": environment,
                "RELEASE_BUILD_ID": self.candidate_id,
                "BACKEND_OCI_DIGEST": self.image,
            }
            secret_bindings = {
                field: {
                    "resource": f"projects/{project}/secrets/{secret_id}",
                    "version": str(index + 1),
                    "value_sha256": f"{7000 + int(suffix) * 10 + index:064x}",
                }
                for index, (field, secret_id) in enumerate(MODULE.REVIEWED_SECRET_IDS.items())
            }
            secret_bindings_digest = MODULE._canonical_digest(secret_bindings)
            policy_ref = self.add(f"environments.{environment}.policy", MODULE.CANDIDATE_REF_TYPES["environment-policy"], {
                "kind": "environment-policy", "schema_version": "1.0", "environment": environment,
                "project_id": project, "project_number": suffix * 9, "region": "us-central1",
                "state_bucket": f"{project}-state", "state_prefix": "service",
                "registry_repository": f"us-central1-docker.pkg.dev/{project}/locallingo",
                "api_domain": f"{environment}.acme.dev", "cloud_run_service": service,
                "runtime_service_account_email": f"runtime@{project}.iam.gserviceaccount.com",
                "runtime_service_account_unique_id": unique_id, "firestore_database": "(default)",
                "firestore_location": "us-central1", "environment_variables": environment_variables,
                "secret_bindings": secret_bindings,
                "environment_sha256": MODULE._canonical_digest(environment_variables),
                "secret_bindings_sha256": secret_bindings_digest, "bootstrap_outputs_sha256": self.sha("3"),
                "iam_policy_sha256": self.sha("4"), "generated_at": self.timestamp(self.run_time),
            })
            policy_digest = policy_ref["artifact"]["sha256"]
            v1_plan_provenance = self.artifact(f"{environment}-v1-plan-provenance")
            self.file_json[v1_plan_provenance["path"]] = {
                "schema_version": "1.0", "stack": "service", "app_commit": self.commit,
                "terraform_version": "1.15.7", "configuration_sha256": self.sha("6"),
                "backend_config_sha256": self.sha("7"), "variables_sha256": self.sha("8"),
                "plan_sha256": self.sha("9"), "project_id": project, "environment": environment,
                "generated_at": self.timestamp(self.run_time),
            }
            plan_ref = self.add(f"environments.{environment}.terraform_plan", MODULE.CANDIDATE_REF_TYPES["terraform-plan"], {
                "kind": "terraform-plan", "schema_version": "2.0", "environment": environment,
                "source_commit": self.commit, "source_tree": self.tree, "terraform_version": "1.15.7",
                "provider_lock_sha256": self.sha("5"), "configuration_sha256": self.sha("6"),
                "backend_config_sha256": self.sha("7"), "variables_sha256": self.sha("8"),
                "binary_plan_sha256": self.sha("9"), "plan_json_sha256": self.sha("a"),
                "v1_plan_provenance": v1_plan_provenance,
                "image_name": backend["environment_image_names"][environment],
                "image_digest": self.image, "runnable_manifest_digest": self.runnable_manifest,
                "state_bucket": f"{project}-state", "state_prefix": "service", "state_lineage": "lineage-0001",
                "state_serial": 1, "state_object_generation": "123", "state_sha256": self.sha("b"),
                "environment_policy_sha256": policy_digest, "project_id": project, "region": "us-central1",
                "nonce": ("n" if environment == "production" else "t") * 32, "generated_at": self.timestamp(self.run_time),
            })
            revision = f"{service}-00001-{'pro' if environment == 'production' else 'tst'}"
            control = self.artifact(f"{environment}-control")
            availability = self.artifact(f"{environment}-availability")
            registry_manifest = self.artifact(f"{environment}-registry-manifest")
            observed = self.timestamp(self.run_time)
            self.file_json[control["path"]] = {
                "project_id": project, "location": "us-central1", "service": service,
                "revision": revision, "image_digest": self.image, "traffic_percent": 100,
                "runtime_service_account_unique_id": unique_id, "observed_at": observed,
            }
            self.file_json[availability["path"]] = {
                "available": True, "buildIdentity": {"releaseBuildID": self.candidate_id,
                "ociDigest": self.image, "environment": environment, "revision": revision,
                "assurance": "self-reported-diagnostic"},
            }
            self.file_json[registry_manifest["path"]] = {
                "schema_version": "1.0", "image_name": backend["environment_image_names"][environment],
                "oci_index_digest": self.image, "runnable_manifest_digest": self.runnable_manifest,
            }
            receipt_ref = self.add(f"environments.{environment}.deployment_receipt", MODULE.CANDIDATE_REF_TYPES["deployment"], {
                "kind": "deployment-receipt", "schema_version": "1.0", "environment": environment,
                "plan_sha256": plan_ref["artifact"]["sha256"], "environment_policy_sha256": policy_digest,
                "release_build_id": self.candidate_id, "cloud_run_revision": revision, "image_digest": self.image,
                "traffic_percent": 100, "runtime_service_account_unique_id": unique_id,
                "iam_sha256": self.sha("4"), "firestore_sha256": self.sha("5"),
                "secret_bindings_sha256": secret_bindings_digest, "load_balancer_sha256": self.sha("6"),
                "api_domain": f"{environment}.acme.dev", "registry_manifest": registry_manifest,
                "control_plane": control, "availability": availability, "observed_at": observed,
            })
            environments[environment] = {"policy": policy_ref, "terraform_plan": plan_ref, "deployment_receipt": receipt_ref}
            receipts[environment] = self.documents[f"environments.{environment}.deployment_receipt"]
        device_runs = []
        v1_matrix = []
        direction_corpora: dict[str, dict[str, str]] = {}
        tier_udids = {"minimum": f"{1000:064x}", "mid_tier": f"{1001:064x}", "current": f"{1002:064x}"}
        for index, (direction, route, tier, environment) in enumerate(itertools.product(
            ("en->es", "es->en", "en->ja", "ja->en"),
            ("local_only", "online_quality", "auto_local", "auto_online"),
            ("minimum", "mid_tier", "current"), ("testflight", "production"),
        )):
            ios_key = "testflight" if environment == "testflight" else "release"
            local_route = route in {"local_only", "auto_local"}
            trace = self.artifact(f"trace-{index}")
            if local_route:
                self.file_json[trace["path"]] = {
                    "network_request_count": 0, "conversation_content_egress_bytes": 0,
                    "capture_sha256": f"{2000 + index:064x}", "tool_digest": "sha256:" + self.sha("d"),
                    "started_at": self.timestamp(self.run_time), "completed_at": self.timestamp(self.run_time + timedelta(minutes=1)),
                }
            outputs = self.artifact(f"outputs-{index}")
            run_id = f"device-run-{index:05d}"
            v1_run_ref = {
                "artifact_uri": f"artifacts/v1-run-{index:05d}.json",
                "sha256": f"{3000 + index:064x}",
            }
            self.file_json[v1_run_ref["artifact_uri"]] = {"run_id": run_id}
            corpus_ref = direction_corpora.setdefault(direction, {
                "artifact_uri": f"artifacts/v1-corpus-{direction.replace('->', '-')}.jsonl",
                "sha256": direction_corpus_digests[direction],
            })
            v1_report_ref = {
                "artifact_uri": f"artifacts/v1-automated-{index:05d}.json",
                "sha256": f"{5000 + index:064x}",
            }
            self.file_json[v1_report_ref["artifact_uri"]] = {
                "schema_version": "1.0", "category": "automated_text", "status": "passed",
                "scope": {"kind": "cell", "direction": direction, "route": route,
                          "device_tier": tier, "environment": environment},
                "bindings": {"corpus": corpus_ref, "run_identity": v1_run_ref},
                "attachments": [{"artifact_uri": outputs["path"], "sha256": outputs["sha256"]}],
            }
            v1_matrix.append({
                "direction": direction, "route": route, "device_tier": tier, "environment": environment,
                "evidence": {"automated_text": {
                    "status": "passed", **v1_report_ref,
                    "reviewed_by": "v1-reviewer", "reviewed_at": self.timestamp(self.preflight_time),
                }},
            })
            run = {
                "kind": "device-run", "schema_version": "2.0", "run_id": run_id,
                "nonce": f"nonce-{index:03d}-" + ("x" * 32), "candidate_id": self.candidate_id,
                "corpus_sha256": corpus["artifact"]["sha256"], "direction": direction, "route": route,
                "v1_corpus_sha256": corpus_ref["sha256"],
                "v1_run_identity_sha256": v1_run_ref["sha256"],
                "v1_automated_report_sha256": v1_report_ref["sha256"],
                "device_tier": tier, "environment": environment, "device_registry_sha256": registry["artifact"]["sha256"],
                "device_identifier": tiers[tier]["model_identifier"], "device_udid_sha256": tier_udids[tier],
                "os_version": tiers[tier]["os_version"], "os_build": tiers[tier]["os_build"],
                "app_build_id": self.candidate_id, "ios_build_attestation_sha256": ios_refs[ios_key]["artifact"]["sha256"],
                "backend_image_digest": None if local_route else self.image,
                "backend_revision": None if local_route else receipts[environment]["cloud_run_revision"],
                "api_domain": None if local_route else receipts[environment]["api_domain"],
                "app_attest_request_id": None if local_route else f"attest-{index:05d}",
                "outputs": outputs, "timings": self.artifact(f"timings-{index}"),
                "trace": trace, "started_at": self.timestamp(self.run_time),
                "completed_at": self.timestamp(self.run_time + timedelta(minutes=1)),
            }
            device_runs.append(self.add(f"device_runs[{index}]", MODULE.CANDIDATE_REF_TYPES["device-run"], run))
        v1_release = {
            "app_commit": self.commit, "app_version": "1.0.0", "build_number": "1",
            "release_build_id": self.candidate_id,
            "xcode_version": self.documents["ios_builds.release"]["xcode_version"],
            "backend_base_image": "node:22-bookworm-slim@" + self.documents["backend.provenance"]["base_image_digest"],
            "backend_image": f"{backend['image_name']}@{backend['image_digest']}",
            "backend_build_metadata_sha256": build_metadata["sha256"],
            "terraform_plan_sha256": self.documents["environments.production.terraform_plan"]["binary_plan_sha256"],
            "testflight_terraform_plan_sha256": self.documents["environments.testflight.terraform_plan"]["binary_plan_sha256"],
            "terraform_backend_config_sha256": self.documents["environments.production.terraform_plan"]["backend_config_sha256"],
            "testflight_terraform_backend_config_sha256": self.documents["environments.testflight.terraform_plan"]["backend_config_sha256"],
            "terraform_variables_sha256": self.documents["environments.production.terraform_plan"]["variables_sha256"],
            "testflight_terraform_variables_sha256": self.documents["environments.testflight.terraform_plan"]["variables_sha256"],
            "terraform_plan_provenance_sha256": self.documents["environments.production.terraform_plan"]["v1_plan_provenance"]["sha256"],
            "testflight_terraform_plan_provenance_sha256": self.documents["environments.testflight.terraform_plan"]["v1_plan_provenance"]["sha256"],
            "ios_resolved_config_sha256": resolved_config_ref["sha256"],
            "testflight_resolved_config_sha256": testflight_config_ref["sha256"],
            "device_registry_sha256": registry["artifact"]["sha256"],
            "configuration": "Release", "local_llm_experiment": False,
        }
        self.file_json[release_manifest_ref["path"]] = {
            "schema_version": "1.0", "criteria_sha256": criteria_file["sha256"],
            "release": v1_release, "signoffs": {}, "global_evidence": {}, "matrix": v1_matrix,
        }
        preflight_report_json["release_identity_sha256"] = MODULE._canonical_digest(v1_release)
        return {
            "schema_version": "2.0", "candidate_id": self.candidate_id, "repository": "acme/locallingo",
            "source_commit": self.commit, "source_tree": self.tree, "source_ref": "refs/tags/v1.0.0",
            "app_version": "1.0.0", "build_number": "1", "created_at": self.timestamp(self.candidate_time),
            "preflight": preflight, "criteria": criteria, "corpus": corpus, "device_registry": registry,
            "ios_builds": ios_refs, "backend": backend, "environments": environments, "device_runs": device_runs,
        }

    def validate(
        self, candidate: dict | None = None, *, v1_errors: list[str] | None = None,
        nested_signed_at: datetime | None = None, candidate_signed_at: datetime | None = None,
    ) -> list[str]:
        errors: list[str] = []
        candidate = candidate or self.candidate
        store = FakeStore(self.file_json)

        def nested(reference, path, predicate, *_args, **_kwargs):
            name = path.removeprefix("candidate.")
            return copy.deepcopy(self.documents.get(name)), reference["artifact"]["sha256"], nested_signed_at

        policy = {"repository": "acme/locallingo", "source_commit": self.commit, "source_ref": "refs/tags/v1.0.0"}
        with mock.patch.object(MODULE, "_nested_json", side_effect=nested), mock.patch.object(
            MODULE, "validate_manifest", return_value=v1_errors or []
        ):
            MODULE.validate_candidate(
                candidate, "f" * 64, store, policy, "/usr/bin/gh", Path("root.json"), errors,
                candidate_signed_at=candidate_signed_at,
            )
        return errors

    def test_complete_semantic_candidate_passes(self) -> None:
        self.assertEqual(self.validate(), [])

    def test_arbitrary_signed_device_blob_fails(self) -> None:
        self.documents["device_runs[0]"] = {"signed": "but not a device predicate"}
        self.assertTrue(any("device_runs[0]" in error and "missing fields" in error for error in self.validate()))

    def test_duplicate_matrix_cell_fails(self) -> None:
        first = self.documents["device_runs[0]"]
        last = self.documents["device_runs[95]"]
        for field in ("direction", "route", "device_tier", "environment"):
            last[field] = first[field]
        self.assertTrue(any("matrix is missing, duplicated" in error for error in self.validate()))

    def test_unrelated_preflight_or_dummy_device_outputs_fail(self) -> None:
        preflight_report = self.file_json[self.documents["preflight"]["report"]["path"]]
        assert isinstance(preflight_report, dict)
        preflight_report["release_manifest_sha256"] = "0" * 64
        self.documents["device_runs[0]"]["outputs"] = self.artifact("unrelated-output")
        errors = self.validate()
        self.assertTrue(any("signed v1 manifest binding mismatch" in error for error in errors))
        self.assertTrue(any("outputs: must equal the bound v1 automated predictions" in error for error in errors))

    def test_bound_v1_validation_failure_rejects_candidate(self) -> None:
        errors = self.validate(v1_errors=["tampered evidence report"])
        self.assertIn("bound v1 preflight: tampered evidence report", errors)

    def test_digest_consistent_invalid_human_report_fails_full_v1_replay(self) -> None:
        fixture = EVIDENCE_TESTS.ReleaseEvidenceTests(methodName="test_complete_real_artifact_manifest_passes")
        fixture.setUpClass()
        fixture.setUp()
        try:
            manifest, _live = fixture.manifest()
            human = manifest["matrix"][0]["evidence"]["human_quality"]
            fixture.rewrite_report(human, lambda report: report["metrics"].update(median_adequacy_1_to_5=0))

            candidate = copy.deepcopy(self.candidate)
            documents = copy.deepcopy(self.documents)
            file_json = copy.deepcopy(self.file_json)
            release = manifest["release"]
            source_commit = release["app_commit"]
            image_name, image_digest = release["backend_image"].rsplit("@", 1)
            registry_digest = fixture.digest("inputs/device-registry.json")
            release_config_digest = fixture.digest("inputs/resolved-config.json")
            testflight_config_digest = fixture.digest("inputs/testflight-resolved-config.json")

            candidate.update(source_commit=source_commit)
            candidate["backend"].update(image_name=image_name, image_digest=image_digest)
            candidate["device_registry"]["artifact"]["sha256"] = registry_digest

            documents["preflight"]["source_commit"] = source_commit
            documents["preflight"]["generated_at"] = fixture.signoff_time
            documents["criteria"]["source_commit"] = source_commit
            documents["device_registry"] = copy.deepcopy(fixture.registry)
            for name in ("ios_builds.release", "ios_builds.testflight"):
                documents[name]["source_commit"] = source_commit
            documents["ios_builds.release"].update(
                xcode_version=release["xcode_version"], bundle_id=fixture.config["APP_BUNDLE_IDENTIFIER"],
                application_identifier=f"ABCDE12345.{fixture.config['APP_BUNDLE_IDENTIFIER']}",
                resolved_config_sha256=release_config_digest,
            )
            documents["ios_builds.testflight"].update(
                bundle_id=fixture.testflight_config["APP_BUNDLE_IDENTIFIER"],
                application_identifier=f"ABCDE12345.{fixture.testflight_config['APP_BUNDLE_IDENTIFIER']}",
                resolved_config_sha256=testflight_config_digest,
            )
            documents["backend.provenance"].update(
                source_commit=source_commit, image_name=image_name, image_digest=image_digest,
                base_image_digest=release["backend_base_image"].rsplit("@", 1)[1],
            )
            build_metadata_ref = documents["backend.provenance"]["v1_build_metadata"]
            build_metadata_ref["sha256"] = release["backend_build_metadata_sha256"]
            file_json[build_metadata_ref["path"]] = {
                "containerimage.digest": image_digest, "buildx.build.provenance": {"materials": []},
                "locallingo.release": {
                    "schema_version": "1.0", "source_commit": source_commit,
                    "base_image": release["backend_base_image"], "application_image_digest": image_digest,
                    "oci_index_digest": image_digest,
                    "runnable_manifest_digest": documents["backend.provenance"]["runnable_manifest_digest"],
                    "platform": "linux/amd64",
                    "backend_context_sha256": documents["backend.provenance"]["build_context_sha256"],
                },
            }
            for environment, prefix in (("production", ""), ("testflight", "testflight_")):
                plan = documents[f"environments.{environment}.terraform_plan"]
                plan.update(
                    source_commit=source_commit,
                    binary_plan_sha256=release[f"{prefix}terraform_plan_sha256"],
                    backend_config_sha256=release[f"{prefix}terraform_backend_config_sha256"],
                    variables_sha256=release[f"{prefix}terraform_variables_sha256"],
                )
                provenance_ref = plan["v1_plan_provenance"]
                provenance_ref["sha256"] = release[f"{prefix}terraform_plan_provenance_sha256"]
                file_json[provenance_ref["path"]] = {
                    "schema_version": "1.0", "stack": "service", "app_commit": source_commit,
                    "terraform_version": "1.15.7", "configuration_sha256": plan["configuration_sha256"],
                    "backend_config_sha256": plan["backend_config_sha256"],
                    "variables_sha256": plan["variables_sha256"], "plan_sha256": plan["binary_plan_sha256"],
                    "project_id": plan["project_id"], "environment": environment,
                    "generated_at": self.timestamp(self.run_time),
                }

            preflight = documents["preflight"]
            preflight["release_manifest"]["sha256"] = hashlib.sha256(
                json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
            ).hexdigest()
            preflight["resolved_ios_config"]["sha256"] = release_config_digest
            preflight["testflight_resolved_ios_config"]["sha256"] = testflight_config_digest
            criteria_ref = documents["criteria"]["criteria"]
            criteria_ref["sha256"] = fixture.criteria_digest
            file_json[preflight["release_manifest"]["path"]] = manifest
            file_json[preflight["resolved_ios_config"]["path"]] = fixture.config
            file_json[preflight["testflight_resolved_ios_config"]["path"]] = fixture.testflight_config
            file_json[criteria_ref["path"]] = fixture.criteria
            preflight_report = file_json[preflight["report"]["path"]]
            assert isinstance(preflight_report, dict)
            preflight_report.update(
                release_manifest_sha256=preflight["release_manifest"]["sha256"],
                release_identity_sha256=EVIDENCE_TESTS.MODULE._canonical_digest(release),
                criteria_sha256=fixture.criteria_digest,
            )

            for environment, config, ios_name in (
                ("production", fixture.config, "ios_builds.release"),
                ("testflight", fixture.testflight_config, "ios_builds.testflight"),
            ):
                policy = documents[f"environments.{environment}.policy"]
                receipt = documents[f"environments.{environment}.deployment_receipt"]
                contract = config["backend_contract"]
                policy["api_domain"] = contract["API_DOMAIN"]
                policy["environment_variables"].update(
                    APPLE_APP_ID_PREFIX=documents[ios_name]["team_id"],
                    APPLE_BUNDLE_ID=config["APP_BUNDLE_IDENTIFIER"],
                    APPLE_TEAM_ID=config["DEVELOPMENT_TEAM"],
                    APP_ATTEST_ENVIRONMENT=config["APP_ATTEST_ENVIRONMENT"],
                    ALLOWED_PRODUCT_IDS=contract["ALLOWED_PRODUCT_IDS"],
                    ALLOWED_APP_BUNDLE_VERSIONS=contract["ALLOWED_APP_BUNDLE_VERSIONS"],
                    BACKEND_OCI_DIGEST=image_digest,
                )
                policy["environment_sha256"] = MODULE._canonical_digest(policy["environment_variables"])
                receipt.update(api_domain=contract["API_DOMAIN"], image_digest=image_digest)
                file_json[receipt["availability"]["path"]]["buildIdentity"]["ociDigest"] = image_digest
                file_json[receipt["control_plane"]["path"]]["image_digest"] = image_digest

            for index, row in enumerate(manifest["matrix"]):
                automated_ref = row["evidence"]["automated_text"]
                automated_report = json.loads(
                    (fixture.artifact_root / automated_ref["artifact_uri"]).read_text(encoding="utf-8")
                )
                run_ref = automated_report["bindings"]["run_identity"]
                run_identity = json.loads(
                    (fixture.artifact_root / run_ref["artifact_uri"]).read_text(encoding="utf-8")
                )
                output_ref = automated_report["attachments"][0]
                run = documents[f"device_runs[{index}]"]
                run.update(
                    run_id=run_identity["run_id"], device_registry_sha256=registry_digest,
                    v1_corpus_sha256=automated_report["bindings"]["corpus"]["sha256"],
                    v1_run_identity_sha256=run_ref["sha256"],
                    v1_automated_report_sha256=automated_ref["sha256"],
                    outputs={**run["outputs"], "path": output_ref["artifact_uri"], "sha256": output_ref["sha256"]},
                )
                if run["backend_image_digest"] is not None:
                    run["backend_image_digest"] = image_digest
                    run["api_domain"] = documents[f"environments.{run['environment']}.deployment_receipt"]["api_domain"]

            real_direction_corpora: dict[str, str] = {}
            for row in manifest["matrix"]:
                automated_ref = row["evidence"]["automated_text"]
                automated_report = json.loads(
                    (fixture.artifact_root / automated_ref["artifact_uri"]).read_text(encoding="utf-8")
                )
                real_direction_corpora.setdefault(
                    row["direction"], automated_report["bindings"]["corpus"]["sha256"]
                )
            documents["corpus"]["direction_corpora"] = real_direction_corpora
            documents["corpus"]["cases_sha256"] = MODULE._canonical_digest(real_direction_corpora)

            errors: list[str] = []
            store = FakeStore(file_json)
            store.store = MODULE.ArtifactStore(fixture.artifact_root, errors)

            def nested(reference, path, predicate, *_args, **_kwargs):
                del predicate
                name = path.removeprefix("candidate.")
                return copy.deepcopy(documents.get(name)), reference["artifact"]["sha256"], None

            policy = {
                "repository": "acme/locallingo", "source_commit": source_commit,
                "source_ref": "refs/tags/v1.0.0",
            }
            with mock.patch.object(MODULE, "_nested_json", side_effect=nested):
                MODULE.validate_candidate(candidate, "f" * 64, store, policy, "/usr/bin/gh", Path("root.json"), errors)
            self.assertTrue(any(
                error.startswith("bound v1 preflight:") and "median_adequacy_1_to_5" in error
                for error in errors
            ), errors)
        finally:
            fixture.tearDown()

    def test_v1_build_and_plan_inputs_must_match_signed_v2_evidence(self) -> None:
        preflight = self.documents["preflight"]
        manifest = self.file_json[preflight["release_manifest"]["path"]]
        report = self.file_json[preflight["report"]["path"]]
        assert isinstance(manifest, dict) and isinstance(report, dict)
        release = manifest["release"]
        release["xcode_version"] = "26.9"
        release["backend_base_image"] = "node:22-bookworm-slim@sha256:" + "0" * 64
        release["terraform_plan_sha256"] = "0" * 64
        report["release_identity_sha256"] = MODULE._canonical_digest(release)
        errors = self.validate()
        self.assertTrue(any("release.xcode_version: candidate binding mismatch" in error for error in errors))
        self.assertTrue(any("release.backend_base_image: candidate binding mismatch" in error for error in errors))
        self.assertTrue(any("release.terraform_plan_sha256: candidate binding mismatch" in error for error in errors))

    def test_environment_policy_must_match_resolved_ios_contract(self) -> None:
        policy = self.documents["environments.production.policy"]
        policy["environment_variables"]["APPLE_BUNDLE_ID"] = "org.attacker.unrelated"
        policy["environment_sha256"] = MODULE._canonical_digest(policy["environment_variables"])
        self.assertTrue(any(
            "environment_variables.APPLE_BUNDLE_ID: resolved iOS binding mismatch" in error
            for error in self.validate()
        ))

    def test_registry_repository_and_reopened_manifest_are_bound(self) -> None:
        policy = self.documents["environments.production.policy"]
        policy["registry_repository"] = "us-central1-docker.pkg.dev/unrelated-project/locallingo"
        receipt = self.documents["environments.production.deployment_receipt"]
        manifest_ref = receipt["registry_manifest"]
        self.file_json[manifest_ref["path"]]["runnable_manifest_digest"] = "sha256:" + "0" * 64
        errors = self.validate()
        self.assertTrue(any("registry_repository: invalid canonical" in error for error in errors))
        self.assertTrue(any("registry subject/runnable identity mismatch" in error for error in errors))

    def test_nested_claimed_time_cannot_postdate_trusted_signature(self) -> None:
        old_signature = datetime.now(timezone.utc).replace(microsecond=0) - timedelta(days=44)
        errors = self.validate(nested_signed_at=old_signature, candidate_signed_at=self.preflight_time)
        self.assertTrue(any("claimed event is after trusted signing time" in error for error in errors))

    def test_sbom_label_must_match_parsed_document(self) -> None:
        document_ref = self.documents["backend.sbom"]["document"]
        self.file_json[document_ref["path"]]["specVersion"] = "1.4"
        self.assertTrue(any(
            "must be a parsed CycloneDX 1.5 document" in error for error in self.validate()
        ))

    def test_wrong_binary_image_and_environment_bindings_fail(self) -> None:
        self.documents["ios_builds.release"]["embedded_build_id"] = "another-build-000000"
        self.documents["device_runs[6]"]["backend_image_digest"] = "sha256:" + "0" * 64
        self.documents["environments.production.deployment_receipt"]["environment"] = "testflight"
        errors = self.validate()
        self.assertTrue(any("embedded_build_id" in error for error in errors))
        self.assertTrue(any("backend_image_digest" in error for error in errors))
        self.assertTrue(any("deployment/policy/candidate binding" in error for error in errors))

    def test_tag_version_must_match_candidate_version(self) -> None:
        self.candidate["app_version"] = "9.9.9"
        for name in ("ios_builds.release", "ios_builds.testflight"):
            self.documents[name]["app_version"] = "9.9.9"
        self.assertTrue(any("version tag must match" in error for error in self.validate()))

    def test_v2_corpus_must_bind_v1_direction_corpora(self) -> None:
        replacement_digest = "0" * 64
        self.candidate["corpus"]["artifact"]["sha256"] = replacement_digest
        for index in range(96):
            self.documents[f"device_runs[{index}]"]["corpus_sha256"] = replacement_digest
        self.documents["corpus"]["cases_sha256"] = "f" * 64
        self.assertTrue(any("cases_sha256: must bind" in error for error in self.validate()))

    def test_each_tier_requires_one_distinct_physical_udid(self) -> None:
        for index in range(96):
            self.documents[f"device_runs[{index}]"]["device_udid_sha256"] = "1" * 64
        self.assertTrue(any("distinct physical-device UDID" in error for error in self.validate()))

    def test_release_and_testflight_may_not_reuse_archive_or_ipa(self) -> None:
        self.documents["ios_builds.testflight"]["archive"] = copy.deepcopy(
            self.documents["ios_builds.release"]["archive"]
        )
        self.documents["ios_builds.testflight"]["ipa"] = copy.deepcopy(
            self.documents["ios_builds.release"]["ipa"]
        )
        self.assertTrue(any("artifacts must be distinct" in error for error in self.validate()))

    def test_terraform_plan_nonces_must_be_nonempty_and_distinct(self) -> None:
        production = self.documents["environments.production.terraform_plan"]
        testflight = self.documents["environments.testflight.terraform_plan"]
        production["nonce"] = ""
        testflight["nonce"] = "x" * 32
        errors = self.validate()
        self.assertTrue(any("production.terraform_plan.nonce" in error for error in errors))
        production["nonce"] = "x" * 32
        self.assertTrue(any("testflight.terraform_plan.nonce" in error for error in self.validate()))

    def test_local_route_with_backend_contact_fails(self) -> None:
        self.documents["device_runs[0]"]["backend_revision"] = "locallingo-api-testflight-00001-tst"
        self.assertTrue(any("local route must not contain" in error for error in self.validate()))

    def test_online_route_missing_authenticated_contact_fails(self) -> None:
        self.documents["device_runs[6]"]["app_attest_request_id"] = None
        self.assertTrue(any("online route requires" in error for error in self.validate()))

    def test_nonempty_waiver_injection_fails(self) -> None:
        errors: list[str] = []
        approval = {"schema_version": "1.0", "role": "quality", "candidate_sha256": "a" * 64,
            "preflight_sha256": "b" * 64, "reviewer_login": "reviewer", "reviewer_id": "123",
            "approved_at": self.timestamp(self.preflight_time), "waivers": [self.signed("waiver", "urn:locallingo:attestation:waiver:v1")]}
        MODULE.validate_approval(approval, "quality", "a" * 64, "b" * 64, errors)
        self.assertTrue(any("does not permit" in error for error in errors))

    def test_pre_attestation_result_is_never_an_approval(self) -> None:
        pre = MODULE.verification_result("a" * 64, signed_final=False)
        final = MODULE.verification_result("a" * 64, signed_final=True)
        self.assertEqual(pre, {
            "release_decision": False, "ready_to_sign": True, "schema_version": "2.0",
            "candidate_sha256": "a" * 64, "verification": "pre-attestation",
        })
        self.assertEqual(final["release_decision"], "approved")

    def test_device_predicate_routes_to_device_signer(self) -> None:
        reference = self.candidate["device_runs"][0]
        store = mock.Mock()
        store.signed.return_value = (Path("run.json"), Path("bundle.json"))
        store.json.return_value = {"kind": "device-run"}
        policy = {"signers": {"device": {"workflow": "acme/locallingo/.github/workflows/device.yml"}}, "repository": "acme/locallingo", "source_commit": self.commit, "source_ref": "refs/tags/v1.0.0"}
        errors: list[str] = []
        with mock.patch.object(MODULE, "gh_verify") as verify:
            MODULE._nested_json(reference, "candidate.device_runs[0]", MODULE.CANDIDATE_REF_TYPES["device-run"], store, policy, "/usr/bin/gh", Path("root"), errors)
        self.assertEqual(verify.call_args.kwargs["signer_name"], "device")

    def test_gh_verification_requires_trusted_time_and_certificate_identity(self) -> None:
        policy = {
            "repository": "acme/locallingo", "source_commit": self.commit,
            "source_ref": "refs/tags/v1.0.0",
            "repository_id": "12345", "repository_owner_id": "67890",
            "signers": {"candidate": {"workflow": "acme/locallingo/.github/workflows/release-candidate.yml"}},
        }
        payload = [{"verificationResult": {
            "signature": {"certificate": {
                "buildSignerDigest": self.commit, "sourceRepositoryDigest": self.commit,
                "sourceRepositoryRef": "refs/tags/v1.0.0",
                "sourceRepositoryURI": "https://github.com/acme/locallingo",
                "sourceRepositoryIdentifier": "12345", "sourceRepositoryOwnerIdentifier": "67890",
            }},
            "verifiedTimestamps": [{"type": "Tlog", "timestamp": self.timestamp(self.preflight_time)}],
        }}]
        completed = mock.Mock(returncode=0, stdout=json.dumps(payload), stderr="")
        errors: list[str] = []
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed) as run:
            signed_at = MODULE.gh_verify(
                gh="/usr/bin/gh", artifact=Path("subject"), bundle=Path("bundle"),
                trusted_root=Path("root"), policy=policy, signer_name="candidate",
                predicate=MODULE.CANDIDATE_PREDICATE, errors=errors,
            )
        self.assertIsNotNone(signed_at)
        self.assertEqual(errors, [])
        self.assertIn("--signer-digest", run.call_args.args[0])
        del payload[0]["verificationResult"]["verifiedTimestamps"]
        completed.stdout = json.dumps(payload)
        errors = []
        with mock.patch.object(MODULE.subprocess, "run", return_value=completed):
            self.assertIsNone(MODULE.gh_verify(
                gh="/usr/bin/gh", artifact=Path("subject"), bundle=Path("bundle"),
                trusted_root=Path("root"), policy=policy, signer_name="candidate",
                predicate=MODULE.CANDIDATE_PREDICATE, errors=errors,
            ))
        self.assertTrue(any("verified timestamp" in error for error in errors))

    def test_wrong_signer_predicate_policy_fails(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            workflows = root / ".github" / "workflows"
            workflows.mkdir(parents=True)
            signers = {}
            for name, predicates in MODULE.SIGNER_PREDICATES.items():
                workflow = workflows / f"{name}.yml"
                workflow.write_text(f"name: {name}\n", encoding="utf-8")
                signers[name] = {
                    "workflow": f"acme/locallingo/.github/workflows/{name}.yml",
                    "workflow_sha256": hashlib.sha256(workflow.read_bytes()).hexdigest(),
                    "predicate_types": sorted(predicates),
                }
            signers["candidate"]["predicate_types"].append(MODULE.CANDIDATE_REF_TYPES["device-run"])
            policy = {"schema_version": "1.0", "repository": "acme/locallingo", "repository_id": "12345", "repository_owner_id": "67890", "source_ref": "refs/tags/v1.0.0",
                "source_commit": self.commit, "trusted_root": self.artifact("trusted-root"), "signers": signers}
            errors: list[str] = []
            MODULE.verify_signer_policy(policy, root, errors)
            self.assertTrue(any("candidate.predicate_types" in error for error in errors))

    def test_real_trusted_store_reopens_and_hashes_inner_artifact_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            contents = b'{"schema_version":"1.0","stack":"service"}\n'
            (root / "plan-provenance.json").write_bytes(contents)
            errors: list[str] = []
            store = MODULE.TrustedStore(root, errors)
            reference = {
                "path": "plan-provenance.json", "sha256": hashlib.sha256(contents).hexdigest(),
                "size_bytes": len(contents), "media_type": "application/json",
            }
            snapshot = store.artifact(reference, "inner")
            self.assertIsNotNone(snapshot)
            self.assertEqual(errors, [])
            reference["sha256"] = "0" * 64
            store.artifact(reference, "tampered")
            self.assertTrue(any("digest mismatch" in error for error in errors))
            store.store.close()


if __name__ == "__main__":
    unittest.main()
