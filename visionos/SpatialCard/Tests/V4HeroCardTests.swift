import XCTest
import simd

/// **v4 A4 · 名片本体.** The hero card's timeline, odometer and layout, checked without a RealityKit scene: the
/// numbers the art bible sets (spring overshoot, anticipation depth, stagger, breath, sweep interval, foil limits)
/// and the brief's (layer heights 3 / 10 / 18 mm, 40 ms apart, entrance ≤ 2.5 s, 0 → 4,401 in 1.2 s, fast then slow).
final class V4HeroCardTests: XCTestCase {
    private typealias Motion = V4.HeroCardMotion
    private let timeline = V4.HeroCardTimeline()

    // MARK: - Springs

    func testTheSpringStartsAtRestAndSettlesOnTarget() {
        XCTAssertEqual(Motion.spring(0, response: 0.5, damping: 0.72), 0, accuracy: 1e-12)
        XCTAssertEqual(Motion.spring(-1, response: 0.5, damping: 0.72), 0, accuracy: 1e-12)
        // Released from rest: the first millisecond barely moves.
        XCTAssertLessThan(Motion.spring(0.001, response: 0.5, damping: 0.72), 1e-3)
        XCTAssertEqual(Motion.spring(1.0, response: 0.5, damping: 0.72), 1, accuracy: 0.005)
    }

    /// Bible §3: springs are response 0.35–0.50, damping 0.65–0.80, and overshoot 2–6 % — checked numerically on the
    /// curves that actually play (the rise's spring chases a ramp, the layers' is released onto a step).
    func testBothSpringsStayInsideTheBible() {
        for (response, damping) in [(timeline.riseResponse, timeline.riseDamping),
                                    (timeline.layerResponse, timeline.layerDamping)] {
            XCTAssertGreaterThanOrEqual(response, 0.35, "bible: response 0.35–0.50")
            XCTAssertLessThanOrEqual(response, 0.50, "bible: response 0.35–0.50")
            XCTAssertGreaterThanOrEqual(damping, 0.65, "bible: damping 0.65–0.80")
            XCTAssertLessThanOrEqual(damping, 0.80, "bible: damping 0.65–0.80")
        }
        let grid = stride(from: 0.0, through: 3.0, by: 0.0005)
        let layerPeak = grid.map { Motion.spring($0, response: timeline.layerResponse, damping: timeline.layerDamping) }.max() ?? 0
        XCTAssertEqual(layerPeak - 1, Motion.overshoot(damping: timeline.layerDamping), accuracy: 0.002)
        let risePeak = grid.map {
            Motion.rampedSpring($0, ramp: timeline.riseRamp, response: timeline.riseResponse, damping: timeline.riseDamping)
        }.max() ?? 0
        for peak in [layerPeak, risePeak] {
            XCTAssertGreaterThanOrEqual(peak - 1, 0.02)
            XCTAssertLessThanOrEqual(peak - 1, 0.06)
        }
    }

    func testARampedSpringStartsAtRestAndSettlesOnTarget() {
        let f = { (t: Double) in Motion.rampedSpring(t, ramp: 0.45, response: 0.5, damping: 0.65) }
        XCTAssertEqual(f(0), 0, accuracy: 1e-12)
        XCTAssertLessThan(f(0.01), 1e-3, "zero velocity at lift-off")
        XCTAssertEqual(f(2), 1, accuracy: 0.002)
        // No ramp = the plain spring.
        XCTAssertEqual(Motion.rampedSpring(0.3, ramp: 0, response: 0.5, damping: 0.65),
                       Motion.spring(0.3, response: 0.5, damping: 0.65), accuracy: 1e-12)
        // Driven along a ramp it is slower than released onto a step: at 0.2 s the step has done most of its travel.
        XCTAssertLessThan(f(0.2), Motion.spring(0.2, response: 0.5, damping: 0.65) - 0.3)
    }

