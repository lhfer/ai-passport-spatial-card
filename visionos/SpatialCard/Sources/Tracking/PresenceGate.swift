import Foundation
import simd

/// Persistent-recognition state machine (plan §8 C2): turns image-anchor observations, device events and world
/// state into a `Presence` for the hologram plus the `Transition` that should carry it there. It is the only
/// way anything reaches `HologramController.apply(presence:transition:)`.
///
/// The point of the design: the hologram never disappears or replays because of a button press, a short
/// occlusion, a pick-up-and-put-down or a theme redraw. Losing the image only *freezes* the last pose (`held`).
///
/// v2 (plan 工作包 A): recognition places the card, it no longer decides whether the card exists. Once revealed
/// the card stays until something explicit takes it away (`requestDismiss` / `requestReplay` / `forceHide`) —
/// `graceTimeout` is
/// `.infinity` and the freeze is *visually silent*; only after `searchCueAfter` of being held while in view does
/// the gate emit `.search`, the one transition that may shimmer. `legacyHide` (`--legacy-hide`) restores v1's
/// timed disappearance for A/B comparisons on the headset.
///
/// Pure value type with an injected clock (every mutating call takes `at time`, one monotonic clock), no
/// ARKit dependency, so the scenarios in `SpatialCardTests` can be driven deterministically.
struct PresenceGate {
    enum CarryReason: Equatable {
        case moving
        case notFlat
    }

    enum HoldReason: Equatable {
        /// No anchor update for `staleSoft`.
        case stale
        /// ARKit reported `isTracked == false` / removed the anchor.
        case untracked
        /// A device button was pressed: the nudge must not move the hologram (`buttonHold`).
        case button
        /// The device is redrawing its screen (`will_change` … `changed`, capped at `themeHoldCap`).
        case theme
        /// A world is active (tracking stops under `.full`); unlimited.
        case world
    }

    enum Presence: Equatable {
        case absent
        case acquiring
        case expanded
        case carrying(CarryReason)
        case settling
        case held(HoldReason)

        var label: String {
            switch self {
            case .absent: return "absent"
            case .acquiring: return "acquiring"
            case .expanded: return "expanded"
            case .carrying(.moving): return "carrying(moving)"
            case .carrying(.notFlat): return "carrying(notFlat)"
            case .settling: return "settling"
            case .held(let r): return "held(\(r))"
            }
        }

        /// Fresh observations drive this state (as opposed to `absent` / `held`).
        var isTracking: Bool {
            switch self {
            case .acquiring, .expanded, .carrying, .settling: return true
            case .absent, .held: return false
            }
        }

        var isHeld: Bool {
            if case .held = self { return true }
            return false
        }

        /// The device is in the wearer's hand (工作包 G2 rule 5 reads this: in hand the image tracker is the
        /// source that lies, so it loses its veto over the object).
        var isCarrying: Bool {
            if case .carrying = self { return true }
            return false
        }

        var holdReason: HoldReason? {
            if case .held(let r) = self { return r }
            return nil
        }

        /// The card is (or stays) on screen in this state, in whatever form.
        var showsHologram: Bool {
            switch self {
            case .expanded, .settling, .carrying, .held: return true
            case .absent, .acquiring: return false
            }
        }
    }

    enum Transition: Equatable {
        /// Full reveal choreography (once per session, or after `requestReplay`).
        case cinematic
        /// Short (≤ 1 s) reappearance after a hide.
        case reentry
        /// Card shrinks and rides along while the device is carried; desk effects stay put.
        case carry
        /// Spring back to full size at the new resting place.
        case settle
        /// Stop following the pose. **Visually silent**: nothing on the card may change (v2 — a 0.8 s gap in a
        /// 6 Hz image stream is normal, and a shimmer on every gap was the "breathing" the first device test saw).
        case freeze
        /// Held (stale / untracked) for `searchCueAfter` while in view: now the card may show it is looking.
        case search
        /// Resume following: glide over `glide` metres between the frozen and the new pose.
        case thaw(glide: Float)
        case hide

        var label: String {
            switch self {
            case .cinematic: return "cinematic"
            case .reentry: return "reentry"
            case .carry: return "carry"
            case .settle: return "settle"
            case .freeze: return "freeze"
            case .search: return "search"
            case .thaw(let d): return String(format: "thaw(%.1f cm)", d * 100)
            case .hide: return "hide"
            }
        }
    }

    /// Why a `.hide` happened. The card only ever leaves on purpose, and each purpose leaves the desk in a
    /// different state — which is why the controller needs to be told rather than to guess from the presence.
    enum HideKind: Equatable {
        /// The wearer folded the card away (base-ring tap, `cmd hide`): the socket light stays on the device,
        /// dimmed and tappable, and observations are ignored until `requestShow()`.
        case dismiss
        /// `requestReplay()`: the same fold, but the cinematic relights everything `replayDelay` later.
        case replay
        /// The session is going away (`forceHide`): fade the whole presentation out, nothing is coming back.
        case teardown
    }

    /// One presence change, in order. `transition` is nil for silent changes (settling → expanded, absent → acquiring).
    struct Event: Equatable {
        var presence: Presence
        var transition: Transition?
        /// Set exactly when `transition == .hide`.
        var hideKind: HideKind?
        /// `absent → acquiring` for the session's (or a replay's) first detection: the acquire glint plays only then.
        var firstAcquire = false
        /// This thaw ends a world hold — directly, or after the wait in `held(.stale)` because the card was not seen
        /// yet when the world released the desk: the return-from-world light plays either way.
        var resumeFromWorld = false
    }

    // MARK: Constants

