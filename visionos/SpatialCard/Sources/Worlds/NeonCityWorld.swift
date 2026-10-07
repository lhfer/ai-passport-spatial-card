import Foundation
import RealityKit
import UIKit

/// W1 霓虹雨城: a vertical seam of light tears open above the card into a rain-soaked cyberpunk
/// rooftop; when the tear fills the view the city becomes the scene and the sky dome covers the
/// passthrough. Your card is a 9 × 12 m billboard on the tower ahead; your follower count is a split-flap
/// board under the tag signs on the building to the right.
///
/// Three depth layers: the wet rooftop you stand on (Poly Haven props from the descriptor, procedural tank /
/// mast / hut / puddles), the neighbouring rooftops 14–26 m out (Kenney low-poly towers under the fog, an
/// elevated metro to the left, the sign building to the right) and the far skyline (procedural lit towers,
/// the billboard tower, the airship, the Bund HDRI on the dome).
///
/// Entry (3.4 s, tear): 0.00–0.25 seam appears above the card · 0.25–0.62 seam widens to a tear (portal: city
/// visible inside, rain falls through) · 0.62–0.78 the tear races to fill the view while the shell closes
/// (ease-in cubic) · 0.78 switch: portal removed, world rendered directly · 0.82 billboard snaps on ·
/// 0.88 / 0.93 / 0.98 the signs strike with a ballast envelope and ascending chips.
/// Inside: the metro's first nose enters at 1.5 s and returns every 16 s (`take`), the airship drifts, the
/// ticker flips on every follower update, a celebration clatters the board and peaks the billboard bloom.
/// Exit (2.6 s, CRT collapse): city dims twice, rain freezes → black shutters close to the eye line with a bright
/// cyan seam → the line shrinks toward the card and pops (white disc at the card) → warm-up eases the black away.
@MainActor
final class NeonCityWorld: World {
    let descriptor: WorldDescriptor
    let root = Entity()
    private let city = Entity()            // carries WorldComponent during the portal phase
    private let portal: ModelEntity
    private let seamLeft: ModelEntity
    private let seamRight: ModelEntity
    private let rain = Entity()
    private var streaks: StreakField?
    private var billboard: ModelEntity?
    private var signs: [ModelEntity] = []
    private var signStrike: [Float?] = [nil, nil, nil]     // `time` at which each sign struck
    private var clouds: [ModelEntity] = []
    private let eyeLine: ModelEntity
    private var switched = false
    private var popped = false
    private var time: Float = 0
    private var rng = WorldKit.RNG(0x5EED)

    // Phase B set pieces.
    private var slab: ModelEntity?
    private var slabTextured = false
    private var puddles: [ModelEntity] = []
    private var train: NeonCityProps.Train?
    private var trainAnchor: SIMD3<Float> = .zero      // deck-top point on the track, at forward 0
    private var trainDeckY: Float = 0
    private var trainClock: Float = -1000              // seconds since the first nose entered (negative = not yet)
    private var airship: NeonCityProps.Airship?
    private var airshipPath: (from: SIMD3<Float>, to: SIMD3<Float>) = (.zero, .zero)
    private var airshipClock: Float = 0
    private var beacon: ModelEntity?
    private var crown: ModelEntity?
    private var outerRing: [ModelEntity] = []
    private var ticker: SplitFlapTicker?
    private var billboardBloom: Float = 0.7
    private var quality: WorldQuality = .high
    /// Entity writes the last `inside` tick made, and the worst seen since entry (the `[perf] … tier` line).
    private var writesThisTick = 0
    private var writesPeak = 0
    /// CPU spent in `inside` (the world's own per-frame work), summed and worst-case, for the tier line.
    private var tickSeconds: Double = 0
    private var tickWorst: Double = 0
    private var tickCount = 0
    /// Rain budget. The steady state of a box emitter is `birthRate × lifeSpan`, plus the splash each drop
    /// fires when it dies (`birthRate × splashBirth × splashLife`): 900 × 1.0 + 900 × 2 × 0.22 ≈ 1 296 alive at
    /// high, where it used to be 1 300 × 1.0 + 1 300 × 3 × 0.22 ≈ 2 158. The emitter box shrank with it
    /// (11 → 9 m), so the drops are *denser* per square metre than before; only the ones too far out to read
    /// are gone.
    private static let rainBirthRate: Float = 900
    private static let rainLifeSpan: Float = 1.0
    private static let rainSplashBirth: Float = 2
    private static let rainSplashLife: Float = 0.22
    private static let trainSpeed: Float = 15
    private static let trackLength: Float = 130
    private static let airshipLeg: Float = 110
    private static let billboardBloomBase: Float = 0.7
    private static let billboardBloomPeak: Float = 0.9

    /// **v4 B5 §5.** What `build` would make on the main thread, made ahead: the Bund dome's mesh.
    static func prewarm(_ d: WorldDescriptor) {
        WorldKit.prewarmSkySphere(radius: (d.environment?.skyRadius ?? 40) - 4)
        WorldKit.prewarmSkySphere(radius: 1, rings: NeonCityProps.Airship.hullRings, segments: NeonCityProps.Airship.hullSegments)   // the airship's hull
    }

    /// **v4 B5 §5.** The wet asphalt (the slab's textured material), warmed as soon as its three textures are in.
    static func warmMaterials(_ d: WorldDescriptor, assets: WorldAssetLibrary, in root: Entity) {
        assets.warmMaterial("\(d.id)/wet-asphalt", in: root) {
            guard let diffuse = assets.texture(world: d.id, name: NeonCityProps.asphaltDiffuse),
                  let normal = assets.texture(world: d.id, name: NeonCityProps.asphaltNormal),
                  let roughness = assets.texture(world: d.id, name: NeonCityProps.asphaltRoughness) else { return nil }
            return NeonCityProps.wetAsphalt(diffuse: diffuse, normal: normal, roughness: roughness)
        }
    }

    /// CoreText textures `build` needs, rendered in the background at space open.
    static func preheatJobs(_ d: WorldDescriptor) -> [WorldKit.TextJob] {
        let card = CardData.loadFromBundle()
        var jobs: [WorldKit.TextJob] = []
        let signColors = [d.primaryColor, d.secondaryColor, d.accentColor]
        for (i, tag) in card.tags.prefix(3).enumerated() { jobs.append(WorldKit.textJob(tag, color: signColors[i])) }
        jobs.append(WorldKit.textJob(card.name, color: d.secondaryColor, fontSize: 120))
        jobs.append(WorldKit.textJob("粉丝", color: d.accentColor, fontSize: 150))
        for digit in 0...9 { jobs.append(WorldKit.glyphJob(String(digit), color: d.highlightColor, size: 256)) }
        jobs.append(NeonCityProps.trainWindowsJob(accent: d.accentColor))
        // v4 B5 §5: the billboard (the theme bitmap, rounded) — rendered and uploaded ahead, not inside the build.
        jobs.append(NeonCityProps.billboardJob(themeBitmap: PassportManifest.shared.theme(forWorld: d.id).bitmap))
        return jobs
    }

