import importlib.util, json, struct, sys
from pathlib import Path
import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "build-signed-asset.py"
spec = importlib.util.spec_from_file_location("build_signed_asset", SCRIPT)
bsa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bsa)

SHA = "ab" * 32


def make_glb(path, doc, bin_data=b"\0\0\0\0"):
    j = json.dumps(doc).encode()
    j += b" " * (-len(j) % 4)
    b = bin_data + b"\0" * (-len(bin_data) % 4)
    total = 12 + 8 + len(j) + 8 + len(b)
    path.write_bytes(
        struct.pack("<3I", 0x46546C67, 2, total)
        + struct.pack("<2I", len(j), 0x4E4F534A) + j
        + struct.pack("<2I", len(b), 0x004E4942) + b
    )
    return path


def shard_doc(nodes, **over):
    doc = {
        "asset": {"version": "2.0"},
        "nodes": [{"name": f"shard_{i}"} for i in range(nodes)],
        "materials": [{"name": n} for n in ("General", "Skin_candidate", "Hair_candidate")],
        "buffers": [{"byteLength": 4}],
        "images": [{"bufferView": 0, "mimeType": "image/png"}],
    }
    doc.update(over)
    return doc


def test_semantic8_payload_unchanged():
    got = bsa.make_payload("semantic8", 1234, SHA, 7, None, bsa.SOURCE)
    expected = (
        '{"id":7,"minAppVersion":82,"package":"com.xs.character.viewer",'
        '"profile":"semantic8","schema":1,"sha256":"' + SHA + '","size":1234,'
        '"sourceSha256":"97c80d3a7f5b8e6412687ab30574fa4efdb5cd4db0a3115356de426ae411e379"}'
    )
    assert got == expected.encode()


def test_shards1_payload_fields():
    src = "cd" * 32
    got = json.loads(bsa.make_payload("shards1", 99, SHA, 9, "hero-1", src))
    assert got == {
        "schema": 1, "package": "com.xs.character.viewer", "profile": "shards1",
        "minAppVersion": 83, "id": 9, "size": 99, "sha256": SHA,
        "characterId": "hero-1", "sourceSha256": src,
    }
    raw = bsa.make_payload("shards1", 99, SHA, 9, "hero-1", src)
    assert b" " not in raw and list(json.loads(raw)) == sorted(json.loads(raw))


def test_shards1_requires_character_and_source():
    base = ["m.glb", "o.zip", "--id", "5", "--key", "k", "--cert", "c", "--profile", "shards1"]
    for extra in ([], ["--character-id", "hero"], ["--source-sha256", "cd" * 32],
                  ["--character-id", "Bad_ID", "--source-sha256", "cd" * 32],
                  ["--character-id", "hero", "--source-sha256", "xyz"]):
        with pytest.raises(SystemExit):
            bsa.parse_args(base + extra)
    a = bsa.parse_args(base + ["--character-id", "hero", "--source-sha256", "cd" * 32])
    assert a.profile == "shards1"
    assert bsa.parse_args(["m.glb", "o.zip", "--id", "5", "--key", "k", "--cert", "c"]).profile == "semantic8"


def test_check_shards_rejects_external_buffer(tmp_path):
    p = make_glb(tmp_path / "a.glb", shard_doc(60, buffers=[{"uri": "x.bin", "byteLength": 4}]))
    with pytest.raises(ValueError):
        bsa.check_shards_model(p)
    p = make_glb(tmp_path / "b.glb", shard_doc(60, images=[{"uri": "x.png"}]))
    with pytest.raises(ValueError):
        bsa.check_shards_model(p)


def test_check_shards_node_bounds(tmp_path):
    with pytest.raises(ValueError):
        bsa.check_shards_model(make_glb(tmp_path / "49.glb", shard_doc(49)))
    p = make_glb(tmp_path / "50.glb", shard_doc(50))
    assert bsa.check_shards_model(p) == p.stat().st_size
    with pytest.raises(ValueError):
        bsa.check_shards_model(make_glb(tmp_path / "1001.glb", shard_doc(1001)))


def test_check_shards_rejects_unknown_material(tmp_path):
    p = make_glb(tmp_path / "m.glb", shard_doc(60, materials=[{"name": "Weird"}]))
    with pytest.raises(ValueError):
        bsa.check_shards_model(p)
