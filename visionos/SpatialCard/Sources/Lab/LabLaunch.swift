import Foundation

/// `--lab <id>` launches one v4 lab scene instead of the product: a virtual desk, a proxy AI Passport and a single
/// experiment built on them — no tracking, BLE, hub or worlds (see `LabRegistry`).
///
/// - `--lab-pose <deskHeight> <distance>`: where the desk top and the device sit, in metres (height above the
///   floor, distance in front of the wearer). The defaults frame the device in the simulator, whose eye height is
///   ≈ 1.59 m.
/// - `--lab-no-desk`: no virtual desk (on a headset the real desk is the stage).
/// - `--lab-night`: a night-blue dome around the set, so the night-gold look can be judged in the daylit simulator
///   room (it hides passthrough — a stand-in for the dim room the film is shot in).
/// - `--exit-after <s>`: quit after that many seconds, for scripted runs.
enum LabLaunch {
    static let id: String? = value(after: "--lab")
    static let deskHeight: Float = pose?.height ?? 1.35
    static let distance: Float = pose?.distance ?? 0.7
    static let showsDesk = !CommandLine.arguments.contains("--lab-no-desk")
    static let night = CommandLine.arguments.contains("--lab-night")
    static let exitAfter: Double? = value(after: "--exit-after").flatMap(Double.init)

    private static var pose: (height: Float, distance: Float)? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: "--lab-pose"), index + 2 < args.count,
              let height = Float(args[index + 1]), let distance = Float(args[index + 2]) else { return nil }
        return (height, distance)
    }

    private static func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
