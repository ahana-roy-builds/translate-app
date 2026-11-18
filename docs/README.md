# Product and launch documentation

These documents define the initial operating contract for a local-first travel conversation translator:

- [Speak Duet accounts and commerce](speak-duet-setup.md): the new app name,
  default-language onboarding, device-local free access, monthly subscription,
  Firebase authentication, testing, and remaining external configuration.
- [Speak Duet TestFlight tracker](speak-duet-testflight.md): completed setup,
  work in progress, remaining release checks, SDK disclosures, and beta copy.
- [Speak Duet support and privacy site](../distribution/speak-duet/): local
  page drafts for the account-enabled app, with publication steps.

- [Product and architecture decision record](decision-log.md): options considered, accepted/deferred choices, rationale, tradeoffs, open questions, and revisit triggers.
- [Architecture](architecture.md): pipeline, component boundaries, offline packs, and failure behavior.
- [Privacy](privacy.md): data inventory, default processing, retention, disclosures, and user controls.
- [Private Beta privacy policy source](../distribution/locallingo-privacy/): standalone public-site payload for the offline-only TestFlight build.
- [Private Beta App Store Connect package](private-beta-app-store-connect.md): app record values, TestFlight copy, review notes, privacy answers, and submission assumptions.
- [Threat model](threat-model.md): assets, trust boundaries, attack cases, mitigations, and residual risks.
- [Platform prerequisites](platform-prerequisites.md): Apple, App Store Connect, Google Cloud, and release-account setup.
- [Hindi offline support research](hindi-offline-support-research.md): evidence, candidate ASR paths, evaluation sequence, and decision gates.
- [Hindi capability probe](hindi-capability-probe.md): read-only physical-iPhone inventory for Apple speech, translation, and synthesis support.
- [Hindi DictationTranscriber research spike](hindi-dictation-research-spike.md): guarded Apple-model inventory, install, and deterministic offline-inference procedure.
- [Evaluation and acceptance](evaluation-and-acceptance.md): corpus design and measurable quality gates.
- [Release trust and evidence flow](release-trust.md): unsigned preflight, GitHub OIDC/Sigstore roles, cross-bindings, and final approval.
- [Launch checklist](launch-checklist.md): evidence required before TestFlight and production release.
- [Experimental local LLM](experimental-local-llm.md): internal-only MLX/Qwen artifact and promotion boundary.

The production path is model-agnostic. Every model, voice, runtime, and
evaluation set still needs a versioned bill of materials with its own license
review; an experiment is not a production dependency merely because it has a
source scaffold.
