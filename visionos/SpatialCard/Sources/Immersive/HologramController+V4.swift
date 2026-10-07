import Foundation
import QuartzCore
import RealityKit
import UIKit

/// **v4 B1 — recognition + hero card, in the product.**
///
/// The first detection is recognised by A2's ribbon instead of v3's box scan; the card is A4's hero card (A1's
/// materials once loaded) instead of v3's slab, rim and SwiftUI sheets. Everything else — the pick-up onto the hinge,
/// the hand deck, the put-down, the gallery and its previews, the keys, the worlds and the mini card, the
/// celebration, the fold and the summon, the face-down gesture — is v3's choreography, unchanged: it moves
/// `cardGroup`, and the hero card rides inside it (`V4CardIntegration`).
///
/// Beats of the first recognition (A2's clock, then the card's):
///
///     0.00  .burst      the real LCD is asked for its `glow` (`--lcd-burst flash`); the virtual burst in the simulator
///     0.10  .launch     the ribbon rises out of the screen, circles the device, draws the card's outline (portrait)
///     1.90  .closure    ← v3's convergence beat: chip, the device's `connect`, the held entrance is released;
///                         the card dissolves in from the outline (0.7 s), type and art behind its front, the pop-up
///                         opens (from 2.40), the count rolls (2.20 → lands 3.49 s)
///     2.40  .handOver   the outline fades (A2) — the card is ≈ 80 % dissolved and owns the scene
///     3.59              entrance complete → idle; the billboard eases to the wearer over 0.5 s
///
/// **The hand-over hold** (B1 follow-up, `V4.HandOverHold`): if A1's style is not on the card at the closure, the
/// closure plays its chip but not its release — the ribbon breaks up as designed, the recognition's clock waits at
/// 2.20 with the outline breathing, and the entrance stays held. The frame A1's style is in (at most 2.5 s later)
/// the release runs exactly as above, shifted: `[v4] hand-over held N ms for materials`; past the cap the placeholder
/// reveals the card, as before.
extension HologramController {
    // MARK: - Install

    /// Mount the hero card and the recognition (built asynchronously in `ImmersiveView`'s make closure, before any
    /// presence event is applied). v3's slab, rim, idle scan line and avatar sparks leave the tree — detached, not
    /// deleted, so every v3 write to them stays harmless.
    func installV4(_ integration: V4CardIntegration) {
        guard v4 == nil else { return }
        v4 = integration
        for entity in [slab, rim, idleScan, avatarSparks] as [Entity] { entity.removeFromParent() }
        cardFaceGroup.addChild(integration.mount)
        integration.probeForHinge(maxDepth: Self.hingeOverhangDepth)
        if let recognition = integration.recognition {
            recognition.root.isEnabled = true
            anchorRoot.addChild(recognition.root)
            recognition.cameraPosition = { [weak self] in self?.headWorldPosition }
            recognition.onBeat = { [weak self] beat, t in self?.recognitionBeat(beat, at: t) }
        }
        integration.onLeaveDeskIdle = { [weak self] reason in self?.leaveV4DeskIdle(reason: reason) }
        print("[v4] installed: hero card in cardGroup (mount at the inverse rest pose), recognition \(integration.recognition == nil ? "off (box scan)" : "on"), v3 slab / rim / idle scan / avatar sparks detached")
        Task { @MainActor [weak self, weak integration] in
            guard let integration else { return }
            await integration.loadMagic()
            // Before the card has ever been shown the swap cannot pop; otherwise it waits for the next entrance.
            guard let self, !self.hasShownCard else { return }
            integration.installMagicIfReady()
        }
    }

    /// The wearer's eyes, world space (nil before the first head pose).
    var headWorldPosition: SIMD3<Float>? {
        headPoseProvider?().map { SIMD3<Float>($0.columns.3.x, $0.columns.3.y, $0.columns.3.z) }
    }

    // MARK: - Recognition (A2's ribbon instead of the first detection's box scan)

    /// Will the next first detection be recognised by the ribbon? (v3's acquire flash stays off the LCD if so.)
    func willRecogniseWithRibbon(animated: Bool) -> Bool {
        v4?.recognition != nil && boxScanEnabled && animated
    }

