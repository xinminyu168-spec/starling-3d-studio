import json
import subprocess
import sys
from pathlib import Path

import pytest

from conftest import MATERIALS, import_glb

SCRIPT = Path(__file__).resolve().parents[1] / "fracture_character.py"


def load_source(fixture_glb):
    meshes = import_glb(fixture_glb)
    assert len(meshes) == 1
    return meshes[0]


def loop_signature(objs):
    """Sorted multiset of (world position, UV) per face corner, per UV layer."""
    sig = []
    for o in objs:
        me = o.data
        mw = o.matrix_world
        for p in me.polygons:
            for li in p.loop_indices:
                pos = mw @ me.vertices[me.loops[li].vertex_index].co
                uvs = tuple(
                    tuple(round(c, 5) for c in layer.data[li].uv) for layer in me.uv_layers
                )
                sig.append((tuple(round(c, 5) for c in pos), uvs))
    return sorted(sig)


def test_union_preserves_faces(fixture_glb):
    import fracture_character as fc
    src = load_source(fixture_glb)
    src_faces = len(src.data.polygons)
    src_sig = loop_signature([src])
    shards = fc.fracture_object(src, 300, 7)
    assert sum(len(s.data.polygons) for s in shards) == src_faces
    assert loop_signature(shards) == src_sig


def test_uv_and_materials_preserved(fixture_glb):
    import fracture_character as fc
    src = load_source(fixture_glb)
    uv_names = [l.name for l in src.data.uv_layers]
    assert uv_names
    shards = fc.fracture_object(src, 300, 7)
    names = set()
    for s in shards:
        assert [l.name for l in s.data.uv_layers] == uv_names
        for p in s.data.polygons:
            names.add(s.data.materials[p.material_index].name)
    assert names == set(MATERIALS)


def test_order_range_and_bottom_first(fixture_glb):
    import fracture_character as fc
    src = load_source(fixture_glb)
    shards = fc.fracture_object(src, 300, 7)
    orders = [s["shard_order"] for s in shards]
    assert all(0.0 <= o <= 1.0 for o in orders)
    lowest = min(shards, key=lambda s: s.location.z)
    assert abs(lowest["shard_order"] - 0.0) < 1e-6
    assert abs(max(orders) - 1.0) < 1e-6
    assert sorted(s["shard_index"] for s in shards) == list(range(len(shards)))


def test_deterministic(fixture_glb):
    import fracture_character as fc

    def counts(seed):
        src = load_source(fixture_glb)
        return [len(s.data.polygons) for s in fc.fracture_object(src, 300, seed)]

    assert counts(7) == counts(7)
    assert counts(7) != counts(8)


def test_count_bounds(fixture_glb):
    import fracture_character as fc
    src = load_source(fixture_glb)
    shards = fc.fracture_object(src, 300, 7)
    assert 200 <= len(shards) <= 300
    assert all(len(s.data.polygons) > 0 for s in shards)


def test_cli_roundtrip(fixture_glb, tmp_path):
    out = tmp_path / "out.glb"
    r = subprocess.run([sys.executable, str(SCRIPT), "--", str(fixture_glb), str(out),
                        "--shards", "300", "--seed", "7"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert out.exists()
    meshes = import_glb(out)
    assert 200 <= len(meshes) <= 300
    for o in meshes:
        assert "shard_order" in o.keys()
    # single binary buffer, original material names
    data = out.read_bytes()
    jlen = int.from_bytes(data[12:16], "little")
    doc = json.loads(data[20:20 + jlen])
    assert len(doc["buffers"]) == 1
    assert {m["name"] for m in doc["materials"]} == set(MATERIALS)
    assert len(doc["nodes"]) == len(meshes)


def normal_signature(objs):
    """Sorted multiset of (world position, world split normal) per face corner."""
    sig = []
    for o in objs:
        me = o.data
        mw = o.matrix_world
        nm = mw.to_3x3().inverted_safe().transposed()
        for p in me.polygons:
            for li in p.loop_indices:
                pos = mw @ me.vertices[me.loops[li].vertex_index].co
                n = (nm @ me.corner_normals[li].vector).normalized()
                sig.append((tuple(round(c, 3) + 0.0 for c in pos), tuple(n)))
    return sig


def assert_same_normals(a, b, tol=2e-3):
    """Multiset equality of (position, normal) with a float tolerance on normals."""
    from collections import defaultdict
    assert len(a) == len(b)
    buckets = defaultdict(list)
    for pos, n in a:
        buckets[pos].append(n)
    for pos, n in b:
        cands = buckets[pos]
        for i, m in enumerate(cands):
            if max(abs(x - y) for x, y in zip(n, m)) <= tol:
                cands.pop(i)
                break
        else:
            raise AssertionError(f"no matching normal at {pos}: {n}")


def test_normals_preserved(fixture_glb, tmp_path):
    import fracture_character as fc
    src = load_source(fixture_glb)
    src_sig = normal_signature([src])
    # smooth part really has non-flat normals (guards the fixture)
    assert len({tuple(round(c, 2) for c in s[1]) for s in src_sig}) > 1000
    shards = fc.fracture_object(src, 300, 7)
    assert_same_normals(normal_signature(shards), src_sig)

    out = tmp_path / "normals.glb"
    r = subprocess.run([sys.executable, str(SCRIPT), "--", str(fixture_glb), str(out),
                        "--shards", "300", "--seed", "7"], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    assert_same_normals(normal_signature(import_glb(out)), src_sig)
