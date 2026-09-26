"""Synthetic (folder tree, file, soft target) generator for base training.

Every batch shares one randomly-built folder tree, which is exactly how the app
queries the model (one scan = one tree, many files). Targets are soft: the
right folder gets most of the mass, a parent folder or a closely related
sibling gets a little, and files whose kind isn't in the tree go to
"none of these" (or to their group folder if one exists).

    uv run python -m datasets.generate --out datasets/generated/sample.jsonl --groups 20
"""

from __future__ import annotations

import argparse
import json
import random
import string
from dataclasses import dataclass
from pathlib import Path

from jevsort_engine.state import NONE_ID

from .ontology import CONCEPTS, FILLERS, GENERIC, GROUPS, JUNK, OPAQUE_NAMES, Concept

BY_KEY = {c.key: c for c in CONCEPTS}
BY_GROUP: dict[str, list[Concept]] = {}
for _c in CONCEPTS:
    BY_GROUP.setdefault(_c.group, []).append(_c)

KINDS = {
    "pdf": "PDF document", "docx": "Microsoft Word document", "doc": "Microsoft Word 97 - 2004 document",
    "pages": "Pages Publication", "md": "Markdown Document", "txt": "Plain Text Document",
    "pptx": "PowerPoint Presentation", "key": "Keynote Presentation", "xlsx": "Microsoft Excel spreadsheet",
    "numbers": "Numbers Spreadsheet", "csv": "comma-separated values", "png": "PNG image",
    "jpg": "JPEG image", "heic": "HEIF Image", "gif": "GIF Image", "webp": "WebP Image", "dng": "DNG image",
    "mov": "QuickTime movie", "mp4": "MPEG-4 movie", "mkv": "Matroska Video", "m4v": "MPEG-4 movie",
    "mp3": "MP3 audio", "m4a": "Apple MPEG-4 audio", "wav": "Waveform audio", "flac": "FLAC audio",
    "dmg": "Disk Image", "pkg": "Installer package", "zip": "ZIP archive", "tar.gz": "gzip compressed archive",
    "rar": "RAR Archive", "7z": "7-Zip archive", "exe": "Windows executable", "msi": "Windows Installer",
    "app.zip": "ZIP archive", "epub": "EPUB document", "mobi": "Kindle book", "py": "Python Source",
    "js": "JavaScript script", "ts": "TypeScript source", "swift": "Swift Source", "go": "Go source",
    "rs": "Rust source", "sh": "Shell Script", "java": "Java Source", "cpp": "C++ Source", "rb": "Ruby Source",
    "json": "JSON document", "jsonl": "JSON Lines", "parquet": "Document", "sqlite": "SQLite database",
    "yaml": "YAML document", "toml": "TOML document", "env": "Document", "pem": "PEM certificate",
    "plist": "Property List", "conf": "Configuration file", "ipynb": "Jupyter Notebook", "pt": "Document",
    "ckpt": "Document", "fig": "Figma file", "sketch": "Sketch document", "psd": "Adobe Photoshop file",
    "ai": "Adobe Illustrator document", "svg": "SVG image", "xd": "Adobe XD document", "eps": "EPS document",
    "ttf": "TrueType font", "otf": "OpenType font", "woff2": "Web Open Font", "gpx": "GPS Exchange",
    "fit": "Document", "pkpass": "Wallet Pass", "eml": "Email Message", "tex": "LaTeX document",
    "gdoc": "Google Docs",
}
TEXT_EXTS = {"pdf", "docx", "doc", "pages", "md", "txt", "pptx", "key", "xlsx", "numbers", "csv", "epub",
             "mobi", "py", "js", "ts", "swift", "go", "rs", "sh", "java", "cpp", "rb", "json", "jsonl",
             "yaml", "toml", "env", "conf", "ipynb", "tex", "eml", "gdoc", "plist"}
BLAND_NAMES = ["document", "download", "scan0001", "Untitled", "file", "document (3)", "export", "new",
               "Scan 12", "image", "attachment", "final", "copy"]
