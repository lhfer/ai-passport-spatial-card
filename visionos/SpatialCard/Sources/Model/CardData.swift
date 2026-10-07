import Foundation

/// Card content, decoded from the bundled `card.json` (schema 2, the single source of truth shared with the
/// hub and the firmware). The old flat schema (`name` / `stats: [{value,label}]` at the top level) still decodes.
struct CardData: Equatable {
    struct Link: Codable, Equatable {
        var label: String
        var url: String
    }

    struct ThemeEntry: Codable, Equatable {
        var id: String
        var label: String
        var world: String?
    }

    struct Device: Codable, Equatable {
        var model: String?
        var screenPx: [Int]?
        var activeAreaMm: [Float]?
        var thicknessMm: Float?
        var cornerRadiusPx: Int?
        var dynamicStripPx: Int?
    }

    var name: String
    var handle: String
    var location: String
    var tags: [String]
    var bullets: [String]
    var avatar: String
    var links: [Link]
    var xhsUserID: String?
    var stats: CardStats
    var themes: [ThemeEntry]
    var device: Device?

    /// SF Symbols used for the tag pills and the orbiting chips, in tag order (sparkle / code / game controller).
    static let tagSymbols = ["sparkles", "chevron.left.forwardslash.chevron.right", "gamecontroller.fill"]

    static func symbol(forTagAt index: Int) -> String {
        tagSymbols[index % tagSymbols.count]
    }

    var primaryLink: Link? { links.first }

    var primaryLinkURL: URL? {
        guard let link = primaryLink else { return nil }
        return URL(string: link.url)
    }

    /// Device thickness in meters (`device.thicknessMm`), used when no desk plane is available.
    var deviceThickness: Float { (device?.thicknessMm ?? 8.5) / 1000 }

    /// Loads `card.json` from the app bundle, falling back to built-in content if the file is missing or malformed.
    static func loadFromBundle() -> CardData {
        guard let url = Bundle.main.url(forResource: "card", withExtension: "json"),
              let data = try? Data(contentsOf: url) else {
            return .fallback
        }
        return decode(data) ?? .fallback
    }

    /// Schema 2 first, then the legacy flat shape.
    static func decode(_ data: Data) -> CardData? {
        let decoder = JSONDecoder()
        if let v2 = try? decoder.decode(SchemaV2.self, from: data) {
            return CardData(v2)
        }
        if let legacy = try? decoder.decode(Legacy.self, from: data) {
            return CardData(legacy)
        }
        return nil
    }

    static let fallback = CardData(
        name: "星际访客",
        handle: "@SpatialExplorer",
        location: "Hello, World",
        tags: ["AI 工具", "Vibe Coding", "小游戏"],
        bullets: ["把创意带进空间", "分享你的发现", "做一点有趣的东西", "从一张名片开始"],
        avatar: "avatar.png",
        links: [Link(label: "小红书主页", url: "https://example.com")],
        xhsUserID: nil,
        stats: CardStats(followers: 1024, likes: 8192, notes: 0, delta: 0, updatedAt: Date(timeIntervalSince1970: 1_758_153_600), source: "demo"),
        themes: [ThemeEntry(id: "base", label: "名片", world: nil), ThemeEntry(id: "neon-city", label: "霓虹雨城", world: "neon-city"),
                 ThemeEntry(id: "data-nebula", label: "数据星云", world: "data-nebula")],
        device: Device(model: "FoloToy AI Passport", screenPx: [240, 320], activeAreaMm: [36.72, 48.96], thicknessMm: 8.5, cornerRadiusPx: 30, dynamicStripPx: 48)
    )

    // MARK: - Wire shapes

    private struct SchemaV2: Decodable {
        struct Profile: Decodable {
            var name: String
            var handle: String
            var location: String?
            var tags: [String]?
            var bullets: [String]?
            var avatar: String?
        }
        struct Stats: Decodable {
            var followers: Int
            var likes: Int?
            var notes: Int?
            var delta: Int?
            var updatedAt: String?
            var source: String?
        }
        struct XHS: Decodable { var userId: String? }
        var schema: Int?
        var profile: Profile
        var links: [Link]?
        var xhs: XHS?
        var stats: Stats?
        var themes: [ThemeEntry]?
        var device: Device?
    }

    private struct Legacy: Decodable {
        struct Stat: Decodable { var value: String; var label: String }
        var name: String
        var handle: String
        var location: String?
        var tags: [String]?
        var bullets: [String]?
        var stats: [Stat]?
        var links: [Link]?
    }

    private init(_ v2: SchemaV2) {
        name = v2.profile.name
        handle = v2.profile.handle
        location = v2.profile.location ?? ""
        tags = v2.profile.tags ?? []
        bullets = v2.profile.bullets ?? []
        avatar = v2.profile.avatar ?? "avatar.png"
        links = v2.links ?? []
        xhsUserID = v2.xhs?.userId
        let updated = v2.stats?.updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) } ?? Date(timeIntervalSince1970: 0)
        stats = CardStats(followers: v2.stats?.followers ?? 0, likes: v2.stats?.likes ?? 0, notes: v2.stats?.notes ?? 0,
                          delta: v2.stats?.delta ?? 0, updatedAt: updated, source: v2.stats?.source ?? "card.json")
        themes = v2.themes ?? CardData.fallback.themes
        device = v2.device
    }

    private init(_ legacy: Legacy) {
        name = legacy.name
        handle = legacy.handle
        location = legacy.location ?? ""
        tags = legacy.tags ?? []
        bullets = legacy.bullets ?? []
        avatar = "avatar.png"
        links = legacy.links ?? []
        xhsUserID = nil
        // Old stats were display strings ("4313" / "4.4万"); take the digits when they parse, else the seed.
        func number(_ s: String?) -> Int? {
            guard let s else { return nil }
            if let v = Int(s.filter(\.isNumber)), !s.contains("万"), !s.contains("亿") { return v }
            if s.contains("万"), let v = Double(s.replacingOccurrences(of: "万", with: "")) { return Int(v * 10_000) }
            return nil
        }
        let followers = number(legacy.stats?.first { $0.label.contains("粉丝") }?.value) ?? CardData.fallback.stats.followers
        let likes = number(legacy.stats?.first { $0.label.contains("赞") }?.value) ?? CardData.fallback.stats.likes
        stats = CardStats(followers: followers, likes: likes, notes: 0, delta: 0, updatedAt: Date(timeIntervalSince1970: 0), source: "card.json(legacy)")
        themes = CardData.fallback.themes
        device = nil
    }

    init(name: String, handle: String, location: String, tags: [String], bullets: [String], avatar: String, links: [Link],
         xhsUserID: String?, stats: CardStats, themes: [ThemeEntry], device: Device?) {
        self.name = name
        self.handle = handle
        self.location = location
        self.tags = tags
        self.bullets = bullets
        self.avatar = avatar
        self.links = links
        self.xhsUserID = xhsUserID
        self.stats = stats
        self.themes = themes
        self.device = device
    }
}
