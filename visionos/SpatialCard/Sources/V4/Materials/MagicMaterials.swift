import Foundation
import RealityKit
import UIKit

/// **v4 A1 — the magic material library, RealityKit side.**
///
/// Each material is a `V4.MagicMaterialGraphs` graph (pure, unit-tested) loaded once as a `ShaderGraphMaterial` from
/// the USD text the graph writes, then copied per entity. Parameters are set through cached handles and pushed to the
/// entity with `commit(to:)` — a parameter change never rebuilds a material or a mesh.
///
/// Loading is the only expensive step (≈ 0.25–0.75 s per graph in the simulator, see the A1 report), so the product
/// should `MagicMaterialLoader.preload()` while the reveal's first beats play, not on the frame that needs the card.
@MainActor
enum MagicMaterialLoader {
    private static var cache: [String: ShaderGraphMaterial] = [:]
    private static var handles: [String: MaterialParameters.Handle] = [:]
    /// Milliseconds each graph took to load (first load only), for the lab's log and the report.
    private(set) static var loadTimes: [String: Double] = [:]

    /// The graph's material, loaded on first use and copied afterwards (a copy has its own parameter values).
    static func material(for graph: @autoclosure () -> V4.ShadeGraph, name: String) async throws -> ShaderGraphMaterial {
        if let cached = cache[name] { return cached }
        let graph = graph()
        let problems = graph.problems()
        guard problems.isEmpty else { throw MagicMaterialError.invalidGraph(name, problems) }
        let text = graph.usda()
        let start = CACurrentMediaTime()
        var material = try await ShaderGraphMaterial(named: graph.materialPath, from: Data(text.utf8))
        let ms = (CACurrentMediaTime() - start) * 1000
        // Transparent layers: no depth writes (the sort group orders them), front faces only.
        material.writesDepth = false
        material.faceCulling = .back
        cache[name] = material
        loadTimes[name] = ms
        print(String(format: "[materials] loaded %@ in %.1f ms (%d nodes, %d parameters, %.1f KB of USD)",
                     name, ms, graph.nodes.count, graph.parameters.count, Double(text.utf8.count) / 1024))
        return material
    }

    /// How `preload` orders the five loads (v4 B1 follow-up A/B, `--v4-preload serial|parallel|warm`).
    enum PreloadOrder: String {
        /// One after another (A1's original order).
        case serial
        /// All five at once (a `TaskGroup`).
        case parallel
        /// The smallest graph alone first (it pays the process's one-time ShaderGraph set-up), then the other four at once.
        case warm
    }

    /// Loads the hero card's five graphs so later `load()` calls are instant.
    static func preload(_ order: PreloadOrder = .serial) async {
        switch order {
        case .serial:
            await preloadOne(CrystalSlabMaterial.self)
            await preloadOne(HoloFoilMaterial.self)
            await preloadOne(GoldEdgeMaterial.self)
            await preloadOne(MagicDissolveMaterial.self)
            await preloadOne(SweepGlintMaterial.self)
        case .parallel:
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await preloadOne(CrystalSlabMaterial.self) }
                group.addTask { @MainActor in await preloadOne(HoloFoilMaterial.self) }
                group.addTask { @MainActor in await preloadOne(GoldEdgeMaterial.self) }
                group.addTask { @MainActor in await preloadOne(MagicDissolveMaterial.self) }
                group.addTask { @MainActor in await preloadOne(SweepGlintMaterial.self) }
            }
        case .warm:
            await preloadOne(SweepGlintMaterial.self)
            await withTaskGroup(of: Void.self) { group in
                group.addTask { @MainActor in await preloadOne(CrystalSlabMaterial.self) }
                group.addTask { @MainActor in await preloadOne(HoloFoilMaterial.self) }
                group.addTask { @MainActor in await preloadOne(GoldEdgeMaterial.self) }
                group.addTask { @MainActor in await preloadOne(MagicDissolveMaterial.self) }
            }
        }
    }

    private static func preloadOne<M: MagicMaterial>(_ type: M.Type) async {
        do {
            _ = try await type.load()
        } catch {
            print("[materials] \(type.graphName) failed to load: \(error)")
        }
    }

    static func handle(_ name: String) -> MaterialParameters.Handle {
        if let handle = handles[name] { return handle }
        let handle = ShaderGraphMaterial.parameterHandle(name: name)
        handles[name] = handle
        return handle
    }
}

enum MagicMaterialError: Error, CustomStringConvertible {
    case invalidGraph(String, [String])

    var description: String {
        switch self {
        case .invalidGraph(let name, let problems): return "\(name): \(problems.joined(separator: "; "))"
        }
    }
}

/// What every wrapper shares: the material value, a handle-based setter, and the push to an entity.
@MainActor
protocol MagicMaterial {
    static var graphName: String { get }
    static func graph() -> V4.ShadeGraph
    var material: ShaderGraphMaterial { get set }
    init(material: ShaderGraphMaterial)
}