DEEP_TOPS = [["Personal", "Private", "Me", "Life"], ["Work", "Professional", "Business"]]


class Fill(dict):
    """format_map source that invents a value for any placeholder."""

    def __init__(self, rng: random.Random) -> None:
        super().__init__()
        self.rng = rng

    def __missing__(self, key: str):  # noqa: C901 - a flat table of generators
        r = self.rng
        base = key.rstrip("0123456789") if key not in FILLERS else key
        if base in FILLERS:
            v = r.choice(FILLERS[base])
        elif key == "year":
            v = str(r.randint(2016, 2026))
        elif key in ("q", "quarter"):
            v = str(r.randint(1, 4)) if key == "q" else f"Q{r.randint(1, 4)}"
        elif base == "amount":
            v = f"{r.choice(['$', '£', '€', '₹', ''])}{r.randint(5, 9000):,}.{r.randint(0, 99):02d}"
        elif base == "date":
            y, m, d = r.randint(2018, 2026), r.randint(1, 12), r.randint(1, 28)
            v = r.choice([f"{y}-{m:02d}-{d:02d}", f"{d:02d}/{m:02d}/{y}", f"{y}{m:02d}{d:02d}"])
        elif key == "date8":
            v = f"{r.randint(2018, 2026)}{r.randint(1, 12):02d}{r.randint(1, 28):02d}"
        elif key == "time":
            v = f"{r.randint(1, 12)}.{r.randint(0, 59):02d}.{r.randint(0, 59):02d} {r.choice(['AM', 'PM'])}"
        elif key == "n":
            v = str(r.randint(1000, 99999999))
        elif key == "n1":
            v = r.randint(1, 12)
        elif key == "n4":
            v = f"{r.randint(0, 9999):04d}"
        elif key == "pct":
            v = f"{r.uniform(1, 7):.2f}%"
        elif key in ("hours", "rate"):
            v = str(r.randint(5, 150))
        elif key == "arxiv":
            v = f"{r.randint(15, 26)}{r.randint(1, 12):02d}.{r.randint(1000, 29999):05d}"
        elif key == "ver":
            v = f"{r.randint(0, 12)}.{r.randint(0, 30)}.{r.randint(0, 9)}"
        else:
            v = "".join(r.choices(string.ascii_lowercase, k=5))
        self[key] = v
        return v


def fmt(template: str, rng: random.Random) -> str:
    return template.format_map(Fill(rng))


@dataclass
class Node:
    id: str
    path: str
    description: str
    concept: str | None  # leaf concept this folder is for
    group: str | None  # group this folder stands for
    bucket: frozenset = frozenset()  # concepts a generic folder ("Documents") accepts


DESCRIPTION_TEMPLATES = [
    "{d}", "{d}", "all my {n}", "anything about {n}", "{n} and similar", "put {n} here", "{n}, {m}",
    "files like {n}", "{d} — nothing else", "for {n}", "everything related to {n} ({m})",
]


def describe(concept: Concept, rng: random.Random) -> str:
    """A plain-English folder description, in many phrasings, so the model
    learns to follow descriptions rather than memorise a few fixed strings."""
    names = [n.lower() for n in concept.names] or [concept.key]
    return rng.choice(DESCRIPTION_TEMPLATES).format(
        d=rng.choice(concept.descriptions), n=rng.choice(names), m=rng.choice(names))


