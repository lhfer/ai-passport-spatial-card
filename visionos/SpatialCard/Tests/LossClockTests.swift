import XCTest

/// **V3-6 §4.** `[timing] pick-up: loss → carrying` has to mean "the reach", and a passport the camera loses
/// while it is lying still has to be counted somewhere else.
///
/// The headset numbers these are written against (round 3, `spatialcard-20260922-230959.log`): two pick-ups
/// reported as `4.17 s` and `6.17 s`, each preceded by `expanded → held(untracked)` **8.4 s** / **1.0 s**
/// earlier with `tracked=49–59%` — a dark room, not a hand.
final class LossClockTests: XCTestCase {
    private let radius: Float = 0.15

    /// A wrist inside the radius is a grab, and the pick-up is timed from the loss.
    func testAGrabIsTimedFromTheLoss() {
        var clock = LossClock()
        clock.lost(handDistance: 0.08, radius: radius, carrying: false, at: 100)
        XCTAssertEqual(clock.kind, .grab)
        // The passport becomes visible again mid-pick-up: that does **not** close the clock, because
        // `held(untracked) → carrying` arrives after it.
        XCTAssertNil(clock.found(at: 100.6))
        XCTAssertEqual(clock.carried(at: 100.9) ?? -1, 0.9, accuracy: 1e-6)
        // …and the clock is spent: a second carry with no new loss prints nothing.
        XCTAssertNil(clock.carried(at: 101))
    }

    /// Every tracked wrist outside the radius is the desk, and it is reported on its own when the camera
    /// finds the passport again — never as a pick-up.
    func testADeskLossIsReportedOnItsOwnAndNeverBecomesAPickUp() {
        var clock = LossClock()
        clock.lost(handDistance: 0.40, radius: radius, carrying: false, at: 10)
        XCTAssertEqual(clock.kind, .desk)
        XCTAssertEqual(clock.found(at: 18.4) ?? -1, 8.4, accuracy: 1e-6)
        XCTAssertNil(clock.lostAt)
        XCTAssertNil(clock.carried(at: 19))
    }

    /// Round 3's actual shape: the passport is lost on a dark desk for 8.4 s, *then* a hand reaches it, and
    /// the pick-up takes 4.17 s from the reach. Two numbers, not one 12.57 s number.
    func testAReachSplitsADeskLossFromThePickUp() {
        var clock = LossClock()
        clock.lost(handDistance: 0.45, radius: radius, carrying: false, at: 0)
        XCTAssertNil(clock.reach(handDistance: 0.30, radius: radius, at: 4), "a hand still 30 cm away is not a reach")
        XCTAssertEqual(clock.reach(handDistance: 0.09, radius: radius, at: 8.4) ?? -1, 8.4, accuracy: 1e-6)
        XCTAssertEqual(clock.kind, .grab)
        XCTAssertEqual(clock.carried(at: 12.57) ?? -1, 4.17, accuracy: 1e-6)
    }

    /// A reach is reported once: the ticks after it are the same grab.
    func testAReachIsReportedOnce() {
        var clock = LossClock()
        clock.lost(handDistance: 0.45, radius: radius, carrying: false, at: 0)
        XCTAssertNotNil(clock.reach(handDistance: 0.05, radius: radius, at: 2))
        XCTAssertNil(clock.reach(handDistance: 0.05, radius: radius, at: 2.05))
        XCTAssertEqual(clock.carried(at: 3) ?? -1, 1, accuracy: 1e-6)
    }

    /// A grab that never had a desk half reports no desk loss when a later tick confirms the hand.
    func testAGrabThatWasAlreadyAGrabReportsNoDeskLoss() {
        var clock = LossClock()
        clock.lost(handDistance: 0.05, radius: radius, carrying: false, at: 0)
        XCTAssertNil(clock.reach(handDistance: 0.05, radius: radius, at: 0.2))
        XCTAssertEqual(clock.lostAt, 0, "the clock must not be restarted by a tick that changes nothing")
    }

    /// **The regression V3-6 §1's default makes visible.** Round 3: the passport is occluded by the hand that
    /// is putting it down, the card comes to rest on the desk, and the loss must not be left on the books for
    /// the next pick-up to print.
    func testAnOcclusionAtAPutDownLeavesNothingForTheNextPickUp() {
        var clock = LossClock()
        clock.lost(handDistance: 0.06, radius: radius, carrying: false, at: 50)
        XCTAssertEqual(clock.kind, .grab)
        clock.settled()
        XCTAssertNil(clock.lostAt)
        XCTAssertNil(clock.carried(at: 53), "a put-down occlusion is not a 3 s pick-up")
    }

    /// No hand data at all — `--no-hands`, the simulator, every `--fake-track` script without a `hand`
    /// segment — keeps V3-4's behaviour exactly: one clock, started at the loss, printed at the carry.
    func testNoHandDataKeepsTheV34Behaviour() {
        var clock = LossClock()
        clock.lost(handDistance: nil, radius: radius, carrying: false, at: 0)
        XCTAssertEqual(clock.kind, .unknown)
        XCTAssertNil(clock.found(at: 1), "an unclassifiable loss is not a desk loss and prints nothing")
        XCTAssertNil(clock.reach(handDistance: nil, radius: radius, at: 1.5))
        XCTAssertEqual(clock.carried(at: 2) ?? -1, 2, accuracy: 1e-6)
    }

