import ARKit
import Foundation
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

/// `--lab grounding` (A3 · 真实落地 + 封面立体化).
///
/// **Desk zone** — the floating name card (a white 12 mm slab standing in for A4's card) 0.22 m over the proxy device,
/// bobbing ±3 cm; three small note cards at three heights; everything casts a grounding shadow; the additive light
/// pool under the card follows its height (`DeskLightPool`).
/// **Cover zone** — three `LivingCover`s in gold-edged frames with a SwiftUI caption, swaying ±20° so the depth shows.
///
/// Flags:
/// - `--grounding-occlusion on|off` — `EnvironmentBlendingComponent(.occluded(by: .surroundings))` on the lab's
///   content (off by default).
/// - `--cover-mode auto|scene|lift|flat` — the living covers' request (auto by default).
/// - `--grounding-zone all|desk|covers|none` — build one zone only, centred (for close-ups with `--lab-pose 1.45 0.45`),
///   or none (room probes alone).
/// - `--grounding-shadows on|off` — grounding shadows on the lab's content (on by default).
/// - `--grounding-room` — probes for the simulator's room: an occlusion row behind the sofa (opaque, translucent,
///   particles, SwiftUI, parent-only) and height-finder plates over its tables. Use with `--lab-no-desk`, no night.
/// - `--grounding-spill on|off` — a warm spot light with `SpotLightComponent.SurroundingsLight` over the card (off).
/// - `--grounding-device-occluder on|off` — an `OcclusionMaterial` box on the device (off; the proxy is virtual).
/// - `--grounding-freeze <s>` — stop the lab's clock at that time (repeatable screenshots).
/// - `--cover-files a,b,c` — the three covers (bundle names, asset names or paths). Default: Avatar, fake-cover-8,
///   fake-cover-2 — a real subject, a clean graphic subject, and a cover Vision misreads (its light band), so every
///   branch of the automatic choice is on screen.
/// - `--grounding-shadow-probe` — four 3 cm cubes hovering 3 cm over the desk's front edge, all with
///   `GroundingShadowComponent(castsShadow: true)`: PBR opaque, unlit opaque, PBR 35 % and unlit 50 % transparent —
///   which materials actually cast.
/// - `--cover-bench` — times the spatial-scene generation (10 covers serial, then parallel), the live mask and the
///   lift layers, and logs the numbers.
@MainActor
final class GroundingLab {
    enum Zone: String { case all, desk, covers, none }

    struct Flags {
        var occlusion = false
        var coverMode = V4.CoverRequest.auto
        var zone = Zone.all
        var shadows = true
        var room = false
        var spill = false
        var deviceOccluder = false
        var freeze: Double?
        var coverFiles = ["Avatar", "fake-cover-8", "fake-cover-2"]
        var bench = false
        var shadowProbe = false

        init(arguments: [String] = CommandLine.arguments) {
            func value(_ flag: String) -> String? {
                guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
                return arguments[i + 1]
            }
            func toggle(_ flag: String, default fallback: Bool) -> Bool {
                guard let v = value(flag) else { return fallback }
                return v == "on" || v == "1" || v == "true"
            }
            occlusion = toggle("--grounding-occlusion", default: false)
            coverMode = V4.CoverRequest(argument: value("--cover-mode"))
            zone = value("--grounding-zone").flatMap(Zone.init(rawValue:)) ?? .all
            shadows = toggle("--grounding-shadows", default: true)
            room = arguments.contains("--grounding-room")
            spill = toggle("--grounding-spill", default: false)
            deviceOccluder = toggle("--grounding-device-occluder", default: false)
            freeze = value("--grounding-freeze").flatMap(Double.init)
            if let files = value("--cover-files") {
                coverFiles = files.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            }
            bench = arguments.contains("--cover-bench")
            shadowProbe = arguments.contains("--grounding-shadow-probe")
        }
    }

    /// Kept alive for the life of the scene (the registry's closure returns immediately).
    private static var current: GroundingLab?

    static func build(_ stage: LabStage) async {
        let lab = GroundingLab(stage: stage, flags: Flags())
        current = lab
        await lab.start()
    }

    // MARK: - State

    private let stage: LabStage
    private let flags: Flags
    /// Everything this lab adds, for the entity count and the global toggles.
    private let deskZone = Entity()
    private let coverZone = Entity()
    private let roomZone = Entity()
    private var nameCard: Entity?
    private var pool: DeskLightPool?
    private var covers: [(frame: Entity, cover: LivingCover, baseYaw: Float, basePitch: Float, phase: Float)] = []
    private var tickStats = V4.GroundingTickStats(capacity: 600)
    /// The same tick split in parts: the card's bob, the pool's update, the covers' sway.
    private var bobStats = V4.GroundingTickStats(capacity: 600)
    private var poolStats = V4.GroundingTickStats(capacity: 600)
    private var swayStats = V4.GroundingTickStats(capacity: 600)
    private var sinceReport: Float = 0
    private var clock: Double = 0

