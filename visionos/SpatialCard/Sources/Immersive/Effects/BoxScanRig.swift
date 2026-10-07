import Foundation
import RealityKit
import simd
import UIKit

/// **The recognition scan** (V3-2a2 S1 / plan §4 E1): twelve 0.8 mm light rods drawn along the *real*
/// shell's own edges, a bright band sweeping its long axis, and then the whole wireframe contracting onto
/// the screen rectangle and handing over to the socket light.
///
/// This is the app's one sentence of "the magic knows where the hardware is": the outline is the anchor
/// box, so on camera the light sits exactly on the smoked-plastic edges, and the real LCD sweeps a white
/// bar of its own (the `glow` command, S2) while the virtual band is over it.
///
/// Everything here is **timed** — the whole rig is gone 1.2 s after it starts (0.6 s on a summon) — so it
/// is one of H0's two exemptions to "nothing inside the device's footprint". `run` pauses the audit for
/// exactly as long as it draws.
///
/// The clock is `BoxScanTimeline`, a pure value type: the rig only turns its numbers into tweens.
@MainActor
final class BoxScanRig {
    let root = Entity()
    /// The twelve rods, in `BoxScanTimeline.edges` order.
    private var rods: [ModelEntity] = []
    /// The sweeping band and the sparks that trail it.
    private let band: ModelEntity
    private let sparks = Entity()
    private var box: SIMD3<Float>
    /// The screen rectangle the wireframe contracts onto (36.7 × 49 mm).
    private var screen: SIMD2<Float>
    /// **v4 B1.** The rig lives in the **case** frame C (its twelve rods are the shell's own edges); the screen it
    /// contracts onto is centred here in that frame — the lit area's offset on the case (`V4.ScreenOffset`).
    private var screenCenter: SIMD2<Float> = .zero
    private let tint: UIColor
    private var task: Task<Void, Never>?
    /// The four vertical rods' 0.1 s flashes, cancelled with the scan.
    private var flashes: [Task<Void, Never>] = []

    /// Side of a rod's square section.
    static let rodSize: Float = 0.0008
    /// The band: 64 mm across the device, 3 mm along its sweep.
    static let bandSize: SIMD2<Float> = [0.064, 0.003]
    /// How far above the top face the band and the contracted rectangle float.
    static let bandLift: Float = 0.001
    static let screenLift: Float = 0.0006

    init(box: SIMD3<Float>, screen: SIMD2<Float>, tint: UIColor) {
        self.box = box
        self.screen = screen
        self.tint = tint
        band = ModelEntity(mesh: .generatePlane(width: BoxScanRig.bandSize.x, depth: BoxScanRig.bandSize.y),
                           materials: [HologramController.emissive(.white, intensity: 6, opacity: 0)])
        band.name = "boxscan.band"
        root.name = "boxscan"
        root.components.set(BloomComponent(scope: .hierarchical))
        var bloom = BloomOptionsComponent()
        bloom.strength = 0.6
        bloom.threshold = 1.0
        root.components.set(bloom)
        sparks.name = "boxscan.sparks"
        sparks.components.set(BoxScanRig.sparkEmitter(width: BoxScanRig.bandSize.x, tint: tint))
        band.addChild(sparks)
        root.addChild(band)
        root.isEnabled = false
        rebuild()
    }

    /// The anchor box changed (`--fake-box scan`, a future device): the outline is re-cut to it.
    func configure(box: SIMD3<Float>, screen: SIMD2<Float>, screenCenter: SIMD2<Float> = .zero) {
        guard box != self.box || screen != self.screen || screenCenter != self.screenCenter else { return }
        self.box = box
        self.screen = screen
        self.screenCenter = screenCenter
        rebuild()
    }

    var isRunning: Bool { task != nil }

    /// How a presence transition reaches a running scan. `nil` = the scan has no opinion about it.
    ///
    /// Only the three *entrances* are held back, and a `.carry` counts as one only while the card is off
    /// screen — that is the unfold, the case the plan is about. A `.carry` that picks a card up off the
    /// desk is the pick-up morph and must not be delayed by half a second.
    static func arrival(for transition: PresenceGate.Transition?,
                        cardOnScreen: Bool) -> BoxScanTimeline.Arrival? {
        switch transition {
        case .cinematic?: return .intro(.cinematic)
        case .reentry?: return .intro(.reentry)
        case .carry?: return cardOnScreen ? nil : .intro(.unfold)
        case .freeze?: return .freeze
        case .hide?: return .hide
        default: return nil
        }
    }

