import XCTest
import simd

/// **v4 A2.** "认出" — the recognition's beats and flight path, against the brief: burst 0–0.15 s; the ribbon
/// rises out of the screen centre at 0.10 s and spirals once round the device (radius 8–12 cm, height 2 → 20 cm,
/// slow then fast) until 1.20 s; it draws the 0.27 × 0.27 m card outline (30 mm corners, centre 0.22 m up,
/// leaning back 6°) until 1.90 s; the outline closes; everything is done by 2.20 s.
final class V4RecognitionTimelineTests: XCTestCase {
    let timeline = V4.RecognitionTimeline()

    func testTheBeatsAreTheBriefs() {
        let b = timeline.beats
        XCTAssertEqual(b.burstStart, 0, accuracy: 1e-6)
        XCTAssertEqual(b.burstEnd, 0.15, accuracy: 1e-6)
        XCTAssertEqual(b.launch, 0.10, accuracy: 1e-6)
        XCTAssertEqual(b.outlineStart, 1.20, accuracy: 1e-6)
        XCTAssertEqual(b.closure, 1.90, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(b.total, 2.2 + 1e-6)
        XCTAssertEqual(b.outlineHold, 0.5, accuracy: 1e-6)
        XCTAssertTrue(b.burstStart < b.launch && b.launch < b.burstEnd, "the ribbon leaves while the screen bursts")
        XCTAssertTrue(b.launch < b.outlineStart && b.outlineStart < b.closure && b.closure < b.dissolveEnd)
    }

    func testTheGeometryIsTheProductsCard() {
        let g = V4.RecognitionTimeline.Geometry.standard
        XCTAssertEqual(g.cardWidth, 0.27, accuracy: 1e-6)
        XCTAssertEqual(g.cardHeight, 0.27, accuracy: 1e-6)
        XCTAssertEqual(g.cornerRadius, 0.030, accuracy: 1e-6)
        XCTAssertEqual(g.cardCenterHeight, 0.22, accuracy: 1e-6)
        XCTAssertEqual(g.cardTiltDegrees, -6, accuracy: 1e-6)
        // Leaning back: the card's top edge is farther from the reader (−Z) than its bottom edge.
        XCTAssertLessThan(g.onCard(0, 0.1).z, g.onCard(0, -0.1).z)
    }

    func testTheRibbonIsBornAtTheScreenCentreAndRisesStraightOut() {
        XCTAssertEqual(simd_distance(timeline.path.start, [0, timeline.geometry.launchLift, 0]), 0, accuracy: 1e-6)
        XCTAssertEqual(simd_distance(timeline.path.tangent(atDistance: 0), [0, 1, 0]), 0, accuracy: 1e-3)
        var lastY: Float = -1
        var s: Float = 0
        while s <= timeline.spiralStart {
            let y = timeline.path.point(atDistance: s).y
            XCTAssertGreaterThanOrEqual(y, lastY - 1e-5, "the launch never sags (at \(s) m)")
            lastY = y
            s += 0.001
        }
    }

    func testTheSpiralCirclesTheDeviceOnceWhileClimbing() {
        var s = timeline.spiralStart
        var lastY: Float = -1
        var sweep: Float = 0
        var lastAngle: Float?
        while s <= timeline.transitionStart {
            let p = timeline.path.point(atDistance: s)
            let r = simd_length(SIMD2<Float>(p.x, p.z))
            XCTAssertGreaterThanOrEqual(r, 0.08 - 0.001)
            XCTAssertLessThanOrEqual(r, 0.12 + 0.001)
            XCTAssertGreaterThanOrEqual(p.y, lastY - 1e-5, "the spiral only climbs")
            lastY = p.y
            let angle = atan2(p.z, p.x)
            if let lastAngle {
                var d = angle - lastAngle
                d = atan2(sin(d), cos(d))
                sweep += d
            }
            lastAngle = angle
            s += 0.002
        }
        XCTAssertEqual(abs(sweep), 2 * .pi, accuracy: 0.05, "one full turn")
        XCTAssertEqual(timeline.path.point(atDistance: timeline.spiralStart).y, 0.02, accuracy: 1e-4)
        XCTAssertEqual(timeline.path.point(atDistance: timeline.transitionStart).y, 0.20, accuracy: 1e-4)
    }

    /// Every point the head draws between 1.20 and 1.90 s lies on the card's rounded rectangle, in the card's
    /// tilted plane, and the outline closes where it began — on the top-right corner.
    func testTheOutlineIsTheCardsRoundedRectangle() {
        let g = timeline.geometry
        let ax = g.cardWidth / 2, ay = g.cardHeight / 2, r = g.cornerRadius
        var s = timeline.outlineStart
        while s <= timeline.outlineEnd {
            let p = timeline.path.point(atDistance: s)
            let d = p - g.cardCenter
            XCTAssertEqual(simd_dot(d, g.cardNormal), 0, accuracy: 1e-4, "off the card's plane at \(s)")
            let x = simd_dot(d, g.cardRight), y = simd_dot(d, g.cardUp)
            let qx = abs(x) - ax + r, qy = abs(y) - ay + r
            let sdf = simd_length(SIMD2<Float>(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0) - r
            XCTAssertEqual(sdf, 0, accuracy: 0.0003, "off the rounded rectangle at \(s)")
            s += 0.002
        }
        let perimeter = 2 * (g.cardWidth + g.cardHeight) - 8 * r + 2 * .pi * r
        XCTAssertEqual(timeline.outlineEnd - timeline.outlineStart, perimeter, accuracy: 0.001)
        XCTAssertEqual(simd_distance(timeline.path.point(atDistance: timeline.outlineStart), timeline.closurePoint), 0,
                       accuracy: 1e-4, "the outline closes where it began")
        XCTAssertEqual(simd_distance(timeline.closurePoint, g.onCard(ax, ay - r)), 0, accuracy: 1e-5)
    }

    /// No kinks anywhere: the tangent is continuous along the whole flight (G1) — a corner would show as a jump
    /// however small the step — so no stretch of ribbon ever shows one, the joins between launch, spiral,
    /// transition and outline included. And no bend is tighter than 10 mm, so an 11 mm ribbon never folds on
    /// itself in 3D (tighter turns *as seen by the viewer* are the strip's fold guard's business).
    func testTheFlightHasNoKinksAndNoFoldingBends() {
        let step: Float = 0.0001
        var s: Float = 0
        var last = timeline.path.tangent(atDistance: 0)
        var worstJump: Float = 0
        var tightest: Float = .greatestFiniteMagnitude
        while s < timeline.path.length - step {
            s += step
            let t = timeline.path.tangent(atDistance: s)
            let turn = acos(max(-1, min(1, simd_dot(t, last))))
            worstJump = max(worstJump, turn)
            if turn > 1e-5 { tightest = min(tightest, step / turn) }
            last = t
        }
        XCTAssertLessThan(worstJump * 180 / .pi, 1, "no tangent jump: < 1° per 0.1 mm everywhere")
        XCTAssertGreaterThan(tightest, 0.010, "tightest bend \(tightest * 1000) mm")
    }

    func testTheHeadKeepsTheBeats() {
        XCTAssertEqual(timeline.headDistance(at: 0), 0, accuracy: 1e-6)
        XCTAssertEqual(timeline.headDistance(at: timeline.beats.launch), 0, accuracy: 1e-5)
        XCTAssertEqual(timeline.headDistance(at: 1.20), timeline.outlineStart, accuracy: 1e-3)
        XCTAssertEqual(timeline.headDistance(at: 1.90), timeline.path.length, accuracy: 1e-3)
        XCTAssertEqual(timeline.headDistance(at: 3), timeline.path.length, accuracy: 1e-5)
        XCTAssertFalse(timeline.isFlying(at: 0.05))
        XCTAssertTrue(timeline.isFlying(at: 1.0))
        XCTAssertFalse(timeline.isFlying(at: 1.95))
    }

    /// "先慢后快", and no jolt where the spiral hands over to the outline.
    func testSlowThenFastWithoutAJoltAtTheCard() {
        let timing = timeline.timing
        XCTAssertLessThan(timing.speed(at: 0.15), 0.4 * timing.speed(at: 1.15))
        let before = timing.speed(at: 1.1999), after = timing.speed(at: 1.2001)
        XCTAssertEqual(before, after, accuracy: 0.03 * after, "speed at the hand-over: \(before) vs \(after) m/s")
        // Monotonic (Fritsch–Carlson): the spiral's cubic, from its end slopes.
        let a = timeline.beats.launchSlope, b = timeline.spiralEndSlope
        XCTAssertGreaterThan(b, 0)
        XCTAssertLessThanOrEqual(a * a + b * b, 9)
        var last: Float = -1
        for k in 0...230 {
            let d = timing.distance(at: Float(k) / 100)
            XCTAssertGreaterThanOrEqual(d, last)
            last = d
        }
    }

    func testTheLevelsFadeOnTheirBeats() {
        XCTAssertEqual(timeline.ribbonLevel(at: 1.0), 1, accuracy: 1e-6)
        XCTAssertEqual(timeline.ribbonLevel(at: 1.9), 1, accuracy: 1e-6)
        XCTAssertEqual(timeline.ribbonLevel(at: 2.2), 0, accuracy: 1e-6)
        XCTAssertEqual(timeline.outlineLevel(at: 1.0), 0, accuracy: 1e-6)
        XCTAssertEqual(timeline.outlineLevel(at: 1.5), 1, accuracy: 1e-6)
        XCTAssertEqual(timeline.outlineLevel(at: 2.39), 1, accuracy: 1e-6)
        XCTAssertEqual(timeline.outlineLevel(at: 2.7), 0, accuracy: 1e-6)
        XCTAssertEqual(timeline.burstProgress(at: 0.075) ?? -1, 0.5, accuracy: 1e-5)
        XCTAssertNil(timeline.burstProgress(at: 0.2))
        XCTAssertEqual(timeline.dissolveProgress(at: 2.05), 0.5, accuracy: 1e-5)
    }

    /// The art bible's H0: nothing resident inside the device's outline. The only part of the flight over the
    /// device is the launch out of the screen centre (transient, 0.10–0.3 s); everything after it stays
    /// outside the 60 × 95 mm footprint.
    func testTheFlightLeavesTheDeviceFootprint() {
        let halfWidth: Float = 0.030, halfLength: Float = 0.0475
        var s = timeline.spiralStart
        while s <= timeline.path.length {
            let p = timeline.path.point(atDistance: s)
            let over = abs(p.x) < halfWidth && abs(p.z) < halfLength
            XCTAssertFalse(over && p.y < 0.08, "over the device at \(s) m: \(p)")
            s += 0.003
        }
    }

    /// The card outline takes the product's own layout numbers when the app builds it.
    func testAPortraitCardStillClosesOnItsCorner() {
        var g = V4.RecognitionTimeline.Geometry.standard
        g.cardHeight = 0.36
        let portrait = V4.RecognitionTimeline(geometry: g)
        XCTAssertEqual(simd_distance(portrait.closurePoint, g.onCard(0.135, 0.18 - 0.03)), 0, accuracy: 1e-5)
        XCTAssertEqual(portrait.headDistance(at: 1.9), portrait.path.length, accuracy: 1e-3)
    }
}
