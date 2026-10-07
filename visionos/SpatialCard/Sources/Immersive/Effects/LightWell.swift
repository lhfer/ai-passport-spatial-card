import Foundation
import RealityKit
import UIKit

/// A sunken, lit shaft under the tracked image (design round 4, item 3). The image rectangle — exactly its
/// physical size — is a `PortalComponent` window into a small `WorldComponent` scene: four glowing walls
/// going down, receding ring frames, a bright floor and mist drifting up toward the mouth. The ink /
/// pixels rise out of it during the reveal. Everything is anchor-local, so it follows the ImageAnchor.
///
/// M1b: the shaft no longer seals at the end of the reveal — it stays open, *dimmed* to
/// `HologramLayout.wellIdleLevel`, for the whole idle life of the card, because the depth under the device is the
/// strongest 3D cue on the desk and losing it left the card looking pasted on. Only the light dims; the geometry
/// stays fully open. `--well-level 0` restores v1 (close at the end of the reveal).
@MainActor
final class LightWell {
    /// `--well edge|portal`. **V3-2a H0**: the portal's mouth is a virtual hole drawn exactly over the real
    /// LCD, which is the single biggest reason the hardware could not be filmed. In `edge` (the default) the
    /// portal and the whole shaft below it stay disabled and the well becomes a glow ring hugging the device
    /// **from the outside** — the same light, moved off the screen. `portal` restores the v2 look.
    enum Mode: String, Equatable { case edge, portal }

    /// Set before the first `open`; changing it later takes effect on the next call.
    static var mode: Mode = .edge

    let root = Entity()
    /// The edge glow (H0): a rounded-rect ring outside the device's footprint, in the device plane.
    private let edge: ModelEntity
    /// Clear gap between the device's outline and the ring's inner edge. The brief asks for 2 mm; the audit
    /// prism is the footprint **plus 3 mm**, so the ring starts 2 mm outside *that* — otherwise the very rule
    /// this ring exists to satisfy would report it forever.
    static let edgeGap: Float = 0.005
    /// Radial width of the band.
    static let edgeWidth: Float = 0.015
    /// Ring opacity at `level` 1.
    static let edgeOpacity: Float = 0.75
    private let portal: ModelEntity
    private let world = Entity()
    private let depthRoot = Entity()
    private var walls: [ModelEntity] = []
    private var rings: [ModelEntity] = []
    private let floor: ModelEntity
    private let mist = Entity()
    private let fx = FXTextures.shared
    private(set) var footprint: SIMD2<Float>
    private(set) var device: SIMD2<Float> = DeviceFootprint.aiPassport.size
    /// **v4 B1.** Where the case's centre is in this rig's frame (the screen frame S). The portal is the **screen**
    /// (its mouth stays on S's origin, the LCD's lit size); the edge glow hugs the **case** and is centred here.
    private(set) var caseCenter: SIMD3<Float> = .zero
    private(set) var isOpen = false
    /// Physical depth of the shaft when fully open.
    private let depth: Float = 0.30
    /// Current light level (1 = the reveal's full shaft, `wellIdleLevel` while idle).
    private(set) var level: Float = 1
    /// Bumped by every `open` / `dim` / `hide`: the delayed `portal.isEnabled = false` that `close` schedules is
    /// only allowed to fire if nothing overtook it. `!isOpen` alone was enough while the well always closed for
    /// good; now a `dim` during a closing tween reopens it and the stale disable would blank the portal after it.
    private var closeGeneration = 0
    /// Mist density at full brightness (`mistEmitter` builds the emitter with it; `dim` scales it).
    private static let mistBirthRate: Float = 90
    /// Ring breathing amplitude at full brightness.
    private static let ringOpacityAmplitude: Float = 0.35
    /// The edge glow's colour (`look.tint`, or a world's override).
    private var edgeTint: UIColor = .white

