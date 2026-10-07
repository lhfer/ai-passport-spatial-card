import Foundation
import RealityKit
import UIKit

/// W3 深海微光: water rises from the floor past the eyes; the room sinks into a moonlit reef where
/// plankton drifts, god rays sway and jellyfish pass. Exit: the surface falls back down past the eyes.
///
/// Entry (3.6 s, flood): 0.00–0.08 highlight sweep on the card, first bubbles · 0.08–0.53 the water
/// plane rises 0.75 m/s from the floor (bubble shell around the card) · 0.53–0.64 the surface passes the
/// eyes: a brief cyan dim-flash (never a full-white flash) and a ring on the shell · 0.64 sky dome deep
/// blue, reef fades in · 0.64–1.0 god rays, plankton, first jellyfish.
/// Exit (3.0 s, drain): bubbles rise, the surface falls from 12 m toward the eyes (the wearer never
/// moves) · passes the eyes at 0.55 with the same dim-flash · reef fades, shell clears, a foam ring on the
/// desk, water drops off the card.
///
/// Art (Phase B): the terrace, the coral cliff 6–12 m ahead and the wreck right-rear are scanned rocks and
/// Kenney hull pieces from `deep-sea.json` (placements/scatters, lit by the `kloppenheim_02` IBL, hazed by
/// three fog bands); this file adds the PBR sand disc with caustics, the instanced kelp forest to the left,
/// the fish school, the whale, jellyfish, plankton and the water surface.
@MainActor
final class DeepSeaWorld: World {
    let descriptor: WorldDescriptor
    let root = Entity()
    private let reef = Entity()
    private var assetLayer: Entity?
    private let water: ModelEntity
    private let moon: ModelEntity
    private let sand: ModelEntity
    private var caustics: [ModelEntity] = []
    private var rays: [ModelEntity] = []
    private var jellies: [Entity] = []
    private var coralGlow: [Entity] = []
    private let plankton = Entity()
    private let bubbles = Entity()
    private let kelp = KelpForest()
    private let fish = FishSchool()
    private let whale = WhaleSilhouette()
    private var time: Float = 0
    private var rng = WorldKit.RNG(0x5EA)
    private var eyeY: Float = 1.15
    private var quality: WorldQuality = .high

