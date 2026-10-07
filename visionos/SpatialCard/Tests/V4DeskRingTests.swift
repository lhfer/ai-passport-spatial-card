import XCTest

/// **v4 B2 §2 — one button ring on the desk, and one way to close a preview.** The ring is the gallery's notes in
/// gallery order and then the two world coins, round again; DOWN = next, UP = previous, from nothing DOWN = the first
/// note and UP = the last coin; a highlight is only acted on for `window` seconds. `.closePreview` closes whatever
/// preview is open and does nothing when none is.
final class V4DeskRingTests: XCTestCase {
    private typealias Ring = V4.DeskRing
    private let notes = (0..<10).map { "n\($0)" }
    private let worlds = ["neon-city", "data-nebula"]

    private func ring() -> Ring {
        var r = Ring()
        r.sync(notes: notes, worlds: worlds)
        return r
    }

    func testTheRingIsTheNotesInGalleryOrderThenTheCoins() {
        let r = ring()
        XCTAssertEqual(r.items.count, 12)
        XCTAssertEqual(r.items.first, .note("n0"))
        XCTAssertEqual(r.items[9], .note("n9"))
        XCTAssertEqual(Array(r.items.suffix(2)), [.world("neon-city"), .world("data-nebula")])
        XCTAssertNil(r.highlighted)
    }

    func testFromNothingDownIsTheFirstNoteAndUpTheLastCoin() {
        var down = ring()
        XCTAssertEqual(down.step(+1, at: 0), .note("n0"))
        var up = ring()
        XCTAssertEqual(up.step(-1, at: 0), .world("data-nebula"))
    }

    /// The brief's smoke, step by step: UP ×3 lands on a note, OK opens it, DOWN pages (inside the notes), OK closes
    /// (the ring stays on the note just read), UP reaches a world coin.
    func testTheBriefsSequence() {
        var r = ring()
        XCTAssertEqual(r.step(-1, at: 0), .world("data-nebula"))
        XCTAssertEqual(r.step(-1, at: 0.8), .world("neon-city"))
        XCTAssertEqual(r.step(-1, at: 1.6), .note("n9"))
        XCTAssertEqual(r.current(at: 3), .note("n9"), "OK opens n9")
        let paged = r.adjacentNote(to: "n9", delta: +1)
        XCTAssertEqual(paged, "n0", "DOWN inside the preview wraps within the notes")
        XCTAssertTrue(r.jump(to: .note(paged!), at: 6))
        XCTAssertEqual(r.current(at: 9), .note("n0"), "closing leaves the ring on the note just read")
        XCTAssertEqual(r.step(-1, at: 11.5), .world("data-nebula"), "UP from the first note wraps to a coin")
        XCTAssertEqual(r.current(at: 13), .world("data-nebula"), "OK enters it")
    }

    func testTheRingWrapsBothWays() {
        var r = ring()
        _ = r.step(+1, at: 0)
        for _ in 0..<11 { _ = r.step(+1, at: 0) }
        XCTAssertEqual(r.highlighted, .world("data-nebula"))
        XCTAssertEqual(r.step(+1, at: 0), .note("n0"))
        XCTAssertEqual(r.step(-1, at: 0), .world("data-nebula"))
    }

    /// v3 H2 §4's rule, kept: an old highlight is not something OK acts on (or OK could never fold the card again).
    func testAHighlightLapsesAfterTheWindow() {
        var r = ring()
        _ = r.step(+1, at: 10)
        XCTAssertEqual(r.current(at: 10 + Ring.window), .note("n0"))
        XCTAssertNil(r.current(at: 10 + Ring.window + 0.01))
        XCTAssertTrue(r.hasLapsed(at: 10 + Ring.window + 0.01))
        XCTAssertFalse(r.hasLapsed(at: 10 + Ring.window))
        XCTAssertGreaterThan(Ring.window, 5, "longer than v3's coin window: a title takes longer to read than a name")
    }

    /// No gallery on the desk (folded, taken back): the ring is the two coins only, as v3's carousel was.
    func testWithoutAGalleryTheRingIsTheCoins() {
        var r = Ring()
        r.sync(notes: [], worlds: worlds)
        XCTAssertEqual(r.step(+1, at: 0), .world("neon-city"))
        XCTAssertEqual(r.step(+1, at: 0), .world("data-nebula"))
        XCTAssertEqual(r.step(+1, at: 0), .world("neon-city"))
        XCTAssertNil(r.adjacentNote(to: "n0", delta: 1))
    }

    func testANewListKeepsTheHighlightOnlyIfItsItemIsStillThere() {
        var r = ring()
        _ = r.step(+1, at: 0)
        _ = r.step(+1, at: 0)
        XCTAssertEqual(r.highlighted, .note("n1"))
        r.sync(notes: ["x", "n1", "y"], worlds: worlds)
        XCTAssertEqual(r.highlighted, .note("n1"))
        XCTAssertEqual(r.index, 1)
        r.sync(notes: ["x", "y"], worlds: worlds)
        XCTAssertNil(r.highlighted)
        XCTAssertNil(r.current(at: 0))
    }

    func testAnEmptyRingDoesNothing() {
        var r = Ring()
        XCTAssertNil(r.step(+1, at: 0))
        XCTAssertFalse(r.jump(to: .note("n0"), at: 0))
        XCTAssertEqual(Ring.Item.note("6ab205ffff").label, "note 6ab205")
        XCTAssertEqual(Ring.Item.world("neon-city").label, "neon-city")
    }

    // MARK: - `.closePreview`

    private func fannedMachine() -> NoteFanMachine {
        var m = NoteFanMachine()
        _ = m.handle(.notesChanged(ids: notes))
        _ = m.handle(.settled)
        XCTAssertEqual(m.state, .fanned)
        return m
    }

    func testClosingAGalleryPreviewGoesBackToTheGallery() {
        var m = fannedMachine()
        XCTAssertEqual(m.handle(.tapped("n3")), .preview("n3"))
        XCTAssertEqual(m.handle(.closePreview), .endPreview)
        XCTAssertEqual(m.state, .fanned)
        XCTAssertFalse(m.suppressed, "closing a preview is not taking the fan back")
    }

    /// A second tap that lands after the panel has gone must not take the fan back (long OK would) or throw it.
    func testClosingWithNothingOpenDoesNothing() {
        var m = fannedMachine()
        XCTAssertEqual(m.handle(.closePreview), .none)
        XCTAssertEqual(m.state, .fanned)
        var collapsed = NoteFanMachine()
        _ = collapsed.handle(.notesChanged(ids: notes))
        XCTAssertEqual(collapsed.handle(.closePreview), .none)
        XCTAssertEqual(collapsed.state, .collapsed)
    }

    /// In the hand the card goes back to its raised deck slot (V3-2a H6), the same as OK there always did.
    func testClosingADeckPreviewPutsTheCardBackRaised() {
        var m = fannedMachine()
        m.deckEnabled = true
        XCTAssertEqual(m.handle(.carried), .morphToDeck)
        _ = m.handle(.raiseDeck("n2"))
        XCTAssertEqual(m.handle(.previewDirect("n2")), .preview("n2"))
        XCTAssertEqual(m.handle(.closePreview), .endPreview)
        XCTAssertEqual(m.state, .deck(raised: "n2"))
    }

    func testPagingInADeskPreviewIsTheGallerySwitch() {
        var m = fannedMachine()
        _ = m.handle(.tapped("n9"))
        XCTAssertEqual(m.handle(.tapped("n0")), .switchPreview(from: "n9", to: "n0"))
        XCTAssertEqual(m.state, .preview("n0"))
    }
}
