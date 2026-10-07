// v4 A4 · 名片本体 — splits the real avatar into the three pop-up-book layers the hero card stands up.
//
//     swift visionos/SpatialCard/Tools/v4/v4-avatar-layers.swift \
//         visionos/SpatialCard/Resources/Assets.xcassets/Avatar.imageset/avatar.png \
//         visionos/SpatialCard/Resources/v4 [debugDir]
//
// Runs on the Mac, entirely on-device: Vision's `VNGenerateForegroundInstanceMaskRequest` finds the figure, plain
// Swift does the rest. Nothing is uploaded anywhere — the avatar is the user's own picture and stays on this machine.
//
// Outputs (all 540 × 540, the source's own size, so the three layers register pixel-for-pixel on the card):
//   v4-avatar-back.png    the painted sky with the figure and the steam removed (push-pull inpainting) — layer 1, 3 mm
//   v4-avatar-figure.png  the figure, die-cut with a white sticker margin, fading out at the bottom — layer 2, 10 mm
//   v4-avatar-shadow.png  the sticker's soft shadow (deep-night alpha), drawn just under the figure
//   v4-avatar-steam.png   the rainbow steam lifted off the painting, with a faint glow — layer 3, 18 mm
// plus, with a third argument, a contact sheet and the raw masks for the report.
//
// Why these choices:
// - The figure's bottom edge is the image's own bottom edge (the hoodie is cropped). Floating 10 mm off the card, a
//   hard cut would slide over the type below it as soon as the head moves, so the last 14 % of the figure fades out.
// - The white margin is what makes a flat cut-out read as a *thing* standing off the page (a die-cut sticker), and it
//   also hides the few pixels of halo Vision leaves around the hair.
// - The steam is painted over the sky with no outline, so Vision never includes it in the figure. It is found as
//   "whatever differs from the inpainted sky" inside a box above the mug, then un-mixed from that sky.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Plain float images

/// A single-channel float image, row-major, y = 0 at the top.
struct Plane {
    let width: Int
    let height: Int
    var data: [Float]

    init(width: Int, height: Int, value: Float = 0) {
        self.width = width
        self.height = height
        data = [Float](repeating: value, count: width * height)
    }

    subscript(x: Int, y: Int) -> Float {
        get { data[y * width + x] }
        set { data[y * width + x] = newValue }
    }

    /// Separable box blur, `passes` times (three passes ≈ a Gaussian of σ ≈ radius). Edges clamp.
    func boxBlurred(radius: Int, passes: Int = 3) -> Plane {
        guard radius > 0 else { return self }
        var a = self
        var b = Plane(width: width, height: height)
        let w = width, h = height, r = radius
        let norm = 1 / Float(2 * r + 1)
        for _ in 0..<passes {
            // Horizontal: a -> b
            a.data.withUnsafeBufferPointer { src in
                b.data.withUnsafeMutableBufferPointer { dst in
                    for y in 0..<h {
                        let row = y * w
                        var sum: Float = 0
                        for k in -r...r { sum += src[row + min(max(k, 0), w - 1)] }
                        for x in 0..<w {
                            dst[row + x] = sum * norm
                            let add = min(x + r + 1, w - 1), sub = max(x - r, 0)
                            sum += src[row + add] - src[row + sub]
                        }
                    }
                }
            }
            // Vertical: b -> a
            b.data.withUnsafeBufferPointer { src in
                a.data.withUnsafeMutableBufferPointer { dst in
                    for x in 0..<w {
                        var sum: Float = 0
                        for k in -r...r { sum += src[min(max(k, 0), h - 1) * w + x] }
                        for y in 0..<h {
                            dst[y * w + x] = sum * norm
                            let add = min(y + r + 1, h - 1), sub = max(y - r, 0)
                            sum += src[add * w + x] - src[sub * w + x]
                        }
                    }
                }
            }
        }
        return a
    }

    func map(_ f: (Float) -> Float) -> Plane {
        var out = self
        for i in out.data.indices { out.data[i] = f(out.data[i]) }
        return out
    }
}

