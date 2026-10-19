#!/usr/bin/env python3
"""Score translation predictions and enforce supported automated release gates."""

from __future__ import annotations

import argparse
import array
import hashlib
import itertools
import json
import math
import os
import re
import stat
import sys
import tempfile
import unicodedata
import wave
from collections import Counter, defaultdict
from pathlib import Path
from datetime import datetime, timezone
from typing import Any, Iterable

from validate_corpus import ID_RE, load_and_validate
from strict_json import loads as strict_json_loads


PREDICTION_KEYS = {
    "id",
    "prediction",
    "latency_ms",
    "model_build",
    "device",
    "processing_mode",
    "run_id",
}
PREDICTION_REQUIRED = PREDICTION_KEYS - {"run_id"}
MODES = {"local_only", "online_quality", "auto_local", "auto_online"}
RUN_IDENTITY_KEYS = {
    "schema_version", "run_id", "release_identity_sha256", "direction", "route",
    "device_tier", "deployment_environment", "app_commit", "app_version",
    "build_number", "app_bundle_id", "api_domain", "device_model_identifier",
    "device_os_version", "device_os_build", "engine_build", "generated_at",
}
SUPPORTED_GATES = {
    "min_case_count": ("case_count", "min"),
    "min_mean_chrf2": ("mean_chrf2", "min"),
    "min_mean_token_f1": ("mean_token_f1", "min"),
    "min_exact_match_rate": ("exact_match_rate", "min"),
    "min_critical_check_pass_rate": ("critical_check_pass_rate", "min"),
    "max_missing_predictions": ("missing_predictions", "max"),
    "max_extra_predictions": ("extra_predictions", "max"),
    "max_p95_latency_ms": ("latency_ms.p95", "max"),
}


def normalize(text: str) -> str:
    """NFKC/casefold text and replace punctuation/symbol runs with spaces."""
    normalized = unicodedata.normalize("NFKC", text).casefold()
    characters = []
    for character in normalized:
        category = unicodedata.category(character)
        characters.append(character if category[0] in {"L", "N", "M"} else " ")
    return " ".join("".join(characters).split())


def token_f1(hypothesis: str, reference: str) -> float:
    hypothesis_tokens = normalize(hypothesis).split()
    reference_tokens = normalize(reference).split()
    if not hypothesis_tokens and not reference_tokens:
        return 1.0
    if not hypothesis_tokens or not reference_tokens:
        return 0.0
    hypothesis_counts = Counter(hypothesis_tokens)
    reference_counts = Counter(reference_tokens)
    overlap = sum((hypothesis_counts & reference_counts).values())
    precision = overlap / len(hypothesis_tokens)
    recall = overlap / len(reference_tokens)
    return 0.0 if precision + recall == 0 else 2 * precision * recall / (precision + recall)


def _character_ngrams(text: str, order: int) -> Counter[str]:
    compact = normalize(text).replace(" ", "")
    if len(compact) < order:
        return Counter()
    return Counter(compact[index : index + order] for index in range(len(compact) - order + 1))


def chrf2(hypothesis: str, reference: str, maximum_order: int = 6) -> float:
    """Whitespace-independent macro chrF with character orders 1..6 and beta=2."""
    beta_squared = 4.0
    order_scores: list[float] = []
    for order in range(1, maximum_order + 1):
        hypothesis_counts = _character_ngrams(hypothesis, order)
        reference_counts = _character_ngrams(reference, order)
        if not hypothesis_counts and not reference_counts:
            continue
        if not hypothesis_counts or not reference_counts:
            order_scores.append(0.0)
            continue
        overlap = sum((hypothesis_counts & reference_counts).values())
        precision = overlap / sum(hypothesis_counts.values())
        recall = overlap / sum(reference_counts.values())
        denominator = beta_squared * precision + recall
        order_scores.append(
            0.0
            if denominator == 0
            else (1 + beta_squared) * precision * recall / denominator
        )
    return sum(order_scores) / len(order_scores) if order_scores else 1.0


