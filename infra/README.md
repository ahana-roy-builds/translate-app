# Google Cloud deployment

Infrastructure is split into two independently stateful stacks so long-lived
security resources are not coupled to ordinary backend releases.

- `bootstrap/` enables APIs and creates immutable-tag Artifact Registry with
  inherited vulnerability scanning, the runtime service
  account, regional Firestore security state with TTL policies, and Secret
  Manager containers.
- `service/` deploys an immutable Cloud Run image behind an external HTTPS load
  balancer, Cloud Armor, monitoring, finite log retention, and a project budget.

Use separate projects, state backends, registries, services, runtime identities,
DNS names, secrets, and notification channels for development, staging,
TestFlight, and production.

The service stack is intentionally deployable only as `staging`, `testflight`,
or `production`. Staging uses the same real App Attest, StoreKit, Firestore,
session, replay, and quota code with Apple's development AAGUID and StoreKit
Sandbox. The fake development entry point is localhost-only and Terraform can
never deploy it. TestFlight is a separately billed/project/state/DNS/bundle
environment: it uses production App Attest (as required by TestFlight-signed
apps) with StoreKit Sandbox and live App Store Server API status refresh. Start
from `service/staging.tfvars.example`, `service/testflight.tfvars.example`, or
`service/terraform.tfvars.example` respectively.

## Security boundary

Cloud Run accepts unauthenticated IAM invocation because an iPhone cannot carry
a Google identity, but its ingress is restricted to internal traffic and the
external load balancer. The default `run.app` URL therefore cannot bypass Cloud
Armor. Application access still requires a short-lived session and a fresh App
Attest assertion before provider work. Firestore transactions provide shared
replay, counter, device-binding, and quota state; Cloud Armor is only the first
IP-based cost guard. Registration routes have a lower abuse threshold, while
the general API uses a higher throttle suitable for hotel/shared-NAT egress;
attested installation and entitlement quotas remain authoritative.

Online Quality sends canonical WAV audio through Cloud Run to regional Google
Speech-to-Text and sends the resulting source text to regional Cloud
Translation. Synthesis always runs on the iPhone. Terraform does not enable the
Text-to-Speech API.

No Terraform variable or state file should contain a secret value. Bootstrap
creates only secret metadata. Operators add versions through an audited secret
workflow; the service stack requires an explicit positive version number and
never accepts `latest`.

`APPLE_APP_ATTEST_ROOT_CA_PEM` contains the reviewed Apple App Attest root as
PEM or base64-encoded PEM. `APPLE_STOREKIT_ROOT_CA_PEMS` contains the reviewed
StoreKit/App Store root PEMs as comma-separated base64-encoded PEM values.
`APPLE_IAP_SIGNING_KEY_P8` contains the App Store Server API In-App Purchase key;
its key and issuer IDs are explicit non-secret environment values. Only the
runtime service account receives numeric-version access to these three secret
containers. The P8 key is private credential material and must be created,
rotated, and audited outside Terraform.

## Deployment

Both stacks declare a partial GCS backend and deliberately cannot initialize a
default local backend. Copy `infra/backend.hcl.example` outside the repository,
use a versioned/encrypted bucket and a distinct environment/stack prefix, and
authenticate with short-lived ADC/workload identity. The planning wrapper
accepts only literal `bucket` and `prefix`, initializes with `lockfile=readonly`,
and inspects Terraform's local backend metadata to prove the selected backend is
GCS before planning.

Terraform is pinned to 1.15.7 and the Google provider to 7.34.0. Both committed
multi-platform `.terraform.lock.hcl` files were generated from HashiCorp-signed
packages. CI uses them read-only. Update either version and regenerate/review
both locks as an explicit dependency change; never hand-author lock hashes.
The service provider uses the environment project for quota/billing override so
user ADC can manage the budget resource; the deployment principal therefore
needs `serviceusage.services.use` in that project in addition to narrowly scoped
resource-management roles.

```sh
cp infra/bootstrap/terraform.tfvars.example /secure/path/bootstrap.tfvars
cp infra/backend.hcl.example /secure/path/bootstrap-backend.hcl
make infra-plan STACK=bootstrap BACKEND_CONFIG=/secure/path/bootstrap-backend.hcl TFVARS=/secure/path/bootstrap.tfvars TFPLAN=/secure/path/bootstrap.tfplan
# Record the "Trusted plan SHA-256" line from protected planner output in the
# approval record before authorizing apply.
make infra-apply STACK=bootstrap BACKEND_CONFIG=/secure/path/bootstrap-backend.hcl TFVARS=/secure/path/bootstrap.tfvars TFPLAN=/secure/path/bootstrap.tfplan EXPECTED_TFPLAN_SHA256=REVIEWED_PLANNER_OUTPUT
```

Populate initial Secret Manager versions outside Terraform. Never put their
contents on a command line. Record each numeric version and pass it to the
service stack.

