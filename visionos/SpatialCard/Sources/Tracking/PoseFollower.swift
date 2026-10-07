import Foundation
import simd

/// Critically damped second-order follower for the card's world pose, stepped once per rendered frame.
///
/// Why it exists (first on-device round): every image-anchor update restarted a 0.2–0.35 s `anchorRoot.move(to:)`,
/// and each restart threw the previous animation's velocity away — following a real move felt draggy, and a 1 mm
/// tracking correction while the wearer held still was visible as a shimmy. A follower keeps one continuous state
/// (position + velocity) and only ever receives a **new target**, so retargeting mid-flight is smooth by
/// construction and whatever rate the anchors arrive at is resampled to the render rate. (The design assumed
/// ≈ 6 Hz; the headset actually reports 22–30 Hz. Neither number appears here — that is the point — and the 4 mm /
/// 1.5° dead zone in `HologramController.apply(pose:)` decides which updates are worth retargeting for at all.)
///
/// The step is the exact closed-form solution of the critically damped oscillator (ω = 2/τ), not an Euler
/// integration: at 6 Hz input and a 0.05 s frame clamp an explicit integrator is not stable at these gains, and
/// the closed form cannot overshoot no matter how large the step is.
///
/// Pure value type over `simd` + `Foundation` — no ARKit, no RealityKit (`HologramController` converts to and from
/// `Transform`), so `SpatialCardTests` can drive it deterministically.
struct PoseFollower {
    /// Time constant (s): the 1/e settling time of the position error. Smaller = tighter following.
    var tau: Float
    /// **V3-2b B2.** A separate time constant for the rotation. Nil (the default, and what every follower
    /// before the hand deck used) means `tau` drives both. The deck's cards want the two apart: they trail the
    /// name card in *position* by 50–90 ms, which is the "hand of cards" swing, but turn on a slower 80 ms so
    /// a flick of the wrist does not make the fan flutter.
    var tauRotation: Float?
    /// Speed limit (m/s). `.infinity` (the default) = unlimited; the relocation glide is the one case that caps it,
    /// so a card that comes back 30 cm away travels at a readable speed instead of snapping across the desk.
    var maxSpeed: Float

    private(set) var position: SIMD3<Float> = .zero
    private(set) var velocity: SIMD3<Float> = .zero
    private(set) var rotation: simd_quatf = PoseFollower.identityRotation
    private(set) var targetPosition: SIMD3<Float> = .zero
    private(set) var targetRotation: simd_quatf = PoseFollower.identityRotation
    /// Within `arrivedDistance` / `arrivedSpeed` / `arrivedAngle` of the target. Starts true (nothing to do).
    private(set) var arrived = true

    /// 1 mm / 5 mm·s⁻¹ / 0.5°: below this the remaining error is smaller than the tracking noise it came from.
    static let arrivedDistance: Float = 0.001
    static let arrivedSpeed: Float = 0.005
    static let arrivedAngle: Float = 0.5 * .pi / 180
    /// `EngineTickSystem` already clamps `deltaTime` to 0.05 s; the guard is repeated here so a follower stepped
    /// from anywhere else (a test, a stalled frame) cannot be handed a second-long step.
    static let maxStep: Float = 0.05
    /// Kept here rather than as `extension simd_quatf { static var identity }`: simd or RealityKit adding one of
    /// their own would turn every use into "ambiguous use of 'identity'".
    static let identityRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    init(tau: Float = 0.25, maxSpeed: Float = .infinity) {
        self.tau = tau
        self.maxSpeed = maxSpeed
    }

    // MARK: - Targets

    /// Be there now: the session's first pose, the pose after leaving preview, and the first pose after any
    /// hide → show (gliding in from wherever the card used to be would be a lie).
    mutating func snap(position: SIMD3<Float>, rotation: simd_quatf) {
        let r = PoseFollower.normalized(rotation)
        self.position = position
        self.velocity = .zero
        self.rotation = r
        targetPosition = position
        targetRotation = r
        arrived = true
    }

    /// New target, **same velocity**: a retarget in mid-flight continues the motion instead of restarting it.
    /// This is the call the 6 Hz pose stream makes; the continuity is the whole point of the follower.
    mutating func retarget(position: SIMD3<Float>, rotation: simd_quatf) {
        targetPosition = position
        targetRotation = PoseFollower.normalized(rotation)
        updateArrived()
    }

    // MARK: - Step

    mutating func step(dt rawDt: Float) {
        let dt = min(PoseFollower.maxStep, max(0, rawDt.isFinite ? rawDt : 0))
        guard dt > 0 else { return }
        let omega = 2 / max(0.0001, tau)

        // Closed-form critically damped step: x(t) = (x₀ + B·t)·e^{−ωt} with B = v₀ + ω·x₀.
        let previous = position
        let x = position - targetPosition
        let b = velocity + x * omega
        let e = exp(-omega * dt)
        position = targetPosition + (x + b * dt) * e
        velocity = (velocity - b * (omega * dt)) * e

        if maxSpeed.isFinite {
            let speed = simd_length(velocity)
            if speed > maxSpeed, speed > 0 {
                // Clamp the *step*, not just the state: re-integrate from where the frame started, so the visible
                // travel per frame never exceeds maxSpeed·dt.
                velocity *= maxSpeed / speed
                position = previous + velocity * dt
            }
        }

        // Rotation: first-order lag along the shortest arc. Quaternions are a double cover, so a target whose
        // dot product is negative has to be negated first or the card would spin the long way round.
        var target = targetRotation
        if simd_dot(rotation.vector, target.vector) < 0 { target = simd_quatf(vector: -target.vector) }
        let k = 1 - exp(-dt / max(0.0001, tauRotation ?? tau))
        if simd_dot(rotation.vector, target.vector) > 0.9999995 {
            // Already there to within ~0.09°: slerp's sin(θ) denominator would be a division by ~0.
            rotation = target
        } else {
            rotation = PoseFollower.normalized(simd_slerp(rotation, target, k))
        }

        updateArrived()
    }

    // MARK: - Derived

    var distanceToTarget: Float { simd_length(position - targetPosition) }

    var angleToTarget: Float {
        let dot = min(1, abs(simd_dot(rotation.vector, targetRotation.vector)))
        return 2 * acos(dot)
    }

    private mutating func updateArrived() {
        arrived = distanceToTarget < PoseFollower.arrivedDistance
            && simd_length(velocity) < PoseFollower.arrivedSpeed
            && angleToTarget < PoseFollower.arrivedAngle
    }

    private static func normalized(_ q: simd_quatf) -> simd_quatf {
        let length = simd_length(q.vector)
        guard length.isFinite, length > 1e-6 else { return PoseFollower.identityRotation }
        return simd_quatf(vector: q.vector / length)
    }
}