    private func rebuild() {
        for rod in rods { rod.removeFromParent() }
        rods = BoxScanTimeline.edges(width: box.x, length: box.z, thickness: box.y).enumerated().map { index, edge in
            let s = BoxScanRig.rodSize
            let mesh: MeshResource
            switch edge.along {
            case .x: mesh = .generateBox(width: edge.length, height: s, depth: s)
            case .y: mesh = .generateBox(width: s, height: max(s, edge.length), depth: s)
            case .z: mesh = .generateBox(width: s, height: s, depth: edge.length)
            }
            let rod = ModelEntity(mesh: mesh, materials: [HologramController.emissive(tint, intensity: 4, opacity: 0)])
            rod.name = "boxscan.edge\(index)"
            rod.position = edge.mid
            rod.components.set(OpacityComponent(opacity: 0))
            root.addChild(rod)
            return rod
        }
        band.model?.mesh = .generatePlane(width: box.x * 1.07, depth: BoxScanRig.bandSize.y)
        sparks.components.set(BoxScanRig.sparkEmitter(width: box.x * 1.07, tint: tint))
    }

    /// Draw the outline. `onGlow` fires at the beat the real LCD has to be told (S2), `onConverge` at the
    /// beat the card's entrance may start. Both run on the main actor; neither runs if the scan is stopped.
    func run(_ timeline: BoxScanTimeline, onGlow: @escaping () -> Void, onConverge: @escaping () -> Void) {
        task?.cancel()
        for flash in flashes { flash.cancel() }
        flashes.removeAll()
        root.isEnabled = true
        let w = box.x, l = box.z, t = box.y
        let edges = BoxScanTimeline.edges(width: w, length: l, thickness: t)

        // 0 → `edgesIn`: the rods are drawn out of the corner nearest the reader, 20 ms apart.
        let order = BoxScanTimeline.drawOrder(width: w, length: l, thickness: t)
        let span = max(0.001, timeline.edgesIn - Float(max(0, order.count - 1)) * BoxScanTimeline.edgeStagger)
        for (rank, index) in order.enumerated() {
            rods[index].components.set(TweenComponent(
                opacity: (from: 0, to: BoxScanTimeline.edgeLevel),
                delay: Float(rank) * BoxScanTimeline.edgeStagger,
                duration: span, easing: .easeOutCubic))
        }

        // `bandStart` → `bandEnd`: the band crosses the device along its long axis. Opacity is deliberately
        // **not** a channel of this tween — a delayed tween snaps to its `from` on the very first frame, and
        // the band has to stay invisible until the sweep actually begins.
        band.position = [0, BoxScanRig.bandLift, l / 2]
        band.components.set(OpacityComponent(opacity: 0))
        band.components.set(TweenComponent(
            position: (from: [0, BoxScanRig.bandLift, l / 2], to: [0, BoxScanRig.bandLift, -l / 2]),
            delay: timeline.bandStart,
            duration: timeline.bandEnd - timeline.bandStart, easing: .easeInOutCubic))

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            /// Sleep to an absolute beat on the scan's own clock; false = the scan was stopped.
            let start = Date()
            @MainActor func wait(_ beat: Float) async -> Bool {
                let remaining = Double(beat) - Date().timeIntervalSince(start)
                if remaining > 0 { try? await Task.sleep(for: .milliseconds(Int(remaining * 1000))) }
                return !Task.isCancelled
            }
            guard await wait(timeline.bandStart) else { return }
            self.band.components.set(OpacityComponent(opacity: 0.95))
            self.setSparks(true)
            // The four vertical rods flash as the band passes them: up in half the flash, down in the
            // other half. One little task each, because a rod can only carry one tween at a time.
            for (index, edge) in edges.enumerated() where edge.along == .y {
                guard let at = timeline.bandCrosses(z: edge.mid.z, length: l), at < timeline.converge else { continue }
                self.flashes.append(Task { @MainActor [weak self] in
                    let wait = Double(at - timeline.bandStart)
                    if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                    guard let self, !Task.isCancelled, index < self.rods.count else { return }
                    let half = BoxScanTimeline.edgeFlashDuration / 2
                    self.rods[index].components.set(TweenComponent(
                        opacity: (from: BoxScanTimeline.edgeLevel, to: BoxScanTimeline.edgeFlashLevel),
                        duration: half, easing: .easeOutCubic))
                    try? await Task.sleep(for: .milliseconds(Int(BoxScanTimeline.edgeFlashDuration * 1000)))
                    guard !Task.isCancelled else { return }
                    self.rods[index].components.set(TweenComponent(
                        opacity: (from: BoxScanTimeline.edgeFlashLevel, to: BoxScanTimeline.edgeLevel),
                        duration: half, easing: .easeInCubic))
                })
            }
            guard await wait(timeline.glowAt) else { return }
            onGlow()
            guard await wait(timeline.bandEnd) else { return }
            self.band.components.set(TweenComponent(opacity: (from: 0.95, to: 0), duration: 0.12, easing: .easeInCubic))
            self.setSparks(false)
            self.contract(timeline)
            guard await wait(timeline.converge) else { return }
            onConverge()
            guard await wait(timeline.total) else { return }
            self.stop(fade: 0)
        }
    }

    /// `bandEnd` → `converge`: every rod tweens onto the flat screen rectangle and fades as it lands.
    private func contract(_ timeline: BoxScanTimeline) {
        let duration = max(0.01, timeline.converge - timeline.contractStart)
        let target = BoxScanTimeline.edges(width: screen.x, length: screen.y, thickness: 0)
        for (index, rod) in rods.enumerated() where index < target.count {
            var to = target[index].mid
            to.y = BoxScanRig.screenLift
            to.x += screenCenter.x
            to.z += screenCenter.y
            let shrink: SIMD3<Float>
            switch target[index].along {
            // A vertical rod has nowhere to go on a flat rectangle: it collapses into its corner.
            case .y: shrink = [1, 0.02, 1]
            case .x: shrink = [screen.x / max(0.001, box.x), 1, 1]
            case .z: shrink = [1, 1, screen.y / max(0.001, box.z)]
            }
            rod.components.set(TweenComponent(
                scale: (from: rod.scale, to: shrink),
                position: (from: rod.position, to: to),
                opacity: (from: rod.components[OpacityComponent.self]?.opacity ?? BoxScanTimeline.edgeLevel, to: 0),
                duration: duration, easing: .easeInCubic))
        }
    }

    /// Take the wireframe away. `fade` > 0 is the `.hide` case (the card is going, 0.2 s).
    func stop(fade: Float) {
        task?.cancel()
        task = nil
        for flash in flashes { flash.cancel() }
        flashes.removeAll()
        setSparks(false)
        guard fade > 0 else {
            for rod in rods {
                rod.components.remove(TweenComponent.self)
                rod.components.set(OpacityComponent(opacity: 0))
            }
            band.components.remove(TweenComponent.self)
            band.components.set(OpacityComponent(opacity: 0))
            root.isEnabled = false
            reset()
            return
        }
        for rod in rods {
            rod.components.set(TweenComponent(
                opacity: (from: rod.components[OpacityComponent.self]?.opacity ?? 0, to: 0),
                duration: fade, easing: .easeInCubic))
        }
        band.components.set(TweenComponent(
            opacity: (from: band.components[OpacityComponent.self]?.opacity ?? 0, to: 0),
            duration: fade, easing: .easeInCubic))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(fade * 1000) + 60))
            guard let self, self.task == nil else { return }
            self.root.isEnabled = false
            self.reset()
        }
    }

    /// Put the rods back on the box, so the next scan starts from the shell and not from the screen.
    private func reset() {
        let edges = BoxScanTimeline.edges(width: box.x, length: box.z, thickness: box.y)
        for (index, rod) in rods.enumerated() where index < edges.count {
            rod.components.remove(TweenComponent.self)
            rod.transform = Transform(translation: edges[index].mid)
            rod.components.set(OpacityComponent(opacity: 0))
        }
        band.components.remove(TweenComponent.self)
        band.position = [0, BoxScanRig.bandLift, box.z / 2]
        band.components.set(OpacityComponent(opacity: 0))
    }

    private func setSparks(_ on: Bool) {
        guard var emitter = sparks.components[ParticleEmitterComponent.self] else { return }
        emitter.isEmitting = on
        sparks.components.set(emitter)
    }

    /// A copy of `RegistrationOverlay.sparkEmitter` (the scan line's own trail): 400/s, 0.4 s, 1 mm motes
    /// that start white and die in the look's tint.
    private static func sparkEmitter(width: Float, tint: UIColor) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = [width, 0.001, 0.003]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.1
        p.speedVariation = 0.05
        p.isEmitting = false
        p.mainEmitter.image = FXTextures.shared.particle
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 400
        p.mainEmitter.lifeSpan = 0.4
        p.mainEmitter.lifeSpanVariation = 0.15
        p.mainEmitter.size = 0.001
        p.mainEmitter.sizeVariation = 0.0006
        p.mainEmitter.color = .evolving(start: .single(.white), end: .single(tint.withAlphaComponent(0)))
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.spreadingAngle = 0.4
        p.mainEmitter.isLightingEnabled = false
        return p
    }
}
