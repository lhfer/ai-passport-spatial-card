import XCTest
import simd

/// `PoseFollower` is the thing that replaced `anchorRoot.move(to:)`, so these are the properties the card's motion
/// depends on: it never overshoots, a retarget in mid-flight does not restart the motion, the speed limit is a
/// limit on the *step*, and nothing explodes when a frame is late.
final class PoseFollowerTests: XCTestCase {
    private let dt: Float = 1.0 / 90
    private let identity = PoseFollower.identityRotation

    private func steps(_ follower: inout PoseFollower, count: Int) -> [SIMD3<Float>] {
        var out: [SIMD3<Float>] = []
        for _ in 0..<count {
            follower.step(dt: dt)
            out.append(follower.position)
        }
        return out
    }

    // (a) step response: monotone along the step direction, never past the target
    func testStepResponseNeverOvershoots() {
        var follower = PoseFollower(tau: 0.25)
        follower.snap(position: .zero, rotation: identity)
        let target = SIMD3<Float>(0.3, 0, 0)
        follower.retarget(position: target, rotation: identity)
        var previous: Float = 0
        for _ in 0..<300 {
            follower.step(dt: dt)
            let along = follower.position.x
            XCTAssertGreaterThanOrEqual(along, previous - 1e-7, "position moved backwards")
            XCTAssertLessThanOrEqual(along, 0.3 + 1e-6, "overshot the target")
            previous = along
        }
        XCTAssertEqual(follower.position.x, 0.3, accuracy: 1e-4)
    }

    // (b) a retarget in mid-flight is velocity-continuous
    func testMidFlightRetargetIsVelocityContinuous() {
        var follower = PoseFollower(tau: 0.25)
        follower.snap(position: .zero, rotation: identity)
        follower.retarget(position: [0.3, 0, 0], rotation: identity)
        // ~0.1 s in: past the acceleration phase, so the velocity is substantial.
        let before = steps(&follower, count: 9)
        let deltaBefore = before[8].x - before[7].x
        XCTAssertGreaterThan(deltaBefore, 0.002, "the test needs the follower to be genuinely in flight")
        follower.retarget(position: [0.35, 0, 0], rotation: identity)
        follower.step(dt: dt)
        let deltaAfter = follower.position.x - before[8].x
        XCTAssertEqual(deltaAfter / deltaBefore, 1, accuracy: 0.15, "the step jumped across the retarget")

        // With a speed limit, no step may exceed maxSpeed·dt either side of the retarget.
        var limited = PoseFollower(tau: 0.25, maxSpeed: 0.6)
        limited.snap(position: .zero, rotation: identity)
        limited.retarget(position: [0.3, 0, 0], rotation: identity)
        var last = SIMD3<Float>.zero
        for index in 0..<60 {
            if index == 9 { limited.retarget(position: [0.35, 0, 0], rotation: identity) }
            limited.step(dt: dt)
            XCTAssertLessThanOrEqual(simd_length(limited.position - last), 0.6 * dt + 1e-4)
            last = limited.position
        }
    }

    // (c) arrived: true within 5·τ of a step, false again right after a retarget
    func testArrivedFlipsWithinFiveTau() {
        let tau: Float = 0.25
        var follower = PoseFollower(tau: tau)
        follower.snap(position: .zero, rotation: identity)
        XCTAssertTrue(follower.arrived)
        follower.retarget(position: [0.3, 0, 0], rotation: identity)
        XCTAssertFalse(follower.arrived)
        var elapsed: Float = 0
        var arrivedAt: Float?
        while elapsed < 5 * tau {
            follower.step(dt: dt)
            elapsed += dt
            if arrivedAt == nil, follower.arrived { arrivedAt = elapsed }
        }
        XCTAssertNotNil(arrivedAt, "not arrived within 5τ")
        follower.retarget(position: [0.35, 0, 0], rotation: identity)
        XCTAssertFalse(follower.arrived, "a 5 cm retarget must leave the arrival tolerance")
    }

    // (d) the speed limit caps the per-frame step
    func testMaxSpeedIsRespected() {
        var follower = PoseFollower(tau: 0.25, maxSpeed: 0.6)
        follower.snap(position: .zero, rotation: identity)
        follower.retarget(position: [1, 0, 0], rotation: identity)
        var last = SIMD3<Float>.zero
        for _ in 0..<400 {
            follower.step(dt: dt)
            XCTAssertLessThanOrEqual(simd_length(follower.position - last), 0.6 * dt + 1e-4)
            last = follower.position
        }
        XCTAssertEqual(follower.position.x, 1, accuracy: 1e-3)
    }

