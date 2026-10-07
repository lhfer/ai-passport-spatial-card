import Foundation
import RealityKit
import UIKit

/// SwiftUI side of a celebration (the stats row lives in the glass card attachment, owned by AppModel).
struct CelebrationHooks {
    /// Write the new follower count (the number rolls with `numericText`).
    var writeStats: () -> Void = {}
    /// Show the "+N" badge.
    var showBadge: () -> Void = {}
    /// Ease the badge out.
    var hideBadge: () -> Void = {}
}

extension HologramController {
    /// New followers (plan §9), t = 0 at the call:
    /// 0.00 `celebrate` cue + avatar spark burst (48 particles, 0.7 s)
    /// 0.06 rim 1.03 → 1 spring + bloom peak 0.95
    /// 0.10 projector flare + desk ripple + 80-particle burst
    /// 0.12 stats write → the number rolls
    /// 0.20 badge in
    /// 0.35 / 0.48 / 0.61 three staggered dings, 12 sparks each (v1 spent these on the orbiting chips; the
    ///      chips are gone but the rhythm is what makes a celebration read as an event, so the rim answers instead)
    /// 2.60 badge out
    /// Only while the card is on the desk; inside a world `WorldEngine.celebrate(delta:)` takes over.
    func playCelebration(delta: Int, hooks: CelebrationHooks) {
        guard hologram.isEnabled, currentPresence.showsHologram else {
            // Nothing to animate on: still update the numbers so the card is right when it appears.
            hooks.writeStats()
            return
        }
        // **V3-2b B5 / plan §4 E13.** The same event, told from the hand: the ripple comes out of the device
        // the wearer is holding, and the hand of cards answers it instead of the gallery.
        let inHand = isHandForm
        print("[celebrate] +\(delta) \(inHand ? "in the hand" : "on the desk")")
        audio.play(.celebrate, on: anchorRoot)
        // The note fan answers the same event in a wave (工作包 D), if it happens to be out.
        if inHand { rippleDeck() } else { rippleNoteFan() }
        if var sparks = avatarSparks.components[ParticleEmitterComponent.self] {
            sparks.burstCount = 48
            sparks.burst()
            avatarSparks.components.set(sparks)
        }
        hologram.components.set(PerfProbeComponent(label: "celebration", duration: 2.8))
        Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func at(_ seconds: Double, _ work: @MainActor () -> Void) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                guard !Task.isCancelled, self.currentPresence.showsHologram else { return false }
                work()
                return true
            }
            guard await at(0.06, {
                self.rim.components.set(TweenComponent(scale: (from: [1.03, 1.03, 1.03], to: [1, 1, 1]), duration: 0.45, easing: .spring(response: 0.35, damping: 0.7)))
                self.setBloom(strength: self.look.bloomStrength, peak: 0.95, decay: 0.8)
            }) else { return }
            guard await at(0.04, {
                self.flareBeam()
                if inHand {
                    // E13: a ring around the **device**, 0.13 → 0.5 m, outside the footprint by construction.
                    self.spawnDeviceRing(tint: self.look.secondaryTint, startDiameter: 0.13, endDiameter: 0.5,
                                         duration: 0.9, peak: 0.7)
                } else {
                    self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.2, endScale: 1.3, duration: 0.9, peak: 0.7)
                }
                self.burst(count: 80)
            }) else { return }
            guard await at(0.02, { hooks.writeStats() }) else { hooks.writeStats(); return }
            guard await at(0.08, { hooks.showBadge() }) else { return }
            for index in 0..<3 {
                guard await at(index == 0 ? 0.15 : 0.13, {
                    self.burst(count: 12)
                    self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index], on: self.anchorRoot)
                    self.pulseRim(scale: 1.02 - 0.004 * Float(index))
                }) else { hooks.hideBadge(); return }
            }
            try? await Task.sleep(for: .milliseconds(1990))
            hooks.hideBadge()
        }
    }
}