    var stationaryDelay: TimeInterval = 0.3
    /// Small motion that restarts the stationary timer (acquiring / carrying) and the rest-pose dwell.
    var moveDistance: Float = 0.015
    var moveAngle: Float = 6 * .pi / 180
    /// Clear motion that collapses a resting card into `carrying`, measured against `restPose` — where the card has
    /// been sitting — rather than against the previous frame, and only once it has held for `collapseSustain`.
    var collapseDistance: Float = 0.05
    var collapseAngle: Float = 18 * .pi / 180
    var collapseSustain: TimeInterval = 0.25
    /// The accepted pose must sit inside `moveDistance` / `moveAngle` of where it settled for this long before
    /// `restPose` follows it. A continuous slide never qualifies, so it is still allowed to collapse.
    var restDwell: TimeInterval = 0.5
    /// Continuity gate (`.expanded` / `.settling` only). Tracked image-anchor updates arrive at 22–30 Hz on the
    /// headset, so a step this large between two consecutive ones is not a device lying on a desk (5 cm in 40 ms
    /// = 1.25 m/s): it is ARKit losing the 37 mm self-lit target. Device round 1 produced a single *tracked* pose
    /// 9.8 cm / 20° away with nobody touching the device, the gate ran carrying → settling → expanded at that
    /// wrong spot for 1.2 s and only then went untracked. That churn is what the gate removes.
    var jumpDistance: Float = 0.05
    var jumpAngle: Float = 15 * .pi / 180
    /// A jumped pose reported in the same place for this long *and* passing `isCardOnDesk` is a real relocation.
    /// Drift persists too (until ARKit gives up), so the sanity check — not the dwell — is what actually decides.
    var jumpAcceptAfter: TimeInterval = 1.5
    /// "Could this be the card lying on the desk?": the image normal within this of gravity …
    var acceptTiltMax: Float = 6 * .pi / 180
    /// … and no further than this above / below where the card was resting. Computed from the pose here rather
    /// than taken from `CardTracker.isFlat`, whose hysteresis (enter 30°, exit 42°) is far too generous for it.
    var acceptHeightDelta: Float = 0.02

    // MARK: Acceptance policy (v3 H1)

    /// **The rule set that kept the card off the wearer's hand.** Everything above — the fixed 5 cm / 15° step,
    /// the 1.5 s dwell, and above all the "it must look like a card lying flat at the same height" test — was
    /// written for the *image* tracker, whose failure mode is a drifted detection of a 37 mm self-lit target
    /// that ARKit keeps reporting as tracked. Against that, "only accept a pose that reads like a card on a
    /// desk" is exactly right.
    ///
    /// The object tracker fails differently: it either has the slab or it does not. Its detections while the
    /// device is in a hand are *correct* and are tilted and 20 cm higher by definition — and the first Extended
    /// device round rejected every single one of them (`[gate] ignoring detection (20.8 cm, tilt 24° > 6°)`,
    /// `height Δ 22.9 cm > 2.0 cm`) while the card sat frozen on the desk. So the object source turns this off
    /// (`CardTracker` sets it from `activeSource`) and gets a *velocity* test instead: a step no human hand
    /// could have made in the time since the last accepted pose is still an outlier, everything else is the
    /// device moving. The image source keeps the desk test, unchanged, and so does every existing test.
    var deskOnlyAcceptance = true
    /// Fastest plausible hand: 1.5 m/s. At the object tracker's 13–30 Hz that is 5–11 cm between observations,
    /// which is why the fixed 5 cm threshold had to go even before the tilt test did.
    var maxHandSpeed: Float = 1.5
    /// …and 200°/s of turn, which is a brisk wrist roll.
    var maxHandTurn: Float = 200 * .pi / 180
    /// The velocity test never grows the threshold beyond one of these gaps' worth: a 2 s stall must not buy
    /// the next pose a 3 m licence.
    var handStepCap: TimeInterval = 0.25
    /// A step past the velocity limit is a *candidate*: one more observation this close to it, this soon,
    /// accepts it. No 1.5 s dwell — in the hand that is a visible freeze, and the object tracker's outliers do
    /// not repeat in the same place the way a drifted image detection does.
    var handConfirmWindow: TimeInterval = 0.4
    var settleDuration: TimeInterval = 0.45
    /// No tracked update for this long → `held(.stale)`. Image tracking runs at ≈ 6 Hz in `.mixed` and the real
    /// device drops below that on a 37 mm self-lit LCD: 0.5 s froze and thawed every few seconds (v1 field test),
    /// 0.8 s rides out a missed update or two.
    var staleSoft: TimeInterval = 0.8
    /// `held(.stale/.untracked)` for this long (counted only while in view and not paused) → `absent`.
    /// v2 default: `.infinity` — losing the image never hides the card. `legacyHide` puts v1's 6 s back.
    var graceTimeout: TimeInterval = .infinity
    /// v1 behaviour (`--legacy-hide`): the stale grace and the theme / world reacquire windows expire into `.hide`,
    /// so the two policies can be compared on the headset in one session pair.
    var legacyHide = false {
        didSet { graceTimeout = legacyHide ? PresenceGate.legacyGraceTimeout : .infinity }
    }
    static let legacyGraceTimeout: TimeInterval = 6
    /// Held (stale / untracked) and in view for this long → one `.search` transition (the only visible sign that
    /// the card is not being seen). Reset by every new hold and every thaw.
    var searchCueAfter: TimeInterval = 3.0
    var themeHoldCap: TimeInterval = 3
    /// Grace after a theme change ends (the device shows a new image; give ARKit time to find it). Only armed as a
    /// hide deadline under `legacyHide`; `CardTracker` also reads it as the window in which only the new theme's
    /// image may take over the pose, which is why it keeps its value in both modes.
    var themeReacquireWindow: TimeInterval = 8
    /// Grace after a world ends (the hologram comes back through the opening shell). `legacyHide` only.
    var worldReacquireWindow: TimeInterval = 6
    var buttonHold: TimeInterval = 1.5
    /// Collapse thresholds are doubled this long after the button hold ends.
    var buttonBoost: TimeInterval = 1.5
    /// `requestReplay`: hide, then the next observation plays the cinematic after this long.
    var replayDelay: TimeInterval = 1.3
    /// Director mode: grace never runs out.
    var directorMode = false
    var logging = true

    // MARK: State