    init(descriptor: WorldDescriptor) {
        self.descriptor = descriptor
        portal = ModelEntity(mesh: .generatePlane(width: 1, height: 1, cornerRadius: 0.02), materials: [PortalMaterial()])
        seamLeft = ModelEntity(mesh: .generatePlane(width: 0.012, height: 1), materials: [WorldKit.emissive(descriptor.highlightColor, intensity: 6)])
        seamRight = ModelEntity(mesh: .generatePlane(width: 0.012, height: 1), materials: [WorldKit.emissive(descriptor.highlightColor, intensity: 6)])
        eyeLine = ModelEntity(mesh: .generatePlane(width: 6, height: 0.02), materials: [WorldKit.emissive(descriptor.secondaryColor, intensity: 8)])
        eyeLine.isEnabled = false
        root.addChild(city)
        root.addChild(portal)
        root.addChild(seamLeft)
        root.addChild(seamRight)
        root.addChild(eyeLine)
        portal.isEnabled = false
        seamLeft.isEnabled = false
        seamRight.isEnabled = false
    }

    func build(ctx: WorldContext, engine: WorldEngine) {
        let buildStarted = Date()
        defer { print(String(format: "\(PerfLog.prefix) world neon-city build %.0f ms", Date().timeIntervalSince(buildStarted) * 1000)) }
        for step in buildSteps(ctx: ctx, engine: engine) { step.run() }
    }

