import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// Procedurally drawn alpha textures for the glow effects. Everything is white with a soft alpha
/// falloff, so one texture serves every style: the material tint supplies the colour.
///
/// Generated once at first use (all textures together take well under 10 ms) so the app has no
/// image assets to keep in sync with the code.
@MainActor
final class FXTextures {
    static let shared = FXTextures()

    /// Radial glow: alpha 1 at the centre falling to 0 at the rim with a squared-cosine curve.
    let softDisc: TextureResource
    /// Tight-core glow with a long faint tail, for the "hot spot" on the device.
    let coreDisc: TextureResource
    /// Feathered ring, radius ≈ 0.42 of the texture, used by the expanding ripples.
    let ring: TextureResource
    /// Vertical light shaft: bright and wide at the bottom, fading and narrowing toward the top.
    let beam: TextureResource
    /// Two opposite soft blades with a radial falloff: rotated slowly it reads as a light sweep.
    let sweep: TextureResource
    /// Wrapped around `generateCone` (apex at v = 1): bright at the apex, fading toward the base,
    /// uniform around the circumference — a soft light volume instead of a hard triangle.
    let coneGlow: TextureResource
    /// Wrapped the same way as `coneGlow` but weighted the other way: dim at the apex (down on the device) and
    /// brightening toward the base — light *arriving* at the slab rather than leaving the projector.
    let coneGlowTop: TextureResource
    /// Small soft dot for the particle emitter.
    let particle: TextureResource
    /// Pixie dust: a hot core with four long spikes and two short ones — a star, not a dot, so a 3 mm sparkle
    /// still reads as a sparkle instead of a blob (笔记扇出 v2).
    let sparkle: TextureResource
    /// **V3-5 §7a.** A soft round mote — a core and a smooth falloff, no arms at all.
    ///
    /// The headset screen recording is what asked for it: 5 mm four-armed stars at 120/s read on camera as
    /// **snow**, not as a trail. The arms are what does it — at trail density they tile into a field of
    /// flakes. A dot at the same density reads as motion blur, which is what a trail is for. The star stays
    /// on the one-shot bursts, where there are twelve of them and each one is meant to be seen as a spark.
    let mote: TextureResource
    /// A soft diagonal highlight band with feathered ends, for the shimmer that crosses a cover.
    let glint: TextureResource
    /// Thin laser ray: bright core along the middle column, soft sides, slightly brighter at the base (v = 0).
    let ray: TextureResource
    /// Horizontal interference lines (1 bright row in 4) for the hologram card.
    let scanlines: TextureResource
    /// 4 × 4 sprite sheet: soft dots, four-point stars, short streaks, hex flecks (for `imageSequence`).
    let spriteSheet: TextureResource

    private var roundedCache: [String: TextureResource] = [:]

    /// Soft rounded-rectangle glow with the given width/height aspect (the "socket light" on the card).
    func roundedGlow(aspect: Float) -> TextureResource {
        let key = "glow-\(Int(aspect * 100))"
        if let cached = roundedCache[key] { return cached }
        let tex = FXTextures.make(size: 512, name: "fx.\(key)") { x, y in
            // Signed distance to a rounded rect occupying the central 70 % (aspect-corrected), then a soft falloff.
            let hw: Float = aspect >= 1 ? 0.35 : 0.35 * aspect
            let hh: Float = aspect >= 1 ? 0.35 / aspect : 0.35
            let d = FXTextures.roundedRectDistance(x - 0.5, y - 0.5, hw, hh, 0.06)
            return d <= 0 ? 1 : pow(max(0, 1 - d / 0.22), 2.2)
        }
        roundedCache[key] = tex
        return tex
    }

    /// Feathered rounded-rectangle ring hugging the edge (lift-off light leak / bevel frame).
    func roundedRing(aspect: Float) -> TextureResource {
        let key = "ring-\(Int(aspect * 100))"
        if let cached = roundedCache[key] { return cached }
        let tex = FXTextures.make(size: 512, name: "fx.\(key)") { x, y in
            let hw: Float = aspect >= 1 ? 0.44 : 0.44 * aspect
            let hh: Float = aspect >= 1 ? 0.44 / aspect : 0.44
            let d = abs(FXTextures.roundedRectDistance(x - 0.5, y - 0.5, hw, hh, 0.05))
            return d >= 0.045 ? 0 : pow(1 - d / 0.045, 1.8)
        }
        roundedCache[key] = tex
        return tex
    }

    /// Soft annulus: nothing inside `inner`, a `sin²` band out to `outer`, nothing beyond. Radii are
    /// fractions of the plane's **half** size (`radius(x, y)` is 1 at the edge midpoint), so a 0.30 m plane
    /// with `inner: 0.5` leaves a 7.5 cm clear hole in the middle.
    ///
    /// V3-2a H0: every round glow that used to sit *on* the device (the desk halo, the projector's base disk
    /// and ring) is one of these now, with a hole wide enough to clear the footprint prism.
    func softRing(inner: Float, outer: Float) -> TextureResource {
        let key = "softring-\(Int(inner * 1000))-\(Int(outer * 1000))"
        if let cached = roundedCache[key] { return cached }
        let tex = FXTextures.make(size: 512, name: "fx.\(key)") { x, y in
            let r = FXTextures.radius(x, y)
            guard r > inner, r < outer, outer > inner else { return 0 }
            let s = sin((r - inner) / (outer - inner) * .pi)
            return s * s
        }
        roundedCache[key] = tex
        return tex
    }

