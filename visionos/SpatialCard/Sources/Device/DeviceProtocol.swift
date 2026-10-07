import Foundation

/// Wire format of `docs/protocol.md` (v1): one JSON object per line, `t` is the message type. Inbound
/// (device → Vision Pro over BLE TX) is `DeviceMessage`, outbound (Vision Pro → device over BLE RX) is
/// `DeviceCommand`. Unknown `t` values decode as `.unknown` and are ignored (a real device would get
/// `ack ok:false err:"unknown"` for the opposite direction).

/// A loosely typed JSON scalar (`cmd.arg` may be a string or a number).
enum JSONValue: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .null: return nil
        }
    }
}

/// The `stats` object, identical on every link (`ts` = Unix seconds).
struct DeviceStats: Codable, Equatable {
    var followers: Int
    var likes: Int
    var notes: Int
    var delta: Int
    var ts: Int

    init(followers: Int, likes: Int, notes: Int, delta: Int, ts: Int) {
        self.followers = followers
        self.likes = likes
        self.notes = notes
        self.delta = delta
        self.ts = ts
    }

    init(_ stats: CardStats) {
        self.init(followers: stats.followers, likes: stats.likes, notes: stats.notes, delta: stats.delta, ts: stats.ts)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        followers = try c.decode(Int.self, forKey: .followers)
        likes = try c.decodeIfPresent(Int.self, forKey: .likes) ?? 0
        notes = try c.decodeIfPresent(Int.self, forKey: .notes) ?? 0
        delta = try c.decodeIfPresent(Int.self, forKey: .delta) ?? 0
        ts = try c.decodeIfPresent(Int.self, forKey: .ts) ?? 0
    }

    /// `source` names the link the sample arrived on: `device` (BLE) or `hub` (the `/vp` WebSocket).
    func cardStats(source: String = "device") -> CardStats {
        CardStats(followers: followers, likes: likes, notes: notes, delta: delta, ts: TimeInterval(ts), source: source)
    }
}

// MARK: - Inbound

enum DeviceMessage: Equatable {
    enum Button: String, Codable { case up, down, ok }
    enum ButtonEvent: String, Codable { case click, long }

    struct Hello: Codable, Equatable {
        struct Battery: Codable, Equatable { var soc: Int?; var mv: Int? }
        struct BLE: Codable, Equatable { var connected: Bool? }
        var fw: String?
        var boot: Int?
        var mode: String?
        var theme: String?
        var stats: DeviceStats?
        var battery: Battery?
        var ble: BLE?
        var heap: Int?
        /// Backlight percentage actually in effect (`docs/protocol.md`); only the `[gate] Σ bl=` field reads it.
        var backlight: Int?
        /// Active-area width the firmware was built with (mm); checked against `passport-manifest.json`.
        var screenWidthMm: Float?
    }

    case hello(Hello)
    case button(Button, ButtonEvent)
    case willChange(id: String?, kind: String?, theme: String?, region: [Int]?)
    case changed(id: String?, theme: String?)
    case stats(DeviceStats)
    case celebrate(delta: Int, followers: Int?)
    case cmd(c: String, arg: JSONValue?)
    case battery(soc: Int?, mv: Int?, usb: Bool?, backlight: Int?)
    case ack(id: String?, ok: Bool, err: String?, theme: String?)
    case unknown(t: String)

    var typeName: String {
        switch self {
        case .hello: return "hello"
        case .button: return "button"
        case .willChange: return "will_change"
        case .changed: return "changed"
        case .stats: return "stats"
        case .celebrate: return "celebrate"
        case .cmd: return "cmd"
        case .battery: return "battery"
        case .ack: return "ack"
        case .unknown(let t): return t
        }
    }

    /// Decodes one line (a JSON object); nil if the line is not JSON or has no `t`.
    static func parse(line: String) -> DeviceMessage? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(DeviceMessage.self, from: data)
    }
}

