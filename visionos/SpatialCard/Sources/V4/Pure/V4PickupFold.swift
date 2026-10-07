import Foundation
import simd

extension V4 {
    /// **v4 B2 §3.3 — the pick-up fold** (`--pickup-fold on|off`, default on).
    ///
    /// The user's rule stands: the card follows the **device**, never the hand. Before this, a loss while the passport
    /// was being picked up left the card where the passport had been — hanging 22 cm over an empty desk, dimmed, for as
    /// long as the camera could not find the device (round 1: tens of seconds). Now a loss that is a **grab** (a
    /// tracked wrist within the bridge's 15 cm when the camera lost the device, or reaching it later — `LossClock`'s
    /// rule, applied per hold by `GrabWatch`)
    /// that has lasted `after` seconds folds the card into the device's last position: an arc down into a warm gold
    /// point beside the case's top edge (v4 B3; B2 had it 40 mm over the screen). When the device is seen again the card
    /// comes out of it — grown straight
    /// onto the hinge if the passport is in the hand (the hand form's own 0.35 s spring from the point: the summon's
    /// short version), or A4's rise off the screen if it is back on the desk. A loss with no hand near it (the desk
    /// case) keeps V3-6's "wait where it was, dimmed".
    ///
    /// Motion (art bible §3): a 80 ms / +4 % anticipation, then a 0.5 s arc (a medium move; the lift is 18 % of the
    /// distance, inside the bible's 10–25 %), the point popping in as the card arrives (a small flash on landing), and
    /// breathing at the searching rate while it waits.
    enum PickupFold {
        /// How long a grab loss lasts before the card folds (the brief's 0.5 s).
        static let after: TimeInterval = 0.5
        /// A thawed, folded card waits this long for the `.carry` that says the passport is in a hand; without one it
        /// rises on the desk. (A tilted re-detection is `carrying(notFlat)` on the very next observation, 33 ms later.)
        static let carryGrace: TimeInterval = 0.35
        /// **v4 B3 §2: the gold point beside the case's top edge** (the lanyard end), in the case frame C: `pointBeyondEdge`
        /// past the edge and `pointLift` over the top face. B2 had it 40 mm straight over the LCD — above the prism, but in
        /// the hand (screen to the eyes) exactly between the eyes and the screen. Out past the top edge it is clear of the
        /// prism in Z, the real screen stays in view from the desk and from the hand, and it is the one resting picture of
        /// a collapsed card (it replaces v3's socket light and sleeping dust) as well as the pick-up fold's point.
        static let pointBeyondEdge: Float = 0.018
        static let pointLift: Float = 0.012
        /// Where the point stands in C for a case `caseLength` long: (0, +12, −(L/2 + 18)) mm — (0, +12, −66) on the
        /// 96 mm AI Passport.
        static func pointPosition(caseLength: Float) -> SIMD3<Float> {
            [0, pointLift, -(caseLength / 2 + pointBeyondEdge)]
        }
        /// The bright core's radius (what the eye reads as "the point"; the rest of the 32 mm plane is a falloff to nothing).
        static let pointCore: Float = 0.005
        /// Its size: a 10 mm bright core in a 32 mm soft glow (the plane is the glow; the core is the texture's).
        static let pointSize: Float = 0.032
        /// The card's scale at the end of the fold, relative to where it started (it *becomes* the point).
        static let foldedScale: Float = 0.04
        static let anticipationDuration: Float = 0.08
        static let anticipationScale: Float = 1.04
        static let foldDuration: Float = 0.5
        /// The share of the travel the arc lifts by (bible: 10–25 %).
        static let arcLiftFraction: Float = 0.18
        /// The point's breath while it waits: V3-6's searching rate.
        static let breathPeriod: Float = 2.4

