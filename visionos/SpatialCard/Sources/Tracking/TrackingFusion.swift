import Foundation
import simd

/// Which tracker is placing the card right now, and the rules that pick it (工作包 G — hybrid tracking).
///
/// Two providers report the same physical object. `ImageTrackingProvider` reports the **screen**: the anchor sits
/// at the centre of the LCD with +Y as its normal, and every single thing downstream — `PresenceGate`, the
/// continuity gate, `PoseFollower`, the desk surface, the registration overlay, the light well — is written
/// against that pose. `ObjectTrackingProvider` reports the **device**, in whatever frame Create ML happened to
/// train, which is not the screen frame and is not known until the two are seen together.
///
/// So the object pose is mapped into the screen frame (`ObjectScreenCalibration`) *before* it is ever offered as a
/// candidate, and the chosen pose then goes through the existing `CardTracker.ingest`. From `ingest` down nothing
/// knows, or needs to know, which provider a pose came from: the gate and the follower are untouched by 工作包 G.
///
/// Pure value type over `simd` + `Foundation` — no ARKit — so the policy and the calibration maths are exercised
/// in `SpatialCardTests` instead of first on the wearer's headset (same rule as `PoseFollower` / `MiniCardFollow`).
///
/// **G2 (after the first on-device trial).** The object tracker's *orientation* turned out to be the weak part of
/// it: the accepted pose read 12–22° of tilt while the device lay flat on the desk (the image reads 1–6°), which
/// drew the card visibly tilted, and — through the ~3.6 cm lever arm between Create ML's origin and the screen —
/// leaked straight back into position as millimetres of wander. Four of the five rules below exist because of
/// that one measurement: the desk snap (`DeskOrientationGate`), the yaw-only calibration, the object smoother, and
/// the in-hand preference that stops a fresh-looking image pose from vetoing the source that is actually right.
struct TrackingFusion {
    /// Which provider a pose came from.
    enum Source: String, Equatable {
        case image
        case object
        /// What the `[gate] Σ src=` field prints.
        var label: String { self == .object ? "obj" : "img" }
    }

    /// `--tracker image|object|both`. `image` never even constructs the object provider (sensor budget: the same
    /// reason v2 stopped running scene reconstruction next to image tracking). `object` — **the v3 default** —
    /// never even constructs the *image* provider: the screen frame comes off the scan (`ObjectScreenFrame`),
    /// so there is nothing to calibrate against and nothing to wait for, and the source never changes for the
    /// life of the session (see `objectIsUsable`). `both` is the v2 policy, kept for the experiment matrix and
    /// for the simulator: object once calibrated (or leading, see `objectLeadAfter`), image otherwise.
    enum Mode: String, Equatable {
        case image
        case object
        case both
    }

    /// One source's most recent observation. The object's pose is already in the **screen** frame.
    struct Sample: Equatable {
        var pose: simd_float4x4
        var isTracked: Bool
        var time: TimeInterval
        /// Object samples only (G2): the desk gate read this observation as a device lying flat, so its pose has
        /// been snapped gravity-aligned and may be trusted to place the card before there is any calibration.
        var onDesk: Bool

        init(pose: simd_float4x4, isTracked: Bool, time: TimeInterval, onDesk: Bool = true) {
            self.pose = pose
            self.isTracked = isTracked
            self.time = time
            self.onDesk = onDesk
        }
    }

    /// What `decide` concluded for this observation.
    struct Decision: Equatable {
        var source: Source
        var pose: simd_float4x4?
        var isTracked: Bool
        /// The active source changed on this call.
        var switched = false
        /// A switch was due but both sources are live and disagree: the old source keeps the tick.
        var vetoed = false
        /// How far apart the two sources are (metres), whenever that was measured.
        var disagreement: Float?
        /// Print the `[obj] sources disagree …` line — once per veto, not once per observation.
        var logVeto = false
        /// G2: the object was placing the card **without** a calibration (`objectLeadAfter`) and the image has
        /// just taken it back. The correction that comes with it is the caller's to log — downstream it is an
        /// ordinary jump, and the continuity gate glides it like any other relocation.
        var leadEnded = false
    }

    var mode: Mode = .both
    /// An image observation older than this is not "live".
    var liveWindow: TimeInterval = 0.3
    /// G2: the object source gets a longer window. Its rate on the headset dips to 5/s in hand (the standard-mode
    /// model at arm's length), and at 5/s two consecutive observations are already 0.2 s apart: with the image's
    /// 0.3 s the card was handed back to the image — the source that lies in hand — between object frames.
    var objectLiveWindow: TimeInterval = 0.5
    /// G2: the disagreement veto needs **both** sources this fresh. An image pose that is merely "not yet stale"
    /// is exactly the thing that vetoed every in-hand hand-over in the first trial.
    var vetoWindow: TimeInterval = 0.3
    /// Sources this far apart cannot both be right. Same value as the gate's continuity threshold, and for the
    /// same reason: a hand-over that moved the card 6 cm would read exactly like the ARKit drift M1b removed.
    var jumpDistance: Float = 0.05
    /// G2 (object-first acquisition): with no image seen for this long since the session started, a **flat**,
    /// tracked object anchor may drive the card on the bounding-box fallback alone. Device trial: the object was
    /// tracked from ~10 s and the image not until 49 s, and the card waited for the image the whole time.
    var objectLeadAfter: TimeInterval = 2.0
    /// The object→screen offset has converged (or is not being waited for). Written by `CardTracker`.
    var calibrated = false
    /// G2: the gate says the device is in the wearer's hand (`presence == .carrying(*)`). The image tracker is the
    /// one that lies there — a 37 mm self-lit target seen edge-on — so it does not get to veto the object.
    var isCarrying = false
    /// Session start (`start()` / `startFakeTrack`), the clock `objectLeadAfter` counts from.
    var sessionStart: TimeInterval = 0