    /// **v4 B5 §5 — the build in steps**, so the desk's prebuild can spread it over frames (`WorldBuildJob`) instead of
    /// holding one 100–240 ms frame (round 3: `world neon-city build 175 ms`, `frame hitch 194 ms`). The sections are the
    /// old `build`'s, in its order; a live build at an entry runs them all at once.
    func buildSteps(ctx: WorldContext, engine: WorldEngine) -> [WorldBuildStep] {
        let origin = ctx.origin, f = ctx.forward, r = ctx.right
        // The billboard tower straight ahead (30 m): the billboard, the follower board under it.
        let towerDist: Float = 30
        let card = CardData.loadFromBundle()
        // The sign building (right, 18 m ahead / 14 m right) and the face of it that looks at the rooftop.
        let signCenterH = origin + f * 18 + r * 14
        let toWearer = simd_normalize(origin - signCenterH)          // horizontal, building → wearer
        let faceYaw = simd_quatf(angle: atan2(toWearer.x, toWearer.z), axis: [0, 1, 0])   // plane +Z → toward the wearer
        let facade = signCenterH + toWearer * 5.6
        return [
            WorldBuildStep("rooftop: art layer") { [self] in
                city.components.set(WorldComponent())
                city.components.set(OpacityComponent(opacity: 1))
                // The descriptor's art layer joins the portal-rendered city so the rooftop props show through the tear too.
                root.findEntity(named: "assets")?.setParent(city, preservingWorldTransform: true)
            },
            WorldBuildStep("rooftop: slab") { [self] in
                // MARK: Rooftop — 16 m wet asphalt slab (Poly Haven asphalt_02, tiled 5×), parapet, puddles.
                let roof = ModelEntity(mesh: NeonCityProps.slabMesh(size: 16, tiles: 5), materials: [NeonCityProps.wetAsphaltPlaceholder()])
                roof.position = origin + [0, 0.002, 0]
                roof.orientation = ctx.yaw
                city.addChild(roof)
                slab = roof
            },
            WorldBuildStep("rooftop: asphalt") { [self] in
                applyRooftopTexturesIfReady(engine: engine)
            },
            WorldBuildStep("rooftop: parapet") { [self] in
                // Parapet (4 walls + 4 neon caps), the 7 railing posts and the 6 puddles are each one instanced draw:
                // 21 draws of a handful of boxes became 4. Every piece keeps its own size through its instance transform.
                let parapetMaterial = NeonCityProps.concrete("#3A3E50")
                var wallTransforms: [simd_float4x4] = [], capTransforms: [simd_float4x4] = []
                for (dx, dz, w, d) in [(0, -8, 16.3, 0.3), (0, 8, 16.3, 0.3), (-8, 0, 0.3, 16.3), (8, 0, 0.3, 16.3)] as [(Float, Float, Float, Float)] {
                    let at = r * dx + f * (-dz) + [0, 0.225, 0]
                    wallTransforms.append(NeonCityWorld.instance(ctx.yaw, scale: [w, 0.45, d], at: at))
                    capTransforms.append(NeonCityWorld.instance(ctx.yaw, scale: [w + 0.1, 0.03, d + 0.1], at: at + [0, 0.24, 0]))
                }
                city.addChild(NeonCityWorld.instanced(NeonCityProps.unitBox, material: parapetMaterial, at: origin, transforms: wallTransforms,
                                                      bounds: BoundingBox(min: [-9, -1, -9], max: [9, 2, 9])))
                city.addChild(NeonCityWorld.instanced(NeonCityProps.unitBox, material: WorldKit.emissive(descriptor.secondaryColor, intensity: 0.5, opacity: 0.3),
                                                      at: origin, transforms: capTransforms, bounds: BoundingBox(min: [-9, -1, -9], max: [9, 2, 9])))
            },
            WorldBuildStep("rooftop: puddles, railing") { [self] in
                var puddleTransforms: [simd_float4x4] = []
                for (i, (px, pz, s)) in ([(2.2, -1.6, 1.9), (-1.6, 2.4, 1.4), (4.6, 1.2, 2.6), (-3.4, -2.8, 1.7), (0.6, 4.4, 1.2), (-5.2, 3.2, 2.1)] as [(Float, Float, Float)]).enumerated() {
                    puddleTransforms.append(NeonCityWorld.instance(ctx.yaw * simd_quatf(angle: Float(i) * 0.9, axis: [0, 1, 0]),
                                                                   scale: [s, 1, s], at: f * pz + r * px + [0, 0.006, 0]))
                }
                let puddleField = NeonCityWorld.instanced(NeonCityProps.puddleMesh, material: NeonCityProps.puddleMaterial(), at: origin,
                                                          transforms: puddleTransforms, bounds: BoundingBox(min: [-8, -1, -8], max: [8, 1, 8]))
                city.addChild(puddleField)
                puddles.append(puddleField)
                // Railing ahead (0.9 m) — the "railing terminal" of the tear choreography.
                // No `cornerRadius`: RealityKit tessellates a rounded box into ~13 k triangles whatever its size, and a
                // 1 cm fillet on a 4 cm rail is invisible — this one bar cost more than every prop on the roof together.
                let rail = ModelEntity(mesh: .generateBox(width: 3.0, height: 0.04, depth: 0.04), materials: [WorldKit.unlit(UIColor(hex: "#262C48"))])
                rail.position = origin + f * 1.0 + [0, 1.02, 0]
                rail.orientation = ctx.yaw
                city.addChild(rail)
                let postTransforms = (-3...3).map { NeonCityWorld.instance(ctx.yaw, scale: [0.03, 1.0, 0.03], at: f * 1.0 + r * (Float($0) * 0.45) + [0, 0.5, 0]) }
                city.addChild(NeonCityWorld.instanced(NeonCityProps.unitBox, material: WorldKit.unlit(UIColor(hex: "#262C48")), at: origin,
                                                      transforms: postTransforms, bounds: BoundingBox(min: [-3, -1, -3], max: [3, 2, 3])))
            },
            // Rooftop furniture behind / beside the wearer: water tank, antenna mast, access hut (never ahead).
            WorldBuildStep("water tank") { [self] in
                let tank = NeonCityProps.waterTank()
                tank.position = origin + f * (-5.2) + r * (-6.2)
                tank.orientation = ctx.yaw * simd_quatf(angle: 0.4, axis: [0, 1, 0])
                city.addChild(tank)
            },
            WorldBuildStep("antenna mast") { [self] in
                let mast = NeonCityProps.antennaMast(height: 7)
                mast.root.position = origin + f * (-4.6) + r * 6.0
                mast.root.orientation = ctx.yaw
                city.addChild(mast.root)
                beacon = mast.beacon
            },
            WorldBuildStep("access hut") { [self] in
                let hut = NeonCityProps.accessHut(lampColor: descriptor.accentColor)
                hut.position = origin + f * (-5.6) + r * (-1.6)
                hut.orientation = ctx.yaw
                city.addChild(hut)
            },
            WorldBuildStep("skyline") { [self] in
                // MARK: Far skyline — two rings of lit towers (bases 25 m below, tops +3…+25 m so the skyline stays visible
                // above the Kenney blocks yet never rivals the billboard tower): 24 at 30–48 m and 26 hazier, broader ones at
                // 48–75 m that close the horizon. None straight ahead of the billboard, none straddling the metro track
                // (right = −11 m); each ring is dimmer than the last (atmospheric perspective).
                //
                // Instanced: the towers only differ by transform and by which of `WorldKit.windowSeeds` facade textures they
                // wear, so one draw per (ring, seed) — 8 instead of 50, and the material is opaque (a lit-window strip has no
                // alpha), which keeps the whole skyline out of the sorted transparent pass. The placement maths, the RNG
                // order and the seed → texture mapping are untouched, so every tower stands exactly where it did.
                var skyline: [[simd_float4x4]] = Array(repeating: [], count: 2 * WorldKit.windowSeeds)
                for (ring, count, near, far, hMin, hMax) in [(0, 24, Float(30), Float(48), Float(28), Float(40)),
                                                             (1, 26, Float(48), Float(75), Float(30), Float(50))] {
                    // One tower per angular slot (jittered) so the skyline closes evenly instead of leaving random gaps; a slot
                    // whose every candidate would straddle the track is simply left empty (the track runs there anyway).
                    let slot = 5.8 / Float(count)
                    for i in 0..<count {
                        for _ in 0..<8 {
                            let angle = -2.9 + (Float(i) + rng.range(0.1, 0.9)) * slot
                            let dist = abs(angle) < 0.24 ? rng.range(max(near, 36), far) : rng.range(near, far)
                            let w = rng.range(6, 12) * (ring == 0 ? 1 : 1.4), d = rng.range(6, 12) * (ring == 0 ? 1 : 1.4), h = rng.range(hMin, hMax)
                            if abs(dist * sin(angle) + 11) < max(w, d) / 2 + 2.5 { continue }
                            let dir = simd_normalize(f * cos(angle) + r * sin(angle))
                            let base = origin + dir * dist + [0, -25, 0]
                            var m = simd_float4x4(simd_quatf(angle: atan2(dir.x, dir.z) + rng.range(-0.2, 0.2), axis: [0, 1, 0]))
                            m.columns.0 *= w; m.columns.1 *= h; m.columns.2 *= d
                            m.columns.3 = SIMD4<Float>(base + [0, h / 2, 0] - origin, 1)
                            skyline[ring * WorldKit.windowSeeds + (i + ring * 40) % WorldKit.windowSeeds].append(m)
                            break
                        }
                    }
                }
                for (group, transforms) in skyline.enumerated() where !transforms.isEmpty {
                    let ring = group / WorldKit.windowSeeds
                    let haze: CGFloat = ring == 0 ? 0.78 : 0.48
                    let material = WorldKit.unlit(UIColor(white: haze, alpha: 1), texture: WorldKit.windowsTexture(seed: group % WorldKit.windowSeeds), toneMap: false, opaque: true)
                    let towers = ModelEntity(mesh: NeonCityProps.unitBox, materials: [material])
                    towers.position = origin
                    guard let data = try? LowLevelInstanceData(instanceCount: transforms.count) else { continue }
                    data.withMutableTransforms { buffer in for (i, m) in transforms.enumerated() { buffer[i] = m } }
                    if let comp = try? MeshInstancesComponent(mesh: NeonCityProps.unitBox, instances: data,
                                                              bounds: BoundingBox(min: [-80, -30, -80], max: [80, 40, 80])) {
                        towers.components.set(comp)
                    }
                    city.addChild(towers)
                    if ring == 1 { outerRing.append(towers) }
                }
            },
            WorldBuildStep("billboard") { [self] in
                // Billboard tower straight ahead (30 m) with your theme screen, 9 × 12 m (the 3:4 device bitmap), emissive.
                let towerBase = origin + f * towerDist + [0, -25, 0]
                let mainTower = ModelEntity(mesh: .generateBox(width: 12, height: 44, depth: 12), materials: [WorldKit.unlit(.white, texture: WorldKit.windowsTexture(seed: 99), toneMap: false, opaque: true)])
                mainTower.position = towerBase + [0, 22, 0]
                mainTower.orientation = ctx.yaw
                city.addChild(mainTower)
                let bitmap = PassportManifest.shared.theme(forWorld: descriptor.id).bitmap
                // v4 B5 §5: rendered and uploaded ahead of the build when it can be (`preheatJobs`), the same pixels.
                if let cardTex = NeonCityProps.billboardTexture(themeBitmap: bitmap) {
                    let boardW: Float = 9, boardH: Float = boardW * Float(cardTex.height) / Float(max(1, cardTex.width))
                    // Dark backing plate so the board reads as mounted, then the screen itself.
                    let plate = ModelEntity(mesh: .generateBox(width: boardW + 0.6, height: boardH + 0.6, depth: 0.3), materials: [WorldKit.unlit(UIColor(hex: "#0A0D1A"))])
                    plate.position = origin + f * (towerDist - 6.0) + [0, 8, 0]
                    plate.orientation = ctx.yaw
                    city.addChild(plate)
                    let board = ModelEntity(mesh: .generatePlane(width: boardW, height: boardH), materials: [WorldKit.unlit(.white, texture: cardTex, toneMap: false)])
                    board.components.set(OpacityComponent(opacity: 0))
                    board.components.set(BloomComponent(scope: .hierarchical))
                    var bloom = BloomOptionsComponent()
                    bloom.strength = NeonCityWorld.billboardBloomBase
                    bloom.threshold = 0.8
                    bloom.blurRadius = 3
                    board.components.set(bloom)
                    board.position = origin + f * (towerDist - 6.2) + [0, 8, 0]
                    board.orientation = ctx.yaw
                    city.addChild(board)
                    billboard = board
                } else {
                    print("[world] neon-city: billboard bitmap \(bitmap) missing")
                }
            },
            WorldBuildStep("sign building") { [self] in
                // MARK: Sign building (right, 18 m ahead / 14 m right): the three tag signs mounted on its face, the
                // follower split-flap board under them.
                let signBuilding = ModelEntity(mesh: .generateBox(width: 12, height: 40, depth: 11), materials: [WorldKit.unlit(.white, texture: WorldKit.windowsTexture(seed: 3), toneMap: false, opaque: true)])
                signBuilding.position = signCenterH + [0, -25 + 20, 0]
                signBuilding.orientation = faceYaw
                city.addChild(signBuilding)
                let signColors = [descriptor.primaryColor, descriptor.secondaryColor, descriptor.accentColor]
                for (i, tag) in card.tags.prefix(3).enumerated() {
                    let sign = ModelEntity(mesh: .generatePlane(width: 8, height: 2), materials: [FXMaterials.glow(WorldKit.textTexture(tag, color: signColors[i]), tint: .white, opacity: 1)])
                    sign.components.set(OpacityComponent(opacity: 0.05))
                    let mount = NeonCityProps.mountedSign(sign: sign, width: 8, height: 2, color: signColors[i])
                    mount.position = facade + [0, 2.6 + Float(i) * 3.8, 0]
                    mount.orientation = faceYaw
                    city.addChild(mount)
                    signs.append(sign)
                }
            },
            WorldBuildStep("follower board: flaps") { [self] in
                // Follower board: "粉丝" + six split-flap digits on the billboard tower, right under the screen (straight
                // ahead, so it is in frame with the billboard for the take), set silently from the frozen stats.
                ticker = SplitFlapTicker(digits: descriptor.statsRules.tickerDigits, color: descriptor.highlightColor, frame: descriptor.accentColor)
            },
            WorldBuildStep("follower board: mount") { [self] in
                guard let board = ticker else { return }
                let label = ModelEntity(mesh: .generatePlane(width: 2.2, height: 0.55), materials: [FXMaterials.glow(WorldKit.textTexture("粉丝", color: descriptor.accentColor, fontSize: 150), tint: .white, opacity: 1)])
                label.components.set(BloomComponent(scope: .hierarchical))
                let boardMount = Entity()
                boardMount.position = origin + f * (towerDist - 6.0) + [0, 0.55, 0]
                boardMount.orientation = ctx.yaw
                let boardWidth = board.width + 0.5 + 2.2
                board.root.position = [boardWidth / 2 - board.width / 2, 0, 0.1]
                label.position = [-boardWidth / 2 + 1.1, 0.05, 0.1]
                let backing = ModelEntity(mesh: .generateBox(width: boardWidth + 0.6, height: board.cellHeight + 0.5, depth: 0.25), materials: [WorldKit.unlit(UIColor(hex: "#0A0D1A"))])
                backing.position = [0, 0, -0.2]
                boardMount.addChild(backing)
                boardMount.addChild(board.root)
                boardMount.addChild(label)
                city.addChild(boardMount)
                board.set(value: ctx.stats.followers, animated: false)
                // (B5: no `flattenRoundedBoxes` pass any more — the ticker's cells are plain boxes from the start.)
            },
            WorldBuildStep("crown, strip") { [self] in
                // Roof crown + corner strip in the primary colour so the building reads as one lit landmark.
                let crownBar = ModelEntity(mesh: .generateBox(width: 12.4, height: 0.35, depth: 0.2), materials: [WorldKit.emissive(descriptor.primaryColor, intensity: 4)])
                crownBar.position = facade + [0, 14.6, 0]
                crownBar.orientation = faceYaw
                crownBar.components.set(BloomComponent(scope: .hierarchical))
                city.addChild(crownBar)
                crown = crownBar
                let strip = ModelEntity(mesh: .generateBox(width: 0.25, height: 38, depth: 0.25), materials: [WorldKit.emissive(descriptor.secondaryColor, intensity: 2.5)])
                strip.position = facade + faceYaw.act([-6.05, 0, 0]) + [0, -6, 0]
                city.addChild(strip)
            },
            WorldBuildStep("metro rail") { [self] in
                // MARK: Elevated metro to the left (11 m): 130 m of track, a train every `take.trainPeriod` seconds.
                trainDeckY = 1.6
                let railRoot = NeonCityProps.elevatedRail(length: NeonCityWorld.trackLength, deckY: trainDeckY, pillarBottomY: -25, lightColor: descriptor.secondaryColor)
                railRoot.position = origin + r * (-11) + f * 5
                railRoot.orientation = ctx.yaw
                city.addChild(railRoot)
                trainAnchor = origin + r * (-11) + [0, trainDeckY, 0]
            },
            WorldBuildStep("metro train") { [self] in
                let metro = NeonCityProps.Train(cars: 4, accent: descriptor.accentColor, windows: NeonCityProps.trainWindowsTexture(accent: descriptor.accentColor))
                city.addChild(metro.root)
                train = metro
            },
            WorldBuildStep("airship") { [self] in
                // MARK: Airship at 17 m (above every top but the billboard tower, 40–55 m out): right → left and back, passing
                // behind the billboard tower and then hanging in the open sky over the metro, left of the tower.
                let ship = NeonCityProps.Airship(primary: descriptor.primaryColor, accent: descriptor.accentColor, banner: WorldKit.textTexture(card.name, color: descriptor.secondaryColor, fontSize: 120))
                airshipPath = (origin + f * 46 + r * 26 + [0, 17.5, 0], origin + f * 30 + r * (-46) + [0, 16.5, 0])
                city.addChild(ship.root)
                airship = ship
            },
            WorldBuildStep("sky dome") { [self] in
                // MARK: Sky — the Bund panorama on an equirect dome just inside the shell (opaque, so the dome radius is the
                // far limit of the scene: 90 m per the descriptor); the Pudong skyline (panorama column 0.58) faces forward,
                // the near Bund facades end up behind the wearer. The engine keeps the shell flat (`skyOnShell: false`).
                let skyRadius = descriptor.environment?.skyRadius ?? 40
                if let sky = engine.assets.sky(for: descriptor.id) {
                    let tint = descriptor.environment?.skyTint.map { UIColor(hex: $0) } ?? .white
                    let dome = ModelEntity(mesh: WorldKit.skySphere(radius: skyRadius - 4), materials: [WorldKit.skyMaterial(sky, tint: tint)])
                    dome.position = ctx.headPosition
                    dome.orientation = ctx.yaw * WorldKit.skyYaw(centerU: 0.58)
                    city.addChild(dome)
                }
            },
            WorldBuildStep("clouds, rain, streaks") { [self] in
                // Clouds lit from below: two 60 × 40 m transparent sheets (a third one only ever cost fill), and the
                // quality tier takes them down to one and then none.
                for i in 0..<2 {
                    let cloud = ModelEntity(mesh: .generatePlane(width: 60, depth: 40), materials: [WorldKit.unlit(descriptor.primaryColor.withAlphaComponent(0.18), opacity: 0.18, texture: FXTextures.shared.softDisc)])
                    cloud.position = origin + f * Float(10 + i * 8) + r * Float(i * 15 - 15) + [0, 30 + Float(i) * 3, 0]
                    cloud.components.set(FloatComponent(basePosition: cloud.position, axis: r, amplitude: 4, period: 40 + Float(i) * 7, phase: Float(i)))
                    city.addChild(cloud)
                    clouds.append(cloud)
                }
                // Rain: box emitter above the rooftop, falls through the portal too (PortalCrossingComponent).
                rain.position = origin + f * 1.5 + [0, 6, 0]
                rain.components.set(NeonCityWorld.rainEmitter(color: descriptor.secondaryColor, sprite: FXTextures.shared.particle))
                rain.components.set(PortalCrossingComponent())
                city.addChild(rain)
                // Traffic streaks 25 m below.
                let streakField = StreakField(origin: origin + [0, -25, 0], forward: f, right: r, color: descriptor.accentColor)
                city.addChild(streakField.root)
                streaks = streakField
            },
            WorldBuildStep("portal") { [self] in
                // Portal seam above the card (centre ≈ eye level for a seated reader).
                // V3-2b B3 / plan §4 E11: 0.45 m above a card on the desk, 0.25 m above one in the wearer's hand.
                let seamBase = ctx.cardPosition + [0, ctx.seamRise, 0]
                portal.position = seamBase - f * 0.05
                portal.orientation = ctx.yaw
                portal.components.set(PortalComponent(target: city, clippingMode: .plane(.positiveZ), crossingMode: .plane(.positiveZ)))
                portal.scale = [0.001, 1.3, 1]
                for seam in [seamLeft, seamRight] {
                    seam.position = portal.position
                    seam.orientation = ctx.yaw
                    seam.scale = [1, 1.3, 1]
                    seam.components.set(BloomComponent(scope: .hierarchical))
                }
                eyeLine.position = ctx.headPosition + f * 2.5
                eyeLine.orientation = ctx.yaw
                airshipClock = 0.55 * NeonCityWorld.airshipLeg
                moveTrainAndAirship(ctx: ctx)
            },
        ]
    }


