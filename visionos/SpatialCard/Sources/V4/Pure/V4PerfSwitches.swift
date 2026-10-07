import Foundation

extension V4 {
    /// **v4 B4 §3.5 — `cmd perf`: the desk's layers, switched live on the headset.**
    ///
    /// Round 2 left the desk at 44–46 fps with a list of suspects and no way to take them out one at a time without a
    /// relaunch (a relaunch loses the session's state, and the room's light with it). The director sends
    /// `{"c":"perf","arg":"<switches>"}` through the Hub's `POST /api/cmd`; every command **sets a state** (it never
    /// toggles), so the same command arriving twice — over the device's BLE relay and over the Hub's WebSocket — leaves the
    /// same scene. After each one the app opens a fresh 5 s `[perf]` window and prints the scene line.
    ///
    /// The argument is one string (a scalar survives every link; the BLE relay and `JSONValue` carry no objects):
    /// space- or comma-separated `layer=on|off`, `material=plain|blur|placeholder`, and the words `reset` (everything back
    /// to the app's defaults), `all=off` / `all=on`, or nothing at all (just measure). Unknown words are reported and
    /// skipped. `layer=off` forces the layer out of the scene; `layer=on` hands it back to the app (it is drawn when the
    /// app would draw it) — except `worlds`, which is out of the tree by default since B4: `worlds=on` puts the desk's
    /// prebuilt worlds back in it, B3's desk, for the A/B.
    enum PerfLayer: String, CaseIterable, Comparable {
        /// The desk's prebuilt worlds in the scene tree (parked 4 km away). Default **off** (B4 §3.2).
        case worlds
        /// The projector's three cone layers (`shimmer`, `coneTop`, `shimmerWide`).
        case cones
        /// The projector's ten rays to the card's bottom edge.
        case rays
        /// The light well's edge glow round the device.
        case well
        /// The whole gallery: the ten note cards (SwiftUI attachments), their trails and the twinkle.
        case gallery
        /// Only the note cards' glass (`glassBackgroundEffect`, a background blur each — the deck's two world cards with
        /// them): on = the system glass; off = the static frost (`NoteCardBase.frost`, v4 B5 §2; B4's was a flat night
        /// blue). **Off by default since 10-06** (the user's decision on the B5 stills: the frost is the cards' ground;
        /// `gallery-glass=on` brings the glass back to compare). Kept apart from `gallery` so one run tells "fix one
        /// effect" from "redesign the gallery".
        case galleryGlass = "gallery-glass"
        /// The ten note trails (`trail.note`): they rest with their cards since B4 §3.4; off = never.
        case trails
        /// The motes round the resting gallery (`notes.twinkle`).
        case twinkle
        /// The card's resident motes (`card.particles`).
        case cardParticles = "card-particles"
        /// The dust in the projector's beam (`rig.dust`).
        case rigDust = "rig-dust"
        /// The desk itself: the halo, the two world coins, the chips (`surface`).
        case desk
        /// **v4 B5 §2.** The gallery cards' opacity across their whole flight (a fan-out, the put-down bloom, the pick-up
        /// morph, a collapse): off = the cards fade in the first fifth of a flight out (the last fifth of a flight home)
        /// and are opaque the rest of the way — so a card is translucent for ~0.1 s instead of ~0.5 s.
        case noteFade = "note-fade"
        /// **v4 B5 §2.** The gallery's landing beats: the three 12-spark bursts, the rim's pulse, the bloom peak and the
        /// desk ripple of a fan-out (and the bursts of the put-down bloom). The chimes stay.
        case flourish
        /// **v4 B5 §2.** RealityKit's bloom on the desk (the `BloomComponent`s under the hologram, the desk, the mini card,
        /// the gold point): off = no glow pass at all. A measuring switch — the magic light's halo is the bloom.
        case bloom
        /// **v4 B5 §2.** The lost-passport cue's dim (V3-6 §1: the card and the whole gallery to 0.6 while the desk has
        /// lost the passport): off = only the rim breathes. Round 3's desk ladder ran under this dim.
        case holdDim = "hold-dim"
        /// **v4 B5 §3.** The three resident emitters at full rate (`notes.twinkle` 10/s, `card.particles` 30/s, `rig.dust`
        /// 18/s — ≈ 56 + 84 + 63 = 203 alive at the desk): off = two-thirds of each (≈ 137 alive). Not the same as the
        /// three per-emitter layers above, which take an emitter out entirely.
        case motes

        static func < (a: PerfLayer, b: PerfLayer) -> Bool {
            allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)!
        }

