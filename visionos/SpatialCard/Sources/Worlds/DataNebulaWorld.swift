import Foundation
import RealityKit
import UIKit

/// W5 数据星云: the room powers down (the shell goes black), the card charges, then one star per follower
/// bursts out of it and settles into a galactic disc around the wearer. Three named stars (your tags) are joined
/// into a constellation; a title above the card counts the followers. New followers arrive as a fountain of
/// new stars from the card. Exit: the stars stream back into the card, the night closes over them, and the shell
/// opens onto the room.
///
/// The look is "you are standing inside a galaxy", which needs four things a plain star field does not give:
/// every star faces the reader (a quad edge-on is invisible), its size comes from its distance, its colour comes
/// from one of three temperature buckets, and there is a far layer plus a Milky Way band behind the near disc so
/// the sky has depth instead of being a shell of dots.
///
/// Entry (3.8 s, lights-out): 0.00–0.25 power down: shell to black, only the card glows · 0.25–0.38 the card
/// charges (core glow grows, `charge` cue) while dust starts to rise · 0.38–0.70 star burst (one instance per
/// follower, easing out along a spiral) · 0.66–1.00 constellation lines + labels, planet and nebulae, the far
/// layer and the dark sky fade in behind everything · 0.85 title.
/// Inside: the disc turns at 0.4°/s, and at `take.heroAt` the whole galaxy rolls over to `take.heroTilt`°.
/// Exit (3.0 s): 0.00–0.45 the stars stream back into the card, lines fade 0–0.2 · 0.45–0.65 the sky darkens to
/// the black shell (`dawn` chord at 0.45) · 0.55–1.00 the shell opens onto the room.
@MainActor
final class DataNebulaWorld: World {
    let descriptor: WorldDescriptor
    let root = Entity()
    private let galaxy = Entity()

    /// One colour temperature of star = one instanced draw. `LowLevelInstanceData` carries transforms only (no
    /// per-instance colour), so colour can only vary between buckets: warm / white / cool repeat 1 : 2 : 1, which
    /// makes the split 25 / 50 / 25 and the global → (bucket, slot) mapping arithmetic instead of a table.
    private struct Bucket {
        let entity: ModelEntity
        let data: LowLevelInstanceData
    }
    private var buckets: [Bucket] = []
    /// Warm / white / cool, with the emissive strength each needs. A pale tint at 3.5 tone-maps to plain white,
    /// so the two coloured buckets are deeper and burn a little less — the white bucket is half the sky and keeps
    /// the field reading as stars rather than as confetti.
    private static let bucketTints: [(hex: String, emissive: Float)] = [("#FF9A3C", 3.0), ("#F2F0FF", 3.5), ("#6E9CFF", 3.2)]

    private var targets: [SIMD3<Float>] = []
    /// Look-at rotation per star, computed once against the frozen head. The galaxy is centred on the head and
    /// only ever rotates about it, so a rotation carries star and facing together — nothing to redo per frame.
    private var facings: [simd_quatf] = []
    private var sizes: [Float] = []
    private var delays: [Float] = []
    /// One star per follower, clamped by the descriptor; the pool holds spares for celebrations (an instance
    /// buffer cannot grow, so spares sit at zero scale until a fountain activates them).
    private var starCount = 0
    private var poolCount = 0
    private var activeCount = 0
    /// The far layer: static, much dimmer stars at 18–26 m that fill the sky behind the disc.
    private var far: ModelEntity?
    private var farData: LowLevelInstanceData?
    private var farTransforms: [simd_float4x4] = []
    private var band: ModelEntity?
    /// The Milky Way's own stars: a band is stars, not a strip of haze painted over the sky.
    private var bandStars: ModelEntity?
    private var bandData: LowLevelInstanceData?
    private var bandTransforms: [simd_float4x4] = []
    /// The few dozen stars big enough to be looked at, and the diffraction sprite drawn over them.
    private var heroIndices: [Int] = []
    private var heroSpikes: ModelEntity?
    private let starLight = Entity()
    private var named: [ModelEntity] = []
    private var labels: [ModelEntity] = []
    private var lines: [ModelEntity] = []
    private let dust = Entity()
    private let comet: ModelEntity
    private let cometTail = Entity()
    private let planet = Entity()
    private var nebulae: [Entity] = []
    private var halos: [ModelEntity] = []
    private var dome: ModelEntity?
    private var charge: ModelEntity?
    private var artLayer: Entity?
    /// The art layer's fog bands (`WorldLighting.fogLayers`): transparent haze, so they keep fading by subtree.
    private var fogLayer: Entity?
    /// Which skin each prop takes, resolved once in `skinAssets`.
    private enum ArtSkin { case rock, crystal, metal }
    private var artPieces: [(entity: Entity, skin: ArtSkin)] = []
    /// The alpha the prop materials currently carry (quantised — see `setArtOpacity`).
    private var artAlpha: Float = 1
    private var time: Float = 0
    /// Accumulated disc rotation (radians) while inside; a quaternion's angle wraps at π, so it is kept here.
    private var spin: Float = 0
    /// Seconds inside, for the hero shot.
    private var heroClock: Float = 0
    private var cometClock: Float = -1000
    private var burstPlayed = false
    private var chargePlayed = false
    private var titleShown = false
    private var dawnPlayed = false
    private var tier: WorldQuality = .high
    private var rng = WorldKit.RNG(0x57A2)
    private var cardPos: SIMD3<Float> = .zero
    private var cameraHead: SIMD3<Float> = .zero
    /// The view direction frozen at entry: the axis the hero shot rolls the galaxy about.
    private var heroAxis: SIMD3<Float> = [0, 0, -1]

    /// A celebration fountain: stars `range` fly from the card to their targets over `duration`.
    private struct Fountain {
        let range: Range<Int>
        var elapsed: Float = 0
        let duration: Float = 1.4
        let followers: Int
        var landed = false
    }
    private var fountains: [Fountain] = []
    private var pendingInject = 0
    private static let titleScale: Float = 2.2
    private static let cometPassSeconds: Float = 3
    private static let farCount = 800
    private static let bandStarCount = 1500
    private static let heroCount = 32
    /// The band's tilt out of the disc plane — enough to keep it off dead level, little enough that it still
    /// reads as the same galaxy the near stars belong to.
    private static let bandTilt: Float = 8 * .pi / 180
    /// Moon: ~8° across at 25 m. Any bigger and it stops being a distant body and becomes a grey wall.
    private static let moonRadius: Float = 1.8
    /// Moon offset from the world origin in [forward, right, up] metres — 25 m out, up and well clear of the
    /// constellation. `starLight` is aimed from it, so the two can never drift apart.
    private static let moonAt = SIMD3<Float>(20, 13, 8)
    /// The hero roll takes 4 s, so the comet's first pass (`take.cometFirst`) runs right through it.
    private static let heroDuration: Float = 4
    /// Median star: 0.13° across, log-normal with σ 0.45 — a real sky is a few bright stars over many faint ones.
    private static let medianAngle: Float = 0.13 * .pi / 180
    private static let farAngle: Float = 0.08 * .pi / 180

    /// **v4 B5 §5.** What `build` would render and upload on the main thread, made ahead: the star sprites of the three
    /// buckets, the far layer and the band; the hero and named stars' spikes; the halo; the 48 × 128 dome.
    static func prewarm(_ d: WorldDescriptor) {
        WorldKit.prewarmStarTextures(sprites: bucketTints.map { UIColor(hex: $0.hex) } + [UIColor(hex: "#DFE4FF"), UIColor(hex: "#D6DEFF")],
                                     spikes: [UIColor(hex: "#E8EEFF"), UIColor(hex: "#FFF0DC")], halo: true)
        WorldKit.prewarmSkySphere(radius: (d.environment?.skyRadius ?? 30) - 4, rings: 48, segments: 128)
    }

