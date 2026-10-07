import XCTest

/// v3 H2 §6: "turn the passport face down and the card folds away". The gesture is read from the object
/// tracker's own tilt, whose orientation error measured 14–28° on a device lying *flat*, so the dwell and the
/// hysteresis are the whole design — and both are pure timing, which is what this checks.
final class DeviceGesturesTests: XCTestCase {
    private let down: Float = 170 * .pi / 180
    private let up: Float = 5 * .pi / 180
    /// Inside the band between `rearmTilt` (120°) and `faceDownTilt` (150°): neither counting nor re-arming.
    private let band: Float = 135 * .pi / 180

    /// Held face down past the sustain: exactly one event, however long it stays there.
    func testSustainedFlipFiresOnce() {
        var gestures = DeviceGestures()
        XCTAssertNil(gestures.update(tilt: down, at: 10.0), "the dwell starts here")
        XCTAssertNil(gestures.update(tilt: down, at: 10.4))
        XCTAssertNil(gestures.update(tilt: down, at: 10.79), "0.79 s is not 0.8 s")
        XCTAssertEqual(gestures.update(tilt: down, at: 10.8), .faceDown)
        // Still face down 3 s later: the card is already away, and folding it again would be a flicker.
        for t in stride(from: 10.85, through: 13.8, by: 0.05) {
            XCTAssertNil(gestures.update(tilt: down, at: t))
        }
    }

    /// A quick flip on the way to somewhere else (0.3 s) is not the gesture. This is the one that matters on
    /// the headset: handing the passport to someone turns it over for a moment every time.
    func testBriefFlipDoesNotFire() {
        var gestures = DeviceGestures()
        XCTAssertNil(gestures.update(tilt: down, at: 20.0))
        XCTAssertNil(gestures.update(tilt: down, at: 20.3))
        XCTAssertNil(gestures.update(tilt: up, at: 20.35), "back up: the dwell is forgotten")
        // …and turning it over again starts the 0.8 s from scratch rather than resuming the old 0.3 s.
        XCTAssertNil(gestures.update(tilt: down, at: 20.4))
        XCTAssertNil(gestures.update(tilt: down, at: 21.0))
        XCTAssertEqual(gestures.update(tilt: down, at: 21.21), .faceDown)
    }

    /// After firing, the gesture re-arms only once the device is clearly the right way up again — and then it
    /// can fire a second time. (Turning it back up is deliberately *not* a "show": that is OK's job.)
    func testRearmsOnlyAfterComingBackUp() {
        var gestures = DeviceGestures()
        _ = gestures.update(tilt: down, at: 0)
        XCTAssertEqual(gestures.update(tilt: down, at: 0.8), .faceDown)

        // Wobbling inside the hysteresis band is neither a re-arm nor a new flip.
        XCTAssertNil(gestures.update(tilt: band, at: 1.0))
        XCTAssertNil(gestures.update(tilt: down, at: 1.1))
        XCTAssertNil(gestures.update(tilt: down, at: 3.0), "still the same flip, however long")

        // Clearly back up, then over again: a second fold.
        XCTAssertNil(gestures.update(tilt: 60 * .pi / 180, at: 3.5))
        XCTAssertNil(gestures.update(tilt: down, at: 4.0))
        XCTAssertNil(gestures.update(tilt: down, at: 4.7))
        XCTAssertEqual(gestures.update(tilt: down, at: 4.81), .faceDown)
    }

    /// The hand form sits around 60° and the desk around 0–28°: neither may ever start the dwell.
    func testOrdinaryPosesNeverArmTheGesture() {
        var gestures = DeviceGestures()
        for tilt: Float in [0, 15, 28, 45, 60, 90, 119] {
            XCTAssertNil(gestures.update(tilt: tilt * .pi / 180, at: Double(tilt)))
        }
        XCTAssertNil(gestures.downSince)
    }

