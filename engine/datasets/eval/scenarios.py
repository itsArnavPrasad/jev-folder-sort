"""The end-to-end scenarios (examples/scenarios.py) in eval format.

Used as a second *development* set while iterating on the model. The held-out
sets (messy.py, plain_english.py) stay untouched for honest reporting.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "examples"))
from scenarios import SCENARIOS  # noqa: E402

TREES = {name: list(spec["folders"].items()) for name, spec in SCENARIOS.items()}
FILES = {name: [(f, text, "", expect) for f, _kind, text, expect in spec["files"]] for name, spec in SCENARIOS.items()}
