import Foundation
import RealityKit

/// **v4 B4 §3.5 — `cmd perf`'s state on the controller** (an extension cannot hold stored properties).
@MainActor
final class PerfSwitchRig {
    /// What the director last set (`V4.PerfSwitches`).
    var switches = V4.PerfSwitches()
    /// The entities a layer's `off` took out of the tree, to give back when the layer is on again.
    var disabled: [V4.PerfLayer: [Entity]] = [:]
    /// Some entity layer is held `off` (the per-frame hold has work to do).
    var holdsAnyLayer = false
    /// **v4 B5 §1.** The window that waits for the switch to settle before it opens (cancelled by the next command).
    var settleTask: Task<Void, Never>?
    /// **v4 B5 §1.** How often the app turned an `off` layer's entity back on since the last `[perf]` window reported
    /// (a pick-up, a put-down, a fan-out re-enabling it) and the per-frame hold took it out again — the evidence that a
    /// layer stays off across the desk and the hand until `reset`.
    var reHeld: [V4.PerfLayer: Int] = [:]
    /// **v4 B5 §1.** A rehearsal's label for the next desk fan-out window (`desk fan out (rehearse #n · …)`), with the
    /// scene printed when it reports.
    var fanOutProbeLabel: String?
    /// **v4 B5 §2** `--note-fade quick` / `--hold-dim off`: the launch's choices for two look switches (the layers turn
    /// them off at run time; `on` hands back to these).
    var launchQuickFade = false
    var launchHoldDim = true
    /// **v4 B5 §3** `--resident-motes lite`: the launch's choice for the resident motes (`motes=off` is the same, live).
    var launchLiteMotes = false
    /// **v4 B5 §2** `bloom=off`: the `BloomComponent`s taken off, to put back.
    var bloomTaken: [(entity: Entity, bloom: BloomComponent)] = []
}

/// **v4 B4 §3.5 — the desk's layers, switched live** (`cmd perf`, `V4.PerfSwitches`). A layer that is `off` is held out of
/// the scene tree every frame (whatever the choreography does to it); `on` gives it back and lets the app draw it as it
/// would. Each command opens a fresh 5 s `[perf]` window and prints the scene as it stands.
extension HologramController {
    /// The entities a layer names on this controller (`worlds` and `gallery-glass` are not entities here: the world engine
    /// and the note cards' SwiftUI view answer those).
    func perfEntities(_ layer: V4.PerfLayer) -> [Entity] {
        switch layer {
        case .cones, .rays, .rigDust: return projector.perfEntities(layer)
        case .well: return [well.root]
        case .gallery: return [notes.group]
        case .trails: return Array(notes.trails.values) + Array(notes.worldTrails.values)
        case .twinkle: return [notes.twinkle]
        case .cardParticles: return [particleEntity]
        case .desk: return [surface]
        case .worlds, .galleryGlass, .noteFade, .flourish, .bloom, .holdDim, .motes: return []
        }
    }

    // MARK: - v4 B5 §2: the look switches the choreography reads

    /// The gallery cards fade in a fifth of their flight (`note-fade=off`, `--note-fade quick`) instead of all of it.
    var quickNoteFade: Bool { perf.launchQuickFade || !perf.switches.isOn(.noteFade) }
    /// The gallery's landing beats (bursts, rim pulse, bloom peak, ripple) play.
    var playsGalleryFlourish: Bool { perf.switches.isOn(.flourish) }
    /// The lost-passport cue dims the card and the gallery.
    var holdDims: Bool { perf.launchHoldDim && perf.switches.isOn(.holdDim) }
    /// **v4 B5 §3.** The resident emitters' share of their birth rates: 1, or two-thirds (`motes=off`, `--resident-motes lite`).
    var residentMotesScale: Float { perf.launchLiteMotes || !perf.switches.isOn(.motes) ? 2.0 / 3.0 : 1 }

    /// The resident motes take `residentMotesScale` (the twinkle when it is out, the card's motes by their own rule, the
    /// beam's dust by the projector's).
    func applyResidentMotes() {
        if notes.twinkle.parent != nil, var emitter = notes.twinkle.components[ParticleEmitterComponent.self] {
            emitter.mainEmitter.birthRate = HologramController.noteTwinkleBirthRate * residentMotesScale
            notes.twinkle.components.set(emitter)
        }
        updateParticleRate()
        projector.setDustScale(residentMotesScale)
    }

