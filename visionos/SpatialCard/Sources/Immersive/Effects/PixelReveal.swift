import CoreGraphics
import Foundation
import RealityKit
import SwiftUI
import UIKit

/// "Pixel reassembly" reveal (user round 3, item 2): the card image on the screen breaks into a few
/// thousand colour-sampled pixel quads (GPU-instanced, one `MeshInstancesComponent` per colour
/// bucket), they lift row by row, swirl upward in a vortex with ghost trails and bloom, then
/// coalesce into the card's face at card size — where the glass card cross-fades in. Collapse plays
/// the same path backwards. Everything is a closed-form function of time evaluated in
/// `PixelRevealSystem`, so scrubbing / reversing is free and there is no per-particle state.
///
/// One pixel set is built per theme screen at start (`prepare(themes:)`); `configure(theme:)` only swaps
/// which set is enabled. Bands (which pixels are avatar / name / … / followers) come from
/// `passport-manifest.json`, the LCD's rounded-rect mask marks the black corners as edge sparks, and
/// "paper" is the bitmap's dominant background colour (white on the base screen, near-black on the worlds').
///
/// Colour rules ("ink becomes light"): dark ink → the look's highlight; coloured ink → its own colour
/// pushed 30 % toward white; background → a dim, half-size tint so the grid reads as a faint lattice.
@MainActor
final class PixelCloud {
    struct Pixel {
        var rest: SIMD3<Float>        // on the screen, anchor-local (y ≈ 0.001)
        var targetUV: SIMD2<Float>    // 0…1 across the card face (u right, v up)
        var bucket: Int
        var index: Int                // instance index inside its bucket
        var row: Float                // 0 = bottom edge (+Z), 1 = top edge (−Z)
        var phase: Float              // vortex start angle
        var swirlRadius: Float
        var lift: Float               // stagger 0…1
        var height: Float             // swirl top height (m)
        var isPaper: Bool
        // Ink-extraction path
        var band: Int                 // PassportBand raw value
        var glassUV: SIMD2<Float>     // where this glyph pixel lands on the glass card (u right, v up)
        var typesetOrder: Float       // 0…1 stagger inside the typeset stage
        var jitter: SIMD3<Float>      // small per-pixel offset used while floating / dusting
    }

    /// Everything derived from one theme bitmap.
    private struct ThemeSet {
        var container = Entity()
        var pixels: [Pixel] = []
        var bucketEntities: [ModelEntity] = []
        var ghostEntities: [ModelEntity] = []
        var bucketData: [LowLevelInstanceData] = []
        var ghostData: [LowLevelInstanceData] = []
        var bucketCounts: [Int] = []
        var paletteRGB: [SIMD3<Float>] = []
        var paperBucket = -1
    }

    /// Which choreography `write` evaluates.
    enum Mode {
        case reassembly   // A4: every pixel swirls up and re-forms the picture
        case inkLift      // A5: ink lifts as line art, flips to the reader, re-typesets; paper turns to dust
    }
    var mode: Mode = .inkLift

    let root = Entity()
    private var sets: [String: ThemeSet] = [:]
    private var active: ThemeSet?
    private(set) var footprint: SIMD2<Float>
    private(set) var theme: PassportManifest.Theme
    private var look: HologramLook = .desk

    /// World-size pixel on the screen and on the card.
    private(set) var paperCellSize: Float = 0.0014
    private(set) var cardCellSize: Float = 0.006

    init(footprint: SIMD2<Float>, theme: PassportManifest.Theme) {
        self.footprint = footprint
        self.theme = theme
        root.isEnabled = false
        let cols = 40
        paperCellSize = footprint.x / Float(cols)
        cardCellSize = HologramLayout.cardWidth * 0.86 / Float(cols)
    }

    /// Build the pixel sets of every theme screen (≈ 2 400 instances each); the current theme becomes active.
    func prepare(themes: [PassportManifest.Theme]) {
        let start = Date()
        for t in themes where sets[t.bitmap] == nil {
            if let built = build(theme: t) {
                sets[t.bitmap] = built
                root.addChild(built.container)
                built.container.isEnabled = false
            }
        }
        print(String(format: "[pixels] %d theme sets in %.0f ms", sets.count, Date().timeIntervalSince(start) * 1000))
        activate(theme)
    }

    /// Theme handover: enable that theme's instances (built on demand if `prepare` has not run for it).
    func configure(theme: PassportManifest.Theme) {
        guard theme.id != self.theme.id || active == nil else { return }
        self.theme = theme
        activate(theme)
    }

    private func activate(_ theme: PassportManifest.Theme) {
        if sets[theme.bitmap] == nil, let built = build(theme: theme) {
            sets[theme.bitmap] = built
            root.addChild(built.container)
        }
        for (name, set) in sets { set.container.isEnabled = name == theme.bitmap }
        active = sets[theme.bitmap]
    }

    func apply(look: HologramLook) {
        self.look = look
        for set in sets.values { recolor(set) }
    }

    var instanceCount: Int { active?.pixels.count ?? 0 }
    var pixels: [Pixel] { active?.pixels ?? [] }

    // MARK: - Build

