import XCTest
import simd

/// **v4 B2 §3.2 — a loss that can explain itself.** `[track] in view but untracked …` (the last pose inside the head's
/// view cone, nearer than 1.2 m, no tracked object observation for more than 1 s; again every 5 s; one line when it
/// ends) and the desk / hand segment summaries.
final class V4TrackingWatchTests: XCTestCase {
    private typealias Watch = V4.TrackingWatch

    /// A head at 1.6 m looking straight down −Z (the simulator's stand-in reader, and every seated wearer's default).
    private let head = simd_float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                     SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, 1.6, 0, 1))

    private func pose(_ p: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(p.x, p.y, p.z, 1)
        return m
    }

    private func context(lastTracked: TimeInterval?, at p: SIMD3<Float> = [0, 1.2, -0.6],
                         paused: Bool = false) -> Watch.Context {
        Watch.Context(head: head, lastPose: pose(p), lastTracked: lastTracked, handDistance: 0.09,
                      strip: nil, backlight: 100, paused: paused)
    }

    // MARK: The view cone

    func testADeviceOnTheDeskInFrontIsInView() {
        // 0.6 m ahead, 0.4 m below the eyes: 0.72 m away, 34° off the gaze.
        let g = Watch.geometry(head: head, pose: pose([0, 1.2, -0.6]))!
        XCTAssertEqual(g.distance, 0.721, accuracy: 0.001)
        XCTAssertEqual(g.angle * 180 / .pi, 33.7, accuracy: 0.1)
        XCTAssertTrue(Watch.isInView(head: head, pose: pose([0, 1.2, -0.6])))
    }

    func testTooFarOrTooFarOffTheGazeIsNotInView() {
        XCTAssertFalse(Watch.isInView(head: head, pose: pose([0, 1.6, -1.3])), "1.3 m is past 1.2 m")
        XCTAssertFalse(Watch.isInView(head: head, pose: pose([0.6, 1.6, 0])), "90° to the side")
        XCTAssertFalse(Watch.isInView(head: head, pose: pose([0, 0.9, -0.3])), "67° below the gaze")
        XCTAssertFalse(Watch.isInView(head: nil, pose: pose([0, 1.2, -0.6])), "no head, no claim")
    }

    // MARK: In view but untracked

    func testNothingUntilASecondHasPassedThenOneLineEveryFiveSeconds() {
        var watch = Watch()
        XCTAssertTrue(watch.tick(context(lastTracked: 10), at: 10.5).isEmpty)
        XCTAssertTrue(watch.tick(context(lastTracked: 10), at: 11.0).isEmpty, "exactly 1 s is not more than 1 s")
        let first = watch.tick(context(lastTracked: 10), at: 11.06)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].hasPrefix("[track] in view but untracked 1.1 s (dist 0.72 m, angle 34°, normal 56°, hand 9 cm, strip followers, bl 100 %)"),
                      first[0])
        XCTAssertTrue(watch.tick(context(lastTracked: 10), at: 13).isEmpty)
        XCTAssertTrue(watch.tick(context(lastTracked: 10), at: 16.0).isEmpty)
        let second = watch.tick(context(lastTracked: 10), at: 16.1)
        XCTAssertEqual(second.count, 1)
        XCTAssertTrue(second[0].contains("untracked 6.1 s"), second[0])
    }

    /// Found again: one line with the total, measured from the last tracked observation to the next one.
    func testTheEndSaysHowLongItLasted() {
        var watch = Watch()
        _ = watch.tick(context(lastTracked: 10), at: 11.5)
        let end = watch.tick(context(lastTracked: 17.3), at: 17.35)
        XCTAssertEqual(end, ["[track] in view but untracked ended after 7.3 s (tracked again)"])
        XCTAssertTrue(watch.tick(context(lastTracked: 17.3), at: 17.4).isEmpty, "and it is over")
    }

    func testTurningAwayOrAWorldEndsItTooAndSaysSo() {
        var away = Watch()
        _ = away.tick(context(lastTracked: 10), at: 11.5)
        XCTAssertEqual(away.tick(context(lastTracked: 10, at: [0.6, 1.6, 0]), at: 14),
                       ["[track] in view but untracked ended after 4.0 s (out of view)"])
        var world = Watch()
        _ = world.tick(context(lastTracked: 10), at: 11.5)
        XCTAssertEqual(world.tick(context(lastTracked: 10, paused: true), at: 12),
                       ["[track] in view but untracked ended after 2.0 s (a world paused the tracker)"])
    }

    /// A world holds the tracker paused: the stream is off, not lost — nothing to explain.
    func testAPausedTrackerIsNeverReported() {
        var watch = Watch()
        XCTAssertTrue(watch.tick(context(lastTracked: 10, paused: true), at: 30).isEmpty)
        XCTAssertTrue(watch.tick(context(lastTracked: nil), at: 30).isEmpty, "never tracked: nothing to have lost")
    }

    /// Out of view it says nothing at all: the camera is not expected to see it.
    func testOutOfViewIsSilent() {
        var watch = Watch()
        XCTAssertTrue(watch.tick(context(lastTracked: 10, at: [0, 1.6, -2]), at: 20).isEmpty)
    }

    // MARK: Segments

    func testASegmentSaysItsTrackedShareRateSamplesAndLosses() {
        var watch = Watch()
        XCTAssertNil(watch.enter(.desk, at: 0))
        // 2 s tracked at 30 Hz, a 1.5 s hole, 1.5 s tracked again, and three untracked observations in the hole.
        for i in 0..<60 { watch.observe(tracked: true, at: Double(i) / 30) }
        for u in [2.2, 2.6, 3.0] { watch.observe(tracked: false, at: u) }
        for i in 0..<45 { watch.observe(tracked: true, at: 3.5 + Double(i) / 30) }
        let summary = watch.enter(.hand, at: 5.0)!
        XCTAssertTrue(summary.hasPrefix("[track] segment desk 5.0 s: objTracked 97 %, obj 21.0/s (1 s samples 0–30), 1 loss (re-found in 1.5 s)"),
                      summary)
        XCTAssertEqual(watch.segment, .hand)
    }

    /// The round-1 shape: put down, lost 1.2 s later and never found again on the desk.
    func testASegmentThatEndsLostSaysSo() {
        var watch = Watch()
        _ = watch.enter(.desk, at: 0)
        for i in 0..<36 { watch.observe(tracked: true, at: Double(i) / 30) }
        let summary = watch.enter(.hand, at: 58.8)!
        XCTAssertTrue(summary.contains("0 losses"), summary)
        XCTAssertTrue(summary.hasSuffix("untracked for the last 57.6 s"), summary)
    }

    func testTheSameSegmentAgainIsNotAnEnd() {
        var watch = Watch()
        XCTAssertNil(watch.enter(.hand, at: 0))
        XCTAssertNil(watch.enter(.hand, at: 3))
        XCTAssertNotNil(watch.finish(at: 5))
        XCTAssertNil(watch.segment)
    }

    func testWhichSegmentAPresenceBelongsTo() {
        XCTAssertEqual(Watch.segment(carrying: true, resting: false, held: false, world: false, current: .desk), .hand)
        XCTAssertEqual(Watch.segment(carrying: false, resting: true, held: false, world: false, current: .hand), .desk)
        XCTAssertEqual(Watch.segment(carrying: false, resting: false, held: true, world: false, current: .desk), .desk,
                       "a hold stays in the segment it froze in")
        XCTAssertNil(Watch.segment(carrying: false, resting: false, held: true, world: true, current: .desk),
                     "a world: the stream is off, not lost")
        XCTAssertNil(Watch.segment(carrying: false, resting: false, held: false, world: false, current: .desk), "absent")
    }

    // MARK: v4 B4 §4 — how the device was seen

    /// `normal`: the line of sight off the screen's normal. A passport lying flat 0.6 m ahead and 0.4 m below the eyes
    /// is seen 56° off its normal; turned to face the eyes, 0°; edge-on, 90°.
    func testTheViewAngleIsTheLineOfSightOffTheScreensNormal() {
        let flat = pose([0, 1.2, -0.6])
        XCTAssertEqual(Watch.viewAngle(head: head, pose: flat)! * 180 / .pi, 56.3, accuracy: 0.1)
        // Turned so its +Y points at the eye.
        let toEye = simd_normalize(SIMD3<Float>(0, 0.4, 0.6))
        var facing = simd_float4x4(simd_quatf(from: [0, 1, 0], to: toEye))
        facing.columns.3 = SIMD4<Float>(0, 1.2, -0.6, 1)
        XCTAssertEqual(Watch.viewAngle(head: head, pose: facing)! * 180 / .pi, 0, accuracy: 0.1)
        // Edge-on: its normal across the line of sight.
        var edge = simd_float4x4(simd_quatf(angle: .pi / 2, axis: [0, 0, 1]))
        edge.columns.3 = SIMD4<Float>(0, 1.6, -0.6, 1)
        XCTAssertEqual(Watch.viewAngle(head: head, pose: edge)! * 180 / .pi, 90, accuracy: 0.1)
        XCTAssertNil(Watch.viewAngle(head: nil, pose: flat))
        let both = Watch.angles(head: head, pose: flat)!
        XCTAssertEqual(both.offGaze * 180 / .pi, 33.7, accuracy: 0.1)
        XCTAssertEqual(both.offNormal * 180 / .pi, 56.3, accuracy: 0.1)
    }

    /// The segment's summary gives both angles at the moment of each loss (the last tracked observation before the gap),
    /// averaged — the trailing loss included.
    func testTheSegmentSummaryGivesTheAnglesAtTheLosses() {
        var watch = Watch()
        _ = watch.enter(.desk, at: 0)
        let a = Watch.Angles(offGaze: 20 * .pi / 180, offNormal: 60 * .pi / 180)
        let b = Watch.Angles(offGaze: 40 * .pi / 180, offNormal: 70 * .pi / 180)
        var t: TimeInterval = 0
        while t < 2 { watch.observe(tracked: true, at: t, angles: a); t += 1.0 / 30 }
        // Lost for 1 s, found again with a different view, then lost for good.
        t = 3
        while t < 4 { watch.observe(tracked: true, at: t, angles: b); t += 1.0 / 30 }
        let summary = watch.enter(.hand, at: 6)!
        XCTAssertTrue(summary.contains("1 loss (re-found in 1.0 s)"), summary)
        XCTAssertTrue(summary.contains("untracked for the last 2.0 s"), summary)
        XCTAssertTrue(summary.hasSuffix("at the losses (avg): angle 30°, normal 65°"), summary)
        // No loss, no angles.
        var quiet = Watch()
        _ = quiet.enter(.desk, at: 0)
        quiet.observe(tracked: true, at: 0.5, angles: a)
        XCTAssertFalse(quiet.enter(nil, at: 0.6)!.contains("at the loss"))
    }
}
