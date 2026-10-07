import Foundation

/// v4 B1: the `.burst` beat's command to the real LCD (`glow`, 250 ms).
///
/// `DeviceCoordinator.sendGlow` drops a command silently while the BLE link is down, and the first recognition often
/// starts in the very second the link comes up: in the simulator the fake device connects ~1.3 s after launch, a few
/// milliseconds after the first detection's burst, so most first-run smokes sent nothing. The burst therefore waits
/// for the link for a short grace — while the ribbon is still leaving the screen (it launches at 0.10 s) — and is
/// dropped after it, with a log line: a flash after the ribbon has left the screen would read as a second event.
@MainActor
enum V4LCDBurst {
    static let grace: TimeInterval = 0.3
    static let milliseconds = 250

    static func send(on device: DeviceCoordinator, kind: String) {
        guard device.glowEnabled else { return }
        if device.isConnected {
            device.sendGlow(ms: milliseconds, kind: kind, reason: "v4 recognition")
            return
        }
        let start = Date()
        Task { @MainActor in
            while !device.isConnected {
                guard Date().timeIntervalSince(start) < grace else {
                    print(String(format: "[v4] LCD burst dropped: the BLE link was not up within %.1f s of the burst", grace))
                    return
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let waited = Date().timeIntervalSince(start)
            device.sendGlow(ms: milliseconds, kind: kind,
                            reason: String(format: "v4 recognition, link up %.2f s after the burst", waited))
        }
    }
}