def make_generic_tree(rng: random.Random, opaque: bool) -> list[Node]:
    """A few catch-all folders ("Documents", "Media"), or opaque names whose
    only meaning is in the description — teaches the model to read descriptions."""
    if opaque and rng.random() < 0.5:
        # Concept-level folders with meaningless names, described in plain English.
        picks = rng.sample(CONCEPTS, k=rng.randint(4, 10))
        return [Node("", name, describe(c, rng), c.key, None)
                for name, c in zip(rng.sample(OPAQUE_NAMES, k=len(picks)), picks)]
    keys = rng.sample(list(GENERIC), k=rng.randint(3, len(GENERIC)))
    names = rng.sample(OPAQUE_NAMES, k=len(keys))
    nodes = []
    for key, opaque_name in zip(keys, names):
        folder_names, descriptions, concepts = GENERIC[key]
        path = opaque_name if opaque else rng.choice(folder_names)
        desc = rng.choice(descriptions) if opaque or rng.random() < 0.7 else ""
        nodes.append(Node("", path, desc, None, None, frozenset(concepts)))
    if not opaque and rng.random() < 0.5:  # sometimes a specific leaf under a bucket
        parent = rng.choice(nodes)
        c = BY_KEY[rng.choice(sorted(parent.bucket))]
        nodes.append(Node("", f"{parent.path}/{rng.choice(c.names)}", rng.choice(c.descriptions) if rng.random() < 0.4 else "", c.key, None))
    return nodes


def make_tree(rng: random.Random) -> list[Node]:
    style = rng.choices(["grouped", "flat", "deep", "mixed", "generic", "opaque"], weights=[5, 2, 2, 3, 3, 2])[0]
    if style in ("generic", "opaque"):
        nodes = make_generic_tree(rng, opaque=style == "opaque")
        rng.shuffle(nodes)
        for i, n in enumerate(nodes):
            n.id = f"f{i + 1}"
        return nodes
    groups = rng.sample(list(GROUPS), k=rng.randint(2, 7) if style != "flat" else rng.randint(3, 8))
    nodes: list[Node] = []

    def add(path: str, concept: str | None, group: str | None) -> None:
        desc = ""
        if concept and rng.random() < 0.55:
            desc = describe(BY_KEY[concept], rng)
        elif group and not concept and rng.random() < 0.2:
            desc = " , ".join(c.names[0].lower() for c in rng.sample(BY_GROUP[group], k=min(3, len(BY_GROUP[group]))))
        nodes.append(Node("", path, desc, concept, group))

    def leaves(prefix: str, group: str, lo: int = 1) -> None:
        pool = BY_GROUP[group]
        parent = prefix.rsplit("/", 1)[-1].lower()
        for c in rng.sample(pool, k=rng.randint(min(lo, len(pool)), len(pool))):
            names = [n for n in c.names if n.lower() != parent] or c.names
            add(f"{prefix}/{rng.choice(names)}" if prefix else rng.choice(names), c.key, None)

    if style == "flat":
        for g in groups:
            leaves("", g)
    elif style == "deep":
        tops = [rng.choice(t) for t in DEEP_TOPS]
        for top in tops:
            add(top, None, None)
        for g in groups:
            top = tops[1] if g in ("work", "dev", "creative") else tops[0]
            gname = f"{top}/{rng.choice(GROUPS[g])}"
            add(gname, None, g)
            leaves(gname, g)
    else:
        for g in groups:
            gname = rng.choice(GROUPS[g])
            add(gname, None, g)
            if style == "grouped" or rng.random() < 0.6:
                leaves(gname, g)
        if style == "mixed":  # a few concepts float at the top level
            for c in rng.sample(CONCEPTS, k=rng.randint(1, 3)):
                if c.group not in groups:
                    add(rng.choice(c.names), c.key, None)

    # Folder names must be unique by path; drop accidental duplicates.
    seen: set[str] = set()
    unique = []
    for n in nodes:
        if n.path.lower() not in seen:
            seen.add(n.path.lower())
            unique.append(n)
    # A concept appears at most once, otherwise the target is ill-defined.
    concepts_seen: set[str] = set()
    nodes = []
    for n in unique:
        if n.concept and n.concept in concepts_seen:
            continue
        concepts_seen.add(n.concept or "")
        nodes.append(n)
    rng.shuffle(nodes)
    for i, n in enumerate(nodes):
        n.id = f"f{i + 1}"
    return nodes[:60]


