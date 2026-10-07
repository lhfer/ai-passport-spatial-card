import Foundation
import QuartzCore
import RealityKit
import SwiftUI
import UIKit

/// **The hero card** (v4 A4): a limited-edition holographic collectible — a pale, luminous frosted crystal slab
/// 12 mm thick — rising out of the passport's screen.
///
/// Tree (card frame: origin at the centre of the slab's front face, +Z towards the reader):
///
///     root                    ← pose in the device's screen frame S (entrance / breath / exit), tap target
///     ├─ slab                 z −6 mm (12 mm thick, front face at 0)                               ┐
///     ├─ frost                z +0.15 mm  the pale face (opaque; off when the style's slab is frost) │
///     ├─ foil                 z +0.25 mm  holo foil tint                                           │ HeroCardSurface,
///     ├─ rim / halo           z +0.3 mm   edge light inside / glow outside the edge (Fresnel)       │ dressed by a
///     ├─ goldLine             z +0.35 mm  1.5 mm in from the edge                                   │ CardSurfaceStyle
///     ├─ sweep                z +1.2 mm   diagonal light sweep (additive)                           ┘ (A1 replaces it)
///     ├─ shadowCaster         z −12.5 mm  opaque PBR plate: the desk shadow (nothing else casts one)
///     ├─ type                 z +0.9 mm   SwiftUI (ViewAttachmentComponent): name, handle, count, tags
///     ├─ frame                z +0.9 mm   the art window's gold rule
///     ├─ sky / shadow / figure / steam   the pop-up: 3 / ≈3.4 / 10 / 18 mm when open
///     ├─ dust × digits        gold motes over the odometer's reels
///     └─ sparkle              the four-point star on the landing beat
///
/// Everything moves by **sampling `V4.HeroCardTimeline` at a time `t`** — no tweens in flight — so a restart is just
/// `t = 0`, a screenshot can freeze any instant, and what the tests check is what plays.
@MainActor
final class HeroCardRig {
    let layout: V4.HeroCardLayout
    /// The entrance being played (v4 B1: A4's rise, the recognition's in-place reveal, or the rise without the
    /// count — see `restart(with:)`).
    private(set) var timeline = V4.HeroCardTimeline()
    let faceModel: HeroCardFaceModel
    let root: Entity
    /// Draw order among the card's see-through pieces (depth writes are off on all of them).
    let sortGroup: ModelSortGroup
    let surface: HeroCardSurface
    private(set) var style: CardSurfaceStyle
    /// The only part of the card that casts its desk shadow (see the note where it is built).
    let shadowCaster: ModelEntity
    let type = Entity()
    /// The pop-up, back to front: 0 sky (window), 1 figure, 2 steam; plus the figure's shadow on the sky.
    let layers: [ModelEntity]
    let shadow: ModelEntity
    /// The art window's double gold rule (inner 1 mm line, outer hairline), in the sort group behind the pop-up.
    let frame = Entity()
    let sparkle: ModelEntity
    private var dust: [Entity] = []
    /// Where the eye is, in world space (the lab: the simulator's camera; the product: the device anchor).
    var viewerPosition: () -> SIMD3<Float> = { [0, 1.59, 0] }
    /// Extra turn about the vertical (lab: oblique close-ups — the simulator's camera cannot move).
    var yaw: Float = 0
    /// Where the card starts: the LCD's lit area, so the entrance lifts the screen's own picture off.
    let startScale: Float

    private var odometer: V4.HeroCardOdometer
    private var pops: [V4.HeroCardOdometer.Pop]
    private var digitLayout: V4.HeroCardDigitLayout
    private var firedPops = 0
    /// **v4 B1**: a live follower change rolls on its own clock (seconds since `setFollowers`), independent of the
    /// entrance's; nil while the entrance's own count is the one on the reels.
    private var recountStartedAt: Double?
    /// **v4 B1**: the type, frame and pop-up's shared opacity during the in-place reveal (written when it changes).
    private var lastContentOpacity: Float = -1
    private var lastCasterOpacity: Float = -1
    private var sweepTimes: [Double]
    private var lastOpacity: Float = -1
    private var lastCountTime: Double = .nan
    private var lastNumeric = -1
    private var lastShadowOpacity: Float = -1
    private var lastSparkleOpacity: Float = -1
    private var lastGlint: Double = -1

