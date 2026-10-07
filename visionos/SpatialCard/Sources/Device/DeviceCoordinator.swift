import AVFoundation
import Foundation
import Observation

/// Owns the device link and turns its messages into app actions (plan §8 C3):
///
/// | event | action |
/// | --- | --- |
/// | connected (= `hello` received after subscribing) | `set_mode{ar}` (idempotent) + `set_theme` if the device shows another screen; world exit button hidden |
/// | disconnected ≥ 2 s | world exit button shown again |
/// | `hello` | stats (newest wins) → `AppModel.stats`; `theme` → tracker's expected reference image; `screenWidthMm` vs manifest |
/// | `button up/down click` · `button ok click` · `button ok long` | `AppModel.handleKey` → `V4.ButtonMap` (v4 B3, the table below); gate button hold (image source only) |
///
/// **The keys (v4 B3 §1)** — one rule set, no press unanswered, no single press that takes the card away:
///
/// | where | UP / DOWN | OK | long OK |
/// | --- | --- | --- | --- |
/// | world, fully inside | — | back to the desk | back to the desk |
/// | world, entering / exiting | — | ignored (logged) | ignored (logged) |
/// | preview open (desk or hand) | page | close | close |
/// | desk, a fresh highlight | move it (ring: notes, then the coins) | open the note / enter the world | collapse |
/// | desk, no highlight (also a lost card, `held`) | move it | = DOWN: the ring's first item | collapse |
/// | hand, a card raised | raise the next | open the note / enter the world | collapse |
/// | hand, profile | raise the next | = DOWN: slot 0 (neon-city's world card) | collapse |
/// | collapsed (the gold point) | — | summon: the full recognition again (`--v3-card`: v3's short scan) | — |
/// | arriving (a recognition holds the entrance) · pick-up fold · nothing seen | — | — | (pick-up fold: collapse) |
///
/// "—" = ignored, with the reason in the `[keys]` line. Collapse = the card goes into the device and becomes a gold
/// point beside its top edge; the passport face down for 0.8 s does the same. A pinch on the desk card and the desk's
/// 「笔记」 chip keep the note fan's toggle (`AppModel.toggleNotesFan`), which used to be long OK's.
/// | `will_change` | ack at once; `kind:theme` → `held(.theme)` unless the tracker is paused (inside a world) or the object tracker holds the pose |
/// | `changed` | end the theme hold, expect the new reference image |
/// | `stats` | `AppModel.stats` |
/// | `celebrate` | `AppModel.celebrate` (desk choreography or `worlds.celebrate`) |
/// | `cmd` | director: replay / hide / show / celebrate / theme / director / perf (v4 B4 §3.5) |
/// | `battery` | `AppModel.deviceBattery` + `CardTracker.deviceBacklight` (`[gate] Σ bl=`) |
///
/// It owns the hub link too (`HubLink`, plan P1 "WS /vp"): when the device is unplugged from the Mac the same
/// `stats` / `celebrate` / `set_theme` / `cmd` messages arrive over `ws://<mac>.local:8787/vp` instead, are
/// handled by the very same code below (`handle(_:from:)`), and `stats` / `celebrate` are relayed down to the
/// device over BLE when it is linked. Nothing is ever echoed back to the link it came from, and `set_theme` /
/// `cmd` are never relayed (see `applyHubTheme`).
@MainActor
@Observable
final class DeviceCoordinator {
    /// Which link a message came in on (the relay rules below are all "not back to the source").
    enum MessageSource { case device, hub }