    /// CoreText textures `build` needs, rendered in the background at space open.
    static func preheatJobs(_ d: WorldDescriptor) -> [WorldKit.TextJob] {
        CardData.loadFromBundle().tags.prefix(3).map { WorldKit.textJob($0, color: d.highlightColor, fontSize: 176, size: CGSize(width: 2048, height: 512)) }
    }

    init(descriptor: WorldDescriptor) {
        self.descriptor = descriptor
        comet = ModelEntity(mesh: .generateBox(width: 3, height: 0.03, depth: 0.03), materials: [WorldKit.emissive(descriptor.highlightColor, intensity: 6, opacity: 0.8)])
        root.addChild(galaxy)
        galaxy.addChild(comet)
        comet.addChild(cometTail)
        comet.isEnabled = false
    }

    // MARK: Star material and instance layout

    /// Emissive star: PBR with a star disc in both base colour and emission (the `ProjectorRig` way). An unlit
    /// glow peaks at 1.0 and never crosses the bloom threshold — these have to actually glow, so they are lit.
    /// `instanced` picks the un-mipmapped sprite, which the instanced fields need (see `starSpriteTexture`).
    private static func starMaterial(_ color: UIColor, intensity: Float = 3.5, spikes: Bool = false) -> PhysicallyBasedMaterial {
        var m = PhysicallyBasedMaterial()
        let disc = spikes ? WorldKit.starSpikeTexture(color) : WorldKit.starSpriteTexture(color)
        m.baseColor = .init(tint: color, texture: .init(disc))
        m.emissiveColor = .init(color: color, texture: .init(disc))
        m.emissiveIntensity = intensity
        // Fully rough and non-specular: the default gloss adds a constant IBL highlight across the whole quad
        // that the sprite's alpha does not cut, which shows up as a faint grey box around the biggest stars.
        m.roughness = .init(floatLiteral: 1)
        m.specular = .init(floatLiteral: 0)
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        m.opacityThreshold = nil
        m.faceCulling = .none
        m.writesDepth = false
        return m
    }

    /// Where global star `i` lives: `(bucket, slot)` for the 1 : 2 : 1 warm / white / cool pattern.
    private static func slot(_ i: Int) -> (bucket: Int, index: Int) {
        let group = i / 4
        switch i % 4 {
        case 0: return (0, group)
        case 2: return (2, group)
        case 1: return (1, group * 2)
        default: return (1, group * 2 + 1)
        }
    }

    /// Capacity bucket `b` needs to hold its share of `pool` stars.
    private static func capacity(_ b: Int, pool: Int) -> Int {
        let groups = (pool + 3) / 4
        return b == 1 ? groups * 2 : groups
    }

    /// Open all three instance buffers at once, so one pass over the global star indices can write every bucket.
    private func withBuckets(_ body: (UnsafeMutableBufferPointer<simd_float4x4>, UnsafeMutableBufferPointer<simd_float4x4>, UnsafeMutableBufferPointer<simd_float4x4>) -> Void) {
        guard buckets.count == 3 else { return }
        buckets[0].data.withMutableTransforms { warm in
            buckets[1].data.withMutableTransforms { white in
                buckets[2].data.withMutableTransforms { cool in body(warm, white, cool) }
            }
        }
    }

    private func setStarsEnabled(_ on: Bool) {
        for b in buckets { b.entity.isEnabled = on }
    }

    /// Fade a named star. `PulseSystem` rewrites its `OpacityComponent` every frame from the pulse's own base, so
    /// an opacity set here would last one tick — the fade has to move the base (and gate `isEnabled` at zero, or
    /// three bright stars hang in the black through the lights-out beat).
    private func setNamedOpacity(_ i: Int, _ value: Float) {
        guard i < named.count else { return }
        let v = max(0, min(1, value))
        named[i].isEnabled = v > 0.001
        guard var pulse = named[i].components[PulseComponent.self] else { return }
        pulse.baseOpacity = v
        pulse.opacityAmplitude = 0.2 * v
        named[i].components.set(pulse)
    }

    /// Rotation that turns a quad (normal +Z) toward the galaxy's centre, where the frozen head sits.
    private static func facing(_ p: SIMD3<Float>) -> simd_quatf {
        let toHead = -p
        let len = simd_length(toHead)
        guard len > 1e-4 else { return simd_quatf(angle: 0, axis: [0, 1, 0]) }
        let d = toHead / len
        // `simd_quatf(from:to:)` is undefined for exactly opposite vectors; a star straight along +Z is the case.
        if d.z < -0.9999 { return simd_quatf(angle: .pi, axis: [0, 1, 0]) }
        return simd_quatf(from: [0, 0, 1], to: d)
    }

    // MARK: Build

    /// The galactic disc, one colour temperature at a time: instanced quads, sizes from distance, every one facing the
    /// reader. One colour temperature's instanced quads, every instance parked at zero scale (spares stay so until a fountain).
    /// **v4 B5 §5**: the active stars are no longer written at the card here — the buckets stay switched off until the
    /// burst, and the burst's own `writeStars` lays them out on the frame it switches them on, so that pass of 4 000–5 000
    /// transforms bought nothing.
    private func buildStarBucket(_ b: Int) {
        if b == 0 { buckets.removeAll() }
        let bucket = DataNebulaWorld.bucketTints[b]
        let quad = MeshResource.generatePlane(width: 1, height: 1)
        let bounds = BoundingBox(min: [-14, -8, -14], max: [14, 8, 14])
        guard let data = try? LowLevelInstanceData(instanceCount: DataNebulaWorld.capacity(b, pool: poolCount)) else { return }
        let e = ModelEntity(mesh: quad, materials: [DataNebulaWorld.starMaterial(UIColor(hex: bucket.hex), intensity: bucket.emissive)])
        if let comp = try? MeshInstancesComponent(mesh: quad, instances: data, bounds: bounds) {
            e.components.set(comp)
        }
        e.components.set(BloomComponent(scope: .hierarchical))
        e.isEnabled = false
        galaxy.addChild(e)
        data.withMutableTransforms { buffer in
            let zero = simd_float4x4(diagonal: [0, 0, 0, 1])
            for i in 0..<buffer.count { buffer[i] = zero }
        }
        buckets.append(Bucket(entity: e, data: data))
    }

    /// 800 faint stars at 18–26 m, written once: the near disc is thin, so without this the sky between the arms
    /// is empty and the world reads as "dots around me" instead of "深空".
    private func buildFarLayer(head: SIMD3<Float>) {
        let n = DataNebulaWorld.farCount
        guard let data = try? LowLevelInstanceData(instanceCount: n) else { return }
        var rng = WorldKit.RNG(0x7E1A)
        farTransforms.removeAll(keepingCapacity: true)
        farTransforms.reserveCapacity(n)
        for _ in 0..<n {
            let r = rng.range(18, 26)
            let theta = rng.range(0, 2 * .pi)
            // Whole sphere, pulled gently toward the galactic plane (c·c² squashes toward the equator).
            let c = rng.range(-1, 1)
            let cosPhi = c * (0.5 + 0.5 * c * c)
            let sinPhi = sqrt(max(0, 1 - cosPhi * cosPhi))
            let p = SIMD3<Float>(r * sinPhi * cos(theta), r * cosPhi, r * sinPhi * sin(theta))
            let s = r * DataNebulaWorld.farAngle * 2 * exp(0.3 * rng.gaussian())
            var m = simd_float4x4(DataNebulaWorld.facing(p))
            m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
            m.columns.3 = SIMD4<Float>(p, 1)
            farTransforms.append(m)
        }
        data.withMutableTransforms { t in
            for i in 0..<min(t.count, farTransforms.count) { t[i] = farTransforms[i] }
        }
        let quad = MeshResource.generatePlane(width: 1, height: 1)
        let e = ModelEntity(mesh: quad, materials: [DataNebulaWorld.starMaterial(UIColor(hex: "#DFE4FF"), intensity: 2.6)])
        if let comp = try? MeshInstancesComponent(mesh: quad, instances: data, bounds: BoundingBox(min: [-27, -27, -27], max: [27, 27, 27])) {
            e.components.set(comp)
        }
        e.components.set(BloomComponent(scope: .hierarchical))
        e.position = head
        e.components.set(OpacityComponent(opacity: 0))
        root.addChild(e)
        far = e
        farData = data
    }

