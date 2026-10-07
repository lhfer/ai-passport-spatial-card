import Foundation

/// Gestures read from the **device's own pose** rather than from a button (v3 H2).
///
/// The only one v3-1 ships is "turn it face down": the wearer flips the passport over on the desk or in their
/// hand and the card folds away — the physical equivalent of closing a laptop. It has to be sustained, because
/// the object tracker's orientation is the noisy half of it (12–28° of pitch/roll error while the device lay
/// *flat* on the desk in the first Extended round): a threshold with no dwell would fire on a fast wave.
///
/// Turning the device back up deliberately does **not** bring the card back — OK does. A gesture that both
/// hides and shows would make every careless flip a flicker, and "the card comes back when I ask" is the whole
/// point of v3's OK semantics.
///
/// Pure value type with an injected clock, so `DeviceGesturesTests` drives the timing deterministically.
struct DeviceGestures: Equatable {
    enum Event: Equatable {
        /// The device has been face down for `faceDownSustain`.
        case faceDown
        /// **V3-2b B4 / plan §4 E12.** The wearer has started turning the passport over — past 120°, on the
        /// way to the 150° the fold wants. No dwell at all: this *is* the causal preview of the fold, and a
        /// preview that arrives late has nothing to preview. `false` when they turn it back (< 110°, the
        /// hysteresis that keeps a device wobbling on the threshold from flickering).
        case anticipation(Bool)
    }

    /// The screen normal has to be this far past horizontal — 150° from world up is 30° short of fully
    /// inverted, which a device resting face down on a desk clears easily and a device held at a steep angle
    /// (the hand form's ~60°) never approaches.
    var faceDownTilt: Float = 150 * .pi / 180
    /// …for this long. 0.8 s is long enough that turning the device over *on the way* to somewhere else does
    /// not fire, and short enough that the fold feels like an answer to the flip.
    var faceDownSustain: TimeInterval = 0.8
    /// Once fired, the gesture re-arms only when the device is clearly the right way up again. The gap between
    /// this and `faceDownTilt` is the hysteresis that stops a device wobbling on the threshold from repeating.
    var rearmTilt: Float = 120 * .pi / 180

    /// **B4.** Where the anticipation turns on and off. `enter` is the same 120° as `rearmTilt` on purpose:
    /// "clearly not the right way up any more" is one threshold, and the card starting to gather at exactly
    /// the angle where a new flip may begin is what makes the fold read as caused by the wearer's wrist.
    var anticipationEnter: Float = 120 * .pi / 180
    var anticipationLeave: Float = 110 * .pi / 180

    /// Since when the tilt has been continuously past `faceDownTilt` (nil = it is not).
    private(set) var downSince: TimeInterval?
    /// The event has fired for this flip and will not fire again until the device comes back up.
    private(set) var fired = false
    /// The card is gathered up, waiting to see whether this flip becomes a fold.
    private(set) var anticipating = false

    init() {}

    /// One **tracked** object observation's raw tilt (its screen normal against gravity, rad). Returns the
    /// event on the tick it becomes true, and nil on every other one.
    @discardableResult
    mutating func update(tilt: Float, at time: TimeInterval) -> Event? {
        guard tilt.isFinite else { return nil }
        if tilt < rearmTilt {
            // Back up (or on its way): the dwell restarts and the gesture is armed again.
            downSince = nil
            fired = false
            return nil
        }
        guard tilt > faceDownTilt else {
            // In the hysteresis band: neither counting nor re-arming.
            return nil
        }
        guard let since = downSince else {
            downSince = time
            return nil
        }
        guard !fired, time - since >= faceDownSustain else { return nil }
        fired = true
        return .faceDown
    }

    /// **B4.** The anticipation edge of the same observation, if it crossed one.
    ///
    /// Deliberately **not** folded into `update(tilt:at:)`: that call's contract is "the face-down event, or
    /// nil", and six of this file's own tests read it that way (`XCTAssertNil` on the first tick of a 170°
    /// hold). Two entry points, one state; `CardTracker` calls this one first.
    @discardableResult
    mutating func updateAnticipation(tilt: Float) -> Event? {
        guard tilt.isFinite else { return nil }
        if !anticipating, tilt > anticipationEnter {
            anticipating = true
            return .anticipation(true)
        }
        if anticipating, tilt < anticipationLeave {
            anticipating = false
            return .anticipation(false)
        }
        return nil
    }

    /// A tracking loss: the dwell means nothing across a gap (the device could have been turned in the dark).
    /// Returns the anticipation's own edge when it was on — a card left at 0.55 opacity because the tracker
    /// blinked mid-flip would never come back on its own.
    @discardableResult
    mutating func reset() -> Event? {
        downSince = nil
        fired = false
        guard anticipating else { return nil }
        anticipating = false
        return .anticipation(false)
    }
}
