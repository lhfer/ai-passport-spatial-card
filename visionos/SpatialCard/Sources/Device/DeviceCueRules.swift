import Foundation

/// When the **device** should ring along with the card (工作包 A 设备联动 → `docs/protocol.md` `play_cue`).
///
/// The three moments the plan asks for are all readable from the gate's own event stream, so they are decided
/// here — a pure value type with no BLE and no RealityKit — and `DeviceCoordinator` only does the sending:
///
/// | moment | cue | why |
/// | --- | --- | --- |
/// | the session's first `expanded` | `connect` | the hologram stands up out of the screen: the device answers once |
/// | **V3-2a2 S1**: with the recognition scan on (`scanDriven`), that one `connect` moves earlier — to the scan's convergence beat, where the wireframe becomes the socket light. A summon's scan rings `tick` instead. |  |  |
/// | `settling → expanded` after a carry | `tick` | the card was put back down and has landed |
/// | a relocation glide arrives | `tick` | same confirmation, but for a card that came back somewhere else — and it belongs to the **landing**, not to the thaw that started the glide |
///
/// Nothing here fires twice: `connect` is once per session (a replay's second cinematic is not a new connection),
/// and each relocation arms exactly one landing.
struct DeviceCueRules {
    /// The cue names the firmware knows (`play_cue`): `celebrate` is sent by the celebration path, not from here.
    enum Cue: String, Equatable {
        case connect
        case tick
    }

    /// A relocation glide shorter than this is not a relocation at all (`PresenceGate`'s own threshold).
    var relocateDistance: Float = PresenceGate.relocateDistanceDefault
    /// **V3-2a2 S1**: the recognition scan is running the session, so the one `connect` belongs to its
    /// convergence beat rather than to the first `expanded` — which, with the entrance held back until that
    /// beat, would otherwise ring while the card is still nothing but a wireframe. `--box-scan off` leaves
    /// this false and the original rule stands.
    var scanDriven = false

    /// The card has stood up at least once in this session.
    private(set) var revealed = false
    /// The card has been carried since it was last resting: `settling → expanded` is only a "put back down" then.
    private(set) var carried = false
    /// A relocation glide is in flight; its `tick` is owed to the landing.
    private(set) var awaitingLanding = false
    private(set) var previous: PresenceGate.Presence = .absent

    /// One gate event, in order. Returns the cue to send now, if any.
    mutating func handle(presence: PresenceGate.Presence, transition: PresenceGate.Transition?) -> Cue? {
        defer { previous = presence }
        if case .thaw(let glide) = transition, glide > relocateDistance {
            // The card came back somewhere else: the confirmation waits for `landed()`. Ringing now would put the
            // sound at the spot the card is leaving, half a second before it gets anywhere.
            awaitingLanding = true
        }
        if case .hide = transition {
            // Gone on purpose: the glide is cancelled with everything else, and the next reveal starts over.
            awaitingLanding = false
            carried = false
            return nil
        }
        if case .carrying = presence { carried = true }
        if presence == .expanded, !revealed {
            // V3-2a2 S1: with the scan running the session, its convergence beat owns the first `connect`
            // — and owns `revealed` with it, or the beat would find the session already "revealed" (the
            // gate reaches `expanded` while the card is still nothing but a wireframe) and ring a `tick`.
            guard !scanDriven else {
                carried = false
                return nil
            }
            revealed = true
            carried = false
            return .connect
        }
        if presence == .expanded, previous == .settling, carried {
            carried = false
            return .tick
        }
        return nil
    }

    /// **V3-2a2 S1**: the recognition scan has converged — the wireframe has just become the socket light
    /// and the card is about to stand up out of it. The session's first one is the `connect`; every later
    /// scan is a summon, and a summon is a confirmation, not a connection.
    mutating func scanConverged() -> Cue? {
        guard !revealed else { return .tick }
        revealed = true
        carried = false
        return .connect
    }

    /// The pose follower reports the relocation glide has landed.
    mutating func landed() -> Cue? {
        guard awaitingLanding else { return nil }
        awaitingLanding = false
        return .tick
    }
}
