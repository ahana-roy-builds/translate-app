PYTHON ?= python3

.PHONY: test test-fast test-integration backend-check backend-test backend-image evaluation-check script-tests repository-check infra-fmt infra-validate infra-plan infra-apply ios-test ios-private-beta-compile ios-testflight-compile ios-release-compile ios-resolved-config-from-environment release-preflight release-check release-finalize release-template

test: test-fast

test-fast: backend-check backend-test evaluation-check script-tests repository-check

backend-check:
	npm --prefix backend run check

backend-test:
	npm --prefix backend test

backend-image:
	bash scripts/build-backend-image.sh

evaluation-check:
	$(MAKE) -C evaluation validate test smoke

script-tests:
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s scripts/tests -p 'test_*.py'

repository-check:
	bash scripts/validate-repository.sh --structural-only

infra-fmt:
	@command -v terraform >/dev/null || (echo "terraform is required" >&2; exit 2)
	terraform fmt -check -recursive infra

infra-validate: infra-fmt
	bash scripts/validate-terraform.sh

infra-plan:
	@test -n "$(STACK)" -a -n "$(BACKEND_CONFIG)" -a -n "$(TFVARS)" -a -n "$(TFPLAN)" || (echo "STACK, BACKEND_CONFIG, TFVARS, and TFPLAN are required" >&2; exit 2)
	bash scripts/terraform-plan.sh "$(STACK)" "$(BACKEND_CONFIG)" "$(TFVARS)" "$(TFPLAN)"

infra-apply:
	@test -n "$(STACK)" -a -n "$(BACKEND_CONFIG)" -a -n "$(TFVARS)" -a -n "$(TFPLAN)" -a -n "$(EXPECTED_TFPLAN_SHA256)" || (echo "STACK, BACKEND_CONFIG, TFVARS, TFPLAN, and out-of-band EXPECTED_TFPLAN_SHA256 are required" >&2; exit 2)
	bash scripts/terraform-apply.sh "$(STACK)" "$(BACKEND_CONFIG)" "$(TFVARS)" "$(TFPLAN)" "$(EXPECTED_TFPLAN_SHA256)"

ios-test:
	@command -v xcodegen >/dev/null || (echo "xcodegen is required" >&2; exit 2)
	@command -v xcodebuild >/dev/null || (echo "xcodebuild is required" >&2; exit 2)
	cd ios && xcodegen generate && xcodebuild -project LocalLingo.xcodeproj -scheme 'Speak Duet' -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' test

ios-private-beta-compile:
	@command -v xcodegen >/dev/null || (echo "xcodegen is required" >&2; exit 2)
	@command -v xcodebuild >/dev/null || (echo "Xcode 26.4 or newer is required" >&2; exit 2)
	cd ios && xcodegen generate && xcodebuild -project LocalLingo.xcodeproj -scheme 'LocalLingo Private Beta' -configuration PrivateBeta -destination 'generic/platform=iOS' -derivedDataPath /tmp/locallingo-private-beta-derived-data CODE_SIGNING_ALLOWED=NO build

ios-release-compile:
	@command -v xcodegen >/dev/null || (echo "xcodegen is required" >&2; exit 2)
	@command -v xcodebuild >/dev/null || (echo "Xcode 26.4 or newer is required" >&2; exit 2)
	cd ios && xcodegen generate && xcodebuild -project LocalLingo.xcodeproj -scheme LocalLingo -configuration Release -destination 'generic/platform=iOS' -derivedDataPath /tmp/locallingo-derived-data CODE_SIGNING_ALLOWED=NO build

ios-testflight-compile:
	@command -v xcodegen >/dev/null || (echo "xcodegen is required" >&2; exit 2)
	@command -v xcodebuild >/dev/null || (echo "Xcode 26.4 or newer is required" >&2; exit 2)
	cd ios && xcodegen generate && xcodebuild -project LocalLingo.xcodeproj -scheme LocalLingo -configuration TestFlight -destination 'generic/platform=iOS' -derivedDataPath /tmp/locallingo-testflight-derived-data CODE_SIGNING_ALLOWED=NO build

test-integration: test-fast infra-validate ios-test