    private(set) var source: Source = .image
    private(set) var image: Sample?
    /// Object observation, already mapped into the screen frame (and, on the desk, snapped gravity-aligned).
    private(set) var object: Sample?
    /// Last **tracked** image observation: `objectLeadAfter` measures from it (or from `sessionStart`).
    private(set) var lastImageTracked: TimeInterval?
    /// The veto is logged once per attempt, then re-armed when the sources agree again.
    private var vetoLogged = false

    /// The object is placing the card on the bounding-box fallback, with no calibration behind it.
    var isLeading: Bool { source == .object && mode == .both && !calibrated }

    // MARK: - Inputs

    mutating func note(image sample: Sample) {
        image = sample
        if sample.isTracked { lastImageTracked = sample.time }
    }

    mutating func note(object sample: Sample) { object = sample }

    /// A new ARKit session (or `--fake-track` run): the lead clock restarts, so a teardown does not inherit the
    /// previous session's "the image was seen once, long ago".
    mutating func beginSession(at time: TimeInterval) {
        sessionStart = time
        lastImageTracked = nil
        // v3 H1: object mode has no image provider at all, so start on the source that is going to place the
        // card. `CardTracker` reads `activeSource` before the first observation arrives (the button hold and
        // `PresenceGate.deskOnlyAcceptance` both depend on it) and `.image` would be a lie for the whole gap.
        source = mode == .object ? .object : .image
    }

    /// The object source went away (provider stopped, reference object never loaded): forget it, so a stale
    /// pose can never come back as a candidate.
    mutating func dropObject() {
        object = nil
        if source == .object { source = .image }
    }

    // MARK: - Policy

    /// Which source should drive `ingest` right now. Call it after every observation from either source; the
    /// caller forwards the observation only when the decision names the source it came from, which is what keeps
    /// the *other* source's untracked observations from freezing the gate.
    mutating func decide(at time: TimeInterval) -> Decision {
        let wasLeading = isLeading
        let wanted: Source = objectIsUsable(at: time) ? .object : .image
        guard wanted != source else {
            vetoLogged = false
            return decision(on: source, switched: false)
        }
        // A hand-over must not look like the card teleporting. Only two *fresh* sources can disagree: when the one
        // we are on has gone quiet or untracked there is nothing to compare against and nothing to protect — the
        // switch happens, and a genuine relocation is then the gate's business (two consistent detections), not
        // the fusion's. Vetoing on a dead source would freeze the card wherever it was last seen for good.
        if let distance = vetoDistance(wanted: wanted, at: time) {
            let log = !vetoLogged
            vetoLogged = true
            var held = decision(on: source, switched: false)
            held.vetoed = true
            held.disagreement = distance
            held.logVeto = log
            return held
        }
        vetoLogged = false
        let apart = separation(between: source, and: wanted, at: time)
        source = wanted
        var switched = decision(on: wanted, switched: true)
        switched.disagreement = apart
        switched.leadEnded = wasLeading && wanted == .image
        return switched
    }

    /// `--tracker object`, or `both` once the offset is known (or while the object is leading): the anchor must
    /// also be tracked and fresh.
    private func objectIsUsable(at time: TimeInterval) -> Bool {
        switch mode {
        case .image: return false
        case .object:
            // v3 H1: in object mode the source is the object, full stop — an *untracked* object observation is
            // forwarded too, so the gate freezes as `held(.untracked)` on the frame the device is lost instead
            // of handing the card to an image source that, in this mode, does not exist. (There is nothing to
            // fall back to before the first observation, which is what `object != nil` says.)
            return object != nil
        case .both:
            // Rule 4: uncalibrated, the object may still take the card — but only when the image has had its
            // chance and missed it, and only from a device that reads as lying flat on the desk (a bounding-box
            // offset applied to a pose held at an angle is not something to hand the card to).
            if !calibrated {
                guard let object = live(.object, at: time), object.onDesk else { return false }
                return time - max(sessionStart, lastImageTracked ?? sessionStart) >= objectLeadAfter
            }
        }
        return live(.object, at: time) != nil
    }

    /// The veto's distance, or nil when there is nothing to veto. **Position only** (G2): in hand the object's
    /// orientation is the noisy part and comparing it would veto every hand-over that matters, so the two sources
    /// are compared where they claim the card *is*, never how it is turned.
    private func vetoDistance(wanted: Source, at time: TimeInterval) -> Float? {
        // Only a calibrated offset earns a veto: while the object is leading on its bounding box the image is the
        // ground truth the calibration needs, and the whole point is to let it back in the moment it appears.
        guard calibrated else { return nil }
        // Rule 5: in hand, prefer the object even against an image pose that still looks fresh.
        if isCarrying, wanted == .object { return nil }
        guard let current = fresh(source, at: time), let next = fresh(wanted, at: time) else { return nil }
        let (distance, _) = PresenceGate.delta(from: current.pose, to: next.pose)
        return distance > jumpDistance ? distance : nil
    }

