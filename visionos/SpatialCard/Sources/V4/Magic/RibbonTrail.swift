import Foundation
import Metal
import RealityKit
import UIKit

/// **The fairy ribbon** (v4 A2; art bible §4 丝带光轨): one continuous, viewer-facing strip of light with a
/// bright head, a 6–12 mm body that tapers to nothing and fades over its tail, warm gold at the centre and a
/// holo colour shift at the edges. The recognition draws the card with it; the gallery fly-out, the
/// follower meteor and summon / put-away are meant to reuse it unchanged.
///
/// Three ways to drive it:
/// - `play(path:duration:easing:)` / `play(path:timing:)` — the head flies a `V4.RibbonSpline`;
/// - `follow(_:)` — the head chases a moving target (a closure, re-read every frame);
/// - `stroke(path:timing:range:)` — a line that stays where the head drew it (the card outline).
///
/// **How it is drawn.** A `LowLevelMesh` whose vertex buffer is rewritten every frame (≤ 240 samples × 2
/// vertices; the index buffer is written once): the centre line comes from `V4.RibbonBody` / `V4.TrailHistory`,
/// the strip from `V4.RibbonStrip` (camera-facing, no flips). Colour cannot ride on the vertices —
/// `UnlitMaterial` ignores the `.color` attribute (A2 SDK probe 1) — so each vertex carries its brightness in
/// U and its side in V, and `MagicTextures.ribbonRamp` turns that into white-gold → gold → holo tint.
/// `uv1` = (distance along the path in metres, age in seconds), unused by the Unlit material, is there for
/// A1's ShaderGraph replacement (flowing foil glued to the world, age-driven dissolve): swap it in with
/// `setMaterial(_:)`; nothing else changes.
///
/// **The camera.** The strip faces `cameraPosition()` (world space; the lab passes the simulator's eye,
/// the product passes the head pose). The head glow uses `BillboardComponent`.
@MainActor
final class RibbonTrail {
    struct Style {
        var profile: V4.RibbonProfile
        /// Centre-line sample spacing (m): at the head for a fairy (2.5× that at the end of its tail), on the
        /// straights for a stroke. Bends are always sampled as finely as the path asks (≤ 0.1 mm sagitta —
        /// `V4.RibbonSpline.maxStep`), so this only decides how much work the easy stretches cost. `maxSamples`
        /// bounds CPU and buffer size.
        var spacing: Float = 0.005
        var maxSamples: Int = 240
        /// Size of the head's glow sprite (m); 0 = no head glow.
        var headGlowSize: Float = 0.030

        static let fairy = Style(profile: .fairy)
        static let stroke = Style(profile: .stroke, spacing: 0.015, maxSamples: 240, headGlowSize: 0)
    }

    struct Vertex {
        var position: SIMD3<Float> = .zero
        var normal: SIMD3<Float> = .zero
        var uv0: SIMD2<Float> = .zero
        var uv1: SIMD2<Float> = .zero
    }

    enum Source {
        case none
        case path(V4.RibbonSpline, V4.RibbonTiming)
        case stroke(V4.RibbonSpline, V4.RibbonTiming, ClosedRange<Float>)
        case follow(() -> SIMD3<Float>?)
    }

    let root = Entity()
    let style: Style
    /// World-space eye position. Nil keeps the last one (the strip must never snap to a default mid-flight).
    var cameraPosition: () -> SIMD3<Float>? = { nil }
    /// The ribbon's own clock, seconds. `update(dt:)` advances it; a choreography can also set it directly
    /// (to share one clock with the rest of a rig, or to hold a frame for a screenshot).
    var clock: Float = 0
    /// Whole-ribbon multipliers: a dissolve, a flare.
    var intensityScale: Float = 1
    var widthScale: Float = 1
    var headGlowScale: Float = 1

    private(set) var source: Source = .none
    private let model = ModelEntity()
    private let head: ModelEntity?
    private let mesh: LowLevelMesh
    private var samples: [V4.RibbonSample] = []
    private var frames: [V4.RibbonStrip.Frame] = []
    private var history: V4.TrailHistory
    private var headSide: SIMD3<Float>?
    private var lastCamera: SIMD3<Float>?

    /// Samples of the centre line as of the last rebuild, head first (for dust that breaks off the body).
    var body: [V4.RibbonSample] { samples }
    /// The head, in `root`'s space, as of the last rebuild.
    var headPosition: SIMD3<Float>? { samples.first?.position }
    var isVisible: Bool { frames.count >= 2 }

