import XCTest
import simd

/// `HandDeckLayout` decides whether the seven cards in the wearer's hand read as a hand of cards or as a
/// pile behind the name card, and whether the raised one is actually readable. All of it is geometry, so
/// none of it needs a headset.
final class HandDeckLayoutTests: XCTestCase {
    private let full = HandDeckLayout.fullCount   // 7

    /// (a) In the band above the name card's top edge — the only part of a deck card the wearer can see —
    /// every card shows a sliver of itself that its neighbour does not cover.
    ///
    /// The cards *do* overlap lower down: that is what a hand of cards is. What must not happen is two of
    /// them landing in the same column, which is the difference between a fan and a pile.
    func testEveryCardShowsASliverNoNeighbourCovers() {
        let slots = HandDeckLayout.slots(count: full)
        let xs = slots.map(\.position.x)
        XCTAssertEqual(xs, xs.sorted(), "the fan has to run left to right without crossing itself")
        for (a, b) in zip(slots, slots.dropFirst()) {
            let step = b.position.x - a.position.x
            XCTAssertGreaterThanOrEqual(step, HandDeckLayout.minimumExposedSliver,
                                        "slots \(a.index) and \(b.index) are \(step * 1000) mm apart")
        }
    }

    /// (b) The middle card — the one the fan is built around — shows at least 25 mm above the card's top
    /// edge. Below that there is no cover art to read and the deck stops being a deck.
    func testTheMiddleCardShowsAtLeastTwentyFiveMillimetres() {
        let middle = HandDeckLayout.slot(index: full / 2, count: full)
        XCTAssertEqual(middle.angle, 0, accuracy: 1e-6)
        let exposed = middle.top - HandDeckLayout.cardTop
        XCTAssertGreaterThanOrEqual(exposed, 0.025, "only \(exposed * 1000) mm of the middle card shows")
        // …and the cards at the two ends are lower than it, or the fan is upside down.
        for end in [0, full - 1] {
            XCTAssertLessThan(HandDeckLayout.slot(index: end, count: full).top, middle.top)
        }
    }

    /// (c) A raised card clears the name card: its bottom edge is above the card's top edge (and in front of
    /// it), so nothing of the profile is hidden behind it.
    func testTheRaisedCardDoesNotIntersectTheNameCard() {
        let raised = HandDeckLayout.raised(index: 3)
        let bottom = raised.position.y - HandDeckLayout.cardSize.y * raised.scale / 2
        XCTAssertGreaterThan(bottom, HandDeckLayout.cardTop, "the raised card's bottom edge overlaps the card")
        XCTAssertEqual(bottom - HandDeckLayout.cardTop, 0.005, accuracy: 0.0005, "the plan's 5 mm")
        XCTAssertGreaterThan(raised.position.z, 0, "and it stands in front of the card, not behind it")
        XCTAssertEqual(raised.scale, HandDeckLayout.raisedScale)
    }

    /// (d) The deck degrades: no notes at all is still the two world cards, and everything between keeps the
    /// fan centred and the 12° step.
    func testTheDeckDegradesWithFewerNotes() {
        for notes in 0...5 {
            let count = HandDeckLayout.count(notes: notes)
            XCTAssertEqual(count, notes + HandDeckLayout.worldCards)
            let slots = HandDeckLayout.slots(count: count)
            XCTAssertEqual(slots.count, count)
            // Centred: the angles sum to zero.
            XCTAssertEqual(slots.map(\.angle).reduce(0, +), 0, accuracy: 1e-5)
            for (a, b) in zip(slots, slots.dropFirst()) {
                XCTAssertEqual(b.angle - a.angle, HandDeckLayout.angleStep, accuracy: 1e-6)
            }
        }
        // More than five notes is still five: the deck is the *latest* five, not the whole gallery.
        XCTAssertEqual(HandDeckLayout.count(notes: 10), HandDeckLayout.fullCount)
    }

    /// (e) The ring: profile → the first world → the five newest notes → the second world → and round.
    func testRingOrderPutsTheWorldsAtTheTwoEnds() {
        let worlds = ["neon-city", "data-nebula"]
        let notes = ["n0", "n1", "n2", "n3", "n4", "n5"]
        let pages = HandDeckLayout.pages(worlds: worlds, notes: notes)
        XCTAssertEqual(pages, [.profile, .world("neon-city"),
                               .note("n0"), .note("n1"), .note("n2"), .note("n3"), .note("n4"),
                               .world("data-nebula")])
        // A pager walking it wraps both ways.
        var pager = HandPager()
        pager.deck = true
        pager.sync(worlds: worlds, notes: notes)
        XCTAssertEqual(pager.step(1), .world("neon-city"))
        XCTAssertEqual(pager.step(-1), .profile)
        XCTAssertEqual(pager.step(-1), .world("data-nebula"))
        // Fewer worlds: the remaining one stays at the head and the notes close up behind it.
        XCTAssertEqual(HandDeckLayout.pages(worlds: ["neon-city"], notes: ["n0"]),
                       [.profile, .world("neon-city"), .note("n0")])
        XCTAssertEqual(HandDeckLayout.pages(worlds: [], notes: ["n0"]), [.profile, .note("n0")])
    }

    /// (f) Page ↔ slot: the ring's page `n` is slot `n − 1`, and the profile is no slot at all.
    func testSlotMappingFollowsTheRing() {
        let worlds = ["neon-city", "data-nebula"]
        let notes = ["n0", "n1", "n2", "n3", "n4"]
        XCTAssertNil(HandDeckLayout.slotIndex(of: .profile, worlds: worlds, notes: notes))
        XCTAssertEqual(HandDeckLayout.slotIndex(of: .world("neon-city"), worlds: worlds, notes: notes), 0)
        XCTAssertEqual(HandDeckLayout.slotIndex(of: .note("n0"), worlds: worlds, notes: notes), 1)
        XCTAssertEqual(HandDeckLayout.slotIndex(of: .note("n4"), worlds: worlds, notes: notes), 5)
        XCTAssertEqual(HandDeckLayout.slotIndex(of: .world("data-nebula"), worlds: worlds, notes: notes), 6)
        XCTAssertNil(HandDeckLayout.slotIndex(of: .note("gone"), worlds: worlds, notes: notes))
    }
}
