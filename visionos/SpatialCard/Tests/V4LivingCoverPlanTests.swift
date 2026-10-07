import XCTest
import simd

/// **A3 目标 2.** The living cover's decisions: which modes a request tries, what counts as a liftable subject, and
/// the lift's geometry staying inside the brief's numbers.
final class V4LivingCoverPlanTests: XCTestCase {
    typealias Stats = V4.CoverMaskStats

    /// `auto` tries the spatial scene first until the device has shown it cannot generate one; an explicit mode
    /// never swaps itself for another (except lift → flat, which is what "no subject" means).
    func testPlannerOrder() {
        var caps = V4.CoverCapabilities()
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .auto, capabilities: caps), [.scene, .lift, .flat])
        caps.scene = .unavailable("unableToGenerateSpatial3DImage")
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .auto, capabilities: caps), [.lift, .flat])
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .scene, capabilities: caps), [.scene])
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .lift, capabilities: caps), [.lift, .flat])
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .flat, capabilities: caps), [.flat])
        caps.scene = .available
        XCTAssertEqual(V4.CoverPlanner.attempts(for: .auto, capabilities: caps), [.scene, .lift, .flat])
        XCTAssertEqual(V4.CoverRequest(argument: "lift"), .lift)
        XCTAssertEqual(V4.CoverRequest(argument: "nonsense"), .auto)
        XCTAssertEqual(V4.CoverRequest(argument: nil), .auto)
    }

    /// A centred blob is a subject; the numbers match a hand count.
    func testCentredSubjectIsLifted() {
        let (w, h) = (40, 50)
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 20..<40 { for x in 10..<30 { mask[y * w + x] = 255 } }
        let stats = Stats.measure(mask, width: w, height: h)
        XCTAssertEqual(stats.coverage, Float(20 * 20) / Float(w * h), accuracy: 1e-6)
        XCTAssertEqual(stats.bounds, SIMD4<Float>(10 / 40, 20 / 50, 30 / 40, 40 / 50))
        XCTAssertEqual(stats.edgeContact, .zero)
        XCTAssertEqual(stats.verdict(), .lift)
    }

    /// The fake covers' diagonal light band (Vision's pick on covers 1 and 2): 12.6 % coverage, touching the left
    /// and right edges — not a subject.
    func testBandAcrossTheFrameIsRejected() {
        let (w, h) = (48, 62)
        var mask = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            let centre = 40 - x * 20 / w
            for y in max(0, centre - 4)..<min(h, centre + 4) { mask[y * w + x] = 255 }
        }
        let stats = Stats.measure(mask, width: w, height: h)
        XCTAssertGreaterThan(stats.edgeContact[0], 0.05)
        XCTAssertGreaterThan(stats.edgeContact[1], 0.05)
        XCTAssertEqual(stats.verdict(), .spansFrame)
    }

    /// A portrait cut by the bottom edge (the avatar, a parrot) touches one edge only: still a subject. A subject
    /// that fills the frame (an owl at 91 %) is not worth lifting, and neither is a speck or nothing at all.
    func testEdgeCasesOfTheVerdict() {
        let (w, h) = (40, 40)
        var portrait = [UInt8](repeating: 0, count: w * h)
        for y in 15..<40 { for x in 8..<32 { portrait[y * w + x] = 255 } }
        XCTAssertEqual(Stats.measure(portrait, width: w, height: h).verdict(), .lift)

        let full = [UInt8](repeating: 255, count: w * h)
        XCTAssertEqual(Stats.measure(full, width: w, height: h).verdict(), .tooLarge)

        var speck = [UInt8](repeating: 0, count: w * h)
        speck[20 * w + 20] = 255
        XCTAssertEqual(Stats.measure(speck, width: w, height: h).verdict(), .tooSmall)

        XCTAssertEqual(Stats.measure([UInt8](repeating: 0, count: w * h), width: w, height: h).verdict(), .empty)
        // Below the threshold is background.
        XCTAssertEqual(Stats.measure([UInt8](repeating: 100, count: w * h), width: w, height: h).verdict(), .empty)
    }

    /// Padded rows (CVPixelBuffer bytesPerRow > width) are skipped, not read as pixels.
    func testRowPaddingIsIgnored() {
        let (w, h, stride) = (4, 3, 8)
        var mask = [UInt8](repeating: 255, count: stride * h)
        for y in 0..<h { for x in 0..<w { mask[y * stride + x] = 0 } }
        mask[1 * stride + 1] = 255
        let stats = Stats.measure(mask, width: w, height: h, rowBytes: stride)
        XCTAssertEqual(stats.coverage, 1 / 12, accuracy: 1e-6)
    }

    /// The lift stays in 8–15 mm, the background zoom in 2–8 %, the border fade covers the slide, and the shadow
    /// falls down-right.
    func testParallaxGeometry() {
        var parallax = V4.CoverParallax(size: [0.10, 0.13])
        XCTAssertEqual(parallax.clampedLift, 0.012, accuracy: 1e-6)
        XCTAssertEqual(parallax.maxSlide, 0.012 * tan(35 * Float.pi / 180), accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(parallax.backgroundZoom, 1.02)
        XCTAssertLessThanOrEqual(parallax.backgroundZoom, 1.08)
        XCTAssertGreaterThanOrEqual(parallax.borderFade * 0.10, parallax.maxSlide * 0.99)
        XCTAssertGreaterThan(parallax.shadowOffset.x, 0)
        XCTAssertLessThan(parallax.shadowOffset.y, 0)
        parallax.lift = 0.05
        XCTAssertEqual(parallax.clampedLift, 0.015, accuracy: 1e-6)
        parallax.lift = 0.001
        XCTAssertEqual(parallax.clampedLift, 0.008, accuracy: 1e-6)
    }
}