    /// Where a gallery card's opacity moves inside its flight: nil = all the way (the default); with the quick fade, the
    /// first fifth of a flight that fades in, the last fifth of one that fades out.
    func noteFadeWindow(from: Float, to: Float) -> SIMD2<Float>? {
        guard quickNoteFade, abs(to - from) > 0.001 else { return nil }
        return to > from ? SIMD2<Float>(0, 0.2) : SIMD2<Float>(0.8, 1)
    }

    /// `bloom=off`: every `BloomComponent` under the controller's root comes off (and is remembered); `on` puts them back.
    private func setBloomPass(_ on: Bool) {
        if on {
            for taken in perf.bloomTaken { taken.entity.components.set(taken.bloom) }
            print("\(PerfLog.prefix) bloom back on \(perf.bloomTaken.count) subtrees")
            perf.bloomTaken.removeAll()
            return
        }
        // The controller's tree and the world engine's (the prebuilt worlds included, in the tree or not): `bloom=off`
        // inside the nebula prices its star bloom too.
        var stack: [Entity] = PerfLog.sceneRoots?() ?? [root]
        while let entity = stack.popLast() {
            if let bloom = entity.components[BloomComponent.self] {
                perf.bloomTaken.append((entity, bloom))
                entity.components.remove(BloomComponent.self)
            }
            stack.append(contentsOf: entity.children)
        }
        print("\(PerfLog.prefix) bloom off: \(perf.bloomTaken.count) BloomComponents taken off")
    }

    /// The director's new state: layers going `off` leave the tree now (and stay out), layers coming back `on` are
    /// returned; the card's material follows `material=`.
    func applyPerfSwitches(_ switches: V4.PerfSwitches) {
        let before = perf.switches
        perf.switches = switches
        perf.holdsAnyLayer = V4.PerfLayer.allCases.contains { $0.defaultOn && !switches.isOn($0) }
        for layer in V4.PerfLayer.allCases where before.isOn(layer) != switches.isOn(layer) && switches.isOn(layer) {
            restorePerfLayer(layer)
            perf.reHeld[layer] = nil
        }
        enforcePerfSwitches()
        if switches.isOn(.bloom) != before.isOn(.bloom) { setBloomPass(switches.isOn(.bloom)) }
        if switches.isOn(.holdDim) != before.isOn(.holdDim) { refreshHoldingDim() }
        if switches.isOn(.motes) != before.isOn(.motes) { applyResidentMotes() }
        if switches.material != before.material, let v4 {
            Task { @MainActor [weak v4] in await v4?.setPerfMaterial(switches.material) }
        }
    }

    /// Every frame (`stepFollower`): whatever the choreography switched back on in a layer that is `off` goes out again.
    func enforcePerfSwitches() {
        for layer in V4.PerfLayer.allCases where layer.defaultOn && !perf.switches.isOn(layer) {
            for entity in perfEntities(layer) where entity.isEnabled {
                entity.isEnabled = false
                if (perf.disabled[layer] ?? []).contains(where: { $0 === entity }) {
                    // v4 B5 §1: the app turned it back on (a pick-up, a put-down, a fan-out); held out again this frame.
                    perf.reHeld[layer, default: 0] += 1
                } else {
                    perf.disabled[layer, default: []].append(entity)
                }
            }
        }
    }

    /// A layer is `on` again: what the switch took out comes back where the app still wants it.
    private func restorePerfLayer(_ layer: V4.PerfLayer) {
        let taken = perf.disabled.removeValue(forKey: layer) ?? []
        switch layer {
        case .gallery:
            notes.group.isEnabled = notes.isOut || notes.deckOut
        case .twinkle:
            if notes.isOut, !notes.deckOut { setNoteTwinkle(true) }
        case .desk:
            if !deskIsFaded { surface.isEnabled = true }
        case .trails:
            // They come back with their cards' next flight (the desk's rest rule, the deck's hand rule).
            break
        case .cones, .rigDust, .rays:
            // The rig's own rule decides: back only while it is showing, and the cones / dust not in the hand form.
            guard projector.root.isEnabled else { break }
            if layer != .rays, isHandForm { break }
            for entity in taken { entity.isEnabled = true }
        default:
            for entity in taken { entity.isEnabled = true }
        }
    }

