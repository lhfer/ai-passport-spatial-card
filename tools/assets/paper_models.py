"""Generate the paper-valley paper-craft pieces as RealityKit-ready USDZ, headless in Blender.

    /Applications/Blender.app/Contents/MacOS/Blender -b -P tools/assets/paper_models.py -- \
        [--out visionos/SpatialCard/Resources/worlds/paper-valley] [--paper assets/worlds/raw/ambientcg/Paper001] \
        [--only mountain_a,tree] [--texture-size 1024]

Every piece is built from plain vertex lists (no hand modelling), given a real paper material (ambientCG Paper001
colour map tinted to the palette + its GL normal map, constant roughness, metallic 0 — RealityKit drops packed
roughness/metallic channels, so nothing is packed) and exported with the same usd_export settings as to_usdz.py,
then validated with `usdchecker --arkit`.

Conventions (RealityKit space after the -90° X rotation applied at export): +Y up, +Z toward the wearer.
  * desk pop-ups and room pieces sit on y = 0 with their footprint centred on the origin, so scale.y pops them out
    of the page and scale.x unfolds them from a centre crease;
  * paper_windmill_blades pivots on its hub (origin) and faces +Z, so the world spins it around Z;
  * paper_bird_wing hinges on x = 0 and extends +X (mirror it with scale.x = -1 for the other wing);
  * paper_train_engine / paper_train_car point along +X, origin under the wheels; paper_track is the desk ellipse
    (semi-axes TRACK_A × TRACK_B m) the engine follows;
  * paper_ground is the room's valley floor (12.6 m meadow disc, river, fields), top face 4 mm under y = 0.
Unit sizes: mountains 2.0 × 1.0 m, tree 1.0 m, windmill tower 1.0 m, house 1.0 m wide, sun 1.0 m, cloud 1.0 m,
    bird wing 0.35 m; train / track are real desk size (cm). The world scales them (×0.2 on the book, ×1–2.5 in the room).
Without --only the script also writes the environment: paper_ibl.hdr (graded `fireplace` HDRI) and paper_sky.jpg.
"""
import argparse
import math
import os
import random
import shutil
import subprocess
import sys

import bpy
import numpy as np
from mathutils import Matrix, Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("--out", default="visionos/SpatialCard/Resources/worlds/paper-valley")
ap.add_argument("--paper", default="assets/worlds/raw/ambientcg/Paper001")
ap.add_argument("--tex-dir", default="assets/worlds/raw/prep/paper-valley")
ap.add_argument("--texture-size", type=int, default=1024)
ap.add_argument("--normal-size", type=int, default=512)   # fibre normal is subtle; every USDZ embeds its own copy
ap.add_argument("--only", default="")
ap.add_argument("--env", action="store_true", help="also write paper_ibl.hdr + paper_sky.jpg (default when no --only)")
ap.add_argument("--hdri", default="assets/worlds/raw/polyhaven/fireplace/fireplace_2k.hdr")
ap.add_argument("--no-check", action="store_true")
args = ap.parse_args(argv)

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT = os.path.join(REPO, args.out) if not os.path.isabs(args.out) else args.out
PAPER = os.path.join(REPO, args.paper) if not os.path.isabs(args.paper) else args.paper
TEX = os.path.join(REPO, args.tex_dir) if not os.path.isabs(args.tex_dir) else args.tex_dir
os.makedirs(OUT, exist_ok=True)
os.makedirs(TEX, exist_ok=True)
random.seed(7)

PALETTE = {
    "tan": "#C9A87A", "tan_light": "#E1CBA5", "tan_dark": "#A98A5E", "sand": "#D9BE94",
    "blue": "#5B8DEF", "blue_deep": "#3F6FD0", "coral": "#FF9C8A", "coral_deep": "#E8806E",
    "cream": "#FFF8EC", "white": "#FFFFFF", "green": "#7FB77E", "green_deep": "#5E9660",
    "meadow": "#CFDDB4", "brown": "#9C7A52", "ink": "#3A3A3A", "grey": "#8A8A8A",
}


def hex_rgb(h):
    h = h.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


# ---------------------------------------------------------------- paper textures (tinted colour + normal)

def square_rgb(path, n, colorspace):
    """Centre square crop of an image resampled to n×n (Blender's own filter), as a float RGB array."""
    src = bpy.data.images.load(path)
    src.colorspace_settings.name = colorspace
    w, h = src.size
    s = min(w, h)
    px = np.array(src.pixels[:], dtype=np.float32).reshape(h, w, 4)
    x0, y0 = (w - s) // 2, (h - s) // 2
    sq = np.ascontiguousarray(px[y0:y0 + s, x0:x0 + s, :])
    tmp = bpy.data.images.new("paper_tmp", s, s, alpha=False, float_buffer=True, is_data=(colorspace == "Non-Color"))
    tmp.pixels.foreach_set(sq.ravel())
    tmp.scale(n, n)
    out = np.array(tmp.pixels[:], dtype=np.float32).reshape(n, n, 4)[..., :3]
    bpy.data.images.remove(tmp)
    bpy.data.images.remove(src)
    return out


