from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
from strict_json import loads  # noqa: E402


class StrictJSONTests(unittest.TestCase):
    def test_duplicate_nonfinite_and_surrogate_values_are_rejected(self) -> None:
        for value in ('{"a":1,"a":2}', '{"value":NaN}', '"\\ud800"'):
            with self.subTest(value=value), self.assertRaises((ValueError, UnicodeError)):
                loads(value)

    def test_excessive_nesting_fails_closed(self) -> None:
        with self.assertRaises((ValueError, RecursionError)):
            loads("[" * 200 + "0" + "]" * 200)


if __name__ == "__main__":
    unittest.main()
