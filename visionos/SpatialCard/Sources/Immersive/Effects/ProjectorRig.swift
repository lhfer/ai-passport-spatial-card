import Foundation
import RealityKit
import UIKit

/// The light that carries the card: a glowing base disk + slowly turning ring on the device, ten thin rays
/// fanning from the base to the **slab's underside** (re-aimed every frame because the card billboards), a
/// flattened volumetric fan in three layers — a bright inner cone, a wide haze, and one weighted toward the
/// top so the light reads as *arriving* at the plate — and dust motes drifting in it.
///
/// v2 (工作包 B 光束): 36 rays and travelling light packets made a busy sci-fi projector; the reference image
/// is one calm beam. Ten finer, dimmer rays and a much stronger, flatter cone do the same job quietly.
@MainActor
final class ProjectorRig {
    static let cardEntityName = "hologram.cardGroup"
    /// Tappable base ring: folds the card back into the device (no settings window in this app).
    static let baseName = "projector.base"
    /// How flat the volumetric cones are squashed on Z — a fan across the card, not a searchlight.
    static let fanFlatten: Float = 0.45
    /// The base annuli live on one plane this wide; `softRing`'s radii are fractions of its half size.
    static let basePlane: Float = 0.21
    /// Inner radius of the soft base glow (0.0693 m) and of the crisp ring (0.0756…0.0882 m): both clear the
    /// 0.0603 m half-diagonal of the AI Passport's footprint prism, with room for their own breathing.
    static let baseDiscInner: Float = 0.66
    static let baseRingInner: Float = 0.72
    static let baseRingOuter: Float = 0.84
    /// Clearance between the device's outline and where a ray may start / a cone's foot may stand.
    ///
    /// 10 mm, not 5: the audit's prism is the footprint **+ 3 mm**, each ray is spread ±4 mm around its
    /// origin so ten threads do not collapse into three, and a ray climbing away covers another ~2 mm of
    /// ground in its first 5 mm. 5 mm of clearance left the middle origin's rays inside the prism for their
    /// first centimetre, which `--fake-box scan` caught; 10 mm clears it on both boxes with ~5 mm to spare.
    static let footClearance: Float = 0.010
    /// The lofted fan's foot is this much outside the device on each side (an n = 4 superellipse through
    /// those half extents contains the footprint prism's corners).
    static let fanFootMargin: SIMD2<Float> = [0.012, 0.0125]

    let root = Entity()
    /// **v4 B4 §3.5** `cmd perf`: the entities one of its layers names (`cones`, `rays`, `rig-dust`), for the switch to
    /// take out of the tree and give back.
    func perfEntities(_ layer: V4.PerfLayer) -> [Entity] {
        switch layer {
        case .cones: return [shimmer, coneTop, shimmerWide]
        case .rays: return rays
        case .rigDust: return [dust]
        default: return []
        }
    }
    private let baseDisc: ModelEntity
    private let baseRing: ModelEntity
    /// Bright inner fan.
    private let shimmer: ModelEntity
    /// Wide, very faint haze around it.
    private let shimmerWide: ModelEntity
    /// Third layer, brightening toward the slab: the light arriving rather than leaving.
    private let coneTop: ModelEntity
    private let dust = Entity()
    private var coneHolders: [Entity] = []
    /// The three origins on the device's outline the rays leave from (H0: the top edge and the two top
    /// corners), recomputed whenever the footprint changes.
    private var rayOrigins: [SIMD3<Float>] = []
    private var handMode = false
    /// **V3-6 §2** `--hand-cones off|on` (default **off**): whether the three volumetric cone layers and the
    /// base dust are drawn at all while the card is in the wearer's hand.
    ///
    /// The third headset round's first 5 s window after a **pick-up** ran at 45.0 fps with `14 emitters alive`
    /// while every window after a **summon** ran at 89–90 fps with 8–9. The one thing the pick-up path does
    /// that the summon path does not is leave this fan on the screen — three lofted shells squashed to a
    /// 55 mm shelf under a card 35 mm above them, which is a lot of overdraw for a light the card's own ten
    /// rays already explain. `put-down bloom 45.6` / `pick-up morph 46.6` / `desk fan out 67.1` are the other
    /// three moments the cones are moving.
    /// Written once, by `AppModel`'s flag parsing, before the space opens.
    ///
    /// **v4 B2.** It only holds on the paths that tell the rig the card is in a hand: every way into the hand form
    /// now does (`HologramController.syncProjectorForm`), and `[perf] scene: … cones on|off` is read off the tree
    /// (`PerfLog.coneNames`) instead of off a static that only `setHandMode` wrote.
    nonisolated(unsafe) static var handConesEnabled = false
    /// The three cone layers have been faded out and disabled for the hand form.
    private var conesParked = false
    /// What `setVisible` last asked for. The cone switch needs it because the hand form calls
    /// `setHandMode(true)` and `setVisible(true, animated: false)` back to back, and the second of those used
    /// to turn the dust and the cone opacities straight back on.
    private var wantsVisible = false
    private var rays: [Entity] = []
    private var rayQuads: [ModelEntity] = []

