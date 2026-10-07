import XCTest
import simd

/// **V3-4 §1.** The edge wave's geometry and its clock: where the 24 segments stand (H0 — outside the prism,
/// every one of them, including the corners), where a key sits on the contour, and that the light really does
/// leave the key in both directions and meet on the far side.
final class ButtonWaveTests: XCTestCase {
    private let footprint = DeviceFootprint.aiPassport

    func testTheRingIsOutsideTheAuditedPrism() {
        let h = ButtonWaveLayout.halfExtent(footprint)
        // The centre line is the prism plus the gap plus half a segment's width …
        XCTAssertEqual(h.x, footprint.half.x + ButtonWaveLayout.gap + ButtonWaveLayout.segmentWidth / 2, accuracy: 1e-6)
        XCTAssertEqual(h.y, footprint.half.y + ButtonWaveLayout.gap + ButtonWaveLayout.segmentWidth / 2, accuracy: 1e-6)
        // … so every segment's own inner edge clears the prism by exactly the gap.
        for segment in ButtonWaveLayout.segments(footprint: footprint) {
            XCTAssertFalse(footprint.contains(segment.position),
                           "segment at \(segment.position) is inside the prism")
            let inset = min(h.x - abs(segment.position.x), h.y - abs(segment.position.z))
            XCTAssertLessThanOrEqual(inset, ButtonWaveLayout.cornerRadius + 1e-6)
        }
    }

    /// The whole 14 × 6 mm rectangle, not just its centre: a segment at a corner is rotated 45° and its
    /// bounding box reaches further in than its centre does.
    func testEverySegmentsWholeRectangleClearsThePrism() {
        for segment in ButtonWaveLayout.segments(footprint: footprint) {
            let rotation = simd_quatf(angle: segment.yaw, axis: [0, 1, 0])
            let halfLength = ButtonWaveLayout.segmentLength / 2, halfWidth = ButtonWaveLayout.segmentWidth / 2
            for sx in [-halfLength, halfLength] {
                for sz in [-halfWidth, halfWidth] {
                    let corner = segment.position + rotation.act(SIMD3<Float>(sx, 0, sz))
                    XCTAssertFalse(footprint.contains(corner),
                                   "a corner of the segment at arc \(segment.arc) reaches into the prism")
                }
            }
        }
    }

    func testTheSegmentsAreEvenlySpacedRoundTheWholeContour() {
        let segments = ButtonWaveLayout.segments(footprint: footprint)
        XCTAssertEqual(segments.count, ButtonWaveLayout.segmentCount)
        let step = ButtonWaveLayout.perimeter(footprint) / Float(segments.count)
        for (index, segment) in segments.enumerated() {
            XCTAssertEqual(segment.arc, (Float(index) + 0.5) * step, accuracy: 1e-5)
        }
        // A step of 15.9 mm on this device, which a 14 mm segment does not quite close: the ring is dashed
        // on purpose, so the wave reads as light running round rather than as a ring switching on.
        XCTAssertGreaterThan(step, ButtonWaveLayout.segmentLength)
    }

    /// The contour is closed: walking one perimeter comes back to the same point.
    func testTheContourIsClosed() {
        let total = ButtonWaveLayout.perimeter(footprint)
        let a = ButtonWaveLayout.point(atArc: 0.017, footprint: footprint)
        let b = ButtonWaveLayout.point(atArc: 0.017 + total, footprint: footprint)
        XCTAssertEqual(simd_distance(a.position, b.position), 0, accuracy: 1e-5)
    }

    /// Every key is on the long side the flag names, and mirroring the flag mirrors its arc about the
    /// contour — the wave has to start under the thumb whichever side the keys turn out to be on.
    func testTheKeySitsOnTheEdgeTheFlagNames() {
        for key in ButtonGlintLayout.Key.allCases {
            let right = ButtonWaveLayout.keyArc(key, edge: .plusX, footprint: footprint)
            let left = ButtonWaveLayout.keyArc(key, edge: .minusX, footprint: footprint)
            let onRight = ButtonWaveLayout.point(atArc: right, footprint: footprint).position
            let onLeft = ButtonWaveLayout.point(atArc: left, footprint: footprint).position
            XCTAssertGreaterThan(onRight.x, 0)
            XCTAssertLessThan(onLeft.x, 0)
            XCTAssertEqual(onRight.z, key.z, accuracy: 1e-5)
            XCTAssertEqual(onLeft.z, key.z, accuracy: 1e-5)
            XCTAssertEqual(onRight.x, -onLeft.x, accuracy: 1e-5)
        }
    }

