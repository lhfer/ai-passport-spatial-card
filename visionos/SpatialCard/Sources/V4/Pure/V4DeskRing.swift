import Foundation

extension V4 {
    /// **v4 B2 §2 — one button ring on the desk.**
    ///
    /// Round 1's desk had two things UP / DOWN could reach — the two world coins (`carousel → neon-city / data-nebula`,
    /// 22 presses) — and the ten notes in the gallery could only be opened with a pinch. The ring puts them on one loop:
    /// the gallery's notes in gallery order, then the two world coins, and round again. DOWN is the next item and UP the
    /// previous one (the hand deck's and v3's carousel's convention); from nothing, DOWN lands on the first note and UP
    /// on the last coin. OK opens the highlighted note or enters the highlighted world.
    ///
    /// A highlight is only something OK acts on for `window` seconds after the press that put it there — v3 H2 §4's
    /// rule for the coins, kept for the same reason: with every note on the ring, a highlight that never lapsed would
    /// mean OK could never fold the card on the desk again. The controller fades the highlight when it lapses, so what
    /// the wearer sees and what OK will do agree. The window is longer than v3's 5 s coin window because a note title
    /// takes longer to read than a world's name.
    struct DeskRing: Equatable {
        enum Item: Equatable {
            case note(String)
            case world(String)

            var noteID: String? {
                if case .note(let id) = self { return id }
                return nil
            }

            var worldID: String? {
                if case .world(let id) = self { return id }
                return nil
            }

            /// `note 6ab205` / `neon-city` — what `[desk] ring →` prints.
            var label: String {
                switch self {
                case .note(let id): return "note \(id.prefix(6))"
                case .world(let id): return id
                }
            }
        }

        /// How long a highlight stays actionable after the press that put it there (s).
        static let window: TimeInterval = 8

        private(set) var items: [Item] = []
        private(set) var index: Int?
        private(set) var highlightedAt: TimeInterval?

        init() {}

        /// The highlighted item, whatever its age.
        var highlighted: Item? { index.flatMap { items.indices.contains($0) ? items[$0] : nil } }

        /// The highlighted item if OK may still act on it at `time`.
        func current(at time: TimeInterval) -> Item? {
            guard let item = highlighted, let at = highlightedAt, time - at <= DeskRing.window else { return nil }
            return item
        }

        /// Has the highlight lapsed at `time` (there is one, and it is older than the window)?
        func hasLapsed(at time: TimeInterval) -> Bool {
            guard highlighted != nil, let at = highlightedAt else { return false }
            return time - at > DeskRing.window
        }

        /// The notes (gallery order) or the worlds changed. The highlight survives if its item is still on the ring.
        mutating func sync(notes: [String], worlds: [String]) {
            let kept = highlighted
            items = notes.map(Item.note) + worlds.map(Item.world)
            if let kept, let at = items.firstIndex(of: kept) {
                index = at
            } else {
                index = nil
                highlightedAt = nil
            }
        }

        /// DOWN = `+1`, UP = `-1`, wrapping both ways. From nothing, DOWN is the first item and UP the last.
        @discardableResult
        mutating func step(_ delta: Int, at time: TimeInterval) -> Item? {
            guard !items.isEmpty, delta != 0 else { return nil }
            let count = items.count
            let next: Int
            if let index {
                next = ((index + delta) % count + count) % count
            } else {
                next = delta > 0 ? 0 : count - 1
            }
            index = next
            highlightedAt = time
            return items[next]
        }

        /// Put the highlight on `item` without walking to it (a preview that closes leaves it on the note just read).
        @discardableResult
        mutating func jump(to item: Item, at time: TimeInterval) -> Bool {
            guard let at = items.firstIndex(of: item) else { return false }
            index = at
            highlightedAt = time
            return true
        }

        /// No highlight (the card left the desk, a world opened, the highlight lapsed).
        mutating func clear() {
            index = nil
            highlightedAt = nil
        }

        /// The note `delta` steps from `id` among the notes only, wrapping — what UP / DOWN page to inside a preview.
        func adjacentNote(to id: String, delta: Int) -> String? {
            let notes = items.compactMap(\.noteID)
            guard notes.count > 1, let at = notes.firstIndex(of: id) else { return nil }
            return notes[((at + delta) % notes.count + notes.count) % notes.count]
        }
    }
}
