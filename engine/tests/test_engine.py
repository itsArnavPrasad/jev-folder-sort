import io
import json

import pytest
import torch

from jevsort_engine.baseline import KeywordSorter
from jevsort_engine.model import FileSorter, build_model, default_config, load_checkpoint, save_checkpoint
from jevsort_engine.server import PROTOCOL_VERSION, Server
from jevsort_engine.state import NONE_ID, humanize, model_state, parse_tree
from jevsort_engine.tokenizer import PretrainedTokenizer

TREE = [
    {"id": "f1", "path": "Finance", "description": "bank statements, invoices"},
    {"id": "f2", "path": "Finance/Taxes", "description": "tax returns, W-2, 1099"},
    {"id": "f3", "path": "Photos"},
]
FILES = [
    {"id": "a", "name": "2025_W2_acme.pdf", "text": "Form W-2 Wage and Tax Statement"},
    {"id": "b", "name": "IMG_2231.HEIC", "kind": "HEIF image"},
]


@pytest.fixture(scope="module")
def sorter():
    torch.manual_seed(0)
    return FileSorter(build_model(pretrained=False).to("cpu"), {"version": "test"})


def test_tokenizer_subwords_and_pad():
    tok = PretrainedTokenizer()
    ids = tok.encode("invoices invoice", 16)
    assert ids and 0 not in ids
    batch, pad = tok.encode_batch(["tax", "bank statement march"], 8)
    assert batch.shape[0] == 2 and pad[0].any() and not pad[1, 0]
    assert tok.encode("", 8) == [100]  # never empty


def test_humanize_and_state():
    assert humanize("2025_W2-acmeCorp.pdf") == "2025 W2 acme Corp"
    state = model_state({"name": "a.PDF", "where_from": ["https://www.chase.com/x"], "text": " x  y "})
    assert state == {"name": "a", "ext": "pdf", "source": "chase.com", "text": "x y"}


def test_tree_validation():
    with pytest.raises(ValueError):
        parse_tree([{"id": "x", "path": "A"}, {"id": "x", "path": "B"}])
    with pytest.raises(ValueError):
        parse_tree([{"id": NONE_ID, "path": "A"}])
    with pytest.raises(ValueError):
        parse_tree([])


@pytest.mark.parametrize("make", ["model", "stub"])
def test_choice_is_always_a_given_id(sorter, make):
    s = sorter if make == "model" else KeywordSorter()
    results = s.classify(parse_tree(TREE), FILES)
    allowed = {f["id"] for f in TREE} | {NONE_ID}
    assert [r["file"] for r in results] == ["a", "b"]
    for r in results:
        assert r["choice"] in allowed
        assert 0.0 <= r["confidence"] <= 1.0
        assert all(t["folder"] in allowed for t in r["top"])


def test_key_order_invariance(sorter):
    tree = parse_tree(TREE)
    a = sorter.distributions(tree, [{"name": "x.pdf", "text": "hello", "kind": "PDF"}])[0]
    b = sorter.distributions(tree, [{"kind": "PDF", "text": "hello", "name": "x.pdf"}])[0]
    assert max(abs(a[k] - b[k]) for k in a) < 1e-5


def test_single_folder_tree_still_has_none_option(sorter):
    (dist,) = sorter.distributions(parse_tree(TREE[:1]), FILES[:1])
    assert set(dist) == {"f1", NONE_ID}


def test_checkpoint_round_trip(sorter, tmp_path):
    save_checkpoint(sorter.model, tmp_path, {"version": "rt"})
    model, meta = load_checkpoint(tmp_path, torch.device("cpu"))
    assert meta["version"] == "rt" and model.cfg == default_config()
    a = sorter.distributions(parse_tree(TREE), FILES)
    b = FileSorter(model).distributions(parse_tree(TREE), FILES)
    assert max(abs(x[k] - y[k]) for x, y in zip(a, b) for k in x) < 5e-3  # fp16 weights


def test_protocol_round_trip():
    reqs = [
        {"id": 1, "op": "health"},
        {"id": 2, "op": "classify", "tree": TREE, "files": [{"id": f["id"], "state": f} for f in FILES]},
        {"id": 3, "op": "nope"},
        {"id": 4, "op": "classify", "tree": TREE, "files": [{"id": "x"}]},
        {"id": 5, "op": "shutdown"},
        {"id": 6, "op": "health"},  # after shutdown: never answered
    ]
    out = io.StringIO()
    Server(KeywordSorter()).serve(io.StringIO("\n".join(json.dumps(r) for r in reqs) + "\nnot json\n"), out)
    resps = [json.loads(line) for line in out.getvalue().splitlines()]
    assert [r["id"] for r in resps] == [1, 2, 3, 4, 5]
    assert resps[0]["protocol"] == PROTOCOL_VERSION
    assert len(resps[1]["results"]) == 2
    assert resps[2]["ok"] is False and resps[3]["ok"] is False


def test_engine_is_self_contained():
    """open-jev was folded into decision.py; nothing may import it again."""
    import pathlib

    pkg = pathlib.Path(__file__).parents[1] / "jevsort_engine"
    offenders = [p.name for p in pkg.glob("*.py") if "import open_jev" in p.read_text() or "from open_jev" in p.read_text()]
    assert offenders == []
    assert not (pkg.parent / "third_party").exists()


def test_old_architecture_checkpoints_are_refused(sorter, tmp_path):
    import json

    save_checkpoint(sorter.model, tmp_path, {"version": "x"})
    cfg = json.loads((tmp_path / "config.json").read_text())
    cfg["arch"] = "jev"
    (tmp_path / "config.json").write_text(json.dumps(cfg))
    with pytest.raises(ValueError, match="only 'minilm'"):
        load_checkpoint(tmp_path, torch.device("cpu"))
