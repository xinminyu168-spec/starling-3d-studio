"""Face-owned Voronoi fracture of a character GLB into shards (offline Blender tool).

Each triangle of the source belongs to exactly one shard (nearest seed to the triangle
centroid), so no geometry is cut and reassembly is exact. Every shard is its own object
(one glTF node) whose origin is the shard vertex centroid; UVs and material slots are kept.

Usage:
  blender -b --python fracture_character.py -- IN.glb OUT.glb [--shards 300] [--seed 7]
  python fracture_character.py -- IN.glb OUT.glb [--shards 300] [--seed 7]   # bpy module
"""
import random
import sys

import bpy
import bmesh
from mathutils import Vector
from mathutils.kdtree import KDTree


def sample_seeds(centroids, areas, count, seed):
    """Area-weighted pick of `count` distinct triangle centroids (deterministic per seed)."""
    n = len(centroids)
    count = max(0, min(count, n))
    rng = random.Random(seed)
    weights = [max(a, 1e-12) for a in areas]
    chosen = []
    # Efraimidis-Spirakis weighted sampling without replacement.
    keys = [(rng.random() ** (1.0 / w), i) for i, w in enumerate(weights)]
    keys.sort(reverse=True)
    chosen = [i for _, i in keys[:count]]
    chosen.sort()
    return [centroids[i].copy() for i in chosen]


def assign_cells(centroids, seeds):
    """Index of the nearest seed for each centroid."""
    kd = KDTree(len(seeds))
    for i, s in enumerate(seeds):
        kd.insert(s, i)
    kd.balance()
    return [kd.find(c)[1] for c in centroids]


def fracture_object(obj, count, seed):
    """Split `obj` into face-owned shard objects. Returns the new objects."""
    mw = obj.matrix_world.copy()
    src = obj.data
    # Triangulate through a modifier on a temp object so custom (split) normals survive.
    tmp = obj.copy()
    tmp.data = src.copy()
    bpy.context.scene.collection.objects.link(tmp)
    tmp.modifiers.new("tri", "TRIANGULATE").min_vertices = 4
    bpy.context.view_layer.update()
    ev = tmp.evaluated_get(bpy.context.evaluated_depsgraph_get())
    tri = bpy.data.meshes.new_from_object(ev)
    bpy.data.objects.remove(tmp)
    # world-space per-loop normals of the triangulated source
    nmat = mw.to_3x3().inverted_safe().transposed()
    loop_normals = [(nmat @ n.vector).normalized() for n in tri.corner_normals]
    loop_start = [p.loop_start for p in tri.polygons]
    bm = bmesh.new()
    bm.from_mesh(tri)
    bm.faces.ensure_lookup_table()

    wcent = [mw @ f.calc_center_median() for f in bm.faces]
    areas = [f.calc_area() for f in bm.faces]
    seeds = sample_seeds(wcent, areas, count, seed)
    cells = assign_cells(wcent, seeds)

    uv_layers = list(bm.loops.layers.uv.values())
    uv_names = [l.name for l in uv_layers]
    by_cell = {}
    for fi, c in enumerate(cells):
        by_cell.setdefault(c, []).append(fi)

    collections = obj.users_collection or [bpy.context.scene.collection]
    shards, centers = [], []
    for k, cell in enumerate(sorted(by_cell)):
        faces = [bm.faces[i] for i in by_cell[cell]]
        sb = bmesh.new()
        slayers = [sb.loops.layers.uv.new(n) for n in uv_names]
        nrm = []
        vmap = {}
        for f in faces:
            for v in f.verts:
                if v.index not in vmap:
                    vmap[v.index] = sb.verts.new(mw @ v.co)
        centroid = sum((v.co for v in vmap.values()), Vector()) / len(vmap)
        for v in vmap.values():
            v.co -= centroid
        for f in faces:
            nf = sb.faces.new([vmap[v.index] for v in f.verts])
            nf.material_index = f.material_index
            nf.smooth = f.smooth
            nrm.extend(loop_normals[loop_start[f.index] + j] for j in range(len(f.verts)))
            for src_l, dst_l in zip(f.loops, nf.loops):
                for sl, dl in zip(uv_layers, slayers):
                    dst_l[dl].uv = src_l[sl].uv
        me = bpy.data.meshes.new(f"{obj.name}_shard_{k:04d}")
        sb.to_mesh(me)
        sb.free()
        me.normals_split_custom_set(nrm)
        for m in src.materials:
            me.materials.append(m)
        so = bpy.data.objects.new(me.name, me)
        so.location = centroid
        for col in collections:
            col.objects.link(so)
        so["shard_index"] = k
        shards.append(so)
        centers.append(centroid.z)
    bm.free()
    bpy.data.meshes.remove(tri)
    bpy.context.view_layer.update()

    lo, hi = min(centers), max(centers)
    span = (hi - lo) or 1.0
    for so, z in zip(shards, centers):
        so["shard_order"] = (z - lo) / span
    return shards


def _parse(argv):
    import argparse
    args = argv[argv.index("--") + 1:] if "--" in argv else argv[1:]
    p = argparse.ArgumentParser(prog="fracture_character.py")
    p.add_argument("input")
    p.add_argument("output")
    p.add_argument("--shards", type=int, default=300)
    p.add_argument("--seed", type=int, default=7)
    return p.parse_args(args)


def main(argv=None):
    a = _parse(sys.argv if argv is None else argv)
    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=a.input)
    meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    if not meshes:
        raise SystemExit("no mesh objects in input")
    bpy.ops.object.select_all(action="DESELECT")
    for o in meshes:
        o.select_set(True)
    bpy.context.view_layer.objects.active = meshes[0]
    if len(meshes) > 1:
        bpy.ops.object.join()
    src = bpy.context.view_layer.objects.active
    shards = fracture_object(src, a.shards, a.seed)
    for o in list(bpy.context.scene.objects):
        if o not in shards:
            bpy.data.objects.remove(o, do_unlink=True)
    bpy.ops.object.select_all(action="DESELECT")
    for o in shards:
        o.select_set(True)
    bpy.context.view_layer.objects.active = shards[0]
    bpy.ops.export_scene.gltf(filepath=a.output, export_format="GLB", use_selection=True,
                              export_extras=True, export_image_format="AUTO")
    print(f"fractured into {len(shards)} shards -> {a.output}")


if __name__ == "__main__":
    main()
