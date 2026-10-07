import Foundation

/// Follower / like / note counts shown on the glass card and handed to the worlds. Seeded from `card.json`,
/// overwritten by the device's `hello` / `stats` messages (BLE) — newest `updatedAt` wins.
struct CardStats: Codable, Equatable {
    var followers: Int
    var likes: Int
    var notes: Int
    /// Net follower gain since the previous sample (≥ 0).
    var delta: Int
    var updatedAt: Date
    var source: String

    static let zero = CardStats(followers: 0, likes: 0, notes: 0, delta: 0, updatedAt: .distantPast, source: "none")

    /// `stats` object of the device protocol (`ts` = Unix seconds).
    init(followers: Int, likes: Int, notes: Int, delta: Int = 0, ts: TimeInterval, source: String) {
        self.followers = followers
        self.likes = likes
        self.notes = notes
        self.delta = delta
        self.updatedAt = Date(timeIntervalSince1970: ts)
        self.source = source
    }

    init(followers: Int, likes: Int, notes: Int, delta: Int, updatedAt: Date, source: String) {
        self.followers = followers
        self.likes = likes
        self.notes = notes
        self.delta = delta
        self.updatedAt = updatedAt
        self.source = source
    }

    /// Unix seconds, as the device protocol carries it.
    var ts: Int { Int(updatedAt.timeIntervalSince1970) }

    /// `true` when `other` is at least as new as this sample (the device de-duplicates by `ts` the same way).
    func shouldAccept(_ other: CardStats) -> Bool {
        other.updatedAt >= updatedAt
    }

    /// The firmware's number style: plain digits below 10 000, one decimal *truncated* with 万 at or above
    /// (44 990 → "4.4万"). Mirror it wherever a count is not shown through `formatted()`.
    static func compact(_ value: Int) -> String {
        guard value >= 10_000 else { return String(value) }
        let tenths = value / 1_000            // truncates
        return "\(tenths / 10).\(tenths % 10)万"
    }
}
