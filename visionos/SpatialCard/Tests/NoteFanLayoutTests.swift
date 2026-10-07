import XCTest
import simd

/// The gallery's geometry (工作包 D v2): ten cards **平铺** in two staggered rows of five, on a gentle arc struck
/// around the wearer. The number that matters is the distance between card centres — v1 put them on one 152°
/// arc 30 cm from the card, which is 9.7 cm between neighbours for a 10 cm card: they overlapped.
final class NoteFanLayoutTests: XCTestCase {
    private let cardCenterHeight: Float = 0.22     // HologramLayout.cardCenterHeight

    // (a) no card comes within 11.5 cm of any other — and that is checked over **every pair**, not just the
    //     ones that happen to be neighbours in the list: the diagonal between the two rows is a real pair too.
    func testNoCardOverlapsAnyOther() {
        let slots = NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight)
        XCTAssertEqual(slots.count, 10)
        for a in slots {
            for b in slots where b.index > a.index {
                let d = simd_distance(a.position, b.position)
                XCTAssertGreaterThanOrEqual(d, NoteFanLayout.minimumNeighbourDistance,
                                            String(format: "cards %d–%d are %.1f mm apart", a.index, b.index, d * 1000))
            }
        }
        // The tightest pair is two neighbours inside a row: 12.6 cm against a 10 cm card.
        let neighbours = zip(slots, slots.dropFirst()).map { simd_distance($0.position, $1.position) }
        XCTAssertGreaterThan(neighbours.min() ?? 0, NoteFanLayout.cardSize.x + 0.02)
    }

    // (b) two rows of five, the back one raised and pushed away, offset half a column sideways
    func testTwoStaggeredRows() {
        let slots = NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight)
        XCTAssertEqual(NoteFanLayout.columns(count: 10), 5)
        XCTAssertEqual(NoteFanLayout.rows(count: 10), 2)
        XCTAssertEqual(slots.filter { $0.row == 0 }.map(\.index), [0, 1, 2, 3, 4])
        XCTAssertEqual(slots.filter { $0.row == 1 }.map(\.index), [5, 6, 7, 8, 9])
        for slot in slots {
            XCTAssertEqual(slot.radius, slot.row == 0 ? NoteFanLayout.nearRadius : NoteFanLayout.farRadius)
            // Every card is exactly its row's radius from the wearer: one viewing distance for the gallery.
            let fromWearer = simd_length(SIMD3<Float>(slot.position.x - NoteFanLayout.wearerEstimate.x, 0,
                                                      slot.position.z - NoteFanLayout.wearerEstimate.z))
            XCTAssertEqual(fromWearer, slot.radius, accuracy: 1e-5)
        }
        // The back row is one `rowRise` above the front one at the matching column, and half a column across.
        for column in 0..<5 {
            let front = slots[column], back = slots[column + 5]
            XCTAssertEqual(back.position.y - front.position.y,
                           NoteFanLayout.rowRise + NoteFanLayout.crown(index: column + 5, count: 10)
                               - NoteFanLayout.crown(index: column, count: 10), accuracy: 1e-5)
            XCTAssertEqual(back.angle - front.angle, NoteFanLayout.rowStagger * NoteFanLayout.columnStep, accuracy: 1e-5)
        }
        // …and the pair of rows stays centred on −Z: the two staggers cancel.
        XCTAssertEqual(slots.map(\.angle).reduce(0, +), 0, accuracy: 1e-5)
    }

    // (c) the gallery hangs behind and above the 0.27 m card: nothing intersects the slab, nothing is in front
    //     of the reader, and the rows clear each other by more than a card's height
    func testGalleryClearsTheCardAndItself() {
        let slots = NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight)
        let cardCentre = SIMD3<Float>(0, cardCenterHeight, 0)
        let noteHalfHeight = NoteFanLayout.cardSize.y / 2
        for slot in slots {
            // Half the slab's diagonal (0.282 m card) plus half a note card's diagonal is 0.28 m: staying
            // outside that sphere is what keeps a note card from standing inside the plate.
            XCTAssertGreaterThan(simd_distance(slot.position, cardCentre), 0.28, "card \(slot.index) is inside the slab")
            XCTAssertGreaterThan(slot.position.y - noteHalfHeight, cardCenterHeight, "card \(slot.index) hangs too low")
            XCTAssertLessThan(slot.position.z, 0, "card \(slot.index) fell in front of the card")
        }
        // Rows never touch: even the highest front card and the lowest back card leave a gap.
        let frontTop = slots.filter { $0.row == 0 }.map { $0.position.y + noteHalfHeight }.max()!
        let backBottom = slots.filter { $0.row == 1 }.map { $0.position.y - noteHalfHeight }.min()!
        XCTAssertGreaterThan(backBottom - frontTop, 0.01, "the two rows overlap vertically")
    }

    // (d) the crown: a row is a gentle arc, highest in the middle and level at its ends
    func testRowsAreCrowned() {
        XCTAssertEqual(NoteFanLayout.crown(index: 0, count: 10), 0, accuracy: 1e-6, "the end of a row is the datum")
        XCTAssertEqual(NoteFanLayout.crown(index: 9, count: 10), 0, accuracy: 1e-6)
        for index in 0..<10 {
            let c = NoteFanLayout.crown(index: index, count: 10)
            XCTAssertGreaterThanOrEqual(c, 0)
            XCTAssertLessThanOrEqual(c, NoteFanLayout.heightAmplitude)
        }
        // The card nearest θ = 0 is the highest of its row.
        let front = NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight).filter { $0.row == 0 }
        XCTAssertEqual(front.max(by: { $0.position.y < $1.position.y })!.index,
                       front.min(by: { abs($0.angle) < abs($1.angle) })!.index)
    }

    // (e) every card is turned toward the wearer — the yaw is the bearing back to `wearerEstimate`, not a
    //     billboard and not the splay of v1 (which turned the ends away)
    func testCardsFaceTheWearer() {
        for slot in NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight) {
            XCTAssertEqual(slot.yaw, -slot.angle, accuracy: 1e-6)
            XCTAssertEqual(slot.pitch, NoteFanLayout.pitchDegrees * .pi / 180, accuracy: 1e-6)
            // The card's face is its local +Z; a yaw of φ about +Y sends it to (sin φ, 0, cos φ).
            let facing = SIMD3<Float>(sin(slot.yaw), 0, cos(slot.yaw))
            var toWearer = NoteFanLayout.wearerEstimate - slot.position
            toWearer.y = 0
            toWearer = simd_normalize(toWearer)
            XCTAssertEqual(simd_dot(facing, toWearer), 1, accuracy: 1e-5, "card \(slot.index) is not looking at the wearer")
        }
    }

    // (f) degenerate counts do not produce NaN (a single note, none at all, or a list that fits one row)
    func testSmallCountsAreFinite() {
        XCTAssertTrue(NoteFanLayout.slots(count: 0, cardCenterHeight: cardCenterHeight).isEmpty)
        let one = NoteFanLayout.slots(count: 1, cardCenterHeight: cardCenterHeight)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(one[0].angle, 0)
        XCTAssertEqual(one[0].row, 0)
        XCTAssertEqual(one[0].position.z, NoteFanLayout.wearerEstimate.z - NoteFanLayout.nearRadius, accuracy: 1e-6)
        for count in [0, 1, 2, 3, 5, 6, 7, 10, 11] {
            let slots = NoteFanLayout.slots(count: count, cardCenterHeight: cardCenterHeight)
            XCTAssertEqual(slots.count, count)
            XCTAssertEqual(NoteFanLayout.rows(count: count), count > NoteFanLayout.columnsPerRow ? 2 : 1)
            for slot in slots {
                XCTAssertTrue(slot.position.x.isFinite && slot.position.y.isFinite && slot.position.z.isFinite)
                XCTAssertTrue(slot.yaw.isFinite && slot.pitch.isFinite && slot.angle.isFinite && slot.radius.isFinite)
            }
            for a in slots {
                for b in slots where b.index > a.index {
                    XCTAssertGreaterThanOrEqual(simd_distance(a.position, b.position),
                                                NoteFanLayout.minimumNeighbourDistance,
                                                "count \(count): cards \(a.index)–\(b.index) overlap")
                }
            }
        }
    }

    // (g) the outward direction is the unit bearing from the **wearer** through the slot (the "step back" axis)
    func testOutwardIsTheBearingFromTheWearer() {
        for slot in NoteFanLayout.slots(count: 10, cardCenterHeight: cardCenterHeight) {
            XCTAssertEqual(simd_length(slot.outward), 1, accuracy: 1e-5)
            var fromWearer = slot.position - NoteFanLayout.wearerEstimate
            fromWearer.y = 0
            XCTAssertEqual(simd_distance(simd_normalize(fromWearer), slot.outward), 0, accuracy: 1e-5)
            // Stepping back moves a card away from the wearer, never toward them.
            let stepped = slot.position + slot.outward * 0.03
            XCTAssertGreaterThan(simd_distance(stepped, NoteFanLayout.wearerEstimate),
                                 simd_distance(slot.position, NoteFanLayout.wearerEstimate))
        }
    }
}
