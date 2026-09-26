"""open-jev configured and wrapped for one job: pick a folder for a file."""

from __future__ import annotations

import glob
import json
import os
import time
from dataclasses import asdict
from pathlib import Path

import torch
from open_jev import Choice, Jev, JevConfig
from safetensors.torch import load_file, save_file

from .state import NONE_ID, NONE_OPTION, QUESTION, Folder, model_state
from .tokenizer import VOCAB_SIZE, PretrainedTokenizer

MINILM = "sentence-transformers/all-MiniLM-L6-v2"
MAX_CHOICE = 255  # open-jev's Choice cardinality cap
BATCH = 16


def default_config(arch: str = "minilm") -> JevConfig:
    if arch == "minilm":
        # d_model/vocab fixed by MiniLM; n_heads/d_ff/layers below are open-jev's read-out stack.
        return JevConfig(
            vocab_size=VOCAB_SIZE, d_model=384, n_heads=6, d_ff=1024, dropout=0.1,
            n_state_layers=0, max_state_len=510, n_question_layers=0, max_question_len=48,
            n_slots=8, n_readout_layers=4,
        )
    return JevConfig(
        vocab_size=VOCAB_SIZE,
        d_model=384,
        n_heads=6,
        d_ff=1024,
        dropout=0.1,
        n_state_layers=4,
        max_state_len=512,
        n_question_layers=2,
        max_question_len=48,
        n_slots=8,
        n_readout_layers=4,
    )


def pick_device() -> torch.device:
    if os.environ.get("JEVSORT_DEVICE"):
        return torch.device(os.environ["JEVSORT_DEVICE"])
    # At this model size CPU beats MPS: kernel-launch overhead dominates the
    # tiny matmuls, and CPU avoids a ~1 s Metal warm-up. JEVSORT_DEVICE=mps to override.
    return torch.device("cpu")


def _minilm_weights() -> dict[str, torch.Tensor]:
    from huggingface_hub import hf_hub_download

    return load_file(hf_hub_download(MINILM, "model.safetensors"))


def _minilm_word_embeddings() -> torch.Tensor:
    return _minilm_weights()["embeddings.word_embeddings.weight"]


def build_model(cfg: JevConfig | None = None, pretrained_embeddings: bool = True, arch: str = "minilm") -> Jev:
    """A fresh model.

    arch="minilm" (v0.2+): open-jev read-out on a shared pretrained MiniLM
    encoder with a description-matching prior (see minilm.py).
    arch="jev" (v0.1): plain open-jev encoders with frozen MiniLM word vectors.
    """
    if arch == "minilm":
        from .minilm import JevMiniLM

        model = JevMiniLM(cfg or default_config("minilm"), tokenizer=PretrainedTokenizer())
        if pretrained_embeddings:
            model.bert.load_pretrained(_minilm_weights())
        # Word vectors stay frozen: they are what keeps unseen words (brands,
        # other languages) meaningful. The transformer layers fine-tune.
        model.bert.word.weight.requires_grad_(False)
        return model

    cfg = cfg or default_config("jev")
    model = Jev(cfg, tokenizer=PretrainedTokenizer())
    # open-jev initialises every embedding at N(0, 1), which would drown the
    # pretrained word vectors (std ~0.056). Structural/position signals start
    # small so content dominates early training.
    enc = model.state_encoder
    for emb in (enc.depth_emb, enc.sibling_emb, enc.path_emb, enc.pos_emb, model.text_encoder.pos):
        torch.nn.init.normal_(emb.weight, std=0.02)
    # One word-embedding table, shared by state and question/option encoders and
    # frozen at MiniLM's pretrained values: 23M fewer trainable parameters, and
    # words the synthetic corpus never uses (brands, German) keep their meaning.
    model.text_encoder.token = enc.token
    if pretrained_embeddings:
        with torch.no_grad():
            enc.token.weight.copy_(_minilm_word_embeddings())
    else:
        torch.nn.init.normal_(enc.token.weight, std=0.056)
    enc.token.weight.requires_grad_(False)
    return model


def model_arch(model: Jev) -> str:
    return getattr(model, "arch", "jev")


def save_checkpoint(model: Jev, directory: Path, meta: dict) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    # Tied tensors are stored once (the plain-jev text encoder shares the state
    # encoder's table; in "minilm" both encoders share model.bert).
    skip_prefixes = ("text_encoder.", "state_encoder.bert.") if model_arch(model) == "minilm" else ()
    weights = {
        k: v.detach().to("cpu", torch.float16)
        for k, v in model.state_dict().items()
        if k != "text_encoder.token.weight" and not k.startswith(skip_prefixes)
    }
    save_file(weights, str(directory / "model.safetensors"))
    (directory / "config.json").write_text(json.dumps({**asdict(model.cfg), "arch": model_arch(model)}, indent=2))
    (directory / "meta.json").write_text(json.dumps(meta, indent=2))