    /// The Milky Way: one band around the disc at 27 m, just outside the far layer and just inside the sky. It is
    /// a cylinder band, not a flat ring — a ring would contain the reader's eye and project to a hard line across
    /// the sky. It lies in the star disc's own plane (a band at a different angle from the stars reads as a second,
    /// unrelated galaxy), tilted only enough to keep it off dead level; the hero shot rolls it with the stars.
    private func buildBand() {
        let ring = ModelEntity(mesh: FXMeshes.cylinderBand(radius: 27, yMin: -5.5, yMax: 5.5, segments: 64),
                               materials: [FXMaterials.glow(WorldKit.milkyWayTexture(), tint: UIColor(hex: "#C4D0FF"), opacity: 0.05)])
        ring.position = [0, 0.2, 0]
        ring.orientation = simd_quatf(angle: DataNebulaWorld.bandTilt, axis: [1, 0, 0])
        ring.components.set(OpacityComponent(opacity: 0))
        galaxy.addChild(ring)
        band = ring
    }

    /// The band's stars: 1 500 tiny ones packed along the band's plane between the near disc and the far layer,
    /// with a gaussian scatter about it so the edges are soft. This — not the haze — is what makes the Milky Way
    /// read as a galaxy seen edge-on, and it puts the band inside the disc instead of behind it.
    private func buildBandStars() {
        let n = DataNebulaWorld.bandStarCount
        guard let data = try? LowLevelInstanceData(instanceCount: n) else { return }
        var rng = WorldKit.RNG(0x2B4D)
        let tilt = simd_quatf(angle: DataNebulaWorld.bandTilt, axis: [1, 0, 0])
        bandTransforms.removeAll(keepingCapacity: true)
        bandTransforms.reserveCapacity(n)
        for _ in 0..<n {
            let r = rng.range(15, 27)
            let theta = rng.range(0, 2 * .pi)
            let p = tilt.act(SIMD3<Float>(cos(theta) * r, rng.gaussian() * 2.2, sin(theta) * r)) + [0, 0.2, 0]
            let s = simd_length(p) * (0.06 + 0.04 * rng.next()) * (.pi / 180) * 2
            var m = simd_float4x4(DataNebulaWorld.facing(p))
            m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
            m.columns.3 = SIMD4<Float>(p, 1)
            bandTransforms.append(m)
        }
        let quad = MeshResource.generatePlane(width: 1, height: 1)
        let e = ModelEntity(mesh: quad, materials: [DataNebulaWorld.starMaterial(UIColor(hex: "#D6DEFF"), intensity: 2.8)])
        if let comp = try? MeshInstancesComponent(mesh: quad, instances: data, bounds: BoundingBox(min: [-28, -28, -28], max: [28, 28, 28])) {
            e.components.set(comp)
        }
        e.components.set(BloomComponent(scope: .hierarchical))
        e.components.set(OpacityComponent(opacity: 0))
        galaxy.addChild(e)
        bandStars = e
        bandData = data
        writeBandStars(count: n)
    }

    /// Band-star transforms for a tier (one write, never per frame): the dropped tail is parked at zero scale.
    private func writeBandStars(count: Int) {
        guard let bandData, !bandTransforms.isEmpty else { return }
        bandData.instanceCount = bandTransforms.count
        bandData.withMutableTransforms { buf in
            let zero = simd_float4x4(diagonal: [0, 0, 0, 1])
            for i in 0..<min(buf.count, bandTransforms.count) { buf[i] = i < count ? bandTransforms[i] : zero }
        }
        bandData.instanceCount = max(1, count)
    }

    /// The diffraction sprites of the hero stars: one instanced quad each, parked at the star's destination. They
    /// only exist once the stars have landed, so nothing has to be rewritten while the field is in flight.
    private func buildHeroSpikes() {
        guard !heroIndices.isEmpty, let data = try? LowLevelInstanceData(instanceCount: heroIndices.count) else { return }
        data.withMutableTransforms { t in
            for (k, i) in heroIndices.enumerated() where k < t.count {
                let s = sizes[i] * 3.2          // the spikes reach well past the star's own disc
                var m = simd_float4x4(facings[i])
                m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
                m.columns.3 = SIMD4<Float>(targets[i], 1)
                t[k] = m
            }
        }
        let quad = MeshResource.generatePlane(width: 1, height: 1)
        let e = ModelEntity(mesh: quad, materials: [DataNebulaWorld.starMaterial(UIColor(hex: "#E8EEFF"), intensity: 3.8, spikes: true)])
        if let comp = try? MeshInstancesComponent(mesh: quad, instances: data, bounds: BoundingBox(min: [-16, -10, -16], max: [16, 10, 16])) {
            e.components.set(comp)
        }
        e.components.set(BloomComponent(scope: .hierarchical))
        e.components.set(OpacityComponent(opacity: 0))
        galaxy.addChild(e)
        heroSpikes = e
    }

    /// Moon 25 m out: a moon-textured sphere (Poly Haven moon_01, 2k) with a thin dust ring.
    private func buildPlanet(ctx: WorldContext, engine: WorldEngine) {
        planet.children.forEach { $0.removeFromParent() }
        var mat = PhysicallyBasedMaterial()
        let diffuse = engine.assets.texture(world: descriptor.id, name: "moon_01_Diffuse_2k")
        mat.baseColor = .init(tint: UIColor(hex: "#C6C0D6"), texture: diffuse.map { .init($0) })
        if let n = engine.assets.texture(world: descriptor.id, name: "moon_01_nor_gl_2k") { mat.normal = .init(texture: .init(n)) }
        // No emissive. Lighting it through its own texture gave a flat, evenly bright ball with no terminator —
        // the "grey disc" read. `starLight` alone shapes it, so it hangs as a crescent with a dark limb.
        mat.roughness = .init(floatLiteral: 0.92)
        mat.specular = .init(floatLiteral: 0.04)
        let body = ModelEntity(mesh: .generateSphere(radius: DataNebulaWorld.moonRadius), materials: [mat])
        body.components.set(SpinComponent(axis: [0.2, 1, 0.1], radiansPerSecond: 0.01))
        planet.addChild(body)
        // Up and well to the right of the constellation, and small: 3.6 m across at 25 m is about 8°.
        let at = DataNebulaWorld.moonAt
        planet.position = ctx.origin + ctx.forward * at.x + ctx.right * at.y + [0, at.z, 0]
        planet.components.set(OpacityComponent(opacity: 0))
        root.addChild(planet)
    }

    /// Low-saturation magenta / teal / blue, and narrower than before: wide flat panels read as smeared light, not gas.
    static let nebulaSpecs: [(center: SIMD3<Float>, tint: String, size: Float)] = [
        ([-15, 3.5, -14], "#9E5FA8", 10),
        ([17, 2, 11], "#4E93A0", 9),
        ([4, -4.5, 20], "#5A72B8", 9),
    ]
    /// The gas clouds' RNG, drawn cloud after cloud (v4 B5 §5: one cloud a build step, in the same order).
    private var nebulaRNG = WorldKit.RNG(0x4EB)

