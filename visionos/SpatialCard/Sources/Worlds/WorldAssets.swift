import Foundation
import ImageIO
import RealityKit
import UIKit

// MARK: - Descriptor data (all optional so the JSON stays small)

/// One placed USDZ, in the frozen world frame: `at` = [forward, right, up] metres from the world origin
/// (head projected to the floor), `yaw` degrees relative to the view direction.
struct WorldPlacement: Codable, Equatable {
    var asset: String
    var at: [Float]
    var yaw: Float = 0
    var scale: Float = 1
    /// Lowest quality tier that still shows this piece (0 low, 1 medium, 2 high).
    var minTier: Int = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decode(String.self, forKey: .asset)
        at = try c.decode([Float].self, forKey: .at)
        yaw = try c.decodeIfPresent(Float.self, forKey: .yaw) ?? 0
        scale = try c.decodeIfPresent(Float.self, forKey: .scale) ?? 1
        minTier = try c.decodeIfPresent(Int.self, forKey: .minTier) ?? 0
    }
}

/// Repeated USDZ scattered in an annulus around the origin (rocks, kelp, lamps…), deterministic per seed.
struct WorldScatter: Codable, Equatable {
    var asset: String
    var count: Int
    var radius: [Float]            // [min, max]
    var angle: [Float] = [-180, 180] // degrees around the view direction
    var scale: [Float] = [1, 1]
    var y: Float = 0
    var randomYaw: Bool = true
    var seed: Int = 1
    /// Lowest tier for the whole scatter; on top of that the last third of the instances is high-only.
    var minTier: Int = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        asset = try c.decode(String.self, forKey: .asset)
        count = try c.decode(Int.self, forKey: .count)
        radius = try c.decode([Float].self, forKey: .radius)
        angle = try c.decodeIfPresent([Float].self, forKey: .angle) ?? [-180, 180]
        scale = try c.decodeIfPresent([Float].self, forKey: .scale) ?? [1, 1]
        y = try c.decodeIfPresent(Float.self, forKey: .y) ?? 0
        randomYaw = try c.decodeIfPresent(Bool.self, forKey: .randomYaw) ?? true
        seed = try c.decodeIfPresent(Int.self, forKey: .seed) ?? 1
        minTier = try c.decodeIfPresent(Int.self, forKey: .minTier) ?? 0
    }
}

/// Ring of translucent gradient bands around the wearer: distance haze without a fog shader.
struct WorldFogLayer: Codable, Equatable {
    var distance: Float
    var height: Float
    var color: String
    var opacity: Float
    var minTier: Int = 0

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        distance = try c.decode(Float.self, forKey: .distance)
        height = try c.decode(Float.self, forKey: .height)
        color = try c.decode(String.self, forKey: .color)
        opacity = try c.decode(Float.self, forKey: .opacity)
        minTier = try c.decodeIfPresent(Int.self, forKey: .minTier) ?? 0
    }
}

struct WorldEnvironment: Codable, Equatable {
    /// `.hdr` stem inside `worlds/<id>/` used as the image-based light.
    var hdri: String?
    var iblIntensity: Float = 0
    /// Image stem (jpg/png/hdr) for the sky dome (unlit); falls back to the shell colour.
    var sky: String?
    var skyTint: String?
    var skyRadius: Float = 40
    /// Put the sky texture on the engine's shell sphere (default). Worlds that render their own dome (an
    /// equirect sphere they can fade or yaw) set this false so only one sky is drawn.
    var skyOnShell: Bool = true

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hdri = try c.decodeIfPresent(String.self, forKey: .hdri)
        iblIntensity = try c.decodeIfPresent(Float.self, forKey: .iblIntensity) ?? 0
        sky = try c.decodeIfPresent(String.self, forKey: .sky)
        skyTint = try c.decodeIfPresent(String.self, forKey: .skyTint)
        skyRadius = try c.decodeIfPresent(Float.self, forKey: .skyRadius) ?? 40
        skyOnShell = try c.decodeIfPresent(Bool.self, forKey: .skyOnShell) ?? true
    }
}

