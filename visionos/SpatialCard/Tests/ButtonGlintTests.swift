import XCTest
import simd

/// **V3-2a2 S3 / plan §4 E6.** Where the three key glints stand: on the right side of the device
/// (`--button-edge`), at the right key, and — H0 — never over the hardware.
final class ButtonGlintTests: XCTestCase {
    private let footprint = DeviceFootprint.aiPassport

    func testTheThreeKeysAreWhereThePlanPutsThem() {
        XCTAssertEqual(ButtonGlintLayout.Key.ok.z, 0, accuracy: 1e-6)
        XCTAssertEqual(ButtonGlintLayout.Key.up.z, -0.020, accuracy: 1e-6)
        XCTAssertEqual(ButtonGlintLayout.Key.down.z, 0.020, accuracy: 1e-6)
        // UP is toward the device's top edge (−Z) and DOWN toward the reader (+Z), and both are on the
        // device: a glint 20 mm off centre is well inside the 95 mm length.
        for key in ButtonGlintLayout.Key.allCases {
            XCTAssertLessThan(abs(key.z), footprint.size.y / 2)
        }
    }

    func testTheEdgeFlagMirrorsTheGlintsAndNothingElse() {
        for key in ButtonGlintLayout.Key.allCases {
            let right = ButtonGlintLayout.position(key, edge: .plusX, footprint: footprint)
            let left = ButtonGlintLayout.position(key, edge: .minusX, footprint: footprint)
            XCTAssertEqual(right.x, -left.x, accuracy: 1e-6)
            XCTAssertGreaterThan(right.x, 0)
            XCTAssertLessThan(left.x, 0)
            XCTAssertEqual(right.y, left.y, accuracy: 1e-6)
            XCTAssertEqual(right.z, left.z, accuracy: 1e-6)
            XCTAssertEqual(right.z, key.z, accuracy: 1e-6)
            XCTAssertEqual(right.y, ButtonGlintLayout.y, accuracy: 1e-6)
        }
    }

    /// **The H0 margin.** A glint is a persistent entity (it lives for the whole session at opacity 0), so
    /// unlike the box scan it cannot buy itself a timed exemption: its whole 6 mm plane has to be outside
    /// the audited prism, on both edges, for every key.
    func testEveryGlintClearsTheFootprintPrism() {
        for edge in ButtonGlintLayout.Edge.allCases {
            for key in ButtonGlintLayout.Key.allCases {
                let p = ButtonGlintLayout.position(key, edge: edge, footprint: footprint)
                XCTAssertFalse(footprint.contains(p), "\(edge.rawValue) \(key.rawValue) is inside the prism")
                XCTAssertEqual(abs(p.x), footprint.half.x + ButtonGlintLayout.clearance, accuracy: 1e-6)
                // The plane's own inner edge clears it too.
                let inner = abs(p.x) - ButtonGlintLayout.size / 2
                XCTAssertGreaterThanOrEqual(inner, footprint.half.x - 1e-6,
                                            "the \(ButtonGlintLayout.size * 1000) mm plane reaches into the prism")
            }
        }
    }

    /// A bigger device moves the glints out with it, because the margin is measured from the footprint.
    func testTheGlintsFollowTheMeasuredDevice() {
        let wide = DeviceFootprint(size: [0.080, 0.095])
        let p = ButtonGlintLayout.position(.ok, edge: .plusX, footprint: wide)
        XCTAssertEqual(p.x, wide.half.x + ButtonGlintLayout.clearance, accuracy: 1e-6)
        XCTAssertGreaterThan(p.x, ButtonGlintLayout.position(.ok, edge: .plusX, footprint: footprint).x)
    }

    func testTheLogSaysWhichKeyAndWhichEdge() {
        XCTAssertEqual(ButtonGlintLayout.logSuffix(.down, edge: .plusX), "down (+x, z +20 mm)")
        XCTAssertEqual(ButtonGlintLayout.logSuffix(.up, edge: .minusX), "up (-x, z -20 mm)")
        XCTAssertEqual(ButtonGlintLayout.logSuffix(.ok, edge: .plusX), "ok (+x, z +0 mm)")
    }
}
