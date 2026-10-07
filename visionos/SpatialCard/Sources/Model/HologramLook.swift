import RealityKit
import SwiftUI
import UIKit

/// The one look of the desk card (v2 工作包 B). v1 had three switchable crystal styles picked from desk orbs;
/// the reference the user gave is a single **frosted glass slab**, so there is nothing to switch any more —
/// a world's colour only tints the rim light and the beam, gently (`rimColor(tint:strength:)`).
///
/// The palette is deliberately near-white: the card's colour is supposed to come from the light behind it,
/// not from the material.
struct HologramLook {
    /// Cool near-white blue: the colour of light coming *through* frosted glass.
    var tint: UIColor
    /// A touch deeper, for the desk halo and ripples.
    var secondaryTint: UIColor
    /// The hot core of anything emissive (rim, beam, well floor).
    var highlight: UIColor
    /// Outermost desk glow behind the device — low saturation so a lit room does not fight it.
    var background: UIColor
    var bloomStrength: Float
    /// Opacity of the slab body itself (the frosted plate).
    var slabOpacity: Float
    var beamOpacity: Float
    /// Steady-state particles per second rising off the device footprint.
    var particleBirthRate: Float

    /// The only look there is.
    static let desk = HologramLook(
        tint: UIColor(hex: "#DBEBFF"),
        secondaryTint: UIColor(hex: "#BFD4FF"),
        highlight: .white,
        background: UIColor(hex: "#2A3A52"),
        bloomStrength: 0.45,
        slabOpacity: 0.30,
        beamOpacity: 0.5,
        particleBirthRate: 30)

    /// The rim's colour: the look's own near-white, with a world's colour blended in at `strength`
    /// (0.35 while a coin is highlighted, 1 inside / after a world). This is the *only* place a world's
    /// colour reaches the card body — the slab itself stays milky white.
    func rimColor(tint worldTint: UIColor?, strength: Float) -> UIColor {
        guard let worldTint else { return highlight }
        return highlight.mixed(with: worldTint.withAlphaComponent(1), by: CGFloat(max(0, min(1, strength))))
    }

    // MARK: SwiftUI

    var accentColor: Color { Color(uiColor: tint) }

    // MARK: Particles

    /// Steady-state particles rising from the device footprint: embers that drift up and swell as they fade.
    /// (A 4 × 4 sprite sheet rather than one dot, and a deliberately quiet birth rate so the event bursts read
    /// as events.)
    func makeParticles(footprint: SIMD2<Float>, spriteSheet: TextureResource) -> ParticleEmitterComponent {
        var particles = ParticleEmitterComponent()

        particles.emitterShape = .box
        particles.emitterShapeSize = [footprint.x * 1.2, 0.004, footprint.y * 1.2]
        particles.birthLocation = .volume
        particles.birthDirection = .local
        particles.emissionDirection = [0, 1, 0]
        particles.spawnedEmitter = nil
        particles.isEmitting = true
        particles.simulationState = .play

        particles.mainEmitter.image = spriteSheet
        var sequence = ParticleEmitterComponent.ParticleEmitter.ImageSequence()
        sequence.rowCount = 4
        sequence.columnCount = 4
        sequence.frameRate = 12
        sequence.initialFrameVariation = 15
        sequence.animationMode = .looping
        particles.mainEmitter.imageSequence = sequence
        particles.mainEmitter.blendMode = .additive
        particles.mainEmitter.isLightingEnabled = false
        particles.mainEmitter.billboardMode = .billboard
        particles.mainEmitter.colorEvolutionPower = 2
        particles.mainEmitter.color = .evolving(
            start: .random(a: highlight, b: tint),
            end: .single(secondaryTint.withAlphaComponent(0)))
        // v4 B5 §3: unsorted. The motes are added (`.additive`), and a sum does not depend on the order it is taken in —
        // sorting them by age every frame bought nothing on screen (the only resident emitter that sorted).
        particles.mainEmitter.sortOrder = .unsorted

        // (vortexStrength reads as a side wind in this RealityKit build, so the swirl is left out.)
        particles.speed = 0.05
        particles.speedVariation = 0.02
        particles.mainEmitter.birthRate = particleBirthRate
        particles.mainEmitter.lifeSpan = 2.8
        particles.mainEmitter.lifeSpanVariation = 0.7
        particles.mainEmitter.size = 0.0013
        particles.mainEmitter.sizeVariation = 0.0006
        particles.mainEmitter.sizeMultiplierAtEndOfLifespan = 1.4
        particles.mainEmitter.acceleration = [0, 0.008, 0]
        particles.mainEmitter.noiseStrength = 0.003
        particles.mainEmitter.noiseScale = 1.4
        particles.mainEmitter.spreadingAngle = 0.2
        particles.mainEmitter.opacityCurve = .gradualFadeInOut
        return particles
    }
}

/// Which reveal choreography plays (design doc §3.4). Ink extraction is the default and the only one the
/// card is designed around; pixel / scan stay reachable through `--reveal` for A/B material.
/// (v1's `peel` / `voxel` hooks were never implemented and are gone.)
enum RevealKind: String, CaseIterable {
    /// A5 — the ink lifts off as floating line art, flips to the reader and re-typesets into the slab;
    /// the paper turns to dust (default).
    case inkExtraction = "ink"
    /// A4 — the bitmap breaks into colour-sampled pixels that lift, swirl and reassemble as the card.
    case pixelReassembly = "pixel"
    /// A1 — a scan line reveals a wireframe on the paper, which pries off and grows into the card.
    case scanDissolve = "scan"

    var displayName: String {
        switch self {
        case .inkExtraction: return "墨水抽离"
        case .pixelReassembly: return "像素重组"
        case .scanDissolve: return "扫描线"
        }
    }
}

/// `--card-glass`: which SwiftUI glass treatment sits behind the card's white frosting. visionOS has no
/// `glassEffect` / `GlassEffectContainer` (both are `@available(visionOS, unavailable)` in the 27 SDK), so the
/// choices are the plate and feathered variants of `glassBackgroundEffect` — or none at all.
enum CardGlass: String {
    /// Thick plate (default): the closest thing the SDK has to a 12 mm acrylic card.
    case plate
    /// Soft-edged glass — less of an object, more of a projection.
    case feathered
    /// No glass at all: just the white frosting. The fallback if a plate reads as "a floating system window"
    /// on the headset.
    case plain
}