    /// How far apart the two sources are right now, when both are live enough to ask.
    private func separation(between current: Source, and next: Source, at time: TimeInterval) -> Float? {
        guard let a = live(current, at: time), let b = live(next, at: time) else { return nil }
        return PresenceGate.delta(from: a.pose, to: b.pose).distance
    }

    /// Tracked and inside this source's live window (the object gets the longer one — see `objectLiveWindow`).
    private func live(_ source: Source, at time: TimeInterval) -> Sample? {
        guard let sample = self.sample(for: source), sample.isTracked else { return nil }
        let window = source == .object ? objectLiveWindow : liveWindow
        return time - sample.time <= window ? sample : nil
    }

    /// Tracked and inside the **veto** window, which is the same 0.3 s for both sources.
    private func fresh(_ source: Source, at time: TimeInterval) -> Sample? {
        guard let sample = self.sample(for: source), sample.isTracked, time - sample.time <= vetoWindow else { return nil }
        return sample
    }

    private func sample(for source: Source) -> Sample? {
        source == .object ? object : image
    }

    private func decision(on source: Source, switched: Bool) -> Decision {
        let sample = sample(for: source)
        return Decision(source: source, pose: sample?.pose, isTracked: sample?.isTracked ?? false, switched: switched)
    }

    // MARK: - Gravity (G2)

    /// The yaw (rad) of a rigid transform: the heading of its +Z axis in the horizontal plane. Falls back to +X
    /// when +Z is (nearly) vertical, so a device stood on its edge still reports a defined heading.
    static func yaw(of m: simd_float4x4) -> Float {
        let z = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        var h = SIMD2<Float>(z.x, z.z)
        if simd_length(h) < 1e-4 {
            let x = SIMD3<Float>(m.columns.0.x, m.columns.0.y, m.columns.0.z)
            h = SIMD2<Float>(-x.z, x.x)
        }
        guard simd_length(h) > 1e-6, h.x.isFinite, h.y.isFinite else { return 0 }
        return atan2(h.x, h.y)
    }

    /// Same position, rotation reduced to its yaw: a device lying on a desk is flat *by definition*, and the
    /// anchor convention downstream is "+Y is the screen normal". This is rule 1 of G2.
    ///
    /// **It therefore only means anything applied to a pose whose +Y really is the screen normal** — i.e. to a
    /// pose already in the **screen** frame. V3-1 applied it to the *object* pose instead
    /// (`gravityAligned(objectPose) * offset`), which was right only while the trained object's own +Y happened to
    /// be the thin axis. The headset's `ObjectAnchor.boundingBox` is Z-thin: its +Y is the 95 mm long axis, so
    /// forcing *that* axis to point at the sky stood the passport on end on the desk (`tilt=90.0°` next to
    /// `objTilt=3.7°` in the V3-1 trial log) and the flat gate then read `carrying(notFlat)` for a whole session.
    /// V3-1b applies it to `rawPose * offset`, where +Y is the screen normal and +Z the reader axis by
    /// construction, so `yaw(of:)` also reads the heading off the long edge instead of falling through to +X.
    ///
    /// The cost of aligning after the offset rather than before it is that the offset's lever arm (4.25 mm on the
    /// headset box — half the 8.5 mm thickness) now turns with the tracker's pitch/roll noise instead of being
    /// applied to an already-flattened frame: ≤ 4.25 mm × sin 20° ≈ 1.5 mm of wander at the worst rest reading
    /// measured on the headset, against the 90° of error it removes.
    static func gravityAligned(_ m: simd_float4x4) -> simd_float4x4 {
        var out = simd_float4x4(simd_quatf(angle: yaw(of: m), axis: [0, 1, 0]))
        out.columns.3 = m.columns.3
        return out
    }
}