    /// **v4 B4 §1.** Where the recognition starting now draws the card: the device's raw tilt and the desk gate's answer at
    /// `acquiring` (`V4.RecognitionPlan`). Without a reading it is the desk (the gate's own prior).
    func decideRecognitionPlace() -> V4.RecognitionPlan.Decision {
        let state = recognitionStateProvider?()
        let decision = V4.RecognitionPlan.decide(tilt: state?.tilt, deskGateOnDesk: state?.deskGateOnDesk ?? true,
                                                 handFormAvailable: usesHandForm && handForm == .hinge)
        guard let forced = recognitionPlaceOverride else { return decision }
        return .init(place: forced, tilt: decision.tilt, reason: "--recognition-place \(forced.rawValue); it read \(decision.reason)")
    }

    /// **v4 B4 §1.** The hinge angle the hand form will settle at for the wearer's head right now, frozen for the hand's
    /// recognition and reveal. Worked from the tracker's latest pose of the device, not from `handPivot`: at a first
    /// detection `apply(pose:)` has not placed `anchorRoot` yet (it runs after the transition). Without a head pose (none
    /// yet, or the simulator's first frames, which report the head at the world origin) the head is taken 40 cm out
    /// along the screen's normal — someone reading the passport they hold — and the line says so.
    func frozenHandHingeAngle(device: simd_float4x4?) -> (angle: Float, head: SIMD3<Float>?) {
        let weight = handFacing == .hinged ? HandFacing.hingeWeight : handFacing.weight
        func angle(headInS: SIMD3<Float>) -> Float {
            let inHinge = HandFacing.base.inverse.act(headInS - hingePosition)
            return HandFacing.restingHingeAngle(weight: weight, halfHeight: hingeCardPosition.y, head: inHinge)
        }
        guard let head = headWorldPosition, simd_length(head) > 1e-3,
              let screen = device ?? (hasPose ? anchorRoot.transformMatrix(relativeTo: nil) : nil) else {
            return (angle(headInS: Self.nominalHandHead), nil)
        }
        let local = simd_mul(screen.inverse, SIMD4<Float>(head.x, head.y, head.z, 1))
        return (angle(headInS: SIMD3<Float>(local.x, local.y, local.z)), head)
    }

    /// Where the head is taken to be, in S, when there is no head pose: 40 cm out along the screen's normal.
    static let nominalHandHead = SIMD3<Float>(0, 0.40, 0)

    /// Called by `startBoxScan` for a first detection. False = the ribbon is not available: v3's scan runs.
    func startV4Recognition() -> Bool {
        guard let v4, let recognition = v4.recognition else { return false }
        // v4 B2: parked after the last recognition (`parkRecognitionRig`); back in the tree before its first beat.
        recognition.root.isEnabled = true
        // v4 B3 §2: a summon (or a replay) starts here — the collapsed card's gold point fades as the ribbon leaves the screen.
        releaseGoldPoint(reason: "the ribbon leaves the screen")
        v4.recognitionRuns += 1
        scanPending = BoxScanTimeline.Pending()
        heldIntro = nil
        v4.recognitionHolding = true
        updateParticleRate()
        // v4 B4 §1: the flight is chosen once, before take-off (`runTransition` decided it before lighting the desk).
        let decision = pendingRecognitionDecision ?? decideRecognitionPlace()
        pendingRecognitionDecision = nil
        v4.closingRecognitionDecision = decision
        v4.handRecognition = nil
        var flight = RecognitionMagic.Flight.desk
        if decision.place == .hand {
            let frozen = frozenHandHingeAngle(device: recognitionStateProvider?().device)
            let geometry = V4.RecognitionTimeline.HandGeometry(
                hinge: hingePosition, hingeAngle: frozen.angle,
                cardWidth: cardSize.x * handScale, cardHeight: cardSize.y * handScale,
                cornerRadius: v4.rig.layout.cornerRadius * handScale)
            v4.handRecognition = .init(decision: decision, hingeAngle: frozen.angle, geometry: geometry)
            flight = .hand(geometry)
            print(String(format: "[v4] recognition #%d: the hand's path (%@) — out of the screen, over the top edge, round the hand card; outline %.2f × %.2f m on the hinge (%.0f, %.0f, %.1f) mm at %.0f° (hinge angle frozen at take-off%@)",
                         v4.recognitionRuns, decision.reason, geometry.cardWidth, geometry.cardHeight,
                         hingePosition.x * 1000, hingePosition.y * 1000, hingePosition.z * 1000,
                         frozen.angle * 180 / .pi, frozen.head == nil ? "; no head pose yet — the head taken 40 cm out along the screen's normal" : ""))
        } else {
            print("[v4] recognition #\(v4.recognitionRuns): the desk's path (\(decision.reason))")
        }
        recognition.resetPerf()
        recognition.run(flight)
        let beats = recognition.timeline.beats
        // The ribbon rises out of the screen and crosses the device in its first 0.3 s, and the screen burst is on the
        // LCD for 0.25 s: the brief effects H0 exempts by name. The rest of the flight is ≥ 8 cm off the device (on the
        // desk) / beyond the top edge (in the hand).
        pauseFootprintAudit(beats.outlineGone + 0.3, reason: "v4 recognition")
        choreography?.cancel()
        overlay.root.isEnabled = true
        print(String(format: "[v4] recognition start (ribbon %.1f mm → portrait outline %.2f × %.2f m; closure %.2f s, hand-over %.2f s)",
                     recognition.ribbon.style.profile.width * 1000 * (flight == .desk ? 1 : v4.handRecognition?.geometry.ribbonWidthScale ?? 1),
                     recognition.timeline.outline.width, recognition.timeline.outline.height,
                     beats.closure, beats.closure + beats.outlineHold))
        if let t = v4.freezeAt, v4.freezesThisRun {
            recognition.freeze(at: t)
            print(String(format: "[v4] recognition #%d will freeze at %.2f s (--v4-freeze%@)", v4.recognitionRuns, t,
                         v4.freezeRun.map { " --v4-freeze-run \($0)" } ?? ""))
        }
        print("[v4] recognition #\(v4.recognitionRuns) of the session")
        return true
    }

