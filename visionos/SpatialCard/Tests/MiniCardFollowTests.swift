import XCTest
import simd

/// The pure half of the in-world mini card (工作包 C): where it stands relative to the head, and the lazy
/// follow's hysteresis. These are the parts that decide whether the card reads as "parked low, out of the way"
/// or as a cursor stuck to the wearer's face, and neither needs RealityKit to be checked.
final class MiniCardFollowTests: XCTestCase {
    private let dt: Float = 1.0 / 90

    /// Head at `eye`, looking along `yaw` (0 = −Z), level. Built by hand rather than through `Transform`:
    /// the test target compiles the pure sources only, so it has no RealityKit.
    private func head(_ eye: SIMD3<Float>, yawDegrees: Float = 0) -> simd_float4x4 {
        pose(simd_quatf(angle: yawDegrees * .pi / 180, axis: [0, 1, 0]), at: eye)
    }

    private func pose(_ rotation: simd_quatf, at eye: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(eye.x, eye.y, eye.z, 1)
        return m
    }

    // MARK: - Target

    // (a) 0.60 m ahead, 0.20 m down, from a level head looking −Z
    func testTargetIsAheadAndLow() {
        let pose = MiniCardTarget.pose(head: head([0, 1.4, 0]))
        XCTAssertEqual(pose.position.x, 0, accuracy: 1e-6)
        XCTAssertEqual(pose.position.y, 1.2, accuracy: 1e-6)
        XCTAssertEqual(pose.position.z, -0.6, accuracy: 1e-6)
    }

    // (b) the target turns with the head's yaw and stays 0.6 m away, horizontally
    func testTargetFollowsYawAtConstantDistance() {
        for yaw in stride(from: Float(-170), through: 170, by: 37) {
            let h = head([0.2, 1.5, -0.3], yawDegrees: yaw)
            let p = MiniCardTarget.position(head: h)
            let planar = simd_length(SIMD3<Float>(p.x - 0.2, 0, p.z + 0.3))
            XCTAssertEqual(planar, 0.6, accuracy: 1e-4, "yaw \(yaw)")
            XCTAssertEqual(p.y, 1.3, accuracy: 1e-5, "yaw \(yaw)")
        }
    }

