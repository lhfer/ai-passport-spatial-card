import XCTest
import simd

/// Clock-driven scenarios for `PresenceGate` (plan §13 T3–T8 + the theme / world holds and the replay).
/// The gate is compiled into this bundle directly: no app host, no ARKit.
final class PresenceGateTests: XCTestCase {
    private var gate = PresenceGate()
    private var events: [PresenceGate.Event] = []

    override func setUp() {
        super.setUp()
        gate = PresenceGate()
        gate.logging = false
        events = []
    }

    // MARK: Helpers

    private func pose(x: Float = 0, y: Float = 0.9, z: Float = -0.5, tiltDegrees: Float = 0) -> simd_float4x4 {
        var m = simd_float4x4(simd_quatf(angle: tiltDegrees * .pi / 180, axis: [1, 0, 0]))
        m.columns.3 = SIMD4<Float>(x, y, z, 1)
        return m
    }

    private func drain() {
        while let e = gate.takeEvent() { events.append(e) }
    }

    /// Ticks at 20 Hz from `from` to `to`; `observeEvery` > 0 also feeds tracked observations at that period.
    private func run(from: TimeInterval, to: TimeInterval, observeEvery: TimeInterval = 0, pose p: simd_float4x4? = nil, flat: Bool = true) {
        var t = from
        var nextObserve = from
        while t <= to + 1e-9 {
            if observeEvery > 0, t >= nextObserve - 1e-9 {
                gate.observe(pose: p ?? pose(), isTracked: true, isFlat: flat, at: t)
                nextObserve += observeEvery
            }
            gate.tick(at: t)
            drain()
            t += 0.05
        }
    }

    /// Tracked observations at `rateHz` from `from` (inclusive) to `to` (exclusive), with the card sliding from
    /// `x0` to `x1`. The headset reports 22–30 Hz, and the continuity gate only accepts steps under `jumpDistance`,
    /// so motion in these scenarios has to be continuous — which is what a hand moving a device actually looks like.
    /// Returns the time just past the last observation.
    @discardableResult
    private func stream(from: TimeInterval, to: TimeInterval, x0: Float, x1: Float? = nil, rateHz: Double = 30,
                        tiltDegrees: Float = 0, y: Float = 0.9, flat: Bool = true) -> TimeInterval {
        let period = 1 / rateHz
        let span = max(1e-9, to - from)
        var t = from
        while t < to - 1e-9 {
            let u = Float((t - from) / span)
            let x = x0 + (x1.map { ($0 - x0) * u } ?? 0)
            gate.observe(pose: pose(x: x, y: y, tiltDegrees: tiltDegrees), isTracked: true, isFlat: flat, at: t)
            gate.tick(at: t)
            drain()
            t += period
        }
        return t
    }

    private var acceptedX: Float { gate.acceptedPose?.columns.3.x ?? .nan }

    /// The `.thaw` glide of the last transition, or nil.
    private var lastThawGlide: Float? {
        guard case .thaw(let glide)? = events.last(where: { $0.transition != nil })?.transition else { return nil }
        return glide
    }

    /// Steady tracking until expanded (cinematic).
    private func bringUp() {
        run(from: 0, to: 1.0, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 1)
    }

    private func transitions(_ t: PresenceGate.Transition) -> Int {
        events.filter { $0.transition == t }.count
    }

    private var sawAbsent: Bool { events.contains { $0.presence == .absent } }

    private func firstTime(where predicate: (PresenceGate.Event) -> Bool) -> Int? {
        events.firstIndex(where: predicate)
    }

    // MARK: T3 — 30 s of steady updates: never hides, exactly one cinematic

    func testSteadyTrackingNeverHides() {
        run(from: 0, to: 30, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)
        XCTAssertFalse(sawAbsent)
        XCTAssertFalse(events.contains { $0.presence.isHeld })
        // First detection is flagged as the first acquire; the cinematic follows the 0.3 s stationary wait.
        XCTAssertEqual(events.first?.presence, .acquiring)
        XCTAssertEqual(events.first?.firstAcquire, true)
    }

    // MARK: T4 — button press then a nudge: no carry, no hide

