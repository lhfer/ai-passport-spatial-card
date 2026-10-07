import CoreGraphics
import Foundation
import Metal
import RealityKit
import UIKit

/// **The night-gold palette in linear light** (art bible §1). Every magic texture mixes colours in linear
/// space and only encodes at the end, because the blend (additive) happens in linear space: a gold mixed in
/// sRGB and then added looks paler and greener than the hex on the page.
enum MagicPalette {
    static let night = SIMD3<Float>(srgbHex: 0x0B1230)
    static let gold = SIMD3<Float>(srgbHex: 0xFFD58A)
    static let goldHot = SIMD3<Float>(srgbHex: 0xFFF3D6)
    static let oldGold = SIMD3<Float>(srgbHex: 0xC9A45C)
    static let amber = SIMD3<Float>(srgbHex: 0xFFB347)
    static let white = SIMD3<Float>(1, 1, 1)
    /// The holo-foil gradient, in order: only ever a colour *shift* at the edges, never a base colour.
    static let holo: [SIMD3<Float>] = [
        SIMD3(srgbHex: 0x7FE7FF), SIMD3(srgbHex: 0xB18CFF), SIMD3(srgbHex: 0xFF9ED8), SIMD3(srgbHex: 0xFFE08A),
    ]

    /// The holo gradient as a loop: phase 0…1 walks cyan → violet → pink → pale gold → back to cyan.
    static func holo(phase: Float) -> SIMD3<Float> {
        let count = Float(holo.count)
        let x = (phase - floor(phase)) * count
        let i = Int(x) % holo.count
        let f = x - floor(x)
        let s = f * f * (3 - 2 * f)
        return holo[i] + (holo[(i + 1) % holo.count] - holo[i]) * s
    }

    static func uiColor(_ linear: SIMD3<Float>, alpha: CGFloat = 1) -> UIColor {
        let e = SIMD3<Float>(MagicTextures.encode(linear.x), MagicTextures.encode(linear.y), MagicTextures.encode(linear.z))
        return UIColor(red: CGFloat(e.x), green: CGFloat(e.y), blue: CGFloat(e.z), alpha: alpha)
    }
}

extension SIMD3 where Scalar == Float {
    /// An sRGB hex colour, linearised.
    init(srgbHex hex: UInt32) {
        self.init(MagicTextures.decode(Float((hex >> 16) & 0xFF) / 255),
                  MagicTextures.decode(Float((hex >> 8) & 0xFF) / 255),
                  MagicTextures.decode(Float(hex & 0xFF) / 255))
    }
}

/// **v4's magic-light textures, drawn in code** (no image assets): the ribbon's intensity ramp, the head
/// glow, the gold-dust twinkle frames, the four-point glint and the screen burst's flip-book. All together
/// ≈ 0.2 M texels — a twentieth of the 2048² budget.
///
/// Authoring rule, measured in the A2 SDK probe (row 3): an sRGB `CGImage` with *premultiplied* alpha is
/// decoded as sRGB colour × **linear** alpha. So every pixel here is computed as linear premultiplied RGB,
/// written as straight colour (encoded) × alpha, with alpha = the pixel's brightest channel; an additive
/// material then adds exactly the linear RGB that was computed. Alpha is dithered by half a code value so the
/// long faint falloffs against the night blue do not band.
@MainActor
final class MagicTextures {
    static let shared = MagicTextures()

    /// U = intensity 0…1 (the ribbon's brightness, set per vertex), V = across the ribbon.
    let ribbonRamp: TextureResource
    /// A round glow with a white-hot core: the ribbon's head, the fairy itself.
    let headGlow: TextureResource
    /// Gold dust: one soft round dot at eight brightnesses (4 × 2 cells) — the twinkle is the flip-book.
    let dustTwinkle: TextureResource
    /// The four-point star of the key beats. The only star in the magic; never used as a resident particle.
    let starGlint: TextureResource
    /// Eight frames (8 × 1 cells, each at the screen's 3:4 aspect) of the screen's own star burst.
    let screenBurst: TextureResource
    static let screenBurstFrames = 8

