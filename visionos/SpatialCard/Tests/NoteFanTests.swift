import XCTest

/// The rules that decide when the ten note covers are out (工作包 D 笔记扇出). Everything that can hide the
/// card — picking it up, folding it away, walking into a world — has to take the fan with it, and only the
/// wearer's own long press may stop it from coming back.
final class NoteFanTests: XCTestCase {
    private let ten = (0..<10).map { "id\($0)" }

    /// A machine that already has a list and a card sitting on the desk, with the fan out.
    private func fanned() -> NoteFanMachine {
        var m = NoteFanMachine()
        m.handle(.notesChanged(ids: ten))
        m.handle(.settled)
        XCTAssertEqual(m.state, .fanned)
        return m
    }

    // (a) notes that arrive before the card has settled wait for it
    func testNotesBeforeSettleWaitForTheCard() {
        var m = NoteFanMachine()
        XCTAssertEqual(m.handle(.notesChanged(ids: ten)), .none)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertEqual(m.handle(.settled), .fanOut)
        XCTAssertEqual(m.state, .fanned)
    }

    // (b) …and the usual way round: the hub's list lands while the card is already idle
    func testNotesAfterSettleFanOutAtOnce() {
        var m = NoteFanMachine()
        XCTAssertEqual(m.handle(.settled), .none, "nothing to fan yet")
        XCTAssertEqual(m.handle(.notesChanged(ids: ten)), .fanOut)
        XCTAssertEqual(m.state, .fanned)
    }

    // (c) a second settle (every startIdle is one) does not throw the fan twice
    func testSettleIsIdempotent() {
        var m = fanned()
        XCTAssertEqual(m.handle(.settled), .none)
        XCTAssertEqual(m.state, .fanned)
    }

    // (d) picking the device up takes the fan back — and putting it down brings it straight out again
    func testCarryCollapsesAndSettleRestores() {
        var m = fanned()
        XCTAssertEqual(m.handle(.carried), .collapse)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertFalse(m.suppressed, "a carry is not the wearer saying no")
        XCTAssertEqual(m.handle(.settled), .fanOut)
    }

    // (e) a carry during a preview ends the preview too (one collapse, not two events)
    func testCarryDuringPreviewCollapses() {
        var m = fanned()
        XCTAssertEqual(m.handle(.tapped("id3")), .preview("id3"))
        XCTAssertEqual(m.handle(.carried), .collapse)
        XCTAssertEqual(m.state, .collapsed)
    }

    // (f) folding the card away sinks the fan with it (no choreography of its own)
    func testHideSinksTheFan() {
        var m = fanned()
        XCTAssertEqual(m.handle(.hidden), .sink)
        XCTAssertEqual(m.state, .collapsed)
    }

    // (g) worlds: collapse on the way in, fan again on the way back
    func testWorldRoundTrip() {
        var m = fanned()
        XCTAssertEqual(m.handle(.worldEntered), .collapse)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertEqual(m.handle(.returnedFromWorld), .fanOut)
        XCTAssertEqual(m.state, .fanned)
    }

    // (h) long OK cycles fan → collapsed → fan, and a hand-collapsed fan stays away by itself
    func testLongOKToggles() {
        var m = fanned()
        XCTAssertEqual(m.handle(.longOK), .collapse)
        XCTAssertTrue(m.suppressed)
        XCTAssertEqual(m.handle(.settled), .none, "suppressed: no automatic fan-out")
        XCTAssertEqual(m.handle(.returnedFromWorld), .none)
        XCTAssertEqual(m.handle(.longOK), .fanOut, "asking for it lifts the suppression")
        XCTAssertFalse(m.suppressed)
    }

    // (i) long OK inside a preview is "back to the arc", not "away with the fan"
    func testLongOKEndsPreviewFirst() {
        var m = fanned()
        m.handle(.tapped("id2"))
        XCTAssertEqual(m.handle(.longOK), .endPreview)
        XCTAssertEqual(m.state, .fanned)
        XCTAssertFalse(m.suppressed)
        XCTAssertEqual(m.handle(.longOK), .collapse)
    }

