import Foundation
import simd

/// **The hand bridge** (v3 plan H4 / V3-2b B6): what places the card during the second the object tracker
/// cannot see the passport.
///
/// The V3-1b headset round lost the object anchor **nine times in ten minutes** while the passport was in the
/// wearer's hand — 0.4 to 2.4 s each, with the device 4 to 45 cm from where it was picked up. Every one of
/// those is a `→ held(untracked)` freeze: the card stops dead in the air while the hand carrying it keeps
/// going, which on camera reads as the illusion breaking rather than as a tracker blinking.
///
/// But the hand is still being tracked. If the wearer's wrist was next to the device when it was last seen,
/// the rigid transform between the two — `T_hand→device` — is known, and while the object is missing the card
/// can be driven by `T_hand · T_hand→device` instead. The passport has not left their hand; the only thing
/// that has gone is the camera's opinion about where it is.
///
/// Three rules keep that from becoming a lie of its own:
///
/// 1. **The offset is only learned from a hand that is actually holding the device** — a wrist within
///    `attachRadius` of the device's centre, while the object *is* tracked — and it is low-passed (τ
///    `offsetTau`), so a grip that shifts is followed and one frame of nonsense is not.
/// 2. **The bridge is short.** `maxBridge` seconds and it gives up: past that the wearer has put the
///    passport down, handed it over or walked away, and a frozen card is the honest answer. (V3-5 §1 took it
///    from three seconds to six — ARKit's own re-detection after a pick-up measured 8.5 s on the headset.)
/// 3. **Coming back is a blend, not a cut.** When the object is seen again the card eases from the bridged
///    pose to the tracked one over `blendBack`, so the continuity gate sees a continuous path and does not
///    read the hand-over as a relocation.
///
/// Pure value type (simd + Foundation), so `HandBridgeTests` can drive the whole rule deterministically —
/// which matters more here than anywhere else in the app, because the simulator has neither hand tracking nor
/// object tracking and the headset is the only place this can ever run for real.
struct HandBridge {
    enum Side: String, CaseIterable, Equatable {
        case left, right

        /// How the Σ line names it: `L` / `R`.
        var initial: String { self == .left ? "L" : "R" }
    }

    /// **V3-4 §3** `--bridge-orientation frozen|hand`: where the card's *rotation* comes from during a
    /// bridge. `frozen` (the default) keeps the last orientation the camera actually saw and lets the hand
    /// supply only the translation; `hand` is V3-2b's `hand · offset`, which on the headset turned the
    /// wrist's own 5–12° of noise into 12° of card through a 10 cm lever.
    enum Orientation: String, CaseIterable, Equatable {
        case frozen, hand
    }