    private init(style: Style, mesh: LowLevelMesh, material: any Material, headMaterial: (any Material)?) {
        self.style = style
        self.mesh = mesh
        history = V4.TrailHistory(maxAge: style.profile.kind == .fairy ? style.profile.tail : 0.6)
        root.name = "v4.ribbon"
        model.name = "v4.ribbon.strip"
        if let resource = try? MeshResource(from: mesh) {
            model.components.set(ModelComponent(mesh: resource, materials: [material]))
        }
        // v4 B1: empty until the first rebuild with two samples (`writeMesh` enables it) — the rule `writeMesh` keeps
        // for a cleared strip. Enabled with its empty mesh, its zero bounds sit at the LCD centre, and the product's
        // H0 audit (which runs whenever the space is open) reports it for as long as no recognition has played.
        model.isEnabled = false
        root.addChild(model)
        if let headMaterial, style.headGlowSize > 0 {
            let glow = ModelEntity(mesh: .generatePlane(width: style.headGlowSize, height: style.headGlowSize),
                                   materials: [headMaterial])
            glow.name = "v4.ribbon.head"
            glow.components.set(BillboardComponent())
            glow.isEnabled = false
            root.addChild(glow)
            head = glow
        } else {
            head = nil
        }
    }

    /// Builds a ribbon with the default look (the additive ramp material). Async because the additive
    /// material program is (it is made once per process and cached).
    static func make(style: Style = .fairy) async throws -> RibbonTrail {
        let mesh = try makeMesh(maxSamples: style.maxSamples)
        let textures = MagicTextures.shared
        let material = await MagicMaterials.additive(textures.ribbonRamp)
        let headMaterial = style.headGlowSize > 0 ? await MagicMaterials.additive(textures.headGlow) : nil
        return RibbonTrail(style: style, mesh: mesh, material: material, headMaterial: headMaterial)
    }

    /// A1 hook: draw the strip with another material (e.g. a ShaderGraph that reads `uv1`).
    func setMaterial(_ material: any Material) {
        model.model?.materials = [material]
    }

    // MARK: - Driving

    /// Fly `path` in `duration` seconds with `easing`, starting `delay` seconds from now.
    func play(path: V4.RibbonSpline, duration: Float, easing: Easing = .easeInOutCubic, delay: Float = 0) {
        play(path: path, timing: .eased(length: path.length, duration: duration, delay: delay, easing: easing))
    }

    /// Fly `path` on an explicit timing (whose clock is this ribbon's `clock`, reset to 0 here).
    func play(path: V4.RibbonSpline, timing: V4.RibbonTiming, resetClock: Bool = true) {
        source = .path(path, timing)
        if resetClock { clock = 0 }
        headSide = nil
    }

    /// Draw a lasting line along `range` of `path` (distances), revealed as `timing`'s head passes.
    func stroke(path: V4.RibbonSpline, timing: V4.RibbonTiming, range: ClosedRange<Float>, resetClock: Bool = true) {
        source = .stroke(path, timing, range)
        if resetClock { clock = 0 }
        headSide = nil
    }

    /// Chase `target` (in `root`'s parent space… i.e. the same space as `root`'s children), re-read every frame.
    func follow(_ target: @escaping () -> SIMD3<Float>?) {
        source = .follow(target)
        history.reset()
        clock = 0
        headSide = nil
    }

    /// Stop recording a followed target: the ribbon then ages out behind its last head position.
    func release() {
        if case .follow = source { source = .follow({ nil }) }
    }

    func clear() {
        source = .none
        samples.removeAll(keepingCapacity: true)
        frames.removeAll(keepingCapacity: true)
        history.reset()
        headSide = nil
        writeMesh()
    }

    /// Advance the clock by `dt` and rebuild.
    func update(dt: Float) {
        clock += dt
        rebuild()
    }

    /// Rebuild the strip for the current `clock` (no time passes).
    func rebuild() {
        let profile = style.profile
        switch source {
        case .none:
            samples.removeAll(keepingCapacity: true)
        case .path(let spline, let timing):
            V4.RibbonBody.trail(spline: spline, timing: timing, time: clock, tail: profile.tail,
                                spacing: style.spacing, maxSamples: style.maxSamples, into: &samples)
        case .stroke(let spline, let timing, let range):
            V4.RibbonBody.stroke(spline: spline, timing: timing, time: clock, start: range.lowerBound,
                                 end: range.upperBound, spacing: style.spacing, maxSamples: style.maxSamples,
                                 into: &samples)
        case .follow(let target):
            if let position = target() { history.record(position, at: clock) }
            history.samples(at: clock, tail: profile.kind == .fairy ? profile.tail : 0.6, spacing: style.spacing,
                            maxSamples: style.maxSamples, into: &samples)
        }
        if let world = cameraPosition() { lastCamera = world }
        let camera = lastCamera.map { root.convert(position: $0, from: nil) } ?? [0, 0.3, 0.7]
        headSide = V4.RibbonStrip.build(samples: samples, profile: profile, camera: camera,
                                        previousHeadSide: headSide, time: clock,
                                        intensityScale: intensityScale, widthScale: widthScale, into: &frames)
        writeMesh()
        updateHead()
    }

