import XCTest
import simd

/// **v4 B4 §1** — the recognition in the hand: the decision made before take-off, the frozen hinge angle, and the flight
/// (out of the screen, over the top edge, round the hand card's up axis, the outline where the hand card will stand).
final class V4HandRecognitionTests: XCTestCase {
    typealias Plan = V4.RecognitionPlan
    typealias Timeline = V4.RecognitionTimeline

    /// The measured case (60 × 96 mm, the LCD 1.64 / 11.52 mm off its centre) and the hinge on its top edge, 6 mm up.
    static let caseCenter = SIMD3<Float>(0.00164, 0, 0.01152)
    static let hinge = caseCenter + SIMD3<Float>(0, 0.006, -0.048)
    static let angles: [Float] = [0, 0.15, 0.35, HandFacing.hingeClamp]

    func hand(_ angle: Float) -> Timeline {
        Timeline(hand: .init(hinge: Self.hinge, hingeAngle: angle))
    }

    // MARK: The decision

    func testTheDecisionReadsTheTiltAndTheDeskGate() {
        let deg: Float = .pi / 180
        // Run 1's first recognition: in the hand at 100°, the fresh desk gate still at its desk prior.
        XCTAssertEqual(Plan.decide(tilt: 100 * deg, deskGateOnDesk: true, handFormAvailable: true).place, .hand)
        // Run 1's summons in the hand: 72–90°, the desk gate long since in "hand".
        XCTAssertEqual(Plan.decide(tilt: 72 * deg, deskGateOnDesk: false, handFormAvailable: true).place, .hand)
        // Held nearly flat in a palm after a while in the hand: the desk gate's answer decides.
        XCTAssertEqual(Plan.decide(tilt: 30 * deg, deskGateOnDesk: false, handFormAvailable: true).place, .hand)
        // Lying on the desk.
        XCTAssertEqual(Plan.decide(tilt: 3 * deg, deskGateOnDesk: true, handFormAvailable: true).place, .desk)
        // The desk gate's own threshold: up to 45° is still the desk, over it is the hand.
        XCTAssertEqual(Plan.decide(tilt: Plan.handTilt, deskGateOnDesk: true, handFormAvailable: true).place, .desk)
        XCTAssertEqual(Plan.decide(tilt: 44 * deg, deskGateOnDesk: true, handFormAvailable: true).place, .desk)
        XCTAssertEqual(Plan.decide(tilt: 46 * deg, deskGateOnDesk: true, handFormAvailable: true).place, .hand)
        XCTAssertEqual(Plan.handTilt, DeskOrientationGate().exitAngle)
        // Nothing to read yet: the desk (the gate's own prior).
        XCTAssertEqual(Plan.decide(tilt: nil, deskGateOnDesk: true, handFormAvailable: true).place, .desk)
        // No hinged hand form (`--hand-form hover`, the image tracker): the desk path and the closure's unfold.
        XCTAssertEqual(Plan.decide(tilt: 100 * deg, deskGateOnDesk: false, handFormAvailable: false).place, .desk)
        XCTAssertTrue(Plan.decide(tilt: 100 * deg, deskGateOnDesk: true, handFormAvailable: true).reason.contains("100°"))
    }

    // MARK: The frozen hinge angle

    /// The angle the outline is drawn at is the one the facing tick would settle the card at: its own fixed point.
    func testTheRestingAngleIsTheFacingTicksFixedPoint() {
        let halfHeight: Float = 0.07
        for head in [SIMD3<Float>(0, -0.25, 0.30), SIMD3<Float>(0.05, -0.10, 0.40), SIMD3<Float>(0, -0.40, 0.15)] {
            let angle = HandFacing.restingHingeAngle(weight: HandFacing.hingeWeight, halfHeight: halfHeight, head: head)
            let next = HandFacing.hingeAngle(weight: HandFacing.hingeWeight,
                                             card: HandFacing.cardCentre(angle: angle, halfHeight: halfHeight), head: head)
            XCTAssertEqual(angle, next, accuracy: 0.2 * .pi / 180, "head \(head)")
            XCTAssertGreaterThanOrEqual(angle, 0)
            XCTAssertLessThanOrEqual(angle, HandFacing.hingeClamp + 1e-6)
        }
        XCTAssertEqual(HandFacing.restingHingeAngle(weight: 0.6, halfHeight: halfHeight, head: nil), 0)
    }

    // MARK: The flight