    /// A wrist this close to the device's centre is holding it.
    ///
    /// **V3-5 §1: 10 cm → 15 cm.** The second headset round measured a pick-up off the desk as
    /// `[timing] pick-up: loss → carrying 9.71 s` with `hands=L(-)·R(-)` and `bridged=0%` throughout: the
    /// fingers closing over the passport lose it for the camera *before* the wrist ever comes within 10 cm
    /// of its centre — reaching down from above, the wrist / middle-knuckle midpoint sits 8–12 cm away — so
    /// no offset was ever learned and there was nothing to bridge with. ARKit took 8.5 s to re-detect.
    ///
    /// Widening this used to be dangerous because `Side.allCases` picked the *first* hand inside the circle;
    /// since V3-4 §3 the rule is "whoever has held it longest", and a hand that has only just arrived is
    /// skipped (`newHandGrace`). With that in place 15 cm buys the overhead grip and still cannot reach
    /// across to the other hand's wrist.
    var attachRadius: Float = 0.15
    /// Low-pass time constant on `T_hand→device`.
    var offsetTau: Float = 0.3
    /// No *tracked* object observation for this long and the object counts as lost.
    var lossTimeout: TimeInterval = 0.15
    /// The bridge never drives the card for longer than this.
    ///
    /// **V3-5 §1: 3 s → 6 s.** Three seconds was sized for an occlusion. The case that actually hurt on the
    /// headset is a *re-detection*: ARKit needed 8.5 s to find the passport again after a pick-up, and the
    /// difference between a card that follows the hand for six of those seconds and one that freezes after
    /// three is the whole illusion. `--bridge-max` still moves it.
    var maxBridge: TimeInterval = 6.0
    /// …and hands back over this long when the object returns.
    var blendBack: TimeInterval = 0.25
    /// A hand observation older than this is not a hand any more (the provider runs at 20–90 Hz).
    var handTimeout: TimeInterval = 0.25
    /// **V3-4 §3.** An offset the camera has not confirmed for this long is a memory of a grip, not a grip.
    /// It cannot *start* a bridge (the headset round's `bridge on (right, 461.16 s after loss)` came from a
    /// hand that had held the passport minutes earlier), and a hold that resumes after a gap this long counts
    /// as a new one.
    var offsetStale: TimeInterval = 1.0
    /// A hand that has only just come into the 10 cm circle is the one **occluding** the passport, not the
    /// one carrying it. It is skipped while any other hand can carry.
    var newHandGrace: TimeInterval = 0.5
    /// A bridge may only *begin* this soon after the object was lost. Past it the wearer has put the
    /// passport down, handed it over or walked away, and the existing freeze is the honest answer.
    var engageWindow: TimeInterval = 0.5
    /// How long the take-over residual — the gap between the last tracked pose and the first bridged one —
    /// is smoothed away over. Without it the hand-over is a visible jump (the headset round measured it as
    /// `trail on (1.90–2.96 m/s)` on all three occlusions).
    var takeoverBlend: TimeInterval = 0.25
    /// Where the rotation comes from while the bridge drives.
    var orientation: Orientation = .frozen

    /// What the bridge says the card should do this tick.
    struct Drive: Equatable {
        enum Kind: Equatable {
            /// The object is missing and this hand is carrying the card.
            case bridged
            /// The object is back; this is the hand-over, easing from the bridged pose to the tracked one.
            case blending
        }
        var kind: Kind
        var pose: simd_float4x4
        var side: Side
        /// Seconds since the object was lost (`bridged`) or since it came back (`blending`).
        var elapsed: TimeInterval
        /// **V3-4 §3.** How long this hand had been holding the passport when it took over — the number the
        /// log prints, and the reason this hand was picked over the other one.
        var holding: TimeInterval = 0
        /// Seconds between the last tracked object observation and the take-over.
        var afterLoss: TimeInterval = 0

        static func == (a: Drive, b: Drive) -> Bool {
            a.kind == b.kind && a.side == b.side && a.elapsed == b.elapsed && a.pose == b.pose
                && a.holding == b.holding
        }
    }

    private struct HandState {
        var pose: simd_float4x4
        var at: TimeInterval
        var tracked: Bool
        /// `T_hand→device`, low-passed. Nil until this wrist has been seen holding the device.
        var offset: simd_float4x4?
        var offsetAt: TimeInterval?
        /// **V3-4 §3.** When this hand's *current continuous* hold began. A gap longer than `offsetStale`
        /// between two confirmations starts a new hold, so "how long has this hand been holding it" cannot
        /// be inherited from a grip two minutes ago.
        var offsetSince: TimeInterval?
    }

    private var hands: [Side: HandState] = [:]
    private(set) var lastObjectPose: simd_float4x4?
    /// When the object was last seen **tracked**.
    private(set) var lastObjectTracked: TimeInterval?
    /// Whether the most recent object observation was a tracked one. The plan's rule has two halves —
    /// "`isTracked = false` **or** no update for `lossTimeout`" — and this is the first: a provider that
    /// says out loud that it has lost the passport has lost it *now*, and making the card wait out the
    /// timeout would be 150 ms of frozen card for nothing.
    private(set) var lastObjectWasTracked = false
    /// The bridge is driving, since when and with which hand.
    private(set) var bridgingSince: TimeInterval?
    private(set) var bridgingSide: Side?
    /// The last pose the bridge produced — where the blend back starts from.
    private(set) var lastBridgedPose: simd_float4x4?
    /// **V3-4 §3.** The gap between the last tracked pose and the first bridged one, smoothed to identity
    /// over `takeoverBlend` so the hand-over has no step in it.
    private var takeoverResidual: simd_float4x4?
    /// The object came back at this time and the card is easing onto it.
    private(set) var blendingSince: TimeInterval?
    /// This loss has already used its budget: no second bridge until the object is seen again.
    private(set) var expired = false
    /// **V3-5 §1.** A world has the tracker paused (`.full` immersion): nothing is looking at the passport,
    /// so nothing here is evidence about it. See `setPaused(_:at:)`.
    private(set) var isPaused = false
    private var pausedAt: TimeInterval?