    /// Placeholder hero card: A4's 5:7 portrait (0.20 × 0.28 m, 18 mm corners, 12 mm thick, 6° back tilt).
    private let cardSize = SIMD2<Float>(0.20, 0.28)
    private let cardThickness: Float = 0.012
    private let cardCornerRadius: Float = 0.018
    private let cardCentreHeight: Float = 0.22
    private let bobAmplitude: Float = 0.03
    private let bobPeriod: Float = 6

    private init(stage: LabStage, flags: Flags) {
        self.stage = stage
        self.flags = flags
    }

    private func start() async {
        stage.log("grounding: occlusion \(flags.occlusion ? "on" : "off") · shadows \(flags.shadows ? "on" : "off") · "
                  + "cover-mode \(flags.coverMode.rawValue) · zone \(flags.zone.rawValue) · spill \(flags.spill ? "on" : "off")"
                  + " · room \(flags.room) · desk \(LabLaunch.showsDesk) · night \(LabLaunch.night)")
        stage.log("grounding: PlaneDetectionProvider.isSupported = \(PlaneDetectionProvider.isSupported), "
                  + "SceneReconstructionProvider.isSupported = \(SceneReconstructionProvider.isSupported)")
        deskZone.name = "grounding.deskZone"
        coverZone.name = "grounding.coverZone"
        roomZone.name = "grounding.roomZone"

        if flags.zone == .all || flags.zone == .desk { await buildDeskZone() }
        if flags.zone == .all || flags.zone == .covers { await buildCoverZone() }
        if flags.room { buildRoomProbes() }
        if !flags.shadows {
            GroundingShadows.remove(from: deskZone)
            GroundingShadows.remove(from: coverZone)
            stage.log("grounding: shadows removed (--grounding-shadows off)")
        }
        if flags.occlusion {
            // The whole subtree: whether the component reaches children is one of the questions, so the room probes
            // answer it separately (`parentOnly`).
            SurroundingsGrounding.setOcclusion(true, on: deskZone, recursive: true)
            SurroundingsGrounding.setOcclusion(true, on: coverZone, recursive: true)
        }
        stage.log("grounding: entities — desk \(count(deskZone)), covers \(count(coverZone)), room \(count(roomZone))")

        stage.onTick { [weak self] dt in self?.tick(dt) }
        if flags.bench {
            Task { @MainActor in await self.runBench() }
        }
    }

    // MARK: - Desk zone

    private func buildDeskZone() async {
        stage.deviceFrame.addChild(deskZone)
        // With the covers alone off, the desk zone stays centred on the device; `all` leaves it there too — the covers
        // go to the right.
        let card = makeNameCard()
        deskZone.addChild(card)
        nameCard = card

        // Three small note cards to the left, at three heights: resting (1 mm), hovering 3.5 cm, hovering 8 cm — the
        // shadow's softness and offset against height, side by side.
        let small: [(cover: String, position: SIMD3<Float>, pitch: Float, yaw: Float)] = [
            ("fake-cover-3", [-0.40, -LabStage.deviceSize.y + 0.0025, 0.05], -90, 14),
            ("fake-cover-5", [-0.30, 0.035 - LabStage.deviceSize.y, 0.02], -55, 6),
            ("fake-cover-7", [-0.20, 0.08 - LabStage.deviceSize.y, -0.01], -30, -4),
        ]
        for (index, spec) in small.enumerated() {
            let note = makeSmallCard(cover: spec.cover)
            note.name = "grounding.smallCard\(index)"
            note.position = spec.position
            note.orientation = simd_quatf(angle: spec.yaw * .pi / 180, axis: [0, 1, 0])
                * simd_quatf(angle: spec.pitch * .pi / 180, axis: [1, 0, 0])
            deskZone.addChild(note)
        }

        do {
            let footprint = SIMD2<Float>(LabStage.deviceSize.x, LabStage.deviceSize.z) / 2
            let pool = try await DeskLightPool(holeHalf: footprint + SIMD2<Float>(repeating: 0.002), holeRadius: 0.006)
            pool.entity.position = [0, -LabStage.deviceSize.y + 0.001, 0]
            deskZone.addChild(pool.entity)
            self.pool = pool
        } catch {
            stage.log("grounding: light pool failed: \(error)")
        }

        await addCardGlow()

        if flags.spill {
            // A warm spot hanging under the card's bottom edge, pointing at the desk: on virtual surfaces it is an
            // ordinary light; `SurroundingsLight` asks the system to light the real room with it as well.
            let spot = SurroundingsGrounding.makeSpotSpill(color: UIColor(hex: "#FFD58A"), intensity: 1800,
                                                           innerAngle: 35, outerAngle: 70, range: 1.2, surroundings: true)
            spot.position = [0, cardCentreHeight - cardSize.y / 2 - 0.01, 0.03]
            spot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            deskZone.addChild(spot)
            stage.log("grounding: spot light + SpotLightComponent.SurroundingsLight under the card")
        }
        if flags.deviceOccluder {
            let occluder = SurroundingsGrounding.makeDeviceOccluder(size: LabStage.deviceSize)
            deskZone.addChild(occluder)
            stage.log("grounding: device occluder (OcclusionMaterial box) on")
        }

        let casters = GroundingShadows.apply(to: deskZone)
        stage.log("grounding: desk zone built, \(casters) shadow casters")
        if flags.shadowProbe { buildShadowProbe() }
    }