        /// What the app does with no command: everything drawn as designed, the prebuilt worlds out of the tree, the note
        /// cards on the frost (10-06).
        var defaultOn: Bool { self != .worlds && self != .galleryGlass }
    }

    /// **v4 B5 §1** `rehearse=…`: an *action*, not a state — play one real transition again at the desk so the headset can
    /// time it in whatever state the layers are in, with the wearer just looking at the desk.
    enum PerfRehearsal: String, CaseIterable {
        /// The gallery goes back into the card and fans out again, through `AppModel.toggleNotesFan` — the card's own pinch,
        /// the one entry B3 kept for it — called twice. Not a look-alike animation: the fan-out is welded to
        /// `NoteFanMachine` (its `suppressed`, its preview guards), and only the real entry exercises all of that.
        case fanout

        static let alias: [String: PerfRehearsal] = ["fan": .fanout, "fan-out": .fanout, "gallery": .fanout]
    }

    /// **v4 B5 §4** `tier=low|medium|high`: a world's quality tier, held there (the watchdog does not move it while it
    /// is forced) — inside a world now, and at the next entry. The tiers are the worlds' own (`WorldQuality`): `low`
    /// drops the nebula's far layer and gas clouds and halves its band stars.
    enum PerfWorldTier: String, CaseIterable {
        case low, medium, high
    }

    /// `material=…`: the card's own material.
    enum PerfCardMaterial: String, CaseIterable {
        /// A1's crystal without the background-blur pass (the product's frost since B4).
        case plain
        /// A1's crystal sampling RealityKit's background blur (B1–B3's frost).
        case blur
        /// A4's placeholder style: no A1 graph at all.
        case placeholder
    }

    struct PerfSwitches: Equatable {
        /// Every layer's state: `true` = drawn as the app would (for `worlds`: in the scene tree).
        private(set) var layers: [PerfLayer: Bool] = Dictionary(uniqueKeysWithValues: PerfLayer.allCases.map { ($0, $0.defaultOn) })
        /// The card's material; nil = whatever the launch chose (`--card-frost`, `--card-style`).
        private(set) var material: PerfCardMaterial?
        /// **v4 B5 §4.** A world's tier, forced; nil = the launch's (and the watchdog's).
        private(set) var tier: PerfWorldTier?

        func isOn(_ layer: PerfLayer) -> Bool { layers[layer] ?? layer.defaultOn }
        /// A layer the command forced out of the scene (`layer=off`; for `worlds`, the default).
        func isForcedOff(_ layer: PerfLayer) -> Bool { !isOn(layer) }

        /// One parsed command.
        struct Command: Equatable {
            var reset = false
            var all: Bool?
            var set: [PerfLayer: Bool] = [:]
            var material: PerfCardMaterial?
            var tier: PerfWorldTier?
            /// **v4 B5 §1** `rehearse=fanout`: an action to play once the switches have settled (no 5 s state window then:
            /// the rehearsal's own windows are the measurement).
            var rehearse: PerfRehearsal?
            /// **v4 B5 §1** `wait=<s>`: how long the switch settles before its window opens (0–10 s; nil = the default).
            var wait: Double?
            /// Words it could not read, as given.
            var unknown: [String] = []
            /// Nothing to change and nothing to play: the command only measures.
            var isMeasureOnly: Bool { !reset && all == nil && set.isEmpty && material == nil && tier == nil && rehearse == nil }
        }

        /// **v4 B5 §1.** Round 3's ladder opened each 5 s window on the frame of the switch, so the switch's own redraw
        /// landed inside it: "only the glass off" read 45.9 fps (worst 66.7 ms), the window where the gallery came back
        /// 70.9. A command that changes the scene now waits this long before its window opens.
        static let defaultSettle: Double = 2
        static let maxSettle: Double = 10

        /// How long a command waits before its window (or its rehearsal): `wait=` if it says, else the default when it
        /// changed the scene and nothing when it did not (a measure-only command, the same state again).
        static func settle(for command: Command, changedState: Bool) -> Double {
            command.wait ?? (changedState ? defaultSettle : 0)
        }

        static func parse(_ arg: String?) -> Command {
            var command = Command()
            let words = (arg ?? "").lowercased()
                .split(whereSeparator: { $0 == " " || $0 == "," || $0 == ";" || $0 == "\n" || $0 == "\t" })
                .map(String.init)
            for word in words {
                if word == "reset" || word == "defaults" { command.reset = true; continue }
                if word == "status" || word == "measure" { continue }
                let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { command.unknown.append(word); continue }
                let key = parts[0], value = parts[1]
                if key == "material" || key == "card" {
                    if let material = PerfCardMaterial(rawValue: value) { command.material = material } else { command.unknown.append(word) }
                    continue
                }
                if key == "tier" || key == "quality" {
                    if let tier = PerfWorldTier(rawValue: value) { command.tier = tier } else { command.unknown.append(word) }
                    continue
                }
                if key == "rehearse" || key == "rehearsal" {
                    if let kind = PerfRehearsal(rawValue: value) ?? PerfRehearsal.alias[value] { command.rehearse = kind } else { command.unknown.append(word) }
                    continue
                }
                if key == "wait" || key == "settle" {
                    let seconds = Double(value.hasSuffix("s") ? String(value.dropLast()) : value)
                    if let seconds, seconds.isFinite, seconds >= 0 { command.wait = min(maxSettle, seconds) } else { command.unknown.append(word) }
                    continue
                }
                guard let on = Self.flag(value) else { command.unknown.append(word); continue }
                if key == "all" { command.all = on; continue }
                guard let layer = PerfLayer(rawValue: key) ?? Self.alias[key] else { command.unknown.append(word); continue }
                command.set[layer] = on
            }
            return command
        }

        static let alias: [String: PerfLayer] = ["glass": .galleryGlass, "galleryglass": .galleryGlass, "notes": .gallery,
                                                 "particles": .cardParticles, "dust": .rigDust, "world": .worlds,
                                                 "fade": .noteFade, "flourishes": .flourish, "glow": .bloom, "dim": .holdDim,
                                                 "resident-motes": .motes]

        static func flag(_ value: String) -> Bool? {
            switch value {
            case "on", "1", "true", "yes", "in": return true
            case "off", "0", "false", "no", "out": return false
            default: return nil
            }
        }

        /// Apply a command: `reset` first, then `all`, then each named layer — so `all=off desk=on` is everything off but
        /// the desk. Setting what is already set changes nothing (the same command twice is the same scene).
        mutating func apply(_ command: Command) {
            if command.reset {
                self = PerfSwitches()
            }
            if let all = command.all {
                for layer in PerfLayer.allCases { layers[layer] = all }
            }
            for (layer, on) in command.set { layers[layer] = on }
            if let material = command.material { self.material = material }
            if command.reset, command.material == nil { material = nil }
            if let tier = command.tier { self.tier = tier }
            if command.reset, command.tier == nil { tier = nil }
        }

        /// `worlds in the tree · cones off · gallery-glass on · … · material plain` — only what differs from the defaults,
        /// or `defaults`.
        var summary: String {
            var parts: [String] = []
            for layer in PerfLayer.allCases where isOn(layer) != layer.defaultOn {
                if isOn(layer) {
                    parts.append(layer == .worlds ? "worlds in the tree" : "\(layer.rawValue) on")
                } else {
                    parts.append("\(layer.rawValue) off")
                }
            }
            if let material { parts.append("material \(material.rawValue)") }
            if let tier { parts.append("tier \(tier.rawValue)") }
            return parts.isEmpty ? "defaults" : parts.joined(separator: " · ")
        }
    }

    /// **v4 B5 §1 — when a `rehearse=fanout` may play.** A rehearsal is the card's own pinch, twice, so it may only run
    /// where that pinch means "take the gallery back, then throw it again": the card standing on the desk with its
    /// gallery out and nothing else in flight. Anywhere else the same pinch does something else entirely (inside a world
    /// it is the way out; in a preview it closes the preview), so the director gets a refusal with the reason instead.
    struct PerfRehearsalContext: Equatable {
        /// The immersive space is open and the controller exists.
        var spaceOpen = true
        var inWorld = false
        /// The card is showing (not collapsed into the gold point, not folded away, not yet recognised).
        var cardShown = true
        /// The passport is in the hand: the hand form, or the deck standing.
        var inHand = false
        var previewOpen = false
        /// An entrance (a recognition, a rise) is still playing on the card, or another rehearsal is.
        var busy = false
        /// `NoteFanMachine` says `.fanned`: the gallery stands on the desk.
        var galleryOut = true

        /// Nil = go; otherwise why not, for the log.
        var refusal: String? {
            if !spaceOpen { return "the immersive space is not open" }
            if inWorld { return "a world is open (the card's pinch is the way out there)" }
            if !cardShown { return "the card is put away" }
            if inHand { return "the passport is in the hand (the deck, not the gallery)" }
            if previewOpen { return "a note preview is open (the pinch would close it)" }
            if busy { return "the card is still busy (an entrance or a rehearsal is playing)" }
            if !galleryOut { return "the gallery is not out on the desk" }
            return nil
        }
    }
}