/// Three planes: r, g, b in 0…1 (straight, not premultiplied).
struct RGB {
    var r: Plane, g: Plane, b: Plane
    var width: Int { r.width }
    var height: Int { r.height }
}

func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}

// MARK: - I/O

func loadRGB(_ url: URL) -> (RGB, CGImage) {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("cannot read \(url.path)")
    }
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    var rgb = RGB(r: Plane(width: w, height: h), g: Plane(width: w, height: h), b: Plane(width: w, height: h))
    for i in 0..<(w * h) {
        rgb.r.data[i] = Float(bytes[i * 4]) / 255
        rgb.g.data[i] = Float(bytes[i * 4 + 1]) / 255
        rgb.b.data[i] = Float(bytes[i * 4 + 2]) / 255
    }
    return (rgb, image)
}

/// Writes straight RGB + alpha as a PNG (premultiplied on the way into CoreGraphics, which is what it stores).
func writePNG(_ url: URL, rgb: RGB, alpha: Plane?) {
    let w = rgb.width, h = rgb.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    for i in 0..<(w * h) {
        let a = alpha.map { max(0, min(1, $0.data[i])) } ?? 1
        bytes[i * 4] = UInt8(max(0, min(1, rgb.r.data[i])) * a * 255 + 0.5)
        bytes[i * 4 + 1] = UInt8(max(0, min(1, rgb.g.data[i])) * a * 255 + 0.5)
        bytes[i * 4 + 2] = UInt8(max(0, min(1, rgb.b.data[i])) * a * 255 + 0.5)
        bytes[i * 4 + 3] = UInt8(a * 255 + 0.5)
    }
    let info = alpha == nil ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info)!
    guard let image = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fatalError("cannot write \(url.path)")
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("cannot finalize \(url.path)") }
}

func writeMask(_ url: URL, _ plane: Plane) {
    writePNG(url, rgb: RGB(r: plane, g: plane, b: plane), alpha: nil)
}

// MARK: - Vision

/// The union of every foreground instance Vision finds, at the source's resolution (0…1, soft edges).
func foregroundMask(_ image: CGImage) -> Plane {
    let request = VNGenerateForegroundInstanceMaskRequest()
    let handler = VNImageRequestHandler(cgImage: image, options: [:])
    do { try handler.perform([request]) } catch { fatalError("Vision failed: \(error)") }
    guard let observation = request.results?.first else { fatalError("Vision found no foreground") }
    let instances = observation.allInstances
    print("[avatar] Vision: \(instances.count) foreground instance(s): \(Array(instances))")
    // Per-instance areas, for the report (is the mug its own instance?).
    for index in instances {
        if let buffer = try? observation.generateScaledMaskForImage(forInstances: IndexSet(integer: index), from: handler) {
            let plane = planeFrom(buffer)
            let area = plane.data.reduce(0, +) / Float(plane.data.count)
            print(String(format: "[avatar]   instance %d covers %.1f %% of the frame", index, area * 100))
        }
    }
    guard let buffer = try? observation.generateScaledMaskForImage(forInstances: instances, from: handler) else {
        fatalError("Vision could not scale the mask")
    }
    return planeFrom(buffer)
}