    /// One of three gas clouds of four billboarded noise quads each (12 alpha quads in all), in the disc's frame: the
    /// layers drift against each other, and that parallax is what gives a flat quad volume. The first clears what an
    /// earlier build left and restarts the RNG.
    private func buildNebula(_ cloud: Int) {
        if cloud == 0 {
            for n in nebulae { n.removeFromParent() }
            nebulae.removeAll()
            nebulaRNG = WorldKit.RNG(0x4EB)
        }
        let tex = WorldKit.nebulaTexture()
        let spec = DataNebulaWorld.nebulaSpecs[cloud]
        let center = spec.center, tint = UIColor(hex: spec.tint), size = spec.size
        var rng = nebulaRNG
        do {
            let body = Entity()
            for k in 0..<4 {
                let disc = ModelEntity(mesh: .generatePlane(width: size * rng.range(0.8, 1.3), height: size * rng.range(0.6, 1.0)),
                                       materials: [FXMaterials.glow(tex, tint: tint, opacity: 0.14)])
                disc.position = [rng.range(-size * 0.3, size * 0.3), rng.range(-size * 0.2, size * 0.2), rng.range(-2.5, 2.5)]
                disc.components.set(BillboardComponent())
                disc.components.set(FloatComponent(basePosition: disc.position, axis: simd_normalize(SIMD3<Float>(rng.range(-1, 1), rng.range(-0.3, 0.3), rng.range(-1, 1))), amplitude: 0.6, period: 20 + Float(k) * 4, phase: Float(k)))
                body.addChild(disc)
            }
            body.position = center
            body.components.set(OpacityComponent(opacity: 0))
            galaxy.addChild(body)
            nebulae.append(body)
        }
        nebulaRNG = rng
    }

    /// Kenney meteors / crystals / station pieces: rock and dark metal skins (the crystals keep a violet glow).
    /// Which piece takes which skin is resolved once here, so fading them later is a material swap over a known
    /// list instead of a name match per frame.
    private func skinAssets() {
        guard let assets = artLayer ?? root.findEntity(named: "assets") else { return }
        artPieces = assets.children.filter { $0.name != "fog" }.map { child in
            let name = child.name.lowercased()
            let skin: ArtSkin = name.contains("crystal") ? .crystal : (name.contains("meteor") || name.contains("crater") ? .rock : .metal)
            return (child, skin)
        }
        artAlpha = 1
        applyArtSkins(alpha: 1)
    }

    /// One prop skin at `alpha`. Below 1 the material is transparent **and still writes depth** — that is the
    /// whole reason the art layer fades through its materials instead of an `OpacityComponent` (`setArtOpacity`).
    private static func artSkin(_ kind: ArtSkin, primary: UIColor, alpha: Float) -> PhysicallyBasedMaterial {
        // Lit by `starLight` and floored with a faint cool self-glow: inside the shell the IBL is near black, and
        // an unlit prop is a pure black cut-out — a blob, not an object catching starlight.
        var m = PhysicallyBasedMaterial()
        switch kind {
        case .rock:
            m.baseColor = .init(tint: UIColor(hex: "#7C7690"), texture: nil)
            m.emissiveColor = .init(color: UIColor(hex: "#3A4776"))
            m.emissiveIntensity = 0.34
            m.roughness = .init(floatLiteral: 0.9)
        case .crystal:
            m.baseColor = .init(tint: primary, texture: nil)
            m.emissiveColor = .init(color: primary)
            m.emissiveIntensity = 0.5
            m.roughness = .init(floatLiteral: 0.25)
        case .metal:
            m.baseColor = .init(tint: UIColor(hex: "#5C6480"), texture: nil)
            m.emissiveColor = .init(color: UIColor(hex: "#36406A"))
            m.emissiveIntensity = 0.42
            m.metallic = .init(floatLiteral: 0.7)
            m.roughness = .init(floatLiteral: 0.45)
        }
        if alpha < 1 {
            m.blending = .transparent(opacity: .init(floatLiteral: alpha))
            m.opacityThreshold = nil
            m.writesDepth = true
        }
        return m
    }

    private func applyArtSkins(alpha: Float) {
        var cache: [ArtSkin: PhysicallyBasedMaterial] = [:]
        func visit(_ e: Entity, _ m: PhysicallyBasedMaterial) {
            if let model = e as? ModelEntity, let count = model.model?.materials.count { model.model?.materials = Array(repeating: m, count: max(1, count)) }
            for c in e.children { visit(c, m) }
        }
        for (entity, skin) in artPieces {
            let m = cache[skin] ?? DataNebulaWorld.artSkin(skin, primary: descriptor.primaryColor, alpha: alpha)
            cache[skin] = m
            visit(entity, m)
        }
    }

    /// Fade the meteors and station pieces in or out **without leaving the depth-writing path**.
    ///
    /// An `OpacityComponent` moves a whole subtree into the translucent pass, where it stops writing depth. The
    /// star layers are pinned into `WorldEngine.sortGroup`, so against *ungrouped* transparent geometry their
    /// order is the group's, not the distance sort: while the props are opaque the depth buffer decides and the
    /// picture is right, but the moment the entry / exit fade made them translucent the whole field was drawn
    /// over them — stars 20 m behind a prop at full strength on top of it, and the order even flips between
    /// inside and the exit. Fading the *materials* keeps `writesDepth = true`, so a half-faded prop still rejects
    /// what is behind it. The fog bands are transparent either way, so they keep the cheap subtree fade.
    ///
    /// The alpha is quantised to 1/12: a fade costs at most twelve material swaps, not one per frame.
    private func setArtOpacity(_ value: Float) {
        let v = max(0, min(1, value))
        artLayer?.isEnabled = v > 0.002
        // The haze keeps the subtree fade, and like the planet it drops the component once it is fully in: an
        // OpacityComponent left at 1.0 would keep the bands on the translucent path for nothing.
        if v >= 1 { fogLayer?.components.remove(OpacityComponent.self) } else { fogLayer?.components.set(OpacityComponent(opacity: v)) }
        guard v > 0.002 else { return }
        let q = v >= 1 ? 1 : (v * 12).rounded() / 12
        guard abs(q - artAlpha) > 0.001 else { return }
        artAlpha = q
        applyArtSkins(alpha: q)
    }

    func build(ctx: WorldContext, engine: WorldEngine) {
        for step in buildSteps(ctx: ctx, engine: engine) { step.run() }
    }