extension MagicMaterial {
    static func load() async throws -> Self {
        Self(material: try await MagicMaterialLoader.material(for: graph(), name: graphName))
    }

    /// **v4 B4 §3.5.** The cache name of a frost variant: the launch's frost keeps the plain name (what the preload
    /// loaded), the other one is cached beside it.
    static func frostName(blur: Bool) -> String {
        blur == V4.MagicMaterialGraphs.backgroundBlur ? graphName : graphName + (blur ? ".blur" : ".plain")
    }

    /// Sets one parameter by name (through a cached handle). A wrong name or type is a programming error: it is
    /// logged once per name rather than thrown at the per-frame caller.
    mutating func set(_ name: String, _ value: MaterialParameters.Value) {
        do {
            try material.setParameter(handle: MagicMaterialLoader.handle(name), value: value)
        } catch {
            MagicMaterialDiagnostics.reportOnce("\(Self.graphName).\(name): \(error)")
        }
    }

    func value(_ name: String) -> MaterialParameters.Value? {
        material.getParameter(handle: MagicMaterialLoader.handle(name))
    }

    /// Pushes the current parameter values to `entity` (its first material slot).
    func commit(to entity: ModelEntity) {
        entity.model?.materials = [material]
    }
}

@MainActor
enum MagicMaterialDiagnostics {
    private static var reported = Set<String>()

    static func reportOnce(_ message: String) {
        guard reported.insert(message).inserted else { return }
        print("[materials] parameter error \(message)")
    }
}

private typealias P = V4.MagicMaterialGraphs.Param

// MARK: - The four wrappers

/// The name card's frosted slab (art bible §2): 6–12 % body, warm Fresnel edge light 0.45 → 0.9, weak reflection.
struct CrystalSlabMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.crystalSlabName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.crystalSlab() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    /// **v4 B4 §3.5.** The frost with or without the background blur (`cmd perf material=plain|blur`).
    static func load(frostBlur blur: Bool) async throws -> Self {
        Self(material: try await MagicMaterialLoader.material(for: V4.MagicMaterialGraphs.crystalSlab(blur: blur),
                                                              name: frostName(blur: blur)))
    }

    mutating func setTint(_ color: UIColor) { set(P.tint, .color(color.cgColor)) }
    mutating func setRimColor(_ color: UIColor) { set(P.rimColor, .color(color.cgColor)) }
    /// Edge light seen square-on (0.45 in the bible).
    mutating func setRimFacing(_ level: Float) { set(P.rimFacing, .float(max(0, level))) }
    /// Edge light seen edge-on (0.9 in the bible).
    mutating func setRimGrazing(_ level: Float) { set(P.rimGrazing, .float(max(0, level))) }
    /// The frosted white over the blur, square-on (before the inner glow): `MagicMaterialRules.slabOpacityRange` (0.35–0.5
    /// since the 2026-09-26 review; the bible's clear plate was 0.06–0.12). 0 is allowed for fades.
    mutating func setOpacity(_ opacity: Float) { set(P.opacity, .float(min(1, max(0, opacity)))) }
    /// How much of the scene through the slab is replaced by its blurred copy (0.75 default).
    mutating func setFrost(_ frost: Float) { set(P.frost, .float(min(1, max(0, frost)))) }
    /// Strength of the environment reflection (0.35 default: "very weak").
    mutating func setReflection(_ amount: Float) { set(P.reflection, .float(max(0, amount))) }
    /// The outline the edge light follows, in the mesh's own metres.
    mutating func setOutline(halfSize: SIMD2<Float>, cornerRadius: Float) {
        set(P.halfSize, .simd2Float(halfSize))
        set(P.cornerRadius, .float(cornerRadius))
    }
    /// Plate thickness (the side band's arris lines sit at its two faces). 12 mm for the name card.
    mutating func setThickness(_ thickness: Float) { set(P.thickness, .float(max(0.0005, thickness))) }
    /// The glass glint of the diagonal sweep, 0…1 (1 = resting past the far corner, invisible).
    mutating func setSweep(_ sweep: Float) { set(P.sweep, .float(sweep)) }
}

/// The holographic foil over the card face: pure additive light, capped by the view angle (≤ 0.12 square-on,
/// ≤ 0.45 edge-on, inside the graph), flowing with the head, with a diagonal sweep.
struct HoloFoilMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.holoFoilName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.holoFoil() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    /// 0…1, scales the foil *under* its cap (1 = at most the cap).
    mutating func setStrength(_ strength: Float) { set(P.strength, .float(min(1, max(0, strength)))) }
    /// 0…1: where the diagonal sweep band is (0 and 1 are just off the card).
    mutating func setSweep(_ sweep: Float) { set(P.sweep, .float(sweep)) }
    /// How many colour cycles run across the diagonal (1.15 default).
    mutating func setBands(_ bands: Float) { set(P.bands, .float(bands)) }
    /// How far the colours move per unit of lateral head offset (1.6 default).
    mutating func setFlow(_ flow: Float) { set(P.flow, .float(flow)) }
    mutating func setHalfSize(_ halfSize: SIMD2<Float>) { set(P.halfSize, .simd2Float(halfSize)) }
}