    /// The portal tear is the whole transition: no room fission competing with it.
    func fissionRecipe(ctx: WorldContext) -> RoomFission.Recipe? { nil }

    /// Parked at the desk (prebuilt, out of view): no rain simulation until entry.
    func setParked(_ parked: Bool) {
        if var emitter = rain.components[ParticleEmitterComponent.self] {
            emitter.isEmitting = !parked
            rain.components.set(emitter)
        }
    }

    func applyQuality(_ tier: WorldQuality) {
        quality = tier
        if var emitter = rain.components[ParticleEmitterComponent.self] {
            emitter.mainEmitter.birthRate = NeonCityWorld.rainBirthRate * tier.density
            // The splash is a second emitter fired on every death — half the alive count for a mote at the
            // wearer's feet, so it is the first thing `low` gives up.
            emitter.spawnedEmitter?.birthRate = tier > .low ? NeonCityWorld.rainSplashBirth : 0
            rain.components.set(emitter)
        }
        streaks?.visibleCount = max(6, Int(Float(streaks?.count ?? 0) * tier.density))
        airship?.root.isEnabled = tier > .low
        // The puddles and the outer ring of towers used to be dropped at `low` because they were 6 transparent
        // clearcoat draws and 26 separate draws; instanced and opaque they are 1 + 4 draws and ~750 triangles,
        // so `low` — the tier the watchdog falls to — keeps the wet floor and a closed horizon.
        for puddle in puddles { puddle.isEnabled = true }
        for tower in outerRing { tower.isEnabled = true }
        // 60 × 40 m sheets overhead, transparent and stacked: two at high, one at medium, none at low.
        for (i, cloud) in clouds.enumerated() { cloud.isEnabled = i < NeonCityWorld.cloudCount(tier) }
        logTier()
    }

