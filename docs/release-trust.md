# Release trust and evidence flow

This document is the operating contract for D-15 and D-19 in the
[decision record](decision-log.md). It explains how LocalLingo distinguishes a
useful local preflight from an authenticated production approval.

## Two deliberately different decisions

`make release-preflight` runs the version-1 evaluator. It safely snapshots the
explicit artifact tree, replays quality thresholds, checks the complete matrix,
compares clean Git index bytes and modes, inspects both Terraform plans and
their exact inputs, and verifies the backend build context/provenance contract.
Its successful output is evidence for a candidate, but always contains
`release_decision: false`. `make release-check` is only a compatibility alias.

`make release-finalize` verifies a stored version-2 decision and its Sigstore
bundles. It is the only command allowed to emit
`release_decision: "approved"`. A structural fixture, unsigned JSON file,
successful Xcode compile, or reviewer name in a manifest can never reach that
state.

## Independent signer roles

The digest-pinned trust policy allows predicates only from these workflow
identities:

| Signer | Predicate it alone may attest |
| --- | --- |
| Build | Evidence describing signed Release/TestFlight archives and executable identity; backend OCI provenance, SBOM, vulnerability report, and secret report |
| Corpus | Exact acceptance criteria and hidden corpus/audio/rights/tool digests |
| Device | Locked physical-device registry and individual nonce-bearing matrix runs |
| Infrastructure | Isolated environment policy, immutable Terraform plan/state evidence, and post-deploy control-plane receipt |
| Candidate | Non-approving preflight wrapper and the exact release-candidate graph |
| Quality, security, privacy, operations | Four separate approvals bound to the same candidate and preflight digests |
| Finalizer | Verification of the complete graph and issuance of the final decision |

These workflows are attestation wrappers: they validate and sign protected JSON
subjects that authenticated producer environments have already generated. They
do not build/sign iOS, build/scan/publish OCI images, run physical devices,
apply Terraform, or query a deployment. Those producer jobs and their credentials
remain launch prerequisites. The candidate workflow cannot impersonate build,
corpus, device, or infrastructure evidence. Approval roles may share reviewed
workflow code, but
each protected environment supplies its own authenticated actor; the verifier
requires four distinct numeric GitHub actor IDs. V2 currently rejects every
non-empty waiver list. A future waiver protocol needs a separately signed,
owned, scoped, and expiring predicate before this rule can change.

## Candidate bindings

The finalizer reopens every referenced artifact beneath a held directory handle
and rejects traversal, link or directory-swap races, hardlinks, mutation during
read, digest/size mismatch, duplicate or non-finite JSON, unknown fields, stale
trusted signing times, and wrong workflow or predicate types. Claimed evidence
times cannot postdate their cryptographically verified signing time. It then
cross-binds:

- tag, commit, source-tree digest, candidate ID, app version, and build number;
- the candidate ID embedded in both iOS binaries and injected into both Cloud
  Run environments;
- bundle/team/application identifiers, executable/signature/entitlement/profile
  digests, resolved build configuration, Xcode, and SDK;
- backend OCI index and runnable manifest, reviewed base material, exact inner
  BuildKit metadata, Docker context, SBOM, and passed scans;
- distinct production/TestFlight projects, state, registries, services,
  identities, domains, plans, exact inner plan provenance, secret bindings,
  canonical image names, registry manifests, and deployment receipts;
- the Cloud Run control plane's observed revision, resolved OCI digest, traffic,
  service account, and the content-free availability diagnostic;
- corpus and physical-device registry digests plus every unique direction ×
  route × device-tier × environment run.

There are exactly 96 device cells: four directions, four resolved routes, three
physical tiers, and two signed environments. Online cells require the exact
backend digest/revision/domain and an authenticated request ID. Local cells
require backend content-request fields to be null; this prevents “evidence” for
a Local Only run from silently containing an online turn.

The validation contract binds iPhone 15 Pro, iPhone 16 Pro, and iPhone 17 Pro as
release-qualification tiers. A completed and accepted registry and run matrix
would provide evidence for behavior on those physical devices; neither is a
runtime model allowlist. Any broader quality or performance claim for other iOS
26 iPhones requires corresponding physical evidence, even though the app
permits them to launch and applies capability/readiness checks before continuous
or locally resolved recording.

## GitHub and runner controls

The repository is public and release attestation wrappers use GitHub Actions OIDC with
GitHub Artifact Attestations/Sigstore bundles—no long-lived attestation private
key. The trust policy pins the immutable numeric GitHub repository and owner IDs
as well as the repository name, commit, tag, and workflow bytes, preventing a
deleted/recreated repository from inheriting trust by name. Actions are pinned
by full commit SHA. Configure protected tag rules and
separate build, corpus, device, infrastructure/deployment, four approval, and
finalizer environments. The device job must use an access-controlled physical
macOS/iPhone runner; Simulator and Debug runs are invalid physical-device
evidence.

Every helper executed by a wrapper is digest-pinned by the reviewed workflow and
run with an isolated interpreter; changing a helper therefore changes the trusted
workflow bytes. The trust-policy digest and trusted-root artifact are
release-controller inputs,
not workflow-dispatch text supplied by an arbitrary caller. Preserve every
bundle and predicate in immutable, access-controlled storage for independent
re-verification. Rotate/reissue the policy after a workflow, repository,
visibility, environment, trusted-root, or GitHub trust-semantics change.

## Runtime identity is defense in depth

`/v2/availability` labels its build identity `self-reported-diagnostic`; a
process cannot attest the image containing itself. The app nevertheless binds
the returned release ID, OCI digest, environment, and revision into every
subsequent App Attest assertion and content request, and the backend rejects a
deployment change before consuming the challenge. Production trust still comes
from the independently signed Cloud Run control-plane receipt.

## Release sequence

1. Issue one immutable candidate ID from a clean version tag.
2. In authenticated producer environments, build and sign both iOS
   configurations and one byte-identical backend OCI subject, then scan/publish
   it. Pass the resulting predicates through the protected attestation wrappers.
3. Produce isolated Terraform/state/deployment predicates and query the control
   plane after 100% traffic is on the reviewed revisions, then attest them.
4. Produce the corpus and device registry, run all 96 physical cells, and attest
   the exact bound predicates.
5. Run and attest the non-approving preflight over those exact artifacts;
   assemble and attest the candidate.
6. Collect the four digest-bound approvals after the last candidate evidence.
   Their trusted signing times must follow the candidate signing time.
7. Run the protected finalizer and preserve its decision and verification
   bundles. Any missing or mismatched input is a no-go.