/// The inset gold line (old gold, lifting to gold where the sweep crosses it).
struct GoldEdgeMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.goldEdgeName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.goldEdge() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    mutating func setSweep(_ sweep: Float) { set(P.sweep, .float(sweep)) }
    /// Overall brightness (1 = the bible's old gold at rest); 0 hides the line.
    mutating func setIntensity(_ intensity: Float) { set(P.intensity, .float(max(0, intensity))) }
    mutating func setColors(base: UIColor, hot: UIColor) {
        set(P.baseColor, .color(base.cgColor))
        set(P.hotColor, .color(hot.cgColor))
    }
    mutating func setOutline(halfSize: SIMD2<Float>, cornerRadius: Float) {
        set(P.halfSize, .simd2Float(halfSize))
        set(P.cornerRadius, .float(cornerRadius))
    }
    /// Line geometry in metres (bible: 1.5 mm inset).
    mutating func setLine(inset: Float, width: Float) {
        set(P.inset, .float(inset))
        set(P.lineWidth, .float(max(0.0001, width)))
    }
    /// The warm light spilling up to 6 mm past the outline (0.35 default; 0 = the line alone).
    mutating func setOuterGlow(_ glow: Float) { set(P.outerGlow, .float(max(0, glow))) }
}

/// Reveal / dissolve: 0 = transparent with a glowing outline, 1 = exactly `CrystalSlabMaterial` (same parameters).
struct MagicDissolveMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.magicDissolveName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.magicDissolve() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    /// **v4 B4 §3.5.** The dissolve resolving into the frost with or without the background blur.
    static func load(frostBlur blur: Bool) async throws -> Self {
        Self(material: try await MagicMaterialLoader.material(for: V4.MagicMaterialGraphs.magicDissolve(blur: blur),
                                                              name: frostName(blur: blur)))
    }

    mutating func setProgress(_ progress: Float) { set(P.progress, .float(min(1, max(0, progress)))) }
    /// Width of the burning band, as a fraction of the way from the outline to the centre (0.09 default).
    mutating func setEdgeWidth(_ width: Float) { set(P.edgeWidth, .float(max(0.01, width))) }
    mutating func setEdgeColor(_ color: UIColor) { set(P.edgeColor, .color(color.cgColor)) }
    /// Noise frequency, per metre (16 default: blobs of a few centimetres on the card).
    mutating func setNoiseScale(_ scale: Float) { set(P.noiseScale, .float(max(0, scale))) }
    mutating func setGlow(_ glow: Float) { set(P.glow, .float(max(0, glow))) }
    // The slab it resolves into.
    mutating func setTint(_ color: UIColor) { set(P.tint, .color(color.cgColor)) }
    mutating func setRimColor(_ color: UIColor) { set(P.rimColor, .color(color.cgColor)) }
    mutating func setRim(facing: Float, grazing: Float) {
        set(P.rimFacing, .float(facing))
        set(P.rimGrazing, .float(grazing))
    }
    mutating func setOpacity(_ opacity: Float) { set(P.opacity, .float(min(1, max(0, opacity)))) }
    mutating func setOutline(halfSize: SIMD2<Float>, cornerRadius: Float) {
        set(P.halfSize, .simd2Float(halfSize))
        set(P.cornerRadius, .float(cornerRadius))
    }
    mutating func setThickness(_ thickness: Float) { set(P.thickness, .float(max(0.0005, thickness))) }
    mutating func setFrost(_ frost: Float) { set(P.frost, .float(min(1, max(0, frost)))) }
}

/// The sweep as a light of its own, for a face covered by an opaque panel (A4's hero card).
struct SweepGlintMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.sweepGlintName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.sweepGlint() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    mutating func setSweep(_ sweep: Float) { set(P.sweep, .float(sweep)) }
    mutating func setIntensity(_ intensity: Float) { set(P.intensity, .float(max(0, intensity))) }
    mutating func setHalfSize(_ halfSize: SIMD2<Float>) { set(P.halfSize, .simd2Float(halfSize)) }
}

/// The soft ink plate that keeps gold type legible on the pale crystal.
struct InkVeilMaterial: MagicMaterial {
    static let graphName = V4.MagicMaterialGraphs.inkVeilName
    static func graph() -> V4.ShadeGraph { V4.MagicMaterialGraphs.inkVeil() }
    var material: ShaderGraphMaterial
    init(material: ShaderGraphMaterial) { self.material = material }

    mutating func setOpacity(_ opacity: Float) { set(P.opacity, .float(min(1, max(0, opacity)))) }
    /// The plate's rectangle (in the mesh's metres) and how far its edge fades.
    mutating func setShape(halfSize: SIMD2<Float>, cornerRadius: Float, softness: Float) {
        set(P.halfSize, .simd2Float(halfSize))
        set(P.cornerRadius, .float(cornerRadius))
        set(P.softness, .float(max(0.0005, softness)))
    }
}