    // Perf (own CPU per frame, `CACurrentMediaTime`).
    private(set) var perfFrames = 0
    private(set) var perfTotal: Double = 0
    private(set) var perfMax: Double = 0
    /// Frames over 0.4 ms since the last `takePerf()`: (milliseconds, entrance clock).
    private(set) var slowFrames: [(ms: Double, t: Double)] = []
    private var clock: Double = 0

    static let typeZ: Float = 0.0009
    /// The shadow lies on the sky, 0.4 mm above it.
    static let shadowLift: Float = 0.0004
    static let sparkleSize: Float = 0.011

    // MARK: - Build

    static func make(shape: V4.HeroCardShape, content: HeroCardContent, style: CardSurfaceStyle,
                     odometerStyle: HeroCardOdometerStyle, screen: SIMD2<Float>) async -> HeroCardRig {
        var descriptor = UnlitMaterial.Program.Descriptor()
        descriptor.blendMode = .add
        descriptor.applyPostProcessToneMap = false
        let additive = await UnlitMaterial.Program(descriptor: descriptor)
        return HeroCardRig(layout: V4.HeroCardLayout(shape: shape), content: content, style: style,
                           odometerStyle: odometerStyle, screen: screen, additive: additive)
    }

    private init(layout: V4.HeroCardLayout, content: HeroCardContent, style: CardSurfaceStyle,
                 odometerStyle: HeroCardOdometerStyle, screen: SIMD2<Float>, additive: UnlitMaterial.Program) {
        self.layout = layout
        self.style = style
        let model = HeroCardFaceModel(layout: layout, content: content, style: odometerStyle)
        faceModel = model
        odometer = model.odometer
        pops = model.odometer.pops()
        digitLayout = V4.HeroCardDigitLayout(target: model.odometer.target)
        startScale = layout.screenScale(screen: screen)
        sweepTimes = V4.HeroCardTimeline().sweepTimes(until: 3600)
        let cardRoot = Entity()
        root = cardRoot
        let group = ModelSortGroup(depthPass: nil)
        sortGroup = group
        surface = HeroCardSurface(layout: layout, root: cardRoot, sortGroup: group)

        // The brief's desk shadow. Measured with `--card-shadow-probe`: in this runtime only **opaque lit** materials
        // cast a grounding shadow — unlit (the frost) and transparent (the crystal) cast nothing, so a card with the
        // component on both left the desk pixel-identical to one without it. The caster is an opaque PBR plate, the
        // content box's silhouette 8 mm smaller, just behind the slab. It is frost-coloured: the placeholder's opaque
        // frost hides it, but A1's CrystalSlab is ≈ 42 % frost, and a dark plate would show through it.
        var casterMaterial = PhysicallyBasedMaterial()
        casterMaterial.baseColor = .init(tint: HeroCardTextures.frostBottom)
        casterMaterial.roughness = .init(floatLiteral: 1)
        casterMaterial.faceCulling = .none
        let casterInset: Float = 0.008
        let caster = ModelEntity(mesh: .generatePlane(width: layout.panel.width - 2 * casterInset,
                                                      height: layout.panel.height - 2 * casterInset,
                                                      cornerRadius: max(0.002, layout.panelCornerRadius - casterInset)),
                                 materials: [casterMaterial])
        caster.name = "card.shadowCaster"
        caster.position = [layout.panel.midX, layout.panel.midY, -V4.HeroCardLayout.thickness - 0.0005]
        caster.components.set(GroundingShadowComponent(castsShadow: true))
        shadowCaster = caster

        // The pop-up. All four share the avatar quad, so they register pixel-for-pixel; the sky alone is cut to the
        // window (a rounded plane sampling its part of the image).
        let quad = layout.avatarQuad
        let origin = quad.center
        func art(_ name: String) -> UnlitMaterial {
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            if let texture = HeroCardTextures.bundled(name) {
                material.color = .init(tint: .white, texture: .init(texture, sampler: HeroCardTextures.clampSampler))
            } else {
                material.color = .init(tint: HeroCardPalette.indigo)
            }
            material.blending = .transparent(opacity: .init(floatLiteral: 1))
            material.opacityThreshold = nil
            material.faceCulling = .none
            material.writesDepth = false
            return material
        }
        var skyMaterial = art("v4-avatar-back")
        skyMaterial.blending = .opaque
        let sky = ModelEntity(mesh: HeroCardMeshes.roundedPlane(layout.artWindow, radius: layout.artCornerRadius,
                                                                origin: origin, uv: layout.avatarUV),
                              materials: [skyMaterial])
        sky.name = "card.pop.sky"
        let figure = ModelEntity(mesh: .generatePlane(width: quad.width, height: quad.height), materials: [art("v4-avatar-figure")])
        figure.name = "card.pop.figure"
        let steam = ModelEntity(mesh: .generatePlane(width: quad.width, height: quad.height), materials: [art("v4-avatar-steam")])
        steam.name = "card.pop.steam"
        // The shadow lies on the sky, so it is cut to the same window (its down-right offset is baked in the PNG):
        // on a full quad it hung below the window as a dark veil over the panel (round 2).
        shadow = ModelEntity(mesh: HeroCardMeshes.roundedPlane(layout.artWindow, radius: layout.artCornerRadius,
                                                               origin: origin, uv: layout.avatarUV),
                             materials: [art("v4-avatar-shadow")])
        shadow.name = "card.pop.shadow"
        layers = [sky, figure, steam]

        // The sparkle is laid on (alpha) in a warm gold, not added: added onto the pale frost it bleached to nothing.
        var sparkleMaterial = UnlitMaterial(applyPostProcessToneMap: false)
        sparkleMaterial.color = .init(tint: UIColor(hex: "#E0A93A"), texture: .init(HeroCardTextures.sparkle()))
        sparkleMaterial.blending = .transparent(opacity: .init(floatLiteral: 1))
        sparkleMaterial.faceCulling = .none
        sparkleMaterial.writesDepth = false
        sparkle = ModelEntity(mesh: .generatePlane(width: Self.sparkleSize * 2, height: Self.sparkleSize * 2),
                              materials: [sparkleMaterial])
        sparkle.name = "card.sparkle"

        root.name = "card.root"
        for entity in surface.entities { root.addChild(entity) }
        root.addChild(shadowCaster)
        type.name = "card.type"
        type.position = [0, 0, Self.typeZ]
        type.components.set(ViewAttachmentComponent(rootView: HeroCardFaceView(model: faceModel)))
        root.addChild(type)
        for layer in layers {
            layer.position = [origin.x, origin.y, 0]
            root.addChild(layer)
        }
        root.addChild(shadow)
        shadow.position = [origin.x, origin.y, 0]
        let rules = Self.buildFrame(layout: layout)
        frame.name = "card.frame"
        frame.position = [layout.artWindow.midX, layout.artWindow.midY, Self.typeZ]
        for rule in rules { frame.addChild(rule) }
        root.addChild(frame)
        root.addChild(sparkle)
        sparkle.components.set(OpacityComponent(opacity: 0))
        buildDust()

        // Draw order: the surface's six (orders 0–5, see `HeroCardSurface`), then frame, pop-up, sparkle.
        let order: [(Entity, Int32)] = [(surface.slab, 0), (surface.frost, 1), (surface.foil, 2), (surface.halo, 3),
                                        (surface.rim, 3), (surface.goldLine, 4), (surface.sweep, 5), (rules[0], 6),
                                        (rules[1], 6), (sky, 7), (shadow, 8), (figure, 9), (steam, 10), (sparkle, 11)]
        for (entity, index) in order { entity.components.set(ModelSortGroupComponent(group: group, order: index)) }

        style.apply(to: surface)
        apply(at: 0)
    }