def target_for(concept: Concept, tree: list[Node]) -> dict[str, float]:
    if concept.key == JUNK.key:
        return {NONE_ID: 1.0}
    buckets = [n for n in tree if concept.key in n.bucket]
    if buckets:
        leaf = next((n for n in tree if n.concept == concept.key), None)
        t = {leaf.id: 0.8, buckets[0].id: 0.2} if leaf else {buckets[0].id: 0.95, NONE_ID: 0.05}
        return t
    leaf = next((n for n in tree if n.concept == concept.key), None)
    group = next((n for n in tree if n.group == concept.group and n.concept is None), None)
    related = [n for n in tree if n.concept in concept.related]
    t: dict[str, float] = {}
    if leaf:
        t[leaf.id] = 0.9
        if group and leaf.path.startswith(group.path + "/"):
            t[group.id] = 0.05
        for n in related:
            t[n.id] = t.get(n.id, 0) + 0.05 / len(related)
    elif group:
        t[group.id] = 0.85
        t[NONE_ID] = 0.1
        for n in related:
            t[n.id] = t.get(n.id, 0) + 0.05 / len(related)
    elif related:
        for n in related:
            t[n.id] = 0.35 / len(related)
        t[NONE_ID] = 0.65
    else:
        t[NONE_ID] = 1.0
    total = sum(t.values())
    return {k: v / total for k, v in t.items()}


def make_file(concept: Concept, rng: random.Random) -> dict:
    ext = rng.choice(concept.exts)
    name = fmt(rng.choice(concept.filenames), rng)
    has_text = bool(concept.texts) and ext.split(".")[-1] in TEXT_EXTS
    text = fmt(rng.choice(concept.texts), rng) if has_text and rng.random() < 0.8 else ""
    if text and rng.random() < 0.3:
        name = rng.choice(BLAND_NAMES)  # only the content tells you what it is
    if text and rng.random() < 0.3:
        text = text[: rng.randint(30, max(31, len(text)))]
    raw = {"name": f"{name}.{ext}" if ext else name, "ext": ext}
    if rng.random() < 0.85:
        raw["kind"] = KINDS.get(ext, "Document")
    if concept.domains and rng.random() < 0.4:
        raw["where_from"] = [f"https://{rng.choice(concept.domains)}/{fmt('{n}', rng)}"]
    if text:
        raw["text"] = text
    if has_text and rng.random() < 0.15:
        raw["title"] = humanish(name)
    return raw


def humanish(name: str) -> str:
    return name.replace("_", " ").replace("-", " ").title()


def make_group(rng: random.Random, n_files: int = 16) -> dict:
    tree = make_tree(rng)
    in_tree = [BY_KEY[n.concept] for n in tree if n.concept]
    groups_in_tree = {n.group for n in tree if n.group}
    bucketed = set().union(*(n.bucket for n in tree))
    in_tree += [c for c in CONCEPTS if (c.group in groups_in_tree or c.key in bucketed) and c not in in_tree]
    files = []
    for _ in range(n_files):
        roll = rng.random()
        if roll < 0.07:
            c = JUNK
        elif in_tree and roll < 0.82:
            c = rng.choice(in_tree)
        else:
            c = rng.choice(CONCEPTS)
        files.append({"state": make_file(c, rng), "target": target_for(c, tree), "concept": c.key})
    return {"tree": [{"id": n.id, "path": n.path, "description": n.description} for n in tree], "files": files}


def augment(raw: dict, rng: random.Random) -> dict:
    """A semantically equivalent-ish view for the RLCD consistency term."""
    out = dict(raw)
    droppable = [k for k in ("kind", "where_from", "title") if k in out]
    if droppable and rng.random() < 0.7:
        del out[rng.choice(droppable)]
    if "text" in out and rng.random() < 0.5:
        out["text"] = out["text"][: max(40, len(out["text"]) // 2)]
    return out


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--out", type=Path, required=True)
    p.add_argument("--groups", type=int, default=200)
    p.add_argument("--seed", type=int, default=0)
    args = p.parse_args()
    rng = random.Random(args.seed)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w") as f:
        for _ in range(args.groups):
            f.write(json.dumps(make_group(rng)) + "\n")
    print(f"wrote {args.groups} groups to {args.out}")


if __name__ == "__main__":
    main()
