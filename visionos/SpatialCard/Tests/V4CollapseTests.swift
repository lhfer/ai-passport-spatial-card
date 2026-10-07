import XCTest

/// **v4 B3 §2 — collapse and summon as a pair.** The wake hint's schedule, where it stands, and the device's cue rule
/// across a summon that replays the recognition: `connect` once a session, `tick` for every summon after it.
final class V4CollapseTests: XCTestCase {
    private typealias Collapse = V4.Collapse

    func testTheWakeHintIsForTheFirstThreeCollapsesOnly() {
        XCTAssertFalse(Collapse.showsWakeHint(collapse: 0))
        XCTAssertTrue(Collapse.showsWakeHint(collapse: 1))
        XCTAssertTrue(Collapse.showsWakeHint(collapse: 2))
        XCTAssertTrue(Collapse.showsWakeHint(collapse: 3))
        XCTAssertFalse(Collapse.showsWakeHint(collapse: 4))
        XCTAssertFalse(Collapse.showsWakeHint(collapse: 10))
        XCTAssertEqual(Collapse.wakeHintDelay, 1.5)
    }

    /// The hint waits until the card has become the point (anticipation + arc + the point's pop ≈ 0.82 s).
    func testTheWakeHintComesAfterThePointHasLanded() {
        let landed = Double(V4.PickupFold.anticipationDuration + V4.PickupFold.foldDuration) + 0.24
        XCTAssertGreaterThan(Collapse.wakeHintDelay, landed)
    }

    /// Beside the keys (the `+x` / `−x` side), clear of the case, at B2's first-gallery hint's 13 cm.
    func testTheWakeHintStandsOnTheKeysSideOutsideTheCase() {
        let prism = DeviceFootprint.aiPassport
        for sign: Float in [1, -1] {
            let p = Collapse.hintPosition(edgeSign: sign)
            XCTAssertEqual(p.x, sign * 0.13, accuracy: 1e-6)
            XCTAssertGreaterThan(abs(p.x) - 0.07, prism.half.x, "a 14 cm capsule centred 13 cm out starts outside the prism")
        }
    }

    /// The breath never goes dark and never flashes: a resting state (0.70–1.00 opacity, B2's searching rate).
    func testThePointBreathesBetweenSteadyLevels() {
        let breath = Collapse.breathOpacity
        XCTAssertGreaterThanOrEqual(breath.base - breath.amplitude, 0.6)
        XCTAssertLessThanOrEqual(breath.base + breath.amplitude, 1.0)
        XCTAssertEqual(Collapse.breathPeriod, V4.PickupFold.breathPeriod)
    }

    /// `connect` belongs to the session's first recognition, whichever path brought it; every summon's recognition after
    /// it — a first acquire again, because the gate's `revealedOnce` was reset — rings `tick`. The cue rule keeps its own
    /// memory (`revealed`), so resetting the gate's cannot bring the `connect` back.
    func testConnectRingsOnceAndEverySummonTicks() {
        var cues = DeviceCueRules()
        cues.scanDriven = true
        XCTAssertNil(cues.handle(presence: .expanded, transition: .cinematic))
        XCTAssertEqual(cues.scanConverged(), .connect)
        for _ in 0..<5 {
            XCTAssertNil(cues.handle(presence: .absent, transition: .hide))
            XCTAssertNil(cues.handle(presence: .acquiring, transition: nil))
            XCTAssertNil(cues.handle(presence: .expanded, transition: .cinematic))
            XCTAssertEqual(cues.scanConverged(), .tick)
        }
    }
}