    /// The V3-2a H0 edge glow: a rounded-rect ring that hugs a rectangle **from the outside** and falls off
    /// outward, with a hard zero over the rectangle itself. All four numbers are metres, and the texture is
    /// generated for one exact plane size, so the ring's geometry is the ring's geometry — no aspect fudge.
    ///
    /// `inner` is the half extent of the clear rectangle; the band runs from there to `inner + width`.
    func edgeGlow(planeSize: SIMD2<Float>, inner: SIMD2<Float>, corner: Float, width: Float) -> TextureResource {
        let key = String(format: "edge-%.0f-%.0f-%.0f-%.0f-%.0f-%.0f",
                         planeSize.x * 10000, planeSize.y * 10000, inner.x * 10000, inner.y * 10000,
                         corner * 10000, width * 10000)
        if let cached = roundedCache[key] { return cached }
        let tex = FXTextures.make(size: 512, name: "fx.\(key)") { x, y in
            let px = (x - 0.5) * planeSize.x, py = (y - 0.5) * planeSize.y
            let d = FXTextures.roundedRectDistance(px, py, inner.x, inner.y, corner)
            guard d > 0, d < width else { return 0 }
            let t = d / width
            // Brightest right against the device, gone at the outer edge: light leaking out from under it.
            return pow(1 - t, 1.7) * min(1, t / 0.12)
        }
        roundedCache[key] = tex
        return tex
    }

