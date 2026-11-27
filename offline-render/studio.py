"""Run: blender -b -t 8 --python studio.py -- INPUT.glb OUTPUT.png
Input stays local. This script uses a procedural studio, not a downloaded HDRI.
"""
import bpy, sys, math
from mathutils import Vector
from pathlib import Path
args=sys.argv[sys.argv.index("--")+1:]
if len(args)!=2: raise SystemExit("Expected GLB input and PNG output")
src,dst=map(lambda x: str(Path(x).resolve()),args)
bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=src)
meshes=[o for o in bpy.context.scene.objects if o.type=="MESH"]
if not meshes: raise RuntimeError("No mesh")
pts=[o.matrix_world @ Vector(v) for o in meshes for v in o.bound_box]
lo=Vector(tuple(min(p[i] for p in pts) for i in range(3)))
hi=Vector(tuple(max(p[i] for p in pts) for i in range(3)))
center=(lo+hi)/2
h=hi.z-lo.z
if h<=0: raise RuntimeError("Invalid model bounds")
# Keep source geometry and UVs. Tune candidate slots without replacing texture maps.
for m in bpy.data.materials:
 if not m.use_nodes: continue
 b=next((n for n in m.node_tree.nodes if n.type=="BSDF_PRINCIPLED"),None)
 if not b: continue
 name=m.name.lower()
 def setv(key,value):
  if key in b.inputs: b.inputs[key].default_value=value
 if "skin" in name:
  setv("Subsurface Weight",0.12); setv("Subsurface Radius",(1.0,0.45,0.25)); setv("Subsurface Scale",0.01*h)
 elif "fabric" in name:
  setv("Sheen Weight",0.3); setv("Sheen Roughness",0.55)
 elif "shell" in name:
  setv("Coat Weight",0.28); setv("Coat Roughness",0.27)
 elif "hair" in name:
  setv("Anisotropic IOR Level",0.45)
# Studio floor and background.
bpy.ops.mesh.primitive_plane_add(size=h*20,location=(center.x,center.y,lo.z-h*0.003))
floor=bpy.context.object; floor.name="Studio floor"
mat=bpy.data.materials.new("Charcoal floor"); mat.use_nodes=True
p=mat.node_tree.nodes.get("Principled BSDF"); p.inputs["Base Color"].default_value=(0.025,0.03,0.04,1); p.inputs["Roughness"].default_value=0.7
floor.data.materials.append(mat)
def aim(o,target): o.rotation_euler=(Vector(target)-o.location).to_track_quat("-Z","Y").to_euler()
def area(name,offset,energy,size,color):
 d=bpy.data.lights.new(name,"AREA"); d.energy=energy*h*h; d.shape="DISK"; d.size=size*h; d.color=color
 o=bpy.data.objects.new(name,d); bpy.context.scene.collection.objects.link(o); o.location=center+Vector(offset)*h; aim(o,center)
area("Key",(-1.2,-1.7,1.7),480,1.1,(1,.94,.89))
area("Fill",(1.2,-1.4,.8),190,1.4,(.87,.94,1))
area("Rim",(.7,1.0,1.4),420,.85,(.9,.95,1))
area("Top",(0,.1,2.0),160,1.0,(1,1,1))
d=bpy.data.cameras.new("Camera"); o=bpy.data.objects.new("Camera",d); bpy.context.scene.collection.objects.link(o)
o.location=center+Vector((0,-3.5,.08))*h; aim(o,center); d.type="ORTHO"; d.ortho_scale=max(h*1.15,(hi.x-lo.x)*1.45)
s=bpy.context.scene; s.camera=o
s.world=bpy.data.worlds.new("Studio world"); s.world.use_nodes=True; s.world.node_tree.nodes["Background"].inputs[0].default_value=(.16,.18,.22,1); s.world.node_tree.nodes["Background"].inputs[1].default_value=.25
s.render.engine="CYCLES"; s.cycles.device="CPU"; s.cycles.samples=128; s.cycles.use_denoising=True
s.render.resolution_x=1440; s.render.resolution_y=1800; s.render.resolution_percentage=100
s.view_settings.view_transform="AgX"; s.render.image_settings.file_format="PNG"; s.render.filepath=dst
bpy.ops.render.render(write_still=True)