    @ObservationIgnored weak var app: AppModel?
    /// `--theme-follow-worlds`: let a world change the *physical* screen again. Off by default — see
    /// `sendThemeUnlessLocked`.
    @ObservationIgnored var themeFollowsWorlds = false
    @ObservationIgnored private(set) var link: (any DeviceLinking)?
    private(set) var isConnected = false
    /// The card stood up before the device was linked: ring `connect` once the link comes up (工作包 A).
    private var pendingConnectCue = false
    @ObservationIgnored private(set) var hub: (any HubLinking)?
    /// State of the hub WebSocket (`disconnected` also while no `--hub` / `hub.json` URL is configured).
    private(set) var hubState: HubState = .disconnected
    /// Coin the carousel rests on (owned by the world engine; UP / DOWN move it, OK enters it).
    var carouselIndex: Int { app?.worlds.highlightedIndex ?? 0 }
    private(set) var lastMessage = ""
    /// Theme screen the device reported / acknowledged last (nil until its first `hello`).
    private(set) var deviceTheme: String?
    @ObservationIgnored private var ids = DeviceCommandIDs()
    @ObservationIgnored private var consumer: Task<Void, Never>?
    @ObservationIgnored private var hubConsumer: Task<Void, Never>?
    @ObservationIgnored private var exitButtonTask: Task<Void, Never>?
    /// Recent notes (工作包 D): the REST half of the hub, alive only for a real `HubLink` (a `--fake-hub`
    /// script has no host to ask).
    @ObservationIgnored private(set) var notesClient: HubNotesClient?
    @ObservationIgnored private var notesTask: Task<Void, Never>?
    /// The `strip` command waiting for its `ack`, and what the device's bottom strip shows because of us
    /// (nil = the follower count).
    @ObservationIgnored private var pendingStrip: (id: String, text: String, sentAt: Date)?
    @ObservationIgnored private var stripWatchdog: Task<Void, Never>?
    @ObservationIgnored private(set) var stripOverride: String?
    /// **V3-2a2 S2.** `--glow on|off`.
    @ObservationIgnored var glowEnabled = true
    /// The firmware version the device reported in its `hello` (`glow` is new in 0.2.0).
    @ObservationIgnored private(set) var firmwareVersion: String?
    /// The device answered a `glow` with `ok:false err:"unknown"`: it is an older build, so nothing is sent
    /// for the rest of the session and the reason is logged exactly once.
    @ObservationIgnored private var glowUnsupported = false
    /// The `glow` waiting for its ack.
    @ObservationIgnored private var pendingGlow: (id: String, sentAt: Date)?
    /// **v4 B2** `--ar-backlight 100|85|keep` (default 100): the AR session's backlight, sent after `set_mode ar` on
    /// every link-up (see `V4.ARBacklight` for why, and for what 100 % does to the key blink).
    @ObservationIgnored var arBacklight: V4.ARBacklight = .default
    /// The `backlight` waiting for its ack.
    @ObservationIgnored private var pendingBacklight: (id: String, percent: Int, sentAt: Date)?
    @ObservationIgnored private let speech = AVSpeechSynthesizer()
    /// Voice for `speak`, resolved **off the main actor** exactly once (see `resolveVoice`); nil = system default.
    @ObservationIgnored private var voice: AVSpeechSynthesisVoice?
    @ObservationIgnored private var voiceRequested = false

    static let exitButtonReturnDelay: Double = 2
    /// Hints arrive one per change, but a burst of them (a scrape that moves several notes) must cost one GET.
    static let notesCoalesce: Double = 0.5
    /// After this long without an `ack` the strip command is assumed lost (the device keeps its own watchdog).
    static let stripAckTimeout: Double = 1.5

    /// Called on every space open; both links have their own guard, so reopening is a no-op for an existing one.
    func start() {
        startHub()
        startDevice()
        startFakeNotes()
    }

    /// The list the hub would have served, from a file: `--fake-notes <path>` (simulator), else the optional
    /// `Resources/notes.json` seed — the fan then exists before, or entirely without, a hub. Once per space open,
    /// and never over a list the hub has already delivered.
    private func startFakeNotes() {
        guard let app, app.recentNotes.isEmpty else { return }
        if let path = app.fakeNotesPath {
            guard let payload = RecentNotesPayload.load(path: path) else {
                return print("[notes] --fake-notes \(path): no usable payload")
            }
            return app.applyNotes(payload, source: "fake")
        }
        guard let seed = RecentNotesPayload.seed() else { return }
        app.applyNotes(seed, source: "notes.json seed")
    }

    private func startDevice() {
        guard let app, link == nil else { return }
        let link: any DeviceLinking
        if let path = app.fakeDevicePath {
            link = FakeDeviceLink(scriptURL: ScriptFile.url(path))
        } else if app.noBLE {
            print("[ble] disabled (--no-ble)")
            return
        } else {
            link = DeviceLink()
        }
        self.link = link
        consumer = Task { @MainActor [weak self] in
            for await event in link.events {
                guard let self else { return }
                self.handle(event)
            }
        }
        link.start()
    }