    init() {}

    /// Whether a bridge is driving the card right now (`Σ src=hand`).
    var isBridging: Bool { bridgingSince != nil }

    /// Does this hand know how it is holding the device?
    func hasOffset(_ side: Side) -> Bool { hands[side]?.offset != nil }
    /// The stored `T_hand→device` (tests, diagnostics).
    func offset(_ side: Side) -> simd_float4x4? { hands[side]?.offset }

    // MARK: - Observations

    /// One object observation, **in the screen frame S** — the same pose everything downstream is written in.
    mutating func observeObject(screen pose: simd_float4x4, tracked: Bool, at time: TimeInterval) {
        lastObjectWasTracked = tracked
        guard tracked else { return }
        lastObjectPose = pose
        lastObjectTracked = time
        expired = false
        let centre = HandBridge.translation(of: pose)
        for side in Side.allCases {
            guard var state = hands[side], state.tracked, time - state.at <= handTimeout else { continue }
            // Rule 1: only a wrist that is actually on the device teaches the offset.
            guard simd_length(HandBridge.translation(of: state.pose) - centre) <= attachRadius else { continue }
            let target = state.pose.inverse * pose
            // **V3-4 §3.** A gap longer than `offsetStale` between two confirmations is a *new* hold, not a
            // continuation of the old one: this is what the bridge sorts hands by, so it may not be
            // inherited across a minute in which the hand was somewhere else entirely.
            if let at = state.offsetAt, time - at <= offsetStale, state.offsetSince != nil {
                // still the same hold
            } else {
                state.offsetSince = time
            }
            if let current = state.offset, let at = state.offsetAt, time > at, time - at <= offsetStale {
                let alpha = 1 - exp(-Float(time - at) / max(0.0001, offsetTau))
                state.offset = HandBridge.mix(current, target, alpha)
            } else {
                state.offset = target
            }
            state.offsetAt = time
            hands[side] = state
        }
    }

    /// One hand observation: the wrist / middle-knuckle midpoint, in the same world space as the object's.
    mutating func observeHand(_ side: Side, pose: simd_float4x4, tracked: Bool, at time: TimeInterval) {
        var state = hands[side] ?? HandState(pose: pose, at: time, tracked: tracked)
        state.pose = pose
        state.at = time
        state.tracked = tracked
        hands[side] = state
    }

    // MARK: - The decision

