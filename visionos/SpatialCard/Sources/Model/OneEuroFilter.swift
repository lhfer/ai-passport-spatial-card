import Foundation
import simd

/// **The 1€ filter** (Casiez, Roussel & Vogel, CHI 2012), for V3-4 §7.
///
/// A fixed low pass has one setting and two jobs it cannot both do: short enough that a carried device does
/// not visibly trail, long enough that a device lying still does not shimmer. V3-2b's answer was to switch τ
/// by presence (0.08 s on the desk, 0.03 s in the hand), which still leaves the hand case — the one the
/// wearer checks against the real passport underneath — filtering a 2–4 mm tracker noise floor at τ 0.03 s,
/// i.e. barely at all. The first headset round measured 0.0–1.1° of rotation jitter standing still and
/// "the fit is not precise" as the wearer's verdict.
///
/// The 1€ filter makes the cutoff a function of speed: `fc = minCutoff + beta · |ẋ|`. Standing still the
/// cutoff is low and the noise is gone; moving fast the cutoff rises and the lag disappears. Two parameters
/// with a physical meaning — `minCutoff` is "how steady when still", `beta` is "how responsive when moving" —
/// instead of one τ that has to be wrong somewhere.
///
/// Pure value type (simd + Foundation): `OneEuroFilterTests` drives it against a synthetic noise floor and a
/// step, which is the only place this can be measured at all (the simulator has no object tracking).
struct OneEuroFilter {
    /// Cutoff at zero speed, Hz. Lower = steadier at rest, more lag when a slow movement starts.
    var minCutoff: Float
    /// How fast the cutoff climbs with speed, Hz per (unit/s).
    var beta: Float
    /// Cutoff of the low pass on the speed estimate itself, Hz.
    var derivativeCutoff: Float

    private var value: Float?
    private var derivative: Float = 0
    private var lastTime: TimeInterval?

    /// The bare initialiser is the **position** setting: that is what the app runs, so it is what a test
    /// that writes `OneEuroFilter()` is measuring.
    init(minCutoff: Float = OneEuroFilter.positionMinCutoff,
         beta: Float = OneEuroFilter.positionBeta,
         derivativeCutoff: Float = OneEuroFilter.positionDerivativeCutoff) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// The chain is broken (a tracking loss, a source switch): the next sample is the truth, not a blend
    /// with a memory of where the device used to be.
    mutating func reset() {
        value = nil
        derivative = 0
        lastTime = nil
    }