    /// Bible §3: a big move takes 0.8–1.6 s. The rise, anticipation included, settles (±1 % of its climb) inside that.
    func testTheRiseIsABigMoveNotAPop() {
        let climb = timeline.riseHeight - timeline.startHeight
        var settled = 0.0
        for t in stride(from: 0.0, through: 2.5, by: 0.001) {
            let y = timeline.pose(at: t, startScale: 0.175).position.y
            if abs(y - timeline.riseHeight) > 0.01 * climb { settled = t }
        }
        XCTAssertGreaterThanOrEqual(settled, 0.8)
        XCTAssertLessThanOrEqual(settled, 1.6)
        // …and the pop-up only opens once the card is nearly there.
        let there = (timeline.pose(at: timeline.layerStart, startScale: 0.175).position.y - timeline.startHeight) / climb
        XCTAssertGreaterThan(there, 0.9)
    }

    func testAnticipationDipsThenSpringsFromRest() {
        let lead = 0.1, depth = 0.05
        let v = { (t: Double) in Motion.anticipatedSpring(t, lead: lead, depth: depth, response: 0.42, damping: 0.68) }
        XCTAssertEqual(v(lead), -depth, accuracy: 1e-9)
        XCTAssertLessThan(v(lead / 2), 0)
        // Continuous (and flat) where the spring takes over.
        XCTAssertEqual(v(lead - 1e-6), v(lead + 1e-6), accuracy: 1e-5)
        XCTAssertEqual(v(2), 1, accuracy: 0.005)
    }

    // MARK: - The rise

    func testTheCardStartsFlatOnTheScreenAtTheScreensSize() {
        let layout = V4.HeroCardLayout(shape: .portrait)
        let start = layout.screenScale(screen: [0.03672, 0.04896])
        let pose = timeline.pose(at: 0, startScale: start)
        XCTAssertEqual(pose.pitch, -.pi / 2, accuracy: 1e-6, "lying face-up on the LCD")
        XCTAssertEqual(pose.scale, start, accuracy: 1e-6)
        XCTAssertEqual(pose.opacity, 0, accuracy: 1e-6)
        XCTAssertEqual(pose.position.y, timeline.startHeight, accuracy: 1e-6)
        // At the LCD's size: it never overhangs the lit area.
        XCTAssertLessThanOrEqual(layout.size.x * start, 0.03672 + 1e-6)
        XCTAssertLessThanOrEqual(layout.size.y * start, 0.04896 + 1e-6)
    }

    /// Bible §3: 60–120 ms of 3–6 % reverse movement before a big move.
    func testTheRiseIsAnticipated() {
        XCTAssertGreaterThanOrEqual(timeline.anticipation, 0.06)
        XCTAssertLessThanOrEqual(timeline.anticipation, 0.12)
        XCTAssertGreaterThanOrEqual(timeline.anticipationSquash, 0.03)
        XCTAssertLessThanOrEqual(timeline.anticipationSquash, 0.06)
        let start: Float = 0.175
        let squashed = timeline.pose(at: timeline.anticipation, startScale: start)
        XCTAssertEqual(squashed.scale, start * Float(1 - timeline.anticipationSquash), accuracy: 1e-6)
        XCTAssertLessThan(timeline.pose(at: timeline.anticipation / 2, startScale: start).position.y, timeline.startHeight)
    }

    func testTheCardLandsUprightAtTwentyTwoCentimetresWithASmallOvershoot() {
        let start: Float = 0.175
        let samples = stride(from: 0.0, through: timeline.entranceDuration, by: 0.001).map { timeline.pose(at: $0, startScale: start) }
        let highest = samples.map(\.position.y).max() ?? 0
        let climb = timeline.riseHeight - timeline.startHeight
        let over = (highest - timeline.riseHeight) / climb
        XCTAssertGreaterThanOrEqual(over, 0.02, "a 2–6 % overshoot")
        XCTAssertLessThanOrEqual(over, 0.06, "a 2–6 % overshoot")
        let end = timeline.pose(at: timeline.entranceDuration, startScale: start)
        XCTAssertEqual(end.position.y, 0.22, accuracy: 0.0005)
        XCTAssertEqual(end.position.z, 0, accuracy: 1e-6, "the arc has closed")
        XCTAssertEqual(end.pitch, timeline.finalPitch, accuracy: 0.002)
        XCTAssertEqual(end.scale, 1, accuracy: 0.002)
        XCTAssertEqual(end.opacity, 1, accuracy: 1e-6)
    }

