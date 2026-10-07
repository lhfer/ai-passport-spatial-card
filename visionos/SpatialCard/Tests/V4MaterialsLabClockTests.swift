import XCTest

/// **v4 A1.** The materials lab's parameter cycles: the brief's numbers (±35°, a sweep every 3 s, a dissolve every
/// 4 s that holds 1 s) as functions of time.
final class V4MaterialsLabClockTests: XCTestCase {
    typealias Clock = V4.MaterialsLabClock

    func testSwayStaysInsideThirtyFiveDegrees() {
        let limit = 35 * Float.pi / 180
        XCTAssertEqual(Clock.sway(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(Clock.sway(at: Clock.swayPeriod / 4), limit, accuracy: 1e-5)
        XCTAssertEqual(Clock.sway(at: Clock.swayPeriod * 3 / 4), -limit, accuracy: 1e-5)
        for step in 0...200 {
            XCTAssertLessThanOrEqual(abs(Clock.sway(at: Double(step) * 0.05)), limit + 1e-6)
        }
    }

    func testSweepEveryThreeSeconds() {
        XCTAssertEqual(Clock.sweep(at: 0), 0)
        XCTAssertEqual(Clock.sweep(at: Clock.sweepDuration), 1, accuracy: 1e-6)
        XCTAssertEqual(Clock.sweep(at: 2.9), 1, "rests past the far corner")
        XCTAssertEqual(Clock.sweep(at: 3.0), 0, accuracy: 1e-6, "the next sweep starts")
        XCTAssertEqual(Clock.sweep(at: 3.7), Clock.sweep(at: 0.7), accuracy: 1e-6)
        var previous: Float = -1
        for step in 0...14 {
            let s = Clock.sweep(at: Double(step) * 0.1)
            XCTAssertGreaterThanOrEqual(s, previous)
            previous = s
        }
    }

    /// A4's `CardSurfaceStyle` receives the sweep as linear progress, nil at rest.
    func testSweepProgressAsA4HandsIt() {
        XCTAssertEqual(Clock.sweepProgress(at: 0), 0)
        XCTAssertEqual(Clock.sweepProgress(at: 0.7) ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertNil(Clock.sweepProgress(at: 2))
        XCTAssertEqual(Clock.sweepProgress(at: 3.7) ?? -1, 0.5, accuracy: 1e-6)
    }

    func testDissolveCycle() {
        XCTAssertEqual(Clock.dissolve(at: 0), 0)
        XCTAssertEqual(Clock.dissolve(at: Clock.dissolveRise), 1, accuracy: 1e-6)
        XCTAssertEqual(Clock.dissolve(at: Clock.dissolveRise + 0.5), 1, "holds for a second")
        XCTAssertEqual(Clock.dissolve(at: 3.999), 0, accuracy: 1e-3)
        XCTAssertEqual(Clock.dissolve(at: 4.0), 0, accuracy: 1e-6)
        let falling = Clock.dissolve(at: 3.4)
        XCTAssertGreaterThan(falling, 0)
        XCTAssertLessThan(falling, 1)
        XCTAssertEqual(Clock.dissolve(at: 5.2), Clock.dissolve(at: 1.2), accuracy: 1e-6)
        XCTAssertEqual(Clock.dissolvePeriod, 4)
    }

    func testNegativeTimeWraps() {
        XCTAssertEqual(Clock.positiveModulo(-0.5, 3), 2.5, accuracy: 1e-9)
        XCTAssertEqual(Clock.sweep(at: -0.5), Clock.sweep(at: 2.5), accuracy: 1e-6)
    }
}
