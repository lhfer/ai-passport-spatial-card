import XCTest
import simd

/// **v4 B2 §3.3 — the pick-up fold.** A loss that is a grab (a hand within 15 cm — `LossClock`) and has lasted more
/// than 0.5 s folds the card into the device's last position; the desk loss keeps V3-6's wait-and-dim. The thaw grows
/// it out of the point onto the hinge if the passport is in the hand, or lets it rise on the desk. These check the
/// rule, the unfold decision, the motion numbers against the art bible, and that the point clears the H0 prism.
final class V4PickupFoldTests: XCTestCase {
    private typealias Fold = V4.PickupFold

    func testAGrabLossFoldsAfterHalfASecond() {
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: true, grab: true, lossSeconds: 0.5, cardOnDesk: true))
        XCTAssertTrue(Fold.shouldFold(enabled: true, lossHold: true, grab: true, lossSeconds: 0.51, cardOnDesk: true))
    }

    /// The user's rule: the card follows the device, not the hand — and a loss with no hand near it is the desk case.
    func testOnlyAGrabFolds() {
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: true, grab: false, lossSeconds: 5, cardOnDesk: true),
                       "a desk loss waits where it was, dimmed")
        XCTAssertFalse(Fold.shouldFold(enabled: false, lossHold: true, grab: true, lossSeconds: 5, cardOnDesk: true),
                       "--pickup-fold off")
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: false, grab: true, lossSeconds: 5, cardOnDesk: true),
                       "a button / theme / world hold is not a loss")
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: true, grab: true, lossSeconds: 5, cardOnDesk: false),
                       "only a card standing on the desk (not in the hand, not a mini card, not already folded)")
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: true, grab: true, lossSeconds: nil, cardOnDesk: true),
                       "no loss clock running")
    }

    /// The grab is judged per hold (`GrabWatch`): `LossClock`'s rule — a tracked wrist within the attach radius, at the
    /// loss or reaching it later — on a clock that the hold's end resets.
    func testTheGrabIsJudgedPerHold() {
        var watch = Fold.GrabWatch()
        let radius: Float = 0.15
        watch.step(lossHold: true, handDistance: 0.40, radius: radius, at: 10)
        XCTAssertNil(watch.grabSeconds(at: 10.6), "a hand 40 cm away: the desk case")
        watch.step(lossHold: true, handDistance: 0.08, radius: radius, at: 11)
        XCTAssertEqual(watch.grabSeconds(at: 11.6) ?? -1, 0.6, accuracy: 1e-9, "a reach during the loss starts it")
        watch.step(lossHold: true, handDistance: 0.35, radius: radius, at: 12)
        XCTAssertEqual(watch.grabSeconds(at: 12) ?? -1, 1.0, accuracy: 1e-9,
                       "the hand carrying the passport away from where it lay keeps it")
        XCTAssertEqual(watch.holdSince, 10)
    }

    /// The simulator bug this exists for: `LossClock` keeps a grab running through a thaw back to the desk, so a hand
    /// that closed over the passport and left (or a fold that unfolded back onto the desk) folded the card again at the
    /// next loss of any kind — `lost 14.8 s, hand -`. A hold that ends forgets its grab.
    func testAHoldThatEndsForgetsItsGrab() {
        var watch = Fold.GrabWatch()
        watch.step(lossHold: true, handDistance: 0.05, radius: 0.15, at: 10)
        XCTAssertNotNil(watch.grabSeconds(at: 10.3))
        watch.step(lossHold: false, handDistance: 0.40, radius: 0.15, at: 13)       // found again, on the desk
        XCTAssertNil(watch.grabSeconds(at: 13))
        XCTAssertNil(watch.holdSince)
        watch.step(lossHold: true, handDistance: nil, radius: 0.15, at: 25)         // a later loss, no hand anywhere
        let seconds = watch.grabSeconds(at: 40)
        XCTAssertNil(seconds, "nothing reached for it in this hold")
        XCTAssertFalse(Fold.shouldFold(enabled: true, lossHold: true, grab: seconds != nil, lossSeconds: seconds,
                                       cardOnDesk: true), "the desk case: wait where it was, dimmed")
        watch.step(lossHold: true, handDistance: 0.10, radius: 0.15, at: 41)         // …until a hand does reach
        XCTAssertEqual(watch.grabSeconds(at: 41.6) ?? -1, 0.6, accuracy: 1e-9, "and that grab is this hold's own")
    }

    func testNoHandDataIsNeverAGrab() {
        var watch = Fold.GrabWatch()
        watch.step(lossHold: true, handDistance: nil, radius: 0.15, at: 0)
        XCTAssertNil(watch.grabSeconds(at: 5), "--no-hands, a script without a hand segment: V3-6's wait-and-dim")
        XCTAssertEqual(watch.holdSince, 0)
    }

    func testTheThawGrowsTheCardIntoTheHandOrLetsItRiseOnTheDesk() {
        XCTAssertEqual(Fold.unfold(carrying: true, resting: false, lost: false, sinceThaw: 0), .hand)
        XCTAssertEqual(Fold.unfold(carrying: false, resting: true, lost: false, sinceThaw: 0.1), .wait,
                       "a tilted re-detection becomes a carry on the next observation — wait for it")
        XCTAssertEqual(Fold.unfold(carrying: false, resting: true, lost: false, sinceThaw: Fold.carryGrace), .desk)
        XCTAssertEqual(Fold.unfold(carrying: false, resting: false, lost: true, sinceThaw: 1), .stay, "lost again")
        XCTAssertLessThan(Fold.carryGrace, 0.5, "the desk rise must not feel like a second loss")
    }

    /// Art bible §3: a medium move is 0.35–0.60 s, an anticipation 60–120 ms of 3–6 %, and anything that travels more
    /// than 5 cm arcs, lifted 10–25 % of the distance.
    func testTheMotionIsInsideTheBible() {
        let total = Fold.anticipationDuration + Fold.foldDuration
        XCTAssertGreaterThanOrEqual(Fold.foldDuration, 0.35)
        XCTAssertLessThanOrEqual(total, 0.60)
        XCTAssertGreaterThanOrEqual(Fold.anticipationDuration, 0.06)
        XCTAssertLessThanOrEqual(Fold.anticipationDuration, 0.12)
        XCTAssertGreaterThanOrEqual(Fold.anticipationScale, 1.03)
        XCTAssertLessThanOrEqual(Fold.anticipationScale, 1.06)
        XCTAssertGreaterThanOrEqual(Fold.arcLiftFraction, 0.10)
        XCTAssertLessThanOrEqual(Fold.arcLiftFraction, 0.25)
        // The card's centre (0.22 m up) down to a point 0.18 m below it: a 3.2–3.3 cm arc.
        let arc = Fold.arcOffset(from: [0, 0.22, 0], to: [0, 0.04, 0])
        XCTAssertEqual(arc.y, 0.18 * Fold.arcLiftFraction, accuracy: 1e-5)
        XCTAssertEqual(arc.x, 0)
    }

    /// **v4 B3 §2.** H0: the gold point waits **outside** the footprint prism (the case + 3 mm), past the case's top edge,
    /// by geometry — nothing for the audit to exempt — with its bright core clear of the prism too.
    func testThePointClearsTheFootprintPrism() {
        let prism = DeviceFootprint.aiPassport
        let p = Fold.pointPosition(caseLength: prism.size.y)
        XCTAssertEqual(p.x, 0)
        XCTAssertEqual(p.z, -0.066, accuracy: 1e-6, "(0, +12, −66) mm on the 96 mm case")
        XCTAssertEqual(p.y, 0.012, accuracy: 1e-6)
        XCTAssertLessThan(p.z + Fold.pointCore, -prism.half.y, "the bright core is past the prism's top edge")
        XCTAssertTrue((prism.yMin...prism.yMax).contains(p.y), "it sits beside the case, not floating over it")
    }

    /// **v4 B3 §2.** Round 2's reason for moving it: in the hand the screen faces the eyes, and a point straight over the
    /// LCD sat between the two. Beside the top edge it is clear of the LCD's whole lit area in Z (12 mm below that edge).
    func testThePointIsNotInFrontOfTheScreen() {
        let prism = DeviceFootprint.aiPassport
        let p = Fold.pointPosition(caseLength: prism.size.y)
        let glow = Fold.pointSize / 2
        let lcdTopEdge = -prism.size.y / 2 + 0.012          // the lit area starts 12 mm in from the lanyard end
        XCTAssertLessThan(p.z + glow, lcdTopEdge, "not even the soft glow reaches over the lit area")
    }

    func testTheFoldLineSaysWhy() {
        XCTAssertEqual(Fold.foldLine(handDistance: 0.05, lossSeconds: 0.6),
                       "[reveal] pick-up fold: the card goes into the device's last position (grab, hand 5 cm, lost 0.6 s)")
        XCTAssertTrue(Fold.foldLine(handDistance: nil, lossSeconds: 0.6).contains("hand -"))
    }
}