    private func build(theme: PassportManifest.Theme) -> ThemeSet? {
        guard let image = UIImage(named: theme.bitmap)?.cgImage else {
            print("[pixels] bitmap \(theme.bitmap) not found")
            return nil
        }
        var set = ThemeSet()
        let manifest = PassportManifest.shared
        // Grid: ~40 columns, rows by aspect (40 × 53 for the 3:4 screen).
        let cols = 40
        let rows = max(8, Int((Float(cols) * footprint.y / footprint.x).rounded()))
        paperCellSize = footprint.x / Float(cols)
        cardCellSize = HologramLayout.cardWidth * 0.86 / Float(cols)

        let samples = PixelCloud.sample(image, cols: cols, rows: rows)
        // Quantise to at most 8 buckets: 4 levels per channel, keep the most frequent, snap the rest.
        var histogram: [UInt32: Int] = [:]
        var keys: [UInt32] = []
        keys.reserveCapacity(samples.count)
        for c in samples {
            let key = UInt32(min(3, Int(c.x * 3.999))) << 16 | UInt32(min(3, Int(c.y * 3.999))) << 8 | UInt32(min(3, Int(c.z * 3.999)))
            keys.append(key)
            histogram[key, default: 0] += 1
        }
        let palette = histogram.sorted { $0.value > $1.value }.prefix(8).map { $0.key }
        func rgb(_ key: UInt32) -> SIMD3<Float> {
            SIMD3<Float>(Float((key >> 16) & 3) / 3, Float((key >> 8) & 3) / 3, Float(key & 3) / 3)
        }
        let paletteRGB = palette.map(rgb)
        set.paletteRGB = paletteRGB
        func bucket(for key: UInt32) -> Int {
            if let i = palette.firstIndex(of: key) { return i }
            let c = rgb(key)
            var best = 0, bestD = Float.greatestFiniteMagnitude
            for (i, p) in paletteRGB.enumerated() {
                let d = simd_length_squared(p - c)
                if d < bestD { bestD = d; best = i }
            }
            return best
        }

        var seed: UInt32 = 0xC0FFEE
        func rand() -> Float { seed = seed &* 1664525 &+ 1013904223; return Float(seed >> 8) / Float(1 << 24) }

        set.bucketCounts = Array(repeating: 0, count: palette.count)
        // Pass 1: cells with bands. "Paper" = the most common colour bucket inside the rounded rect (the background).
        struct Cell { var c: Int; var r: Int; var b: Int; var isPaper: Bool; var band: Int; var u: Float; var vTop: Float }
        var cells: [Cell] = []
        cells.reserveCapacity(cols * rows)
        var insideHistogram: [Int: Int] = [:]
        for r in 0..<rows {
            for c in 0..<cols {
                let u = (Float(c) + 0.5) / Float(cols)
                let vTop = (Float(r) + 0.5) / Float(rows)
                guard !manifest.isMasked(u: u, vTop: vTop) else { continue }
                insideHistogram[bucket(for: keys[r * cols + c]), default: 0] += 1
            }
        }
        let paperBucket = insideHistogram.max { $0.value < $1.value }?.key ?? -1
        set.paperBucket = paperBucket
        var bandU: [Int: (min: Float, max: Float)] = [:]
        var bandV: [Int: (min: Float, max: Float)] = [:]
        for r in 0..<rows {
            for c in 0..<cols {
                let key = keys[r * cols + c]
                let b = bucket(for: key)
                let u = (Float(c) + 0.5) / Float(cols)
                let vTop = (Float(r) + 0.5) / Float(rows)
                let manifestBand = manifest.band(u: u, vTop: vTop, theme: theme)
                let isBorder = manifestBand == .border
                let isPaper = !isBorder && b == paperBucket
                // Background near the edge (outer 22 %) becomes the card's frame; inner background turns to dust.
                let outer = min(min(u, 1 - u), min(vTop, 1 - vTop)) < 0.22
                let band: PassportBand
                if isBorder { band = .border }
                else if isPaper { band = outer ? .frame : .paper }
                else { band = manifestBand }
                cells.append(Cell(c: c, r: r, b: b, isPaper: isPaper, band: band.rawValue, u: u, vTop: vTop))
                if !isPaper && !isBorder {
                    let bu = bandU[band.rawValue] ?? (1, 0), bv = bandV[band.rawValue] ?? (1, 0)
                    bandU[band.rawValue] = (min(bu.min, u), max(bu.max, u))
                    bandV[band.rawValue] = (min(bv.min, vTop), max(bv.max, vTop))
                }
            }
        }
        // Pass 2: pixels with glass targets.
        let avatar = theme.regions["avatar"]?.circle ?? [0.5, 0.24, 0.19]
        for cell in cells {
            let rest = SIMD3<Float>((cell.u - 0.5) * footprint.x, 0.001, (cell.vTop - 0.5) * footprint.y)   // image top at −Z
            let glass = PixelCloud.glassTarget(band: cell.band, u: cell.u, vTop: cell.vTop, avatar: avatar,
                                               bandU: bandU[cell.band] ?? (0, 1), bandV: bandV[cell.band] ?? (0, 1))
            let order: Float
            switch PassportBand(rawValue: cell.band) {
            case .avatar: order = 0.0 + 0.15 * Float(rand())
            case .name: order = 0.20 + 0.18 * cell.u
            case .handle: order = 0.42 + 0.14 * cell.u
            case .location: order = 0.56 + 0.08 * cell.u
            case .followers: order = 0.64 + 0.10 * cell.u
            case .tags: order = 0.74 + 0.18 * cell.u
            case .frame: order = 0.1 + 0.6 * Float(rand())
            default: order = 0.3 + 0.5 * Float(rand())
            }
            set.pixels.append(Pixel(
                rest: rest, targetUV: [cell.u, 1 - cell.vTop], bucket: cell.b, index: set.bucketCounts[cell.b], row: 1 - cell.vTop,
                phase: rand() * 2 * .pi, swirlRadius: 0.05 + 0.07 * rand(), lift: rand(),
                height: 0.10 + 0.10 * rand(), isPaper: cell.isPaper,
                band: cell.band, glassUV: glass, typesetOrder: order,
                jitter: [(rand() - 0.5) * 0.004, rand() * 0.003, (rand() - 0.5) * 0.004]))
            set.bucketCounts[cell.b] += 1
        }

        let quad = MeshResource.generatePlane(width: 1, height: 1)
        for (b, count) in set.bucketCounts.enumerated() {
            let paper = b == paperBucket
            for ghost in [false, true] {
                guard let data = try? LowLevelInstanceData(instanceCount: max(1, count)) else { continue }
                data.withMutableTransforms { t in for i in 0..<t.count { t[i] = matrix_identity_float4x4 * 0 } }
                let entity = ModelEntity(mesh: quad, materials: [PixelCloud.material(rgb: paletteRGB[b], paper: paper, ghost: ghost, look: look)])
                if let comp = try? MeshInstancesComponent(mesh: quad, instances: data,
                                                          bounds: BoundingBox(min: [-0.6, -0.3, -0.6], max: [0.6, 0.7, 0.6])) {
                    entity.components.set(comp)
                }
                set.container.addChild(entity)
                if ghost { set.ghostEntities.append(entity); set.ghostData.append(data) } else { set.bucketEntities.append(entity); set.bucketData.append(data) }
            }
        }
        print("[pixels] \(theme.id): \(set.pixels.count) pixels in \(palette.count) colour buckets (\(cols)×\(rows)), paper bucket \(paperBucket)")
        return set
    }