    /// `[perf]` over the whole first appearance — the ribbon's flight, the dissolve, the pop-up and the count — from the
    /// `.launch` beat (0.10 s) to the end of the entrance. Not from the run itself: a probe's first frame carries
    /// whatever the frame before it cost, and on a first detection 0.7 s after launch (the fake track) that frame is
    /// the immersive space still opening — a 240 ms "worst frame" no wall-clock gap inside the recognition shows.
    private func armRecognitionPerf() {
        let beats = V4.RecognitionTimeline.Beats.standard
        let entrance = beats.closure + Float(V4.HeroCardTimeline.revealInPlace().entranceDuration) - beats.launch
        // v4 B3 §2.4: with a `[perf] scene:` census at its end — a recognition plays at every summon now, and five in a row
        // have to leave the scene as they found it (entities, attachments, emitters), which this line shows run by run.
        startPerfProbe(Self.recognitionProbe, duration: entrance, reportsScene: true)
    }

    static let recognitionProbe = "v4 recognition + reveal"

    /// One of the recognition's beats (`RecognitionMagic.onBeat`).
    private func recognitionBeat(_ beat: RecognitionMagic.Beat, at t: Float) {
        switch beat {
        case .burst:
            // The LCD's own burst (BLE ≈ 60 ms, so it goes out on the first frame) and the "seen" chime.
            onRecognitionBurst?()
            audio.play(.acquire, on: anchorRoot)
            print(String(format: "[v4] beat burst at %.2f s", t))
        case .launch:
            audio.play(.scan, on: anchorRoot)
            armRecognitionPerf()
            print(String(format: "[v4] beat launch at %.2f s", t))
        case .outline:
            print(String(format: "[v4] beat outline at %.2f s", t))
        case .closure:
            if holdHandOverForMaterials(closureAt: t) { return }
            recognitionClosed(at: t)
        case .dissolved:
            print(String(format: "[v4] beat ribbon dissolved at %.2f s", t))
        case .handOver:
            let dissolve = v4.map { $0.rig.timeline.dissolveProgress(at: $0.clock) } ?? 0
            print(String(format: "[v4] beat hand-over at %.2f s (card dissolve %.0f %%)", t, dissolve * 100))
        case .done:
            if let recognition = v4?.recognition {
                print(String(format: "[v4] recognition done at %.2f s — rig CPU avg %.3f ms, p95 %.3f, max %.3f (outline+dissolve window avg %.3f, max %.3f), %d entities",
                             t, recognition.perf.average, recognition.perf.p95, recognition.perf.maximum,
                             recognition.perfPeak.average, recognition.perfPeak.maximum, recognition.entityCount))
                parkRecognitionRig(after: Self.recognitionParkDelay)
            }
        }
    }

    /// **v4 B2.** How long the rig stays in the tree after its last beat: the longest-lived gold mote (1.6 s + its
    /// variation) finishes falling first.
    static let recognitionParkDelay: Double = 2.0