    // (j) tapping: into a preview, across to another card, and out again on the same card
    func testTapEntersSwitchesAndLeavesThePreview() {
        var m = fanned()
        XCTAssertEqual(m.handle(.tapped("id1")), .preview("id1"))
        XCTAssertEqual(m.state.previewID, "id1")
        XCTAssertEqual(m.handle(.tapped("id7")), .switchPreview(from: "id1", to: "id7"))
        XCTAssertEqual(m.state.previewID, "id7")
        XCTAssertEqual(m.handle(.tapped("id7")), .endPreview)
        XCTAssertEqual(m.state, .fanned)
    }

    // (k) a tap on a card that is not in the list (a stale attachment) changes nothing
    func testTapOnUnknownNoteIsIgnored() {
        var m = fanned()
        XCTAssertEqual(m.handle(.tapped("gone")), .none)
        XCTAssertEqual(m.state, .fanned)
        m.handle(.tapped("id0"))
        XCTAssertEqual(m.handle(.tapped("gone")), .none)
        XCTAssertEqual(m.state.previewID, "id0")
    }

    // (l) collapsed cards are inert: a tap cannot open a preview out of nothing
    func testTapWhileCollapsedIsIgnored() {
        var m = NoteFanMachine()
        m.handle(.notesChanged(ids: ten))
        XCTAssertEqual(m.handle(.tapped("id0")), .none)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertFalse(m.state.isInteractive)
    }

    // (m) a new rev while the fan is out is a re-layout, and only that
    func testNewRevWhileFannedRelayouts() {
        var m = fanned()
        var next = ten
        next[0] = "new0"
        XCTAssertEqual(m.handle(.notesChanged(ids: next)), .relayout)
        XCTAssertEqual(m.state, .fanned)
    }

    // (n) …unless it takes the previewed note away, in which case the preview ends
    func testNewRevWithoutThePreviewedNoteEndsThePreview() {
        var m = fanned()
        m.handle(.tapped("id4"))
        let next = ten.filter { $0 != "id4" }
        XCTAssertEqual(m.handle(.notesChanged(ids: next)), .endPreview)
        XCTAssertEqual(m.state, .fanned)
        // A note that is still there survives the same event.
        m.handle(.tapped("id5"))
        XCTAssertEqual(m.handle(.notesChanged(ids: next)), .relayout)
        XCTAssertEqual(m.state.previewID, "id5")
    }

    // (o) an empty list takes the fan back instead of leaving ten ghosts on the arc
    func testEmptyListCollapses() {
        var m = fanned()
        XCTAssertEqual(m.handle(.notesChanged(ids: [])), .collapse)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertEqual(m.handle(.settled), .none)
    }

    // (p) the space closing resets everything, suppression included
    func testSpaceDismissResets() {
        var m = fanned()
        m.handle(.longOK)
        XCTAssertTrue(m.suppressed)
        XCTAssertEqual(m.handle(.spaceDismissed), .none)
        XCTAssertFalse(m.suppressed)
        XCTAssertFalse(m.deskReady)
        XCTAssertEqual(m.state, .collapsed)
        XCTAssertEqual(m.handle(.settled), .fanOut, "a fresh space fans again")
    }
    // MARK: - V3-2a H3: the hand deck

    private func deckMachine(ids: [String] = ["a", "b", "c"]) -> NoteFanMachine {
        var m = NoteFanMachine()
        m.deckEnabled = true
        m.handle(.notesChanged(ids: ids))
        m.handle(.settled)
        return m
    }

