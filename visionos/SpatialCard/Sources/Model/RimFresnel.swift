import Foundation
import simd

/// **V3-3 C1 / plan §4 E14a — the rim's Fresnel.**
///
/// A real edge-lit plate is dimmest seen square-on and brightest seen along its edge, because grazing rays
/// travel further through the material. The card's rim is one flat emissive ring, so the effect has to be
/// written by hand — every frame, as a number:
///
///     opacity = 0.45 + 0.35 · (1 − |n · v|)^1.5
///
/// `n` is the card's own normal (its local +Z, the face the SwiftUI attachment is on) and `v` the direction
/// from the card to the wearer's eyes. `|·|` because the *back* of the card is just as grazing-lit as the
/// front: what the exponent measures is the angle, not the side.
///
/// On the desk the billboard keeps the card square to the reader, so this lands on ≈ 0.45 and stays there —
/// which is the point (0.45 rather than the plan's 0.35 — the reviewer raised the floor so a real LCD next to the
/// rim never makes it read as switched off): the rim is quiet until the passport is in a hand, where turning the wrist sweeps the
/// light along the edge. It is written through `PulseComponent.baseOpacity` (the pulse system re-derives the
/// `OpacityComponent` from it every frame) rather than by rebuilding the material, which would cost a
/// `MeshResource`/material swap 90 times a second.
enum RimFresnel {
    /// Square-on: the dimmest the rim ever gets.
    static let facing: Float = 0.45
    /// How much brighter a grazing edge is than a square-on one.
    static let range: Float = 0.35
    /// > 1 keeps the middle of the sweep dark, so the brightening reads as an *edge* catching the light
    /// rather than as the whole card changing brightness.
    static let exponent: Float = 1.5
    /// Edge-on: the brightest, `facing + range`.
    static var grazing: Float { facing + range }

    /// The rim's base opacity for one frame. Neither argument has to be normalised; a degenerate one
    /// (the head exactly at the card's centre, a zero normal) reads as square-on, which is the quiet value.
    static func opacity(normal: SIMD3<Float>, view: SIMD3<Float>) -> Float {
        let nl = simd_length(normal), vl = simd_length(view)
        guard nl > 1e-6, vl > 1e-6, nl.isFinite, vl.isFinite else { return facing }
        let d = abs(simd_dot(normal / nl, view / vl))
        // The dot of two unit vectors can leave [−1, 1] by an ulp; clamping here is what makes the value
        // below provably inside [facing, grazing] rather than inside it by luck.
        let t = max(0, min(1, 1 - d))
        let value = facing + range * pow(t, exponent)
        return max(facing, min(grazing, value))
    }
}