    private(set) var presence: Presence = .absent
    /// The cinematic reveal plays once per session; later appearances use `reentry`. Reset by `requestReplay`.
    private(set) var revealedOnce = false
    /// The wearer folded the card into the device: every observation is ignored until `requestShow()` /
    /// `requestReplay()`. This is the only way the card stays away while the image is in plain sight — it is a
    /// *decision*, which is exactly what v2 wanted hiding to be.
    private(set) var isDismissed = false
    /// Monotonic count of queued events. `CardTracker` publishes it so the RealityView update closure re-runs for
    /// same-presence events too (`.search` changes nothing observable otherwise, and would sit in the FIFO until
    /// the thaw drained it — the shimmer would then blink on and straight off).
    private(set) var eventCount = 0
    /// Thaws whose glide was larger than `relocateDistance`: the card came back somewhere else. Reported in the
    /// 5 s `[gate] Σ` line.
    private(set) var relocateCount = 0
    /// Tracked observations rejected by the continuity gate. Also in the `Σ` line (`outliers=`).
    private(set) var outlierCount = 0
    /// A thaw further than this counts as a relocation rather than tracking noise.
    var relocateDistance: Float = PresenceGate.relocateDistanceDefault
    /// Same, as a constant `HologramController` can read without owning a gate (it picks the glide kind from it).
    static let relocateDistanceDefault: Float = 0.02
    /// … and no further than this in angle. Inside both, a detection means "the card is where it was": thaw at once.
    var relocateAngle: Float = 10 * .pi / 180
    /// A relocation needs a second detection this soon after the first …
    var relocateConfirmWindow: TimeInterval = 0.6
    /// … and this close to it. A false positive (a reflection, a sibling theme) lands somewhere else every time,
    /// so two consistent detections are what separates "the card was put down over there" from "ARKit blinked".
    var relocateConsistency: Float = 0.015
    var relocateConsistencyAngle: Float = 6 * .pi / 180
    private var events: [Event] = []

    /// The last observation the gate **accepted** as the card's real pose (see the continuity gate). Everything
    /// downstream — the presentation, `frozenPose`, the thaw glide — uses this, never a raw observation.
    private var lastPose: simd_float4x4?
    private var frozenPose: simd_float4x4?
    /// Where the card has been resting: what the collapse test measures against. It only follows the accepted pose
    /// once that pose has been still for `restDwell`.
    private var restPose: simd_float4x4?
    /// Start of the current "still" window and the pose it is anchored to (`restDwell`).
    private var stillSince: TimeInterval?
    private var stillAnchor: simd_float4x4?
    /// Since when the accepted pose has been continuously far from `restPose` (nil = not far). `collapseSustain`.
    private var farSince: TimeInterval?
    /// A tracked observation that broke the continuity gate, waiting to be confirmed or forgotten.
    private var jumpCandidate: (pose: simd_float4x4, firstSeen: TimeInterval, logged: Bool)?
    /// First detection of a possible relocation while held, waiting for a second consistent one.
    private var relocateCandidate: (pose: simd_float4x4, time: TimeInterval)?
    /// Rate limit for the "ignoring tilted detection" line (a reflection can produce one per frame).
    private var lastTiltLog: TimeInterval = -.infinity
    private var lastMotionTime: TimeInterval = 0
    private var lastTrackedTime: TimeInterval?
    /// When the gate last **accepted** a pose: the clock the object source's velocity threshold is measured
    /// over (`continuityLimits`). Nil = nothing accepted yet, which makes the first step free.
    private var lastAcceptTime: TimeInterval?
    private var isFlat = true
    private var inView = true
    private var paused = false
    private var settleStart: TimeInterval = 0
    private var resumeTo: Presence = .expanded
    private var holdStart: TimeInterval = 0
    private var buttonUntil: TimeInterval = 0
    private var boostUntil: TimeInterval = 0
    private var reacquireWindow: TimeInterval?
    /// Time spent in the current stale / untracked hold *while in view* — the search cue's countdown, and the
    /// hide countdown under `legacyHide`.
    private var graceElapsed: TimeInterval = 0
    /// The `.search` transition has already been emitted for this hold (it fires once, not on a timer).
    private var searchCued = false
    private var lastTickTime: TimeInterval?
    private var replayUntil: TimeInterval?
    private var lastChangeTime: TimeInterval?
    /// A world hold ended without the card in view: the eventual thaw still gets the return light.
    private var resumeFromWorld = false

    // MARK: Inputs

