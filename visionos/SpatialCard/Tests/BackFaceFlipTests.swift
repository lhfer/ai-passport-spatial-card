import XCTest

/// **V3-3 C3 / plan §4 E14c.** The flip between the card's two sides: when it happens, when it does not,
/// and — the part that matters for a log the reviewer reads — that it happens *once*.
final class BackFaceFlipTests: XCTestCase {
    /// The back needs the card pointing more than 100° away. 99° is not 101°, and once it is up, every
    /// further frame past the threshold is silent.
    func testTheBackComesUpPastAHundredDegreesAndNotBefore() {
        var flip = BackFaceFlip()
        XCTAssertFalse(flip.showsBack)
        // Square on, edge on, and just short of the threshold: nothing.
        for dot: Float in [1, 0.5, 0, -0.05, -0.12, -0.169] {
            XCTAssertNil(flip.update(facing: dot), "flipped at \(dot)")
            XCTAssertFalse(flip.showsBack)
        }
        XCTAssertEqual(flip.update(facing: -0.18), .toBack)
        XCTAssertTrue(flip.showsBack)
        // Once per flip: the next hundred frames of the wearer holding it there say nothing.
        for dot: Float in [-0.2, -0.5, -0.9, -1, -0.3] {
            XCTAssertNil(flip.update(facing: dot))
            XCTAssertTrue(flip.showsBack)
        }
        // A frame with no answer in it (no head pose, a degenerate normal) changes nothing either.
        XCTAssertNil(flip.update(facing: .nan))
        XCTAssertTrue(flip.showsBack)
    }

    /// Coming back, the threshold is a different one — and the band between them is where a passport held
    /// edge-on actually sits, so nothing in it may move the card.
    func testTheFrontComesBackOnlyAfterTheDeadBand() {
        var flip = BackFaceFlip()
        XCTAssertEqual(flip.update(facing: -0.4), .toBack)
        // Inside the dead band (−0.17 … −0.05): still the back, however long the wearer dithers there.
        for dot: Float in [-0.16, -0.10, -0.06, -0.051, -0.16] {
            XCTAssertNil(flip.update(facing: dot), "returned at \(dot)")
            XCTAssertTrue(flip.showsBack)
        }
        XCTAssertEqual(flip.update(facing: -0.04), .toFront)
        XCTAssertFalse(flip.showsBack)
        // …and the way back in needs the full −0.17 again: the dead band cannot be re-entered from below.
        XCTAssertNil(flip.update(facing: -0.16))
        XCTAssertFalse(flip.showsBack)

        // A wrist turning smoothly all the way over and back flips exactly twice — no chatter at either
        // crossing, which is the whole reason the two thresholds are different numbers.
        var turns = 0
        var sweep = BackFaceFlip()
        for degrees in stride(from: Float(0), through: 360, by: 2) {
            let a = degrees * .pi / 180
            // 0° → 180° → 360°: facing, turned right away, facing again.
            if sweep.update(facing: cos(a)) != nil { turns += 1 }
        }
        XCTAssertEqual(turns, 2)
        XCTAssertFalse(sweep.showsBack)

        // A fold while the back is up puts the card back on its front, once.
        var folded = BackFaceFlip()
        XCTAssertEqual(folded.update(facing: -1), .toBack)
        XCTAssertEqual(folded.reset(), .toFront)
        XCTAssertNil(folded.reset())
        XCTAssertFalse(folded.showsBack)
    }
}