/// "Is the device lying on the desk, or is it in a hand?" — the gate that decides whether the screen pose is
/// snapped gravity-aligned, and (V3-1b) whether the presence gate is told the card is flat at all.
///
/// **V3-1 judged it on tilt alone**, with a 25°/35° hysteresis. Two measurements from the headset say that is not
/// enough in either direction:
///
/// - the object tracker's pitch/roll on a thin slab **at rest on a desk** read 3.7°, 5.5°, 14.1°, 17.3°, 21.9° and
///   27.7° across two sessions, so the "back on the desk" angle has to be generous — 25° would have kept a device
///   that was simply lying there in the hand form;
/// - a device held **flat in a palm** is under 35° too, and calling that "desk" snaps the card's orientation to
///   gravity and hands the presence gate a `flat`, which is a card that quietly stops following the hand.
///
/// So tilt decides only that the device *may* be on a desk; the evidence that it *is* comes from the two things a
/// palm cannot fake: the device stands still (desk jitter is 0.3–1 mm, in hand 5–9 mm) and there is a detected
/// horizontal plane right underneath it. With no plane known — no scene understanding yet, the simulator, a shelf
/// the plane detector has not found — a longer stillness stands in for it.
///
/// Leaving is deliberately cheap and quick (one condition, 0.15 s) and coming back is expensive: being wrong about
/// "in a hand" costs a gravity snap that is not applied, being wrong about "on the desk" costs the card.
///
/// **The prior before any evidence is the desk** (`isOnDesk == true` on a fresh gate). The stillness clock needs
/// 0.4 s to say anything at all, and a card that is detected lying on a desk must reveal itself on the desk —
/// `PresenceGate` turns a single non-flat observation in `acquiring` straight into `carrying(.notFlat)`, so a gate
/// that started in "hand" would cost every session its cinematic first reveal. A device that is picked up before
/// it is first seen pays for that prior with ≤ `exitDwell` of desk.
///
/// Pure value type: `DeskOrientationGateTests` drives the whole matrix (still + plane, still without a plane,
/// moving, resting at 27°, the 40°/46° hysteresis) without a headset.
struct DeskOrientationGate: Equatable {
    /// One observation of the device, as the gate wants it.
    struct Sample: Equatable {
        var time: TimeInterval
        var position: SIMD3<Float>
    }

    /// What `update` reports when the answer changed — the caller logs it (`[obj] desk gate → …`).
    struct Change: Equatable {
        var isOnDesk: Bool
        var reason: String
    }

    /// Below this the device *may* be lying on a desk. Generous on purpose: the object tracker's own rest error
    /// reached 27.7° on the headset. Used for the first observation and for re-entry alike.
    var enterAngle: Float = 35 * .pi / 180
    /// Above this, for `exitDwell`, it is in a hand.
    var exitAngle: Float = 45 * .pi / 180
    /// Under this the device counts as standing still (desk jitter is 0.3–1 mm; a 5 mm RMS shimmy at 30 Hz reads
    /// as ≈ 0.024 m/s through the `speedWindow`, which is what makes a window rather than a per-frame difference
    /// the right estimator).
    var stillSpeed: Float = 0.04
    /// Over this, for `exitDwell`, the device is being carried.
    var movingSpeed: Float = 0.12
    /// Stillness needed to enter the desk **with** a plane underneath …
    var stillForPlane: TimeInterval = 0.4
    /// … and without one.
    ///
    /// **V3-4 §5**: 2.0 s → 1.2 s. The first headset round never found a usable plane (see `planeRise`) and
    /// paid the full two seconds on all three put-downs — "put it down → the gallery" measured 2.5 s against
    /// a 1.5 s target. 1.2 s is still four times the 0.3 s speed window, so a carry cannot sneak through it.
    var stillForNoPlane: TimeInterval = 1.2
    /// A detected horizontal surface this far under the screen origin is the desk the device is lying on.
    ///
    /// **V3-4 §5**: 3 cm → 4 cm, and see `planeRise`.
    var planeReach: Float = 0.04
    /// How far a detected plane may sit **above** the screen origin and still be the desk it is lying on.
    ///
    /// The headset reported `desk plane found … (drop -0.019 m)`: ARKit's plane for the real desk was 1.9 cm
    /// *higher* than the passport's screen. A plane estimate is a fitted rectangle over a noisy point cloud
    /// with a tablecloth, a laptop and a coffee cup in it; a centimetre of bias either way is normal. V3-2b
    /// only accepted −1 cm, so the one plane the session ever found was thrown away on every put-down.
    var planeRise: Float = 0.03
    /// **V3-4 §5.** The screen's world height the last time the device was confirmed to be on the desk. A
    /// device that is flat, still and back within `rememberedTolerance` of that height is on the same desk,
    /// plane or no plane — which is the fast path the put-down actually needs.
    ///
    /// The known cost, written down rather than discovered on the headset: a palm held perfectly flat *at
    /// the same height as the desk* enters the desk state in 0.4 s instead of 1.2 s. A palm anywhere else —
    /// and a hand is almost never within 3 cm of the surface it just lifted off — pays the full 1.2 s.
    private(set) var rememberedHeight: Float?
    var rememberedTolerance: Float = 0.03
    /// An exit condition has to hold this long: one noisy observation is not a pick-up.
    var exitDwell: TimeInterval = 0.15
    /// Speed is |p(t) − p(t − w)| / w over this trailing window rather than a per-frame difference, so tracking
    /// jitter (which never averages out of |Δp|/Δt) cannot read as motion.
    var speedWindow: TimeInterval = 0.3
    /// The shortest span the speed estimate is willing to divide by.
    var minSpeedSpan: TimeInterval = 0.1
    /// A gap this long between two tracked observations is not a measurement of anything: whatever the device did
    /// while nobody was watching, "it has not moved since" is not evidence any more. The stillness clock starts
    /// again. (The headset's object rate dips to 5/s in hand — 0.2 s between observations — so this has to sit
    /// comfortably above that.)
    var staleGap: TimeInterval = 0.5

    /// `objectDeskTilt`: the nominal "this is a card lying flat" angle. Still the one
    /// `ObjectScreenCalibration.maxObjectTilt` samples against.
    static let deskTilt: Float = 30 * .pi / 180

