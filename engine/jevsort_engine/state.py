"""Turn the app's raw file description into the fixed-schema state the model sees.

Stable keys matter: open-jev's structural path embeddings learn what each field
means (`name` vs `text`), so every producer — the app, the dataset generator and
the eval set — goes through `model_state`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from urllib.parse import urlparse

NONE_ID = "__none__"
NONE_OPTION = "none of these folders fit this file"
QUESTION = "Which folder does this file belong in?"
MAX_TEXT_CHARS = 1500

_CAMEL = re.compile(r"(?<=[a-z])(?=[A-Z])")
_SEP = re.compile(r"[^0-9A-Za-z]+")
_WS = re.compile(r"\s+")


@dataclass(frozen=True)
class Folder:
    id: str
    path: str
    description: str = ""

    def option_text(self) -> str:
        path = " / ".join(p.strip() for p in self.path.split("/") if p.strip())
        return f"{path}: {self.description}" if self.description else path


def humanize(name: str) -> str:
    """`2025_W2-acmeCorp.pdf` -> `2025 W2 acme Corp`."""
    stem = name.rsplit(".", 1)[0] if "." in name.lstrip(".") else name
    return _WS.sub(" ", _SEP.sub(" ", _CAMEL.sub(" ", stem))).strip()


def domain(url: str) -> str:
    host = urlparse(url).hostname or ""
    return host.removeprefix("www.")


def model_state(raw: dict) -> dict:
    name = str(raw.get("name", ""))
    ext = str(raw.get("ext") or (name.rsplit(".", 1)[1] if "." in name else "")).lower()
    sources = [d for d in (domain(u) for u in raw.get("where_from") or []) if d]
    text = _WS.sub(" ", str(raw.get("text") or "")).strip()[:MAX_TEXT_CHARS]
    state = {
        "name": humanize(name),
        "ext": ext,
        "kind": str(raw.get("kind") or ""),
        "source": " ".join(dict.fromkeys(sources)),
        "title": str(raw.get("title") or ""),
        "text": text,
    }
    # Empty fields carry no signal; dropping them keeps sequences short.
    return {k: v for k, v in state.items() if v} or {"name": name}


def parse_tree(items: list[dict]) -> list[Folder]:
    folders = [Folder(str(f["id"]), str(f["path"]), str(f.get("description") or "")) for f in items]
    ids = [f.id for f in folders]
    if len(set(ids)) != len(ids):
        raise ValueError("folder ids must be unique")
    if NONE_ID in ids:
        raise ValueError(f"{NONE_ID} is reserved")
    if not folders:
        raise ValueError("tree must contain at least one folder")
    return folders