    private static func cloudCount(_ tier: WorldQuality) -> Int { [0, 1, 2][tier.rawValue] }

    /// Particles alive in the steady state at `tier` — RealityKit reports no live count, so this is the number
    /// the emitter settles at, which is what the budget is about.
    static func aliveParticles(_ tier: WorldQuality) -> Int {
        let main = rainBirthRate * tier.density
        let splash = tier > .low ? main * rainSplashBirth * rainSplashLife : 0
        return Int((main * rainLifeSpan + splash).rounded())
    }

    /// `[perf] world neon-city tier …`: what this tier actually draws. Triangles count only *enabled* entities
    /// (a disabled subtree costs nothing) and multiply an instanced draw by its instance count, so the next
    /// headset log says where the budget went without a profiler.
    private func logTier() {
        let art = root.findEntity(named: "assets").map { WorldLighting.triangleCount($0, enabledOnly: true) } ?? 0
        let total = WorldLighting.triangleCount(root, enabledOnly: true)
        print("\(PerfLog.prefix) world neon-city tier \(quality): \(art) art + \(total - art) set-piece = \(total) triangles, "
              + "\(WorldLighting.drawCount(root)) draws (\(WorldLighting.blendedDrawCount(root)) blended), "
              + "≤ \(NeonCityWorld.aliveParticles(quality)) particles alive, "
              + "≤ \(perTickWriteCap) entity writes/tick (peak \(writesPeak))"
              + (tickCount > 0 ? String(format: ", inside CPU avg %.0f µs worst %.0f µs over %d ticks",
                                        tickSeconds / Double(tickCount) * 1e6, tickWorst * 1e6, tickCount) : ""))
    }