    private(set) var isOnDesk = true
    /// **V3-2a H5.** The device is flat enough to be a desk but has not held still long enough yet: the
    /// put-down is *coming*. The deck uses it for its anticipation (the fan opens 15 % wider), which is what
    /// fills the 0.4 s the stillness test costs — without it the bloom always arrives late and unannounced.
    private(set) var isCandidate = false
    /// The trailing-window speed estimate (m/s) — `Σ`-worthy and what the tests assert on.
    private(set) var speed: Float = 0
    private var samples: [Sample] = []
    private var stillSince: TimeInterval?
    private var tiltHighSince: TimeInterval?
    private var movingSince: TimeInterval?

    init() {}

    /// How long the device has been standing still, at `time`.
    func stillFor(at time: TimeInterval) -> TimeInterval {
        guard let stillSince else { return 0 }
        return max(0, time - stillSince)
    }

    /// One tracked object observation. `tilt` is the **screen** pose's tilt (the un-snapped `rawPose · offset`),
    /// `position` the raw **object anchor**'s position — deliberately not the screen one, so that a change of
    /// mapping underneath the stream (a `both`-mode calibration converging) is not read as the device moving —
    /// and `planeBelow` the drop from the screen origin to the nearest detected horizontal surface, or nil when
    /// none is known. `screenY` is the **screen** pose's world height, which is what the remembered desk
    /// height is measured in (V3-4 §5); nil falls back to the anchor's own. Returns the change, if the answer
    /// moved.
    @discardableResult
    mutating func update(tilt: Float, position: SIMD3<Float>, planeBelow: Float?,
                         screenY: Float? = nil, at time: TimeInterval) -> Change? {
        guard tilt.isFinite, position.x.isFinite, position.y.isFinite, position.z.isFinite else { return nil }
        updateSpeed(position: position, at: time)
        if speed < stillSpeed {
            if stillSince == nil { stillSince = time }
        } else {
            stillSince = nil
        }

        let degrees = tilt * 180 / .pi
        if isOnDesk {
            isCandidate = false
            // **V3-4 §5.** While the device *is* on the desk, and lying still on it, that is how high the desk
            // is. Learning it here rather than only on the transition matters because the gate's prior is the
            // desk: a session that starts with the passport already lying there never sees an entry at all.
            if speed < stillSpeed, tilt < enterAngle { rememberedHeight = screenY ?? position.y }
            if tilt > exitAngle {
                if tiltHighSince == nil { tiltHighSince = time }
                if time - (tiltHighSince ?? time) >= exitDwell {
                    return leave(reason: String(format: "tilt %.0f°", degrees))
                }
            } else {
                tiltHighSince = nil
            }
            if speed > movingSpeed {
                if movingSince == nil { movingSince = time }
                if time - (movingSince ?? time) >= exitDwell {
                    return leave(reason: String(format: "moving %.2f m/s", speed))
                }
            } else {
                movingSince = nil
            }
            return nil
        }

        guard tilt < enterAngle else {
            isCandidate = false
            return nil
        }
        let still = stillFor(at: time)
        let onPlane = planeBelow.map { $0 > -planeRise && $0 <= planeReach } ?? false
        // **V3-4 §5.** …or the device is back at the height of the desk it was last seen lying on.
        let height = screenY ?? position.y
        let remembered = rememberedHeight.map { abs(height - $0) <= rememberedTolerance } ?? false
        guard still >= stillForPlane, onPlane || remembered || still >= stillForNoPlane else {
            // Flat, and slowing down: the wearer is putting it down. Motion cancels it on the next
            // observation, because `stillSince` is cleared the moment the speed passes `stillSpeed`.
            isCandidate = still > 0
            return nil
        }
        isOnDesk = true
        isCandidate = false
        tiltHighSince = nil
        movingSince = nil
        let why: String
        if onPlane {
            why = String(format: ", plane %.1f cm below", (planeBelow ?? 0) * 100)
        } else if remembered, let known = rememberedHeight {
            why = String(format: ", remembered height Δ %.1f cm", abs(height - known) * 100)
        } else {
            why = ", no plane"
        }
        rememberedHeight = height
        return Change(isOnDesk: true, reason: String(format: "tilt %.0f°, still %.1f s", degrees, still) + why)
    }

    /// ARKit stopped tracking the object. Nothing about *where* the device is survives that, so the stillness
    /// clock (and the window it is measured over) starts again — but the answer itself does not change: a device
    /// that was on a desk when it was lost is still on the desk while it is not being seen.
    mutating func loseTracking() {
        samples.removeAll()
        stillSince = nil
        speed = 0
    }

    mutating func reset() { self = DeskOrientationGate() }

    /// Forget the desk this session learned (a teardown, a new room, `--recalibrate`).
    mutating func forgetDeskHeight() { rememberedHeight = nil }

    private mutating func leave(reason: String) -> Change {
        isCandidate = false
        isOnDesk = false
        tiltHighSince = nil
        movingSince = nil
        return Change(isOnDesk: false, reason: reason)
    }