        /// **The grab, judged per hold.** `LossClock`'s rule decides what a loss is — a tracked wrist inside the bridge's
        /// attach radius at the loss, or reaching it later, is a grab (`LossClock.classify`) — but `LossClock` itself keeps
        /// a grab's clock running through a thaw back to the desk, on purpose: its `[timing] pick-up` waits for a carry
        /// that can arrive after the passport is seen again. Read by the fold, that clock was wrong twice (found running
        /// the fold's desk-unfold script in the simulator): a hand that closed over the passport and left again (a grab
        /// under 0.5 s, or a fold that unfolded back onto the desk) left a `.grab` running, so the next loss of any kind
        /// — minutes later, no hand anywhere — folded the card on the spot (`lost 14.8 s, hand -`); and a real pick-up in
        /// that later loss could not start a clock of its own (`reach` only upgrades a desk / unknown loss). So the fold
        /// applies the same rule on its own clock, one hold at a time: it starts the first time this hold sees a tracked
        /// wrist inside the radius, keeps running when the hand moves away with the passport, and a hold that ends
        /// forgets it.
        struct GrabWatch: Equatable {
            /// When the current loss hold began (the poll's clock), nil while the passport is not lost.
            private(set) var holdSince: TimeInterval?
            /// When this hold first saw a wrist within the radius, nil until it does.
            private(set) var grabSince: TimeInterval?

            /// One poll. `handDistance`: the nearest tracked wrist to where the passport was last seen (nil = no hand
            /// data); `radius`: the bridge's attach radius, the one `LossClock` classifies with.
            mutating func step(lossHold: Bool, handDistance: Float?, radius: Float, at now: TimeInterval) {
                guard lossHold else {
                    holdSince = nil
                    grabSince = nil
                    return
                }
                if holdSince == nil { holdSince = now }
                if grabSince == nil, LossClock.classify(handDistance: handDistance, radius: radius) == .grab {
                    grabSince = now
                }
            }

            /// How long this hold's grab has been going, nil when this hold has not seen one.
            func grabSeconds(at now: TimeInterval) -> TimeInterval? {
                grabSince.map { max(0, now - $0) }
            }
        }

        /// **v4 B4 §2 — a pick-up has to be seen, not assumed.**
        ///
        /// B2 folded on the grab alone (a wrist within 15 cm for 0.5 s of a loss). On the desk that is also every key press
        /// and every put-down: round 2 (B3 run 1) folded the card seven times on the desk and six of them were not pick-ups
        /// — the passport was found again 1.2–7.3 cm from where it lay. Lines 603 (1 s after the put-down, the hand still
        /// there), 792 / 832 (the instant of an OK / a DOWN), 681 / 918 / 1084 (the hand reaching over to press a key — 1084
        /// with the loss already 3 s old when the hand came, so a clock from the loss would have let it through). The one real
        /// pick-up (1282) had the hand go from 15 to 29 cm off the passport's last position within a second; in the false ones
        /// it stayed at 12–15 cm.
        ///
        /// So the watch waits for **evidence**, timed from the moment the hand comes within the radius (the reach), not from
        /// the loss: within `window` of the reach the hand either leaves — gets `departure` farther from where the passport
        /// lay than it ever came — or rises `rise` above its lowest point since the reach. Evidence seen within `settleGuard`
        /// of a put-down or `keyGuard` of a key press is ignored (the hand is leaving because it just put the passport down /
        /// pressed a key). Without evidence the card waits where it is, dimmed (B2's desk loss), and brightens where it stood
        /// when the passport is seen again. A fold also needs the hold to have lasted `after` (a hand sweeping past is not a
        /// pick-up). Every step is a log line (`[pickup] …`) the next headset round can tune from.
        struct PickupWatch: Equatable {
            /// How long after the reach the hand's evidence counts.
            static let window: TimeInterval = 1.5
            /// The hand gets this much farther from the passport's last position than its closest since the reach.
            static let departure: Float = 0.10
            /// …or rises this much above its lowest since the reach.
            static let rise: Float = 0.10
            /// Evidence this soon after the card settled on the desk (a put-down) is the hand letting go.
            static let settleGuard: TimeInterval = 2.0
            /// …and this soon after a key press, the hand that pressed it.
            static let keyGuard: TimeInterval = 1.5
            /// The hand has left the reach (a new reach can start a new window) once it is this far past the radius.
            static let leaveMargin: Float = 0.03
            /// While a hand is near, a trace line this often.
            static let traceEvery: TimeInterval = 0.5

            /// The nearest tracked hand: its distance from where the passport was last seen, and its height above it (m).
            struct Hand: Equatable {
                var distance: Float
                var height: Float
            }

