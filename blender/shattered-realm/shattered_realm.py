"""碎域 / Shattered Realm —— 一键生成「碎裂地面 + 悬浮碎石 + 水晶心核」场景（Blender 5.0）

教程流程的程序化复现，并补齐视频里没有展示的成片材质、灯光与后期。

用法
  GUI：在「脚本」工作区打开本文件，点运行。会新建一个名为 Shattered Realm 的场景，不动你已有的场景。
  无头：
    blender -b --python shattered_realm.py -- --save realm.blend
    blender -b --python shattered_realm.py -- --render out.png --frame 150 --quality preview
    blender -b --python shattered_realm.py -- --render frames/ --animation --quality final

参数
  --seed N            整体随机种子（默认 7）
  --quality Q         preview | final（默认 preview）
  --engine E          cycles | eevee（默认 cycles）
  --gray              灰模模式：关掉材质、雾与后期，对照教程 01–09 章的阶段画面
  --frame F           渲染单帧时的帧号（默认 150）
  --resolution WxH    覆盖分辨率
  --samples N         覆盖采样数
"""
import bpy
import bmesh
import math
import random
import sys
from mathutils import Vector, Euler, Matrix

# --------------------------------------------------------------------------------------
# 全局参数（单位：米）。道路沿 +Y 向远处延伸，相机从 Y≈-8 推进到 Y≈58。
# --------------------------------------------------------------------------------------
CFG = dict(
    ground_x=(-38.0, 38.0),
    ground_y=(-16.0, 118.0),
    road_half_width_near=9.5,     # 前方宽
    road_half_width_far=4.0,      # 远端收束（PDF p05：前方宽、远端收束）
    road_lift=1.7,                # 中央抬升高度（PDF p04：比例编辑 G Z）
    subject_pos=(0.0, 100.0, 19.0),
    subject_size=13.0,
    frame_end=300,                # PDF p10：结束帧 300
    fps=30,
)

PALETTE = dict(
    void=(0.004, 0.008, 0.022),
    deep=(0.010, 0.030, 0.080),
    teal=(0.020, 0.420, 0.620),
    ice=(0.550, 0.850, 1.000),
    violet=(0.420, 0.120, 1.000),
    magenta=(1.000, 0.180, 0.620),
    ember=(1.000, 0.520, 0.220),
)


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    opts = dict(seed=7, quality="preview", engine="cycles", gray=False, frame=150,
                render=None, save=None, animation=False, resolution=None, samples=None)
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--gray", "--animation"):
            opts[a[2:]] = True
            i += 1
            continue
        key = a[2:]
        if key not in opts or i + 1 >= len(argv):
            raise SystemExit(f"未知参数或缺少取值: {a}")
        val = argv[i + 1]
        opts[key] = int(val) if key in ("seed", "frame", "samples") else val
        i += 2
    return opts


# --------------------------------------------------------------------------------------
# 小工具
# --------------------------------------------------------------------------------------
def smoothstep(e0, e1, x):
    t = max(0.0, min(1.0, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)


def lerp(a, b, t):
    return a + (b - a) * t


def link_obj(obj, coll):
    coll.objects.link(obj)
    return obj


def new_collection(scene, name, parent=None):
    c = bpy.data.collections.new(name)
    (parent or scene.collection).children.link(c)
    return c


def set_linear_keys(enable=True):
    """5.0 的分层动作 API 改了 fcurves 的位置；直接设新关键帧默认插值最稳（PDF p10：插值线性）。"""
    prefs = bpy.context.preferences.edit
    old = prefs.keyframe_new_interpolation_type
    prefs.keyframe_new_interpolation_type = "LINEAR" if enable else old
    return old


# --------------------------------------------------------------------------------------
# 01–02 地面与碎裂：二维 Voronoi（等价于 Cell Fracture 对薄板的切割）
# --------------------------------------------------------------------------------------
def clip_halfplane(poly, site, other):
    """保留离 site 比离 other 更近的一侧。poly: [(x,y),...] 凸多边形。"""
    mx, my = (site[0] + other[0]) * 0.5, (site[1] + other[1]) * 0.5
    nx, ny = other[0] - site[0], other[1] - site[1]
    out = []
    n = len(poly)
    for k in range(n):
        p, q = poly[k], poly[(k + 1) % n]
        dp = (p[0] - mx) * nx + (p[1] - my) * ny
        dq = (q[0] - mx) * nx + (q[1] - my) * ny
        if dp <= 0:
            out.append(p)
        if (dp <= 0) != (dq <= 0):
            t = dp / (dp - dq)
            out.append((p[0] + (q[0] - p[0]) * t, p[1] + (q[1] - p[1]) * t))
    return out


def road_half_width(y):
    t = smoothstep(CFG["ground_y"][0], CFG["ground_y"][1], y)
    return lerp(CFG["road_half_width_near"], CFG["road_half_width_far"], t)


def sample_sites(rng):
    """中央稀疏（大块）、两侧密集（碎）。用拒绝采样实现随 |x| 变化的点密度。"""
    (x0, x1), (y0, y1) = CFG["ground_x"], CFG["ground_y"]
    sites = []
    target = 2300
    tries = 0
    while len(sites) < target and tries < target * 40:
        tries += 1
        x, y = rng.uniform(x0, x1), rng.uniform(y0, y1)
        w = road_half_width(y)
        spacing = lerp(3.1, 1.45, smoothstep(w * 0.4, w * 1.6, abs(x)))
        if rng.random() < (1.45 / spacing) ** 2:
            sites.append((x, y))
    return sites


def voronoi_cells(sites):
    (x0, x1), (y0, y1) = CFG["ground_x"], CFG["ground_y"]
    bucket = 4.0
    grid = {}
    for i, (x, y) in enumerate(sites):
        grid.setdefault((int(math.floor(x / bucket)), int(math.floor(y / bucket))), []).append(i)
    cells = []
    for i, s in enumerate(sites):
        bx, by = int(math.floor(s[0] / bucket)), int(math.floor(s[1] / bucket))
        cand = []
        for dx in range(-2, 3):
            for dy in range(-2, 3):
                cand.extend(grid.get((bx + dx, by + dy), ()))
        cand = sorted((j for j in cand if j != i),
                      key=lambda j: (sites[j][0] - s[0]) ** 2 + (sites[j][1] - s[1]) ** 2)[:18]
        poly = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
        for j in cand:
            poly = clip_halfplane(poly, s, sites[j])
            if len(poly) < 3:
                break
        if len(poly) >= 3:
            cells.append((s, poly))
    return cells


def add_prism(bm, poly2d, thickness, matrix, glow_layer=None, glow=0.0):
    """把多边形挤出为石板，并用 matrix 摆放。返回新面。"""
    top = [bm.verts.new(matrix @ Vector((x, y, 0.0))) for x, y in poly2d]
    bot = [bm.verts.new(matrix @ Vector((x, y, -thickness))) for x, y in poly2d]
    faces = [bm.faces.new(top), bm.faces.new(list(reversed(bot)))]
    n = len(poly2d)
    for k in range(n):
        faces.append(bm.faces.new((bot[k], bot[(k + 1) % n], top[(k + 1) % n], top[k])))
    if glow_layer is not None:
        for f in faces:
            f[glow_layer] = glow
    return faces


def build_ground(scene, coll, rng, mat):
    """03–04：比例编辑式的中央抬升 + 外侧随机化变换（缩小、倾斜、删除、抬起）。"""
    cells = voronoi_cells(sample_sites(rng))
    bm = bmesh.new()
    glow_layer = bm.faces.layers.float.new("glow")
    kept = 0
    for (sx, sy), poly in cells:
        w = road_half_width(sy)
        ax = abs(sx)
        outer = smoothstep(w * 0.85, w * 3.2, ax)          # 0=道路中央 1=最外侧
        if rng.random() < outer * 0.82:                    # 外侧逐渐破碎消失
            continue
        if sy > CFG["subject_pos"][1] + 2 and ax < 14:     # 道路在主体下方终止
            continue
        cx = sum(p[0] for p in poly) / len(poly)
        cy = sum(p[1] for p in poly) / len(poly)
        gap = lerp(0.10, 0.30, outer) + rng.uniform(0, 0.06)
        shrink = lerp(0.97, 0.62, outer * rng.random())
        local = []
        for x, y in poly:
            vx, vy = x - cx, y - cy
            L = math.hypot(vx, vy) or 1.0
            f = max(0.05, (L - gap) / L) * shrink
            local.append((vx * f, vy * f))
        # 中央抬升（高斯衰减，相当于比例编辑的衰减半径）+ 远端缓慢上扬
        lift = CFG["road_lift"] * math.exp(-(sx / (w * 0.95)) ** 2)
        lift += 0.9 * smoothstep(60, 115, sy) * math.exp(-(sx / w) ** 2)
        z = lift + rng.uniform(-0.18, 0.22)
        tilt = lerp(3.0, 38.0, outer) * (0.4 + rng.random())
        if outer > 0.25 and rng.random() < 0.35:           # 一部分碎片被"掀起"
            z += rng.uniform(0.3, 3.0) * outer
        rot = Euler((math.radians(rng.uniform(-tilt, tilt)),
                     math.radians(rng.uniform(-tilt, tilt)),
                     math.radians(rng.uniform(-6, 6) * (1 + outer * 4))), "XYZ").to_matrix().to_4x4()
        m = Matrix.Translation((cx, cy, z)) @ rot
        thick = lerp(1.1, 0.35, outer) * rng.uniform(0.6, 1.25)
        glow = 1.0 if (rng.random() < lerp(0.045, 0.02, outer) and sy > 12) else 0.0   # 镜头脚下不放发光砖
        add_prism(bm, local, thick, m, glow_layer, glow)
        kept += 1
    me = bpy.data.meshes.new("Ground_cells")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    obj = link_obj(bpy.data.objects.new("Plane_cell", me), coll)
    bev = obj.modifiers.new("Bevel", "BEVEL")
    bev.width, bev.segments, bev.limit_method = 0.045, 1, "ANGLE"
    return obj, kept


def build_shard_sources(coll, rng, mat):
    """05：实例源集合 pt 1 —— 24 块形状各异的碎片，原点在中心。"""
    objs = []
    for i in range(24):
        n = rng.randint(4, 7)
        ang = sorted(rng.uniform(0, math.tau) for _ in range(n))
        r = [rng.uniform(0.55, 1.25) for _ in range(n)]
        poly = [(math.cos(a) * rr * rng.uniform(0.8, 1.6), math.sin(a) * rr) for a, rr in zip(ang, r)]
        # 保证凸性：取凸包
        poly = convex_hull(poly)
        bm = bmesh.new()
        thick = rng.uniform(0.25, 0.8)
        add_prism(bm, poly, thick, Matrix.Translation((0, 0, thick * 0.5)))
        # 让碎片不那么"平"：随机推一推顶点
        for v in bm.verts:
            v.co.z += rng.uniform(-0.12, 0.12)
        me = bpy.data.meshes.new(f"Shard_{i:02d}")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(mat)
        o = link_obj(bpy.data.objects.new(f"Shard_{i:02d}", me), coll)
        b = o.modifiers.new("Bevel", "BEVEL")
        b.width, b.segments, b.limit_method = 0.035, 1, "ANGLE"
        objs.append(o)
    return objs


def convex_hull(pts):
    pts = sorted(set(pts))
    if len(pts) <= 2:
        return pts

    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])

    lower, upper = [], []
    for p in pts:
        while len(lower) >= 2 and cross(lower[-2], lower[-1], p) <= 0:
            lower.pop()
        lower.append(p)
    for p in reversed(pts):
        while len(upper) >= 2 and cross(upper[-2], upper[-1], p) <= 0:
            upper.pop()
        upper.append(p)
    return lower[:-1] + upper[:-1]