    private mutating func updateSpeed(position: SIMD3<Float>, at time: TimeInterval) {
        if let last = samples.last, time - last.time > staleGap || time < last.time {
            samples.removeAll()
            stillSince = nil
            speed = 0
        }
        samples.append(Sample(time: time, position: position))
        // Keep exactly one sample at or beyond the window edge: that one is the window's anchor.
        while samples.count > 2, time - samples[1].time >= speedWindow { samples.removeFirst() }
        // An out-of-order or repeated timestamp (a stalled main actor replaying a backlog) is not a measurement.
        guard let first = samples.first else { return }
        let span = time - first.time
        guard span >= minSpeedSpan else { return }
        speed = simd_length(position - first.position) / Float(span)
    }
}

/// First-order low pass on the object stream (工作包 G2, rule 3).
///
/// The image tracker's resting noise is 0.1–0.5 mm; the object tracker's is 2–4 mm, and a 2 mm shimmy on a card
/// that is supposed to be lying still on a desk is the difference between "printed on the device" and "floating
/// above it". τ 0.12 s is short enough that a carried device does not lag visibly (at 0.3 m/s it trails 3.6 cm —
/// and a carry is a `carrying` presence, where the card is deliberately soft anyway) and long enough to swallow
/// the noise. Reset on a tracking loss and on a source switch: the next pose is where the device *is*, not
/// somewhere between there and where it used to be.
///
/// **v3 H1: two time constants.** One τ for both halves was a compromise between two different signals. The
/// device's *position* is the accurate half (0.3 mm at rest) and the half the eye checks against the real
/// passport underneath, so it wants to be quick: τ 0.08 s trails 2.4 cm at 0.3 m/s instead of 3.6 cm. Its
/// *orientation* is the noisy half (14–28° of pitch/roll error on a device lying flat), and in the hand there
/// is no gravity snap to hide that, so it wants to be slow: τ 0.20 s turns a 20° jerk into a lean.
struct ObjectPoseSmoother {
    /// **V3-4 §7** `--filter euro|lowpass`. `lowpass` is everything below — one τ for position, one for
    /// orientation, switched by presence. `euro` is the 1€ filter: the cutoff rises with speed, so a device
    /// standing still is filtered hard and a device being carried is barely filtered at all, which is the
    /// trade a fixed τ cannot make.
    ///
    /// **V3-5 §4: the default goes back to `lowpass`.** V3-4 shipped `euro` on simulator evidence and the
    /// headset falsified it — every hand-held Σ window came back with `jitterOut ≥ jitter`, because real
    /// tracker noise is read as speed and opens the cutoff (see `OneEuroFilter.positionBeta`). Retuned to
    /// β 2 the filter is genuinely steady (9 % of the resting step) but lags a 0.3 m/s slide by 19.5 mm
    /// against the low pass's 5.0 mm — nearly four times the brief's ceiling. A steadier filter that trails
    /// the passport it is drawn on is not the trade this app can make, so `euro` stays as the A/B.
    enum Kind: String, CaseIterable, Equatable { case lowpass, euro }

    /// The filter in use. Defaults to `lowpass` so an `ObjectPoseSmoother()` built anywhere else (the tests
    /// this file's τ numbers were measured with) behaves exactly as it did; `CardTracker` sets it from the
    /// flag, whose default is `euro`.
    var kind: Kind = .lowpass

    /// **V3-4 §7's numbers**, and why they are not the brief's — see `OneEuroFilter.positionBeta`.
    private var euroPosition = OneEuroVector()
    private var euroRotation = OneEuroRotation()

    /// **V3-1b: the carry is the case that is watched against the device itself.** In the hand form the card sits
    /// 35 mm above the screen of a passport the wearer is holding, so every millisecond of filter delay is visible
    /// as the card trailing the device. τ 0.08 s costs 2.4 cm at 0.3 m/s before the follower has even seen the
    /// pose; τ 0.03 s costs 0.9 mm per cm/s — and the noise it lets through is the object tracker's 2–4 mm, which
    /// is far below the amplitude of the hand carrying it. `CardTracker` switches between the two by presence.
    static let tauPositionDesk: Float = 0.08
    static let tauPositionHand: Float = 0.03

    /// Position low pass (s).
    var tauPosition: Float = ObjectPoseSmoother.tauPositionDesk
    /// Orientation low pass (s) — deliberately 2.5× the position one; see the type's note.
    var tauRotation: Float = 0.20
    /// The longest step the filter integrates in one go (a stalled main actor must not teleport the card).
    static let maxStep: TimeInterval = 0.25

    private(set) var pose: simd_float4x4?
    private var lastTime: TimeInterval?

    init(tauPosition: Float = ObjectPoseSmoother.tauPositionDesk, tauRotation: Float = 0.20) {
        self.tauPosition = tauPosition
        self.tauRotation = tauRotation
    }

    mutating func reset() {
        pose = nil
        lastTime = nil
        euroPosition.reset()
        euroRotation.reset()
    }

