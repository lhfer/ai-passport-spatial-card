import Foundation

/// **The device's bottom strip, following the hand deck** (V3-2b B1 / plan §4 E8).
///
/// Flipping through the deck is a fast thing — UP UP UP to get to the third note — and the strip is a real
/// LCD region that takes ~600 ms to repaint. Sending every card the wearer flips *past* would queue five
/// repaints behind a hand that has already stopped somewhere else. So the rule is a dwell: stop on a card for
/// 0.4 s and the device answers with its `♥N`; flip past it and the device never hears about it at all.
///
/// The debounce is a generation counter rather than a timestamp comparison, because the thing that actually
/// waits is a cancellable `Task` and a cancelled task is not always the one that loses the race: every raise
/// takes the next generation, and a timer may only send if `due` still recognises the generation it was
/// started for. Everything that writes the strip for its own reasons (a preview opening, a fold, a put-down,
/// leaving the hand) calls `cancel()`, which bumps the generation too — so a dwell armed 0.3 s ago cannot
/// come back and paint `♥33` over a strip that has just gone home to the follower count.
///
/// Pure value type (Foundation only) so `NoteFanTests` can drive the five-quick-raises case deterministically;
/// `AppModel` owns one and supplies the clock.
struct StripDwell: Equatable {
    /// What the strip is being asked to say.
    enum Request: Equatable {
        /// A note is raised: its `♥N`.
        case likes(String)
        /// A world card is raised, or the deck is back at the profile: the follower count.
        case restore

        /// What `sendStrip` takes.
        var text: String? {
            switch self {
            case .likes(let text): return text
            case .restore: return nil
            }
        }
    }

    /// `--strip-dwell <s>`.
    static let defaultSeconds: TimeInterval = 0.4

    var seconds: TimeInterval = StripDwell.defaultSeconds
    private(set) var request: Request?
    private(set) var requestedAt: TimeInterval = 0
    private(set) var generation = 0

    init(seconds: TimeInterval = StripDwell.defaultSeconds) { self.seconds = seconds }

    /// The deck raised something (or went back to the profile). Returns the generation this raise owns.
    @discardableResult
    mutating func raise(_ request: Request, at time: TimeInterval) -> Int {
        generation += 1
        self.request = request
        requestedAt = time
        return generation
    }

    /// The timer started for `generation` has fired: what to send, or nil when a later raise has superseded
    /// it, when something else has taken the strip over, or when the dwell is not actually up yet.
    mutating func due(_ generation: Int, at time: TimeInterval) -> Request? {
        guard generation == self.generation, let request,
              time - requestedAt >= seconds - 1e-9 else { return nil }
        self.request = nil
        return request
    }

    /// Someone else owns the strip now. Whatever the deck was waiting to say is dropped, and a timer already
    /// in flight can no longer fire.
    mutating func cancel() {
        generation += 1
        request = nil
    }
}
