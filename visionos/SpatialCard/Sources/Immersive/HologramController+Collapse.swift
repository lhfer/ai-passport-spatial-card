import Foundation
import RealityKit
import UIKit

/// **v4 B3 §2 — the collapse's state** (an extension cannot hold stored properties; the controller holds one).
@MainActor
final class CollapseRig {
    /// The card is collapsed into the gold point (the v4 dismiss / replay hide), from the hide until a summon's
    /// recognition starts, a teardown, or anything else brings the card back.
    var collapsed = false
    /// The collapse's staged beats (tuck → gather → arc → the point pops in → it breathes).
    var task: Task<Void, Never>?
    /// 「OK · 唤醒」 beside the keys (`AppModel.collapseCard` decides when). In the case frame C, not under `surface`:
    /// the collapse takes the desk out of the tree (§3.3).
    let wakeHintHolder = Entity()
    /// 「按 OK 回到桌面」 under the in-world mini card (v4 only — v3's card face has its own 「返回桌面」 capsule). A child
    /// of `cardGroup`, not of `cardFaceGroup`, so the back-face flip leaves it alone.
    let miniHintHolder = Entity()
}

/// **v4 B3 §2 — collapse and summon as a pair.**
///
/// The collapse (long OK, face down for 0.8 s, `cmd hide`; and a `cmd replay`'s hide) reuses B2's pick-up fold picture:
/// the card gathers itself (+4 %, 80 ms), arcs into the device (0.5 s) and becomes the warm gold point, which pops in as it
/// lands and then breathes — beside the case's top edge (`V4.PickupFold.pointPosition`), in the case frame, so it follows
/// the **device** and never the hand, and leaves the real screen in view from the desk and from the hand. The desk's light
/// goes with the card (projector, well, halo, coins, socket — the whole `surface` leaves the tree, which is §3.3's fix).
/// The point is the **only** resting picture: no socket light, no sleeping dust. `hologram` is switched off at the end —
/// `runCarry` and `BoxScanRig.arrival(cardOnScreen:)` read it as "the card is on screen", which is what sends a summon in
/// the hand down the unfold. The summon (OK) is the whole recognition again (`AppModel.requestShowCard`): the point fades
/// as the ribbon leaves the screen.
///
/// `--v3-card` keeps v3's pair exactly: `foldIntoDevice`, the socket light, the sleeping dust, and the short scan back.
extension HologramController {
    static let wakeHintAttachmentID = "collapse.wakeHint"
    static let miniHintAttachmentID = "mini.hint"

    /// The collapse takes the gold point (v4); `--v3-card` folds v3's way.
    func collapsesIntoPoint(_ kind: PresenceGate.HideKind?) -> Bool {
        isV4Card && (kind == .dismiss || kind == .replay)
    }

    /// A recognition (the ribbon, or v3's short scan) is holding the card's entrance: the keys wait for its closure.
    var isArriving: Bool {
        v4?.recognitionHolding == true || isHoldingEntrance || boxScan.isRunning
    }

    /// Where the gold point stands in `hologram` space (S): the pick-up fold's arc ends there.
    var goldPointInHologram: SIMD3<Float> {
        hologram.convert(position: pickup.point.position, from: caseRoot)
    }

    /// Re-place the point (and the wake hint) for the device's measured length / key side.
    func layoutGoldPoint() {
        pickup.point.position = V4.PickupFold.pointPosition(caseLength: deviceFootprint.size.y)
        collapse.wakeHintHolder.position = V4.Collapse.hintPosition(edgeSign: buttonEdge.sign)
    }

    // MARK: - The collapse