    /// The outline is the hand card: its four corners are where the hand form puts the card's — the hinge frame
    /// (`HandFacing.base`), the arm at the hinge angle, the card half its height up the arm — to well under a millimetre,
    /// and every point the head draws lies on that card's rounded rectangle.
    func testTheOutlineIsWhereTheHandCardStands() {
        for angle in Self.angles {
            let t = hand(angle)
            XCTAssertEqual(t.place, .hand)
            let q = HandFacing.base * HandFacing.hinged(angle: angle)
            let halfW: Float = 0.05, halfH: Float = 0.07
            let center = Self.hinge + q.act([0, halfH, 0])
            let expected = [center + q.act([halfW, halfH, 0]), center + q.act([-halfW, halfH, 0]),
                            center + q.act([-halfW, -halfH, 0]), center + q.act([halfW, -halfH, 0])]
            for (corner, want) in zip(t.outline.corners, expected) {
                XCTAssertLessThan(simd_distance(corner, want), 0.0005, "angle \(angle): \(corner) vs \(want)")
            }
            // Its bottom edge is on the hinge.
            XCTAssertLessThan(simd_distance(t.outline.on(0, -halfH), Self.hinge), 1e-5)
            var s = t.outlineStart
            while s <= t.outlineEnd {
                let d = t.outline.distance(to: t.path.point(atDistance: s))
                XCTAssertEqual(d.offPlane, 0, accuracy: 1e-4, "off the card's plane at \(s), angle \(angle)")
                XCTAssertEqual(d.edge, 0, accuracy: 0.0003, "off the rounded rectangle at \(s), angle \(angle)")
                s += 0.002
            }
            let r = t.outline.cornerRadius
            XCTAssertLessThan(simd_distance(t.closurePoint, t.outline.on(halfW, halfH - r)), 1e-5, "closes on its corner")
        }
    }

    /// Born on the screen, it leaves along the screen's normal, and is 2–3 cm off the screen when it heads for the top edge.
    func testItIsBornOnTheScreenAndLeavesAlongItsNormal() {
        for angle in Self.angles {
            let t = hand(angle)
            let g = t.hand!
            XCTAssertLessThan(simd_distance(t.path.start, [0, g.launchLift, 0]), 1e-6)
            XCTAssertLessThan(simd_distance(t.path.tangent(atDistance: 0), [0, 1, 0]), 1e-3)
            // Straight out for the first centimetre.
            var s: Float = 0
            while s < g.riseStraight {
                let p = t.path.point(atDistance: s)
                XCTAssertLessThan(simd_length(SIMD2<Float>(p.x, p.z)), 1e-4)
                s += 0.001
            }
            // Where the bend has turned it up the card's axis, it is 2–3 cm off the screen.
            var turned: Float?
            s = 0
            while s < t.spiralStart {
                if simd_dot(t.path.tangent(atDistance: s), g.cardUp) > cos(Float(2) * .pi / 180) { turned = s; break }
                s += 0.0005
            }
            guard let turned else { return XCTFail("the launch never heads up the card (angle \(angle))") }
            let height = t.path.point(atDistance: turned).y
            XCTAssertGreaterThanOrEqual(height, 0.02, "angle \(angle)")
            XCTAssertLessThanOrEqual(height, 0.03, "angle \(angle)")
            // …and the head is still on the screen when the ribbon is launched.
            XCTAssertEqual(t.headDistance(at: t.beats.launch), 0, accuracy: 1e-5)
        }
    }

    /// A2's rule: no bend tighter than the ribbon's half width (5.5 mm at the desk's 11 mm), or the strip folds on itself.
    /// The hand's flight keeps ≥ 8 mm everywhere, at every hinge angle, and its tangent never jumps.
    func testTheHandFlightNeverFolds() {
        for angle in Self.angles {
            let t = hand(angle)
            let step: Float = 0.0001
            var s: Float = 0
            var last = t.path.tangent(atDistance: 0)
            var worstJump: Float = 0
            var tightest: Float = .greatestFiniteMagnitude
            while s < t.path.length - step {
                s += step
                let tangent = t.path.tangent(atDistance: s)
                let turn = acos(max(-1, min(1, simd_dot(tangent, last))))
                worstJump = max(worstJump, turn)
                if turn > 1e-5 { tightest = min(tightest, step / turn) }
                last = tangent
            }
            XCTAssertLessThan(worstJump * 180 / .pi, 1.2, "angle \(angle): a tangent jump")
            XCTAssertGreaterThan(tightest, 0.0055, "angle \(angle): tightest bend \(tightest * 1000) mm is tighter than the half width")
            XCTAssertGreaterThan(tightest, 0.008, "angle \(angle): tightest bend \(tightest * 1000) mm")
        }
    }