    /// Feed every image-anchor update here (tracked or not). `isFlat` comes from the tracker's hysteresis gate.
    /// Returns whether the observation was **accepted**: a rejected one is tracking noise and must not reach the
    /// presentation either (`CardTracker` only writes `latestPose` when this is true).
    @discardableResult
    mutating func observe(pose: simd_float4x4, isTracked: Bool, isFlat: Bool, at time: TimeInterval) -> Bool {
        self.isFlat = isFlat
        // Folded away on purpose: seeing the card again is not a reason to bring it back — the presence stays
        // `absent` until `requestShow()` / `requestReplay()`. The *pose* is a different question: the socket light
        // is still burning on the device and it is the way back, so a tracked observation that survives the
        // continuity gate is still accepted (`CardTracker` writes `latestPose`, `anchorRoot` follows) and the glow
        // rides along when the device is moved while the card is away. Nothing else is touched: no presence
        // change, no event, no rest pose, no jump candidate — there is no presentation to relocate.
        if isDismissed {
            guard isTracked else {
                // A gap while the card is away starts a fresh chain: there is no presentation to protect, and
                // without this a device carried out of view and put down somewhere else would strand the socket
                // light on the old spot for good (the same "it must never become un-thawable" rule the
                // relocation escape hatch follows).
                lastPose = nil
                return false
            }
            lastTrackedTime = time
            // The continuity gate still applies. Device round 1 produced a *tracked* pose 9.8 cm / 20° away with
            // nobody touching the device; carrying the socket light off the screen with it would be the same bug
            // in a smaller costume. A device that is really being moved arrives as continuous steps and passes.
            if let previous = lastPose {
                let (distance, angle) = PresenceGate.delta(from: previous, to: pose)
                let (maxStep, maxAngle) = continuityLimits(at: time)
                guard distance <= maxStep, angle <= maxAngle else {
                    outlierCount += 1
                    return false
                }
            }
            lastPose = pose
            lastAcceptTime = time
            return true
        }
        if let until = replayUntil {
            guard time >= until else { return false }
            replayUntil = nil
        }
        guard isTracked else {
            if presence.isTracking { freeze(.untracked, at: time, reason: "untracked") }
            return false
        }

        // ARKit is still *seeing* the image even when the pose it reports is not believable, so staleness counts
        // from here: a rejected observation is a bad pose, not a lost card.
        lastTrackedTime = time

        // Held: the frozen pose *is* the hold, and while it is stale / untracked a detection only becomes the
        // accepted pose when it actually thaws — a tilted false positive must not quietly become "where the card
        // is" and then be used as the thaw's destination.
        if presence.isHeld {
            jumpCandidate = nil
            guard let why = presence.holdReason, why == .stale || why == .untracked else {
                // button / theme / world: the pose keeps being recorded, so the release can glide to it.
                lastPose = pose
                lastAcceptTime = time
                return true
            }
            return evaluateRelocation(pose: pose, at: time)
        }

        // Continuity gate: only where the card is supposed to be resting. While it is carried the device really is
        // moving, and while acquiring there is no accepted pose to compare against yet.
        var acceptedJump: Float?
        if presence == .expanded || presence == .settling, let accepted = lastPose {
            let (jumpD, jumpA) = PresenceGate.delta(from: accepted, to: pose)
            let (maxStep, maxAngle) = continuityLimits(at: time)
            if jumpD > maxStep || jumpA > maxAngle {
                guard trackJump(pose: pose, distance: jumpD, angle: jumpA, at: time) else {
                    outlierCount += 1
                    return false
                }
                acceptedJump = jumpD
            } else {
                jumpCandidate = nil
            }
        } else {
            jumpCandidate = nil
        }

        var distance: Float = 0, angle: Float = 0
        if let previous = lastPose {
            (distance, angle) = PresenceGate.delta(from: previous, to: pose)
        }
        lastPose = pose
        lastAcceptTime = time
        let boost: Float = time < boostUntil ? 2 : 1
        let clearlyMoved = distance > collapseDistance * boost || angle > collapseAngle * boost
        let moved = distance > moveDistance || angle > moveAngle
        if presence == .absent {
            noteRest(pose: pose, at: time)
            lastMotionTime = time
        } else if updateStillWindow(pose: pose, at: time) {
            // "Moving" is measured over a window, not per frame: at 22–30 Hz a real 0.3 m/s slide is 1 cm between
            // two updates, which the old per-frame threshold read as standing still — the card would have settled
            // in mid-carry. The window also feeds `restPose`.
            lastMotionTime = time
        }

        if let glide = acceptedJump {
            // The jumped pose held its ground and looks like a card on the desk: the card was moved while we could
            // not see it happen. The presence does not change, only the pose — the controller glides there.
            relocateCount += 1
            noteRest(pose: pose, at: time)
            change(to: presence, transition: .thaw(glide: glide),
                   reason: String(format: "jump accepted after %.1f s", jumpAcceptAfter), at: time)
            return true
        }

        switch presence {
        case .absent:
            change(to: .acquiring, transition: nil, reason: "tracked", at: time, firstAcquire: !revealedOnce)
        case .acquiring:
            if !isFlat {
                noteCarryReveal()
                change(to: .carrying(.notFlat), transition: .carry, reason: "not flat", at: time)
            } else if clearlyMoved {
                noteCarryReveal()
                change(to: .carrying(.moving), transition: .carry, reason: String(format: "moved %.1f cm / %.0f°", distance * 100, angle * 180 / .pi), at: time)
            } else {
                evaluateStationary(at: time)
            }
        case .expanded, .settling:
            // Both are "the card is resting here": the same rest-pose test decides, so a single outlier (which the
            // continuity gate has already dropped) and a small nudge never fold the card away.
            if !isFlat {
                change(to: .carrying(.notFlat), transition: .carry, reason: "not flat", at: time)
            } else if let why = evaluateCollapse(pose: pose, boost: boost, at: time) {
                change(to: .carrying(.moving), transition: .carry, reason: why, at: time)
            }
        case .carrying(let why):
            if !isFlat, why != .notFlat {
                change(to: .carrying(.notFlat), transition: nil, reason: "not flat", at: time)
            } else if isFlat, why != .moving, moved {
                change(to: .carrying(.moving), transition: nil, reason: "flat again, moving", at: time)
            } else {
                evaluateStationary(at: time)
            }
        case .held:
            break          // handled above, before the continuity gate
        }
        return true
    }

    /// ARKit removed the anchor.
    mutating func markRemoved(at time: TimeInterval) {
        if presence.isTracking { freeze(.untracked, at: time, reason: "anchor removed") }
    }

    /// Timer-driven evaluation (≈ 20 Hz): stationary timers, staleness, grace and hold caps.
    mutating func tick(at time: TimeInterval) {
        defer { lastTickTime = time }
        let dt = lastTickTime.map { max(0, time - $0) } ?? 0
        if let until = replayUntil, time >= until { replayUntil = nil }
        guard !paused else { return }

        switch presence {
        case .absent:
            break
        case .acquiring, .carrying:
            if isStale(at: time) { freeze(.stale, at: time, reason: String(format: "stale %.2fs", time - (lastTrackedTime ?? time))) }
            else { evaluateStationary(at: time) }
        case .expanded:
            if isStale(at: time) { freeze(.stale, at: time, reason: String(format: "stale %.2fs", time - (lastTrackedTime ?? time))) }
        case .settling:
            if isStale(at: time) { freeze(.stale, at: time, reason: String(format: "stale %.2fs", time - (lastTrackedTime ?? time))) }
            else if time - settleStart >= settleDuration { change(to: .expanded, transition: nil, reason: "settled", at: time) }
        case .held(.button):
            if time >= buttonUntil { release(reason: "button hold over", at: time, window: nil) }
        case .held(.theme):
            // The reacquire window is a *hide deadline* and therefore v1-only — `endHold` already gates its windows
            // on `legacyHide`, and this call used not to: a theme hold that hit the cap while the image was not
            // being seen went `held(.stale)` with an 8 s fuse and then vanished, which is exactly the loss-hide v2
            // forbids. (`CardTracker` reads `themeReacquireWindow` separately, as the "only the new theme's image
            // may take the pose" window; that is unaffected.)
            if time - holdStart >= themeHoldCap {
                release(reason: String(format: "theme cap %.0fs", themeHoldCap), at: time,
                        window: legacyHide ? themeReacquireWindow : nil)
            }
        case .held(.world):
            break
        case .held(.stale), .held(.untracked):
            if let candidate = relocateCandidate, time - candidate.time > relocateConfirmWindow {
                relocateCandidate = nil
                if logging { print("[gate] relocation candidate expired") }
            }
            if inView { graceElapsed += dt }
            // The freeze itself was silent; after `searchCueAfter` of not being seen *while the wearer is looking
            // at it* the card may say so once. Out of view (or paused) nothing accumulates and nothing shimmers.
            if !searchCued, graceElapsed >= searchCueAfter {
                searchCued = true
                change(to: presence, transition: .search, reason: String(format: "searching %.1fs", graceElapsed), at: time)
            }
            let limit = directorMode ? .infinity : (reacquireWindow ?? graceTimeout)
            if graceElapsed >= limit {
                resumeFromWorld = false
                change(to: .absent, transition: .hide, reason: String(format: "grace %.1fs", graceElapsed), at: time,
                       hideKind: .teardown)
                reacquireWindow = nil
                graceElapsed = 0
            }
        }
    }