    init(footprint: SIMD2<Float>) {
        self.footprint = footprint
        portal = ModelEntity(mesh: .generatePlane(width: footprint.x, depth: footprint.y), materials: [PortalMaterial()])
        edge = ModelEntity(mesh: .generatePlane(width: 0.1, depth: 0.1), materials: [UnlitMaterial(color: .clear)])
        floor = ModelEntity(mesh: .generatePlane(width: footprint.x * 0.9, depth: footprint.y * 0.9), materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: .white, opacity: 1)])
        root.position = [0, -0.0006, 0]          // just under the registration quads
        world.components.set(WorldComponent())
        portal.components.set(PortalComponent(target: world, clippingMode: .plane(.positiveY), crossingMode: .plane(.positiveY)))
        root.addChild(portal)
        root.addChild(world)
        root.addChild(edge)
        world.addChild(depthRoot)
        portal.name = "well.portal"
        world.name = "well.world"
        edge.name = "well.edge"
        // The ring lies 1 mm above the device's top face (`root` is 0.6 mm under the registration quads).
        edge.position = [0, 0.0016, 0]
        edge.isEnabled = false
        edge.components.set(OpacityComponent(opacity: 0))
        buildEdge()
        build()
        world.components.set(OpacityComponent(opacity: 0))
        depthRoot.scale = [1, 0.001, 1]
        portal.isEnabled = false
        world.isEnabled = false
    }

    private func build() {
        for e in walls + rings { e.removeFromParent() }
        walls.removeAll(); rings.removeAll()
        floor.removeFromParent(); mist.removeFromParent()
        let fw = footprint.x, fh = footprint.y
        // Walls: unit height (y 0 → −1), stretched to `depth` by depthRoot.scale.y.
        let wallSpecs: [(width: Float, position: SIMD3<Float>, yaw: Float)] = [
            (fw, [0, -0.5, -fh / 2], 0), (fw, [0, -0.5, fh / 2], .pi), (fh, [-fw / 2, -0.5, 0], .pi / 2), (fh, [fw / 2, -0.5, 0], -.pi / 2),
        ]
        for spec in wallSpecs {
            let wall = ModelEntity(mesh: .generatePlane(width: spec.width, height: 1), materials: [FXMaterials.glow(fx.beam, tint: .white, opacity: 0.55)])
            wall.name = "well.wall"
            wall.position = spec.position
            wall.orientation = simd_quatf(angle: spec.yaw, axis: [0, 1, 0])
            depthRoot.addChild(wall)
            walls.append(wall)
        }
        for i in 0..<5 {
            let inset = 0.004 + Float(i) * 0.004
            let ring = ModelEntity(mesh: FXMeshes.roundedRectRing(width: fw - inset * 2, height: fh - inset * 2, radius: 0.006, thickness: 0.0025),
                                   materials: [FXMaterials.glow(fx.coreDisc, tint: .white, opacity: 0.9 - Float(i) * 0.12)])
            ring.name = "well.ring\(i)"
            ring.orientation = simd_quatf(angle: -.pi / 2, axis: [1, 0, 0])
            ring.position = [0, -(0.14 + 0.18 * Float(i)), 0]
            ring.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.01, baseOpacity: 1,
                                               opacityAmplitude: LightWell.ringOpacityAmplitude, period: 1.6, phase: Float(i) * 0.8))
            depthRoot.addChild(ring)
            rings.append(ring)
        }
        floor.model?.mesh = .generatePlane(width: fw * 0.9, depth: fh * 0.9)
        floor.name = "well.floor"
        floor.position = [0, -0.985, 0]
        floor.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.04, baseOpacity: 1, opacityAmplitude: 0.25, period: 2.2))
        depthRoot.addChild(floor)
        mist.position = [0, -0.9, 0]
        mist.name = "well.mist"
        mist.components.set(LightWell.mistEmitter(sprite: fx.particle, width: fw, depth: fh))
        depthRoot.addChild(mist)
        apply(level: level)          // a rebuild (footprint change) must not throw the dimmed state away
    }

    /// The glow ring around the device: inner edge `edgeGap` outside the footprint, `edgeWidth` of soft
    /// falloff outward, lying in the device's own plane so on the desk it lies on the desk around the
    /// passport and in the hand it rides it.
    private func buildEdge() {
        let inner = SIMD2<Float>(device.x / 2 + LightWell.edgeGap, device.y / 2 + LightWell.edgeGap)
        let plane = SIMD2<Float>((inner.x + LightWell.edgeWidth) * 2 + 0.004, (inner.y + LightWell.edgeWidth) * 2 + 0.004)
        edge.model?.mesh = .generatePlane(width: plane.x, depth: plane.y)
        edge.model?.materials = [FXMaterials.glow(fx.edgeGlow(planeSize: plane, inner: inner, corner: 0.006,
                                                              width: LightWell.edgeWidth),
                                                  tint: edgeTint, opacity: 1)]
        edge.components.set(FootprintProbeComponent(.hole(inner)))
    }

    /// The real device's footprint in the screen frame (V3-2a H0). The portal is the *screen*, so it never
    /// changes size; the edge glow is built around the **device** and does.
    func configure(device: SIMD2<Float>, caseCenter: SIMD3<Float> = .zero) {
        guard device != self.device || caseCenter != self.caseCenter else { return }
        self.device = device
        self.caseCenter = caseCenter
        edge.position = [caseCenter.x, 0.0016, caseCenter.z]
        buildEdge()
    }

    func configure(footprint: SIMD2<Float>) {
        guard footprint != self.footprint, footprint.x > 0 else { return }
        self.footprint = footprint
        portal.model?.mesh = .generatePlane(width: footprint.x, depth: footprint.y)
        build()
    }

    func apply(look: HologramLook) {
        apply(tint: look.tint, highlight: look.highlight)
    }

    func apply(tint: UIColor, highlight: UIColor, glow: Float = 1) {
        edgeTint = tint
        buildEdge()
        for wall in walls { wall.model?.materials = [FXMaterials.glow(fx.beam, tint: tint, opacity: 0.55 * glow)] }
        for (i, ring) in rings.enumerated() { ring.model?.materials = [FXMaterials.glow(fx.coreDisc, tint: highlight, opacity: (0.9 - Float(i) * 0.12) * glow)] }
        floor.model?.materials = [FXMaterials.glow(fx.softDisc, tint: highlight, opacity: 1)]
        if var e = mist.components[ParticleEmitterComponent.self] {
            e.mainEmitter.color = .evolving(start: .single(highlight.withAlphaComponent(0.7)), end: .single(tint.withAlphaComponent(0)))
            mist.components.set(e)
        }
    }

    /// The shaft drops open under the image at full brightness (walls extend downward, light comes up).
    func open(duration: Float) {
        openTo(level: 1, duration: duration, opacityFraction: 0.6, easing: .easeOutCubic)
    }

    /// Keep the shaft open but turn its light down to `level`: the depth — the 3D cue — does not move, only the
    /// glow recedes. Level 0 is a plain close.
    func dim(to level: Float, duration: Float) {
        guard level > 0 else { return close(duration: duration) }
        openTo(level: level, duration: duration, opacityFraction: 1, easing: .easeInOutCubic)
    }

    /// Open straight into the dimmed idle state, or just dim if the shaft is already open.
    func showDimmed(level: Float, animated: Bool = true) {
        dim(to: level, duration: animated ? 0.45 : 0)
    }

    private func openTo(level: Float, duration: Float, opacityFraction: Float, easing: Easing) {
        isOpen = true
        closeGeneration &+= 1          // invalidate a pending `close` disable
        guard LightWell.mode == .portal else {
            // Edge mode: no portal, no shaft — `level` is the ring's brightness and its breath.
            portal.isEnabled = false
            world.isEnabled = false
            applyEdge(level: level, duration: duration)
            return
        }
        portal.isEnabled = true
        world.isEnabled = true
        apply(level: level)
        depthRoot.components.set(TweenComponent(scale: (from: depthRoot.scale, to: [1, depth, 1]), duration: duration, easing: easing))
        // Always a *fresh* tween on `world`, even when the opacity already matches: a `close` in flight left one
        // with `disableWhenDone`, and installing this one is what drops it.
        world.components.set(TweenComponent(opacity: (from: world.components[OpacityComponent.self]?.opacity ?? 0, to: level),
                                            duration: duration * opacityFraction, easing: easing))
    }

    /// The floor rises back to the surface and the light seals.
    func close(duration: Float) {
        guard isOpen else { return }
        isOpen = false
        closeGeneration &+= 1
        guard LightWell.mode == .portal else { return applyEdge(level: 0, duration: duration) }
        let generation = closeGeneration
        if var e = mist.components[ParticleEmitterComponent.self] { e.isEmitting = false; mist.components.set(e) }
        depthRoot.components.set(TweenComponent(scale: (from: depthRoot.scale, to: [1, 0.001, 1]), duration: duration, easing: .easeInCubic))
        world.components.set(TweenComponent(opacity: (from: world.components[OpacityComponent.self]?.opacity ?? 1, to: 0), delay: duration * 0.4, duration: duration * 0.6, easing: .easeInCubic, disableWhenDone: true))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 40))
            guard let self, self.closeGeneration == generation, !self.isOpen else { return }
            self.portal.isEnabled = false
        }
    }

    func hide() {
        isOpen = false
        closeGeneration &+= 1
        level = 1
        edge.components.remove(TweenComponent.self)
        edge.components.set(OpacityComponent(opacity: 0))
        edge.isEnabled = false
        depthRoot.components.remove(TweenComponent.self)
        world.components.remove(TweenComponent.self)
        depthRoot.scale = [1, 0.001, 1]
        apply(level: 1)
        world.components.set(OpacityComponent(opacity: 0))
        world.isEnabled = false
        portal.isEnabled = false
    }

    /// The edge ring's brightness and breath, tweened to `level` (H0: `level` means exactly what it meant
    /// for the portal — how bright the well is — it just lights a ring now instead of a hole).
    private func applyEdge(level: Float, duration: Float) {
        self.level = level
        let target = level * LightWell.edgeOpacity
        let from = edge.components[OpacityComponent.self]?.opacity ?? 0
        if target > 0.001 { edge.isEnabled = true }
        var pulse = edge.components[PulseComponent.self]
            ?? PulseComponent(baseScale: 1, scaleAmplitude: 0.006, baseOpacity: target, opacityAmplitude: 0, period: 3.4)
        pulse.baseOpacity = target
        pulse.opacityAmplitude = 0.22 * target
        edge.components.set(pulse)
        edge.components.set(TweenComponent(opacity: (from: from, to: target), duration: duration,
                                           easing: .easeInOutCubic, disableWhenDone: target <= 0.001))
    }

    /// **V3-4 §1.** One brighter breath of the edge ring on top of whatever level it is at — the button
    /// wave's "the whole outline answered" — settling back to `level` by itself. `PulseSystem` skips an
    /// entity that has a `TweenComponent`, so the breath and the tween never fight; the pulse picks the ring
    /// back up at its own base the frame the tween ends.
    func pulseEdge(multiplier: Float, duration: Float) {
        guard LightWell.mode == .edge, edge.isEnabled else { return }
        let target = level * LightWell.edgeOpacity
        guard target > 0.001 else { return }
        edge.components.set(TweenComponent(opacity: (from: min(1, target * multiplier), to: target),
                                           duration: duration, easing: .easeOutCubic))
    }

    /// Ring breathing and mist density follow the light level; the shaft's depth never does.
    private func apply(level: Float) {
        self.level = level
        for ring in rings {
            guard var pulse = ring.components[PulseComponent.self] else { continue }
            pulse.baseOpacity = level
            pulse.opacityAmplitude = LightWell.ringOpacityAmplitude * level
            ring.components.set(pulse)
        }
        if var e = mist.components[ParticleEmitterComponent.self] {
            e.mainEmitter.birthRate = LightWell.mistBirthRate * level
            e.isEmitting = level > 0
            mist.components.set(e)
        }
    }

    private static func mistEmitter(sprite: TextureResource, width: Float, depth: Float) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [width * 0.8, 0.02, depth * 0.8]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.12
        p.speedVariation = 0.05
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = LightWell.mistBirthRate
        p.mainEmitter.lifeSpan = 2.4
        p.mainEmitter.size = 0.004
        p.mainEmitter.sizeVariation = 0.002
        p.mainEmitter.noiseStrength = 0.02
        p.mainEmitter.opacityCurve = .gradualFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.color = .evolving(start: .single(UIColor.white.withAlphaComponent(0.7)), end: .single(UIColor.white.withAlphaComponent(0)))
        p.isEmitting = false
        return p
    }
}
