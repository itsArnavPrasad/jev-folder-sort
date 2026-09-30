"""The folder model: build, save, load, and the inference wrapper (FileSorter)."""

from __future__ import annotations

import glob
import json
import os
import time
from dataclasses import asdict
from pathlib import Path

import torch
from safetensors.torch import load_file, save_file

from .decision import Choice, ModelConfig
from .minilm import FolderModel
from .state import NONE_ID, NONE_OPTION, QUESTION, Folder, model_state
from .tokenizer import VOCAB_SIZE, PretrainedTokenizer

MINILM = "sentence-transformers/all-MiniLM-L6-v2"
MAX_CHOICE = 255  # Choice cardinality cap (two-stage choice above it)
BATCH = 16
ARCH = "minilm"


def default_config() -> ModelConfig:
    # d_model/vocab are fixed by MiniLM; heads/d_ff/layers describe the read-out stack.
    return ModelConfig(vocab_size=VOCAB_SIZE, d_model=384, n_heads=6, d_ff=1024, dropout=0.1,
                       max_state_len=510, max_question_len=48, n_slots=8, n_readout_layers=4)


def pick_device() -> torch.device:
    if os.environ.get("JEVSORT_DEVICE"):
        return torch.device(os.environ["JEVSORT_DEVICE"])
    # At this model size CPU beats MPS: kernel-launch overhead dominates the
    # tiny matmuls, and CPU avoids a ~1 s Metal warm-up. JEVSORT_DEVICE=mps to override.
    return torch.device("cpu")


def _minilm_weights() -> dict[str, torch.Tensor]:
    from huggingface_hub import hf_hub_download

    return load_file(hf_hub_download(MINILM, "model.safetensors"))


def build_model(cfg: ModelConfig | None = None, pretrained: bool = True) -> FolderModel:
    """A fresh FolderModel. `pretrained=True` loads MiniLM (downloaded once, at training time only)."""
    model = FolderModel(cfg or default_config(), tokenizer=PretrainedTokenizer())
    if pretrained:
        model.bert.load_pretrained(_minilm_weights())
    # Word vectors stay frozen: they are what keeps unseen words (brands,
    # other languages) meaningful. The transformer layers fine-tune.
    model.bert.word.weight.requires_grad_(False)
    return model


def save_checkpoint(model: FolderModel, directory: Path, meta: dict) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    # Both encoders share model.bert; store those tensors once.
    weights = {
        k: v.detach().to("cpu", torch.float16)
        for k, v in model.state_dict().items()
        if not k.startswith(("text_encoder.", "state_encoder.bert."))
    }
    save_file(weights, str(directory / "model.safetensors"))
    (directory / "config.json").write_text(json.dumps({**asdict(model.cfg), "arch": ARCH}, indent=2))
    (directory / "meta.json").write_text(json.dumps(meta, indent=2))


NEW_IN_V04 = ("none_bias", "lexical_scale")  # parameters added after minilm-0.3.0


def load_checkpoint(directory: Path, device: torch.device | None = None,
                    allow_new: bool = True) -> tuple[FolderModel, dict]:
    """Load a checkpoint. A minilm-0.3.x checkpoint predates the parameters in
    NEW_IN_V04; with `allow_new` they keep their initial values."""
    raw = json.loads((directory / "config.json").read_text())
    arch = raw.pop("arch", "jev")
    if arch != ARCH:
        raise ValueError(f"{directory} is a '{arch}' checkpoint; only '{ARCH}' (v0.3+) is supported")
    model = build_model(ModelConfig.from_dict(raw), pretrained=False)
    weights = {k: v.float() for k, v in load_file(str(directory / "model.safetensors")).items()}
    model.load_state_dict(weights, strict=False)
    missing = [k for k in model.state_dict() if k not in weights
               and not k.startswith(("text_encoder.", "state_encoder.bert."))
               and not (allow_new and k in NEW_IN_V04)]
    if missing:
        raise ValueError(f"checkpoint is missing {missing[:3]}")
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

    def __init__(self, model: FolderModel, meta: dict | None = None) -> None:
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
