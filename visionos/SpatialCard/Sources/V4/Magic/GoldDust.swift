import Foundation
import RealityKit
import UIKit

/// **Gold dust** (v4 A2; art bible §4 金尘): the particle presets of the magic light, built from
/// `V4.GoldDustSpec` so the numbers the unit tests check are the numbers RealityKit gets.
///
/// Soft round motes only — `MagicTextures.dustTwinkle`, eight brightnesses of one dot, played as a looping
/// image sequence from a random frame at a random 3–8 Hz so every mote twinkles on its own. No star or
/// snowflake sprite is ever resident (v3's headset recording showed 5 mm stars at trail density read as snow).
/// Colour runs gold → white-gold while the opacity curve holds and then lets go; the motes fall a little and
/// drag to a stop. `particlesInheritTransform = false`: once born, a mote stays where the ribbon dropped it.
@MainActor
enum GoldDust {
    enum Kind {
        case trail, dissolve, sparkle
    }

    static func component(_ kind: Kind, spec: V4.GoldDustSpec = .standard) -> ParticleEmitterComponent {
        let e: V4.GoldDustSpec.Emitter
        switch kind {
        case .trail: e = spec.trail
        case .dissolve: e = spec.dissolve
        case .sparkle: e = spec.sparkle
        }
        var p = ParticleEmitterComponent()
        if e.streak > 0 {
            // Stretched along the emitter's local Z, which the owner keeps pointed along the path.
            p.emitterShape = .box
            p.emitterShapeSize = [2 * e.spread, 2 * e.spread, e.streak]
        } else {
            p.emitterShape = .sphere
            p.emitterShapeSize = SIMD3<Float>(repeating: e.spread)
        }
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = e.speed
        p.speedVariation = e.speedVariation
        p.particlesInheritTransform = false
        // **Always emitting, `birthRate` is the switch, short emit cycles.** A2 lab findings (`--ribbon-latch-test`):
        // turning `isEmitting` back on for an emitter that has existed with it off emitted nothing for ≈ 0.9 s
        // (default timing `repeating(emit: 1 s)`) — the whole spiral flew bare; a `birthRate` change is picked up
        // at once with the default or a 0.05 s cycle, but *never* inside one long cycle (`emit: 3600 s`) unless the
        // emitter is `restart()`ed — which would also be the wrong thing to do to the motes still in the air.
        p.isEmitting = true
        p.timing = .repeating(warmUp: nil, emit: .init(duration: 0.05), idle: nil)
        p.burstCount = e.burstCount
        p.burstCountVariation = 0
        p.mainEmitter.image = MagicTextures.shared.dustTwinkle
        var sequence = ParticleEmitterComponent.ParticleEmitter.ImageSequence()
        sequence.rowCount = 2
        sequence.columnCount = 4
        sequence.initialFrame = 0
        sequence.initialFrameVariation = max(0, spec.twinkleFrames.count - 1)
        sequence.frameRate = spec.frameRate
        sequence.frameRateVariation = spec.frameRateVariation
        sequence.animationMode = .looping
        p.mainEmitter.imageSequence = sequence
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0                               // off until `GoldDustEmitter.start()`
        p.mainEmitter.birthRateVariation = 0
        p.mainEmitter.lifeSpan = Double(e.lifeSpan)
        p.mainEmitter.lifeSpanVariation = Double(e.lifeSpanVariation)
        p.mainEmitter.size = e.size
        p.mainEmitter.sizeVariation = e.sizeVariation
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.55
        p.mainEmitter.acceleration = [0, -e.fall, 0]
        p.mainEmitter.dampingFactor = e.damping
        p.mainEmitter.spreadingAngle = .pi
        p.mainEmitter.angle = 0
        p.mainEmitter.angleVariation = .pi
        p.mainEmitter.billboardMode = .billboard
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.colorEvolutionPower = 1.4
        p.mainEmitter.color = .evolving(start: .single(MagicPalette.uiColor(MagicPalette.gold)),
                                        end: .single(MagicPalette.uiColor(MagicPalette.goldHot)))
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        p.mainEmitter.noiseStrength = 0
        return p
    }
}

/// One dust emitter on its own entity, with the only three writes a choreography needs — start, stop, burst —
/// each a single component write. The emitter is always "emitting"; start and stop set its birth rate (see the
/// note in `GoldDust.component`). The component is never rewritten per frame; the entity is simply moved.
@MainActor
final class GoldDustEmitter {
    let entity = Entity()
    private(set) var isEmitting = false
    private(set) var isPaused = false
    private let birthRate: Float

    init(_ kind: GoldDust.Kind, name: String, spec: V4.GoldDustSpec = .standard) {
        entity.name = name
        switch kind {
        case .trail: birthRate = spec.trail.birthRate
        case .dissolve: birthRate = spec.dissolve.birthRate
        case .sparkle: birthRate = spec.sparkle.birthRate
        }
        entity.components.set(GoldDust.component(kind, spec: spec))
    }

    var position: SIMD3<Float> {
        get { entity.position }
        set { entity.position = newValue }
    }

    /// Put the emitter at `position`, its birth box (local Z) along `direction` — only the transform moves.
    func place(at position: SIMD3<Float>, along direction: SIMD3<Float>) {
        entity.position = position
        let length = simd_length(direction)
        guard length > 1e-6 else { return }
        entity.orientation = simd_quatf(from: [0, 0, 1], to: direction / length)
    }

    func start() {
        guard !isEmitting, var p = entity.components[ParticleEmitterComponent.self] else { return }
        p.mainEmitter.birthRate = birthRate
        entity.components.set(p)
        isEmitting = true
    }

    func stop() {
        guard isEmitting, var p = entity.components[ParticleEmitterComponent.self] else { return }
        p.mainEmitter.birthRate = 0
        entity.components.set(p)
        isEmitting = false
    }

    func burst() {
        guard var p = entity.components[ParticleEmitterComponent.self] else { return }
        p.burst()
        entity.components.set(p)
    }

    /// Freezes (or releases) every mote in the air — the lab's still frames.
    func pause(_ paused: Bool) {
        guard paused != isPaused, var p = entity.components[ParticleEmitterComponent.self] else { return }
        p.simulationState = paused ? .pause : .play
        entity.components.set(p)
        isPaused = paused
    }
}