    /// The smoothing factor of a first-order low pass with cutoff `cutoff` at sample interval `dt`.
    static func alpha(cutoff: Float, dt: Float) -> Float {
        guard cutoff > 0, dt > 0 else { return 1 }
        let tau = 1 / (2 * Float.pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    /// The cutoff this filter would use for a signal moving at `speed` (tests, diagnostics).
    func cutoff(forSpeed speed: Float) -> Float { minCutoff + beta * abs(speed) }

    @discardableResult
    mutating func filter(_ sample: Float, at time: TimeInterval) -> Float {
        guard sample.isFinite else { return value ?? sample }
        guard let previous = value, let last = lastTime, time > last else {
            value = sample
            lastTime = time
            derivative = 0
            return sample
        }
        let dt = Float(min(OneEuroFilter.maxStep, time - last))
        lastTime = time
        guard dt > 0 else { return previous }
        // The speed estimate is itself low-passed, or one noisy sample would open the cutoff wide and let
        // the same noise straight through.
        let rawDerivative = (sample - previous) / dt
        derivative += (rawDerivative - derivative) * OneEuroFilter.alpha(cutoff: derivativeCutoff, dt: dt)
        let a = OneEuroFilter.alpha(cutoff: cutoff(forSpeed: derivative), dt: dt)
        let filtered = previous + (sample - previous) * a
        value = filtered
        return filtered
    }

    /// The longest gap the filter integrates in one go (a stalled main actor must not teleport the card).
    static let maxStep: TimeInterval = 0.25

    // MARK: - The shipped settings

    /// **Position**, in metres — **retuned in V3-5 §4, and no longer the shipped default.**
    ///
    /// V3-4 derived β 20 from the simulator: with scripted noise the cutoff only opens when the *card*
    /// moves, so a big β bought a fast step response for free. The headset said otherwise. Every hand-held
    /// Σ window of the second round came back with `jitterOut ≥ jitter` (3.8 → 6.9, 5.3 → 10.5, 0.4 → 0.6
    /// mm): real 30 Hz tracker noise is read as *speed*, a 3 mm step at 33 ms is 0.09 m/s, and β 20 turns
    /// that into a 2.8 Hz cutoff on a device that is not moving at all. At β 20 the filter was, for the
    /// noise it exists to remove, switched off. (Part of that ratio was a measurement artefact — `jitterOut`
    /// was sampled at the 20 Hz tick and `jitter` at the 30 Hz observation; V3-5 §4 sampled both on the
    /// same observation. The corrected ratio is ≈ 1.0, which is still "β 20 filters nothing".)
    ///
    /// β 2 with `minCutoff` 0.7 Hz is the honest setting for that noise: measured against the simulator's
    /// 3 mm @ 30 Hz noise model it takes the resting step down to **9 %** of what goes in. What it costs is
    /// lag — 19.5 mm behind a 0.3 m/s slide, against 5.0 mm for the τ 0.03 s low pass — and the brief's own
    /// acceptance test is 1.5× that low pass. It fails it by 3.9×, so **`--filter` now defaults to
    /// `lowpass`** and this is the A/B, not the shipped path. See `ObjectPoseSmoother.Kind`.
    ///
    /// The tempting middle (β ≈ 10 passes both simulator criteria) is deliberately not taken: that is the
    /// same bet V3-4 made at β 20 and the headset settled it. A constant fitted to scripted noise is a
    /// constant fitted to the wrong noise.
    static let positionMinCutoff: Float = 0.7
    static let positionBeta: Float = 2
    /// The speed estimate's own low pass. 1.0 → **0.5 Hz** (V3-5 §4): the thing being kept out of the speed
    /// estimate is the tracker's noise floor, and at 30 Hz that needs a longer memory than the cutoff it
    /// then sets. (The derivative is already taken against the **filtered** previous value rather than the
    /// previous raw sample, which is the other half of not letting noise drive the cutoff.)
    static let positionDerivativeCutoff: Float = 0.5

    /// **Orientation**, in radians — and here the brief's 0.2 is right, for a reason worth writing down.
    ///
    /// A rotation's "speed" is the **unsigned** angle between consecutive samples over dt. Unlike a
    /// translation's derivative it therefore never cancels: 3° of resting noise at 30 Hz reads as a steady
    /// 2 rad/s however still the device is. A β of 4 would open the cutoff to 8.8 Hz for a device lying
    /// motionless on a desk and let the noise straight through (measured: 1.57° of jitter out of 3.8° in,
    /// against 0.6° at β 0.2). So the orientation half is, in practice, a fixed ≈ 1.2 Hz low pass — τ 0.13 s,
    /// against the 0.20 s it replaces — and the speed term only earns its keep on the translation.
    static let rotationMinCutoff: Float = 0.8
    static let rotationBeta: Float = 0.2
    static let rotationDerivativeCutoff: Float = 1.0
}

/// Three 1€ filters sharing one speed estimate's worth of parameters — a position.
struct OneEuroVector {
    private var x: OneEuroFilter
    private var y: OneEuroFilter
    private var z: OneEuroFilter

    init(minCutoff: Float = OneEuroFilter.positionMinCutoff,
         beta: Float = OneEuroFilter.positionBeta,
         derivativeCutoff: Float = OneEuroFilter.positionDerivativeCutoff) {
        x = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        y = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
        z = OneEuroFilter(minCutoff: minCutoff, beta: beta, derivativeCutoff: derivativeCutoff)
    }

    mutating func reset() {
        x.reset(); y.reset(); z.reset()
    }

    mutating func filter(_ sample: SIMD3<Float>, at time: TimeInterval) -> SIMD3<Float> {
        [x.filter(sample.x, at: time), y.filter(sample.y, at: time), z.filter(sample.z, at: time)]
    }
}

/// The same idea for an orientation: the "speed" is the angle between consecutive samples per second, and
/// the filter is a slerp by the resulting alpha rather than three independent scalars (which would shear the
/// quaternion off the unit sphere and read as the card skewing).
struct OneEuroRotation {
    var minCutoff: Float
    var beta: Float
    var derivativeCutoff: Float

    private var value: simd_quatf?
    private var speed: Float = 0
    private var lastTime: TimeInterval?

    init(minCutoff: Float = OneEuroFilter.rotationMinCutoff,
         beta: Float = OneEuroFilter.rotationBeta,
         derivativeCutoff: Float = OneEuroFilter.rotationDerivativeCutoff) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    mutating func reset() {
        value = nil
        speed = 0
        lastTime = nil
    }

    mutating func filter(_ sample: simd_quatf, at time: TimeInterval) -> simd_quatf {
        var target = sample
        guard let previous = value, let last = lastTime, time > last else {
            value = simd_normalize(sample)
            lastTime = time
            speed = 0
            return value ?? sample
        }
        let dt = Float(min(OneEuroFilter.maxStep, time - last))
        lastTime = time
        guard dt > 0 else { return previous }
        if simd_dot(previous.vector, target.vector) < 0 { target = simd_quatf(vector: -target.vector) }
        let step = abs((previous.inverse * target).angle)
        let rawSpeed = step / dt
        speed += (rawSpeed - speed) * OneEuroFilter.alpha(cutoff: derivativeCutoff, dt: dt)
        let a = OneEuroFilter.alpha(cutoff: minCutoff + beta * speed, dt: dt)
        let filtered = simd_normalize(simd_slerp(previous, target, a))
        value = filtered
        return filtered
    }
}