    mutating func smooth(_ target: simd_float4x4, at time: TimeInterval) -> simd_float4x4 {
        guard kind == .lowpass else { return smoothEuro(target, at: time) }
        guard let previous = pose, let last = lastTime, tauPosition > 0 || tauRotation > 0 else {
            pose = target
            lastTime = time
            return target
        }
        let dt = Float(min(ObjectPoseSmoother.maxStep, max(0, time - last)))
        lastTime = time
        guard dt > 0 else { return previous }
        let alphaPosition = tauPosition > 0 ? 1 - exp(-dt / tauPosition) : 1
        let alphaRotation = tauRotation > 0 ? 1 - exp(-dt / tauRotation) : 1
        let from = ObjectScreenCalibration.translation(of: previous)
        let to = ObjectScreenCalibration.translation(of: target)
        let position = from + (to - from) * alphaPosition
        let rotation = simd_slerp(PresenceGate.rotation(of: previous), PresenceGate.rotation(of: target), alphaRotation)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            pose = target
            return target
        }
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        pose = m
        return m
    }

    /// **V3-4 §7.** The 1€ path: two filters, one for the translation and one for the rotation, both of
    /// them opening up as the device moves. There is no presence switch here — that is the point, the speed
    /// *is* the switch, and it is continuous instead of a step at the moment the gate changes its mind.
    private mutating func smoothEuro(_ target: simd_float4x4, at time: TimeInterval) -> simd_float4x4 {
        let position = euroPosition.filter(ObjectScreenCalibration.translation(of: target), at: time)
        let rotation = euroRotation.filter(PresenceGate.rotation(of: target), at: time)
        guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            pose = target
            lastTime = time
            return target
        }
        var m = simd_float4x4(rotation)
        m.columns.3 = SIMD4<Float>(position.x, position.y, position.z, 1)
        pose = m
        lastTime = time
        return m
    }
}

/// The offset from the trained object's **gravity-aligned** frame to the screen anchor's frame, averaged over
/// co-observations: a yaw and a translation (工作包 G2, rule 2).
///
/// `objectToScreen = inverse(gravityAligned(objectPose)) · imagePose`, so `screenPose = gravityAligned(objectPose)
/// · objectToScreen` on the desk (and `objectPose · objectToScreen` in hand, where there is no gravity-aligned
/// frame to speak of). Both providers see the same rigid body, so the offset is a constant — every co-observation
/// is the same number plus two trackers' noise, and the mean of enough of them is the answer.
///
/// **Why only a yaw.** Every sample is taken with both sources flat on a desk, so the true rotation between the
/// two frames *is* a yaw; the pitch and roll in `inverse(obj)·img` are the object tracker's orientation noise
/// (12–22° of it on the headset), and storing them means storing noise. Worse, applying a translation of
/// |t| ≈ 3.6 cm through a rotation that wrong turns 15° of orientation error into ~9 mm of position error — more
/// than this struct's own 6 mm convergence gate. Measuring and applying the offset against the *yaw-only* object
/// frame removes that term entirely, which is what makes a 6 mm gate reachable on the headset at all.
///
/// It converges once there are `minSamples` of them **and** the last `window` translations all sit within
/// `tolerance` of the mean; a wandering mean means one of the two trackers is not actually locked on, and a bad
/// offset is worse than no offset (it would move the card off the device the moment the source switches).
/// Afterwards the mean keeps running with a capped sample count, so an offset measured during a bad minute heals
/// instead of being outvoted by its own history for the rest of the session.
///
/// Persisted per reference object, so the second run of the day starts calibrated.
struct ObjectScreenCalibration: Equatable {
    /// Co-observations before the offset may be trusted …
    var minSamples = 60
    /// … of which the last this many …
    var window = 20
    /// … must all be within this of the running mean (6 mm).
    var tolerance: Float = 0.006
    /// A sample is only a *co-observation of a card on a desk* while the image reads flat …
    var maxImageTilt: Float = 6 * .pi / 180
    /// … and the object is not being held (`objectDeskTilt`).
    var maxObjectTilt: Float = DeskOrientationGate.deskTilt
    /// Once the running mean has this many samples behind it, the oldest weight is dropped for every new sample:
    /// the mean becomes a slow exponential one (≈ 20 s at the headset's 20–30 object updates/s) instead of an
    /// average that stops moving. That is what lets a bad calibration heal in place.
    var effectiveCap = 400

    private(set) var count = 0
    private(set) var translationSum: SIMD3<Float> = .zero
    /// The yaw as a summed unit vector (cos, sin) — the circular mean. Summing the angles themselves would put
    /// the mean of −179° and +179° at zero, i.e. the card facing exactly the wrong way.
    private(set) var yawSum: SIMD2<Float> = .zero
    private(set) var recent: [SIMD3<Float>] = []
    private(set) var isConverged = false
    /// Co-observations thrown away by the tilt tests (useful when the offset refuses to converge on the headset).
    private(set) var rejected = 0

    init() {}

    /// A persisted offset: exactly as if `minSamples` co-observations had all reported this number. A calibration
    /// stored by an earlier build (full rotation) is reduced to its yaw here, and the refresh path walks the
    /// translation the rest of the way.
    init(restored offset: simd_float4x4) {
        let n = Float(minSamples)
        let t = ObjectScreenCalibration.translation(of: offset)
        let yaw = TrackingFusion.yaw(of: offset)
        translationSum = t * n
        yawSum = SIMD2<Float>(cos(yaw), sin(yaw)) * n
        count = minSamples
        recent = Array(repeating: t, count: window)
        isConverged = true
    }

    // MARK: - Samples