    /// Upper bound on the entities one `inside` tick writes to: 3 signs, the billboard, the train root, the
    /// beacon, the airship's two lamps, the ticker's cells and the streak instance buffer.
    private var perTickWriteCap: Int { 3 + 1 + 1 + 1 + 2 + (ticker?.digits ?? 0) + 1 }

    // MARK: Followers

    /// The board shows the new count (idempotent; `onCelebrate` adds the fanfare).
    func onStats(_ stats: CardStats, engine: WorldEngine) {
        ticker?.set(value: stats.followers, animated: true)
    }

    /// The board clatters to the new count while the billboard bloom peaks (0.9 → 0.7 over 0.5 s).
    func onCelebrate(delta: Int, stats: CardStats, engine: WorldEngine) {
        ticker?.set(value: stats.followers, animated: true)
        billboardBloom = NeonCityWorld.billboardBloomPeak
        print("[world] neon-city ticker → \(stats.followers) (+\(delta))")
    }

    // MARK: Per-frame set pieces

    /// Write an `OpacityComponent` only when it moves: an opacity write re-evaluates the entity (and, on a
    /// subtree root like the train, everything under it), and `inside` was making eight of them every frame for
    /// values that mostly stand still — the train's edge fade is 1 for most of its run, a sign flickers a few
    /// frames a second, the beacon is a two-state blink.
    @discardableResult
    private func setOpacity(_ entity: Entity?, _ value: Float, epsilon: Float = 0.01) -> Bool {
        guard let entity else { return false }
        if let current = entity.components[OpacityComponent.self]?.opacity, abs(current - value) <= epsilon { return false }
        entity.components.set(OpacityComponent(opacity: value))
        writesThisTick += 1
        return true
    }

    private func applyRooftopTexturesIfReady(engine: WorldEngine) {
        guard !slabTextured, let slab else { return }
        let assets = engine.assets
        guard let diffuse = assets.texture(world: descriptor.id, name: NeonCityProps.asphaltDiffuse),
              let normal = assets.texture(world: descriptor.id, name: NeonCityProps.asphaltNormal),
              let roughness = assets.texture(world: descriptor.id, name: NeonCityProps.asphaltRoughness) else { return }
        slab.model?.materials = [NeonCityProps.wetAsphalt(diffuse: diffuse, normal: normal, roughness: roughness)]
        slabTextured = true
    }

    /// Train: every `take.trainPeriod` s a 4-car metro crosses the 130 m track at 15 m/s (alternating direction),
    /// its nose entering at `trainClock` = 0. Airship: ping-pong along its path, nose along the travel direction,
    /// 110 s per leg.
    private func moveTrainAndAirship(ctx: WorldContext) {
        let f = ctx.forward
        if let train {
            let period = descriptor.takeTiming.trainPeriod
            if trainClock < 0 {
                train.root.isEnabled = false
            } else {
                let cycle = Int(trainClock / period)
                let t = trainClock - Float(cycle) * period
                let travel = t * NeonCityWorld.trainSpeed
                let span = NeonCityWorld.trackLength + train.length
                if travel < span {
                    let dir: Float = cycle % 2 == 0 ? 1 : -1              // +1 = toward the far skyline
                    let along = -NeonCityWorld.trackLength / 2 - train.length / 2 + travel   // nose-first from behind
                    train.root.position = trainAnchor + f * (5 + dir * along)
                    // Local −Z is the nose; travelling along +forward means nose = forward.
                    train.root.orientation = ctx.yaw * simd_quatf(angle: dir > 0 ? 0 : .pi, axis: [0, 1, 0])
                    train.root.isEnabled = true
                    // Fade the ends so the train never pops in the far haze.
                    let edge = min(travel, span - travel) / 18
                    setOpacity(train.root, max(0, min(1, edge)))
                } else {
                    train.root.isEnabled = false
                }
            }
        }
        if let airship, airship.root.isEnabled {
            let leg = NeonCityWorld.airshipLeg
            let k = (airshipClock / leg).truncatingRemainder(dividingBy: 2)
            let forwardLeg = k < 1
            let u = forwardLeg ? k : 2 - k
            let e = u * u * (3 - 2 * u)
            airship.root.position = simd_mix(airshipPath.from, airshipPath.to, SIMD3<Float>(repeating: e))
            let d = simd_normalize((forwardLeg ? 1 : -1) * (airshipPath.to - airshipPath.from) * [1, 0, 1])
            airship.root.orientation = simd_quatf(angle: atan2(-d.z, d.x), axis: [0, 1, 0])
            airship.blink(time: time)
        }
        setOpacity(beacon, time.truncatingRemainder(dividingBy: 1.6) < 0.18 ? 1 : 0.08)
    }

    /// Fluorescent strike: three flashes (0 / 60 / 140 ms) with dark gaps, then steady from 200 ms.
    private static func ballast(_ t: Float) -> Float {
        if t < 0.025 { return 1 }
        if t < 0.06 { return 0.12 }
        if t < 0.085 { return 1 }
        if t < 0.14 { return 0.08 }
        if t < 0.165 { return 1 }
        if t < 0.2 { return 0.35 }
        return 1
    }

