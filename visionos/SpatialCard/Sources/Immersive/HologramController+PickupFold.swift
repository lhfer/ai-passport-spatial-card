import Foundation
import RealityKit
import UIKit

/// **v4 B2 §3.3 — the pick-up fold's state** (an extension cannot hold stored properties; the controller holds one).
@MainActor
final class PickupFoldRig {
    /// The warm gold point the card folds into. **v4 B3**: beside the case's top edge, in the case frame C
    /// (`V4.PickupFold.pointPosition`; B2 had it 40 mm over the screen, under `hologram`), with its own bloom — and it is
    /// the collapsed card's point too (`HologramController+Collapse`).
    let point: ModelEntity
    /// The card is folded into the point (from the fold's first frame until an unfold or a hide takes it out).
    var folded = false
    /// When the thaw of a folded card arrived (nil = not thawed yet).
    var thawedAt: TimeInterval?
    /// The fold's two-step choreography, and the post-thaw wait for a carry.
    var task: Task<Void, Never>?
    var unfoldTask: Task<Void, Never>?
    /// The 10 Hz poll of the loss (`stepPickupFold`).
    var pollAt: Float = 0
    /// **v4 B4 §2.** This hold's pick-up evidence (`V4.PickupFold.PickupWatch`): the reach, then the hand leaving or rising
    /// with the passport — not a hand that is merely near it (B2's `GrabWatch`, which folded on every key press).
    var watch = V4.PickupFold.PickupWatch()
    /// The last put-down (`settling → expanded`) and the last key press, on the tracker's clock (the watch's guards).
    var settledAt: TimeInterval?
    var keyAt: TimeInterval?

    init() {
        // v4 B3: the glow is unlit and takes its alpha from the soft disc. B2's emissive PBR plane ignored the texture's
        // alpha (constant opacity 0.95), so in a dark room the point stood in a grey 32 mm square (B2's own night still
        // shows it); and its 2.4 emissive bloomed to white. Now: a warm-gold glow (`gold`) round a white-gold core
        // (`goldHot`, bible §1: the hottest part of the light), 10 mm across.
        point = ModelEntity(mesh: .generatePlane(width: V4.PickupFold.pointSize, height: V4.PickupFold.pointSize),
                            materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: UIColor(hex: "#FFD58A"), opacity: 0.9)])
        let core = ModelEntity(mesh: .generatePlane(width: V4.PickupFold.pointCore * 2.4, height: V4.PickupFold.pointCore * 2.4),
                               materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: UIColor(hex: "#FFF3D6"), opacity: 1)])
        core.name = "pickup.point.core"
        core.position = [0, 0, 0.0005]
        core.components.set(FootprintProbeComponent(.points([.zero])))
        point.addChild(core)
        point.name = "pickup.point"
        point.position = V4.PickupFold.pointPosition(caseLength: DeviceFootprint.aiPassport.size.y)
        point.components.set(BillboardComponent())
        point.components.set(OpacityComponent(opacity: 0))
        // H0: judged on its centre, 18 mm past the case's top edge — outside the prism by geometry. (The plane's soft rim
        // is a falloff to nothing; the bright core is the centre ± 5 mm, and that clears the prism too.)
        point.components.set(FootprintProbeComponent(.points([.zero])))
        point.isEnabled = false
    }
}

extension HologramController {
    /// The one poll (10 Hz, from the follower's tick): is this desk loss a pick-up? **v4 B4 §2**: only on evidence — the
    /// hand leaving or rising with the passport after it reached it, outside the put-down's and the key's guards
    /// (`V4.PickupFold.PickupWatch`); every step is a `[pickup]` line. Without evidence the card waits where it is, dimmed.
    func stepPickupFold(dt: Float) {
        guard pickupFoldEnabled, !pickup.folded else { return }
        pickup.pollAt += dt
        guard pickup.pollAt >= 0.1 else { return }
        pickup.pollAt = 0
        guard let state = lossStateProvider?() else { return }
        let lossHold: Bool
        if case .held(let reason) = currentPresence { lossHold = reason == .untracked || reason == .stale } else { lossHold = false }
        let onDesk = hologram.isEnabled && hasShownCard && !isHandForm && !isMiniCard && cardGroup.isEnabled
        let hand = state.handDistance.map { V4.PickupFold.PickupWatch.Hand(distance: $0, height: state.handHeight ?? 0) }
        for event in pickup.watch.step(active: lossHold && onDesk, hand: hand, radius: state.radius, at: state.now,
                                       settledAt: pickup.settledAt, keyAt: pickup.keyAt) {
            print(V4.PickupFold.PickupWatch.line(event))
        }
        guard pickup.watch.shouldFold(at: state.now) else { return }
        beginPickupFold(handDistance: state.handDistance, lossSeconds: pickup.watch.holdSeconds(at: state.now))
        pickup.watch = V4.PickupFold.PickupWatch()
    }

    /// **v4 B4 §2.** A key was pressed (any key): for 1.5 s a hand leaving the passport is the hand that pressed it.
    func notePickupKey() {
        guard let now = lossStateProvider?().now else { return }
        pickup.keyAt = now
    }

    /// **v4 B4 §2.** The card settled on the desk (`settling → expanded`): for 2 s a hand leaving it is letting go.
    func notePickupSettled() {
        guard let now = lossStateProvider?().now else { return }
        pickup.settledAt = now
    }