    /// …and a hand that appears during an unclassifiable loss still restarts the clock at the reach, but has
    /// no desk half to report (nobody ever said the passport was alone).
    func testAHandArrivingDuringAnUnknownLossRestartsTheClockSilently() {
        var clock = LossClock()
        clock.lost(handDistance: nil, radius: radius, carrying: false, at: 0)
        XCTAssertNil(clock.reach(handDistance: 0.10, radius: radius, at: 3), "nothing to report: this was never a desk loss")
        XCTAssertEqual(clock.kind, .grab)
        XCTAssertEqual(clock.carried(at: 3.5) ?? -1, 0.5, accuracy: 1e-6)
    }

    /// Only the first untracked observation of a run starts the clock; ARKit sends 30 of them a second.
    func testOnlyTheFirstUntrackedObservationStartsTheClock() {
        var clock = LossClock()
        clock.lost(handDistance: 0.40, radius: radius, carrying: false, at: 7)
        for step in 1...30 { clock.lost(handDistance: 0.40, radius: radius, carrying: false, at: 7 + Double(step) / 30) }
        XCTAssertEqual(clock.lostAt, 7)
        XCTAssertEqual(clock.found(at: 9) ?? -1, 2, accuracy: 1e-6)
    }

    /// **Round 3's put-down, exactly.** `carrying(notFlat) → held(untracked) → carrying(notFlat)`: the thaw
    /// goes back to `carrying` because that is where it came from, and V3-4's rule printed
    /// `[timing] pick-up: loss → carrying 1.53 s` for a passport that was being **put down**.
    func testALossThatBeganInTheHandIsNeverAPickUp() {
        var clock = LossClock()
        clock.lost(handDistance: 0.03, radius: radius, carrying: true, at: 8)
        XCTAssertEqual(clock.kind, .inHand)
        XCTAssertNil(clock.reach(handDistance: 0.03, radius: radius, at: 9.4), "it cannot be upgraded into a grab")
        XCTAssertNil(clock.found(at: 9.5), "an occlusion in the hand is not a desk loss either")
        XCTAssertNil(clock.carried(at: 9.53))
        XCTAssertNil(clock.lostAt, "…and the clock is cleared, so the next pick-up starts from its own loss")
    }

    /// **The swallow this file exists to prevent.** The card is dismissed *during* an in-hand loss, so it
    /// never reaches `carrying` or `settling` — and `lost()` only starts a clock when none is running, so a
    /// clock left standing would make the next loss invisible. Reproduced in the simulator by putting the OK
    /// button on top of `fake-track-v36-putdown-occluded.json`: the desk loss four seconds later printed
    /// nothing at all.
    func testAnInHandLossIsClosedWhenThePassportComesBackSoTheNextLossIsNotSwallowed() {
        var clock = LossClock()
        clock.lost(handDistance: 0.03, radius: radius, carrying: true, at: 8)
        XCTAssertNil(clock.found(at: 9.5))
        XCTAssertNil(clock.lostAt, "the in-hand loss is closed, not left running")
        // …and the desk loss that follows is measured normally.
        clock.lost(handDistance: 0.40, radius: radius, carrying: false, at: 13)
        XCTAssertEqual(clock.kind, .desk)
        XCTAssertEqual(clock.found(at: 14.2) ?? -1, 1.2, accuracy: 1e-6)
    }

    /// The same hole on the other three kinds: `settled()` is what a dismiss / teardown calls.
    func testGoingAbsentClearsWhateverClockWasRunning() {
        for (distance, carrying) in [(Float(0.40), false), (Float(0.03), false), (Float(0.03), true)] {
            var clock = LossClock()
            clock.lost(handDistance: distance, radius: radius, carrying: carrying, at: 1)
            clock.settled()
            XCTAssertNil(clock.lostAt)
            clock.lost(handDistance: 0.40, radius: radius, carrying: false, at: 5)
            XCTAssertEqual(clock.lostAt, 5, "the next loss starts its own clock")
        }
    }

    /// A dropout while the card is already in the hand (`fake-track-hand.json`'s 0.4 s) is the same rule —
    /// V3-4 timed it as a pick-up, and nothing was picked up.
    func testADropoutInTheHandIsNotAPickUpEither() {
        var clock = LossClock()
        clock.lost(handDistance: nil, radius: radius, carrying: true, at: 6)
        XCTAssertEqual(clock.kind, .inHand)
        XCTAssertNil(clock.carried(at: 6.4))
    }

    /// The radius is the bridge's own `attachRadius`, and it is inclusive — a wrist exactly on the circle is
    /// holding the passport, which is the reading `HandBridge.holdingHand` uses.
    func testTheRadiusIsInclusive() {
        XCTAssertEqual(LossClock.classify(handDistance: 0.15, radius: 0.15), .grab)
        XCTAssertEqual(LossClock.classify(handDistance: 0.1501, radius: 0.15), .desk)
        XCTAssertEqual(LossClock.classify(handDistance: nil, radius: 0.15), .unknown)
        XCTAssertEqual(LossClock.classify(handDistance: .nan, radius: 0.15), .unknown)
    }
}
