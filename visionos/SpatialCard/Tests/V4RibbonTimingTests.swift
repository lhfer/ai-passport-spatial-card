import XCTest

/// **v4 A2.** When the ribbon's head is where: the eased timing behind `play(path:duration:easing:)`, the
/// speed-matched cubic the recognition is built on, and the inverse that gives every point of a ribbon its age.
final class V4RibbonTimingTests: XCTestCase {
    typealias Timing = V4.RibbonTiming

    func testAnEasedTimingRunsThePathInItsDuration() {
        let timing = Timing.eased(length: 1, duration: 2, delay: 0.5, easing: .easeInOutCubic)
        XCTAssertEqual(timing.start, 0.5, accuracy: 1e-6)
        XCTAssertEqual(timing.end, 2.5, accuracy: 1e-6)
        XCTAssertEqual(timing.distance(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(timing.distance(at: 0.5), 0, accuracy: 1e-6)
        XCTAssertEqual(timing.distance(at: 1.5), 0.5, accuracy: 0.002)       // easeInOutCubic is symmetric
        XCTAssertEqual(timing.distance(at: 2.5), 1, accuracy: 1e-5)
        XCTAssertEqual(timing.distance(at: 9), 1, accuracy: 1e-5)
        var last: Float = -1
        for k in 0...300 {
            let d = timing.distance(at: Float(k) / 100)
            XCTAssertGreaterThanOrEqual(d, last)
            last = d
        }
    }

    /// The age of a ribbon point is "now − when the head passed it": the inverse must round-trip.
    func testTheInverseRoundTrips() {
        let timing = Timing.eased(length: 0.8, duration: 1.4, delay: 0.1, easing: .easeInOutCubic)
        for k in 1..<140 {
            let t = 0.1 + Float(k) / 100
            let back = timing.time(atDistance: timing.distance(at: t))
            XCTAssertEqual(back, t, accuracy: 0.003, "at t = \(t)")
        }
        XCTAssertEqual(timing.time(atDistance: -1), 0.1, accuracy: 1e-6)
        // The first moment the end was reached (not the last moment the head sat there).
        XCTAssertEqual(timing.time(atDistance: 0.8), 1.5, accuracy: 0.003)
    }

    func testTheWalkingInverseMatchesTheBisection() {
        let timing = V4.RecognitionTimeline().timing
        var hint = -1
        var s = timing.totalDistance
        while s > 0 {
            XCTAssertEqual(timing.time(atDistance: s, hint: &hint), timing.time(atDistance: s), accuracy: 1e-5, "at \(s)")
            s -= 0.0041
        }
    }

    func testTheSpeedMatchedCubicHitsBothSlopes() {
        let curve = Timing.speedMatched(startSlope: 0.3, endSlope: 1.8)
        XCTAssertEqual(curve.apply(0), 0, accuracy: 1e-6)
        XCTAssertEqual(curve.apply(1), 1, accuracy: 1e-6)
        XCTAssertEqual(curve.slope(0), 0.3, accuracy: 1e-5)
        XCTAssertEqual(curve.slope(1), 1.8, accuracy: 1e-5)
        for k in 0...100 { XCTAssertGreaterThan(curve.slope(Float(k) / 100), 0) }
    }

    /// An overshooting easing (easeOutBack) would walk the head backwards through its own trail; the table is
    /// made monotonic, so it holds at the far end instead.
    func testAnOvershootingEasingNeverRunsBackwards() {
        let timing = Timing.eased(length: 1, duration: 1, easing: .easeOutBack)
        var last: Float = -1
        for k in 0...200 {
            let d = timing.distance(at: Float(k) / 200)
            XCTAssertGreaterThanOrEqual(d, last - 1e-6)
            last = d
        }
        XCTAssertLessThanOrEqual(timing.totalDistance, 1.2)
    }
}