    func entry(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        time += dt
        airshipClock += dt
        streaks?.update(dt: dt)
        applyRooftopTexturesIfReady(engine: engine)
        moveTrainAndAirship(ctx: ctx)
        if p >= 0.25 && p < 0.78 {
            portal.isEnabled = true
            seamLeft.isEnabled = true
            seamRight.isEnabled = true
            // 0.25–0.62 seam → tear; the last stretch (0.62–0.78) races to cover the view.
            let t = (p - 0.25) / 0.53
            let widen = t < 0.7 ? pow(t / 0.7, 1.6) * 3.0 : 3.0 + pow((t - 0.7) / 0.3, 2) * 9.0
            let tall = 0.9 + t * 1.5 + (t > 0.7 ? pow((t - 0.7) / 0.3, 2) * 7 : 0)
            let crackle = 1 + 0.03 * sin(time * 37) * (1 - t)
            portal.scale = [max(0.02, widen) * crackle, tall, 1]
            for (i, seam) in [seamLeft, seamRight].enumerated() {
                let side: Float = i == 0 ? -1 : 1
                seam.position = portal.position + ctx.right * (side * widen / 2)
                seam.scale = [1 + 2 * (1 - t), tall, 1]
                seam.components.set(OpacityComponent(opacity: (0.9 - 0.6 * max(0, (t - 0.7) / 0.3)) * (0.85 + 0.15 * sin(time * 23 + Float(i)))))
            }
            // While the tear races to fill the view, the shell closes behind it (ease-in cubic) so the passthrough
            // is gone the moment the portal is: the engine measures the shell opaque here and asks for .full.
            if p >= 0.62 {
                let k = (p - 0.62) / 0.16
                engine.shell.set(opacity: max(engine.shell.opacity, k * k * k * descriptor.immersion.shellOpacity))
            }
        }
        if p >= 0.78 && !switched {
            switched = true
            city.components.remove(WorldComponent.self)
            portal.isEnabled = false
            seamLeft.isEnabled = false
            seamRight.isEnabled = false
            engine.shell.set(opacity: descriptor.immersion.shellOpacity)
            FXAudio.shared.play(.whoosh, on: root)
        }
        if p >= 0.78 {
            // A count that changed since the desk build clatters in as the city appears (not on top of the strikes later).
            ticker?.update(dt: dt)
            // Billboard snaps on at 0.82; signs strike at 0.88 / 0.93 / 0.98 with a ballast envelope and ascending chips.
            let snap = max(0, min(1, (p - 0.82) / 0.04))
            setOpacity(billboard, 0.15 + 0.85 * snap)
            setOpacity(crown, 0.1 + 0.9 * snap)
            for (i, sign) in signs.enumerated() {
                if signStrike[i] == nil, p >= 0.88 + 0.05 * Float(i) {
                    signStrike[i] = time
                    FXAudio.shared.play([FXAudio.Cue.chip0, .chip1, .chip2][i], on: root)
                }
                if let struck = signStrike[i] { setOpacity(sign, NeonCityWorld.ballast(time - struck)) }
            }
        } else {
            setOpacity(billboard, 0.15)
            setOpacity(crown, 0.1)
        }
    }

    func inside(dt: Float, ctx: WorldContext, engine: WorldEngine) {
        let tickStarted = CFAbsoluteTimeGetCurrent()
        writesThisTick = 0
        if trainClock < -100 {
            // First frame inside: seed the take clocks so the shot is the same every time.
            trainClock = -descriptor.takeTiming.trainFirst
            airshipClock = 0.55 * NeonCityWorld.airshipLeg
        }
        time += dt
        trainClock += dt
        airshipClock += dt
        streaks?.update(dt: dt)
        applyRooftopTexturesIfReady(engine: engine)
        moveTrainAndAirship(ctx: ctx)
        ticker?.update(dt: dt)
        // Signs finish their strike, then flicker faintly; the billboard breathes and peaks after a celebration.
        for (i, sign) in signs.enumerated() {
            if let struck = signStrike[i], time - struck < 0.2 {
                setOpacity(sign, NeonCityWorld.ballast(time - struck))
            } else {
                let flick: Float = sin(time * (3.1 + Float(i))) > 0.97 ? 0.5 : 1
                setOpacity(sign, flick)
            }
        }
        if billboardBloom > NeonCityWorld.billboardBloomBase {
            billboardBloom = max(NeonCityWorld.billboardBloomBase, billboardBloom - dt * (NeonCityWorld.billboardBloomPeak - NeonCityWorld.billboardBloomBase) / 0.5)
            if var bloom = billboard?.components[BloomOptionsComponent.self] {
                bloom.strength = billboardBloom
                billboard?.components.set(bloom)
            }
        }
        setOpacity(billboard, 0.85 + 0.15 * sin(time * 0.8))
        writesPeak = max(writesPeak, writesThisTick)
        let spent = CFAbsoluteTimeGetCurrent() - tickStarted
        tickSeconds += spent
        tickWorst = max(tickWorst, spent)
        tickCount += 1
    }

