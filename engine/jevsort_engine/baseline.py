"""Keyword-overlap baseline.

Two jobs: the bar the trained model has to beat in eval, and the `--stub`
engine the app can develop against before a checkpoint exists. It is
deliberately simple — no learned weights, no extension tables.
"""

from __future__ import annotations

import math
import re
import time

from .model import result
from .state import NONE_ID, Folder, model_state

_WORD = re.compile(r"[a-z0-9]+")
_STOP = {"the", "and", "of", "for", "a", "to", "in", "my", "files", "file", "other", "misc", "stuff"}


def _stem(w: str) -> str:
    for suffix in ("ies", "es", "s"):
        if w.endswith(suffix) and len(w) > len(suffix) + 2:
            return w[: -len(suffix)] + ("y" if suffix == "ies" else "")
    return w


def words(text: str) -> set[str]:
    return {_stem(w) for w in _WORD.findall(text.lower()) if w not in _STOP and len(w) > 1}


class KeywordSorter:
    meta = {"version": "baseline-keyword", "kind": "stub"}
    device = "cpu"

    def __init__(self, sharpness: float = 3.0, none_score: float = 0.6) -> None:
        self.sharpness = sharpness
        self.none_score = none_score

    def distributions(self, folders: list[Folder], raw_files: list[dict]) -> list[dict[str, float]]:
        option_words = {f.id: words(f.option_text()) for f in folders}
        out = []
        for raw in raw_files:
            state = model_state(raw)
            name_words = words(f"{state.get('name', '')} {state.get('ext', '')} {state.get('title', '')}")
            body_words = words(f"{state.get('kind', '')} {state.get('source', '')} {state.get('text', '')}")
            scores = {
                fid: 2.0 * len(ow & name_words) + len(ow & body_words)
                for fid, ow in option_words.items()
            }
            scores[NONE_ID] = self.none_score
            z = max(scores.values())
            exp = {k: math.exp(self.sharpness * (v - z)) for k, v in scores.items()}
            total = sum(exp.values())
            out.append({k: v / total for k, v in exp.items()})
        return out

    def classify(self, folders: list[Folder], raw_files: list[dict]) -> list[dict]:
        start = time.perf_counter()
        dists = self.distributions(folders, raw_files)
        per_file_ms = (time.perf_counter() - start) * 1000 / max(len(raw_files), 1)
        return [result(raw["id"], dist, per_file_ms) for raw, dist in zip(raw_files, dists)]
