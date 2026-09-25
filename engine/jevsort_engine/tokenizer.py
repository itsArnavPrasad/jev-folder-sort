"""Pretrained WordPiece tokenizer that plugs into open-jev.

open-jev's `Jev(cfg, tokenizer=...)` only needs `encode`, `encode_batch` and a
`PAD` id, so we can swap its placeholder `HashTokenizer` for a real subword
vocabulary without touching the vendored code. We use the vocabulary of
sentence-transformers/all-MiniLM-L6-v2 (Apache-2.0) so the token embeddings can
be initialised from that model's pretrained word embeddings.
"""

from __future__ import annotations

from collections.abc import Sequence
from functools import lru_cache
from pathlib import Path

import torch
from tokenizers import Tokenizer
from torch import Tensor

ASSET = Path(__file__).parent / "assets" / "minilm-tokenizer.json"
VOCAB_SIZE = 30522
UNK_ID = 100


class PretrainedTokenizer:
    PAD: int = 0

    def __init__(self, path: Path = ASSET) -> None:
        self._tok = Tokenizer.from_file(str(path))
        self._tok.no_padding()
        self._tok.no_truncation()
        self.vocab_size = self._tok.get_vocab_size()

    @lru_cache(maxsize=65536)
    def _ids(self, text: str) -> tuple[int, ...]:
        return tuple(self._tok.encode(text, add_special_tokens=False).ids)

    def encode(self, text: str, max_len: int) -> list[int]:
        ids = list(self._ids(text)[:max_len])
        return ids or [UNK_ID]

    def encode_batch(self, texts: Sequence[str], max_len: int) -> tuple[Tensor, Tensor]:
        """Returns (ids [B, L], pad_mask [B, L]) where pad_mask is True at PAD."""
        seqs = [self.encode(t, max_len) for t in texts]
        length = max(len(s) for s in seqs)
        ids = torch.full((len(seqs), length), self.PAD, dtype=torch.long)
        for i, s in enumerate(seqs):
            ids[i, : len(s)] = torch.tensor(s, dtype=torch.long)
        return ids, ids.eq(self.PAD)
