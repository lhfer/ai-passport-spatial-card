import Foundation

/// One scripted frame, shared by `--fake-device` (BLE) and `--fake-hub` (WebSocket `/vp`).
struct ScriptEvent: Decodable {
    var atSeconds: Double
    var line: String
    /// The literal `NOW` inside a line = the current Unix time (so scripted `ts` beats the `card.json` seed).
    var resolvedLine: String { line.replacingOccurrences(of: "NOW", with: String(Int(Date().timeIntervalSince1970))) }
}

/// Where `--fake-device` / `--fake-hub` look for their script. An absolute path wins; anything else is
/// resolved **against the app bundle's resources**, because the app's working directory in the simulator /
/// on the headset is not the repo (a relative `Tools/x.json` would end up as `/Tools/x.json`). `Tools/*.json`
/// is copied into the bundle root by `project.yml`, so both `fake-device-events.json` and the repo-style
/// `Tools/fake-device-events.json` resolve.
enum ScriptFile {
    static func url(_ path: String, bundle: Bundle = .main) -> URL? {
        let manager = FileManager.default
        if manager.fileExists(atPath: (path as NSString).expandingTildeInPath) {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        if let resources = bundle.resourceURL {
            for candidate in [resources.appendingPathComponent(path),
                              resources.appendingPathComponent((path as NSString).lastPathComponent)]
            where manager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        print("[script] cannot find \(path) (pass an absolute path, or the name of a file bundled from Tools/)")
        return nil
    }

    /// Decodes a script file, sorted by time; `[]` (a silent link) when it is missing or invalid.
    static func events(_ url: URL?, log prefix: String) -> [ScriptEvent] {
        guard let url else { return [] }
        guard let data = try? Data(contentsOf: url) else {
            print("\(prefix): cannot read \(url.path)")
            return []
        }
        do {
            let events = try JSONDecoder().decode([ScriptEvent].self, from: data).sorted { $0.atSeconds < $1.atSeconds }
            print("\(prefix): \(events.count) scripted events from \(url.lastPathComponent)")
            return events
        } catch {
            print("\(prefix): script invalid: \(error)")
            return []
        }
    }
}

/// Scripted device for the simulator (`--fake-device <path>`): replays a JSON array of
/// `{"atSeconds": 1.5, "line": "{\"t\":\"button\",\"btn\":\"up\",\"ev\":\"click\"}"}` entries as if they had
/// arrived over BLE, reports `connected` at start, and answers `set_theme` with the real handshake
/// (`will_change` → `changed` → `ack`) so the gate's theme hold runs in the simulator too. The literal
/// `NOW` inside a line is replaced by the current Unix time (for `ts`). An empty array is a silent device.
///
/// **V3-2a2 S2**: `glow` is answered like `strip` is — a plain `ack` 80 ms later — so the simulator can show
/// the whole `[reveal] box scan …` → `[ble] fake send {"…":"glow"…}` → `[ble] glow acked in 0.08 s` chain.
@MainActor
final class FakeDeviceLink: DeviceLinking {
    let events: AsyncStream<DeviceEvent>
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    private(set) var isConnected = false
    private let script: [ScriptEvent]
    private var task: Task<Void, Never>?
    private var handshakeTask: Task<Void, Never>?
    /// Answer `set_theme` with `will_change` / `changed` / `ack` like the firmware does in AR mode.
    var simulatesHandshake = true
    /// Delay before `changed` follows `will_change` (the LVGL redraw takes ~100–300 ms).
    var redrawSeconds: Double = 0.35
    /// What the bottom strip currently shows (nil = the follower count): a `strip` with the same text is
    /// acknowledged without a repaint, exactly like the firmware.
    private var stripText: String?

    init(scriptURL: URL?) {
        var continuation: AsyncStream<DeviceEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        script = ScriptFile.events(scriptURL, log: "[ble] fake device")
    }

    func start() {
        guard task == nil else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self.isConnected = true
            print("[ble] fake connected")
            self.continuation?.yield(.connected(name: "SpatialCard-FAKE"))
            let start = Date()
            for event in self.script {
                let wait = event.atSeconds - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                guard !Task.isCancelled else { return }
                self.deliver(event.resolvedLine)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        handshakeTask?.cancel()
        isConnected = false
    }

    func rescan() {}

    func send(_ command: DeviceCommand) {
        print("[ble] fake send \(command.line.trimmingCharacters(in: .newlines))")
        guard simulatesHandshake else { return }
        switch command {
        case .setTheme(let id, let theme):
            handshakeTask?.cancel()
            handshakeTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .milliseconds(60))
                guard !Task.isCancelled else { return }
                self.deliver("{\"t\":\"will_change\",\"id\":\"w-\(id)\",\"kind\":\"theme\",\"theme\":\"\(theme)\",\"region\":[0,0,240,320]}")
                try? await Task.sleep(for: .milliseconds(Int(self.redrawSeconds * 1000)))
                guard !Task.isCancelled else { return }
                self.deliver("{\"t\":\"changed\",\"id\":\"w-\(id)\",\"theme\":\"\(theme)\"}")
                self.deliver("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":true,\"theme\":\"\(theme)\"}")
            }
        case .strip(let id, let text):
            // The firmware's own order (`docs/protocol.md` 「底条覆盖」): `will_change{kind:"stat"}` first, the
            // command's `ack` after the ≤ 300 ms wait for our answer, `changed` only once the flip has run —
            // and nothing but the `ack` when the strip already shows this text.
            let repaint = text != stripText
            stripText = text
            Task { @MainActor [weak self] in
                guard let self else { return }
                if repaint {
                    try? await Task.sleep(for: .milliseconds(30))
                    guard !Task.isCancelled else { return }
                    self.deliver("{\"t\":\"will_change\",\"id\":\"s-\(id)\",\"kind\":\"stat\",\"region\":[0,272,240,48]}")
                }
                try? await Task.sleep(for: .milliseconds(repaint ? 50 : 40))
                guard !Task.isCancelled else { return }
                self.deliver("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":true}")
                guard repaint else { return }
                try? await Task.sleep(for: .milliseconds(520))
                guard !Task.isCancelled else { return }
                self.deliver("{\"t\":\"changed\",\"id\":\"s-\(id)\"}")
            }
        default:
            // Everything with no handshake of its own — `ping`, `set_mode`, `play_cue`, `stats`,
            // `celebrate` and (V3-2a2 S2) `glow` — gets a plain ack after the delay the command itself
            // declares (`DeviceCommand.fakeAckDelayMilliseconds`, checked in `DeviceProtocolTests`).
            guard let delay = command.fakeAckDelayMilliseconds else { return }
            let id = command.id
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                self?.deliver("{\"t\":\"ack\",\"id\":\"\(id)\",\"ok\":true}")
            }
        }
    }

    private func deliver(_ line: String) {
        guard let message = DeviceMessage.parse(line: line) else {
            print("[ble] fake: unparsable line \(line)")
            return
        }
        print("[ble] fake recv \(line)")
        continuation?.yield(.message(message, raw: line))
    }
}
