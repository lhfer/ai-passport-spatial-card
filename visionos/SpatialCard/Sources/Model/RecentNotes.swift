import Foundation

/// One recent Xiaohongshu note, exactly as the hub's `GET /api/notes` hands it over
/// (`docs/protocol.md` → "Hub REST"). The app never scrapes anything itself: the list is already filtered
/// (hidden notes dropped, pinned moved to the end) and capped at ten.
struct RecentNote: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case normal, video }

    /// 24 lowercase hex characters.
    let id: String
    var title: String
    var likes: Int
    var pinned: Bool
    var type: Kind
    /// **Relative** on the hub (`/api/notes/<id>/cover`), the name of a bundled file in the `--fake-notes`
    /// set, `nil` when the note has no cover. `AppModel.coverURL(for:)` resolves it.
    var coverURL: String?
    /// Absolute xiaohongshu.com link carrying the `xsec_token` — what 「在小红书打开」 opens.
    var url: String?
    /// Always `null` today; kept so a hub that starts sending it does not break the decode.
    var publishedAt: String?

    /// The firmware's number style (`CardStats.compact`): `1825`, `1.2万`. No commas.
    var likesLabel: String { CardStats.compact(likes) }
    /// What the device's bottom strip shows while this note is previewed.
    var stripText: String { "♥" + likesLabel }
    var link: URL? { url.flatMap { URL(string: $0) } }

    init(id: String, title: String, likes: Int, pinned: Bool = false, type: Kind = .normal,
         coverURL: String? = nil, url: String? = nil, publishedAt: String? = nil) {
        self.id = id
        self.title = title
        self.likes = likes
        self.pinned = pinned
        self.type = type
        self.coverURL = coverURL
        self.url = url
        self.publishedAt = publishedAt
    }

    /// Lenient on purpose: a note whose `type` is a word this build has never heard of is still a note.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try c.decodeIfPresent(String.self, forKey: .title) ?? "")
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        let rawType = (try? c.decodeIfPresent(String.self, forKey: .type)) ?? nil
        type = rawType.flatMap(Kind.init(rawValue:)) ?? .normal
        coverURL = try c.decodeIfPresent(String.self, forKey: .coverURL)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        publishedAt = try c.decodeIfPresent(String.self, forKey: .publishedAt)
    }
}

/// The whole `GET /api/notes` body. `rev` is the hub's list revision: it only moves when the normalised list
/// really changed, which is what the `/vp` hint frame announces (rev 0 = the hub has never scraped).
struct RecentNotesPayload: Codable, Equatable {
    var rev: Int
    var updatedAt: String?
    var count: Int?
    var notes: [RecentNote]

    static let limit = 10
    static let empty = RecentNotesPayload(rev: 0, updatedAt: nil, count: 0, notes: [])

    /// What the fan is allowed to show: real ids only, de-duplicated, titles cut to 80 code points, ten at most.
    /// The hub does all of this already — this is the app refusing to lay out something it cannot lay out.
    var sanitized: RecentNotesPayload {
        var seen = Set<String>()
        var kept: [RecentNote] = []
        for var note in notes where !note.id.isEmpty && seen.insert(note.id).inserted {
            if note.title.count > 80 { note.title = String(note.title.prefix(80)) }
            kept.append(note)
            if kept.count == RecentNotesPayload.limit { break }
        }
        return RecentNotesPayload(rev: rev, updatedAt: updatedAt, count: kept.count, notes: kept)
    }

    static func decode(_ data: Data) -> RecentNotesPayload? {
        guard let payload = try? JSONDecoder().decode(RecentNotesPayload.self, from: data) else { return nil }
        return payload.sanitized
    }

    /// `--fake-notes <path>` (absolute, or the name of a file bundled from `Tools/`), and the optional
    /// `Resources/notes.json` seed that lets the fan exist before any hub answers.
    static func load(path: String, bundle: Bundle = .main) -> RecentNotesPayload? {
        guard let url = ScriptFile.url(path, bundle: bundle), let data = try? Data(contentsOf: url) else { return nil }
        guard let payload = decode(data) else {
            print("[notes] \(url.lastPathComponent) is not a /api/notes payload")
            return nil
        }
        return payload
    }

    static func seed(bundle: Bundle = .main) -> RecentNotesPayload? {
        guard let url = bundle.url(forResource: "notes", withExtension: "json"), let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }
}