    // (c) a head looking steeply down does not drag the card down with it (horizontal forward), and never
    //     produces a NaN from a degenerate flattened forward
    func testSteepLookDownKeepsTheCardLevelAndFinite() {
        let h = pose(simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]), at: [0, 1.4, 0])   // looking straight down
        let p = MiniCardTarget.position(head: h)
        XCTAssertTrue(p.x.isFinite && p.y.isFinite && p.z.isFinite)
        XCTAssertEqual(p.y, 1.2, accuracy: 1e-5)
        XCTAssertEqual(simd_length(SIMD3<Float>(p.x, 0, p.z)), 0.6, accuracy: 1e-4)
    }

    // (d) the card's face (+Z) points back at the head in yaw, and is pitched 8° up
    func testOrientationFacesTheHeadWithAnEightDegreeUpPitch() {
        for yaw in stride(from: Float(-160), through: 160, by: 40) {
            let h = head([0, 1.4, 0], yawDegrees: yaw)
            let pose = MiniCardTarget.pose(head: h)
            let normal = pose.orientation.act(SIMD3<Float>(0, 0, 1))
            let toHead = simd_normalize(MiniCardTarget.eye(h) - pose.position)
            // Yaw: the flattened normal is the flattened direction to the head.
            let flatNormal = simd_normalize(SIMD3<Float>(normal.x, 0, normal.z))
            let flatToHead = simd_normalize(SIMD3<Float>(toHead.x, 0, toHead.z))
            XCTAssertEqual(simd_dot(flatNormal, flatToHead), 1, accuracy: 1e-4, "yaw \(yaw)")
            // Pitch: 8° up out of the horizontal plane.
            XCTAssertEqual(asin(normal.y) * 180 / .pi, 8, accuracy: 1e-3, "yaw \(yaw)")
        }
    }

    // MARK: - Lazy follow

    // (e) a small head turn (< 14°) does not move the card horizontally at all
    func testSmallTurnDoesNotEngage() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let before = follow.position
        let turned = head([0, 1.4, 0], yawDegrees: 10)
        for _ in 0..<180 { follow.step(dt: dt, head: turned) }
        XCTAssertFalse(follow.engaged)
        XCTAssertEqual(follow.position.x, before.x, accuracy: 1e-6)
        XCTAssertEqual(follow.position.z, before.z, accuracy: 1e-6)
    }

    // (f) a real turn engages, converges, and lets go again inside the release window
    func testLargeTurnEngagesConvergesAndReleases() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let turned = head([0, 1.4, 0], yawDegrees: 45)
        follow.step(dt: dt, head: turned)
        XCTAssertTrue(follow.engaged, "45° off axis must start the follow")
        for _ in 0..<270 { follow.step(dt: dt, head: turned) }
        XCTAssertFalse(follow.engaged, "the follow must let go once it has caught up")
        let target = MiniCardTarget.position(head: turned)
        XCTAssertLessThan(simd_distance(follow.position, target), MiniCardFollow.releaseDistance)
        // …and it stays let go: a 2° twitch afterwards moves nothing.
        let twitch = head([0, 1.4, 0], yawDegrees: 47)
        let resting = follow.position
        for _ in 0..<90 { follow.step(dt: dt, head: twitch) }
        XCTAssertFalse(follow.engaged)
        XCTAssertEqual(simd_distance(follow.position, resting), 0, accuracy: 1e-5)
    }

    // (g) walking sideways engages even with the head pointing the same way
    func testHeadTranslationEngagesWithoutAnyTurn() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let nudged = head([0.1, 1.4, 0])                    // 10 cm: under the 0.18 m gate
        for _ in 0..<60 { follow.step(dt: dt, head: nudged) }
        XCTAssertFalse(follow.engaged, "10 cm must not be enough")
        let moved = head([0.25, 1.4, 0])                    // 25 cm: over it
        follow.step(dt: dt, head: moved)
        XCTAssertTrue(follow.engaged)
    }

    // (h) the glide is the specified exponential: ~63 % of the error is gone after one τ
    func testPlanarGlideUsesTheSpecifiedTimeConstant() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let turned = head([0, 1.4, 0], yawDegrees: 90)
        let target = MiniCardTarget.position(head: turned)
        let error0 = simd_length(SIMD3<Float>(target.x - follow.position.x, 0, target.z - follow.position.z))
        for _ in 0..<Int((MiniCardFollow.tauPlanar / dt).rounded()) { follow.step(dt: dt, head: turned) }
        let error1 = simd_length(SIMD3<Float>(target.x - follow.position.x, 0, target.z - follow.position.z))
        XCTAssertEqual(error1 / error0, exp(-1), accuracy: 0.02)
    }

    // (i) height follows with no dead zone — even while the follow is disengaged — at its own τ
    func testHeightFollowsWhileDisengaged() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let stood = head([0, 1.62, 0])                      // stood up 22 cm, same direction
        let y0 = follow.position.y
        for _ in 0..<Int((MiniCardFollow.tauHeight / dt).rounded()) { follow.step(dt: dt, head: stood) }
        let remaining = (1.42 - follow.position.y) / (1.42 - y0)
        XCTAssertEqual(remaining, exp(-1), accuracy: 0.02)
        for _ in 0..<600 { follow.step(dt: dt, head: stood) }
        XCTAssertEqual(follow.position.y, 1.42, accuracy: 1e-3)
        XCTAssertFalse(follow.engaged, "height alone must never engage the horizontal follow")
    }

    // (j) a stalled frame is clamped, and nothing ever becomes NaN
    func testLateFrameIsClampedAndStaysFinite() {
        var follow = MiniCardFollow()
        let start = head([0, 1.4, 0])
        follow.place(at: MiniCardTarget.position(head: start), head: start)
        let turned = head([0, 1.4, 0], yawDegrees: 120)
        follow.step(dt: 5, head: turned)                    // a five-second "frame"
        let target = MiniCardTarget.position(head: turned)
        XCTAssertTrue(follow.position.x.isFinite && follow.position.y.isFinite && follow.position.z.isFinite)
        XCTAssertGreaterThan(simd_distance(follow.position, target), 0.05, "a 5 s step must not teleport the card")
        follow.step(dt: .nan, head: turned)
        XCTAssertTrue(follow.position.x.isFinite && follow.position.y.isFinite && follow.position.z.isFinite)
    }
}