def save_rgb(rgb, path, fmt, quality=88):
    n = rgb.shape[0]
    img = bpy.data.images.new(os.path.basename(path), n, n, alpha=False)
    buf = np.ones((n, n, 4), dtype=np.float32)
    buf[..., :3] = rgb
    img.pixels.foreach_set(buf.ravel())
    img.file_format = fmt
    img.filepath_raw = path
    bpy.context.scene.render.image_settings.quality = quality
    img.save()
    bpy.data.images.remove(img)


def prepare_textures():
    """Tint the Paper001 colour map to every palette entry (fibre contrast boosted so the grain survives the tint)
    and downscale the GL normal. Blender loads the results from disk so usd_export can pack them."""
    n = args.texture_size
    grain = square_rgb(os.path.join(PAPER, "Paper001_2K-JPG_Color.jpg"), n, "sRGB")
    mean = grain.mean()
    grain = np.clip(mean + (grain - mean) * 3.0, 0, 1)      # 3× fibre contrast
    grain = grain / max(1e-3, grain.mean()) * 0.92           # normalise so the tint reads as the palette colour
    paths = {}
    for name, hx in PALETTE.items():
        tint = np.array(hex_rgb(hx), dtype=np.float32)
        path = os.path.join(TEX, f"paper_{name}.jpg")
        save_rgb(np.clip(grain * tint[None, None, :], 0, 1), path, "JPEG")
        paths[name] = path
    nsq = square_rgb(os.path.join(PAPER, "Paper001_2K-JPG_NormalGL.jpg"), args.normal_size, "Non-Color")
    npath = os.path.join(TEX, "paper_normal.png")
    save_rgb(nsq, npath, "PNG")
    print(f"[paper] {len(paths)} tinted paper textures at {n}px + normal at {args.normal_size}px → {TEX}")
    return paths, npath


TEX_PATHS, NORMAL_PATH = prepare_textures()
_materials = {}


def material(name):
    """One Blender material per palette colour: Principled BSDF with the tinted paper colour + paper normal."""
    if name in _materials:
        return _materials[name]
    mat = bpy.data.materials.new(f"paper_{name}")
    if not mat.node_tree:
        mat.use_nodes = True
    mat.use_backface_culling = False
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    out = nodes.new("ShaderNodeOutputMaterial")
    out.name = "output"
    bsdf = nodes.new("ShaderNodeBsdfPrincipled")
    bsdf.name = "surface"                    # node names become USD prim names: keep them ASCII (UI is localised)
    links.new(bsdf.outputs["BSDF"], out.inputs["Surface"])
    bsdf.inputs["Roughness"].default_value = 0.92
    bsdf.inputs["Metallic"].default_value = 0.0
    bsdf.inputs["Specular IOR Level"].default_value = 0.25
    tex = nodes.new("ShaderNodeTexImage")
    tex.name = "diffuse_texture"
    tex.image = bpy.data.images.load(TEX_PATHS[name], check_existing=True)
    tex.image.colorspace_settings.name = "sRGB"
    links.new(tex.outputs["Color"], bsdf.inputs["Base Color"])
    ntex = nodes.new("ShaderNodeTexImage")
    ntex.name = "normal_texture"
    ntex.image = bpy.data.images.load(NORMAL_PATH, check_existing=True)
    ntex.image.colorspace_settings.name = "Non-Color"
    nmap = nodes.new("ShaderNodeNormalMap")
    nmap.name = "normal_map"
    nmap.inputs["Strength"].default_value = 0.8
    links.new(ntex.outputs["Color"], nmap.inputs["Color"])
    links.new(nmap.outputs["Normal"], bsdf.inputs["Normal"])
    _materials[name] = mat
    return mat


# ---------------------------------------------------------------- mesh helpers (Blender Z-up while building)

def new_object(name, verts, faces, color, uv_scale=1.0, uv_offset=None, solidify=0.0):
    """Mesh from vertex/face lists with a planar paper UV (dominant-axis projection) and optional paper thickness."""
    me = bpy.data.meshes.new(name)
    me.from_pydata([Vector(v) for v in verts], [], faces)
    me.validate()
    me.update()
    ob = bpy.data.objects.new(name, me)
    bpy.context.collection.objects.link(ob)
    ob.data.materials.append(material(color))
    if uv_offset is None:
        uv_offset = (random.random(), random.random())
    uv = me.uv_layers.new(name="st")
    for poly in me.polygons:
        nrm = poly.normal
        for li in poly.loop_indices:
            co = me.vertices[me.loops[li].vertex_index].co
            if abs(nrm.z) >= max(abs(nrm.x), abs(nrm.y)):
                u, v = co.x, co.y
            elif abs(nrm.y) >= abs(nrm.x):
                u, v = co.x, co.z
            else:
                u, v = co.y, co.z
            uv.data[li].uv = (u * uv_scale + uv_offset[0], v * uv_scale + uv_offset[1])
    if solidify > 0:
        bpy.context.view_layer.objects.active = ob
        mod = ob.modifiers.new("paper", "SOLIDIFY")
        mod.thickness = solidify
        mod.offset = 0.0
        mod.use_even_offset = True
        bpy.ops.object.modifier_apply(modifier=mod.name)
    return ob