release-template:
	@test -n "$(OUTPUT)" || (echo "OUTPUT=/secure/path/release-evidence.json is required" >&2; exit 2)
	$(MAKE) -C evaluation release-template OUTPUT="$(OUTPUT)"

ios-resolved-config-from-environment:
	@test -n "$(ARTIFACT_ROOT)" -a -n "$(IOS_RESOLVED_CONFIG)" -a -n "$(CONFIGURATION)" || (echo "ARTIFACT_ROOT, IOS_RESOLVED_CONFIG, and CONFIGURATION=Release|TestFlight are required" >&2; exit 2)
	@test -d "$(ARTIFACT_ROOT)" || (echo "ARTIFACT_ROOT must already exist" >&2; exit 2)
	$(PYTHON) scripts/validate-ios-release-config.py --build-environment --configuration "$(CONFIGURATION)" --emit-resolved-config "$(ARTIFACT_ROOT)/$(IOS_RESOLVED_CONFIG)"

release-preflight:
	@test -n "$(RELEASE_MANIFEST)" -a -n "$(DEVICE_REGISTRY)" -a -n "$(TERRAFORM_PLAN)" -a -n "$(TESTFLIGHT_TERRAFORM_PLAN)" -a -n "$(TERRAFORM_BACKEND_CONFIG)" -a -n "$(TESTFLIGHT_TERRAFORM_BACKEND_CONFIG)" -a -n "$(TERRAFORM_VARIABLES)" -a -n "$(TESTFLIGHT_TERRAFORM_VARIABLES)" -a -n "$(TERRAFORM_PLAN_PROVENANCE)" -a -n "$(TESTFLIGHT_PLAN_PROVENANCE)" -a -n "$(BACKEND_BUILD_METADATA)" -a -n "$(BACKEND_BASE_IMAGE)" || (echo "RELEASE_MANIFEST, DEVICE_REGISTRY, production/TestFlight plans/provenance/backends/variables, BACKEND_BUILD_METADATA, and BACKEND_BASE_IMAGE are required" >&2; exit 2)
	bash scripts/validate-repository.sh
	$(MAKE) infra-validate
	$(MAKE) -C evaluation release-preflight \
		RELEASE_MANIFEST="$(RELEASE_MANIFEST)" \
		ARTIFACT_ROOT="$(ARTIFACT_ROOT)" \
		DEVICE_REGISTRY="$(DEVICE_REGISTRY)" \
		IOS_RESOLVED_CONFIG="$(IOS_RESOLVED_CONFIG)" \
		TESTFLIGHT_IOS_RESOLVED_CONFIG="$(TESTFLIGHT_IOS_RESOLVED_CONFIG)" \
		TERRAFORM_PLAN="$(TERRAFORM_PLAN)" \
		TESTFLIGHT_TERRAFORM_PLAN="$(TESTFLIGHT_TERRAFORM_PLAN)" \
		TERRAFORM_BACKEND_CONFIG="$(TERRAFORM_BACKEND_CONFIG)" \
		TESTFLIGHT_TERRAFORM_BACKEND_CONFIG="$(TESTFLIGHT_TERRAFORM_BACKEND_CONFIG)" \
		TERRAFORM_VARIABLES="$(TERRAFORM_VARIABLES)" \
		TESTFLIGHT_TERRAFORM_VARIABLES="$(TESTFLIGHT_TERRAFORM_VARIABLES)" \
		TERRAFORM_PLAN_PROVENANCE="$(TERRAFORM_PLAN_PROVENANCE)" \
		TESTFLIGHT_PLAN_PROVENANCE="$(TESTFLIGHT_PLAN_PROVENANCE)" \
		BACKEND_BUILD_METADATA="$(BACKEND_BUILD_METADATA)" \
		BACKEND_BASE_IMAGE="$(BACKEND_BASE_IMAGE)"

release-check: release-preflight
	@echo "release-check is a compatibility alias; success is preflight only and never approval"

release-finalize:
	$(MAKE) -C evaluation trusted-release \
		ARTIFACT_ROOT="$(ARTIFACT_ROOT)" \
		DECISION="$(DECISION)" \
		DECISION_BUNDLE="$(DECISION_BUNDLE)" \
		TRUST_POLICY="$(TRUST_POLICY)" \
		TRUST_POLICY_SHA256="$(TRUST_POLICY_SHA256)"
