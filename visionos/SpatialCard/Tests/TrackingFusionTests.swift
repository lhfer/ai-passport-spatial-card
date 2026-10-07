import XCTest
import simd

/// 工作包 G: the hybrid tracker's *policy* and the object→screen calibration maths, driven deterministically
/// (no ARKit, no headset, no reference object). The rest of G — the provider, the anchor stream, the Σ fields —
/// is wiring around these two value types.
final class TrackingFusionTests: XCTestCase {
    private func pose(x: Float = 0, y: Float = 0.9, z: Float = -0.5, yawDegrees: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    /// The truth the harness scripts: the screen is 2 cm forward, 0.5 cm up and 10° yawed from the object's frame.
    private var trueOffset: simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: 10 * .pi / 180, axis: [0, 1, 0]))
        m.columns.3 = SIMD4<Float>(0, 0.005, -0.02, 1)
        return m
    }

    /// The same pose with pitch / roll on top: what the object tracker reports for a device that is in fact flat.
    private func tiltedPose(x: Float = 0, y: Float = 0.9, z: Float = -0.5, yawDegrees: Float = 0,
                            pitchDegrees: Float = 0, rollDegrees: Float = 0) -> simd_float4x4 {
        let q = simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0])
            * simd_quatf(angle: pitchDegrees * .pi / 180, axis: [1, 0, 0])
            * simd_quatf(angle: rollDegrees * .pi / 180, axis: [0, 0, 1])
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    private func sample(_ pose: simd_float4x4, tracked: Bool = true, at time: TimeInterval) -> TrackingFusion.Sample {
        TrackingFusion.Sample(pose: pose, isTracked: tracked, time: time)
    }

    // MARK: - Policy

    /// The default is the image source, and it stays the image source while the object is not calibrated —
    /// however healthy the object anchor is.
    func testUncalibratedObjectNeverTakesOver() {
        var fusion = TrackingFusion()
        fusion.note(image: sample(pose(), at: 1.0))
        fusion.note(object: sample(pose(), at: 1.0))
        let decision = fusion.decide(at: 1.0)
        XCTAssertEqual(decision.source, .image)
        XCTAssertFalse(decision.switched)
    }

    /// Calibrated, tracked and fresh: the object takes over, and the decision carries its pose.
    func testCalibratedObjectTakesOver() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        fusion.note(object: sample(pose(x: 0.001), at: 1.0))
        let decision = fusion.decide(at: 1.0)
        XCTAssertEqual(decision.source, .object)
        XCTAssertTrue(decision.switched)
        XCTAssertTrue(decision.isTracked)
        XCTAssertEqual(decision.pose?.columns.3.x ?? .nan, 0.001, accuracy: 1e-6)
    }

    /// An object anchor that stopped updating hands the card back to the image source after `objectLiveWindow`
    /// (G2: 0.5 s, because the object's rate in hand dips to 5/s), and an untracked one hands it back at once.
    func testStaleOrUntrackedObjectFallsBackToImage() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        fusion.note(object: sample(pose(), at: 1.0))
        XCTAssertEqual(fusion.decide(at: 1.0).source, .object)

        fusion.note(image: sample(pose(), at: 1.45))
        XCTAssertEqual(fusion.decide(at: 1.45).source, .object, "0.45 s is still inside the object's live window")

        fusion.note(image: sample(pose(), at: 1.55))
        let back = fusion.decide(at: 1.55)
        XCTAssertEqual(back.source, .image)
        XCTAssertTrue(back.switched)

        fusion.note(object: sample(pose(), at: 1.6))
        XCTAssertEqual(fusion.decide(at: 1.6).source, .object)
        fusion.note(object: sample(pose(), tracked: false, at: 1.65))
        XCTAssertEqual(fusion.decide(at: 1.65).source, .image)
    }

    /// `--tracker image` ignores the object source entirely; `--tracker object` does not wait for the calibration.
    func testModesOverrideThePolicy() {
        var forcedImage = TrackingFusion()
        forcedImage.mode = .image
        forcedImage.calibrated = true
        forcedImage.note(image: sample(pose(), at: 1.0))
        forcedImage.note(object: sample(pose(), at: 1.0))
        XCTAssertEqual(forcedImage.decide(at: 1.0).source, .image)

        var forcedObject = TrackingFusion()
        forcedObject.mode = .object
        forcedObject.note(image: sample(pose(), at: 1.0))
        forcedObject.note(object: sample(pose(), at: 1.0))
        XCTAssertEqual(forcedObject.decide(at: 1.0).source, .object, "no calibration needed when it was asked for")

        // **v3 H1 changed this.** It used to fall back to the image the moment the object went untracked or
        // stale. In v3 `object` mode there *is* no image provider (`CardTracker.start` does not build one), so
        // falling back would hand the card to a source that never reports: the object keeps it, the untracked
        // observation is forwarded, and the gate freezes as `held(.untracked)` on that very frame instead of
        // waiting out `staleSoft` first.
        forcedObject.note(object: sample(pose(), tracked: false, at: 1.1))
        forcedObject.note(image: sample(pose(), at: 1.1))
        let lost = forcedObject.decide(at: 1.1)
        XCTAssertEqual(lost.source, .object)
        XCTAssertFalse(lost.isTracked, "…and the loss is forwarded, not swallowed")

        // Stale for a second: still the object's card.
        XCTAssertEqual(forcedObject.decide(at: 2.5).source, .object)

        // A session that begins in object mode starts *on* the object source, before any observation: the
        // button hold and the gate's acceptance policy both read it in that gap.
        var fresh = TrackingFusion()
        fresh.mode = .object
        fresh.beginSession(at: 0)
        XCTAssertEqual(fresh.source, .object)
        var hybrid = TrackingFusion()
        hybrid.beginSession(at: 0)
        XCTAssertEqual(hybrid.source, .image, "`both` is unchanged: the image starts it")
    }

    // MARK: - Disagreement veto

    /// Two live sources that disagree by more than `jumpDistance` cannot both be right, and a hand-over between
    /// them would read as the card teleporting: the old source keeps the tick and the line is logged **once**.
    func testDisagreementVetoesTheSwitchAndLogsOnce() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        fusion.note(object: sample(pose(x: 0.061), at: 1.0))

        let first = fusion.decide(at: 1.0)
        XCTAssertEqual(first.source, .image)
        XCTAssertFalse(first.switched)
        XCTAssertTrue(first.vetoed)
        XCTAssertTrue(first.logVeto)
        XCTAssertEqual(first.disagreement ?? .nan, 0.061, accuracy: 1e-5)
        XCTAssertEqual(first.pose?.columns.3.x ?? .nan, 0, accuracy: 1e-6, "the image pose still drives the card")

        fusion.note(object: sample(pose(x: 0.061), at: 1.03))
        let second = fusion.decide(at: 1.03)
        XCTAssertTrue(second.vetoed)
        XCTAssertFalse(second.logVeto, "one line per veto, not one per observation")

        // The sources agree again: the hand-over goes ahead, and the next veto may log again.
        fusion.note(object: sample(pose(x: 0.004), at: 1.06))
        let agreed = fusion.decide(at: 1.06)
        XCTAssertEqual(agreed.source, .object)
        XCTAssertTrue(agreed.switched)
        XCTAssertFalse(agreed.vetoed)
    }

    /// The veto only protects a hand-over between two *live* sources. With the image gone (the case the object
    /// tracker exists for) a disagreement is not a contradiction, it is the only information there is — vetoing
    /// would strand the card wherever the image was last seen, forever.
    func testDeadSourceNeverVetoes() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        XCTAssertEqual(fusion.decide(at: 1.0).source, .image)

        // Image untracked, object 25 cm away (the device was picked up while nobody could see the screen).
        fusion.note(image: sample(pose(), tracked: false, at: 1.05))
        fusion.note(object: sample(pose(x: 0.25), at: 1.05))
        let decision = fusion.decide(at: 1.05)
        XCTAssertEqual(decision.source, .object)
        XCTAssertTrue(decision.switched)
        XCTAssertFalse(decision.vetoed)

        // Same again in the other direction: a stale object anchor cannot veto the way back to the image.
        var stale = TrackingFusion()
        stale.calibrated = true
        stale.note(image: sample(pose(), at: 2.0))
        stale.note(object: sample(pose(), at: 2.0))
        XCTAssertEqual(stale.decide(at: 2.0).source, .object)
        stale.note(image: sample(pose(x: 0.30), at: 2.6))
        let home = stale.decide(at: 2.6)
        XCTAssertEqual(home.source, .image)
        XCTAssertFalse(home.vetoed)
    }

    /// The object source going away entirely (provider stopped, reference object refused to load) puts the card
    /// back on the image without waiting for a timeout.
    func testDropObjectReturnsToImage() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        fusion.note(object: sample(pose(), at: 1.0))
        XCTAssertEqual(fusion.decide(at: 1.0).source, .object)
        fusion.dropObject()
        XCTAssertEqual(fusion.source, .image)
        fusion.note(image: sample(pose(), at: 1.1))
        XCTAssertEqual(fusion.decide(at: 1.1).source, .image)
    }

    // MARK: - Calibration

    /// Noise-free co-observations recover the scripted offset exactly, and converge on the 30th one.
    func testCalibrationRecoversTheOffset() throws {
        var calibration = ObjectScreenCalibration()
        let offset = trueOffset
        var converged = 0
        for i in 0..<80 {
            let screen = pose(x: Float(i) * 0.0005, yawDegrees: 3)
            let object = screen * offset.inverse
            if calibration.add(objectPose: object, imagePose: screen) { converged = i + 1 }
        }
        XCTAssertEqual(converged, 60, "converges on the sample that reaches minSamples, and says so exactly once")
        XCTAssertTrue(calibration.isConverged)
        let recovered = try XCTUnwrap(calibration.offset)
        let t = ObjectScreenCalibration.translation(of: recovered)
        XCTAssertEqual(t.y, 0.005, accuracy: 1e-5)
        XCTAssertEqual(t.z, -0.02, accuracy: 1e-5)
        let (distance, angle) = PresenceGate.delta(from: trueOffset, to: recovered)
        XCTAssertEqual(distance, 0, accuracy: 1e-5)
        XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.05)
    }

    /// `screenPose = objectPose · objectToScreen` is the identity the whole fusion rests on: once calibrated, an
    /// object observation of a device lying at X lands the card exactly where the image says it is.
    func testCalibratedOffsetMapsObjectPosesOntoTheScreen() {
        var calibration = ObjectScreenCalibration()
        let offset = trueOffset
        for i in 0..<60 {
            let screen = pose(x: Float(i) * 0.001)
            calibration.add(objectPose: screen * offset.inverse, imagePose: screen)
        }
        let screen = pose(x: 0.4, yawDegrees: -25)
        let object = screen * offset.inverse
        let mapped = object * (calibration.offset ?? matrix_identity_float4x4)
        let (distance, angle) = PresenceGate.delta(from: screen, to: mapped)
        XCTAssertEqual(distance, 0, accuracy: 1e-5)
        XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.05)
    }

    /// A wandering offset means one of the two trackers is not really locked on. Sixty samples are not enough on
    /// their own: the last twenty have to agree to 6 mm, and while they do not, nothing is trusted.
    func testWanderingSamplesDoNotConverge() {
        var calibration = ObjectScreenCalibration()
        let offset = trueOffset
        for i in 0..<60 {
            let screen = pose()
            var drifting = offset
            // ±3 cm of wander, alternating: the mean is fine, the spread is not.
            drifting.columns.3.x += (i % 2 == 0 ? 0.03 : -0.03)
            calibration.add(objectPose: screen * drifting.inverse, imagePose: screen)
        }
        XCTAssertFalse(calibration.isConverged)
        XCTAssertGreaterThan(calibration.spread, 0.006)

        // It settles down: twenty quiet samples later the offset is trusted.
        for _ in 0..<20 {
            let screen = pose()
            calibration.add(objectPose: screen * offset.inverse, imagePose: screen)
        }
        XCTAssertTrue(calibration.isConverged)
        XCTAssertLessThanOrEqual(calibration.spread, 0.006)
    }

    /// A restored offset is converged from the first frame and survives the round trip through `UserDefaults`'
    /// flat float storage.
    func testRestoredCalibrationRoundTrips() throws {
        let stored = ObjectScreenCalibration.floats(trueOffset)
        XCTAssertEqual(stored.count, 16)
        let matrix = try XCTUnwrap(ObjectScreenCalibration.matrix(stored))
        let restored = ObjectScreenCalibration(restored: matrix)
        XCTAssertTrue(restored.isConverged)
        let (distance, angle) = PresenceGate.delta(from: trueOffset, to: try XCTUnwrap(restored.offset))
        XCTAssertEqual(distance, 0, accuracy: 1e-6)
        XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.01)
        XCTAssertNil(ObjectScreenCalibration.matrix([1, 2, 3]))
        XCTAssertNil(ObjectScreenCalibration.matrix(Array(repeating: Float.nan, count: 16)))
    }

    /// Why the `UserDefaults` key had to be versioned (`…objectToScreen.v2.<name>`, `CardTracker`). A record
    /// written before G2 holds a **full** rotation and a translation measured in the *raw* object frame. Restoring
    /// it keeps only the yaw — which silently moves the offset, because the discarded pitch/roll is exactly the
    /// lever arm the new mapping removes. The app is launched from the headset's home view, where `--recalibrate`
    /// cannot be typed, so an old record is discarded rather than restored.
    func testRestoringAPreG2OffsetSilentlyMovesIt() throws {
        // A pre-G2 offset: the same translation, but 15° of the object tracker's pitch baked into the rotation.
        var legacy = trueOffset
        legacy = legacy * simd_float4x4(simd_quatf(angle: 15 * .pi / 180, axis: [1, 0, 0]))
        legacy.columns.3 = trueOffset.columns.3

        let restored = ObjectScreenCalibration(restored: legacy)
        let offset = try XCTUnwrap(restored.offset)
        XCTAssertEqual(PresenceGate.tilt(of: offset) * 180 / .pi, 0, accuracy: 0.05, "restoring keeps only the yaw")
        let (_, angle) = PresenceGate.delta(from: legacy, to: offset)
        XCTAssertGreaterThan(angle * 180 / .pi, 10, "…so a pre-v2 record does not survive the round trip intact")

        // A record written by this build is a yaw already, so it does survive it exactly.
        let current = ObjectScreenCalibration(restored: trueOffset)
        let (d, a) = PresenceGate.delta(from: trueOffset, to: try XCTUnwrap(current.offset))
        XCTAssertEqual(d, 0, accuracy: 1e-6)
        XCTAssertEqual(a * 180 / .pi, 0, accuracy: 0.01)
    }

    /// Before the calibration exists the object's own bounding box places the screen: the top face of the slab,
    /// in the object's frame, with the object's own orientation.
    func testBoundingBoxFallbackSitsOnTheTopFace() {
        let offset = ObjectScreenCalibration.boundingBoxOffset(center: [0, 0, 0], extent: [0.037, 0.0085, 0.049])
        let t = ObjectScreenCalibration.translation(of: offset)
        XCTAssertEqual(t.x, 0, accuracy: 1e-6)
        XCTAssertEqual(t.y, 0.00425, accuracy: 1e-6)
        XCTAssertEqual(t.z, 0, accuracy: 1e-6)
        XCTAssertEqual(PresenceGate.rotation(of: offset).angle, 0, accuracy: 1e-5)

        // An off-centre box carries its centre through.
        let shifted = ObjectScreenCalibration.boundingBoxOffset(center: [0.01, -0.02, 0.03], extent: [0.037, 0.0085, 0.049])
        let s = ObjectScreenCalibration.translation(of: shifted)
        XCTAssertEqual(s.x, 0.01, accuracy: 1e-6)
        XCTAssertEqual(s.y, -0.02 + 0.00425, accuracy: 1e-6)
        XCTAssertEqual(s.z, 0.03, accuracy: 1e-6)
    }

    // MARK: - G2: gravity, the desk snap and the smoother

    /// A device lying on a desk is flat by definition. `gravityAligned` keeps where it is and which way it faces
    /// and throws away the rest — which is what the object tracker gets wrong (12–22° on the headset).
    func testGravityAlignedKeepsOnlyTheYaw() {
        let tilted = tiltedPose(x: 0.2, y: 1.1, z: -0.7, yawDegrees: 40, pitchDegrees: 15, rollDegrees: -9)
        XCTAssertGreaterThan(PresenceGate.tilt(of: tilted) * 180 / .pi, 10, "the input really is tilted")

        let flat = TrackingFusion.gravityAligned(tilted)
        // `tilt` is an acos near 1, where single precision is worth ≈ 0.03°: anything under a twentieth of a
        // degree is "flat" as far as `acceptTiltMax` (6°) and the desk gate (25–35°) are concerned.
        XCTAssertEqual(PresenceGate.tilt(of: flat) * 180 / .pi, 0, accuracy: 0.05, "+Y is gravity again")
        XCTAssertEqual(TrackingFusion.yaw(of: flat) * 180 / .pi, 40, accuracy: 0.5, "the heading survives")
        XCTAssertEqual(flat.columns.3.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(flat.columns.3.y, 1.1, accuracy: 1e-6)
        XCTAssertEqual(flat.columns.3.z, -0.7, accuracy: 1e-6)
    }

    /// A rotation about world +Y cannot change how far +Y is from gravity, so a yaw-only offset leaves the object
    /// anchor's own tilt exactly as ARKit reported it — which is why `Σ objTilt=` means what it says.
    func testYawOnlyOffsetDoesNotChangeTheObjectTilt() {
        let raw = tiltedPose(x: 0, y: 1, z: -1, yawDegrees: 12, pitchDegrees: 18, rollDegrees: 4)
        let mapped = raw * trueOffset
        XCTAssertEqual(PresenceGate.tilt(of: mapped), PresenceGate.tilt(of: raw), accuracy: 1e-5)
    }

    /// **V3-1b: the gate takes evidence, not just an angle** (the whole matrix is in `DeskOrientationGateTests`).
    /// The part that belongs next to the fusion is the hysteresis it hands the snap: 45° out, 35° back in, and a
    /// device resting at 40° stays wherever the gate already had it.
    func testDeskSnapHysteresis() {
        func hold(_ gate: inout DeskOrientationGate, tilt: Float, from: TimeInterval, to: TimeInterval,
                  planeBelow: Float? = 0.008) {
            var t = from
            while t <= to + 1e-9 {
                gate.update(tilt: tilt * .pi / 180, position: [0, 1.05, -0.6], planeBelow: planeBelow, at: t)
                t += 1.0 / 30
            }
        }
        var gate = DeskOrientationGate()
        XCTAssertTrue(gate.isOnDesk, "the prior is the desk: a card first seen lying on one reveals itself there")
        hold(&gate, tilt: 20, from: 0, to: 1.0)
        XCTAssertTrue(gate.isOnDesk)
        hold(&gate, tilt: 40, from: 1.0, to: 2.0)
        XCTAssertTrue(gate.isOnDesk, "past the entry angle but not past the exit angle: still the desk")
        hold(&gate, tilt: 46, from: 2.0, to: 2.5)
        XCTAssertFalse(gate.isOnDesk, "picked up")
        hold(&gate, tilt: 40, from: 2.5, to: 4.0)
        XCTAssertFalse(gate.isOnDesk, "coming back down, but not below the entry angle yet")
        hold(&gate, tilt: 24, from: 4.0, to: 4.6)
        XCTAssertTrue(gate.isOnDesk, "back on the desk — flat, still, and on a plane")

        // Stillness is not optional: the same angle while the device is moving is a device in a hand.
        var carried = DeskOrientationGate()
        hold(&carried, tilt: 70, from: 0, to: 0.5)
        XCTAssertFalse(carried.isOnDesk)
        var t: TimeInterval = 1.0
        while t <= 3.0 {
            carried.update(tilt: 24 * .pi / 180, position: [0.3 * Float(t - 1), 1.1, -0.6],
                           planeBelow: 0.008, at: t)
            t += 1.0 / 30
        }
        XCTAssertFalse(carried.isOnDesk, "flat but travelling at 0.3 m/s")
    }

    /// **v3 H1 §4: two time constants.** Position τ 0.08 s (the accurate half — the eye checks the card
    /// against the real passport under it) and rotation τ 0.20 s (the noisy half — 14–28° of object-tracker
    /// pitch/roll error, with no gravity snap to hide it once the device is in a hand). The first pose passes
    /// straight through, and a reset (a loss, a source switch, a change of frame) puts the filter back where
    /// the device actually is instead of dragging it there.
    func testObjectSmootherLowPassesPositionFasterThanRotation() {
        var smoother = ObjectPoseSmoother()
        XCTAssertEqual(smoother.tauPosition, 0.08)
        XCTAssertEqual(smoother.tauRotation, 0.20)
        let start = smoother.smooth(pose(x: 0), at: 10.0)
        XCTAssertEqual(start.columns.3.x, 0, accuracy: 1e-6, "nothing to filter against yet")

        // One *position* time constant later, 1 − e⁻¹ = 63.2 % of a 10 cm step.
        let stepped = smoother.smooth(pose(x: 0.10), at: 10.08)
        XCTAssertEqual(stepped.columns.3.x, 0.0632, accuracy: 0.002)

        // It keeps converging …
        var last = stepped.columns.3.x
        for i in 1...20 {
            last = smoother.smooth(pose(x: 0.10), at: 10.08 + Double(i) * 0.03).columns.3.x
        }
        XCTAssertEqual(last, 0.10, accuracy: 0.001)

        // … and a reset means the next pose is taken as it is.
        smoother.reset()
        let afterReset = smoother.smooth(pose(x: 0.4), at: 11.5)
        XCTAssertEqual(afterReset.columns.3.x, 0.4, accuracy: 1e-6)

        // Rotation is the slow one: after 0.08 s a 40° step is only 1 − e^(−0.4) = 33 % of the way there,
        // where the position has already covered 63 %. That gap *is* the split.
        var split = ObjectPoseSmoother()
        _ = split.smooth(pose(x: 0, yawDegrees: 0), at: 30)
        let blended = split.smooth(pose(x: 0.10, yawDegrees: 40), at: 30.08)
        XCTAssertEqual(blended.columns.3.x, 0.0632, accuracy: 0.002)
        let (_, turned) = PresenceGate.delta(from: pose(yawDegrees: 0), to: blended)
        XCTAssertEqual(turned * 180 / .pi, 40 * 0.3297, accuracy: 1.5, "33 % of the turn, not 63 %")

        // Orientation still goes the short way and lands on the target, not past it.
        var rotating = ObjectPoseSmoother()
        _ = rotating.smooth(pose(yawDegrees: -170), at: 20)
        let short = rotating.smooth(pose(yawDegrees: 170), at: 20.20)
        let (_, angleFromTarget) = PresenceGate.delta(from: short, to: pose(yawDegrees: 170))
        XCTAssertLessThan(angleFromTarget * 180 / .pi, 8, "63 % of a 20° short-arc step, not 63 % of 340°")
    }

    // MARK: - G2: yaw-only calibration

    /// The offset is measured against the object's **gravity-aligned** frame, so the object tracker's pitch/roll
    /// noise — ±12° here — never reaches the answer. Averaging the full rotation instead would both store that
    /// noise and, through the 3.6 cm lever arm, smear the translation by millimetres.
    func testCalibrationIsYawOnlyAndIgnoresObjectPitchNoise() throws {
        var calibration = ObjectScreenCalibration()
        let screen = pose(x: 0.1, yawDegrees: 25)
        let desk = pose(x: 0.1 + 0.02, y: 0.9, z: -0.5 + 0.01, yawDegrees: 15)
        for i in 0..<80 {
            // The same device, reported with alternating pitch and roll error by the object tracker.
            let wobble = simd_quatf(angle: (i % 2 == 0 ? 12 : -12) * .pi / 180, axis: [1, 0, 0])
                * simd_quatf(angle: (i % 3 == 0 ? 7 : -7) * .pi / 180, axis: [0, 0, 1])
            calibration.add(objectPose: desk * simd_float4x4(wobble), imagePose: screen)
        }
        XCTAssertTrue(calibration.isConverged)
        let recovered = try XCTUnwrap(calibration.offset)
        XCTAssertEqual(PresenceGate.tilt(of: recovered) * 180 / .pi, 0, accuracy: 0.05, "stored rotation is a yaw")

        // …and it is the *right* yaw and translation: the desk pose mapped through it lands on the screen.
        let mapped = desk * recovered
        let (distance, angle) = PresenceGate.delta(from: screen, to: mapped)
        XCTAssertEqual(distance * 1000, 0, accuracy: 0.05, "sub-0.05 mm, from samples wobbling ±12°")
        XCTAssertEqual(angle * 180 / .pi, 0, accuracy: 0.05)
    }

    /// Neither a drifted image detection nor a device in a hand describes the constant the calibration is after.
    func testCalibrationRejectsTiltedSamples() {
        var calibration = ObjectScreenCalibration()
        let flatScreen = pose()
        calibration.add(objectPose: tiltedPose(pitchDegrees: 45), imagePose: flatScreen)
        XCTAssertEqual(calibration.count, 0, "the object is in a hand (45° > 30°)")
        calibration.add(objectPose: pose(), imagePose: tiltedPose(pitchDegrees: 10))
        XCTAssertEqual(calibration.count, 0, "the image pose is tilted 10° > 6°: a drifted detection")
        XCTAssertEqual(calibration.rejected, 2)

        calibration.add(objectPose: tiltedPose(pitchDegrees: 20), imagePose: flatScreen)
        XCTAssertEqual(calibration.count, 1, "20° is a device on a desk, seen by a noisy tracker")
    }

    /// A converged offset keeps being refreshed: past `effectiveCap` the running mean drops its oldest weight for
    /// every new sample, so an offset measured during a bad minute heals instead of being outvoted forever.
    func testConvergedCalibrationKeepsHealing() throws {
        var calibration = ObjectScreenCalibration()
        let screen = pose()
        var wrong = trueOffset
        wrong.columns.3.z -= 0.03                       // 3 cm out
        for _ in 0..<60 { calibration.add(objectPose: screen * wrong.inverse, imagePose: screen) }
        XCTAssertTrue(calibration.isConverged)
        XCTAssertEqual(try XCTUnwrap(calibration.offset).columns.3.z, wrong.columns.3.z, accuracy: 1e-4)

        // The truth, from now on.
        for _ in 0..<2000 { calibration.add(objectPose: screen * trueOffset.inverse, imagePose: screen) }
        let healed = try XCTUnwrap(calibration.offset)
        XCTAssertEqual(healed.columns.3.z, trueOffset.columns.3.z, accuracy: 1e-4, "the mean walked all the way over")
        XCTAssertLessThanOrEqual(calibration.count, calibration.effectiveCap)
    }

    // MARK: - G2: object-first acquisition

    /// Device trial: the object anchor was tracked from ~10 s and the image not until 49 s, and the card waited
    /// for the image the whole time. After `objectLeadAfter` a flat, tracked object anchor drives it instead —
    /// with no calibration, on the bounding-box fallback alone.
    func testObjectLeadsBeforeCalibrationAndHandsBackToTheImage() {
        var fusion = TrackingFusion()
        fusion.beginSession(at: 100)
        fusion.note(object: sample(pose(), at: 101.0))
        XCTAssertEqual(fusion.decide(at: 101.0).source, .image, "1 s in, the image still has its chance")

        fusion.note(object: sample(pose(), at: 102.1))
        let led = fusion.decide(at: 102.1)
        XCTAssertEqual(led.source, .object)
        XCTAssertTrue(led.switched)
        XCTAssertTrue(fusion.isLeading)
        XCTAssertFalse(fusion.calibrated, "no calibration was needed or claimed")

        // The image finally appears, 8 cm from where the bounding box put the card. There is no veto here — the
        // image is the thing the calibration is measured against, and it is right — so the correction is handed
        // straight to the continuity gate, which holds it and then glides the card over.
        fusion.note(image: sample(pose(x: 0.08), at: 102.2))
        let back = fusion.decide(at: 102.2)
        XCTAssertEqual(back.source, .image)
        XCTAssertTrue(back.switched)
        XCTAssertTrue(back.leadEnded)
        XCTAssertFalse(back.vetoed)
        XCTAssertEqual(back.disagreement ?? .nan, 0.08, accuracy: 1e-5)
        XCTAssertFalse(fusion.isLeading)
    }

    /// The lead is only ever offered by a device that reads as lying flat: a bounding-box offset applied to a pose
    /// held at an angle is not something to hand the card to.
    func testObjectDoesNotLeadWhenItIsNotFlat() {
        var fusion = TrackingFusion()
        fusion.beginSession(at: 0)
        fusion.note(object: TrackingFusion.Sample(pose: pose(), isTracked: true, time: 5.0, onDesk: false))
        XCTAssertEqual(fusion.decide(at: 5.0).source, .image)

        fusion.note(object: TrackingFusion.Sample(pose: pose(), isTracked: true, time: 5.1, onDesk: true))
        XCTAssertEqual(fusion.decide(at: 5.1).source, .object)
    }

    /// The clock the lead counts from is "the last time the image was tracked", falling back to the session start.
    /// So the image always gets the first 2 s, and it gets 2 s again every time it goes away — which is the case
    /// the first trial spent 25 s frozen in, with `cal=no` and a perfectly healthy object anchor.
    func testObjectLeadWaitsTwoSecondsAfterEveryImageLoss() {
        var fusion = TrackingFusion()
        fusion.beginSession(at: 0)
        fusion.note(image: sample(pose(), at: 4.0))
        XCTAssertEqual(fusion.decide(at: 4.0).source, .image)

        fusion.note(object: sample(pose(), at: 5.5))
        XCTAssertEqual(fusion.decide(at: 5.5).source, .image, "1.5 s since the image: not yet")

        fusion.note(object: sample(pose(), at: 6.1))
        XCTAssertEqual(fusion.decide(at: 6.1).source, .object, "2.1 s since the image: the object leads")

        // An untracked image observation is not the image being seen.
        fusion.note(image: sample(pose(), tracked: false, at: 6.2))
        fusion.note(object: sample(pose(), at: 6.25))
        XCTAssertEqual(fusion.decide(at: 6.25).source, .object)
    }

    // MARK: - G2: the veto in hand

    /// In hand the image tracker is the one that lies — a 37 mm self-lit target seen edge-on — so it does not get
    /// to hold on to the card by disagreeing with the object.
    func testCarryingPrefersTheObjectOverADisagreeingImage() {
        var carried = TrackingFusion()
        carried.calibrated = true
        carried.isCarrying = true
        carried.note(image: sample(pose(), at: 1.0))
        carried.note(object: sample(pose(x: 0.09), at: 1.0))
        let decision = carried.decide(at: 1.0)
        XCTAssertEqual(decision.source, .object)
        XCTAssertFalse(decision.vetoed)

        // On the desk the same disagreement is still a veto: two sources that can both be trusted cannot both be
        // right, and a 9 cm hand-over would read exactly like the ARKit drift M1b removed.
        var resting = TrackingFusion()
        resting.calibrated = true
        resting.note(image: sample(pose(), at: 1.0))
        resting.note(object: sample(pose(x: 0.09), at: 1.0))
        XCTAssertTrue(resting.decide(at: 1.0).vetoed)
    }

    /// The veto needs **both** sources fresher than 0.3 s. An image pose that is merely "not yet stale" is what
    /// held the card on the image for whole carries in the first trial.
    func testVetoNeedsBothSourcesFresherThanTheVetoWindow() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(), at: 1.0))
        XCTAssertEqual(fusion.decide(at: 1.0).source, .image)

        // 0.35 s later the image is still inside nobody's idea of stale, but it has lost its vote.
        fusion.note(object: sample(pose(x: 0.09), at: 1.35))
        let decision = fusion.decide(at: 1.35)
        XCTAssertEqual(decision.source, .object)
        XCTAssertFalse(decision.vetoed)
    }

    /// Position only. The object tracker's orientation is its weak axis, and comparing orientations would veto
    /// exactly the hand-overs the object source exists for.
    func testVetoComparesPositionsAndIgnoresOrientation() {
        var fusion = TrackingFusion()
        fusion.calibrated = true
        fusion.note(image: sample(pose(yawDegrees: 0), at: 1.0))
        fusion.note(object: sample(pose(yawDegrees: 90), at: 1.0))
        let decision = fusion.decide(at: 1.0)
        XCTAssertEqual(decision.source, .object, "same place, 90° apart: not a disagreement about where the card is")
        XCTAssertFalse(decision.vetoed)
        XCTAssertEqual(decision.disagreement ?? .nan, 0, accuracy: 1e-6)
    }

    /// An uncalibrated object source has no veto at all — in either direction. It is placing the card on a guess,
    /// and the image is the measurement that guess is about to be replaced by.
    func testUncalibratedLeadNeverVetoes() {
        var fusion = TrackingFusion()
        fusion.beginSession(at: 0)
        fusion.note(object: sample(pose(), at: 3.0))
        XCTAssertEqual(fusion.decide(at: 3.0).source, .object)

        fusion.note(image: sample(pose(x: 0.5), at: 3.05))
        let decision = fusion.decide(at: 3.05)
        XCTAssertEqual(decision.source, .image)
        XCTAssertFalse(decision.vetoed)
        XCTAssertTrue(decision.leadEnded)
    }
}