    // (e) a huge dt is clamped and produces nothing strange
    func testHugeStepIsClampedAndFinite() {
        var follower = PoseFollower(tau: 0.25)
        follower.snap(position: .zero, rotation: identity)
        follower.retarget(position: [0.3, 0, 0], rotation: simd_quatf(angle: .pi / 2, axis: [0, 1, 0]))
        follower.step(dt: 1.0)
        XCTAssertTrue(follower.position.x.isFinite && follower.velocity.x.isFinite)
        XCTAssertTrue(follower.rotation.vector.x.isFinite && follower.rotation.vector.w.isFinite)
        XCTAssertLessThanOrEqual(follower.position.x, 0.3 + 1e-6)
        // 1.0 s was clamped to `maxStep`, so a single frame cannot have covered the whole step.
        XCTAssertLessThan(follower.position.x, 0.25)
        XCTAssertEqual(simd_length(follower.rotation.vector), 1, accuracy: 1e-4)
    }

    // (f) rotation takes the short way round and the angle is monotone
    func testRotationConvergesTheShortWay() {
        var follower = PoseFollower(tau: 0.25)
        follower.snap(position: .zero, rotation: identity)
        let target = simd_quatf(angle: .pi / 2, axis: [0, 1, 0])
        follower.retarget(position: .zero, rotation: target)
        var previous = follower.angleToTarget
        XCTAssertEqual(previous, .pi / 2, accuracy: 1e-3)
        for _ in 0..<200 {
            follower.step(dt: dt)
            let angle = follower.angleToTarget
            XCTAssertLessThanOrEqual(angle, previous + 1e-5, "the rotation went the long way round")
            previous = angle
        }
        XCTAssertLessThan(previous, 0.5 * .pi / 180)

        // Same target expressed with the opposite quaternion sign: still the short arc.
        var flipped = PoseFollower(tau: 0.25)
        flipped.snap(position: .zero, rotation: identity)
        flipped.retarget(position: .zero, rotation: simd_quatf(vector: -target.vector))
        var previousFlipped = flipped.angleToTarget
        for _ in 0..<200 {
            flipped.step(dt: dt)
            XCTAssertLessThanOrEqual(flipped.angleToTarget, previousFlipped + 1e-5)
            previousFlipped = flipped.angleToTarget
        }
        XCTAssertLessThan(previousFlipped, 0.5 * .pi / 180)
    }

    // MARK: - V3-1b: the carry chain (smoother → follower → lead)

    /// **How far behind the passport the card is while it is being carried.**
    ///
    /// The card hangs 35 mm over a screen the wearer is holding, so the lag is read directly against the device:
    /// the V3-1 chain (smoother τ 0.08 s, follower τ 0.18 s, no feed-forward) trails a 0.3 m/s carry by v·(τs+τf)
    /// ≈ 7.8 cm — a hand's width. V3-1b tightens both (0.03 / 0.08) and leads the follower by the measured raw
    /// velocity, which takes the residual to ≈ 1.9 cm without touching the resting card (at rest v is millimetres
    /// per second and the lead is invisible).
    ///
    /// Note for the record: the brief's target was "< 1.5 cm". The steady-state residual of this chain is
    /// v·(τs + τf − lead) = 0.3 × (0.03 + 0.08 − 0.05) = 1.8 cm, so 1.5 cm is not reachable at `--carry-lead 0.05`
    /// (it needs ≈ 0.065 s). The constants the brief specified are the ones implemented; the bound asserted here
    /// is the one they actually produce, and the ratio against the old chain is what the headset round compares.
    func testCarryChainLagAtThreeTenthsOfAMetrePerSecond() {
        let speed: Float = 0.3
        let new = carryLag(tauPosition: ObjectPoseSmoother.tauPositionHand, followerTau: 0.08, lead: 0.05, speed: speed)
        let old = carryLag(tauPosition: ObjectPoseSmoother.tauPositionDesk, followerTau: 0.18, lead: 0, speed: speed)
        XCTAssertGreaterThan(old, 0.06, "the V3-1 chain trails a carry by more than 6 cm")
        XCTAssertLessThan(new, 0.02, "the V3-1b chain trails it by under 2 cm")
        XCTAssertLessThan(new, old / 3, "and by less than a third of what it used to")

        // The feed-forward is the half of the change that costs nothing at rest …
        let noLead = carryLag(tauPosition: ObjectPoseSmoother.tauPositionHand, followerTau: 0.08, lead: 0, speed: speed)
        XCTAssertGreaterThan(noLead, new, "the lead is worth ~1.5 cm of it")
        // … because a standing-still device has no velocity to lead by.
        XCTAssertLessThan(carryLag(tauPosition: ObjectPoseSmoother.tauPositionHand, followerTau: 0.08,
                                   lead: 0.05, speed: 0), 0.0005)
    }