// MARK: - Quality tiers

enum WorldQuality: Int, Comparable, CustomStringConvertible {
    case low = 0, medium = 1, high = 2
    static func < (a: WorldQuality, b: WorldQuality) -> Bool { a.rawValue < b.rawValue }
    var description: String { ["low", "medium", "high"][rawValue] }
    /// Multiplier for particle birth rates and instance counts.
    var density: Float { [0.35, 0.65, 1][rawValue] }
}

// MARK: - Library

/// Loads and caches a world's USDZ entities, HDRI environment and sky texture so entering a world is a
/// clone, not a load. Everything lives under `worlds/<id>/` in the bundle (folder reference).
@MainActor
final class WorldAssetLibrary {
    private var entities: [String: Entity] = [:]                 // "<world>/<asset>"
    private var environments: [String: EnvironmentResource] = [:]
    private var skies: [String: TextureResource] = [:]
    private var textures: [String: TextureResource] = [:]           // "<world>/<stem>"
    private var loading: Set<String> = []

    func url(world: String, file: String, ext: String) -> URL? {
        Bundle.main.url(forResource: file, withExtension: ext, subdirectory: "worlds/\(world)")
    }

    /// Kick off loading everything the descriptor references (idempotent).
    func preload(_ d: WorldDescriptor) {
        let names = Set((d.placements ?? []).map(\.asset) + (d.scatters ?? []).map(\.asset) + (d.extraAssets ?? []))
        for name in names where entities["\(d.id)/\(name)"] == nil && !loading.contains("\(d.id)/\(name)") {
            guard let url = url(world: d.id, file: name, ext: "usdz") else {
                print("[assets] \(d.id)/\(name).usdz missing from the bundle"); continue
            }
            loading.insert("\(d.id)/\(name)")
            Task { @MainActor [weak self] in
                let started = Date()
                if let e = try? await Entity(contentsOf: url) {
                    self?.entities["\(d.id)/\(name)"] = e
                    print(String(format: "[assets] %@/%@ loaded in %.0f ms", d.id, name, Date().timeIntervalSince(started) * 1000))
                } else {
                    print("[assets] \(d.id)/\(name) failed to load")
                }
                self?.loading.remove("\(d.id)/\(name)")
            }
        }
        for stem in d.textures ?? [] where textures["\(d.id)/\(stem)"] == nil && !loading.contains("\(d.id)/tex/\(stem)") {
            loading.insert("\(d.id)/tex/\(stem)")
            Task { @MainActor [weak self] in
                let semantic = WorldAssetLibrary.semantic(forTextureStem: stem)
                for ext in ["jpg", "png"] {
                    if let url = self?.url(world: d.id, file: stem, ext: ext),
                       let tex = try? await TextureResource(contentsOf: url, options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll)) {
                        self?.textures["\(d.id)/\(stem)"] = tex
                        break
                    }
                }
                if self?.textures["\(d.id)/\(stem)"] == nil { print("[assets] \(d.id) texture \(stem) failed") }
                self?.loading.remove("\(d.id)/tex/\(stem)")
            }
        }
        if let hdri = d.environment?.hdri, environments[d.id] == nil, !loading.contains("\(d.id)/hdri") {
            loading.insert("\(d.id)/hdri")
            Task { @MainActor [weak self] in
                if let url = self?.url(world: d.id, file: hdri, ext: "hdr") ?? self?.url(world: d.id, file: hdri, ext: "exr"),
                   let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                   let env = try? await EnvironmentResource(equirectangular: image, withName: "\(d.id).ibl") {
                    self?.environments[d.id] = env
                    print("[assets] \(d.id) IBL ready (\(image.width)×\(image.height))")
                } else {
                    print("[assets] \(d.id) HDRI \(hdri) failed")
                }
                self?.loading.remove("\(d.id)/hdri")
            }
        }
        if let sky = d.environment?.sky, skies[d.id] == nil, !loading.contains("\(d.id)/sky") {
            loading.insert("\(d.id)/sky")
            Task { @MainActor [weak self] in
                for ext in ["jpg", "png", "hdr"] {
                    if let url = self?.url(world: d.id, file: sky, ext: ext),
                       let tex = try? await TextureResource(contentsOf: url, options: .init(semantic: .color)) {
                        self?.skies[d.id] = tex
                        print("[assets] \(d.id) sky ready")
                        break
                    }
                }
                self?.loading.remove("\(d.id)/sky")
            }
        }
    }

    func environment(for world: String) -> EnvironmentResource? { environments[world] }
    /// A fresh clone of a cached USDZ (nil until loaded).
    func entity(world: String, name: String) -> Entity? { entities["\(world)/\(name)"]?.clone(recursive: true) }
    func texture(world: String, name: String) -> TextureResource? { textures["\(world)/\(name)"] }

    /// Colour space / channel meaning from the Poly Haven-style stem: `*_nor*` (`nor_gl`, `_nor`) is a tangent-space
    /// normal map, `rough` / `arm` / `ao` / `metal` / `disp` are linear data channels, everything else is sRGB colour.
    /// Reading a normal map as sRGB bends every normal (the wet roof loses its sheen), so the suffix decides.
    nonisolated static func semantic(forTextureStem stem: String) -> TextureResource.Semantic {
        let s = stem.lowercased()
        if s.contains("_nor") || s.hasSuffix("nor") || s.contains("normal") { return .normal }
        for data in ["rough", "_arm", "_ao", "metal", "disp", "height"] where s.contains(data) { return .raw }
        return .color
    }

    private var warmed: Set<String> = []
    private var warmedCount = 0

    /// Big textures (4K sky, 2K PBR sets) upload on first render; a 1 mm quad under the floor pays that cost at the desk.
    /// Cheap to call every tick: nothing is rebuilt unless a texture arrived since the last call.
    func warmTextures(in root: Entity) {
        guard skies.count + textures.count > warmedCount else { return }
        var all: [(String, TextureResource)] = skies.map { ("sky/\($0.key)", $0.value) }
        all += textures.map { ("tex/\($0.key)", $0.value) }
        for (key, tex) in all where !warmed.contains(key) {
            warmed.insert(key)
            let quad = ModelEntity(mesh: .generatePlane(width: 0.001, height: 0.001), materials: [WorldKit.unlit(.white, texture: tex)])
            quad.name = "tex-warm-\(key)"
            quad.position = [0, -3, 0]
            root.addChild(quad)
        }
        warmedCount = skies.count + textures.count
    }

    private var warmedMaterials: Set<String> = []

    /// **v4 B5 §5.** A world's own lit materials that first meet their textures in a build (the wet asphalt), on a 1 mm
    /// quad under the floor: in the simulator, the frame after the slab first took its textured material stalled ~66 ms
    /// (the step itself 2.6 ms) — RealityKit's work, not ours. The engine calls this before there is a card (the
    /// headset's launch) or on a quiet desk, so the cost is not inside a prebuild's frames. `make` returns nil until the
    /// material can be made.
    func warmMaterial(_ key: String, in root: Entity, make: () -> RealityKit.Material?) {
        guard !warmedMaterials.contains(key), let material = make() else { return }
        warmedMaterials.insert(key)
        let quad = ModelEntity(mesh: .generatePlane(width: 0.001, height: 0.001), materials: [material])
        quad.name = "mat-warm-\(key)"
        quad.position = [0, -3, 0]
        root.addChild(quad)
        print("[worlds] material \(key) warmed under the floor")
    }

    private var warmedIBL: Set<String> = []

    /// Environment maps are prefiltered on first use; a 1 mm sphere far under the floor pays that cost at the desk.
    func warmIBL(_ env: EnvironmentResource, in root: Entity, key: String) {
        guard !warmedIBL.contains(key) else { return }
        warmedIBL.insert(key)
        let warm = ModelEntity(mesh: .generateSphere(radius: 0.001), materials: [PhysicallyBasedMaterial()])
        warm.name = "ibl-warm-\(key)"
        warm.position = [0, -3, 0]
        warm.components.set(ImageBasedLightComponent(source: .single(env)))
        warm.components.set(ImageBasedLightReceiverComponent(imageBasedLight: warm))
        root.addChild(warm)
    }
    func sky(for world: String) -> TextureResource? { skies[world] }

    private var prebuilt: [String: Entity] = [:]

    func hasPrebuilt(_ d: WorldDescriptor) -> Bool { prebuilt[d.id] != nil }

    /// True when everything the descriptor references is cached: USDZ pieces, loose textures, the sky and the HDRI.
    func isReady(_ d: WorldDescriptor) -> Bool {
        let names = Set((d.placements ?? []).map(\.asset) + (d.scatters ?? []).map(\.asset) + (d.extraAssets ?? []))
        guard names.allSatisfy({ entities["\(d.id)/\($0)"] != nil }) else { return false }
        guard (d.textures ?? []).allSatisfy({ textures["\(d.id)/\($0)"] != nil }) else { return false }
        if d.environment?.sky != nil, skies[d.id] == nil { return false }
        if d.environment?.hdri != nil, environments[d.id] == nil { return false }
        return true
    }

    /// Build the layer ahead of time (at the desk) so entering is a re-parent, not a clone storm.
    func prebuild(_ d: WorldDescriptor) {
        guard prebuilt[d.id] == nil, isReady(d) else { return }
        prebuilt[d.id] = instantiateCanonical(d)
        print("[assets] \(d.id) art layer prebuilt")
    }

    /// The layer in the frozen frame: canonical build (or the prebuilt one), then origin + yaw applied once.
    func instantiate(_ d: WorldDescriptor, ctx: WorldContext) -> Entity {
        let layer = prebuilt.removeValue(forKey: d.id) ?? instantiateCanonical(d)
        layer.position = ctx.origin
        layer.orientation = ctx.yaw
        return layer
    }

    /// One clone of the art layer: which asset, where (`at` = [forward, right, up] in the canonical frame), and from which
    /// quality tier up it exists.
    private struct Piece {
        let asset: String
        let at: SIMD3<Float>
        let yaw: Float
        let scale: Float
        let tier: Int
    }

    /// Every piece of the layer, in the order (and with the scatter RNG) the canonical build has always used.
    private func pieces(_ d: WorldDescriptor) -> (pieces: [Piece], missing: Set<String>) {
        var out: [Piece] = []
        var missing = Set<String>()
        for p in d.placements ?? [] {
            guard entities["\(d.id)/\(p.asset)"] != nil else { missing.insert(p.asset); continue }
            let at = SIMD3<Float>(p.at.count > 0 ? p.at[0] : 0, p.at.count > 1 ? p.at[1] : 0, p.at.count > 2 ? p.at[2] : 0)
            out.append(Piece(asset: p.asset, at: at, yaw: p.yaw, scale: p.scale, tier: p.minTier))
        }
        for s in d.scatters ?? [] {
            guard entities["\(d.id)/\(s.asset)"] != nil else { missing.insert(s.asset); continue }
            var rng = WorldKit.RNG(UInt32(truncatingIfNeeded: s.seed &* 7919 &+ 17))
            for i in 0..<s.count {
                let radius = rng.range(s.radius[0], s.radius.count > 1 ? s.radius[1] : s.radius[0])
                let angle = rng.range(s.angle[0], s.angle.count > 1 ? s.angle[1] : s.angle[0]) * .pi / 180
                let at = SIMD3<Float>(cos(angle) * radius, sin(angle) * radius, s.y)
                let scale = rng.range(s.scale[0], s.scale.count > 1 ? s.scale[1] : s.scale[0])
                let yaw = s.randomYaw ? rng.range(0, 360) : 0
                // The last third of every scatter only exists at high quality, the middle third from medium up.
                let tier = max(s.minTier, i * 3 / max(1, s.count))
                out.append(Piece(asset: s.asset, at: at, yaw: yaw, scale: scale, tier: tier))
            }
        }
        return (out, missing)
    }

    /// One clone into `layer` (canonical frame: origin at (0,0,0), forward −Z, right +X).
    private func place(_ piece: Piece, of d: WorldDescriptor, into layer: Entity) {
        guard let proto = entities["\(d.id)/\(piece.asset)"] else { return }
        let f = SIMD3<Float>(0, 0, -1), r = SIMD3<Float>(1, 0, 0)
        let e = proto.clone(recursive: true)
        e.position = f * piece.at.x + r * piece.at.y + SIMD3<Float>(0, piece.at.z, 0)
        e.orientation = simd_quatf(angle: piece.yaw * .pi / 180, axis: [0, 1, 0])
        e.scale = SIMD3(repeating: piece.scale)
        e.components.set(WorldTierComponent(minTier: piece.tier))
        layer.addChild(e)
    }

    /// Canonical frame: origin at (0,0,0), forward −Z, right +X. `at` = [forward, right, up].
    private func instantiateCanonical(_ d: WorldDescriptor) -> Entity {
        let layer = Entity()
        layer.name = "assets"
        let (all, missing) = pieces(d)
        for piece in all { place(piece, of: d, into: layer) }
        if !missing.isEmpty { print("[assets] \(d.id): not yet loaded → \(missing.sorted())") }
        return layer
    }

    /// **v4 B5 §5.** The art layer's clone storm (20–33 ms in one frame on the headset) as steps of `chunk` clones each,
    /// for a build spread over frames. The layer is empty until the last step has run; nothing is in the scene.
    func canonicalSteps(_ d: WorldDescriptor, chunk: Int = 6) -> (layer: Entity, steps: [WorldBuildStep]) {
        let layer = Entity()
        layer.name = "assets"
        let (all, missing) = pieces(d)
        if !missing.isEmpty { print("[assets] \(d.id): not yet loaded → \(missing.sorted())") }
        var steps: [WorldBuildStep] = []
        var start = 0
        let size = max(1, chunk)
        while start < all.count {
            let slice = Array(all[start..<min(all.count, start + size)])
            steps.append(WorldBuildStep("art layer \(start + 1)–\(start + slice.count)/\(all.count)") { [weak self, weak layer] in
                guard let self, let layer else { return }
                for piece in slice { self.place(piece, of: d, into: layer) }
            })
            start += size
        }
        return (layer, steps)
    }

    /// **v4 B5 §5.** The art layer prebuilt for later, built over frames by the engine (`canonicalSteps`), handed back here.
    func storePrebuilt(_ layer: Entity, for d: WorldDescriptor) {
        guard prebuilt[d.id] == nil else { return }
        prebuilt[d.id] = layer
    }

    /// Everything currently cached for a world other than `keep` is released (memory).
    func unloadAll(except keep: Set<String>) {
        for key in entities.keys where !keep.contains(String(key.split(separator: "/").first ?? "")) { entities.removeValue(forKey: key) }
        for key in environments.keys where !keep.contains(key) { environments.removeValue(forKey: key) }
        for key in skies.keys where !keep.contains(key) { skies.removeValue(forKey: key) }
    }
}