extension DeviceMessage: Decodable {
    private enum Keys: String, CodingKey {
        case t, id, btn, ev, kind, theme, region, delta, followers, likes, notes, ts, c, arg, soc, mv, usb, ok, err
        case fw, boot, mode, stats, battery, ble, heap, backlight
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let t = try c.decode(String.self, forKey: .t)
        switch t {
        case "hello":
            self = .hello(try Hello(from: decoder))
        case "button":
            self = .button(try c.decode(Button.self, forKey: .btn), try c.decodeIfPresent(ButtonEvent.self, forKey: .ev) ?? .click)
        case "will_change":
            self = .willChange(id: try c.decodeIfPresent(String.self, forKey: .id), kind: try c.decodeIfPresent(String.self, forKey: .kind),
                               theme: try c.decodeIfPresent(String.self, forKey: .theme), region: try c.decodeIfPresent([Int].self, forKey: .region))
        case "changed":
            self = .changed(id: try c.decodeIfPresent(String.self, forKey: .id), theme: try c.decodeIfPresent(String.self, forKey: .theme))
        case "stats":
            self = .stats(try DeviceStats(from: decoder))
        case "celebrate":
            self = .celebrate(delta: try c.decodeIfPresent(Int.self, forKey: .delta) ?? 1, followers: try c.decodeIfPresent(Int.self, forKey: .followers))
        case "cmd":
            self = .cmd(c: try c.decode(String.self, forKey: .c), arg: try c.decodeIfPresent(JSONValue.self, forKey: .arg))
        case "battery":
            self = .battery(soc: try c.decodeIfPresent(Int.self, forKey: .soc), mv: try c.decodeIfPresent(Int.self, forKey: .mv),
                            usb: try c.decodeIfPresent(Bool.self, forKey: .usb),
                            backlight: try c.decodeIfPresent(Int.self, forKey: .backlight))
        case "ack":
            self = .ack(id: try c.decodeIfPresent(String.self, forKey: .id), ok: try c.decodeIfPresent(Bool.self, forKey: .ok) ?? true,
                        err: try c.decodeIfPresent(String.self, forKey: .err), theme: try c.decodeIfPresent(String.self, forKey: .theme))
        default:
            self = .unknown(t: t)
        }
    }
}

// MARK: - Outbound

enum DeviceCommand: Equatable {
    enum Mode: String, Codable { case idle, ar }

    case setMode(id: String, mode: Mode)
    case setTheme(id: String, theme: String)
    case ack(id: String, ok: Bool, err: String?)
    case stats(id: String, DeviceStats)
    case celebrate(id: String, delta: Int)
    case playCue(id: String, cue: String)
    /// Bottom-strip override (工作包 D): `text` = what the strip shows, no `text` = restore the follower count.
    case strip(id: String, text: String?)
    /// **V3-2a2 S2** (`docs/protocol.md` 「LCD 像素」, new in fw 0.2.0): the real screen sweeps a white bar
    /// of its own while the recognition scan's virtual band crosses it — the one piece of evidence that the
    /// magic comes out of *this* device. `kind` is `sweep` (a 240 × 24 px bar running up the screen) or
    /// `flash` (the whole screen). `ms` ≤ 1000. It does **not** go through `handshake_begin`: the redraw is
    /// the point, and the object tracker is looking at the shell, not at the pixels.
    case glow(id: String, ms: Int, kind: String)
    /// **v4 B2** (`docs/protocol.md` 「backlight」): in AR mode the level for this AR session — a button press does not
    /// clear it, `set_mode` and a BLE edge do, so it is sent *after* `set_mode ar`. 100 = direct current.
    case backlight(id: String, percent: Int)
    case ping(id: String)

    var typeName: String {
        switch self {
        case .setMode: return "set_mode"
        case .setTheme: return "set_theme"
        case .ack: return "ack"
        case .stats: return "stats"
        case .celebrate: return "celebrate"
        case .playCue: return "play_cue"
        case .strip: return "strip"
        case .glow: return "glow"
        case .backlight: return "backlight"
        case .ping: return "ping"
        }
    }