    /// One co-observation. Returns true on the call that *makes* it converge, so the caller logs once.
    @discardableResult
    mutating func add(objectPose: simd_float4x4, imagePose: simd_float4x4) -> Bool {
        // Rule 2's sample rejection. A tilted image pose is a drifted detection, and a tilted object pose is a
        // device in a hand: neither describes the constant this struct is trying to measure.
        guard PresenceGate.tilt(of: imagePose) <= maxImageTilt,
              PresenceGate.tilt(of: objectPose) <= maxObjectTilt else {
            rejected += 1
            return false
        }
        let offset = ObjectScreenCalibration.offset(objectPose: objectPose, imagePose: imagePose)
        let t = ObjectScreenCalibration.translation(of: offset)
        guard t.x.isFinite, t.y.isFinite, t.z.isFinite else { return false }
        let yaw = TrackingFusion.yaw(of: offset)
        guard yaw.isFinite else { return false }
        if count >= effectiveCap {
            let decay = Float(effectiveCap - 1) / Float(effectiveCap)
            translationSum *= decay
            yawSum *= decay
            count = effectiveCap - 1
        }
        translationSum += t
        yawSum += SIMD2<Float>(cos(yaw), sin(yaw))
        count += 1
        recent.append(t)
        if recent.count > window { recent.removeFirst(recent.count - window) }

        guard !isConverged else { return false }
        guard count >= minSamples, recent.count >= window else { return false }
        let mean = meanTranslation
        guard recent.allSatisfy({ simd_length($0 - mean) <= tolerance }) else { return false }
        isConverged = true
        return true
    }

    mutating func reset() { self = ObjectScreenCalibration() }

    // MARK: - Derived

    var meanTranslation: SIMD3<Float> {
        count > 0 ? translationSum / Float(count) : .zero
    }

    /// The circular mean of the sampled yaws (rad).
    var meanYaw: Float {
        guard simd_length(yawSum) > 1e-6 else { return 0 }
        return atan2(yawSum.y, yawSum.x)
    }

    var meanRotation: simd_quatf { simd_quatf(angle: meanYaw, axis: [0, 1, 0]) }

    /// `objectToScreen`. Nil until there is something to average.
    var offset: simd_float4x4? {
        guard count > 0 else { return nil }
        var m = simd_float4x4(meanRotation)
        let t = meanTranslation
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    /// How far the last `window` samples wander from the mean (metres) — the number the convergence test reads,
    /// and a useful thing to print when it does *not* converge on the headset.
    var spread: Float {
        let mean = meanTranslation
        return recent.reduce(Float(0)) { max($0, simd_length($1 - mean)) }
    }

    // MARK: - Statics

    /// Measured against the object's **gravity-aligned** frame, which is the frame the offset is applied in while
    /// the device is on the desk (see the type's note on the lever arm).
    ///
    /// **Assumption, named here because V3-1b did not change it (`--tracker both` is not the default path).**
    /// `gravityAligned` only means anything on a pose whose +Y is the screen normal, and this one is the *object*
    /// pose. On the headset's Z-thin bounding box the object's +Y is the 95 mm long axis, so a device lying flat
    /// reports `PresenceGate.tilt(of: objectPose) ≈ 90°` — past `maxObjectTilt` — and every co-observation is
    /// rejected: `both` mode can never converge on that device. Fixing it properly means measuring the offset
    /// against `objectPose · ObjectScreenFrame.offset` and storing it as a *correction* to that frame rather than
    /// as the whole mapping (and giving up the yaw-only representation, which cannot express a 90° axis swap), so
    /// it is not the one-line change this round was allowed. `--tracker object` — the default — does not use it.
    static func offset(objectPose: simd_float4x4, imagePose: simd_float4x4) -> simd_float4x4 {
        TrackingFusion.gravityAligned(objectPose).inverse * imagePose
    }

    /// Where the screen is on a device that has not been calibrated yet: the top face of the object's own
    /// bounding box, in the object's frame. Rotation is identity — the box is axis-aligned there, so the screen
    /// pose simply inherits the object's orientation (which the desk snap then flattens). Good enough to place
    /// the card and, since G2's object-first rule, good enough to place it *before* the image has ever been seen.
    static func boundingBoxOffset(center: SIMD3<Float>, extent: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(center.x, center.y + extent.y / 2, center.z, 1)
        return m
    }

    static func translation(of m: simd_float4x4) -> SIMD3<Float> {
        SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    }

    /// Flat storage for `UserDefaults` (column-major, 16 floats).
    static func floats(_ m: simd_float4x4) -> [Float] {
        (0..<4).flatMap { c -> [Float] in
            let column = m[c]
            return [column.x, column.y, column.z, column.w]
        }
    }

    static func matrix(_ floats: [Float]) -> simd_float4x4? {
        guard floats.count == 16, floats.allSatisfy({ $0.isFinite }) else { return nil }
        return simd_float4x4(columns: (SIMD4<Float>(floats[0], floats[1], floats[2], floats[3]),
                                       SIMD4<Float>(floats[4], floats[5], floats[6], floats[7]),
                                       SIMD4<Float>(floats[8], floats[9], floats[10], floats[11]),
                                       SIMD4<Float>(floats[12], floats[13], floats[14], floats[15])))
    }
}
