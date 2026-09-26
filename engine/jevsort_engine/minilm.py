"""open-jev with a pretrained MiniLM brain (model architecture "minilm", v0.2+).

Why: the plain open-jev encoders are trained from scratch, so everything the
model knows about language comes from our small synthetic corpus. That caps it
at ~60% on real files. all-MiniLM-L6-v2 is a sentence-similarity model
pretrained on over a billion sentence pairs: it already knows that "W-2" and
"tax documents" belong together, which is exactly what matching a file to a
plain-English folder description needs.

What changes relative to open-jev (all done here, from the outside; the vendored
open-jev code is untouched):

1. `StateEncoder` and `TextEncoder` are replaced by ONE shared, pretrained
   MiniLM (6 post-norm BERT layers, 384-d, 12 heads). open-jev's pre-norm blocks
   can't take BERT weights, so this file implements the BERT layers itself
   (no `transformers` dependency) and loads MiniLM's weights exactly.
2. open-jev's structural embeddings (depth / sibling / path hash) are kept and
   added to MiniLM's input embeddings, initialised at zero so the model starts
   out as exactly MiniLM.
3. Choice scores get a **description-matching prior**: the scaled cosine
   similarity between the file's mean-pooled MiniLM embedding and each option
   ("Finance / Taxes: tax returns, W-2"). Plain-English descriptions therefore
   work from step 0; open-jev's learned Choice head adds corrections on top.

Unchanged from open-jev: the query-slot read-out stack, typed heads (Noul,
Choice, Score), the evidential confidence head, and RLCDLoss.
"""

from __future__ import annotations

from collections.abc import Sequence

import torch
import torch.nn.functional as F
from open_jev import Choice, Jev, JevConfig, Noul
from torch import Tensor, nn

CLS, SEP = 101, 102
HIDDEN, LAYERS, HEADS, FFN, MAX_POS = 384, 6, 12, 1536, 512


