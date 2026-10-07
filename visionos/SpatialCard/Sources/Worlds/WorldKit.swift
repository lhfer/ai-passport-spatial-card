import CoreGraphics
import Foundation
import RealityKit
import UIKit

/// Shared helpers for the procedural worlds: deterministic random, materials, and the handful of
/// generated textures (lit windows, glyph atlases, star field, caustics, paper grain).
@MainActor
enum WorldKit {
    // MARK: Random

    struct RNG {
        var state: UInt32
        init(_ seed: UInt32) { state = seed }
        mutating func next() -> Float {
            state = state &* 1664525 &+ 1013904223
            return Float(state >> 8) / Float(1 << 24)
        }
        mutating func range(_ a: Float, _ b: Float) -> Float { a + (b - a) * next() }
        mutating func pick<T>(_ items: [T]) -> T { items[min(items.count - 1, Int(next() * Float(items.count)))] }
        /// Standard normal (Box–Muller). Star sizes are log-normal and a galaxy's disc thickness is normal, and
        /// a uniform `range` gives neither: it makes every star the same and the band a slab with hard edges.
        mutating func gaussian() -> Float {
            let u = max(1e-6, next()), v = next()
            return sqrt(-2 * log(u)) * cos(2 * .pi * v)
        }
    }

    // MARK: Materials

