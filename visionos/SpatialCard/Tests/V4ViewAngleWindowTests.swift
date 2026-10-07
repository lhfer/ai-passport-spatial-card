import simd
import XCTest

/// **v4 B5 §6** — the `Σ` line's `normal=` field: the mean (and range) of the line of sight's angle to the screen's normal
/// over the window's tracked observations.
final class V4ViewAngleWindowTests: XCTestCase {
    typealias Window = V4.ViewAngleWindow

    func testAnEmptyWindowSaysSo() {
        XCTAssertEqual(Window().field, "normal=-")
    }

    func testTheMeanAndTheRange() {
        var w = Window()
        for degrees: Float in [52, 58, 64, 58] { w.add(degrees * .pi / 180) }
        XCTAssertEqual(w.count, 4)
        XCTAssertEqual(w.field, "normal=58° (52–64°)")
    }

    func testNonsenseIsNotAnObservation() {
        var w = Window()
        w.add(.nan)
        w.add(.infinity)
        XCTAssertEqual(w.field, "normal=-")
        w.add(30 * .pi / 180)
        XCTAssertEqual(w.field, "normal=30° (30–30°)")
    }

    /// The angle itself is `TrackingWatch.viewAngle`'s (B4 §4): a passport flat on a desk 0.62 m ahead and 0.29 m below the
    /// eyes is seen 65° off its normal; held up square to the face, 0°.
    func testTheAngleFeedingItIsB4s() {
        let head = simd_float4x4(translation: [0, 1.6, 0])
        let flat = simd_float4x4(translation: [0, 1.31, -0.62])
        let angle = V4.TrackingWatch.viewAngle(head: head, pose: flat)!
        XCTAssertEqual(angle * 180 / .pi, 65, accuracy: 1)
        var w = Window()
        w.add(angle)
        XCTAssertEqual(w.field, "normal=65° (65–65°)")
    }
}

private extension simd_float4x4 {
    init(translation t: SIMD3<Float>) {
        self = matrix_identity_float4x4
        columns.3 = SIMD4<Float>(t, 1)
    }
}