class BertLayer(nn.Module):
    """Post-norm BERT layer, parameter layout matching Hugging Face's BertLayer."""

    def __init__(self, dropout: float) -> None:
        super().__init__()
        self.query, self.key, self.value = (nn.Linear(HIDDEN, HIDDEN) for _ in range(3))
        self.attn_out = nn.Linear(HIDDEN, HIDDEN)
        self.attn_norm = nn.LayerNorm(HIDDEN, eps=1e-12)
        self.ffn_in = nn.Linear(HIDDEN, FFN)
        self.ffn_out = nn.Linear(FFN, HIDDEN)
        self.ffn_norm = nn.LayerNorm(HIDDEN, eps=1e-12)
        self.dropout = dropout

    def forward(self, x: Tensor, attn_mask: Tensor) -> Tensor:
        B, T, _ = x.shape

        def heads(t: Tensor) -> Tensor:
            return t.view(B, T, HEADS, HIDDEN // HEADS).transpose(1, 2)

        drop = self.dropout if self.training else 0.0
        ctx = F.scaled_dot_product_attention(heads(self.query(x)), heads(self.key(x)), heads(self.value(x)),
                                             attn_mask=attn_mask, dropout_p=drop)
        ctx = ctx.transpose(1, 2).reshape(B, T, HIDDEN)
        x = self.attn_norm(x + F.dropout(self.attn_out(ctx), drop, self.training))
        h = self.ffn_out(F.gelu(self.ffn_in(x)))
        return self.ffn_norm(x + F.dropout(h, drop, self.training))


class MiniLM(nn.Module):
    """all-MiniLM-L6-v2 encoder. `extra` embeddings are added before the embedding LayerNorm."""

    def __init__(self, vocab_size: int, dropout: float = 0.1) -> None:
        super().__init__()
        self.word = nn.Embedding(vocab_size, HIDDEN, padding_idx=0)
        self.position = nn.Embedding(MAX_POS, HIDDEN)
        self.token_type = nn.Embedding(2, HIDDEN)
        self.emb_norm = nn.LayerNorm(HIDDEN, eps=1e-12)
        self.layers = nn.ModuleList(BertLayer(dropout) for _ in range(LAYERS))
        self.dropout = dropout

    def forward(self, ids: Tensor, pad_mask: Tensor, extra: Tensor | None = None) -> Tensor:
        """ids [B, T], pad_mask [B, T] (True = pad) -> hidden [B, T, 384]."""
        T = ids.shape[1]
        pos = torch.arange(T, device=ids.device).clamp(max=MAX_POS - 1)
        x = self.word(ids) + self.position(pos).unsqueeze(0) + self.token_type.weight[0]
        if extra is not None:
            x = x + extra
        x = F.dropout(self.emb_norm(x), self.dropout, self.training)
        # Additive mask: 0 where attending is allowed, -inf on padding keys.
        attn_mask = torch.zeros(ids.shape, dtype=x.dtype, device=ids.device).masked_fill(pad_mask, float("-inf"))
        attn_mask = attn_mask[:, None, None, :]
        for layer in self.layers:
            x = layer(x, attn_mask)
        return x

    def load_pretrained(self, weights: dict[str, Tensor]) -> None:
        """Copy Hugging Face BertModel weights (all-MiniLM-L6-v2) into this module."""
        m = {
            "word.weight": "embeddings.word_embeddings.weight",
            "position.weight": "embeddings.position_embeddings.weight",
            "token_type.weight": "embeddings.token_type_embeddings.weight",
            "emb_norm.weight": "embeddings.LayerNorm.weight",
            "emb_norm.bias": "embeddings.LayerNorm.bias",
        }
        for i in range(LAYERS):
            p = f"encoder.layer.{i}."
            for ours, theirs in [("query", "attention.self.query"), ("key", "attention.self.key"),
                                 ("value", "attention.self.value"), ("attn_out", "attention.output.dense"),
                                 ("attn_norm", "attention.output.LayerNorm"), ("ffn_in", "intermediate.dense"),
                                 ("ffn_out", "output.dense"), ("ffn_norm", "output.LayerNorm")]:
                for t in ("weight", "bias"):
                    m[f"layers.{i}.{ours}.{t}"] = p + f"{theirs}.{t}"
        missing = [v for v in m.values() if v not in weights]
        if missing:
            raise ValueError(f"not a MiniLM checkpoint, missing {missing[:3]}")
        self.load_state_dict({k: weights[v] for k, v in m.items()})


def mean_pool(hidden: Tensor, pad_mask: Tensor) -> Tensor:
    keep = (~pad_mask).unsqueeze(-1).to(hidden.dtype)
    return (hidden * keep).sum(1) / keep.sum(1).clamp(min=1.0)


class MiniLMStateEncoder(nn.Module):
    """open-jev StateEncoder interface backed by MiniLM + open-jev's structural embeddings."""

    def __init__(self, cfg: JevConfig, bert: MiniLM) -> None:
        super().__init__()
        self.cfg = cfg
        self.bert = bert
        self.depth_emb = nn.Embedding(cfg.max_path_depth, HIDDEN)
        self.sibling_emb = nn.Embedding(cfg.max_sibling_index, HIDDEN)
        self.path_emb = nn.Embedding(cfg.path_hash_buckets, HIDDEN)
        for e in (self.depth_emb, self.sibling_emb, self.path_emb):
            nn.init.zeros_(e.weight)  # start out as exactly MiniLM
        self.pooled: Tensor | None = None  # last mean-pooled embedding, for the prior

    @property
    def token(self) -> nn.Embedding:  # parity with open-jev's StateEncoder
        return self.bert.word

    def forward(self, ids: Tensor, paths: Tensor, pad_mask: Tensor) -> Tensor:
        cfg = self.cfg
        B = ids.shape[0]
        struct = (
            self.depth_emb(paths[..., 0].clamp(0, cfg.max_path_depth - 1))
            + self.sibling_emb(paths[..., 1].clamp(0, cfg.max_sibling_index - 1))
            + self.path_emb(paths[..., 2].remainder(cfg.path_hash_buckets))
        )
        # Prepend [CLS] as in MiniLM's pretraining; drop it again so the output
        # lines up with open-jev's pad mask.
        cls = torch.full((B, 1), CLS, dtype=ids.dtype, device=ids.device)
        full_ids = torch.cat([cls, ids], 1)
        full_pad = torch.cat([torch.zeros_like(pad_mask[:, :1]), pad_mask], 1)
        extra = torch.cat([torch.zeros_like(struct[:, :1]), struct], 1)
        hidden = self.bert(full_ids, full_pad, extra)
        self.pooled = mean_pool(hidden, full_pad)
        return hidden[:, 1:]


class MiniLMTextEncoder(nn.Module):
    """open-jev TextEncoder interface: short strings -> mean-pooled MiniLM sentence embedding."""

    def __init__(self, bert: MiniLM) -> None:
        super().__init__()
        self.bert = bert

    @property
    def token(self) -> nn.Embedding:
        return self.bert.word

    def forward(self, ids: Tensor, pad_mask: Tensor) -> Tensor:
        B = ids.shape[0]
        lengths = (~pad_mask).sum(1)
        full = torch.zeros(B, ids.shape[1] + 2, dtype=ids.dtype, device=ids.device)
        full[:, 0] = CLS
        full[:, 1 : ids.shape[1] + 1] = ids.masked_fill(pad_mask, 0)
        full[torch.arange(B, device=ids.device), lengths + 1] = SEP
        full_pad = full.eq(0)
        return mean_pool(self.bert(full, full_pad), full_pad)


class JevMiniLM(Jev):
    """open-jev's read-out and heads on a shared pretrained MiniLM, plus the description prior."""

    arch = "minilm"

    def __init__(self, cfg: JevConfig, tokenizer=None) -> None:
        super().__init__(cfg, tokenizer)
        if cfg.d_model != HIDDEN:
            raise ValueError("JevMiniLM needs d_model=384")
        self.bert = MiniLM(cfg.vocab_size, cfg.dropout)
        self.state_encoder = MiniLMStateEncoder(cfg, self.bert)
        self.text_encoder = MiniLMTextEncoder(self.bert)
        # Scale of the cosine-similarity prior (sentence-transformers cosines live in ~[-0.2, 0.9]).
        self.prior_scale = nn.Parameter(torch.tensor(20.0))
        # The learned Choice score starts at exactly 0, so an untrained model is
        # pure description matching; training learns corrections on top.
        nn.init.zeros_(self.choice_head.o_proj[1].weight)
        nn.init.zeros_(self.choice_head.o_proj[1].bias)

    def encoder_parameters(self) -> list[nn.Parameter]:
        return list(self.bert.parameters())

    def logits(self, states: Sequence, questions: Sequence) -> list[tuple[Tensor, Tensor]]:
        """Same contract as Jev.logits; Choice logits get the description prior."""
        cache = self.encode_state(states)
        state_emb = F.normalize(self.state_encoder.pooled, dim=-1)  # [B, d]
        pooled = self._readout(cache, questions)
        B, N = cache.batch_size, len(questions)
        out: list[tuple[Tensor, Tensor]] = []
        for n, q in enumerate(questions):
            vec = pooled[torch.arange(B, device=pooled.device) * N + n]
            if isinstance(q, Noul):
                p_true = torch.sigmoid(self.noul_head(vec)).unsqueeze(-1)
                probs = torch.cat([1 - p_true, p_true], dim=-1)
            elif isinstance(q, Choice):
                opts = self._encode_options(q.options)  # [K, d]
                mask = torch.ones(B, len(q.options), dtype=torch.bool, device=vec.device)
                learned = self.choice_head(vec, opts.unsqueeze(0).expand(B, -1, -1), mask)
                prior = self.prior_scale * state_emb @ F.normalize(opts, dim=-1).T  # [B, K]
                probs = F.softmax(learned + prior, dim=-1)
            else:
                probs = self.score_head(vec, len(q.labels))
            conf, _ = self.confidence_head(vec, probs.shape[-1])
            out.append((probs.clamp(min=1e-8), conf))
        return out

    def forward(self, *args, **kwargs):  # the Jev.forward path would skip the prior
        raise NotImplementedError("use logits(); FileSorter wraps it")


__all__ = ["JevMiniLM", "MiniLM", "mean_pool"]
