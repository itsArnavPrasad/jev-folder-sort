"""Turn the app's raw file description into the fixed-schema state the model sees.

Stable keys matter: the structural path embeddings learn what each field
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


# Plain-English kinds for common extensions. Used when macOS only says
# "Document" (or nothing): a sentence model can match "SQL database script" to a
# folder described as "SQL migrations", but not the bare word "Document".
EXT_KINDS = {
    "sql": "SQL database script", "py": "Python source code", "js": "JavaScript source code",
    "ts": "TypeScript source code", "tsx": "TypeScript React source code", "jsx": "React source code",
    "swift": "Swift source code", "go": "Go source code", "rs": "Rust source code", "java": "Java source code",
    "kt": "Kotlin source code", "rb": "Ruby source code", "php": "PHP source code", "c": "C source code",
    "cpp": "C++ source code", "h": "C header file", "cs": "C# source code", "sh": "shell script",
    "zsh": "shell script", "ipynb": "Jupyter notebook", "r": "R script", "m": "source code",
    "yml": "YAML configuration file", "yaml": "YAML configuration file", "toml": "TOML configuration file",
    "json": "JSON data file", "jsonl": "JSON lines data file", "xml": "XML file", "csv": "CSV spreadsheet data",
    "tsv": "tab-separated data", "parquet": "Parquet dataset", "sqlite": "SQLite database", "db": "database file",
    "env": "environment variables config file", "pem": "certificate or private key", "pub": "SSH public key",
    "key": "Keynote presentation", "dmg": "macOS disk image installer", "pkg": "macOS installer package",
    "exe": "Windows installer program", "msi": "Windows installer package", "app": "application",
    "zip": "ZIP archive", "rar": "RAR archive", "7z": "7-Zip archive", "gz": "compressed archive",
    "otf": "OpenType font file", "ttf": "TrueType font file", "woff": "web font file", "woff2": "web font file",
    "epub": "ebook", "mobi": "Kindle ebook", "azw3": "Kindle ebook", "psd": "Photoshop design file",
    "ai": "Illustrator design file", "fig": "Figma design file", "sketch": "Sketch design file",
    "svg": "SVG vector graphic", "heic": "photo", "dng": "raw camera photo", "cr2": "raw camera photo",
    "mp3": "music audio file", "m4a": "audio recording", "wav": "audio file", "flac": "lossless music file",
    "mp4": "video", "mov": "video", "mkv": "video", "ics": "calendar invite", "vcf": "contact card",
    "eml": "email message", "pkpass": "Apple Wallet pass (ticket or boarding pass)", "gpx": "GPS track",
    "pt": "PyTorch model checkpoint", "safetensors": "machine learning model weights", "ckpt": "model checkpoint",
    "log": "log file", "bin": "binary data file", "dat": "data file", "tmp": "temporary file",
}
GENERIC_KINDS = {"", "document", "unix executable file", "data", "unknown", "file"}


def model_state(raw: dict) -> dict:
    name = str(raw.get("name", ""))
    ext = str(raw.get("ext") or (name.rsplit(".", 1)[1] if "." in name else "")).lower()
    sources = [d for d in (domain(u) for u in raw.get("where_from") or []) if d]
    text = _WS.sub(" ", str(raw.get("text") or "")).strip()[:MAX_TEXT_CHARS]
    kind = str(raw.get("kind") or "")
    if kind.lower() in GENERIC_KINDS and ext in EXT_KINDS:
        kind = EXT_KINDS[ext]
    # Strong, cheap signals macOS already knows: fold them into the kind so the
    # model reads e.g. "PNG image, screenshot" or "JPEG image, photo taken with Apple iPhone 15".
    if raw.get("screenshot"):
        kind = f"{kind}, screenshot" if kind else "screenshot"
    if raw.get("camera"):
        kind = f"{kind}, photo taken with {raw['camera']}" if kind else f"photo taken with {raw['camera']}"
    state = {
        "name": humanize(name),
        "ext": ext,
        "kind": kind,
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


# --- lexical overlap (hybrid keyword + semantic matching) -------------------

_WORD_RE = re.compile(r"[a-z0-9]+")
_STOPWORDS = {
    "the", "and", "for", "with", "from", "this", "that", "are", "was", "all", "any", "anything", "files", "file",
    "folder", "folders", "stuff", "things", "other", "misc", "like", "about", "related", "everything", "here",
    "put", "only", "nothing", "else", "our", "my", "mine", "your", "their", "his", "her", "its", "you", "etc",
    "name", "ext", "kind", "source", "title", "text", "document", "documents", "pdf", "none", "these", "fit",
}


def _stem(w: str) -> str:
    for suffix in ("ies", "es", "s"):
        if w.endswith(suffix) and len(w) > len(suffix) + 2:
            return w[: -len(suffix)] + ("y" if suffix == "ies" else "")
    return w


def content_words(text: str) -> set[str]:
    return {_stem(w) for w in _WORD_RE.findall(text.lower()) if len(w) > 2 and w not in _STOPWORDS}


def state_words(state: dict) -> set[str]:
    return content_words(" ".join(str(v) for v in state.values()))