    /// Two wavefronts: the delay grows away from the key in both directions and peaks, for exactly one
    /// segment or two, at the meet time on the far side.
    func testTheWaveLeavesTheKeyBothWaysAndMeetsOpposite() {
        let delays = ButtonWaveLayout.delays(footprint: footprint, key: .ok, edge: .plusX)
        XCTAssertEqual(delays.count, ButtonWaveLayout.segmentCount)
        let meet = ButtonWaveLayout.meetSeconds(footprint)
        XCTAssertEqual(delays.max() ?? 0, meet, accuracy: meet / Float(ButtonWaveLayout.segmentCount))
        XCTAssertLessThan(delays.min() ?? 1, meet / 4)
        for delay in delays {
            XCTAssertGreaterThanOrEqual(delay, 0)
            XCTAssertLessThanOrEqual(delay, meet + 1e-5)
        }
        // The nearest segment to the key is on the key's own side of the device.
        guard let nearest = delays.firstIndex(of: delays.min() ?? 0) else { return XCTFail("no delays") }
        XCTAssertGreaterThan(ButtonWaveLayout.segments(footprint: footprint)[nearest].position.x, 0)
    }

    /// The three keys are 20 mm apart along the same straight run, so their waves are 20 ms apart at 1 m/s.
    func testTheThreeKeysStartFromThreeDifferentPlaces() {
        let up = ButtonWaveLayout.keyArc(.up, edge: .plusX, footprint: footprint)
        let ok = ButtonWaveLayout.keyArc(.ok, edge: .plusX, footprint: footprint)
        let down = ButtonWaveLayout.keyArc(.down, edge: .plusX, footprint: footprint)
        XCTAssertEqual(ok - up, 0.020, accuracy: 1e-5)
        XCTAssertEqual(down - ok, 0.020, accuracy: 1e-5)
    }

    /// A bigger device grows the ring with it, and the wave takes correspondingly longer to go round.
    func testTheRingFollowsTheMeasuredDevice() {
        let wide = DeviceFootprint(size: [0.080, 0.120])
        XCTAssertGreaterThan(ButtonWaveLayout.perimeter(wide), ButtonWaveLayout.perimeter(footprint))
        XCTAssertGreaterThan(ButtonWaveLayout.meetSeconds(wide), ButtonWaveLayout.meetSeconds(footprint))
        for segment in ButtonWaveLayout.segments(footprint: wide) {
            XCTAssertFalse(wide.contains(segment.position))
        }
    }

    // MARK: - V3-5 §3: the audit finding, and the probe that answers it

    /// **The false positive itself, as an assertion.** The second headset round reported
    /// `[footprint] buttonWave.11 / .18 inside for 2–3 s`. This pins both halves of why:
    ///
    /// 1. segments **6, 11, 18 and 23** are the four *corner* segments, and they are the only four whose
    ///    axis-aligned bounds — the only thing `visualBounds` can give the auditor — reach into the prism;
    /// 2. not one of them is *actually* inside: every corner of every rotated rectangle is outside.
    ///
    /// So the finding was the bounding box, not the geometry, and the fix is to judge the corners
    /// (`ButtonWaveLayout.localCorners`, which the rig hands to `FootprintProbeComponent.points`).
    func testOnlyTheCornerSegmentsAxisAlignedBoundsCrossThePrism() {
        // The finding is the headset's, on the box its object anchor reports (60 × 95 mm) — which is still the
        // footprint on the headset (the anchor's box overrides the ruler default, `DeviceFootprint.aiPassport`, that
        // v4 B1 moved to 60 × 96). On 96 mm the ring's 24 segments shift and only 11 / 23 have oversized boxes.
        let footprint = DeviceFootprint(size: [0.060, 0.095])
        let segments = ButtonWaveLayout.segments(footprint: footprint)
        var crossing: [Int] = []
        for (index, segment) in segments.enumerated() {
            let box = ButtonWaveLayout.bounds(of: segment)
            if footprint.intersects(min: box.min, max: box.max) { crossing.append(index) }
            for corner in ButtonWaveLayout.corners(of: segment) {
                XCTAssertFalse(footprint.contains(corner),
                               "segment \(index) really is inside the prism — this is not a bounding-box artefact")
            }
        }
        XCTAssertEqual(crossing, [6, 11, 18, 23],
                       "the headset reported buttonWave.11 and .18; both are corner segments")
        // …and the corners are where the contour turns, which is what makes their boxes ±5 mm too big.
        for index in crossing {
            let yaw = abs(segments[index].yaw) * 180 / .pi
            XCTAssertGreaterThan(min(yaw, 180 - yaw), 20,
                                 "segment \(index) is not lying along an axis, so its AABB is oversized")
        }
    }