    /// `--fake-hub <path>` wins over `--hub <url>` / `hub.json`; without any of them the WebSocket stays off
    /// (BLE only). Independent of `--no-ble`: the hub link is exactly what carries the show when there is no USB.
    private func startHub() {
        guard let app, hub == nil else { return }
        let hub: any HubLinking
        if let path = app.fakeHubPath {
            guard let url = ScriptFile.url(path) else { return }
            hub = FakeHubLink(scriptURL: url)
        } else if let url = HubLink.configuredURL(explicit: app.hubURLString) {
            hub = HubLink(url: url)
        } else {
            return
        }
        self.hub = hub
        if let link = hub as? HubLink { notesClient = HubNotesClient(hubURL: link.url) }
        hubConsumer = Task { @MainActor [weak self] in
            for await event in hub.events {
                guard let self else { return }
                self.handle(hub: event)
            }
        }
        hub.start()
    }

    func stop() {
        consumer?.cancel()
        consumer = nil
        link?.stop()
        link = nil
        isConnected = false
        hubConsumer?.cancel()
        hubConsumer = nil
        hub?.stop()
        hub = nil
        hubState = .disconnected
        notesTask?.cancel()
        notesTask = nil
        notesClient = nil
        stripWatchdog?.cancel()
        stripWatchdog = nil
        pendingStrip = nil
        stripOverride = nil
    }

    func rescan() {
        link?.rescan()
    }

    // MARK: - Sending

    func sendTheme(_ id: String) {
        link?.send(.setTheme(id: ids.make(), theme: id))
    }

    /// **The device screen is locked to the base theme.** The `.referenceobject` was scanned with the base screen
    /// showing, so every automatic `set_theme` — a world opening, a reconnect inside a world — would change the
    /// very thing the object tracker was trained on. The world's colour still reaches the *virtual* card, rim and
    /// beam; only the physical 37 mm LCD stays put. `--theme-follow-worlds` restores the old behaviour, and the
    /// firmware refuses a `set_theme` it does not want with `ack err:"locked"` (handled in `handle(_:)`).
    /// Explicit director commands (`cmd theme`) still go through — they are an instruction, not a side effect.
    func sendThemeUnlessLocked(_ id: String, reason: String) {
        guard themeFollowsWorlds else {
            print("[ble] set_theme \(id) skipped (\(reason)): the device screen is locked to " +
                  "\(PassportManifest.shared.defaultTheme.id) (--theme-follow-worlds to unlock)")
            return
        }
        sendTheme(id)
    }

    func sendMode(_ mode: DeviceCommand.Mode) {
        link?.send(.setMode(id: ids.make(), mode: mode))
    }

    /// **v4 B2 §3.1.** The AR session's backlight (`--ar-backlight`). The firmware applies a `backlight` in AR mode to
    /// the session: a key press does not clear it, and the next `set_mode` or BLE edge puts its own level back — which
    /// is why this goes out right after `set_mode ar`, on every link-up. BLE writes to the one RX characteristic arrive
    /// in order and the firmware handles lines one at a time, so the two cannot swap.
    func sendARBacklight() {
        guard let percent = arBacklight.percent else {
            print("[ble] backlight kept at the firmware's AR level (--ar-backlight keep)")
            return
        }
        let id = ids.make()
        pendingBacklight = (id: id, percent: percent, sentAt: Date())
        link?.send(.backlight(id: id, percent: percent))
        print(V4.ARBacklight.sentLine(percent))
    }

    func sendStats(_ stats: CardStats) {
        link?.send(.stats(id: ids.make(), DeviceStats(stats)))
    }

    func sendCelebrate(delta: Int) {
        link?.send(.celebrate(id: ids.make(), delta: delta))
    }

    func sendPlayCue(_ cue: String) {
        link?.send(.playCue(id: ids.make(), cue: cue))
    }