    /// The card is outside the wearer's field of view: the grace countdown pauses (nothing hides).
    mutating func setInView(_ inView: Bool, at time: TimeInterval) {
        self.inView = inView
    }

    /// Paused under `.full` immersion: no staleness, no grace (the world hold covers the rest).
    mutating func setPaused(_ paused: Bool, at time: TimeInterval) {
        guard paused != self.paused else { return }
        self.paused = paused
        if !paused, presence.isTracking { lastTrackedTime = time }
    }

    /// Device button: freeze for `buttonHold` (no visual), then double the collapse thresholds for `buttonBoost`.
    mutating func buttonPressed(at time: TimeInterval) {
        buttonUntil = time + buttonHold
        boostUntil = buttonUntil + buttonBoost
        if presence.isTracking {
            beginHold(.button, at: time)
        }
    }

    /// Explicit hold (`.theme` from `will_change`, `.world` from entering a world). From `absent` it is a no-op.
    mutating func beginHold(_ reason: HoldReason, at time: TimeInterval) {
        switch presence {
        case .absent:
            return
        case .acquiring, .expanded, .carrying, .settling:
            resumeTo = presence == .settling ? .expanded : presence
            frozenPose = lastPose
            holdStart = time
            graceElapsed = 0
            searchCued = false
            reacquireWindow = nil
            change(to: .held(reason), transition: .freeze, reason: "hold \(reason)", at: time)
        case .held(let current):
            guard PresenceGate.priority(reason) > PresenceGate.priority(current) else { return }
            holdStart = time
            change(to: .held(reason), transition: nil, reason: "hold \(reason)", at: time)
        }
    }

    /// The reason is over (`changed` arrived / the world is back on the desk): thaw if the image is being tracked,
    /// otherwise wait in `held(.stale)` with the reason's reacquire window. `trackedRecently` overrides the gate's
    /// own judgement (the tracker passes `false` when the device switched to another image: observations of the
    /// old one must not thaw).
    mutating func endHold(_ reason: HoldReason, trackedRecently: Bool? = nil, at time: TimeInterval) {
        guard presence == .held(reason) else { return }
        // The windows are hide deadlines only in v1 mode; in v2 the wait in `held(.stale)` is unbounded, like
        // every other loss of the image. (`themeReacquireWindow` keeps its value either way: `CardTracker` reads it
        // as the window in which only the newly announced theme's image may take the pose.)
        var window: TimeInterval?
        if legacyHide {
            switch reason {
            case .theme: window = themeReacquireWindow
            case .world: window = worldReacquireWindow
            default: window = nil
            }
        }
        release(reason: "end \(reason)", at: time, window: window, trackedRecently: trackedRecently, after: reason)
    }

    /// The wearer put the card away (base-ring tap / `cmd hide`): fold it into the device and stay away —
    /// observations are ignored until `requestShow()` or `requestReplay()`. `revealedOnce` is deliberately kept,
    /// so coming back is a `reentry`, not a second cinematic.
    mutating func requestDismiss(at time: TimeInterval) {
        guard !isDismissed else { return }
        isDismissed = true
        replayUntil = nil
        reacquireWindow = nil
        graceElapsed = 0
        searchCued = false
        resumeFromWorld = false
        clearPoseTracking()
        if presence != .absent {
            change(to: .absent, transition: .hide, reason: "dismiss", at: time, hideKind: .dismiss)
        }
    }

    /// Undo a dismiss (socket tap / `cmd show`): the next time the image is seen the card comes back with a
    /// `reentry`. A no-op when nothing was dismissed.
    ///
    /// **v4 B3 §2** `replayRecognition`: the summon is the whole recognition again, not a reentry — `revealedOnce` goes
    /// back to false (as `requestReplay` does), so the next detection is a first acquire (`firstAcquire`) and resolves
    /// as a `cinematic` on the desk or a `carry` in the hand, exactly like the session's first one. Nothing else of the
    /// replay is borrowed: no hide (the card is already away) and no `replayDelay` gap (the wearer is waiting for it).
    mutating func requestShow(at time: TimeInterval, replayRecognition: Bool = false) {
        guard isDismissed else { return }
        isDismissed = false
        lastTrackedTime = nil
        if replayRecognition { revealedOnce = false }
        if logging {
            print("[gate] show requested (dismissed → listening again\(replayRecognition ? "; the recognition plays again" : ""))")
        }
    }

    /// Session teardown: whatever is shown goes now (a restart replays the cinematic on a clean desk).
    mutating func forceHide(at time: TimeInterval, reason: String) {
        replayUntil = nil
        reacquireWindow = nil
        graceElapsed = 0
        searchCued = false
        frozenPose = nil
        lastPose = nil
        lastTrackedTime = nil
        lastAcceptTime = nil
        resumeFromWorld = false
        clearPoseTracking()
        if presence != .absent {
            change(to: .absent, transition: .hide, reason: reason, at: time, hideKind: .teardown)
        }
    }

    /// New tracking session: forget every pose and timer and arm the cinematic again, but keep the queued events
    /// (the `.hide` from the teardown still has to reach the controller).
    mutating func beginSession() {
        let pending = events
        reset()
        events = pending
    }