    private init() {
        let spec = V4.GoldDustSpec.standard
        ribbonRamp = Self.make(width: 256, height: 64, name: "v4.ribbonRamp", pixel: Self.ribbonPixel)
        headGlow = Self.make(width: 128, height: 128, name: "v4.headGlow", pixel: Self.headPixel)
        let frames = spec.twinkleFrames
        dustTwinkle = Self.make(width: 256, height: 128, name: "v4.dustTwinkle") { x, y in
            let col = min(3, Int(x * 4)), row = min(1, Int(y * 2))
            let u = (x * 4 - Float(col)) * 2 - 1, v = (y * 2 - Float(row)) * 2 - 1
            let index = row * 4 + col
            return Self.dustPixel(u, v, brightness: index < frames.count ? frames[index] : 0)
        }
        starGlint = Self.make(width: 128, height: 128, name: "v4.starGlint", pixel: Self.starPixel)
        let cells = Self.screenBurstFrames
        screenBurst = Self.make(width: 96 * cells, height: 128, name: "v4.screenBurst") { x, y in
            let cell = min(cells - 1, Int(x * Float(cells)))
            let u = (x * Float(cells) - Float(cell)) * 2 - 1, v = y * 2 - 1
            return Self.burstPixel(u, v, progress: Float(cell) / Float(cells - 1))
        }
    }

    // MARK: - The ribbon

    /// One texel of the ribbon ramp, linear premultiplied RGB. `x` = intensity, `y` = across.
    static func ribbonPixel(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let intensity = x
        let d = abs(2 * y - 1)                                   // 0 on the centre line, 1 at the edge
        let core = exp(-pow(d / 0.26, 2) * 2.2)                  // the white-hot / gold filament
        let body = pow(max(0, 1 - d * d), 1.6)                   // a full, translucent band — silk, not a wire
        let rim = exp(-pow((d - 0.70) / 0.15, 2))                // the edges catch the light…
        let fringe = V4.smoothstep(1.0, 0.86, d)                 // …and there is exactly nothing past them
        let hot = V4.smoothstep(0.62, 1.0, intensity)
        // The dim end dissolves into the night rather than cooling to a brown wire: dim gold on night blue reads
        // as brown (the A2 lab measured the old amber tail at sRGB 80/64/49), so the last stretch leans to a
        // pale lavender — the holo loop's violet thinned with white-gold, the colour frame ①'s far tail takes.
        let cool = V4.smoothstep(0.30, 0.03, intensity)
        let dusk = MagicPalette.holo[1] * 0.55 + MagicPalette.goldHot * 0.45
        let warm = MagicPalette.gold + (dusk - MagicPalette.gold) * (0.6 * cool)
        let coreColor = warm + (MagicPalette.white - warm) * hot
        let bodyColor = warm * 0.9 + (MagicPalette.goldHot - warm * 0.9) * (hot * 0.6)
        // The rims walk through the holo loop as the ribbon cools — pale gold/cyan behind the head, then violet,
        // pink, gold — and only across the middle intensities: faint at the white-hot head, gone in the embers
        // (the bible: a colour shift, never a base colour; mixed into a dim tail it would read as grey).
        let holo = MagicPalette.holo(phase: 0.9 + (1 - intensity) * 1.0)
        let holoStrength: Float = 0.58 * (1 - 0.55 * hot) * V4.smoothstep(0.10, 0.34, intensity)
        let rimColor = holo * holoStrength + warm * (0.30 * (1 - holoStrength))
        let brightness = pow(intensity, 1.15)
        let rgb = (core * coreColor + body * bodyColor * 0.58 + rim * rimColor) * brightness * fringe
        return rgb
    }

    // MARK: - Glows

    static func headPixel(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let dx = x * 2 - 1, dy = y * 2 - 1
        let r = min(1, sqrt(dx * dx + dy * dy))
        let core = exp(-pow(r / 0.07, 2) * 2)
        let inner = exp(-pow(r / 0.22, 2) * 2)
        let halo = exp(-pow(r / 0.55, 2) * 2) * pow(1 - r, 1.5)
        return core * MagicPalette.white + inner * MagicPalette.goldHot * 0.55 + halo * MagicPalette.gold * 0.22
    }