    // MARK: - Mesh

    private static func makeMesh(maxSamples: Int) throws -> LowLevelMesh {
        var descriptor = LowLevelMesh.Descriptor()
        descriptor.vertexCapacity = maxSamples * 2
        descriptor.indexCapacity = max(0, maxSamples - 1) * 6
        descriptor.vertexAttributes = [
            .init(semantic: .position, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.position)!),
            .init(semantic: .normal, format: .float3, offset: MemoryLayout<Vertex>.offset(of: \.normal)!),
            .init(semantic: .uv0, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv0)!),
            .init(semantic: .uv1, format: .float2, offset: MemoryLayout<Vertex>.offset(of: \.uv1)!),
        ]
        descriptor.vertexLayouts = [.init(bufferIndex: 0, bufferStride: MemoryLayout<Vertex>.stride)]
        descriptor.indexType = .uint32
        let mesh = try LowLevelMesh(descriptor: descriptor)
        // The index buffer never changes: quad i joins samples i and i + 1. Only the part's count does.
        mesh.withUnsafeMutableIndices { raw in
            let indices = raw.bindMemory(to: UInt32.self)
            for i in 0..<max(0, maxSamples - 1) {
                let l0 = UInt32(2 * i), r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
                let base = 6 * i
                indices[base] = l0; indices[base + 1] = r0; indices[base + 2] = l1
                indices[base + 3] = r0; indices[base + 4] = r1; indices[base + 5] = l1
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexOffset: 0, indexCount: 0, topology: .triangle,
                                                 materialIndex: 0, bounds: BoundingBox(min: .zero, max: .zero))])
        return mesh
    }

    private func writeMesh() {
        let count = min(frames.count, style.maxSamples)
        guard count >= 2 else {
            mesh.parts.replaceAll([LowLevelMesh.Part(indexOffset: 0, indexCount: 0, topology: .triangle,
                                                     materialIndex: 0, bounds: BoundingBox(min: .zero, max: .zero))])
            model.isEnabled = false
            return
        }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        frames.withUnsafeBufferPointer { frames in
            mesh.replaceUnsafeMutableBytes(bufferIndex: 0) { raw in
                let vertices = raw.bindMemory(to: Vertex.self)
                for i in 0..<count {
                    let frame = frames[i]
                    let left = frame.left, right = frame.right
                    let extra = SIMD2<Float>(frame.distance, frame.age)
                    vertices[2 * i] = Vertex(position: left, normal: frame.normal, uv0: [frame.intensity, 0], uv1: extra)
                    vertices[2 * i + 1] = Vertex(position: right, normal: frame.normal, uv0: [frame.intensity, 1], uv1: extra)
                    lower = simd_min(lower, simd_min(left, right))
                    upper = simd_max(upper, simd_max(left, right))
                }
            }
        }
        mesh.parts.replaceAll([LowLevelMesh.Part(indexOffset: 0, indexCount: (count - 1) * 6, topology: .triangle,
                                                 materialIndex: 0, bounds: BoundingBox(min: lower, max: upper))])
        model.isEnabled = true
    }

    private func updateHead() {
        guard let head else { return }
        guard let first = frames.first, style.profile.kind == .fairy else {
            head.isEnabled = false
            return
        }
        // The head glow follows the ribbon's own head brightness, so a parked head ages out with its tail.
        let level = first.intensity
        guard level > 0.02 else {
            head.isEnabled = false
            return
        }
        // A barely-there flutter (two incommensurate rates) — a light with a life, not a strobe.
        let flutter = 1 + 0.06 * sin(clock * 41) + 0.04 * sin(clock * 67 + 1.3)
        let s = headGlowScale * flutter * (0.35 + 0.65 * level)
        head.position = first.center
        head.scale = SIMD3<Float>(repeating: s)
        head.isEnabled = true
    }
}