    /// **v4 B2.** The recognition has nothing left to draw: its 24 entities — four gold-dust emitters `emitting` at
    /// 0/s among them (A2 keeps them "emitting" and switches the birth rate, see `GoldDust.component`) — leave the
    /// tree until the next recognition. Round 1 carried all four (`v4.dust.*`) in every `[perf] scene:` line of the
    /// session, hand, desk and worlds alike.
    func parkRecognitionRig(after seconds: Double) {
        guard let recognition = v4?.recognition else { return }
        Task { @MainActor [weak self, weak recognition] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard let self, let recognition, !recognition.isRunning, self.v4?.recognitionHolding != true else { return }
            guard recognition.root.isEnabled else { return }
            recognition.root.isEnabled = false
            print("[v4] recognition rig parked (\(recognition.entityCount) entities out of the tree until the next recognition)")
        }
    }

    /// **The closure is v3's convergence beat** (`boxScanConverged`): the chip, the device's answer, and the entrance
    /// the recognition was holding — the same `Pending`, the same hand-off to `AppModel`. After a hand-over hold the
    /// chip has already played (on the closure's glint) and the rest runs at the release.
    private func recognitionClosed(at t: Float, afterHold: Bool = false) {
        guard let v4 else { return }
        v4.recognitionHolding = false
        if !afterHold { audio.play(.chip0, on: anchorRoot) }
        onScanConverged?()
        let moment = afterHold ? "hand-over released"
                               : String(format: "beat closure at %.2f s (%.2f s after launch)", t, V4LaunchClock.sinceLaunch)
        // v4 B4 §1: the closure is the one moment the flight's place is read (the hand reveal, or the fallbacks).
        defer {
            v4.handRecognition = nil
            v4.closingRecognitionDecision = nil
        }
        guard scanPending.take() != nil, let held = heldIntro else {
            print("[v4] \(moment) (nothing held)")
            return
        }
        heldIntro = nil
        // v4 B4 §1: a carry released into the hand after the hand's flight is the hand reveal, not the unfold.
        let label = held.label == .unfold && v4.handRecognition != nil && usesHandForm && handForm == .hinge
            ? "hand reveal (in the outline on the hinge)" : held.label.rawValue
        print("[v4] \(moment) → \(label)")
        runTransition(held.transition, previous: held.previous, hideKind: nil,
                      firstAcquire: held.firstAcquire, resumeFromWorld: held.resumeFromWorld,
                      animated: held.animated)
        retuneRelocationForPresence()
        updateParticleRate()
        onScanEntranceStarted?()
    }

    /// A hide arrived while the ribbon was still flying (or its outline was holding the hand-over): it goes, with
    /// whatever it was holding.
    func cancelV4Recognition() {
        guard let v4 else { return }
        v4.recognitionHolding = false
        v4.handOverHold = nil
        v4.recognitionResume = nil
        v4.handRecognition = nil
        v4.closingRecognitionDecision = nil
        v4.recognition?.stop()
        print("[v4] recognition cancelled (hide)")
        parkRecognitionRig(after: Self.recognitionParkDelay)
    }

    // MARK: - The hand-over hold: the first reveal always gets A1's dissolve

    /// At the closure: is A1's style on the card? If not and it can still come, the hand-over waits for it
    /// (`V4.HandOverHold`) — the chip plays on the closure's glint, the ribbon breaks up as designed, the recognition's
    /// clock waits at the end of that with the outline breathing, and the entrance stays held (`Pending` unchanged).
    /// `stepHandOverHold` releases it. False = no hold: the closure runs now.
    private func holdHandOverForMaterials(closureAt t: Float) -> Bool {
        guard let v4, let recognition = v4.recognition else { return false }
        if v4.installMagicIfReady() { return false }
        guard v4.magicMayStillArrive else { return false }
        let hold = recognition.hold
        v4.handOverHold = .init(startedAt: CACurrentMediaTime(), closureTime: t)
        recognition.hold(at: hold.holdPoint(recognition.timeline.beats))
        // v4 B4 §1: the hand's outline lies on the hinge — its bottom edge inside the prism's 3 mm margin at the case's top
        // edge, where only the hinged card itself is tolerated. Without a hold it is gone (2.70 s) before the recognition's
        // pause ends (3.0 s); a hold keeps it breathing up to the cap and then runs its last 0.8 s, so the pause goes too.
        if v4.handRecognition != nil {
            let beats = recognition.timeline.beats
            pauseFootprintAudit(Float(hold.cap) + (beats.outlineGone - hold.holdPoint(beats)) + 0.3,
                                reason: "v4 recognition (hand), hand-over hold")
        }
        audio.play(.chip0, on: anchorRoot)
        // The recognition's `[perf]` window would end inside a long hold: widened by the cap now, trimmed at the release.
        extendPerfProbe(Self.recognitionProbe, by: Float(hold.cap))
        print(String(format: "[v4] beat closure at %.2f s (%.2f s after launch): A1 materials not ready (style %@, preload %@) — the outline holds the hand-over (cap %.1f s)",
                     t, V4LaunchClock.sinceLaunch, v4.styleName, V4MaterialPreload.isDone ? "done" : "loading", hold.cap))
        return true
    }

