import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit

/// The hero card's procedural textures, drawn once when the card is built (≈ 10–40 ms in a Debug build, all together
/// ≈ 0.12 × 2048² texels — well inside the package's 2048² budget next to the four 540² avatar layers).
///
/// Procedural rather than bundled, for the same reason v3's `FXTextures` is: there is nothing to keep in sync, and
/// the panel texture is drawn for the exact aspect of the card shape it goes on.
@MainActor
enum HeroCardTextures {
    /// Straight (not premultiplied) RGBA, 0…1.
    typealias RGBA = SIMD4<Float>

    // MARK: - Holo foil

    /// Tileable holographic foil: the bible's four hues cycling along a diagonal, twice per tile, with a slow bright
    /// / dim modulation so there are bands to catch the eye as they flow. Opaque RGB — it is added onto the card, so
    /// its strength is the entity's opacity (0.12 square-on → 0.45 grazing).
    static func foil() -> TextureResource {
        let stops = HeroCardPalette.foil.map(rgba)
        return make(width: 256, height: 256, name: "v4.card.foil", repeats: true) { u, v in
            // Periodic in u (period ½) and v (period 1), so the flowing UVs never show a seam.
            let phase = u * 2 + 0.18 * sin(2 * .pi * v) + 0.06 * sin(2 * .pi * (u * 3 + v * 2))
            let x = (phase - floor(phase)) * Float(stops.count)
            let i = Int(x) % stops.count, j = (i + 1) % stops.count
            let f = x - floor(x)
            let s = f * f * (3 - 2 * f)
            var c = stops[i] * (1 - s) + stops[j] * s
            // Bands: a slow brightness swell and a fine diffraction ripple — kept shallow, so it reads as a sheen
            // moving over the card and not as stripes printed on it.
            let swell = 0.78 + 0.22 * (0.5 + 0.5 * sin(2 * .pi * (u * 4 - v * 1)))
            let ripple = 0.95 + 0.05 * sin(2 * .pi * (u * 24 + v * 24))
            c *= swell * ripple
            c.w = 1
            return c
        }
    }

    // MARK: - Crystal edge light

    /// Light caught in the edge of a thick crystal block, for a ring mesh whose v runs 0 at the outer edge → 1 inside
    /// (`FXMeshes.roundedRectRing`): a bright hairline right at the edge, then an exponential fall-off inward — what
    /// makes 12 mm of clear acrylic read as a *block* in a dark room, where there is nothing behind it to refract.
    static func edgeLight() -> TextureResource {
        let hot = rgba(HeroCardPalette.goldHot), gold = rgba(HeroCardPalette.gold)
        return make(width: 4, height: 128, name: "v4.card.edgeLight", repeats: false) { _, row in
            // RealityKit samples v up (mesh v = 0 reads the image's *bottom* row), and the ring's v is 0 at its outer
            // edge: so the edge is drawn at the bottom. (Rounds 3–8 had it the other way up — the hot core sat 6 mm
            // inside the edge, which is why the edge light never read as one.)
            let v = 1 - row
            // A crisp ≈ 0.25 mm hairline at the edge (v 0.028 of the 6 mm ring), then the fall-off inward.
            let core = exp(-pow(v / 0.028, 2))
            let falloff = exp(-v * 6.5)
            var c = hot * core + gold * (1 - core)
            c.w = min(1, 0.95 * core + 0.42 * falloff) * Float(1 - V4.HeroCardMotion.smoothstep(0.85, 1, Double(v)))
            return c
        }
    }

    // MARK: - Light sweep

    /// One soft diagonal band (along u), warm gold at the flanks and white-gold in the core, clear at both ends of u.
    /// Sampled clamp-to-edge, so the band crosses the card exactly once however far the UVs slide.
    static func sweepBand() -> TextureResource {
        let gold = rgba(HeroCardPalette.gold), hot = rgba(HeroCardPalette.goldHot)
        return make(width: 256, height: 4, name: "v4.card.sweep", repeats: false) { u, _ in
            let d = u - 0.5
            let body = exp(-pow(d / 0.11, 2))
            let core = exp(-pow(d / 0.028, 2))
            let edge = min(1, min(u, 1 - u) / 0.04)            // exactly 0 on the clamped border texels
            var c = gold * (1 - core) + hot * core
            c.w = min(1, (0.75 * body + 0.5 * core)) * edge
            return c
        }
    }

