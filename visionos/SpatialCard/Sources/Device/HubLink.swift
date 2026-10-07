import Foundation

/// Hub → Vision Pro link (`docs/protocol.md`, "Hub → Vision Pro（WebSocket /vp）", plan P1 "WS /vp").
///
/// While filming, the AI Passport may be unplugged from the Mac: nothing reaches the Vision Pro over the
/// device's USB → BLE path any more. The hub then broadcasts the same messages on `ws://<mac>.local:8787/vp`
/// (one-way, no ids, no acks) and the app treats them exactly like the BLE ones — and relays `stats` /
/// `celebrate` back down to the device over BLE when the device *is* linked, so the LCD count and the chime
/// stay in sync. Console prefix `[hub]`.

/// Connection state of a hub link.
enum HubState: String { case disconnected, connecting, connected }

/// What a hub link reports.
enum HubEvent {
    case connected(url: String)
    case disconnected(reason: String)
    case message(HubMessage, raw: String)
}

/// One `/vp` frame. `stats`, `celebrate` and `cmd` are byte-identical to the BLE messages, so the existing
/// `DeviceMessage` decoder handles them; `set_theme` only exists as a *command* (`DeviceCommand.setTheme`) in
/// the BLE protocol — inbound it has no `DeviceMessage` case, hence the extra one here.
enum HubMessage: Equatable {
    case device(DeviceMessage)
    case setTheme(String)
    /// Recent-notes **hint** (工作包 D): no note data, only the hub's list revision. Sent once per change,
    /// never on connect — the app pulls `GET /api/notes` itself when `rev` differs from the one it holds.
    case notes(rev: Int, count: Int)

    var typeName: String {
        switch self {
        case .device(let message): return message.typeName
        case .setTheme: return "set_theme"
        case .notes: return "notes"
        }
    }

    private struct SetTheme: Decodable { var t: String; var theme: String }
    private struct Notes: Decodable { var t: String; var rev: Int; var count: Int? }

    /// Decodes one frame (a single JSON object, no trailing newline); nil if it is not JSON or has no `t`.
    static func parse(frame: String) -> HubMessage? {
        let trimmed = frame.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return nil }
        if let theme = try? JSONDecoder().decode(SetTheme.self, from: data), theme.t == "set_theme" {
            return .setTheme(theme.theme)
        }
        // Before the `DeviceMessage` fallback: `notes` has no BLE counterpart and would decode as `.unknown`.
        if let notes = try? JSONDecoder().decode(Notes.self, from: data), notes.t == "notes" {
            return .notes(rev: notes.rev, count: notes.count ?? 0)
        }
        guard let message = DeviceMessage.parse(line: trimmed) else { return nil }
        return .device(message)
    }
}

/// A WebSocket link to the hub, or its scripted stand-in for the simulator.
@MainActor
protocol HubLinking: AnyObject {
    var events: AsyncStream<HubEvent> { get }
    var state: HubState { get }
    func start()
    func stop()
}

/// `URLSessionWebSocketTask` client for `/vp`: connects on space open, reconnects with a 1 / 2 / 4 / 8 s
/// backoff forever, pings every 20 s so a hub that went away is noticed, and parses one JSON object per text
/// frame. Delegate callbacks arrive on the main queue (`delegateQueue: .main`) and hop onto the main actor
/// with `assumeIsolated`, like `DeviceLink` does with CoreBluetooth.
@MainActor
final class HubLink: NSObject, HubLinking {
    /// Backoff cap; the first retry waits `initialBackoff`.
    static let initialBackoff: TimeInterval = 1
    static let maxBackoff: TimeInterval = 8
    static let pingInterval: TimeInterval = 20

    let url: URL
    let events: AsyncStream<HubEvent>
    private var continuation: AsyncStream<HubEvent>.Continuation?
    private(set) var state: HubState = .disconnected

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var backoff = HubLink.initialBackoff
    private var started = false

