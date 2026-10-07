import XCTest
import simd

/// **v4 B1 §1.** The case frame C and the screen frame S: one measured offset, one resolution rule, and an H0 prism
/// that is the *case* with the LCD hard zone at its real place on it.
final class V4CaseScreenFrameTests: XCTestCase {
    private typealias Offset = V4.ScreenOffset

    // MARK: - The offset

    /// tracking-and-perf §4: x = −30 + 10 + 18.36 = −1.64 mm, z = −48 + 12 + 24.48 = −11.52 mm.
    func testTheMeasuredOffsetIsTheRulerArithmetic() {
        XCTAssertEqual(Offset.measured.x, -0.00164, accuracy: 1e-6)
        XCTAssertEqual(Offset.measured.y, -0.01152, accuracy: 1e-6)
        XCTAssertEqual(Offset.caseSize, [0.060, 0.096])
        XCTAssertEqual(Offset.caseThickness, 0.008, accuracy: 1e-7)
    }

    /// The lit area is inside the case on every side, with the margins the ruler read.
    func testTheLitAreaSitsInsideTheCaseWithTheMeasuredMargins() {
        let o = Offset.measured, lcd = Offset.lcdSize, half = Offset.caseSize / 2
        let left = (o.x - lcd.x / 2) - (-half.x)
        let top = (o.y - lcd.y / 2) - (-half.y)
        XCTAssertEqual(left, Offset.lcdLeftMargin, accuracy: 1e-6)
        XCTAssertEqual(top, Offset.lcdTopMargin, accuracy: 1e-6)
        XCTAssertGreaterThan(half.x - (o.x + lcd.x / 2), 0, "right margin")
        XCTAssertGreaterThan(half.y - (o.y + lcd.y / 2), 0, "bottom margin")
    }

    /// One source: the flag wins, then a persisted value, then the ruler.
    func testResolutionIsFlagThenStoredThenMeasured() {
        let flag = SIMD2<Float>(0.001, -0.002), stored = SIMD2<Float>(-0.003, 0.004)
        XCTAssertEqual(Offset.resolve(flag: flag, stored: stored).offset, flag)
        XCTAssertEqual(Offset.resolve(flag: flag, stored: stored).source, .flag)
        XCTAssertEqual(Offset.resolve(flag: nil, stored: stored).offset, stored)
        XCTAssertEqual(Offset.resolve(flag: nil, stored: stored).source, .stored)
        XCTAssertEqual(Offset.resolve(flag: nil, stored: nil).offset, Offset.measured)
        XCTAssertEqual(Offset.resolve(flag: nil, stored: nil).source, .measured)
        // `--screen-offset 0 0` is a real value (v3's single frame), not "nothing given".
        XCTAssertEqual(Offset.resolve(flag: .zero, stored: stored).offset, .zero)
        // Garbage never becomes the offset.
        XCTAssertEqual(Offset.resolve(flag: [.nan, 0], stored: nil).offset, Offset.measured)
    }

    /// C hangs off S at the offset turned round: the screen is 11.5 mm towards the lanyard, so the case centre is
    /// 11.5 mm towards the reader.
    func testTheCaseFrameIsTheOffsetTurnedRound() {
        let c = Offset.caseCenter(offset: Offset.measured)
        XCTAssertEqual(c.x, 0.00164, accuracy: 1e-6)
        XCTAssertEqual(c.y, 0, accuracy: 1e-7)
        XCTAssertEqual(c.z, 0.01152, accuracy: 1e-6)
        XCTAssertEqual(Offset.caseCenter(offset: .zero), .zero, "zero offset = v3's single frame")
    }

    func testTheLogLineSaysWhereTheNumbersCameFrom() {
        let line = Offset.describe(Offset.measured, source: .measured)
        XCTAssertTrue(line.hasPrefix("[obj] screen offset (x -1.64, z -11.52 mm, measured)"), line)
    }

    // MARK: - The prism is the case

    private var measuredFootprint: DeviceFootprint {
        var f = DeviceFootprint.aiPassport
        f.lcdCenter = Offset.measured
        return f
    }

    func testTheDefaultCaseIsTheRulerSize() {
        XCTAssertEqual(DeviceFootprint.aiPassport.size, [0.060, 0.096])
        XCTAssertEqual(DeviceFootprint.aiPassport.lcdCenter, .zero, "the default is v3's frame until the offset is set")
    }