    /// Bible §3: moves over 5 cm travel on an arc raised 10–25 % of the distance.
    func testTheRiseBowsTowardsTheReader() {
        let climb = timeline.riseHeight - timeline.startHeight
        XCTAssertGreaterThanOrEqual(timeline.arcBow / climb, 0.10)
        XCTAssertLessThanOrEqual(timeline.arcBow / climb, 0.25)
        let mid = timeline.pose(at: timeline.anticipation + timeline.arcDuration / 2, startScale: 0.175)
        XCTAssertEqual(mid.position.z, timeline.arcBow, accuracy: 1e-5)
    }

    func testFollowThroughStandsUpAfterTheClimbStarts() {
        XCTAssertGreaterThan(timeline.standLag, timeline.scaleLag)
        let early = timeline.pose(at: timeline.anticipation + timeline.standLag, startScale: 0.175)
        XCTAssertGreaterThan(early.position.y, timeline.startHeight + 0.002, "already climbing")
        XCTAssertEqual(early.pitch, -.pi / 2, accuracy: 1e-5, "not yet standing")
    }

    // MARK: - The pop-up

    func testTheLayersPopFortyMillisecondsApartToThreeTenAndEighteenMillimetres() {
        XCTAssertEqual(timeline.layerHeights, [0.003, 0.010, 0.018])
        let starts = (0..<3).map(timeline.layerStartTime).sorted()
        XCTAssertEqual(starts[1] - starts[0], 0.040, accuracy: 1e-9)
        XCTAssertEqual(starts[2] - starts[1], 0.040, accuracy: 1e-9)
        // Front to back: the steam leads, the sky follows.
        XCTAssertLessThan(timeline.layerStartTime(2), timeline.layerStartTime(1))
        XCTAssertLessThan(timeline.layerStartTime(1), timeline.layerStartTime(0))
        for index in 0..<3 {
            let settled = timeline.layer(index, at: timeline.entranceDuration)
            XCTAssertEqual(settled.height, timeline.layerHeights[index], accuracy: 0.0001)
            XCTAssertEqual(settled.scale, 1, accuracy: 0.002)
            // Closed while the card rises.
            XCTAssertEqual(timeline.layer(index, at: 0.3).height, timeline.layerFlatHeights[index], accuracy: 1e-7)
        }
    }

    func testEachLayerDipsBeforeItPops() {
        for index in 0..<3 {
            let dipped = timeline.layer(index, at: timeline.layerStartTime(index) + timeline.layerLead)
            XCTAssertLessThan(dipped.height, timeline.layerFlatHeights[index])
            // …but never through the type layer (0.9 mm) or the face.
            XCTAssertGreaterThan(dipped.height, 0.0009)
        }
    }

    /// The pop-up can never cross itself: sky under figure under steam, at every instant, overshoot included.
    func testTheLayersStayInOrderThroughTheWholeEntrance() {
        for t in stride(from: 0.0, through: timeline.entranceDuration, by: 0.002) {
            let h = (0..<3).map { timeline.layer($0, at: t).height }
            XCTAssertLessThan(h[0], h[1], "t = \(t)")
            XCTAssertLessThan(h[1], h[2], "t = \(t)")
        }
    }

    // MARK: - Beats

    func testTheEntranceIsSequencedAndFitsTwoAndAHalfSeconds() {
        XCTAssertLessThanOrEqual(timeline.entranceDuration, 2.5)
        XCTAssertGreaterThan(timeline.layerStart, timeline.anticipation, "the pop-up opens after the rise starts")
        XCTAssertGreaterThan(timeline.odometerStart, timeline.layerStart, "the count rolls after the pop-up opens")
        XCTAssertEqual(timeline.odometerDuration, 1.2, accuracy: 1e-9)
        XCTAssertEqual(timeline.odometerRoll, V4.HeroCardOdometer(target: 4401).rollDuration, accuracy: 1e-9)
        XCTAssertEqual(timeline.sparkleTime, timeline.countLanding, accuracy: 1e-9)
        // The gold glint crosses the ink count from the landing, and is gone before the first idle sweep ends.
        XCTAssertNil(timeline.glint(at: timeline.countLanding - 0.01))
        XCTAssertEqual(timeline.glint(at: timeline.countLanding) ?? -1, 0, accuracy: 1e-9)
        XCTAssertNil(timeline.glint(at: timeline.countLanding + timeline.glintDuration + 0.01))
        XCTAssertLessThan(timeline.firstSweepTime, timeline.entranceDuration + 0.001)
    }

