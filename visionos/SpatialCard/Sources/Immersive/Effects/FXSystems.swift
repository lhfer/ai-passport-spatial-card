import Foundation
import RealityKit

// Small ECS building blocks for the hologram choreography. Every component carries its own
// elapsed time so effects can be started, retargeted or cancelled per entity by simply
// setting/removing the component. Registered once in `SpatialCardApp.init`.

// MARK: - Tween

/// One-shot interpolation of any subset of scale / position / orientation / opacity.
struct TweenComponent: Component {
    var scale: (from: SIMD3<Float>, to: SIMD3<Float>)?
    var position: (from: SIMD3<Float>, to: SIMD3<Float>)?
    var orientation: (from: simd_quatf, to: simd_quatf)?
    var opacity: (from: Float, to: Float)?
    /// Extra offset added to the position path as sin(π·t)·arcOffset (bows the path, e.g. backward).
    var arcOffset: SIMD3<Float> = .zero
    var delay: Float = 0
    var duration: Float
    var easing: Easing = .easeOutCubic
    /// Disable the entity when the tween completes (used for fade-outs).
    var disableWhenDone = false
    /// Remove the entity from its parent when done (one-shot effect entities).
    var removeWhenDone = false
    /// **v4 B5 §2.** The part of the flight (0…1 of its linear time) in which the opacity moves, eased with a smoothstep;
    /// nil = the opacity follows the flight's own easing all the way, as it always has. The gallery's `note-fade=off`
    /// puts a card's fade into the first fifth of a flight out (the last fifth of a flight home).
    var opacityWindow: SIMD2<Float>? = nil
    var elapsed: Float = 0
}

