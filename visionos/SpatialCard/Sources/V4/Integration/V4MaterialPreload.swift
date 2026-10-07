import Darwin
import Foundation
import QuartzCore
import RealityKit

/// **v4 B1 §3: the magic materials load at launch, not on the frame that needs them.**
///
/// The hero card needs five ShaderGraph materials (CrystalSlab, HoloFoil, GoldEdge, SweepGlint for the resting card,
/// MagicDissolve for the reveal). In the simulator the first graph of a process costs 1.2–1.6 s and each further one
/// 0.2–0.5 s, and a device seen right away closes its recognition ≈ 3.5 s after launch — so the loads start with the
/// process (`startAtLaunch`, the App's first stored property, before `AppModel` is built) and run in parallel
/// (`MagicMaterialLoader.preload`). The card is built with A4's placeholder style meanwhile (never left empty), and
/// the first recognition holds its hand-over until A1's style is on the card (`V4.HandOverHold`).
///
/// Debug flags:
/// - `--v4-preload serial|parallel|warm` — the load order (the A/B for the totals in the log);
/// - `--v4-material-delay <s>` — hold the loaded materials back `s` seconds (proves the hand-over hold in a smoke).
@MainActor
enum V4MaterialPreload {
    private static var task: Task<Void, Never>?
    private(set) static var isDone = false
    /// Load time of the five graphs (ms), without any debug delay.
    private(set) static var milliseconds: Double = 0
    /// The product's order (`--v4-preload` overrides it for the A/B).
    static let defaultOrder: MagicMaterialLoader.PreloadOrder = .parallel

    /// Called from `SpatialCardApp`'s first stored property. Not under `--v3-card` (v3 never uses the materials).
    @discardableResult
    static func startAtLaunch() -> Bool {
        guard !CommandLine.arguments.contains("--v3-card") else { return false }
        start()
        return true
    }

    /// **v4 B2** `--card-style a1|placeholder` (default `a1`): `placeholder` keeps A4's placeholder style on the hero card
    /// for the whole session and never loads A1's five ShaderGraph materials — the device-side A/B for the 45 fps of
    /// round 1. Under `--card-frost blur` A1's CrystalSlab samples `realitykit_surface_background_blur` (the frost), a
    /// full-screen-area cost only the headset's compositor can price; with this flag the card is the same card minus
    /// every A1 graph. (v4 B4: the frost is `plain` by default, so the blur is already out unless asked for.)
    static let placeholderOnly: Bool = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--card-style"), i + 1 < args.count else { return false }
        return args[i + 1].lowercased() == "placeholder"
    }()

    static func start() {
        guard task == nil else { return }
        guard !placeholderOnly else { return }
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        let order = value(after: "--v4-preload").flatMap { MagicMaterialLoader.PreloadOrder(rawValue: $0.lowercased()) }
            ?? defaultOrder
        let delay = value(after: "--v4-material-delay").flatMap(Double.init).map { max(0, min(30, $0)) } ?? 0
        let startedAfterLaunch = V4LaunchClock.sinceLaunch
        let started = CACurrentMediaTime()
        // Nothing is printed before this task runs: the App's `init` sets stdout's buffering after its stored
        // properties (this call among them) are initialised.
        task = Task { @MainActor in
            await MagicMaterialLoader.preload(order)
            milliseconds = (CACurrentMediaTime() - started) * 1000
            print(String(format: "[v4] magic materials preloaded in %.0f ms (%@, 5 graphs, frost \(V4.MagicMaterialGraphs.backgroundBlur ? "blur" : "plain"); started %.0f ms after launch, loaded %.0f ms after launch)",
                         milliseconds, order.rawValue, startedAfterLaunch * 1000,
                         V4LaunchClock.sinceLaunch * 1000))
            if delay > 0 {
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                print(String(format: "[v4] --v4-material-delay: materials held back %.1f s → ready %.0f ms after launch",
                             delay, V4LaunchClock.sinceLaunch * 1000))
            }
            isDone = true
        }
    }

    /// Suspends until the preload has finished (immediately, if it has — or if it was never started).
    static func wait() async {
        await task?.value
    }
}

/// Seconds since this process started (the kernel's `p_starttime`), for launch-relative timing lines: the closure of a
/// first recognition races the material preload, and both are timed against the same zero.
enum V4LaunchClock {
    private static let processStart: Double? = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
    }()

    static var sinceLaunch: Double {
        guard let processStart else { return -1 }
        return Date().timeIntervalSince1970 - processStart
    }
}