    // MARK: - Idle

    func testBreathStaysInsideTheBible() {
        XCTAssertGreaterThanOrEqual(timeline.breathAmplitude, 0.0005)
        XCTAssertLessThanOrEqual(timeline.breathAmplitude, 0.0015)
        XCTAssertGreaterThanOrEqual(timeline.breathPeriod, 4)
        XCTAssertLessThanOrEqual(timeline.breathPeriod, 6)
        XCTAssertEqual(timeline.breath(atIdle: 0), 0, accuracy: 1e-9, "no jump when idle takes over")
        let values = stride(from: 0.0, through: 20, by: 0.01).map { timeline.breath(atIdle: $0) }
        XCTAssertLessThanOrEqual(values.map(abs).max() ?? 0, timeline.breathAmplitude + 1e-7)
    }

    func testSweepsComeEveryEightToTwelveSecondsAndAreReproducible() {
        let times = timeline.sweepTimes(until: 200)
        XCTAssertEqual(times.first ?? -1, timeline.firstSweepTime, accuracy: 1e-9)
        XCTAssertGreaterThan(times.count, 10)
        for (a, b) in zip(times, times.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b - a, 8)
            XCTAssertLessThanOrEqual(b - a, 12)
        }
        XCTAssertEqual(times, timeline.sweepTimes(until: 200))
        XCTAssertNotNil(timeline.sweep(at: timeline.firstSweepTime + 0.5, times: times))
        XCTAssertNil(timeline.sweep(at: timeline.firstSweepTime + timeline.sweepDuration + 0.5, times: times))
    }

    // MARK: - Foil and rim

    func testFoilAndRimFollowTheViewingAngleWithinTheBible() {
        XCTAssertEqual(V4.HeroCardLook.foil(facing: 1), 0.12, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardLook.foil(facing: 0), 0.45, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardLook.rim(facing: 1), 0.45, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardLook.rim(facing: 0), 0.90, accuracy: 1e-6)
        var last: Float = 0
        for f in stride(from: Float(1), through: 0, by: -0.01) {
            let foil = V4.HeroCardLook.foil(facing: f)
            XCTAssertGreaterThanOrEqual(foil, last - 1e-6)
            XCTAssertLessThanOrEqual(foil, 0.45 + 1e-6)
            last = foil
        }
        XCTAssertEqual(V4.HeroCardLook.facing(normal: [0, 0, 1], toViewer: [0, 0, 3]), 1, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardLook.facing(normal: [0, 0, 1], toViewer: [1, 0, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(V4.HeroCardLook.facing(normal: .zero, toViewer: [1, 0, 0]), 1, "degenerate reads as square-on")
    }

    // MARK: - Odometer

    private let odometer = V4.HeroCardOdometer(target: 4401)

    func testTheCountRunsFromZeroToTheTargetInOnePointTwoSeconds() {
        XCTAssertEqual(odometer.value(at: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(odometer.value(at: -1), 0, accuracy: 1e-9)
        XCTAssertEqual(odometer.value(at: 1.2), 4401, accuracy: 1e-9)
        XCTAssertEqual(odometer.value(at: 5), 4401, accuracy: 1e-9)
        XCTAssertEqual(odometer.displayed(at: 1.2), 4401)
        var last = -1.0
        for t in stride(from: 0.0, through: 1.2, by: 0.001) {
            XCTAssertGreaterThanOrEqual(odometer.value(at: t), last)
            last = odometer.value(at: t)
        }
    }

    /// 先快后慢: most of the number arrives early, and the rate only ever falls.
    func testTheCountIsFastThenSlow() {
        XCTAssertGreaterThan(odometer.value(at: 0.3), 0.6 * 4401)
        XCTAssertGreaterThan(odometer.value(at: 0.6), 0.9 * 4401)
        XCTAssertLessThan(4401 - odometer.value(at: 0.9), 40, "the last followers tick in one by one")
        var last = Double.infinity
        for t in stride(from: 0.001, through: 1.199, by: 0.01) {
            XCTAssertLessThan(odometer.rate(at: t), last)
            last = odometer.rate(at: t)
        }
        XCTAssertEqual(odometer.rate(at: 1.2), 0, accuracy: 1e-9, "lands with zero speed")
    }

    func testTheInverseMatchesTheCurve() {
        for v in [1.0, 1000, 2200, 4000, 4400, 4401] {
            XCTAssertEqual(odometer.value(at: odometer.time(reaching: v)), v, accuracy: 1e-6)
        }
    }

    func testEveryReelLandsExactlyOnItsDigit() {
        let digits = [1, 0, 4, 4]                    // ones, tens, hundreds, thousands of 4401
        XCTAssertEqual(odometer.landing, 1.29, accuracy: 1e-9)
        for column in 0..<4 {
            for t in [odometer.landing, 5] {
                let end = odometer.reel(column: column, at: t)
                XCTAssertEqual(end.digit, digits[column], "column \(column)")
                XCTAssertEqual(end.roll, 0, accuracy: 1e-9)
            }
            let start = odometer.reel(column: column, at: 0)
            XCTAssertEqual(start.digit, 0)
            XCTAssertEqual(start.roll, 0, accuracy: 1e-9)
        }
        // Still rolling onto the 1 until the landing.
        XCTAssertGreaterThan(odometer.reel(column: 0, at: 1.2 + 0.045).roll, 0.1)
    }

    /// Round 3's bug: a value-based carry showed 4,991 while the count was 3,891. A reel may lag the count by one
    /// roll, never lead it.
    func testReelsAreNeverAheadOfTheCount() {
        for column in 0..<4 {
            let unit = pow(10, Double(column))
            for t in stride(from: 0.0, through: 1.4, by: 0.0007) {
                XCTAssertLessThanOrEqual(odometer.reelPosition(column: column, at: t), odometer.value(at: t) / unit + 1e-9,
                                         "column \(column) at \(t)")
            }
        }
        // The moment round 3 read 4,991: the thousands reel is on its 3, the hundreds one at most on its 8 (it lags
        // by up to one roll — the count moves ≈ 3,500 a second there).
        let t = odometer.time(reaching: 3891)
        XCTAssertEqual(odometer.reel(column: 3, at: t).digit, 3)
        XCTAssertEqual(odometer.reel(column: 3, at: t).roll, 0, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(odometer.reelPosition(column: 2, at: t), 38.91)
        XCTAssertGreaterThan(odometer.reelPosition(column: 2, at: t), 35)
    }

    func testReelsOnlyRollForwardAndTheSlowOnesRestOnDigits() {
        for column in 0..<4 {
            var last = -1.0
            for t in stride(from: 0.0, through: 1.4, by: 0.0005) {
                let p = odometer.reelPosition(column: column, at: t)
                XCTAssertGreaterThanOrEqual(p, last - 1e-9, "column \(column) at \(t)")
                last = p
            }
        }
        // Thousands: only ever between digits for one roll after the count passes a multiple of 1000.
        let resting = odometer.time(reaching: 3800)                  // 172 ms after the 3,000 carry
        XCTAssertEqual(odometer.reel(column: 3, at: resting).roll, 0, accuracy: 1e-9)
        let carry = odometer.time(reaching: 3000)
        XCTAssertEqual(odometer.reel(column: 3, at: carry + odometer.rollDuration / 2).roll, 0.5, accuracy: 1e-6)
    }

    func testLeadingZerosLightUpAsTheCountRollsIntoThem() {
        XCTAssertEqual(odometer.lit(column: 0, at: 0), 1)
        for column in 1..<4 {
            XCTAssertEqual(odometer.lit(column: column, at: 0), 0, accuracy: 1e-9)
            XCTAssertEqual(odometer.lit(column: column, at: odometer.landing), 1, accuracy: 1e-9)
        }
        // The thousands reel lights while it rolls 0 → 1, in the 90 ms after the count reaches 1,000.
        let thousand = odometer.time(reaching: 1000)
        XCTAssertEqual(odometer.lit(column: 3, at: odometer.time(reaching: 900)), 0, accuracy: 1e-9)
        XCTAssertEqual(odometer.lit(column: 3, at: thousand + odometer.rollDuration / 2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(odometer.lit(column: 3, at: thousand + odometer.rollDuration), 1, accuracy: 1e-9)
    }

    /// Faster reels blur; the view keys on this. The ones reel is still spinning well past half-way. (`speed` lags
    /// the count by half a roll, so the search starts once the rolls have started.)
    func testReelsComeIntoFocusFromLeftToRight() {
        let start = odometer.rollDuration / 2 + 0.001
        let focus = { (column: Int) -> Double in
            stride(from: start, through: 1.3, by: 0.001).first { self.odometer.speed(column: column, at: $0) < 12 } ?? 1.3
        }
        XCTAssertLessThan(focus(3), focus(2))
        XCTAssertLessThan(focus(2), focus(1))
        XCTAssertLessThan(focus(1), focus(0))
        XCTAssertGreaterThan(focus(0), 1.0)
    }

    func testGoldDustPopsOnLeadingCarriesThenOnTheLanding() {
        let pops = odometer.pops(minSpacing: 0.08)
        XCTAssertGreaterThanOrEqual(pops.count, 6)
        XCTAssertLessThanOrEqual(pops.count, 16)
        for (a, b) in zip(pops, pops.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.time - a.time, 0.08 - 1e-9)
        }
        XCTAssertEqual(pops.last?.isLanding, true)
        XCTAssertEqual(pops.last?.time ?? 0, odometer.landing, accuracy: 1e-9)
        XCTAssertEqual(pops.last?.count, 2)
        XCTAssertTrue(pops.dropLast().allSatisfy { ($0.column == 2 && $0.count == 1) || ($0.column == 3 && $0.count == 2) })
        // 1–2 motes each, so a whole count is a few dozen motes at most.
        XCTAssertLessThanOrEqual(pops.map(\.count).reduce(0, +), 20)
        // The hundreds carries of the slow tail all get their own pop, half-way through their roll…
        for v in [4300.0, 4400] {
            let t = odometer.time(reaching: v) + odometer.rollDuration / 2
            XCTAssertTrue(pops.contains { abs($0.time - t) < 1e-9 }, "carry at \(v)")
        }
        // …and every new thousand gets one over the thousands reel, crowded as the start is.
        for v in [1000.0, 2000, 3000, 4000] {
            let t = odometer.time(reaching: v) + odometer.rollDuration / 2
            XCTAssertTrue(pops.contains { abs($0.time - t) < 1e-9 && $0.column == 3 }, "thousand at \(v)")
        }
    }

    func testSmallAndEmptyCountsStillLand() {
        let zero = V4.HeroCardOdometer(target: 0)
        XCTAssertEqual(zero.digitCount, 1)
        XCTAssertEqual(zero.pops().count, 1)
        XCTAssertEqual(zero.reel(column: 0, at: zero.landing).digit, 0)
        let seven = V4.HeroCardOdometer(target: 7)
        XCTAssertEqual(seven.reel(column: 0, at: seven.landing).digit, 7)
        XCTAssertEqual(seven.pops().map(\.isLanding), [true])
    }

    // MARK: - Numbers and layout

    func testNumbersPrintTheWayXiaohongshuDoes() {
        XCTAssertEqual(V4.HeroCardNumbers.grouped(4401), "4,401")
        XCTAssertEqual(V4.HeroCardNumbers.grouped(0), "0")
        XCTAssertEqual(V4.HeroCardNumbers.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(V4.HeroCardNumbers.compact(44_000), "4.4万")
        XCTAssertEqual(V4.HeroCardNumbers.compact(40_000), "4万")
        XCTAssertEqual(V4.HeroCardNumbers.compact(9_999), "9,999")
        XCTAssertEqual(V4.HeroCardNumbers.compact(120_000_000), "1.2亿")
    }

    func testDigitReelsAndCommasLineUp() {
        let four = V4.HeroCardDigitLayout(target: 4401)
        XCTAssertEqual(four.digitCount, 4)
        XCTAssertEqual((0..<4).map(four.commaAfter), [true, false, false, false])
        XCTAssertEqual(four.centerEm(ofReel: 0), V4.HeroCardDigitLayout.reelEm / 2, accuracy: 1e-6)
        XCTAssertEqual(four.centerEm(ofReel: 1) - four.centerEm(ofReel: 0),
                       V4.HeroCardDigitLayout.reelEm + V4.HeroCardDigitLayout.commaEm, accuracy: 1e-6)
        XCTAssertEqual(four.reel(ofColumn: 0), 3)
        let seven = V4.HeroCardDigitLayout(target: 1_234_567)
        XCTAssertEqual(seven.commaCount, 2)
        XCTAssertEqual(V4.HeroCardDigitLayout(target: 12).commaCount, 0)
    }

    func testTheArtAndTheTypeFitInsideThePanel() {
        for shape in V4.HeroCardShape.allCases {
            let layout = V4.HeroCardLayout(shape: shape)
            let panel = layout.panel
            XCTAssertEqual(panel.width, layout.size.x - 2 * V4.HeroCardLayout.panelInset, accuracy: 1e-6)
            // The frost covers the whole face; the content box sits inside it.
            XCTAssertEqual(layout.face.width, layout.size.x - 2 * V4.HeroCardLayout.faceInset, accuracy: 1e-6)
            XCTAssertLessThan(layout.face.minX, panel.minX)
            XCTAssertGreaterThan(layout.face.maxY, panel.maxY)
            // The window is inside the panel; the popped-out hair (above the window) too.
            XCTAssertGreaterThanOrEqual(layout.artWindow.minX, panel.minX)
            XCTAssertLessThanOrEqual(layout.artWindow.maxX, panel.maxX)
            XCTAssertLessThanOrEqual(layout.avatarQuad.maxY, panel.maxY + 1e-6, "\(shape)")
            // The window shows 10–96 % of the image, so the quad and the window agree.
            XCTAssertEqual(layout.avatarUV([layout.artWindow.minX, layout.artWindow.maxY]).y, 0.10, accuracy: 1e-5)
            XCTAssertEqual(layout.avatarUV([layout.artWindow.maxX, layout.artWindow.minY]).y, 0.96, accuracy: 1e-5)
            // Type below the art, with room for the column (name ≈ 40 mm, count ≈ 45, tags ≈ 17 in the lab's
            // measurements) above the panel's bottom edge.
            XCTAssertLessThan(layout.nameTop, layout.artWindow.minY)
            XCTAssertLessThan(layout.statsTopEstimate, layout.nameTop)
            XCTAssertGreaterThan(layout.nameTop - panel.minY, 0.105, "\(shape)")
            XCTAssertGreaterThanOrEqual(layout.textLeft, panel.minX + 0.008)
            XCTAssertLessThanOrEqual(layout.textRight, panel.maxX - 0.008)
            // Points: the SwiftUI view is the card's size at 1360 pt/m.
            let corner = layout.viewPoint([-layout.size.x / 2, layout.size.y / 2])
            XCTAssertEqual(corner.x, 0, accuracy: 1e-4)
            XCTAssertEqual(corner.y, 0, accuracy: 1e-4)
        }
        XCTAssertEqual(V4.HeroCardLayout(shape: .square).size, [0.27, 0.27])
        XCTAssertEqual(V4.HeroCardLayout(shape: .portrait).size, [0.20, 0.28])
        XCTAssertEqual(V4.HeroCardLayout(shape: .portrait).size.x / V4.HeroCardLayout(shape: .portrait).size.y,
                       5.0 / 7.0, accuracy: 1e-6)
    }
}