def build_spires(coll, rng, mat):
    """远景冰晶山峰（成片截图中道路两侧的尖峰），低多边形锥体。"""
    bm = bmesh.new()
    count = 0
    while count < 44:
        side = rng.choice((-1, 1))
        x = side * rng.uniform(26, 85)
        y = rng.uniform(25, 175)
        if abs(x) < 30 and y > 95:
            continue
        h = rng.uniform(4, 15) * (0.5 + y / 150)
        r = h * rng.uniform(0.18, 0.32)
        mat_ = (Matrix.Translation((x, y, -1.5 + h * 0.5))
                @ Euler((rng.uniform(-0.15, 0.15), rng.uniform(-0.15, 0.15), rng.uniform(0, 6.28))).to_matrix().to_4x4())
        bmesh.ops.create_cone(bm, cap_ends=True, segments=rng.randint(4, 6),
                              radius1=r, radius2=r * rng.uniform(0.0, 0.08), depth=h, matrix=mat_)
        count += 1
    me = bpy.data.meshes.new("Spires")
    bm.to_mesh(me)
    bm.free()
    me.materials.append(mat)
    return link_obj(bpy.data.objects.new("Spires", me), coll)


# --------------------------------------------------------------------------------------
# 06–08 几何节点 scatter：体积散布 + 随机旋转/缩放 + 噪波漂移
# --------------------------------------------------------------------------------------
class NB:
    """极简节点搭建器：按列摆放，方便在节点编辑器里阅读。"""

    def __init__(self, tree):
        self.t = tree
        self.nodes, self.links = tree.nodes, tree.links

    def add(self, kind, x, y, **props):
        n = self.nodes.new(kind)
        n.location = (x * 220, -y * 180)
        for k, v in props.items():
            setattr(n, k, v)
        return n

    def link(self, a, b):
        self.links.new(a, b)


def sock(node, name, kind=None, out=False):
    """按名字（必要时按类型）找 socket；Random Value 等节点有同名不同类型的 socket。"""
    for s in (node.outputs if out else node.inputs):
        if s.name == name and s.enabled and (kind is None or s.type == kind):
            return s
    raise KeyError(f"{node.bl_idname}: {'out' if out else 'in'} {name} {kind}")


def iface(tree, name, io, stype, default=None, lo=None, hi=None):
    s = tree.interface.new_socket(name, in_out=io, socket_type=stype)
    if default is not None:
        s.default_value = default
    if lo is not None:
        s.min_value = lo
    if hi is not None:
        s.max_value = hi
    return s