    /// The real device's footprint (V3-2a H0): the rays start on its outline and the base ring and the cones'
    /// feet clear it.
    private(set) var device: SIMD2<Float> = DeviceFootprint.aiPassport.size
    /// **v4 B1.** Where the case's centre is in this rig's frame (the screen frame S, 4 mm up). Everything H0 makes
    /// this rig keep *off the hardware* — the three ray origins outside the outline, the base annuli, the cones'
    /// feet — is laid out around the **case**; the rays' far ends follow the card (S), and the desk fan's top is
    /// pulled back over the screen so the beam still arrives under the card.
    private(set) var caseCenter: SIMD3<Float> = .zero

    private let fx = FXTextures.shared
    /// Ten fine rays, ordered along the slab's lower edge so they never cross.
    private let rayCount = 10
    private let shaftHeight: Float

    /// `cardWidth` / `cardHeight` are the **slab's** outer size and `targetZ` its mid-plane: the rays aim at the
    /// underside of the plate, not at the SwiftUI card's lower edge.
    init(shaftHeight: Float, cardWidth: Float, cardHeight: Float, targetZ: Float) {
        self.shaftHeight = shaftHeight
        // V3-2a H0: the base disk used to be a bright 9 cm blob centred on the screen and the three cones
        // had their apex on it. Both are annuli / shells now, with a hole the device's footprint fits through.
        baseDisc = ModelEntity(mesh: .generatePlane(width: ProjectorRig.basePlane, depth: ProjectorRig.basePlane),
                               materials: [FXMaterials.glow(fx.softRing(inner: ProjectorRig.baseDiscInner, outer: 1),
                                                            tint: .white, opacity: 0.55)])
        baseRing = ModelEntity(mesh: .generatePlane(width: ProjectorRig.basePlane, depth: ProjectorRig.basePlane),
                               materials: [FXMaterials.glow(fx.softRing(inner: ProjectorRig.baseRingInner, outer: ProjectorRig.baseRingOuter),
                                                            tint: .white, opacity: 0.45)])
        shimmer = ModelEntity(mesh: .generatePlane(width: 0.01, depth: 0.01), materials: [FXMaterials.glow(fx.coneGlow, tint: .white, opacity: 0.16)])
        shimmerWide = ModelEntity(mesh: .generatePlane(width: 0.01, depth: 0.01), materials: [FXMaterials.glow(fx.coneGlow, tint: .white, opacity: 0.06)])
        coneTop = ModelEntity(mesh: .generatePlane(width: 0.01, depth: 0.01), materials: [FXMaterials.glow(fx.coneGlowTop, tint: .white, opacity: 0.10)])
        shimmer.name = "projector.shimmer"
        shimmerWide.name = "projector.shimmerWide"
        coneTop.name = "projector.coneTop"

        baseDisc.position = [0, 0.0006, 0]
        baseDisc.name = "projector.baseDisc"
        baseRing.position = [0, 0.0009, 0]
        baseRing.name = ProjectorRig.baseName
        baseRing.components.set(InputTargetComponent())
        baseRing.components.set(HoverEffectComponent())
        baseRing.components.set(CollisionComponent(shapes: [.generateBox(width: ProjectorRig.basePlane, height: 0.012, depth: ProjectorRig.basePlane)]))
        baseRing.components.set(SpinComponent(axis: [0, 1, 0], radiansPerSecond: 0.35))
        baseRing.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.03, baseOpacity: 1, opacityAmplitude: 0.2, period: 2.6))
        baseDisc.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.05, baseOpacity: 1, opacityAmplitude: 0.25, period: 1.7, phase: 1.2))
        // Each cone lives in a holder squashed on Z: the beam is a flat *fan* spreading along the card's width,
        // not a circular searchlight. (The holder carries the squash because `PulseSystem` owns the cone's own
        // scale and writes it uniformly every frame.)
        for (cone, pulse) in [
            (shimmer, PulseComponent(baseScale: 1, scaleAmplitude: 0.02, baseOpacity: 1, opacityAmplitude: 0.30, period: 0.9)),
            (coneTop, PulseComponent(baseScale: 1, scaleAmplitude: 0.015, baseOpacity: 1, opacityAmplitude: 0.22, period: 1.6, phase: 2.1)),
            (shimmerWide, PulseComponent(baseScale: 1, scaleAmplitude: 0.03, baseOpacity: 1, opacityAmplitude: 0.25, period: 3.1, phase: 0.7)),
        ] {
            // The shell already stands on the device (foot at y = 0, opening up), so no flip; and the fan's
            // Z squash is baked into the mesh, because a holder scale would squash the foot into the
            // footprint the shell exists to stay out of.
            cone.components.set(pulse)
            let holder = Entity()
            holder.position = [0, 0, 0]
            holder.addChild(cone)
            root.addChild(holder)
            coneHolders.append(holder)
        }
        root.addChild(baseDisc)
        root.addChild(baseRing)

        // Rays: each a pivot whose +Y is aimed at its card target every frame, carrying two crossed quads.
        // Base points and targets share the parameter u along the card's lower edge, so the fan never crosses.
        for index in 0..<rayCount {
            let pivot = Entity()
            let u = Float(index) / Float(rayCount - 1) * 2 - 1              // −1…1
            pivot.components.set(ProjectorRayComponent(
                u: u, cardHalfWidth: cardWidth * 0.46, cardBottom: -cardHeight / 2, targetZ: targetZ,
                flickerPeriod: 1.1 + 0.9 * Float((index * 7) % 5) / 4, flickerPhase: Float(index) * 0.7,
                seed: UInt32(1000 + index * 7919)))
            for k in 0..<2 {
                let quad = ModelEntity(mesh: .generatePlane(width: 1, height: 1), materials: [ProjectorRig.rayMaterial(.white)])
                quad.name = "projector.ray\(index).\(k)"
                quad.orientation = simd_quatf(angle: Float(k) * .pi / 2, axis: [0, 1, 0])
                quad.position = [0, 0.5, 0]     // unit quad from y = 0 (base) to y = 1 (target)
                pivot.addChild(quad)
                rayQuads.append(quad)
            }
            root.addChild(pivot)
            rays.append(pivot)
        }
        // H0: the motes used to fill a cylinder starting at y = 0, i.e. standing in the air right over the
        // LCD. They start above the audited prism now (y ≥ 0.035) and are as wide as the base annulus.
        dust.position = [0, 0.035 + (shaftHeight - 0.035) * 0.5, 0]
        dust.name = "rig.dust"
        dust.components.set(ProjectorRig.dustEmitter(sprite: fx.particle, height: shaftHeight - 0.035))
        root.addChild(dust)
        layoutForFootprint()

        root.isEnabled = false
    }

    // MARK: - Footprint layout (V3-2a H0)

    /// Everything whose place depends on the real device's size: the three lofted fans' feet, and the three
    /// origins on the outline the rays leave from.
    private func layoutForFootprint() {
        let foot = SIMD2<Float>(device.x / 2 + ProjectorRig.fanFootMargin.x,
                                device.y / 2 + ProjectorRig.fanFootMargin.y)
        let hole = SIMD2<Float>(device.x / 2 + ProjectorRig.footClearance,
                                device.y / 2 + ProjectorRig.footClearance)
        // v4 B1: the feet (and the holders they are built in) stand around the case; the desk fan's top is offset
        // back over the screen, where the card is. (With the case centred on the screen both offsets are zero —
        // v3's rig exactly.)
        let c = caseCenter
        for holder in coneHolders { holder.position = [c.x, 0, c.z] }
        for (cone, height, radius) in [(shimmer, shaftHeight, Float(0.11)),
                                       (coneTop, shaftHeight, Float(0.105)),
                                       (shimmerWide, shaftHeight * 1.05, Float(0.16))] {
            cone.model?.mesh = handMode
                ? FXMeshes.loftedFan(height: ProjectorRig.handConeHeight, bottomHalf: foot,
                                     topHalf: [radius * 0.45, radius * 0.45 * ProjectorRig.fanFlatten],
                                     topOffset: [0, 0, -(device.y / 2)])
                : FXMeshes.loftedFan(height: height, bottomHalf: foot,
                                     topHalf: [radius, radius * ProjectorRig.fanFlatten],
                                     topOffset: [-c.x, 0, -c.z])
            cone.components.set(FootprintProbeComponent(.hole(hole)))
        }
        baseDisc.position = [c.x, 0.0006, c.z]
        baseRing.position = [c.x, 0.0009, c.z]
        baseDisc.components.set(FootprintProbeComponent(.circularHole(ProjectorRig.baseDiscInner * ProjectorRig.basePlane / 2)))
        baseRing.components.set(FootprintProbeComponent(.circularHole(ProjectorRig.baseRingInner * ProjectorRig.basePlane / 2)))
        // Three origins on the outline: the middle of the device's **top** edge (−Z, the edge the hand card hinges
        // on) and its two top corners, all `footClearance` outside the audited prism — of the case, wherever the
        // screen is on it.
        let x = device.x / 2 + ProjectorRig.footClearance
        let z = -(device.y / 2 + ProjectorRig.footClearance)
        rayOrigins = [[c.x, 0.0012, c.z + z], [c.x - x, 0.0012, c.z + z], [c.x + x, 0.0012, c.z + z]]
        for (index, pivot) in rays.enumerated() {
            guard var ray = pivot.components[ProjectorRayComponent.self] else { continue }
            ray.origin = rayOrigins[index % rayOrigins.count]
            pivot.components.set(ray)
        }
        for quad in rayQuads {
            // What the audit asks a ray is **where it leaves the device**, not where it goes.
            //
            // A 1.4 mm additive thread that starts on the outline and climbs to a card 22 cm above the desk
            // is inside the prism between roughly 10 % and 35 % of its flight, and so is *any* beam from
            // outside the footprint to a card centred over it — the rule cannot be read as forbidding the
            // beam, and the brief does not: H0.4 keeps the rays and dictates their three **origins**. So the
            // probe samples the first 5 % (≈ 5 mm, y ≤ 6 mm), which is exactly the part that used to sit on
            // the screen when the base was a 5.6 cm arc across it, and nothing further up.
            //
            // The quad is a **unit** plane whose local Y runs −0.5 (the base) to +0.5 (the target), and the
            // pivot scales it to the ray's length, so local −0.5 + f samples fraction f along the ray.
            quad.components.set(FootprintProbeComponent(.points(
                [0, 0.02, 0.05].map { SIMD3<Float>(0, -0.5 + $0, 0) })))
        }
    }

    /// The hand form (E3 / H0): the rig stays on the screen but the fan becomes a short shell leaning from
    /// the device's outline into the card's bottom edge on the hinge, and the two haze layers stand down.
    func setHandMode(_ on: Bool) {
        guard on != handMode else { return }
        handMode = on
        layoutForFootprint()
        applyHandCones(animated: true)
    }

    /// **V3-6 §2.** The one place that answers "are the cones and the base dust on right now", from
    /// `handMode` and `--hand-cones`. Everything that can change either calls it, so `setVisible(true)`
    /// arriving right after `setHandMode(true)` cannot put back what the hand form just took away.
    private func applyHandCones(animated: Bool) {
        let dustOn = conesWanted && wantsVisible
        if var emitter = dust.components[ParticleEmitterComponent.self] {
            // v4 B5 §3: times the resident motes' share (`cmd perf motes=off`, `--resident-motes lite`).
            emitter.mainEmitter.birthRate = (handMode ? 6 : 18) * dustScale
            emitter.isEmitting = dustOn
            dust.components.set(emitter)
        }
        dust.isEnabled = dustOn
        guard !conesWanted else {
            // Desk, or `--hand-cones on`: V3-5's shape, exactly — plus, when the three layers were parked,
            // the tween that parked them has to go before their opacity means anything again.
            if conesParked {
                conesParked = false
                for cone in [shimmer, shimmerWide, coneTop] { cone.components.remove(TweenComponent.self) }
            }
            shimmer.isEnabled = true
            coneTop.isEnabled = !handMode
            shimmerWide.isEnabled = !handMode
            shimmer.components.set(OpacityComponent(opacity: handMode ? 0.8 : 1))
            if !handMode {
                let level: Float = wantsVisible ? 1 : 0
                coneTop.components.set(OpacityComponent(opacity: level))
                shimmerWide.components.set(OpacityComponent(opacity: level))
            }
            return
        }
        // In the hand with the cones off: fade what is on screen over 0.25 s and take all three out of the
        // tree behind it, so they stop costing fill *and* stop being counted by `[perf] scene:`.
        conesParked = true
        for cone in [shimmer, shimmerWide, coneTop] {
            guard cone.isEnabled else { continue }
            let from = cone.components[OpacityComponent.self]?.opacity ?? 1
            cone.components.set(TweenComponent(opacity: (from: from, to: 0),
                                               duration: animated ? 0.25 : 0, easing: .easeInCubic,
                                               disableWhenDone: true))
        }
    }

    /// Are the three cone layers and the base dust drawn at all right now?
    private var conesWanted: Bool { ProjectorRig.handConesEnabled || !handMode }

    /// **v4 B5 §3.** The beam dust's share of its birth rate (`cmd perf motes=off`, `--resident-motes lite`: two-thirds).
    private var dustScale: Float = 1

    func setDustScale(_ k: Float) {
        guard k != dustScale else { return }
        dustScale = k
        guard var emitter = dust.components[ParticleEmitterComponent.self] else { return }
        emitter.mainEmitter.birthRate = (handMode ? 6 : 18) * dustScale
        dust.components.set(emitter)
    }

    /// **v4 B2.** Is the rig in its hand form? (`HologramController.syncProjectorForm` asks before it re-lays the cones.)
    var isHandMode: Bool { handMode }

    /// How tall the hand form's short shell is (the card's bottom edge sits on the hinge, 6 mm up).
    static let handConeHeight: Float = 0.055

    func configure(device: SIMD2<Float>, caseCenter: SIMD3<Float> = .zero) {
        guard device != self.device || caseCenter != self.caseCenter else { return }
        self.device = device
        self.caseCenter = caseCenter
        layoutForFootprint()
    }


    func apply(look: HologramLook) {
        apply(base: look.secondaryTint, cone: look.tint, ray: ProjectorRig.rayColor(look: look), dust: look.highlight)
    }

    /// Rays are the look's highlight pulled 30 % toward its tint: white-hot, but the same family as the cone.
    static func rayColor(look: HologramLook) -> UIColor {
        look.highlight.mixed(with: look.tint, by: 0.3)
    }

    private func apply(base: UIColor, cone: UIColor, ray: UIColor, dust dustTint: UIColor) {
        baseDisc.model?.materials = [FXMaterials.glow(fx.softRing(inner: ProjectorRig.baseDiscInner, outer: 1), tint: base, opacity: 0.55)]
        baseRing.model?.materials = [FXMaterials.glow(fx.softRing(inner: ProjectorRig.baseRingInner, outer: ProjectorRig.baseRingOuter), tint: cone, opacity: 0.45)]
        shimmer.model?.materials = [FXMaterials.glow(fx.coneGlow, tint: cone, opacity: 0.16)]
        shimmerWide.model?.materials = [FXMaterials.glow(fx.coneGlow, tint: cone, opacity: 0.06)]
        coneTop.model?.materials = [FXMaterials.glow(fx.coneGlowTop, tint: cone, opacity: 0.10)]
        for quad in rayQuads { quad.model?.materials = [ProjectorRig.rayMaterial(ray)] }
        if var emitter = dust.components[ParticleEmitterComponent.self] {
            emitter.mainEmitter.color = .evolving(start: .single(dustTint.withAlphaComponent(0.9)), end: .single(cone.withAlphaComponent(0)))
            dust.components.set(emitter)
        }
    }

    /// Whether the base ring accepts gaze + pinch (off inside worlds so taps cannot fall through to desk controls).
    func setInteractive(_ enabled: Bool) {
        // V3-4 §4: the base ring sits on the device's own footprint, so it obeys `--device-taps` too.
        baseRing.components[InputTargetComponent.self]?.isEnabled = enabled && ProjectorRig.deviceTapsEnabled
    }

    /// `--device-taps on|off`, written once by `AppModel` before the space opens.
    static var deviceTapsEnabled = false

    /// World override: base, ring and the three cones take the world colour; rays stay near-white.
    func apply(tint: UIColor) {
        apply(base: tint, cone: tint, ray: UIColor.white.mixed(with: tint, by: 0.3), dust: .white)
    }

    /// Bumped on every `setVisible`; the deferred disable only fires if no later call superseded it.
    private var visibilityGeneration = 0

    /// Show: rays grow out of the base (Y scale 0 → 1 via the ray system's `growth`), base blooms. Hide: every ray
    /// fades through `ProjectorRayComponent.targetFade` (eased by the system, which owns the rays' opacity), the
    /// root is disabled 0.32 s later unless a newer `setVisible(true)` has arrived in the meantime.
    func setVisible(_ visible: Bool, animated: Bool) {
        visibilityGeneration += 1
        wantsVisible = visible
        if visible {
            root.isEnabled = true
            for (index, pivot) in rays.enumerated() {
                if var ray = pivot.components[ProjectorRayComponent.self] {
                    ray.growth = animated ? 0 : 1
                    ray.growthDelay = animated ? 0.04 * Float(index) : 0
                    ray.targetFade = 1
                    if !animated { ray.fade = 1 }
                    pivot.components.set(ray)
                }
            }
            // **v4 B3 §3.1.** A hide now takes these five layers out of the tree at the end of its fade (below), so
            // the show switches them back on — the base always, the cones by `applyHandCones`' own rule.
            baseDisc.isEnabled = true
            baseRing.isEnabled = true
            baseDisc.components.set(TweenComponent(scale: (from: [0.3, 1, 0.3], to: [1, 1, 1]), opacity: (from: 0, to: 1), duration: animated ? 0.45 : 0, easing: .easeOutBackSoft))
            baseRing.components.set(TweenComponent(scale: (from: [0.3, 1, 0.3], to: [1, 1, 1]), opacity: (from: 0, to: 1), delay: animated ? 0.05 : 0, duration: animated ? 0.5 : 0, easing: .easeOutBackSoft))
            // **V3-6 §2.** In the hand with `--hand-cones off` there is nothing to fade up — the three
            // layers are parked, and `runHandForm` calls `setVisible(true)` one line after `setHandMode(true)`
            // precisely here, which is how the cones used to come straight back.
            if conesWanted {
                shimmer.isEnabled = true
                coneTop.isEnabled = !handMode
                shimmerWide.isEnabled = !handMode
                shimmer.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: animated ? 0.6 : 0, easing: .easeOutCubic))
                coneTop.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: animated ? 0.1 : 0, duration: animated ? 0.7 : 0, easing: .easeOutCubic))
                shimmerWide.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: animated ? 0.15 : 0, duration: animated ? 0.8 : 0, easing: .easeOutCubic))
                if var emitter = dust.components[ParticleEmitterComponent.self] { emitter.isEmitting = true; dust.components.set(emitter) }
                dust.isEnabled = true
            }
        } else {
            for pivot in rays {
                if var ray = pivot.components[ProjectorRayComponent.self] {
                    ray.targetFade = 0
                    if !animated { ray.fade = 0 }
                    pivot.components.set(ray)
                }
            }
            // **v4 B3 §3.1 (B2 §6.2).** The last 1–3 frames of every animated hide flashed back to full: each layer's
            // `PulseComponent` (base opacity 1) takes the opacity back the frame its tween ends, and the rig itself is
            // only switched off by the 0.32 s task below. So each fade takes its layer out of the tree as it ends, and
            // starts from where the layer is — a hide in the middle of a show's fade-in jumped to 1 the same way.
            for layer in [baseDisc, baseRing, shimmer, coneTop, shimmerWide] {
                let from: Float = layer.isEnabled ? (layer.components[OpacityComponent.self]?.opacity ?? 1) : 0
                layer.components.set(TweenComponent(opacity: (from: from, to: 0), duration: animated ? 0.3 : 0,
                                                    easing: .easeInCubic, disableWhenDone: true))
            }
            if var emitter = dust.components[ParticleEmitterComponent.self] { emitter.isEmitting = false; dust.components.set(emitter) }
            dust.isEnabled = false
            let generation = visibilityGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(animated ? 320 : 0))
                guard let self, generation == self.visibilityGeneration else { return }
                self.root.isEnabled = false
            }
        }
    }

    /// **V3-2a H4.** The ten threads run back into the device's outline (0.25 s, the system eases
    /// `growth` toward `targetGrowth`) — the first thing that happens when the passport is picked up, so
    /// the light is visibly *taken back* before the card leaves the desk.
    func retractRays() {
        for pivot in rays {
            guard var ray = pivot.components[ProjectorRayComponent.self] else { continue }
            ray.targetGrowth = 0
            ray.growthDelay = 0
            pivot.components.set(ray)
        }
    }

    /// …and out again, staggered.
    func growRays(staggered: Bool = true) {
        for (index, pivot) in rays.enumerated() {
            guard var ray = pivot.components[ProjectorRayComponent.self] else { continue }
            ray.targetGrowth = 1
            ray.growthDelay = staggered ? 0.03 * Float(index) : 0
            pivot.components.set(ray)
        }
    }

    /// Searching shimmer while the pose is frozen: the fan flickers more and the base ring breathes faster.
    func setSearching(_ on: Bool) {
        for pivot in rays {
            if var ray = pivot.components[ProjectorRayComponent.self] { ray.searching = on ? 1 : 0; pivot.components.set(ray) }
        }
        var pulse = baseRing.components[PulseComponent.self] ?? PulseComponent(baseScale: 1, scaleAmplitude: 0.03, baseOpacity: 1, opacityAmplitude: 0.2, period: 2.6)
        pulse.period = on ? 1.1 : 2.6
        pulse.opacityAmplitude = on ? 0.35 : 0.2
        baseRing.components.set(pulse)
    }

    /// Landing kick: all rays flare for a moment.
    func flare() {
        for pivot in rays {
            if var ray = pivot.components[ProjectorRayComponent.self] { ray.flare = 1; pivot.components.set(ray) }
        }
    }

    // MARK: - Materials

    private static func rayMaterial(_ color: UIColor) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color, texture: .init(FXTextures.shared.ray))
        material.emissiveColor = .init(color: color, texture: .init(FXTextures.shared.ray))
        material.emissiveIntensity = 3.2
        material.blending = .transparent(opacity: .init(floatLiteral: 1))
        material.opacityThreshold = nil
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    private static func dustEmitter(sprite: TextureResource, height: Float) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .cylinder
        p.emitterShapeSize = [0.045, height, 0.045]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.012
        p.speedVariation = 0.008
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 18
        p.mainEmitter.lifeSpan = 3.5
        p.mainEmitter.lifeSpanVariation = 1.2
        p.mainEmitter.size = 0.0008
        p.mainEmitter.sizeVariation = 0.0005
        p.mainEmitter.noiseStrength = 0.004
        p.mainEmitter.noiseScale = 0.8
        p.mainEmitter.opacityCurve = .gradualFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.color = .evolving(start: .single(UIColor(white: 1, alpha: 0.9)), end: .single(UIColor(white: 1, alpha: 0)))
        return p
    }
}

