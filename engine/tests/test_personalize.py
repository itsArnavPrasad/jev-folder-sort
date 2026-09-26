import torch

from jevsort_engine.model import build_model, load_checkpoint, save_checkpoint
from jevsort_engine.personalize import MIN_EXAMPLES, personalize

TREE = [{"id": "a", "path": "Alpha", "description": ""}, {"id": "b", "path": "Beta", "description": ""}]


def examples(n):
    out = []
    for i in range(n):
        if i % 2:
            out.append({"state": {"name": f"banana bread recipe {i}.txt", "text": "banana flour sugar oven"}, "target": "a"})
        else:
            out.append({"state": {"name": f"rocket launch log {i}.txt", "text": "rocket orbit thrust launch"}, "target": "b"})
    return out


def base_ckpt(tmp_path):
    torch.manual_seed(0)
    save_checkpoint(build_model(pretrained_embeddings=False), tmp_path / "base", {"version": "base-test"})
    return tmp_path / "base"


def test_too_few_examples_does_nothing(tmp_path):
    base = base_ckpt(tmp_path)
    r = personalize(base, tmp_path / "user", TREE, examples(MIN_EXAMPLES - 1) + [{"state": {"name": "x"}, "target": "gone"}])
    assert r["activated"] is False and r["dropped"] == 1
    assert not (tmp_path / "user").exists()


def test_learns_users_mapping_and_activates(tmp_path):
    base = base_ckpt(tmp_path)
    r = personalize(base, tmp_path / "user", TREE, examples(30), steps=120, replay=False)
    assert r["new_accuracy"] >= r["current_accuracy"]
    assert r["new_accuracy"] >= 0.8, r
    assert r["activated"] and (tmp_path / "user" / "model.safetensors").exists()
    _, meta = load_checkpoint(tmp_path / "user", torch.device("cpu"))
    assert meta["personalized_from"] == "base-test" and "+user." in meta["version"]


def test_report_has_per_folder_and_threshold(tmp_path):
    from jevsort_engine.personalize import suggest_threshold

    base = base_ckpt(tmp_path)
    r = personalize(base, tmp_path / "user", TREE, examples(30), steps=60, replay=False, unfreeze_top=1)
    assert set(r["per_folder"]) <= {"Alpha", "Beta"} and r["unfrozen_layers"] == 1
    assert sum(v["held_out"] for v in r["per_folder"].values()) == r["holdout"]
    assert r["examples_per_folder"] == {"Alpha": 15, "Beta": 15}
    assert suggest_threshold([("a", 0.99, "a")] * 9 + [("b", 0.6, "a")]) == 0.65
    assert suggest_threshold([("a", 0.99, "b")] * 10) is None