    /// **v4 B5 §5 — the build in steps.** The desk's prebuild was one 79–239 ms block on the headset (`world.build`,
    /// round 3's `frame hitch 194 / 236 ms`). Each step here is one part of the galaxy, built off the scene; the engine
    /// runs as many as fit in a few milliseconds per frame (`WorldBuildJob`), and the live build at an entry runs them
    /// all at once, exactly as before. The order is the old `build`'s.
    func buildSteps(ctx: WorldContext, engine: WorldEngine) -> [WorldBuildStep] {
        // The pool's destinations in chunks (the loop is 6 000–7 000 stars of maths and RNG), one bucket of stars a step,
        // one named star a step, one gas cloud a step: each step a few milliseconds, in the old order.
        var steps = [WorldBuildStep("targets: counts") { [self] in self.beginTargets(ctx: ctx) }]
        for chunk in 0..<DataNebulaWorld.targetChunks {
            steps.append(WorldBuildStep("targets \(chunk + 1)/\(DataNebulaWorld.targetChunks)") { [self] in
                self.buildTargetChunk(chunk)
            })
        }
        steps.append(WorldBuildStep("targets: hero stars") { [self] in self.finishTargets() })
        for bucket in 0..<DataNebulaWorld.bucketTints.count {
            steps.append(WorldBuildStep("stars: bucket \(bucket + 1)") { [self] in self.buildStarBucket(bucket) })
        }
        steps += [
            WorldBuildStep("far layer") { self.buildFarLayer(head: ctx.headPosition) },
            WorldBuildStep("band") { self.buildBand() },
            WorldBuildStep("band stars") { self.buildBandStars() },
            WorldBuildStep("hero spikes") { self.buildHeroSpikes() },
            WorldBuildStep("star light") { self.buildStarLight(ctx: ctx) },
        ]
        for i in 0..<3 {
            steps.append(WorldBuildStep("named star \(i + 1)") { [self] in self.buildNamedStar(i, ctx: ctx) })
        }
        steps += [
            WorldBuildStep("constellation lines") { self.buildConstellationLines() },
            WorldBuildStep("dust, comet") { self.buildDustComet(ctx: ctx) },
            WorldBuildStep("halos, charge") { self.buildHalosCharge() },
            WorldBuildStep("sky dome") { self.buildDome(ctx: ctx, engine: engine) },
            WorldBuildStep("title, moon") {
                self.buildTitle(ctx: ctx, engine: engine)
                self.buildPlanet(ctx: ctx, engine: engine)
            },
        ]
        for cloud in 0..<DataNebulaWorld.nebulaSpecs.count {
            steps.append(WorldBuildStep("nebula \(cloud + 1)") { [self] in self.buildNebula(cloud) })
        }
        steps.append(WorldBuildStep("art skins") { self.buildArtSkins() })
        return steps
    }

    /// How many steps the pool's destinations take (v4 B5 §5).
    static let targetChunks = 4

    /// Every star's destination, size, facing and delay (the whole pool, spares included), and the hero stars, in
    /// `targetChunks` pieces: the counts, the chunks of the pool (the RNG drawn in the same order as one loop), the heroes.
    private func beginTargets(ctx: WorldContext) {
        cardPos = ctx.cardPosition
        let head = ctx.headPosition
        cameraHead = head
        heroAxis = ctx.forward
        galaxy.position = head
        let rules = descriptor.statsRules
        starCount = max(rules.starsMin, min(rules.starsMax, ctx.stats.followers))
        poolCount = min(rules.starsMax, starCount + 2000)
        activeCount = starCount
        // Disc destinations for the whole pool, relative to the head (spares get theirs too).
        targets.reserveCapacity(poolCount); sizes.reserveCapacity(poolCount); delays.reserveCapacity(poolCount); facings.reserveCapacity(poolCount)
    }

    private func buildTargetChunk(_ chunk: Int) {
        let per = (poolCount + DataNebulaWorld.targetChunks - 1) / DataNebulaWorld.targetChunks
        let range = min(poolCount, chunk * per)..<min(poolCount, (chunk + 1) * per)
        for i in range {
            let t = Float(i % max(1, starCount)) / Float(max(1, starCount))
            let arm = Float(i % 3) * (2 * .pi / 3)
            let radius = 2.5 + 9.5 * pow(rng.next(), 0.7)
            let p: SIMD3<Float>
            if rng.next() < 0.08 {
                // Core bulge: the galaxy's bright, nearly spherical middle at 2.5–4 m, seen from just outside it.
                let br = rng.range(2.5, 4)
                let theta = rng.range(0, 2 * .pi)
                let cosPhi = rng.range(-1, 1)
                let sinPhi = sqrt(max(0, 1 - cosPhi * cosPhi))
                p = [br * sinPhi * cos(theta), 0.2 + br * cosPhi * 0.55, br * sinPhi * sin(theta)]
            } else {
                // A disc, not a slab: the scatter about the plane grows with radius and has no hard edge.
                let angle = arm + radius * 0.55 + rng.range(-0.5, 0.5)
                let y = 0.2 + rng.gaussian() * 0.35 * (0.5 + radius / 12)
                p = [cos(angle) * radius, y, sin(angle) * radius]
            }
            targets.append(p)
            facings.append(DataNebulaWorld.facing(p))
            // Angular size, so a far star is small and a near one is big; 2 % are giants.
            let ang = DataNebulaWorld.medianAngle * exp(0.45 * rng.gaussian())
            let size = simd_length(p) * ang * 2 * (rng.next() < 0.02 ? 2.5 : 1)
            sizes.append(size)
            delays.append(t * 0.5 * rng.next())
        }
    }

    private func finishTargets() {
        // Hero stars: a few dozen blown up to 0.35–0.6° so the field has something to look at. They are ordinary
        // members of the three buckets, so they keep their colour temperature and cost no extra draw.
        heroIndices.removeAll()
        var heroRNG = WorldKit.RNG(0x11E5)
        var tries = 0
        while heroIndices.count < DataNebulaWorld.heroCount && tries < DataNebulaWorld.heroCount * 40 {
            tries += 1
            let i = Int(heroRNG.next() * Float(max(1, starCount)))
            if i < starCount && !heroIndices.contains(i) { heroIndices.append(i) }
        }
        for (k, i) in heroIndices.enumerated() {
            let ang = (0.35 + 0.25 * heroRNG.next()) * .pi / 180
            // The first three sit nearest the reader, so one is always big in the corner of the eye.
            sizes[i] = simd_length(targets[i]) * ang * 2 * (k < 3 ? 1.6 : 1)
        }
    }

    /// The light that carves the moon (and the tally line for the log).
    private func buildStarLight(ctx: WorldContext) {
        let head = ctx.headPosition
        // One cool directional light. It carves the moon into a crescent and keeps the props from being black
        // cut-outs; inside the shell there is nothing else to light them but the near-black IBL.
        starLight.components.set(DirectionalLightComponent(color: UIColor(hex: "#BCD0FF"), intensity: 3400))
        // Across the scene from the left and slightly down. Aiming it back along the moon's own bearing does give
        // a geometric crescent, but the lit rim comes out too dim to read (raising the intensity from 3 400 to
        // 9 000 lux barely moved it — at 25 m the analytic light has little authority over the moon next to the
        // IBL), and it costs the props their rim. This direction keeps a soft terminator on the moon and gives
        // the three props an edge to catch.
        starLight.orientation = simd_quatf(from: [0, 0, -1], to: simd_normalize(ctx.right * 0.85 - SIMD3<Float>(0, 0.45, 0)))
        starLight.position = head
        root.addChild(starLight)
        print("[world] data-nebula: \(starCount) stars for \(ctx.stats.followers) followers (pool \(poolCount), 3 buckets + \(DataNebulaWorld.farCount) far)")
    }