    /// Hide now and play the cinematic reveal again `replayDelay` later.
    mutating func requestReplay(at time: TimeInterval) {
        revealedOnce = false
        isDismissed = false
        // Observations are ignored for the gap; the first one after it restarts the stationary timer, so the
        // cinematic lands `replayDelay` after the hide.
        replayUntil = time + max(0, replayDelay - stationaryDelay)
        reacquireWindow = nil
        graceElapsed = 0
        searchCued = false
        resumeFromWorld = false
        clearPoseTracking()
        if presence != .absent {
            change(to: .absent, transition: .hide, reason: "replay", at: time, hideKind: .replay)
        }
    }

    /// Next queued presence change (FIFO), or nil.
    mutating func takeEvent() -> Event? {
        events.isEmpty ? nil : events.removeFirst()
    }

    mutating func reset() {
        presence = .absent
        revealedOnce = false
        isDismissed = false
        events.removeAll()
        lastPose = nil
        frozenPose = nil
        lastMotionTime = 0
        lastTrackedTime = nil
        lastAcceptTime = nil
        isFlat = true
        inView = true
        paused = false
        resumeTo = .expanded
        buttonUntil = 0
        boostUntil = 0
        reacquireWindow = nil
        graceElapsed = 0
        searchCued = false
        lastTickTime = nil
        replayUntil = nil
        lastChangeTime = nil
        resumeFromWorld = false
        outlierCount = 0
        relocateCount = 0
        clearPoseTracking()
    }

    /// Everything the continuity gate and the collapse test carry between observations.
    private mutating func clearPoseTracking() {
        restPose = nil
        stillSince = nil
        stillAnchor = nil
        farSince = nil
        jumpCandidate = nil
        relocateCandidate = nil
    }

    // MARK: Derived

    /// While held: how far the latest tracked pose is from the frozen one (a pick-up inside a `.mixed` world).
    var heldDisplacement: Float {
        guard presence.isHeld, let f = frozenPose, let l = lastPose else { return 0 }
        return PresenceGate.delta(from: f, to: l).distance
    }

    var isPaused: Bool { paused }

    /// The most recent observation the gate accepted as the card's real pose.
    var acceptedPose: simd_float4x4? { lastPose }

    /// A far detection is waiting for a second, consistent one (`[gate] Σ … cand=`).
    var hasRelocateCandidate: Bool { relocateCandidate != nil }

    // MARK: Internals

    private func isStale(at time: TimeInterval) -> Bool {
        guard let last = lastTrackedTime else { return false }
        return time - last > staleSoft
    }

    /// v3: the session's **first** appearance can be a carry rather than a reveal on the desk — with the
    /// object source, a passport that is already in the wearer's hand when it is first recognised goes
    /// straight `absent → acquiring → carrying`, and the controller answers that with `unfoldFromDevice`:
    /// the card visibly stands up out of the screen. That *is* the reveal. Without this the gate still owed a
    /// cinematic, and putting the passport down a few seconds later replayed the whole ink choreography on
    /// the desk (`carrying(notFlat) → expanded (stationary, first reveal · cinematic)`), which read as the
    /// card being introduced twice.
    private mutating func noteCarryReveal() {
        guard !revealedOnce else { return }
        revealedOnce = true
    }

    private mutating func evaluateStationary(at time: TimeInterval) {
        guard isFlat, time - lastMotionTime >= stationaryDelay else { return }
        switch presence {
        case .acquiring:
            let transition: Transition = revealedOnce ? .reentry : .cinematic
            revealedOnce = true
            change(to: .expanded, transition: transition, reason: "stationary", at: time)
        case .carrying:
            if revealedOnce {
                settleStart = time
                change(to: .settling, transition: .settle, reason: "stationary", at: time)
            } else {
                // Never revealed: the first presentation is always the cinematic, not a settle.
                revealedOnce = true
                change(to: .expanded, transition: .cinematic, reason: "stationary, first reveal", at: time)
            }
        default:
            break
        }
    }

    private mutating func freeze(_ reason: HoldReason, at time: TimeInterval, reason why: String) {
        resumeTo = presence == .settling ? .expanded : presence
        // The **accepted** pose, never the drifted one the continuity gate was holding: a freeze that happens while
        // ARKit is already wandering must still come back to where the card actually is (0 cm glide).
        frozenPose = lastPose
        jumpCandidate = nil
        holdStart = time
        graceElapsed = 0
        searchCued = false
        lastTickTime = time
        change(to: .held(reason), transition: .freeze, reason: why, at: time)
    }

    private mutating func thaw(reason why: String, at time: TimeInterval) {
        let glide: Float
        if let f = frozenPose, let l = lastPose { glide = PresenceGate.delta(from: f, to: l).distance } else { glide = 0 }
        if glide > relocateDistance { relocateCount += 1 }
        relocateCandidate = nil
        jumpCandidate = nil
        frozenPose = nil
        reacquireWindow = nil
        graceElapsed = 0
        searchCued = false
        let target = resumeTo
        if target == .settling { settleStart = time }
        let fromWorld = resumeFromWorld
        resumeFromWorld = false
        change(to: target, transition: .thaw(glide: glide), reason: why + (fromWorld ? ", from world" : ""), at: time, resumeFromWorld: fromWorld)
    }

    /// An explicit hold ended: resume if tracked recently, else wait in `held(.stale)` with `window` as the grace.
    /// A world hold remembers itself (`resumeFromWorld`) so the thaw after the wait still plays the return light.
    private mutating func release(reason why: String, at time: TimeInterval, window: TimeInterval?, trackedRecently: Bool? = nil, after: HoldReason? = nil) {
        if after == .world { resumeFromWorld = true }
        let recent = trackedRecently ?? (lastTrackedTime.map { time - $0 <= staleSoft } ?? false)
        if recent {
            thaw(reason: why, at: time)
        } else {
            reacquireWindow = window
            graceElapsed = 0
            searchCued = false
            lastTickTime = time          // grace counts from this moment, not from the previous tick
            change(to: .held(.stale), transition: nil, reason: why + ", not tracked", at: time)
        }
    }

    private static func priority(_ reason: HoldReason) -> Int {
        switch reason {
        case .stale, .untracked: return 0
        case .button: return 1
        case .theme: return 2
        case .world: return 3
        }
    }