    /// The LCD hard zone moved with the screen: over the real LCD is hard, over the bottom bezel (towards the reader)
    /// is not — which is exactly where v3's centred zone put 11.5 mm of screen that is not there.
    func testTheHardZoneIsOverTheRealScreen() {
        let f = measuredFootprint
        func box(_ x: Float, _ z: Float) -> (SIMD3<Float>, SIMD3<Float>) {
            ([x - 0.001, 0.001, z - 0.001], [x + 0.001, 0.003, z + 0.001])
        }
        let onScreen = box(f.lcdCenter.x, f.lcdCenter.y)
        XCTAssertTrue(f.intersectsLCD(min: onScreen.0, max: onScreen.1))
        // 20 mm towards the reader from the case centre: inside the case, below the lit area's bottom (≈ +16 mm).
        let bottomBezel = box(0, 0.020)
        XCTAssertFalse(f.intersectsLCD(min: bottomBezel.0, max: bottomBezel.1))
        XCTAssertTrue(f.intersects(min: bottomBezel.0, max: bottomBezel.1), "still the case")
        // …and the same box *was* in v3's centred hard zone.
        let v3 = DeviceFootprint.aiPassport
        XCTAssertTrue(v3.intersectsLCD(min: bottomBezel.0, max: bottomBezel.1))
    }

    /// The hinge overhang rule is measured from the *case's* top edge, and the hard zone is where it cannot reach.
    func testTheOverhangToleranceIsMeasuredFromTheCaseTopEdge() {
        let f = measuredFootprint
        XCTAssertEqual(f.topEdgeZ, -0.048, accuracy: 1e-6)
        // A 3 mm overhang over the top bezel is tolerated…
        XCTAssertTrue(f.toleratesOverhang(min: [-0.05, 0.002, -0.06], max: [0.05, 0.008, -0.045], maxDepth: 0.007))
        // …one reaching the lit area (whose top edge is 12 mm in from the case's) is not.
        XCTAssertFalse(f.toleratesOverhang(min: [-0.05, 0.002, -0.06], max: [0.05, 0.008, -0.030], maxDepth: 0.030))
    }

    // MARK: - Hollow shapes are judged where they stand

    /// The socket / edge rings hug the case: centred on the case they clear it, centred on the screen (v3's
    /// assumption) the same opening does not.
    func testARingCentredOnTheCaseClearsItAndTheSameRingOnTheScreenDoesNot() {
        let f = measuredFootprint
        let inner = SIMD2<Float>(f.size.x / 2 + 0.005, f.size.y / 2 + 0.005)
        XCTAssertTrue(f.fitsThrough(hole: inner, center: .zero))
        XCTAssertFalse(f.fitsThrough(hole: inner, center: f.lcdCenter))
        XCTAssertEqual(f.fitsThrough(hole: inner), f.fitsThrough(hole: inner, center: .zero), "v3's call is the centred case")
    }

    /// A round opening has to reach the case's farthest corner from wherever it is centred. The projector's soft
    /// base disc (69.3 mm) clears the case from the case's centre but not from the screen's — which is why the rig's
    /// clearance geometry is laid out around the case.
    func testRoundOpeningsHaveToReachTheFarthestCorner() {
        let f = measuredFootprint
        let baseDisc: Float = 0.66 * 0.21 / 2
        XCTAssertTrue(f.fitsThrough(circularHole: baseDisc, center: .zero))
        XCTAssertFalse(f.fitsThrough(circularHole: baseDisc, center: f.lcdCenter))
        // The desk halo (75 mm) stands under the screen and still clears the whole case.
        XCTAssertTrue(f.fitsThrough(circularHole: 0.075, center: f.lcdCenter))
        // v3's rule for a centred opening is the half-diagonal.
        XCTAssertTrue(f.fitsThrough(circularHole: simd_length(f.half) + 1e-5, center: .zero))
        XCTAssertFalse(f.fitsThrough(circularHole: simd_length(f.half) - 1e-4, center: .zero))
    }

    /// The edge wave is struck around the case (it lives in C): on the ruler-sized case every corner of every one of its
    /// 24 segments is still outside the prism (V3-5 §3's invariant, now on 60 × 96).
    func testTheEdgeWaveStaysOffTheRulerSizedCase() {
        let f = measuredFootprint
        for (index, segment) in ButtonWaveLayout.segments(footprint: f).enumerated() {
            for corner in ButtonWaveLayout.corners(of: segment) {
                XCTAssertFalse(f.contains(corner), "segment \(index)")
            }
        }
    }

    func testOnlyTheSlabOfAirOverTheDeviceIsProtected() {
        let f = measuredFootprint
        XCTAssertTrue(f.containsHeight(0.001))
        XCTAssertFalse(f.containsHeight(-0.3), "the desk under a passport held up is not on the passport")
        XCTAssertFalse(f.containsHeight(0.2))
    }
}