    func testButtonHoldThenNudge() {
        bringUp()
        events.removeAll()
        let t0: TimeInterval = 1.0
        gate.buttonPressed(at: t0)
        drain()
        XCTAssertEqual(gate.presence, .held(.button))
        XCTAssertEqual(transitions(.freeze), 1)
        // The nudge lands during the hold: the pose is frozen, nothing moves.
        run(from: t0 + 0.05, to: t0 + 1.4, observeEvery: 0.16, pose: pose(x: 0.05))
        XCTAssertEqual(gate.presence, .held(.button))
        // Hold over at t0 + 1.5: thaw glides ~5 cm back to expanded.
        stream(from: t0 + 1.45, to: t0 + 1.8, x0: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
        guard let glide = lastThawGlide else { return XCTFail("expected a thaw, got \(events)") }
        XCTAssertEqual(glide, 0.05, accuracy: 0.005)
        // Boost window (1.5 s after the hold): a further 5 cm does not collapse (thresholds doubled to 10 cm / 36°).
        stream(from: t0 + 1.8, to: t0 + 2.2, x0: 0.05, x1: 0.10)
        stream(from: t0 + 2.2, to: t0 + 2.9, x0: 0.10)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
        // After the boost the same kind of move does collapse, once it has lasted `collapseSustain`.
        stream(from: t0 + 3.1, to: t0 + 3.6, x0: 0.10, x1: 0.30)
        XCTAssertEqual(gate.presence, .carrying(.moving))
        XCTAssertEqual(transitions(.carry), 1)
        XCTAssertFalse(sawAbsent)
    }

    // MARK: T5 — hand over the card for 3 s: held(stale) then thaw with ~0 glide

    func testOcclusionHoldsThenThaws() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 4.0)                       // no observations for 3 s
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertEqual(transitions(.freeze), 1)
        XCTAssertFalse(sawAbsent)
        run(from: 4.05, to: 4.5, observeEvery: 0.16)   // seen again
        XCTAssertEqual(gate.presence, .expanded)
        guard case .thaw(let glide)? = events.last(where: { $0.transition != nil })?.transition else {
            return XCTFail("expected a thaw")
        }
        XCTAssertEqual(glide, 0, accuracy: 0.001)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertEqual(transitions(.reentry), 0)
        XCTAssertEqual(events.last(where: { $0.transition != nil })?.resumeFromWorld, false)
    }

    // MARK: T6 — pick up, move 30 cm, put down: carry ≤ 0.3 s, settle ≤ 0.6 s after stopping

    func testCarryAndSettle() {
        bringUp()
        events.removeAll()
        // 30 cm over 1 s at 30 Hz = 1 cm per update — a real move, continuous, every step well inside the
        // continuity gate. The collapse needs `collapseSustain` past the 5 cm mark, so it lands ≈ 0.45 s in.
        var t: TimeInterval = 1.0
        var carryTime: TimeInterval?
        while t < 2.0 - 1e-9 {
            gate.observe(pose: pose(x: Float(t - 1.0) * 0.30), isTracked: true, isFlat: true, at: t)
            gate.tick(at: t)
            drain()
            if carryTime == nil, events.contains(where: { $0.transition == .carry }) { carryTime = t }
            t += 1.0 / 30
        }
        XCTAssertNotNil(carryTime)
        XCTAssertLessThanOrEqual((carryTime ?? 99) - 1.0, gate.collapseSustain + 0.26)
        XCTAssertEqual(gate.presence, .carrying(.moving))
        // Stops at x ≈ 0.30: settling within 0.6 s, expanded 0.45 s later, nothing hidden, no cinematic.
        events.removeAll()
        let stop = t
        var settleTime: TimeInterval?
        var expandedTime: TimeInterval?
        while t < stop + 2 {
            gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: t)
            gate.tick(at: t)
            drain()
            if settleTime == nil, events.contains(where: { $0.transition == .settle }) { settleTime = t }
            if expandedTime == nil, events.contains(where: { $0.presence == .expanded }) { expandedTime = t }
            t += 0.05
        }
        XCTAssertNotNil(settleTime)
        XCTAssertLessThanOrEqual((settleTime ?? 99) - stop, 0.6)
        XCTAssertNotNil(expandedTime)
        XCTAssertEqual((expandedTime ?? 0) - (settleTime ?? 0), 0.45, accuracy: 0.06)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.settle), 1)
        XCTAssertEqual(transitions(.carry), 0)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertFalse(sawAbsent)
    }

    // MARK: T7 — looking away for 10 s pauses the grace: still there when looking back

    func testOutOfViewPausesGrace() {
        bringUp()
        events.removeAll()
        gate.setInView(false, at: 1.0)
        run(from: 1.05, to: 11.0)                      // no observations, out of view
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertFalse(sawAbsent)
        gate.setInView(true, at: 11.0)
        run(from: 11.05, to: 11.4, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
    }

    // MARK: T8 (v1 behaviour, `--legacy-hide` only) — card taken away: absent after the grace, back with a reentry

    func testLegacyHideGraceExpiryThenReentry() {
        gate.legacyHide = true
        bringUp()
        events.removeAll()
        let lastUpdate: TimeInterval = 0.96   // last observation of bringUp (0.16 grid)
        var t: TimeInterval = 1.05
        var hideTime: TimeInterval?
        while t < 12 {
            gate.tick(at: t)
            drain()
            if hideTime == nil, events.contains(where: { $0.transition == .hide }) { hideTime = t }
            t += 0.05
        }
        XCTAssertNotNil(hideTime)
        // 0.8 s until stale + 6.0 s grace.
        XCTAssertEqual((hideTime ?? 0) - lastUpdate, 6.8, accuracy: 0.15)
        XCTAssertEqual(gate.presence, .absent)
        events.removeAll()
        run(from: 12.0, to: 13.0, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.reentry), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertEqual(events.first?.firstAcquire, false)
        let reentryIndex = firstTime { $0.transition == .reentry }
        XCTAssertNotNil(reentryIndex)
    }

    // MARK: Theme hold: will_change freezes, changed thaws; the 3 s cap falls back to an 8 s window

    func testThemeHoldAndThaw() {
        bringUp()
        events.removeAll()
        gate.beginHold(.theme, at: 1.0)
        drain()
        XCTAssertEqual(gate.presence, .held(.theme))
        XCTAssertEqual(transitions(.freeze), 1)
        // Tracking updates during the hold change nothing.
        run(from: 1.05, to: 1.5, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .held(.theme))
        gate.endHold(.theme, at: 1.55)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
    }

    /// v2: the theme cap falls back into `held(.stale)` like any other loss — with **no** fuse. The `tick` release
    /// used to hand it the 8 s reacquire window unconditionally, which made a redraw the wearer happened not to be
    /// looking at the one way the card could still disappear.
    func testThemeHoldCapWithoutImageNeverHides() {
        bringUp()
        events.removeAll()
        gate.beginHold(.theme, at: 1.0)
        drain()
        XCTAssertEqual(gate.presence, .held(.theme))
        run(from: 1.05, to: 31.0)                            // no observations for 30 s
        XCTAssertEqual(gate.presence, .held(.stale))         // released by the 3 s cap, then simply waiting
        XCTAssertEqual(transitions(.hide), 0)
        XCTAssertFalse(sawAbsent)
        XCTAssertEqual(transitions(.search), 1)              // the one thing the wearer may see
    }

    func testLegacyHideThemeHoldCapThenReacquireWindow() {
        gate.legacyHide = true
        bringUp()
        events.removeAll()
        gate.beginHold(.theme, at: 1.0)
        drain()
        var t: TimeInterval = 1.05
        var releasedAt: TimeInterval?
        var hiddenAt: TimeInterval?
        while t < 14 {
            gate.tick(at: t)
            drain()
            if releasedAt == nil, gate.presence == .held(.stale) { releasedAt = t }
            if hiddenAt == nil, gate.presence == .absent { hiddenAt = t }
            t += 0.05
        }
        XCTAssertEqual(releasedAt ?? 0, 4.0, accuracy: 0.1)      // 3 s cap
        XCTAssertEqual(hiddenAt ?? 0, 12.0, accuracy: 0.15)      // + 8 s reacquire window
    }

    /// `changed` to another image: the old image's observations must not thaw; wait in the 8 s window for the new one.
    func testThemeChangeToOtherImageWaitsForNewImage() {
        bringUp()
        events.removeAll()
        gate.beginHold(.theme, at: 1.0)
        run(from: 1.05, to: 1.4, observeEvery: 0.16)            // old image still reported while the device redraws
        gate.endHold(.theme, trackedRecently: false, at: 1.45)   // the device now shows a different theme
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertEqual(transitions(.thaw(glide: 0)), 0)
        run(from: 1.5, to: 8.9)                                  // 7.45 s without the new image: inside the 8 s window
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertFalse(sawAbsent)
        run(from: 8.95, to: 9.3, observeEvery: 0.16)             // new image found
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
    }

    func testLegacyHideThemeChangeWindowExpiresToAbsent() {
        gate.legacyHide = true
        bringUp()
        events.removeAll()
        gate.beginHold(.theme, at: 1.0)
        gate.endHold(.theme, trackedRecently: false, at: 1.45)
        var t: TimeInterval = 1.5
        var hiddenAt: TimeInterval?
        while t < 12 {
            gate.tick(at: t)
            drain()
            if hiddenAt == nil, gate.presence == .absent { hiddenAt = t }
            t += 0.05
        }
        XCTAssertEqual(hiddenAt ?? 0, 9.45, accuracy: 0.1)      // 1.45 + 8 s reacquire window
    }

    /// Session teardown hides now; the next session starts clean and plays the cinematic again.
    func testTeardownHidesAndNextSessionIsCinematic() {
        bringUp()
        events.removeAll()
        gate.forceHide(at: 1.0, reason: "teardown")
        gate.beginSession()
        drain()
        XCTAssertEqual(events.first?.transition, .hide)
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertFalse(gate.revealedOnce)
        events.removeAll()
        run(from: 2.0, to: 3.0, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)
    }

    func testThemeHoldFromAbsentIsNoOp() {
        gate.beginHold(.theme, at: 0)
        drain()
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertTrue(events.isEmpty)
    }

    // MARK: World hold: unlimited; back on the desk → thaw once the card is seen (6 s window)

    func testWorldHoldIsUnlimited() {
        bringUp()
        events.removeAll()
        gate.beginHold(.world, at: 1.0)
        gate.setPaused(true, at: 1.0)
        run(from: 1.05, to: 25.0)
        XCTAssertEqual(gate.presence, .held(.world))
        gate.setPaused(false, at: 25.0)
        gate.endHold(.world, at: 25.0)
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))      // not seen yet: waits, does not hide
        run(from: 25.05, to: 27.0)
        XCTAssertEqual(gate.presence, .held(.stale))
        run(from: 27.05, to: 27.5, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
        XCTAssertFalse(sawAbsent)
    }

    /// World released the desk before the card was seen again: the wait in held(.stale) must not lose the return light.
    func testWorldReturnAfterStaleWaitCarriesResumeFlag() {
        bringUp()
        events.removeAll()
        gate.beginHold(.world, at: 1.0)
        gate.setPaused(true, at: 1.0)
        run(from: 1.05, to: 6.0)
        gate.setPaused(false, at: 6.0)
        gate.endHold(.world, at: 6.0)                       // `onReturnedToDesk`, card not found yet
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))
        run(from: 6.05, to: 7.0)                            // still looking
        run(from: 7.05, to: 7.4, observeEvery: 0.16)        // found
        XCTAssertEqual(gate.presence, .expanded)
        let thaw = events.last { $0.transition != nil }
        XCTAssertEqual(thaw?.transition, .thaw(glide: 0))
        XCTAssertEqual(thaw?.resumeFromWorld, true)
        // A later ordinary occlusion does not inherit the flag.
        events.removeAll()
        run(from: 7.45, to: 9.0)
        run(from: 9.05, to: 9.4, observeEvery: 0.16)
        XCTAssertEqual(events.last { $0.transition != nil }?.resumeFromWorld, false)
    }

    func testWorldReturnDirectThawCarriesResumeFlag() {
        bringUp()
        events.removeAll()
        gate.beginHold(.world, at: 1.0)
        run(from: 1.05, to: 3.0, observeEvery: 0.16)        // card in view all along (a .mixed world)
        gate.endHold(.world, at: 3.0)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(events.last?.resumeFromWorld, true)
    }

    // MARK: Replay: hide now, cinematic 1.3 s later

    func testReplayHidesThenPlaysCinematic() {
        bringUp()
        events.removeAll()
        gate.requestReplay(at: 1.0)
        drain()
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertEqual(transitions(.hide), 1)
        var t: TimeInterval = 1.05
        var cinematicAt: TimeInterval?
        while t < 4 {
            gate.observe(pose: pose(), isTracked: true, isFlat: true, at: t)
            gate.tick(at: t)
            drain()
            if cinematicAt == nil, events.contains(where: { $0.transition == .cinematic }) { cinematicAt = t }
            t += 0.05
        }
        XCTAssertEqual((cinematicAt ?? 0) - 1.0, 1.3, accuracy: 0.11)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)
        XCTAssertEqual(gate.presence, .expanded)
    }

    // MARK: Flat gate demotes to carrying(.notFlat); the first carry *is* the reveal (v3 FIX C)

    /// **v3 changed this.** It used to assert that putting the passport down after a first detection in the
    /// hand played the full `cinematic` — the gate still owed one, because only `expanded` had ever counted
    /// as a reveal. With the object source that first `acquiring → carrying` is answered by
    /// `unfoldFromDevice`: the card stands up out of the screen in the wearer's hand. On the headset the
    /// put-down then replayed the whole ink choreography on the desk
    /// (`carrying(notFlat) → expanded (stationary, first reveal · cinematic)` + `[reveal] ink start`), which
    /// read as the card being introduced twice. The carry now claims the reveal and the put-down is a settle.
    func testFirstCarryIsTheRevealAndThePutDownIsASettle() {
        run(from: 0, to: 1.0, observeEvery: 0.16, flat: false)
        XCTAssertEqual(gate.presence, .carrying(.notFlat))
        XCTAssertEqual(transitions(.carry), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertTrue(gate.revealedOnce, "the carry is the reveal")
        XCTAssertFalse(sawAbsent)

        run(from: 1.05, to: 1.6, observeEvery: 0.16, flat: true)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 0, "no second introduction")
        XCTAssertEqual(transitions(.settle), 1)
        XCTAssertTrue(events.contains { $0.presence == .settling })
    }

    /// A first detection that is flat and still is unaffected: the desk reveal is the cinematic, as always.
    func testFirstDetectionOnTheDeskIsStillTheCinematic() {
        bringUp()
        XCTAssertEqual(transitions(.settle), 0)
        XCTAssertTrue(gate.revealedOnce)
    }

    /// The world's 6 s reacquire window is a hide deadline under `--legacy-hide` only (v2 waits forever).
    func testLegacyHideWorldWindowExpires() {
        gate.legacyHide = true
        bringUp()
        events.removeAll()
        gate.beginHold(.world, at: 1.0)
        gate.setPaused(true, at: 1.0)
        run(from: 1.05, to: 5.0)
        gate.setPaused(false, at: 5.0)
        gate.endHold(.world, at: 5.0)                    // back on the desk, card not found yet
        XCTAssertEqual(gate.presence, .held(.stale))
        var t: TimeInterval = 5.05
        var hiddenAt: TimeInterval?
        while t < 13 {
            gate.tick(at: t)
            drain()
            if hiddenAt == nil, gate.presence == .absent { hiddenAt = t }
            t += 0.05
        }
        XCTAssertEqual(hiddenAt ?? 0, 11.0, accuracy: 0.1)   // 5.0 + the 6 s world window
    }

    // MARK: v2 — recognition places the card, it does not decide whether the card exists

    /// The headline of 工作包 A: two minutes without a single image update must not take the hologram away, and
    /// the only thing the wearer ever sees is one search cue, 3 s in, and only while they are looking at it.
    func testSilentLossNeverHides() {
        bringUp()
        events.removeAll()
        let lastUpdate: TimeInterval = 0.96              // last observation of bringUp (0.16 grid)
        var t: TimeInterval = 1.05
        var freezeAt: TimeInterval?
        var searchAt: TimeInterval?
        while t < 121 {
            gate.tick(at: t)
            drain()
            if freezeAt == nil, events.contains(where: { $0.transition == .freeze }) { freezeAt = t }
            if searchAt == nil, events.contains(where: { $0.transition == .search }) { searchAt = t }
            t += 0.05
        }
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertFalse(sawAbsent)
        XCTAssertEqual(transitions(.hide), 0)
        XCTAssertEqual(transitions(.freeze), 1)
        XCTAssertEqual(transitions(.search), 1)          // once, not a pulse every 3 s
        XCTAssertEqual((freezeAt ?? 0) - lastUpdate, gate.staleSoft, accuracy: 0.1)
        XCTAssertEqual((searchAt ?? 0) - (freezeAt ?? 0), gate.searchCueAfter, accuracy: 0.1)
        // The cue keeps the presence exactly where it is: it is a visual event, not a state change.
        XCTAssertEqual(events.first(where: { $0.transition == .search })?.presence, .held(.stale))

        // Seen again after two minutes: an ordinary thaw, no reveal, no reentry.
        run(from: 121, to: 121.5, observeEvery: 0.16)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertEqual(transitions(.reentry), 0)

        // The same loss while looking somewhere else is completely silent (and still never hides).
        events.removeAll()
        gate.setInView(false, at: 121.5)
        run(from: 121.55, to: 241.5)
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertEqual(transitions(.search), 0)
        XCTAssertEqual(transitions(.hide), 0)
    }

    /// `staleSoft` 0.5 → 0.8 s: the freeze/thaw pair the first device test saw every few seconds came from a
    /// 6 Hz stream that misses an update now and then, not from the card being gone.
    func testStaleSoftIsPointEight() {
        XCTAssertEqual(gate.staleSoft, 0.8, accuracy: 0.0001)
        bringUp()
        events.removeAll()
        let lastUpdate: TimeInterval = 0.96
        var t: TimeInterval = 1.05
        while t < lastUpdate + 0.75 {                    // 0.75 s gap: still expanded under 0.8, frozen under 0.5
            gate.tick(at: t)
            drain()
            t += 0.05
        }
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.freeze), 0)
        while t < lastUpdate + 1.0 {
            gate.tick(at: t)
            drain()
            t += 0.05
        }
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertEqual(transitions(.freeze), 1)
    }

    // MARK: M1b — the continuity gate: ARKit drift must not move (or fold) the card

    /// Device round 1: one *tracked* observation 9.8 cm / 20° away, with nobody touching the device. It used to
    /// collapse the card into `carrying` and re-settle it at the wrong spot.
    func testSingleOutlierDoesNotCollapse() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        let accepted = gate.observe(pose: pose(x: 0.098, tiltDegrees: 20), isTracked: true, isFlat: true, at: 2.0)
        gate.tick(at: 2.0)
        drain()
        XCTAssertFalse(accepted, "the outlier must not be accepted")
        XCTAssertEqual(acceptedX, 0, accuracy: 1e-5)
        XCTAssertEqual(gate.outlierCount, 1)
        stream(from: 2.05, to: 3.0, x0: 0)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
        XCTAssertTrue(events.isEmpty, "an outlier is silent: \(events)")
    }

    /// The occlusion shape: a jump that does not last long enough to be believed, then the image is lost. The
    /// freeze has to take the last *accepted* pose, so coming back at the real spot is a 0 cm thaw.
    func testOcclusionJumpThenLossFreezesAtRestPose() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 2.8, x0: 0.098)                 // 0.8 s, under `jumpAcceptAfter`
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
        XCTAssertEqual(acceptedX, 0, accuracy: 1e-5)
        gate.observe(pose: pose(x: 0.098), isTracked: false, isFlat: true, at: 2.8)
        drain()
        XCTAssertEqual(gate.presence, .held(.untracked))
        stream(from: 3.5, to: 4.0, x0: 0)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
        XCTAssertEqual(gate.relocateCount, 0)
    }

    /// The same 9.8 cm jump, but tilted 20°: whatever that pose is, it is not a card lying on a desk, so it is
    /// never accepted no matter how long ARKit insists on it.
    func testDriftedJumpIsNeverAccepted() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 5.0, x0: 0.098, tiltDegrees: 20)
        XCTAssertEqual(gate.presence, .expanded, "ARKit is still seeing the image, it is just wrong about where")
        XCTAssertEqual(gate.relocateCount, 0)
        XCTAssertEqual(acceptedX, 0, accuracy: 1e-5)
        XCTAssertTrue(events.isEmpty, "a drifted pose must produce no events at all: \(events)")
        gate.observe(pose: pose(x: 0.098, tiltDegrees: 20), isTracked: false, isFlat: true, at: 5.0)
        drain()
        XCTAssertEqual(gate.presence, .held(.untracked))
        stream(from: 5.5, to: 6.0, x0: 0)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.thaw(glide: 0)), 1)
        XCTAssertEqual(gate.relocateCount, 0)
    }

    /// Flat, at the same height, and it holds its ground past `jumpAcceptAfter`: the card really was moved while we
    /// could not see it happen. The presence does not change — only the pose, through one thaw.
    func testFlatSameHeightJumpIsAcceptedAfterOnePointFive() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 3.7, x0: 0.098)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
        let thaws = events.filter { if case .thaw = $0.transition { return true } else { return false } }
        XCTAssertEqual(thaws.count, 1)
        guard case .thaw(let glide)? = thaws.first?.transition else { return XCTFail("expected a thaw") }
        XCTAssertEqual(glide, 0.098, accuracy: 0.002)
        XCTAssertEqual(gate.relocateCount, 1)
        XCTAssertEqual(acceptedX, 0.098, accuracy: 1e-5)
        // The rest pose moved with it, so sitting there does not then look like a collapse.
        stream(from: 3.7, to: 4.6, x0: 0.098)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
    }

    // MARK: M1b — a real move still collapses (continuous motion, 30 Hz)

    func testSustainedMoveCollapses() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 2.3, x0: 0, x1: 0.075)
        XCTAssertEqual(gate.presence, .expanded, "far from rest, but not yet for `collapseSustain`")
        stream(from: 2.3, to: 2.6, x0: 0.075, x1: 0.15)
        XCTAssertEqual(gate.presence, .carrying(.moving))
        XCTAssertEqual(transitions(.carry), 1)
        XCTAssertFalse(sawAbsent)
    }

    /// 30 cm/s, 1 cm per update: every single step is far below `jumpDistance`, so nothing here is an outlier.
    func testContinuousSlideCollapses() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 2.4, x0: 0, x1: 0.12)          // crosses 5 cm from the rest pose at ≈ 2.2
        XCTAssertEqual(gate.presence, .expanded)
        stream(from: 2.4, to: 2.55, x0: 0.12, x1: 0.165)
        XCTAssertEqual(gate.presence, .carrying(.moving))
        XCTAssertEqual(transitions(.carry), 1)
    }

    /// Two nudges that never add up: the rest pose follows the card whenever it has been still, so 4 cm now and
    /// 2 cm later are each measured from where the card actually is.
    func testTwoSmallNudgesNeverCollapse() {
        bringUp()
        events.removeAll()
        stream(from: 1.0, to: 2.0, x0: 0)
        stream(from: 2.0, to: 2.27, x0: 0, x1: 0.04)         // 4 cm in 5 mm steps
        stream(from: 2.27, to: 3.3, x0: 0.04)                // 1 s still: the rest pose catches up
        stream(from: 3.3, to: 3.44, x0: 0.04, x1: 0.06)      // 2 cm more
        stream(from: 3.44, to: 4.5, x0: 0.06)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.carry), 0)
        XCTAssertTrue(events.isEmpty, "two small nudges must be completely silent: \(events)")
    }

    // MARK: M1b — relocation needs two consistent detections

    func testNearbyDetectionThawsImmediately() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 3.0)                             // no observations: held(.stale)
        XCTAssertEqual(gate.presence, .held(.stale))
        gate.observe(pose: pose(x: 0.01), isTracked: true, isFlat: true, at: 3.0)
        gate.tick(at: 3.0)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertFalse(gate.hasRelocateCandidate)
        XCTAssertEqual(gate.relocateCount, 0)
        XCTAssertEqual(lastThawGlide ?? -1, 0.01, accuracy: 0.001)
    }

    func testRelocationNeedsConsistentDetections() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 3.0)
        XCTAssertEqual(gate.presence, .held(.stale))
        events.removeAll()                                   // the freeze itself
        gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 3.0)
        gate.tick(at: 3.0)
        drain()
        XCTAssertEqual(gate.presence, .held(.stale), "one far detection must not thaw the card onto it")
        XCTAssertTrue(gate.hasRelocateCandidate)
        XCTAssertTrue(events.isEmpty, "waiting for a confirmation is silent: \(events)")
        gate.observe(pose: pose(x: 0.305), isTracked: true, isFlat: true, at: 3.3)
        gate.tick(at: 3.3)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(lastThawGlide ?? -1, 0.305, accuracy: 0.01)
        XCTAssertEqual(gate.relocateCount, 1)
        XCTAssertFalse(gate.hasRelocateCandidate)
    }

    func testRelocationCandidateExpires() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 3.0)
        gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 3.0)
        gate.tick(at: 3.0)
        drain()
        XCTAssertTrue(gate.hasRelocateCandidate)
        run(from: 3.05, to: 3.75)                            // the 0.6 s window runs out
        XCTAssertFalse(gate.hasRelocateCandidate)
        gate.observe(pose: pose(x: 0.305), isTracked: true, isFlat: true, at: 3.8)
        gate.tick(at: 3.8)
        drain()
        XCTAssertEqual(gate.presence, .held(.stale), "0.8 s later is a new candidate, not a confirmation")
        gate.observe(pose: pose(x: 0.305), isTracked: true, isFlat: true, at: 4.1)
        gate.tick(at: 4.1)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(gate.relocateCount, 1)
    }

    func testInconsistentSecondDetectionReplacesCandidate() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 3.0)
        gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 3.0)
        gate.tick(at: 3.0)
        drain()
        gate.observe(pose: pose(x: 0.36), isTracked: true, isFlat: true, at: 3.3)   // 6 cm off: not the same place
        gate.tick(at: 3.3)
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertTrue(gate.hasRelocateCandidate)
        gate.observe(pose: pose(x: 0.362), isTracked: true, isFlat: true, at: 3.5)  // confirms the *new* candidate
        gate.tick(at: 3.5)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(lastThawGlide ?? -1, 0.362, accuracy: 0.01)
        XCTAssertEqual(gate.relocateCount, 1)
    }

    /// A tilted detection is neither a confirmation nor a candidate — the card must not thaw onto a reflection.
    func testTiltedDetectionDoesNotConfirmRelocation() {
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 3.0)
        for time in [3.0, 3.3] as [TimeInterval] {
            gate.observe(pose: pose(x: 0.30, tiltDegrees: 20), isTracked: true, isFlat: true, at: time)
            gate.tick(at: time)
            drain()
        }
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertFalse(gate.hasRelocateCandidate)
        // Flat ones at the same place do relocate it.
        gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 3.6)
        gate.tick(at: 3.6)
        drain()
        XCTAssertTrue(gate.hasRelocateCandidate)
        gate.observe(pose: pose(x: 0.305), isTracked: true, isFlat: true, at: 3.9)
        gate.tick(at: 3.9)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(gate.relocateCount, 1)
    }

    /// The world's return light must survive the two-detection wait, relocation included.
    func testWorldHoldReleaseStillPlaysReturnLightAfterRelocation() {
        bringUp()
        events.removeAll()
        gate.beginHold(.world, at: 1.0)
        gate.setPaused(true, at: 1.0)
        run(from: 1.05, to: 6.0)
        gate.setPaused(false, at: 6.0)
        gate.endHold(.world, at: 6.0)                        // back on the desk, card not found yet
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))
        gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 6.5)
        gate.tick(at: 6.5)
        drain()
        XCTAssertEqual(gate.presence, .held(.stale))
        gate.observe(pose: pose(x: 0.305), isTracked: true, isFlat: true, at: 6.8)
        gate.tick(at: 6.8)
        drain()
        XCTAssertEqual(gate.presence, .expanded)
        let thaw = events.last { $0.transition != nil }
        XCTAssertEqual(thaw?.resumeFromWorld, true)
        XCTAssertEqual(gate.relocateCount, 1)
    }

    // MARK: Director mode: grace never runs out

    func testDirectorModeNeverHides() {
        gate.directorMode = true
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 40)
        XCTAssertEqual(gate.presence, .held(.stale))
        XCTAssertFalse(sawAbsent)
    }

    // MARK: Explicit dismiss / show (工作包 A 显式隐藏/显示)

    /// The base-ring tap folds the card away and the image being in plain sight does not bring it back —
    /// that is the whole point of making hiding a decision instead of a timeout.
    func testDismissIgnoresObservationsUntilShow() {
        bringUp()
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertTrue(gate.isDismissed)
        XCTAssertEqual(transitions(.hide), 1)
        XCTAssertEqual(events.first(where: { $0.transition == .hide })?.hideKind, .dismiss)

        // Ten seconds of perfectly good observations change nothing.
        run(from: 1.05, to: 11, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertEqual(transitions(.reentry), 0)

        gate.requestShow(at: 11.1)
        XCTAssertFalse(gate.isDismissed)
        run(from: 11.15, to: 12.5, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
    }

    /// Coming back from a dismiss is a reentry, not a second cinematic: the card was put away, not reset.
    func testDismissThenShowIsReentry() {
        bringUp()
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        gate.requestShow(at: 1.5)
        run(from: 1.55, to: 3, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.reentry), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
    }

    /// **v4 B3 §2.** A summon that replays the recognition: the next detection is a *first* acquire (so the controller
    /// runs the ribbon, not the short scan) and lands as the cinematic on the desk — the session's first path, again.
    func testSummonWithReplayRecognitionIsAFirstAcquireAndACinematic() {
        bringUp()
        XCTAssertEqual(events.filter(\.firstAcquire).count, 1)
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        gate.requestShow(at: 1.5, replayRecognition: true)
        XCTAssertFalse(gate.isDismissed)
        run(from: 1.55, to: 3, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(events.first(where: { $0.presence == .acquiring })?.firstAcquire, true)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)

        // …every time: a second collapse and summon plays it again.
        events.removeAll()
        gate.requestDismiss(at: 4.0)
        drain()
        gate.requestShow(at: 4.5, replayRecognition: true)
        run(from: 4.55, to: 6, observeEvery: 0.05)
        XCTAssertEqual(events.first(where: { $0.presence == .acquiring })?.firstAcquire, true)
        XCTAssertEqual(transitions(.cinematic), 1)
    }

    /// **v4 B3 §2.** In the hand the same summon is a first acquire that arrives as a `.carry` (the controller's unfold,
    /// held for the recognition's closure) — and the put-down after it is a settle, not a second cinematic.
    func testSummonWithReplayRecognitionInTheHandIsACarry() {
        bringUp()
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        gate.requestShow(at: 1.5, replayRecognition: true)
        run(from: 1.55, to: 2.5, observeEvery: 0.05, pose: pose(y: 1.1, tiltDegrees: 60), flat: false)
        XCTAssertEqual(events.first(where: { $0.presence == .acquiring })?.firstAcquire, true)
        XCTAssertEqual(gate.presence, .carrying(.notFlat))
        XCTAssertEqual(transitions(.carry), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
    }

    /// The default summon (and `--v3-card`'s) is unchanged: a reentry, no first acquire.
    func testSummonWithoutReplayRecognitionStaysAReentry() {
        bringUp()
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        gate.requestShow(at: 1.5, replayRecognition: false)
        run(from: 1.55, to: 3, observeEvery: 0.05)
        XCTAssertEqual(events.first(where: { $0.presence == .acquiring })?.firstAcquire, false)
        XCTAssertEqual(transitions(.reentry), 1)
    }

    /// `replayRecognition` on a card that is not dismissed does nothing (the gate's `requestShow` guard).
    func testReplayRecognitionNeedsADismiss() {
        bringUp()
        events.removeAll()
        gate.requestShow(at: 1.5, replayRecognition: true)
        run(from: 1.55, to: 3, observeEvery: 0.05)
        XCTAssertEqual(transitions(.cinematic), 0)
        XCTAssertEqual(gate.presence, .expanded)
    }

    /// A replay still clears the dismiss and still plays the full cinematic — `--replay-after` and the director's
    /// `cmd replay` are unchanged by the fold.
    func testReplayStillPlaysCinematic() {
        bringUp()
        events.removeAll()
        gate.requestReplay(at: 1.0)
        drain()
        XCTAssertEqual(events.last(where: { $0.transition == .hide })?.hideKind, .replay)
        run(from: 1.05, to: 4, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)

        // … and it works from a dismissed card too: the replay clears the dismiss (there is nothing left to
        // hide, so no second `.hide` event — the card is already away) and plays the cinematic again.
        gate.requestDismiss(at: 5.0)
        drain()
        XCTAssertTrue(gate.isDismissed)
        events.removeAll()
        gate.requestReplay(at: 6.0)
        drain()
        XCTAssertFalse(gate.isDismissed)
        XCTAssertEqual(transitions(.hide), 0)
        run(from: 6.05, to: 9, observeEvery: 0.05)
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.cinematic), 1)
        XCTAssertEqual(transitions(.reentry), 0)
    }

    /// While the card is folded away the socket light is still burning on the device, and it is the only way
    /// back — so a moved device has to take it with it. The gate keeps ignoring the *presence* side of every
    /// observation (no reentry, no events) but still **accepts** tracked poses, which is what makes
    /// `CardTracker` write `latestPose` and `anchorRoot` follow the device.
    func testDismissedStillReportsPoses() {
        bringUp()
        events.removeAll()
        gate.requestDismiss(at: 1.0)
        drain()
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertTrue(gate.isDismissed)
        events.removeAll()

        // ARKit drift on the folded-away card: one *tracked* pose 10 cm off and tilted. The continuity gate still
        // applies — this must not carry the socket light off the device's screen.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.10, tiltDegrees: 20), isTracked: true, isFlat: true, at: 1.2))
        XCTAssertEqual(gate.acceptedPose?.columns.3.x ?? .nan, 0, accuracy: 1e-6)

        // The device is really slid 30 cm across the desk: continuous steps, every one accepted and reported …
        stream(from: 1.5, to: 3.0, x0: 0, x1: 0.30)
        XCTAssertEqual(gate.acceptedPose?.columns.3.x ?? .nan, 0.30, accuracy: 0.01)

        // … and nothing at all happens to the presence.
        XCTAssertEqual(gate.presence, .absent)
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(gate.isDismissed)

        // An *untracked* observation is refused (there is no pose in it to follow) and starts a fresh chain, so a
        // device carried out of view and put down elsewhere can never strand the socket light.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.9), isTracked: false, isFlat: true, at: 3.1))
        XCTAssertTrue(gate.observe(pose: pose(x: 0.9), isTracked: true, isFlat: true, at: 3.2))
        XCTAssertEqual(gate.acceptedPose?.columns.3.x ?? .nan, 0.9, accuracy: 1e-6)

        // And the way back is unchanged: the next observation after `requestShow()` is a reentry at the new spot.
        gate.requestShow(at: 3.5)
        run(from: 3.55, to: 5, observeEvery: 0.05, pose: pose(x: 0.9))
        XCTAssertEqual(gate.presence, .expanded)
        XCTAssertEqual(transitions(.reentry), 1)
        XCTAssertEqual(transitions(.cinematic), 0)
    }

    // MARK: v3 H1 — the object source's acceptance policy (`deskOnlyAcceptance = false`)

    /// **The bug V3-1 exists to fix.** Every test above runs with `deskOnlyAcceptance = true`, which is the
    /// image tracker's rule set and stays its rule set. These four are the object source's.
    ///
    /// A hand moving the passport at 0.8 m/s while the object tracker reports 15 Hz steps 5.3 cm apart: past
    /// the fixed 5 cm threshold on every single observation, so the old gate would have called the whole
    /// carry an outlier. The velocity test allows 1.5 m/s × 67 ms = 10 cm, and nothing is rejected.
    func testFastHandMotionIsAcceptedByTheVelocityGate() {
        gate.deskOnlyAcceptance = false
        bringUp()
        events.removeAll()
        let outliersBefore = gate.outlierCount
        // 0.8 m/s for 0.6 s at 15 Hz = nine 5.33 cm steps.
        var t = 1.05
        var x: Float = 0
        for _ in 0..<9 {
            x += 0.8 / 15
            XCTAssertTrue(gate.observe(pose: pose(x: x), isTracked: true, isFlat: true, at: t),
                          String(format: "step to %.3f m at %.2f s", x, t))
            gate.tick(at: t)
            drain()
            t += 1.0 / 15
        }
        XCTAssertEqual(gate.outlierCount, outliersBefore, "no step in a 0.8 m/s carry is an outlier")
        XCTAssertEqual(acceptedX, x, accuracy: 1e-5, "the card is where the device is")

        // The same stream under the image source's rules is rejected from the first step — this is the
        // comparison that says the change is the policy, not the numbers.
        var desk = PresenceGate()
        desk.logging = false
        gate = desk
        events.removeAll()
        bringUp()
        XCTAssertFalse(gate.observe(pose: pose(x: 0.8 / 15), isTracked: true, isFlat: true, at: 1.05))
        desk = gate
        XCTAssertEqual(desk.outlierCount, 1)
    }

    /// A 30 cm step is past *any* velocity: it is held as a candidate and accepted only when a second
    /// observation lands in the same place — no 1.5 s dwell, because in the hand that reads as a freeze.
    func testLargeHandJumpNeedsTwoConsistentSamples() {
        gate.deskOnlyAcceptance = false
        bringUp()
        events.removeAll()
        run(from: 1.05, to: 2.0, observeEvery: 0.05)

        // One detection 30 cm away: not accepted, and the card does not move.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 2.05))
        XCTAssertEqual(acceptedX, 0, accuracy: 1e-6)
        // A second one somewhere else entirely replaces the candidate rather than confirming it.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.55), isTracked: true, isFlat: true, at: 2.10))
        XCTAssertEqual(acceptedX, 0, accuracy: 1e-6)
        // Two consistent ones (within `relocateConsistency`) do accept it, on the second.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 2.15))
        XCTAssertTrue(gate.observe(pose: pose(x: 0.308), isTracked: true, isFlat: true, at: 2.20))
        XCTAssertEqual(acceptedX, 0.308, accuracy: 1e-5)
        drain()
        XCTAssertEqual(gate.relocateCount, 1)

        // …and a confirmation that arrives after `handConfirmWindow` is a new candidate, not a confirmation.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.9), isTracked: true, isFlat: true, at: 3.0))
        XCTAssertFalse(gate.observe(pose: pose(x: 0.9), isTracked: true, isFlat: true, at: 3.5))
        XCTAssertEqual(acceptedX, 0.308, accuracy: 1e-5)
    }

    /// The exact log line from the first Extended device round: `ignoring detection (20.8 cm, tilt 24° > 6°)`,
    /// repeated on every in-hand frame while the card sat frozen on the desk. Under the object source's rules
    /// the same two detections thaw the card onto the wearer's hand.
    func testTiltedDetectionInTheHandThawsAfterTwoConsistentSamples() {
        gate.deskOnlyAcceptance = false
        bringUp()
        events.removeAll()
        // The device is picked up and the object tracker loses it for a moment.
        gate.observe(pose: pose(), isTracked: false, isFlat: true, at: 1.1)
        drain()
        XCTAssertEqual(gate.presence, .held(.untracked))

        // Found again 20 cm away, tilted 24° and 23 cm higher — a passport in a hand, which the desk rules
        // reject on both counts (`acceptTiltMax` 6°, `acceptHeightDelta` 2 cm).
        let inHand = pose(x: 0.20, y: 1.13, tiltDegrees: 24)
        XCTAssertFalse(gate.observe(pose: inHand, isTracked: true, isFlat: false, at: 1.4))
        XCTAssertTrue(gate.hasRelocateCandidate, "a candidate, not a rejection")
        XCTAssertTrue(gate.observe(pose: pose(x: 0.205, y: 1.13, tiltDegrees: 24), isTracked: true, isFlat: false, at: 1.7))
        drain()
        XCTAssertFalse(gate.presence.isHeld, "the card followed the device into the hand")
        XCTAssertEqual(acceptedX, 0.205, accuracy: 1e-5)
    }

    /// **v3 FIX A.** The two-consistent confirmation used a fixed 1.5 cm window, which at 30 Hz is a hidden
    /// 0.45 m/s speed limit: while the hand was actually moving, a candidate could never be confirmed. Here a
    /// single outlier 40 cm away lands in the middle of a 0.6 m/s carry — it is dropped, and the very next
    /// real observation is accepted with no candidate left behind and no freeze.
    func testOutlierDuringAFastMoveDoesNotStallTheCard() {
        gate.deskOnlyAcceptance = false
        bringUp()
        events.removeAll()
        let outliersBefore = gate.outlierCount

        // 0.6 m/s at 30 Hz = 2 cm steps. Three of them, then one bad pose, then three more — all inside the
        // 0.25 s collapse sustain, so the gate is still `.expanded` and the continuity gate is really the
        // thing being tested (in `carrying` there is no continuity gate at all).
        var t = 1.05
        var x: Float = 0
        func step() -> Bool {
            x += 0.6 / 30
            let accepted = gate.observe(pose: pose(x: x), isTracked: true, isFlat: true, at: t)
            gate.tick(at: t)
            drain()
            t += 1.0 / 30
            return accepted
        }
        for _ in 0..<3 { XCTAssertTrue(step()) }
        XCTAssertEqual(gate.presence, .expanded)

        XCTAssertFalse(gate.observe(pose: pose(x: x + 0.40), isTracked: true, isFlat: true, at: t),
                       "40 cm in 33 ms is not a hand")
        t += 1.0 / 30
        XCTAssertEqual(gate.outlierCount, outliersBefore + 1)

        // The carry continues, uninterrupted, and the card is where the device is.
        for _ in 0..<3 { XCTAssertTrue(step(), "the move must not stall behind the outlier") }
        XCTAssertEqual(gate.presence, .expanded, "still gated, so the acceptances above meant something")
        XCTAssertEqual(gate.outlierCount, outliersBefore + 1, "exactly one outlier, not a chain of them")
        XCTAssertEqual(acceptedX, x, accuracy: 1e-5)
        XCTAssertFalse(gate.hasRelocateCandidate)
    }

    /// The other half of FIX A: re-acquired **while still moving** after a pick-up loss — the normal case, and
    /// the one that used to leave the card frozen on the desk until the wearer stopped.
    func testRelocationConfirmsWhileTheHandIsStillMoving() {
        gate.deskOnlyAcceptance = false
        bringUp()
        events.removeAll()
        gate.observe(pose: pose(), isTracked: false, isFlat: true, at: 1.1)
        drain()
        XCTAssertEqual(gate.presence, .held(.untracked))

        // 0.4 s of nothing, then the object tracker finds the passport 8 cm away, in a hand doing 0.6 m/s.
        XCTAssertFalse(gate.observe(pose: pose(x: 0.08, y: 1.10, tiltDegrees: 30), isTracked: true, isFlat: false, at: 1.5))
        XCTAssertTrue(gate.hasRelocateCandidate)
        XCTAssertTrue(gate.observe(pose: pose(x: 0.10, y: 1.10, tiltDegrees: 30), isTracked: true, isFlat: false, at: 1.533),
                      "2 cm further along the same move confirms it")
        drain()
        XCTAssertFalse(gate.presence.isHeld, "thawed on the second sample, mid-move")
        XCTAssertEqual(acceptedX, 0.10, accuracy: 1e-5)
    }

    /// The image source's confirmation window is untouched: still the fixed 1.5 cm, so a detection that moved
    /// 2 cm between the two samples is still two different detections, not one relocation.
    func testImageSourceConsistencyWindowIsUnchanged() {
        XCTAssertTrue(gate.deskOnlyAcceptance)
        bringUp()
        events.removeAll()
        gate.observe(pose: pose(), isTracked: false, isFlat: true, at: 1.1)
        drain()
        XCTAssertFalse(gate.observe(pose: pose(x: 0.30), isTracked: true, isFlat: true, at: 1.4))
        XCTAssertTrue(gate.hasRelocateCandidate)
        XCTAssertFalse(gate.observe(pose: pose(x: 0.32), isTracked: true, isFlat: true, at: 1.433),
                       "2 cm apart is still inconsistent for the image tracker")
        XCTAssertEqual(gate.presence, .held(.untracked))
        // …and 1 cm apart still confirms, exactly as it always did.
        XCTAssertTrue(gate.observe(pose: pose(x: 0.325), isTracked: true, isFlat: true, at: 1.466))
    }

    /// …and the image source keeps rejecting exactly that, for exactly the reason it always did: a tilted
    /// detection from a 37 mm self-lit target is a drifted one. The default is unchanged.
    func testImageSourceStillRejectsATiltedDetection() {
        XCTAssertTrue(gate.deskOnlyAcceptance, "the default is the image tracker's rule set")
        bringUp()
        events.removeAll()
        gate.observe(pose: pose(), isTracked: false, isFlat: true, at: 1.1)
        drain()
        XCTAssertEqual(gate.presence, .held(.untracked))
        for time in [1.4, 1.7, 2.0] as [TimeInterval] {
            XCTAssertFalse(gate.observe(pose: pose(x: 0.20, y: 1.13, tiltDegrees: 24), isTracked: true, isFlat: false, at: time))
        }
        XCTAssertFalse(gate.hasRelocateCandidate)
        XCTAssertEqual(gate.presence, .held(.untracked), "still frozen on the desk, as v2 intends")
    }
}