    /// A crisp warm-gold line 0.9 mm outside the sky and a faint old-gold hairline 3.4 mm out: the engraved frame of
    /// a collectible, not a UI border.
    private static func buildFrame(layout: V4.HeroCardLayout) -> [ModelEntity] {
        let window = layout.artWindow, r = layout.artCornerRadius
        func rule(outset: Float, width: Float, color: UIColor, opacity: Float) -> ModelEntity {
            let e = outset + width
            let mesh = FXMeshes.roundedRectRing(width: window.width + 2 * e, height: window.height + 2 * e,
                                                radius: r + e, thickness: width)
            var material = UnlitMaterial(applyPostProcessToneMap: false)
            material.color = .init(tint: color)
            material.faceCulling = .none
            if opacity < 1 {
                material.blending = .transparent(opacity: .init(floatLiteral: opacity))
                material.writesDepth = false
            }
            return ModelEntity(mesh: mesh, materials: [material])
        }
        // Deep gold on the pale frost (warm-gold lines vanished into its warm edge light).
        let inner = rule(outset: 0.0009, width: 0.0010, color: UIColor(hex: "#A67C2E"), opacity: 1)
        inner.name = "card.frame.inner"
        let outer = rule(outset: 0.0034, width: 0.00045, color: UIColor(hex: "#A67C2E"), opacity: 0.55)
        outer.name = "card.frame.outer"
        return [inner, outer]
    }

