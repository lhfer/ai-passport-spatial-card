"""Tone-map an equirectangular .hdr into a sky JPG for the shell dome (Blender headless, numpy inside Blender).

    /Applications/Blender.app/Contents/MacOS/Blender -b -P tools/assets/hdr_to_sky.py -- in.hdr out.jpg [--exposure 2.0] [--gamma 2.2] [--max 4096]
"""
import argparse
import sys

import bpy
import numpy as np

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
ap = argparse.ArgumentParser()
ap.add_argument("input"); ap.add_argument("output")
ap.add_argument("--exposure", type=float, default=1.0, help="EV offset (2 = ×4)")
ap.add_argument("--gamma", type=float, default=2.2)
ap.add_argument("--max", type=int, default=4096, help="max width")
ap.add_argument("--mirror-upper", action="store_true", help="replace the lower hemisphere with the flipped upper one (space skies)")
ap.add_argument("--black", type=float, default=0.0, help="subtract this before tone-mapping (crush the horizon glow)")
ap.add_argument("--auto-median", type=float, default=0.0, help="auto exposure: map the median to this value (e.g. 0.008 for space skies)")
args = ap.parse_args(argv)

img = bpy.data.images.load(args.input)
w, h = img.size
if w > args.max:
    img.scale(args.max, args.max * h // w)
    w, h = img.size
px = np.array(img.pixels[:], dtype=np.float32).reshape(h, w, 4)
rgb = np.maximum(px[:, :, :3] - args.black, 0)
if args.mirror_upper:
    # Blender image rows are bottom-up: the upper hemisphere is the second half of the rows.
    upper = rgb[h // 2:, :, :]
    rgb = np.concatenate([upper[::-1, :, :], upper], axis=0)
if args.auto_median > 0:
    # Auto exposure: map the median luminance to `auto_median` (0.008 → a dark night sky, stars still clip to white).
    lum = rgb.mean(axis=2)
    med = max(float(np.median(lum)), 1e-6)
    rgb = rgb * (args.auto_median / med)
else:
    rgb = rgb * (2.0 ** args.exposure)
rgb = rgb / (1.0 + rgb)                       # Reinhard
rgb = np.clip(rgb, 0, 1) ** (1.0 / args.gamma)
print(f"[hdr_to_sky] src mean {px[:, :, :3].mean():.4f} → out mean {rgb.mean():.3f} p50 {np.percentile(rgb, 50):.3f} p99 {np.percentile(rgb, 99):.3f}")
scene = bpy.context.scene
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 88
out = bpy.data.images.new("sky", width=w, height=h, alpha=False)
out.pixels.foreach_set(np.concatenate([rgb, np.ones((h, w, 1), dtype=np.float32)], axis=2).ravel())
out.save_render(args.output, scene=scene)
print(f"[hdr_to_sky] wrote {args.output} {w}x{h}")