// MARK: - Ray aiming / flicker system

/// Per-ray state. `u` (−1…1) is the ray's position along the card's lower edge; the base point uses the same
/// parameter on a short arc of the base disk (aligned to the card each frame), so rays stay ordered and never cross.
struct ProjectorRayComponent: Component {
    /// V3-2a H0: where this ray leaves the device, in rig space. One of three points on the footprint's
    /// outline (the top edge and the two top corners) — never the screen's middle, which is where the old
    /// 5.6 cm base arc sat.
    var origin: SIMD3<Float> = [0, 0.0012, -0.0525]
    /// How far the ray has grown out of its origin, eased toward `targetGrowth` by the system: the pick-up
    /// morph retracts the whole fan into the outline by driving this to 0.
    var targetGrowth: Float = 1
    var u: Float
    var cardHalfWidth: Float
    var cardBottom: Float
    /// Depth of the aim point in card space: the slab's mid-plane, so the rays end *inside* the plate.
    var targetZ: Float
    var flickerPeriod: Float
    var flickerPhase: Float
    var seed: UInt32
    var growth: Float = 1
    var growthDelay: Float = 0
    var flare: Float = 0
    /// Visibility of this ray, eased toward `targetFade` by the system (0.3 s); the system owns the pivot's opacity.
    var fade: Float = 1
    var targetFade: Float = 1
    /// 1 while the hologram is frozen and "searching": stronger flicker dips.
    var searching: Float = 0
    var jitter: SIMD3<Float> = .zero
    var smoothTarget: SIMD3<Float>?
    var smoothBase: SIMD3<Float>?
    var elapsed: Float = 0
    /// Written by the system for diagnostics: current base and target in rig space.
    var base: SIMD3<Float> = .zero
    var target: SIMD3<Float> = .zero
    var intensity: Float = 1
}