    /// A soft round mote (no arms — at trail density arms read as snow), its core a little larger when bright.
    static func dustPixel(_ u: Float, _ v: Float, brightness: Float) -> SIMD3<Float> {
        let r = sqrt(u * u + v * v) / 0.95
        guard r < 1 else { return .zero }
        let coreRadius: Float = 0.16 + 0.06 * brightness
        let core = exp(-pow(r / coreRadius, 2) * 2)
        let glow = exp(-pow(r / 0.45, 2) * 2) * 0.32 * (1 - r)
        return SIMD3<Float>(repeating: brightness * min(1, core + glow))
    }

    static func starPixel(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let u = x * 2 - 1, v = y * 2 - 1
        let r = sqrt(u * u + v * v)
        func arm(_ along: Float, _ across: Float) -> Float {
            let reach = max(0, 1 - abs(along))
            let width = 0.010 + 0.075 * pow(reach, 2.2)
            return exp(-pow(across / width, 2)) * pow(reach, 1.6)
        }
        let arms = arm(u, v) + arm(v, u)
        let core = exp(-pow(r / 0.12, 2) * 2)
        // A wide soft bloom baked in (the simulator draws no BloomComponent): the "ding" is as much this
        // brief swell of warm light as it is the star's arms.
        let halo = exp(-pow(r / 0.42, 2) * 2) * 0.42 * (1 - r * 0.5)
        return min(1, core) * MagicPalette.white + min(1, arms) * MagicPalette.goldHot + max(0, halo) * MagicPalette.gold
    }

    // MARK: - The screen burst

    /// One frame of the 2D burst on the device screen, `u`,`v` in −1…1 across the cell (3:4, like the LCD),
    /// `progress` 0…1 across the 0.15 s: a flash, eight rays shooting out (long on the axes, short on the
    /// diagonals) and ten tiny stars flung outward, all cooling from white-gold to gold as they go.
    static func burstPixel(_ u: Float, _ v: Float, progress p: Float) -> SIMD3<Float> {
        // Physical proportions: the LCD is 36.7 × 49 mm, so x is scaled by 0.75 to keep circles round.
        let x = u * 0.75, y = v
        let r = sqrt(x * x + y * y)
        let angle = atan2(y, x)
        let out = 1 - pow(1 - p, 2.2)                              // ease-out travel
        let fade = pow(1 - p, 1.3)
        let rise = min(1, p / 0.12 + 0.35)
        // Flash: a hot centre that swells and cools.
        let flashRadius = 0.16 + 0.34 * out
        let flash = exp(-pow(r / flashRadius, 2) * 2) * rise * (0.35 + 0.65 * fade)
        // Rays: bold enough to read at arm's length (≈ 1.5 mm wide at the root on a 49 mm screen).
        var rays: Float = 0
        for k in 0..<8 {
            let theta = Float(k) * .pi / 4
            let long = k % 2 == 0
            let length = (long ? 1.25 : 0.80) * (0.20 + 0.80 * out)
            var delta = angle - theta
            delta = atan2(sin(delta), cos(delta))
            let along = r * cos(delta), across = abs(r * sin(delta))
            guard along > 0, along < length else { continue }
            let t = along / length
            let width = (long ? 0.060 : 0.045) * (1 - t) + 0.006
            rays += exp(-pow(across / width, 2)) * pow(1 - t, 1.1) * (long ? 1 : 0.75)
        }
        rays *= fade * rise
        // A thin ring riding out ahead of the rays.
        let ringRadius = 0.22 + 0.85 * out
        let ring = exp(-pow((r - ringRadius) / 0.035, 2)) * 0.55 * fade * rise
        // Flung stars
        var stars: Float = 0
        for k in 0..<10 {
            let theta = Float(k) * 2.39996 + 0.4                   // golden angle
            let distance = (0.18 + 0.05 * Float(k % 3)) + (0.60 + 0.12 * Float(k % 2)) * out
            let cx = cos(theta) * distance, cy = sin(theta) * distance
            let dx = x - cx, dy = y - cy
            let size: Float = 0.065 * (0.6 + 0.4 * fade)
            let arms = exp(-pow(dx / (size * 0.16), 2)) * max(0, 1 - abs(dy) / size)
                + exp(-pow(dy / (size * 0.16), 2)) * max(0, 1 - abs(dx) / size)
            let dot = exp(-(dx * dx + dy * dy) / (size * size * 0.06))
            stars += (arms * 0.7 + dot) * fade
        }
        let hot = MagicPalette.goldHot + (MagicPalette.white - MagicPalette.goldHot) * fade
        let warm = MagicPalette.gold + (MagicPalette.goldHot - MagicPalette.gold) * fade
        // Nothing past the cell's own edge: the burst lives on the LCD and nowhere else.
        let edge = V4.smoothstep(1.0, 0.94, abs(u)) * V4.smoothstep(1.0, 0.95, abs(v))
        return (min(1, flash) * hot + min(1, rays) * warm + min(1, ring) * warm + min(1, stars) * hot) * edge
    }