    /// The dismiss / replay hide, v4: into the gold point. `previous` tells a card that is already a point (a long OK
    /// during a pick-up fold — the point stays lit and nothing flies).
    func collapseIntoPoint(kind: PresenceGate.HideKind, alreadyPoint: Bool, animated: Bool) {
        collapse.task?.cancel()
        collapse.collapsed = true
        let why = kind == .replay ? "replay" : "dismiss"
        // H0: the card's arc down onto the device is the brief effect the rule exempts by name (the fold's own 1.2 s).
        pauseFootprintAudit(animated ? 1.2 : 0.2, reason: "collapse")
        v4?.settleForV3Choreography(reason: "collapse")
        releaseCardForCollapse()
        setSearching(false)
        stopSleepFX()
        overlay.hideAll()
        // The desk's light goes with the card — it is where the card *was*. `setDeskFaded` takes the whole surface (halo,
        // coins, chips, ripples) out of the tree once it is dark: §3.3, the halo the pulse used to relight inside the
        // case's outline while the passport was lifted.
        projector.retractRays()
        projector.setVisible(false, animated: animated)
        if animated { well.close(duration: 0.3) } else { well.hide() }
        setDeskFaded(animated: animated)
        guard !alreadyPoint else {
            // A pick-up fold had already made the card the point: it stays as it is (the hide only makes it deliberate).
            hologram.isEnabled = false
            breatheGoldPoint()
            print("[reveal] collapse (\(why)): the card was already the gold point (pick-up fold)")
            return
        }
        guard animated else {
            hologram.isEnabled = false
            lightGoldPoint(pop: false)
            breatheGoldPoint()
            return
        }
        print("[reveal] collapse into the gold point (\(why)): beside the top edge, \(goldPointLabel)")
        audio.play(.collapse, on: anchorRoot)
        // V3-2a2 S4's rule, kept: in the hand the deck goes into the card before the card goes into the device.
        let tuck: Float = notes.deckOut ? 0.2 : 0
        if tuck > 0 { tuckDeck(duration: tuck) }
        let start = cardGroup.transform
        let point = goldPointInHologram
        collapse.task = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func step(_ seconds: Float) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                return !Task.isCancelled && self.collapse.collapsed && self.currentPresence == .absent
            }
            if tuck > 0 { guard await step(tuck) else { return } }
            // 0.00–0.08: the card gathers itself (+4 %), bible §3's anticipation.
            let s = self.cardGroup.scale
            self.cardGroup.components.set(TweenComponent(scale: (from: s, to: s * V4.PickupFold.anticipationScale),
                                                         duration: V4.PickupFold.anticipationDuration, easing: .easeOutCubic))
            guard await step(V4.PickupFold.anticipationDuration) else { return }
            // 0.08–0.58: one arc down into the point, shrinking and fading as it goes (it *becomes* the point).
            let from = self.cardGroup.transform
            self.cardGroup.components.set(TweenComponent(
                scale: (from: from.scale, to: start.scale * V4.PickupFold.foldedScale),
                position: (from: from.translation, to: point),
                opacity: (from: self.cardGroup.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
                arcOffset: V4.PickupFold.arcOffset(from: from.translation, to: point),
                duration: V4.PickupFold.foldDuration, easing: .easeInOutCubic))
            guard await step(V4.PickupFold.foldDuration - 0.08) else { return }
            // The landing: the point pops in where the card arrives (a small flash on landing), then breathes.
            self.lightGoldPoint(pop: true)
            self.audio.play(.chip0, on: self.anchorRoot)
            guard await step(0.32) else { return }
            self.breatheGoldPoint()
            // The card *is* the point now: the whole hologram leaves the tree until a summon rebuilds it.
            self.hologram.isEnabled = false
            self.collapse.task = nil
            print("[reveal] collapsed: the gold point breathes beside the top edge (OK summons the card)")
        }
    }

    /// `[reveal] collapse …`'s numbers: where the point is on the case.
    private var goldPointLabel: String {
        let p = pickup.point.position * 1000
        return String(format: "C (%.0f, %+.0f, %.0f) mm", p.x, p.y, p.z)
    }

    /// The point pops in (×1.7 → 1, 0.24 s) or simply comes on.
    func lightGoldPoint(pop: Bool) {
        let dot = pickup.point
        dot.isEnabled = true
        dot.components.remove(PulseComponent.self)
        if pop {
            dot.components.set(TweenComponent(scale: (from: [1.7, 1.7, 1.7], to: [1, 1, 1]), opacity: (from: 0, to: 1),
                                              duration: 0.24, easing: .easeOutCubic))
        } else {
            dot.components.remove(TweenComponent.self)
            dot.scale = [1, 1, 1]
            dot.components.set(OpacityComponent(opacity: V4.Collapse.breathOpacity.base))
        }
    }

    /// …and breathes at the searching rate while it waits.
    func breatheGoldPoint() {
        let dot = pickup.point
        guard dot.isEnabled else { return }
        dot.components.remove(TweenComponent.self)
        dot.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.12,
                                          baseOpacity: V4.Collapse.breathOpacity.base,
                                          opacityAmplitude: V4.Collapse.breathOpacity.amplitude,
                                          period: V4.Collapse.breathPeriod))
    }

    /// The collapse is over (a summon's ribbon is leaving the screen, a teardown, anything that brings the card back):
    /// the point fades and leaves the tree. Idempotent; the pick-up fold's own point is `endPickupFold`'s.
    func releaseGoldPoint(reason: String, animated: Bool = true) {
        guard collapse.collapsed else { return }
        collapse.collapsed = false
        if let task = collapse.task {
            // A summon inside the collapse's own 0.82 s (long OK, then OK at once): the card is already on its way into
            // the device — it finishes there, out of the tree, so the summon in a hand still reads "nothing on screen"
            // (`runCarry` → the unfold) instead of springing the half-folded card onto the hinge under the ribbon.
            task.cancel()
            if currentPresence == .absent || currentPresence == .acquiring { hologram.isEnabled = false }
        }
        collapse.task = nil
        let dot = pickup.point
        guard dot.isEnabled, !pickup.folded else { return }
        dot.components.remove(PulseComponent.self)
        dot.components.set(TweenComponent(scale: (from: dot.scale, to: [0.6, 0.6, 0.6]),
                                          opacity: (from: dot.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
                                          duration: animated ? V4.Collapse.pointFadeOnSummon : 0, easing: .easeInCubic,
                                          disableWhenDone: true))
        print("[reveal] gold point out (\(reason))")
    }

    /// Every update while the card is dismissed (`ImmersiveView`, through `armDismissedSocket`): a dismiss that had nothing
    /// on screen to fold (`cmd hide` before the first reveal, `--auto-show never`) still leaves the point on the device —
    /// the visible way back. Idempotent.
    func armCollapsedPoint() {
        if !collapse.collapsed {
            collapse.collapsed = true
            lightGoldPoint(pop: true)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(320))
                guard let self, self.collapse.collapsed else { return }
                self.breatheGoldPoint()
            }
            print("[reveal] collapsed with nothing on screen: the gold point waits beside the top edge (OK summons)")
        }
        if surface.isEnabled { setDeskFaded(animated: false) }
    }

    // MARK: - 「OK · 唤醒」 and 「按 OK 回到桌面」

    func attachWakeHint(_ entity: Entity) {
        let holder = collapse.wakeHintHolder
        holder.name = "collapse.wakeHint"
        if holder.parent == nil {
            holder.components.set(BillboardComponent())
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
            caseRoot.addChild(holder)
            layoutGoldPoint()
        }
        holder.children.forEach { $0.removeFromParent() }
        entity.transform = .identity
        holder.addChild(entity)
    }

    /// Fade 「OK · 唤醒」 in (0.35 s) or out (0.25 s, then out of the tree) — B2's first-gallery hint's motion.
    func setWakeHint(visible: Bool) {
        let holder = collapse.wakeHintHolder
        guard holder.parent != nil else { return }
        let from = holder.isEnabled ? (holder.components[OpacityComponent.self]?.opacity ?? 0) : 0
        if visible {
            layoutGoldPoint()
            holder.isEnabled = true
            holder.components.set(TweenComponent(scale: (from: [0.9, 0.9, 0.9], to: [1, 1, 1]), opacity: (from: from, to: 1),
                                                 duration: 0.35, easing: .easeOutCubic))
        } else if holder.isEnabled {
            holder.components.set(TweenComponent(opacity: (from: from, to: 0), duration: 0.25, easing: .easeInCubic,
                                                 disableWhenDone: true))
        }
    }

    /// The mini card's hint, under its bottom edge in the card's own frame (the card is scaled 0.35 in a world, so the
    /// view's type is drawn at ≈ 1/0.35 — `MiniCardHintView`).
    func attachMiniHint(_ entity: Entity) {
        guard isV4Card else { return }
        let holder = collapse.miniHintHolder
        holder.name = "mini.hint"
        if holder.parent == nil {
            holder.position = [0, -(cardSize.y / 2 + Self.miniHintGap), 0.004]
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
            cardGroup.addChild(holder)
        }
        holder.children.forEach { $0.removeFromParent() }
        entity.transform = .identity
        holder.addChild(entity)
    }

    /// The hint's centre sits this far below the card's bottom edge (card space: ×0.35 in the world ≈ 1.2 cm).
    static let miniHintGap: Float = 0.035

    /// In with the mini layout (0.35 s after the shrink starts), out with it.
    func setMiniHint(visible: Bool) {
        let holder = collapse.miniHintHolder
        guard holder.parent != nil else { return }
        let from = holder.isEnabled ? (holder.components[OpacityComponent.self]?.opacity ?? 0) : 0
        if visible {
            holder.isEnabled = true
            holder.components.set(TweenComponent(opacity: (from: from, to: 1), delay: 0.35, duration: 0.3, easing: .easeOutCubic))
            print("[reveal] mini card hint 「按 OK 回到桌面」")
        } else if holder.isEnabled {
            holder.components.set(TweenComponent(opacity: (from: from, to: 0), duration: 0.15, easing: .easeInCubic,
                                                 disableWhenDone: true))
        }
    }
}