func planeFrom(_ buffer: CVPixelBuffer) -> Plane {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    let format = CVPixelBufferGetPixelFormatType(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { fatalError("empty mask buffer") }
    var plane = Plane(width: w, height: h)
    for y in 0..<h {
        let row = base.advanced(by: y * stride)
        for x in 0..<w {
            switch format {
            case kCVPixelFormatType_OneComponent32Float:
                plane[x, y] = row.assumingMemoryBound(to: Float.self)[x]
            case kCVPixelFormatType_OneComponent8:
                plane[x, y] = Float(row.assumingMemoryBound(to: UInt8.self)[x]) / 255
            default:
                fatalError("unexpected mask format \(format)")
            }
        }
    }
    return plane
}

// MARK: - Inpainting

/// Push-pull fill: every hole pixel (`known` = 0) takes the normalised blur of the known pixels around it, from the
/// finest radius that has any support there, falling back to coarser ones — a soft continuation of the painted sky.
func inpaint(_ rgb: RGB, known: Plane) -> RGB {
    var out = rgb
    let radii = [6, 12, 24, 48, 96, 192]
    var filled = Plane(width: rgb.width, height: rgb.height)   // how much of each pixel has been decided so far
    var fillR = Plane(width: rgb.width, height: rgb.height)
    var fillG = fillR, fillB = fillR
    for radius in radii {
        let m = known.boxBlurred(radius: radius)
        let pr = Plane(width: rgb.width, height: rgb.height, value: 0)
        var wr = pr, wg = pr, wb = pr
        for i in m.data.indices {
            wr.data[i] = rgb.r.data[i] * known.data[i]
            wg.data[i] = rgb.g.data[i] * known.data[i]
            wb.data[i] = rgb.b.data[i] * known.data[i]
        }
        let br = wr.boxBlurred(radius: radius), bg = wg.boxBlurred(radius: radius), bb = wb.boxBlurred(radius: radius)
        for i in m.data.indices {
            let support = m.data[i]
            guard support > 1e-4 else { continue }
            // Confidence grows with support; what is left undecided goes to the next (coarser) radius.
            let take = min(1, support / 0.35) * (1 - filled.data[i])
            fillR.data[i] += br.data[i] / support * take
            fillG.data[i] += bg.data[i] / support * take
            fillB.data[i] += bb.data[i] / support * take
            filled.data[i] += take
        }
    }
    for i in out.r.data.indices {
        let k = known.data[i]
        let f = max(filled.data[i], 1e-4)
        out.r.data[i] = rgb.r.data[i] * k + fillR.data[i] / f * (1 - k)
        out.g.data[i] = rgb.g.data[i] * k + fillG.data[i] / f * (1 - k)
        out.b.data[i] = rgb.b.data[i] * k + fillB.data[i] / f * (1 - k)
    }
    return out
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: swift v4-avatar-layers.swift <avatar.png> <outDir> [debugDir]")
    exit(2)
}
let inputURL = URL(fileURLWithPath: args[1])
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let debugDir = args.count >= 4 ? URL(fileURLWithPath: args[3], isDirectory: true) : nil
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
if let debugDir { try? FileManager.default.createDirectory(at: debugDir, withIntermediateDirectories: true) }

let started = Date()
let (source, cgImage) = loadRGB(inputURL)
let W = source.width, H = source.height
print("[avatar] source \(W) × \(H)")

// 1. The figure, as Vision sees it. On this avatar that is ONE instance, and it includes the steam: the rainbow wisps
//    touch the mug, so Vision treats cup + steam + boy as one object — together with a wedge of sky between the chin
//    and the steam. (`VNGeneratePersonSegmentationRequest` returns an empty mask for this illustration and
//    `VNGeneratePersonInstanceMaskRequest` no result at all, so the foreground mask is the only one to start from.)
let rawFigure = foregroundMask(cgImage)
let visionMask = rawFigure.map { smoothstep(0.35, 0.65, $0) }   // Vision's edge is a soft ramp; tighten it a little

func luminance(_ i: Int) -> Float { 0.2126 * source.r.data[i] + 0.7152 * source.g.data[i] + 0.0722 * source.b.data[i] }

// 2. The boy's true right-hand contour next to the steam, read off the line art: every row of the steam band is
//    scanned from the right until the first black outline pixel. Everything right of that line is sky or steam, so it
//    leaves the figure — which removes both the steam and the sky wedge Vision swept in, and leaves the face and the
//    hoodie untouched (they are to the left of their own outline by definition). Rows below the mug's rim (y 0.705)
//    are not touched: the steam's foot in the coffee stays with the cup.
let band = (y0: 0.34, y1: 0.705, xRight: 0.84, xLeft: 0.45)
var contour = [Int?](repeating: nil, count: H)
for y in 0..<H {
    let fy = (Double(y) + 0.5) / Double(H)
    guard fy >= band.y0, fy <= band.y1 else { continue }
    var x = Int(band.xRight * Double(W))
    while Double(x) / Double(W) > band.xLeft {
        let i = y * W + x
        let r = source.r.data[i], g = source.g.data[i], b = source.b.data[i]
        let chroma = max(r, g, b) - min(r, g, b)
        if luminance(i) < 0.30, chroma < 0.28 { contour[y] = x; break }
        x -= 1
    }
}
// A 7-row median keeps a stray dark pixel from notching the cut.
var smoothed = contour
for y in 0..<H where contour[y] != nil {
    let window = (max(0, y - 3)...min(H - 1, y + 3)).compactMap { contour[$0] }.sorted()
    smoothed[y] = window[window.count / 2]
}
var rightOfBoy = Plane(width: W, height: H)
// Where the steam may be looked for: a few pixels further out, because the outline's anti-aliased fringe is exactly
// the kind of local contrast the steam detector below keys on (it came out as a grey rim along the cut).
var clearOfOutline = Plane(width: W, height: H)
for y in 0..<H {
    guard let cx = smoothed[y] else { continue }
    for x in 0..<W {
        // Soft 1.5 px ramp just outside the outline's right edge, so its anti-aliased fringe stays with the figure.
        rightOfBoy[x, y] = smoothstep(Float(cx) + 1.0, Float(cx) + 2.5, Float(x))
        clearOfOutline[x, y] = smoothstep(Float(cx) + 3.0, Float(cx) + 7.0, Float(x))
    }
}
let figureMask: Plane = {
    var m = visionMask
    for i in m.data.indices { m.data[i] *= 1 - rightOfBoy.data[i] }
    return m
}()

// 3. The steam, inside the band right of the boy: first a rough mask from local contrast (the painted strokes have
//    edges, the sky is a smooth wash), then the sky under it re-painted from its *immediate* surroundings (a box-wide
//    fill picks up the neighbouring cloud and turns it into a grey ghost), then coverage = difference from that sky.
let steamBox = (x0: 0.52, x1: 0.84, y0: 0.36, y1: 0.705)
var inBox = Plane(width: W, height: H)
for y in 0..<H {
    for x in 0..<W {
        let fx = (Double(x) + 0.5) / Double(W), fy = (Double(y) + 0.5) / Double(H)
        if fx >= steamBox.x0, fx <= steamBox.x1, fy >= steamBox.y0, fy <= steamBox.y1 { inBox[x, y] = clearOfOutline[x, y] }
    }
}
let low = RGB(r: source.r.boxBlurred(radius: 10), g: source.g.boxBlurred(radius: 10), b: source.b.boxBlurred(radius: 10))
var rough = Plane(width: W, height: H)
for i in rough.data.indices where inBox.data[i] > 0 {
    let dr = source.r.data[i] - low.r.data[i], dg = source.g.data[i] - low.g.data[i], db = source.b.data[i] - low.b.data[i]
    rough.data[i] = smoothstep(0.025, 0.07, (dr * dr + dg * dg + db * db).squareRoot()) * inBox.data[i]
}
let roughGrow = rough.boxBlurred(radius: 5).map { $0 > 0.04 ? 1 : 0 }
var knownLocal = Plane(width: W, height: H)
let figureGrow = figureMask.boxBlurred(radius: 3).map { $0 > 0.02 ? 1 : 0 }
for i in knownLocal.data.indices { knownLocal.data[i] = (1 - figureGrow.data[i]) * (1 - roughGrow.data[i]) }
let sky = inpaint(source, known: knownLocal)

// It rises out of the coffee, so it fades in over the last few pixels above the rim instead of starting on a line.
var steamAlpha = Plane(width: W, height: H)
for y in 0..<H {
    let fy = (Float(y) + 0.5) / Float(H)
    let base = 1 - smoothstep(0.668, 0.702, fy)
    for x in 0..<W {
        let i = y * W + x
        guard roughGrow.data[i] > 0, inBox.data[i] > 0 else { continue }
        let dr = source.r.data[i] - sky.r.data[i], dg = source.g.data[i] - sky.g.data[i], db = source.b.data[i] - sky.b.data[i]
        let d = (dr * dr + dg * dg + db * db).squareRoot()
        steamAlpha.data[i] = smoothstep(0.05, 0.18, d) * inBox.data[i] * base
    }
}
steamAlpha = steamAlpha.boxBlurred(radius: 1, passes: 1)
// Un-mix: colour = (pixel − (1 − a)·sky) / a, then lift the saturation a touch — it is the magic in the picture.
var steamRGB = RGB(r: Plane(width: W, height: H), g: Plane(width: W, height: H), b: Plane(width: W, height: H))
for i in steamAlpha.data.indices {
    let a = max(steamAlpha.data[i], 0.2)
    var r = (source.r.data[i] - (1 - a) * sky.r.data[i]) / a
    var g = (source.g.data[i] - (1 - a) * sky.g.data[i]) / a
    var b = (source.b.data[i] - (1 - a) * sky.b.data[i]) / a
    let l = (r + g + b) / 3
    r = l + (r - l) * 1.15; g = l + (g - l) * 1.15; b = l + (b - l) * 1.15
    steamRGB.r.data[i] = max(0, min(1, r)); steamRGB.g.data[i] = max(0, min(1, g)); steamRGB.b.data[i] = max(0, min(1, b))
    // The steam is a rainbow; anything the difference picked up that is not chromatic (a lighter patch of cloud,
    // a speck of line art) is not steam.
    let chroma = max(steamRGB.r.data[i], steamRGB.g.data[i], steamRGB.b.data[i])
        - min(steamRGB.r.data[i], steamRGB.g.data[i], steamRGB.b.data[i])
    steamAlpha.data[i] *= smoothstep(0.10, 0.20, chroma)
}
// A faint glow around the strokes (same colours, spread wider), so the lifted steam reads as light, not as paint.
let glowAlpha = steamAlpha.boxBlurred(radius: 5).map { min(1, $0 * 1.6) * 0.45 }
var steamOutAlpha = Plane(width: W, height: H)
var steamOut = steamRGB
let spreadR = RGB(r: Plane(width: W, height: H), g: Plane(width: W, height: H), b: Plane(width: W, height: H))
var wR = spreadR.r, wG = spreadR.g, wB = spreadR.b
for i in steamAlpha.data.indices {
    wR.data[i] = steamRGB.r.data[i] * steamAlpha.data[i]
    wG.data[i] = steamRGB.g.data[i] * steamAlpha.data[i]
    wB.data[i] = steamRGB.b.data[i] * steamAlpha.data[i]
}
let bR = wR.boxBlurred(radius: 5), bG = wG.boxBlurred(radius: 5), bB = wB.boxBlurred(radius: 5)
let bA = steamAlpha.boxBlurred(radius: 5)
for i in steamAlpha.data.indices {
    let core = steamAlpha.data[i], glow = glowAlpha.data[i]
    let a = core + glow * (1 - core)
    steamOutAlpha.data[i] = a
    guard a > 1e-4 else { continue }
    let support = max(bA.data[i], 1e-4)
    let gr = bR.data[i] / support, gg = bG.data[i] / support, gb = bB.data[i] / support
    steamOut.r.data[i] = (steamRGB.r.data[i] * core + gr * glow * (1 - core)) / a
    steamOut.g.data[i] = (steamRGB.g.data[i] * core + gg * glow * (1 - core)) / a
    steamOut.b.data[i] = (steamRGB.b.data[i] * core + gb * glow * (1 - core)) / a
}

// 3. The background: the sky with the figure *and* the steam gone (the steam lives on its own layer now).
var knownBack = Plane(width: W, height: H)
let steamGrow = steamAlpha.boxBlurred(radius: 3).map { $0 > 0.02 ? 1 : 0 }
for i in knownBack.data.indices { knownBack.data[i] = (1 - figureGrow.data[i]) * (1 - steamGrow.data[i]) }
let back = inpaint(source, known: knownBack)

// 4. The figure: die-cut with a white margin (a blurred, thresholded mask ≈ a rounded dilation), bottom fade.
let marginPx = max(4, Int((Float(W) * 0.013).rounded()))          // ≈ 7 px at 540 → ≈ 2 mm on the card
let dilated = figureMask.boxBlurred(radius: marginPx).map { smoothstep(0.04, 0.16, $0) }
var figureAlpha = Plane(width: W, height: H)
var figureRGB = source
// The card's art window shows the image down to 96 % (`HeroCardLayout.windowV1`); the fade has to be over by then,
// or the faded hoodie hangs below the window's gold frame as a veil over the panel. It starts under the hands.
let fadeStart: Float = 0.895, fadeEnd: Float = 0.955
for y in 0..<H {
    let fy = (Float(y) + 0.5) / Float(H)
    let fade = 1 - smoothstep(fadeStart, fadeEnd, fy)
    for x in 0..<W {
        let i = y * W + x
        let m = figureMask.data[i], outer = max(m, dilated.data[i])
        // Straight colour: the painted figure over the white sticker margin.
        let whiteShare = outer > 1e-4 ? (outer - m) / outer : 0
        figureRGB.r.data[i] = source.r.data[i] * (1 - whiteShare) + 1 * whiteShare
        figureRGB.g.data[i] = source.g.data[i] * (1 - whiteShare) + 0.995 * whiteShare
        figureRGB.b.data[i] = source.b.data[i] * (1 - whiteShare) + 0.985 * whiteShare
        figureAlpha.data[i] = outer * fade
    }
}

// 5. The sticker's shadow on the sky: the die-cut silhouette, blurred, in deep night, and pushed down-right by
//    1.4 × 2.5 mm on the card (5 × 9 px) — baked, because the card draws it on the window's own clipped mesh.
let blurredFigure = figureAlpha.boxBlurred(radius: max(6, W / 50))
var shadowAlpha = Plane(width: W, height: H)
let shift = (x: 5, y: 9)
for y in 0..<H {
    for x in 0..<W {
        let sx = x - shift.x, sy = y - shift.y
        guard sx >= 0, sy >= 0 else { continue }
        shadowAlpha[x, y] = blurredFigure[sx, sy] * 0.55
    }
}
let deep: (Float, Float, Float) = (6.0 / 255, 10.0 / 255, 28.0 / 255)
let shadowRGB = RGB(r: Plane(width: W, height: H, value: deep.0), g: Plane(width: W, height: H, value: deep.1),
                    b: Plane(width: W, height: H, value: deep.2))

writePNG(outDir.appendingPathComponent("v4-avatar-back.png"), rgb: back, alpha: nil)
writePNG(outDir.appendingPathComponent("v4-avatar-figure.png"), rgb: figureRGB, alpha: figureAlpha)
writePNG(outDir.appendingPathComponent("v4-avatar-shadow.png"), rgb: shadowRGB, alpha: shadowAlpha)
writePNG(outDir.appendingPathComponent("v4-avatar-steam.png"), rgb: steamOut, alpha: steamOutAlpha)

let figureCover = figureMask.data.reduce(0, +) / Float(W * H)
let steamCover = steamAlpha.data.reduce(0, +) / Float(W * H)
print(String(format: "[avatar] figure covers %.1f %%, steam %.2f %% of the frame; sticker margin %d px", figureCover * 100,
             steamCover * 100, marginPx))

if let debugDir {
    writeMask(debugDir.appendingPathComponent("mask-figure.png"), figureMask)
    writeMask(debugDir.appendingPathComponent("mask-steam.png"), steamAlpha)
    writeMask(debugDir.appendingPathComponent("mask-vision.png"), visionMask)
    writeMask(debugDir.appendingPathComponent("mask-right-of-boy.png"), rightOfBoy)
    writeMask(debugDir.appendingPathComponent("mask-steam-rough.png"), roughGrow)
    writePNG(debugDir.appendingPathComponent("sky-under-steam.png"), rgb: sky, alpha: nil)
}
print(String(format: "[avatar] done in %.1f s → %@", Date().timeIntervalSince(started), outDir.path))