    /// The four points the rig hands the auditor are the rectangle's own corners, in its own space — an
    /// exact test of the rotated rectangle, not an exemption.
    func testTheProbePointsAreTheSegmentsOwnFourCorners() {
        XCTAssertEqual(ButtonWaveLayout.localCorners.count, 4)
        for point in ButtonWaveLayout.localCorners {
            XCTAssertEqual(abs(point.x), ButtonWaveLayout.segmentLength / 2, accuracy: 1e-7)
            XCTAssertEqual(point.y, 0, accuracy: 1e-7)
            XCTAssertEqual(abs(point.z), ButtonWaveLayout.segmentWidth / 2, accuracy: 1e-7)
        }
        let segment = ButtonWaveLayout.segments(footprint: footprint)[11]
        let rotation = simd_quatf(angle: segment.yaw, axis: [0, 1, 0])
        for (point, corner) in zip(ButtonWaveLayout.localCorners, ButtonWaveLayout.corners(of: segment)) {
            XCTAssertEqual(simd_distance(segment.position + rotation.act(point), corner), 0, accuracy: 1e-6)
        }
    }

    /// **The second candidate cause, ruled out.** A wave that ends at some small non-zero opacity would be
    /// reported by the auditor for ever (it only skips alpha ≤ 0.02). The envelope returns nil the instant
    /// the fall is over, and nil is what makes `WaveSegmentSystem` write exactly 0 and drop the component.
    func testTheEnvelopeEndsAtExactlyZeroAndNeverExceedsThePeak() {
        let rise = ButtonWaveLayout.rise, hold = ButtonWaveLayout.hold, fall = ButtonWaveLayout.fall
        let total = rise + hold + fall
        var sawPeak = false
        for k in 0...400 {
            let t = Float(k) / 400 * total
            guard let value = ButtonWaveLayout.envelope(t: t, rise: rise, hold: hold, fall: fall, peak: 1) else {
                XCTAssertGreaterThanOrEqual(t, total - 1e-4, "the wave went dark at \(t) s, before its fall was over")
                continue
            }
            XCTAssertGreaterThanOrEqual(value, 0)
            XCTAssertLessThanOrEqual(value, 1 + 1e-5)
            if value > 0.999 { sawPeak = true }
        }
        XCTAssertTrue(sawPeak, "the wave never reached its peak")
        XCTAssertEqual(ButtonWaveLayout.envelope(t: -0.01, rise: rise, hold: hold, fall: fall, peak: 1), 0)
        XCTAssertNil(ButtonWaveLayout.envelope(t: total, rise: rise, hold: hold, fall: fall, peak: 1))
        XCTAssertNil(ButtonWaveLayout.envelope(t: total + 5, rise: rise, hold: hold, fall: fall, peak: 1))
    }

    func testTheLogSaysWhichKeyHowManySegmentsAndWhenTheyMeet() {
        let line = ButtonWaveLayout.logSuffix(.down, edge: .plusX, footprint: footprint)
        XCTAssertTrue(line.hasPrefix("down (+x, z +20 mm, 24 segments, meet at "), line)
        XCTAssertTrue(line.hasSuffix(" s)"), line)
    }
}