    private mutating func change(to new: Presence, transition: Transition?, reason: String, at time: TimeInterval,
                                 firstAcquire: Bool = false, resumeFromWorld: Bool = false, hideKind: HideKind? = nil) {
        guard new != presence || transition != nil else { return }
        let old = presence
        presence = new
        if new != old, new == .expanded || new == .settling, let pose = lastPose {
            // Entering a resting state (reveal, settle, thaw): this is where the card is, so this is the rest pose
            // the collapse test measures against from now on.
            noteRest(pose: pose, at: time)
        }
        events.append(Event(presence: new, transition: transition, hideKind: hideKind,
                            firstAcquire: firstAcquire, resumeFromWorld: resumeFromWorld))
        eventCount += 1
        if logging {
            let delta = lastChangeTime.map { Int(((time - $0) * 1000).rounded()) } ?? 0
            let via = transition.map { " · \($0.label)" } ?? ""
            print("[gate] \(old.label) → \(new.label) (\(reason)\(via), Δ\(delta)ms)")
        }
        lastChangeTime = time
    }

    // MARK: - Continuity gate / rest pose / relocation

    /// A tracked observation that broke the continuity gate. It is not shown, not counted for the collapse and does
    /// not rebase anything — it only becomes a candidate. A candidate reported in the same place (within
    /// `relocateConsistency`) for `jumpAcceptAfter` **and** looking like a card lying flat at the rest height is a
    /// real relocation; anything else is drift and is held indefinitely, so the presentation stays where the card
    /// actually is until ARKit either comes back or gives up.
    /// How far a single observation may step from the accepted pose before it is treated as a jump.
    ///
    /// Image source (`deskOnlyAcceptance`): the fixed 5 cm / 15°, as M1b shipped. Object source: whatever a
    /// 1.5 m/s hand could have covered since the last **accepted** pose, never less than the fixed pair (so a
    /// burst of observations 3 ms apart cannot shrink the window to nothing) and never more than
    /// `handStepCap`'s worth (so a stall cannot widen it without limit).
    private func continuityLimits(at time: TimeInterval) -> (step: Float, angle: Float) {
        guard !deskOnlyAcceptance else { return (jumpDistance, jumpAngle) }
        let dt = Float(min(handStepCap, max(0, time - (lastAcceptTime ?? time))))
        return (max(jumpDistance, maxHandSpeed * dt), max(jumpAngle, maxHandTurn * dt))
    }

    /// How close a **second** detection has to land to the first for the two to count as the same thing.
    ///
    /// Image source: the fixed 1.5 cm / 6°, unchanged. Object source: that, or whatever a 1.5 m/s hand could
    /// have covered since the candidate — whichever is larger. The fixed number alone is a hidden speed limit:
    /// 1.5 cm between two observations at 30 Hz is 0.45 m/s, so a confirmation could only ever happen while
    /// the hand was nearly still, and the two paths that need one (a jump mid-carry, and re-acquiring after a
    /// pick-up loss) are exactly the moments the hand is moving. The card froze until the wearer stopped.
    private func consistencyLimits(since: TimeInterval, at time: TimeInterval) -> (distance: Float, angle: Float) {
        guard !deskOnlyAcceptance else { return (relocateConsistency, relocateConsistencyAngle) }
        let dt = Float(min(handStepCap, max(0, time - since)))
        return (max(relocateConsistency, maxHandSpeed * dt), max(relocateConsistencyAngle, maxHandTurn * dt))
    }

    /// Returns true when this observation should be accepted after all.
    private mutating func trackJump(pose: simd_float4x4, distance: Float, angle: Float, at time: TimeInterval) -> Bool {
        guard deskOnlyAcceptance else { return trackHandJump(pose: pose, distance: distance, at: time) }
        var firstSeen = time
        var logged = false
        if let candidate = jumpCandidate {
            let (d, a) = PresenceGate.delta(from: candidate.pose, to: pose)
            if d <= relocateConsistency && a <= relocateConsistencyAngle {
                firstSeen = candidate.firstSeen
                logged = candidate.logged
            }
        }
        let plausible = isCardOnDesk(pose: pose, reference: restPose ?? lastPose)
        if plausible, time - firstSeen >= jumpAcceptAfter {
            jumpCandidate = nil
            return true
        }
        if !plausible, !logged, logging {
            print(String(format: "[gate] holding drifted pose (%.1f cm, tilt %.0f°)", distance * 100,
                         PresenceGate.tilt(of: pose) * 180 / .pi))
            logged = true
        }
        jumpCandidate = (pose: pose, firstSeen: firstSeen, logged: logged)
        return false
    }

    /// The object source's version (v3 H1): a step past the velocity limit is held for exactly one more
    /// observation. If that one lands within `relocateConsistency` of it inside `handConfirmWindow`, the device
    /// really is over there and the card goes with it; anything else starts a new candidate. No dwell and no
    /// desk test — see `deskOnlyAcceptance`.
    private mutating func trackHandJump(pose: simd_float4x4, distance: Float, at time: TimeInterval) -> Bool {
        if let candidate = jumpCandidate, time - candidate.firstSeen <= handConfirmWindow {
            let (d, a) = PresenceGate.delta(from: candidate.pose, to: pose)
            let limits = consistencyLimits(since: candidate.firstSeen, at: time)
            if d <= limits.distance && a <= limits.angle {
                jumpCandidate = nil
                if logging { print(String(format: "[gate] hand jump %.1f cm accepted (2 consistent)", distance * 100)) }
                return true
            }
        }
        jumpCandidate = (pose: pose, firstSeen: time, logged: true)
        return false
    }

    /// How long the accepted pose has been sitting inside `moveDistance` / `moveAngle` of where it settled — a
    /// *window*, not a per-frame step, because a continuous slide takes small steps too. `restPose` follows the
    /// pose once the window has held for `restDwell`. Returns true when the pose has just left the window, which
    /// is what "the card is moving" means for the stationary timers.
    private mutating func updateStillWindow(pose: simd_float4x4, at time: TimeInterval) -> Bool {
        guard let anchor = stillAnchor, let since = stillSince else {
            stillAnchor = pose
            stillSince = time
            return true
        }
        let (d, a) = PresenceGate.delta(from: anchor, to: pose)
        guard d <= moveDistance && a <= moveAngle else {
            stillAnchor = pose
            stillSince = time
            return true
        }
        if time - since >= restDwell { restPose = pose }
        return false
    }

