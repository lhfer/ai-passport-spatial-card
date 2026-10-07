import XCTest
import simd

/// V3-1b P0: **which frame the gravity snap is applied in**.
///
/// The V3-1 headset trial spent its entire session in `carrying(notFlat)` with the passport lying on a desk. The
/// Σ line said why in two fields: `tilt=90.0° objTilt=3.7°` — the raw screen pose was flat and the *presented*
/// one was vertical. `CardTracker` was computing `gravityAligned(rawPose) * offset`, and `gravityAligned` forces
/// its input's +Y straight up. On the headset's Z-thin bounding box the object's +Y is the 95 mm long axis, so
/// that stood the device on end and the offset then laid the screen frame out horizontally.
///
/// These are the assertions that would have failed before the fix.
final class DeskSnapTests: XCTestCase {
    private let deg: Float = .pi / 180

    /// The box the headset reports: 60 × 95 × 8.5 mm, thin axis **Z**.
    private var headsetFrame: ObjectScreenFrame { ObjectScreenFrame(box: .aiPassportHeadset) }

    /// A pose from a position and a rotation.
    private func pose(_ position: SIMD3<Float>, _ rotation: simd_quatf) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        return m
    }

    /// A device lying on a desk, heading 37°, reported by a tracker that is 20° out in pitch and roll.
    ///
    /// The error is applied **in the screen's own frame** — a pitch about its X and a roll about its Z, which is
    /// what a tracker's orientation error on a flat slab is. Composed in that order it leaves the long edge's
    /// heading alone, so "the same heading survives the snap" is a statement about `gravityAligned` rather than
    /// about the error model. 14.1° of each is 19.8° of tilt.
    private func flatScreenPoseWithTrackerError(headingDegrees: Float = 37,
                                                pitchDegrees: Float = 14.1,
                                                rollDegrees: Float = 14.1) -> simd_float4x4 {
        let heading = simd_quatf(angle: headingDegrees * deg, axis: [0, 1, 0])
        let pitch = simd_quatf(angle: pitchDegrees * deg, axis: [1, 0, 0])
        let roll = simd_quatf(angle: rollDegrees * deg, axis: [0, 0, 1])
        return pose([0.12, 1.05, -0.62], heading * pitch * roll)
    }

    /// The box really is Z-thin, and the offset really does swap the axes: this is the premise of everything below.
    func testTheHeadsetBoxIsZThin() {
        XCTAssertEqual(headsetFrame.axis, .z)
        XCTAssertEqual(headsetFrame.readerAxis, .y)
    }

    /// **The fix.** Align the pose that is already in the screen frame: flat, the same heading, the same origin.
    func testGravityAlignedAfterTheOffsetIsFlatAndKeepsTheHeading() {
        let screen = flatScreenPoseWithTrackerError()
        XCTAssertEqual(PresenceGate.tilt(of: screen) / deg, 19.8, accuracy: 0.3, "the tracker really is ~20° out")
        let offset = headsetFrame.offset
        let rawObject = screen * offset.inverse

        let snapped = TrackingFusion.gravityAligned(rawObject * offset)
        XCTAssertLessThan(PresenceGate.tilt(of: snapped) / deg, 0.5, "the card lies flat on the desk")
        XCTAssertEqual(TrackingFusion.yaw(of: snapped) / deg, 37, accuracy: 0.5, "and still faces the same way")

        let origin = ObjectScreenCalibration.translation(of: snapped)
        let rawOrigin = ObjectScreenCalibration.translation(of: screen)
        XCTAssertLessThan(simd_length(origin - rawOrigin), 0.002, "within 2 mm of the raw screen origin")
    }

    /// **What V3-1 did.** Kept here as an assertion rather than a comment: the old expression puts the card on
    /// its edge on the headset's box, which is the 90° the trial log printed for a whole session.
    func testTheOldExpressionStandsTheCardOnItsEdge() {
        let screen = flatScreenPoseWithTrackerError()
        let offset = headsetFrame.offset
        let rawObject = screen * offset.inverse

        let v31 = TrackingFusion.gravityAligned(rawObject) * offset
        XCTAssertEqual(PresenceGate.tilt(of: v31) / deg, 90, accuracy: 0.5,
                       "V3-1: `gravityAligned(rawPose) * offset` — tilt=90.0° next to objTilt=3.7°")
    }

    /// The Y-thin scan box is the case the old expression was written for, and it still works there — which is
    /// exactly why the bug survived the simulator: every `--fake-track` run used that box.
    func testTheOldExpressionWasRightForTheYThinScanBox() {
        let screen = flatScreenPoseWithTrackerError()
        let frame = ObjectScreenFrame(box: .aiPassport)
        XCTAssertEqual(frame.axis, .y)
        let rawObject = screen * frame.offset.inverse

        XCTAssertLessThan(PresenceGate.tilt(of: TrackingFusion.gravityAligned(rawObject) * frame.offset) / deg, 0.5)
        XCTAssertLessThan(PresenceGate.tilt(of: TrackingFusion.gravityAligned(rawObject * frame.offset)) / deg, 0.5)
    }

    /// The price of aligning after the offset: the frame's own lever arm (half the 8.5 mm thickness) now turns
    /// with the tracker's pitch/roll instead of with an already-flattened frame.
    ///
    /// Modelled the way the error really arrives: the tracker localises the object's **origin** well (0.3 mm at
    /// rest on the headset) and its *orientation* badly, so the object pose keeps the true translation and gets
    /// 19.8° of pitch and roll on its rotation. Mapping that through the offset swings the screen origin by
    /// |(I − R_error)·t| with |t| = 4.25 mm — about 1 mm here, and 1.5 mm at the worst 20° the headset produced.
    /// Three orders of magnitude cheaper than the 90° the old expression cost.
    func testTheLeverArmCostsUnderTwoMillimetres() {
        let offset = headsetFrame.offset
        let truth = pose([0.12, 1.05, -0.62], simd_quatf(angle: 37 * deg, axis: [0, 1, 0]))
        let trueObject = truth * offset.inverse

        let error = simd_quatf(angle: 14.1 * deg, axis: [1, 0, 0]) * simd_quatf(angle: 14.1 * deg, axis: [0, 0, 1])
        var objectPose = simd_float4x4(PresenceGate.rotation(of: trueObject) * error)
        objectPose.columns.3 = trueObject.columns.3      // the origin the tracker gets right

        let snapped = TrackingFusion.gravityAligned(objectPose * offset)
        XCTAssertLessThan(PresenceGate.tilt(of: snapped) / deg, 0.5, "still flat")
        let drift = simd_length(ObjectScreenCalibration.translation(of: snapped)
                                - ObjectScreenCalibration.translation(of: truth))
        XCTAssertGreaterThan(drift, 0.0005, "the lever arm is real: the origin does move")
        XCTAssertLessThan(drift, 0.002, "…and it costs under 2 mm")
    }
}