    /// One carry: a constant-speed ramp sampled at 30 Hz through the object smoother, retargeted with the
    /// velocity lead, and stepped at the render rate. Returns the mean |rendered − raw| after the first second —
    /// the same quantity `[gate] Σ lag=` measures on the headset.
    private func carryLag(tauPosition: Float, followerTau: Float, lead: Float, speed: Float) -> Float {
        var smoother = ObjectPoseSmoother(tauPosition: tauPosition, tauRotation: 0.20)
        var follower = PoseFollower(tau: followerTau)
        follower.snap(position: .zero, rotation: identity)
        let observationStep: TimeInterval = 1.0 / 30
        var nextObservation: TimeInterval = 0
        var time: TimeInterval = 0
        var total: Float = 0
        var count = 0
        while time < 2.0 {
            while nextObservation <= time + 1e-9 {
                var raw = matrix_identity_float4x4
                raw.columns.3 = SIMD4<Float>(speed * Float(nextObservation), 0, 0, 1)
                let smoothed = smoother.smooth(raw, at: nextObservation)
                let target = SIMD3<Float>(smoothed.columns.3.x, smoothed.columns.3.y, smoothed.columns.3.z)
                follower.retarget(position: target + SIMD3<Float>(speed * lead, 0, 0), rotation: identity)
                nextObservation += observationStep
            }
            follower.step(dt: dt)
            time += TimeInterval(dt)
            if time >= 1.0 {
                total += abs(follower.position.x - speed * Float(time))
                count += 1
            }
        }
        return count > 0 ? total / Float(count) : 0
    }
    // MARK: - V3-2a H1: a relocation that changes regime mid-glide

    /// The headset evidence (trial lines 312–326): a 12 cm desk relocation (τ 0.35, capped at 0.6 m/s) was
    /// 137 ms old when the passport was picked up, and the card then crawled after the hand for **3.81 s**
    /// with `Σ lag=157mm`. Retuning that same glide to the hand's τ 0.10 with the cap lifted lands it inside
    /// the brief's 1.0 s.
    func testRetuningAMidGlideRelocationToTheHandCatchesUpInsideASecond() {
        // `HologramController.followTauRelocate` / `.followRelocateSpeed` / `.followTauRelocateHand`
        // (the controller is not in this target: these tests compile against the pure types only).
        var follower = PoseFollower(tau: 0.35, maxSpeed: 0.6)
        follower.snap(position: .zero, rotation: identity)
        follower.retarget(position: [0.12, 0, 0], rotation: identity)
        var elapsed: Float = 0
        while elapsed < 0.27 { follower.step(dt: dt); elapsed += dt }
        XCTAssertGreaterThan(follower.distanceToTarget, 0.05, "more than handRelocateMin is still to go")
        follower.tau = 0.10
        follower.maxSpeed = .infinity
        let pickedUpAt = elapsed
        while elapsed < 6, !follower.arrived { follower.step(dt: dt); elapsed += dt }
        XCTAssertTrue(follower.arrived)
        XCTAssertLessThanOrEqual(elapsed - pickedUpAt, 1.0)
    }

    /// Why the glide has to be retuned at all: a hand does not hold still, and against a target that keeps
    /// moving the desk glide's τ 0.35 is a permanent 8–9 cm of lag (the headset read 157 mm while the
    /// relocation was still in flight). The hand's τ 0.10 keeps it under the brief's 30 mm.
    func testADeskGlideCannotKeepUpWithAHandAndTheRetunedOneCan() {
        func lag(tau: Float, maxSpeed: Float) -> Float {
            var follower = PoseFollower(tau: 0.35, maxSpeed: 0.6)
            follower.snap(position: .zero, rotation: identity)
            follower.retarget(position: [0.12, 0, 0], rotation: identity)
            var elapsed: Float = 0
            while elapsed < 0.27 { follower.step(dt: dt); elapsed += dt }
            follower.tau = tau
            follower.maxSpeed = maxSpeed
            // The passport now travels on at 0.25 m/s for two seconds.
            var target = SIMD3<Float>(0.12, 0, 0)
            var worst: Float = 0
            var carried: Float = 0
            while carried < 2 {
                target.x += 0.25 * dt
                follower.retarget(position: target, rotation: identity)
                follower.step(dt: dt)
                carried += dt
                if carried > 1 { worst = max(worst, follower.distanceToTarget) }
            }
            return worst
        }
        XCTAssertGreaterThan(lag(tau: 0.35, maxSpeed: 0.6), 0.08, "the desk glide is what Σ read as lag=157mm")
        XCTAssertLessThan(lag(tau: 0.10, maxSpeed: .infinity), 0.030, "the brief's < 30 mm")
    }

    /// Under 5 cm there is nothing left to glide: `retuneRelocationForPresence` ends the relocation instead,
    /// and the ordinary carry follower covers the rest in well under a tenth of a second.
    func testTheRemainderOfAShortGlideIsCoveredByTheCarryFollower() {
        let identity = PoseFollower.identityRotation
        var follower = PoseFollower(tau: 0.08, maxSpeed: .infinity)   // `followTauCarrying`
        follower.snap(position: .zero, rotation: identity)
        follower.retarget(position: [0.028, 0, 0], rotation: identity)
        var elapsed: Float = 0
        let dt: Float = 1.0 / 90
        while elapsed < 1, !follower.arrived { follower.step(dt: dt); elapsed += dt }
        XCTAssertTrue(follower.arrived)
        XCTAssertLessThan(elapsed, 0.6)
    }

}
