#!/usr/bin/env python3
"""Validate traveler-translation JSONL corpora without third-party packages."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path, PurePosixPath
from typing import Any, Iterable

from strict_json import loads as strict_json_loads


ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{2,127}$")
LANGUAGE_RE = re.compile(r"^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$")
TAG_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,63}$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")

CASE_KEYS = {
    "id",
    "source_language",
    "target_language",
    "source",
    "references",
    "domain",
    "tags",
    "risk",
    "critical_checks",
    "audio",
    "provenance",
    "notes",
}
CASE_REQUIRED = CASE_KEYS - {"audio", "notes"}
DOMAINS = {
    "transit",
    "lodging",
    "dining",
    "directions",
    "shopping",
    "payments",
    "health",
    "emergency",
    "social",
    "logistics",
}
RISKS = {"standard", "elevated", "critical"}
PROVENANCE_KINDS = {
    "synthetic-original",
    "commissioned",
    "consented",
    "public-domain",
}
AUDIO_ENVIRONMENTS = {
    "quiet",
    "street",
    "station",
    "vehicle",
    "restaurant",
    "lobby",
    "other",
}


def _error(errors: list[str], source: str, line: int, field: str, message: str) -> None:
    errors.append(f"{source}:{line}: {field}: {message}")


def _nonempty_string(
    value: Any,
    *,
    maximum: int,
    errors: list[str],
    source: str,
    line: int,
    field: str,
) -> bool:
    if not isinstance(value, str):
        _error(errors, source, line, field, "must be a string")
        return False
    if not value.strip():
        _error(errors, source, line, field, "must not be empty")
        return False
    if len(value) > maximum:
        _error(errors, source, line, field, f"must be at most {maximum} characters")
        return False
    return True


def _unknown_and_missing(
    value: dict[str, Any],
    *,
    allowed: set[str],
    required: set[str],
    errors: list[str],
    source: str,
    line: int,
    field: str,
) -> None:
    unknown = sorted(set(value) - allowed)
    missing = sorted(required - set(value))
    if unknown:
        _error(errors, source, line, field, f"unknown fields: {', '.join(unknown)}")
    if missing:
        _error(errors, source, line, field, f"missing fields: {', '.join(missing)}")


def _validate_critical_checks(
    value: Any, errors: list[str], source: str, line: int
) -> int:
    if not isinstance(value, list):
        _error(errors, source, line, "critical_checks", "must be an array")
        return 0

    seen_names: set[str] = set()
    required_count = 0
    allowed = {"name", "accepted", "required", "description"}
    required = {"name", "accepted", "required"}
    for index, check in enumerate(value):
        field = f"critical_checks[{index}]"
        if not isinstance(check, dict):
            _error(errors, source, line, field, "must be an object")
            continue
        _unknown_and_missing(
            check,
            allowed=allowed,
            required=required,
            errors=errors,
            source=source,
            line=line,
            field=field,
        )

        name = check.get("name")
        if _nonempty_string(
            name,
            maximum=64,
            errors=errors,
            source=source,
            line=line,
            field=f"{field}.name",
        ):
            if not TAG_RE.fullmatch(name):
                _error(errors, source, line, f"{field}.name", "has an invalid format")
            if name in seen_names:
                _error(errors, source, line, f"{field}.name", "must be unique in the case")
            seen_names.add(name)

        accepted = check.get("accepted")
        if not isinstance(accepted, list) or not accepted:
            _error(errors, source, line, f"{field}.accepted", "must be a non-empty array")
        else:
            accepted_values: list[str] = []
            for accepted_index, phrase in enumerate(accepted):
                if _nonempty_string(
                    phrase,
                    maximum=200,
                    errors=errors,
                    source=source,
                    line=line,
                    field=f"{field}.accepted[{accepted_index}]",
                ):
                    accepted_values.append(phrase)
            if len(accepted_values) != len(set(accepted_values)):
                _error(errors, source, line, f"{field}.accepted", "must not contain duplicates")

        is_required = check.get("required")
        if not isinstance(is_required, bool):
            _error(errors, source, line, f"{field}.required", "must be a boolean")
        elif is_required:
            required_count += 1

        if "description" in check:
            _nonempty_string(
                check["description"],
                maximum=500,
                errors=errors,
                source=source,
                line=line,
                field=f"{field}.description",
            )

    return required_count


def _validate_provenance(value: Any, errors: list[str], source: str, line: int) -> None:
    field = "provenance"
    if not isinstance(value, dict):
        _error(errors, source, line, field, "must be an object")
        return
    _unknown_and_missing(
        value,
        allowed={"kind", "author", "license", "source_record"},
        required={"kind", "author", "license"},
        errors=errors,
        source=source,
        line=line,
        field=field,
    )
    if value.get("kind") not in PROVENANCE_KINDS:
        _error(errors, source, line, f"{field}.kind", "is not an allowed provenance kind")
    for name, maximum in (("author", 200), ("license", 100)):
        _nonempty_string(
            value.get(name),
            maximum=maximum,
            errors=errors,
            source=source,
            line=line,
            field=f"{field}.{name}",
        )
    if "source_record" in value:
        _nonempty_string(
            value["source_record"],
            maximum=500,
            errors=errors,
            source=source,
            line=line,
            field=f"{field}.source_record",
        )


def _validate_audio(value: Any, errors: list[str], source: str, line: int) -> None:
    field = "audio"
    if not isinstance(value, dict):
        _error(errors, source, line, field, "must be an object")
        return
    allowed = {"path", "sha256", "speaker_id", "duration_ms", "environment", "consent_record", "kind"}
    _unknown_and_missing(
        value,
        allowed=allowed,
        required=allowed,
        errors=errors,
        source=source,
        line=line,
        field=field,
    )

    path = value.get("path")
    if _nonempty_string(
        path,
        maximum=500,
        errors=errors,
        source=source,
        line=line,
        field=f"{field}.path",
    ):
        parsed = PurePosixPath(path)
        if parsed.is_absolute() or ".." in parsed.parts or "\\" in path:
            _error(errors, source, line, f"{field}.path", "must be a safe relative POSIX path")

    sha256 = value.get("sha256")
    if not isinstance(sha256, str) or not SHA256_RE.fullmatch(sha256):
        _error(errors, source, line, f"{field}.sha256", "must be 64 lowercase hexadecimal characters")

    speaker_id = value.get("speaker_id")
    if not isinstance(speaker_id, str) or not re.fullmatch(r"^[a-zA-Z0-9._-]{1,64}$", speaker_id):
        _error(errors, source, line, f"{field}.speaker_id", "has an invalid format")

    duration_ms = value.get("duration_ms")
    if (
        isinstance(duration_ms, bool)
        or not isinstance(duration_ms, int)
        or not 1 <= duration_ms <= 120000
    ):
        _error(errors, source, line, f"{field}.duration_ms", "must be an integer from 1 to 120000")

    if value.get("environment") not in AUDIO_ENVIRONMENTS:
        _error(errors, source, line, f"{field}.environment", "is not an allowed environment")

    if value.get("kind") not in {"speech", "silence", "noise", "wrong_language"}:
        _error(errors, source, line, f"{field}.kind", "must be speech, silence, noise, or wrong_language")

    _nonempty_string(
        value.get("consent_record"),
        maximum=200,
        errors=errors,
        source=source,
        line=line,
        field=f"{field}.consent_record",
    )


def validate_case(record: Any, source: str, line: int, errors: list[str]) -> None:
    if not isinstance(record, dict):
        _error(errors, source, line, "$", "record must be a JSON object")
        return
    _unknown_and_missing(
        record,
        allowed=CASE_KEYS,
        required=CASE_REQUIRED,
        errors=errors,
        source=source,
        line=line,
        field="$",
    )

    case_id = record.get("id")
    if not isinstance(case_id, str) or not ID_RE.fullmatch(case_id):
        _error(errors, source, line, "id", "has an invalid format")

    languages: dict[str, str] = {}
    for field in ("source_language", "target_language"):
        value = record.get(field)
        if not isinstance(value, str) or not LANGUAGE_RE.fullmatch(value):
            _error(errors, source, line, field, "must be a supported BCP-47-style language tag")
        else:
            languages[field] = value
    if languages.get("source_language") == languages.get("target_language"):
        _error(errors, source, line, "target_language", "must differ from source_language")

    _nonempty_string(
        record.get("source"),
        maximum=1000,
        errors=errors,
        source=source,
        line=line,
        field="source",
    )

    references = record.get("references")
    if not isinstance(references, list) or not references:
        _error(errors, source, line, "references", "must be a non-empty array")
    else:
        valid_references: list[str] = []
        for index, reference in enumerate(references):
            if _nonempty_string(
                reference,
                maximum=1000,
                errors=errors,
                source=source,
                line=line,
                field=f"references[{index}]",
            ):
                valid_references.append(reference)
        if len(valid_references) != len(set(valid_references)):
            _error(errors, source, line, "references", "must not contain duplicates")

    if record.get("domain") not in DOMAINS:
        _error(errors, source, line, "domain", "is not an allowed travel domain")

    tags = record.get("tags")
    if not isinstance(tags, list):
        _error(errors, source, line, "tags", "must be an array")
    else:
        valid_tags: list[str] = []
        for index, tag in enumerate(tags):
            if not isinstance(tag, str) or not TAG_RE.fullmatch(tag):
                _error(errors, source, line, f"tags[{index}]", "has an invalid format")
            else:
                valid_tags.append(tag)
        if len(valid_tags) != len(set(valid_tags)):
            _error(errors, source, line, "tags", "must not contain duplicates")

    risk = record.get("risk")
    if risk not in RISKS:
        _error(errors, source, line, "risk", "is not an allowed risk level")

    required_check_count = _validate_critical_checks(
        record.get("critical_checks"), errors, source, line
    )
    if risk == "critical" and required_check_count == 0:
        _error(errors, source, line, "critical_checks", "critical cases need at least one required check")

    _validate_provenance(record.get("provenance"), errors, source, line)
    if "audio" in record:
        _validate_audio(record["audio"], errors, source, line)
    if "notes" in record:
        _nonempty_string(
            record["notes"],
            maximum=2000,
            errors=errors,
            source=source,
            line=line,
            field="notes",
        )


def load_and_validate(paths: Iterable[Path]) -> tuple[list[dict[str, Any]], list[str]]:
    records: list[dict[str, Any]] = []
    errors: list[str] = []
    seen_ids: dict[str, str] = {}

    for path in paths:
        try:
            handle = path.open("r", encoding="utf-8")
        except OSError as exc:
            errors.append(f"{path}: unable to read: {exc}")
            continue
        with handle:
            for line_number, raw_line in enumerate(handle, start=1):
                if not raw_line.strip():
                    continue
                try:
                    record = strict_json_loads(raw_line)
                except (json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
                    errors.append(f"{path}:{line_number}: invalid JSON: {exc}")
                    continue
                validate_case(record, str(path), line_number, errors)
                if isinstance(record, dict) and isinstance(record.get("id"), str):
                    case_id = record["id"]
                    location = f"{path}:{line_number}"
                    if case_id in seen_ids:
                        errors.append(
                            f"{location}: id: duplicate of {seen_ids[case_id]} ({case_id})"
                        )
                    else:
                        seen_ids[case_id] = location
                if isinstance(record, dict):
                    records.append(record)

    if not records and not errors:
        errors.append("corpus contains no JSONL records")
    return records, errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", nargs="+", type=Path, help="JSONL corpus file(s)")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    records, errors = load_and_validate(args.corpus)
    if errors:
        for message in errors:
            print(message, file=sys.stderr)
        print(f"Validation failed with {len(errors)} error(s).", file=sys.stderr)
        return 1
    print(f"Validated {len(records)} case(s) from {len(args.corpus)} file(s).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