    /// A tracking loss breaks the dwell: the device could have been turned in the dark, and a gesture that
    /// counted through a gap would fire on an observation from a different pose entirely.
    func testResetOnLossClearsTheDwell() {
        var gestures = DeviceGestures()
        XCTAssertNil(gestures.update(tilt: down, at: 5.0))
        gestures.reset()
        XCTAssertNil(gestures.update(tilt: down, at: 5.9), "the dwell restarts at 5.9, not at 5.0")
        XCTAssertNil(gestures.update(tilt: down, at: 6.65), "…so 0.75 s in it has not fired yet")
        XCTAssertEqual(gestures.update(tilt: down, at: 6.75), .faceDown)
    }

    /// A NaN tilt (a degenerate pose) must not arm, fire, or clear anything.
    func testNonFiniteTiltIsIgnored() {
        var gestures = DeviceGestures()
        XCTAssertNil(gestures.update(tilt: .nan, at: 1))
        XCTAssertNil(gestures.downSince)
        XCTAssertNil(gestures.update(tilt: down, at: 2))
        XCTAssertNil(gestures.update(tilt: .nan, at: 2.4))
        XCTAssertEqual(gestures.update(tilt: down, at: 2.85), .faceDown, "the NaN did not restart the dwell")
    }

    // MARK: - V3-2b B4: the anticipation (plan §4 E12)

    /// Past 120° the card starts gathering **immediately** — no dwell, because the whole point is that the
    /// preview arrives before the fold it predicts. Back under 110° it is cancelled; the 10° in between is
    /// hysteresis, so a passport wobbling on the threshold does not strobe the card.
    func testAnticipationEntersAtOneTwentyAndLeavesAtOneTen() {
        var gestures = DeviceGestures()
        func deg(_ d: Float) -> Float { d * .pi / 180 }
        XCTAssertNil(gestures.updateAnticipation(tilt: deg(119)), "the hand form sits well below this")
        XCTAssertFalse(gestures.anticipating)
        XCTAssertEqual(gestures.updateAnticipation(tilt: deg(121)), .anticipation(true), "no dwell at all")
        XCTAssertTrue(gestures.anticipating)
        // Already on: neither a further turn nor the hysteresis band says anything more.
        XCTAssertNil(gestures.updateAnticipation(tilt: deg(150)))
        XCTAssertNil(gestures.updateAnticipation(tilt: deg(170)))
        XCTAssertNil(gestures.updateAnticipation(tilt: deg(115)), "inside the band: still gathered")
        XCTAssertEqual(gestures.updateAnticipation(tilt: deg(109)), .anticipation(false))
        XCTAssertFalse(gestures.anticipating)
        XCTAssertNil(gestures.updateAnticipation(tilt: deg(0)))
        // …and it can happen again.
        XCTAssertEqual(gestures.updateAnticipation(tilt: deg(130)), .anticipation(true))
    }

    /// The anticipation and the fold are one gesture read twice: the flip that becomes a fold keeps the card
    /// gathered through it, and a tracking loss in the middle of a flip puts the card back — nothing else
    /// would. A NaN changes nothing either way.
    func testAnticipationSurvivesTheFoldAndIsUndoneByALoss() {
        var gestures = DeviceGestures()
        XCTAssertEqual(gestures.updateAnticipation(tilt: down), .anticipation(true))
        XCTAssertNil(gestures.update(tilt: down, at: 0), "the fold's own dwell starts here")
        XCTAssertNil(gestures.updateAnticipation(tilt: down))
        XCTAssertEqual(gestures.update(tilt: down, at: 0.8), .faceDown)
        XCTAssertTrue(gestures.anticipating, "the card stays gathered: it is about to fold")

        XCTAssertEqual(gestures.reset(), .anticipation(false), "a loss mid-flip must restore the card")
        XCTAssertFalse(gestures.anticipating)
        XCTAssertNil(gestures.reset(), "…and only once")

        XCTAssertNil(gestures.updateAnticipation(tilt: .nan))
        XCTAssertFalse(gestures.anticipating)
    }
}
