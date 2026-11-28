"""Fixtures: a generated humanoid-ish test model. No real character assets are used."""
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

MATERIALS = ["General", "Skin_candidate", "Hair_candidate", "Blue_fabric_candidate",
             "Painted_shell_candidate", "Metal_candidate", "Goggle_lens_candidate",
             "Eye_surface_candidate"]


def _build_model():
    import bpy
    import bmesh
    from mathutils import Matrix

    bpy.ops.wm.read_factory_settings(use_empty=True)
    mats = [bpy.data.materials.new(n) for n in MATERIALS]
    bm = bmesh.new()
    bm.loops.layers.uv.new("UVMap")

    def add(op_result_geom, mat_idx):
        for f in [g for g in op_result_geom if isinstance(g, bmesh.types.BMFace)]:
            f.material_index = mat_idx

    # head: UV sphere
    r = bmesh.ops.create_uvsphere(bm, u_segments=64, v_segments=32, radius=0.5,
                                  matrix=Matrix.Translation((0, 0, 1.9)), calc_uvs=True)
    for f in bm.faces:
        f.material_index = 1
    n0 = len(bm.faces)

    def box(size, loc, mat, cuts=14):
        before = {f for f in bm.faces}
        r = bmesh.ops.create_cube(bm, size=1.0, calc_uvs=True,
                                  matrix=Matrix.Translation(loc) @ Matrix.Diagonal((*size, 1.0)))
        geom = r["verts"]
        edges = list({e for v in geom for e in v.link_edges})
        faces = list({f for v in geom for f in v.link_faces})
        res = bmesh.ops.subdivide_edges(bm, edges=edges, cuts=cuts, use_grid_fill=True,
                                        use_single_edge=False)
        new_faces = [f for f in bm.faces if f not in before]
        for f in new_faces:
            f.material_index = mat

    box((0.8, 0.5, 1.0), (0, 0, 1.0), 3, 12)      # torso
    box((0.25, 0.25, 0.9), (-0.65, 0, 1.1), 4, 8)  # arms
    box((0.25, 0.25, 0.9), (0.65, 0, 1.1), 4, 8)
    box((0.3, 0.3, 0.9), (-0.2, 0, 0.0), 5, 8)     # legs
    box((0.3, 0.3, 0.9), (0.2, 0, 0.0), 5, 8)
    box((0.9, 0.1, 0.1), (0, 0.3, 1.9), 6, 4)      # "goggles"
    box((0.08, 0.08, 0.08), (0, -0.3, 1.9), 7, 2)
    box((0.15, 0.15, 0.15), (0, 0, 2.5), 2, 2)     # hair tuft
    box((0.1, 0.1, 0.1), (0.9, 0, 0.6), 0, 2)
    bmesh.ops.triangulate(bm, faces=bm.faces[:])
    me = bpy.data.meshes.new("Fixture")
    for m in mats:
        me.materials.append(m)
    bm.to_mesh(me)
    bm.free()
    assert len(me.polygons) >= 5000, len(me.polygons)
    obj = bpy.data.objects.new("Fixture", me)
    bpy.context.scene.collection.objects.link(obj)
    return obj


@pytest.fixture(scope="session")
def fixture_glb(tmp_path_factory) -> Path:
    import bpy
    obj = _build_model()
    path = tmp_path_factory.mktemp("fixture") / "fixture.glb"
    bpy.ops.object.select_all(action="DESELECT")
    obj.select_set(True)
    bpy.context.view_layer.objects.active = obj
    bpy.ops.export_scene.gltf(filepath=str(path), export_format="GLB", use_selection=True)
    return path


def import_glb(path):
    import bpy
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=str(path))
    return [o for o in bpy.context.scene.objects if o.type == "MESH"]