def contains_phrase(prediction: str, phrase: str) -> bool:
    prediction_normalized = normalize(prediction)
    phrase_normalized = normalize(phrase)
    if not phrase_normalized:
        return False
    # Word-boundary padding works for whitespace-delimited scripts. Japanese,
    # Chinese, Thai, and similar scripts may place a required phrase directly
    # beside other characters, so compare compact normalized strings there.
    unsegmented_ranges = (
        ("\u0e00", "\u0e7f"),  # Thai
        ("\u3040", "\u30ff"),  # Hiragana and Katakana
        ("\u3400", "\u9fff"),  # CJK ideographs
        ("\uac00", "\ud7af"),  # Hangul syllables
    )
    if any(lower <= character <= upper for character in phrase for lower, upper in unsegmented_ranges):
        return phrase_normalized.replace(" ", "") in prediction_normalized.replace(" ", "")
    return f" {phrase_normalized} " in f" {prediction_normalized} "


def percentile(values: Iterable[float], quantile: float) -> float | None:
    ordered = sorted(values)
    if not ordered:
        return None
    if len(ordered) == 1:
        return ordered[0]
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    fraction = position - lower
    return ordered[lower] * (1 - fraction) + ordered[upper] * fraction


def rounded(value: float | None) -> float | None:
    return None if value is None else round(value, 6)


def load_predictions(path: Path) -> tuple[list[dict[str, Any]], list[str]]:
    predictions: list[dict[str, Any]] = []
    errors: list[str] = []
    seen: dict[str, int] = {}
    try:
        handle = path.open("r", encoding="utf-8")
    except OSError as exc:
        return [], [f"{path}: unable to read: {exc}"]

    with handle:
        for line_number, raw_line in enumerate(handle, start=1):
            if not raw_line.strip():
                continue
            try:
                record = strict_json_loads(raw_line)
            except (json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
                errors.append(f"{path}:{line_number}: invalid JSON: {exc}")
                continue
            prefix = f"{path}:{line_number}"
            if not isinstance(record, dict):
                errors.append(f"{prefix}: record must be an object")
                continue
            unknown = sorted(set(record) - PREDICTION_KEYS)
            missing = sorted(PREDICTION_REQUIRED - set(record))
            if unknown:
                errors.append(f"{prefix}: unknown fields: {', '.join(unknown)}")
            if missing:
                errors.append(f"{prefix}: missing fields: {', '.join(missing)}")

            prediction_id = record.get("id")
            if not isinstance(prediction_id, str) or not ID_RE.fullmatch(prediction_id):
                errors.append(f"{prefix}: id has an invalid format")
            elif prediction_id in seen:
                errors.append(
                    f"{prefix}: duplicate id {prediction_id}; first seen on line {seen[prediction_id]}"
                )
            else:
                seen[prediction_id] = line_number

            prediction_text = record.get("prediction")
            if (
                not isinstance(prediction_text, str)
                or not prediction_text.strip()
                or len(prediction_text) > 2000
            ):
                errors.append(f"{prefix}: prediction must be a non-empty string up to 2000 characters")

            latency = record.get("latency_ms")
            if (
                isinstance(latency, bool)
                or not isinstance(latency, (int, float))
                or not math.isfinite(latency)
                or not 0 <= latency <= 300000
            ):
                errors.append(f"{prefix}: latency_ms must be a finite number from 0 to 300000")

            for field in ("model_build", "device"):
                value = record.get(field)
                if not isinstance(value, str) or not value.strip() or len(value) > 200:
                    errors.append(f"{prefix}: {field} must be a non-empty string up to 200 characters")
            if record.get("processing_mode") not in MODES:
                errors.append(f"{prefix}: processing_mode is not supported")
            if "run_id" in record and (
                not isinstance(record["run_id"], str)
                or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}", record["run_id"])
            ):
                errors.append(f"{prefix}: run_id has an invalid format")
            predictions.append(record)

    if not predictions and not errors:
        errors.append(f"{path}: prediction file contains no records")
    return predictions, errors


def summarize_rows(rows: list[dict[str, Any]]) -> dict[str, Any]:
    if not rows:
        return {
            "case_count": 0,
            "mean_chrf2": None,
            "mean_token_f1": None,
            "exact_match_rate": None,
            "critical_checks": {"passed": 0, "total": 0, "pass_rate": None},
            "latency_ms": {"p50": None, "p95": None, "maximum": None},
        }
    count = len(rows)
    critical_passed = sum(row["critical_checks_passed"] for row in rows)
    critical_total = sum(row["critical_checks_total"] for row in rows)
    latencies = [float(row["latency_ms"]) for row in rows]
    return {
        "case_count": count,
        "mean_chrf2": rounded(sum(row["chrf2"] for row in rows) / count),
        "mean_token_f1": rounded(sum(row["token_f1"] for row in rows) / count),
        "exact_match_rate": rounded(sum(row["exact_match"] for row in rows) / count),
        "critical_checks": {
            "passed": critical_passed,
            "total": critical_total,
            "pass_rate": rounded(critical_passed / critical_total) if critical_total else None,
        },
        "latency_ms": {
            "p50": rounded(percentile(latencies, 0.50)),
            "p95": rounded(percentile(latencies, 0.95)),
            "maximum": rounded(max(latencies)),
        },
    }


