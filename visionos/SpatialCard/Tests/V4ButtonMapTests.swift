import XCTest

/// **v4 B3 §1 — one table for the three keys.** One test per row of `V4.ButtonMap`'s table, so the report's key map and
/// these assertions are the same object: no press is unanswered (every ignore has a reason) and no single press takes the
/// card away (only long OK collapses it).
final class V4ButtonMapTests: XCTestCase {
    private typealias Map = V4.ButtonMap

    private func act(_ key: Map.Key, _ context: Map.Context) -> Map.Action {
        Map.action(key, in: context)
    }

    // MARK: Worlds (round 2 run A: sixteen presses inside neon-city, none answered)

    func testInsideAWorldOKAndLongOKBothGoBackToTheDesk() {
        XCTAssertEqual(act(.ok, .world(inside: true)), .exitWorld)
        XCTAssertEqual(act(.longOK, .world(inside: true)), .exitWorld)
    }

    func testUpDownDoNothingInsideAWorldAndSaySo() {
        XCTAssertEqual(act(.up, .world(inside: true)), .ignore(.worldKeys))
        XCTAssertEqual(act(.down, .world(inside: true)), .ignore(.worldKeys))
    }

    func testDuringAWorldsEntryOrExitEveryKeyIsIgnoredWithAReason() {
        for key in Map.Key.allCases {
            guard case .ignore(let reason) = act(key, .world(inside: false)) else {
                return XCTFail("\(key) during a transition must be ignored")
            }
            XCTAssertTrue(reason == .worldTransition || reason == .worldKeys)
        }
        XCTAssertEqual(act(.ok, .world(inside: false)), .ignore(.worldTransition))
        XCTAssertEqual(act(.longOK, .world(inside: false)), .ignore(.worldTransition))
    }

    // MARK: Preview

    func testAnOpenPreviewPagesOnUpDownAndClosesOnOKOrLongOK() {
        XCTAssertEqual(act(.down, .preview), .pagePreview(1))
        XCTAssertEqual(act(.up, .preview), .pagePreview(-1))
        XCTAssertEqual(act(.ok, .preview), .closePreview)
        XCTAssertEqual(act(.longOK, .preview), .closePreview)
    }

    // MARK: Desk (round 2 run A: OK with nothing highlighted folded the card, twice)

    func testOnTheDeskOKWithAHighlightOpensIt() {
        XCTAssertEqual(act(.ok, .desk(highlight: true, held: false)), .deskOpen)
    }

    func testOnTheDeskOKWithNoHighlightIsDownNotACollapse() {
        XCTAssertEqual(act(.ok, .desk(highlight: false, held: false)), .deskStep(1))
        XCTAssertEqual(act(.ok, .desk(highlight: false, held: false)), act(.down, .desk(highlight: false, held: false)))
    }

    func testALostCardOnTheDeskTakesOKAsDownToo() {
        // Run A line 1086: the second accidental fold happened in `held(stale)`.
        XCTAssertEqual(act(.ok, .desk(highlight: false, held: true)), .deskStep(1))
        XCTAssertEqual(act(.ok, .desk(highlight: true, held: true)), .deskOpen)
    }

    func testUpDownWalkTheDeskRing() {
        XCTAssertEqual(act(.down, .desk(highlight: false, held: false)), .deskStep(1))
        XCTAssertEqual(act(.up, .desk(highlight: true, held: false)), .deskStep(-1))
    }

    func testLongOKCollapsesFromTheDesk() {
        for highlight in [false, true] {
            for held in [false, true] {
                XCTAssertEqual(act(.longOK, .desk(highlight: highlight, held: held)), .collapse)
            }
        }
    }

    // MARK: Hand

    func testInTheHandOKAtTheProfileRaisesSlotZeroLikeDown() {
        XCTAssertEqual(act(.ok, .hand(raised: false)), .handStep(1))
        XCTAssertEqual(act(.ok, .hand(raised: false)), act(.down, .hand(raised: false)))
    }

    func testInTheHandOKOnARaisedCardOpensIt() {
        XCTAssertEqual(act(.ok, .hand(raised: true)), .handOpen)
    }

    func testInTheHandUpDownRaiseAndLongOKCollapses() {
        XCTAssertEqual(act(.up, .hand(raised: true)), .handStep(-1))
        XCTAssertEqual(act(.down, .hand(raised: false)), .handStep(1))
        XCTAssertEqual(act(.longOK, .hand(raised: true)), .collapse)
        XCTAssertEqual(act(.longOK, .hand(raised: false)), .collapse)
    }

    // MARK: Collapsed, arriving, pick-up fold, nothing

    func testCollapsedOKSummonsAndNothingElseDoesAnything() {
        XCTAssertEqual(act(.ok, .collapsed), .summon)
        XCTAssertEqual(act(.longOK, .collapsed), .ignore(.alreadyCollapsed))
        XCTAssertEqual(act(.up, .collapsed), .ignore(.collapsed))
        XCTAssertEqual(act(.down, .collapsed), .ignore(.collapsed))
    }

    func testWhileTheCardIsArrivingKeysWaitForTheClosure() {
        // A second OK during a summon's ribbon must not highlight an invisible coin (and a third enter its world).
        for key in Map.Key.allCases { XCTAssertEqual(act(key, .arriving), .ignore(.arriving)) }
    }

    func testAPickUpFoldOnlyTakesLongOK() {
        XCTAssertEqual(act(.longOK, .pickupFolded), .collapse)
        for key in [Map.Key.up, .down, .ok] { XCTAssertEqual(act(key, .pickupFolded), .ignore(.pickupFolded)) }
    }

    func testBeforeAnythingIsSeenEveryKeyIsIgnored() {
        // v3 walked an invisible coin with UP / DOWN here, and the next OK entered its world from nothing.
        for key in Map.Key.allCases { XCTAssertEqual(act(key, .nothing), .ignore(.nothingSeen)) }
    }

    // MARK: The two invariants

    func testOnlyLongOKEverCollapsesTheCard() {
        let contexts: [Map.Context] = [.world(inside: true), .world(inside: false), .preview, .collapsed, .arriving,
                                       .pickupFolded, .desk(highlight: true, held: false), .desk(highlight: false, held: true),
                                       .hand(raised: true), .hand(raised: false), .nothing]
        for context in contexts {
            for key in Map.Key.allCases where key != .longOK {
                XCTAssertNotEqual(act(key, context), .collapse, "\(key) in \(context.label)")
            }
        }
    }

    func testEveryIgnoreCarriesAReasonAndTheLogLineSaysIt() {
        let line = Map.line(.ok, .world(inside: false), act(.ok, .world(inside: false)))
        XCTAssertTrue(line.hasPrefix("[keys] ok · world (entering / exiting) → ignored ("), line)
        let down = Map.line(.ok, .desk(highlight: false, held: true), act(.ok, .desk(highlight: false, held: true)))
        XCTAssertEqual(down, "[keys] ok · desk (lost, held), no highlight → ring +1 (= DOWN)")
        let hand = Map.line(.ok, .hand(raised: false), act(.ok, .hand(raised: false)))
        XCTAssertEqual(hand, "[keys] ok · hand, profile → deck +1 (= DOWN)")
    }

    func testUpIsMinusOneAndDownPlusOne() {
        XCTAssertEqual(Map.Key.up.step, -1)
        XCTAssertEqual(Map.Key.down.step, 1)
        XCTAssertNil(Map.Key.ok.step)
        XCTAssertNil(Map.Key.longOK.step)
    }
}