    /// One fresh 5 s `[perf]` window after a switch, and the scene as it stands right now. A window still running from
    /// the previous command is cut short (it would straddle the switch) and says so; all of them share one carrier.
    ///
    /// **v4 B5 §1.** The window opens `settle` seconds after the switch, not on its frame: round 3's ladder measured the
    /// switch's own redraw inside its windows. The label says how long it waited.
    func startPerfSwitchWindow(label: String, settle: Double) {
        if let scene = PerfLog.census() { print("\(PerfLog.prefix) scene (cmd perf, now): \(scene)") }
        if let detail = PerfLog.censusDetail() { print("\(PerfLog.prefix) scene detail (cmd perf, now): \(detail)") }
        cancelPerfSwitchWindow(reason: "this command")
        let windowLabel = String(format: "cmd perf %@ (settled %.1f s)", label, settle)
        guard settle > 0 else {
            startPerfProbe(windowLabel, duration: 5, reportsScene: true, carrier: Self.perfSwitchCarrier)
            return
        }
        print(String(format: "\(PerfLog.prefix) cmd perf %@: the 5 s window opens in %.1f s (the switch's own redraw stays out of it)",
                     label, settle))
        perf.settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(settle * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.perf.settleTask = nil
            self.startPerfProbe(windowLabel, duration: 5, reportsScene: true, carrier: Self.perfSwitchCarrier)
        }
    }

    /// A state window that is settling or running is dropped (a newer command, a rehearsal): it would straddle the change.
    func cancelPerfSwitchWindow(reason: String) {
        if let pending = perf.settleTask {
            pending.cancel()
            perf.settleTask = nil
            print("\(PerfLog.prefix) cmd perf: the previous window was dropped before it opened (\(reason) came during its settle)")
        }
        if cancelPerfProbe(Self.perfSwitchCarrier) {
            print("\(PerfLog.prefix) cmd perf: the previous window was cut short by \(reason) (it would straddle the switch)")
        }
    }

    /// **v4 B5 §1.** Printed after every `[perf]` window while the director has anything switched: the state it was
    /// measured in (a pick-up morph in round 4 is only comparable to another one in the same state), and which layers the
    /// app tried to bring back during it (held out again the same frame). Nil with everything at its defaults.
    func perfWindowNote() -> String? {
        let summary = perf.switches.summary
        guard summary != "defaults" || !perf.reHeld.isEmpty else { return nil }
        let held = perf.reHeld.keys.sorted().map { "\($0.rawValue) ×\(perf.reHeld[$0] ?? 0)" }
        perf.reHeld.removeAll()
        return "  ↳ cmd perf state: \(summary)"
            + (held.isEmpty ? "" : "; the app turned back on and the hold took out again: \(held.joined(separator: ", "))")
    }

    /// **v4 B5 §1.** What a `cmd perf rehearse=fanout` needs to know about the card: is it showing on the desk (not
    /// collapsed into the gold point, not folded by a pick-up loss, not the mini card), is the passport in the hand, and is
    /// an entrance still playing on it.
    var rehearsalCardState: (shown: Bool, inHand: Bool, busy: Bool) {
        let shown = hologram.isEnabled && hasShownCard && !collapse.collapsed && !pickup.folded && !isMiniCard
            && currentPresence.showsHologram
        let inHand = isHandForm || notes.deckOut || carriedVisual
        let busy = (v4.map { $0.entranceKind != .idle || $0.recognitionHolding } ?? false) || isHoldingEntrance
        return (shown, inHand, busy)
    }

    /// **v4 B5 §1.** The scene for a rehearsal's log (`[perf] scene (rehearse #n, …):`).
    func printPerfScene(_ moment: String) {
        if let scene = PerfLog.census() { print("\(PerfLog.prefix) scene (\(moment)): \(scene)") }
        if let detail = PerfLog.censusDetail() { print("\(PerfLog.prefix) scene detail (\(moment)): \(detail)") }
    }

    static let perfSwitchCarrier = "cmd-perf"
}