def score_cases(
    cases: list[dict[str, Any]], predictions: list[dict[str, Any]]
) -> tuple[list[dict[str, Any]], list[str], list[str]]:
    prediction_by_id = {record["id"]: record for record in predictions}
    case_by_id = {record["id"]: record for record in cases}
    missing = sorted(set(case_by_id) - set(prediction_by_id))
    extra = sorted(set(prediction_by_id) - set(case_by_id))
    rows: list[dict[str, Any]] = []

    for case in cases:
        prediction = prediction_by_id.get(case["id"])
        if prediction is None:
            continue
        prediction_text = prediction["prediction"]
        candidates = []
        for reference in case["references"]:
            candidates.append(
                (
                    chrf2(prediction_text, reference),
                    token_f1(prediction_text, reference),
                    reference,
                )
            )
        best_chrf2, best_token_f1, best_reference = max(
            candidates, key=lambda item: (item[0], item[1])
        )

        check_rows = []
        required_passed = 0
        required_total = 0
        for check in case["critical_checks"]:
            passed = any(contains_phrase(prediction_text, phrase) for phrase in check["accepted"])
            if check["required"]:
                required_total += 1
                required_passed += int(passed)
            check_rows.append(
                {"name": check["name"], "required": check["required"], "passed": passed}
            )

        rows.append(
            {
                "id": case["id"],
                "direction": f"{case['source_language']}->{case['target_language']}",
                "domain": case["domain"],
                "risk": case["risk"],
                "processing_mode": prediction["processing_mode"],
                "model_build": prediction["model_build"],
                "device": prediction["device"],
                "run_id": prediction.get("run_id"),
                "latency_ms": prediction["latency_ms"],
                "chrf2": rounded(best_chrf2),
                "token_f1": rounded(best_token_f1),
                "exact_match": normalize(prediction_text) == normalize(best_reference),
                "best_reference": best_reference,
                "critical_checks_passed": required_passed,
                "critical_checks_total": required_total,
                "critical_checks": check_rows,
            }
        )
    return rows, missing, extra


def grouped_summary(rows: list[dict[str, Any]], field: str) -> dict[str, Any]:
    grouped: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for row in rows:
        grouped[str(row[field])].append(row)
    return {key: summarize_rows(grouped[key]) for key in sorted(grouped)}


def _metric_value(summary: dict[str, Any], metric_path: str) -> Any:
    if metric_path == "critical_check_pass_rate":
        return summary["critical_checks"]["pass_rate"]
    value: Any = summary
    for component in metric_path.split("."):
        value = value[component]
    return value