    init(descriptor: WorldDescriptor) {
        self.descriptor = descriptor
        water = ModelEntity(mesh: .generatePlane(width: 40, depth: 40), materials: [DeepSeaWorld.waterMaterial(descriptor)])
        moon = ModelEntity(mesh: .generatePlane(width: 1.6, depth: 1.6), materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: descriptor.highlightColor, opacity: 0.9)])
        sand = ModelEntity(mesh: .generatePlane(width: 60, depth: 60, cornerRadius: 30), materials: [DeepSeaWorld.sandMaterial(DeepSeaWorld.sandTextures)])
        root.addChild(water)
        root.addChild(reef)
        reef.components.set(OpacityComponent(opacity: 0))
        reef.isEnabled = false
    }

    private static func waterMaterial(_ d: WorldDescriptor) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        m.baseColor = .init(tint: d.primaryColor.withAlphaComponent(0.6), texture: nil)
        m.roughness = .init(floatLiteral: 0.05)
        m.metallic = .init(floatLiteral: 0.3)
        m.emissiveColor = .init(color: d.secondaryColor, texture: nil)
        m.emissiveIntensity = 0.3
        m.blending = .transparent(opacity: .init(floatLiteral: 0.55))
        m.faceCulling = .none
        m.writesDepth = false
        return m
    }

    // MARK: Sand (Poly Haven coast_sand_01, PBR under the IBL)

    private struct SandTextures {
        var color: TextureResource
        var normal: TextureResource?
        var roughness: TextureResource?
        var occlusion: TextureResource?
    }
    private static var sandTextures: SandTextures?
    private static var sandLoading = false

    private static func loadSandTextures() async -> SandTextures? {
        func load(_ name: String, _ semantic: TextureResource.Semantic) async -> TextureResource? {
            guard let url = Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "worlds/deep-sea") else {
                print("[assets] deep-sea/\(name).jpg missing from the bundle"); return nil
            }
            return try? await TextureResource(contentsOf: url, options: .init(semantic: semantic, mipmapsMode: .allocateAndGenerateAll))
        }
        guard let color = await load("coast_sand_01_Diffuse_1k", .color) else { return nil }
        return SandTextures(color: color,
                            normal: await load("coast_sand_01_nor_gl_1k", .normal),
                            roughness: await load("coast_sand_01_Rough_1k", .raw),
                            occlusion: await load("coast_sand_01_AO_1k", .raw))
    }

    /// Moonlit sand: the scan's albedo cooled toward the palette, tiled 21× over the 60 m disc (reaches the 30 m shell).
    private static func sandMaterial(_ t: SandTextures?) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        if let t {
            m.baseColor = .init(tint: UIColor(hex: "#7D93A6"), texture: .init(t.color))
            if let n = t.normal { m.normal = .init(texture: .init(n)) }
            if let r = t.roughness { m.roughness = .init(scale: 1, texture: .init(r)) } else { m.roughness = .init(floatLiteral: 0.9) }
            if let ao = t.occlusion { m.ambientOcclusion = .init(texture: .init(ao)) }
            m.textureCoordinateTransform = .init(offset: .zero, scale: [21, 21], rotation: 0)
        } else {
            m.baseColor = .init(tint: UIColor(hex: "#5C6F7E"), texture: nil)
            m.roughness = .init(floatLiteral: 0.9)
        }
        m.metallic = .init(floatLiteral: 0)
        return m
    }

    private func causticsMaterial(opacity: Float) -> UnlitMaterial {
        var m = FXMaterials.glow(WorldKit.causticsTexture(), tint: UIColor(hex: "#A8ECFF"), opacity: opacity)
        m.textureCoordinateTransform = .init(offset: .zero, scale: [11, 11], rotation: 0)
        return m
    }

    /// Ground haze: a disc whose alpha ramps from 0 at ~8 m to opaque at the shell, so the far sand dissolves into the
    /// fog colour instead of meeting the sky dome at a hard horizon.
    private static var hazeTex: TextureResource?
    private static func hazeTexture() -> TextureResource? {
        if let t = hazeTex { return t }
        let size = CGSize(width: 256, height: 256)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0).cgColor, UIColor(white: 1, alpha: 0.55).cgColor,
                          UIColor(white: 1, alpha: 0.9).cgColor, UIColor(white: 1, alpha: 1).cgColor]
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 0.27, 0.6, 0.85, 1])!
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.cgContext.drawRadialGradient(gradient, startCenter: c, startRadius: 0, endCenter: c, endRadius: size.width / 2, options: [.drawsAfterEndLocation])
        }
        hazeTex = image.cgImage.flatMap { try? TextureResource(image: $0, withName: "sea.haze", options: .init(semantic: .color, mipmapsMode: .allocateAndGenerateAll)) }
        return hazeTex
    }

    // MARK: Build

    func build(ctx: WorldContext, engine: WorldEngine) {
        eyeY = ctx.headPosition.y
        var f = ctx.forward, r = ctx.right
        let origin = ctx.origin
        water.position = SIMD3(ctx.headPosition.x, ctx.floorY - 0.05, ctx.headPosition.z)
        water.components.set(FloatComponent(basePosition: water.position, amplitude: 0.01, period: 3.2))

        // The descriptor's rocks / wreck / fog arrive with the room still visible; they surface with the reef.
        assetLayer = root.findEntity(named: "assets")
        assetLayer?.components.set(OpacityComponent(opacity: 0))
        assetLayer?.isEnabled = false
        if CommandLine.arguments.contains("--world-bounds"), let layer = assetLayer {
            // Clones are all named "root"; identify them by the first mesh prim below and dump one material per asset.
            var seen = Set<String>()
            func firstModel(_ e: Entity) -> ModelEntity? {
                if let m = e as? ModelEntity { return m }
                for c in e.children { if let m = firstModel(c) { return m } }
                return nil
            }
            for child in layer.children {
                guard let model = firstModel(child), seen.insert(model.name).inserted else { continue }
                let b = child.visualBounds(relativeTo: child)
                var desc = "?"
                if let mat = model.model?.materials.first {
                    if let p = mat as? PhysicallyBasedMaterial {
                        desc = "PBR tex:\(p.baseColor.texture == nil ? "no" : "yes") metal:\(p.metallic) rough:\(p.roughness) blend:\(p.blending)"
                    } else { desc = String(describing: type(of: mat)) }
                }
                print(String(format: "[bounds] %@ at (%.1f, %.1f, %.1f) s=%.2f extents (%.2f, %.2f, %.2f) min y %.2f %@", model.name, child.position.x, child.position.y, child.position.z, child.scale.x, b.extents.x, b.extents.y, b.extents.z, b.min.y, desc))
            }
        }
        // Debug aid (simulator cannot turn its head): `--world-yaw <degrees>` spins the whole world around the wearer.
        if let i = CommandLine.arguments.firstIndex(of: "--world-yaw"), i + 1 < CommandLine.arguments.count,
           let degrees = Float(CommandLine.arguments[i + 1]) {
            let spin = simd_quatf(angle: degrees * .pi / 180, axis: [0, 1, 0])
            f = spin.act(f); r = spin.act(r)
            if let layer = assetLayer { layer.orientation = spin * layer.orientation }
        }

        // Sand disc (PBR, textures stream in once and are cached for the next entry) + two drifting caustic sheets.
        sand.position = origin + [0, 0.002, 0]
        reef.addChild(sand)
        if DeepSeaWorld.sandTextures == nil, !DeepSeaWorld.sandLoading {
            DeepSeaWorld.sandLoading = true
            Task { @MainActor [weak self] in
                let started = Date()
                if let t = await DeepSeaWorld.loadSandTextures() {
                    DeepSeaWorld.sandTextures = t
                    self?.sand.model?.materials = [DeepSeaWorld.sandMaterial(t)]
                    print(String(format: "[assets] deep-sea sand textures ready in %.0f ms", Date().timeIntervalSince(started) * 1000))
                }
                DeepSeaWorld.sandLoading = false
            }
        }
        if let hazeTex = DeepSeaWorld.hazeTexture() {
            let haze = ModelEntity(mesh: .generatePlane(width: 62, depth: 62, cornerRadius: 31), materials: [FXMaterials.glow(hazeTex, tint: UIColor(hex: "#0A2040"), opacity: 0.96)])
            haze.position = origin + [0, 0.03, 0]
            reef.addChild(haze)
        }
        for i in 0..<2 {
            let sheet = ModelEntity(mesh: .generatePlane(width: 40, depth: 40, cornerRadius: 20), materials: [causticsMaterial(opacity: i == 0 ? 0.07 : 0.045)])
            sheet.position = origin + [0, 0.012 + Float(i) * 0.006, 0]
            // Two sheets drifting against each other read as moving caustics without touching the material per frame.
            sheet.components.set(FloatComponent(basePosition: sheet.position, axis: simd_normalize(i == 0 ? f + r * 0.4 : -f + r * 0.7), amplitude: 0.5, period: i == 0 ? 11 : 14, phase: Float(i) * 2))
            reef.addChild(sheet)
            caustics.append(sheet)
        }

        // Kelp forest to the left, fish school over the terrace, whale circling far out.
        kelp.build(origin: origin, forward: f, right: r, rng: &rng)
        reef.addChild(kelp.root)
        fish.build(origin: origin, forward: f, right: r, color: UIColor(hex: "#6C8DA6"), rng: &rng)
        reef.addChild(fish.root)
        whale.build(origin: origin, forward: f, right: r)
        reef.addChild(whale.root)

        // Bioluminescent coral accents at the foot of the cliff and on the terrace (billboarded soft glows).
        let glowTex = FXTextures.shared.softDisc
        for i in 0..<10 {
            let ahead = i < 6 ? rng.range(5.4, 7.2) : rng.range(2.4, 5.0)
            let side = i < 6 ? rng.range(-5, 5) : rng.range(-6, 6)
            let glow = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [FXMaterials.glow(glowTex, tint: i % 3 == 0 ? descriptor.secondaryColor : descriptor.accentColor, opacity: 0.2)])
            let size = rng.range(0.18, 0.36)
            glow.position = origin + f * ahead + r * side + [0, rng.range(0.1, i < 6 ? 0.9 : 0.4), 0]
            glow.components.set(BillboardComponent())
            glow.components.set(PulseComponent(baseScale: size, scaleAmplitude: size * 0.15, baseOpacity: 1, opacityAmplitude: 0.4, period: rng.range(2.5, 5), phase: rng.range(0, 6)))
            reef.addChild(glow)
            coralGlow.append(glow)
        }

        // Moon disc 12 m up, god rays slanting from it.
        moon.position = origin + f * 3 + [0, 11.5, 0]
        moon.orientation = simd_quatf(angle: .pi, axis: [1, 0, 0])
        reef.addChild(moon)
        for i in 0..<4 {
            let ray = ModelEntity(mesh: .generateCone(height: 12, radius: 0.9), materials: [FXMaterials.glow(FXTextures.shared.coneGlow, tint: descriptor.secondaryColor, opacity: 0.08)])
            ray.position = origin + f * (2 + Float(i)) + r * (Float(i) * 1.4 - 2) + [0, 6, 0]
            ray.orientation = simd_quatf(angle: 0.25 + 0.1 * Float(i), axis: [1, 0, 0.3])
            ray.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.02, baseOpacity: 1, opacityAmplitude: 0.35, period: 4 + Float(i)))
            ray.components.set(BloomComponent(scope: .hierarchical))
            reef.addChild(ray)
            rays.append(ray)
        }
        // Plankton: near-still motes (birth rate scales with the quality tier).
        plankton.position = origin + [0, 1.2, 0]
        var pk = ParticleEmitterComponent()
        pk.emitterShape = .sphere
        pk.emitterShapeSize = [3.5, 2, 3.5]
        pk.birthLocation = .volume
        pk.speed = 0.01; pk.speedVariation = 0.01
        pk.mainEmitter.image = FXTextures.shared.particle
        pk.mainEmitter.blendMode = .additive
        pk.mainEmitter.birthRate = 240 * quality.density
        pk.mainEmitter.lifeSpan = 5; pk.mainEmitter.lifeSpanVariation = 2
        pk.mainEmitter.size = 0.006; pk.mainEmitter.sizeVariation = 0.004
        pk.mainEmitter.dampingFactor = 0.9
        pk.mainEmitter.noiseStrength = 0.01
        pk.mainEmitter.opacityCurve = .gradualFadeInOut
        pk.mainEmitter.isLightingEnabled = false
        pk.mainEmitter.color = .evolving(start: .single(descriptor.secondaryColor.withAlphaComponent(0.8)), end: .single(UIColor(hex: "#38FFC8").withAlphaComponent(0)))
        pk.isEmitting = false
        plankton.components.set(pk)
        reef.addChild(plankton)
        // Jellyfish: bell + tentacles, drifting on Float.
        for i in 0..<3 {
            let jelly = Entity()
            let bell = ModelEntity(mesh: .generateSphere(radius: 0.16), materials: [WorldKit.emissive(descriptor.accentColor, intensity: 0.5, opacity: 0.22)])
            bell.scale = [1, 0.7, 1]
            jelly.addChild(bell)
            for k in 0..<6 {
                let tentacle = ModelEntity(mesh: .generateBox(width: 0.008, height: 0.55, depth: 0.008), materials: [WorldKit.emissive(descriptor.accentColor, intensity: 0.4, opacity: 0.2)])
                let a = Float(k) / 6 * 2 * .pi
                tentacle.position = [cos(a) * 0.12, -0.45, sin(a) * 0.12]
                jelly.addChild(tentacle)
            }
            bell.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.12, baseOpacity: 1, opacityAmplitude: 0.3, period: 2.0, phase: Float(i)))
            jelly.position = origin + f * rng.range(2, 5) + r * rng.range(1, 5) + [0, rng.range(1.2, 2.6), 0]
            jelly.components.set(FloatComponent(basePosition: jelly.position, axis: simd_normalize(r + [0, 0.4, 0]), amplitude: 0.6, period: 14 + Float(i) * 3, phase: Float(i)))
            reef.addChild(jelly)
            jellies.append(jelly)
        }
        // Bubbles around the card (entry) — box emitter at the card.
        bubbles.position = ctx.cardPosition + [0, 0.02, 0]
        var bb = ParticleEmitterComponent()
        bb.emitterShape = .box
        bb.emitterShapeSize = [0.12, 0.01, 0.12]
        bb.birthLocation = .volume
        bb.emissionDirection = [0, 1, 0]
        bb.speed = 0.25; bb.speedVariation = 0.1
        bb.mainEmitter.image = FXTextures.shared.ring
        bb.mainEmitter.blendMode = .alpha
        bb.mainEmitter.birthRate = 0
        bb.mainEmitter.lifeSpan = 2.5
        bb.mainEmitter.size = 0.008; bb.mainEmitter.sizeVariation = 0.005
        bb.mainEmitter.noiseStrength = 0.03
        bb.mainEmitter.opacityCurve = .gradualFadeInOut
        bb.mainEmitter.isLightingEnabled = false
        bb.mainEmitter.color = .constant(.single(descriptor.highlightColor.withAlphaComponent(0.7)))
        bubbles.components.set(bb)
        root.addChild(bubbles)

        engine.shell.setColor(descriptor.shellColor)
    }

    private func setBubbles(rate: Float) {
        guard var e = bubbles.components[ParticleEmitterComponent.self] else { return }
        e.mainEmitter.birthRate = rate
        e.isEmitting = rate > 0
        bubbles.components.set(e)
    }

    /// Quality tier: plankton density, fish count, far kelp layer, half the god rays and the coral glows; the far
    /// cliff rows carry `minTier` in the descriptor and are handled by the engine.
    func applyQuality(_ tier: WorldQuality) {
        quality = tier
        if var e = plankton.components[ParticleEmitterComponent.self] {
            e.mainEmitter.birthRate = 240 * tier.density
            plankton.components.set(e)
        }
        fish.setVisible(fraction: tier.density)
        kelp.setFarVisible(tier >= .medium)
        for (i, ray) in rays.enumerated() { ray.isEnabled = tier == .high || i % 2 == 0 }
        for glow in coralGlow { glow.isEnabled = tier >= .medium }
        for sheet in caustics.dropFirst() { sheet.isEnabled = tier == .high }
    }

    /// Surfaces shimmer with caustics and dissolve downward like they were never solid (RoomFission).
    func fissionRecipe(ctx: WorldContext) -> RoomFission.Recipe? { RoomFission.deepSea(descriptor) }

    /// Per-frame life: kelp sway, fish loop, whale pass (caustic drift and jellyfish run on components).
    private func animate(dt: Float) {
        kelp.update(time: time)
        fish.update(time: time)
        whale.update(time: time)
    }

    private func setReefVisible(_ k: Float) {
        reef.isEnabled = k > 0
        reef.components.set(OpacityComponent(opacity: k))
        assetLayer?.isEnabled = k > 0
        assetLayer?.components.set(OpacityComponent(opacity: k))
    }

    func entry(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        setBubbles(rate: p < 0.6 ? 14 : 0)
        // Water rises from the floor (0.08–0.53), reaching eye level at 0.53, then keeps going to 12 m.
        let rise = max(0, (p - 0.08) / 0.45)
        let targetY: Float
        if rise < 1 {
            targetY = ctx.floorY + (eyeY - ctx.floorY) * rise
        } else {
            targetY = eyeY + (p - 0.53) / 0.47 * 11
        }
        water.components.remove(FloatComponent.self)
        water.position.y = targetY
        // Passing the eyes (0.53–0.64): shell dims to blue quickly; a soft ring is implied by the dim.
        if p < 0.53 {
            engine.shell.set(opacity: 0.15 * rise)     // room cools slightly
        } else if p < 0.64 {
            let k = (p - 0.53) / 0.11
            engine.shell.set(opacity: 0.15 + 0.85 * k)
        } else {
            engine.shell.set(opacity: 1)
            let k = min(1, (p - 0.64) / 0.3)
            setReefVisible(k)
            if let e = plankton.components[ParticleEmitterComponent.self], !e.isEmitting {
                var em = e; em.isEmitting = true; plankton.components.set(em)
            }
            animate(dt: dt)
        }
        if p >= 0.53 && p < 0.56 { FXAudio.shared.play(.surface, on: root) }
    }

    func inside(dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        engine.shell.set(opacity: 1)
        water.position.y = eyeY + 11 + 0.05 * sin(time * 0.6)
        moon.components.set(OpacityComponent(opacity: 0.85 + 0.15 * sin(time * 0.4)))
        animate(dt: dt)
    }

    func exit(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        // 0–0.13 bubbles, moon brightens · 0.13–0.55 surface falls from 12 m to the eyes, reef fades ·
        // 0.55–0.62 passes the eyes (dim-flash) · 0.62–0.87 surface falls to the floor, shell clears · 0.87–1 foam.
        setBubbles(rate: p < 0.2 ? 40 : 0)
        let fall = max(0, min(1, (p - 0.13) / 0.42))
        if p < 0.55 {
            water.position.y = eyeY + 11 * (1 - fall * fall)
            setReefVisible(1 - fall)
            engine.shell.set(opacity: 1)
            animate(dt: dt)
        } else if p < 0.62 {
            engine.shell.set(opacity: 1 - (p - 0.55) / 0.07 * 0.85)
            setReefVisible(0)
            water.position.y = eyeY - (p - 0.55) / 0.07 * 0.3
            if p < 0.565 { FXAudio.shared.play(.surface, on: root) }
        } else {
            let k = min(1, (p - 0.62) / 0.25)
            water.position.y = eyeY - 0.3 - (eyeY - 0.3 - ctx.floorY + 0.1) * k
            engine.shell.set(opacity: 0.15 * (1 - k))
            water.components.set(OpacityComponent(opacity: 1 - k))
            setReefVisible(0)
        }
    }

    func teardown() {}
}