def build_scatter_group():
    t = bpy.data.node_groups.new("scatter", "GeometryNodeTree")
    iface(t, "Geometry", "INPUT", "NodeSocketGeometry")
    iface(t, "Instances", "INPUT", "NodeSocketCollection")
    iface(t, "Density", "INPUT", "NodeSocketFloat", 0.02, 0.0, 100.0)
    iface(t, "Seed", "INPUT", "NodeSocketInt", 0)
    iface(t, "Scale Min", "INPUT", "NodeSocketFloat", 0.1, 0.0)
    iface(t, "Scale Max", "INPUT", "NodeSocketFloat", 1.3, 0.0)
    iface(t, "Rotation Range", "INPUT", "NodeSocketFloat", 4.0, 0.0)
    iface(t, "Drift", "INPUT", "NodeSocketFloat", 6.0, 0.0)
    iface(t, "Drift Speed", "INPUT", "NodeSocketFloat", 0.05, 0.0)
    iface(t, "Spin", "INPUT", "NodeSocketFloat", 0.15, 0.0)
    iface(t, "Corridor", "INPUT", "NodeSocketFloat", 0.0, 0.0)
    iface(t, "Corridor Top", "INPUT", "NodeSocketFloat", 0.0)
    iface(t, "Material", "INPUT", "NodeSocketMaterial")
    iface(t, "Geometry", "OUTPUT", "NodeSocketGeometry")

    b = NB(t)
    gi = b.add("NodeGroupInput", 0, 0)
    go = b.add("NodeGroupOutput", 12, 0)

    # 主链（PDF p07）：网格转体积 → 体积内分布点 → 实例化于点上 → 输出
    m2v = b.add("GeometryNodeMeshToVolume", 1, 0)
    m2v.inputs["Resolution Mode"].default_value = "Amount"
    m2v.inputs["Voxel Amount"].default_value = 64.0
    m2v.inputs["Interior Band Width"].default_value = 0.2
    b.link(sock(gi, "Geometry", out=True), m2v.inputs["Mesh"])

    dist = b.add("GeometryNodeDistributePointsInVolume", 2, 0)
    b.link(m2v.outputs["Volume"], dist.inputs["Volume"])
    b.link(sock(gi, "Density", out=True), dist.inputs["Density"])
    b.link(sock(gi, "Seed", out=True), dist.inputs["Seed"])

    # 时间：W 接场景秒数，让噪波随时间变化 → 碎石缓慢漂移（手册"时间驱动方式未辨认"处的补全）
    time = b.add("GeometryNodeInputSceneTime", 2, 3)
    tmul = b.add("ShaderNodeMath", 3, 3, operation="MULTIPLY")
    b.link(time.outputs["Seconds"], tmul.inputs[0])
    b.link(sock(gi, "Drift Speed", out=True), tmul.inputs[1])

    # PDF p09：噪波纹理 3D/FBM、缩放 5、细节 2、粗糙度 0.5、间隙度 2、畸变 0；这里用 4D 以便接时间
    pos = b.add("GeometryNodeInputPosition", 2, 2)
    pscale = b.add("ShaderNodeVectorMath", 3, 2, operation="SCALE")
    b.link(pos.outputs["Position"], pscale.inputs[0])
    pscale.inputs["Scale"].default_value = 0.02     # 场景尺度比视频大，先把位置缩回噪波的有效频率
    noise = b.add("ShaderNodeTexNoise", 4, 2, noise_dimensions="4D", noise_type="FBM")
    noise.inputs["Scale"].default_value = 5.0
    noise.inputs["Detail"].default_value = 2.0
    noise.inputs["Roughness"].default_value = 0.5
    noise.inputs["Lacunarity"].default_value = 2.0
    noise.inputs["Distortion"].default_value = 0.0
    b.link(pscale.outputs["Vector"], noise.inputs["Vector"])
    b.link(tmul.outputs[0], noise.inputs["W"])
    center = b.add("ShaderNodeVectorMath", 5, 2, operation="SUBTRACT")
    b.link(noise.outputs["Color"], center.inputs[0])
    center.inputs[1].default_value = (0.5, 0.5, 0.5)
    amp = b.add("ShaderNodeVectorMath", 6, 2, operation="SCALE")       # 噪波 × 值 = 偏移幅度
    b.link(center.outputs["Vector"], amp.inputs[0])
    b.link(sock(gi, "Drift", out=True), amp.inputs["Scale"])
    # 镜头走廊（补充）：删掉 |x| < Corridor 且 z < Corridor Top 的点，给道路和主体留出视线
    cpos = b.add("GeometryNodeInputPosition", 2, -3)
    csep = b.add("ShaderNodeSeparateXYZ", 3, -3)
    b.link(cpos.outputs["Position"], csep.inputs[0])
    cabs = b.add("ShaderNodeMath", 4, -3, operation="ABSOLUTE")
    b.link(csep.outputs["X"], cabs.inputs[0])
    cx = b.add("ShaderNodeMath", 5, -3, operation="LESS_THAN")
    b.link(cabs.outputs[0], cx.inputs[0])
    b.link(sock(gi, "Corridor", out=True), cx.inputs[1])
    cz = b.add("ShaderNodeMath", 5, -4, operation="LESS_THAN")
    b.link(csep.outputs["Z"], cz.inputs[0])
    b.link(sock(gi, "Corridor Top", out=True), cz.inputs[1])
    cand = b.add("ShaderNodeMath", 6, -3, operation="MULTIPLY")
    b.link(cx.outputs[0], cand.inputs[0])
    b.link(cz.outputs[0], cand.inputs[1])
    dele = b.add("GeometryNodeDeleteGeometry", 3, -1, domain="POINT")
    b.link(dist.outputs["Points"], dele.inputs["Geometry"])
    b.link(cand.outputs[0], dele.inputs["Selection"])
    setpos = b.add("GeometryNodeSetPosition", 4, 0)
    b.link(dele.outputs["Geometry"], setpos.inputs["Geometry"])
    b.link(amp.outputs["Vector"], setpos.inputs["Offset"])

    # 每个碎片一个随机 tint，材质用它决定少量碎片发光、以及发光颜色
    tint = b.add("FunctionNodeRandomValue", 3, 5, data_type="FLOAT")
    b.link(sock(gi, "Seed", out=True), sock(tint, "Seed"))
    store = b.add("GeometryNodeStoreNamedAttribute", 4, 0, data_type="FLOAT", domain="POINT")
    store.inputs["Name"].default_value = "tint"
    b.link(setpos.outputs["Geometry"], store.inputs["Geometry"])
    b.link(sock(tint, "Value", "VALUE", out=True), sock(store, "Value", "VALUE"))

    # PDF p08：随机值（向量）× 值 → 旋转；再加随时间的自转
    rrot = b.add("FunctionNodeRandomValue", 4, 6, data_type="FLOAT_VECTOR")
    sock(rrot, "Max", "VECTOR").default_value = (1, 1, 1)
    b.link(sock(gi, "Seed", out=True), sock(rrot, "Seed"))
    rmul = b.add("ShaderNodeVectorMath", 5, 6, operation="SCALE")
    b.link(sock(rrot, "Value", "VECTOR", out=True), rmul.inputs[0])
    b.link(sock(gi, "Rotation Range", out=True), rmul.inputs["Scale"])
    rspin = b.add("FunctionNodeRandomValue", 4, 8, data_type="FLOAT_VECTOR")
    sock(rspin, "Min", "VECTOR").default_value = (-1, -1, -1)
    sock(rspin, "Max", "VECTOR").default_value = (1, 1, 1)
    sm = b.add("ShaderNodeMath", 4, 9.5, operation="MULTIPLY")
    b.link(time.outputs["Seconds"], sm.inputs[0])
    b.link(sock(gi, "Spin", out=True), sm.inputs[1])
    spin = b.add("ShaderNodeVectorMath", 5, 8, operation="SCALE")
    b.link(sock(rspin, "Value", "VECTOR", out=True), spin.inputs[0])
    b.link(sm.outputs[0], spin.inputs["Scale"])
    radd = b.add("ShaderNodeVectorMath", 6, 7, operation="ADD")
    b.link(rmul.outputs["Vector"], radd.inputs[0])
    b.link(spin.outputs["Vector"], radd.inputs[1])
    e2r = b.add("FunctionNodeEulerToRotation", 7, 7)
    b.link(radd.outputs["Vector"], e2r.inputs["Euler"])

    # PDF p08：浮点随机值 0.1–1.3 → 缩放
    rscale = b.add("FunctionNodeRandomValue", 6, 10, data_type="FLOAT")
    b.link(sock(gi, "Scale Min", out=True), sock(rscale, "Min", "VALUE"))
    b.link(sock(gi, "Scale Max", out=True), sock(rscale, "Max", "VALUE"))
    b.link(sock(gi, "Seed", out=True), sock(rscale, "Seed"))

    # PDF p07：集合信息 pt 1（分离子级、重置子级）→ 实例；实例化节点勾选「选择实例」
    cinfo = b.add("GeometryNodeCollectionInfo", 6, -2, transform_space="ORIGINAL")
    b.link(sock(gi, "Instances", out=True), cinfo.inputs["Collection"])
    cinfo.inputs["Separate Children"].default_value = True
    cinfo.inputs["Reset Children"].default_value = True
    iop = b.add("GeometryNodeInstanceOnPoints", 8, 0)
    iop.inputs["Pick Instance"].default_value = True
    b.link(store.outputs["Geometry"], iop.inputs["Points"])
    b.link(cinfo.outputs["Instances"], iop.inputs["Instance"])
    b.link(e2r.outputs["Rotation"], iop.inputs["Rotation"])
    b.link(sock(rscale, "Value", "VALUE", out=True), iop.inputs["Scale"])

    # 实现实例（让 tint 落到网格上，材质可读）；若传入材质则覆盖
    real = b.add("GeometryNodeRealizeInstances", 9, 0)
    b.link(iop.outputs["Instances"], real.inputs["Geometry"])
    setm = b.add("GeometryNodeSetMaterial", 10, 1)
    b.link(real.outputs["Geometry"], setm.inputs["Geometry"])
    b.link(sock(gi, "Material", out=True), setm.inputs["Material"])
    sw = b.add("GeometryNodeSwitch", 11, 0, input_type="GEOMETRY")
    iface(t, "Override Material", "INPUT", "NodeSocketBool", False)
    b.link(sock(gi, "Override Material", out=True), sw.inputs["Switch"])
    b.link(real.outputs["Geometry"], sw.inputs["False"])
    b.link(setm.outputs["Geometry"], sw.inputs["True"])
    b.link(sw.outputs["Output"], go.inputs[0])
    return t


