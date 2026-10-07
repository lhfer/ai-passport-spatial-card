import XCTest

/// **v4 A2.** Gold dust against the art bible (§4 金尘) and the package budget (≤ 400 motes alive at once),
/// on the very numbers `GoldDust` gives RealityKit.
final class V4GoldDustSpecTests: XCTestCase {
    let spec = V4.GoldDustSpec.standard

    func testTheRecognitionNeverHasMoreThanFourHundredMotesInTheAir() {
        XCTAssertLessThanOrEqual(spec.peakAlive, 400, "peak \(spec.peakAlive)")
        // The bound is every birth of the last max-life seconds: trail 1.8 s of emission outlives its 1.6 s life.
        XCTAssertEqual(spec.trail.peakAlive, Int(ceil(spec.trail.birthRate * spec.trail.maxLife)))
    }

    func testTheTrailIsTheBiblesDust() {
        let e = spec.trail
        XCTAssertGreaterThanOrEqual(e.birthRate, 40)
        XCTAssertLessThanOrEqual(e.birthRate, 120)
        XCTAssertGreaterThanOrEqual(e.minLife, 0.6 - 1e-5)
        XCTAssertLessThanOrEqual(e.maxLife, 1.6 + 1e-5)
        XCTAssertGreaterThan(e.fall, 0, "a slight fall")
        XCTAssertGreaterThan(e.damping, 0, "with drag")
        // A soft dot's visible core is ≈ 60 % of its sprite: 1–3 mm.
        XCTAssertGreaterThanOrEqual(0.6 * (e.size - e.sizeVariation), 0.001 - 1e-6)
        XCTAssertLessThanOrEqual(0.6 * (e.size + e.sizeVariation), 0.003 + 1e-6)
    }

    func testEveryEmitterIsSoftRoundDustOfTheRightSize() {
        for e in [spec.trail, spec.dissolve, spec.sparkle] {
            XCTAssertGreaterThanOrEqual(0.6 * (e.size - e.sizeVariation), 0.001 - 1e-6)
            XCTAssertLessThanOrEqual(0.6 * (e.size + e.sizeVariation), 0.003 + 1e-6)
            XCTAssertGreaterThanOrEqual(e.minLife, 0.55)
            XCTAssertLessThanOrEqual(e.maxLife, 1.6 + 1e-5)
        }
    }

    func testTheTwinkleRunsAtThreeToEightHertz() {
        let frames = Float(spec.twinkleFrames.count)
        XCTAssertEqual((spec.frameRate - spec.frameRateVariation) / frames, 3, accuracy: 1e-5)
        XCTAssertEqual((spec.frameRate + spec.frameRateVariation) / frames, 8, accuracy: 1e-5)
    }

    /// Twinkle, not strobe: one bright frame, a dip that never goes dark, and back.
    func testTheTwinkleFramesAreABreathNotAStrobe() {
        XCTAssertEqual(spec.twinkleFrames.count, 8, "4 × 2 cells")
        XCTAssertEqual(spec.twinkleFrames.max() ?? 0, 1, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(spec.twinkleFrames.min() ?? 0, 0.2)
    }

    func testTheDissolveFitsItsBeat() {
        let beats = V4.RecognitionTimeline.Beats.standard
        XCTAssertEqual(spec.dissolve.emitSeconds, beats.dissolveEnd - beats.closure, accuracy: 1e-5)
        XCTAssertEqual(spec.sparkle.birthRate, 0, "the closing sparkle is one burst")
        XCTAssertGreaterThan(spec.sparkle.burstCount, 0)
    }
}