    // MARK: - Frost

    /// Frost tones (sRGB): cool pearl at the top, a touch of lavender lower down, warm white-gold where the edge
    /// scatters light in. Paler than A1's measured night frost (≈ #A0A0AC) on purpose: the deep-gold numerals need a
    /// light ground — #A67C2E on mid-grey is ≈ 2:1, on this ≈ 3.5:1 — and ink #1A2238 on it is ≈ 10:1.
    static let frostTop = UIColor(hex: "#DCDCE5")
    static let frostBottom = UIColor(hex: "#CFCEDA")
    static let frostEdge = UIColor(hex: "#EDE4D2")

    /// The card's face: a pale, luminous frost (the approved A1 direction) drawn for one card shape — a cool-pearl to
    /// lavender gradient, edge-lit (brighter and warmer within ≈ 10 mm of the outline, the way frosted acrylic
    /// glows along its polished edge), a fine frosted grain, and a faint old-gold guilloché (the engraved rosette of
    /// a certificate) behind the count.
    static func frost(layout: V4.HeroCardLayout) -> TextureResource {
        let face = layout.face
        let aspect = face.height / face.width
        let width = 400, height = Int((Float(width) * aspect).rounded())
        let top = rgba(frostTop), bottom = rgba(frostBottom), edge = rgba(frostEdge)
        let oldGold = rgba(HeroCardPalette.oldGold)
        let rosetteU: Float = 0.5
        let rosetteV = (face.maxY - layout.statsTopEstimate) / face.height + 0.02
        // Distance to the outline in metres, for the edge light (rounded-rect SDF, negative inside).
        let hw = face.width / 2, hh = face.height / 2, radius = layout.faceCornerRadius
        return make(width: width, height: height, name: "v4.card.frost.\(layout.shape.rawValue)", repeats: false) { u, v in
            var c = top * (1 - v) + bottom * v
            let px = (u - 0.5) * face.width, py = (0.5 - v) * face.height
            let qx = abs(px) - hw + radius, qy = abs(py) - hh + radius
            let outside = simd_length(SIMD2<Float>(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0) - radius
            let inset = max(0, -outside)                        // metres in from the edge
            let edgeLight = exp(-inset / 0.0045) * 0.75 + exp(-inset / 0.020) * 0.18
            c = c * (1 - edgeLight) + edge * edgeLight
            // Soft luminous centre.
            let dx = u - 0.5, dy = (v - 0.42) * aspect
            c *= 1 + 0.035 * exp(-(dx * dx + dy * dy) / (2 * 0.3 * 0.3))
            // Guilloché behind the count: fine old-gold lines, 9 % at their strongest.
            let rx = (u - rosetteU), ry = (v - rosetteV) * aspect
            let r = sqrt(rx * rx + ry * ry), theta = atan2(ry, rx)
            let wave = r * 34 + 0.55 * sin(theta * 7) * (0.4 + r)
            let line = pow(0.5 + 0.5 * cos(2 * .pi * wave), 22)
            let mask = max(0, min(1, (v - 0.45) / 0.18)) * (1 - min(1, r / 0.75))
            c = c * (1 - 0.09 * line * mask) + oldGold * (0.09 * line * mask)
            // Frosted grain: ±1.2 %, a hash, so it is stable run to run.
            let hash = sin(u * 12_989.8 + v * 78_233.1) * 43_758.547
            c *= 1 + 0.024 * ((hash - floor(hash)) - 0.5)
            c.w = 1
            return c
        }
    }

    /// Glow outside the card's edge, for a ring whose v runs 0 at its outer rim → 1 against the slab: nothing far
    /// out, rising to a warm gold where it meets the edge — the luminous halo the approved stack has in the dark.
    static func outerHalo() -> TextureResource {
        let gold = rgba(HeroCardPalette.gold), hot = rgba(HeroCardPalette.goldHot)
        return make(width: 4, height: 128, name: "v4.card.halo", repeats: false) { _, row in
            let v = 1 - row                                   // v up, as for `edgeLight()`
            // Steep: most of the light sits in the first millimetre against the edge.
            let a = pow(v, 3.2) * 0.95
            var c = gold * (1 - v) + hot * v
            c.w = a
            return c
        }
    }

    // MARK: - Gold dust

    /// 2 × 2 frames of one soft round mote at four brightnesses. Played as an image sequence at a random 3–8 Hz it is
    /// the bible's twinkle (§4: round, soft, no star shapes on the dust).
    static func dustSprites() -> TextureResource {
        let levels: [Float] = [1.0, 0.45, 0.8, 0.3]
        return make(width: 128, height: 128, name: "v4.card.dust", repeats: false) { u, v in
            let cx = u * 2, cy = v * 2
            let col = min(1, Int(cx)), row = min(1, Int(cy))
            let x = (cx - Float(col)) * 2 - 1, y = (cy - Float(row)) * 2 - 1
            let r = min(1, sqrt(x * x + y * y))
            let core = exp(-pow(r / 0.28, 2) * 2)
            let halo = pow(max(0, 1 - r), 2.4) * 0.55
            let a = min(1, core + halo) * levels[row * 2 + col]
            return RGBA(1, 1, 1, a)
        }
    }

    // MARK: - Sparkle

    /// The four-point star for the landing beat (bible §4: only on key beats, 6–12 mm, ≤ 6 on screen): a hot core and
    /// four tapered rays on the axes — no diagonal rays, which is what separates it from v3's snow-like sparkle.
    static func sparkle() -> TextureResource {
        make(width: 128, height: 128, name: "v4.card.sparkle", repeats: false) { u, v in
            let x = u * 2 - 1, y = v * 2 - 1
            let r = sqrt(x * x + y * y)
            let core = exp(-pow(r / 0.10, 2) * 1.6)
            func ray(_ along: Float, _ across: Float) -> Float {
                let t = min(1, abs(along))
                let width = 0.045 * pow(1 - t, 1.3) + 0.002
                return exp(-pow(across / width, 2)) * pow(1 - t, 1.6)
            }
            let rays = ray(x, y) + ray(y, x)
            let glow = pow(max(0, 1 - r), 3) * 0.25
            return RGBA(1, 1, 1, min(1, core + rays + glow))
        }
    }

    // MARK: - Drawing

    static func rgba(_ color: UIColor) -> RGBA {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(Float(r), Float(g), Float(b), Float(a))
    }

    /// Fills a premultiplied RGBA8 bitmap from a straight-alpha colour function of (u, v) ∈ [0, 1]² (v down) and wraps it
    /// in a `TextureResource` with mipmaps.
    static func make(width: Int, height: Int, name: String, repeats: Bool,
                     pixel: (Float, Float) -> RGBA) -> TextureResource {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            let v = (Float(py) + 0.5) / Float(height)
            for px in 0..<width {
                let u = (Float(px) + 0.5) / Float(width)
                let c = pixel(u, v)
                let a = max(0, min(1, c.w))
                let i = (py * width + px) * 4
                bytes[i] = UInt8(max(0, min(1, c.x)) * a * 255 + 0.5)
                bytes[i + 1] = UInt8(max(0, min(1, c.y)) * a * 255 + 0.5)
                bytes[i + 2] = UInt8(max(0, min(1, c.z)) * a * 255 + 0.5)
                bytes[i + 3] = UInt8(a * 255 + 0.5)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            fatalError("HeroCardTextures: could not build \(name)")
        }
        do {
            return try TextureResource(image: image, withName: name,
                                       options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        } catch {
            fatalError("HeroCardTextures: TextureResource failed for \(name): \(error)")
        }
    }

    /// A bundled PNG (Resources/v4 is flattened into the bundle root) as a colour texture with mipmaps.
    static func bundled(_ name: String) -> TextureResource? {
        guard let image = UIImage(named: name)?.cgImage else {
            print("[card] missing bundle image \(name).png")
            return nil
        }
        do {
            return try TextureResource(image: image, withName: name,
                                       options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        } catch {
            print("[card] TextureResource(\(name)) failed: \(error)")
            return nil
        }
    }

    /// Sampler for textures that must not wrap (the sweep band, the panel).
    static var clampSampler: MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return MaterialParameters.Texture.Sampler(descriptor)
    }

    /// Sampler for the tileable foil.
    static var repeatSampler: MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .repeat
        descriptor.tAddressMode = .repeat
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return MaterialParameters.Texture.Sampler(descriptor)
    }
}
