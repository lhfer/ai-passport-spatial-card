import Foundation
import simd

extension V4 {
    /// **A1 lab timeline** (`--lab materials`): the parameter cycles the brief asks for, as pure functions of time
    /// so the tests can pin them — sway ±35°, a sweep every 3 s, a dissolve every 4 s (0 → 1, hold 1 s, → 0).
    enum MaterialsLabClock {
        /// Samples swing about their vertical axis: ±35°, one full swing every `swayPeriod` seconds.
        static let swayAmplitude: Float = 35 * .pi / 180
        static let swayPeriod: Double = 8

        static func sway(at t: Double) -> Float {
            swayAmplitude * Float(Foundation.sin(2 * .pi * t / swayPeriod))
        }

        /// A sweep starts every `sweepPeriod` s and crosses the card in `sweepDuration` s (eased), then rests past
        /// the far corner (sweep = 1 is off the card, so resting there is invisible).
        static let sweepPeriod: Double = 3
        static let sweepDuration: Double = 1.4

        static func sweep(at t: Double) -> Float {
            let local = positiveModulo(t, sweepPeriod)
            return easeInOut(Float(min(1, local / sweepDuration)))
        }

        /// The same sweep as A4's `CardSurfaceStyle.update` receives it: linear progress 0…1 while it crosses, nil at rest.
        static func sweepProgress(at t: Double) -> Float? {
            let local = positiveModulo(t, sweepPeriod)
            return local < sweepDuration ? Float(local / sweepDuration) : nil
        }

        /// Dissolve cycle: 0 → 1 in `dissolveRise` s, holds 1 for `dissolveHold` s, 1 → 0 in the rest of 4 s.
        static let dissolvePeriod: Double = 4
        static let dissolveRise: Double = 1.8
        static let dissolveHold: Double = 1.0

        static func dissolve(at t: Double) -> Float {
            let local = positiveModulo(t, dissolvePeriod)
            if local < dissolveRise { return easeInOut(Float(local / dissolveRise)) }
            if local < dissolveRise + dissolveHold { return 1 }
            let fall = dissolvePeriod - dissolveRise - dissolveHold
            return 1 - easeInOut(Float((local - dissolveRise - dissolveHold) / fall))
        }

        static func easeInOut(_ x: Float) -> Float {
            let t = max(0, min(1, x))
            return t * t * (3 - 2 * t)
        }

        static func positiveModulo(_ t: Double, _ period: Double) -> Double {
            let r = t.truncatingRemainder(dividingBy: period)
            return r < 0 ? r + period : r
        }
    }
}

extension V4.MagicMaterialRules {
    /// Hermite step, the same curve as MaterialX `smoothstep`.
    static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        guard high > low else { return x < low ? 0 : 1 }
        let t = max(0, min(1, (x - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }

    /// During a reveal the gold line arrives with the last third of the fill …
    static func revealEdgeIntensity(_ progress: Float) -> Float { smoothstep(0.6, 0.95, progress) }
    /// … and the foil after it, so the card's colour is the last thing to appear (text stays readable first).
    static func revealFoilStrength(_ progress: Float) -> Float { smoothstep(0.8, 1.0, progress) }
}
