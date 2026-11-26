#!/usr/bin/env python3
"""Compare a complete iPhone fixture run with previously reviewed meanings."""
import argparse
from collections import Counter
import json
from pathlib import Path
import unicodedata


def label_key(locale, index, text):
    return locale, str(index), " ".join(unicodedata.normalize("NFC", text).split())


def reviewed_labels(runs, baseline):
    labels = {}

    def note(locale, row, field, meaning):
        if row.get(field) and isinstance(meaning, bool):
            key = label_key(locale, row["idx"], row[field])
            if key in labels and labels[key] != meaning:
                raise ValueError(f"Conflicting reviews of {key}")
            labels[key] = meaning

    for row in baseline["fixtures"]:
        note(row["code"], row, "text", True)
    for row in baseline["cleanText"]:
        note(row["target"], row, "out", row["meaning"])
    for row in baseline["fixedLanguage"]:
        note(row["src"], row, "asr", row["meaning"])
    for row in baseline["spoken"]:
        grade = row["reviewedOutcome"]
        if grade["correctSpeaker"]:
            note(row["expected"], row, "asr", grade["transcriptMeaning"])
            note(row["intended"], row, "output", grade["outputMeaning"])

    for run in runs:
        for row in run["cleanText"]:
            note(row["target"], row, "out", row["meaning"])
        for row in run["fixedLanguage"]:
            note(row["src"], row, "asr", row["meaning"])
        for row in run["spoken"]:
            grade = row["grading"]
            if grade["speaker"]:
                note(row["expected"], row, "asr", grade["transcriptMeaning"])
                note(row["intended"], row, "output", grade["outputMeaning"])
    return labels


def verification_runs(published):
    runs = list(published["runs"])
    for name in ("autoSpeak", "fullAutoSpeak", "finalJapaneseKoreanReplay", "finalGermanKoreanAutoSpeak",
                 "finalCompetingSpeakers"):
        if published.get(name):
            runs.append(published[name])
    return runs


def compare(log, baseline, labels, pairs=None):
    fixtures = {(row["code"], str(row["idx"])): row["text"] for row in baseline["fixtures"]}
    original = {(row["expected"], row["intended"], row["idx"]): row for row in baseline["spoken"]}
    if pairs is not None:
        wanted = {frozenset(pair.split("_")) for pair in pairs}
        supported = {frozenset((source, target)) for source, target, _ in original}
        if not wanted or not wanted <= supported:
            raise ValueError(f"Unknown fixture pair(s): {pairs}")
        original = {key: row for key, row in original.items() if frozenset(key[:2]) in wanted}
    regressions = []
    wrong_playback = []
    routing_errors = []
    observed = set()
    unknown = set()
    totals = Counter()

    def meaning(locale, row, field):
        text = row.get(field, "")
        if not text.strip():
            return False
        key = label_key(locale, row["idx"], text)
        if key not in labels:
            unknown.add(key)
        return labels.get(key)

    for line in log.read_text().splitlines():
        if not line.startswith("MATRIX {"):
            continue
        row = json.loads(line.removeprefix("MATRIX "))
        kind = row["kind"]
        if kind == "reference":
            totals["referenceCalls"] += 1
            totals["referenceMeaning"] += meaning(row["target"], row, "out") is True
        if kind == "manual":
            totals["fixedLanguageCalls"] += 1
            totals["fixedLanguageMeaning"] += meaning(row["src"], row, "asr") is True
        if kind == "voice":
            totals["voiceChecks"] += 1
            if row.get("actual", "").replace("_", "-") == row["src"]:
                totals["correctVoices"] += 1
            else:
                wrong_playback.append(row)
        if kind == "replay":
            partner = next(code for code in row["pair"].split("_") if code != row["expected"])
            totals["replayRequests"] += 1
            correct_voice = row.get("voice", "").replace("_", "-") == partner and row.get("sameText") == "true"
            totals["correctReplay"] += correct_voice
            unresolved = row.get("unresolvedSpeaker") == "true"
            if (unresolved and row.get("error") != "ineligible") or (not unresolved and not correct_voice):
                wrong_playback.append(row)
        if kind != "spoken":
            continue
        source, target, index = row["expected"], row["intended"], row["idx"]
        key = source, target, index
        if key not in original or row["ref"] != fixtures[source, index]:
            raise ValueError(f"Recording is outside the baseline at {key}: {row['ref']}")
        if key in observed:
            raise ValueError(f"Duplicate fixture result: {key}")
        observed.add(key)
        saved = row.get("count") == "1"
        reasons = set(row.get("reviewReasons", "").split(","))
        pending = bool(reasons & {"conflictingSpeakerEvidence", "competingFinals"}) and not row.get("output")
        expected_side = "traveler" if row["pair"].split("_")[0] == source else "local"
        routed = saved and not pending and (row.get("savedSource"), row.get("savedTarget"), row.get("side")) == (source, target, expected_side)
        totals["savedOnce"] += saved
        totals["awaitingSpeaker"] += pending
        totals["correctSpeaker"] += routed
        if not routed and not (saved and pending):
            routing_errors.append(key)
        if row.get("autoVoice"):
            totals["automaticPlaybacks"] += 1
            correct_playback = (
                routed and row["autoVoice"].replace("_", "-") == target
                and row.get("lastSynthesizedText") == row.get("output")
            )
            totals["correctAutomaticPlayback"] += correct_playback
            if not correct_playback:
                wrong_playback.append(row)
        transcript_meaning = meaning(source, row, "asr") if routed else False
        totals["transcriptMeaning"] += transcript_meaning is True
        output_meaning = meaning(target, row, "output") if routed else False
        correct = output_meaning is True
        totals["translationMeaning"] += correct
        prior = original[key]["reviewedOutcome"]
        if prior["transcriptMeaning"] and transcript_meaning is False:
            regressions.append((*key, "transcript"))
        if prior["outputMeaning"]:
            totals["baselineSuccessesRetained"] += correct
            if output_meaning is False:
                regressions.append((*key, "translation"))
        else:
            totals["baselineFailuresRecovered"] += correct

    return {
        "counts": dict(totals),
        "regressions": sorted(regressions),
        "wrongPlayback": wrong_playback,
        "routingErrors": sorted(routing_errors),
        "expectedTurns": len(original),
        "observedTurns": len(observed),
        "missing": sorted(original.keys() - observed),
        "needsReview": sorted(unknown),
    }


def quality_issues(score):
    return [f"{key}: {len(score[key])}" for key in
            ("missing", "needsReview", "regressions", "wrongPlayback", "routingErrors") if score[key]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--review", type=Path, help="Additional published per-turn engineering reviews")
    parser.add_argument("--pairs", help="Canonical pairs selected for a partial run, separated by commas")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    runs = []
    if args.review:
        published = json.loads(args.review.read_text())
        runs = verification_runs(published)
    result = compare(args.log, baseline, reviewed_labels(runs, baseline), args.pairs.split(",") if args.pairs else None)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(bool(quality_issues(result)))


if __name__ == "__main__":
    raise SystemExit(main())