final class TweenSystem: System {
    private static let query = EntityQuery(where: .has(TweenComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("tween", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: TweenSystem.query, updatingSystemWhen: .rendering) {
            guard var tween = entity.components[TweenComponent.self] else { continue }
            tween.elapsed += dt
            let raw = tween.duration > 0 ? (tween.elapsed - tween.delay) / tween.duration : 1
            let t = tween.easing.apply(raw)
            if raw >= 0 || tween.elapsed == dt {
                // Before the delay ends we still snap to the "from" state once so nothing pops.
                let e = raw < 0 ? 0 : t
                if let s = tween.scale { entity.scale = simd_mix(s.from, s.to, SIMD3<Float>(repeating: e)) }
                if let p = tween.position {
                    let linear = max(0, min(1, raw))
                    entity.position = simd_mix(p.from, p.to, SIMD3<Float>(repeating: e)) + tween.arcOffset * sin(.pi * linear)
                }
                if let o = tween.orientation { entity.orientation = simd_slerp(o.from, o.to, e) }
                if let a = tween.opacity {
                    var k = e
                    if let window = tween.opacityWindow {
                        let linear = max(0, min(1, raw))
                        let local = max(0, min(1, (linear - window.x) / max(0.0001, window.y - window.x)))
                        k = raw < 0 ? 0 : local * local * (3 - 2 * local)
                    }
                    let value = a.from + (a.to - a.from) * k
                    // v4 B5 §2: only when it moves — a tween that holds a card at 1 (the deck's slots, the ring's lift)
                    // rewrote the same `OpacityComponent` every frame, and every write is an update the renderer handles.
                    if let current = entity.components[OpacityComponent.self]?.opacity, abs(current - value) < 0.0005 {
                        // unchanged
                    } else {
                        entity.components.set(OpacityComponent(opacity: value))
                    }
                }
            }
            if raw >= 1 {
                if tween.disableWhenDone { entity.isEnabled = false }
                entity.components.remove(TweenComponent.self)
                if tween.removeWhenDone { entity.removeFromParent() }
            } else {
                entity.components.set(tween)
            }
        }
    }
}

// MARK: - Pulse (breathing glow)

/// Sinusoidal breathing of scale and opacity around a base value. Skipped while a tween runs.
struct PulseComponent: Component {
    var baseScale: Float
    var scaleAmplitude: Float
    var baseOpacity: Float
    var opacityAmplitude: Float
    var period: Float
    var phase: Float = 0
    var elapsed: Float = 0
}

final class PulseSystem: System {
    private static let query = EntityQuery(where: .has(PulseComponent.self) && !.has(TweenComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("pulse", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: PulseSystem.query, updatingSystemWhen: .rendering) {
            guard var pulse = entity.components[PulseComponent.self] else { continue }
            pulse.elapsed += dt
            let w = sin((pulse.elapsed / pulse.period) * 2 * .pi + pulse.phase)
            let s = pulse.baseScale + pulse.scaleAmplitude * w
            entity.scale = [s, s, s]
            entity.components.set(OpacityComponent(opacity: max(0, pulse.baseOpacity + pulse.opacityAmplitude * w)))
            entity.components.set(pulse)
        }
    }
}

// MARK: - Ripple (expanding ring)

/// Ring that grows from `startScale` to `endScale` while fading. Single-shot by default (event
/// ripples); `repeats` restores the old radar loop, `phase` staggers copies.
struct RippleComponent: Component {
    var startScale: Float
    var endScale: Float
    var period: Float
    var peakOpacity: Float
    var repeats = false
    /// Remove the entity when a single-shot ripple finishes.
    var removeWhenDone = false
    var phase: Float = 0
    var elapsed: Float = 0
}

final class RippleSystem: System {
    private static let query = EntityQuery(where: .has(RippleComponent.self) && !.has(TweenComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("ripple", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: RippleSystem.query, updatingSystemWhen: .rendering) {
            guard var ripple = entity.components[RippleComponent.self] else { continue }
            ripple.elapsed += dt
            let cycle = (ripple.elapsed + ripple.phase) / ripple.period
            if !ripple.repeats && cycle >= 1 {
                entity.components.set(OpacityComponent(opacity: 0))
                entity.components.remove(RippleComponent.self)
                if ripple.removeWhenDone { entity.removeFromParent() } else { entity.isEnabled = false }
                continue
            }
            let t = cycle - floor(cycle)
            let grow = 1 - pow(1 - t, 2)                       // ease-out expansion
            let s = ripple.startScale + (ripple.endScale - ripple.startScale) * grow
            let fadeIn = min(1, t / 0.12)
            let fadeOut = pow(1 - t, 1.6)
            entity.scale = [s, s, s]
            entity.components.set(OpacityComponent(opacity: ripple.peakOpacity * fadeIn * fadeOut))
            entity.components.set(ripple)
        }
    }
}

// MARK: - Float (idle hover)

/// Gentle idle drift: position offset = amplitude·sin(2π·t/period + phase) on the given axis.
struct FloatComponent: Component {
    var basePosition: SIMD3<Float>
    var axis: SIMD3<Float> = [0, 1, 0]
    var amplitude: Float
    var period: Float
    var phase: Float = 0
    var elapsed: Float = 0
}

final class FloatSystem: System {
    private static let query = EntityQuery(where: .has(FloatComponent.self) && !.has(TweenComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("float", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: FloatSystem.query, updatingSystemWhen: .rendering) {
            guard var f = entity.components[FloatComponent.self] else { continue }
            f.elapsed += dt
            entity.position = f.basePosition + f.axis * (f.amplitude * sin(2 * .pi * f.elapsed / f.period + f.phase))
            entity.components.set(f)
        }
    }
}

// MARK: - Sway (idle life of a card that has landed)

/// Slow idle life around a **resting transform**: a vertical bob plus a tiny roll / pitch sway. One write of
/// `position` + `orientation` per entity per frame, and nothing at all while a `TweenComponent` owns the entity
/// (the query excludes it), so a flight is never fought over.
///
/// `elapsed` starts at 0 every time the component is re-set (a landing, a re-layout, the end of a preview) and
/// the amplitude ramps in over `rampSeconds`: without the ramp a card whose `phase` is near ±π/2 would jump the
/// full 8 mm on the frame the tween is removed.
struct SwayComponent: Component {
    var basePosition: SIMD3<Float>
    var baseOrientation: simd_quatf
    /// Vertical bob, metres (the plan's ±8 mm).
    var bobAmplitude: Float = 0.008
    var bobPeriod: Float = 6
    /// Roll / pitch sway, radians (the plan's ±2°; the pitch half runs at 0.6 × this).
    var tiltAmplitude: Float = 2 * .pi / 180
    var tiltPeriod: Float = 9
    var phase: Float = 0
    var rampSeconds: Float = 1.2
    var elapsed: Float = 0
}

final class SwaySystem: System {
    private static let query = EntityQuery(where: .has(SwayComponent.self) && !.has(TweenComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("sway", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: SwaySystem.query, updatingSystemWhen: .rendering) {
            guard var sway = entity.components[SwayComponent.self] else { continue }
            sway.elapsed += dt
            let ramp = sway.rampSeconds > 0 ? min(1, sway.elapsed / sway.rampSeconds) : 1
            let bob = sin(2 * .pi * sway.elapsed / max(0.01, sway.bobPeriod) + sway.phase)
            // The two tilts run on co-prime-ish periods so no two cards ever look mechanically in step.
            let roll = sin(2 * .pi * sway.elapsed / max(0.01, sway.tiltPeriod) + sway.phase * 1.7)
            let nod = cos(2 * .pi * sway.elapsed / max(0.01, sway.tiltPeriod * 1.31) + sway.phase)
            entity.position = sway.basePosition + SIMD3<Float>(0, sway.bobAmplitude * bob * ramp, 0)
            entity.orientation = sway.baseOrientation
                * simd_quatf(angle: sway.tiltAmplitude * roll * ramp, axis: [0, 0, 1])
                * simd_quatf(angle: sway.tiltAmplitude * nod * ramp * 0.6, axis: [1, 0, 0])
            entity.components.set(sway)
        }
    }
}

// MARK: - Note trail (pixie dust behind a flying card)

/// The dust trail of one note card. The emitter is a **sibling** of the card's holder rather than a child, for
/// two reasons: a holder carries an `OpacityComponent` (hierarchical — it would fade the sparks out together
/// with the card it is meant to be trailing) and it is `isEnabled = false` the moment it lands back inside the
/// slab (which would kill every spark still in the air).
///
/// The system needs no choreography of its own: it emits exactly while the holder's `TweenComponent` is moving
/// it, which is true of a fan-out, a re-layout, a preview flight **and** a collapse — so the trails reverse into
/// the card for free.
struct NoteTrailComponent: Component {
    weak var target: Entity?
    var birthRate: Float = 95
    var isOn = false
    /// v3 H2 §3: the hand-held card is moved by the **pose follower** on `anchorRoot`, not by a tween of its
    /// own, so "is a position tween running" is always false for it. Set this and the owner decides instead
    /// (the controller's speed hysteresis: on above 0.15 m/s, off below 0.10). Nil = the note fan's rule.
    var forceFlying: Bool?
}

final class NoteTrailSystem: System {
    private static let query = EntityQuery(where: .has(NoteTrailComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("noteTrail", since: cpuStart) }
        for entity in context.entities(matching: NoteTrailSystem.query, updatingSystemWhen: .rendering) {
            guard var trail = entity.components[NoteTrailComponent.self], let target = trail.target else { continue }
            entity.position = target.position
            // Flying = a position tween past its stagger delay. A card waiting for its turn, sitting on its
            // slot or folded away emits nothing.
            var flying = false
            if let forced = trail.forceFlying {
                flying = forced
            } else if target.isEnabled, let tween = target.components[TweenComponent.self],
                      tween.position != nil, tween.elapsed >= tween.delay {
                flying = true
            }
            guard flying != trail.isOn else { continue }
            trail.isOn = flying
            entity.components.set(trail)
            // Only on a state change: re-setting a `ParticleEmitterComponent` every frame restarts the emitter.
            guard var emitter = entity.components[ParticleEmitterComponent.self] else { continue }
            emitter.mainEmitter.birthRate = flying ? trail.birthRate : 0
            entity.components.set(emitter)
        }
    }
}

// MARK: - Glint sweep (a highlight crossing a card)

/// One highlight quad travelling once across a card's face, its opacity shaped as sin(π·t) so it has no edge at
/// either end. Removes itself (and its entity) when it is through.
struct GlintSweepComponent: Component {
    var from: SIMD3<Float>
    var to: SIMD3<Float>
    var duration: Float
    var peakOpacity: Float = 0.8
    var elapsed: Float = 0
}

final class GlintSweepSystem: System {
    private static let query = EntityQuery(where: .has(GlintSweepComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("glint", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: GlintSweepSystem.query, updatingSystemWhen: .rendering) {
            guard var glint = entity.components[GlintSweepComponent.self] else { continue }
            glint.elapsed += dt
            let t = glint.duration > 0 ? min(1, glint.elapsed / glint.duration) : 1
            if t >= 1 {
                entity.components.remove(GlintSweepComponent.self)
                entity.removeFromParent()
                continue
            }
            let eased = 1 - pow(1 - t, 2)                       // fast in, easing out at the far edge
            entity.position = simd_mix(glint.from, glint.to, SIMD3<Float>(repeating: eased))
            entity.components.set(OpacityComponent(opacity: glint.peakOpacity * sin(.pi * t)))
            entity.components.set(glint)
        }
    }
}

// MARK: - Spin

/// Constant rotation about a local axis (light sweep, beam fins).
struct SpinComponent: Component {
    var axis: SIMD3<Float> = [0, 1, 0]
    var radiansPerSecond: Float
}

final class SpinSystem: System {
    private static let query = EntityQuery(where: .has(SpinComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("spin", since: cpuStart) }
        let dt = Float(context.deltaTime)
        for entity in context.entities(matching: SpinSystem.query, updatingSystemWhen: .rendering) {
            guard let spin = entity.components[SpinComponent.self] else { continue }
            entity.orientation = simd_quatf(angle: spin.radiansPerSecond * dt, axis: spin.axis) * entity.orientation
        }
    }
}

// MARK: - Registration

enum FXRegistration {
    static func register() {
        TweenComponent.registerComponent()
        PulseComponent.registerComponent()
        RippleComponent.registerComponent()
        SpinComponent.registerComponent()
        FloatComponent.registerComponent()
        SwayComponent.registerComponent()
        NoteTrailComponent.registerComponent()
        GlintSweepComponent.registerComponent()
        ScanRevealComponent.registerComponent()
        ProjectorRayComponent.registerComponent()
        PixelRevealComponent.registerComponent()
        PerfProbeComponent.registerComponent()
        FootprintProbeComponent.registerComponent()
        WaveSegmentComponent.registerComponent()
        TweenSystem.registerSystem()
        PulseSystem.registerSystem()
        RippleSystem.registerSystem()
        SpinSystem.registerSystem()
        FloatSystem.registerSystem()
        SwaySystem.registerSystem()
        NoteTrailSystem.registerSystem()
        GlintSweepSystem.registerSystem()
        ScanRevealSystem.registerSystem()
        ProjectorRaySystem.registerSystem()
        PixelRevealSystem.registerSystem()
        PerfProbeSystem.registerSystem()
        WaveSegmentSystem.registerSystem()
    }
}