    /// Swap the material stack (A1's ShaderGraph style in place of the placeholder), keeping everything else.
    func setStyle(_ newStyle: CardSurfaceStyle) {
        style = newStyle
        newStyle.apply(to: surface)
    }

    /// One emitter per digit reel, just above its figure: bursts of 1–2 soft round motes (bible §4 gold dust).
    private func buildDust() {
        let sprites = HeroCardTextures.dustSprites()
        for reel in 0..<digitLayout.digitCount {
            let emitter = Entity()
            emitter.name = "card.dust.\(reel)"
            emitter.components.set(Self.dustEmitter(sprites: sprites))
            root.addChild(emitter)
            dust.append(emitter)
        }
        placeOnCount()
    }

    /// The count's box in the card frame, metres: where SwiftUI laid it out once it has reported, estimated before.
    private var countBox: (left: Float, top: Float, width: Float) {
        let ppm = V4.HeroCardLayout.pointsPerMeter
        if let frame = faceModel.countFrame {
            return (Float(frame.minX) / ppm - layout.size.x / 2, layout.size.y / 2 - Float(frame.minY) / ppm,
                    Float(frame.width) / ppm)
        }
        return (layout.textLeft, layout.statsTopEstimate, digitLayout.widthEm * layout.followerSize / ppm)
    }

    /// Top of the figures inside the reels: the reel's top plus the margin above New York's 0.70 em lining figures.
    private var figureTop: Float {
        let em = layout.followerSize / V4.HeroCardLayout.pointsPerMeter
        return countBox.top - (Float(HeroCardReels.rowEm) - 0.70) / 2 * em
    }

    private var placedCountFrame: CGRect?

    /// Dust over each reel's centre, 1.5 mm above the figures; re-run whenever SwiftUI reports a new frame.
    private func placeOnCount() {
        placedCountFrame = faceModel.countFrame
        let em = layout.followerSize / V4.HeroCardLayout.pointsPerMeter
        let box = countBox, top = figureTop
        for (reel, emitter) in dust.enumerated() {
            emitter.position = [box.left + digitLayout.centerEm(ofReel: reel) * em, top + 0.0015, 0.003]
        }
    }

