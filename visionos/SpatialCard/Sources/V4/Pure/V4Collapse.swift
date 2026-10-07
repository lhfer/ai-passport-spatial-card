import Foundation
import simd

extension V4 {
    /// **v4 B3 §2 — collapse and summon, as a pair.**
    ///
    /// The user's call (2026-10-04): collapse = long OK, or the passport turned face down; the one resting picture of a
    /// collapsed card is a breathing gold point beside the device's top edge (B2's pick-up fold point, moved out of the
    /// way of the screen — `V4.PickupFold.pointPosition`), and it *replaces* v3's socket light and sleeping dust rather
    /// than joining them. OK summons the card with the whole recognition again: the point fades as the ribbon leaves the
    /// screen. The guidance: 1.5 s after a collapse 「OK · 唤醒」 fades in beside the keys (where B2's first-gallery hint
    /// stands), for the session's first three collapses; any key fades it.
    enum Collapse {
        /// How long after the collapse the hint comes up (the card has become the point by 0.82 s).
        static let wakeHintDelay: TimeInterval = 1.5
        /// How many collapses a session gets the hint for.
        static let wakeHintCollapses = 3

        /// Does the `n`-th collapse of the session (1-based) get the hint?
        static func showsWakeHint(collapse n: Int) -> Bool {
            n >= 1 && n <= wakeHintCollapses
        }

        /// Where the hint stands, in the case frame C: on the keys' side (`edgeSign`, +1 for `+x`), 13 cm out and a little
        /// over the top face — B2's first-gallery hint's place (that one hangs off the desk surface, 3 cm over the desk).
        static func hintPosition(edgeSign: Float) -> SIMD3<Float> {
            [edgeSign * 0.13, 0.022, 0]
        }

        /// The point breathes at the searching rate (B2's), between these: never out, never a flash.
        static let breathPeriod: Float = 2.4
        static let breathOpacity: (base: Float, amplitude: Float) = (0.85, 0.15)
        /// The point leaves when a summon's ribbon does (the recognition's `.launch` is at 0.10 s).
        static let pointFadeOnSummon: Float = 0.25
    }
}
