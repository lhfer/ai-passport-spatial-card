import XCTest
import simd

/// **V3-3 C1 / plan §4 E14a.** The rim's Fresnel curve: square-on is quiet, edge-on is bright, and nothing
/// a bad frame can hand it (a zero vector, an un-normalised one, the head sitting on the card's centre)
/// takes it outside that band.
final class RimFresnelTests: XCTestCase {
    /// Square-on — the desk's billboard case, and the hand card's resting one. `|n · v|`, so the *back* of
    /// the card is square-on too: a card turned right round is still being looked at through its face.
    func testFacingIsTheQuietEnd() {
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: [0, 0, 1]), 0.45, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: [0, 0, -1]), 0.45, accuracy: 1e-5)
        // …and an un-normalised pair is the same number: the helper normalises both.
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 4], view: [0, 0, 0.25]), 0.45, accuracy: 1e-5)
    }

    /// Edge-on: 0.45 + 0.35 = 0.80, from any of the four directions the edge can be turned toward.
    func testGrazingIsTheBrightEnd() {
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: [1, 0, 0]), 0.80, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: [0, 1, 0]), 0.80, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: [0, -1, 0]), 0.80, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.grazing, 0.80, accuracy: 1e-5)
        // The exponent is what keeps the middle of the sweep dark: 60° off square is only a third of the way
        // up, not half. (1 − cos 60°)^1.5 = 0.5^1.5 = 0.3536.
        let sixty = SIMD3<Float>(sin(Float.pi / 3), 0, cos(Float.pi / 3))
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: sixty),
                       0.45 + 0.35 * pow(0.5, 1.5), accuracy: 1e-4)
    }

    /// Whatever it is handed, the answer is a real number inside [0.45, 0.80] — a degenerate frame reads as
    /// square-on (the quiet value), never as a flash.
    func testItIsClampedAndNeverDegenerate() {
        XCTAssertEqual(RimFresnel.opacity(normal: .zero, view: [0, 0, 1]), 0.45, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, 1], view: .zero), 0.45, accuracy: 1e-5)
        XCTAssertEqual(RimFresnel.opacity(normal: [0, 0, .nan], view: [0, 0, 1]), 0.45, accuracy: 1e-5)
        // A full sweep of the hinge's own range and well past it: every sample inside the band, monotonic
        // from square-on to edge-on.
        var previous = RimFresnel.opacity(normal: [0, 0, 1], view: [0, 0, 1])
        for degrees in stride(from: Float(0), through: 90, by: 5) {
            let a = degrees * .pi / 180
            let value = RimFresnel.opacity(normal: [0, 0, 1], view: [sin(a), 0, cos(a)])
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, RimFresnel.facing)
            XCTAssertLessThanOrEqual(value, RimFresnel.grazing)
            XCTAssertGreaterThanOrEqual(value, previous - 1e-6)
            previous = value
        }
    }
}
