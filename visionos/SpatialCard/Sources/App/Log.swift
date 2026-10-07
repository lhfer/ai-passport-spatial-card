import Foundation

/// Work package F — console *and* file logging, with no call-site changes.
///
/// The app prints ≈ 140 diagnostics (`[gate]`, `[theme]`, `[timing]`, `[perf]`, `[world]`, `[ble]` …) and on the
/// headset they are only reachable through `devicectl … --console`, which refuses to take over an app that is
/// already running. This file declares a module-scope `print` that **shadows `Swift.print` for every file in the
/// app target** (Swift name lookup prefers a declaration in the current module over one in the standard library),
/// forwards to the real `print` so the console behaves exactly as before, and appends the same line to a rolling
/// file in the app's Documents container. `tools/vp-logs.sh` pulls those files back with
/// `xcrun devicectl device copy from … --domain-type appDataContainer`.
///
/// Deliberately *not* in the `SpatialCardTests` target (see `project.yml`: the test bundle compiles `Tests/` plus
/// `Sources/Tracking/PresenceGate.swift` only), so the gate's own `print` stays `Swift.print` under XCTest.
///
/// Use `Swift.print(…)` explicitly at a call site that must never reach the file.
func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let text = items.map { String(describing: $0) }.joined(separator: separator)
    Swift.print(text, terminator: terminator)
    AppLog.shared.append(text + terminator)
}

/// Serial file sink behind `print`: `<Documents>/logs/spatialcard-<yyyyMMdd-HHmmss>.log`, rotated at 5 MB,
/// the newest 5 files kept. Every file starts with the build and the launch arguments, so a log pulled off the
/// headset says which binary and which experiment flags produced it.
///
/// Everything below runs on `queue`; nothing here may call the shadowing `print` (that would recurse) — the few
/// diagnostics it emits use `Swift.print`.
final class AppLog {
    static let shared = AppLog()

    static let maxBytes = 5 * 1024 * 1024
    static let keepFiles = 5

    private let queue = DispatchQueue(label: "org.spatialcard.spatialcard.log", qos: .utility)
    private var handle: FileHandle?
    private var bytes = 0
    private var disabled = false

    private var directory: URL? {
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        return documents.appendingPathComponent("logs", isDirectory: true)
    }

    private init() {}

    /// Queue the line for the current log file (opening / rotating it as needed). Never throws, never blocks the
    /// caller: a broken container only costs the file copy, the console line is already out.
    func append(_ line: String) {
        guard !disabled, let data = line.data(using: .utf8) else { return }
        queue.async { [weak self] in
            guard let self, !self.disabled else { return }
            if self.handle == nil { self.open() }
            guard let handle = self.handle else { return }
            if self.bytes + data.count > AppLog.maxBytes {
                self.rotate()
                guard self.handle != nil else { return }
                self.write(data)
                return
            }
            self.write(data, to: handle)
        }
    }

    private var currentURL: URL?

    private func write(_ data: Data, to handle: FileHandle? = nil) {
        guard let target = handle ?? self.handle else { return }
        do {
            try target.write(contentsOf: data)
            bytes += data.count
        } catch {
            Swift.print("[log] write failed: \(error); file logging off")
            disabled = true
            try? target.close()
            self.handle = nil
        }
    }

    private func open() {
        guard let directory else { disabled = true; return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Swift.print("[log] cannot create \(directory.path): \(error); file logging off")
            disabled = true
            return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = directory.appendingPathComponent("spatialcard-\(formatter.string(from: Date())).log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else {
            Swift.print("[log] cannot open \(url.lastPathComponent); file logging off")
            disabled = true
            return
        }
        _ = try? handle.seekToEnd()
        self.handle = handle
        currentURL = url
        bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        if bytes == 0 { write(AppLog.header().data(using: .utf8) ?? Data(), to: handle) }
        prune()
        Swift.print("[log] \(url.path)")
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        bytes = 0
        open()
    }

    /// Keep the newest `keepFiles` logs (the names sort chronologically).
    private func prune() {
        guard let directory else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        let logs = files.filter { $0.hasPrefix("spatialcard-") && $0.hasSuffix(".log") }.sorted()
        guard logs.count > AppLog.keepFiles else { return }
        for name in logs.dropLast(AppLog.keepFiles) {
            try? fm.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// First line of every file: build, bundle id and the launch arguments that produced this run.
    private static func header() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let bundle = Bundle.main.bundleIdentifier ?? "?"
        let args = CommandLine.arguments.dropFirst().joined(separator: " ")
        let stamp = ISO8601DateFormatter().string(from: Date())
        return "# SpatialCard \(version) (\(build)) \(bundle) · \(stamp) · args: \(args.isEmpty ? "(none)" : args)\n"
    }
}
