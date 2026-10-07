import Foundation

/// **V3-6 §4.** Which clock a loss of object tracking belongs to.
///
/// V3-4 started one clock — `[timing] pick-up: loss → carrying` — at *every* loss, because "a hand closing
/// over a device is a tracking loss before it is anything else". The third headset round showed the other
/// half of that sentence: so is a dark room. Both pick-ups it measured (`4.17 s`, `6.17 s`) began with the
/// passport already lost **on the desk** — 8.4 s and 1.0 s of `expanded → held(untracked)` before a hand ever
/// moved — so the number the acceptance list asks for ("pick it up → the card is in the hand form ≤ 1 s")
/// could not be read off it.
///
/// The rule: a loss with a tracked wrist inside the bridge's attach radius is a **grab** and starts the
/// pick-up clock; a loss with every tracked wrist outside it is a **desk** loss and is reported on its own
/// (`[timing] desk loss N.N s`); and a desk loss that a hand later reaches turns into a grab *at the reach*,
/// which is where the pick-up really started.
///
/// `unknown` — no hand data at all — deliberately behaves like V3-4: `--no-hands`, the simulator and every
/// `--fake-track` script without a `hand` segment have nothing to classify with, and inventing a "desk" for
/// them would silently delete the line the gate script greps.
///
/// Pure value type: the whole rule is `LossClockTests`, because the headset is the only place the inputs are
/// real and a rule that can only be checked there is a rule that is not checked.
struct LossClock: Equatable {
    enum Kind: Equatable {
        /// No hand was being tracked when the passport went: V3-4's behaviour, unchanged.
        case unknown
        /// Every tracked wrist was outside the attach radius: the passport is lying still and the camera
        /// simply cannot see it.
        case desk
        /// A wrist was inside the attach radius: this is a hand closing over the passport.
        case grab
        /// The card was **already** being carried when the camera lost the passport, so whatever this is, it
        /// is not a pick-up: a dropout in the hand, or — the case round 3 filmed — the hand occluding the
        /// passport as it is being **put down**. The thaw out of it goes straight back to `carrying`, which
        /// is why timing it as a pick-up produced `[timing] pick-up: loss → carrying 1.53 s` for a put-down.
        case inHand
    }

    private(set) var kind: Kind = .unknown
    /// When the clock that is running now started, or nil when none is.
    private(set) var lostAt: TimeInterval?

    /// `handDistance`: the nearest **tracked** wrist to where the passport was last seen, or nil when no hand
    /// is being tracked at all.
    static func classify(handDistance: Float?, radius: Float) -> Kind {
        guard let distance = handDistance, distance.isFinite else { return .unknown }
        return distance <= radius ? .grab : .desk
    }

    /// The camera lost the passport. Only the **first** untracked observation of a run of them starts a
    /// clock: the ones after it are the same loss.
    /// `carrying`: the card was in the hand form when this loss began. Nothing is being picked up then.
    mutating func lost(handDistance: Float?, radius: Float, carrying: Bool, at time: TimeInterval) {
        guard lostAt == nil else { return }
        lostAt = time
        kind = carrying ? .inHand : LossClock.classify(handDistance: handDistance, radius: radius)
    }

    /// One tick while the passport is still lost. A hand arriving at a passport that was already lost ends
    /// the desk half (returned, in seconds, for `[timing] desk loss`) and restarts the clock at the reach.
    mutating func reach(handDistance: Float?, radius: Float, at time: TimeInterval) -> TimeInterval? {
        guard let lost = lostAt, kind == .desk || kind == .unknown else { return nil }
        guard LossClock.classify(handDistance: handDistance, radius: radius) == .grab else { return nil }
        let desk: TimeInterval? = kind == .desk ? max(0, time - lost) : nil
        kind = .grab
        lostAt = time
        return desk
    }

    /// The camera has the passport again.
    ///
    /// A **desk** loss is over and says how long it was. A loss that began **in the hand** is over too and
    /// says nothing — and closing it here is not cosmetic: a card dismissed during one never reaches
    /// `carrying` or `settling`, and a clock left running would swallow the *next* loss outright, because
    /// `lost()` only starts one when none is running. (Found by running the put-down script with the OK
    /// button on top of it: the desk loss two seconds later printed nothing.)
    ///
    /// A **grab** (or an unclassifiable loss) keeps its clock, because the carry it belongs to has not
    /// happened yet — the hand-over at the end of a pick-up is `held(untracked) → carrying`, which arrives
    /// *after* the passport is visible again.
    mutating func found(at time: TimeInterval) -> TimeInterval? {
        guard let lost = lostAt, kind == .desk || kind == .inHand else { return nil }
        let was = kind
        lostAt = nil
        kind = .unknown
        return was == .desk ? max(0, time - lost) : nil
    }

    /// The card reached `carrying`: this is the pick-up, and this is how long it took.
    mutating func carried(at time: TimeInterval) -> TimeInterval? {
        guard let lost = lostAt else { return nil }
        let was = kind
        lostAt = nil
        kind = .unknown
        // A loss the card was already in the hand for has no pick-up to report — it goes back to `carrying`
        // because that is where it came from.
        guard was != .inHand else { return nil }
        return max(0, time - lost)
    }

    /// The card is **settling** onto the desk, or has gone **absent** (a dismiss, a teardown). Whatever that
    /// loss was, it was not a pick-up, and leaving its clock running would hand the number to the next one.
    ///
    /// Deliberately not `expanded` as well: `held(untracked) → expanded (relocated 12 cm) → carrying` is the
    /// relocate-then-pick-up path (`fake-track-v32-reloc-pickup.json`), and its 1.45 s is a real pick-up
    /// measured across a thaw.
    mutating func settled() {
        lostAt = nil
        kind = .unknown
    }
}