def box(name, center, size, color, uv_scale=1.0):
    cx, cy, cz = center
    sx, sy, sz = size[0] / 2, size[1] / 2, size[2] / 2
    v = [(cx - sx, cy - sy, cz - sz), (cx + sx, cy - sy, cz - sz), (cx + sx, cy + sy, cz - sz), (cx - sx, cy + sy, cz - sz),
         (cx - sx, cy - sy, cz + sz), (cx + sx, cy - sy, cz + sz), (cx + sx, cy + sy, cz + sz), (cx - sx, cy + sy, cz + sz)]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return new_object(name, v, f, color, uv_scale)


def frustum(name, base_half, top_half, z0, z1, color, uv_scale=1.0):
    """4-sided tapered box (windmill tower)."""
    b, t = base_half, top_half
    v = [(-b, -b, z0), (b, -b, z0), (b, b, z0), (-b, b, z0), (-t, -t, z1), (t, -t, z1), (t, t, z1), (-t, t, z1)]
    f = [(0, 3, 2, 1), (4, 5, 6, 7), (0, 1, 5, 4), (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]
    return new_object(name, v, f, color, uv_scale)


def pyramid(name, half, z0, z1, color, apex_offset=(0, 0), uv_scale=1.0):
    h = half
    v = [(-h, -h, z0), (h, -h, z0), (h, h, z0), (-h, h, z0), (apex_offset[0], apex_offset[1], z1)]
    f = [(0, 3, 2, 1), (0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4)]
    return new_object(name, v, f, color, uv_scale)


def sheet_xz(name, points, y, color, thickness, uv_scale=1.0, depth_per_point=None):
    """A standing paper sheet in the XZ plane (faces -Y = front) from a 2D polygon; optional per-point depth for folds."""
    verts = [(x, y + (depth_per_point[i] if depth_per_point else 0.0), z) for i, (x, z) in enumerate(points)]
    faces = [tuple(range(len(points)))]
    return new_object(name, verts, faces, color, uv_scale, solidify=thickness)


def fan_folded_sheet(name, columns, y, color, thickness, fold, uv_scale=1.0):
    """Standing sheet built from vertical strips between silhouette columns [(x, height), ...]; alternate columns
    sit at ±fold depth so each strip is a planar facet — a fan-folded paper mountain."""
    verts, faces = [], []
    for i, (x, h) in enumerate(columns):
        d = y + (fold if i % 2 == 0 else -fold)
        verts.append((x, d, 0.0))
        verts.append((x, d, h))
    for i in range(len(columns) - 1):
        a = i * 2
        faces.append((a, a + 2, a + 3, a + 1))
    return new_object(name, verts, faces, color, uv_scale, solidify=thickness)


def disc_points(cx, cz, r, n=24, start=0.0):
    return [(cx + r * math.cos(start + 2 * math.pi * k / n), cz + r * math.sin(start + 2 * math.pi * k / n)) for k in range(n)]


def flat_sheet(name, points, z, color, thickness, uv_scale=1.0):
    """A paper sheet lying flat in the XY plane (bird wings / body): polygon of (x, y) at height z."""
    verts = [(x, y, z) for (x, y) in points]
    return new_object(name, verts, [tuple(range(len(points)))], color, uv_scale, solidify=thickness)


# ---------------------------------------------------------------- pieces

def mountain(variant):
    """Three stacked fan-folded sheets (back → front, each lower and offset for shadow) + snow-cap sheets."""
    rnd = random.Random(11 if variant == "a" else 23)
    width, height = 2.0, 1.0
    thickness = 0.012

    def silhouette(scale_h, n_cols, seed_shift):
        cols = []
        xs = np.linspace(-width / 2, width / 2, n_cols)
        peaks = []
        for i, x in enumerate(xs):
            if i == 0 or i == n_cols - 1:
                h = 0.02
            else:
                t = (i / (n_cols - 1))
                base = math.sin(t * math.pi) ** 0.8
                jag = 0.55 + 0.45 * abs(math.sin(t * math.pi * (2.5 + seed_shift) + rnd.random() * 0.6))
                h = height * scale_h * base * jag + rnd.random() * 0.05
            cols.append((float(x), float(h)))
        for i in range(1, n_cols - 1):
            if cols[i][1] > cols[i - 1][1] and cols[i][1] > cols[i + 1][1] and cols[i][1] > height * scale_h * 0.55:
                peaks.append(i)
        return cols, peaks

    layers = [(1.00, 13, 0.0, 0.00, "tan_dark" if variant == "a" else "tan"),
              (0.78, 11, 0.6, 0.06, "tan" if variant == "a" else "tan_light"),
              (0.52, 9, 1.1, 0.12, "tan_light" if variant == "a" else "sand")]
    for li, (sh, ncol, shift, y, col) in enumerate(layers):
        cols, peaks = silhouette(sh, ncol, shift)
        # Front layers are narrower so the stack reads as receding ridges.
        w = 1.0 - li * 0.18
        cols = [(x * w + (0.08 if li == 1 else -0.06 if li == 2 else 0), h) for x, h in cols]
        fan_folded_sheet(f"mountain_{variant}_{li}", cols, -y, col, thickness, fold=0.02 - li * 0.004, uv_scale=0.9)
        # Snow caps: a jagged white sheet over each peak of the back two layers, slightly forward.
        if li < 2:
            for pi in peaks:
                x, h = cols[pi]
                xl, hl = cols[pi - 1]
                xr, hr = cols[pi + 1]
                cap_h = h - (h - max(hl, hr)) * 0.55
                pts = [(x, h + 0.004)]
                # Left flank down to cap height, zig-zag hem back to the right flank.
                tl = (h - cap_h) / max(1e-4, h - hl)
                tr = (h - cap_h) / max(1e-4, h - hr)
                lx = x + (xl - x) * min(1, tl)
                rx = x + (xr - x) * min(1, tr)
                pts.append((lx, cap_h))
                for k in range(1, 4):
                    t = k / 4
                    pts.append((lx + (rx - lx) * t, cap_h - (0.05 if k % 2 else 0.02) * height))
                pts.append((rx, cap_h))
                sheet_xz(f"snow_{variant}_{li}_{pi}", pts, -y - thickness * 1.6, "white", thickness * 0.8, uv_scale=1.5)


def tree(variant):
    """Paper cone crown with a serrated hem on a short trunk. Height 1 m."""
    if variant == "a":
        crown_h, crown_r, trunk_h, n = 0.72, 0.30, 0.28, 12
        colors = ("green", "brown")
    else:
        crown_h, crown_r, trunk_h, n = 0.80, 0.22, 0.20, 10
        colors = ("green_deep", "brown")
    verts = [(0, 0, trunk_h + crown_h)]
    for k in range(n):
        a = 2 * math.pi * k / n
        # Serrated hem: alternate teeth rise 6 % of the crown.
        z = trunk_h + (0.06 * crown_h if k % 2 else 0.0)
        verts.append((crown_r * math.cos(a), crown_r * math.sin(a), z))
    faces = [(0, 1 + k, 1 + (k + 1) % n) for k in range(n)]
    new_object(f"tree_{variant}_crown", verts, faces, colors[0], uv_scale=1.2, solidify=0.012)
    # Second, smaller cone sheet sitting inside/over the first — layered paper.
    verts2 = [(0, 0, trunk_h + crown_h * 0.98)]
    for k in range(n):
        a = 2 * math.pi * k / n + math.pi / n
        z = trunk_h + crown_h * 0.42 + (0.05 * crown_h if k % 2 else 0.0)
        verts2.append((crown_r * 0.62 * math.cos(a), crown_r * 0.62 * math.sin(a), z))
    faces2 = [(0, 1 + k, 1 + (k + 1) % n) for k in range(n)]
    new_object(f"tree_{variant}_crown2", verts2, faces2, "green_deep" if variant == "a" else "green", uv_scale=1.2, solidify=0.012)
    box(f"tree_{variant}_trunk", (0, 0, trunk_h / 2 + 0.005), (0.07, 0.07, trunk_h + 0.01), colors[1], uv_scale=2.0)


def windmill():
    """Tapered tower with a pyramid roof and a door; blades are a separate file (see windmill_blades)."""
    frustum("windmill_tower", 0.15, 0.10, 0.0, 0.80, "cream", uv_scale=1.0)
    pyramid("windmill_roof", 0.13, 0.80, 1.0, "coral", uv_scale=1.0)
    # Roof lip: a thin darker sheet band under the pyramid.
    frustum("windmill_lip", 0.135, 0.13, 0.78, 0.81, "coral_deep", uv_scale=1.0)
    box("windmill_door", (0, -0.148, 0.10), (0.07, 0.006, 0.18), "brown", uv_scale=2.0)
    box("windmill_window", (0, -0.128, 0.50), (0.06, 0.006, 0.06), "blue", uv_scale=2.0)
    # Hub stub on the front face where the blades attach (at z 0.72, the world offsets the blade file there).
    box("windmill_hub_stub", (0, -0.13, 0.72), (0.03, 0.06, 0.03), "ink", uv_scale=2.0)


def windmill_blades():
    """Four tapered blades + hub, centred on the origin, facing -Y (front) → +Z in RealityKit."""
    verts, faces = [], []
    r0, r1 = 0.05, 0.45
    for k in range(4):
        a = k * math.pi / 2
        c, s = math.cos(a), math.sin(a)
        w0, w1 = 0.035, 0.07
        # Blade in the XZ plane, rotated about Y (Blender) by a: local (r along, w across).
        pts = [(r0, -w0), (r1, -w1), (r1, w1), (r0, w0)]
        base = len(verts)
        for (r, w) in pts:
            x = r * c - w * s
            z = r * s + w * c
            verts.append((x, 0.0, z))
        faces.append((base, base + 1, base + 2, base + 3))
    ob = new_object("windmill_blades", verts, faces, "blue", uv_scale=1.0, solidify=0.008)
    # Alternate blades a hair forward so overlapping paper reads as layered.
    verts_h = [(0.055 * math.cos(2 * math.pi * k / 12), -0.006, 0.055 * math.sin(2 * math.pi * k / 12)) for k in range(12)]
    new_object("windmill_hub", verts_h, [tuple(range(12))], "coral", uv_scale=2.0, solidify=0.016)
    return ob


def house(variant):
    """Box body with a folded two-sheet roof (overhang), door and windows. 1 m wide."""
    w, d, h = (1.0, 0.7, 0.55) if variant == "a" else (0.8, 0.8, 0.62)
    wall = "cream" if variant == "a" else "tan_light"
    roof = "coral" if variant == "a" else "blue"
    box(f"house_{variant}_body", (0, 0, h / 2), (w, d, h), wall, uv_scale=1.0)
    ridge_h = h + (0.38 if variant == "a" else 0.34)
    ov = 0.06
    # Two roof sheets meeting at the ridge (along X), each sloping down to y = ±(d/2 + overhang).
    for side in (-1, 1):
        pts = [(-w / 2 - ov, 0.0, ridge_h), (w / 2 + ov, 0.0, ridge_h),
               (w / 2 + ov, side * (d / 2 + ov), h - 0.02), (-w / 2 - ov, side * (d / 2 + ov), h - 0.02)]
        new_object(f"house_{variant}_roof_{'l' if side < 0 else 'r'}", pts, [(0, 1, 2, 3)], roof, uv_scale=1.0, solidify=0.02)
    # Gable triangles closing the roof ends.
    for side in (-1, 1):
        x = side * w / 2
        pts = [(x, -d / 2, h - 0.001), (x, d / 2, h - 0.001), (x, 0.0, ridge_h - 0.01)]
        new_object(f"house_{variant}_gable_{'l' if side < 0 else 'r'}", pts, [(0, 1, 2)], wall, uv_scale=1.0, solidify=0.012)
    box(f"house_{variant}_door", (0.0 if variant == "a" else -0.18, -d / 2 - 0.004, 0.16), (0.16, 0.008, 0.30), "brown", uv_scale=2.0)
    for i, x in enumerate((-0.3, 0.3) if variant == "a" else (0.18,)):
        box(f"house_{variant}_window_{i}", (x, -d / 2 - 0.004, 0.34), (0.14, 0.008, 0.14), "blue" if variant == "a" else "coral", uv_scale=2.0)
    box(f"house_{variant}_chimney", (w * 0.28, 0.12, ridge_h - 0.05), (0.08, 0.08, 0.22), "tan_dark", uv_scale=2.0)


def sun():
    """Disc with 12 alternating rays, standing in the XZ plane. 1 m across."""
    r = 0.33
    disc = disc_points(0, 0.5, r, 28)
    sheet_xz("sun_disc", disc, 0.0, "coral", 0.014, uv_scale=1.0)
    sheet_xz("sun_core", disc_points(0, 0.5, r * 0.72, 24), -0.02, "cream", 0.012, uv_scale=1.0)
    for k in range(12):
        a = 2 * math.pi * k / 12
        L = 0.5 if k % 2 == 0 else 0.42
        wdt = 0.07 if k % 2 == 0 else 0.05
        c, s = math.cos(a), math.sin(a)
        p0 = (r * 0.92 * c - wdt * s, 0.5 + r * 0.92 * s + wdt * c)
        p1 = (r * 0.92 * c + wdt * s, 0.5 + r * 0.92 * s - wdt * c)
        p2 = (L * c, 0.5 + L * s)
        sheet_xz(f"sun_ray_{k}", [p0, p1, p2], 0.006 if k % 2 else -0.006, "coral_deep" if k % 2 else "coral", 0.01, uv_scale=1.0)


def cloud(variant):
    """Three overlapping paper discs, slightly staggered in depth. 1 m wide."""
    puffs = [(-0.3, 0.16, 0.2), (0.0, 0.24, 0.27), (0.3, 0.15, 0.19)] if variant == "a" else [(-0.28, 0.14, 0.17), (0.02, 0.2, 0.24), (0.3, 0.17, 0.2)]
    for i, (x, z, r) in enumerate(puffs):
        sheet_xz(f"cloud_{variant}_{i}", disc_points(x, z, r, 26), (i - 1) * 0.012, "white" if i != 1 else "cream", 0.02, uv_scale=1.0)
    # Flat base sheet tying the puffs together.
    sheet_xz(f"cloud_{variant}_base", [(-0.42, 0.0), (0.42, 0.0), (0.42, 0.1), (-0.42, 0.1)], 0.0, "white", 0.02, uv_scale=1.0)


def bird_body():
    """Elongated folded diamond lying flat (XY), pointing +X, with a tail notch."""
    pts = [(-0.14, 0.0), (-0.09, 0.025), (0.06, 0.03), (0.13, 0.0), (0.06, -0.03), (-0.09, -0.025)]
    flat_sheet("bird_body", pts, 0.0, "ink", 0.008, uv_scale=2.0)
    flat_sheet("bird_tail", [(-0.2, -0.05), (-0.13, -0.008), (-0.13, 0.008), (-0.2, 0.05)], 0.004, "grey", 0.006, uv_scale=2.0)


def bird_wing():
    """One wing hinged on x = 0, extending +X, lying flat (XY). 0.35 m."""
    pts = [(0.0, -0.06), (0.16, -0.075), (0.35, -0.03), (0.33, 0.05), (0.2, 0.085), (0.0, 0.06)]
    flat_sheet("bird_wing", pts, 0.0, "ink", 0.008, uv_scale=2.0)
    flat_sheet("bird_wing_tip", [(0.24, -0.05), (0.35, -0.03), (0.33, 0.05), (0.26, 0.06)], 0.005, "grey", 0.006, uv_scale=2.0)


def wheels(prefix, xs, half_w, z, color, r=0.008):
    for i, x in enumerate(xs):
        for side in (-1, 1):
            pts = [(x + r * math.cos(2 * math.pi * k / 10), side * half_w, z + r * math.sin(2 * math.pi * k / 10)) for k in range(10)]
            new_object(f"{prefix}_wheel_{i}_{'l' if side < 0 else 'r'}", pts, [tuple(range(10))], color, uv_scale=8.0, solidify=0.004)


def train_engine():
    """Desk-size engine (7 cm) pointing +X: boiler body, cab, chimney, four paper wheels."""
    box("engine_body", (0.005, 0, 0.022), (0.05, 0.026, 0.024), "coral", uv_scale=8.0)
    box("engine_cab", (-0.02, 0, 0.034), (0.02, 0.028, 0.03), "blue", uv_scale=8.0)
    box("engine_roof", (-0.02, 0, 0.051), (0.026, 0.034, 0.005), "blue_deep", uv_scale=8.0)
    box("engine_chimney", (0.022, 0, 0.041), (0.008, 0.008, 0.018), "ink", uv_scale=8.0)
    box("engine_front", (0.032, 0, 0.018), (0.006, 0.02, 0.012), "ink", uv_scale=8.0)
    wheels("engine", (-0.02, 0.0, 0.02), 0.014, 0.009, "ink")


def train_car():
    """Desk-size car (5 cm) pointing +X."""
    box("car_body", (0, 0, 0.02), (0.046, 0.024, 0.02), "tan", uv_scale=8.0)
    box("car_load", (0, 0, 0.033), (0.036, 0.018, 0.008), "sand", uv_scale=8.0)
    wheels("car", (-0.015, 0.015), 0.013, 0.009, "ink")


TRACK_A, TRACK_B = 0.15, 0.105     # desk track semi-axes (m); PaperValleyWorld drives the train on the same ellipse


def track():
    """Elliptical desk track: two rails and paper ties, lying flat on z = 0."""
    a, b, n = TRACK_A, TRACK_B, 72
    for rail_off in (-0.006, 0.006):
        verts, faces = [], []
        for k in range(n):
            t = 2 * math.pi * k / n
            nx, ny = math.cos(t) / a, math.sin(t) / b
            L = math.hypot(nx, ny)
            nx, ny = nx / L, ny / L
            for off in (rail_off - 0.0012, rail_off + 0.0012):
                verts.append((a * math.cos(t) + nx * off, b * math.sin(t) + ny * off, 0.0025))
        for k in range(n):
            i = k * 2
            j = ((k + 1) % n) * 2
            faces.append((i, j, j + 1, i + 1))
        new_object(f"rail_{'in' if rail_off < 0 else 'out'}", verts, faces, "ink", uv_scale=6.0, solidify=0.002)
    for k in range(36):
        t = 2 * math.pi * (k + 0.5) / 36
        cx, cy = a * math.cos(t), b * math.sin(t)
        ang = math.atan2(b * math.cos(t), -a * math.sin(t))   # tangent direction
        tie = box(f"tie_{k}", (0, 0, 0.001), (0.004, 0.02, 0.002), "brown", uv_scale=8.0)
        tie.rotation_euler = (0, 0, ang)
        tie.location = (cx, cy, 0)


def ground():
    """Valley floor for the room: a 12.6 m paper meadow disc (top 4 mm under y = 0 so pieces never z-fight), a
    paper river with cream banks meandering from far-left to near-right, and a few tan field patches."""
    rnd = random.Random(5)
    disc = disc_points(0, 0, 6.3, 64)
    new_object("ground_disc", [(x, y, -0.006) for (x, y) in disc], [tuple(range(len(disc)))], "meadow", uv_scale=1.0, solidify=0.004)
    # River centre line (Blender XY: +Y = away from the wearer): far-left → near-right, gentle S.
    n = 40
    pts = []
    for i in range(n):
        t = i / (n - 1)
        x = -5.5 + 11.0 * t
        y = 4.5 - 8.0 * t + math.sin(t * math.pi * 2.2) * 1.1
        pts.append(Vector((x, y, 0)))
    for name, width, color, z in (("river_bank", 0.95, "cream", -0.0035), ("river", 0.6, "blue", -0.002)):
        verts, faces = [], []
        for i, p in enumerate(pts):
            d = (pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
            d.normalize()
            side = Vector((-d.y, d.x, 0)) * (width / 2)
            verts.append(tuple(p - side + Vector((0, 0, z))))
            verts.append(tuple(p + side + Vector((0, 0, z))))
        for i in range(n - 1):
            a = i * 2
            faces.append((a, a + 2, a + 3, a + 1))
        new_object(name, verts, faces, color, uv_scale=0.8)
    # Field patches: irregular hexagons, alternating tan tints, kept off the river and the wearer's spot.
    for k, (cx, cy, r) in enumerate(((-3.6, -1.2, 1.1), (3.2, 2.6, 1.3), (-2.4, 3.8, 0.9), (4.2, -2.6, 1.0), (1.2, 4.6, 0.8))):
        poly = [(cx + r * (0.8 + 0.4 * rnd.random()) * math.cos(a), cy + r * (0.8 + 0.4 * rnd.random()) * math.sin(a))
                for a in (2 * math.pi * j / 6 + rnd.random() * 0.3 for j in range(6))]
        new_object(f"field_{k}", [(x, y, -0.0025) for (x, y) in poly], [tuple(range(6))], "tan_light" if k % 2 else "sand", uv_scale=0.8)


PIECES = {
    "paper_ground": ground,
    "paper_mountain_a": lambda: mountain("a"),
    "paper_mountain_b": lambda: mountain("b"),
    "paper_tree_a": lambda: tree("a"),
    "paper_tree_b": lambda: tree("b"),
    "paper_windmill": windmill,
    "paper_windmill_blades": windmill_blades,
    "paper_house_a": lambda: house("a"),
    "paper_house_b": lambda: house("b"),
    "paper_sun": sun,
    "paper_cloud_a": lambda: cloud("a"),
    "paper_cloud_b": lambda: cloud("b"),
    "paper_bird_body": bird_body,
    "paper_bird_wing": bird_wing,
    "paper_train_engine": train_engine,
    "paper_train_car": train_car,
    "paper_track": track,
}


# ---------------------------------------------------------------- export

def clear_scene():
    for o in list(bpy.context.scene.objects):
        bpy.data.objects.remove(o, do_unlink=True)
    for me in list(bpy.data.meshes):
        if me.users == 0:
            bpy.data.meshes.remove(me)


def export_piece(name, build):
    clear_scene()
    build()
    objs = [o for o in bpy.context.scene.objects if o.type == "MESH"]
    bpy.ops.object.select_all(action="DESELECT")
    for o in objs:
        o.select_set(True)
    bpy.context.view_layer.objects.active = objs[0]
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    # Stand it up for RealityKit (which ignores upAxis = Z): Blender +Z → +Y, Blender -Y (front) → +Z.
    for o in objs:
        o.matrix_world = Matrix.Rotation(math.radians(-90), 4, "X") @ o.matrix_world
    bpy.ops.object.transform_apply(location=True, rotation=True, scale=True)
    for o in objs:
        o.data.calc_loop_triangles()
    tris = sum(len(o.data.loop_triangles) for o in objs)
    lo = Vector((1e9,) * 3)
    hi = Vector((-1e9,) * 3)
    for o in objs:
        for c in o.bound_box:
            w = o.matrix_world @ Vector(c)
            lo = Vector(map(min, lo, w))
            hi = Vector(map(max, hi, w))
    out = os.path.join(OUT, f"{name}.usdz")
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
        export_lights=False,
        convert_world_material=False,        # no DomeLight from Blender's default world
        export_custom_properties=False,
        triangulate_meshes=True,
        root_prim_path="/root",
    )
    check = ""
    if not args.no_check and shutil.which("usdchecker"):
        r = subprocess.run(["usdchecker", "--arkit", out], capture_output=True, text=True)
        check = (r.stdout + r.stderr).strip().splitlines()[-1]
    print(f"[paper] {name}: {tris} tris, size x={hi.x - lo.x:.3f} y={hi.y - lo.y:.3f} z={hi.z - lo.z:.3f} (min y {lo.y:.3f}) → {out} | {check}")


# ---------------------------------------------------------------- environment (IBL + sky dome)

def environment():
    """paper_ibl.hdr: the Poly Haven `fireplace` room (warm, one hot fire) is kept as the character of the light but
    graded for paper — hotspot clipped, cast reduced a third, and blended 50/50 with a soft cream box light (bright
    zenith, tan floor bounce) so tops of pages and roofs are not lit by a dark ceiling. paper_sky.jpg: a low-contrast
    tiled paper-fibre dome the engine tints with skyTint."""
    src = os.path.join(REPO, args.hdri) if not os.path.isabs(args.hdri) else args.hdri
    img = bpy.data.images.load(src)
    w, h = img.size
    px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
    fire = px[..., :3].copy()
    lum = fire @ np.array([0.2126, 0.7152, 0.0722], dtype=np.float32)
    fire = np.minimum(fire, 6.0)                                             # clip the fire / doorway hotspots
    fire = fire * 0.65 + lum[..., None].clip(0, 6.0) * 0.35                   # a third less yellow cast
    fire *= 0.5 / max(1e-4, float(fire.mean()))                              # normalise: mean 0.5
    v = (np.arange(h, dtype=np.float32) + 0.5) / h                            # 0 nadir .. 1 zenith
    elev = (v - 0.5) * np.pi
    up = np.clip(np.sin(elev), 0, 1)[:, None, None]
    down = np.clip(-np.sin(elev), 0, 1)[:, None, None]
    zenith = np.array([1.00, 0.97, 0.92], dtype=np.float32) * 0.85
    horizon = np.array([1.00, 0.94, 0.86], dtype=np.float32) * 0.62
    floor = np.array([0.86, 0.75, 0.58], dtype=np.float32) * 0.34
    amb = np.where(elev[:, None, None] >= 0, horizon * (1 - up) + zenith * up ** 1.3,
                   horizon * (1 - down) ** 1.5 + floor * (1 - (1 - down) ** 1.5))
    amb = np.broadcast_to(amb, (h, w, 3))
    px[..., :3] = fire * 0.5 + amb * 0.5
    rows = px[..., :3].mean((1, 2))
    print(f"[paper] ibl mean {px[..., :3].mean():.3f}, zenith→nadir " +
          str([round(float(rows[int(h * (1 - f)) - 1]), 3) for f in (0.02, 0.25, 0.5, 0.75, 0.98)]))
    img.pixels.foreach_set(px.ravel())
    img.scale(1024, 512)
    img.file_format = "HDR"
    img.filepath_raw = os.path.join(OUT, "paper_ibl.hdr")
    img.save()
    bpy.data.images.remove(img)
    # Sky dome: paper fibre tiled 6×3 over the equirect, contrast kept low, faintly brighter toward the zenith.
    grain = square_rgb(os.path.join(PAPER, "Paper001_2K-JPG_Color.jpg"), 512, "sRGB")
    mean = grain.mean()
    grain = np.clip(mean + (grain - mean) * 1.6, 0, 1) / max(1e-3, mean)
    tile = np.tile(grain, (2, 6, 1))[:1024, :3072][:, :2048]                  # 1024 rows × 2048 cols
    shade = (0.90 + 0.10 * np.linspace(0, 1, 1024, dtype=np.float32))[:, None, None]  # rows bottom-up: nadir darker
    sky = np.clip(tile * shade * 0.97, 0, 1)
    out = bpy.data.images.new("paper_sky", 2048, 1024, alpha=False)
    buf = np.ones((1024, 2048, 4), dtype=np.float32)
    buf[..., :3] = sky
    out.pixels.foreach_set(buf.ravel())
    out.file_format = "JPEG"
    out.filepath_raw = os.path.join(OUT, "paper_sky.jpg")
    bpy.context.scene.render.image_settings.quality = 82
    out.save()
    bpy.data.images.remove(out)
    print(f"[paper] wrote {OUT}/paper_ibl.hdr (1024×512) and paper_sky.jpg (2048×1024)")


only = [s.strip() for s in args.only.split(",") if s.strip()]
for name, build in PIECES.items():
    if only and not any(o in name for o in only):
        continue
    export_piece(name, build)
if args.env or not only:
    environment()
print("[paper] done")
