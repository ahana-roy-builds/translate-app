"""Fail-closed JSON loading for signed release evidence."""

from __future__ import annotations

import json
from typing import Any


MAX_NODES = 1_000_000
MAX_DEPTH = 128


def _pairs(rows: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in rows:
        if key in result:
            raise ValueError(f"duplicate JSON object key: {key!r}")
        result[key] = value
    return result


def _constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is forbidden: {value}")


def loads(source: str | bytes | bytearray) -> Any:
    if isinstance(source, (bytes, bytearray)):
        source = bytes(source).decode("utf-8", errors="strict")
    value = json.loads(source, object_pairs_hook=_pairs, parse_constant=_constant)
    stack: list[tuple[Any, int]] = [(value, 0)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > MAX_NODES or depth > MAX_DEPTH:
            raise ValueError("JSON nesting/node bound exceeded")
        if isinstance(current, str):
            current.encode("utf-8", errors="strict")
        elif isinstance(current, dict):
            for key, item in current.items():
                key.encode("utf-8", errors="strict")
                stack.append((item, depth + 1))
        elif isinstance(current, list):
            stack.extend((item, depth + 1) for item in current)
    return value