    /// 工作包 A 设备联动: the card asks the device to ring along with it (`DeviceCueRules` decides when).
    /// A cue raised before the link is up is dropped — except the one `connect` ring, which is remembered and
    /// sent when the device turns up, provided the card is still standing on it.
    func playCue(_ cue: DeviceCueRules.Cue, reason: String) {
        guard isConnected else {
            if cue == .connect {
                pendingConnectCue = true
                print("[ble] cue connect (\(reason)) waits for the link")
            }
            return
        }
        print("[ble] cue \(cue.rawValue) (\(reason))")
        sendPlayCue(cue.rawValue)
    }

    /// **V3-2a2 S2 / plan §3 「LCD 像素」.** Ask the real screen to sweep a white bar of its own, so it runs
    /// with the recognition scan's virtual band and the camera sees the two as one event.
    ///
    /// Three ways this does nothing, all of them logged once and not once per scan: `--glow off`; a
    /// firmware older than 0.2.0 (the command does not exist there, and the `hello` says so before we ever
    /// send one); and a device that answered `ack ok:false err:"unknown"` — an 0.1.x build that did not
    /// report its version. The `objTracked` window around the send is measured either way, because "does
    /// repainting the screen cost us the object anchor" is the one question this feature has to answer.
    func sendGlow(ms: Int = 300, kind: String = "sweep", reason: String) {
        guard glowEnabled else { return }
        guard !glowUnsupported else { return }
        guard isConnected else { return }
        if let version = firmwareVersion, !DeviceCoordinator.firmwareSupportsGlow(version) {
            glowUnsupported = true
            print("[ble] glow unsupported (fw \(version)); disabled for this session")
            return
        }
        let id = ids.make()
        pendingGlow = (id: id, sentAt: Date())
        link?.send(.glow(id: id, ms: ms, kind: kind))
        print("[ble] glow \(kind) \(ms) ms (\(reason))")
        measureGlowWindow()
    }

    /// `glow` landed in firmware 0.2.0. Anything that parses as older — or does not parse at all — is
    /// treated as "no glow", because a build that does not know the command answers `err:"unknown"` and the
    /// point of the check is not to send it in the first place.
    static func firmwareSupportsGlow(_ version: String) -> Bool {
        let parts = version.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        return major > 0 || minor >= 2
    }