    /// `opaque` is the opt-in for a texture that is known to be fully opaque (lit-window strips, the metro's
    /// glass): without it every *textured* unlit material lands in the transparent pass, which on a tile
    /// renderer means no early-z rejection and a full shade for every covered pixel — 霓虹雨城's skyline alone
    /// put ~60 such draws in front of the wearer. Left off by default so the other worlds are untouched.
    static func unlit(_ color: UIColor, opacity: Float = 1, texture: TextureResource? = nil, toneMap: Bool = true, opaque: Bool = false) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: toneMap)
        m.color = .init(tint: color, texture: texture.map { .init($0) })
        m.blending = opacity >= 0.999 && (texture == nil || opaque) ? .opaque : .transparent(opacity: .init(floatLiteral: opacity))
        m.opacityThreshold = nil
        m.faceCulling = .none
        if opacity < 0.999 { m.writesDepth = false }
        return m
    }

    static func emissive(_ color: UIColor, intensity: Float, opacity: Float = 1, texture: TextureResource? = nil, roughness: Float = 0.6) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color, texture: texture.map { .init($0) })
        m.emissiveColor = .init(color: color, texture: texture.map { .init($0) })
        m.emissiveIntensity = intensity
        m.roughness = .init(floatLiteral: roughness)
        if opacity < 0.999 {
            m.blending = .transparent(opacity: .init(floatLiteral: opacity))
            m.writesDepth = false
        }
        m.faceCulling = .none
        return m
    }

    static func pbr(_ color: UIColor, roughness: Float = 0.85, metallic: Float = 0, texture: TextureResource? = nil) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color, texture: texture.map { .init($0) })
        m.roughness = .init(floatLiteral: roughness)
        m.metallic = .init(floatLiteral: metallic)
        return m
    }

    // MARK: Textures (cached, pre-rendered off the main thread)

    private static var cache: [String: TextureResource] = [:]
    private static var prerendered: [String: [UInt8]] = [:]

    /// Procedural texture specs by key; the pixel loops are pure so `preheat()` can run them on a background thread.
    private struct Spec: Sendable {
        let width: Int
        let height: Int
        let rgba: @Sendable (Float, Float, inout RNG) -> SIMD4<Float>
    }

    /// Tileable value noise: bilinear interpolation over an integer lattice hashed per cell, wrapping at `freq` so
    /// the texture repeats seamlessly. A `Spec`'s RNG walks pixel by pixel and can only make white noise; clouds
    /// and star clouds need a hash of the cell instead.
    nonisolated static func valueNoise(_ u: Float, _ v: Float, freq: Int, octave: Int) -> Float {
        func lattice(_ x: Int, _ y: Int) -> Float {
            let cell = Int32(truncatingIfNeeded: x &* 374761393 &+ y &* 668265263 &+ octave &* 1442695041)
            return Float((UInt32(bitPattern: cell) &* 2654435761 >> 8) & 0xFFFF) / 65535
        }
        let fx = max(0, u) * Float(freq), fy = max(0, v) * Float(freq)
        let x0 = Int(fx), y0 = Int(fy)
        let tx = fx - Float(x0), ty = fy - Float(y0)
        let sx = tx * tx * (3 - 2 * tx), sy = ty * ty * (3 - 2 * ty)
        let xa = x0 % freq, ya = y0 % freq, xb = (x0 + 1) % freq, yb = (y0 + 1) % freq
        let top = lattice(xa, ya) + (lattice(xb, ya) - lattice(xa, ya)) * sx
        let bottom = lattice(xa, yb) + (lattice(xb, yb) - lattice(xa, yb)) * sx
        return top + (bottom - top) * sy
    }

    private nonisolated static func spec(for key: String) -> Spec? {
        switch key {
        case "nebula":
            // One puff of interstellar gas for 数据星云: three octaves of value noise pushed through a smoothstep
            // so the gas has ragged edges, times a radial mask so the quad's own corners never show. White: the
            // material tint colours each puff.
            return Spec(width: 512, height: 512) { u, v, _ in
                let n = valueNoise(u, v, freq: 4, octave: 0) * 0.55 + valueNoise(u, v, freq: 8, octave: 1) * 0.3 + valueNoise(u, v, freq: 16, octave: 2) * 0.15
                let a = max(0, min(1, (n - 0.35) / 0.55))
                let smooth = a * a * (3 - 2 * a)
                let r = min(1, 2 * sqrt((u - 0.5) * (u - 0.5) + (v - 0.5) * (v - 0.5)))
                let mask = pow(cos(r * .pi / 2), 1.6)
                return [1, 1, 1, smooth * mask]
            }
        case "milkyway":
            // The galactic band, wrapped once around a cylinder (u = around, v = across the band). A uniform haze
            // profile reads as fog, so the band carries the two things that make the real one legible: clumps of
            // star cloud along it, and dark dust lanes cutting through the bright middle.
            return Spec(width: 1024, height: 256) { u, v, _ in
                let profile = pow(sin(v * .pi), 2.2)
                // The structure has to run ALONG the band: v is compressed in every lookup so the clumps are long
                // streaks in u. Sampling v at full rate gives stripes parallel to the band's edges, which read as
                // layered fog rather than as one river of light.
                let clump = valueNoise(u, v * 0.16 + 0.41, freq: 14, octave: 5) * 0.6
                          + valueNoise(u, v * 0.11 + 0.23, freq: 30, octave: 6) * 0.4
                let lane = valueNoise(u, v * 0.22 + 0.3, freq: 5, octave: 7)
                let dust = max(0, min(1, (lane - 0.45) / 0.28))
                let a = profile * (0.45 + 0.8 * clump) * (1 - 0.55 * dust * dust * (3 - 2 * dust))
                return [1, 1, 1, max(0, min(1, a))]
            }
        case "caustics":
            return Spec(width: 256, height: 256) { u, v, _ in
                var m: Float = 0
                for k in 0..<7 {
                    let fk = Float(k)
                    let px = (sin(fk * 12.9898) * 0.5 + 0.5), py = (cos(fk * 78.233) * 0.5 + 0.5)
                    let dx = abs(u - px), dy = abs(v - py)
                    let d = sqrt(min(dx, 1 - dx) * min(dx, 1 - dx) + min(dy, 1 - dy) * min(dy, 1 - dy))
                    m += exp(-d * d * 60)
                }
                return [0.7, 0.95, 1, min(1, m * 0.5)]
            }
        case "paper":
            return Spec(width: 256, height: 256) { u, v, rng in
                let grain = 0.96 + 0.04 * rng.next()
                let edge = min(min(u, 1 - u), min(v, 1 - v))
                let dark: Float = edge < 0.03 ? 0.85 : 1
                return [0.96 * grain * dark, 0.92 * grain * dark, 0.86 * grain * dark, 1]
            }
        case "hazeband":
            // Uniform around the cylinder, soft vertical falloff: sin profile with a faint per-pixel grain.
            return Spec(width: 64, height: 256) { _, v, rng in
                let a = pow(sin(v * .pi), 0.9) * (0.92 + 0.08 * rng.next())
                return [1, 1, 1, a]
            }
        case "panelgrid":
            return Spec(width: 256, height: 256) { u, v, _ in
                // Dark panel with glowing seams every half tile; the seam colour alternates by tile parity.
                let fu = u * 2 - floor(u * 2), fv = v * 2 - floor(v * 2)
                let seam = min(min(fu, 1 - fu), min(fv, 1 - fv))
                if seam < 0.035 { return [1, 1, 1, 1] }
                if seam < 0.07 { return [1, 1, 1, 0.55] }
                return [0.05, 0.06, 0.11, 0.92]
            }
        case "ringband":
            return Spec(width: 256, height: 256) { u, v, rng in
                let dx = u - 0.5, dy = v - 0.5
                let r = sqrt(dx * dx + dy * dy) * 2
                let band = exp(-pow((r - 0.7) / 0.12, 2))
                return [1, 1, 1, band * (0.6 + 0.4 * rng.next())]
            }
        default:
            guard key.hasPrefix("windows-"), let seed = Int(key.dropFirst("windows-".count)) else { return nil }
            return Spec(width: 128, height: 512) { u, v, _ in
                let cols: Float = 14, rows: Float = 64
                let cu = u * cols, cv = v * rows
                let inWindow = (cu - floor(cu)) > 0.25 && (cu - floor(cu)) < 0.8 && (cv - floor(cv)) > 0.25 && (cv - floor(cv)) < 0.75
                let cell = Int(floor(cu)) + Int(floor(cv)) * 7 + seed * 31
                let h = Float((cell &* 2654435761) & 0xFFFF) / 65535
                if inWindow && h < 0.5 {
                    return h < 0.28 ? [1.0, 0.72, 0.4, 1] : [0.4, 0.85, 1.0, 1]
                }
                return [0.025, 0.03, 0.055, 1]
            }
        }
    }

    private nonisolated static func renderPixels(_ spec: Spec, key: String) -> [UInt8] {
        var rng = RNG(UInt32(truncatingIfNeeded: key.utf8.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1) }))
        let width = spec.width, height = spec.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let c = spec.rgba((Float(x) + 0.5) / Float(width), (Float(y) + 0.5) / Float(height), &rng)
                let i = (y * width + x) * 4
                let a = max(0, min(1, c.w))
                pixels[i] = UInt8(max(0, min(1, c.x)) * a * 255); pixels[i + 1] = UInt8(max(0, min(1, c.y)) * a * 255)
                pixels[i + 2] = UInt8(max(0, min(1, c.z)) * a * 255); pixels[i + 3] = UInt8(a * 255)
            }
        }
        return pixels
    }

    static let windowSeeds = 4

    /// Render every heavy procedural texture on a background thread and upload it, so entering a world never
    /// stalls a frame. Call once when the immersive space opens.
    static func preheat() {
        var keys = ["nebula", "milkyway", "caustics", "paper", "ringband", "hazeband", "panelgrid"]
        for i in 0..<windowSeeds { keys.append("windows-\(i)") }
        let pending = keys.filter { cache[$0] == nil && prerendered[$0] == nil }
        guard !pending.isEmpty else { return }
        print("[worlds] preheating \(pending.count) textures in the background")
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var rendered: [String: [UInt8]] = [:]
            for key in pending {
                guard let spec = spec(for: key) else { continue }
                rendered[key] = renderPixels(spec, key: key)
            }
            let done = rendered
            DispatchQueue.main.async {
                for (key, pixels) in done { prerendered[key] = pixels }
                for key in done.keys { _ = texture(key) }      // upload while idle
                print("[worlds] preheated \(done.count) textures in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            }
        }
    }

    static func texture(_ key: String) -> TextureResource {
        if let t = cache[key] { return t }
        guard let spec = spec(for: key) else { fatalError("WorldKit texture spec \(key)") }
        let pixels = prerendered.removeValue(forKey: key) ?? renderPixels(spec, key: key)
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: spec.width, height: spec.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: spec.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let tex = try? TextureResource(image: image, withName: key, options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)) else {
            fatalError("WorldKit texture \(key)")
        }
        cache[key] = tex
        return tex
    }

    /// Night building facade: grid of windows, ~50 % lit in warm/cool tones. Shared across towers (`windowSeeds` variants).
    static func windowsTexture(seed: Int) -> TextureResource { texture("windows-\(seed % windowSeeds)") }

    // MARK: CoreText textures (cached; `preheatText` renders them on a background thread before a world needs them)

    /// CGImages rendered ahead of time by `preheatText`, uploaded on first request.
    private static var prerenderedImages: [String: CGImage] = [:]

    /// One deferred CoreText render: `key` must equal the key the texture function builds for the same parameters, and
    /// `mipmaps` the choice it makes (v4 B5 §5: the upload happens ahead of the build now, with the same options).
    struct TextJob: Sendable {
        let key: String
        var mipmaps = false
        let render: @Sendable () -> CGImage?
    }

    /// Render CoreText / CoreGraphics textures in the background (sign text, labels, digit glyphs, train windows),
    /// so a world's `build` only uploads them. Call at space open with the jobs of the shipped worlds.
    static func preheatText(_ jobs: [TextJob]) {
        let pending = jobs.filter { cache[$0.key] == nil && prerenderedImages[$0.key] == nil }
        guard !pending.isEmpty else { return }
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var done: [String: CGImage] = [:]
            for job in pending {
                if let image = job.render() { done[job.key] = image }
            }
            let images = done
            let mipmaps = Dictionary(uniqueKeysWithValues: pending.map { ($0.key, $0.mipmaps) })
            DispatchQueue.main.async {
                for (key, image) in images where cache[key] == nil { prerenderedImages[key] = image }
                print("[worlds] preheated \(images.count) text textures in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
                // v4 B5 §5: and uploaded now, off the main thread, so a desk build only looks them up (the nebula's three
                // 2048 × 512 tag labels were most of a 139 ms build step).
                uploadAhead(images.keys.sorted().map { ($0, mipmaps[$0] ?? false) })
            }
        }
    }

    /// **v4 B5 §5.** Upload pre-rendered images with `TextureResource`'s async initialiser (the work happens off the main
    /// thread), into the same cache under the same key and options the build would have used. Whatever a build asks
    /// for before its upload has landed takes the old synchronous path; the late upload is then dropped.
    static func uploadAhead(_ keys: [(key: String, mipmaps: Bool)]) {
        guard !keys.isEmpty else { return }
        Task { @MainActor in
            let started = Date()
            var uploaded = 0
            for (key, mipmaps) in keys {
                guard cache[key] == nil, let cg = prerenderedImages[key] else { continue }
                let options: TextureResource.CreateOptions = mipmaps
                    ? .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll) : .init(semantic: .color)
                guard let tex = try? await TextureResource(image: cg, withName: key, options: options) else { continue }
                prerenderedImages[key] = nil
                if cache[key] == nil {
                    cache[key] = tex
                    uploaded += 1
                }
            }
            print(String(format: "[worlds] uploaded %d textures ahead of the builds in %.2f s (async)", uploaded,
                         Date().timeIntervalSince(started)))
        }
    }

    /// **v4 B5 §5.** The star sprites a world's build draws (`starSpriteTexture`, `starSpikeTexture`, `starHaloTexture`),
    /// rendered on a background queue and uploaded async ahead of the build: their pixel loops ran on the main thread
    /// inside the nebula's build steps (25–31 ms each on the simulator).
    static func prewarmStarTextures(sprites: [UIColor], spikes: [UIColor], halo: Bool) {
        func rgb(_ c: UIColor) -> (Float, Float, Float, String) {
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (Float(r), Float(g), Float(b), "\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))")
        }
        var jobs: [(key: String, render: @Sendable () -> CGImage?)] = []
        for c in sprites {
            let (r, g, b, k) = rgb(c)
            jobs.append(("star-sprite-\(k)", { renderStarSprite(r, g, b) }))
        }
        for c in spikes {
            let (r, g, b, k) = rgb(c)
            jobs.append(("star-spike-\(k)", { renderStarSpike(r, g, b) }))
        }
        if halo { jobs.append(("star-halo", { renderStarHalo() })) }
        let pending = jobs.filter { cache[$0.key] == nil && prerenderedImages[$0.key] == nil }
        guard !pending.isEmpty else { return }
        let work = pending
        DispatchQueue.global(qos: .utility).async {
            var images: [(String, CGImage)] = []
            for job in work { if let cg = job.render() { images.append((job.key, cg)) } }
            let done = images
            DispatchQueue.main.async {
                for (key, cg) in done where cache[key] == nil { prerenderedImages[key] = cg }
                uploadAhead(done.map { ($0.0, false) })
            }
        }
    }

    /// Cache lookup → pre-rendered image → synchronous render, then upload.
    private static func cachedTexture(key: String, mipmaps: Bool, render: () -> CGImage?) -> TextureResource {
        if let t = cache[key] { return t }
        guard let cg = prerenderedImages.removeValue(forKey: key) ?? render() else { fatalError("WorldKit texture \(key)") }
        let options: TextureResource.CreateOptions = mipmaps ? .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll) : .init(semantic: .color)
        guard let tex = try? TextureResource(image: cg, withName: key, options: options) else { fatalError("WorldKit texture \(key)") }
        cache[key] = tex
        return tex
    }

    // Panel grid

    nonisolated static func panelKey(edge: UIColor, edge2: UIColor) -> String { "panel-\(edge.hashValue)-\(edge2.hashValue)" }

    /// Neon panel: dark plate with seams tinted `edge` (a second colour is mixed in by `panelTexture(edge:edge2:)`).
    static func panelTexture(edge: UIColor, edge2: UIColor) -> TextureResource {
        cachedTexture(key: panelKey(edge: edge, edge2: edge2), mipmaps: true) { renderPanel(edge: edge, edge2: edge2) }
    }

    nonisolated static func renderPanel(edge: UIColor, edge2: UIColor) -> CGImage? {
        // Tint the white seams of the generic grid: draw the grid, then colourise seams with a checker of the two colours.
        let size = 256
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(UIColor(red: 0.05, green: 0.06, blue: 0.11, alpha: 0.92).cgColor)
            c.fill(CGRect(x: 0, y: 0, width: size, height: size))
            for i in 0..<2 {
                for j in 0..<2 {
                    let color = (i + j) % 2 == 0 ? edge : edge2
                    let rect = CGRect(x: CGFloat(i) * 128 + 4, y: CGFloat(j) * 128 + 4, width: 120, height: 120)
                    c.setStrokeColor(color.withAlphaComponent(0.95).cgColor)
                    c.setLineWidth(6)
                    c.stroke(rect)
                    c.setStrokeColor(color.withAlphaComponent(0.35).cgColor)
                    c.setLineWidth(14)
                    c.stroke(rect.insetBy(dx: -4, dy: -4))
                }
            }
        }.cgImage
    }

    // Glyph grid

    /// Tileable grid of random glyphs (8 × 8 cells) on transparent, for code-covered room surfaces.
    static func glyphGridTexture(color: UIColor) -> TextureResource {
        cachedTexture(key: "glyphgrid-\(color.hashValue)", mipmaps: true) { renderGlyphGrid(color: color) }
    }

    nonisolated static func renderGlyphGrid(color: UIColor) -> CGImage? {
        let size = 512
        var rng = RNG(0x61CD)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { _ in
            let font = UIFont.monospacedSystemFont(ofSize: 44, weight: .medium)
            for i in 0..<8 {
                for j in 0..<8 {
                    guard rng.next() < 0.8 else { continue }
                    let g = glyphs[Int(rng.next() * Float(glyphs.count)) % glyphs.count]
                    let alpha = 0.35 + 0.65 * rng.next()
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color.withAlphaComponent(CGFloat(alpha))]
                    NSAttributedString(string: g, attributes: attrs).draw(at: CGPoint(x: CGFloat(i) * 64 + 12, y: CGFloat(j) * 64 + 6))
                }
            }
        }.cgImage
    }
    static func nebulaTexture() -> TextureResource { texture("nebula") }
    static func milkyWayTexture() -> TextureResource { texture("milkyway") }
    static func causticsTexture() -> TextureResource { texture("caustics") }
    static func paperTexture() -> TextureResource { texture("paper") }
    static func ringBandTexture() -> TextureResource { texture("ringband") }
    static func hazeBandTexture() -> TextureResource { texture("hazeband") }

    // Single glyph

    nonisolated static func glyphKey(_ glyph: String, color: UIColor, size: Int) -> String { "glyph-\(glyph)-\(color.hashValue)-\(size)" }

    /// Glyph atlas: one big glyph per texture, drawn with CoreText (half-width katakana / digits / brackets).
    /// `size` is the texture edge in pixels (64 for the code rain, 256 for the split-flap digits).
    static func glyphTexture(_ glyph: String, color: UIColor, size: Int = 64) -> TextureResource {
        cachedTexture(key: glyphKey(glyph, color: color, size: size), mipmaps: size > 64) { renderGlyph(glyph, color: color, size: size) }
    }

    nonisolated static func renderGlyph(_ glyph: String, color: UIColor, size: Int) -> CGImage? {
        let px = CGSize(width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: px)
        return renderer.image { ctx in
            UIColor.clear.setFill()
            ctx.fill(CGRect(origin: .zero, size: px))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedSystemFont(ofSize: CGFloat(size) * 0.72, weight: .semibold),
                .foregroundColor: color,
            ]
            let str = NSAttributedString(string: glyph, attributes: attrs)
            let bounds = str.size()
            str.draw(at: CGPoint(x: (px.width - bounds.width) / 2, y: (px.height - bounds.height) / 2))
        }.cgImage
    }

    // Single line of text

    nonisolated static let textDefaultSize = CGSize(width: 1024, height: 256)

    nonisolated static func textKey(_ text: String, color: UIColor, fontSize: CGFloat, size: CGSize) -> String {
        "text-\(text)-\(color.hashValue)-\(Int(fontSize))-\(Int(size.width))x\(Int(size.height))"
    }

    /// Single-line text on a transparent background (neon signs, labels), 1024 × 256 px unless `size` says otherwise.
    static func textTexture(_ text: String, color: UIColor, fontSize: CGFloat = 96, bold: Bool = true, size: CGSize = textDefaultSize) -> TextureResource {
        cachedTexture(key: textKey(text, color: color, fontSize: fontSize, size: size), mipmaps: size.width > 1024) {
            renderText(text, color: color, fontSize: fontSize, bold: bold, size: size)
        }
    }

    nonisolated static func renderText(_ text: String, color: UIColor, fontSize: CGFloat, bold: Bool, size: CGSize) -> CGImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let attrs: [NSAttributedString.Key: Any] = [
                .font: bold ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.systemFont(ofSize: fontSize),
                .foregroundColor: color,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            let bounds = str.size()
            str.draw(at: CGPoint(x: (size.width - bounds.width) / 2, y: (size.height - bounds.height) / 2))
        }.cgImage
    }

    /// Deferred versions of the functions above, for `preheatText`.
    nonisolated static func textJob(_ text: String, color: UIColor, fontSize: CGFloat = 96, bold: Bool = true, size: CGSize = textDefaultSize) -> TextJob {
        TextJob(key: textKey(text, color: color, fontSize: fontSize, size: size), mipmaps: size.width > 1024) { renderText(text, color: color, fontSize: fontSize, bold: bold, size: size) }
    }
    nonisolated static func glyphJob(_ glyph: String, color: UIColor, size: Int) -> TextJob {
        TextJob(key: glyphKey(glyph, color: color, size: size), mipmaps: size > 64) { renderGlyph(glyph, color: color, size: size) }
    }
    /// Any other CoreGraphics texture (e.g. the metro's window strip) under its own key.
    static func customTexture(key: String, mipmaps: Bool, render: () -> CGImage?) -> TextureResource {
        cachedTexture(key: key, mipmaps: mipmaps, render: render)
    }

    // MARK: Star sprite

    /// Point-star sprite for the instanced star fields, in one colour temperature. Two reasons it is not
    /// `FXTextures.coreDisc` with a material tint:
    /// * a `PhysicallyBasedMaterial` whose `emissiveColor` carries a texture takes its emission from the
    ///   texture's RGB and ignores the tint, so a colour temperature only survives if it is *in* the sprite;
    /// * `CreateOptions(semantic:)` defaults to `.allocateAndGenerateAll`, and a minified mip of a point sprite
    ///   is a uniform square where the star should be, so mipmaps are turned off by name.
    static func starSpriteTexture(_ color: UIColor) -> TextureResource {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "star-sprite-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))"
        if let t = cache[key] { return t }
        guard let cg = prerenderedImages.removeValue(forKey: key) ?? renderStarSprite(Float(r), Float(g), Float(b)),
              let tex = try? TextureResource(image: cg, withName: key, options: .init(semantic: .color, mipmapsMode: .none)) else {
            fatalError("WorldKit texture \(key)")
        }
        cache[key] = tex
        return tex
    }

    nonisolated static func renderStarSprite(_ red: Float, _ green: Float, _ blue: Float, size: Int = 128) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) - 0.5, v = (Float(y) + 0.5) / Float(size) - 0.5
                let r = min(1, sqrt(u * u + v * v) * 2)
                let core = exp(-pow(r / 0.22, 2) * 2.2)
                let tail = pow(max(0, 1 - r), 4.5) * 0.32
                let a = max(0, min(1, core + tail))
                let i = (y * size + x) * 4
                // Premultiplied, like FXTextures: the RGB carries both the shape and the colour temperature.
                pixels[i] = UInt8(red * a * 255); pixels[i + 1] = UInt8(green * a * 255)
                pixels[i + 2] = UInt8(blue * a * 255); pixels[i + 3] = UInt8(a * 255)
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Hero-star sprite: a tight core, a soft halo and four thin diffraction spikes — the sparkle a bright star
    /// picks up in a lens, and the thing a field of even dots is missing. White; drawn over a coloured star.
    static func starSpikeTexture(_ color: UIColor) -> TextureResource {
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let key = "star-spike-\(Int(r * 255))-\(Int(g * 255))-\(Int(b * 255))"
        if let t = cache[key] { return t }
        guard let cg = prerenderedImages.removeValue(forKey: key) ?? renderStarSpike(Float(r), Float(g), Float(b)),
              let tex = try? TextureResource(image: cg, withName: key, options: .init(semantic: .color, mipmapsMode: .none)) else {
            fatalError("WorldKit texture \(key)")
        }
        cache[key] = tex
        return tex
    }

    nonisolated static func renderStarSpike(_ red: Float, _ green: Float, _ blue: Float, size: Int = 256) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) - 0.5, v = (Float(y) + 0.5) / Float(size) - 0.5
                let r = min(1, sqrt(u * u + v * v) * 2)
                let core = exp(-pow(r / 0.10, 2) * 2.2)
                let halo = pow(max(0, 1 - r), 5.5) * 0.22
                let du = min(1, abs(u) * 2), dv = min(1, abs(v) * 2)
                // Two crossed slivers, each fading to nothing before the quad's edge.
                let horizontal = exp(-pow(dv / 0.016, 2)) * pow(max(0, 1 - du), 2.4)
                let vertical = exp(-pow(du / 0.016, 2)) * pow(max(0, 1 - dv), 2.4)
                let a = max(0, min(1, core + halo + (horizontal + vertical) * 0.55))
                let i = (y * size + x) * 4
                pixels[i] = UInt8(red * a * 255); pixels[i + 1] = UInt8(green * a * 255)
                pixels[i + 2] = UInt8(blue * a * 255); pixels[i + 3] = UInt8(a * 255)
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Halo behind a named star: a single soft lobe falling off as `^5`, which is what keeps a large, dim glow
    /// from reading as a flat disc with an edge (`FXTextures.softDisc` is `cos²`, far too square-shouldered once
    /// the glow is several degrees wide).
    static func starHaloTexture() -> TextureResource {
        let key = "star-halo"
        if let t = cache[key] { return t }
        guard let cg = prerenderedImages.removeValue(forKey: key) ?? renderStarHalo(),
              let tex = try? TextureResource(image: cg, withName: key, options: .init(semantic: .color, mipmapsMode: .none)) else {
            fatalError("WorldKit texture \(key)")
        }
        cache[key] = tex
        return tex
    }

    nonisolated static func renderStarHalo(size: Int = 256) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        for y in 0..<size {
            for x in 0..<size {
                let u = (Float(x) + 0.5) / Float(size) - 0.5, v = (Float(y) + 0.5) / Float(size) - 0.5
                let r = min(1, sqrt(u * u + v * v) * 2)
                let a = pow(max(0, 1 - r), 5) + exp(-pow(r / 0.30, 2) * 2) * 0.35
                let c = UInt8(max(0, min(1, a)) * 255)
                let i = (y * size + x) * 4
                pixels[i] = c; pixels[i + 1] = c; pixels[i + 2] = c; pixels[i + 3] = c
            }
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: Sky dome

    /// Equirectangular sphere seen from inside (`generateSphere` UVs are not equirectangular, so a panorama on it
    /// is smeared): u = θ/2π grows turning right, v = 1 at the zenith. Rotate the entity by `skyYaw(centerU:)` so the
    /// panorama column `centerU` faces local −Z.
    static func skySphere(radius: Float, rings: Int = 24, segments: Int = 72) -> MeshResource {
        // v4 B5 §5: one mesh per size, built once (and ahead of the first build, `prewarmSkySphere`): the nebula's 48 × 128
        // dome was a 10 ms build step of its own.
        let key = skyKey(radius: radius, rings: rings, segments: segments)
        if let mesh = skyMeshes[key] { return mesh }
        let mesh = (try? MeshResource.generate(from: [skyDescriptor(radius: radius, rings: rings, segments: segments)]))
            ?? .generateSphere(radius: radius)
        skyMeshes[key] = mesh
        return mesh
    }

    private static var skyMeshes: [String: MeshResource] = [:]

    private nonisolated static func skyKey(radius: Float, rings: Int, segments: Int) -> String { "\(radius)-\(rings)-\(segments)" }

    /// **v4 B5 §5.** The dome's mesh built off the main thread (`MeshResource(from:)`'s async initialiser), ahead of the build.
    static func prewarmSkySphere(radius: Float, rings: Int = 24, segments: Int = 72) {
        let key = skyKey(radius: radius, rings: rings, segments: segments)
        guard skyMeshes[key] == nil else { return }
        Task.detached(priority: .utility) {
            let descriptor = skyDescriptor(radius: radius, rings: rings, segments: segments)
            guard let mesh = try? await MeshResource(from: [descriptor]) else { return }
            await MainActor.run {
                if skyMeshes[key] == nil { skyMeshes[key] = mesh }
            }
        }
    }

    /// The dome's vertices: equirectangular, seen from inside.
    nonisolated static func skyDescriptor(radius: Float, rings: Int, segments: Int) -> MeshDescriptor {
        var positions: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], uvs: [SIMD2<Float>] = [], indices: [UInt32] = []
        for r in 0...rings {
            let phi = Float(r) / Float(rings) * .pi          // 0 = zenith
            let y = cos(phi), ring = sin(phi)
            for s in 0...segments {
                let theta = Float(s) / Float(segments) * 2 * .pi
                let p = SIMD3<Float>(cos(theta) * ring, y, sin(theta) * ring)
                positions.append(p * radius)
                normals.append(-p)
                uvs.append([Float(s) / Float(segments), 1 - Float(r) / Float(rings)])
            }
        }
        let stride = UInt32(segments + 1)
        for r in 0..<rings {
            for s in 0..<segments {
                let a = UInt32(r) * stride + UInt32(s), b = a + 1, c = a + stride, d = c + 1
                indices += [a, c, b, b, c, d]
            }
        }
        var d = MeshDescriptor(name: "sky-dome")
        d.positions = MeshBuffers.Positions(positions)
        d.normals = MeshBuffers.Normals(normals)
        d.textureCoordinates = MeshBuffers.TextureCoordinates(uvs)
        d.primitives = .triangles(indices)
        return d
    }

    /// Yaw (about +Y, applied after the world yaw) that brings panorama column `centerU` to local −Z.
    static func skyYaw(centerU: Float) -> simd_quatf {
        simd_quatf(angle: (centerU - 0.75) * 2 * .pi, axis: [0, 1, 0])
    }

    /// Opaque unlit sky material: opaque and depth-writing, so the engine's shell (drawn first, no depth write) is
    /// rejected behind it and every transparent world piece composites over it.
    static func skyMaterial(_ texture: TextureResource, tint: UIColor) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        m.color = .init(tint: tint, texture: .init(texture))
        m.blending = .opaque
        m.faceCulling = .none
        return m
    }

    nonisolated static let glyphs: [String] = ["ｱ", "ｷ", "ﾂ", "ﾈ", "ﾒ", "ﾘ", "0", "1", "7", "Z", "{", "}", "λ", "Σ", "#", "%"]
}
