"""Convert a glTF/GLB/FBX/OBJ/USD model to a RealityKit-ready .usdz with Blender (headless).

    /Applications/Blender.app/Contents/MacOS/Blender -b -P tools/assets/to_usdz.py -- \
        input.glb output.usdz [--scale 1.0] [--max-texture 1024] [--merge] [--yup]

- Applies scale, optionally merges all meshes into one object per material (fewer draw calls),
- resizes textures above --max-texture (JPEG for colour, PNG for normal/ORM stays lossless),
- rotates the geometry Z-up → Y-up (RealityKit ignores USD upAxis metadata),
- exports USD with UsdPreviewSurface materials and packed textures, then validates with usdchecker --arkit.
"""
import argparse
import math
import os
import shutil
import subprocess
import sys

import bpy
from mathutils import Matrix

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("input")
ap.add_argument("output")
ap.add_argument("--scale", type=float, default=1.0)
ap.add_argument("--max-texture", type=int, default=1024)
ap.add_argument("--merge", action="store_true", help="join all meshes into one object")
ap.add_argument("--decimate", type=float, default=1.0, help="collapse-decimate ratio (0.3 keeps ~30 %% of the faces)")
ap.add_argument("--no-check", action="store_true")
args = ap.parse_args(argv)

bpy.ops.wm.read_factory_settings(use_empty=True)
ext = os.path.splitext(args.input)[1].lower()
if ext in (".glb", ".gltf"):
    bpy.ops.import_scene.gltf(filepath=args.input)
elif ext == ".fbx":
    bpy.ops.import_scene.fbx(filepath=args.input)
elif ext == ".obj":
    bpy.ops.wm.obj_import(filepath=args.input)
elif ext in (".usd", ".usda", ".usdc", ".usdz"):
    bpy.ops.wm.usd_import(filepath=args.input)
else:
    sys.exit(f"unsupported input {ext}")

meshes = [o for o in bpy.context.scene.objects if o.type == "MESH"]
if not meshes:
    sys.exit("no meshes imported")
# Drop lights/cameras/empties that came with the file.
for o in list(bpy.context.scene.objects):
    if o.type in ("LIGHT", "CAMERA"):
        bpy.data.objects.remove(o, do_unlink=True)

bpy.ops.object.select_all(action="DESELECT")
for o in meshes:
    o.select_set(True)
bpy.context.view_layer.objects.active = meshes[0]
if args.scale != 1.0:
    bpy.ops.transform.resize(value=(args.scale, args.scale, args.scale))
bpy.ops.object.transform_apply(location=False, rotation=True, scale=True)
if args.merge and len(meshes) > 1:
    bpy.ops.object.join()
# RealityKit ignores the USD `upAxis = Z` metadata Blender writes, so bake the axis change into the geometry:
# Blender +Z (up) → +Y, Blender −Y (front) → +Z. Without this every prop lies on its side in the app.
for o in bpy.context.scene.objects:
    if o.type == "MESH" and o.parent is None:
        o.matrix_world = Matrix.Rotation(math.radians(-90), 4, "X") @ o.matrix_world
bpy.ops.object.select_all(action="DESELECT")
for o in bpy.context.scene.objects:
    if o.type == "MESH":
        o.select_set(True)
bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
if args.decimate < 1.0:
    for o in bpy.context.scene.objects:
        if o.type == "MESH":
            o.data = o.data.copy()                 # single-user, or modifier_apply refuses
            if o.data.shape_keys:
                o.shape_key_clear()
            before = len(o.data.polygons)
            mod = o.modifiers.new("decimate", "DECIMATE")
            mod.ratio = args.decimate
            mod.use_collapse_triangulate = True
            bpy.ops.object.select_all(action="DESELECT")
            o.select_set(True)
            bpy.context.view_layer.objects.active = o
            try:
                bpy.ops.object.modifier_apply(modifier=mod.name)
            except RuntimeError as e:
                print(f"[to_usdz] decimate failed on {o.name}: {e}")
            print(f"[to_usdz] decimate {o.name}: {before} → {len(o.data.polygons)} faces")

# Downscale textures.
for img in bpy.data.images:
    if img.size[0] > args.max_texture or img.size[1] > args.max_texture:
        k = args.max_texture / max(img.size)
        img.scale(max(1, int(img.size[0] * k)), max(1, int(img.size[1] * k)))

tris = sum(len(o.data.loop_triangles) if o.data.loop_triangles else 0 for o in bpy.context.scene.objects if o.type == "MESH")
for o in bpy.context.scene.objects:
    if o.type == "MESH":
        o.data.calc_loop_triangles()
tris = sum(len(o.data.loop_triangles) for o in bpy.context.scene.objects if o.type == "MESH")

out = os.path.abspath(args.output)
os.makedirs(os.path.dirname(out), exist_ok=True)
bpy.ops.wm.usd_export(
    filepath=out,
    selected_objects_only=False,
    export_textures_mode="NEW",
    export_materials=True,
    generate_preview_surface=True,
    convert_orientation=False,
    export_uvmaps=True,
    export_normals=True,
    export_animation=False,
    triangulate_meshes=True,
    root_prim_path="/root",
)
print(f"[to_usdz] wrote {out} triangles={tris} textures={len(bpy.data.images)}")
if not args.no_check and shutil.which("usdchecker"):
    r = subprocess.run(["usdchecker", "--arkit", out], capture_output=True, text=True)
    tail = (r.stdout + r.stderr).strip().splitlines()[-3:]
    print("[to_usdz] usdchecker:", " | ".join(tail))
