import Foundation
import simd

extension V4 {
    /// **v4 B1 follow-up — the hand-over hold** (the numbers the product and the unit tests share).
    ///
    /// The first recognition must always reveal the card with A1's dissolve. When A1's materials are still loading at
    /// the closure, the recognition does not hand over to A4's placeholder: the ribbon breaks up as designed, the
    /// outline it drew stays — breathing, shedding a trickle of dust — and the card's reveal starts the frame the
    /// materials are in, at most `cap` seconds after the closure. Past the cap the placeholder reveals the card (what
    /// every first run did before the hold existed) and A1's style comes in at the next entrance.
    ///
    ///     1.90       closure       the chip; A1 not on the card → hold (the entrance stays held, `Pending` unchanged)
    ///     2.20       ribbon gone   the recognition's clock waits here (`holdPoint`); the outline breathes
    ///     …          ready / cap   `[v4] hand-over held N ms for materials`; the reveal starts (card clock 0)
    ///     card 0.30                the recognition's clock runs on from 2.20 (`resumeCardClock`) …
    ///     card 0.50                … so the outline hands over where it always does: the card ≈ 80 % dissolved
    struct HandOverHold: Equatable {
        /// The longest the hand-over waits for A1's materials (s, wall clock from the closure).
        var cap: Double = 2.5
        /// The breath: the outline brightens by up to this share of its level and back, once every `breathPeriod` s.
        var breathDepth: Float = 0.35
        var breathPeriod: Float = 1.5
        /// After the release the breath eases back to the outline's own level over this (s).
        var settle: Float = 0.3
        /// Nothing to reveal at the release (the held entrance was a carry, or not animated): the recognition's clock
        /// runs on after this instead of waiting for a card clock that never starts (s).
        var resumeGrace: Double = 0.3

        static let standard = HandOverHold()

        /// Where the recognition's clock waits: the end of the ribbon's dissolve, when only the outline is left.
        func holdPoint(_ beats: RecognitionTimeline.Beats) -> Float { beats.dissolveEnd }

        /// The card's entrance clock at which the recognition's clock runs on from `holdPoint` — the moment the two
        /// clocks agree again (without a hold the card's clock is always `t − closure`).
        func resumeCardClock(_ beats: RecognitionTimeline.Beats) -> Double {
            Double(holdPoint(beats) - beats.closure)
        }

        /// The outline's brightness multiplier `held` seconds into the hold: 1 at the start (no step, no kink),
        /// `1 + breathDepth` half a period in, back to 1 — a calm breath that only ever brightens.
        func breath(held: Float) -> Float {
            let h = max(0, held)
            return 1 + breathDepth * 0.5 * (1 - cos(2 * .pi * h / max(0.01, breathPeriod)))
        }

        /// After the release: from the breath's level at the release back to 1 over `settle` seconds.
        func settled(from level: Float, elapsed: Float) -> Float {
            level + (1 - level) * V4.smoothstep(0, max(0.001, settle), elapsed)
        }

        enum Reason: String, Equatable {
            case materialsReady = "materials ready"
            case cap = "cap reached"
            case materialsFailed = "materials failed"
        }

        enum Decision: Equatable {
            case wait
            case release(Reason)
        }

        /// Each frame of the hold: release when A1's style is on the card, when it can no longer come, or at the cap.
        func decide(styleReady: Bool, mayStillArrive: Bool, held: Double) -> Decision {
            if styleReady { return .release(.materialsReady) }
            if !mayStillArrive { return .release(.materialsFailed) }
            return held >= cap ? .release(.cap) : .wait
        }
    }
}

extension V4.GoldDustSpec {
    /// The hold's lingering dust: the trail's motes, a third as many (≈ 33 a second), born anywhere along the held
    /// outline (the emitter hops to a new point on it every frame) for at most the hold's cap. The trail stopped at the
    /// closure and the dissolve's motes are dying out, so the air never holds more than the recognition's own peak.
    var linger: Emitter {
        var e = trail
        e.birthRate = trail.birthRate * 0.35
        e.emitSeconds = Float(V4.HandOverHold.standard.cap)
        e.streak = 0
        return e
    }
}
