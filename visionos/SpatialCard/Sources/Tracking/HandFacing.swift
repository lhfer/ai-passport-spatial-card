import Foundation
import simd

/// Which way the hand-held card faces (v3 H2 §2).
///
/// While the device is in the hand the card is a 13.5 cm pane floating 35 mm above its screen, and the obvious
/// answer — rigidly parallel to the screen — is the one the first Extended round ruled out: the object
/// tracker's pitch/roll read 14–28° off while the device *lay flat on the desk*, and on the desk the gravity
/// snap hides that. In the hand there is nothing to snap to, so a rigidly parallel card would carry the whole
/// error, visibly. The other extreme (a billboard) always faces the reader but stops being attached to the
/// device: turn the passport over and the card does not turn with it.
///
/// `hybrid` (the default) takes 60 % of the way from the screen's own normal toward the reader's eyes — enough
/// that a 20° tracking error is 8° of it, little enough that rolling the device still rolls the card.
///
/// Pure: `HandFacingTests` checks that `device` reproduces the base orientation *exactly* (an approximation
/// there would mean the A/B on the headset compares the wrong thing) and that the blend stays well-formed.
/// `--hand-form hinge|hover` (V3-2a H2): where the hand card stands.
///
/// `hover` is V3-1's form — a pane lying 35 mm above the screen, which is exactly what hid the hardware.
/// `hinge` (the default) stands the card on the device's **top edge** and opens it out along the screen
/// plane, so the LCD is never covered.
enum HandForm: String, Equatable, CaseIterable {
    case hinge
    case hover
}

enum HandFacing: String, Equatable, CaseIterable {
    /// Rigidly parallel to the screen — the reference the other two are judged against.
    case device
    /// 60 % toward the reader.
    case hybrid
    /// Always square to the reader.
    case billboard
    /// V3-2a H2: the card stands on the hinge at the device's top edge and only its **pitch about that
    /// hinge** blends toward the eyes (0.6, clamped ±35°). Yaw and roll stay rigid with the device, so
    /// turning the passport turns the card exactly as a real flip-open cover would.
    case hinged

    /// How far the card's normal is allowed to leave the screen's.
    var weight: Float {
        switch self {
        case .device: return 0
        case .hybrid: return 0.6
        case .billboard: return 1
        case .hinged: return HandFacing.hingeWeight
        }
    }

    /// How far the hinge angle is allowed to follow the eyes, and how far it may open.
    static let hingeWeight: Float = 0.6
    static let hingeClamp: Float = 35 * .pi / 180

    /// The card's orientation in `anchorRoot` space (the device's own frame: +Y out of the screen, −Z toward
    /// its top edge).
    ///
    /// `card` and `head` are both in that space. The result's +Z (the card's front) is the blended normal and
    /// its +Y (the card's up) is as close to the screen's top edge as that normal allows, so the card reads as
    /// standing on the device however far it has turned toward the reader.
    static func orientation(mode: HandFacing, card: SIMD3<Float>, head: SIMD3<Float>?) -> simd_quatf {
        let screenNormal = SIMD3<Float>(0, 1, 0)
        let upHint = SIMD3<Float>(0, 0, -1)
        var normal = screenNormal
        if mode != .device, let head {
            var toHead = head - card
            // The reader is (almost) at the card: there is no direction to face, so keep the screen's own.
            if simd_length(toHead) > 1e-4 {
                toHead = simd_normalize(toHead)
                normal = slerpDirection(from: screenNormal, to: toHead, weight: mode.weight)
            }
        }
        return basis(normal: normal, upHint: upHint)
    }

    /// Rotate `from` toward `to` by `weight` of the angle between them, on the plane they span. (A vector
    /// `simd_mix` + normalise would move fastest in the middle and would collapse at 180°.)
    static func slerpDirection(from: SIMD3<Float>, to: SIMD3<Float>, weight: Float) -> SIMD3<Float> {
        let w = max(0, min(1, weight))
        guard w > 0 else { return from }
        let dot = max(-1, min(1, simd_dot(from, to)))
        let angle = acos(dot)
        guard angle > 1e-4 else { return to }
        var axis = simd_cross(from, to)
        if simd_length(axis) < 1e-5 {
            // Exactly opposite: any perpendicular axis will do, and the result is the same either way.
            axis = abs(from.y) < 0.9 ? simd_cross(from, SIMD3<Float>(0, 1, 0)) : simd_cross(from, SIMD3<Float>(1, 0, 0))
        }
        axis = simd_normalize(axis)
        return simd_normalize(simd_quatf(angle: angle * w, axis: axis).act(from))
    }