def load_checkpoint(directory: Path, device: torch.device | None = None) -> tuple[Jev, dict]:
    raw = json.loads((directory / "config.json").read_text())
    arch = raw.pop("arch", "jev")
    cfg = JevConfig(**raw)
    weights = {k: v.float() for k, v in load_file(str(directory / "model.safetensors")).items()}
    if arch == "minilm":
        model = build_model(cfg, pretrained_embeddings=False, arch="minilm")
        model.load_state_dict(weights, strict=False)
        missing = [k for k in model.state_dict() if k not in weights
                   and not k.startswith(("text_encoder.", "state_encoder.bert."))]
        if missing:
            raise ValueError(f"checkpoint is missing {missing[:3]}")
    else:
        model = Jev(cfg, tokenizer=PretrainedTokenizer())
        model.text_encoder.token = model.state_encoder.token
        weights["text_encoder.token.weight"] = weights["state_encoder.token.weight"]
        model.load_state_dict(weights)
    meta = json.loads((directory / "meta.json").read_text())
    return model.to(device or pick_device()).eval(), meta


def latest_checkpoint(root: Path) -> Path | None:
    found = sorted(glob.glob(str(root / "*" / "model.safetensors")), key=os.path.getmtime)
    return Path(found[-1]).parent if found else None


def build_choice(folders: list[Folder]) -> tuple[Choice, list[str]]:
    """One Choice over the folders plus the reserved 'none of these' option.

    Returns the question and the folder id for each option index. The model
    only ever sees option *text*; ids never leave this process as anything but
    the ids the caller gave us.
    """
    options = [f.option_text() for f in folders] + [NONE_OPTION]
    ids = [f.id for f in folders] + [NONE_ID]
    # Paths are unique, so option texts are too; guard anyway because Choice
    # rejects duplicates and a silent collision would mislabel a folder.
    if len(set(options)) != len(options):
        raise ValueError("duplicate folder option text")
    return Choice(QUESTION, options=options, key="folder"), ids


class FileSorter:
    """Inference wrapper used by the server."""

    def __init__(self, model: Jev, meta: dict | None = None) -> None:
        self.model = model.eval()
        self.meta = meta or {}
        self.device = next(model.parameters()).device

    @torch.no_grad()
    def distributions(self, folders: list[Folder], raw_files: list[dict]) -> list[dict[str, float]]:
        """P(folder id) for each file, including NONE_ID."""
        if len(folders) + 1 > MAX_CHOICE:
            return self._two_stage(folders, raw_files)
        question, ids = build_choice(folders)
        out: list[dict[str, float]] = []
        for i in range(0, len(raw_files), BATCH):
            states = [model_state(f) for f in raw_files[i : i + BATCH]]
            (probs, _conf), = self.model.logits(states, [question])
            for row in probs.float().cpu():
                total = float(row.sum())
                out.append({ids[k]: float(row[k]) / total for k in range(len(ids))})
        return out

    def _two_stage(self, folders: list[Folder], raw_files: list[dict]) -> list[dict[str, float]]:
        """Trees above the Choice cap: pick a top-level group, then choose within it."""
        groups: dict[str, list[Folder]] = {}
        for f in folders:
            groups.setdefault(f.path.split("/")[0], []).append(f)
        heads = [Folder(f"g:{name}", name) for name in groups]
        top = self.distributions(heads, raw_files)
        out = []
        for raw, dist in zip(raw_files, top):
            best = max((k for k in dist if k != NONE_ID), key=dist.get)
            inner = self.distributions(groups[best.removeprefix("g:")], [raw])[0]
            scale = dist[best]
            merged = {k: v * scale for k, v in inner.items() if k != NONE_ID}
            merged[NONE_ID] = 1.0 - sum(merged.values())
            out.append(merged)
        return out

    def classify(self, folders: list[Folder], raw_files: list[dict]) -> list[dict]:
        start = time.perf_counter()
        dists = self.distributions(folders, raw_files)
        per_file_ms = (time.perf_counter() - start) * 1000 / max(len(raw_files), 1)
        return [result(raw["id"], dist, per_file_ms) for raw, dist in zip(raw_files, dists)]


def result(file_id: str, dist: dict[str, float], latency_ms: float) -> dict:
    ranked = sorted(dist.items(), key=lambda kv: kv[1], reverse=True)
    choice, confidence = ranked[0]
    return {
        "file": file_id,
        "choice": choice,
        "confidence": round(confidence, 4),
        "top": [{"folder": k, "p": round(v, 4)} for k, v in ranked[:3]],
        "latency_ms": round(latency_ms, 2),
    }
