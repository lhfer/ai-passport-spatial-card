import Foundation

/// One page of the hand-held card (v3 H2 §8).
///
/// On the desk the passport's UP / DOWN buttons walk the world coins on the arc. In the hand there is no arc —
/// the desk is faded out and the card *is* the display — so the same two buttons page through what the card
/// can show: the profile it always showed, then one page per world, then the three most recent notes.
enum HandPage: Equatable {
    case profile
    case world(String)
    case note(String)

    /// What `[hand] page → …` prints. Note ids are 24 hex characters; six is what every other note line uses.
    var label: String {
        switch self {
        case .profile: return "profile"
        case .world(let id): return id
        case .note(let id): return "note \(id.prefix(6))"
        }
    }

    var isProfile: Bool { self == .profile }
}

/// The ring UP / DOWN walk, and the rules that keep it valid while the world list and the note list change
/// underneath it (the hub's `/api/notes` answer lands seconds after the space opens, and can land *again*).
///
/// One ring, wrapping both ways: profile → each world in coin order → the three latest notes → profile.
/// Pure value type (no RealityKit, no AppModel), so `HandPagerTests` drives the whole ring deterministically.
struct HandPager: Equatable {
    /// How many of the recent notes get a page. Three is what fits the ring without turning it into a list.
    static let noteCount = 3

    /// **V3-2a H3**: this pager drives the hand *deck* rather than the card's own pages, so the ring is the
    /// deck's — five notes, and the two worlds at the two **ends** of the fan (neon → notes → nebula)
    /// instead of both in front of them. The hover form and `--deck off` keep the ring above.
    var deck = false

    private(set) var page: HandPage = .profile
    private(set) var worlds: [String] = []
    private(set) var notes: [String] = []

    init() {}

    /// Every page in ring order. Always at least `[.profile]`, so the pager is never empty.
    var pages: [HandPage] {
        deck ? HandDeckLayout.pages(worlds: worlds, notes: notes)
             : [.profile] + worlds.map(HandPage.world) + notes.map(HandPage.note)
    }

    var index: Int { pages.firstIndex(of: page) ?? 0 }
    var count: Int { pages.count }

    /// The world / note lists have changed. The current page survives if it still exists, otherwise the pager
    /// falls back to the profile — a page for a note the hub has dropped would render an empty frame.
    mutating func sync(worlds: [String], notes: [String]) {
        self.worlds = worlds
        self.notes = Array(notes.prefix(deck ? HandDeckLayout.maxNotes : HandPager.noteCount))
        if !pages.contains(page) { page = .profile }
    }

    /// DOWN = `+1` (the next page), UP = `-1`. Wraps both ways. Returns the new page, or nil when the pager has
    /// nowhere to go (no worlds and no notes — one page is not a ring).
    @discardableResult
    mutating func step(_ delta: Int) -> HandPage? {
        let all = pages
        guard all.count > 1 else { return nil }
        let next = ((index + delta) % all.count + all.count) % all.count
        page = all[next]
        return page
    }

    /// **V3-4 §2(b).** Put the ring on a page without walking to it. Paging *inside* a preview moves the
    /// deck's idea of what is raised straight to the note the wearer is now reading, and the next UP / DOWN
    /// has to carry on from there rather than from wherever the ring was left standing.
    @discardableResult
    mutating func jump(to page: HandPage) -> Bool {
        guard pages.contains(page) else { return false }
        self.page = page
        return true
    }

    /// Back to the profile: the card settling on the desk, folding away, or going into a world all end the
    /// pager — it is a thing the wearer does while holding the passport, not a mode they can leave behind.
    mutating func reset() { page = .profile }
}