    /// What should place the card this tick. Nil = nothing the bridge has an opinion about: either the object
    /// is doing its job, or nothing can (and the existing `held(untracked)` freeze is the right answer).
    mutating func decide(at time: TimeInterval) -> Drive? {
        // **V3-5 §1.** Inside a world the object tracker is switched off, not failing: the passport has not
        // been lost, nobody is looking for it. A bridge started here would spend its whole budget on a
        // non-loss and leave `expired` set for the moment it is actually needed — which is exactly what the
        // second headset round recorded (`bridge on (right, holding 18.1 s, 0.03 s after loss)` at world
        // entry, `3 s up` inside the world, and then a 7 s `held(world) → held(stale)` freeze on the way
        // out). Nothing is decided, nothing is spent, and nothing about the loss clock moves.
        guard !isPaused else { return nil }
        let objectIsFresh = lastObjectWasTracked && (lastObjectTracked.map { time - $0 < lossTimeout } ?? false)
        if objectIsFresh {
            // The object is back. If the bridge was driving, hand the card over rather than cutting to it.
            if bridgingSince != nil {
                blendingSince = time
                bridgingSince = nil
            }
            guard let since = blendingSince, let from = lastBridgedPose,
                  let to = lastObjectPose, let side = bridgingSide else {
                blendingSince = nil
                lastBridgedPose = nil
                return nil
            }
            let elapsed = time - since
            guard elapsed < blendBack else {
                blendingSince = nil
                lastBridgedPose = nil
                bridgingSide = nil
                return nil
            }
            // Smoothstep, so the hand-over has no corner at either end.
            let k = Float(max(0, min(1, elapsed / blendBack)))
            return Drive(kind: .blending, pose: HandBridge.mix(from, to, k * k * (3 - 2 * k)),
                         side: side, elapsed: elapsed)
        }
        blendingSince = nil
        // Rule 2: one bridge per loss, and only for `maxBridge`.
        guard !expired, let (side, state) = holdingHand(at: time), let offset = state.offset else {
            endBridge()
            return nil
        }
        // **V3-4 §3, rule 2b.** A bridge may only *start* inside `engageWindow` of the loss. Once it is
        // running it keeps running for its three seconds; this only refuses to begin one minutes later.
        let afterLoss = lastObjectTracked.map { time - $0 } ?? .greatestFiniteMagnitude
        guard bridgingSince != nil || afterLoss <= engageWindow else {
            endBridge()
            return nil
        }
        let since = bridgingSince ?? time
        guard time - since < maxBridge else {
            expired = true
            endBridge()
            return nil
        }
        let raw = bridgedPose(hand: state.pose, offset: offset)
        if bridgingSince == nil {
            // **V3-4 §3, rule 3.** The first bridged frame is almost never exactly where the last tracked one
            // was — the offset is a low-passed average of a grip that has been shifting. Remember the gap and
            // smooth it to nothing over `takeoverBlend`, so the hand-over is a glide rather than the jump the
            // headset round saw as `trail on (2.96 m/s)`.
            takeoverResidual = lastObjectPose.map { $0 * raw.inverse }
        }
        bridgingSince = since
        bridgingSide = side
        let elapsed = time - since
        var pose = raw
        if let residual = takeoverResidual {
            if elapsed >= takeoverBlend {
                takeoverResidual = nil
            } else {
                let k = Float(max(0, min(1, elapsed / takeoverBlend)))
                // Smoothstep from the whole residual to none of it: no corner at either end.
                let remaining = 1 - k * k * (3 - 2 * k)
                pose = HandBridge.mix(matrix_identity_float4x4, residual, remaining) * raw
            }
        }
        lastBridgedPose = pose
        return Drive(kind: .bridged, pose: pose, side: side, elapsed: elapsed,
                     holding: time - (state.offsetSince ?? time), afterLoss: min(afterLoss, maxBridge))
    }

    /// **V3-4 §3, rule 4.** The bridged pose: the wearer's hand supplies the **translation**, and — unless
    /// `--bridge-orientation hand` — the last frame the camera actually saw supplies the **orientation**.
    ///
    /// The wrist's pitch and roll are the noisy half of hand tracking, and the offset is a ~10 cm lever: 5°
    /// of wrist noise is 9 mm of card, and 12° of it is what the headset round measured as `rotJitter` during
    /// every occlusion. So only the wrist's **yaw** turns the lever, and the card's own facing does not move
    /// at all while the camera cannot see it — which is also what stops `DeviceGestures` seeing a 141° flip
    /// that never happened.
    private func bridgedPose(hand: simd_float4x4, offset: simd_float4x4) -> simd_float4x4 {
        guard orientation == .frozen, let last = lastObjectPose else { return hand * offset }
        let lever = simd_quatf(angle: HandBridge.yaw(of: hand), axis: [0, 1, 0])
            .act(HandBridge.translation(of: offset))
        return HandBridge.pose(rotation: HandBridge.rotation(of: last),
                               translation: HandBridge.translation(of: hand) + lever)
    }