    init(url: URL) {
        self.url = url
        var continuation: AsyncStream<HubEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    /// The configured `/vp` URL: `--hub ws://host:8787/vp` wins, else `{"vpURL":"ws://…"}` in a bundled
    /// `hub.json`, else nil — no URL means the WebSocket link stays off (BLE only), which is the default.
    static func configuredURL(explicit: String?, bundle: Bundle = .main) -> URL? {
        if let explicit {
            guard let url = URL(string: explicit), url.scheme == "ws" || url.scheme == "wss", url.host != nil else {
                print("[hub] --hub \(explicit) is not a ws:// URL; hub link off")
                return nil
            }
            return url
        }
        guard let file = bundle.url(forResource: "hub", withExtension: "json"), let data = try? Data(contentsOf: file) else { return nil }
        struct Config: Decodable { var vpURL: String? }
        guard let text = (try? JSONDecoder().decode(Config.self, from: data))?.vpURL,
              let url = URL(string: text), url.scheme == "ws" || url.scheme == "wss", url.host != nil else {
            print("[hub] hub.json has no usable \"vpURL\"; hub link off")
            return nil
        }
        print("[hub] hub.json → \(url.absoluteString)")
        return url
    }

    func start() {
        guard !started else { return }
        started = true
        backoff = HubLink.initialBackoff
        connect()
    }

    func stop() {
        started = false
        reconnectTask?.cancel()
        reconnectTask = nil
        teardown()
        state = .disconnected
    }

    // MARK: - Connecting

    private func connect() {
        guard started, task == nil else { return }
        state = .connecting
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        // No custom `timeoutIntervalForRequest`: on a WebSocket task it keeps acting as an *idle* timeout, so
        // anything at or below `pingInterval` would drop a perfectly good socket during a quiet stretch of
        // filming. The default (60 s) is comfortably above the 20 s ping/pong that keeps the link warm.
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        print("[hub] connecting \(url.absoluteString)")
        task.resume()
        receiveTask = Task { @MainActor [weak self] in
            await self?.receiveLoop(task)
        }
    }

    /// Closes the socket and cancels its loops (the session holds the delegate until it is invalidated).
    private func teardown() {
        receiveTask?.cancel()
        receiveTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// The socket died (or never opened): report it once and retry with the backoff.
    fileprivate func fail(_ reason: String) {
        guard started, task != nil else { return }
        let wasConnected = state == .connected
        teardown()
        state = .disconnected
        if wasConnected {
            print("[hub] disconnected: \(reason)")
            continuation?.yield(.disconnected(reason: reason))
        }
        scheduleReconnect(reason)
    }

    private func scheduleReconnect(_ reason: String) {
        guard started, reconnectTask == nil else { return }
        let wait = backoff
        backoff = min(backoff * 2, HubLink.maxBackoff)
        print("[hub] reconnecting in \(Int(wait)) s (\(reason))")
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, !Task.isCancelled, self.started else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    fileprivate func opened() {
        guard started else { return }
        state = .connected
        backoff = HubLink.initialBackoff
        print("[hub] connected \(url.absoluteString)")
        continuation?.yield(.connected(url: url.absoluteString))
        startPings()
    }

    private func startPings() {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(HubLink.pingInterval))
                guard let self, !Task.isCancelled, self.state == .connected, let task = self.task else { return }
                task.sendPing { [weak self] error in
                    guard let error else { return }
                    Task { @MainActor [weak self] in self?.fail("ping failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    // MARK: - Receiving

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let frame = try await task.receive()
                guard !Task.isCancelled, self.task === task else { return }
                switch frame {
                case .string(let text): deliver(text)
                case .data(let data): deliver(String(decoding: data, as: UTF8.self))
                @unknown default: break
                }
            } catch {
                guard !Task.isCancelled, self.task === task else { return }
                fail(error.localizedDescription)
                return
            }
        }
    }

    /// One frame = one JSON object (the hub trims the protocol's trailing `\n`); tolerate several lines anyway.
    private func deliver(_ frame: String) {
        for line in frame.split(whereSeparator: \.isNewline) {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            guard let message = HubMessage.parse(frame: text) else {
                print("[hub] unparsable frame \(text)")
                continue
            }
            print("[hub] \(message.typeName) \(text)")
            continuation?.yield(.message(message, raw: text))
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension HubLink: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        MainActor.assumeIsolated {
            guard webSocketTask === task else { return }
            opened()
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                                didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        MainActor.assumeIsolated {
            guard webSocketTask === task else { return }
            fail("closed (code \(closeCode.rawValue))")
        }
    }

    nonisolated func urlSession(_ session: URLSession, task sessionTask: URLSessionTask, didCompleteWithError error: Error?) {
        MainActor.assumeIsolated {
            guard sessionTask === task else { return }
            fail(error?.localizedDescription ?? "socket ended")
        }
    }
}

/// Scripted hub for the simulator (`--fake-hub <path>`): replays `[{"atSeconds": 3, "line": "{…}"}]` frames as
/// if they had arrived on `/vp`, exactly like `--fake-device` does for BLE (`NOW` in a line = the current Unix
/// time, for `ts`). Nothing is sent back — `/vp` is one-way.
@MainActor
final class FakeHubLink: HubLinking {
    let events: AsyncStream<HubEvent>
    private var continuation: AsyncStream<HubEvent>.Continuation?
    private(set) var state: HubState = .disconnected
    private let script: [ScriptEvent]
    private let name: String
    private var task: Task<Void, Never>?

    init(scriptURL: URL?) {
        var continuation: AsyncStream<HubEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        name = scriptURL?.lastPathComponent ?? "?"
        script = ScriptFile.events(scriptURL, log: "[hub] fake hub")
    }

    func start() {
        guard task == nil else { return }
        state = .connecting
        task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self, !Task.isCancelled else { return }
            self.state = .connected
            print("[hub] connected fake://\(self.name)")
            self.continuation?.yield(.connected(url: "fake://\(self.name)"))
            let start = Date()
            for event in self.script {
                let wait = event.atSeconds - Date().timeIntervalSince(start)
                if wait > 0 { try? await Task.sleep(for: .milliseconds(Int(wait * 1000))) }
                guard !Task.isCancelled else { return }
                let line = event.resolvedLine
                guard let message = HubMessage.parse(frame: line) else {
                    print("[hub] fake: unparsable frame \(line)")
                    continue
                }
                print("[hub] \(message.typeName) \(line)")
                self.continuation?.yield(.message(message, raw: line))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        state = .disconnected
    }
}