    /// H0: past the launch (which crosses the top of the device in its first ≈ 0.2 s, inside the recognition's audit
    /// pause), nothing the ribbon flies through is inside the device's prism — case + 3 mm, 20 mm under to 30 mm over
    /// its top face. The outline is the hinged card's: its bottom edge lies on the hinge, in the prism's 3 mm margin past
    /// the case's top edge (the overhang the audit grants the hinged card) and never over the case itself.
    func testAfterTheLaunchTheFlightStaysOutOfThePrism() {
        let half = SIMD2<Float>(0.030 + 0.003, 0.048 + 0.003)
        func inPrism(_ c: SIMD3<Float>) -> Bool { abs(c.x) < half.x && abs(c.z) < half.y && c.y > -0.020 && c.y < 0.030 }
        for angle in Self.angles {
            let t = hand(angle)
            var s = t.spiralStart
            while s < t.outlineStart {
                let c = t.path.point(atDistance: s) - Self.caseCenter
                XCTAssertFalse(inPrism(c), "angle \(angle): the flight is in the prism at \(s) m: \(c)")
                s += 0.002
            }
            while s <= t.path.length {
                let c = t.path.point(atDistance: s) - Self.caseCenter
                if inPrism(c) {
                    XCTAssertLessThanOrEqual(c.z, -0.048 + 1e-4, "angle \(angle): the outline is over the case at \(s) m: \(c)")
                    XCTAssertGreaterThanOrEqual(c.y, 0, "angle \(angle): the outline is under the top face at \(s) m")
                }
                s += 0.002
            }
        }
    }

    /// The desk flight's beats and clock: the head reaches the card at 1.20 s at the outline's own speed, closes at 1.90 s.
    func testTheHandFlightKeepsTheBeats() {
        for angle in Self.angles {
            let t = hand(angle)
            XCTAssertEqual(t.headDistance(at: 1.20), t.outlineStart, accuracy: 1e-3)
            XCTAssertEqual(t.headDistance(at: 1.90), t.path.length, accuracy: 1e-3)
            let before = t.timing.speed(at: 1.1999), after = t.timing.speed(at: 1.2001)
            XCTAssertEqual(before, after, accuracy: 0.03 * after)
            XCTAssertLessThan(t.timing.speed(at: 0.15), 0.4 * t.timing.speed(at: 1.15), "slow, then fast")
            let a = t.beats.launchSlope, b = t.spiralEndSlope
            XCTAssertLessThanOrEqual(a * a + b * b, 9, "the timing curve stays monotonic")
        }
    }

    /// The hand flight circles the card's up axis, climbing: three quarters of a turn, from in front of the card round to
    /// beside its right edge.
    func testTheSpiralCirclesTheCardsUpAxis() {
        let t = hand(0.3)
        let g = t.hand!
        var s = t.spiralStart
        var sweep: Float = 0
        var lastAngle: Float?
        var lastHeight: Float = -1
        while s <= t.transitionStart {
            let d = t.path.point(atDistance: s) - g.hinge
            let x = simd_dot(d, g.cardRight), n = simd_dot(d, g.cardNormal), h = simd_dot(d, g.cardUp)
            XCTAssertGreaterThanOrEqual(h, lastHeight - 1e-5, "it only climbs")
            lastHeight = h
            let angle = atan2(n, x)
            if let lastAngle {
                var a = angle - lastAngle
                a = atan2(sin(a), cos(a))
                sweep += a
            }
            lastAngle = angle
            s += 0.002
        }
        XCTAssertEqual(sweep, 1.5 * .pi, accuracy: 0.05)
    }

    /// The desk's flight is what it was: the same outline frame, place `desk`.
    func testTheDeskFlightIsUnchanged() {
        let desk = Timeline()
        XCTAssertEqual(desk.place, .desk)
        XCTAssertNil(desk.hand)
        XCTAssertEqual(desk.outline, desk.geometry.outline)
        XCTAssertLessThan(simd_distance(desk.closurePoint, desk.geometry.onCard(0.135, 0.135 - 0.03)), 1e-5)
    }
}