    /// **The fold** (t = 0 at the call): the gallery sinks and the desk's light goes (the rays back into the outline,
    /// the halo, the coins, the socket, the well); 0.00–0.08 the card gathers itself (+4 %); 0.08–0.58 it arcs down into
    /// the device's last position and becomes a warm gold point there, which pops in as it lands and then breathes.
    func beginPickupFold(handDistance: Float?, lossSeconds: TimeInterval) {
        guard !pickup.folded, hologram.isEnabled, !isMiniCard else { return }
        pickup.folded = true
        pickup.thawedAt = nil
        pickup.unfoldTask?.cancel()
        print(V4.PickupFold.foldLine(handDistance: handDistance, lossSeconds: lossSeconds))
        // A rise in flight is written against the desk pose; the fold starts from the card as it stands.
        v4?.settleForV3Choreography(reason: "pick-up fold")
        cancelChoreography()
        setSearching(false)
        // The app's half: the gallery (and an open preview) go down with the card, the desk ring rests on nothing.
        onPickupFold?(true)
        // The desk's light goes with it — it is where the card *was*.
        projector.retractRays()
        projector.setVisible(false, animated: true)
        well.close(duration: 0.3)
        setDeskFaded()
        pauseFootprintAudit(1.0, reason: "pick-up fold")
        cardGroup.components.remove(FloatComponent.self)
        let start = cardGroup.transform
        // v4 B3: the point is in the case frame now; the arc is written in `hologram` space.
        let point = goldPointInHologram
        let s = start.scale
        cardGroup.components.set(TweenComponent(scale: (from: s, to: s * V4.PickupFold.anticipationScale),
                                                duration: V4.PickupFold.anticipationDuration, easing: .easeOutCubic))
        audio.play(.collapse, on: anchorRoot)
        pickup.task?.cancel()
        pickup.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(V4.PickupFold.anticipationDuration * 1000)))
            guard let self, !Task.isCancelled, self.pickup.folded else { return }
            let from = self.cardGroup.transform
            let folded = s * V4.PickupFold.foldedScale
            self.cardGroup.components.set(TweenComponent(
                scale: (from: from.scale, to: folded),
                position: (from: from.translation, to: point),
                opacity: (from: self.cardGroup.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
                arcOffset: V4.PickupFold.arcOffset(from: from.translation, to: point),
                duration: V4.PickupFold.foldDuration, easing: .easeInOutCubic))
            try? await Task.sleep(for: .milliseconds(Int(V4.PickupFold.foldDuration * 1000) - 80))
            guard !Task.isCancelled, self.pickup.folded else { return }
            // The landing: the point pops in where the card arrives (a small flash, bible §3), then breathes.
            self.lightGoldPoint(pop: true)
            self.audio.play(.chip0, on: self.anchorRoot)
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, self.pickup.folded else { return }
            self.breatheGoldPoint()
            // The card *is* the point now: out of the tree until something brings it back.
            self.cardGroup.isEnabled = false
            print("[reveal] pick-up fold: waiting as a gold point (the card follows the device, not the hand)")
        }
    }

    /// The fold is over: `to` is where the card goes next (`"hand"` / `"desk"`), nil when it is simply leaving (a hide,
    /// a world). The point fades; the card is back in the tree at its folded scale, for whatever grows it. `keepPoint`
    /// (v4 B3): a collapse is taking the point over — it stays lit.
    func endPickupFold(to destination: String?, keepPoint: Bool = false) {
        guard pickup.folded else { return }
        pickup.folded = false
        pickup.thawedAt = nil
        pickup.task?.cancel()
        pickup.task = nil
        pickup.unfoldTask?.cancel()
        pickup.unfoldTask = nil
        cardGroup.isEnabled = true
        let dot = pickup.point
        if dot.isEnabled, !keepPoint {
            dot.components.remove(PulseComponent.self)
            dot.components.set(TweenComponent(scale: (from: dot.scale, to: [0.6, 0.6, 0.6]),
                                              opacity: (from: dot.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
                                              duration: 0.25, easing: .easeInCubic, disableWhenDone: true))
        }
        onPickupFold?(false)
        if let destination { print("[reveal] pick-up unfold → \(destination) (from the point)") }
    }

    /// The thaw of a folded card: the passport is seen again. A `.carry` on the next observation means a hand — the
    /// hand form grows the card out of the point (`runCarry` ends the fold). Without one inside the grace the card rises
    /// on the desk.
    func notePickupFoldThaw() {
        guard pickup.folded else { return }
        pickup.thawedAt = ProcessInfo.processInfo.systemUptime
        pickup.unfoldTask?.cancel()
        pickup.unfoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(V4.PickupFold.carryGrace * 1000)))
            guard let self, !Task.isCancelled, self.pickup.folded else { return }
            let presence = self.currentPresence
            let lost: Bool
            if case .held = presence { lost = true } else { lost = false }
            let decision = V4.PickupFold.unfold(carrying: presence.isCarrying,
                                                resting: presence == .expanded || presence == .settling,
                                                lost: lost, sinceThaw: V4.PickupFold.carryGrace)
            guard decision == .desk else { return }
            self.endPickupFold(to: "desk")
            if self.v4 != nil {
                self.runV4Reentry(animated: true)
            } else {
                self.runDeskReentryAfterFold()
            }
        }
    }
}