    /// Sustained collapse test for an accepted pose in `.expanded` / `.settling`: how far it is from `restPose`
    /// (where the card has been sitting), not from the previous frame, and it has to stay that far for
    /// `collapseSustain`. Returns the collapse reason once it is due, nil otherwise.
    private mutating func evaluateCollapse(pose: simd_float4x4, boost: Float, at time: TimeInterval) -> String? {
        guard let rest = restPose else { restPose = pose; farSince = nil; return nil }
        let (far, farAngle) = PresenceGate.delta(from: rest, to: pose)
        guard far > collapseDistance * boost || farAngle > collapseAngle * boost else {
            farSince = nil
            return nil
        }
        guard let since = farSince else { farSince = time; return nil }
        guard time - since >= collapseSustain else { return nil }
        farSince = nil
        return String(format: "moved %.1f cm / %.0f° for %.2f s", far * 100, farAngle * 180 / .pi, time - since)
    }

    /// The card is resting here from now on.
    private mutating func noteRest(pose: simd_float4x4, at time: TimeInterval) {
        restPose = pose
        stillAnchor = pose
        stillSince = time
        farSince = nil
    }

    /// A tracked observation while the pose is frozen. Near the frozen pose it simply means "the card is back":
    /// thaw. Anywhere else it may be a false positive — v1 thawed the card onto the first far detection, which can
    /// be a reflection — so it must look like a card on the desk *and* be confirmed by a second, consistent
    /// detection inside `relocateConfirmWindow`. `frozenPose` stays put until the thaw, so `Transition.thaw(glide:)`
    /// still reports the real distance the card travelled.
    /// Returns whether the detection was accepted (i.e. it thawed the card).
    private mutating func evaluateRelocation(pose: simd_float4x4, at time: TimeInterval) -> Bool {
        guard let frozen = frozenPose else {
            // Escape hatch: not every path into `held(.stale)` froze a pose. With nothing to confirm against there
            // is nothing to be careful about, and the card must never become un-thawable — thaw as v1 did.
            relocateCandidate = nil
            lastPose = pose
            lastAcceptTime = time
            thaw(reason: "tracked again", at: time)
            return true
        }
        let (distance, angle) = PresenceGate.delta(from: frozen, to: pose)
        if distance <= relocateDistance && angle <= relocateAngle {
            relocateCandidate = nil
            lastPose = pose
            lastAcceptTime = time
            thaw(reason: "tracked again", at: time)
            return true
        }
        // v3 H1: the object source has no desk test at all. A detection 20 cm away, tilted 60°, *is* the device
        // in the wearer's hand — the exact observation the first Extended round threw away on every frame while
        // the card sat frozen on the desk. It still needs two consistent detections below, which is what keeps
        // a single bad pose from teleporting the card.
        if deskOnlyAcceptance, let why = deskRejection(pose: pose, reference: frozen) {
            // Tilted or floating: neither a confirmation nor a candidate. The line names which of the two tests
            // failed — on the headset "tilt 1°, height Δ 19.5 cm" and "tilt 74°" are completely different
            // problems, and the old wording called both of them tilt.
            if logging, time - lastTiltLog > 2 {
                lastTiltLog = time
                print(String(format: "[gate] ignoring detection (%.1f cm, %@)", distance * 100, why))
            }
            return false
        }
        if let candidate = relocateCandidate, time - candidate.time <= relocateConfirmWindow {
            let (d, a) = PresenceGate.delta(from: candidate.pose, to: pose)
            // The same widening as the continuity gate's: a device re-acquired *while it is still moving* —
            // the normal case after a pick-up loss — would otherwise never confirm its own relocation.
            let limits = consistencyLimits(since: candidate.time, at: time)
            if d <= limits.distance && a <= limits.angle {
                lastPose = pose
                lastAcceptTime = time
                thaw(reason: String(format: "relocated %.1f cm (2 consistent)", distance * 100), at: time)
                return true
            }
        }
        relocateCandidate = (pose, time)
        if logging {
            print(String(format: "[gate] relocation candidate %.1f cm (waiting for a 2nd within %.1f s)",
                         distance * 100, relocateConfirmWindow))
        }
        return false
    }

    /// "Could this pose be the card lying on the desk?" — the image normal within `acceptTiltMax` of gravity, and
    /// within `acceptHeightDelta` of where the card was. Drifted detections are usually tilted, floating, or both.
    private func isCardOnDesk(pose: simd_float4x4, reference: simd_float4x4?) -> Bool {
        deskRejection(pose: pose, reference: reference) == nil
    }

    /// Why this pose is not a card lying on the desk (nil = it could be one). The string is the log's reason.
    private func deskRejection(pose: simd_float4x4, reference: simd_float4x4?) -> String? {
        let tilt = PresenceGate.tilt(of: pose)
        if tilt > acceptTiltMax {
            return String(format: "tilt %.0f° > %.0f°", tilt * 180 / .pi, acceptTiltMax * 180 / .pi)
        }
        guard let reference else { return nil }
        let drop = abs(pose.columns.3.y - reference.columns.3.y)
        if drop > acceptHeightDelta {
            return String(format: "height Δ %.1f cm > %.1f cm", drop * 100, acceptHeightDelta * 100)
        }
        return nil
    }

    // MARK: - Geometry helpers

    /// Translation distance (m) and rotation angle (rad) between two rigid transforms.
    static func delta(from a: simd_float4x4, to b: simd_float4x4) -> (distance: Float, angle: Float) {
        let pa = SIMD3<Float>(a.columns.3.x, a.columns.3.y, a.columns.3.z)
        let pb = SIMD3<Float>(b.columns.3.x, b.columns.3.y, b.columns.3.z)
        let distance = simd_length(pb - pa)

        let qa = PresenceGate.rotation(of: a)
        let qb = PresenceGate.rotation(of: b)
        let dot = min(1, abs(simd_dot(qa.vector, qb.vector)))
        let angle = 2 * acos(dot)
        return (distance, angle)
    }

    /// Angle (rad) between the image normal (the anchor's +Y) and world up.
    static func tilt(of m: simd_float4x4) -> Float {
        let normal = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        return acos(max(-1, min(1, simd_dot(normal, SIMD3<Float>(0, 1, 0)))))
    }

    static func rotation(of m: simd_float4x4) -> simd_quatf {
        let x = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let y = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let z = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }
}