    private func recolor(_ set: ThemeSet) {
        for (b, entity) in set.bucketEntities.enumerated() where b < set.paletteRGB.count {
            let paper = b == set.paperBucket
            entity.model?.materials = [PixelCloud.material(rgb: set.paletteRGB[b], paper: paper, ghost: false, look: look)]
            if b < set.ghostEntities.count {
                set.ghostEntities[b].model?.materials = [PixelCloud.material(rgb: set.paletteRGB[b], paper: paper, ghost: true, look: look)]
            }
        }
    }

    private static func sample(_ image: CGImage, cols: Int, rows: Int) -> [SIMD3<Float>] {
        // Downsample with CoreGraphics (area-averaging) straight to cols × rows RGBA8.
        var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &pixels, width: cols, height: rows, bitsPerComponent: 8, bytesPerRow: cols * 4,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))
        var out: [SIMD3<Float>] = []
        out.reserveCapacity(cols * rows)
        // CGContext rows are bottom-up; flip so index 0 is the image's top row.
        for r in 0..<rows {
            let srcRow = rows - 1 - r
            for c in 0..<cols {
                let i = (srcRow * cols + c) * 4
                out.append([Float(pixels[i]) / 255, Float(pixels[i + 1]) / 255, Float(pixels[i + 2]) / 255])
            }
        }
        return out
    }

    private static func material(rgb: SIMD3<Float>, paper: Bool, ghost: Bool, look: HologramLook) -> PhysicallyBasedMaterial {
        let isInk = rgb.x < 0.2 && rgb.y < 0.2 && rgb.z < 0.2
        let color: UIColor
        if paper {
            color = look.tint
        } else if isInk {
            color = look.highlight
        } else {
            let lit = simd_mix(rgb, SIMD3<Float>(1, 1, 1), SIMD3<Float>(repeating: 0.3))
            color = UIColor(red: CGFloat(lit.x), green: CGFloat(lit.y), blue: CGFloat(lit.z), alpha: 1)
        }
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: color, texture: nil)
        m.emissiveColor = .init(color: color, texture: nil)
        m.emissiveIntensity = paper ? 0.9 : (ghost ? 1.6 : 2.6)
        m.roughness = .init(floatLiteral: 0.6)
        m.blending = .transparent(opacity: .init(floatLiteral: paper ? (ghost ? 0.18 : 0.42) : (ghost ? 0.35 : 0.95)))
        m.faceCulling = .none
        m.writesDepth = false
        return m
    }

    // MARK: - Path

    /// Normalised timeline (0…1 over `PixelRevealSystem.revealDuration`):
    /// lift 0.10–0.45 (staggered by row), swirl until 0.70, gather 0.70–0.90, fade 0.90–1.0.
    static let liftStart: Float = 0.10, liftSpan: Float = 0.35, gatherStart: Float = 0.70, gatherEnd: Float = 0.90

    /// Position (anchor-local), scale and "alive" factor of pixel `p` at normalised time `t`.
    /// `cardFrame` maps card-face UV to anchor-local space; `flat` is the paper orientation and `facing` the card's.
    @inline(__always)
    static func evaluate(_ p: Pixel, t: Float, cardOrigin: SIMD3<Float>, cardRight: SIMD3<Float>, cardUp: SIMD3<Float>,
                         paperCell: Float, cardCell: Float, cardSize: SIMD2<Float>) -> (position: SIMD3<Float>, scale: Float, upright: Float, alive: Float) {
        if p.band == borderBand {
            // Masked corner cells leave with the first rows and are gone before the gather.
            return edgeSpark(p, t: t, from: liftStart + 0.05 * p.lift, until: gatherStart, paperCell: paperCell)
        }
        let start = liftStart + liftSpan * ((1 - p.row) * 0.7 + p.lift * 0.3)   // bottom rows first
        if t <= start {
            return (p.rest, paperCell, 0, t > 0.02 ? 1 : 0)
        }
        // Swirl: rise with ease-out, orbit the vertical axis through the card center, radius blooms then tightens.
        let swirlT = min(1, (t - start) / max(0.05, gatherStart - start))
        let rise = 1 - pow(1 - swirlT, 2.2)
        let angle = p.phase + swirlT * 4.2 + rise * 1.5
        let radiusBloom = sin(swirlT * .pi)                       // 0 → 1 → 0
        let baseRadius = simd_length(SIMD2<Float>(p.rest.x, p.rest.z))
        let radius = baseRadius * (1 - swirlT) + p.swirlRadius * radiusBloom + 0.02 * swirlT
        var pos = SIMD3<Float>(cos(angle) * radius, 0.001 + p.height * rise, sin(angle) * radius)
        var scale = paperCell * (1 + 0.6 * swirlT)
        var upright = min(1, swirlT * 2)
        if t > gatherStart {
            let g = min(1, (t - gatherStart) / (gatherEnd - gatherStart))
            let e = g < 0.5 ? 4 * g * g * g : 1 - pow(-2 * g + 2, 3) / 2
            let target = cardOrigin + cardRight * ((p.targetUV.x - 0.5) * cardSize.x) + cardUp * ((p.targetUV.y - 0.5) * cardSize.y)
            pos = simd_mix(pos, target, SIMD3<Float>(repeating: e))
            scale = paperCell * 1.6 + (cardCell - paperCell * 1.6) * e
            upright = 1
        }
        var alive: Float = 1
        if t > gatherEnd {
            alive = max(0, 1 - (t - gatherEnd) / (1 - gatherEnd))
            scale *= alive
        }
        return (pos, scale, upright, alive)
    }

    // MARK: - Ink layout mapping (device screen from passport-manifest.json → glass card from HologramCardView)

    /// Masked corner cells (outside the LCD's rounded rect): not part of the card's content.
    static let borderBand = PassportBand.border.rawValue
    /// Edge background that re-forms as the glass card's bevel frame (formation principle: silhouette first).
    static let frameBand = PassportBand.frame.rawValue
    /// Corner radius of the card outline, normalised to the card width — derived from the one constant so the
    /// ink's silhouette cannot drift away from the slab it forms into (0.030 / 0.27 ≈ 0.111, v1's hand-set 0.11).
    static let frameCornerRadius: Float = HologramLayout.cardCornerRadius / HologramLayout.cardWidth

    /// Point on the rounded-rectangle outline of the glass card (width 1, height `aspect`, centred), for
    /// perimeter parameter `s` 0…1 starting at the bottom-left corner and running clockwise (right along the bottom).
    static func outlinePoint(s: Float, aspect: Float) -> SIMD2<Float> {
        let r = frameCornerRadius
        let w = 1 - 2 * r, h = aspect - 2 * r
        let arc = Float.pi / 2 * r
        let total = 2 * (w + h) + 4 * arc
        var d = (s - floor(s)) * total
        let hx: Float = 0.5, hy = aspect / 2
        // bottom edge (left → right)
        if d < w { return [-hx + r + d, -hy] }; d -= w
        if d < arc { let a = d / r; return [hx - r + r * sin(a), -hy + r - r * cos(a)] }; d -= arc
        if d < h { return [hx, -hy + r + d] }; d -= h
        if d < arc { let a = d / r; return [hx - r + r * cos(a), hy - r + r * sin(a)] }; d -= arc
        if d < w { return [hx - r - d, hy] }; d -= w
        if d < arc { let a = d / r; return [-hx + r - r * sin(a), hy - r + r * cos(a)] }; d -= arc
        if d < h { return [-hx, hy - r - d] }; d -= h
        let a = min(1, d / max(arc, 0.0001)) * (.pi / 2)
        return [-hx + r - r * cos(a), -hy + r - r * sin(a)]
    }

    /// Edge sparks for the masked corner cells: from `from` (0…1) they shoot outward from the card edge with a
    /// small upward arc, shrink and die by `until`. Used by both reveals so they never land on the glass card.
    @inline(__always)
    static func edgeSpark(_ p: Pixel, t: Float, from: Float, until: Float, paperCell: Float)
        -> (position: SIMD3<Float>, scale: Float, upright: Float, alive: Float) {
        if t <= from { return (p.rest, paperCell, 0, t > 0.02 ? 1 : 0) }
        let d = min(1, (t - from) / max(0.05, until - from))
        let ease = 1 - pow(1 - d, 2)
        let radial = simd_normalize(SIMD3<Float>(p.rest.x, 0, p.rest.z) + SIMD3<Float>(0.0001, 0, 0))
        let pos = p.rest + radial * (0.06 * ease) + SIMD3<Float>(0, 0.035 * sin(.pi * min(1, d * 1.1)) + 0.004, 0) + p.jitter * (3 * ease)
        return (pos, paperCell * (0.9 - 0.7 * ease), 0.5 * ease, 1 - d)
    }

    /// Glass card layout (u right, v up, 0…1 over the 86 % typeset area). Numbers follow HologramCardView's
    /// spacing with the stats row: avatar centre (0.5, 0.80) r 0.165; name v 0.53; handle 0.44; location 0.335;
    /// followers 0.23; chips 0.09. `avatar` is the theme's avatar circle `[cx, cy, r]` in image coordinates.
    static func glassTarget(band: Int, u: Float, vTop: Float, avatar: [Float],
                            bandU: (min: Float, max: Float), bandV: (min: Float, max: Float)) -> SIMD2<Float> {
        func norm(_ x: Float, _ range: (min: Float, max: Float)) -> Float {
            let span = max(0.001, range.max - range.min)
            return (x - range.min) / span
        }
        switch PassportBand(rawValue: band) {
        case .avatar:
            // Polar remap of the avatar disc (the circle radius is relative to the image width; the image is 3:4).
            let cx = avatar.count > 0 ? avatar[0] : 0.5, cy = avatar.count > 1 ? avatar[1] : 0.24
            let rx = avatar.count > 2 ? avatar[2] : 0.19
            let ry = rx / PassportManifest.shared.aspect          // r is a fraction of the width; vTop units are height
            let dx = (u - cx) / rx, dy = (vTop - cy) / ry
            return [0.5 + dx * 0.165, 0.80 - dy * 0.165]
        case .name: return [0.29 + 0.42 * norm(u, bandU), 0.53 + 0.055 - 0.11 * norm(vTop, bandV)]
        case .handle: return [0.30 + 0.40 * norm(u, bandU), 0.44 + 0.03 - 0.06 * norm(vTop, bandV)]
        case .location: return [0.375 + 0.25 * norm(u, bandU), 0.335 + 0.025 - 0.05 * norm(vTop, bandV)]
        case .followers: return [0.31 + 0.38 * norm(u, bandU), 0.23 + 0.04 - 0.08 * norm(vTop, bandV)]
        case .tags: return [0.09 + 0.82 * norm(u, bandU), 0.09 + 0.045 - 0.09 * norm(vTop, bandV)]
        case .frame:
            // Perimeter parameter from the cell's angle around the image centre, so neighbouring edge background
            // stays neighbouring on the frame. Frame is at 100 % card size while the typeset area is 86 %.
            let angle = atan2(-(vTop - 0.5), u - 0.5)                      // image up is −vTop
            let s = (angle + .pi * 1.25) / (2 * .pi)
            let pt = outlinePoint(s: s, aspect: HologramLayout.cardHeight / HologramLayout.cardWidth)
            return [0.5 + pt.x / 0.86, 0.5 + (pt.y / (HologramLayout.cardHeight / HologramLayout.cardWidth)) / 0.86]
        default: return [u, 0.05]                                          // dust: toward the card's foot
        }
    }

    /// Ink-extraction timeline (normalised 0…1 over `PixelRevealSystem.inkDuration`):
    /// 0.12–0.32 ink lifts 4 cm as one sheet · 0.25–0.60 paper turns to dust · 0.32–0.55 sheet flips upright
    /// facing the reader while rising · 0.55–0.92 glyphs re-typeset onto the glass layout · 0.92–1 fade.
    static let inkLiftStart: Float = 0.12, inkFlipStart: Float = 0.32, inkTypesetStart: Float = 0.55, inkTypesetEnd: Float = 0.84
    /// Formation: hold in silhouette, frame resolves (frame particles shrink into it), glass body resolves (glyphs shrink).
    static let inkHoldEnd: Float = 0.89, inkFrameResolveEnd: Float = 0.94

    @inline(__always)
    static func evaluateInk(_ p: Pixel, t: Float, cardOrigin: SIMD3<Float>, cardRight: SIMD3<Float>, cardUp: SIMD3<Float>,
                            footprint: SIMD2<Float>, paperCell: Float, cardCell: Float, cardSize: SIMD2<Float>)
        -> (position: SIMD3<Float>, scale: Float, upright: Float, alive: Float) {
        if p.band == borderBand {
            // Corner cells spark off the edge while the ink sheet lifts; gone before the flip completes.
            return edgeSpark(p, t: t, from: inkLiftStart + 0.06 * p.lift, until: inkTypesetStart - 0.05, paperCell: paperCell)
        }
        if p.isPaper && p.band != frameBand {
            // Dust: shrink, sink a little, drift outward, gone by 0.60.
            if t < 0.25 { return (p.rest, paperCell, 0, t > 0.02 ? 1 : 0) }
            let d = min(1, (t - 0.25) / 0.35)
            let ease = 1 - pow(1 - d, 2)
            let radial = simd_normalize(SIMD3<Float>(p.rest.x, 0, p.rest.z) + SIMD3<Float>(0.0001, 0, 0))
            let pos = p.rest + radial * (0.03 * ease) + SIMD3<Float>(0, -0.0025 * ease + p.jitter.y * (1 - ease), 0) + p.jitter * ease
            return (pos, paperCell * (1 - 0.7 * ease), 0, 1 - d)
        }
        if t <= inkLiftStart { return (p.rest, paperCell, 0, t > 0.02 ? 1 : 0) }

        // Sheet transform: the whole line-art moves rigidly until the typeset stage.
        let local = SIMD3<Float>(p.rest.x, 0, p.rest.z)                         // offset from the sheet centre
        let liftT = min(1, (t - inkLiftStart) / (inkFlipStart - inkLiftStart))
        let lift = 1 - pow(1 - liftT, 3)
        var centre = SIMD3<Float>(0, 0.001 + 0.04 * lift, 0)
        var angle: Float = 0                                                      // 0 = lying flat, π/2 = upright facing +Z
        var scale = paperCell * (1 + 0.3 * lift)
        if t > inkFlipStart {
            let f = min(1, (t - inkFlipStart) / (inkTypesetStart - inkFlipStart))
            let e = f < 0.5 ? 4 * f * f * f : 1 - pow(-2 * f + 2, 3) / 2
            angle = e * (.pi / 2)
            centre.y = 0.041 + (HologramLayout.cardCenterHeight * 0.55 - 0.041) * e
            centre.z = -0.02 * e                                                  // eases a little back as it stands
        }
        // Rotate the flat offset about X: (x, 0, z) → (x, −z·sin, z·cos); image top (−z) goes up.
        var pos = centre + SIMD3<Float>(local.x, -local.z * sin(angle), local.z * cos(angle)) + p.jitter * (0.5 * lift * (1 - min(1, max(0, (t - inkFlipStart) / 0.2))))
        var upright = angle / (.pi / 2)
        var alive: Float = 1

        if t > inkTypesetStart {
            let span = inkTypesetEnd - inkTypesetStart
            let start = inkTypesetStart + span * 0.75 * p.typesetOrder
            let g = max(0, min(1, (t - start) / (span * 0.25)))
            let e = g < 0.5 ? 4 * g * g * g : 1 - pow(-2 * g + 2, 3) / 2
            if p.band == PassportBand.otherInk.rawValue {
                // Ink with no place on the glass card: drifts down toward the foot and dissolves.
                let target = cardOrigin + cardRight * ((p.glassUV.x - 0.5) * cardSize.x) + cardUp * (-0.5 * cardSize.y - 0.03)
                pos = simd_mix(pos, target, SIMD3<Float>(repeating: e))
                alive = 1 - e
                scale *= 1 - 0.5 * e
            } else {
                let target = cardOrigin + cardRight * ((p.glassUV.x - 0.5) * cardSize.x) + cardUp * ((p.glassUV.y - 0.5) * cardSize.y)
                pos = simd_mix(pos, target, SIMD3<Float>(repeating: e))
                scale = scale + (cardCell * (p.band == frameBand ? 1.1 : 0.9) - scale) * e
            }
            upright = 1
        }
        if t > inkTypesetEnd {
            // Hold in silhouette with a faint shimmer, then resolve: frame particles first, glyphs after.
            let shimmer = 1 + 0.08 * sin((t - inkTypesetEnd) * 60 + p.phase)
            scale *= shimmer
            let resolveStart = p.band == frameBand ? inkHoldEnd : inkFrameResolveEnd
            let resolveEnd = p.band == frameBand ? inkFrameResolveEnd : 1
            if t > resolveStart {
                let k = min(1, (t - resolveStart) / max(0.01, resolveEnd - resolveStart))
                let e = k * k
                alive *= 1 - e
                scale *= 1 - e
            }
        }
        return (pos, scale, upright, alive)
    }

    // MARK: - Per-frame write

    /// Writes every instance transform for normalised time `t` (and ghosts at `t - ghostLag`).
    func write(t: Float, ghostLag: Float, cardGroup: Entity, flatOrientation: simd_quatf) {
        guard let set = active, !set.pixels.isEmpty, let parent = root.parent else { return }
        let cardMatrix = cardGroup.transformMatrix(relativeTo: parent)
        let cardOrigin = SIMD3<Float>(cardMatrix.columns.3.x, cardMatrix.columns.3.y, cardMatrix.columns.3.z)
        let cardRight = simd_normalize(SIMD3<Float>(cardMatrix.columns.0.x, cardMatrix.columns.0.y, cardMatrix.columns.0.z))
        let cardUp = simd_normalize(SIMD3<Float>(cardMatrix.columns.1.x, cardMatrix.columns.1.y, cardMatrix.columns.1.z))
        let facing = simd_quatf(simd_float3x3(columns: (cardRight, cardUp, simd_normalize(simd_cross(cardRight, cardUp)))))
        let cardSize = SIMD2<Float>(HologramLayout.cardWidth * 0.86, HologramLayout.cardHeight * 0.86)
        let paperCell = paperCellSize, cardCell = cardCellSize

        for (which, lag) in [(0, Float(0)), (1, ghostLag)] {
            let time = t - lag
            let datas = which == 0 ? set.bucketData : set.ghostData
            guard datas.count == set.bucketCounts.count else { continue }
            // Fill per bucket. Pixels are grouped by bucket index inside each buffer.
            for (b, data) in datas.enumerated() {
                data.withMutableTransforms { transforms in
                    for p in set.pixels where p.bucket == b {
                        let e: (position: SIMD3<Float>, scale: Float, upright: Float, alive: Float)
                        switch mode {
                        case .reassembly:
                            e = PixelCloud.evaluate(p, t: time, cardOrigin: cardOrigin, cardRight: cardRight, cardUp: cardUp,
                                                    paperCell: paperCell, cardCell: cardCell, cardSize: cardSize)
                        case .inkLift:
                            e = PixelCloud.evaluateInk(p, t: time, cardOrigin: cardOrigin, cardRight: cardRight, cardUp: cardUp,
                                                       footprint: footprint, paperCell: paperCell, cardCell: cardCell, cardSize: cardSize)
                        }
                        let s = p.isPaper ? e.scale * (mode == .reassembly ? 0.55 : 0.8) : e.scale
                        if e.alive <= 0 || s <= 0.00005 {
                            transforms[p.index] = matrix_identity_float4x4 * 0
                            continue
                        }
                        let rotation = simd_slerp(flatOrientation, facing, e.upright)
                        var m = simd_float4x4(rotation)
                        m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
                        m.columns.3 = SIMD4<Float>(e.position, 1)
                        transforms[p.index] = m
                    }
                }
            }
        }
    }

    func hide() {
        root.isEnabled = false
    }
}

