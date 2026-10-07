import XCTest

/// 工作包 A 设备联动: the three moments the device rings along with the card, decided from the gate's event
/// stream alone (`DeviceCueRules`). The sending — and the "remember the connect ring until the link is up" rule —
/// lives in `DeviceCoordinator`, which needs BLE and is checked in the simulator smoke instead.
final class DeviceCueRulesTests: XCTestCase {
    private var rules = DeviceCueRules()

    override func setUp() {
        super.setUp()
        rules = DeviceCueRules()
    }

    // MARK: - V3-2a2 S1: the scan's convergence beat owns the `connect`

    /// With `--box-scan on` the wireframe is what the device answers, not the card — the beat where the
    /// outline becomes the socket light. It is still once per session, and it still comes before anything
    /// the first `expanded` could say.
    func testTheScansConvergenceRingsConnectOnceASession() {
        rules.scanDriven = true
        XCTAssertNil(rules.handle(presence: .acquiring, transition: nil))
        // The gate reaches `expanded` while the card is still a wireframe: silent, on purpose.
        XCTAssertNil(rules.handle(presence: .expanded, transition: .cinematic))
        XCTAssertEqual(rules.scanConverged(), .connect)
        // A replay's second cinematic is not a second connection either.
        XCTAssertNil(rules.handle(presence: .absent, transition: .hide))
        XCTAssertNil(rules.handle(presence: .expanded, transition: .cinematic))
    }

    /// Every later scan is a summon, and a summon is a confirmation rather than a connection.
    func testASummonsScanRingsTickNotConnect() {
        rules.scanDriven = true
        XCTAssertNil(rules.handle(presence: .expanded, transition: .cinematic))
        XCTAssertEqual(rules.scanConverged(), .connect)
        // Folded away, then summoned back: the scan runs again and the device ticks.
        XCTAssertNil(rules.handle(presence: .absent, transition: .hide))
        XCTAssertEqual(rules.scanConverged(), .tick)
        XCTAssertEqual(rules.scanConverged(), .tick)
        // …and the put-back-down `tick` still works afterwards.
        XCTAssertNil(rules.handle(presence: .carrying(.moving), transition: .carry))
        XCTAssertNil(rules.handle(presence: .settling, transition: .settle))
        XCTAssertEqual(rules.handle(presence: .expanded, transition: nil), .tick)
    }

    /// The card standing up for the first time is the one `connect` of the session.
    func testFirstExpandedRingsConnectOnce() {
        XCTAssertNil(rules.handle(presence: .acquiring, transition: nil))
        XCTAssertEqual(rules.handle(presence: .expanded, transition: .cinematic), .connect)

        // Freezing and thawing is not a second connection.
        XCTAssertNil(rules.handle(presence: .held(.untracked), transition: .freeze))
        XCTAssertNil(rules.handle(presence: .expanded, transition: .thaw(glide: 0)))
    }

    /// Pick the card up and put it down: the landing rings a `tick`, and only the landing.
    func testPutBackDownRingsTick() {
        XCTAssertEqual(rules.handle(presence: .expanded, transition: .cinematic), .connect)
        XCTAssertNil(rules.handle(presence: .carrying(.moving), transition: .carry))
        XCTAssertNil(rules.handle(presence: .settling, transition: .settle))
        XCTAssertEqual(rules.handle(presence: .expanded, transition: nil), .tick)

        // Settling that did not come from a carry (a hold released mid-settle) rings nothing.
        XCTAssertNil(rules.handle(presence: .settling, transition: .settle))
        XCTAssertNil(rules.handle(presence: .expanded, transition: nil))
    }

    /// A relocation's confirmation belongs to the landing: the thaw only arms it, and it fires once.
    func testRelocationTickWaitsForTheLanding() {
        XCTAssertEqual(rules.handle(presence: .expanded, transition: .cinematic), .connect)
        XCTAssertNil(rules.handle(presence: .held(.untracked), transition: .freeze))
        XCTAssertNil(rules.handle(presence: .expanded, transition: .thaw(glide: 0.30)))
        XCTAssertTrue(rules.awaitingLanding)
        XCTAssertEqual(rules.landed(), .tick)
        XCTAssertNil(rules.landed(), "one landing, one tick")
    }

    /// A thaw that only corrects tracking noise is not a relocation and rings nothing.
    func testSmallThawDoesNotArmALanding() {
        XCTAssertEqual(rules.handle(presence: .expanded, transition: .cinematic), .connect)
        XCTAssertNil(rules.handle(presence: .held(.stale), transition: .freeze))
        XCTAssertNil(rules.handle(presence: .expanded, transition: .thaw(glide: 0.005)))
        XCTAssertFalse(rules.awaitingLanding)
        XCTAssertNil(rules.landed())
    }

    /// The card is folded away mid-glide: the confirmation is cancelled with everything else, and a replay's
    /// second cinematic is still not a second `connect`.
    func testHideCancelsThePendingLanding() {
        XCTAssertEqual(rules.handle(presence: .expanded, transition: .cinematic), .connect)
        XCTAssertNil(rules.handle(presence: .held(.untracked), transition: .freeze))
        XCTAssertNil(rules.handle(presence: .expanded, transition: .thaw(glide: 0.30)))
        XCTAssertNil(rules.handle(presence: .absent, transition: .hide))
        XCTAssertFalse(rules.awaitingLanding)
        XCTAssertNil(rules.landed())
        XCTAssertNil(rules.handle(presence: .expanded, transition: .cinematic))
    }
}