    /// Every frame (`stepV4`, before the card steps): release a hold the frame A1's style is in — or when it cannot
    /// come, or at the cap. While it holds, the desk counts as busy (the world engine's idle prebuild, a 200 ms stall,
    /// would otherwise land in the breathing outline or the reveal after it).
    private func stepHandOverHold(_ v4: V4CardIntegration) {
        guard let recognition = v4.recognition else { return }
        let hold = recognition.hold
        if let state = v4.handOverHold {
            onDeskBusy?()
            let held = CACurrentMediaTime() - state.startedAt
            let decision = hold.decide(styleReady: v4.installMagicIfReady(), mayStillArrive: v4.magicMayStillArrive,
                                       held: held)
            guard case .release(let reason) = decision else { return }
            v4.handOverHold = nil
            recognition.endHoldBreathing()
            v4.recognitionResume = .init(cardClock: hold.resumeCardClock(recognition.timeline.beats),
                                         releasedAt: CACurrentMediaTime())
            extendPerfProbe(Self.recognitionProbe, by: Float(held - hold.cap))
            print(String(format: "[v4] hand-over held %.0f ms for materials (%@; style %@)",
                         held * 1000, reason.rawValue, v4.styleName))
            recognitionClosed(at: state.closureTime, afterHold: true)
        }
    }

    /// Every frame (`stepV4`, after the card steps): once the card's entrance clock reaches the moment the two clocks
    /// agree (`V4.HandOverHold.resumeCardClock`), the recognition runs on from the hold point — caught up by the card's
    /// overshoot, so the outline hands over at the card's usual ≈ 80 % whatever the hold cost. With no reveal after the
    /// release it runs on after the grace.
    private func resumeRecognitionAfterHold(_ v4: V4CardIntegration) {
        guard let resume = v4.recognitionResume, let recognition = v4.recognition else { return }
        let revealing = v4.entranceKind == .reveal
        let due = revealing ? v4.clock >= resume.cardClock
                            : CACurrentMediaTime() - resume.releasedAt >= recognition.hold.resumeGrace
        guard due else { return }
        v4.recognitionResume = nil
        recognition.resumeFromHold(catchUp: revealing ? Float(v4.clock - resume.cardClock) : 0)
        if !revealing { print("[v4] recognition runs on (no reveal followed the hold)") }
    }

    // MARK: - The first reveal: dissolved into the outline