def make_container(coll, name, loc, half):
    """散布容器盒。缩放直接写进网格（相当于 Ctrl+A 应用缩放），
    否则几何节点在局部空间散布的碎片会被物体缩放一起拉伸变形。"""
    bm = bmesh.new()
    bmesh.ops.create_cube(bm, size=2.0)
    for v in bm.verts:
        v.co = Vector((v.co.x * half[0], v.co.y * half[1], v.co.z * half[2]))
    me = bpy.data.meshes.new(name)
    bm.to_mesh(me)
    bm.free()
    o = link_obj(bpy.data.objects.new(name, me), coll)
    o.location = loc
    o.display_type = "WIRE"
    return o


def add_scatter(obj, group, coll, **values):
    mod = obj.modifiers.new("scatter", "NODES")
    mod.node_group = group
    values.setdefault("Instances", coll)
    for item in group.interface.items_tree:
        if item.item_type == "SOCKET" and item.in_out == "INPUT" and item.name in values:
            mod[item.identifier] = values[item.name]
    return mod


# --------------------------------------------------------------------------------------
# 材质（成片部分：视频未展示，按片头/结尾截图的色调设计）
# --------------------------------------------------------------------------------------
def principled(mat):
    mat.use_nodes = True
    return mat.node_tree.nodes["Principled BSDF"], mat.node_tree


def mat_stone(gray):
    m = bpy.data.materials.new("Shard Stone")
    p, t = principled(m)
    if gray:
        p.inputs["Base Color"].default_value = (0.55, 0.55, 0.55, 1)
        p.inputs["Roughness"].default_value = 0.6
        return m
    N, L = t.nodes, t.links
    # 表面：深蓝黑玄武岩，顶面带一点冰霜（法线朝上越多越亮）
    geo = N.new("ShaderNodeNewGeometry")
    sep = N.new("ShaderNodeSeparateXYZ")
    L.new(geo.outputs["Normal"], sep.inputs[0])
    frost = N.new("ShaderNodeMapRange")
    frost.inputs["From Min"].default_value = 0.55
    frost.inputs["From Max"].default_value = 0.98
    L.new(sep.outputs["Z"], frost.inputs["Value"])
    noise = N.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 3.0
    noise.inputs["Detail"].default_value = 6.0
    mix = N.new("ShaderNodeMix")
    mix.data_type = "RGBA"
    mix.inputs["A"].default_value = (0.012, 0.018, 0.032, 1)
    mix.inputs["B"].default_value = (0.10, 0.15, 0.24, 1)
    fm = N.new("ShaderNodeMath"); fm.operation = "MULTIPLY"
    L.new(frost.outputs["Result"], fm.inputs[0])
    L.new(noise.outputs["Fac"], fm.inputs[1])
    L.new(fm.outputs[0], mix.inputs["Factor"])
    L.new(mix.outputs["Result"], p.inputs["Base Color"])
    p.inputs["Metallic"].default_value = 0.35
    rr = N.new("ShaderNodeMapRange")
    rr.inputs["To Min"].default_value = 0.12
    rr.inputs["To Max"].default_value = 0.45
    L.new(noise.outputs["Fac"], rr.inputs["Value"])
    L.new(rr.outputs["Result"], p.inputs["Roughness"])
    p.inputs["Coat Weight"].default_value = 0.4
    p.inputs["Coat Roughness"].default_value = 0.08
    # 发光：地面用面属性 glow，悬浮碎石用 tint（>0.93 的约 7% 发光）
    ag = N.new("ShaderNodeAttribute"); ag.attribute_name = "glow"
    at = N.new("ShaderNodeAttribute"); at.attribute_name = "tint"
    th = N.new("ShaderNodeMath"); th.operation = "GREATER_THAN"
    th.inputs[1].default_value = 0.955
    L.new(at.outputs["Fac"], th.inputs[0])
    mx = N.new("ShaderNodeMath"); mx.operation = "MAXIMUM"
    L.new(ag.outputs["Fac"], mx.inputs[0])
    L.new(th.outputs[0], mx.inputs[1])
    ramp = N.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].color = (*PALETTE["ice"], 1)
    cr.elements[1].position = 0.6
    cr.elements[1].color = (*PALETTE["violet"], 1)
    e = cr.elements.new(0.97)
    e.color = (*PALETTE["magenta"], 1)
    L.new(at.outputs["Fac"], ramp.inputs["Fac"])
    L.new(ramp.outputs["Color"], p.inputs["Emission Color"])
    es = N.new("ShaderNodeMath"); es.operation = "MULTIPLY"
    es.inputs[1].default_value = 3.0
    L.new(mx.outputs[0], es.inputs[0])
    L.new(es.outputs[0], p.inputs["Emission Strength"])
    # 下篇 06：光程 → 混合着色器系数，两路 BSDF 混合。
    # 第二路取近镜面的光泽 BSDF，只在相机直视、且掠射角（菲涅尔）大时生效 → 路面倒映主体与面光，暗部不被冲淡。
    gloss = N.new("ShaderNodeBsdfGlossy") if "ShaderNodeBsdfGlossy" in dir(bpy.types) else N.new("ShaderNodeBsdfAnisotropic")
    gloss.inputs["Roughness"].default_value = 0.035
    gloss.inputs["Color"].default_value = (0.22, 0.28, 0.45, 1)
    lw = N.new("ShaderNodeLayerWeight")
    lw.inputs["Blend"].default_value = 0.3
    lp = N.new("ShaderNodeLightPath")
    fac = N.new("ShaderNodeMath"); fac.operation = "MULTIPLY"
    L.new(lw.outputs["Fresnel"], fac.inputs[0])
    L.new(lp.outputs["Is Camera Ray"], fac.inputs[1])
    fac2 = N.new("ShaderNodeMath"); fac2.operation = "MULTIPLY"
    fac2.inputs[1].default_value = 0.55
    L.new(fac.outputs[0], fac2.inputs[0])
    mixs = N.new("ShaderNodeMixShader")
    L.new(fac2.outputs[0], mixs.inputs["Fac"])
    L.new(p.outputs[0], mixs.inputs[1])
    L.new(gloss.outputs[0], mixs.inputs[2])
    L.new(mixs.outputs[0], t.nodes["Material Output"].inputs["Surface"])
    return m


def mat_emit(name, color, strength):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    t = m.node_tree
    t.nodes.remove(t.nodes["Principled BSDF"])
    em = t.nodes.new("ShaderNodeEmission")
    em.inputs["Color"].default_value = (*color, 1)
    em.inputs["Strength"].default_value = strength
    t.links.new(em.outputs[0], t.nodes["Material Output"].inputs["Surface"])
    return m


def mat_core(gray):
    """心核碎片：按 tint 在 紫 → 品红 → 冰蓝 之间取色，强发光。"""
    if gray:
        return mat_emit("Core", (0.9, 0.9, 0.9), 1.0)
    m = bpy.data.materials.new("Core Ember")
    m.use_nodes = True
    t = m.node_tree
    N, L = t.nodes, t.links
    N.remove(N["Principled BSDF"])
    at = N.new("ShaderNodeAttribute"); at.attribute_name = "tint"
    ramp = N.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].color = (*PALETTE["violet"], 1)
    cr.elements[1].position = 0.55
    cr.elements[1].color = (*PALETTE["magenta"], 1)
    cr.elements.new(0.85).color = (*PALETTE["ice"], 1)
    cr.elements.new(0.97).color = (*PALETTE["ember"], 1)
    L.new(at.outputs["Fac"], ramp.inputs["Fac"])
    em = N.new("ShaderNodeEmission")
    em.inputs["Strength"].default_value = 4.0
    L.new(ramp.outputs["Color"], em.inputs["Color"])
    L.new(em.outputs[0], N["Material Output"].inputs["Surface"])
    return m


