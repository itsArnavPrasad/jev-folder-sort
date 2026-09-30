# Model history: from Jev to our own model

jev-folder-sort's model went through four designs. Each change was driven by numbers on hand-written held-out files. This page records what we tried, what we measured, and why we ended up where we are.

**Today (v0.4):** a pretrained **MiniLM** sentence encoder plus a **System One decision head** (typed Choice, read-out slots, calibrated confidence), with a description-matching prior. It's our own code in `engine/jevsort_engine/` and has no dependency on open-jev.

## The idea we started from: TypeSafe's Jev

[Jev](https://typesafe.ai/blog/introducing-system-one-models-and-jev) is a "System One" model:
- one forward pass;
- typed answers (`Choice`, `Score`, `Noul`) over options supplied at runtime;
- calibrated probabilities;
- no text generation.

That's a perfect shape for "which of *these* folders does this file go in?": the model can't invent a folder, and its confidence decides whether a file moves automatically. The hosted Jev API isn't available to us and would send data off the Mac, so we needed a local model.

## v0.1–v0.2: open-jev

[open-jev](https://github.com/kyegomez/open-jev) is an unofficial PyTorch reconstruction of Jev's architecture. It ships **untrained**: random weights and a placeholder hash tokenizer.

We vendored it, gave it MiniLM's WordPiece tokenizer and frozen word vectors, and trained its from-scratch encoders on a synthetic "file → folder" corpus that we generated.

| | Messy files | Plain-English descriptions |
|---|---|---|
| base-0.1.0 | 61% | 53% |
| base-0.2.0 (better data) | 57% | 51% |

Training on more synthetic data didn't help, because the ceiling was **language understanding**. From-scratch encoders learned our templates and leaned on folder *names*, largely ignoring descriptions. That's the opposite of the product goal: *describe what goes in each folder in plain English, and the sorter follows it.*

## v0.3: a pretrained MiniLM brain

We replaced open-jev's two from-scratch encoders with **one shared, pretrained all-MiniLM-L6-v2**: a sentence-similarity model trained on over a billion sentence pairs. It encodes both the file and each folder option.

- **Our own BERT layers.** open-jev's blocks are pre-norm and BERT's are post-norm, so its weights couldn't be poured into open-jev's layers. `minilm.py` implements the BERT layers itself, with no `transformers` dependency. It is verified identical to the official `sentence-transformers` (cosine 1.0, max difference 1.6e-7).
- **Kept from the Jev design:**
  - structural embeddings, telling the model which field each token came from (zero-initialised);
  - query-slot read-out, a typed Choice head over *your* folders plus "none of these";
  - evidential confidence;
  - the RLCD calibration loss.
- **New: a description-matching prior.** Choice score = learned head (zero-initialised) + a learned-scale cosine similarity between the file and each `Folder / Path: description` option. An *untrained* model already follows descriptions, and fine-tuning learns corrections on top: file-type cues, parent versus child folders, when to say "none".
- **Training:** MiniLM layers fine-tune gently (learning rate 2e-5), the head fast (3e-4). The best checkpoint is chosen on a hand-written dev set, with the untrained step-0 model as a candidate.

## v0.3 final: no more open-jev

After v0.3, our model used only a few of open-jev's pieces: the typed question dataclasses, state flattening, the read-out block, the heads and the RLCD loss. We folded those ~300 lines into our own module, **`decision.py`**, with attribution (Apache-2.0, see NOTICE), and **deleted the vendored open-jev package**.

The parameter names are unchanged, so the trained checkpoint loads identically: we got the same scores before and after removal. Checkpoints from the old from-scratch architecture (v0.1/v0.2) are no longer supported.

## v0.4: fixing what real folders exposed

An end-to-end scenario benchmark (four realistic setups, run through the real app) showed three problems:
1. The model said "none of these fit" too often.
2. It missed names and brands.
3. It was weak on code files.

The fixes:
- **"None" gets a learned constant.** Previously it got a cosine similarity, and MiniLM finds the sentence "none of these folders fit this file" similar to almost anything.
- **A learned keyword-overlap prior** alongside the semantic one: hybrid matching, as in modern search.
- **Readable kinds for common extensions** when macOS only says "Document".
- A warm-started fine-tune.

The results:
- Held-out: 77% → 83% (messy) and 85% → 94% (plain-English).
- End to end: 52% → 64% of files auto-moved, with zero wrong moves.

## We also evaluated Laya

[Laya](https://github.com/NandhaKishorM/laya) (Apache-2.0) is a pretrained, multilingual System One decision engine with Jev-style `choice`, `score` and `noul` questions.

We ran it **zero-shot** on the same held-out files, same inputs, same "none of these" option, on this Mac. We tried the state as JSON and as readable text, a larger option budget, and CPU and Apple GPU:

| | Messy | Plain-English | Dev | Time per file | Size |
|---|---|---|---|---|---|
| **Our model (minilm-0.3.0)** | **77%** | **85%** | **80%** | **4–7 ms** | ~60 MB |
| Laya (ModernBERT-large, 421M) | 31–34% | 47–51% | 42–50% | 150–580 ms | 843 MB |
| Keyword baseline | 33% | 70% | 45% | <0.1 ms | — |

Laya's own README says its base checkpoints are "near chance zero-shot" and should be fine-tuned, which takes 4–5 hours on two T4 GPUs. That also rules out learning on the user's Mac.

As a second opinion on files our model is unsure about, Laya was confident *and* right on only 14 of 157 (~9%). We decided to keep our model and not bundle Laya. It remains a candidate for a future, opt-in "System Two" check, for example once there's a fine-tuned file-sorting Laya checkpoint.

## Summary of results (hand-written held-out sets)

| Model | Messy (150) | Plain-English (53) | Dev (60, used for selection) |
|---|---|---|---|
| Keyword baseline | 33.3% | 69.8% | 45.0% |
| base-0.1.0 (open-jev) | 61.3% | 52.8% | — |
| base-0.2.0 (open-jev) | 57.3% | 50.9% | 56.7% |
| MiniLM, zero training | 62.7% | 79.2% | 65.0% |
| minilm-0.3.0 | 77.3% | 84.9% | 80.0% |
| **minilm-0.4.0** (keyword prior, learned "none", readable kinds) | **82.7%** | **94.3%** | 85.0% |
| Laya zero-shot (best setting) | 34.0% | 50.9% | 50.0% |

Details, thresholds and calibration are in [MODEL.md](MODEL.md).