// MARK: - Component / System

/// Drives a `PixelCloud` forward (reveal) or backward (collapse) over `duration` seconds.
struct PixelRevealComponent: Component {
    var cloud: PixelCloud
    var cardGroup: Entity
    var direction: Float = 1          // +1 reveal, −1 collapse
    var duration: Float
    var elapsed: Float = 0
    var normalizedStart: Float = 0    // collapse starts from 1
    var onFinish: (() -> Void)?
}

final class PixelRevealSystem: System {
    private static let query = EntityQuery(where: .has(PixelRevealComponent.self))
    static let revealDuration: Float = 2.7
    static let inkDuration: Float = 3.3
    static let collapseDuration: Float = 1.2
    private static let flat = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])   // XY quad → lying in XZ, facing up

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("pixelReveal", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: PixelRevealSystem.query, updatingSystemWhen: .rendering) {
            guard var reveal = entity.components[PixelRevealComponent.self] else { continue }
            reveal.elapsed += dt
            let progress = min(1, reveal.elapsed / max(0.01, reveal.duration))
            // Collapse runs from the assembled state (normalizedStart) back to the paper (0).
            let t = reveal.direction > 0 ? progress : reveal.normalizedStart * (1 - progress)
            reveal.cloud.write(t: t, ghostLag: 0.035 * reveal.direction, cardGroup: reveal.cardGroup, flatOrientation: PixelRevealSystem.flat)
            if progress >= 1 {
                entity.components.remove(PixelRevealComponent.self)
                let finish = reveal.onFinish
                Task { @MainActor in finish?() }
            } else {
                entity.components.set(reveal)
            }
        }
    }
}