def mat_fog(gray):
    """上篇 10 / 下篇 03：fog 盒子。原理化体积接材质输出的 Volume（不是 Surface）；
    密度 = 光程「是否为摄像机射线」× 0.008 —— 雾只被相机看到、不挡灯光，渲染快且不会把灯光吃掉。
    在此基础上再乘一层低频噪波，让雾有团块感（下篇未展示，属补充）。"""
    m = bpy.data.materials.new("Fog")
    m.use_nodes = True
    t = m.node_tree
    N, L = t.nodes, t.links
    N.remove(N["Principled BSDF"])
    vol = N.new("ShaderNodeVolumePrincipled")
    vol.inputs["Color"].default_value = (0.45, 0.62, 1.0, 1)
    vol.inputs["Anisotropy"].default_value = 0.264      # 下篇 08:00 画面值
    vol.inputs["Emission Strength"].default_value = 0.0
    lp = N.new("ShaderNodeLightPath")
    mul = N.new("ShaderNodeMath"); mul.operation = "MULTIPLY"
    L.new(lp.outputs["Is Camera Ray"], mul.inputs[0])
    mul.inputs[1].default_value = 0.008 * 0.35          # 下篇 08:00 相乘值 0.008；本场景纵深约为视频的 2–3 倍，按比例缩小
    tc = N.new("ShaderNodeTexCoord")
    noise = N.new("ShaderNodeTexNoise")
    noise.inputs["Scale"].default_value = 2.2
    noise.inputs["Detail"].default_value = 3.0
    L.new(tc.outputs["Object"], noise.inputs["Vector"])
    mr = N.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = 0.3
    mr.inputs["From Max"].default_value = 0.7
    mr.inputs["To Min"].default_value = 0.15
    mr.inputs["To Max"].default_value = 1.0
    L.new(noise.outputs["Fac"], mr.inputs["Value"])
    # 高度衰减：越高越稀，地平线处最浓
    sep = N.new("ShaderNodeSeparateXYZ")
    L.new(tc.outputs["Object"], sep.inputs[0])
    hf = N.new("ShaderNodeMapRange")
    hf.inputs["From Min"].default_value = -1.0
    hf.inputs["From Max"].default_value = 0.6
    hf.inputs["To Min"].default_value = 1.0
    hf.inputs["To Max"].default_value = 0.1
    L.new(sep.outputs["Z"], hf.inputs["Value"])
    m1 = N.new("ShaderNodeMath"); m1.operation = "MULTIPLY"
    L.new(mr.outputs["Result"], m1.inputs[0])
    L.new(hf.outputs["Result"], m1.inputs[1])
    m2 = N.new("ShaderNodeMath"); m2.operation = "MULTIPLY"
    L.new(mul.outputs[0], m2.inputs[0])
    L.new(m1.outputs[0], m2.inputs[1])
    L.new(m2.outputs[0], vol.inputs["Density"])
    L.new(vol.outputs[0], N["Material Output"].inputs["Volume"])
    return m


def mat_energy(gray):
    """下篇 01/02/08：能量方块外壳 cube blue。原视频用一张能量贴图（未随视频提供），
    这里用 Voronoi 裂纹 + 噪波程序化代替：图像纹理 → 颜色渐变（色阶 0.382）→ 色相/饱和度/明度 → 混合，
    冷色（蓝紫）为主、橙红只落在少数亮纹上，再与透明混合保留"看得见内部"的效果。"""
    m = bpy.data.materials.new("cube blue")
    m.use_nodes = True
    t = m.node_tree
    N, L = t.nodes, t.links
    N.remove(N["Principled BSDF"])
    out = N["Material Output"]
    if gray:
        d = N.new("ShaderNodeBsdfDiffuse")
        L.new(d.outputs[0], out.inputs["Surface"])
        return m
    tc = N.new("ShaderNodeTexCoord")
    warp = N.new("ShaderNodeTexNoise")
    warp.inputs["Scale"].default_value = 0.9
    warp.inputs["Detail"].default_value = 4.0
    L.new(tc.outputs["Object"], warp.inputs["Vector"])
    vmix = N.new("ShaderNodeMix"); vmix.data_type = "VECTOR"
    vmix.inputs["Factor"].default_value = 0.35
    L.new(tc.outputs["Object"], vmix.inputs["A"])
    L.new(warp.outputs["Color"], vmix.inputs["B"])
    vor = N.new("ShaderNodeTexVoronoi")
    vor.feature = "DISTANCE_TO_EDGE"
    vor.inputs["Scale"].default_value = 3.2
    L.new(vmix.outputs["Result"], vor.inputs["Vector"])
    ramp = N.new("ShaderNodeValToRGB")                     # 色阶：亮纹范围
    cr = ramp.color_ramp
    cr.elements[0].position = 0.0
    cr.elements[0].color = (1, 1, 1, 1)
    cr.elements[1].position = 0.0382 * 1.2                 # 对应视频色阶 0.382 的亮纹宽度（按本场景尺度缩放）
    cr.elements[1].color = (0, 0, 0, 1)
    L.new(vor.outputs["Distance"], ramp.inputs["Fac"])
    # 冷暖：大块噪波决定该区域是蓝紫还是橙红
    zone = N.new("ShaderNodeTexNoise")
    zone.inputs["Scale"].default_value = 0.6
    L.new(tc.outputs["Object"], zone.inputs["Vector"])
    zr = N.new("ShaderNodeMapRange")
    zr.inputs["From Min"].default_value = 0.56
    zr.inputs["From Max"].default_value = 0.66
    L.new(zone.outputs["Fac"], zr.inputs["Value"])
    cold = N.new("ShaderNodeMix"); cold.data_type = "RGBA"
    cold.inputs["A"].default_value = (*PALETTE["teal"], 1)
    cold.inputs["B"].default_value = (*PALETTE["violet"], 1)
    L.new(warp.outputs["Fac"], cold.inputs["Factor"])
    col = N.new("ShaderNodeMix"); col.data_type = "RGBA"
    L.new(zr.outputs["Result"], col.inputs["Factor"])
    L.new(cold.outputs["Result"], col.inputs["A"])
    col.inputs["B"].default_value = (*PALETTE["ember"], 1)
    hsv = N.new("ShaderNodeHueSaturation")                 # 视频 02:00：色相 0.5、饱和度/明度 1
    L.new(col.outputs["Result"], hsv.inputs["Color"])
    em = N.new("ShaderNodeEmission")
    L.new(hsv.outputs["Color"], em.inputs["Color"])
    es = N.new("ShaderNodeMath"); es.operation = "MULTIPLY"
    es.inputs[1].default_value = 4.0
    L.new(ramp.outputs["Color"], es.inputs[0])
    L.new(es.outputs[0], em.inputs["Strength"])
    glass = N.new("ShaderNodeBsdfGlass")
    glass.inputs["Roughness"].default_value = 0.02
    glass.inputs["IOR"].default_value = 1.45
    glass.inputs["Color"].default_value = (0.8, 0.88, 1.0, 1)
    tr = N.new("ShaderNodeBsdfTransparent")
    shell = N.new("ShaderNodeMixShader")                   # 混合系数 0.5（视频 02:00）
    shell.inputs["Fac"].default_value = 0.5
    L.new(glass.outputs[0], shell.inputs[1])
    L.new(tr.outputs[0], shell.inputs[2])
    add = N.new("ShaderNodeAddShader")
    L.new(shell.outputs[0], add.inputs[0])
    L.new(em.outputs[0], add.inputs[1])
    L.new(add.outputs[0], out.inputs["Surface"])
    return m


def mat_inner(gray):
    """下篇 02/08：内层 Cube.004 —— 高金属、低粗糙，反射外壳的能量纹（23:00 画面：金属度 0.918、粗糙度 0.050）。"""
    m = bpy.data.materials.new("Cube.004 Inner")
    p, t = principled(m)
    p.inputs["Base Color"].default_value = (0.08, 0.06, 0.16, 1) if not gray else (0.6, 0.6, 0.6, 1)
    p.inputs["Metallic"].default_value = 0.918
    p.inputs["Roughness"].default_value = 0.05
    p.inputs["IOR"].default_value = 1.5
    return m


