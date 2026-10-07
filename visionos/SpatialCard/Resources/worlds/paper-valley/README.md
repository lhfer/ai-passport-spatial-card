# paper-valley pieces

All `paper_*.usdz` here are **original, generated** by `tools/assets/paper_models.py` (Blender headless, plain vertex
lists — no third-party geometry). Regenerate with:

```
/Applications/Blender.app/Contents/MacOS/Blender -b -P tools/assets/paper_models.py -- \
    --out visionos/SpatialCard/Resources/worlds/paper-valley --paper assets/worlds/raw/ambientcg/Paper001
```

Third-party inputs (registered in `assets/worlds/THIRD_PARTY_ASSETS.md`, both CC0): ambientCG `Paper001` (paper grain
colour + GL normal, tinted per piece) and Poly Haven `fireplace` (graded into `paper_ibl.hdr`; `paper_sky.jpg` is the
paper grain tinted cream).

Conventions: pieces sit on y = 0 with the footprint centred (scale.y pops them out of the page, scale.x unfolds from the
centre crease); `paper_windmill_blades` pivots on its hub facing +Z; `paper_bird_wing` hinges on x = 0 and extends +X
(mirror with scale.x = −1); the train points along +X and runs on the `paper_track` ellipse (semi-axes 0.15 × 0.105 m).
