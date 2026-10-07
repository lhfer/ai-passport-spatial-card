import Foundation

extension V4 {
    /// **v4 B3 §1 — one table for the three keys.**
    ///
    /// Round 2 run A found the two ways the old map failed the wearer. Inside neon-city sixteen presses did nothing
    /// (only a long OK left a world) until the Digital Crown aborted it and took the tracking session down with it; on
    /// the desk an OK with nothing highlighted folded the card into the device, twice, when the wearer meant something
    /// else. The rules below remove both: **no press goes unanswered, and no single press takes the card away.**
    ///
    /// | where | UP / DOWN | OK | long OK |
    /// | --- | --- | --- | --- |
    /// | world, fully inside | — | leave it (back to the desk, or the hand) | leave it |
    /// | world, entering / exiting | — | ignored (logged) | ignored (logged) |
    /// | preview open (desk or hand) | page | close | close |
    /// | desk, a fresh highlight | move it | open the note / enter the world | collapse |
    /// | desk, no highlight (also lost: `held`) | move it | = DOWN: the ring's first item | collapse |
    /// | hand, a card raised | raise the next | open the note / enter the world | collapse |
    /// | hand, profile (nothing raised) | raise the next | = DOWN: slot 0 (neon-city's world card) | collapse |
    /// | collapsed (the gold point) | — | summon: the full recognition again | — |
    /// | the card is arriving (a recognition holds its entrance) | — | — | — |
    /// | pick-up fold (the point, the passport lost in a hand) | — | — (it comes back when seen) | collapse |
    /// | nothing recognised yet | — | — | — |
    ///
    /// "—" is an ignore, and every ignore says why in the log (`[keys] … → ignored (…)`). Collapsing is long OK (or the
    /// passport turned face down for 0.8 s, which is not a key and is not in this table). Slot 0 of the hand deck is a
    /// world card on purpose (the deck's two ends are the worlds), so OK, OK from the profile enters neon-city.
    enum ButtonMap {
        enum Key: String, Equatable, CaseIterable {
            case up, down, ok
            case longOK = "long ok"

            /// DOWN is the next item (+1), UP the previous one (−1): the deck's, the ring's and v3's carousel's convention.
            var step: Int? {
                switch self {
                case .up: return -1
                case .down: return 1
                case .ok, .longOK: return nil
                }
            }
        }

        /// Where a press lands. `AppModel.keyContext` builds it from the world engine, the note fan, the gate, the
        /// controller and the desk ring, in this order of precedence.
        enum Context: Equatable {
            /// A world owns the screen; `inside` = fully entered (`WorldEngine.State.inside`), else entering / exiting.
            case world(inside: Bool)
            /// A note preview is open, on the desk or in the hand.
            case preview
            /// The card is collapsed on purpose (dismissed): the gold point (`--v3-card`: the socket light) waits.
            case collapsed
            /// A recognition (the ribbon, or v3's short scan) is holding the card's entrance back.
            case arriving
            /// A pick-up loss folded the card into the gold point (B2 §3.4): the gate is holding a lost passport.
            case pickupFolded
            /// The card stands on the desk. `highlight`: the ring rests on something OK may still act on.
            /// `held`: the passport is lost (stale / untracked) and the gallery frozen where it was.
            case desk(highlight: Bool, held: Bool)
            /// The passport is in the hand (the deck, or v3's pager with `--deck off`). `raised`: a card or page other
            /// than the profile is up.
            case hand(raised: Bool)
            /// Nothing has been recognised yet.
            case nothing

            var label: String {
                switch self {
                case .world(let inside): return inside ? "world (inside)" : "world (entering / exiting)"
                case .preview: return "preview"
                case .collapsed: return "collapsed"
                case .arriving: return "arriving"
                case .pickupFolded: return "pick-up fold"
                case .desk(let highlight, let held):
                    return "desk\(held ? " (lost, held)" : "")\(highlight ? ", highlight" : ", no highlight")"
                case .hand(let raised): return raised ? "hand, raised" : "hand, profile"
                case .nothing: return "nothing seen yet"
                }
            }
        }

        enum Reason: String, Equatable {
            case worldTransition = "a world is opening or closing: keys wait for it to be fully inside"
            case worldKeys = "UP / DOWN do nothing inside a world"
            case collapsed = "the card is collapsed: OK summons it"
            case arriving = "the card is arriving: keys wait for the recognition's closure"
            case pickupFolded = "the card is a gold point until the passport is seen again"
            case alreadyCollapsed = "already collapsed"
            case nothingSeen = "nothing recognised yet"
        }

        enum Action: Equatable {
            case exitWorld
            case ignore(Reason)
            case closePreview
            /// UP / DOWN inside an open preview: the next / previous note.
            case pagePreview(Int)
            /// The desk ring moves by `delta`. OK with no highlight is `deskStep(1)` — DOWN.
            case deskStep(Int)
            /// OK on the desk ring's highlight: open the note, or enter the world.
            case deskOpen
            /// The hand deck (or pager) moves by `delta`. OK at the profile is `handStep(1)` — DOWN.
            case handStep(Int)
            /// OK on the raised deck card (or page): open the note, or enter the world.
            case handOpen
            /// Long OK: the card goes into the device and becomes the gold point.
            case collapse
            /// OK while collapsed: the full recognition plays again.
            case summon

            var label: String {
                switch self {
                case .exitWorld: return "leave the world"
                case .ignore(let reason): return "ignored (\(reason.rawValue))"
                case .closePreview: return "close the preview"
                case .pagePreview(let d): return "page the preview \(d > 0 ? "+1" : "-1")"
                case .deskStep(let d): return "ring \(d > 0 ? "+1" : "-1")"
                case .deskOpen: return "open the highlight"
                case .handStep(let d): return "deck \(d > 0 ? "+1" : "-1")"
                case .handOpen: return "open the raised card"
                case .collapse: return "collapse the card"
                case .summon: return "summon the card"
                }
            }
        }

        /// The whole table.
        static func action(_ key: Key, in context: Context) -> Action {
            switch context {
            case .world(let inside):
                if key.step != nil { return .ignore(.worldKeys) }
                return inside ? .exitWorld : .ignore(.worldTransition)
            case .preview:
                if let step = key.step { return .pagePreview(step) }
                return .closePreview
            case .collapsed:
                return key == .ok ? .summon : .ignore(key == .longOK ? .alreadyCollapsed : .collapsed)
            case .arriving:
                return .ignore(.arriving)
            case .pickupFolded:
                return key == .longOK ? .collapse : .ignore(.pickupFolded)
            case .desk(let highlight, _):
                if let step = key.step { return .deskStep(step) }
                if key == .longOK { return .collapse }
                return highlight ? .deskOpen : .deskStep(1)
            case .hand(let raised):
                if let step = key.step { return .handStep(step) }
                if key == .longOK { return .collapse }
                return raised ? .handOpen : .handStep(1)
            case .nothing:
                return .ignore(.nothingSeen)
            }
        }

        /// `[keys] ok · desk, no highlight → ring +1 (= DOWN)` — one line per press, so a headset log says what every
        /// press was taken to mean.
        static func line(_ key: Key, _ context: Context, _ action: Action) -> String {
            let alias: String
            switch (key, action) {
            case (.ok, .deskStep), (.ok, .handStep): alias = " (= DOWN)"
            default: alias = ""
            }
            return "[keys] \(key.rawValue) · \(context.label) → \(action.label)\(alias)"
        }
    }
}
