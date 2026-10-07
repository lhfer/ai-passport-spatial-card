import Foundation
import simd

/// Where the in-world mini card stands relative to the wearer's head (工作包 C 小卡), and how lazily it
/// follows the head once it is there.
///
/// Pure value types over `simd` + `Foundation` — no ARKit, no RealityKit (`HologramController` converts to and
/// from `Transform`) — so `SpatialCardTests` can drive the geometry and the hysteresis deterministically.

// MARK: - Target

/// The mini card's resting pose for a head pose: 0.60 m ahead **horizontally**, 0.20 m below the eyes, turned
/// toward the head by yaw only and pitched 8° so its face opens upward toward the reader looking down at it.
///
/// The forward direction is deliberately horizontal (the same rule `WorldContext.forward` and `setHint` use):
/// "low in the field of view" has to mean low relative to a level head, or looking up at the sky would drag the
/// card up with it.
enum MiniCardTarget {
    /// Metres ahead of the head, on the horizontal plane.
    static let forwardDistance: Float = 0.60
    /// Metres below the eyes.
    static let dropHeight: Float = 0.20
    /// Degrees the card's face tilts **up** (its normal toward the eyes, which are 18° above it at this offset —
    /// 8° is the compromise between "faces the reader" and "stands upright in the world").
    static let pitchDegrees: Float = 8

    /// Eye position of a device pose.
    static func eye(_ head: simd_float4x4) -> SIMD3<Float> {
        SIMD3(head.columns.3.x, head.columns.3.y, head.columns.3.z)
    }

    /// Horizontal unit vector the head is looking along (device −Z, flattened). Falls back to the device's own
    /// up-axis projection and finally to −Z, so a head staring straight down or up never yields a zero vector.
    static func forward(_ head: simd_float4x4) -> SIMD3<Float> {
        var f = -SIMD3(head.columns.2.x, 0, head.columns.2.z)
        if simd_length(f) < 0.01 {
            // Looking straight down / up: the head's own +Y column, flattened, is where the nose points.
            f = SIMD3(head.columns.1.x, 0, head.columns.1.z)
            if simd_length(f) < 0.01 { return [0, 0, -1] }
        }
        return simd_normalize(f)
    }

    /// Resting position for this head pose.
    static func position(head: simd_float4x4) -> SIMD3<Float> {
        eye(head) + forward(head) * forwardDistance + SIMD3<Float>(0, -dropHeight, 0)
    }

    /// Yaw-only facing toward the head, then the 8° pitch in the card's own frame. The card's +Z is its face
    /// (the SwiftUI attachment sits in front of the slab), so the yaw is measured to the head, not from it.
    static func orientation(cardPosition: SIMD3<Float>, eye: SIMD3<Float>) -> simd_quatf {
        var toHead = eye - cardPosition
        toHead.y = 0
        let yaw: Float = simd_length(toHead) < 0.001 ? 0 : atan2(toHead.x, toHead.z)
        // Negative angle about +X tilts the face normal up — the same sign convention as `HologramLayout.cardTiltDegrees`.
        return simd_quatf(angle: yaw, axis: [0, 1, 0]) * simd_quatf(angle: -pitchDegrees * .pi / 180, axis: [1, 0, 0])
    }

    /// Position + orientation in one call (the placement the entry tween aims at).
    static func pose(head: simd_float4x4) -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let p = position(head: head)
        return (p, orientation(cardPosition: p, eye: eye(head)))
    }

    /// Angle between where the head looks and where the card actually is, on the horizontal plane (the quantity
    /// the lazy follow engages on).
    static func offAxisAngle(head: simd_float4x4, cardPosition: SIMD3<Float>) -> Float {
        var toCard = cardPosition - eye(head)
        toCard.y = 0
        guard simd_length(toCard) > 0.001 else { return 0 }
        let f = forward(head)
        let dot = max(-1, min(1, simd_dot(simd_normalize(toCard), f)))
        return acos(dot)
    }
}

// MARK: - Lazy follow

/// Lazy head follow for the mini card: it does **not** ride the head. It stays put until the wearer has really
/// turned (> 14° off axis) or really moved (> 0.18 m since it last came to rest), then glides after them with a
/// 0.35 s time constant and lets go again inside 3° / 1 cm. The hysteresis is the whole point — a card that
/// corrected every degree would be a cursor stuck to the face.
///
/// Height is the exception: it follows **always** (τ 0.6, no dead zone), because standing up or sitting down
/// with the card left at the old height is the one case where "lazy" reads as broken.
struct MiniCardFollow {
    /// Off-axis angle that starts a follow.
    static let engageAngle: Float = 14 * .pi / 180
    /// Head travel since the last rest that starts a follow.
    static let engageDistance: Float = 0.18
    /// Below this angle **and** this planar error the follow stops (hysteresis: both, not either).
    static let releaseAngle: Float = 3 * .pi / 180
    static let releaseDistance: Float = 0.01
    /// Time constants: the horizontal glide, and the height that never stops following.
    static let tauPlanar: Float = 0.35
    static let tauHeight: Float = 0.6
    /// Frame clamp, as in `PoseFollower`: a stalled frame must not teleport the card.
    static let maxStep: Float = 0.05

    private(set) var position: SIMD3<Float> = .zero
    /// True while the card is actively gliding after the head.
    private(set) var engaged = false
    /// Where the head was when the card last came to rest; the 0.18 m test measures against this, so slow drift
    /// accumulates into one catch-up instead of never triggering.
    private(set) var restEye: SIMD3<Float> = .zero

    /// The entry tween has landed: adopt its final position (no pop at the handover) and start at rest.
    mutating func place(at position: SIMD3<Float>, head: simd_float4x4) {
        self.position = position
        engaged = false
        restEye = MiniCardTarget.eye(head)
    }

    /// One rendered frame. Returns the new position; the caller keeps the orientation (which is re-derived from
    /// this position every frame, engaged or not, so a resting card still faces the reader).
    @discardableResult
    mutating func step(dt rawDt: Float, head: simd_float4x4) -> SIMD3<Float> {
        let dt = min(MiniCardFollow.maxStep, max(0, rawDt.isFinite ? rawDt : 0))
        guard dt > 0 else { return position }
        let eye = MiniCardTarget.eye(head)
        let target = MiniCardTarget.position(head: head)
        let angle = MiniCardTarget.offAxisAngle(head: head, cardPosition: position)

        if !engaged, angle > MiniCardFollow.engageAngle || simd_distance(eye, restEye) > MiniCardFollow.engageDistance {
            engaged = true
        }
        if engaged {
            let k = 1 - exp(-dt / MiniCardFollow.tauPlanar)
            position.x += (target.x - position.x) * k
            position.z += (target.z - position.z) * k
        }
        // Height: always, and slower.
        position.y += (target.y - position.y) * (1 - exp(-dt / MiniCardFollow.tauHeight))

        if engaged {
            let planar = simd_length(SIMD3<Float>(target.x - position.x, 0, target.z - position.z))
            let settled = MiniCardTarget.offAxisAngle(head: head, cardPosition: position)
            if settled < MiniCardFollow.releaseAngle && planar < MiniCardFollow.releaseDistance {
                engaged = false
                restEye = eye
            }
        }
        return position
    }

    /// Orientation for the current position (yaw toward the head + the fixed pitch).
    func orientation(head: simd_float4x4) -> simd_quatf {
        MiniCardTarget.orientation(cardPosition: position, eye: MiniCardTarget.eye(head))
    }
}