def build_world(scene, gray):
    w = bpy.data.worlds.new("Nebula")
    scene.world = w
    w.use_nodes = True
    t = w.node_tree
    N, L = t.nodes, t.links
    bg = N["Background"]
    if gray:
        bg.inputs["Color"].default_value = (0.05, 0.05, 0.055, 1)
        bg.inputs["Strength"].default_value = 1.0
        return w
    tc = N.new("ShaderNodeTexCoord")
    dirn = N.new("ShaderNodeVectorMath"); dirn.operation = "NORMALIZE"
    L.new(tc.outputs["Generated"], dirn.inputs[0])

    # 主体方向的星云辉光
    sx, sy, sz = CFG["subject_pos"]
    target = Vector((sx, sy - 0, sz - 4)).normalized()
    dot = N.new("ShaderNodeVectorMath"); dot.operation = "DOT_PRODUCT"
    L.new(dirn.outputs["Vector"], dot.inputs[0])
    dot.inputs[1].default_value = target
    halo = N.new("ShaderNodeMapRange")
    halo.inputs["From Min"].default_value = 0.55
    halo.inputs["From Max"].default_value = 1.0
    L.new(dot.outputs["Value"], halo.inputs["Value"])
    halo_p = N.new("ShaderNodeMath"); halo_p.operation = "POWER"
    halo_p.inputs[1].default_value = 2.2
    L.new(halo.outputs["Result"], halo_p.inputs[0])

    # 斜跨天空的银河带（参考成片里的光弧）
    band_n = Vector((0.85, -0.12, -0.5)).normalized()
    bd = N.new("ShaderNodeVectorMath"); bd.operation = "DOT_PRODUCT"
    L.new(dirn.outputs["Vector"], bd.inputs[0])
    bd.inputs[1].default_value = band_n
    bsq = N.new("ShaderNodeMath"); bsq.operation = "MULTIPLY"
    L.new(bd.outputs["Value"], bsq.inputs[0]); L.new(bd.outputs["Value"], bsq.inputs[1])
    bexp = N.new("ShaderNodeMath"); bexp.operation = "MULTIPLY"
    bexp.inputs[1].default_value = -28.0
    L.new(bsq.outputs[0], bexp.inputs[0])
    band = N.new("ShaderNodeMath"); band.operation = "EXPONENT"
    L.new(bexp.outputs[0], band.inputs[0])

    # 星云纹理
    neb = N.new("ShaderNodeTexNoise")
    neb.inputs["Scale"].default_value = 2.2
    neb.inputs["Detail"].default_value = 10.0
    neb.inputs["Roughness"].default_value = 0.62
    neb.inputs["Distortion"].default_value = 0.6
    L.new(dirn.outputs["Vector"], neb.inputs["Vector"])
    ramp = N.new("ShaderNodeValToRGB")
    cr = ramp.color_ramp
    cr.elements[0].position = 0.32
    cr.elements[0].color = (*PALETTE["void"], 1)
    cr.elements[1].position = 0.78
    cr.elements[1].color = (*PALETTE["magenta"], 1)
    cr.elements.new(0.5).color = (*PALETTE["deep"], 1)
    cr.elements.new(0.62).color = (*PALETTE["teal"], 1)
    cr.elements.new(0.70).color = (*PALETTE["violet"], 1)
    L.new(neb.outputs["Fac"], ramp.inputs["Fac"])

    glow_amt = N.new("ShaderNodeMath"); glow_amt.operation = "ADD"
    L.new(halo_p.outputs[0], glow_amt.inputs[0])
    bscale = N.new("ShaderNodeMath"); bscale.operation = "MULTIPLY"
    bscale.inputs[1].default_value = 0.55
    L.new(band.outputs[0], bscale.inputs[0])
    L.new(bscale.outputs[0], glow_amt.inputs[1])
    neb_strength = N.new("ShaderNodeMath"); neb_strength.operation = "MULTIPLY_ADD"
    L.new(glow_amt.outputs[0], neb_strength.inputs[0])
    neb_strength.inputs[1].default_value = 2.4
    neb_strength.inputs[2].default_value = 0.10
    neb_col = N.new("ShaderNodeVectorMath"); neb_col.operation = "SCALE"
    L.new(ramp.outputs["Color"], neb_col.inputs[0])
    L.new(neb_strength.outputs[0], neb_col.inputs["Scale"])

    # 星点：Voronoi F1 距离很小处为星
    vor = N.new("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = 260.0
    L.new(dirn.outputs["Vector"], vor.inputs["Vector"])
    star = N.new("ShaderNodeMath"); star.operation = "LESS_THAN"
    star.inputs[1].default_value = 0.06
    L.new(vor.outputs["Distance"], star.inputs[0])
    sep = N.new("ShaderNodeSeparateColor")
    L.new(vor.outputs["Color"], sep.inputs[0])
    sb = N.new("ShaderNodeMath"); sb.operation = "MULTIPLY"
    L.new(star.outputs[0], sb.inputs[0])
    L.new(sep.outputs[0], sb.inputs[1])
    sb2 = N.new("ShaderNodeMath"); sb2.operation = "MULTIPLY"
    sb2.inputs[1].default_value = 3.0
    L.new(sb.outputs[0], sb2.inputs[0])
    add = N.new("ShaderNodeVectorMath"); add.operation = "ADD"
    L.new(neb_col.outputs["Vector"], add.inputs[0])
    L.new(sb2.outputs[0], add.inputs[1])
    L.new(add.outputs["Vector"], bg.inputs["Color"])
    bg.inputs["Strength"].default_value = 1.0
    return w


# --------------------------------------------------------------------------------------
# 合成（5.0 新 API：scene.compositing_node_group + 组输出；旧版本退回 scene.node_tree）
# --------------------------------------------------------------------------------------
def build_compositor(scene):
    if hasattr(scene, "compositing_node_group"):
        tree = bpy.data.node_groups.new("Realm Grade", "CompositorNodeTree")
        tree.interface.new_socket("Image", in_out="OUTPUT", socket_type="NodeSocketColor")
        scene.compositing_node_group = tree
        out = tree.nodes.new("NodeGroupOutput")
        out_sock = out.inputs[0]
    else:  # Blender 4.x
        scene.use_nodes = True
        tree = scene.node_tree
        tree.nodes.clear()
        out = tree.nodes.new("CompositorNodeComposite")
        out_sock = out.inputs["Image"]
    N, L = tree.nodes, tree.links
    rl = N.new("CompositorNodeRLayers")

    def glare(kind, strength, size, threshold):
        g = N.new("CompositorNodeGlare")
        if "Type" in g.inputs:                      # 5.0：类型是菜单 socket
            g.inputs["Type"].default_value = kind
            g.inputs["Strength"].default_value = strength
            g.inputs["Size"].default_value = size
            g.inputs["Threshold"].default_value = threshold
            if "Quality" in g.inputs:
                g.inputs["Quality"].default_value = "Medium"
        else:
            g.glare_type = kind.upper().replace(" ", "_")
            g.threshold = threshold
        return g

    bloom = glare("Bloom", 0.6, 0.85, 1.2)
    fog = glare("Fog Glow", 0.35, 0.6, 1.6)
    L.new(rl.outputs["Image"], bloom.inputs["Image"])
    L.new(bloom.outputs["Image"], fog.inputs["Image"])

    lens = N.new("CompositorNodeLensdist")
    if "Dispersion" in lens.inputs:
        lens.inputs["Dispersion"].default_value = 0.018
        lens.inputs["Distortion"].default_value = -0.012
    L.new(fog.outputs["Image"], lens.inputs["Image"])

    grade = N.new("CompositorNodeColorBalance")    # 留作调色入口，默认中性
    L.new(lens.outputs["Image"], grade.inputs["Image"])

    # 暗角：椭圆遮罩 → 模糊 → 与画面相乘
    ell = N.new("CompositorNodeEllipseMask")
    if "Size" in ell.inputs:
        ell.inputs["Size"].default_value = (0.92, 0.80)
    blur = N.new("CompositorNodeBlur")
    if "Size" in blur.inputs and blur.inputs["Size"].type == "VECTOR":
        blur.inputs["Size"].default_value = (240, 240)
    L.new(ell.outputs["Mask"], blur.inputs["Image"])
    vmix = N.new("ShaderNodeMix") if hasattr(scene, "compositing_node_group") else N.new("CompositorNodeMixRGB")
    if vmix.bl_idname == "ShaderNodeMix":
        vmix.data_type = "RGBA"
        vmix.blend_type = "MULTIPLY"
        vmix.inputs["Factor"].default_value = 0.55
        L.new(grade.outputs["Image"], vmix.inputs["A"])
        vb = N.new("ShaderNodeMix"); vb.data_type = "RGBA"
        vb.inputs["A"].default_value = (0.25, 0.25, 0.3, 1)
        vb.inputs["B"].default_value = (1, 1, 1, 1)
        L.new(blur.outputs["Image"], vb.inputs["Factor"])
        L.new(vb.outputs["Result"], vmix.inputs["B"])
        L.new(vmix.outputs["Result"], out_sock)
    else:
        vmix.blend_type = "MULTIPLY"
        L.new(grade.outputs["Image"], vmix.inputs[1])
        L.new(blur.outputs["Image"], vmix.inputs[2])
        L.new(vmix.outputs[0], out_sock)
    for i, n in enumerate((rl, bloom, fog, lens, grade, vmix, out)):
        n.location = (i * 260, 0)
    ell.location, blur.location = (4 * 260, -320), (5 * 260, -320)


# --------------------------------------------------------------------------------------
# 灯光、相机、主体
# --------------------------------------------------------------------------------------
def add_light(coll, name, kind, loc, energy, color, target=None, **kw):
    d = bpy.data.lights.new(name, kind)
    d.energy = energy
    d.color = color
    for k, v in kw.items():
        setattr(d, k, v)
    o = link_obj(bpy.data.objects.new(name, d), coll)
    o.location = loc
    if target is not None:
        o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    return o


def look(o, target, roll=0.0):
    q = (Vector(target) - o.location).to_track_quat("-Z", "Y")
    o.rotation_euler = (q @ Euler((0, 0, roll)).to_quaternion()).to_euler()


def build_camera(scene, coll):
    """09：沿破碎道路匀速推进，线性插值，300 帧；略微上升 + 轻微滚转。"""
    d = bpy.data.cameras.new("Camera")
    d.lens = 24
    d.clip_end = 1000
    d.dof.use_dof = True
    d.dof.aperture_fstop = 2.8
    cam = link_obj(bpy.data.objects.new("Camera", d), coll)
    scene.camera = cam
    sx, sy, sz = CFG["subject_pos"]
    old = set_linear_keys(True)
    keys = [(1, (0.0, -10.0, 3.6), (0, 60, 8.0), math.radians(-1.5)),
            (CFG["frame_end"], (0.6, 54.0, 5.6), (0, 100, 15.5), math.radians(1.5))]
    for f, loc, tgt, roll in keys:
        cam.location = loc
        look(cam, tgt, roll)
        cam.keyframe_insert("location", frame=f)
        cam.keyframe_insert("rotation_euler", frame=f)
    # 对焦到主体
    focus = link_obj(bpy.data.objects.new("Focus", None), coll)
    focus.location = (sx, sy, sz)
    d.dof.focus_object = focus
    bpy.context.preferences.edit.keyframe_new_interpolation_type = old
    return cam


def build_glow_sources(coll, rng, gray):
    """下篇 09：pt 2 集合 —— 三个低面数 Icosphere（棱角小颗粒），各自自发光材质，强度 30。"""
    cols = [PALETTE["ice"], PALETTE["violet"], PALETTE["ember"]]
    objs = []
    for i, c in enumerate(cols):
        bm = bmesh.new()
        bmesh.ops.create_icosphere(bm, subdivisions=1, radius=1.0)
        for v in bm.verts:                      # 稍微捏歪，避免三个都是正二十面体
            v.co *= rng.uniform(0.7, 1.25)
        me = bpy.data.meshes.new(f"Spark_{i}")
        bm.to_mesh(me)
        bm.free()
        me.materials.append(mat_emit(f"Spark {i}", c if not gray else (0.9, 0.9, 0.9), 30.0 if not gray else 1.0))
        o = link_obj(bpy.data.objects.new(f"Spark_{i}", me), coll)
        objs.append(o)
    return objs


def build_particle_ring(scene, coll, pt2, gray):
    """下篇 10：Torus 作发射器，粒子渲染为集合 pt 2，加 Turbulence 力场（强度 5、尺寸 40、流动 0）。"""
    sx, sy, sz = CFG["subject_pos"]
    size = CFG["subject_size"]
    bpy.ops.mesh.primitive_torus_add(major_radius=size * 1.15, minor_radius=2.6,
                                     major_segments=64, minor_segments=16)
    ring = bpy.context.object
    for c in ring.users_collection:
        c.objects.unlink(ring)
    coll.objects.link(ring)
    ring.name = "Torus Emitter"
    ring.location = (sx, sy, sz)
    ring.rotation_euler = (math.radians(68), math.radians(-12), 0)
    ring.show_instancer_for_render = False
    ring.show_instancer_for_viewport = False
    ps_mod = ring.modifiers.new("Particles", "PARTICLE_SYSTEM")
    ps = ps_mod.particle_system.settings
    ps.count = 2600
    ps.frame_start, ps.frame_end = 1, 1          # 第 1 帧一次性发射，整段镜头都在
    ps.lifetime = CFG["frame_end"] + 10
    ps.emit_from = "VOLUME"
    ps.distribution = "RAND"
    ps.normal_factor = 0.15
    ps.factor_random = 0.25
    ps.effector_weights.gravity = 0.0
    ps.damping = 0.35                             # 阻尼：湍流只让粒子"翻涌"，不把整环吹散
    ps.render_type = "COLLECTION"
    ps.instance_collection = pt2
    ps.use_collection_pick_random = True
    ps.use_rotation_instance = True
    ps.use_rotations = True
    ps.rotation_factor_random = 1.0
    ps.particle_size = 0.11
    ps.size_random = 0.759                        # 下篇 34:00 画面值
    # 湍流力场
    bpy.ops.object.effector_add(type="TURBULENCE", location=(sx, sy, sz))
    turb = bpy.context.object
    for c in turb.users_collection:
        c.objects.unlink(turb)
    coll.objects.link(turb)
    turb.name = "Turbulence"
    turb.field.strength = 5.0                     # 下篇 36:00 画面值
    turb.field.size = 40.0
    turb.field.flow = 0.0
    return ring


def build_subject(scene, coll, group, src_coll, mats, gray):
    """09 / 下篇 01–02、08：道路尽头上方的能量方块。
    多层嵌套：外壳 cube blue（能量纹 + 玻璃/透明）→ 内层 Cube.004（高金属反射）→ 碎裂发光内核（scatter 复用）。"""
    sx, sy, sz = CFG["subject_pos"]
    size = CFG["subject_size"]
    pivot = link_obj(bpy.data.objects.new("Subject", None), coll)
    pivot.location = (sx, sy, sz)
    pivot.rotation_euler = (math.radians(35.26), math.radians(45), 0)   # 立在一个角上

    def cube(name, s, mat):
        bm = bmesh.new()
        bmesh.ops.create_cube(bm, size=s)
        me = bpy.data.meshes.new(name)
        bm.to_mesh(me)
        bm.free()
        me.materials.append(mat)
        o = link_obj(bpy.data.objects.new(name, me), coll)
        o.parent = pivot
        return o

    shell = cube("Cube.003 Shell", size, mats["energy"])
    bev = shell.modifiers.new("Bevel", "BEVEL")
    bev.width, bev.segments = 0.2, 2
    edges = cube("Neon Edges", size * 1.004, mats["edge"])
    wf = edges.modifiers.new("Wireframe", "WIREFRAME")
    wf.thickness = 0.07
    cube("Cube.004", size * 0.74, mats["inner"])
    # 碎裂发光内核：同一个 scatter 节点组，高密度、小尺寸、强发光
    core = cube("Core", size * 0.9, mats["core"])
    add_scatter(core, group, src_coll, Density=0.55, Seed=3, **{
        "Scale Min": 0.1, "Scale Max": 0.5, "Drift": 1.6, "Drift Speed": 0.25, "Spin": 0.6,
        "Material": mats["core"], "Override Material": True})
    # 慢速自转（线性）
    old = set_linear_keys(True)
    for f, a in ((1, 0.0), (CFG["frame_end"], math.radians(70))):
        pivot.rotation_euler.z = a
        pivot.keyframe_insert("rotation_euler", index=2, frame=f)
    bpy.context.preferences.edit.keyframe_new_interpolation_type = old
    # 内核点光：品红/橙暖光从内部溢出，与蓝色环境形成冷暖对比
    if not gray:
        add_light(coll, "Core Light", "POINT", (sx, sy, sz), 3.0e4, (1.0, 0.35, 0.55),
                  shadow_soft_size=4.0)
    return pivot


# --------------------------------------------------------------------------------------
# 主流程
# --------------------------------------------------------------------------------------
def build(opts):
    rng = random.Random(opts["seed"])
    gray = opts["gray"]

    if bpy.app.background:
        bpy.ops.wm.read_factory_settings(use_empty=True)
        scene = bpy.context.scene
        scene.name = "Shattered Realm"
    else:
        scene = bpy.data.scenes.new("Shattered Realm")
        bpy.context.window.scene = scene

    scene.frame_start, scene.frame_end = 1, CFG["frame_end"]
    scene.render.fps = CFG["fps"]
    scene.frame_set(opts["frame"])

    c_ground = new_collection(scene, "Ground")
    c_src = new_collection(scene, "pt 1")
    c_float = new_collection(scene, "Floating")
    c_subject = new_collection(scene, "Subject")
    c_env = new_collection(scene, "Environment")

    stone = mat_stone(gray)
    mats = dict(stone=stone, energy=mat_energy(gray), inner=mat_inner(gray), core=mat_core(gray),
                edge=mat_emit("Neon Edge", (0.6, 0.8, 1.0) if not gray else (0.9, 0.9, 0.9),
                              1.6 if not gray else 1.0))

    ground, kept = build_ground(scene, c_ground, rng, stone)
    build_spires(c_ground, rng, stone)
    build_shard_sources(c_src, rng, stone)
    # 源集合不参与渲染（视图层排除），只被几何节点引用
    scene.view_layers[0].layer_collection.children["pt 1"].exclude = True

    group = build_scatter_group()

    # 05–06：Cube.001 作为体积容器，scatter 修改器直接挂在它上面（与教程一致）
    box = make_container(c_float, "Cube.001", (0, 52, 14), (40, 72, 15))
    add_scatter(box, group, c_src, Density=0.0022, Seed=1, Drift=7.0, **{
        "Drift Speed": 0.05, "Corridor": 9.0, "Corridor Top": 4.0})
    # 第二层：近地面的低空碎石，更密更小，强化纵深
    low = make_container(c_float, "Cube.002", (0, 50, 4.2), (32, 62, 2.8))
    add_scatter(low, group, c_src, Density=0.008, Seed=5, Drift=2.5, **{
        "Scale Min": 0.06, "Scale Max": 0.45, "Spin": 0.3, "Corridor": 5.0, "Corridor Top": 1.0})

    # 下篇 09：发光颗粒 —— pt 2 集合 + 同一个 scatter 节点组（布点密度 0.2、种子 2，本场景容器体积大得多，降为 0.006）
    c_src2 = new_collection(scene, "pt 2")
    build_glow_sources(c_src2, rng, gray)
    scene.view_layers[0].layer_collection.children["pt 2"].exclude = True
    dust = make_container(c_float, "Cube.005 Sparks", (0, 62, 14), (42, 66, 15))
    add_scatter(dust, group, c_src2, Density=0.006, Seed=2, Drift=5.0, **{
        "Scale Min": 0.02, "Scale Max": 0.08, "Spin": 1.0, "Corridor": 6.0, "Corridor Top": 0.0})

    build_subject(scene, c_subject, group, c_src, mats, gray)
    build_particle_ring(scene, c_subject, c_src2, gray)
    build_camera(scene, c_env)
    build_world(scene, gray)

    # 上篇 10 / 下篇 07、11、12：环境光 sunshine + lights 集合；fog 体积盒
    sx, sy, sz = CFG["subject_pos"]
    add_light(c_env, "sunshine", "SUN", (0, 200, 60), 1.2 if not gray else 3.0,
              PALETTE["ice"] if not gray else (1, 1, 1), target=(0, 20, 0), angle=math.radians(3))
    if not gray:
        c_lights = new_collection(scene, "lights")
        # 下篇 07：狭长蓝色矩形面光 150 m × 1 m，功率 2000 W，从前上方掠射，给碎片边缘打冷色高光
        add_light(c_lights, "Area.strip", "AREA", (0, 78, 9), 2000, (0.35, 0.6, 1.0),
                  target=(0, 30, 0), shape="RECTANGLE", size=150, size_y=1)
        # 主体背后的大面光：逆光勾出外壳轮廓并在雾里打出光晕
        back = add_light(c_lights, "Area.back", "AREA", (0, sy + 28, sz + 4), 1.2e5, PALETTE["teal"],
                         target=(0, sy - 20, sz - 6), size=30, shape="DISK")
        back.visible_glossy = False     # 只做逆光和雾光，不在路面上反射成一大片白
        # 下篇 12：视频提到"需要红色" —— 低位红色补光，只扫过道路右侧
        add_light(c_lights, "Area.red", "AREA", (26, 30, 5), 2.5e4, (1.0, 0.12, 0.2),
                  target=(0, 45, 1), size=12)
        add_light(c_lights, "Area.violet", "AREA", (-30, 40, 24), 4e4, PALETTE["violet"],
                  target=(0, 50, 0), size=18)
        fog_mat = mat_fog(gray)
        bpy.ops.mesh.primitive_cube_add(size=2)
        fog = bpy.context.object
        for c in fog.users_collection:
            c.objects.unlink(fog)
        c_env.objects.link(fog)
        fog.name = "fog"
        fog.location = (0, 70, 25)
        fog.scale = (120, 120, 40)
        fog.data.materials.append(fog_mat)
        fog.display_type = "WIRE"
        build_compositor(scene)


    configure_render(scene, opts)
    print(f"[碎域] 地面碎片 {kept} 块；场景已生成。")
    return scene


def configure_render(scene, opts):
    r = scene.render
    q = opts["quality"]
    res = opts["resolution"] or ("960x540" if q == "preview" else "1920x1080")
    r.resolution_x, r.resolution_y = (int(v) for v in res.lower().split("x"))
    r.resolution_percentage = 100
    scene.view_settings.view_transform = "AgX"
    for look_name in ("AgX - Medium High Contrast", "Medium High Contrast"):
        try:
            scene.view_settings.look = look_name
            break
        except TypeError:
            pass
    if opts["engine"] == "eevee":
        r.engine = "BLENDER_EEVEE" if "BLENDER_EEVEE" in {
            e.identifier for e in bpy.types.RenderSettings.bl_rna.properties["engine"].enum_items} \
            else "BLENDER_EEVEE_NEXT"
        e = scene.eevee
        e.taa_render_samples = opts["samples"] or (32 if q == "preview" else 128)
        for k, v in (("use_volumetric_shadows", True), ("volumetric_tile_size", "4"), ("use_raytracing", True)):
            if hasattr(e, k):
                try:
                    setattr(e, k, v)
                except Exception:
                    pass
    else:
        r.engine = "CYCLES"
        c = scene.cycles
        c.samples = opts["samples"] or (48 if q == "preview" else 384)
        c.use_denoising = True
        c.max_bounces = 6 if q == "preview" else 10
        c.transmission_bounces = 6
        c.volume_bounces = 0 if q == "preview" else 1
        c.volume_step_rate = 4.0 if q == "preview" else 1.0
        c.caustics_reflective = c.caustics_refractive = False
        try:
            prefs = bpy.context.preferences.addons["cycles"].preferences
            for kind in ("OPTIX", "CUDA", "HIP", "METAL", "ONEAPI"):
                try:
                    prefs.compute_device_type = kind
                    prefs.get_devices()
                    if any(d.type == kind for d in prefs.devices):
                        for d in prefs.devices:
                            d.use = True
                        c.device = "GPU"
                        break
                except TypeError:
                    continue
        except Exception:
            pass
    r.image_settings.file_format = "PNG"


def main():
    opts = parse_args()
    scene = build(opts)
    if opts["save"]:
        bpy.ops.wm.save_as_mainfile(filepath=bpy.path.abspath(opts["save"]))
    if opts["render"]:
        scene.render.filepath = opts["render"]
        if opts["animation"]:
            bpy.ops.render.render(animation=True)
        else:
            # 粒子系统（下篇 10 的圆环 + 湍流）需要从第 1 帧顺序模拟到目标帧
            for f in range(scene.frame_start, opts["frame"] + 1):
                scene.frame_set(f)
            bpy.ops.render.render(write_still=True)


if __name__ == "__main__":
    main()