    /// A right-handed basis whose +Z is `normal` and whose +Y is `upHint` with the normal's component removed.
    static func basis(normal: SIMD3<Float>, upHint: SIMD3<Float>) -> simd_quatf {
        let z = simd_normalize(normal)
        var up = upHint - z * simd_dot(z, upHint)
        if simd_length(up) < 1e-4 {
            // The card is looking straight along the up hint (the reader is directly above / below the device
            // and the blend took the normal all the way there): any perpendicular up keeps the basis valid.
            up = abs(z.y) < 0.9 ? SIMD3<Float>(0, 1, 0) - z * z.y : SIMD3<Float>(1, 0, 0) - z * z.x
        }
        let y = simd_normalize(up)
        let x = simd_normalize(simd_cross(y, z))
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    // MARK: - The hinge (V3-2a H2 / plan §4 E3)

    /// The hinged card's orientation **in hinge space** — the frame that sits on the device's top edge with
    /// +X across the device, +Y running up the card and +Z out of the screen.
    ///
    /// The card is a flip-open cover: at rest it lies in the screen's own plane, opened out past the top
    /// edge (open angle 180°, which is the identity here). The only freedom it has is the hinge angle — a
    /// rotation about the hinge's X axis that lifts its top edge toward the wearer — so yaw and roll stay
    /// rigid with the device and the LCD is never covered, whatever the wearer does with their head.
    ///
    /// `weight` 0 reproduces the base **exactly** (an approximation there would mean `--hand-form hover`
    /// and `hinge` were being compared against different references).
    static func hinged(weight: Float, card: SIMD3<Float>, head: SIMD3<Float>?,
                       clamp: Float = HandFacing.hingeClamp) -> simd_quatf {
        hinged(angle: hingeAngle(weight: weight, card: card, head: head, clamp: clamp))
    }

    // MARK: - The hinge arm (V3-2b B0b)

    /// **The arm.** A frame whose origin *is* the hinge (the device's top edge) and whose rotation is the
    /// hinge angle; the card is mounted on it at (0, `halfHeight`, 0). That is what makes the cover a real
    /// hinge: it pivots about its own bottom edge, which therefore never leaves the device's top edge.
    ///
    /// V3-2a2 wrote the same angle onto the card itself, whose position stayed at (0, `halfHeight`, 0) — a
    /// rotation about the card's **centre**. The cover opened by the same angle, but its bottom edge swung
    /// 2·`halfHeight`·sin(α/2) away from the hinge (≈ 41 mm at the ±35° clamp on a 135 mm card), so the card
    /// floated off the passport's edge exactly when it opened toward the wearer.
    static func hinged(angle: Float) -> simd_quatf {
        guard angle != 0 else { return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) }
        return simd_quatf(angle: angle, axis: [1, 0, 0])
    }

    /// Where the card's centre stands in hinge space with the arm at `angle`: on an arc about the hinge.
    static func cardCentre(angle: Float, halfHeight: Float) -> SIMD3<Float> {
        hinged(angle: angle).act([0, halfHeight, 0])
    }

    /// …and where its bottom edge stands: **on the hinge**, at the origin, at every angle.
    static func cardBottomEdge(angle: Float, halfHeight: Float) -> SIMD3<Float> {
        let q = hinged(angle: angle)
        return q.act([0, halfHeight, 0]) + q.act([0, -halfHeight, 0])
    }

    /// The V3-2a2 model this replaced, kept so the test can state what changed: the same rotation taken about
    /// the card's own centre, which held the centre still and swung the bottom edge off the hinge.
    static func cardBottomEdgeAboutCentre(angle: Float, halfHeight: Float) -> SIMD3<Float> {
        SIMD3<Float>(0, halfHeight, 0) + hinged(angle: angle).act([0, -halfHeight, 0])
    }

    /// How far the cover is lifted, in radians: the angle that would point the card's normal at the wearer,
    /// taken `weight` of the way and clamped to [0, `clamp`] (the cover opens toward the reader and stops flat). Only the component of "toward the head" that the
    /// hinge can actually reach counts — the sideways part is dropped, not converted into roll.
    static func hingeAngle(weight: Float, card: SIMD3<Float>, head: SIMD3<Float>?,
                           clamp: Float = HandFacing.hingeClamp) -> Float {
        guard weight > 0, let head else { return 0 }
        let d = head - card
        // Project onto the hinge's own plane: the hinge turns about X, so X is the direction it cannot use.
        let plane = SIMD2<Float>(d.y, d.z)
        guard simd_length(plane) > 1e-4 else { return 0 }
        // Rx(α) sends the card's normal (0, 0, 1) to (0, −sin α, cos α), so the angle that points it at the
        // wearer is atan2(−dy, dz).
        let target = atan2(-plane.x, plane.y)
        let blended = target * max(0, min(1, weight))
        // V3-3 final (reviewer decision): a cover hinged on an edge opens toward the reader and stops flat —
        // it never hyperextends past the screen plane, so the clamp is [0, +clamp]. When the wearer looks at the
        // card from behind (the back face), the cover simply lies flat instead of folding away from them.
        return max(0, min(clamp, blended))
    }

    /// The card's resting orientation on the device: the plate lying parallel to the screen, its top edge
    /// toward the screen's (anchor −Z). This is `foldIntoDevice`'s end orientation too, which is what lets the
    /// unfold start exactly where the fold finished.
    static var base: simd_quatf { simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]) }

    /// Exponential approach (τ seconds) of `current` toward `target`, so head motion can never jitter the card.
    static func step(current: simd_quatf, target: simd_quatf, dt: Float, tau: Float) -> simd_quatf {
        guard tau > 0 else { return target }
        let clamped = max(0, min(0.25, dt))
        guard clamped > 0 else { return current }
        return simd_slerp(current, target, 1 - exp(-clamped / tau))
    }
}