    /// (m) With the deck on, a carry does not fold the gallery away — it becomes the deck; a settle hands it
    /// back to the gallery **without** an outcome, because the controller's put-down bloom owns that flight.
    func testCarryEntersTheDeckAndSettleLeavesItWithoutAnOutcome() {
        var m = deckMachine()
        XCTAssertEqual(m.state, .fanned)
        XCTAssertEqual(m.handle(.carried), .morphToDeck)
        XCTAssertEqual(m.state, .deck(raised: nil))
        XCTAssertFalse(m.state.isInteractive, "a deck card is driven by the buttons, never by a pinch")
        // A second carry while it is already in the hand is not a second morph.
        XCTAssertEqual(m.handle(.carried), NoteFanMachine.Outcome.none)
        XCTAssertEqual(m.handle(.settled), NoteFanMachine.Outcome.none)
        XCTAssertEqual(m.state, .fanned)
    }

    /// (n) `--deck off` (or the image tracker, which has no hand form): a carry is V3-1's collapse again.
    func testWithoutTheDeckACarryStillCollapses() {
        var m = NoteFanMachine()
        m.handle(.notesChanged(ids: ["a", "b"]))
        m.handle(.settled)
        XCTAssertEqual(m.handle(.carried), .collapse)
        XCTAssertEqual(m.state, .collapsed)
    }

    /// (o) UP / DOWN raise a card; a new list re-slots the deck where it stands, and a raised card that has
    /// gone is simply no longer raised.
    func testRaiseAndRelayoutInTheDeck() {
        var m = deckMachine()
        m.handle(.carried)
        XCTAssertEqual(m.handle(.raiseDeck("b")), NoteFanMachine.Outcome.none)
        XCTAssertEqual(m.state, .deck(raised: "b"))
        XCTAssertEqual(m.handle(.notesChanged(ids: ["a", "b", "c", "d"])), .relayoutDeck)
        XCTAssertEqual(m.state, .deck(raised: "b"), "a card that is still there stays raised")
        XCTAssertEqual(m.handle(.notesChanged(ids: ["a", "c"])), .relayoutDeck)
        XCTAssertEqual(m.state, .deck(raised: nil), "…and one that has gone is not")
    }

    /// (p) H6: OK on a raised note opens it, and OK again puts it back on the **raised** slot — not into the
    /// card, which is where V3-1's hand-card preview went.
    func testAPreviewOpenedFromTheDeckGoesBackToItsRaisedSlot() {
        var m = deckMachine()
        m.handle(.carried)
        m.handle(.raiseDeck("b"))
        XCTAssertEqual(m.handle(.previewDirect("b")), .preview("b"))
        XCTAssertEqual(m.state, .preview("b"))
        XCTAssertEqual(m.handle(.previewDirect("b")), .endPreview)
        XCTAssertEqual(m.state, .deck(raised: "b"))
        // Long OK closes it the same way.
        m.handle(.previewDirect("b"))
        XCTAssertEqual(m.handle(.longOK), .endPreview)
        XCTAssertEqual(m.state, .deck(raised: "b"))
        // …and long OK on the deck itself does nothing: it belongs to the worlds and the preview.
        XCTAssertEqual(m.handle(.longOK), NoteFanMachine.Outcome.none)
        XCTAssertEqual(m.state, .deck(raised: "b"))
    }

    /// (q) Every way the card itself leaves takes the deck with it.
    func testHidingAndEnteringAWorldCollapseTheDeck() {
        var m = deckMachine()
        m.handle(.carried)
        m.handle(.raiseDeck("a"))
        XCTAssertEqual(m.handle(.hidden), .sink)
        XCTAssertEqual(m.state, .collapsed)

        var other = deckMachine()
        other.handle(.carried)
        XCTAssertEqual(other.handle(.worldEntered), .collapse)
        XCTAssertEqual(other.state, .collapsed)
        // A summon back into the hand is a carry from `collapsed`, which is the deck rising out of the card.
        XCTAssertEqual(other.handle(.carried), .morphToDeck)
        XCTAssertEqual(other.state, .deck(raised: nil))
    }