    func exit(progress p: Float, dt: Float, ctx: WorldContext, engine: WorldEngine) {
        streaks?.update(dt: dt * (p < 0.35 ? 1 : 0))
        if p < 0.35 {
            time += dt
            trainClock += dt
            airshipClock += dt
            moveTrainAndAirship(ctx: ctx)
            ticker?.update(dt: dt)
        }
        // 0–0.30 two dims through the near black shell (never a brighten); rain freezes on the second.
        if p < 0.30 {
            let k = p / 0.30
            let dim: Float = (k > 0.2 && k < 0.35) || (k > 0.6 && k < 0.8) ? 0.7 : (k >= 0.8 ? 0.35 : 0)
            engine.shutter.setShutter(0)
            engine.shutter.set(opacity: dim)
            if k > 0.6, var emitter = rain.components[ParticleEmitterComponent.self], emitter.simulationState != .pause {
                emitter.simulationState = .pause
                rain.components.set(emitter)
            }
        }
        // 0.30–0.62 black bands slide in from above and below to the eye line; a bright cyan seam marks the meeting edge.
        if p >= 0.30 && p < 0.62 {
            let k = (p - 0.30) / 0.32
            let e = 1 - pow(1 - k, 3)
            engine.shutter.set(opacity: 1)
            engine.shutter.setShutter(e)
            eyeLine.isEnabled = true
            eyeLine.components.set(OpacityComponent(opacity: 0.4 + 0.6 * e))
            eyeLine.scale = [1, 1 + 3 * (1 - e), 1]
        }
        // 0.62–0.78 the seam shrinks toward the card and pops; the bands stay closed (everything black).
        if p >= 0.62 && p < 0.78 {
            let lineT = (p - 0.62) / 0.16
            engine.shutter.setShutter(1)
            engine.shutter.set(opacity: 1)
            city.components.set(OpacityComponent(opacity: 0))
            eyeLine.scale = [max(0.005, 1 - pow(lineT, 4)), 1, 1]
            eyeLine.position = simd_mix(ctx.headPosition + ctx.forward * 2.5, ctx.cardPosition + [0, 0.02, 0], SIMD3<Float>(repeating: lineT))
            if lineT >= 0.9 {
                eyeLine.isEnabled = false
                if !popped {
                    // The last of the picture collapses into the card: a pop and a 0.12 s white disc where it went.
                    popped = true
                    FXAudio.shared.play(.pop, on: root)
                    let disc = ModelEntity(mesh: .generatePlane(width: 0.08, height: 0.08), materials: [FXMaterials.glow(FXTextures.shared.coreDisc, tint: .white, opacity: 1)])
                    disc.position = ctx.cardPosition + [0, 0.03, 0]
                    disc.components.set(BillboardComponent())
                    disc.components.set(BloomComponent(scope: .hierarchical))
                    disc.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.worldOrder))
                    disc.components.set(TweenComponent(scale: (from: [0.5, 0.5, 0.5], to: [1.6, 1.6, 1.6]), opacity: (from: 1, to: 0), duration: 0.12, easing: .easeOutCubic, removeWhenDone: true))
                    root.addChild(disc)
                }
            }
        }
        // 0.78–1.0 warm-up: the black lifts quickly and settles (ease-out) as the passthrough returns.
        if p >= 0.78 {
            let w = (p - 0.78) / 0.22
            eyeLine.isEnabled = false
            engine.shutter.setShutter(1)
            engine.shutter.set(opacity: pow(1 - w, 3))
            engine.shell.set(opacity: 0)
            city.components.set(OpacityComponent(opacity: 0))
        }
    }

    func teardown() {
        // One last tier line, now that the counters have seen the whole visit — but only for a world that was
        // actually inhabited: `teardown` also runs when a prebuilt world is dropped at the desk, and a tier line
        // with no ticks behind it is noise in the headset log.
        if tickCount > 0 { logTier() }
        streaks = nil
        train = nil
        airship = nil
        ticker = nil
    }

    // MARK: Instancing helpers

    /// One instance transform: scale, then `rotation`, then the offset (the same order an `Entity`'s transform
    /// applies, so a block of entities can be replaced by instances without moving anything).
    private static func instance(_ rotation: simd_quatf, scale: SIMD3<Float>, at offset: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.0 *= scale.x; m.columns.1 *= scale.y; m.columns.2 *= scale.z
        m.columns.3 = SIMD4<Float>(offset, 1)
        return m
    }

    /// A set of identical meshes as one instanced draw, anchored at `at` (the instance offsets are relative to it).
    private static func instanced(_ mesh: MeshResource, material: any RealityKit.Material, at: SIMD3<Float>,
                                  transforms: [simd_float4x4], bounds: BoundingBox) -> ModelEntity {
        let entity = ModelEntity(mesh: mesh, materials: [material])
        entity.position = at
        guard !transforms.isEmpty, let data = try? LowLevelInstanceData(instanceCount: transforms.count) else { return entity }
        data.withMutableTransforms { buffer in for (i, m) in transforms.enumerated() { buffer[i] = m } }
        if let comp = try? MeshInstancesComponent(mesh: mesh, instances: data, bounds: bounds) { entity.components.set(comp) }
        return entity
    }

    /// Rain: 1.0 s drops, each ending in a small upward splash where it lands.
    private static func rainEmitter(color: UIColor, sprite: TextureResource) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [9, 0.2, 9]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, -1, 0]
        p.speed = 6
        p.speedVariation = 1.5
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = rainBirthRate
        p.mainEmitter.lifeSpan = Double(rainLifeSpan)
        p.mainEmitter.size = 0.024
        p.mainEmitter.sizeVariation = 0.006
        p.mainEmitter.stretchFactor = 4
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.color = .evolving(start: .single(UIColor(white: 1, alpha: 0.7)), end: .single(color.withAlphaComponent(0)))
        var splash = ParticleEmitterComponent.ParticleEmitter()
        splash.image = sprite
        splash.blendMode = .additive
        splash.birthRate = rainSplashBirth   // per death event: a small splash (0 at low)
        splash.lifeSpan = Double(rainSplashLife)
        splash.size = 0.006
        splash.sizeVariation = 0.003
        splash.opacityCurve = .linearFadeOut
        splash.isLightingEnabled = false
        splash.color = .evolving(start: .single(color.withAlphaComponent(0.8)), end: .single(UIColor(white: 1, alpha: 0)))
        p.spawnedEmitter = splash
        p.spawnOccasion = .onDeath
        p.spawnInheritsParentColor = false
        p.spawnSpreadFactor = 0.6
        p.spawnVelocityFactor = -0.12
        return p
    }
}

/// 24 emissive streaks sliding along two lanes below the rooftop (traffic light trails). `visibleCount` lets the
/// quality tier park the rest under the city.
@MainActor
final class StreakField {
    let root = Entity()
    private var data: LowLevelInstanceData?
    private var positions: [Float] = []
    private var lanes: [Int] = []
    private let origin: SIMD3<Float>
    private let forward: SIMD3<Float>
    private let right: SIMD3<Float>
    let count = 24
    var visibleCount = 24

    init(origin: SIMD3<Float>, forward: SIMD3<Float>, right: SIMD3<Float>, color: UIColor) {
        self.origin = origin; self.forward = forward; self.right = right
        var rng = WorldKit.RNG(0x7A11)
        for i in 0..<count {
            positions.append(rng.range(-30, 30))
            lanes.append(i % 2)
        }
        let quad = MeshResource.generateBox(width: 0.3, height: 0.12, depth: 4)
        guard let d = try? LowLevelInstanceData(instanceCount: count) else { return }
        data = d
        let entity = ModelEntity(mesh: quad, materials: [WorldKit.emissive(color, intensity: 4)])
        if let comp = try? MeshInstancesComponent(mesh: quad, instances: d, bounds: BoundingBox(min: [-60, -30, -60], max: [60, 5, 60])) {
            entity.components.set(comp)
        }
        root.addChild(entity)
    }

    func update(dt: Float) {
        guard let data else { return }
        let yaw = simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0])
        data.withMutableTransforms { t in
            for i in 0..<count {
                let dir: Float = lanes[i] == 0 ? 1 : -1
                positions[i] += dt * 18 * dir
                if positions[i] > 32 { positions[i] = -32 }
                if positions[i] < -32 { positions[i] = 32 }
                let p = origin + forward * (12 + Float(lanes[i]) * 2) + right * positions[i] + [0, Float(lanes[i]) * 0.5, 0]
                var m = simd_float4x4(yaw * simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
                if i >= visibleCount { m = simd_float4x4(diagonal: [0.001, 0.001, 0.001, 1]) }
                m.columns.3 = SIMD4<Float>(p, 1)
                t[i] = m
            }
        }
    }
}