            enum Event: Equatable {
                /// The hold began (the passport is lost with the card standing on the desk).
                case holdStarted(Hand?)
                /// A hand came within the radius: the window opens.
                case reach(Hand)
                /// Periodic, while the hand is within the radius during an open window.
                case trace(Hand, left: Float, rose: Float, since: TimeInterval)
                /// Evidence of a pick-up: the fold may go (once the hold is `after` old).
                case evidence(String)
                /// Evidence inside a guard: ignored, this reach's window is closed.
                case guarded(String)
                /// The window ran out with the hand still near: not a pick-up.
                case noPickUp(String)
                /// The hand went away after its window closed: a new reach can open a new one.
                case handLeft(Hand)
                /// The hold ended (the passport is seen again, or the card left the desk) without a fold.
                case holdEnded(TimeInterval)
            }

            private(set) var holdSince: TimeInterval?
            private(set) var reachAt: TimeInterval?
            private(set) var closest: Float = .infinity
            private(set) var lowest: Float = .infinity
            /// The pick-up evidence of this hold, once seen (latched until the fold or the hold's end).
            private(set) var evidence: String?
            /// This reach's window is over (it ran out, or evidence was guarded): nothing more counts until the hand leaves.
            private(set) var windowClosed = false
            private var nextTrace: TimeInterval = 0

            /// One poll. `active`: the passport is lost (`held(untracked | stale)`) with the card standing on the desk.
            /// `settledAt` / `keyAt`: the last put-down and the last key press, on the same clock.
            mutating func step(active: Bool, hand: Hand?, radius: Float, at now: TimeInterval,
                               settledAt: TimeInterval?, keyAt: TimeInterval?) -> [Event] {
                guard active else {
                    defer { self = PickupWatch() }
                    if let since = holdSince, evidence == nil { return [.holdEnded(now - since)] }
                    return []
                }
                var events: [Event] = []
                if holdSince == nil {
                    holdSince = now
                    events.append(.holdStarted(hand))
                }
                guard evidence == nil, let hand, hand.distance.isFinite, hand.height.isFinite else { return events }
                guard let reach = reachAt else {
                    guard hand.distance <= radius else { return events }
                    reachAt = now
                    closest = hand.distance
                    lowest = hand.height
                    windowClosed = false
                    nextTrace = now + PickupWatch.traceEvery
                    events.append(.reach(hand))
                    return events
                }
                if windowClosed {
                    // Nothing counts until the hand has gone; then the next reach opens a new window.
                    if hand.distance > radius + PickupWatch.leaveMargin {
                        reachAt = nil
                        closest = .infinity
                        lowest = .infinity
                        windowClosed = false
                        events.append(.handLeft(hand))
                    }
                    return events
                }
                closest = min(closest, hand.distance)
                lowest = min(lowest, hand.height)
                let left = hand.distance - closest, rose = hand.height - lowest
                let since = now - reach
                let detail = String(format: "%.0f → %.0f cm off the passport (+%.0f cm), %+.0f cm over it (rose %.0f cm), %.1f s after the reach",
                                    closest * 100, hand.distance * 100, left * 100, hand.height * 100, rose * 100, since)
                if left >= PickupWatch.departure || rose >= PickupWatch.rise {
                    let what = left >= PickupWatch.departure ? "the hand left with it" : "the hand rose with it"
                    if let settledAt, now - settledAt < PickupWatch.settleGuard {
                        windowClosed = true
                        events.append(.guarded(String(format: "%@ (%@) — but %.1f s after the put-down (< %.1f s): letting go, not a pick-up",
                                                      what, detail, now - settledAt, PickupWatch.settleGuard)))
                    } else if let keyAt, now - keyAt < PickupWatch.keyGuard {
                        windowClosed = true
                        events.append(.guarded(String(format: "%@ (%@) — but %.1f s after a key (< %.1f s): the hand that pressed it",
                                                      what, detail, now - keyAt, PickupWatch.keyGuard)))
                    } else {
                        evidence = "\(what) (\(detail))"
                        events.append(.evidence(evidence!))
                    }
                    return events
                }
                if since > PickupWatch.window {
                    windowClosed = true
                    events.append(.noPickUp("the hand stayed near for \(String(format: "%.1f", PickupWatch.window)) s (\(detail)): the card waits where it is"))
                    return events
                }
                if now >= nextTrace {
                    nextTrace = now + PickupWatch.traceEvery
                    events.append(.trace(hand, left: left, rose: rose, since: since))
                }
                return events
            }