    // MARK: - Encoding

    /// sRGB transfer (IEC 61966-2-1).
    nonisolated static func encode(_ linear: Float) -> Float {
        let l = max(0, min(1, linear))
        return l <= 0.0031308 ? 12.92 * l : 1.055 * pow(l, 1 / 2.4) - 0.055
    }

    nonisolated static func decode(_ encoded: Float) -> Float {
        let e = max(0, min(1, encoded))
        return e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4)
    }

    /// Fills a premultiplied sRGB RGBA8 bitmap from linear premultiplied RGB (see the type's note).
    private static func make(width: Int, height: Int, name: String,
                             pixel: (Float, Float) -> SIMD3<Float>) -> TextureResource {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for py in 0..<height {
            let fy = (Float(py) + 0.5) / Float(height)
            for px in 0..<width {
                let fx = (Float(px) + 0.5) / Float(width)
                let rgb = simd_clamp(pixel(fx, fy), SIMD3<Float>(repeating: 0), SIMD3<Float>(repeating: 1))
                let alpha = max(rgb.x, max(rgb.y, rgb.z))
                let i = (py * width + px) * 4
                guard alpha > 1e-5 else { continue }
                // Half a code value of ordered dither on alpha: the faint tails turn into grain, not rings.
                let dither = Float((px * 7 + py * 13) % 16) / 16 - 0.5
                let a = max(0, min(255, (alpha * 255 + dither).rounded()))
                guard a > 0 else { continue }
                let straight = rgb / alpha
                let aNorm = a / 255
                bytes[i] = UInt8((encode(straight.x) * aNorm * 255).rounded())
                bytes[i + 1] = UInt8((encode(straight.y) * aNorm * 255).rounded())
                bytes[i + 2] = UInt8((encode(straight.z) * aNorm * 255).rounded())
                bytes[i + 3] = UInt8(a)
            }
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else {
            fatalError("MagicTextures: could not build CGImage for \(name)")
        }
        do {
            return try TextureResource(image: image, withName: name,
                                       options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll))
        } catch {
            fatalError("MagicTextures: TextureResource failed for \(name): \(error)")
        }
    }
}

/// The one material every piece of v4 magic light is drawn with until A1's ShaderGraph materials replace it:
/// `UnlitMaterial` on a program whose blend mode is **`.add`** (true additive — the A2 probe measured
/// background + light, not a mix), no tone mapping, double-sided, depth-tested but not depth-writing, and a
/// clamped sampler (the default sampler wraps: a ramp read at U = 1 would bleed its dark end into the head).
@MainActor
enum MagicMaterials {
    private static var program: UnlitMaterial.Program?

    static func additiveProgram() async -> UnlitMaterial.Program {
        if let program { return program }
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        descriptor.applyPostProcessToneMap = false
        let made = await UnlitMaterial.Program(descriptor: descriptor)
        program = made
        return made
    }

    static func additive(_ texture: TextureResource, tint: UIColor = .white) async -> UnlitMaterial {
        var material = UnlitMaterial(program: await additiveProgram())
        material.color = .init(tint: tint, texture: .init(texture, sampler: clampedSampler))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    static var clampedSampler: MaterialParameters.Texture.Sampler {
        let descriptor = MTLSamplerDescriptor()
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .linear
        return .init(descriptor)
    }
}