    private static func roundedRectDistance(_ px: Float, _ py: Float, _ hw: Float, _ hh: Float, _ r: Float) -> Float {
        let qx = abs(px) - hw + r, qy = abs(py) - hh + r
        return simd_length(SIMD2<Float>(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0) - r
    }

    private init() {
        softDisc = FXTextures.make(size: 512, name: "fx.softDisc") { x, y in
            let r = min(1, FXTextures.radius(x, y))
            let c = cos(r * .pi / 2)
            return c * c
        }
        coreDisc = FXTextures.make(size: 512, name: "fx.coreDisc") { x, y in
            let r = min(1, FXTextures.radius(x, y))
            let core = exp(-pow(r / 0.22, 2) * 2.2)
            let tail = pow(max(0, 1 - r), 3) * 0.35
            return min(1, core + tail)
        }
        ring = FXTextures.make(size: 512, name: "fx.ring") { x, y in
            let r = FXTextures.radius(x, y)
            let d = abs(r - 0.42) / 0.075
            return d >= 1 ? 0 : pow(1 - d * d, 2)
        }
        beam = FXTextures.make(width: 128, height: 512, name: "fx.beam") { x, y in
            // y = 0 at the top of the image; the shaft base is at the bottom.
            let h = 1 - y                       // 1 at the base, 0 at the top
            let halfWidth = 0.18 + 0.42 * h     // narrower toward the top
            let dx = abs(x - 0.5) / halfWidth
            let profile = dx >= 1 ? 0 : pow(1 - dx * dx, 2)
            let vertical = pow(h, 1.35) * (1 - pow(1 - h, 8))   // soft at the very base, bright low, gone at the top
            return profile * vertical
        }
        ray = FXTextures.make(width: 32, height: 256, name: "fx.ray") { x, y in
            let dx = abs(x - 0.5) * 2
            let core = pow(max(0, 1 - dx), 3)
            let along = 0.75 + 0.25 * y            // v = 0 (image bottom... y = 1) is the base end
            return min(1, core * along)
        }
        scanlines = FXTextures.make(width: 8, height: 256, name: "fx.scanlines") { _, y in
            let row = Int(y * 256) % 4
            return row == 0 ? 0.9 : (row == 1 ? 0.25 : 0)
        }
        coneGlow = FXTextures.make(width: 64, height: 256, name: "fx.coneGlow") { _, y in
            // y = 0 is the top of the image = v = 1 = the cone apex (on the device).
            let towardApex = 1 - y
            return pow(towardApex, 1.6) * (1 - pow(towardApex, 24)) * 0.95 + 0.05 * (1 - y)
        }
        coneGlowTop = FXTextures.make(width: 64, height: 256, name: "fx.coneGlowTop") { _, y in
            // y = 1 is the base of the cone, which the rig points at the slab's underside.
            pow(y, 2.2) * 0.9 + 0.05
        }
        sweep = FXTextures.make(size: 512, name: "fx.sweep") { x, y in
            let r = min(1, FXTextures.radius(x, y))
            let theta = atan2(y - 0.5, x - 0.5)
            let blades = pow(abs(cos(theta)), 9) * 0.9 + pow(abs(sin(theta * 1.0 + 1.1)), 40) * 0.5
            let falloff = pow(max(0, 1 - r), 1.2) * min(1, r / 0.08)
            return min(1, blades * falloff)
        }
        particle = FXTextures.make(size: 64, name: "fx.particle") { x, y in
            let r = min(1, FXTextures.radius(x, y))
            return pow(max(0, 1 - r), 2.2)
        }
        sparkle = FXTextures.make(size: 64, name: "fx.sparkle") { x, y in
            let dx = (x - 0.5) * 2, dy = (y - 0.5) * 2
            let r = min(1, sqrt(dx * dx + dy * dy))
            let core = exp(-pow(r / 0.16, 2) * 2.0)
            // Four long spikes on the axes + two short ones on the diagonal, all fading with the radius.
            let a = atan2(dy, dx)
            let long = pow(abs(cos(2 * a)), 26)
            let short = pow(abs(cos(2 * (a - .pi / 4))), 40) * 0.45
            let arms = (long + short) * pow(max(0, 1 - r), 2.4)
            return min(1, core + arms * 0.95)
        }
        mote = FXTextures.make(size: 64, name: "fx.mote") { x, y in
            // Core plus a smooth radial falloff. No arms: at 120 births a second the arms are the snow.
            let dx = (x - 0.5) * 2, dy = (y - 0.5) * 2
            let r = min(1, sqrt(dx * dx + dy * dy))
            let core = exp(-pow(r / 0.30, 2) * 2.0)
            return min(1, core + pow(max(0, 1 - r), 2.6) * 0.55)
        }
        glint = FXTextures.make(size: 64, name: "fx.glint") { x, y in
            // A vertical band: bright along the middle column, feathered at the sides and at both ends, so the
            // quad that carries it has no visible edge when it leaves the cover.
            let dx = abs(x - 0.5) * 2
            let band = pow(max(0, 1 - dx), 1.8)
            let ends = pow(max(0, 1 - abs(y - 0.5) * 2), 0.9)
            return band * ends
        }
        spriteSheet = FXTextures.make(size: 256, name: "fx.sprites") { x, y in
            // 4 × 4 cells, 64 px each. Rows: soft dot, star, streak, hex fleck; columns vary size / rotation.
            let cx = x * 4, cy = y * 4
            let col = Int(cx), row = Int(cy)
            let u = (cx - Float(col)) * 2 - 1, v = (cy - Float(row)) * 2 - 1   // −1…1 inside the cell
            let scale: Float = 0.7 + 0.1 * Float(col)
            let r = sqrt(u * u + v * v) / scale
            switch row {
            case 0:
                return pow(max(0, 1 - r), 2.2)
            case 1:
                let a = atan2(v, u) + Float(col) * 0.4
                let spike = pow(abs(cos(2 * a)), 6)
                return min(1, pow(max(0, 1 - r), 1.4) * (0.35 + 0.9 * spike))
            case 2:
                let a = Float(col) * 0.5
                let uu = u * cos(a) - v * sin(a), vv = u * sin(a) + v * cos(a)
                let d = sqrt((uu * uu) * 0.12 + vv * vv * 3.2) / scale
                return pow(max(0, 1 - d), 2)
            default:
                let a = atan2(v, u)
                let hex = cos(.pi / 6) / cos((a.truncatingRemainder(dividingBy: .pi / 3)) - .pi / 6)
                let d = r / max(0.001, hex * 0.95)
                return d >= 1 ? 0 : pow(1 - d, 0.9)
            }
        }
    }

    // MARK: - Drawing

    private static func radius(_ x: Float, _ y: Float) -> Float {
        let dx = (x - 0.5) * 2, dy = (y - 0.5) * 2
        return sqrt(dx * dx + dy * dy)
    }

    private static func make(size: Int, name: String, alpha: (Float, Float) -> Float) -> TextureResource {
        make(width: size, height: size, name: name, alpha: alpha)
    }

    /// Fills a premultiplied RGBA8 bitmap with white × alpha(x, y) and wraps it in a TextureResource.
    private static func make(width: Int, height: Int, name: String, alpha: (Float, Float) -> Float) -> TextureResource {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            let fy = (Float(py) + 0.5) / Float(height)
            for px in 0..<width {
                let fx = (Float(px) + 0.5) / Float(width)
                let a = max(0, min(1, alpha(fx, fy)))
                let v = UInt8(a * 255 + 0.5)
                let i = (py * width + px) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v; pixels[i + 3] = v
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else {
            fatalError("FXTextures: could not build CGImage for \(name)")
        }
        do {
            return try TextureResource(image: image, withName: name, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        } catch {
            fatalError("FXTextures: TextureResource failed for \(name): \(error)")
        }
    }
}

// MARK: - Glow materials

enum FXMaterials {
    /// The same, with no texture at all: a flat hairline (the H0 socket ring).
    static func flat(tint: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: tint)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.opacityThreshold = nil
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    /// Unlit, tone-map-free, double-sided, depth-read-only glow material: white texture × tint × opacity.
    static func glow(_ texture: TextureResource, tint: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial(applyPostProcessToneMap: false)
        material.color = .init(tint: tint, texture: .init(texture))
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.opacityThreshold = nil
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }
}