            /// Fold now: evidence was seen and the hold is at least `after` old.
            func shouldFold(at now: TimeInterval) -> Bool {
                guard evidence != nil, let since = holdSince else { return false }
                return now - since >= PickupFold.after
            }

            /// How long the hold has lasted.
            func holdSeconds(at now: TimeInterval) -> TimeInterval { holdSince.map { max(0, now - $0) } ?? 0 }

            /// The `[pickup] …` line for an event.
            static func line(_ event: Event) -> String {
                func hand(_ h: Hand?) -> String {
                    guard let h else { return "no hand tracked" }
                    return String(format: "hand %.0f cm, %+.0f cm over the passport", h.distance * 100, h.height * 100)
                }
                switch event {
                case .holdStarted(let h): return "[pickup] lost on the desk (\(hand(h))): the card waits; it folds only on a pick-up"
                case .reach(let h): return String(format: "[pickup] reach (%@): watching %.1f s for the hand to leave (+%.0f cm) or rise (+%.0f cm)",
                                                  hand(h), PickupWatch.window, PickupWatch.departure * 100, PickupWatch.rise * 100)
                case .trace(let h, let left, let rose, let since):
                    return String(format: "[pickup] %.1f s: %@ (left +%.0f cm, rose +%.0f cm)", since, hand(h), left * 100, rose * 100)
                case .evidence(let why): return "[pickup] a pick-up: \(why)"
                case .guarded(let why): return "[pickup] not a pick-up: \(why)"
                case .noPickUp(let why): return "[pickup] not a pick-up: \(why)"
                case .handLeft(let h): return "[pickup] the hand went (\(hand(h))): a new reach watches again"
                case .holdEnded(let seconds): return String(format: "[pickup] the hold ended after %.1f s without a pick-up: the card brightens where it stood", seconds)
                }
            }
        }

        /// Should the card fold now?
        /// - `lossHold`: the presence is `held(.untracked)` / `held(.stale)` — the device is lost, not a button / theme /
        ///   world hold.
        /// - `grab`: this hold saw a grab (`GrabWatch`: a hand within 15 cm, at the loss or since — `LossClock`'s rule).
        /// - `lossSeconds`: how long the grab has been going (from the loss, or from the reach).
        /// - `cardOnDesk`: the card is standing on the desk (shown, not in the hand form, not a mini card, not folded).
        static func shouldFold(enabled: Bool, lossHold: Bool, grab: Bool, lossSeconds: TimeInterval?,
                               cardOnDesk: Bool) -> Bool {
            guard enabled, lossHold, grab, cardOnDesk, let seconds = lossSeconds else { return false }
            return seconds > after
        }

        enum Unfold: Equatable {
            /// Not yet: the grace for a carry is still running.
            case wait
            /// The passport is in a hand: the hand form grows the card out of the point.
            case hand
            /// It is back on the desk: the card rises off the screen.
            case desk
            /// Lost again (or gone): stay folded.
            case stay
        }

        /// After the thaw of a folded card: what now, `sinceThaw` seconds later.
        static func unfold(carrying: Bool, resting: Bool, lost: Bool, sinceThaw: TimeInterval) -> Unfold {
            if carrying { return .hand }
            if lost { return .stay }
            guard resting else { return .stay }
            return sinceThaw >= carryGrace ? .desk : .wait
        }

        /// The arc for a flight from `from` to `to`: straight up, `arcLiftFraction` of the distance.
        static func arcOffset(from: SIMD3<Float>, to: SIMD3<Float>) -> SIMD3<Float> {
            let d = simd_distance(from, to)
            return [0, d * arcLiftFraction, 0]
        }

        /// `[reveal] pick-up fold …` — why, in numbers the next headset round can check.
        static func foldLine(handDistance: Float?, lossSeconds: TimeInterval) -> String {
            let hand = handDistance.map { String(format: "hand %.0f cm", $0 * 100) } ?? "hand -"
            return String(format: "[reveal] pick-up fold: the card goes into the device's last position (grab, %@, lost %.1f s)",
                          hand, lossSeconds)
        }
    }
}
