import Foundation

/// What the note fan is doing right now (工作包 D). The wearer only ever sees one of these three.
enum NoteFanState: Equatable {
    /// Hidden inside the card (the fan has not been thrown, or it was taken back).
    case collapsed
    /// The ten covers stand on their arc.
    case fanned
    /// One of them is enlarged in front of the wearer; the rest have stepped back.
    case preview(String)
    /// **V3-2a H3**: the passport is in the wearer's hand and the five latest notes plus the two world
    /// cards are a hand of cards fanned out behind the name card, at most one of them raised over it.
    case deck(raised: String?)

    /// The cards accept a pinch (they do not while they are folded into the card — and a deck card is
    /// 6 cm tall on a device someone is holding, so it is driven by the buttons, never by a pinch).
    var isInteractive: Bool {
        switch self {
        case .collapsed, .deck: return false
        case .fanned, .preview: return true
        }
    }

    var isDeck: Bool {
        if case .deck = self { return true }
        return false
    }

    /// Which deck card is raised over the name card, if any.
    var raisedID: String? {
        if case .deck(let id) = self { return id }
        return nil
    }

    var previewID: String? {
        if case .preview(let id) = self { return id }
        return nil
    }

    var label: String {
        switch self {
        case .collapsed: return "collapsed"
        case .fanned: return "fanned"
        case .preview(let id): return "preview(\(id.prefix(6)))"
        case .deck(let raised): return raised.map { "deck(raised: \($0.prefix(6)))" } ?? "deck"
        }
    }
}

/// The rules that tie the note fan to the card's own life: it is thrown when the card settles on the desk,
/// taken back when the card is picked up, folded away or carried into a world, and thrown again when it comes
/// home — unless the wearer took it back **by hand** (long OK), which holds for the rest of the session.
///
/// Pure value type (no RealityKit, no AppModel) so `SpatialCardTests` can drive every path deterministically.
/// `handle` returns the one thing the caller has to *do*; the state itself is what the views read.
struct NoteFanMachine: Equatable {
    enum Event: Equatable {
        /// The card is on the desk and idle (`HologramController.startIdle`).
        case settled
        /// The device was picked up: the card rides along, the fan is taken back.
        case carried
        /// The card folded into the device (dismiss / replay / teardown).
        case hidden
        case worldEntered
        case returnedFromWorld
        /// Long press on the device's OK button (or a tap on the desk's 「笔记」 chip when no device is linked).
        case longOK
        case tapped(String)
        /// v3 H2 §8: OK on a note page of the **hand** card. There is no fan out on the device — the card is
        /// a 13.5 cm pane in the wearer's hand — so this opens one note's preview straight from `.collapsed`,
        /// and closing it goes back to `.collapsed` rather than to an arc that was never there.
        case previewDirect(String)
        /// V3-2a H3: UP / DOWN raised this deck card over the name card (nil = back to the profile).
        case raiseDeck(String?)
        /// A new list arrived from the hub (same rev = the caller does not send this).
        case notesChanged(ids: [String])
        /// **v4 B2 §2.** Close the open preview — OK on the desk or in the hand, the panel's × button, a tap on the
        /// panel. Unlike `longOK` it does nothing at all when no preview is open, so a second tap that lands after the
        /// panel has gone can never take the fan back or throw it.
        case closePreview
        /// The immersive space went away: everything starts over next time.
        case spaceDismissed
        /// **v4 B5 §1.** Lift a suppression without throwing the fan: a `cmd perf rehearse=fanout` whose fan-out could not
        /// follow its collapse (the passport was picked up in between). That collapse was the director's, not the
        /// wearer's, so it must not keep the gallery down for the rest of the session the way a long OK does.
        case unsuppress
    }

    /// What the choreography has to play. One event produces at most one of these.
    enum Outcome: Equatable {
        case none
        /// Throw the fan (the caller delays it 0.6 s after a settle).
        case fanOut
        /// Take the fan back, outside-in.
        case collapse
        /// The card itself is leaving: the fan goes down with it, without its own choreography.
        case sink
        /// The ids changed while the fan was out: re-slot what stayed, fan in what is new, fly home what left.
        case relayout
        /// V3-2a H3 / plan §4 E2: the gallery becomes the hand deck — five cards to the fan, five folded
        /// into the card, two world cards out from behind it. One continuous morph, not a collapse.
        case morphToDeck
        /// The list changed while the deck is in the hand: re-slot the seven cards where they stand.
        case relayoutDeck
        case preview(String)
        case endPreview
        case switchPreview(from: String, to: String)
    }

    private(set) var state: NoteFanState = .collapsed
    /// The preview on screen was opened from the hand card, not from the arc: there is no fan behind it, so
    /// every way out of it goes back to `.collapsed`.
    private(set) var directPreview = false
    /// The wearer took the fan back by hand: it is not thrown again by itself for the rest of the session.
    private(set) var suppressed = false
    /// The card is on the desk in a state that can carry a fan (not carried, not hidden, not in a world).
    private(set) var deskReady = false
    private(set) var ids: [String] = []
    /// V3-2a H3: `--deck` is on, so a carry becomes the hand deck rather than a plain collapse. Written by
    /// `AppModel` from the flag and from whether the hand form is reachable at all.
    var deckEnabled = false
    /// The preview on screen was opened from a deck card, so closing it puts that card back **raised**
    /// rather than into the card or onto an arc.
    private(set) var fromDeck = false

    var canFan: Bool { deskReady && !suppressed && !ids.isEmpty }