    /// `[obj] glow window: objTracked 100% → NN% (−5 s / +5 s)` — the object stream's health in the five
    /// seconds before the repaint against the five after it. Plan §3's acceptance is a drop of ≤ 5 points.
    private func measureGlowWindow() {
        guard let tracker = app?.tracker else { return }
        let before = tracker.objectTrackedPercent(over: 5)
        // **V3-4 §10.** Whether a hand was over the device at the moment of the repaint. The first headset
        // round's one bad window (100 % → 94 %) had a `bridge on (left …)` 0.03 s after the `glow` acked, so
        // "the repaint cost us the anchor" and "a hand was in the way" were not distinguishable. Now they are.
        let handNear = tracker.nearestHandDistance.map { $0 <= 0.10 }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard self != nil else { return }
            let after = tracker.objectTrackedPercent(over: 5)
            func text(_ value: Float?) -> String { value.map { String(format: "%.0f%%", $0) } ?? "-" }
            let hand = handNear.map { $0 ? "yes" : "no" } ?? "-"
            print("[obj] glow window: objTracked \(text(before)) → \(text(after)) (−5 s / +5 s), hand within 10 cm at glow: \(hand)")
        }
    }

    /// Bottom strip of the device while a note is previewed (`docs/protocol.md` 「底条覆盖」): `text` = what it
    /// shows, nil = give the follower count back. Illegal glyphs are refused **here**, before the device has to
    /// answer `ack ok:false err:"glyph"`; a text the strip already shows is not sent again.
    /// `reason` (V3-2b B1) is appended to the log line — `[notes] strip ♥33 (deck dwell) → device (v8)` — so
    /// a strip the deck's dwell pushed can be told from one a preview pushed immediately.
    func sendStrip(_ text: String?, reason: String? = nil) {
        guard stripOverride != text else { return }
        if let text, !StripText.isValid(text) {
            print("[notes] strip \"\(text)\" refused: not 1–\(StripText.maxLength) glyphs of \(String(StripText.glyphs.sorted()))")
            return
        }
        stripOverride = text
        let why = reason.map { " (\($0))" } ?? ""
        guard isConnected else {
            print("[notes] strip \(text ?? "restore")\(why) skipped: no device linked")
            return
        }
        let id = ids.make()
        pendingStrip = (id: id, text: text ?? "restore", sentAt: Date())
        link?.send(.strip(id: id, text: text))
        print("[notes] strip \(text ?? "restore")\(why) → device (\(id))")
        stripWatchdog?.cancel()
        stripWatchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(DeviceCoordinator.stripAckTimeout * 1000)))
            guard let self, !Task.isCancelled, let pending = self.pendingStrip, pending.id == id else { return }
            print(String(format: "[notes] strip %@ not acked in %.1f s", pending.text, DeviceCoordinator.stripAckTimeout))
            self.pendingStrip = nil
        }
    }

    // MARK: - Recent notes (工作包 D)

    /// Pull `GET /api/notes`. `rev` is the one the hint announced (nil = "we just connected, we have nothing").
    /// A hint whose rev the app already shows costs nothing, and a burst of them costs one request.
    func requestNotes(rev: Int?, reason: String) {
        guard let client = notesClient, let app else { return }
        if let rev, rev == app.recentNotesRev {
            print("[notes] hint rev \(rev) is the one we show; nothing to fetch")
            return
        }
        notesTask?.cancel()
        notesTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(DeviceCoordinator.notesCoalesce * 1000)))
            guard let self, !Task.isCancelled else { return }
            guard let payload = await client.fetch() else { return }
            guard !Task.isCancelled, let app = self.app else { return }
            guard payload.rev != app.recentNotesRev || app.recentNotes.isEmpty else {
                print("[notes] fetched rev \(payload.rev), unchanged")
                return
            }
            print("[notes] fetched \(payload.notes.count) (rev \(payload.rev), \(reason))")
            app.applyNotes(payload, source: reason)
            // The covers are warmed into the very `URLCache` the cards' `AsyncImage` reads.
            await client.prefetchCovers(payload.notes)
        }
    }

    /// The space was dismissed mid-world (`WorldEngine.onAborted`): no world owns the screen any more, so the
    /// device goes back to the base screen. `desiredTheme` cannot answer this one — the world's `changed`
    /// handshake already moved `currentTheme` to the world's screen — so the base theme is named outright.
    /// BLE only, and only when the link is up: the hub drives the device over its own USB link and a second
    /// writer would fight it (see `applyHubTheme`). The device's `changed` / `ack` then brings `deviceTheme`
    /// and the tracker's expectation back to base by themselves.
    func restoreBaseTheme(reason: String) {
        let theme = PassportManifest.shared.defaultTheme.id
        guard isConnected else { return print("[ble] set_theme \(theme) skipped (\(reason)): link not connected") }
        guard deviceTheme != theme else { return print("[ble] set_theme skipped (\(reason)): device already shows \(theme)") }
        print("[ble] send set_theme \(theme) (\(reason))")
        sendTheme(theme)
    }

    /// Theme screen the device should show right now: the active world's, else the tracker's current one.
    private var desiredTheme: String {
        guard let app else { return PassportManifest.shared.defaultTheme.id }
        if let world = app.worlds.state.worldID {
            return PassportManifest.shared.theme(forWorld: world).id
        }
        return app.tracker.currentTheme.id
    }

    // MARK: - Events

    private func handle(_ event: DeviceEvent) {
        guard let app else { return }
        switch event {
        case .connected(let name):
            isConnected = true
            app.deviceConnected = true
            exitButtonTask?.cancel()
            app.worlds.showsExitButton = false
            let theme = desiredTheme
            print("[ble] \(name) connected → set_mode ar\(deviceTheme == theme ? " (device already shows \(theme))" : ", set_theme \(theme)")")
            sendMode(.ar)
            // v4 B2: after `set_mode` — which re-applies the firmware's own AR level — never before it.
            sendARBacklight()
            if deviceTheme != theme { sendThemeUnlessLocked(theme, reason: "link up") }
            if pendingConnectCue {
                pendingConnectCue = false
                // Only if the card is still there: a device that turns up after the card was folded away has
                // nothing to answer.
                if app.tracker.presence == .expanded { playCue(.connect, reason: "link up, card already expanded") }
            }
        case .disconnected:
            isConnected = false
            deviceTheme = nil
            app.deviceConnected = false
            // The firmware puts the follower count back by itself when the link drops (and after its 15 min
            // watchdog), so the app only forgets that it ever overrode the strip.
            stripWatchdog?.cancel()
            pendingStrip = nil
            stripOverride = nil
            // v4 B2: the BLE edge puts the firmware's own AR level back; the next link-up asks again.
            pendingBacklight = nil
            exitButtonTask?.cancel()
            exitButtonTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DeviceCoordinator.exitButtonReturnDelay))
                guard let self, !Task.isCancelled, !self.isConnected else { return }
                self.app?.worlds.showsExitButton = true
                print("[ble] exit button restored after \(DeviceCoordinator.exitButtonReturnDelay) s offline")
            }
        case .message(let message, let raw):
            lastMessage = raw
            handle(message, from: .device)
        }
    }

    // MARK: - Hub (WebSocket /vp)

    private func handle(hub event: HubEvent) {
        switch event {
        case .connected:
            hubState = .connected
            // Nothing is pushed on connect (the hint frame only follows a *change*), so the list is pulled once.
            requestNotes(rev: nil, reason: "hub connected")
        case .disconnected:
            hubState = .disconnected
        case .message(let message, let raw):
            lastMessage = raw
            switch message {
            case .setTheme(let theme):
                applyHubTheme(theme)
            case .notes(let rev, let count):
                print("[notes] hint rev \(rev) (\(count) notes)")
                requestNotes(rev: rev, reason: "hint rev \(rev)")
            case .device(let message):
                switch message {
                case .stats, .celebrate, .cmd:
                    handle(message, from: .hub)
                default:
                    // `/vp` only ever carries these four; anything else is a newer hub talking to an older app
                    // and must not drive the gate (no `hello` / `button` / handshake from the network).
                    print("[hub] ignoring \(message.typeName) (only stats / celebrate / set_theme / cmd are handled)")
                }
            }
        }
    }

    /// The hub announcing which screen it just asked the device to paint (over USB). The app only updates its
    /// **expectation** — which reference image the tracker should prefer — and never writes `set_theme` over
    /// BLE: the device's own screen is driven by the hub's USB link, or by the world / desired-theme logic
    /// (`WorldEngine.onShellOpaque`, `connected`), and a second writer would fight them. The repaint still
    /// announces itself over BLE with `will_change` / `changed`, so the gate hold is unchanged. Inside a world
    /// the world owns the screen, so the hub's theme is ignored there (same rule as the device's `hello`).
    private func applyHubTheme(_ theme: String) {
        guard let app else { return }
        guard !app.worlds.isActive else {
            print("[hub] set_theme \(theme) ignored inside \(app.worlds.state.worldID ?? "?")")
            return
        }
        app.tracker.setExpectedTheme(theme, reason: "hub set_theme")
    }

    /// Hub → device relay (only when the BLE link is up): the device is not on USB, so this is how its LCD
    /// count and chime stay in sync. `stats` is de-duplicated by `ts` on the device itself.
    private func relayStats(_ stats: DeviceStats) {
        guard isConnected else { return }
        link?.send(.stats(id: ids.make(), stats))
        print("[hub] → device stats \(stats.followers) (+\(stats.delta))")
    }

    // MARK: - Messages (either link)

    private func handle(_ message: DeviceMessage, from source: MessageSource) {
        guard let app else { return }
        let tracker = app.tracker
        switch message {
        case .hello(let hello):
            if let stats = hello.stats { app.apply(stats: stats.cardStats()) }
            deviceTheme = hello.theme
            firmwareVersion = hello.fw
            if let backlight = hello.backlight { tracker.deviceBacklight = backlight }
            if let theme = hello.theme, !app.worlds.isActive { tracker.setExpectedTheme(theme, reason: "device hello") }
            print("[ble] hello fw \(hello.fw ?? "?") mode \(hello.mode ?? "?") theme \(hello.theme ?? "?") heap \(hello.heap ?? 0)")
            if let widthMm = hello.screenWidthMm {
                let manifestMm = PassportManifest.shared.physicalWidthMeters * 1000
                if abs(widthMm - manifestMm) > 1 {
                    print(String(format: "[theme] physical width mismatch: device firmware says %.2f mm, manifest %.2f mm", widthMm, manifestMm))
                }
            }
        case .button(let button, let event):
            tracker.handleDevice(.button)
            print("[ble] button \(button.rawValue) \(event.rawValue)")
            // **V3-2a2 S3**: the key lights up on the frame the line arrives, before anything the press
            // means has been worked out. The feedback is the hardware's, and it is immediate.
            if let key = ButtonGlintLayout.Key(rawValue: button.rawValue) {
                app.controller?.flashButton(key, long: event == .long)
            }
            handleButton(button, event)
        case .willChange(let id, let kind, let theme, _):
            if let id { link?.send(.ack(id: id, ok: true, err: nil)) }
            guard kind != "stat" else { return }   // the followers strip alone does not disturb tracking
            if tracker.isPaused {
                print("[gate] will_change \(theme ?? "?") while paused (inside a world): auto-ack, no hold")
            } else if tracker.activeSource == .object {
                // 工作包 G: the hold exists because the *image* is about to be repainted and the pose would be
                // lost with it. The object tracker is looking at the slab, not at what is on its screen, so the
                // redraw is invisible to it — holding would freeze a card that is being tracked perfectly well.
                print("[gate] will_change \(theme ?? "?") while object-tracked: auto-ack, no hold")
            } else {
                tracker.handleDevice(.willChange(theme: theme))
            }
        case .changed(_, let theme):
            if let theme { deviceTheme = theme }
            tracker.handleDevice(.changed(theme: theme))
        case .stats(let stats):
            app.apply(stats: stats.cardStats(source: source == .hub ? "hub" : "device"))
            if source == .hub { relayStats(stats) }
        case .celebrate(let delta, let followers):
            // Never back to the sender: a device celebration is already on the device (and the firmware
            // forwards BLE celebrations, which would loop); a hub one is relayed by `AppModel.celebrate`.
            app.celebrate(delta: delta, followers: followers, fromDevice: source == .device, fromHub: source == .hub)
        case .cmd(let c, let arg):
            handle(command: c, arg: arg, from: source)
        case .battery(let soc, _, _, let backlight):
            app.deviceBattery = soc
            // Only the `[gate] Σ bl=` field: the experiment rounds vary backlight × theme, so the condition has to
            // be readable from the log line alone.
            if let backlight { tracker.deviceBacklight = backlight }
        case .ack(let id, let ok, let err, let theme):
            if let theme, ok { deviceTheme = theme }
            if !ok, err == "locked" {
                // The firmware is holding its screen (the reference object was trained on it). Nothing is wrong
                // and nothing is pending: release any theme hold the gate may be sitting in, because the redraw
                // this app was waiting for is never going to happen.
                print("[ble] set_theme refused (locked); the device keeps its screen")
                app.tracker.handleDevice(.changed(theme: nil))
            } else if !ok {
                print("[ble] ack \(id ?? "?") failed: \(err ?? "?")")
            }
            if let id, let pending = pendingBacklight, pending.id == id {
                pendingBacklight = nil
                let seconds = Date().timeIntervalSince(pending.sentAt)
                if ok {
                    // `Σ bl=` says so from the next window on (the device's own `battery` report confirms it within 60 s).
                    tracker.deviceBacklight = pending.percent
                    print(String(format: "[ble] backlight %d %% acked in %.2f s", pending.percent, seconds))
                } else {
                    print("[ble] backlight \(pending.percent) % refused by the device: \(err ?? "?") (it keeps its own AR level)")
                }
            }
            if let id, let pending = pendingGlow, pending.id == id {
                pendingGlow = nil
                if ok {
                    print(String(format: "[ble] glow acked in %.2f s", Date().timeIntervalSince(pending.sentAt)))
                } else {
                    // An 0.1.x build that did not report its version: it says `unknown` once and we stop.
                    glowUnsupported = true
                    print("[ble] glow unsupported (fw \(firmwareVersion ?? "0.1.0")); disabled for this session")
                }
            }
            if let id, let pending = pendingStrip, pending.id == id {
                // The strip's own ack comes *before* `changed` (the flip takes ~600 ms): this is the moment the
                // command counts as applied, and waiting for `changed` would never fire for an unchanged strip.
                pendingStrip = nil
                stripWatchdog?.cancel()
                let seconds = Date().timeIntervalSince(pending.sentAt)
                if ok {
                    print(String(format: "[notes] strip %@ acked in %.2f s", pending.text, seconds))
                } else {
                    print("[notes] strip \(pending.text) refused by the device: \(err ?? "?")")
                    stripOverride = nil
                }
            }
        case .unknown(let t):
            print("[ble] ignoring unknown message t=\(t)")
        }
    }

    private func handleButton(_ button: DeviceMessage.Button, _ event: DeviceMessage.ButtonEvent) {
        guard let app else { return }
        let worlds = app.worlds
        // v4 B2: a press is the wearer doing something at the desk — the world engine's 4 s idle window starts over,
        // so a prebuild never lands between two presses.
        worlds.noteDeskActivity()
        // v4 B2 §2: the first-gallery hint has done its job.
        app.noteButtonPressed()
        // **v4 B3 §1.** One table for every key and every place (`V4.ButtonMap`, the header above): what a press means
        // is decided in `AppModel.handleKey`, which logs it as one `[keys]` line.
        switch (button, event) {
        case (.up, .click): app.handleKey(.up)
        case (.down, .click): app.handleKey(.down)
        case (.ok, .click): app.handleKey(.ok)
        case (.ok, .long): app.handleKey(.longOK)
        default:
            break
        }
    }

    /// Director commands (relayed by the hub through the device over BLE, or straight off the `/vp` WebSocket).
    /// A `cmd` is for the app and is never relayed on to the device: the hub already sent the same `cmd` down
    /// its own USB link, so `celebrate` here runs the local choreography only (`relayToDevice: false`), while
    /// `theme` is the director's explicit "repaint the screen" and does write `set_theme` over BLE.
    func handle(command c: String, arg: JSONValue?, from source: MessageSource = .device) {
        guard let app else { return }
        print("[\(source == .hub ? "hub" : "ble")] cmd \(c) \(arg.map { "\($0)" } ?? "")")
        switch c {
        case "replay":
            app.tracker.requestReplay()
        case "hide":
            // Director's remote for the fold (工作包 A 显式隐藏/显示): the same collapse as a long OK (v4 B3).
            app.collapseCard(reason: "cmd hide")
        case "show":
            app.requestShowCard()
        case "celebrate":
            app.celebrate(delta: arg?.intValue ?? 1, followers: nil,
                          fromDevice: source == .device, fromHub: source == .hub, relayToDevice: false)
        case "theme":
            if let id = arg?.stringValue { sendTheme(id) }
        case "director":
            if case .bool(let on)? = arg { app.directorMode = on } else { app.directorMode.toggle() }
            print("[gate] director mode \(app.directorMode)")
        case "perf":
            // v4 B4 §3.5: the desk's layers, live (`V4.PerfSwitches`; the arg is one string of `layer=on|off` words).
            app.applyPerfCommand(arg?.stringValue, source: source == .hub ? "hub" : "ble")
        default:
            print("[ble] unknown cmd \(c)")
        }
    }

    /// The world's name, spoken (v3's carousel; v4 B2 §2's ring keeps it for the coins).
    func speak(_ text: String) {
        resolveVoice()
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice          // nil until resolved: the system picks a default voice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.speak(utterance)
    }

    /// `AVSpeechSynthesisVoice(language:)` asks the accessibility voice-asset service for the asset and **blocks
    /// its caller on a semaphore** while it does. On the visionOS 27 simulator that service (`axassetsd`) can die,
    /// and the call then never returns: the first UP / DOWN press froze the whole app on the main actor (sampled:
    /// `speak → AVSpeechSynthesisVoice.init(language:) → TextToSpeech → AXCoreUtilities → semaphore_wait_trap`).
    /// A headset missing the zh-CN voice asset would freeze the same way mid-test, so the lookup happens once, on a
    /// detached task, and the coin name is spoken with the default voice until it lands.
    private func resolveVoice() {
        guard !voiceRequested else { return }
        voiceRequested = true
        Task.detached(priority: .utility) { [weak self] in
            let resolved = AVSpeechSynthesisVoice(language: "zh-CN")
            await MainActor.run { self?.voice = resolved }
        }
    }
}
