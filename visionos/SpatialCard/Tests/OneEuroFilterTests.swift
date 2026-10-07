import XCTest
import simd

/// **V3-4 §7.** The 1€ filter, against the two things a tracking filter has to do at once: swallow the noise
/// of a device standing still, and not lag a device that is moving.
///
/// The numbers are the headset's: the object tracker's resting noise is 2–4 mm, and the wearer checks the
/// card against the real LCD 35 mm under it, so "how steady when still" is a millimetre question.
final class OneEuroFilterTests: XCTestCase {
    /// A deterministic ±`amplitude` wobble — a fixed sequence, so a failure is reproducible.
    private func noise(_ index: Int, amplitude: Float) -> Float {
        let table: [Float] = [0.4, -0.9, 0.7, -0.2, 1.0, -0.6, 0.1, -1.0, 0.8, -0.35, 0.55, -0.75]
        return table[index % table.count] * amplitude
    }

    private func rms(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count)).squareRoot().magnitude.float
    }

    /// **Standing still**: 3 mm of noise at 30 Hz goes in, and what comes out has to be a *third* of it or
    /// less. (V3-2b's τ 0.03 s hand filter takes out almost nothing at this rate — α ≈ 0.53 per sample.)
    func testAStationarySignalComesOutAtUnderAThirdOfTheNoise() {
        var filter = OneEuroFilter()
        var input: [Float] = [], output: [Float] = []
        for k in 0..<180 {
            let t = Double(k) / 30
            let sample = noise(k, amplitude: 0.003)
            let filtered = filter.filter(sample, at: t)
            guard k > 30 else { continue }                   // let it settle
            input.append(sample)
            output.append(filtered)
        }
        let inRMS = rms(input), outRMS = rms(output)
        XCTAssertGreaterThan(inRMS, 0.001)
        XCTAssertLessThan(outRMS, inRMS / 3,
                          "input \(inRMS * 1000) mm rms, output \(outRMS * 1000) mm rms")
    }

    /// **Moving — and the reason `--filter` defaults to `lowpass` again (V3-5 §4).**
    ///
    /// V3-4 asserted here that the 1€ step response was *no slower* than the τ 0.03 s low pass it replaced,
    /// and it was — at β 20, which the headset then showed was β 20 doing no filtering at all (real 30 Hz
    /// tracker noise reads as speed and opens the cutoff; every hand-held Σ window came back with
    /// `jitterOut ≥ jitter`). Retuned to β 2 the filter is genuinely steady and genuinely slower, and this
    /// test now pins **both halves of that trade** so that a future change claiming otherwise has to come
    /// here and say so:
    ///
    /// * a 0.3 m/s slide is trailed by several times the low pass's lag — over the brief's 1.5× ceiling,
    ///   which is what sent the default back to `lowpass`;
    /// * and the resting noise really is taken out (the test above).
    func testTheRetunedFilterTradesLagForSteadiness() {
        // 0.3 m/s for 2 s at 30 Hz, then read how far behind the truth each filter is.
        func lag(_ step: (Float, TimeInterval) -> Float) -> Float {
            var worst: Float = 0
            for k in 0..<60 {
                let t = Double(k) / 30
                let truth = Float(t) * 0.3
                let out = step(truth, t)
                guard t >= 1.0 else { continue }          // past the ramp-up
                worst = max(worst, truth - out)
            }
            return worst
        }
        var euro = OneEuroFilter()
        let euroLag = lag { value, t in euro.filter(value, at: t) }

        var low: Float = 0
        var lastTime: TimeInterval?
        let lowLag = lag { value, t in
            defer { lastTime = t }
            guard let last = lastTime else { low = value; return low }
            low += (value - low) * (1 - exp(-Float(t - last) / 0.03))
            return low
        }
        XCTAssertLessThan(lowLag, 0.010, "the τ 0.03 s low pass trails a 0.3 m/s slide by ~9 mm")
        XCTAssertGreaterThan(euroLag, lowLag * 1.5,
                             "1€ \(euroLag * 1000) mm vs low pass \(lowLag * 1000) mm — if this ever stops "
                             + "being true, `--filter` should go back to defaulting to euro")
        XCTAssertLessThan(euroLag, 0.060, "…but it is a lag, not a different card")
    }

    /// The cutoff really is a function of speed, which is the whole mechanism.
    func testTheCutoffRisesWithSpeed() {
        let filter = OneEuroFilter(minCutoff: 1.0, beta: 20)
        XCTAssertEqual(filter.cutoff(forSpeed: 0), 1.0, accuracy: 1e-6)
        XCTAssertEqual(filter.cutoff(forSpeed: 0.3), 7.0, accuracy: 1e-5, "a brisk carry opens it to 7 Hz")
        XCTAssertEqual(filter.cutoff(forSpeed: -0.3), 7.0, accuracy: 1e-5, "direction does not matter")
        XCTAssertGreaterThan(OneEuroFilter.alpha(cutoff: 5, dt: 1.0 / 30),
                             OneEuroFilter.alpha(cutoff: 1, dt: 1.0 / 30))
    }

    /// A reset is a break in the chain (a tracking loss, a source switch): the next sample is the truth, not
    /// a blend with a memory of where the device used to be.
    func testResetTakesTheNextSampleWhole() {
        var filter = OneEuroFilter()
        for k in 0..<60 { filter.filter(0, at: Double(k) / 30) }
        filter.reset()
        XCTAssertEqual(filter.filter(0.25, at: 2.0), 0.25, accuracy: 1e-6)
    }

    /// The rotation filter slerps rather than filtering four components independently — which would take the
    /// quaternion off the unit sphere and read as the card shearing — and it settles on the input.
    func testTheRotationFilterStaysOnTheUnitSphereAndConverges() {
        var filter = OneEuroRotation()
        let target = simd_quatf(angle: 0.6, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2)))
        var out = simd_quatf(angle: 0, axis: [0, 1, 0])
        for k in 0..<150 {
            out = filter.filter(target, at: Double(k) / 30)
            XCTAssertEqual(simd_length(out.vector), 1, accuracy: 1e-4)
        }
        XCTAssertEqual(abs((out.inverse * target).angle), 0, accuracy: 0.01)
    }

    /// Noise on the orientation is taken out the same way the position's is: what comes out has to be under
    /// a third of the step-to-step wobble that goes in.
    ///
    /// This is also the test that fixed `rotationBeta`. A rotation's speed is the **unsigned** angle between
    /// samples, so unlike a translation's it never cancels — 3° of resting noise reads as a steady 2 rad/s,
    /// and the β 4 that the position half wants would open the cutoff to 8.8 Hz for a device lying perfectly
    /// still. See `OneEuroFilter.rotationBeta`.
    func testTheRotationFilterSwallowsRestingNoise() {
        var filter = OneEuroRotation()
        let base = simd_quatf(angle: 0.2, axis: [1, 0, 0])
        var inSteps: [Float] = [], outSteps: [Float] = []
        var previousIn: simd_quatf?, previousOut: simd_quatf?
        for k in 0..<150 {
            let wobble = simd_quatf(angle: noise(k, amplitude: 3 * .pi / 180), axis: [0, 1, 0])
            let sample = base * wobble
            let out = filter.filter(sample, at: Double(k) / 30)
            if k > 30 {
                if let p = previousIn { inSteps.append(abs((p.inverse * sample).angle)) }
                if let p = previousOut { outSteps.append(abs((p.inverse * out).angle)) }
            }
            previousIn = sample
            previousOut = out
        }
        let inDeg = rms(inSteps) * 180 / .pi, outDeg = rms(outSteps) * 180 / .pi
        XCTAssertGreaterThan(inDeg, 1.0)
        XCTAssertLessThan(outDeg, inDeg / 3, "\(inDeg)° in, \(outDeg)° out")
    }
}

private extension Double {
    var float: Float { Float(self) }
}