    /// **V3-5 §1.** A world took the camera away, or gave it back.
    ///
    /// While paused `decide` answers nothing and spends nothing (see there). The interesting half is the
    /// *unpause*, and it has three parts:
    ///
    /// 1. **The unpause is the loss instant.** The last tracked observation is minutes of world ago; measured
    ///    from there every bridge is far outside `engageWindow` and can never start. Measured from here the
    ///    window is the half second after the wearer comes back, which is when the passport is in their hand
    ///    and the camera has not found it yet — the case this whole type exists for.
    /// 2. **`expired` is cleared**: whatever budget an earlier loss used, this is a different one.
    /// 3. **A grip the camera confirmed on the way in is still a grip on the way out.** `offsetStale` means
    ///    "the camera has not confirmed this for a second", and during the pause the camera confirmed
    ///    *nothing* — so the pause may not age a grip out. The confirmation of a hand that was holding the
    ///    passport when the world opened, and that has been tracked continuously ever since, is carried
    ///    across the gap. A hand that had already let go, or that is not being tracked now, is not.
    mutating func setPaused(_ paused: Bool, at time: TimeInterval) {
        guard paused != isPaused else { return }
        isPaused = paused
        guard !paused else {
            pausedAt = time
            // `blendingSince` **first**: `endBridge` deliberately keeps `bridgingSide` alive while a
            // hand-over is in flight, and a world whose shell goes opaque inside that quarter second would
            // leave the side set. `holdingHand`'s first rule then returns that hand at the unpause without
            // the `offsetStale` check — which is the one guard this whole pause path exists to respect.
            blendingSince = nil
            endBridge()
            return
        }
        let began = pausedAt ?? time
        let gap = max(0, time - began)
        pausedAt = nil
        for side in Side.allCases {
            guard var state = hands[side], let at = state.offsetAt, state.offset != nil else { continue }
            // Still on the wrist now …
            guard state.tracked, time - state.at <= handTimeout else { continue }
            // … and the camera had confirmed the grip when the world opened.
            guard began - at <= offsetStale else { continue }
            // Never into the future: in the simulator (and in `--preview`) the object keeps being observed
            // through the pause, so `at` can already be later than `began`.
            state.offsetAt = min(time, at + gap)
            // `offsetSince` is deliberately **not** moved: the hold did not restart, it carried on through
            // the world, and `holding N s` should say so.
            hands[side] = state
        }
        expired = false
        lastObjectWasTracked = false
        lastObjectTracked = time
    }

    /// Everything the bridge remembers about this loss, forgotten (a teardown, a hide, a put-down).
    mutating func reset() {
        // Same order as `setPaused` and for the same reason: `endBridge` keeps `bridgingSide` while a
        // hand-over is in flight, so the blend has to be cancelled first or a reset leaves a side behind.
        blendingSince = nil
        endBridge()
        expired = false
    }

    private mutating func endBridge() {
        bridgingSince = nil
        takeoverResidual = nil
        if blendingSince == nil {
            bridgingSide = nil
            lastBridgedPose = nil
        }
    }

    /// **V3-4 §10.** What the Σ line prints: `hands=L(0.0s)·R(4.2s*)` — how long each hand has been holding
    /// the passport, and a star on the one the bridge would pick (or is using).
    func handsSummary(at time: TimeInterval) -> String {
        Side.allCases.map { side in
            guard let state = hands[side], state.tracked, time - state.at <= handTimeout else {
                return "\(side.initial)(-)"
            }
            let holding = state.offsetSince.map { max(0, time - $0) } ?? 0
            let fresh = state.offset != nil && (state.offsetAt.map { time - $0 <= offsetStale } ?? false)
            let star = bridgingSide == side ? "*" : (fresh ? "+" : "")
            return String(format: "%@(%.1fs%@)", side.initial, holding, star)
        }.joined(separator: "·")
    }

    /// **V3-4 §8.** How far the nearer tracked wrist is from `point`, or nil when neither is tracked. The
    /// folded card's star dust uses it for "a hand came within 12 cm".
    func nearestHandDistance(to point: SIMD3<Float>, at time: TimeInterval) -> Float? {
        var best: Float?
        for side in Side.allCases {
            guard let state = hands[side], state.tracked, time - state.at <= handTimeout else { continue }
            let d = simd_length(HandBridge.translation(of: state.pose) - point)
            guard d.isFinite else { continue }
            best = best.map { min($0, d) } ?? d
        }
        return best
    }

