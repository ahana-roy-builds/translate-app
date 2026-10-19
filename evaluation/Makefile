PYTHON ?= python3
PYTHON_ENV = PYTHONDONTWRITEBYTECODE=1
CRITERIA = acceptance-criteria.json

.PHONY: validate test smoke smoke-en-es smoke-en-ja release-preflight release-check release-template trusted-release

validate:
	$(PYTHON_ENV) $(PYTHON) scripts/validate_corpus.py fixtures/starter.en-es.jsonl fixtures/starter.en-ja.jsonl fixtures/safety-medications.jsonl
	$(PYTHON_ENV) $(PYTHON) -m json.tool acceptance-criteria.json >/dev/null
	$(PYTHON_ENV) $(PYTHON) -m json.tool schema/release-evidence.schema.json >/dev/null
	$(PYTHON_ENV) $(PYTHON) -m json.tool schema/device-tier-registry.schema.json >/dev/null
	$(PYTHON_ENV) $(PYTHON) -m json.tool schema/category-report.schema.json >/dev/null
	$(PYTHON_ENV) $(PYTHON) -m json.tool schema/run-identity.schema.json >/dev/null
	@for schema in schema/trusted-artifact.schema.json schema/approval-v1.schema.json schema/attestation-predicates.schema.json schema/release-candidate-v2.schema.json schema/release-decision-v2.schema.json schema/trust-policy-v1.schema.json; do $(PYTHON) -m json.tool "$$schema" >/dev/null || exit; done

test:
	$(PYTHON_ENV) $(PYTHON) -m unittest discover -s tests -p 'test_*.py'

smoke: validate smoke-en-es smoke-en-ja

smoke-en-es:
	$(PYTHON_ENV) $(PYTHON) scripts/score_predictions.py fixtures/starter.en-es.jsonl fixtures/predictions.example.jsonl --criteria $(CRITERIA) --profile starter_fixture --summary-only

smoke-en-ja:
	$(PYTHON_ENV) $(PYTHON) scripts/score_predictions.py fixtures/starter.en-ja.jsonl fixtures/predictions.en-ja.example.jsonl --criteria $(CRITERIA) --profile starter_fixture --summary-only

release-preflight:
	@test -n "$(RELEASE_MANIFEST)" -a -n "$(ARTIFACT_ROOT)" -a -n "$(DEVICE_REGISTRY)" -a -n "$(IOS_RESOLVED_CONFIG)" -a -n "$(TESTFLIGHT_IOS_RESOLVED_CONFIG)" -a -n "$(TERRAFORM_PLAN)" -a -n "$(TESTFLIGHT_TERRAFORM_PLAN)" -a -n "$(TERRAFORM_BACKEND_CONFIG)" -a -n "$(TESTFLIGHT_TERRAFORM_BACKEND_CONFIG)" -a -n "$(TERRAFORM_VARIABLES)" -a -n "$(TESTFLIGHT_TERRAFORM_VARIABLES)" -a -n "$(TERRAFORM_PLAN_PROVENANCE)" -a -n "$(TESTFLIGHT_PLAN_PROVENANCE)" -a -n "$(BACKEND_BUILD_METADATA)" -a -n "$(BACKEND_BASE_IMAGE)" || (echo "Release/TestFlight manifests, configs, plans/provenance/backends/variables, build metadata, artifact root, device registry, and base image are required" >&2; exit 2)
	$(PYTHON_ENV) $(PYTHON) scripts/validate_release_evidence.py "$(RELEASE_MANIFEST)" \
		--criteria $(CRITERIA) \
		--artifact-root "$(ARTIFACT_ROOT)" \
		--device-registry "$(DEVICE_REGISTRY)" \
		--resolved-ios-config "$(IOS_RESOLVED_CONFIG)" \
		--testflight-resolved-ios-config "$(TESTFLIGHT_IOS_RESOLVED_CONFIG)" \
		--terraform-plan "$(TERRAFORM_PLAN)" \
		--testflight-terraform-plan "$(TESTFLIGHT_TERRAFORM_PLAN)" \
		--terraform-backend-config "$(TERRAFORM_BACKEND_CONFIG)" \
		--testflight-terraform-backend-config "$(TESTFLIGHT_TERRAFORM_BACKEND_CONFIG)" \
		--terraform-variables "$(TERRAFORM_VARIABLES)" \
		--testflight-terraform-variables "$(TESTFLIGHT_TERRAFORM_VARIABLES)" \
		--terraform-plan-provenance "$(TERRAFORM_PLAN_PROVENANCE)" \
		--testflight-plan-provenance "$(TESTFLIGHT_PLAN_PROVENANCE)" \
		--backend-build-metadata "$(BACKEND_BUILD_METADATA)" \
		--backend-base-image "$(BACKEND_BASE_IMAGE)"

release-check: release-preflight
	@echo "release-check is a compatibility alias for non-approving release-preflight"

trusted-release:
	@test -n "$(ARTIFACT_ROOT)" -a -n "$(DECISION)" -a -n "$(DECISION_BUNDLE)" -a -n "$(TRUST_POLICY)" -a -n "$(TRUST_POLICY_SHA256)" || (echo "ARTIFACT_ROOT, DECISION, DECISION_BUNDLE, TRUST_POLICY, and TRUST_POLICY_SHA256 are required" >&2; exit 2)
	$(PYTHON_ENV) $(PYTHON) scripts/verify_trusted_release.py \
		--artifact-root "$(ARTIFACT_ROOT)" \
		--decision "$(DECISION)" \
		--decision-bundle "$(DECISION_BUNDLE)" \
		--trust-policy "$(TRUST_POLICY)" \
		--trust-policy-sha256 "$(TRUST_POLICY_SHA256)"

release-template:
	@test -n "$(OUTPUT)" || (echo "OUTPUT=/secure/path/release-evidence.json is required" >&2; exit 2)
	$(PYTHON_ENV) $(PYTHON) scripts/make_release_evidence_template.py --criteria $(CRITERIA) --output "$(OUTPUT)"
