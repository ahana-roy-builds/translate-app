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


def compare(log, baseline, labels):
    fixtures = {(row["code"], str(row["idx"])): row["text"] for row in baseline["fixtures"]}
    original = {(row["expected"], row["intended"], row["idx"]): row for row in baseline["spoken"]}
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
        if kind == "replay":
            partner = next(code for code in row["pair"].split("_") if code != row["expected"])
            totals["replayRequests"] += 1
            totals["correctReplay"] += row.get("voice", "").replace("_", "-") == partner and row.get("sameText") == "true"
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
        if row.get("autoVoice"):
            totals["automaticPlaybacks"] += 1
            totals["correctAutomaticPlayback"] += (
                routed and row["autoVoice"].replace("_", "-") == target
                and row.get("lastSynthesizedText") == row.get("output")
            )
        totals["transcriptMeaning"] += routed and meaning(source, row, "asr") is True
        correct = routed and meaning(target, row, "output") is True
        totals["translationMeaning"] += correct
        if original[key]["reviewedOutcome"]["outputMeaning"]:
            totals["baselineSuccessesRetained"] += correct
        else:
            totals["baselineFailuresRecovered"] += correct

    return {
        "counts": dict(totals),
        "expectedTurns": len(original),
        "observedTurns": len(observed),
        "missing": sorted(original.keys() - observed),
        "needsReview": sorted(unknown),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--review", type=Path, help="Additional published per-turn engineering reviews")
    args = parser.parse_args()
    baseline = json.loads(args.baseline.read_text())
    runs = []
    if args.review:
        published = json.loads(args.review.read_text())
        runs.extend(published["runs"])
        for name in ("autoSpeak", "fullAutoSpeak", "finalJapaneseKoreanReplay", "finalGermanKoreanAutoSpeak",
                     "finalCompetingSpeakers"):
            if published.get(name):
                runs.append(published[name])
    result = compare(args.log, baseline, reviewed_labels(runs, baseline))
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 1 if result["needsReview"] or result["missing"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