    /// The magic light the pool answers to: a soft warm halo behind the card and a sparse placeholder gold dust
    /// (A2 owns the real one) drifting down in front of it — ~40 motes alive, the art bible's round soft dots.
    private func addCardGlow() async {
        guard let card = nameCard else { return }
        // Radial, not the card's rounded rectangle: a rectangular halo reads as a lightbox behind the card.
        let halo = ModelEntity(mesh: .generatePlane(width: cardSize.x * 2.4, height: cardSize.y * 2.0),
                               materials: [await DeskLightPool.additiveMaterial(
                                   texture: FXTextures.shared.softDisc,
                                   tint: UIColor(hex: "#FFB347").mixed(with: .black, by: 0.55))])
        halo.name = "grounding.nameCard.halo"
        halo.position = [0, 0, -cardThickness / 2 - 0.006]
        card.addChild(halo)

        let dust = Entity()
        dust.name = "grounding.dust"
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = [cardSize.x * 1.1, cardSize.y * 0.5, 0.05]
        emitter.mainEmitter.birthRate = 30
        emitter.mainEmitter.lifeSpan = 1.4
        emitter.mainEmitter.lifeSpanVariation = 0.4
        emitter.mainEmitter.size = 0.0022
        emitter.mainEmitter.sizeVariation = 0.0008
        emitter.mainEmitter.image = FXTextures.shared.mote
        emitter.mainEmitter.blendMode = .additive
        emitter.mainEmitter.color = .evolving(start: .single(UIColor(hex: "#FFD58A")), end: .single(UIColor(hex: "#FFF3D6").withAlphaComponent(0)))
        emitter.mainEmitter.acceleration = [0, -0.012, 0]
        emitter.mainEmitter.dampingFactor = 1.2
        emitter.speed = 0.004
        emitter.speedVariation = 0.003
        dust.components.set(emitter)
        dust.position = [0, cardCentreHeight - cardSize.y * 0.2, 0.03]
        deskZone.addChild(dust)
    }

