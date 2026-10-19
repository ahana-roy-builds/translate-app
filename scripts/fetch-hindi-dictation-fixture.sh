#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_path="$repository_root/ios/Tests/Resources/hindi-dictation-fixture.wav"
dataset_revision='70bb2e84b976b7e960aa89f1c648e09c59f894dd'
row_url="https://datasets-server.huggingface.co/rows?dataset=google%2Ffleurs&config=hi_in&split=validation&offset=156&length=1&revision=$dataset_revision"
expected_source_sha256='9e34c3ddde1a12e9b4925ac1f8621018a4ab21096c870c18b55fab06f132e552'
expected_transcript='पुलिस ने कहा कि शव लगभग एक दिन पुराना है'

for command in curl jq shasum; do
  command -v "$command" >/dev/null || {
    printf 'Required command is unavailable: %s\n' "$command" >&2
    exit 1
  }
done

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/locallingo-hindi-fixture.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT
row_json="$temporary_directory/row.json"
source_audio="$temporary_directory/source.wav"

curl --fail --location --silent --show-error "$row_url" --output "$row_json"

jq --exit-status \
  --arg transcript "$expected_transcript" \
  '.rows | length == 1
    and .[0].row.id == 1656
    and .[0].row.num_samples == 57600
    and .[0].row.language == "Hindi"
    and .[0].row.transcription == $transcript
    and (.[0].row.path | endswith("/4006648279216781989.wav"))
    and (.[0].row.audio[0].src | startswith("https://"))' \
  "$row_json" >/dev/null

audio_url="$(jq --raw-output '.rows[0].row.audio[0].src' "$row_json")"
curl --fail --location --silent --show-error "$audio_url" --output "$source_audio"

actual_source_sha256="$(shasum -a 256 "$source_audio" | awk '{print $1}')"
if [[ "$actual_source_sha256" != "$expected_source_sha256" ]]; then
  printf 'FLEURS fixture hash mismatch. Expected %s, received %s.\n' \
    "$expected_source_sha256" "$actual_source_sha256" >&2
  exit 1
fi

mkdir -p "$(dirname "$fixture_path")"
install -m 0644 "$source_audio" "$fixture_path"

printf 'Installed local Hindi Dictation fixture: %s\n' "$fixture_path"
printf 'SHA-256: %s\n' "$actual_source_sha256"
printf 'Expected text: %s\n' "$expected_transcript"
printf 'Regenerate the Xcode project before building the fixture test: cd ios && xcodegen generate\n'