    /// (r) The passport is picked up **while a note is open**. The preview is world-locked in root space and
    /// the deck's slots are in the fan's, so the machine may not leave the preview standing: it goes into the
    /// deck, and the morph ends the preview in the same frame.
    func testPickingUpDuringAPreviewLeavesThePreviewBehind() {
        var m = deckMachine()
        XCTAssertEqual(m.handle(.tapped("b")), .preview("b"))
        XCTAssertEqual(m.handle(.carried), .morphToDeck)
        XCTAssertEqual(m.state, .deck(raised: nil))
        XCTAssertNil(m.state.previewID)
    }

    /// (s) …and the other way round: put the passport down while a **deck** preview is open. `settled` used
    /// to fall through its `state == .collapsed` guard and leave the machine in `.preview` with the card on
    /// the desk — the stranded-holder failure mode.
    func testPuttingDownDuringADeckPreviewEndsIt() {
        var m = deckMachine()
        m.handle(.carried)
        m.handle(.raiseDeck("b"))
        XCTAssertEqual(m.handle(.previewDirect("b")), .preview("b"))
        XCTAssertEqual(m.handle(.settled), .endPreview)
        XCTAssertEqual(m.state, .fanned, "the desk gets its gallery, not a preview it cannot place")
        XCTAssertNil(m.state.previewID)
        // …and the next OK opens a preview from the arc again, not from a deck that is not there.
        XCTAssertEqual(m.handle(.tapped("c")), .preview("c"))
        XCTAssertEqual(m.handle(.tapped("c")), .endPreview)
        XCTAssertEqual(m.state, .fanned)
    }

    // MARK: - V3-2b B1: the strip's dwell (plan §4 E8)

    /// The one thing E8 is: flipping **past** cards must not reach the device. Five quick raises arm five
    /// dwells and exactly one of them is allowed to send — the last.
    func testFiveQuickRaisesSendOneStrip() {
        var dwell = StripDwell()
        var generations: [Int] = []
        // DOWN DOWN DOWN DOWN DOWN, 0.12 s apart: well inside the 0.4 s dwell.
        for (index, text) in ["♥12", "♥33", "♥8", "♥120", "♥7"].enumerated() {
            generations.append(dwell.raise(.likes(text), at: 10 + 0.12 * Double(index)))
        }
        // Each timer fires 0.4 s after its own raise; the first four find themselves superseded.
        for (index, generation) in generations.enumerated() where index < 4 {
            XCTAssertNil(dwell.due(generation, at: 10 + 0.12 * Double(index) + 0.4),
                         "raise \(index) reached the device")
        }
        XCTAssertEqual(dwell.due(generations[4], at: 10 + 0.48 + 0.4), .likes("♥7"))
        // …and it only sends once: the strip is not re-painted by a second timer for the same raise.
        XCTAssertNil(dwell.due(generations[4], at: 11.5))
    }

    /// A timer that fires early (a raise landed inside its own dwell window) sends nothing, a world card and
    /// the profile both mean "give the follower count back", and anything that takes the strip over
    /// (a preview, a fold, a put-down) drops a dwell already in flight.
    func testTheDwellIsRealAndCancellable() {
        var dwell = StripDwell()
        let first = dwell.raise(.likes("♥33"), at: 100)
        XCTAssertNil(dwell.due(first, at: 100.39), "0.39 s is not 0.4 s")
        XCTAssertEqual(dwell.due(first, at: 100.40), .likes("♥33"))

        let second = dwell.raise(.restore, at: 101)
        XCTAssertEqual(dwell.due(second, at: 101.4), .restore, "a world card gives the follower count back")

        let third = dwell.raise(.likes("♥8"), at: 102)
        dwell.cancel()
        XCTAssertNil(dwell.due(third, at: 102.5), "a preview opened: the dwell may not paint over it")

        var quick = StripDwell(seconds: 0.1)
        let fourth = quick.raise(.likes("♥1"), at: 200)
        XCTAssertEqual(quick.due(fourth, at: 200.1), .likes("♥1"), "--strip-dwell is honoured")
        XCTAssertEqual(StripDwell.Request.likes("♥1").text, "♥1")
        XCTAssertNil(StripDwell.Request.restore.text)
    }