    var id: String {
        switch self {
        case .setMode(let id, _), .setTheme(let id, _), .ack(let id, _, _), .stats(let id, _), .celebrate(let id, _),
             .playCue(let id, _), .strip(let id, _), .glow(let id, _, _), .backlight(let id, _), .ping(let id):
            return id
        }
    }

    /// **The fake link's ack rule** (`FakeDeviceLink`): how long the simulator's stand-in device takes to
    /// answer this command with a plain `ack`, or nil when the command has a handshake of its own. It lives
    /// here, next to the wire format, so `DeviceProtocolTests` can check it without CoreBluetooth.
    var fakeAckDelayMilliseconds: Int? {
        switch self {
        // Both of these answer with `will_change` / `changed` around their ack — see `FakeDeviceLink.send`.
        case .setTheme, .strip: return nil
        case .ack: return nil
        // The firmware repaints the top layer and answers; 80 ms is what the trial round-trips at.
        case .glow: return 80
        default: return 40
        }
    }

    /// One JSON line (with the trailing `\n`), ≤ 512 bytes by construction.
    var line: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}\n" }
        return text + "\n"
    }
}

extension DeviceCommand: Encodable {
    private enum Keys: String, CodingKey {
        case t, id, mode, theme, ok, err, followers, likes, notes, delta, ts, cue, text, ms, kind, percent
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(typeName, forKey: .t)
        try c.encode(id, forKey: .id)
        switch self {
        case .setMode(_, let mode):
            try c.encode(mode.rawValue, forKey: .mode)
        case .setTheme(_, let theme):
            try c.encode(theme, forKey: .theme)
        case .ack(_, let ok, let err):
            try c.encode(ok, forKey: .ok)
            if let err { try c.encode(err, forKey: .err) }
        case .stats(_, let s):
            try c.encode(s.followers, forKey: .followers)
            try c.encode(s.likes, forKey: .likes)
            try c.encode(s.notes, forKey: .notes)
            try c.encode(s.delta, forKey: .delta)
            try c.encode(s.ts, forKey: .ts)
        case .celebrate(_, let delta):
            try c.encode(delta, forKey: .delta)
        case .playCue(_, let cue):
            try c.encode(cue, forKey: .cue)
        case .strip(_, let text):
            // A `strip` without `text` is the restore, so the key is left out rather than sent as null.
            if let text { try c.encode(text, forKey: .text) }
        case .glow(_, let ms, let kind):
            try c.encode(min(1000, max(1, ms)), forKey: .ms)
            try c.encode(kind, forKey: .kind)
        case .backlight(_, let percent):
            // The firmware answers anything outside 0–100 with `err:"percent"`; it is clamped here instead.
            try c.encode(min(100, max(0, percent)), forKey: .percent)
        case .ping:
            break
        }
    }
}

/// Monotonic command ids (`v1`, `v2`, …).
struct DeviceCommandIDs {
    private var next = 1
    mutating func make() -> String {
        defer { next += 1 }
        return "v\(next)"
    }
}

// MARK: - Bottom strip (工作包 D 设备联动)

/// The device's bottom strip (`[0, 272, 240, 48]`) while a note is previewed: `{"t":"strip","text":"♥1825"}`,
/// or no `text` at all to give the follower count back (`docs/protocol.md` → 「底条覆盖」).
///
/// The firmware's strip font has 19 glyphs and answers anything else with `ack ok:false err:"glyph"`, so the
/// text is checked here, before it is sent.
enum StripText {
    /// `0123456789.+-k万▲▼♥` and the space. **No comma** — same rule as `CardStats.compact`.
    static let glyphs = Set("0123456789.+-k万▲▼♥ ")
    static let maxLength = 12

    static func isValid(_ text: String) -> Bool {
        let count = text.count
        return count >= 1 && count <= maxLength && text.allSatisfy { glyphs.contains($0) }
    }

    /// `♥1825` / `♥1.2万` — the firmware's own number style.
    static func likes(_ likes: Int) -> String {
        "♥" + CardStats.compact(max(0, likes))
    }
}