/// Minimum quality tier at which an entity is shown.
struct WorldTierComponent: Component {
    var minTier: Int
}

// MARK: - Lighting, sky, fog

@MainActor
enum WorldLighting {
    /// Image-based light on `root`; every ModelEntity below receives it (inside the opaque shell there is no
    /// passthrough light, so without this every PBR surface is black).
    static func applyIBL(_ env: EnvironmentResource, intensity: Float, to root: Entity) {
        root.components.set(ImageBasedLightComponent(source: .single(env), intensityExponent: intensity))
        receive(root, light: root)
    }

    static func receive(_ entity: Entity, light: Entity) {
        if let model = entity as? ModelEntity {
            model.components.set(ImageBasedLightReceiverComponent(imageBasedLight: light))
        }
        for child in entity.children { receive(child, light: light) }
    }

    /// Concentric translucent bands = distance haze, centred on the world origin (head over the floor). Cheap, layered,
    /// dims with quality tier.
    static func fogLayers(_ layers: [WorldFogLayer]) -> Entity {
        let root = Entity()
        root.name = "fog"
        let haze = WorldKit.hazeBandTexture()
        for (i, layer) in layers.enumerated() {
            let band = ModelEntity(mesh: FXMeshes.cylinderBand(radius: layer.distance, yMin: -layer.height * 0.35, yMax: layer.height * 0.65),
                                   materials: [FXMaterials.glow(haze, tint: UIColor(hex: layer.color), opacity: layer.opacity)])
            band.position = .zero
            band.components.set(WorldTierComponent(minTier: layer.minTier))
            band.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.worldOrder))
            band.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.005, baseOpacity: 1, opacityAmplitude: 0.12, period: 7 + Float(i) * 2, phase: Float(i)))
            root.addChild(band)
        }
        return root
    }

    /// Apply a quality tier to a subtree: entities with a `WorldTierComponent` above the tier are disabled.
    static func applyTier(_ tier: WorldQuality, to root: Entity) {
        if let t = root.components[WorldTierComponent.self] { root.isEnabled = t.minTier <= tier.rawValue }
        for child in root.children { applyTier(tier, to: child) }
    }

    /// Triangle count of a subtree (for the `[perf]` budget print). `enabledOnly` counts what the current
    /// quality tier actually draws — a disabled subtree costs nothing, so the tier line must not include it —
    /// and multiplies a `MeshInstancesComponent` by its instance count (one draw, N times the triangles).
    static func triangleCount(_ root: Entity, enabledOnly: Bool = false) -> Int {
        if enabledOnly && !root.isEnabled { return 0 }
        var n = 0
        if let model = root as? ModelEntity, let mesh = model.model?.mesh {
            var own = 0
            for m in mesh.contents.models { for part in m.parts { own += (part.triangleIndices?.count ?? 0) / 3 } }
            n += own * max(1, instanceCount(model))
        }
        for child in root.children { n += triangleCount(child, enabledOnly: enabledOnly) }
        return n
    }

    /// Draw calls of a subtree: one per material of every enabled `ModelEntity` that has a mesh (an instanced
    /// entity still issues one draw, which is the point of instancing). A proxy, but the one number that moved
    /// most in 霓虹雨城's pass and the one a headset log can carry.
    static func drawCount(_ root: Entity, enabledOnly: Bool = true) -> Int {
        if enabledOnly && !root.isEnabled { return 0 }
        var n = 0
        if let model = root as? ModelEntity, let component = model.model { n += max(1, component.materials.count) }
        for child in root.children { n += drawCount(child, enabledOnly: enabledOnly) }
        return n
    }

    /// Of those draws, the ones whose material is blended — the transparent pass, where a tile renderer has no
    /// early-z and shades every covered pixel. This is the number the overdraw budget is about.
    static func blendedDrawCount(_ root: Entity, enabledOnly: Bool = true) -> Int {
        if enabledOnly && !root.isEnabled { return 0 }
        var n = 0
        if let model = root as? ModelEntity, let component = model.model {
            n += component.materials.filter(isBlended).count
        }
        for child in root.children { n += blendedDrawCount(child, enabledOnly: enabledOnly) }
        return n
    }

    private static func isBlended(_ material: any RealityKit.Material) -> Bool {
        if let m = material as? UnlitMaterial { if case .opaque = m.blending { return false }; return true }
        if let m = material as? PhysicallyBasedMaterial { if case .opaque = m.blending { return false }; return true }
        return !(material is PortalMaterial)
    }

    /// Instances a `MeshInstancesComponent` draws (1 when the entity has none). The worlds only instance
    /// single-part meshes (a quad, a unit box), so part 0 carries the count.
    private static func instanceCount(_ model: ModelEntity) -> Int {
        guard let instances = model.components[MeshInstancesComponent.self] else { return 1 }
        return instances[partIndex: 0]?.data.instanceCount ?? 1
    }
}