    // MARK: - V3-4 §2(b): paging inside a deck preview

    /// UP / DOWN with a note open page the preview itself, which reaches the machine as a second
    /// `previewDirect`. The thing that must survive it is `fromDeck`: the preview still came out of the hand,
    /// so closing it puts the card back on its **raised** slot rather than folding it into the name card.
    func testPagingInsideADeckPreviewKeepsItADeckPreview() {
        var m = NoteFanMachine()
        m.deckEnabled = true
        m.handle(.notesChanged(ids: ["a", "b", "c", "d", "e"]))
        m.handle(.settled)
        XCTAssertEqual(m.handle(.carried), .morphToDeck)
        XCTAssertEqual(m.handle(.raiseDeck("c")), .none)
        XCTAssertEqual(m.handle(.previewDirect("c")), .preview("c"))
        XCTAssertTrue(m.fromDeck)

        // The page: a plain `.preview`, never a `.switchPreview` (a deck preview is world-locked in
        // `notePreviewRoot` and the switch choreography would overlap two flights across two spaces).
        XCTAssertEqual(m.handle(.previewDirect("d")), .preview("d"))
        XCTAssertEqual(m.state, .preview("d"))
        XCTAssertTrue(m.fromDeck, "a page must not turn a deck preview into a hand-card one")
        XCTAssertEqual(m.handle(.previewDirect("e")), .preview("e"))
        XCTAssertTrue(m.fromDeck)

        // OK on the card that is open closes it, back onto the slot of the note actually being read.
        XCTAssertEqual(m.handle(.previewDirect("e")), .endPreview)
        XCTAssertEqual(m.state, .deck(raised: "e"))
        XCTAssertFalse(m.fromDeck)
    }

    /// `raiseDeck` while a preview is open changes nothing at all: the preview is what UP / DOWN are acting
    /// on, and `AppModel` routes them through `previewDirect`. (The controller's `raiseDeckCard` is still
    /// called — it is the deck's bookkeeping, and its tweens are skipped for cards the preview borrowed.)
    func testRaiseDeckIsIgnoredWhileAPreviewIsOpen() {
        var m = NoteFanMachine()
        m.deckEnabled = true
        m.handle(.notesChanged(ids: ["a", "b", "c"]))
        m.handle(.settled)
        m.handle(.carried)
        m.handle(.raiseDeck("b"))
        XCTAssertEqual(m.handle(.previewDirect("b")), .preview("b"))
        XCTAssertEqual(m.handle(.raiseDeck("a")), .none)
        XCTAssertEqual(m.state, .preview("b"), "the preview owns the buttons while it is open")
        XCTAssertTrue(m.fromDeck)
        XCTAssertEqual(m.handle(.raiseDeck(nil)), .none)
        XCTAssertEqual(m.state, .preview("b"))
    }

    /// **v4 B5 §1.** A `cmd perf rehearse=fanout` whose fan-out cannot follow its collapse (the passport was picked up in
    /// between) lifts the collapse's suppression: that collapse was the director's, and a long OK's suppression would
    /// otherwise keep the gallery down after the next put-down for the rest of the session.
    func testUnsuppressLiftsTheRehearsalsCollapse() {
        var m = NoteFanMachine()
        m.deckEnabled = true
        m.handle(.notesChanged(ids: ["a", "b"]))
        XCTAssertEqual(m.handle(.settled), .fanOut)
        XCTAssertEqual(m.handle(.longOK), .collapse)
        XCTAssertTrue(m.suppressed)
        XCTAssertEqual(m.handle(.carried), .morphToDeck, "picked up mid-rehearsal")
        XCTAssertEqual(m.handle(.unsuppress), .none)
        XCTAssertFalse(m.suppressed)
        XCTAssertEqual(m.state, .deck(raised: nil), "nothing else moves")
        XCTAssertEqual(m.handle(.settled), .none, "the put-down bloom is the controller's")
        XCTAssertEqual(m.state, .fanned, "the gallery comes back with the put-down")
    }
}
