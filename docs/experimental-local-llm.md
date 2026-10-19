# Internal MLX/Qwen translation seam

## What exists

The repository contains a research-only Swift seam, not a runnable local-LLM
feature. `ExperimentalLocalLLM.swift` defines:

- metadata for one allowlisted Qwen artifact;
- streamed SHA-256/size and Ed25519 manifest verification for an artifact that
  is already present on disk;
- memory, free-space, and thermal eligibility checks; and
- an injectable translation closure with deterministic settings and basic
  output bounds.

No MLX package, model, tokenizer, downloader, prompt adapter, activation store,
or user-facing engine selection is included in the production Xcode project.
Setting `LOCAL_LLM_EXPERIMENT=1` alone therefore does not create a runnable
experiment.

## Explicit internal-build boundary

Release, TestFlight, and Staging set `LOCAL_LLM_EXPERIMENT=0`; their build preflight also
rejects the `LOCAL_LLM_EXPERIMENT` Swift compilation condition. An internal
Debug workspace may copy
`ios/Config/InternalExperiment.local.xcconfig.example` to the ignored
`InternalExperiment.local.xcconfig`. That overlay explicitly adds the Swift
condition which compiles the guarded seam. A separate reviewed internal project
must still pin and add MLX Swift/MLX Swift LM and supply the adapter.

Production must continue to build and run when the overlay, dependency, model,
manifest, and artifact host are absent. Release evidence independently binds
the resolved build settings and requires `local_llm_experiment: false`.

## Work required before an internal runnable experiment

Do not describe the following as implemented. Before an internal build can load
a model, it needs reviewed implementations and tests for:

- exact MLX Swift/MLX Swift LM commits and package lock;
- an organization-hosted, immutable artifact and manifest with exact model,
  tokenizer, quantization, license, size, and digest metadata;
- resumable staging, free-space reservation, signature/digest verification,
  smoke loading, atomic activation, last-known-good rollback, and deletion of a
  failed staging artifact;
- a pinned translation-only prompt/tokenizer with actual 256-input/384-output
  token enforcement, language/confidence/entity/negation/allergy checks, and no
  automatic speech for uncertain output;
- cancellation on backgrounding, memory pressure, thermal escalation, and app
  incompatibility; and
- physical-device quality, latency, memory, thermal, energy, storage, long-run,
  safety, license, privacy, and rollback evidence.

The app must never download directly from Hugging Face or contain publishing
credentials. Failing any gate keeps the research engine unavailable and never
routes a Local Only turn online.
