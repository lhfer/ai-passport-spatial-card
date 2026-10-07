import XCTest

/// **V3-3 C2 / plan §4 E14b.** The card's face is three attachments at three depths. What keeps them one
/// card — rather than three views that happen to look alike — is that they are all struck from
/// `CardLayers.sheets`, which hands every one of them the same mode. These are the tests of that.
final class CardLayerTests: XCTestCase {
    /// **The invariant.** Whatever the card is doing — desk, world, hand — all three sheets are told the
    /// same thing. A pick-up that reached the plate but not the avatar would show a half-size card's type
    /// under a desk-size avatar for a third of a second, which is exactly the class of bug the single
    /// attachment made impossible and this one has to keep impossible.
    func testEveryLayerGetsTheSameMode() {
        for mode in [HologramCardMode.full, .mini, .hand] {
            let sheets = CardLayers.sheets(mode: mode)
            XCTAssertEqual(sheets.count, 3)
            XCTAssertEqual(sheets.map(\.mode).filter { $0 == mode }.count, 3, "\(mode): a sheet is out of step")
            // Three distinct layers, three distinct ids, and the ids the controller mounts holders for.
            XCTAssertEqual(Set(sheets.map(\.layer)).count, 3)
            XCTAssertEqual(Set(sheets.map(\.id)).count, 3)
            XCTAssertEqual(Set(sheets.map(\.id)), ["card", "card.avatar", "card.tags"])
            XCTAssertEqual(sheets.map(\.layer), [.base, .tags, .avatar], "back to front")
            // …and exactly one of them catches a pinch.
            XCTAssertEqual(sheets.filter(\.tappable).map(\.layer), [.base])
        }
        // Every case of the enum is mounted: adding a fourth layer without mounting it would fail here.
        XCTAssertEqual(Set(CardLayers.sheets(mode: .full).map(\.layer)), Set(HologramCardLayer.allCases))
    }

    /// The depths, in the card's own frame: the plate where the single attachment always was, the capsules
    /// 4 mm off it, the hero image 8 mm — and the back face, which is not a sheet, on the other side.
    func testTheDepthsAreThePlansEightAndFourMillimetres() {
        XCTAssertEqual(CardLayers.z(.base), 0.002, accuracy: 1e-6)
        XCTAssertEqual(CardLayers.z(.tags), 0.006, accuracy: 1e-6)
        XCTAssertEqual(CardLayers.z(.avatar), 0.010, accuracy: 1e-6)
        XCTAssertEqual(CardLayers.z(.avatar) - CardLayers.z(.base), 0.008, accuracy: 1e-6)
        XCTAssertEqual(CardLayers.z(.tags) - CardLayers.z(.base), 0.004, accuracy: 1e-6)
        // Back to front, strictly: the hero image is never behind the chips.
        let z = CardLayers.sheets(mode: .hand).map(\.z)
        XCTAssertEqual(z, z.sorted())
        XCTAssertNotEqual(CardLayers.backAttachmentID, CardLayers.baseAttachmentID)
    }

    /// `--parallax off` collapses all three onto the base z — V3-2b's single attachment, pixel for pixel —
    /// and changes nothing else: same ids, same layers, same mode, same tappability. The sheets carry the
    /// flag, because at one depth a *partition* would let the plate's own background occlude whichever
    /// coplanar sheet the renderer drew first: off, the base sheet draws the whole card instead.
    func testParallaxOffCollapsesTheDepthsAndNothingElse() {
        let on = CardLayers.sheets(mode: .hand, parallax: true)
        let off = CardLayers.sheets(mode: .hand, parallax: false)
        XCTAssertEqual(off.map(\.z), [0.002, 0.002, 0.002])
        XCTAssertEqual(off.map(\.parallax), [false, false, false])
        XCTAssertEqual(on.map(\.parallax), [true, true, true])
        XCTAssertEqual(off.map(\.id), on.map(\.id))
        XCTAssertEqual(off.map(\.layer), on.map(\.layer))
        XCTAssertEqual(off.map(\.mode).filter { $0 == .hand }.count, 3)
        XCTAssertEqual(off.map(\.tappable), on.map(\.tappable))
        for layer in HologramCardLayer.allCases {
            XCTAssertEqual(CardLayers.lift(layer, parallax: false), 0)
        }
    }
}