    private static func dustEmitter(sprites: TextureResource) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .point
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        // A hop, not a fountain: at 0.075 m/s (round 5) the motes rose onto the handle line above the count.
        p.speed = 0.055
        p.speedVariation = 0.02
        p.isEmitting = false
        p.burstCount = 1
        p.burstCountVariation = 0
        p.simulationState = .play
        p.spawnedEmitter = nil
        p.mainEmitter.birthRate = 0
        p.mainEmitter.image = sprites
        var sequence = ParticleEmitterComponent.ParticleEmitter.ImageSequence()
        sequence.rowCount = 2
        sequence.columnCount = 2
        sequence.frameRate = 5.5                 // ± 2.5 → a 3–8 Hz twinkle
        sequence.frameRateVariation = 2.5
        sequence.initialFrameVariation = 3
        sequence.animationMode = .looping
        p.mainEmitter.imageSequence = sequence
        p.mainEmitter.lifeSpan = 1.05
        p.mainEmitter.lifeSpanVariation = 0.35  // 0.7–1.4 s (bible 0.6–1.6)
        p.mainEmitter.size = 0.0024
        p.mainEmitter.sizeVariation = 0.0006    // 1.8–3.0 mm (bible 1–3): smaller vanished at 0.45 m without bloom
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.55
        p.mainEmitter.spreadingAngle = 0.45
        p.mainEmitter.acceleration = [0, -0.16, 0]
        p.mainEmitter.dampingFactor = 1.6
        // Warm gold → gold, laid on rather than added: over the pale frost additive gold bleached to white and
        // vanished. (Where they rise past the card's edge into the dark they read either way.)
        p.mainEmitter.color = .evolving(start: .single(UIColor(hex: "#D39A2C")),
                                        end: .single(HeroCardPalette.gold.withAlphaComponent(0)))
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.blendMode = .alpha
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.billboardMode = .billboard
        return p
    }

    // MARK: - Playback

    /// Back to the first frame of the entrance: dust re-armed, count at zero.
    func restart() {
        firedPops = 0
        lastCountTime = .nan
        lastNumeric = -1
        apply(at: 0)
    }

    /// **v4 B1.** Play another entrance from its first frame: the recognition's in-place reveal
    /// (`HeroCardTimeline.revealInPlace()`), the rise without the count (a reentry), or A4's own. The count starts
    /// from zero only when the timeline counts up; otherwise the reels stand on the current number.
    func restart(with timeline: V4.HeroCardTimeline) {
        self.timeline = timeline
        sweepTimes = timeline.sweepTimes(until: 3600)
        recountStartedAt = nil
        if timeline.countsUp, odometer.start != 0 {
            setOdometer(V4.HeroCardOdometer(target: odometer.target))
        }
        firedPops = timeline.countsUp ? 0 : pops.count
        lastCountTime = .nan
        lastNumeric = -1
        lastGlint = -1
        lastContentOpacity = -1
        lastCasterOpacity = -1
        apply(at: 0)
    }

    /// **v4 B1 §3: the live follower count.** Rolls the reels from what they show now to `to` — only the columns
    /// whose digit changes turn (`HeroCardOdometer.start`), on a clock of its own, with the landing's gold dust; the
    /// entrance's sparkle and glint are not replayed (the celebration around it is v3's, unchanged). While the card
    /// is off screen (`animated` false) the number is simply set, so the next entrance counts to it.
    func setFollowers(_ to: Int, animated: Bool) {
        let target = max(0, to)
        guard target != odometer.target else { return }
        let shown = currentDisplayedCount
        let from = animated ? shown : target
        setOdometer(V4.HeroCardOdometer(target: target, start: from))
        firedPops = animated ? 0 : pops.count
        recountStartedAt = animated ? clock : nil
        lastCountTime = .nan
        lastNumeric = -1
        print("[v4] card followers \(shown) → \(target)\(animated ? " (rolling the changed digits)" : " (set, off screen)")")
    }

    /// What the reels read right now.
    var currentDisplayedCount: Int {
        let t = lastCountTime.isNaN ? odometer.landing + 1 : lastCountTime
        return t < 0 ? odometer.start : odometer.displayed(at: t)
    }

    private func setOdometer(_ new: V4.HeroCardOdometer) {
        let digits = V4.HeroCardDigitLayout(target: new.target)
        odometer = new
        pops = new.pops()
        faceModel.odometer = new
        if digits.digitCount != digitLayout.digitCount {
            digitLayout = digits
            for emitter in dust { emitter.removeFromParent() }
            dust.removeAll()
            buildDust()
        }
    }

    /// The entrance and idle at time `t` (seconds since the entrance started).
    func apply(at t: Double) {
        let started = CACurrentMediaTime()
        clock = t
        defer { record(CACurrentMediaTime() - started) }
        let pose: V4.HeroCardTimeline.Pose
        if t < timeline.entranceDuration {
            pose = timeline.pose(at: t, startScale: startScale)
        } else {
            var rest = timeline.restPose
            rest.position.y += timeline.breath(atIdle: t - timeline.entranceDuration)
            pose = rest
        }
        place(pose)
        applyLayers(at: t)
        applyContent(at: t)
        if faceModel.countFrame != placedCountFrame { placeOnCount() }
        applyCount(at: t)
        applySparkle(at: t)
        updateSurface(sweep: timeline.sweep(at: t, times: sweepTimes).map(Float.init))
    }

    /// v4 B1: in the in-place reveal the type, the frame and the pop-up come up behind the dissolve's front (the
    /// slab itself is the style's, see `MagicCardSurfaceStyle.setReveal`). Written only when it changes.
    private func applyContent(at t: Double) {
        let caster = Float(timeline.casterOpacity(at: t))
        if abs(caster - lastCasterOpacity) > 0.002 {
            lastCasterOpacity = caster
            // Whole again = no opacity component at all: the caster is the card's one opaque lit plate (the only kind
            // that casts a grounding shadow, A4 §2).
            if caster >= 0.999 {
                shadowCaster.components.remove(OpacityComponent.self)
            } else {
                shadowCaster.components.set(OpacityComponent(opacity: caster))
            }
        }
        let opacity = Float(timeline.contentOpacity(at: t))
        guard abs(opacity - lastContentOpacity) > 0.002 else { return }
        lastContentOpacity = opacity
        for entity in [type, frame] + layers.map({ $0 as Entity }) {
            entity.components.set(OpacityComponent(opacity: opacity))
        }
        lastShadowOpacity = -1        // the pop-up's shadow multiplies it in on its next write
    }

    /// The exit (lab loop reset) at `e` seconds into it, from the pose idle ended on.
    func applyExit(at e: Double, idleTime: Double) {
        let started = CACurrentMediaTime()
        defer { record(CACurrentMediaTime() - started) }
        var from = timeline.restPose
        from.position.y += timeline.breath(atIdle: idleTime)
        place(timeline.exitPose(at: e, from: from, startScale: startScale))
        updateSurface(sweep: nil)
    }

    /// Freeze-frame support (`--card-freeze`): re-pop the dust of the last half second, so a still of the count
    /// shows motes in flight the way a moving shot would.
    func replayRecentDust(at t: Double) {
        let countTime = timeline.odometerTime(at: t)
        for pop in pops where pop.time <= countTime && countTime - pop.time < 0.5 { burst(pop) }
    }

    private func place(_ pose: V4.HeroCardTimeline.Pose) {
        let rotation = simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: pose.pitch, axis: [1, 0, 0])
        root.transform = Transform(scale: SIMD3<Float>(repeating: pose.scale), rotation: rotation, translation: pose.position)
        if abs(pose.opacity - lastOpacity) > 0.001 {
            root.components.set(OpacityComponent(opacity: pose.opacity))
            lastOpacity = pose.opacity
        }
    }

    private func applyLayers(at t: Double) {
        var lifts: [Float] = []
        for (index, entity) in layers.enumerated() {
            let layer = timeline.layer(index, at: t)
            entity.position.z = layer.height
            entity.scale = SIMD3<Float>(repeating: layer.scale)
            lifts.append(layer.lift)
        }
        // The sticker's shadow lies on the sky (down-right: the room's lamp is above-left) and darkens as the figure
        // lifts off it — flat, the figure touches the sky and casts nothing.
        let figureLift = max(0, min(1.06, lifts[1]))
        shadow.position.z = layers[0].position.z + Self.shadowLift
        shadow.scale = layers[0].scale
        let opacity = 0.85 * min(1, figureLift) * max(0, lastContentOpacity < 0 ? 1 : lastContentOpacity)
        if abs(opacity - lastShadowOpacity) > 0.002 {
            shadow.components.set(OpacityComponent(opacity: opacity))
            lastShadowOpacity = opacity
        }
    }

    private func applyCount(at t: Double) {
        // v4 B1: a live change (`setFollowers`) runs on its own clock; otherwise the entrance's.
        let countTime = recountStartedAt.map { t - $0 } ?? timeline.odometerTime(at: t)
        let clamped = min(max(countTime, -0.05), odometer.landing + 0.05)
        if clamped != lastCountTime {
            lastCountTime = clamped
            faceModel.countTime = clamped
            if faceModel.style == .numeric {
                // 20 Hz steps, each rolled by SwiftUI's numericText transition.
                let stepped = clamped < 0 ? odometer.start : odometer.displayed(at: (clamped * 20).rounded(.down) / 20)
                let value = clamped >= odometer.duration ? odometer.target : stepped
                if value != lastNumeric {
                    lastNumeric = value
                    faceModel.numericValue = value
                }
            }
        }
        while firedPops < pops.count, pops[firedPops].time <= countTime {
            burst(pops[firedPops])
            firedPops += 1
        }
        // The gold glint over the landed count (−1 outside its 0.6 s; written only when it changes).
        let glint = timeline.glint(at: t) ?? -1
        if glint != lastGlint {
            lastGlint = glint
            faceModel.glint = glint
        }
    }

    private func burst(_ pop: V4.HeroCardOdometer.Pop) {
        let reel = digitLayout.reel(ofColumn: pop.column)
        guard dust.indices.contains(reel), var emitter = dust[reel].components[ParticleEmitterComponent.self] else { return }
        emitter.burstCount = pop.count
        emitter.burst()
        PerfCensus.noteBurst(pop.count, life: emitter.mainEmitter.lifeSpan)
        dust[reel].components.set(emitter)
    }

    private func applySparkle(at t: Double) {
        guard let x = timeline.sparkle(at: t) else {
            if lastSparkleOpacity != 0 {
                sparkle.components.set(OpacityComponent(opacity: 0))
                lastSparkleOpacity = 0
            }
            return
        }
        // At the top-right shoulder of the count: pops open fast, closes slower, turning a little.
        let box = countBox
        sparkle.position = [box.left + box.width - 0.003, figureTop - 0.001, 0.004]
        let open = Float(sin(Double.pi * min(1, x * 1.6)))
        let s = max(0.001, Float(x < 0.35 ? sin(Double.pi / 2 * x / 0.35) : 1 - 0.4 * (x - 0.35) / 0.65))
        sparkle.scale = SIMD3<Float>(repeating: s)
        sparkle.orientation = simd_quatf(angle: Float(x) * 0.5, axis: [0, 0, 1])
        let opacity = max(0, Float(sin(Double.pi * x))) * max(open, 0.2)
        sparkle.components.set(OpacityComponent(opacity: opacity))
        lastSparkleOpacity = opacity
    }

    private func updateSurface(sweep: Float?) {
        let world = root.transformMatrix(relativeTo: nil)
        let normal = simd_normalize(SIMD3<Float>(world.columns.2.x, world.columns.2.y, world.columns.2.z))
        let centre = SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        let toViewer = viewerPosition() - centre
        let facing = V4.HeroCardLook.facing(normal: normal, toViewer: toViewer)
        let view = simd_length(toViewer) > 1e-5 ? simd_normalize(toViewer) : SIMD3<Float>(0, 0, 1)
        let local = root.convert(direction: view, from: nil)
        let viewInCard = simd_length(local) > 1e-6 ? simd_normalize(local) : SIMD3<Float>(0, 0, 1)
        style.update(surface, facing: facing, viewInCard: viewInCard, sweep: sweep)
    }

    // MARK: - Perf

    private func record(_ seconds: Double) {
        perfFrames += 1
        perfTotal += seconds
        perfMax = max(perfMax, seconds)
        if seconds > 0.0004, slowFrames.count < 8 { slowFrames.append((seconds * 1000, clock)) }
    }

    /// Average and worst own CPU per frame since the last call, milliseconds, and the frames over 0.4 ms.
    func takePerf() -> (frames: Int, averageMs: Double, maxMs: Double, slow: [(ms: Double, t: Double)]) {
        defer { perfFrames = 0; perfTotal = 0; perfMax = 0; slowFrames = [] }
        guard perfFrames > 0 else { return (0, 0, 0, []) }
        return (perfFrames, perfTotal / Double(perfFrames) * 1000, perfMax * 1000, slowFrames)
    }

    /// Entities this card keeps alive (budget: ≤ 60).
    var entityCount: Int {
        var count = 0
        func walk(_ e: Entity) { count += 1; e.children.forEach(walk) }
        walk(root)
        return count
    }
}