final class ProjectorRaySystem: System {
    private static let rayQuery = EntityQuery(where: .has(ProjectorRayComponent.self))
    private static let rayWidth: Float = 0.0014
    private var time: Float = 0
    private var filmFlicker: Float = 1
    /// The card the rays aim at (`hologram.cardGroup`), found once per scene.
    private weak var cachedCard: Entity?

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("projectorRays", since: cpuStart) }
        let dt = Float(context.deltaTime)
        time += dt
        // Film flicker: a slow random gain shared by the whole fan (never below 0.85).
        filmFlicker += ((0.85 + 0.15 * Float(drand48())) - filmFlicker) * min(1, dt * 4)
        // Sweep: a soft highlight travelling across the fan (u from −1.3 to 1.3 every ~4.2 s).
        let sweepU = -1.3 + 2.6 * ((time / 4.2).truncatingRemainder(dividingBy: 1))
        // Fan rotation: the whole pattern swims ±0.04 in u, slowly.
        let swim = 0.04 * sin(time * 0.35)

        for pivot in context.entities(matching: ProjectorRaySystem.rayQuery, updatingSystemWhen: .rendering) {
            guard var ray = pivot.components[ProjectorRayComponent.self], let rig = pivot.parent else { continue }
            // v4 B5 §2: the card is looked up once and kept, not searched for by name across the whole scene once per
            // ray per frame (ten `Scene.findEntity(named:)` walks a frame, over every entity in the scene — the desk's
            // attachments, and B3's 348 prebuilt-world entities when they were still in the tree).
            if cachedCard?.scene == nil || cachedCard?.scene !== rig.scene {
                cachedCard = rig.scene?.findEntity(named: ProjectorRig.cardEntityName)
            }
            guard let card = cachedCard else { continue }
            ray.elapsed += dt
            if ray.growth < ray.targetGrowth {
                if ray.growthDelay > 0 { ray.growthDelay -= dt } else { ray.growth = min(ray.targetGrowth, ray.growth + dt / 0.45) }
            } else if ray.growth > ray.targetGrowth {
                ray.growth = max(ray.targetGrowth, ray.growth - dt / 0.25)
            }
            if ray.fade != ray.targetFade {
                let step = dt / 0.3
                ray.fade = ray.targetFade > ray.fade ? min(ray.targetFade, ray.fade + step) : max(ray.targetFade, ray.fade - step)
            }
            let fade = ray.fade * ray.fade * (3 - 2 * ray.fade)
            // Target jitter: a slow random walk of ±1.5 mm, smoothed.
            ray.seed = ray.seed &* 1664525 &+ 1013904223
            let r1 = Float(ray.seed >> 8) / Float(1 << 24) - 0.5
            ray.seed = ray.seed &* 1664525 &+ 1013904223
            let r2 = Float(ray.seed >> 8) / Float(1 << 24) - 0.5
            ray.jitter += (SIMD3<Float>(r1 * 0.003, r2 * 0.002, 0) - ray.jitter) * min(1, dt * 6)

            let u = ray.u + swim
            // Card edge target: along the lower edge with a shallow scallop, in card-local space → rig space.
            let local = SIMD3<Float>(u * ray.cardHalfWidth, ray.cardBottom + 0.012 * abs(u), ray.targetZ) + ray.jitter
            let rawTarget = card.convert(position: local, to: rig)
            // Base point: same u on a 5.6 cm arc of the disk, aligned with the card's right axis (projected flat).
            // H0: the base is one of three fixed points on the device's outline, not a 5.6 cm arc across
            // its screen. A little spread around it keeps the ten threads from collapsing into three.
            let rawBase = ray.origin + SIMD3<Float>(u * 0.004, 0, 0)
            // Smooth re-aim so a moving card is followed, not chased.
            let k = min(1, dt * 10)
            let target = ray.smoothTarget.map { $0 + (rawTarget - $0) * k } ?? rawTarget
            let base = ray.smoothBase.map { $0 + (rawBase - $0) * k } ?? rawBase
            ray.smoothTarget = target
            ray.smoothBase = base

            let delta = target - base
            let length = simd_length(delta)
            guard length > 0.001 else { continue }
            pivot.position = base
            pivot.orientation = simd_quatf(from: [0, 1, 0], to: delta / length)
            let grown = 1 - pow(1 - ray.growth, 3)
            pivot.scale = [ProjectorRaySystem.rayWidth, length * grown, ProjectorRaySystem.rayWidth]

            // Intensity: breathing + sweep highlight + rare flicker dips + landing flare + film flicker.
            let breathe = 0.75 + 0.25 * sin(ray.elapsed / ray.flickerPeriod * 2 * .pi + ray.flickerPhase)
            let sweep = exp(-pow((ray.u - sweepU) / 0.22, 2))
            ray.seed = ray.seed &* 1664525 &+ 1013904223
            let spark = Float(ray.seed >> 8) / Float(1 << 24)
            let dipChance: Float = ray.searching > 0.5 ? 0.965 : 0.992
            let dip: Float = spark > dipChance ? (ray.searching > 0.5 ? 0.3 : 0.4) : 1
            ray.flare = max(0, ray.flare - dt * 2.5)
            let intensity = (0.22 * breathe + 0.30 * sweep) * dip * filmFlicker + 0.6 * ray.flare
            pivot.components.set(OpacityComponent(opacity: min(1, intensity * grown * fade)))
            ray.base = base; ray.target = target; ray.intensity = intensity
            pivot.components.set(ray)
        }
    }
}