    /// The held cinematic, released at the closure: the card stands where the outline was drawn, dissolves in from
    /// it, pops up, and counts (`HeroCardTimeline.revealInPlace`). The desk comes up around it.
    func runV4Reveal(animated: Bool) {
        guard let v4 else { return }
        detachCardFromHinge()
        pixels.hide()
        overlay.hideAll(keepSocket: true)
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        hologram.isEnabled = true
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.remove(TweenComponent.self)
        cardGroup.transform = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: Self.cardTiltRadians, axis: [1, 0, 0]),
                                        translation: [0, HologramLayout.cardCenterHeight, 0])
        cardGroup.components.set(OpacityComponent(opacity: 1))
        resetCardLayers()
        igniteSurface(level: 1, animated: animated)
        guard animated else {
            v4.showAtRest()
            overlay.socket.components.set(OpacityComponent(opacity: 0.4))
            projector.setVisible(true, animated: false)
            startIdle()
            return
        }
        v4.beginEntrance(.reveal)
        print(String(format: "[v4] reveal: dissolve %.2f s from the outline (style %@), pop-up at %.2f s, count %d from %.2f s → lands %.2f s",
                     v4.rig.timeline.dissolveDuration, v4.styleName, v4.rig.timeline.layerStart,
                     v4.rig.faceModel.odometer.target, v4.rig.timeline.odometerStart, v4.countLanding))
        overlay.socket.components.set(TweenComponent(
            opacity: (from: overlay.socket.components[OpacityComponent.self]?.opacity ?? 0, to: 0.4),
            duration: 0.4, easing: .easeOutCubic))
        showWellDimmed(animated: true)
        setBloom(strength: look.bloomStrength, peak: 0.9, decay: 0.8)
        let landing = v4.countLanding
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            // The beam comes on as the card solidifies…
            guard await self.waitForCardClock(0.55) else { return }
            self.projector.setVisible(true, animated: true)
            // …and the count's landing is the settle.
            guard await self.waitForCardClock(landing) else { return }
            self.flareBeam()
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.1, endScale: 1.1, duration: 0.8, peak: 0.6)
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    // MARK: - The hand's reveal (v4 B4 §1): dissolved into the outline on the hinge

    /// The entrance half of `runV4HandReveal` (the card is already on the hinge at the frozen angle): the desk's in-place
    /// dissolve, the pop-up and the count, on the hand card. The well opens at the screen (the hand form's light); the
    /// count's landing is the settle's chime. The deck rises out of the card as the dissolve completes (AppModel's half of
    /// the same `.carry`, delayed by `nextDeckRiseDelay`).
    func beginV4HandRevealEntrance(_ plan: V4CardIntegration.HandRecognition) {
        guard let v4 else { return }
        v4.beginEntrance(.reveal)
        print(String(format: "[v4] hand reveal: the card dissolves in the outline on the hinge (%.2f s, style %@, scale %.2f, hinge angle %.0f° frozen since take-off), pop-up at %.2f s, count %d from %.2f s → lands %.2f s; the deck rises at %.2f s",
                     v4.rig.timeline.dissolveDuration, v4.styleName, handScale, plan.hingeAngle * 180 / .pi,
                     v4.rig.timeline.layerStart, v4.rig.faceModel.odometer.target, v4.rig.timeline.odometerStart,
                     v4.countLanding, v4.rig.timeline.dissolveDuration))
        // Hand-form idle: the well's edge light is the card's light source in the hand. No bright flash of it here: the
        // light of this moment is the outline the card is dissolving out of (bible §3: ≤ 3 things asking for the eye —
        // the dissolve, the count, the deck).
        showWellDimmed(animated: true)
        setBloom(strength: look.bloomStrength, peak: 0.7, decay: 0.6)
        let landing = v4.countLanding
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForHandCardClock(landing) else { return }
            self.audio.play(.settle, on: self.anchorRoot)
        }
    }

    /// `waitForCardClock` for the hand: that one stops when the presence is `.carrying` (v3's reveal rule, for the desk).
    func waitForHandCardClock(_ t: Double) async -> Bool {
        while let v4, v4.clock < t {
            try? await Task.sleep(for: .milliseconds(15))
            if Task.isCancelled || !isHandForm || !hologram.isEnabled { return false }
        }
        return !Task.isCancelled && isHandForm
    }

    /// The hand reveal is over for the hinge: the card has dissolved in and the ribbon's outline is gone (or the reveal
    /// was cut short).
    var handRevealIsOver: Bool {
        guard let v4 else { return true }
        let dissolved = v4.entranceKind != .reveal || v4.clock >= v4.rig.timeline.dissolveDuration
        return dissolved && !(v4.recognition?.isRunning ?? false)
    }

    /// The facing tick takes the hinge over from the angle the outline was drawn at (τ 0.12 s: it eases, never jumps).
    func releaseHandRevealHinge() {
        guard handRevealHingeFrozen else { return }
        handRevealHingeFrozen = false
        print(String(format: "[v4] hand reveal: the hinge follows the eyes again (from %.0f°)",
                     2 * acos(max(-1, min(1, hingeRotation.real))) * 180 / .pi))
    }

    // MARK: - Reentry: A4's rise off the screen

    /// A reentry (a summon on the desk, a put-down that brings the card back): v3's desk furniture, then A4's rise
    /// off the screen and the pop-up — without the count, the number is already known.
    func runV4Reentry(animated: Bool) {
        guard let v4 else { return }
        // A4 §8.6: the card starts lying flat on the screen for ≈ 0.1–0.3 s — the brief exemption H0 grants by name.
        pauseFootprintAudit(animated ? 1.6 : 0.2, reason: "reentry")
        detachCardFromHinge()
        surface.isEnabled = true
        hasShownCard = true
        carriedVisual = false
        setSearching(false)
        cardIsComingBack()
        overlay.hideAll()
        pixels.hide()
        well.hide()
        resetFollower()
        igniteSurface(level: 1, animated: animated)
        hologram.isEnabled = true
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.remove(TweenComponent.self)
        cardGroup.transform = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: Self.cardTiltRadians, axis: [1, 0, 0]),
                                        translation: [0, HologramLayout.cardCenterHeight, 0])
        cardGroup.components.set(OpacityComponent(opacity: 1))
        resetCardLayers()
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        flareSocketForSummon(animated: animated, settlingTo: 0.4)
        guard animated else {
            v4.showAtRest()
            projector.setVisible(true, animated: false)
            startIdle()
            return
        }
        v4.beginEntrance(.rise)
        print(String(format: "[v4] reentry: rise off the screen (%.2f s, style %@)", v4.entranceDuration, v4.styleName))
        audio.play(.liftOff, on: anchorRoot)
        let settled = v4.entranceDuration
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            guard await self.waitForCardClock(0.25) else { return }
            self.projector.setVisible(true, animated: true)
            self.showWellDimmed(animated: true)
            guard await self.waitForCardClock(0.9) else { return }
            self.flareBeam()
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.1, endScale: 1.1, duration: 0.8, peak: 0.7)
            self.audio.play(.settle, on: self.anchorRoot)
            guard await self.waitForCardClock(settled) else { return }
            self.startIdle()
        }
    }

    /// Suspends until the hero card's entrance clock reaches `t`. The desk's beats ride the card's own clock rather
    /// than the wall's, so a hitch (or `--v4-freeze`) holds them with the card instead of letting them run ahead of it.
    /// False when cancelled, or when the presence no longer lets a reveal continue (v3's rule).
    func waitForCardClock(_ t: Double) async -> Bool {
        while let v4, v4.clock < t {
            try? await Task.sleep(for: .milliseconds(15))
            if Task.isCancelled || !revealMayContinue { return false }
        }
        return !Task.isCancelled && revealMayContinue
    }

    // MARK: - Idle, frames, followers

    /// The card reached its steady state on the desk (`startIdle`): one `[perf]` window over it, the gallery out — only
    /// while it stays the desk scene the budget table means (桌面待机): a pick-up, a fold or a world inside the window
    /// cancels it, and the next time the card rests on the desk arms it again.
    func noteV4Idle() {
        guard let v4 else { return }
        guard !v4.deskIdleProbeArmed else { return }
        v4.deskIdleProbeArmed = true
        v4.deskIdleProbeTask?.cancel()
        v4.deskIdleProbeTask = Task { @MainActor [weak self] in
            // After the gallery has fanned out (0.6 s wait + 1.2 s fan) and after the world engine's desk prebuilds
            // (≈ 4 s of desk quiet, 130–160 ms each): the steady scene the budget table calls 桌面待机.
            try? await Task.sleep(for: .milliseconds(8000))
            guard let self, let v4 = self.v4, !Task.isCancelled, self.isOnTheDeskAtRest else {
                self?.v4?.deskIdleProbeArmed = false
                return
            }
            _ = v4.rig.takePerf()
            self.startPerfProbe(Self.deskIdleProbe, duration: 5, reportsScene: true)
            try? await Task.sleep(for: .milliseconds(5100))
            guard !Task.isCancelled else { return }
            let perf = v4.rig.takePerf()
            print(String(format: "[v4] desk idle: card CPU avg %.3f ms, max %.3f ms over %d frames (style %@, %d card entities)",
                         perf.averageMs, perf.maxMs, perf.frames, v4.styleName, v4.rig.entityCount))
        }
    }

    static let deskIdleProbe = "v4 desk idle 5 s"

    /// The card is on the desk, whole and at rest (not in a hand, not a mini card, not folded away).
    var isOnTheDeskAtRest: Bool {
        hologram.isEnabled && !isHandForm && !isMiniCard && currentPresence == .expanded
            && v4?.entranceKind == V4CardIntegration.EntranceKind.idle
    }

    /// The desk scene is over (a pick-up, a fold, a world): a desk-idle window in flight would measure the wrong scene.
    func leaveV4DeskIdle(reason: String) {
        guard let v4, v4.deskIdleProbeArmed else { return }
        v4.deskIdleProbeTask?.cancel()
        v4.deskIdleProbeTask = nil
        v4.deskIdleProbeArmed = false
        if cancelPerfProbe(Self.deskIdleProbe) { print("[v4] desk idle window dropped (\(reason)); re-armed at the next rest") }
    }

    /// One rendered frame of the hero card (called from `stepFollower`, before its preview guard).
    func stepV4(dt: Float) {
        guard let v4 else { return }
        // Frame hitches, measured on the wall clock (the engine tick's `dt` is clamped): what the frame was doing
        // when it stalled — the recognition's clock, the card's, the style — is the question a `[perf]` worst frame
        // cannot answer.
        let now = CACurrentMediaTime()
        if let last = v4.lastTickAt, now - last > v4.hitchThreshold {
            print(String(format: "[v4] frame hitch %.0f ms (recognition t %.2f, card %@ t %.2f, style %@, materials %@)",
                         (now - last) * 1000, v4.recognition?.time ?? -1, v4.entranceKind.rawValue, v4.clock,
                         v4.styleName, V4MaterialPreload.isDone ? "loaded" : "loading"))
        }
        v4.lastTickAt = now
        stepHandOverHold(v4)
        let visible = cardGroup.isEnabledInHierarchy
        if let blend = v4.step(dt: dt, viewer: headWorldPosition, visible: visible),
           var billboard = cardGroup.components[BillboardComponent.self] {
            billboard.blendFactor = blend
            cardGroup.components.set(billboard)
        }
        resumeRecognitionAfterHold(v4)
        if v4.entranceJustCompleted {
            v4.entranceJustCompleted = false
            updateParticleRate()          // the desk motes come back once the card is whole
        }
    }

    /// The live follower count (`AppModel.stats`, read by `ImmersiveView`'s update): rolled when the card is on screen.
    func setHeroFollowers(_ followers: Int) {
        guard let v4 else { return }
        v4.setFollowers(followers, visible: hasShownCard && cardGroup.isEnabledInHierarchy)
    }

    static var cardTiltRadians: Float { HologramLayout.cardTiltDegrees * .pi / 180 }

    // MARK: - Screenshots

    /// `--lab-night` on the product path (simulator stills): the lab's night-blue dome around the simulator's room, so
    /// the night-gold look is judged in the light the film is shot in (common rules: every still also at night). It is
    /// a lab flag; nothing on the headset passes it.
    func installNightDome() {
        let dome = ModelEntity(mesh: .generateSphere(radius: 6), materials: [UnlitMaterial(color: UIColor(hex: "#0B1230"))])
        dome.name = "debug.nightDome"
        dome.scale = [-1, 1, 1]
        dome.position = [0, 1.5, 0]
        root.addChild(dome)
        print("[v4] --lab-night: night dome around the room")
    }

    /// `--device-proxy` (simulator stills only): the smoked case in the case frame C and the lit LCD in the screen
    /// frame S, 11.5 mm apart as on the real passport — so a screenshot shows where the ribbon leaves, where the card
    /// stands and what the case effects hug. It is the hardware in a run that has none: exempt from the H0 audit.
    func installDeviceProxy() {
        let size = SIMD3<Float>(deviceFootprint.size.x, deviceThickness, deviceFootprint.size.y)
        // Unlit smoky black: a clear-coated PBR shell picks up the simulator room's bright IBL even inside the night
        // dome and reads as silver.
        var shell = UnlitMaterial(color: UIColor(hex: "#15171C"))
        shell.blending = .transparent(opacity: .init(floatLiteral: 0.94))
        let body = ModelEntity(mesh: .generateBox(width: size.x, height: size.y, depth: size.z, cornerRadius: 0.004),
                               materials: [shell])
        body.name = "proxy.case"
        body.position = [0, -size.y / 2, 0]
        body.components.set(FootprintProbeComponent(.exempt))
        caseRoot.addChild(body)
        var glass = UnlitMaterial(color: .black)
        if let image = UIImage(named: "PassportBase")?.cgImage,
           let texture = try? TextureResource(image: image, options: .init(semantic: .color)) {
            glass.color = .init(tint: .white, texture: .init(texture))
        }
        let panel = ModelEntity(mesh: .generatePlane(width: footprint.x, depth: footprint.y, cornerRadius: 0.003),
                                materials: [glass])
        panel.name = "proxy.lcd"
        panel.position = [0, 0.0003, 0]
        panel.components.set(FootprintProbeComponent(.exempt))
        anchorRoot.addChild(panel)
        print(String(format: "[v4] --device-proxy: case %.0f × %.0f × %.0f mm in C, LCD %.2f × %.2f mm in S (C at %+.2f, %+.2f mm)",
                     size.x * 1000, size.z * 1000, size.y * 1000, footprint.x * 1000, footprint.y * 1000,
                     caseCenter.x * 1000, caseCenter.z * 1000))
    }
}