def evaluate_gates(
    criteria_path: Path,
    profile_name: str,
    summary: dict[str, Any],
    missing_count: int,
    extra_count: int,
) -> tuple[dict[str, Any], list[str]]:
    errors: list[str] = []
    try:
        criteria = strict_json_loads(criteria_path.read_bytes())
    except (OSError, json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
        return {}, [f"Unable to read criteria {criteria_path}: {exc}"]
    profiles = criteria.get("profiles") if isinstance(criteria, dict) else None
    profile = profiles.get(profile_name) if isinstance(profiles, dict) else None
    if not isinstance(profile, dict):
        return {}, [f"Criteria profile not found: {profile_name}"]
    automated = profile.get("automated_text")
    if not isinstance(automated, dict) or not automated:
        return {}, [f"Criteria profile {profile_name} has no automated_text gates"]

    gates = []
    all_passed = True
    for gate_name, threshold in automated.items():
        definition = SUPPORTED_GATES.get(gate_name)
        if definition is None:
            gates.append(
                {
                    "name": gate_name,
                    "passed": False,
                    "actual": None,
                    "threshold": threshold,
                    "error": "unsupported gate; scorer fails closed",
                }
            )
            all_passed = False
            continue
        if isinstance(threshold, bool) or not isinstance(threshold, (int, float)):
            errors.append(f"Gate {gate_name} threshold must be numeric")
            continue
        metric_path, comparison = definition
        if metric_path == "missing_predictions":
            actual: Any = missing_count
        elif metric_path == "extra_predictions":
            actual = extra_count
        else:
            actual = _metric_value(summary, metric_path)
        passed = actual is not None and (
            actual >= threshold if comparison == "min" else actual <= threshold
        )
        all_passed = all_passed and passed
        gates.append(
            {
                "name": gate_name,
                "comparison": comparison,
                "actual": actual,
                "threshold": threshold,
                "passed": passed,
            }
        )
    if errors:
        all_passed = False
    return {
        "profile": profile_name,
        "scope": "automated_text_only",
        "passed": all_passed,
        "release_decision": False,
        "notice": "A passing component report is not a release approval; use validate_release_evidence.py.",
        "gates": gates,
    }, errors


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("predictions", type=Path)
    parser.add_argument("--criteria", type=Path)
    parser.add_argument("--profile", help="Profile under criteria.profiles")
    parser.add_argument("--summary-only", action="store_true")
    parser.add_argument("--output", type=Path, help="Write JSON report to a file instead of stdout")
    parser.add_argument("--direction", choices=("en->es", "es->en", "en->ja", "ja->en"))
    parser.add_argument("--processing-mode", choices=tuple(sorted(MODES)))
    parser.add_argument("--device-tier", choices=("minimum", "mid_tier", "current"))
    parser.add_argument("--deployment-environment", choices=("testflight", "production"))
    parser.add_argument("--artifact-root", type=Path)
    parser.add_argument("--corpus-uri", help="Corpus path relative to --artifact-root.")
    parser.add_argument("--predictions-uri", help="Predictions path relative to --artifact-root.")
    parser.add_argument("--device-registry", help="Device-registry path relative to --artifact-root.")
    parser.add_argument("--run-identity", type=Path)
    parser.add_argument("--run-identity-uri", help="Run-identity path relative to --artifact-root.")
    parser.add_argument("--release-identity-sha256")
    args = parser.parse_args(argv)
    if bool(args.criteria) != bool(args.profile):
        parser.error("--criteria and --profile must be supplied together")
    if args.profile == "release_language_direction":
        required = {
            "--direction": args.direction,
            "--processing-mode": args.processing_mode,
            "--device-tier": args.device_tier,
            "--deployment-environment": args.deployment_environment,
            "--artifact-root": args.artifact_root,
            "--corpus-uri": args.corpus_uri,
            "--predictions-uri": args.predictions_uri,
            "--device-registry": args.device_registry,
            "--run-identity": args.run_identity,
            "--run-identity-uri": args.run_identity_uri,
            "--release-identity-sha256": args.release_identity_sha256,
        }
        missing = [name for name, value in required.items() if not value]
        if missing:
            parser.error(f"release_language_direction requires: {', '.join(missing)}")
        if not re.fullmatch(r"[a-f0-9]{64}", args.release_identity_sha256):
            parser.error("--release-identity-sha256 must be 64 lowercase hexadecimal characters")
    return args


def _release_artifact(root: Path, uri: str, expected: Path, label: str) -> tuple[Path | None, str | None]:
    if "\\" in uri or Path(uri).is_absolute() or ".." in Path(uri).parts:
        return None, f"{label} URI must be a safe relative path under artifact root"
    try:
        resolved_root = root.resolve(strict=True)
        candidate = resolved_root / uri
        cursor = candidate
        while cursor != resolved_root:
            if cursor.is_symlink():
                return None, f"{label} path contains a symlink"
            cursor = cursor.parent
        resolved = candidate.resolve(strict=True)
        resolved.relative_to(resolved_root)
    except (OSError, ValueError) as exc:
        return None, f"{label} URI cannot be resolved under artifact root: {exc}"
    if resolved != expected.resolve():
        return None, f"{label} argument does not match its bound artifact URI"
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(resolved, flags)
    except OSError as exc:
        return None, f"{label} cannot be opened safely: {exc}"
    snapshot_path: Path | None = None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            return None, f"{label} must be a regular single-link file"
        with tempfile.NamedTemporaryFile(prefix="locallingo-score-snapshot-", delete=False) as target:
            snapshot_path = Path(target.name)
            size = 0
            with os.fdopen(os.dup(descriptor), "rb", closefd=True) as source:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    target.write(chunk)
                    size += len(chunk)
        after = os.fstat(descriptor)
        if (
            (before.st_dev, before.st_ino, before.st_mode, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            != (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            or size != before.st_size
        ):
            snapshot_path.unlink(missing_ok=True)
            return None, f"{label} changed while it was being snapshotted"
        return snapshot_path, None
    except OSError as exc:
        if snapshot_path is not None:
            snapshot_path.unlink(missing_ok=True)
        return None, f"{label} could not be snapshotted: {exc}"
    finally:
        os.close(descriptor)


def _sha256(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def _release_audio(cases: list[dict[str, Any]], root: Path) -> list[str]:
    errors: list[str] = []
    pcm_owners: dict[str, str] = {}
    fingerprints: list[tuple[str, tuple[int, ...]]] = []
    for index, case in enumerate(cases):
        audio = case.get("audio")
        if not isinstance(audio, dict):
            continue
        uri = audio.get("path")
        expected = root / uri if isinstance(uri, str) else root
        path, error = _release_artifact(root, uri, expected, f"corpus case {index} audio")
        if error:
            errors.append(error)
            continue
        assert path is not None
        if _sha256(path) != audio.get("sha256"):
            errors.append(f"corpus case {index} audio digest does not match bytes")
            continue
        try:
            with wave.open(str(path), "rb") as handle:
                if handle.getnchannels() != 1 or handle.getsampwidth() != 2 or handle.getcomptype() != "NONE":
                    errors.append(f"corpus case {index} audio must be mono 16-bit PCM WAV")
                    continue
                sample_rate = handle.getframerate()
                if sample_rate not in {16_000, 44_100, 48_000}:
                    errors.append(f"corpus case {index} audio sample rate {sample_rate} is not allowlisted")
                    continue
                frame_count = handle.getnframes()
                actual_ms = frame_count * 1000 / sample_rate
                tolerance_ms = max(2.0, 1000 / sample_rate)
                frames = handle.readframes(frame_count)
        except (OSError, EOFError, wave.Error, ZeroDivisionError) as exc:
            errors.append(f"corpus case {index} audio is not a readable PCM WAV: {exc}")
            continue
        if abs(actual_ms - audio["duration_ms"]) > tolerance_ms:
            errors.append(
                f"corpus case {index} audio duration mismatch: declared {audio['duration_ms']} ms, measured {actual_ms:.3f} ms"
            )
            continue
        pcm_digest = hashlib.sha256(frames).hexdigest()
        owner = pcm_owners.setdefault(pcm_digest, str(case.get("id", index)))
        if owner != str(case.get("id", index)):
            errors.append(f"corpus case {index} reuses normalized PCM bytes from {owner}")
        samples = array.array("h")
        samples.frombytes(frames)
        if sys.byteorder != "little":
            samples.byteswap()
        if not samples:
            errors.append(f"corpus case {index} audio contains no PCM samples")
            continue
        normalized = [sample / 32768.0 for sample in samples]
        peak = max(abs(sample) for sample in normalized)
        rms = math.sqrt(sum(sample * sample for sample in normalized) / len(normalized))
        frame_samples = max(1, sample_rate // 50)
        activity_frames = 0
        total_frames = 0
        frame_rms_values: list[float] = []
        for offset in range(0, len(normalized), frame_samples):
            chunk = normalized[offset : offset + frame_samples]
            if not chunk:
                continue
            value = math.sqrt(sum(sample * sample for sample in chunk) / len(chunk))
            frame_rms_values.append(value)
            total_frames += 1
            if value >= max(0.006, rms * 0.5):
                activity_frames += 1
        activity_ratio = activity_frames / total_frames if total_frames else 0.0
        kind = audio.get("kind")
        if kind in {"speech", "wrong_language"} and (peak < 0.03 or rms < 0.003 or activity_ratio < 0.10):
            errors.append(
                f"corpus case {index} {kind} audio lacks required signal energy/activity "
                f"(peak={peak:.6f}, rms={rms:.6f}, active={activity_ratio:.3f})"
            )
        if kind == "silence" and peak > 0.01:
            errors.append(f"corpus case {index} silence audio peak {peak:.6f} exceeds 0.01")
        # Gain-normalized 64-bin energy profile catches copied/near-copied audio
        # even when headers or amplitude are changed. It is deliberately only a
        # preflight duplicate detector; signed v2 evidence also binds a pinned
        # VAD/acoustic-fingerprint report.
        bins: list[int] = []
        maximum_frame_rms = max(frame_rms_values, default=0.0)
        for bin_index in range(64):
            start = bin_index * len(frame_rms_values) // 64
            end = max(start + 1, (bin_index + 1) * len(frame_rms_values) // 64)
            values = frame_rms_values[start:end]
            mean = sum(values) / len(values) if values else 0.0
            bins.append(round(255 * mean / maximum_frame_rms) if maximum_frame_rms else 0)
        fingerprint = tuple(bins)
        for prior_id, prior in fingerprints:
            distance = sum(abs(left - right) for left, right in zip(fingerprint, prior)) / (64 * 255)
            if distance <= 0.01:
                errors.append(f"corpus case {index} is an acoustic near-duplicate of {prior_id}")
                break
        fingerprints.append((str(case.get("id", index)), fingerprint))
    return errors


def _run_identity_errors(
    run: Any,
    *,
    args: argparse.Namespace,
    device: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    if not isinstance(run, dict):
        return ["run identity must be a JSON object"]
    missing = sorted(RUN_IDENTITY_KEYS - set(run))
    unknown = sorted(set(run) - RUN_IDENTITY_KEYS)
    if missing or unknown:
        return [f"run identity fields are not exact; missing={missing}, unknown={unknown}"]
    expected = {
        "schema_version": "1.0",
        "release_identity_sha256": args.release_identity_sha256,
        "direction": args.direction,
        "route": args.processing_mode,
        "device_tier": args.device_tier,
        "deployment_environment": args.deployment_environment,
        "device_model_identifier": device.get("model_identifier"),
        "device_os_version": device.get("os_version"),
        "device_os_build": device.get("os_build"),
    }
    for name, value in expected.items():
        if run.get(name) != value:
            errors.append(f"run identity {name} does not match the selected release run")
    patterns = {
        "run_id": r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}",
        "app_commit": r"[a-f0-9]{40}",
        "app_version": r"[0-9]+\.[0-9]+\.[0-9]+",
        "build_number": r"[1-9][0-9]*",
        "app_bundle_id": r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+",
        "api_domain": r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?",
    }
    for name, pattern in patterns.items():
        if not isinstance(run.get(name), str) or not re.fullmatch(pattern, run[name]):
            errors.append(f"run identity {name} has an invalid format")
    if not isinstance(run.get("engine_build"), str) or not run["engine_build"].strip():
        errors.append("run identity engine_build must be non-empty")
    try:
        generated = datetime.fromisoformat(str(run["generated_at"]).replace("Z", "+00:00"))
        if generated.tzinfo is None:
            raise ValueError
    except ValueError:
        errors.append("run identity generated_at must be an ISO-8601 timestamp with timezone")
    return errors


def _release_report(
    args: argparse.Namespace,
    cases: list[dict[str, Any]],
    rows: list[dict[str, Any]],
    summary: dict[str, Any],
    acceptance: dict[str, Any],
    criteria_digest: str,
    missing: list[str],
    extra: list[str],
) -> tuple[dict[str, Any] | None, list[str]]:
    errors: list[str] = []
    corpus_path, error = _release_artifact(args.artifact_root, args.corpus_uri, args.corpus, "corpus")
    if error:
        errors.append(error)
    predictions_path, error = _release_artifact(args.artifact_root, args.predictions_uri, args.predictions, "predictions")
    if error:
        errors.append(error)
    registry_expected = args.artifact_root / args.device_registry
    registry_path, error = _release_artifact(args.artifact_root, args.device_registry, registry_expected, "device registry")
    if error:
        errors.append(error)
    run_path, error = _release_artifact(args.artifact_root, args.run_identity_uri, args.run_identity, "run identity")
    if error:
        errors.append(error)
    registry: Any = None
    if registry_path is not None:
        try:
            registry = strict_json_loads(registry_path.read_bytes())
        except (OSError, json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
            errors.append(f"device registry is not valid JSON: {exc}")
    try:
        device = registry["tiers"][args.device_tier]
        device_identifier = device["model_identifier"]
    except (KeyError, TypeError):
        errors.append("device registry does not define the selected tier")
        device_identifier = None
        device = {}
    run: Any = None
    if run_path is not None:
        try:
            run = strict_json_loads(run_path.read_bytes())
        except (OSError, json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
            errors.append(f"run identity is not valid JSON: {exc}")
    if run is not None:
        errors.extend(_run_identity_errors(run, args=args, device=device))
    mismatched_directions = sorted({row["direction"] for row in rows if row["direction"] != args.direction})
    mismatched_modes = sorted({row["processing_mode"] for row in rows if row["processing_mode"] != args.processing_mode})
    mismatched_devices = sorted({row["device"] for row in rows if row["device"] != device_identifier})
    if mismatched_directions:
        errors.append(f"release report contains rows outside direction {args.direction}: {mismatched_directions}")
    if mismatched_modes:
        errors.append(f"release report contains rows outside processing mode {args.processing_mode}: {mismatched_modes}")
    if mismatched_devices:
        errors.append(f"release report contains rows outside physical device {device_identifier}: {mismatched_devices}")
    if isinstance(run, dict):
        mismatched_engines = sorted({row["model_build"] for row in rows if row["model_build"] != run.get("engine_build")})
        if mismatched_engines:
            errors.append(f"release report contains model/runtime builds outside bound engine {run.get('engine_build')}: {mismatched_engines}")
        mismatched_runs = sorted({str(row.get("run_id")) for row in rows if row.get("run_id") != run.get("run_id")})
        if mismatched_runs:
            errors.append(f"release report contains predictions outside bound run {run.get('run_id')}: {mismatched_runs}")
    errors.extend(_release_audio(cases, args.artifact_root))
    if errors or corpus_path is None or predictions_path is None or registry_path is None or run_path is None:
        return None, errors
    speech_cases = [
        case for case in cases
        if isinstance(case.get("audio"), dict) and case["audio"].get("kind") == "speech"
    ]
    speakers = {case["audio"]["speaker_id"] for case in speech_cases}
    audio_minutes = sum(case["audio"]["duration_ms"] for case in speech_cases) / 60_000
    domains = sorted({case["domain"] for case in cases})
    strata = sorted({tag for case in cases for tag in case["tags"]})
    domain_counts = Counter(case["domain"] for case in speech_cases)
    stratum_counts = Counter(tag for case in speech_cases for tag in case["tags"])
    risk_counts = Counter(case["risk"] for case in speech_cases)
    domain_speakers: dict[str, set[str]] = defaultdict(set)
    for case in speech_cases:
        domain_speakers[case["domain"]].add(case["audio"]["speaker_id"])
    rows_by_id = {row["id"]: row for row in rows}
    domain_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    stratum_rows: dict[str, list[dict[str, Any]]] = defaultdict(list)
    critical_rows: list[dict[str, Any]] = []
    for case in cases:
        row = rows_by_id.get(case["id"])
        if row is None:
            continue
        domain_rows[case["domain"]].append(row)
        for tag in case["tags"]:
            stratum_rows[tag].append(row)
        if case["risk"] == "critical":
            critical_rows.append(row)
    by_domain = {name: summarize_rows(values) for name, values in sorted(domain_rows.items())}
    by_stratum = {name: summarize_rows(values) for name, values in sorted(stratum_rows.items())}
    metrics = {
        "case_count": summary["case_count"],
        "mean_chrf2": summary["mean_chrf2"],
        "critical_check_pass_rate": summary["critical_checks"]["pass_rate"],
        "missing_predictions": len(missing),
        "extra_predictions": len(extra),
        "speaker_count": len(speakers),
        "audio_minutes": round(audio_minutes, 6),
        "domains": domains,
        "strata": strata,
        "domain_case_counts": dict(sorted(domain_counts.items())),
        "stratum_case_counts": dict(sorted(stratum_counts.items())),
        "risk_case_counts": dict(sorted(risk_counts.items())),
        "domain_speaker_counts": {name: len(values) for name, values in sorted(domain_speakers.items())},
        "by_domain": by_domain,
        "by_stratum": by_stratum,
    }
    criteria = strict_json_loads(args.criteria.read_bytes())
    coverage = criteria["profiles"]["release_language_direction"]["corpus_coverage"]
    stratified = criteria["profiles"]["release_language_direction"]["stratified_automated_text"]
    required_domains = set(coverage["required_domains"])
    required_strata = set(coverage["required_strata"])
    coverage_passed = (
        len(speakers) >= coverage["min_speakers"]
        and audio_minutes >= coverage["min_audio_minutes"]
        and required_domains.issubset(domains)
        and required_strata.issubset(strata)
        and all(domain_counts[name] >= coverage["min_cases_per_required_domain"] for name in required_domains)
        and all(stratum_counts[name] >= coverage["min_cases_per_required_stratum"] for name in required_strata)
        and all(len(domain_speakers[name]) >= coverage["min_speakers_per_required_domain"] for name in required_domains)
        and risk_counts["elevated"] >= coverage["min_elevated_risk_cases"]
        and risk_counts["critical"] >= coverage["min_critical_risk_cases"]
    )
    group_quality_passed = all(
        summary_value["mean_chrf2"] is not None
        and summary_value["mean_chrf2"] >= stratified["min_group_mean_chrf2"]
        for name, summary_value in itertools.chain(by_domain.items(), by_stratum.items())
        if name in required_domains or name in required_strata
    )
    critical_summary = summarize_rows(critical_rows)
    critical_pass_rate = critical_summary["critical_checks"]["pass_rate"]
    critical_quality_passed = (
        bool(critical_rows)
        and critical_pass_rate is not None
        and critical_pass_rate >= stratified["min_critical_check_pass_rate"]
    )
    return {
        "schema_version": "1.0",
        "category": "automated_text",
        "status": "passed" if acceptance["passed"] and coverage_passed and group_quality_passed and critical_quality_passed else "failed",
        "scope": {"kind": "cell", "direction": args.direction, "route": args.processing_mode, "device_tier": args.device_tier, "environment": args.deployment_environment},
        "bindings": {
            "release_identity_sha256": args.release_identity_sha256,
            "criteria_sha256": criteria_digest,
            "device_registry_sha256": _sha256(registry_path),
            "corpus": {"artifact_uri": args.corpus_uri, "sha256": _sha256(corpus_path)},
            "run_identity": {"artifact_uri": args.run_identity_uri, "sha256": _sha256(run_path)},
        },
        "metrics": metrics,
        "checks": {
            "coverage_passed": coverage_passed,
            "stratified_quality_passed": group_quality_passed,
            "critical_quality_passed": critical_quality_passed,
        },
        "attachments": [{"artifact_uri": args.predictions_uri, "sha256": _sha256(predictions_path)}],
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "tool": "locallingo-score-predictions/1.0",
    }, []


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    cases, corpus_errors = load_and_validate([args.corpus])
    predictions, prediction_errors = load_predictions(args.predictions)
    validation_errors = corpus_errors + prediction_errors
    if validation_errors:
        for message in validation_errors:
            print(message, file=sys.stderr)
        print(f"Scoring stopped with {len(validation_errors)} validation error(s).", file=sys.stderr)
        return 2

    rows, missing, extra = score_cases(cases, predictions)
    summary = summarize_rows(rows)
    report: dict[str, Any] = {
        "release_decision": False,
        "report_scope": "reference_text_component",
        "metric_definition": {
            "normalization": "Unicode NFKC, casefold, punctuation/symbol-to-space",
            "chrf2": "Whitespace-independent macro character n-gram F-beta, beta=2, orders 1 through 6",
            "aggregation": "Macro average across scored cases; best reference selected by chrF2 then token F1",
        },
        "expected_case_count": len(cases),
        "scored_case_count": len(rows),
        "missing_prediction_ids": missing,
        "extra_prediction_ids": extra,
        "summary": summary,
        "by_direction": grouped_summary(rows, "direction"),
        "by_processing_mode": grouped_summary(rows, "processing_mode"),
    }
    exit_code = 0
    if args.criteria:
        acceptance, gate_errors = evaluate_gates(
            args.criteria, args.profile, summary, len(missing), len(extra)
        )
        if gate_errors:
            for message in gate_errors:
                print(message, file=sys.stderr)
            return 2
        report["acceptance"] = acceptance
        if not acceptance["passed"]:
            exit_code = 1
        if args.profile == "release_language_direction":
            criteria_digest = hashlib.sha256(args.criteria.read_bytes()).hexdigest()
            typed_report, release_errors = _release_report(args, cases, rows, summary, acceptance, criteria_digest, missing, extra)
            if release_errors:
                for message in release_errors:
                    print(message, file=sys.stderr)
                return 2
            assert typed_report is not None
            report = typed_report
            if typed_report["status"] != "passed":
                exit_code = 1
    if not args.summary_only and args.profile != "release_language_direction":
        report["cases"] = rows

    rendered = json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n"
    if args.output:
        try:
            with args.output.open("x", encoding="utf-8") as handle:
                handle.write(rendered)
        except OSError as exc:
            print(f"Unable to write {args.output}: {exc}", file=sys.stderr)
            return 2
    else:
        sys.stdout.write(rendered)
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