// MARK: - Frame-rate probe

/// **V3-5 §5.** Where every `[perf]` line gets its prefix, and where the scene census lives.
///
/// `--perf-tag <name>` turns `[perf]` into `[perf:name]` on every one of them. The next round measures the
/// hand form with `xctrace`, which means two runs of the same build started from `devicectl` with different
/// flags; without a tag their `[perf]` lines are indistinguishable in one log. (A reviewer's grep therefore
/// becomes `\[perf(:[^]]*)?\]` when a tag is in use; with no tag the output is byte-for-byte what it was.)
enum PerfLog {
    /// Set once, from `AppModel`'s flag parsing.
    static var tag: String? {
        didSet {
            // A tag ends up inside `String(format:)` format strings, and `]` / `%` in one would be a mess.
            tag = tag.map { $0.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." } }
                .flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    static var prefix: String { tag.map { "[perf:\($0)]" } ?? "[perf]" }

    /// The subtrees the census walks — the hologram controller's and the world engine's. Set by
    /// `ImmersiveView` once both are in the scene; nil (and the census silent) in a run with no scene.
    static var sceneRoots: (() -> [Entity])?

    /// **v4 B5 §1.** One more line after every window, when there is something to say (the `cmd perf` state the window
    /// was measured in). Set by `ImmersiveView`; nil = nothing.
    static var windowNote: (() -> String?)?

    /// **V3-5 §5.** One line of "what is actually in the scene at the moment this probe reported", so the
    /// next round's `xctrace` capture has something to correlate its frames with. Walked once, at the
    /// moment of reporting, and only for probes that ask for it.
    ///
    /// `particles` is an **estimate**: RealityKit exposes no live particle count, so it is the steady state
    /// each emitting emitter implies — `birthRate × lifeSpan`, plus `birthRate × spawned.birthRate ×
    /// spawned.lifeSpan` for the ones that spawn on death (the rain's splashes). It is the same arithmetic
    /// `NeonCityWorld`'s rain budget is written in.
    /// **V3-6 §2.** …and which emitters they are. The third headset round's evidence for "the pick-up path
    /// keeps something alive that the summon path does not" was two numbers (`14 emitters` against `8–9`)
    /// with no way to say *which* fourteen. The census now names them — deduped, `×N` for repeats — so one
    /// `scene:` line after a pick-up and one after a summon is a diff, not a riddle. `cones on|off` is
    /// `--hand-cones`, on the same line because it is the first thing that list is read against.
    static func census() -> String? {
        guard let roots = sceneRoots?() else { return nil }
        var entities = 0, attachments = 0, emitters = 0
        var particles: Double = 0
        var names: [String: Int] = [:]
        var cones = false
        for root in roots { walk(root, 1, &entities, &attachments, &emitters, &particles, &names, &cones) }
        let list = names.keys.sorted()
            .map { names[$0]! > 1 ? "\($0)×\(names[$0]!)" : $0 }
            .joined(separator: ", ")
        return String(format: "%d entities enabled, %d attachments, %d emitters alive, %.0f particles, cones %@, emitters: %@",
                      entities, attachments, emitters, particles,
                      cones ? "on" : "off",
                      list.isEmpty ? "(none)" : list)
    }

    /// **v4 B2.** The projector's three cone layers, by name: `cones on|off` is read off the tree itself now.
    ///
    /// Round 1 of v4 on the headset printed `cones on` in every hand window while the cones were not being drawn at
    /// all: the first recognition happened in the hand, the unfold switched the whole projector off, and the label was
    /// a static (`ProjectorRig.conesAlive`) that only `setHandMode` ever wrote — its default was `true`. A number
    /// that can disagree with the scene is worse than no number, so the census now reports what the walk finds: a
    /// cone layer that is enabled all the way up and not faded to nothing.
    static let coneNames: Set<String> = ["projector.shimmer", "projector.shimmerWide", "projector.coneTop"]

    /// **v4 B2.** Where the enabled entities are: every named subtree under the scene roots (and one level into
    /// `anchorRoot` / `hologram` / `worlds`, which hold everything else), largest first, with its attachments.
    /// Printed as its own `[perf] scene detail:` line right after `[perf] scene:`, so the fields of that line — which
    /// the smokes and the round-3 comparisons grep — are untouched.
    static func censusDetail() -> String? {
        guard let roots = sceneRoots?() else { return nil }
        var parts: [(name: String, entities: Int, attachments: Int)] = []
        let containers: Set<String> = ["anchorRoot", "hologram", "worlds", "caseRoot"]
        func tally(_ entity: Entity) -> (Int, Int) {
            guard entity.isEnabled else { return (0, 0) }
            var e = 1, a = entity is ViewAttachmentEntity ? 1 : 0
            for child in entity.children {
                let (ce, ca) = tally(child)
                e += ce
                a += ca
            }
            return (e, a)
        }
        func visit(_ entity: Entity, prefix: String?) {
            guard entity.isEnabled else { return }
            let name = entity.name.isEmpty ? "(unnamed)" : entity.name
            if containers.contains(entity.name) {
                // The container itself counts once; its children are listed one by one.
                parts.append((name: "\(name) (itself)", entities: 1, attachments: 0))
                for child in entity.children { visit(child, prefix: name) }
                return
            }
            let (e, a) = tally(entity)
            parts.append((name: prefix.map { "\($0)/\(name)" } ?? name, entities: e, attachments: a))
        }
        for root in roots {
            for child in root.children { visit(child, prefix: nil) }
        }
        // Merge same-named siblings (twenty `tex-warm-…` quads, perf carriers) so the line stays readable.
        var merged: [String: (entities: Int, attachments: Int, count: Int)] = [:]
        for part in parts {
            var key = part.name
            if let dash = key.firstIndex(of: "-"), key.hasPrefix("worlds/tex-warm") || key.hasPrefix("worlds/ibl-warm") {
                key = String(key[..<dash]) + "-*"
            } else if key.hasPrefix("perf.") {
                key = "perf.*"
            }
            let old = merged[key] ?? (0, 0, 0)
            merged[key] = (old.entities + part.entities, old.attachments + part.attachments, old.count + 1)
        }
        let list = merged.sorted { $0.value.entities != $1.value.entities ? $0.value.entities > $1.value.entities : $0.key < $1.key }
            .filter { $0.value.entities > 0 }
            .map { key, value -> String in
                let many = value.count > 1 ? "×\(value.count)" : ""
                let att = value.attachments > 0 ? "/\(value.attachments)a" : ""
                return "\(key)\(many) \(value.entities)\(att)"
            }
        return list.isEmpty ? nil : list.joined(separator: " · ")
    }

    /// What the emitter list calls one emitter. Every emitter entity in the app is named (`rig.dust`,
    /// `well.mist`, `trail.card`, …); the climb is the honest answer for anything that is not, and prints
    /// the nearest named ancestor with a `.?` so a blank never silently becomes a name.
    private static func emitterName(of entity: Entity) -> String {
        if !entity.name.isEmpty { return entity.name }
        var parent = entity.parent
        var hops = 0
        while let p = parent, hops < 4 {
            if !p.name.isEmpty { return "\(p.name).?" }
            parent = p.parent
            hops += 1
        }
        return "(unnamed)"
    }

    private static func walk(_ entity: Entity, _ opacity: Float, _ entities: inout Int, _ attachments: inout Int,
                             _ emitters: inout Int, _ particles: inout Double, _ names: inout [String: Int],
                             _ cones: inout Bool) {
        guard entity.isEnabled else { return }
        entities += 1
        // Opacity is hierarchical in RealityKit; it is only accumulated for the cone question.
        let alpha = opacity * (entity.components[OpacityComponent.self]?.opacity ?? 1)
        if alpha > 0.01, coneNames.contains(entity.name) { cones = true }
        if entity is ViewAttachmentEntity { attachments += 1 }
        if let emitter = entity.components[ParticleEmitterComponent.self], emitter.isEmitting {
            emitters += 1
            names[emitterName(of: entity), default: 0] += 1
            let main = emitter.mainEmitter
            particles += Double(main.birthRate) * main.lifeSpan
            if let spawned = emitter.spawnedEmitter {
                particles += Double(main.birthRate) * Double(spawned.birthRate) * spawned.lifeSpan
            }
        }
        for child in entity.children {
            walk(child, alpha, &entities, &attachments, &emitters, &particles, &names, &cones)
        }
    }
}

/// Accumulates frame times while attached; prints a summary and removes itself after `duration`.
struct PerfProbeComponent: Component {
    var label: String
    var duration: Float
    var elapsed: Float = 0
    var frames = 0
    var worst: Float = 0
    var over13ms = 0
    /// **V3-5 §5.** Print a `[perf] scene:` census right after this probe's own line. On for the two probes
    /// the brief names — `hand form 5 s #n` and `world … inside` — and off for the rest, because the walk
    /// is a whole-tree recursion and a 0.6 s morph probe does not need one.
    var reportsScene = false
    /// **v4 B5 §2.** The window's per-frame CPU of our systems (always) and, with `--perf-census`, its per-frame scene.
    var window = PerfCensus.Window()
}

final class PerfProbeSystem: System {
    private static let query = EntityQuery(where: .has(PerfProbeComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let dt = Float(context.deltaTime)
        // v4 B5 §2: since this system last ran, every other one of ours ran exactly once — one frame's CPU.
        let spent = FrameCPU.take()
        let frame = PerfCensus.sample(dt: Double(dt))
        for entity in context.entities(matching: PerfProbeSystem.query, updatingSystemWhen: .rendering) {
            guard var probe = entity.components[PerfProbeComponent.self] else { continue }
            probe.elapsed += dt
            probe.frames += 1
            probe.worst = max(probe.worst, dt)
            if dt > 0.0133 { probe.over13ms += 1 }
            probe.window.add(frame, cpu: spent)
            if probe.elapsed >= probe.duration {
                let avg = probe.elapsed / Float(max(1, probe.frames))
                print(String(format: "\(PerfLog.prefix) %@: %d frames in %.2f s, avg %.1f fps, worst %.1f ms, %d frames > 13.3 ms",
                             probe.label, probe.frames, probe.elapsed, 1 / avg, probe.worst * 1000, probe.over13ms))
                for line in probe.window.lines(label: probe.label, census: PerfCensus.enabled) { print(line) }
                if probe.reportsScene, let census = PerfLog.census() {
                    print("\(PerfLog.prefix) scene: \(census)")
                    if let detail = PerfLog.censusDetail() { print("\(PerfLog.prefix) scene detail: \(detail)") }
                }
                if let note = PerfLog.windowNote?() { print("\(PerfLog.prefix)\(note)") }
                entity.components.remove(PerfProbeComponent.self)
            } else {
                entity.components.set(probe)
            }
        }
    }
}