    /// **v4 B4 §2.** The nearer tracked hand's offset from `point` (hand − point, world metres), or nil when neither is
    /// tracked: its length is `nearestHandDistance`, its `y` how far the hand is above the point.
    func nearestHandOffset(to point: SIMD3<Float>, at time: TimeInterval) -> SIMD3<Float>? {
        var best: SIMD3<Float>?
        for side in Side.allCases {
            guard let state = hands[side], state.tracked, time - state.at <= handTimeout else { continue }
            let d = HandBridge.translation(of: state.pose) - point
            guard d.x.isFinite, d.y.isFinite, d.z.isFinite else { continue }
            if best == nil || simd_length(d) < simd_length(best!) { best = d }
        }
        return best
    }

    /// How long a hand has been continuously holding the passport (tests, diagnostics).
    func holdingSeconds(_ side: Side, at time: TimeInterval) -> TimeInterval {
        guard let since = hands[side]?.offsetSince else { return 0 }
        return max(0, time - since)
    }

    /// **V3-4 §3, rule 1.** The hand that can carry the card.
    ///
    /// V3-2b asked `Side.allCases` in order, so the **left** hand won whenever both had ever learned an
    /// offset. On the headset that was exactly backwards: the hand that has just come into the 10 cm circle
    /// is the one reaching over the passport to occlude it, and all three occlusions were bridged by it —
    /// the card flew off after the reaching hand and snapped back (`deckLag=173–177 mm`).
    ///
    /// The rule now is "whoever has been holding it longest":
    ///
    /// 1. the hand already bridging keeps it — its offset cannot be refreshed while the object is missing,
    ///    so the staleness test below must never be allowed to end a bridge in the middle;
    /// 2. a candidate needs a **fresh** offset (confirmed within `offsetStale`);
    /// 3. a hand whose current hold is younger than `newHandGrace` is the occluder and is skipped while
    ///    anything else can carry;
    /// 4. of what is left, the earliest `offsetSince` wins.
    private func holdingHand(at time: TimeInterval) -> (Side, HandState)? {
        func live(_ side: Side) -> HandState? {
            guard let state = hands[side], state.tracked, state.offset != nil,
                  time - state.at <= handTimeout else { return nil }
            return state
        }
        if let side = bridgingSide, let state = live(side) { return (side, state) }
        var candidates: [(Side, HandState)] = []
        for side in Side.allCases {
            guard let state = live(side), let at = state.offsetAt, time - at <= offsetStale else { continue }
            candidates.append((side, state))
        }
        guard !candidates.isEmpty else { return nil }
        let established = candidates.filter { time - ($0.1.offsetSince ?? time) >= newHandGrace }
        let pool = established.isEmpty ? candidates : established
        return pool.min { ($0.1.offsetSince ?? time) < ($1.1.offsetSince ?? time) }
    }

    // MARK: - Rigid-transform helpers

    /// The heading of a pose about world +Y, ignoring its pitch and roll.
    static func yaw(of m: simd_float4x4) -> Float {
        let forward = SIMD3<Float>(m.columns.2.x, 0, m.columns.2.z)
        guard simd_length(forward) > 1e-5 else { return 0 }
        return atan2(forward.x, forward.z)
    }

    static func translation(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    static func rotation(of m: simd_float4x4) -> simd_quatf {
        let x = simd_normalize(SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z))
        let y = simd_normalize(SIMD3<Float>(m.columns.1.x, m.columns.1.y, m.columns.1.z))
        let z = simd_normalize(SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z))
        return simd_quatf(simd_float3x3(columns: (x, y, z)))
    }

    static func pose(rotation q: simd_quatf, translation t: SIMD3<Float>) -> simd_float4x4 {
        var m = simd_float4x4(q)
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    /// Interpolate two rigid transforms: the translation linearly, the rotation along the shortest arc. A
    /// component-wise `simd_mix` of the matrices would shear the basis on the way across.
    static func mix(_ a: simd_float4x4, _ b: simd_float4x4, _ t: Float) -> simd_float4x4 {
        let k = max(0, min(1, t))
        let position = simd_mix(translation(of: a), translation(of: b), SIMD3<Float>(repeating: k))
        var qa = rotation(of: a)
        let qb = rotation(of: b)
        if simd_dot(qa.vector, qb.vector) < 0 { qa = simd_quatf(vector: -qa.vector) }
        return pose(rotation: simd_slerp(qa, qb, k), translation: position)
    }
}