```sh
cp infra/service/terraform.tfvars.example /secure/path/service.tfvars
cp infra/backend.hcl.example /secure/path/service-backend.hcl
make infra-plan STACK=service BACKEND_CONFIG=/secure/path/service-backend.hcl TFVARS=/secure/path/service.tfvars TFPLAN=/secure/path/service.tfplan
# Use the digest captured from this plan invocation's protected stdout.
make infra-apply STACK=service BACKEND_CONFIG=/secure/path/service-backend.hcl TFVARS=/secure/path/service.tfvars TFPLAN=/secure/path/service.tfplan EXPECTED_TFPLAN_SHA256=REVIEWED_PLANNER_OUTPUT
```

The plan wrapper snapshots the clean, tracked Terraform configuration, provider
lock, backend file, and exact variables into a private per-invocation directory;
Terraform never reads the mutable source tree while planning. It verifies that
the initialized GCS bucket/prefix use the normal Google endpoint and exactly
match the reviewed backend file. It also writes
`/secure/path/service.tfplan.provenance.json`, binding the plan to the Git commit,
Terraform/configuration/variable/backend digests, project, and runtime
environment.

Before publishing either artifact, the planner prints `Trusted plan SHA-256`.
Capture that line through protected job output or an approval system which an
artifact-root writer cannot alter. Never derive `EXPECTED_TFPLAN_SHA256` from
the adjacent provenance file and never re-hash the plan after it enters the
mutable artifact root; either would collapse the independent handoff check.
Preserve the plan, provenance, exact variables file, backend configuration, and
captured digest. Always apply with `make infra-apply`: it requires the same live
variables/backend inputs and the independently captured digest, snapshots all
inputs again, verifies the saved plan and provenance, rejects incomplete or
destructive plans, reinitializes against the exact GCS backend, and applies only
the private plan snapshot. A bare `terraform apply` from the shared source
directory is not part of the reviewed workflow.
Production and TestFlight must use different projects, services, runtime service
accounts, registries, domains, secrets, plans, GCS bucket/prefix pairs, and
deployment receipts; their iOS bundles/products are distinct as well. The
release gate verifies those differences.

Create the `api_domain` A record using the `api_ip_address` output. A Google
managed certificate becomes active only after DNS resolves to that address.
Verify `/readyz` through the public hostname and confirm the `cloud_run_uri`
cannot be invoked directly before enabling the iOS Release configuration.

## Fail-closed production checks

Production requires:

- a container reference pinned by a complete `sha256` digest;
- one minimum and no more than three maximum instances, 1 CPU, 1 GiB memory,
  concurrency eight, and a 20-second Cloud Run timeout;
- production App Attest and runtime modes, with no development bypass in the deployed entry point;
- an immutable `RELEASE_BUILD_ID`, derived `BACKEND_OCI_DIGEST`, and Cloud Run-injected `K_REVISION` returned as diagnostic runtime identity;
- a MODERN TLS policy with TLS 1.2 as the minimum, an edge no-query rule, and
  dropping query-bearing request logs before default-bucket storage;
- exact Speech `us` and Translation/Cloud Run/Secret Manager/Firestore
  `us-central1` locations;
- pinned numeric secret versions, deletion protection, at least one alert
  channel, and a billing-account budget;
- a non-placeholder domain, Apple IDs, App Store API IDs, app-build allowlist,
  and product IDs matching the resolved iOS release contract.

The load balancer samples allowlisted request metadata, while application logs
remain structured and content-free. Query-bearing request logs are excluded
from storage after a pre-storage rejection metric is counted; HTTP redirects
also strip queries. The default bucket retains other logs for 30 days.
Monitoring covers readiness, errors, tail latency, memory, instance-cap
saturation, attestation/session/entitlement/quota rejections, edge query abuse,
unexpected secret access, IAM changes, and spend. Production release evidence
must still prove alert delivery and central-security routing without including
conversation content.

## Release evidence

Save reviewed plans, policy scans, SBOM/provenance, image vulnerability results,
direct-URL denial, Cloud Armor behavior, regional endpoint traces, alerts, and
budget tests outside this repository. Reference their immutable digests in the
release-evidence manifest consumed by `make release-preflight`. That unsigned
preflight never approves a release. An authenticated infrastructure producer
must plan/apply and query the control plane. The protected infrastructure
attestation wrapper then signs its environment policy, Terraform plan, and
deployment receipt; it does not perform the deployment or query itself. Those
predicates
bind the control-plane-observed revision to the OCI digest, runtime service
account unique ID, secrets, load balancer, and content-free availability check;
only `make release-finalize` may accept the resulting signed v2 decision.

See the canonical [decision log](../docs/decision-log.md) and
[release-trust contract](../docs/release-trust.md) before changing environment
boundaries or treating infrastructure output as release evidence.