    @discardableResult
    mutating func handle(_ event: Event) -> Outcome {
        switch event {
        case .settled:
            deskReady = true
            if case .preview = state {
                // The passport was put down with a note open. The preview is world-locked in root space and
                // the bloom is about to lay the gallery out in the fan's space: it has to end here, or the
                // card it holds is tweened to a target in a space it is not in.
                directPreview = false
                fromDeck = false
                state = canFan ? .fanned : .collapsed
                return .endPreview
            }
            if state.isDeck {
                // The put-down bloom (plan §4 E10) is choreographed by the controller's own settle: it puts
                // five cards on the front row and fans the other five out of the card. `startIdle()` lands
                // here 0.6 s later, and a `.fanOut` from it would re-fly all ten over the landing.
                state = canFan ? .fanned : .collapsed
                fromDeck = false
                return .none
            }
            guard state == .collapsed, canFan else { return .none }
            state = .fanned
            return .fanOut

        case .carried:
            deskReady = false
            directPreview = false
            fromDeck = false
            guard deckEnabled else {
                guard state != .collapsed else { return .none }
                state = .collapsed
                return .collapse
            }
            // V3-2a H3: the gallery does not go back into the card, it *becomes* the deck. A preview that
            // was open is ended by the morph itself (`morphGalleryToDeck` calls `endPreviewNote`), which is
            // why this is still one outcome and not two.
            guard !state.isDeck else { return .none }
            state = .deck(raised: nil)
            return .morphToDeck

        case .hidden:
            deskReady = false
            directPreview = false
            fromDeck = false
            guard state != .collapsed else { return .none }
            state = .collapsed
            return .sink

        case .worldEntered:
            deskReady = false
            directPreview = false
            fromDeck = false
            guard state != .collapsed else { return .none }
            state = .collapsed
            return .collapse

        case .returnedFromWorld:
            deskReady = true
            guard state == .collapsed, canFan else { return .none }
            state = .fanned
            return .fanOut

        case .raiseDeck(let id):
            guard state.isDeck else { return .none }
            state = .deck(raised: id)
            return .none

        case .previewDirect(let id):
            guard ids.contains(id) else { return .none }
            switch state {
            case .preview(let current):
                guard current != id else {
                    state = previewHome(for: id)
                    directPreview = false
                    return .endPreview
                }
                // Another note page: a plain `.preview`, never a `.switchPreview`. The switch choreography
                // overlaps two flights by 0.1 s, and a hand-card preview is world-locked in root space while
                // an arc one is not — overlapping the two would leave one of them in the wrong space.
                state = .preview(id)
                directPreview = true
                return .preview(id)
            case .collapsed, .fanned:
                directPreview = state == .collapsed
                fromDeck = false
                state = .preview(id)
                return .preview(id)
            case .deck:
                // V3-2a H6: out of the deck and up to the eyes; OK again puts it back on its raised slot.
                directPreview = true
                fromDeck = true
                state = .preview(id)
                return .preview(id)
            }

        case .longOK:
            switch state {
            case .deck:
                // Long OK belongs to the worlds and the preview; a deck in the hand has nothing to take back.
                return .none
            case .preview(let current):
                // A preview the hand card opened has no arc to fall back to.
                state = previewHome(for: current)
                directPreview = false
                return .endPreview
            case .fanned:
                state = .collapsed
                suppressed = true
                return .collapse
            case .collapsed:
                // The wearer is asking for it: that also lifts a suppression from an earlier long press.
                suppressed = false
                guard canFan else { return .none }
                state = .fanned
                return .fanOut
            }

        case .tapped(let id):
            switch state {
            case .collapsed, .deck:
                return .none
            case .fanned:
                guard ids.contains(id) else { return .none }
                state = .preview(id)
                return .preview(id)
            case .preview(let current):
                guard current != id else {
                    state = previewHome(for: current)
                    directPreview = false
                    return .endPreview
                }
                guard ids.contains(id) else { return .none }
                state = .preview(id)
                return .switchPreview(from: current, to: id)
            }

        case .notesChanged(let newIDs):
            ids = newIDs
            switch state {
            case .deck(let raised):
                // The deck keeps standing; its slots are re-laid out around whatever is left.
                if let raised, !newIDs.contains(raised) { state = .deck(raised: nil) }
                return .relayoutDeck
            case .preview(let current) where !newIDs.contains(current):
                // The note being previewed is gone: back to the arc rather than onto an empty frame.
                state = fromDeck ? .deck(raised: nil) : ((ids.isEmpty || directPreview) ? .collapsed : .fanned)
                directPreview = false
                fromDeck = false
                return .endPreview
            case .fanned, .preview:
                guard !ids.isEmpty else {
                    state = .collapsed
                    return .collapse
                }
                return .relayout
            case .collapsed:
                // The usual first run: the card is already idle when the hub's list lands.
                guard canFan else { return .none }
                state = .fanned
                return .fanOut
            }

        case .closePreview:
            guard case .preview(let current) = state else { return .none }
            state = previewHome(for: current)
            directPreview = false
            return .endPreview

        case .spaceDismissed:
            state = .collapsed
            suppressed = false
            directPreview = false
            fromDeck = false
            deskReady = false
            return .none

        case .unsuppress:
            suppressed = false
            return .none
        }
    }

    /// Where a preview goes when it closes: back onto its **raised** deck slot if that is where it came
    /// from (V3-2a H6 — not into the card, which is where V3-1's hand-card preview went), otherwise the old
    /// rule (into the card for a direct preview, onto the arc for one opened from the gallery).
    private mutating func previewHome(for id: String) -> NoteFanState {
        guard fromDeck else { return directPreview ? .collapsed : .fanned }
        fromDeck = false
        return .deck(raised: id)
    }
}
