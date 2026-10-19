#!/usr/bin/env python3
"""Create an unfilled prediction JSONL template from a validated corpus."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from validate_corpus import load_and_validate


MODES = ("local_only", "online_quality", "auto_local", "auto_online")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("corpus", type=Path)
    parser.add_argument("--processing-mode", choices=MODES, required=True)
    parser.add_argument("--model-build", default="TODO")
    parser.add_argument("--device", default="TODO")
    parser.add_argument("--run-id", help="Release run ID to bind every prediction row to a run identity.")
    parser.add_argument("--output", type=Path, help="Output path; stdout when omitted")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    records, errors = load_and_validate([args.corpus])
    if errors:
        for message in errors:
            print(message, file=sys.stderr)
        return 1

    lines = []
    for record in records:
        prediction = {
            "id": record["id"],
            "prediction": "",
            "latency_ms": None,
            "model_build": args.model_build,
            "device": args.device,
            "processing_mode": args.processing_mode,
        }
        if args.run_id:
            prediction["run_id"] = args.run_id
        lines.append(json.dumps(prediction, ensure_ascii=False, separators=(",", ":")))
    rendered = "\n".join(lines) + "\n"

    if args.output is None:
        sys.stdout.write(rendered)
        return 0
    try:
        with args.output.open("x", encoding="utf-8") as handle:
            handle.write(rendered)
    except FileExistsError:
        print(f"Refusing to overwrite existing file: {args.output}", file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"Unable to write {args.output}: {exc}", file=sys.stderr)
        return 1
    print(f"Wrote {len(records)} template record(s) to {args.output}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