    /// Named star `i`: one of the three tags, placed ahead-left / ahead / ahead-right at 4 m, with a legible label.
    private func buildNamedStar(_ i: Int, ctx: WorldContext) {
        if i == 0 {
            named.removeAll()
            labels.removeAll()
        }
        let f = ctx.forward, r = ctx.right
        let tags = Array(CardData.loadFromBundle().tags.prefix(3))
        guard tags.indices.contains(i) else { return }
        let tag = tags[i]
        do {
            let pos = f * 4 + r * (Float(i) - 1) * 1.6 + [0, 0.15 + Float(i % 2) * 0.5, 0]
            let star = ModelEntity(mesh: .generatePlane(width: 0.26, height: 0.26), materials: [DataNebulaWorld.starMaterial(UIColor(hex: "#FFF0DC"), intensity: 4, spikes: true)])
            star.position = pos
            star.components.set(BillboardComponent())
            star.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.15, baseOpacity: 0, opacityAmplitude: 0, period: 2.4 + Float(i) * 0.4, phase: Float(i)))
            star.components.set(BloomComponent(scope: .hierarchical))
            star.isEnabled = false
            galaxy.addChild(star)
            named.append(star)
            let labelHolder = ModelEntity(mesh: .generatePlane(width: 1.6, height: 0.4),
                                          materials: [FXMaterials.glow(WorldKit.textTexture(tag, color: descriptor.highlightColor, fontSize: 176, size: CGSize(width: 2048, height: 512)), tint: .white, opacity: 1)])
            labelHolder.position = pos + [0, -0.36, 0]
            labelHolder.components.set(BillboardComponent())
            labelHolder.components.set(OpacityComponent(opacity: 0))
            // Soft dark backing so the glyphs stay legible over the star field.
            let backing = ModelEntity(mesh: .generatePlane(width: 2.0, height: 0.8), materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: UIColor(hex: "#0A0630"), opacity: 0.6)])
            backing.position = [0, 0, -0.01]
            labelHolder.addChild(backing)
            galaxy.addChild(labelHolder)
            labels.append(labelHolder)
        }
    }

    private func buildConstellationLines() {
        lines.removeAll()
        // Constellation lines between consecutive named stars (the box runs along +Z, aimed at the next star).
        // Thin and dim: they are a reading of the stars, not brighter than the stars themselves.
        for i in 0..<max(0, named.count - 1) {
            let a = named[i].position, b = named[i + 1].position
            let len = simd_length(b - a)
            let line = ModelEntity(mesh: .generateBox(width: 0.005, height: 0.005, depth: len), materials: [WorldKit.emissive(descriptor.secondaryColor, intensity: 1.6, opacity: 0.55)])
            line.position = (a + b) / 2
            line.orientation = simd_quatf(from: [0, 0, 1], to: simd_normalize(b - a))
            line.components.set(OpacityComponent(opacity: 0))
            galaxy.addChild(line)
            lines.append(line)
        }
    }

    /// The weightless dust and the comet with its tail.
    private func buildDustComet(ctx: WorldContext) {
        let head = ctx.headPosition
        let f = ctx.forward, r = ctx.right
        // Weightless dust.
        dust.position = head
        var d = ParticleEmitterComponent()
        d.emitterShape = .sphere
        d.emitterShapeSize = [2.5, 1.5, 2.5]
        d.birthLocation = .volume
        d.emissionDirection = [0, 1, 0]
        d.speed = 0.04; d.speedVariation = 0.03
        d.mainEmitter.image = FXTextures.shared.particle
        d.mainEmitter.blendMode = .additive
        d.mainEmitter.birthRate = 0
        d.mainEmitter.lifeSpan = 6
        d.mainEmitter.size = 0.005; d.mainEmitter.sizeVariation = 0.003
        d.mainEmitter.noiseStrength = 0.02
        d.mainEmitter.opacityCurve = .gradualFadeInOut
        d.mainEmitter.isLightingEnabled = false
        d.mainEmitter.color = .constant(.single(descriptor.highlightColor.withAlphaComponent(0.6)))
        d.isEmitting = false
        dust.components.set(d)
        root.addChild(dust)
        comet.position = f * 9 + r * -8 + [0, 3, 0]
        comet.orientation = simd_quatf(angle: atan2(r.x, r.z), axis: [0, 1, 0])
        // Comet tail: sparse additive motes trailing the streak.
        var tail = ParticleEmitterComponent()
        tail.emitterShape = .box
        tail.emitterShapeSize = [2.6, 0.05, 0.05]
        tail.birthLocation = .volume
        tail.speed = 0.3
        tail.mainEmitter.image = FXTextures.shared.particle
        tail.mainEmitter.blendMode = .additive
        tail.mainEmitter.birthRate = 140
        tail.mainEmitter.lifeSpan = 1.6
        tail.mainEmitter.size = 0.03
        tail.mainEmitter.sizeVariation = 0.02
        tail.mainEmitter.opacityCurve = .linearFadeOut
        tail.mainEmitter.isLightingEnabled = false
        tail.mainEmitter.color = .evolving(start: .single(descriptor.highlightColor.withAlphaComponent(0.8)), end: .single(descriptor.secondaryColor.withAlphaComponent(0)))
        cometTail.components.set(tail)
    }

    /// The halos behind the named stars, and the card's charge glow.
    private func buildHalosCharge() {
        // Halos behind the named stars (soft, dim, larger).
        for h in halos { h.removeFromParent() }
        halos.removeAll()
        for star in named {
            let halo = ModelEntity(mesh: .generatePlane(width: 0.54, height: 0.54), materials: [FXMaterials.glow(WorldKit.starHaloTexture(), tint: descriptor.accentColor, opacity: 0.16)])
            halo.position = star.position
            halo.components.set(BillboardComponent())
            halo.components.set(OpacityComponent(opacity: 0))
            galaxy.addChild(halo)
            halos.append(halo)
        }
        // Card charge: a core glow on the card that grows before the burst.
        let core = ModelEntity(mesh: .generatePlane(width: 0.12, height: 0.12), materials: [FXMaterials.glow(FXTextures.shared.coreDisc, tint: descriptor.highlightColor, opacity: 1)])
        core.position = cardPos + [0, 0.02, 0]
        core.components.set(BillboardComponent())
        core.components.set(BloomComponent(scope: .hierarchical))
        core.components.set(OpacityComponent(opacity: 0))
        core.isEnabled = false
        root.addChild(core)
        charge = core
    }

    /// The night sky: the world's own inward sphere just inside the shell.
    private func buildDome(ctx: WorldContext, engine: WorldEngine) {
        let head = ctx.headPosition
        // Night sky: the world's own inward sphere just inside the shell, faded with an OpacityComponent (drawn
        // after the shell and before the rest of the world while translucent; opaque and depth-writing once fully
        // in, so the flat shell is rejected behind it). Dense rings/segments: at 30 m a coarse sphere shows facets.
        let skyRadius = descriptor.environment?.skyRadius ?? 30
        if let sky = engine.assets.sky(for: descriptor.id) {
            let tint = descriptor.environment?.skyTint.map { UIColor(hex: $0) } ?? .white
            let sphere = ModelEntity(mesh: WorldKit.skySphere(radius: skyRadius - 4, rings: 48, segments: 128), materials: [WorldKit.skyMaterial(sky, tint: tint)])
            sphere.position = head
            sphere.orientation = ctx.yaw
            sphere.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.domeOrder))
            sphere.components.set(OpacityComponent(opacity: 0))
            sphere.isEnabled = false
            root.addChild(sphere)
            dome = sphere
        }
    }

    /// The title above the card.
    private func buildTitle(ctx: WorldContext, engine: WorldEngine) {
        let head = ctx.headPosition
        let f = ctx.forward
        // Title above the card: "4,313 位粉丝 · 每颗星是一位粉丝", fades in at 0.85.
        engine.title.followers = ctx.stats.followers
        engine.title.caption = "每颗星是一位粉丝"
        engine.titleHolder.position = head + f * 3 + [0, 1.1, 0]
        engine.titleHolder.scale = SIMD3(repeating: DataNebulaWorld.titleScale)
        engine.titleHolder.components.set(OpacityComponent(opacity: 0))
        engine.titleHolder.isEnabled = false
    }

    /// The meteors and station pieces: skinned, and hidden until the room has powered down.
    private func buildArtSkins() {
        // The meteors and station pieces belong to the dark: hidden until the room has powered down.
        artLayer = root.findEntity(named: "assets")
        fogLayer = artLayer?.findEntity(named: "fog")
        skinAssets()
        setArtOpacity(0)
    }


    private func setDust(_ rate: Float) {
        guard var d = dust.components[ParticleEmitterComponent.self] else { return }
        d.mainEmitter.birthRate = rate
        d.isEmitting = rate > 0
        dust.components.set(d)
    }

    /// Card position in the galaxy's local frame for the current disc rotation — the spin *and* the hero tilt, so
    /// a fountain or the exit still streams along the card's real direction after the galaxy has rolled over.
    private var localOrigin: SIMD3<Float> {
        galaxy.orientation.inverse.act(cardPos - galaxy.position)
    }

    /// Fountain path from the card (`origin`, galaxy-local) to a star's target: eased, bowed upward, facing the reader.
    private func starTransform(_ i: Int, progress k: Float, origin: SIMD3<Float>) -> simd_float4x4 {
        let e = 1 - pow(1 - k, 3)
        let p = simd_mix(origin, targets[i], SIMD3<Float>(repeating: e)) + SIMD3<Float>(0, sin(.pi * e) * 1.2, 0)
        let s = sizes[i] * (0.2 + 0.8 * e)
        var m = simd_float4x4(facings[i])
        m.columns.0 *= s; m.columns.1 *= s; m.columns.2 *= s
        m.columns.3 = SIMD4<Float>(p, 1)
        return m
    }

    /// `progress` 0 = all active stars at the card, 1 = at their destinations. Only the active range is written.
    private func writeStars(progress: Float) {
        let origin = localOrigin
        let n = activeCount
        withBuckets { warm, white, cool in
            for i in 0..<n {
                let k = max(0, min(1, (progress - delays[i]) / max(0.01, 1 - delays[i])))
                let m = starTransform(i, progress: k, origin: origin)
                let s = DataNebulaWorld.slot(i)
                switch s.bucket {
                case 0: if s.index < warm.count { warm[s.index] = m }
                case 1: if s.index < white.count { white[s.index] = m }
                default: if s.index < cool.count { cool[s.index] = m }
                }
            }
        }
    }

    /// Advance the celebration fountains (stars beyond `activeCount` at their start).
    private func updateFountains(dt: Float, engine: WorldEngine) {
        guard !fountains.isEmpty else { return }
        let origin = localOrigin
        withBuckets { warm, white, cool in
            for f in fountains.indices {
                fountains[f].elapsed += dt
                let range = fountains[f].range
                let count = max(1, range.count)
                for (j, i) in range.enumerated() {
                    // Stagger inside the fountain so it reads as a stream, not a clump.
                    let start = Float(j) / Float(count) * 0.5
                    let k = max(0, min(1, (fountains[f].elapsed / fountains[f].duration - start) / max(0.01, 1 - start)))
                    let m = starTransform(i, progress: k, origin: origin)
                    let s = DataNebulaWorld.slot(i)
                    switch s.bucket {
                    case 0: if s.index < warm.count { warm[s.index] = m }
                    case 1: if s.index < white.count { white[s.index] = m }
                    default: if s.index < cool.count { cool[s.index] = m }
                    }
                }
            }
        }
        for f in fountains.indices where !fountains[f].landed && fountains[f].elapsed >= fountains[f].duration {
            fountains[f].landed = true
            // The last star lands: the title rolls to the new count.
            engine.title.followers = fountains[f].followers
        }
        fountains.removeAll { $0.landed }
    }

    /// The galaxy carries the whole entry: no room fission (v2 — that is also what lets the tracker keep the
    /// sensors, since neither shipped world needs the real room any more).
    func fissionRecipe(ctx: WorldContext) -> RoomFission.Recipe? { nil }

    func applyQuality(_ t: WorldQuality) {
        tier = t
        setDustScale(t.density)
        // The far layer is the sky's depth and the puffs are its volume: medium halves the layer, low drops both.
        far?.isEnabled = t > .low
        applyFarTier(t)
        // The band's stars are the band, so they are thinned rather than dropped — losing them would leave the
        // Milky Way as a strip of haze, which is the thing this pass set out to fix.
        writeBandStars(count: t >= .high ? DataNebulaWorld.bandStarCount : DataNebulaWorld.bandStarCount / 2)
        for n in nebulae { n.isEnabled = t > .low }
        if var tail = cometTail.components[ParticleEmitterComponent.self] { tail.mainEmitter.birthRate = 140 * t.density; cometTail.components.set(tail) }
    }

    /// Instance count of the far layer by tier (one write, never per frame): the dropped half is parked at zero
    /// scale first, so a tier that comes back up can restore it from `farTransforms`.
    private func applyFarTier(_ t: WorldQuality) {
        guard let farData, !farTransforms.isEmpty else { return }
        let n = t >= .high ? farTransforms.count : farTransforms.count / 2
        farData.instanceCount = farTransforms.count
        farData.withMutableTransforms { buf in
            let zero = simd_float4x4(diagonal: [0, 0, 0, 1])
            for i in 0..<min(buf.count, farTransforms.count) { buf[i] = i < n ? farTransforms[i] : zero }
        }
        farData.instanceCount = n
    }

    private var dustScale: Float = 1
    private func setDustScale(_ k: Float) { dustScale = k }

    // MARK: Followers

    /// New count: remember how many stars are owed (idempotent, capped like a celebration). The fountain itself
    /// fires with the next `onCelebrate`, which always follows a follower gain from the hub / device.
    func onStats(_ stats: CardStats, engine: WorldEngine) {
        let rules = descriptor.statsRules
        let target = max(rules.starsMin, min(rules.starsMax, stats.followers))
        let extra = min(rules.celebrateCap, target - activeCount)
        if extra > 0 { pendingInject = max(pendingInject, extra) }
    }

    /// `min(delta, cap)` pooled stars fountain out of the card over 1.4 s, a ripple spreads on the desk, a chime
    /// sounds, and the title rolls when the stars land.
    func onCelebrate(delta: Int, stats: CardStats, engine: WorldEngine) {
        let rules = descriptor.statsRules
        let count = min(rules.celebrateCap, max(pendingInject, max(0, delta)))
        pendingInject = 0
        guard !buckets.isEmpty, count > 0, activeCount < poolCount else {
            engine.title.followers = stats.followers
            return
        }
        let range = activeCount..<min(poolCount, activeCount + count)
        activeCount = range.upperBound
        starCount = activeCount
        let origin = localOrigin
        withBuckets { warm, white, cool in
            for i in range {
                let m = starTransform(i, progress: 0, origin: origin)
                let s = DataNebulaWorld.slot(i)
                switch s.bucket {
                case 0: if s.index < warm.count { warm[s.index] = m }
                case 1: if s.index < white.count { white[s.index] = m }
                default: if s.index < cool.count { cool[s.index] = m }
                }
            }
        }
        fountains.append(Fountain(range: range, followers: stats.followers))
        FXAudio.shared.play(.chime, on: root)
        // Ripple at the card, in the world's colour.
        let ring = ModelEntity(mesh: .generatePlane(width: 0.34, depth: 0.34), materials: [FXMaterials.glow(FXTextures.shared.ring, tint: descriptor.secondaryColor, opacity: 1)])
        ring.position = cardPos + [0, 0.004, 0]
        ring.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.worldOrder))
        ring.components.set(RippleComponent(startScale: 0.1, endScale: 1.3, period: 0.9, peakOpacity: 0.85, repeats: false, removeWhenDone: true))
        root.addChild(ring)
        print("[world] data-nebula: +\(range.count) stars from the card (\(activeCount) active, +\(delta) followers)")
    }

    // MARK: Choreography

    func entry(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        // Power down: shell black by 0.25 (two quick dips then out — never a brighten).
        if p < 0.25 {
            let k = p / 0.25
            let dip: Float = k < 0.3 ? k / 0.3 * 0.6 : (k < 0.45 ? 0.3 : min(1, (k - 0.45) / 0.55))
            engine.shell.set(opacity: dip)
        } else {
            engine.shell.set(opacity: 1)
        }
        setDust(p > 0.25 && p < 0.9 ? 60 * dustScale : 0)
        // Card charge 0.25–0.38: the core glow grows 0.3 → 1.2 and hums, then hands its light to the burst.
        if p >= 0.25 && p < 0.5, let charge {
            if !chargePlayed {
                chargePlayed = true
                charge.isEnabled = true
                FXAudio.shared.play(.charge, on: root)
            }
            let k = max(0, min(1, (p - 0.25) / 0.13))
            let s = 0.3 + 0.9 * (1 - pow(1 - k, 2))
            charge.scale = SIMD3(repeating: s)
            let fade = p < 0.38 ? 1 : max(0, 1 - (p - 0.38) / 0.12)
            charge.components.set(OpacityComponent(opacity: min(1, k * 2) * fade))
            if fade <= 0 { charge.isEnabled = false }
        }
        // Planet, nebulae and halos fade in with the constellation (0.66–1.0).
        let late = max(0, min(1, (p - 0.66) / 0.34))
        // OpacityComponent keeps a subtree on the translucent path even at 1.0 (rings would show through the
        // planet), so drop it once the fade is done.
        if late >= 1 { planet.components.remove(OpacityComponent.self) } else { planet.components.set(OpacityComponent(opacity: late)) }
        setArtOpacity(max(0, min(1, (p - 0.45) / 0.35)))
        for n in nebulae { n.components.set(OpacityComponent(opacity: late * 0.9)) }
        for h in halos { h.components.set(OpacityComponent(opacity: late)) }
        band?.components.set(OpacityComponent(opacity: late))
        if p >= 0.38 {
            if !burstPlayed {
                burstPlayed = true
                setStarsEnabled(true)
                FXAudio.shared.play(.starBurst, on: root)
            }
            writeStars(progress: min(1, (p - 0.38) / 0.32))
        }
        if p >= 0.66 {
            let k = min(1, (p - 0.66) / 0.34)
            for i in named.indices { setNamedOpacity(i, k * 3 - Float(i) * 0.6) }
            for (i, l) in labels.enumerated() { l.components.set(OpacityComponent(opacity: max(0, min(1, k * 3 - Float(i) * 0.6 - 0.3)))) }
            for (i, l) in lines.enumerated() { l.components.set(OpacityComponent(opacity: max(0, min(1, k * 2 - Float(i) * 0.5 - 0.5)))) }
            // The night sky and the far layer rise behind everything (0.70–1.0); the sky then becomes the opaque limit.
            let d = max(0, min(1, (p - 0.7) / 0.3))
            far?.components.set(OpacityComponent(opacity: d))
            bandStars?.components.set(OpacityComponent(opacity: d))
            // The sparkle lands last, once the stars are home.
            heroSpikes?.components.set(OpacityComponent(opacity: max(0, min(1, (p - 0.78) / 0.22))))
            if let dome {
                dome.isEnabled = d > 0
                if d >= 1 { dome.components.remove(OpacityComponent.self) } else { dome.components.set(OpacityComponent(opacity: d)) }
            }
        }
        if p >= 0.85 && !titleShown {
            titleShown = true
            engine.titleHolder.isEnabled = true
            let s = DataNebulaWorld.titleScale
            engine.titleHolder.components.set(TweenComponent(scale: (from: [s * 0.8, s * 0.8, s * 0.8], to: [s, s, s]), opacity: (from: 0, to: 1), duration: 0.5, easing: .easeOutCubic))
        }
    }

    func inside(dt: Float, ctx: WorldContext, engine: WorldEngine) {
        if cometClock < -100 {
            // First frame inside: seed the take clock so the comet's first pass is the same every time.
            cometClock = -descriptor.takeTiming.cometFirst
        }
        time += dt
        heroClock += dt
        cometClock += dt
        engine.shell.set(opacity: 1)
        // The disc turns at 0.4°/s (accumulated, so the exit can undo it without a wrap), and the hero shot rolls
        // the whole galaxy over about the view direction: flat horizon → a tilted disc you are standing inside.
        spin += dt * 0.007
        let take = descriptor.takeTiming
        let hero = max(0, min(1, (heroClock - take.heroAt) / DataNebulaWorld.heroDuration))
        let eased = hero < 0.5 ? 2 * hero * hero : 1 - pow(-2 * hero + 2, 2) / 2
        let tilt = simd_quatf(angle: eased * take.heroTilt * .pi / 180, axis: heroAxis)
        galaxy.orientation = tilt * simd_quatf(angle: spin, axis: [0, 1, 0])
        updateFountains(dt: dt, engine: engine)
        let period = take.cometPeriod
        let cycle = cometClock >= 0 ? cometClock.truncatingRemainder(dividingBy: period) : -1
        if cycle >= 0 && cycle < DataNebulaWorld.cometPassSeconds {
            comet.isEnabled = true
            let k = cycle / DataNebulaWorld.cometPassSeconds
            // The comet flies in the frozen frame, so its path is undone by the galaxy's full rotation, not the spin alone.
            let local = galaxy.orientation.inverse
            comet.position = local.act(ctx.forward * 9 + ctx.right * (-8 + 16 * k) + [0, 3 - k * 1.5, 0])
            comet.orientation = local * simd_quatf(angle: atan2(ctx.right.x, ctx.right.z), axis: [0, 1, 0])
            comet.components.set(OpacityComponent(opacity: sin(k * .pi)))
        } else {
            comet.isEnabled = false
        }
    }

    func exit(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        // The stars stream back into the card (0–0.45) along the rotated disc (no snap) and stay lit the whole way;
        // lines / labels / title fade 0–0.2; the sky darkens to the black shell 0.45–0.65; the shell opens 0.55–1.
        let back = max(0, min(1, p / 0.45))
        if !fountains.isEmpty { fountains.removeAll() }
        writeStars(progress: 1 - back * back)
        let fade = max(0, 1 - p / 0.2)
        let mid = max(0, 1 - p / 0.45)
        planet.components.set(OpacityComponent(opacity: mid))
        setArtOpacity(mid)
        for n in nebulae { n.components.set(OpacityComponent(opacity: mid * 0.9)) }
        band?.components.set(OpacityComponent(opacity: mid))
        // The spikes belong to stars that are no longer there, so they go first.
        heroSpikes?.components.set(OpacityComponent(opacity: max(0, 1 - p / 0.25)))
        for h in halos { h.components.set(OpacityComponent(opacity: fade)) }
        for i in named.indices { setNamedOpacity(i, fade) }
        for l in labels { l.components.set(OpacityComponent(opacity: fade)) }
        for l in lines { l.components.set(OpacityComponent(opacity: fade)) }
        if engine.titleHolder.isEnabled {
            engine.titleHolder.components.set(OpacityComponent(opacity: fade))
            if fade <= 0 { engine.titleHolder.isEnabled = false }
        }
        comet.isEnabled = false
        if back >= 1 { setStarsEnabled(false) }
        if p >= 0.45 {
            if !dawnPlayed {
                dawnPlayed = true
                FXAudio.shared.play(.dawn, on: root)
            }
            // Night, not daybreak: the sky gives way to the shell it was already the colour of, so there is no
            // colour change to notice — the room comes back by the shell opening, not by the world turning amber.
            let d = max(0, 1 - (p - 0.45) / 0.2)
            far?.components.set(OpacityComponent(opacity: d))
            bandStars?.components.set(OpacityComponent(opacity: d))
            if let dome {
                dome.components.set(OpacityComponent(opacity: d))
                if d <= 0 { dome.isEnabled = false }
            }
            if d <= 0 { far?.isEnabled = false; bandStars?.isEnabled = false }
        }
        // One continuous opening, no plateau: ease-out so the room is already mostly back at 0.8, when the desk
        // hologram returns.
        if p >= 0.55 {
            let k = min(1, (p - 0.55) / 0.45)
            engine.shell.set(opacity: pow(1 - k, 3))
        } else {
            engine.shell.set(opacity: 1)
        }
    }

    func teardown() {
        setDust(0)
        fountains.removeAll()
    }
}