    /// Which materials cast a grounding shadow (A4 §2 found: only opaque lit ones). Front-left of the desk, in desk
    /// space, 3 cm above the top.
    private func buildShadowProbe() {
        var pbr = PhysicallyBasedMaterial()
        pbr.baseColor = .init(tint: UIColor(hex: "#FFD58A"))
        pbr.roughness = .init(floatLiteral: 0.5)
        var pbrClear = pbr
        pbrClear.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let unlit = UnlitMaterial(color: UIColor(hex: "#FFD58A"))
        var unlitClear = unlit
        unlitClear.blending = .transparent(opacity: .init(floatLiteral: 0.5))
        let probes: [(String, any RealityKit.Material)] = [("pbrOpaque", pbr), ("unlitOpaque", unlit),
                                                          ("pbr35", pbrClear), ("unlit50", unlitClear)]
        for (index, probe) in probes.enumerated() {
            let cube = ModelEntity(mesh: .generateBox(size: 0.03, cornerRadius: 0.004), materials: [probe.1])
            cube.name = "grounding.shadowProbe.\(probe.0)"
            cube.position = [-0.46 + Float(index) * 0.075, 0.03 + 0.015, 0.2]
            cube.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: false))
            stage.desk.addChild(cube)
        }
        stage.log("grounding: shadow probe — pbrOpaque, unlitOpaque, pbr35, unlit50 (left → right), all castsShadow")
    }

    private func makeNameCard() -> Entity {
        let card = Entity()
        card.name = "grounding.nameCard"
        // Opaque and lit, so it casts (A4 §2): a crystal-white stand-in for A4's card, lacquered, faintly warm.
        var slab = PhysicallyBasedMaterial()
        slab.baseColor = .init(tint: UIColor(hex: "#F4F7FF"))
        slab.roughness = .init(floatLiteral: 0.22)
        slab.metallic = .init(floatLiteral: 0)
        slab.clearcoat = .init(floatLiteral: 1)
        slab.clearcoatRoughness = .init(floatLiteral: 0.04)
        slab.emissiveColor = .init(color: UIColor(hex: "#FFF3D6"))
        slab.emissiveIntensity = 0.22
        let body = ModelEntity(mesh: FXMeshes.roundedSlab(width: cardSize.x, height: cardSize.y, depth: cardThickness,
                                                          radius: cardCornerRadius),
                               materials: [slab])
        body.name = "grounding.nameCard.slab"
        card.addChild(body)

        var gold = UnlitMaterial(applyPostProcessToneMap: false)
        gold.color = .init(tint: UIColor(hex: "#C9A45C"))
        let rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: cardSize.x - 0.003, height: cardSize.y - 0.003,
                                                             radius: cardCornerRadius - 0.0015, thickness: 0.0012),
                              materials: [gold])
        rim.name = "grounding.nameCard.goldEdge"
        rim.position = [0, 0, cardThickness / 2 + 0.0002]
        card.addChild(rim)
        card.position = [0, cardCentreHeight, 0]
        card.orientation = simd_quatf(angle: HologramLayout.cardTiltDegrees * .pi / 180, axis: [1, 0, 0])
        return card
    }

    private func makeSmallCard(cover: String) -> Entity {
        let size = SIMD2<Float>(0.07, 0.091)
        let card = Entity()
        var plateMaterial = PhysicallyBasedMaterial()
        plateMaterial.baseColor = .init(tint: UIColor(hex: "#101634"))
        plateMaterial.roughness = .init(floatLiteral: 0.3)
        plateMaterial.clearcoat = .init(floatLiteral: 1)
        let plate = ModelEntity(mesh: FXMeshes.roundedSlab(width: size.x, height: size.y, depth: 0.003, radius: 0.006),
                                materials: [plateMaterial])
        plate.name = "grounding.smallCard.plate"
        card.addChild(plate)
        if let source = LivingCover.Source.named(cover),
           let texture = try? TextureResource(image: source.image, options: .init(semantic: .color)) {
            var face = UnlitMaterial(color: .white)
            face.color = .init(tint: .white, texture: .init(texture))
            let quad = ModelEntity(mesh: .generatePlane(width: size.x - 0.007, height: size.y - 0.007, cornerRadius: 0.003),
                                   materials: [face])
            quad.name = "grounding.smallCard.cover"
            quad.position = [0, 0, 0.0016]
            card.addChild(quad)
        }
        var gold = UnlitMaterial(applyPostProcessToneMap: false)
        gold.color = .init(tint: UIColor(hex: "#C9A45C"))
        let rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: size.x - 0.003, height: size.y - 0.003,
                                                             radius: 0.0045, thickness: 0.0008),
                              materials: [gold])
        rim.name = "grounding.smallCard.goldEdge"
        rim.position = [0, 0, 0.0017]
        card.addChild(rim)
        return card
    }

    // MARK: - Cover zone

    private func buildCoverZone() async {
        stage.desk.addChild(coverZone)
        let notes = RecentNotesPayload.load(path: "fake-notes.json")?.notes ?? []
        let camera = SIMD3<Float>(0, 1.59, 0)
        let height: Float = 0.117
        let spacing: Float = 0.138
        let centreX: Float = flags.zone == .covers ? 0 : 0.35
        // The close-up raises the row towards eye level so the covers face the lens rather than the desk.
        let rowHeight: Float = flags.zone == .covers ? 0.13 : 0.10
        var loads: [(LivingCover, LivingCover.Source)] = []
        for (index, name) in flags.coverFiles.prefix(3).enumerated() {
            guard let source = LivingCover.Source.named(name) else {
                stage.log("grounding: cover '\(name)' not found")
                continue
            }
            let aspect = Float(source.image.width) / Float(max(1, source.image.height))
            let size = SIMD2<Float>(height * aspect, height)
            let cover = LivingCover(size: size, lift: 0.012)
            let style = LivingCoverFrame.Style()
            let frame = LivingCoverFrame.make(coverSize: size, style: style)
            frame.root.name = "grounding.coverFrame\(index)"
            frame.mount.addChild(cover.root)

            // Caption: the note's own title and likes when the cover is one of the fake notes. The title sits in the
            // band under the cover; the ♥ pill hangs in front of the cover's lower right corner, 2 mm in front of the
            // lifted subject — the brief's "SwiftUI in front of the presentation" test on every mode.
            let note = notes.first { ($0.coverURL ?? "").hasPrefix(name) }
            let title = note?.title ?? (name.lowercased() == "avatar" ? "星际访客 · 我的头像" : name)
            let likes = note?.likesLabel ?? "4.4万"
            let titleEntity = LivingCoverFrame.makeTitle(title, width: size.x - 0.004, height: style.captionBand)
            frame.band.addChild(titleEntity)
            let likesEntity = LivingCoverFrame.makeLikes(likes)
            likesEntity.position = [size.x / 2 - 0.016, -size.y / 2 + 0.008, cover.parallax.clampedLift + 0.002]
            frame.mount.addChild(likesEntity)

            let x = centreX + (Float(index) - 1) * spacing
            let position = SIMD3<Float>(x, rowHeight, 0.03)
            frame.root.position = position
            let world = stage.desk.position + position
            let toCamera = camera - world
            let yaw = atan2(toCamera.x, toCamera.z)
            let pitch = -atan2(toCamera.y, simd_length(SIMD2<Float>(toCamera.x, toCamera.z))) * 0.8
            frame.root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pitch, axis: [1, 0, 0])
            coverZone.addChild(frame.root)
            covers.append((frame.root, cover, yaw, pitch, Float(index) * 2.1))
            loads.append((cover, source))
        }
        let casters = GroundingShadows.apply(to: coverZone)
        stage.log("grounding: cover zone built, \(covers.count) covers, \(casters) shadow casters")
        // Covers load concurrently; each logs its own line when it settles.
        for (cover, source) in loads {
            Task { @MainActor in
                let report = await cover.load(source, request: self.flags.coverMode)
                self.stage.log("[cover] \(report.line)")
                if let holder = cover.presentation, let component = holder.components[ImagePresentationComponent.self] {
                    self.stage.log("[cover] \(source.name) presentation: screen \(component.presentationScreenSize) m, "
                                   + "image \(component.screenImageDimension) px, viewing \(component.viewingMode), "
                                   + "available \(component.availableViewingModes.count) modes, screenHeight \(component.screenHeight)")
                }
                // New entities arrived with the presentation: they cast too.
                GroundingShadows.apply(to: cover.root)
                if !self.flags.shadows { GroundingShadows.remove(from: cover.root) }
                if self.flags.occlusion { SurroundingsGrounding.setOcclusion(true, on: cover.root, recursive: true) }
            }
        }
    }

    // MARK: - Room probes

    /// Occlusion and real-surface probes for the simulator's living room (camera at the origin, eye 1.6 m, −Z ahead).
    /// The sofa's back crosses the view about 2.4 m out, its top ≈ 0.75 m high; the row stands 3.1 m out, straddling
    /// that top edge, so an occluded probe loses its lower part and an unoccluded one is drawn over the sofa.
    private func buildRoomProbes() {
        stage.root.addChild(roomZone)
        let z: Float = -3.1
        let y: Float = 0.52
        var white = PhysicallyBasedMaterial()
        white.baseColor = .init(tint: UIColor(hex: "#F4F7FF"))
        white.roughness = .init(floatLiteral: 0.4)
        white.emissiveColor = .init(color: UIColor(hex: "#FFF3D6"))
        white.emissiveIntensity = 0.5

        // 1. Opaque card, component on the model itself.
        let opaque = ModelEntity(mesh: FXMeshes.roundedSlab(width: 0.30, height: 0.40, depth: 0.012, radius: 0.03), materials: [white])
        opaque.name = "room.opaque"
        opaque.position = [-0.9, y, z]
        roomZone.addChild(opaque)

        // 2. Translucent "crystal" card.
        var crystal = PhysicallyBasedMaterial()
        crystal.baseColor = .init(tint: UIColor(hex: "#F4F7FF"))
        crystal.roughness = .init(floatLiteral: 0.2)
        crystal.blending = .transparent(opacity: .init(floatLiteral: 0.35))
        let translucent = ModelEntity(mesh: FXMeshes.roundedSlab(width: 0.30, height: 0.40, depth: 0.012, radius: 0.03),
                                      materials: [crystal])
        translucent.name = "room.translucent"
        translucent.position = [-0.45, y, z]
        roomZone.addChild(translucent)

        // 3. Gold dust: soft round motes (art bible §4), ~90 alive.
        let dust = Entity()
        dust.name = "room.dust"
        var emitter = ParticleEmitterComponent()
        emitter.emitterShape = .box
        emitter.emitterShapeSize = [0.3, 0.4, 0.02]
        emitter.mainEmitter.birthRate = 60
        emitter.mainEmitter.lifeSpan = 1.5
        emitter.mainEmitter.size = 0.012
        emitter.mainEmitter.color = .constant(.single(UIColor(hex: "#FFD58A")))
        emitter.mainEmitter.blendMode = .additive
        emitter.speed = 0.01
        dust.components.set(emitter)
        dust.position = [0, y, z]
        roomZone.addChild(dust)

        // 4. A SwiftUI attachment.
        let panel = Entity()
        panel.name = "room.swiftui"
        panel.components.set(ViewAttachmentComponent(rootView:
            Text("SwiftUI 附件\n遮挡测试")
                .font(.system(size: 60, weight: .bold))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .padding(24)
                .frame(width: 400, height: 540)
                .background(Color(red: 0.8, green: 0.25, blue: 0.3))
        ))
        panel.position = [0.45, y, z]
        roomZone.addChild(panel)

        // 5. Component on a parent only: does it reach the child?
        let parent = Entity()
        parent.name = "room.parentOnly"
        parent.position = [0.9, y, z]
        var blue = PhysicallyBasedMaterial()
        blue.baseColor = .init(tint: UIColor(hex: "#4C7DFF"))
        blue.emissiveColor = .init(color: UIColor(hex: "#4C7DFF"))
        blue.emissiveIntensity = 0.6
        let child = ModelEntity(mesh: FXMeshes.roundedSlab(width: 0.30, height: 0.40, depth: 0.012, radius: 0.03), materials: [blue])
        child.name = "room.parentOnly.child"
        parent.addChild(child)
        roomZone.addChild(parent)

        // 6. Depth order: an unoccluded red bar *behind* the opaque card (5 cm further). The documentation says an
        // occluded entity "always renders behind other virtual contents that don't have occlusion enabled".
        var red = UnlitMaterial(color: UIColor(hex: "#FF2442"))
        red.faceCulling = .none
        let bar = ModelEntity(mesh: .generateBox(width: 0.44, height: 0.05, depth: 0.01), materials: [red])
        bar.name = "room.behindBar"
        bar.position = [-0.9, y + 0.08, z - 0.05]
        roomZone.addChild(bar)

        if flags.occlusion {
            for probe in [opaque, translucent, dust, panel] as [Entity] {
                SurroundingsGrounding.setOcclusion(true, on: probe, recursive: false)
            }
            SurroundingsGrounding.setOcclusion(true, on: parent, recursive: false)
        }
        // Read the components back: the evidence that "no visible change" is not "component missing".
        let states = [opaque, translucent, dust, panel, parent, child, bar].map { entity in
            "\(entity.name)=\(SurroundingsGrounding.isOccluded(entity) ? "occluded" : (entity.components.has(EnvironmentBlendingComponent.self) ? "default" : "none"))"
        }
        stage.log("grounding: EnvironmentBlendingComponent read back — \(states.joined(separator: ", "))")

        // Real-surface shadows: opaque PBR cubes (the only material that casts, per A4 §2 and the probe below) with a
        // grounding shadow, hovering a few centimetres over the simulated room's near table (top ≈ 0.75 m, 1.5–1.75 m
        // out) and its coffee table (top ≈ 0.40 m, ≈ 3.3 m out).
        var cubeMaterial = PhysicallyBasedMaterial()
        cubeMaterial.baseColor = .init(tint: UIColor(hex: "#FFD58A"))
        cubeMaterial.roughness = .init(floatLiteral: 0.5)
        let hover: [(name: String, position: SIMD3<Float>)] = [
            ("room.shadowCube.near4", [0.10, 0.79, -1.66]),
            ("room.shadowCube.near10", [0.32, 0.85, -1.66]),
            ("room.shadowCube.coffee3", [0.30, 0.44, -3.30]),
            ("room.shadowCube.coffee8", [0.55, 0.49, -3.30]),
        ]
        for spec in hover {
            let cube = ModelEntity(mesh: .generateBox(size: 0.05, cornerRadius: 0.006), materials: [cubeMaterial])
            cube.name = spec.name
            cube.position = spec.position
            if flags.shadows {
                cube.components.set(GroundingShadowComponent(castsShadow: true, receivesShadow: false,
                                                             fadeBehaviorNearPhysicalObjects: .constant))
            }
            roomZone.addChild(cube)
        }

        // Light spill onto the room: a warm spot over the near table and a point light over the coffee table, each
        // with its `SurroundingsLight`, plus a virtual grey plate beside each to prove the light itself is on.
        if flags.spill {
            let spot = SurroundingsGrounding.makeSpotSpill(color: UIColor(hex: "#FFD58A"), intensity: 40000,
                                                           innerAngle: 25, outerAngle: 50, range: 3, surroundings: true)
            spot.position = [-0.30, 1.10, -1.66]
            spot.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            roomZone.addChild(spot)
            let point = SurroundingsGrounding.makePointSpill(color: UIColor(hex: "#FFB347"), intensity: 60000, radius: 2,
                                                             surroundings: true)
            point.position = [-0.05, 0.62, -3.30]
            roomZone.addChild(point)
            var grey = PhysicallyBasedMaterial()
            grey.baseColor = .init(tint: UIColor(white: 0.55, alpha: 1))
            grey.roughness = .init(floatLiteral: 0.8)
            for (position, name) in [(SIMD3<Float>(-0.46, 0.78, -1.66), "room.spillReference.near"),
                                     (SIMD3<Float>(-0.40, 0.44, -3.30), "room.spillReference.coffee")] {
                let plate = ModelEntity(mesh: .generateBox(width: 0.16, height: 0.004, depth: 0.16), materials: [grey])
                plate.name = name
                plate.position = position
                roomZone.addChild(plate)
            }
            stage.log("grounding: room spill on — spot 40000 lm + point 60000 lm, both with SurroundingsLight")
        }

        // Height finders: small horizontal plates at listed heights over the two tables. With occlusion on, a plate
        // below a table's top is hidden by it; the first visible one brackets the top.
        let finders: [(x: Float, z: Float, heights: [Float])] = [
            (-0.35, -1.62, [0.66, 0.70, 0.74, 0.78, 0.82]),
            (0.05, -3.45, [0.34, 0.38, 0.42, 0.46, 0.50]),
        ]
        let palette = ["#FF4D4D", "#FFA64D", "#FFE14D", "#5CFF7A", "#4DD2FF"]
        for finder in finders {
            for (i, h) in finder.heights.enumerated() {
                var m = UnlitMaterial(color: UIColor(hex: palette[i % palette.count]))
                m.faceCulling = .none
                let plate = ModelEntity(mesh: .generateBox(width: 0.07, height: 0.004, depth: 0.07), materials: [m])
                plate.name = String(format: "room.finder.%.2f", h)
                plate.position = [finder.x + Float(i) * 0.09, h, finder.z]
                if flags.occlusion { SurroundingsGrounding.setOcclusion(true, on: plate, recursive: false) }
                roomZone.addChild(plate)
            }
        }
        stage.log("grounding: room probes at z \(z) (opaque, translucent, dust, swiftui, parentOnly, behindBar) + finders")
    }

    // MARK: - Tick

    private func tick(_ dt: Float) {
        let t0 = CACurrentMediaTime()
        clock += Double(dt)
        let t = Float(flags.freeze ?? clock)

        if let card = nameCard {
            let bob = bobAmplitude * sin(2 * .pi * t / bobPeriod)
            card.position.y = cardCentreHeight + bob
            let t1 = CACurrentMediaTime()
            bobStats.add((t1 - t0) * 1000)
            // Lowest edge above the desk: the card's centre over the device top, minus half its (tilted) height,
            // plus the device's own thickness.
            let halfHeight = cardSize.y / 2 * cos(HologramLayout.cardTiltDegrees * .pi / 180)
            let lowest = card.position.y - halfHeight + LabStage.deviceSize.y
            pool?.update(height: lowest, brightness: 1)
            poolStats.add((CACurrentMediaTime() - t1) * 1000)
        }
        let t2 = CACurrentMediaTime()
        for entry in covers {
            let sway = 20 * Float.pi / 180 * sin(2 * .pi * t / 7 + entry.phase)
            entry.frame.orientation = simd_quatf(angle: entry.baseYaw + sway, axis: [0, 1, 0])
                * simd_quatf(angle: entry.basePitch, axis: [1, 0, 0])
        }
        if !covers.isEmpty { swayStats.add((CACurrentMediaTime() - t2) * 1000) }

        tickStats.add((CACurrentMediaTime() - t0) * 1000)
        sinceReport += dt
        if sinceReport >= 5 {
            sinceReport = 0
            stage.log(String(format: "[perf] grounding tick: mean %.4f ms · p95 %.4f ms · max %.4f ms (n=%d) · pool %.3f @ %.3f×%.3f m",
                             tickStats.mean, tickStats.percentile(95), tickStats.max, tickStats.count,
                             pool?.intensity ?? 0, pool?.halfExtent.x ?? 0, pool?.halfExtent.y ?? 0))
            stage.log(String(format: "[perf]   parts (mean / p95 / max ms): card bob %.4f / %.4f / %.4f · pool %.4f / %.4f / %.4f · cover sway %.4f / %.4f / %.4f",
                             bobStats.mean, bobStats.percentile(95), bobStats.max,
                             poolStats.mean, poolStats.percentile(95), poolStats.max,
                             swayStats.mean, swayStats.percentile(95), swayStats.max))
        }
    }

    // MARK: - Bench

    private func runBench() async {
        let names = (1...10).map { "fake-cover-\($0)" }
        let sources = names.compactMap { LivingCover.Source.named($0) }
        stage.log("[bench] \(sources.count) covers")

        // Spatial scene generation: serial, then all at once.
        var serial: [Double] = []
        var firstError: String?
        let serialStart = CACurrentMediaTime()
        for source in sources {
            let t0 = CACurrentMediaTime()
            do {
                let image = try await ImagePresentationComponent.Spatial3DImage(imageSource: source.imageSource)
                try await image.generate()
            } catch {
                if firstError == nil { firstError = String(describing: error) }
            }
            serial.append((CACurrentMediaTime() - t0) * 1000)
        }
        let serialTotal = (CACurrentMediaTime() - serialStart) * 1000
        let parallelStart = CACurrentMediaTime()
        let parallelErrors = await withTaskGroup(of: String?.self) { group -> Int in
            for source in sources {
                group.addTask { @MainActor in
                    do {
                        let image = try await ImagePresentationComponent.Spatial3DImage(imageSource: source.imageSource)
                        try await image.generate()
                        return nil
                    } catch {
                        return String(describing: error)
                    }
                }
            }
            var failures = 0
            for await result in group where result != nil { failures += 1 }
            return failures
        }
        let parallelTotal = (CACurrentMediaTime() - parallelStart) * 1000
        stage.log(String(format: "[bench] scene serial: total %.1f ms, per cover %@ ms", serialTotal,
                         serial.map { String(format: "%.1f", $0) }.joined(separator: " ")))
        stage.log(String(format: "[bench] scene parallel: total %.1f ms, %d/%d failed", parallelTotal, parallelErrors, sources.count))
        if let firstError { stage.log("[bench] scene error: \(firstError)") }

        // Live mask, serial (Vision on this device), then the layer build from bundled masks.
        var maskTimes: [String] = []
        var maskError: String?
        for source in sources {
            let image = source.image
            let t0 = CACurrentMediaTime()
            let outcome = await Task.detached { () -> String? in
                do { _ = try LivingCoverLayers.liveMask(for: image); return nil } catch { return String(describing: error) }
            }.value
            maskTimes.append(String(format: "%.1f", (CACurrentMediaTime() - t0) * 1000))
            if let outcome, maskError == nil { maskError = outcome }
        }
        stage.log("[bench] live mask serial ms: \(maskTimes.joined(separator: " "))\(maskError.map { " · first error: \($0)" } ?? "")")

        var layerTimes: [String] = []
        for source in sources + [LivingCover.Source.named("Avatar")].compactMap({ $0 }) {
            let image = source.image
            let name = source.name
            let parallax = V4.CoverParallax(size: [0.09, 0.117])
            let result = await Task.detached { () -> String in
                guard let pixels = try? LivingCoverLayers.decode(image),
                      let mask = LivingCoverLayers.bundledMask(named: name, width: pixels.width, height: pixels.height) else {
                    return "\(name): no bundled mask"
                }
                let stats = V4.CoverMaskStats.measure(mask.pixels, width: mask.width, height: mask.height)
                let t0 = CACurrentMediaTime()
                _ = try? LivingCoverLayers.makeLayers(pixels, mask: mask, parallax: parallax)
                return String(format: "%@: %@ %.3f layers %.1f ms", name, "\(stats.verdict())", stats.coverage,
                              (CACurrentMediaTime() - t0) * 1000)
            }.value
            layerTimes.append(result)
        }
        for line in layerTimes { stage.log("[bench] \(line)") }
    }

    // MARK: - Helpers

    private func count(_ root: Entity) -> Int {
        1 + root.children.reduce(0) { $0 + count($1) }
    }
}
