import ARKit
import Foundation
import Observation
import QuartzCore
import simd
import UIKit

/// Runs `ARKitSession` with image tracking (the three AI Passport theme screens), world tracking (head pose
/// for the field-of-view gate and the floating hint) and horizontal plane detection (the desk the surface
/// effects sit on). Scene reconstruction is **not** part of that session any more (v2): it costs sensor budget
/// that image tracking needs, and neither shipped world converts the real room. A world that does asks for it
/// through `WorldEngine.onNeedsRoomMesh` → `startSceneReconstruction()`, which runs a second `ARKitSession`;
/// `--mesh-at-start` puts the provider back in the main session for the experiment matrix.
///
/// Every observation goes through `PresenceGate`, which decides what the hologram shows; the view drains the
/// gate's events with `takeTransition()`.
/// Everything here is main-actor isolated so the RealityView update closure can read it without locking.
@MainActor
@Observable
final class CardTracker {
    enum Status: Equatable {
        case idle
        case unsupported
        case missingReferenceImage
        case authorizationDenied
        case starting
        case searching
        case tracking
        case moving
        case notFlat
        case outOfView
        case lost
        /// Pose frozen (occlusion, button, theme redraw, world): the hologram stays; no hint. Also the quiet
        /// first seconds of an `absent` after the card has been seen — see `refreshStatus`.
        case held
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "未开始"
            case .unsupported: return "此设备/模拟器不支持图像跟踪"
            case .missingReferenceImage: return "资源组 CardReference 里没有参考图"
            case .authorizationDenied: return "需要「周围环境感知」权限"
            case .starting: return "正在启动…"
            case .searching: return "看向桌上的设备，会自动识别"
            case .tracking: return "已锁定名片"
            case .moving: return "名片移动中"
            case .notFlat: return "把名片平放到桌面上"
            case .outOfView: return "名片在视野外"
            case .lost: return "暂时看不到设备，看向它就会继续，不用退出"
            case .held: return "保持中"
            case .failed(let message): return "出错：\(message)"
            }
        }

        /// **Errors only.** The hint capsule used to offer 退出 for `.searching` / `.lost` too, and the first
        /// on-device trial showed exactly what that costs: the wearer read "名片丢失" next to an exit button as a
        /// fatal error, tapped it, and tore down the whole ARKit session every time tracking dropped for a few
        /// seconds — although v2's gate recovers on its own and never hides the card. Acquisition and loss are
        /// normal states with reassuring copy and no button; the way out of a *working* session is the 退出 chip
        /// on the desk arc (and the Digital Crown).
        var showsExit: Bool {
            switch self {
            case .unsupported, .missingReferenceImage, .authorizationDenied, .failed: return true
            default: return false
            }
        }

        /// Whether the in-space hint label should show this status.
        var showsHint: Bool {
            switch self {
            case .tracking, .idle, .outOfView, .held: return false
            default: return true
            }
        }
    }

    /// One image anchor ARKit has reported (one per theme screen it has seen).
    struct AnchorRecord {
        var imageName: String
        var theme: PassportManifest.Theme?
        var isTracked: Bool
        var lastUpdate: TimeInterval
        var pose: simd_float4x4
    }

    /// `--auto-show` (v3 H2 §7).
    enum AutoShow: String {
        /// The session's first detection reveals the card; after a dismiss only OK brings it back (v2).
        case first
        /// Every re-acquisition brings a dismissed card back.
        case always
        /// Even the first appearance waits for OK.
        case never
    }

    /// Messages from the device that the gate reacts to (see `DeviceCoordinator`).
    enum DeviceGateEvent {
        case button
        case willChange(theme: String?)
        case changed(theme: String?)
    }

    // MARK: Presentation gates (angles in radians, with hysteresis so nothing flickers)

    /// Flat gate: the card counts as lying flat while its normal is within `flatEnterAngle` of straight up; once
    /// flat it stays flat up to `flatExitAngle`. Not flat only demotes the hologram to `carrying(.notFlat)`.
    var flatEnterAngle: Float = 30 * .pi / 180
    var flatExitAngle: Float = 42 * .pi / 180
    /// View gate: more than `viewExitAngle` off the wearer's gaze = out of view (pauses the grace timer and the
    /// hints, nothing hides); back in view within `viewEnterAngle`. Vision Pro's field of view is ≈ 100° wide.
    var viewEnterAngle: Float = 42 * .pi / 180
    var viewExitAngle: Float = 55 * .pi / 180
    /// Give plane detection this long after the first detection before falling back to the image plane.
    var deskSearchTimeout: TimeInterval = 3.0
    /// The desk must be below the image by at most this much (device thickness + margin).
    var deskMaxDrop: Float = 0.30
    /// Director mode (`--director`): grace never expires, flat / view demotions off.
    var directorMode = false {
        didSet { gate.directorMode = directorMode }
    }
    /// `--legacy-hide`: v1's timed disappearance (6 s grace, 8 s theme / 6 s world reacquire windows) instead of
    /// v2's "a lost image only freezes". For the A/B round on the headset.
    var legacyHide = false {
        didSet { gate.legacyHide = legacyHide }
    }
    /// `--mesh-at-start`: scene reconstruction in the main session from the first frame, as in v1 (experiment E2).
    var meshAtStart = false
    /// `--tracker image|object|both`. **v3 default: `object`** — the screen frame is read off the scan
    /// (`ObjectScreenFrame`), so there is nothing for the image tracker to calibrate and, on the evidence of
    /// the first Extended round (image tracking dead in 15 of 16 windows), nothing it reliably contributes.
    /// `image` never constructs `ObjectTrackingProvider`; `object` never constructs `ImageTrackingProvider`.
    var trackerMode: TrackingFusion.Mode = .object {
        didSet { fusion.mode = trackerMode }
    }
    /// The mode this session is actually running in. `--tracker object` degrades to `.image` when there is no
    /// object source to run it with — the simulator (`ObjectTrackingProvider.isSupported == false`), a missing
    /// or unreadable `.referenceobject`, or a `--fake-track` script with no object segments. Without this the
    /// fusion would sit in a mode that never yields a pose and the card would simply never appear.
    private(set) var effectiveMode: TrackingFusion.Mode = .object
    /// `--object <path>`: a `.referenceobject` outside the bundled `objects/` folder (absolute, or a bundled name).
    var objectPath: String?
    /// `--recalibrate`: forget the stored object→screen offset for this reference object before starting.
    var recalibrate = false
    /// `--auto-show first|always|never` (v3 H2 §7): `first` = the session's first detection reveals the card and
    /// everything after that is the OK button's business (today's behaviour); `never` = even the first
    /// appearance waits for OK (the device wears only its socket light until then); `always` = a dismissed card
    /// comes back the next time the device is **re-acquired** (see `ingest`).
    var autoShow: AutoShow = .first
    /// `--screen-side +y|-y` / `--screen-yaw 0|180`: force one or both of the two signs a bounding box cannot
    /// give (`ObjectScreenFrame.Flips`). Set, they also overwrite the persisted record for this object.
    var screenSideFlipOverride: Bool?
    var screenYawFlipOverride: Bool?
    /// Told when a device gesture fires (`DeviceGestures`); `AppModel` decides what it means.
    var onGesture: ((DeviceGestures.Event) -> Void)?
    /// `--fake-box measured|headset|scan` (V3-1b; `measured` v4 B1): which `ObjectAnchor.boundingBox` the
    /// `--fake-track` harness reports. `headset` is what the device actually sends (Z-thin, 60 × 95 × 8.5 mm);
    /// **`measured` (the default since v4 B1)** is the same Z-thin frame at the case's ruler size, 60 × 96 × 8 mm,
    /// so a simulator run is built on the numbers the case frame is; the Y-thin `scan` box is what the offline usdz
    /// analysis produced. Object segments that do not name an `objectOffset` are emitted through the selected box,
    /// so one script drives any of them.
    var fakeBox: ObjectScreenFrame.Box = .aiPassportMeasured
    /// `--carry-lead <s>` (V3-1b): how far ahead of the measured raw velocity the follower is retargeted while
    /// the device is being carried. 0 disables the feed-forward. See `rawVelocity`.
    var carryLead: Float = CardTracker.carryLeadDefault
    /// **V3-4 §10** `--detection-rate <hz>`; written by `AppModel` before the session starts.
    var detectionRate: Float = 5 {
        didSet { CardTracker.objectDetectionRate = detectionRate }
    }
    /// **V3-4 §8.** How far the nearer tracked wrist is from the device, or nil when neither is tracked.
    /// The folded card's "it noticed you" asks this four times a second.
    var nearestHandDistance: Float? {
        guard handBridgeEnabled, let screen = latestRawScreenPose ?? latestObjectPose else { return nil }
        return bridge.nearestHandDistance(to: ObjectScreenCalibration.translation(of: screen), at: now)
    }
    /// **v4 B4 §2.** The same nearer tracked hand, as the pick-up watch reads it: how far it is from where the passport was
    /// last seen and how high above it (world up, m). Nil when no hand is tracked.
    var nearestHand: (distance: Float, height: Float)? {
        guard handBridgeEnabled, let screen = latestRawScreenPose ?? latestObjectPose,
              let offset = bridge.nearestHandOffset(to: ObjectScreenCalibration.translation(of: screen), at: now) else { return nil }
        return (simd_length(offset), offset.y)
    }
    /// **V3-4 §7** `--filter euro|lowpass`; written by `AppModel` before the session starts.
    var filterMode: ObjectPoseSmoother.Kind = .euro {
        didSet { smoother.kind = filterMode }
    }
    /// Where the card is actually being drawn right now (`anchorRoot.position`), set by the controller. Sampled
    /// every tick while `carrying` for `Σ lag=` — the one number that says whether the card is keeping up with
    /// the passport in the wearer's hand.
    @ObservationIgnored var renderedPosition: (() -> SIMD3<Float>?)?
    /// **V3-2b B6 / plan H4.** `--no-hands` turns the whole bridge off (and never builds the provider).
    var handBridgeEnabled = true
    /// **V3-4 §3** `--bridge-orientation frozen|hand` and `--bridge-max <s>`: set by `AppModel` before the
    /// session starts (the bridge is a value type, so these are written through to it).
    var bridgeOrientation: HandBridge.Orientation = .frozen {
        didSet { bridge.orientation = bridgeOrientation }
    }
    var bridgeMaxSeconds: TimeInterval = HandBridge().maxBridge {
        didSet { bridge.maxBridge = bridgeMaxSeconds }
    }
    /// **V3-5 §1** `--bridge-radius <m>`: how close a wrist has to be to the device's centre to count as
    /// holding it. The default is the rule's own (15 cm); the flag is here so the headset can A/B it.
    var bridgeAttachRadius: Float = HandBridge().attachRadius {
        didSet { bridge.attachRadius = bridgeAttachRadius }
    }
    /// **V3-6 §1** `--bridge on|off` (default **off**): whether the bridge's answer is allowed to *place the
    /// card*. `handBridgeEnabled` stays a different question — it is `--no-hands`, and it still builds the
    /// provider, still feeds `bridge.observeHand` / `observeObject`, and still answers
    /// `nearestHandDistance` and `Σ hands=`. Off, `driveBridged` is simply never called: `Σ src=` cannot
    /// read `hand`, `bridged=` cannot leave 0 %, and a lost object freezes the card where it is.
    var bridgeDrivesCard = false
    /// The rule itself (pure, `HandBridgeTests`).
    @ObservationIgnored private var bridge = HandBridge()
    /// The bridge is placing the card right now: `Σ src=hand`, and `Σ bridged=` counts these ticks.
    @ObservationIgnored private(set) var bridgeDriving = false
    /// When the current bridge started, for the `[hand] bridge off` line.
    @ObservationIgnored private var bridgeStartedAt: TimeInterval?
    /// **V3-4 §3.** The last tilt the *camera* reported, held for as long as the bridge drives: the desk gate
    /// and `DeviceGestures` both judge this instead of the wrist's own idea of which way the passport faces.
    @ObservationIgnored private var bridgeFrozenTilt: Float?
    /// When the object anchor was last reported **tracked** (`lastObjectUpdate` counts untracked ones too).
    @ObservationIgnored private var lastObjectTrackedUpdate: TimeInterval?
    /// Hand anchors, when the provider is running (`nil` in the simulator and under `--no-hands`).
    private var handProvider: HandTrackingProvider?
    /// `[hand] denied` was printed once: the wearer said no to hand tracking and nothing else changes.
    private var handsDenied = false

    /// **V3-2b B2.** The widest gap between a rendered deck card and its slot, this frame (metres), from the
    /// controller. Nil whenever the deck is not being followed — outside the hand, or `--deck-dynamics off`.
    /// `Σ deckLag=` is the window's **peak**, not its mean: one card that snaps is the failure this measures.
    @ObservationIgnored var deckLag: (() -> Float?)?

    // MARK: Published state

    private(set) var status: Status = .idle
    /// What the hologram should show right now (see `PresenceGate`).
    private(set) var presence: PresenceGate.Presence = .absent
    /// Monotonic count of gate events queued so far. The RealityView update closure observes this (not just
    /// `presence`): `.search` is a *same-presence* event, and without an observable change it would sit in the
    /// FIFO until something else re-ran the closure — the shimmer would then appear at the thaw instead of at 3 s.
    private(set) var gateEventCount = 0
    private(set) var latestPose: simd_float4x4?
    private(set) var isTracked = false
    private(set) var isFlat = true
    private(set) var isInView = true
    /// True while a world keeps the tracker paused (`.full` immersion: image tracking sends nothing).
    private(set) var isPaused = false
    /// Physical size (m) of the reference image being tracked (manifest footprint until then).
    private(set) var referencePhysicalSize: CGSize?
    /// Theme screen the device is showing (from the active anchor, or `changed` while a redraw is expected).
    private(set) var currentTheme: PassportManifest.Theme = PassportManifest.shared.defaultTheme
    /// Every image anchor ARKit has reported; the most recently *tracked* one drives the hologram.
    private(set) var anchors: [UUID: AnchorRecord] = [:]
    private(set) var activeAnchorID: UUID?
    /// World-space Y of the desk under the card (detected plane, or image plane − device thickness
    /// after `deskSearchTimeout`). `nil` until known.
    private(set) var surfaceY: Float?
    private(set) var surfaceIsDetectedPlane = false
    /// Head pose, throttled to ~5 Hz and only while a hint should be visible.
    private(set) var hintDevicePose: simd_float4x4?
    /// First-detection timeline for the recognition-speed measurement (seconds since `start()`).
    private(set) var timeline: [String: TimeInterval] = [:]
    /// Every image-anchor update event (added/updated/removed) since `start()`.
    private(set) var anchorUpdateCount = 0
    /// Which provider is placing the card right now (`[gate] Σ src=`). 工作包 G: everything below
    /// `ingest(pose:isTracked:at:)` — the gate, the continuity gate, the follower — is unaware of this.
    private(set) var activeSource: TrackingFusion.Source = .image
    /// The screen frame derived from the active object anchor's bounding box (v3 H1). Nil until the first
    /// anchor (or, under `--fake-track`, the synthetic box) arrives.
    @ObservationIgnored private(set) var screenFrame: ObjectScreenFrame?
    /// V3-2a H5: the desk gate thinks a put-down is coming (flat, not yet still). Edge-triggered.
    @ObservationIgnored private var deskCandidate = false
    /// Told whenever that changes, so the hand deck can play its anticipation.
    @ObservationIgnored var onDeskCandidate: ((Bool) -> Void)?
    /// The trained reference object's name, once one has been loaded. Nil = image-only (no `.referenceobject`
    /// in the bundle, `--tracker image`, or the simulator, where `ObjectTrackingProvider.isSupported` is false).
    private(set) var referenceObjectName: String?
    /// Latest object-anchor pose **mapped into the screen frame** (the calibrated offset, or the anchor's own
    /// bounding box until it converges). This is the candidate the fusion weighs against the image's.
    @ObservationIgnored private(set) var latestObjectPose: simd_float4x4?
    /// The same observation as ARKit reports it, in the trained object's frame.
    @ObservationIgnored private(set) var latestObjectRawPose: simd_float4x4?
    /// The latest object observation in the **screen** frame, *before* the desk snap and the smoother: the raw
    /// signal `Σ lag=` measures the rendered card against, and the one the velocity feed-forward differentiates.
    @ObservationIgnored private(set) var latestRawScreenPose: simd_float4x4?
    /// Raw screen-frame velocity (m/s): a finite difference over the last two tracked object samples, low-passed
    /// at `velocityTau`, zeroed on a tracking loss. `HologramController` leads the follower by
    /// `rawVelocity × carryLead` while the device is carried, which is what takes the carry lag from ~8 cm to
    /// ~2 cm without making the resting card twitchy (at rest the difference is millimetres per second).
    @ObservationIgnored private(set) var rawVelocity: SIMD3<Float> = .zero
    /// The object pose's tilt (its +Y against gravity) in the screen frame, **before** the desk snap: what the
    /// desk gate reads and what `[gate] Σ objTilt=` prints. Nil until a tracked object observation arrives.
    @ObservationIgnored private(set) var objectTilt: Float?
    @ObservationIgnored private(set) var objectTracked = false
    @ObservationIgnored private(set) var lastObjectUpdate: TimeInterval?
    /// Object-anchor updates since `start()` (`[gate] Σ obj=` is this, per second, over the window).
    @ObservationIgnored private(set) var objectUpdateCount = 0
    /// `objectToScreen`, averaged over co-observations and persisted per reference object.
    @ObservationIgnored private(set) var calibration = ObjectScreenCalibration()
    /// Head pose refreshed every tick (also used to place in-space debug rigs).
    private(set) var latestDevicePose: simd_float4x4?
    /// World Y of the floor (largest horizontal plane at least 0.9 m below the head), for world placement.
    private(set) var floorY: Float?
    /// Room geometry from SceneReconstructionProvider, for worlds that turn the room into something else.
    /// Empty unless `startSceneReconstruction()` ran (on demand) or `--mesh-at-start` was passed.
    private(set) var meshAnchors: [UUID: MeshAnchor] = [:]
    var onMeshAnchorsChanged: (() -> Void)?
    /// True once scene reconstruction is running (either session).
    private(set) var isMeshRunning = false
    private(set) var isRunning = false
    /// Consecutive start failures (for the 1 / 2 / 4 s retry backoff).
    private(set) var retryAttempt = 0
    /// Backlight percentage the device last reported (`hello` / `battery`). Only the `[gate] Σ bl=` field reads it:
    /// the experiment rounds vary backlight × theme, so the condition has to be readable from the log line alone.
    @ObservationIgnored var deviceBacklight: Int?

    // MARK: Private

    private var session = ARKitSession()
    private var provider: ImageTrackingProvider?
    /// 工作包 G: runs in the **same** `ARKitSession` as image / world / plane tracking. Nil whenever there is no
    /// reference object to track (which is the normal state until the Create ML scan lands).
    private var objectProvider: ObjectTrackingProvider?
    private var objectTask: Task<Void, Never>?
    private var activeObjectID: UUID?
    /// The active object anchor's bounding-box offset: where the screen is before the calibration converges.
    private var objectBoxOffset: simd_float4x4?
    /// Source-selection policy + the disagreement veto (pure, unit-tested in `TrackingFusionTests`).
    @ObservationIgnored private var fusion = TrackingFusion()
    /// 工作包 G2 rule 1: is the object lying on a desk (snap its orientation gravity-aligned) or in a hand?
    @ObservationIgnored private var deskGate = DeskOrientationGate()
    /// **v4 B4 §1.** The desk gate's current answer (a fresh gate's prior is the desk): with `objectTilt`, what decides at
    /// `acquiring` whether the recognition flies the desk's path or the hand's (`V4.RecognitionPlan`).
    var deskGateOnDesk: Bool { deskGate.isOnDesk }
    /// 工作包 G2 rule 3 (v3: split τ): low pass on the object stream, before it is offered to the fusion.
    @ObservationIgnored private var smoother = ObjectPoseSmoother()
    /// v3 H2 §6: "turned face down" read from the object source's own tilt.
    @ObservationIgnored private var gestures = DeviceGestures()
    /// The screen frame's two signs are decided from the head pose; until one arrives (or this long passes)
    /// the frame runs on its defaults. Set on the first tracked object observation.
    @ObservationIgnored private var frameDecisionDeadline: TimeInterval?
    /// Why there is no object source this run, for the one-line fallback message.
    @ObservationIgnored private var objectUnavailable: String?
    /// `--fake-track`: the simulator has no `WorldTrackingProvider`, so the harness stands a reader at the
    /// simulator's own viewpoint (y ≈ 1.59 m, looking down −Z). Without a head there would be nothing for the
    /// screen frame's side / yaw decision or for the hand card's facing policy to face, and the one thing v3
    /// most needs to rehearse without a headset is exactly those two.
    @ObservationIgnored private var fakeHeadPose: simd_float4x4?
    /// The screen frame's two signs, once anything has decided them (a flag, a stored record, the head).
    @ObservationIgnored private var screenFlips: ObjectScreenFrame.Flips?
    /// `--fake-track` is running: nothing this session decides may be persisted.
    @ObservationIgnored private var isFakeTrack = false
    /// Whether the previous forwarded observation was tracked: `--auto-show always` reads it so that "the next
    /// detection" means a re-acquisition, not simply the next frame of a stream that never stopped.
    @ObservationIgnored private var wasTrackedLastObservation = false
    /// Previous raw screen sample the velocity is differentiated from.
    @ObservationIgnored private var lastRawVelocitySample: (position: SIMD3<Float>, time: TimeInterval)?
    /// Since when the gate has been continuously `expanded` (nil = it is not). The calibration only samples a card
    /// that has been standing still this long — see `calibrationSettle`.
    @ObservationIgnored private var expandedSince: TimeInterval?
    /// Since when the presence has been `absent`: the `.lost` hint is held back this long (`searchCueAfter`), so
    /// a momentary drop never puts "看不到设备" in front of the wearer.
    @ObservationIgnored private var absentSince: TimeInterval = -.infinity
    /// The offset last written to `UserDefaults`, and when: the refresh path keeps improving the mean, and it must
    /// not write on every one of the 30 object updates a second.
    /// The last image pose the gate accepted, and when: what a co-observation is measured against.
    @ObservationIgnored private var lastAcceptedImage: (pose: simd_float4x4, time: TimeInterval)?
    @ObservationIgnored private var savedOffset: simd_float4x4?
    @ObservationIgnored private var savedAt: TimeInterval = -.infinity
    private var worldProvider: WorldTrackingProvider?
    private var planeProvider: PlaneDetectionProvider?
    private var meshProvider: SceneReconstructionProvider?
    private var meshTask: Task<Void, Never>?
    /// Second session, started only when a world needs the room mesh (`startSceneReconstruction()`).
    private var meshSession: ARKitSession?
    /// A world asked for the mesh in this app run: a session restart (space closed and reopened) brings it back.
    private var meshRequested = false
    private var meshUnsupported = false
    @ObservationIgnored private var gate = PresenceGate()
    private var hasTrackedOnce = false
    private var lastHintPoseTime: TimeInterval = 0
    private var startTime: TimeInterval = 0
    private var firstDetectionTime: TimeInterval?
    private var planes: [UUID: PlaneAnchor] = [:]
    private var updatesTask: Task<Void, Never>?
    private var planeTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var isPreview = false
    /// `--fake-track`: the script runner's task, and a desk height it may override.
    private var trackTask: Task<Void, Never>?
    private var fakeSurfaceY: Float?
    /// `start()` is in flight (awaiting authorization / `session.run`): a second start must not build another session.
    private var isStarting = false
    /// Uptime of the last `changed` to another theme: for `themeReacquireWindow` only that theme's image may lock on.
    private var themeChangedAt: TimeInterval = -.infinity
    private var lastRejectLog: [UUID: TimeInterval] = [:]
    /// `[gate] Σ` window accumulators (see `summarize(at:)`).
    private var summaryStart: TimeInterval?
    private var summaryUpdates = 0
    private var summaryTicks = 0
    private var summaryFreshTicks = 0
    private var summaryStaleTicks = 0
    private var summaryJitterSum: Double = 0
    private var summaryJitterCount = 0
    private var summaryObjectUpdates = 0
    /// Every object update in the window, tracked or not (`objTracked=` is the ratio of the two).
    private var summaryObjectUpdatesAll = 0
    /// **V3-2a2 S2.** The same two counts, never reset, plus a once-a-second trail of them: repainting the
    /// real LCD (`glow`) might cost the object anchor, and `[obj] glow window` has to be able to ask "how
    /// tracked were we over the five seconds *before* the send" long after the Σ window that covered them
    /// has been printed and cleared.
    private var objectTrackedTotal = 0
    private var objectUpdatesTotal = 0
    private var objectTrail: [(at: TimeInterval, tracked: Int, all: Int)] = []
    private var objectTrailLast: TimeInterval = -.infinity
    /// RMS **angle** step between consecutive accepted poses (`rotJitter=`), same chain as `jitter=`.
    private var summaryRotJitterSum: Double = 0
    private var summaryRotJitterCount = 0
    /// Ticks spent in `carrying` (`inHand=`): on the headset this is "how much of the window was the passport
    /// in a hand", which is the number the whole of v3 is judged on.
    private var summaryCarryTicks = 0
    private var summaryRelocBase = 0
    private var summaryOutlierBase = 0
    /// Last pose the gate accepted inside the current `Σ` window (`tilt=`).
    private var summaryLastAccepted: simd_float4x4?
    /// Last **raw** object tilt inside the current `Σ` window (`objTilt=`): what the desk gate reads, before the
    /// snap. Together with `tilt=` it says in one line whether the snap is doing its job on the headset.
    private var summaryLastObjectTilt: Float?
    /// `Σ lag=`: |rendered − latest raw screen position|, accumulated on every tick spent in `carrying`.
    private var summaryLagSum: Double = 0
    private var summaryLagCount = 0
    /// `Σ deckLag=` (V3-2b B2): the window's widest deck lag, in metres. Nil = the deck was never followed.
    private var summaryDeckLagPeak: Float?
    /// `Σ bridged=` (V3-2b B6): ticks the hand bridge placed the card on, out of all of them.
    private var summaryBridgedTicks = 0
    private var lastObservationTime: TimeInterval?
    private var lastJitterPose: simd_float4x4?
    /// **V3-4 §7 / V3-5 §4.** The same measurement taken on what is actually **drawn**, so a filter change
    /// can be judged rather than argued about: `Σ jitter=` is the input's noise, `Σ jitterOut=` the presented
    /// card's — both sampled on the same tracked observations since V3-5.
    private var lastRenderedJitter: SIMD3<Float>?
    /// **V3-6 §4.** Which clock the current loss belongs to — the pick-up's or the desk's. The rule itself
    /// is a pure value type (`LossClockTests`); this is only the wiring.
    @ObservationIgnored private var lossClock = LossClock()
    /// **v4 B2 §3.2.** `[track] in view but untracked …` and the desk / hand segment summaries (`V4.TrackingWatch`,
    /// pure; this is the wiring).
    @ObservationIgnored private var watch = V4.TrackingWatch()
    /// What the device's bottom strip shows right now (an override such as `♥62`, nil = the follower count), for the
    /// `strip …` field of that line. Set by `AppModel` (the device coordinator owns the strip).
    @ObservationIgnored var stripProvider: (() -> String?)?
    /// **v4 B2 §3.3.** The tracker's clock (`systemUptime`), for the pick-up fold's per-hold grab clock (the fold applies
    /// `LossClock.classify` to `nearestHandDistance` itself: `LossClock`'s own clock outlives a thaw to the desk, see
    /// `V4.PickupFold.GrabWatch`).
    var clock: TimeInterval { now }
    private var summaryJitterOutSum: Double = 0
    private var summaryJitterOutCount = 0
    /// **V3-5 §4.** `Σ jitterRaw=`: the step of the **unsmoothed** object pose, on the same observations.
    ///
    /// `jitter=` has never been what its own comment claimed. It is measured in `ingest`, i.e. on the pose
    /// the fusion forwards — which for the object source is already through `ObjectPoseSmoother`. So
    /// `jitter=` vs `jitterOut=` compares *after the filter* with *after the follower*, and says nothing
    /// about whether the filter is doing anything. This is the missing end: raw in, `jitter` after the
    /// filter, `jitterOut` as drawn, all three sampled on the same tracked observations.
    private var summaryJitterRawSum: Double = 0
    private var summaryJitterRawCount = 0
    /// **v4 B5 §6.** The line of sight's angle to the screen's normal over the window's tracked observations (`normal=`).
    private var summaryNormal = V4.ViewAngleWindow()
    private var lastRawJitterPose: SIMD3<Float>?

    static let resourceGroupName = "CardReference"
    /// Thickness of the device when no desk plane is available: `card.json` `device.thicknessMm` (AI Passport ≈ 8.5 mm).
    static let fallbackDeviceThickness: Float = CardData.loadFromBundle().deviceThickness
    static let maxRetries = 3
    /// Seconds between `[gate] Σ` lines.
    static let summaryPeriod: TimeInterval = 5
    /// V3-2a2 S2: how often the object stream's running totals are sampled, and how many samples are kept.
    static let objectTrailPeriod: TimeInterval = 0.5
    static let objectTrailMax = 60
    /// Eye height of the `--fake-track` harness's stand-in reader (the simulator's own viewpoint).
    static let fakeHeadHeight: Float = 1.59
    /// v3 H1: how long the screen frame waits for a head pose before committing to its defaults.
    static let screenFrameDecisionWait: TimeInterval = 1.0
    /// V3-1b: low pass on the raw velocity estimate. Short enough to be a feed-forward rather than a memory,
    /// long enough that the object tracker's 2–4 mm of jitter at 30 Hz does not become 0.1 m/s of phantom lead.
    static let velocityTau: Float = 0.05
    /// Default `--carry-lead` (s) and the ceiling on the extrapolation it may produce (m).
    /// **V3-4 §7**: 0.05 → 0.03. The lead exists to cancel the smoother's delay; the 1€ filter has much
     /// less of it while the device is moving, and over-leading shows up as the card overshooting a stop.
     static let carryLeadDefault: Float = 0.03
    static let carryLeadMaxDistance: Float = 0.04
    /// 工作包 G. Bundle folder the `.referenceobject` ships in (a folder reference, see `project.yml`) …
    static let objectFolder = "objects"
    static let objectExtension = "referenceobject"
    /// … the detection rate we ask `ObjectTrackingProvider` for (the default is roughly 1/s; the card has to be
    /// found again the moment it comes back into view, and `session.run` falling back is handled at start) …
    /// **V3-4 §10** `--detection-rate <hz>`: a `var` now, because the first headset round waited 7.6 / 15 /
    /// 18 s for a re-detection after a loss and 10 Hz is the experiment that asks whether that is the app's
    /// side of the problem at all. `session.run` falling back when the rate is refused is handled at start.
    static var objectDetectionRate: Float = 5
    /// … and how fresh the image observation has to be to pair with an object one for a calibration sample.
    static let calibrationPairing: TimeInterval = 0.1
    /// 工作包 G2 rule 2: the gate must have been `expanded` this long before a co-observation counts. A card that
    /// has just landed is still being chased by two followers with different latencies, and that difference would
    /// be baked into the offset.
    static let calibrationSettle: TimeInterval = 3.0
    /// The refresh path writes the offset back at most this often …
    static let calibrationSaveInterval: TimeInterval = 5.0
    /// … and only once the running mean has actually moved this far (2 mm), which is also when it is worth a line.
    static let calibrationSaveDelta: Float = 0.002
    /// **Versioned** (G2). Before G2 the stored offset's translation was measured in the *raw* object frame and
    /// its rotation was a full quaternion; it is now measured in the object's gravity-aligned frame and is a yaw.
    /// A pre-G2 record restored into the new mapping sits several millimetres out until the refresh walks it home,
    /// and the app is launched from the headset's home view where `--recalibrate` cannot be typed — so the key
    /// carries the frame and an old record is simply not a record any more.
    private static let calibrationDefaultsPrefix = "spatialcard.objectToScreen.v2."
    /// The pre-G2 key, read only to delete it.
    private static let legacyCalibrationPrefix = "spatialcard.objectToScreen."

    static func calibrationKey(_ referenceObjectName: String) -> String {
        calibrationDefaultsPrefix + referenceObjectName
    }

    static func legacyCalibrationKey(_ referenceObjectName: String) -> String {
        legacyCalibrationPrefix + referenceObjectName
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init() {}

    // MARK: - Lifecycle

    func start() async {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        // Whatever session came before (failed, denied, stopped) is torn down first: one session at a time.
        teardown()
        status = .starting
        startTime = now
        // 工作包 G: the reference object is loaded before anything else — `ReferenceObject(from:configuration:)`
        // is async and `ObjectTrackingProvider` wants it at construction time. Nil (no scan yet, `--tracker
        // image`, or the simulator) simply means image-only, which is the state the app has to keep working in.
        let referenceObject = await loadReferenceObject()
        // v3 H1: in `object` mode a loaded reference object means there is nothing for the image tracker to do,
        // so it is not built at all — and its `isSupported` / "is there a reference image" guards, which would
        // otherwise refuse to start a session that does not need either, do not apply.
        let objectOnly = trackerMode == .object && referenceObject != nil
        effectiveMode = objectOnly ? .object : (trackerMode == .object ? .image : trackerMode)
        if trackerMode == .object, !objectOnly {
            print("[obj] object tracking unavailable (\(objectUnavailable ?? "no object source")); image only")
        }
        var images: [ReferenceImage] = []
        if objectOnly {
            // The manifest's own footprint stands in for the reference image's physical size (nothing reads a
            // reference image this run), and the `[theme]` audit still runs so a mismatched screen is noticed.
            let footprint = PassportManifest.shared.footprint
            referencePhysicalSize = CGSize(width: CGFloat(footprint.x), height: CGFloat(footprint.y))
            CardTracker.loadReferenceImages()
        } else {
            guard ImageTrackingProvider.isSupported else {
                status = .unsupported
                return
            }
            images = CardTracker.loadReferenceImages()
            referencePhysicalSize = images.first?.physicalSize
            guard !images.isEmpty else {
                status = .missingReferenceImage
                return
            }
        }
        // Providers cannot be re-run after stop(), so build a fresh session + providers every start.
        session = ARKitSession()
        // **V3-2b B6 / plan H4.** Hand tracking is asked for in the same breath as world sensing; a `no`
        // costs the bridge and nothing else, so it is deliberately not a reason to stop.
        var wanted: [ARKitSession.AuthorizationType] = [.worldSensing]
        if handBridgeEnabled, HandTrackingProvider.isSupported { wanted.append(.handTracking) }
        let authorization = await session.requestAuthorization(for: wanted)
        if authorization[.worldSensing] == .denied {
            status = .authorizationDenied
            return
        }
        if handBridgeEnabled, authorization[.handTracking] == .denied {
            handBridgeEnabled = false
            handsDenied = true
            print("[hand] denied")
        }

        // Built as a closure because the raised object detection rate may be refused: neither a session nor a
        // provider can be run twice, so the fallback builds both again.
        func makeProviders(objectDetectionRate: Float?) -> [any DataProvider] {
            var providers: [any DataProvider] = []
            if images.isEmpty {
                provider = nil
            } else {
                let imageProvider = ImageTrackingProvider(referenceImages: images)
                provider = imageProvider
                providers.append(imageProvider)
            }
            if WorldTrackingProvider.isSupported {
                let world = WorldTrackingProvider()
                worldProvider = world
                providers.append(world)
            }
            if PlaneDetectionProvider.isSupported {
                let planeProvider = PlaneDetectionProvider(alignments: [.horizontal])
                self.planeProvider = planeProvider
                providers.append(planeProvider)
            }
            // v2: no scene reconstruction by default. It competes with image tracking for the same sensors and the
            // two shipped worlds do not convert the room; `--mesh-at-start` restores the v1 arrangement.
            if meshAtStart, SceneReconstructionProvider.isSupported {
                let meshProvider = SceneReconstructionProvider(modes: [.classification])
                self.meshProvider = meshProvider
                providers.append(meshProvider)
                isMeshRunning = true
                print("[mesh] scene reconstruction in the main session (--mesh-at-start)")
            }
            // B6: the hand bridge's own provider. Off under `--no-hands`, absent in the simulator, and
            // absent when the wearer refused — in all three the app is exactly what it was before B6.
            if handBridgeEnabled, HandTrackingProvider.isSupported {
                let hands = HandTrackingProvider()
                handProvider = hands
                providers.append(hands)
            } else {
                handProvider = nil
            }
            if let referenceObject {
                var configuration = ObjectTrackingProvider.TrackingConfiguration()
                if let objectDetectionRate { configuration.detectionRate = objectDetectionRate }
                let objectProvider = ObjectTrackingProvider(referenceObjects: [referenceObject],
                                                            trackingConfiguration: configuration)
                self.objectProvider = objectProvider
                providers.append(objectProvider)
            } else {
                objectProvider = nil
            }
            return providers
        }

        var providers = makeProviders(objectDetectionRate: CardTracker.objectDetectionRate)
        var raisedRate = objectProvider != nil
        do {
            try await session.run(providers)
        } catch {
            guard objectProvider != nil else {
                status = .failed(String(describing: error))
                scheduleRetry()
                return
            }
            // Only the object provider is new here, and the raised detection rate is the only thing unusual about
            // it: drop back to the provider's own default rather than losing image tracking over an experiment.
            print(String(format: "[obj] detectionRate %.0f refused (%@); retrying with the provider default",
                         CardTracker.objectDetectionRate, String(describing: error)))
            raisedRate = false
            session.stop()
            session = ARKitSession()
            _ = await session.requestAuthorization(for: [.worldSensing])
            providers = makeProviders(objectDetectionRate: nil)
            do {
                try await session.run(providers)
            } catch {
                status = .failed(String(describing: error))
                scheduleRetry()
                return
            }
        }
        if let objectProvider {
            print(String(format: "[obj] running: detectionRate %.1f (%@) · %@",
                         objectProvider.trackingConfiguration.detectionRate,
                         raisedRate ? "raised" : "provider default",
                         objectProvider.trackingConfiguration.description))
        }

        retryAttempt = 0
        isRunning = true
        isPreview = false
        gate.beginSession()
        applyAutoShow()
        gate.directorMode = directorMode
        gate.legacyHide = legacyHide
        hasTrackedOnce = false
        firstDetectionTime = nil
        timeline = ["sessionRunning": now - startTime]
        planes.removeAll()
        anchors.removeAll()
        activeAnchorID = nil
        themeChangedAt = -.infinity
        surfaceY = nil
        surfaceIsDetectedPlane = false
        isFlat = true
        isInView = true
        presence = .absent
        status = .searching
        resetFusion()

        if let imageProvider = provider {
            updatesTask = Task { @MainActor [weak self] in
                for await update in imageProvider.anchorUpdates {
                    guard let self else { return }
                    self.handle(update)
                }
            }
        }
        if let objectProvider {
            objectTask = Task { @MainActor [weak self] in
                for await update in objectProvider.anchorUpdates {
                    guard let self else { return }
                    self.handle(update)
                }
            }
        }

        if let planeProvider {
            planeTask = Task { @MainActor [weak self] in
                for await update in planeProvider.anchorUpdates {
                    guard let self else { return }
                    self.handle(update)
                }
            }
        }
        if let meshProvider {
            meshTask = Task { @MainActor [weak self] in
                for await update in meshProvider.anchorUpdates {
                    guard let self else { return }
                    switch update.event {
                    case .added, .updated: self.meshAnchors[update.anchor.id] = update.anchor
                    case .removed: self.meshAnchors.removeValue(forKey: update.anchor.id)
                    }
                    self.onMeshAnchorsChanged?()
                }
            }
        }

        eventsTask = Task { @MainActor [weak self, session] in
            for await event in session.events {
                guard let self else { return }
                self.handle(event)
            }
        }

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }

        // The space was reopened while a world that needs the room mesh was already known: bring it back.
        if meshRequested, !meshAtStart { startSceneReconstruction(reason: "session restart") }
    }

    // MARK: - Reference object (工作包 G)

    /// The `.referenceobject` this run should track, if there is one. Everything about it is optional by design:
    /// the Create ML scan of the AI Passport is not in the repo, and the app must build, launch and track
    /// image-only without it — which is also the whole of the simulator's story, where
    /// `ObjectTrackingProvider.isSupported` is false.
    private func loadReferenceObject() async -> ReferenceObject? {
        objectUnavailable = nil
        guard trackerMode != .image else {
            print("[obj] --tracker image: no object provider")
            objectUnavailable = "--tracker image"
            return nil
        }
        guard ObjectTrackingProvider.isSupported else {
            print("[obj] object tracking is not supported here; image only")
            objectUnavailable = "ObjectTrackingProvider.isSupported == false"
            return nil
        }
        guard let url = CardTracker.referenceObjectURL(explicit: objectPath) else {
            print("[obj] no reference object; image only")
            objectUnavailable = "no .referenceobject in the bundle"
            return nil
        }
        var configuration = ReferenceObject.Configuration()
        // visionOS 27 replaced the deprecated stationary / moving tracking rates with this one switch. The card
        // is a 37 × 49 mm slab that gets picked up: the whole point of G is that it keeps up while it moves.
        configuration.highFrameRateTrackingEnabled = true
        do {
            let object = try await ReferenceObject(from: url, configuration: configuration)
            referenceObjectName = object.name
            // v3 H1: only `both` still calibrates. In `object` mode the mapping *is* `ObjectScreenFrame`, and a
            // record restored from an earlier `both` session would silently replace it — with an offset
            // measured against an image tracker this run never runs.
            calibration = trackerMode == .both ? loadCalibration(named: object.name) : ObjectScreenCalibration()
            screenFlips = loadScreenFlips(named: object.name)
            print("[obj] loaded \(object.name) highFrameRate=true")
            return object
        } catch {
            print("[obj] \(url.lastPathComponent) failed to load (\(error)); image only")
            objectUnavailable = "\(url.lastPathComponent) failed to load"
            return nil
        }
    }

    // MARK: - Screen frame (v3 H1)

    /// The two signs for this reference object: `--screen-side` / `--screen-yaw` first, then whatever an
    /// earlier session decided from the head. Nil = undecided, and the first tracked observation with a head
    /// pose settles it.
    private func loadScreenFlips(named name: String) -> ObjectScreenFrame.Flips? {
        if let flips = flagFlips {
            print("[obj] --screen-side / --screen-yaw: side \(flips.side ? "-" : "+")Y, yaw \(flips.yaw ? 180 : 0)")
            saveScreenFlips(flips)
            return flips
        }
        guard let raw = UserDefaults.standard.array(forKey: ObjectScreenFrame.defaultsKey(name)) as? [Int],
              let flips = ObjectScreenFrame.decode(raw) else { return nil }
        print("[obj] restored screen frame for \(name): side \(flips.side ? "-" : "+")Y, yaw \(flips.yaw ? 180 : 0)")
        return flips
    }

    /// Only a real, named reference object is persisted — the `--fake-track` harness must not leave a decision
    /// behind, or its second run would start pre-decided and prove nothing (the same rule as `saveCalibration`).
    private func saveScreenFlips(_ flips: ObjectScreenFrame.Flips) {
        guard let name = referenceObjectName, !isFakeTrack else { return }
        UserDefaults.standard.set(ObjectScreenFrame.encode(flips), forKey: ObjectScreenFrame.defaultsKey(name))
    }

    /// `--screen-side` / `--screen-yaw`, when either was passed.
    private var flagFlips: ObjectScreenFrame.Flips? {
        guard screenSideFlipOverride != nil || screenYawFlipOverride != nil else { return nil }
        return ObjectScreenFrame.Flips(side: screenSideFlipOverride ?? false, yaw: screenYawFlipOverride ?? false)
    }

    /// The box the active anchor reported: builds the frame the first time, and adopts a stored / flagged
    /// decision straight away so the very first observation is already mapped the right way round.
    private func noteObjectBox(_ box: ObjectScreenFrame.Box) {
        if let existing = screenFrame, existing.box == box { return }
        var frame = ObjectScreenFrame(box: box)
        // A flag wins over a stored record, and both mean the frame is decided before the first observation —
        // including under `--fake-track`, which never reaches `loadReferenceObject`.
        if let flips = flagFlips ?? screenFlips { frame.adopt(flips) }
        screenFrame = frame
        if frame.isDecided { print(frame.describe(decision: nil)) }
    }

    /// Decide the side / yaw signs from the head, **before** this observation is forwarded, and persist them.
    /// With no head pose yet (the simulator, or the first frames on the headset) the frame keeps its defaults
    /// for up to a second and is then committed to them, so the card is never held back waiting for a decision.
    private func decideScreenFrame(objectPose: simd_float4x4, at time: TimeInterval) {
        guard var frame = screenFrame, !frame.isDecided else { return }
        if frameDecisionDeadline == nil { frameDecisionDeadline = time + CardTracker.screenFrameDecisionWait }
        if let head = devicePose() {
            let position = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            let decision = ObjectScreenFrame.decision(box: frame.box, objectPose: objectPose, headPosition: position)
            frame.adopt(decision.flips)
            screenFrame = frame
            screenFlips = decision.flips
            saveScreenFlips(decision.flips)
            print(frame.describe(decision: decision))
            // The mapping just changed underneath the object stream: that is a change of *frame*, not the
            // device moving, so the low pass starts again rather than gliding the flip in over τ.
            smoother.reset()
            return
        }
        guard let deadline = frameDecisionDeadline, time >= deadline else { return }
        frame.adopt(ObjectScreenFrame.Flips())
        screenFrame = frame
        print(frame.describe(decision: nil) + " — no head pose after \(String(format: "%.1f", CardTracker.screenFrameDecisionWait)) s, defaults")
    }

    /// Where a reference object may be: `--object <path>` (absolute, or a name bundled from `Tools/`), the
    /// bundled `objects/` folder reference (first by name — one device, one object), or the bundle root, so a
    /// file dropped next to the fake-track scripts also works.
    static func referenceObjectURL(explicit: String?) -> URL? {
        let manager = FileManager.default
        if let explicit {
            if let url = ScriptFile.url(explicit) { return url }
            return nil
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        for directory in [resources.appendingPathComponent(objectFolder), resources] {
            let contents = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            if let url = contents.filter({ $0.pathExtension == objectExtension })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).first {
                return url
            }
        }
        return nil
    }

    /// The stored `objectToScreen` for this reference object, so the second run of the day starts calibrated.
    /// `--recalibrate` throws it away first.
    private func loadCalibration(named name: String) -> ObjectScreenCalibration {
        let key = CardTracker.calibrationKey(name)
        let legacyKey = CardTracker.legacyCalibrationKey(name)
        let defaults = UserDefaults.standard
        if recalibrate {
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: legacyKey)
            print("[obj] --recalibrate: the stored offset for \(name) is forgotten")
            return ObjectScreenCalibration()
        }
        // An offset written before G2 is in the wrong frame (see `calibrationDefaultsPrefix`). Throw it away
        // rather than restore it: a fresh calibration takes a few seconds on the desk, a wrong one takes ~20 s of
        // refresh to heal and is a few millimetres off the whole time.
        if defaults.object(forKey: legacyKey) != nil {
            defaults.removeObject(forKey: legacyKey)
            print("[obj] discarded pre-v2 calibration for \(name) (its offset was measured in the raw object frame)")
        }
        guard let stored = defaults.array(forKey: key) as? [Double],
              let matrix = ObjectScreenCalibration.matrix(stored.map(Float.init)) else {
            return ObjectScreenCalibration()
        }
        let t = ObjectScreenCalibration.translation(of: matrix) * 1000
        print(String(format: "[obj] restored calibration for %@: offset (%.1f, %.1f, %.1f) mm", name, t.x, t.y, t.z))
        return ObjectScreenCalibration(restored: matrix)
    }

    /// Only a real, named reference object is persisted: `--fake-track`'s scripted object source must not leave a
    /// calibration behind, or the second run of the harness would start pre-calibrated and prove nothing.
    ///
    /// G2: the running mean keeps moving after it converges, so this is throttled — at most one write every
    /// `calibrationSaveInterval`, and only once the offset has actually walked `calibrationSaveDelta` from what
    /// was stored. The line it prints is the evidence that a stale calibration is healing.
    private func saveCalibration(offset: simd_float4x4, at time: TimeInterval, force: Bool) {
        guard let name = referenceObjectName, calibration.isConverged else { return }
        let moved = savedOffset.map { PresenceGate.delta(from: $0, to: offset).distance } ?? .greatestFiniteMagnitude
        if !force {
            guard time - savedAt >= CardTracker.calibrationSaveInterval,
                  moved >= CardTracker.calibrationSaveDelta else { return }
            let t = ObjectScreenCalibration.translation(of: offset) * 1000
            print(String(format: "[obj] recalibrated: offset (%.1f, %.1f, %.1f) mm, yaw %.1f° (moved %.1f mm)",
                         t.x, t.y, t.z, calibration.meanYaw * 180 / .pi, moved * 1000))
        }
        savedOffset = offset
        savedAt = time
        UserDefaults.standard.set(ObjectScreenCalibration.floats(offset).map(Double.init),
                                  forKey: CardTracker.calibrationKey(name))
    }

    /// A world that converts the real room is about to be built (`WorldEngine.onNeedsRoomMesh`): start scene
    /// reconstruction in a **second** `ARKitSession`, so the image-tracking session keeps running untouched.
    /// Idempotent, and a no-op where the provider does not exist (simulator).
    func startSceneReconstruction(reason: String) {
        meshRequested = true
        guard !isMeshRunning, !meshUnsupported, meshSession == nil else { return }
        guard SceneReconstructionProvider.isSupported else {
            meshUnsupported = true
            print("[mesh] scene reconstruction is not available here (\(reason))")
            return
        }
        isMeshRunning = true          // set before the task: the hook can fire again on the next tick
        print("[mesh] starting scene reconstruction in a second session (\(reason))")
        let session = ARKitSession()
        let provider = SceneReconstructionProvider(modes: [.classification])
        meshSession = session
        meshProvider = provider
        meshTask = Task { @MainActor [weak self] in
            _ = await session.requestAuthorization(for: [.worldSensing])
            do {
                try await session.run([provider])
            } catch {
                print("[mesh] scene reconstruction failed to start: \(error)")
                self?.isMeshRunning = false
                return
            }
            for await update in provider.anchorUpdates {
                guard let self else { return }
                switch update.event {
                case .added, .updated: self.meshAnchors[update.anchor.id] = update.anchor
                case .removed: self.meshAnchors.removeValue(forKey: update.anchor.id)
                }
                self.onMeshAnchorsChanged?()
            }
        }
    }

    /// `--refs base,neon-city`: register only these themes' reference images. `ImageTrackingProvider` cannot be
    /// changed after `run`, so this is the only way to ask "does one image lock on faster than three?" (experiment
    /// E3). Empty = all of them.
    static var referenceThemeFilter: [String] = []

    /// Loads the resource group and checks it against the manifest (`[theme] N reference images, width …`;
    /// `[theme] physical width mismatch` if a `Contents.json` width differs from the manifest by > 1 mm).
    @discardableResult
    static func loadReferenceImages() -> [ReferenceImage] {
        var images = ReferenceImage.loadReferenceImages(inGroupNamed: resourceGroupName)
        let manifest = PassportManifest.shared
        if !referenceThemeFilter.isEmpty {
            let wanted = Set(referenceThemeFilter)
            let kept = images.filter { image in
                let name = image.name ?? ""
                return wanted.contains(name) || manifest.theme(forReferenceImage: name).map { wanted.contains($0.id) } ?? false
            }
            if kept.isEmpty {
                print("[theme] --refs \(referenceThemeFilter.joined(separator: ",")) matched no reference image; keeping all \(images.count)")
            } else {
                print("[theme] --refs \(referenceThemeFilter.joined(separator: ",")): \(kept.count) of \(images.count) reference images registered")
                images = kept
            }
        }
        print(String(format: "[theme] %d reference images, width %.4f m (manifest %.4f m): %@", images.count,
                     Float(images.first?.physicalSize.width ?? 0), manifest.physicalWidthMeters,
                     images.map { $0.name ?? "?" }.joined(separator: ", ")))
        for image in images {
            let width = Float(image.physicalSize.width)
            if abs(width - manifest.physicalWidthMeters) > 0.001 {
                print(String(format: "[theme] physical width mismatch: %@ is %.4f m, manifest says %.4f m", image.name ?? "?", width, manifest.physicalWidthMeters))
            }
            if manifest.theme(forReferenceImage: image.name ?? "") == nil {
                print("[theme] reference image \(image.name ?? "?") is not in passport-manifest.json")
            }
        }
        if referenceThemeFilter.isEmpty {
            // Only a complete registration can be checked against the manifest; `--refs` leaves images out on purpose.
            for theme in manifest.themes where !images.contains(where: { $0.name == theme.referenceImage }) {
                print("[theme] manifest theme \(theme.id) has no reference image \(theme.referenceImage) in the catalog")
            }
        }
        return images
    }

    /// Preview mode (simulator / no device): no ARKit, but the same gate — the virtual card at `pose` is
    /// "observed" 10× a second so the reveal, replay, holds and the fake device all run the real state machine.
    /// Like the device, nothing is observed while paused (`.full`), and after unpausing the card is only "seen"
    /// again `reacquireDelay` seconds later.
    func startPreview(pose: simd_float4x4, reacquireDelay: TimeInterval = 0) {
        guard !isRunning, !isStarting else { return }
        teardown()
        CardTracker.loadReferenceImages()
        // Preview parks a virtual *image* anchor: there is no object source to run `--tracker object` against.
        effectiveMode = trackerMode == .object ? .image : trackerMode
        isRunning = true
        isPreview = true
        gate.beginSession()
        gate.directorMode = directorMode
        gate.legacyHide = legacyHide
        // Preview mode has no ARKit session to put the provider in; route the flag through the same call so the
        // `[mesh]` line still says which arrangement this run asked for.
        if meshAtStart { startSceneReconstruction(reason: "--mesh-at-start") }
        startTime = now
        latestPose = pose
        isTracked = true
        isFlat = true
        isInView = true
        hasTrackedOnce = true
        presence = .absent
        status = .tracking
        previewTask = Task { @MainActor [weak self] in
            var unpausedAt: TimeInterval?
            var wasPaused = false
            while !Task.isCancelled {
                guard let self else { return }
                let time = self.now
                if self.isPaused {
                    wasPaused = true
                } else {
                    if wasPaused { wasPaused = false; unpausedAt = time }
                    if time - (unpausedAt ?? -.infinity) >= reacquireDelay {
                        self.gate.observe(pose: pose, isTracked: true, isFlat: true, at: time)
                        self.summaryUpdates += 1
                        self.noteTrackedObservation(pose: pose, at: time)
                    }
                }
                self.gate.tick(at: time)
                self.sync()
                self.summarize(at: time)
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// `--fake-track <path>`: the simulator has no image tracking, so **no ARKit session is started** — but the
    /// 20 Hz tick, the gate and `ingest(...)` are the real ones, driven by a scripted pose track. This is what lets
    /// the pose follower, the continuity gate, the relocation rule and the light well be watched in the simulator
    /// instead of first running on the wearer's headset. Run it **without** `--preview`: preview parks the card
    /// itself every frame and never calls `apply(pose:)`.
    func startFakeTrack(scriptURL: URL?) {
        guard !isRunning, !isStarting else { return }
        teardown()
        CardTracker.loadReferenceImages()
        let samples = FakeTrackScript.expand(FakeTrackScript.load(scriptURL), box: fakeBox)
        let objectSamples = samples.filter { $0.source == .object }.count
        isRunning = true
        isPreview = false
        isFakeTrack = true
        // v3 H1: the simulator has no `WorldTrackingProvider`, so stand a reader where the simulator's own
        // viewpoint is. The screen frame's side / yaw decision and the hand card's facing policy both need a
        // head, and both are things this harness exists to rehearse.
        fakeHeadPose = simd_float4x4(SIMD4<Float>(1, 0, 0, 0), SIMD4<Float>(0, 1, 0, 0),
                                     SIMD4<Float>(0, 0, 1, 0), SIMD4<Float>(0, CardTracker.fakeHeadHeight, 0, 1))
        // …and the same mode rule `start()` applies: a script with no object segments cannot run in object
        // mode, and silently forwarding nothing would look like the app being broken rather than the script.
        if trackerMode == .object, objectSamples == 0 {
            effectiveMode = .image
            print("[obj] object tracking unavailable (the script has no object segments); image only")
        } else {
            effectiveMode = trackerMode
        }
        gate.beginSession()
        applyAutoShow()
        gate.directorMode = directorMode
        gate.legacyHide = legacyHide
        startTime = now
        timeline = ["sessionRunning": 0]
        hasTrackedOnce = false
        firstDetectionTime = nil
        planes.removeAll()
        anchors.removeAll()
        activeAnchorID = nil
        themeChangedAt = -.infinity
        surfaceY = nil
        surfaceIsDetectedPlane = false
        isFlat = true
        isInView = true
        presence = .absent
        status = .searching
        resetFusion()
        print("[track] --fake-track: \(samples.count) scripted observations (\(objectSamples) from the object source), no ARKit session")

        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self else { return }
                self.tick()
            }
        }
        // For each sample, the next one from the same source (precomputed once): the runner uses it to drop a
        // backlog rather than replay it — see below.
        var nextFromSameSource = [Int?](repeating: nil, count: samples.count)
        var lastIndex: [TrackingFusion.Source: Int] = [:]
        for index in stride(from: samples.count - 1, through: 0, by: -1) {
            nextFromSameSource[index] = lastIndex[samples[index].source]
            lastIndex[samples[index].source] = index
        }

        trackTask = Task { @MainActor [weak self] in
            let start = ProcessInfo.processInfo.systemUptime
            for (index, sample) in samples.enumerated() {
                let wait = sample.at - (ProcessInfo.processInfo.systemUptime - start)
                if wait > 0 {
                    try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                } else if sample.note == nil, let next = nextFromSameSource[index],
                          samples[next].at <= ProcessInfo.processInfo.systemUptime - start {
                    // The runner has fallen behind — in the simulator a world prebuild stalls the main actor for
                    // 200–250 ms, and on the headset a hitch does the same. A provider does not replay its history
                    // afterwards, it reports where the thing is *now*, so an observation that a newer one from the
                    // same source has already overtaken is dropped instead of ingested late. Without this the
                    // catch-up burst arrives with the *other* source looking 300 ms stale and the fusion hands the
                    // card over for a single tick. Segments that emit one sample ("a detection 30 cm away" —
                    // they all carry a `note`) are never dropped: nothing supersedes them.
                    continue
                }
                guard !Task.isCancelled, let self else { return }
                if let note = sample.note { print(String(format: "[track] %6.2f s  %@", sample.at, note)) }
                self.fakeSurfaceY = sample.surfaceY
                // v4 B4 §3.3: a scripted head moves the harness's reader.
                if let head = sample.head { self.fakeHeadPose?.columns.3 = SIMD4<Float>(head.x, head.y, head.z, 1) }
                // B6: the scripted hand, before the object observation of the same instant — the bridge has
                // to know where the hand is *now* when it is asked to carry the card.
                if let hand = sample.hand, self.handBridgeEnabled {
                    self.bridge.observeHand(HandBridge.Side(rawValue: hand.side) ?? .left,
                                            pose: hand.pose, tracked: hand.isTracked, at: self.now)
                }
                // Same two entry points the real providers use, so the fusion, the calibration and the source
                // switch are the shipping ones — only the anchors are scripted.
                switch sample.source {
                case .image:
                    self.observeImage(pose: sample.pose, isTracked: sample.isTracked, at: self.now)
                case .object:
                    // v3 H1: the harness reports a bounding box, so `ObjectScreenFrame` — the mapping the headset
                    // uses — is what places the card here too. V3-1b: which box is `--fake-box`'s business, and
                    // the default is the one the headset really sends.
                    self.observeObject(rawPose: sample.pose, isTracked: sample.isTracked,
                                       box: self.fakeBox, at: self.now)
                }
                self.sync()
            }
            print("[track] script finished")
        }
    }

    func stop() {
        retryTask?.cancel()
        retryTask = nil
        teardown()
        latestPose = nil
        isFlat = true
        isInView = true
        surfaceY = nil
        surfaceIsDetectedPlane = false
        hintDevicePose = nil
        planes.removeAll()
        status = .idle
    }

    /// Cancels every session task, stops the session (unconditionally: a never-run session ignores it), drops the
    /// providers and hides whatever the gate shows (`.hide` is queued for the controller). Safe to call repeatedly;
    /// `status` is left to the caller (failed / denied / idle).
    private func teardown() {
        // v4 B2 §3.2: the segment running at the end of a session reports before the tracker forgets it.
        if let line = watch.endEpisode(at: now, reason: "session over") { print(line) }
        if let summary = watch.finish(at: now) { print(summary) }
        watch = V4.TrackingWatch()
        for task in [updatesTask, objectTask, planeTask, meshTask, eventsTask, tickTask, previewTask, trackTask] { task?.cancel() }
        updatesTask = nil
        objectTask = nil
        planeTask = nil
        meshTask = nil
        eventsTask = nil
        tickTask = nil
        previewTask = nil
        trackTask = nil
        fakeSurfaceY = nil
        fakeHeadPose = nil
        isFakeTrack = false
        session.stop()
        meshSession?.stop()
        meshSession = nil
        isMeshRunning = false
        provider = nil
        objectProvider = nil
        worldProvider = nil
        handProvider = nil
        bridge.reset()
        bridgeDriving = false
        planeProvider = nil
        meshProvider = nil
        meshAnchors.removeAll()
        resetSummary()
        isRunning = false
        isPreview = false
        isTracked = false
        isPaused = false
        anchors.removeAll()
        activeAnchorID = nil
        resetFusion()
        lastRejectLog.removeAll()
        gate.forceHide(at: now, reason: "session teardown")
        sync()
    }

    /// After `.failed` / `.authorizationDenied` (or from `scenePhase == .active`): start again if not running.
    func retry() {
        guard !isRunning, !isStarting else { return }
        retryTask?.cancel()
        retryTask = nil
        retryAttempt = 0
        Task { @MainActor [weak self] in await self?.start() }
    }

    /// `scenePhase == .active`: restart a session that failed or was denied (permission granted in Settings).
    func retryIfNeeded() {
        switch status {
        case .failed, .authorizationDenied: retry()
        default: break
        }
    }

    /// Opens the app's page in Settings so the wearer can grant World Sensing.
    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func scheduleRetry() {
        guard retryAttempt < CardTracker.maxRetries else {
            print("[gate] tracking failed \(retryAttempt) times; giving up until retry()")
            return
        }
        let delay = pow(2.0, Double(retryAttempt))
        retryAttempt += 1
        print(String(format: "[gate] tracking failed; retry %d in %.0f s", retryAttempt, delay))
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, !self.isRunning, !self.isStarting else { return }
            await self.start()
        }
    }

    // MARK: - Gate API

    /// Pops the next presence event (FIFO). The RealityView update closure drains this every time `presence` changes.
    func takeTransition() -> PresenceGate.Event? {
        gate.takeEvent()
    }

    /// `.full` immersion (image tracking stops): the gate skips staleness and grace until unpaused.
    func setPaused(_ paused: Bool) {
        guard paused != isPaused else { return }
        isPaused = paused
        gate.setPaused(paused, at: now)
        // **V3-5 §1.** The bridge stands down for the world and treats the unpause as the loss instant, so
        // the wearer coming back out of a world with the passport still in their hand is bridged home
        // instead of frozen. See `HandBridge.setPaused(_:at:)`.
        if paused { endBridgeDriving(reason: "the world took over") }
        bridge.setPaused(paused, at: now)
        print("[gate] paused = \(paused)")
        sync()
    }

    /// **V3-5 §2.** How long the passport has been standing still, on the desk gate's own 0.3 s windowed
    /// speed estimate (`DeskOrientationGate.stillSpeed` = 0.04 m/s). The world engine's in-hand prebuild
    /// waits for it: a 200 ms build while the wearer is moving the card is a visible stall, and the same
    /// 200 ms while they hold still is one held frame.
    var stillSeconds: TimeInterval { deskGate.stillFor(at: now) }

    /// A world took over (hold, unlimited) / gave the desk back (thaw when the card is seen again, 6 s window).
    func setWorldActive(_ active: Bool) {
        if active { gate.beginHold(.world, at: now) } else { gate.endHold(.world, at: now) }
        sync()
    }

    /// **V3-2a2 S2.** How much of the object stream was locked on over the last `seconds`, as a percentage,
    /// or nil when there were no object updates in that window at all (image-only, or the anchor has not
    /// been seen yet). This is the same ratio `Σ objTracked=` prints, over a window the caller chooses.
    func objectTrackedPercent(over seconds: TimeInterval) -> Float? {
        let cutoff = now - seconds
        // The newest sample at or before the cutoff is the window's opening balance.
        let opening = objectTrail.last { $0.at <= cutoff }
        let tracked = objectTrackedTotal - (opening?.tracked ?? 0)
        let all = objectUpdatesTotal - (opening?.all ?? 0)
        guard all > 0 else { return nil }
        return 100 * Float(tracked) / Float(all)
    }

    /// Fold the card into the device and keep it away until `requestShow()` (base-ring tap, Hub `cmd hide`).
    func requestDismiss() {
        gate.requestDismiss(at: now)
        sync()
    }

    /// Bring a dismissed card back on the next detection, as a reentry (socket tap, Hub `cmd show`) — or, with
    /// `replayRecognition` (v4 B3: OK / `cmd show` without `--v3-card`), as the session's first recognition again.
    func requestShow(replayRecognition: Bool = false) {
        gate.requestShow(at: now, replayRecognition: replayRecognition)
        sync()
    }

    /// True while the card is folded away on purpose (the socket light is the way back). Mirrored out of the
    /// gate in `sync()` rather than read through it, so the RealityView does not end up observing the gate
    /// struct itself — that mutates 20 times a second.
    private(set) var isDismissed = false

    /// Hide now, cinematic reveal 1.3 s later (base-ring tap, `--replay-after`, director `cmd replay`).
    func requestReplay() {
        gate.requestReplay(at: now)
        sync()
    }

    /// Device messages the gate cares about: button nudges, and the screen-redraw handshake.
    func handleDevice(_ event: DeviceGateEvent) {
        let time = now
        switch event {
        case .button:
            // v3 H1 §5: the 1.5 s hold exists because a thumb on a 37 mm **image** hides it and the nudge would
            // drag the pose. The object tracker is looking at the whole slab and does not care, and a card that
            // freezes for 1.5 s in the wearer's hand every time they press OK reads as a hang.
            guard activeSource != .object else {
                print("[gate] button: no hold (object source)")
                break
            }
            gate.buttonPressed(at: time)
        case .willChange:
            gate.beginHold(.theme, at: time)
        case .changed(let theme):
            var newTheme: PassportManifest.Theme?
            if let theme, let t = PassportManifest.shared.theme(id: theme) {
                newTheme = t
                if t.id != currentTheme.id {
                    currentTheme = t
                    print("[theme] expected = \(t.id) (device changed)")
                }
            }
            // Only the new image counts as "tracked recently": the old one is about to go untracked, and thawing on
            // it would blink (thaw → freeze → thaw). A differing theme retires the old anchor and waits in
            // held(.stale) with the 8 s reacquire window; for that window only the new theme's image may lock on.
            let activeTheme = activeAnchorID.flatMap { anchors[$0] }?.theme?.id
            var trackedRecently: Bool? = nil
            if let newTheme, activeTheme != newTheme.id {
                trackedRecently = false
                themeChangedAt = time
                if activeAnchorID != nil {
                    print("[theme] retiring anchor \(activeTheme ?? "?") — waiting for \(newTheme.id)")
                    activeAnchorID = nil
                    isTracked = false
                }
            }
            gate.endHold(.theme, trackedRecently: trackedRecently, at: time)
        }
        sync()
    }

    /// The screen the device shows (`hello`, `--theme`): the reference image to expect before anything is tracked.
    func setExpectedTheme(_ id: String, reason: String = "expected") {
        guard let t = PassportManifest.shared.theme(id: id), t.id != currentTheme.id else { return }
        currentTheme = t
        print("[theme] expected = \(t.id) (\(reason))")
    }

    /// While held inside a `.mixed` world: how far the tracked card moved from the frozen pose (pick-up = exit).
    var heldDisplacement: Float { gate.heldDisplacement }

    /// `--auto-show never`: the session starts folded away, so even the first detection is an OK press.
    /// `gate.beginSession()` resets `isDismissed`, which is why this runs **after** it rather than at init.
    private func applyAutoShow() {
        guard autoShow == .never else { return }
        gate.requestDismiss(at: now)
        print("[gate] --auto-show never: starting folded away (the socket light is the way back; press OK)")
    }

    /// v3 H1 §3: which acceptance rules the continuity gate runs. The image source keeps the desk tests it was
    /// written for; the object source gets the velocity test, because its in-hand detections are tilted and
    /// 20 cm higher *by definition* and the desk tests threw every one of them away.
    private func applyAcceptancePolicy() {
        let deskOnly = activeSource != .object
        guard gate.deskOnlyAcceptance != deskOnly else { return }
        gate.deskOnlyAcceptance = deskOnly
        print("[gate] acceptance: \(deskOnly ? "desk (image source)" : "velocity (object source)")")
    }

    // MARK: - Image anchors

    private func handle(_ update: AnchorUpdate<ImageAnchor>) {
        let anchor = update.anchor
        let time = now
        let name = anchor.referenceImage.name ?? ""
        anchorUpdateCount += 1
        switch update.event {
        case .added, .updated:
            var record = anchors[anchor.id] ?? AnchorRecord(imageName: name, theme: PassportManifest.shared.theme(forReferenceImage: name),
                                                            isTracked: false, lastUpdate: time, pose: anchor.originFromAnchorTransform)
            record.isTracked = anchor.isTracked
            record.lastUpdate = time
            record.pose = anchor.originFromAnchorTransform
            anchors[anchor.id] = record
            if anchor.isTracked {
                if activeAnchorID != anchor.id {
                    // Switch only to the image the device says it shows, or when the active anchor is gone
                    // (untracked / stale for more than staleSoft) — outside the strict window after a `changed`.
                    // A false positive on a sibling theme (same size, shared followers strip) must not hijack the pose.
                    let matchesDevice = record.theme?.id == currentTheme.id
                    let active = activeAnchorID.flatMap { anchors[$0] }
                    let activeGone = active.map { !$0.isTracked || time - $0.lastUpdate > gate.staleSoft } ?? true
                    let strict = time - themeChangedAt < gate.themeReacquireWindow
                    guard matchesDevice || (activeGone && !strict) else {
                        if time - (lastRejectLog[anchor.id] ?? -.infinity) > 2 {
                            lastRejectLog[anchor.id] = time
                            print("[theme] rejected switch to \(name) (device shows \(currentTheme.id)\(strict ? ", reacquire window" : ", active anchor still tracked"))")
                        }
                        return
                    }
                    activeAnchorID = anchor.id
                    lastJitterPose = nil          // a different image: the step between the two is not jitter
                    if let theme = record.theme, theme.id != currentTheme.id { currentTheme = theme }
                    print("[theme] active = \(name)")
                }
                referencePhysicalSize = anchor.referenceImage.physicalSize
                observeImage(pose: anchor.originFromAnchorTransform, isTracked: true, at: time)
            } else if activeAnchorID == anchor.id {
                observeImage(pose: anchor.originFromAnchorTransform, isTracked: false, at: time)
            }
        case .removed:
            anchors.removeValue(forKey: anchor.id)
            if activeAnchorID == anchor.id {
                activeAnchorID = nil
                isTracked = false
                // The image anchor is gone. That is a freeze only while the image is the *source*: with the object
                // tracker holding the card it is one of two sources going quiet, which the fusion answers by
                // staying where it is. `markRemoved` is the path for "there is no pose to hand over at all".
                if let last = latestPose {
                    observeImage(pose: last, isTracked: false, at: time)
                } else {
                    gate.markRemoved(at: time)
                }
            }
        }
        sync()
    }

    // MARK: - Object anchors (工作包 G)

    private func handle(_ update: AnchorUpdate<ObjectAnchor>) {
        let anchor = update.anchor
        let time = now
        switch update.event {
        case .added, .updated:
            if activeObjectID != anchor.id {
                activeObjectID = anchor.id
                referenceObjectName = anchor.referenceObject.name
                print("[obj] anchor \(anchor.referenceObject.name) (tracked=\(anchor.isTracked))")
            }
            let box = anchor.boundingBox
            observeObject(rawPose: anchor.originFromAnchorTransform, isTracked: anchor.isTracked,
                          box: ObjectScreenFrame.Box(center: box.center, extent: box.extent), at: time)
        case .removed:
            if activeObjectID == anchor.id {
                activeObjectID = nil
                print("[obj] anchor removed")
                observeObject(rawPose: anchor.originFromAnchorTransform, isTracked: false, box: nil, at: time)
            }
        }
        sync()
    }

    // MARK: - Source fusion (工作包 G)

    /// One **image** observation, from the real `ImageTrackingProvider` or from a `--fake-track` script. It is
    /// offered to the fusion and only reaches `ingest` while the image is the active source: with the object
    /// tracker holding the card, an untracked image observation is one of two sources going quiet, not a reason
    /// to freeze the hologram. (That is exactly what segment 3 of `fake-track-object.json` checks.)
    private func observeImage(pose: simd_float4x4, isTracked: Bool, at time: TimeInterval) {
        fusion.note(image: TrackingFusion.Sample(pose: pose, isTracked: isTracked, time: time))
        if isTracked { summaryUpdates += 1 }
        forward(candidate: .image, at: time)
    }

    /// One **object** observation, in the trained object's own frame. It is mapped into the screen frame here —
    /// the calibrated offset once it has converged, the anchor's own bounding box until then — so that everything
    /// below `ingest` keeps receiving the one pose it has always received: the centre of the screen, +Y its normal.
    private func observeObject(rawPose: simd_float4x4, isTracked: Bool, box: ObjectScreenFrame.Box?, at time: TimeInterval) {
        objectUpdateCount += 1
        summaryObjectUpdatesAll += 1
        objectUpdatesTotal += 1
        // v4 B2 §3.2: the segment's tracked share, rate and losses.
        // v4 B4 §4: with the view of the device at this observation (off the gaze, off its screen's normal).
        let angles = isTracked ? V4.TrackingWatch.angles(head: latestDevicePose, pose: rawPose * objectToScreen) : nil
        watch.observe(tracked: isTracked, at: time, angles: angles)
        // v4 B5 §6: and into the Σ window, so the line says how the device is seen while it *is* tracked.
        if let angles { summaryNormal.add(angles.offNormal) }
        if isTracked {
            summaryObjectUpdates += 1
            objectTrackedTotal += 1
        }
        if time - objectTrailLast >= CardTracker.objectTrailPeriod {
            objectTrailLast = time
            objectTrail.append((at: time, tracked: objectTrackedTotal, all: objectUpdatesTotal))
            // Twice the widest window anyone asks for is plenty.
            if objectTrail.count > CardTracker.objectTrailMax { objectTrail.removeFirst() }
        }
        objectTracked = isTracked
        lastObjectUpdate = time
        if isTracked { lastObjectTrackedUpdate = time }
        latestObjectRawPose = rawPose
        // **V3-6 §4.** The camera has the passport again. A *desk* loss ends here and says how long it was
        // — it is never going to become a pick-up. A grab (or an unclassifiable loss) keeps its clock, which
        // `sync` stops when the card reaches `carrying` and drops silently if it reaches `expanded` instead.
        if isTracked, let seconds = lossClock.found(at: time) {
            print(String(format: "[timing] desk loss %.1f s", seconds))
        }
        if let box { noteObjectBox(box) }
        // v3 H1: the screen frame's side / yaw are settled **before** this observation is forwarded, so the
        // card is never placed on the back of the device for a frame and then flipped.
        if isTracked { decideScreenFrame(objectPose: rawPose, at: time) }
        if isTracked, effectiveMode == .both { updateCalibration(objectPose: rawPose, at: time) }

        // 工作包 G2, rule 1. The object pose as the object tracker reports it, in the screen frame — the raw
        // signal the desk gate judges, and the `objTilt=` the Σ line prints. (With a yaw-only offset this is the
        // object anchor's own tilt: a rotation about world +Y cannot change how far +Y is from gravity.)
        let offset = objectToScreen
        let raw = rawPose * offset
        // **V3-2b B6 / plan H4.** Every tracked observation teaches the bridge how the wearer's hand is
        // holding the device; an untracked one is exactly what it exists for.
        if handBridgeEnabled {
            bridge.observeObject(screen: raw, tracked: isTracked, at: time)
            // The bridge gets the last word on every object observation: it carries the card while the
            // object is missing, and eases it back onto the tracked pose when the object returns.
            // **V3-6 §1.** …unless `--bridge off` (the default), where it gets no word at all. It is still
            // fed above, so `--bridge on` is a flag and not a different build.
            if bridgeDrivesCard {
                if let drive = bridge.decide(at: time) {
                    return driveBridged(drive, at: time)
                }
                endBridgeDriving(reason: bridge.expired ? String(format: "%.0f s up", bridgeMaxSeconds) : "the hand went too")
            }
        }
        driveObject(screen: raw, anchor: ObjectScreenCalibration.translation(of: rawPose),
                    isTracked: isTracked, at: time)
    }

    /// **V3-2b B6.** One tick placed by the hand instead of by the camera. The pose goes through
    /// `driveObject` as a **tracked** observation — that is the whole trick: the presence gate never sees an
    /// untracked frame, so it never freezes, and the card keeps following the hand that is holding the
    /// passport for up to three seconds.
    private func driveBridged(_ drive: HandBridge.Drive, at time: TimeInterval) {
        switch drive.kind {
        case .bridged:
            if !bridgeDriving {
                bridgeDriving = true
                bridgeStartedAt = time
                // **V3-4 §3.** The tilt the desk gate and the gestures judge is frozen at the last thing the
                // *camera* said. A bridged pose's own tilt is the wrist's, and V3-2b fed it to both: that is
                // where 14:23's `face down: anticipation (tilt 141°)` came from, on a passport that was being
                // picked up rather than turned over.
                bridgeFrozenTilt = objectTilt
                // How long the object had been gone when the hand took over, and how long this hand had been
                // holding the passport — the second number is *why* this hand was chosen (V3-4 §3).
                // **V3-5 §1.** …and at what radius, because 10 → 15 cm is the change that decides whether
                // a grip from above is learned at all, and `--bridge-radius` is how the headset A/Bs it.
                print(String(format: "[hand] bridge on (%@, holding %.1f s, %.2f s after loss, radius %.0f cm)",
                             drive.side.rawValue, drive.holding, drive.afterLoss, bridgeAttachRadius * 100))
            }
        case .blending:
            endBridgeDriving(reason: "object back")
        }
        driveObject(screen: drive.pose, anchor: HandBridge.translation(of: drive.pose),
                    isTracked: true, bridged: drive.kind == .bridged, at: time)
    }

    /// The bridge gave up (three seconds, or the hand went too): from here the existing freeze is the answer.
    private func endBridgeDriving(reason: String) {
        guard bridgeDriving else { return }
        bridgeDriving = false
        bridgeFrozenTilt = nil
        let carried = bridgeStartedAt.map { now - $0 } ?? 0
        bridgeStartedAt = nil
        print(String(format: "[hand] bridge off (%@, %.1f s)", reason, carried))
    }

    /// **V3-6 §4.** How far the nearest tracked wrist is from where the passport was last seen, or nil when
    /// there is no hand to ask (`--no-hands`, the simulator, a script with no `hand` segment). `LossClock`
    /// reads nil as "cannot tell", which is V3-4's behaviour and not a desk loss.
    private func handDistance(near screen: simd_float4x4?, at time: TimeInterval) -> Float? {
        guard handBridgeEnabled else { return nil }
        guard let pose = screen ?? latestRawScreenPose ?? latestObjectPose else { return nil }
        return bridge.nearestHandDistance(to: ObjectScreenCalibration.translation(of: pose), at: time)
    }

    /// **V3-6 §4.** The passport was lost on the desk and *then* a hand arrived: the desk half is over (and
    /// is reported as such) and the pick-up's own clock starts at the reach, not at the moment the room went
    /// dark. This is the shape of both of round 3's pick-ups.
    private func stepLossKind(at time: TimeInterval) {
        guard isRunning, !isPaused else { return }
        if let seconds = lossClock.reach(handDistance: handDistance(near: nil, at: time),
                                         radius: bridgeAttachRadius, at: time) {
            print(String(format: "[timing] desk loss %.1f s", seconds))
        }
    }

    /// **V3-2b B6.** Where the wearer's two hands are, at 20 Hz. The point the bridge tracks is the midpoint
    /// of the wrist and the middle-finger knuckle: the wrist alone swings several centimetres for a rotation
    /// of the hand that does not move the passport at all, and the knuckle alone moves with the fingers.
    private func readHandAnchors(at time: TimeInterval) {
        guard handBridgeEnabled, let handProvider else { return }
        let anchors = handProvider.handAnchors(at: CACurrentMediaTime())
        for (side, anchor) in [(HandBridge.Side.left, anchors.leftHand), (.right, anchors.rightHand)] {
            guard let anchor else { continue }
            guard anchor.isTracked, let skeleton = anchor.handSkeleton else {
                bridge.observeHand(side, pose: anchor.originFromAnchorTransform, tracked: false, at: time)
                continue
            }
            let base = anchor.originFromAnchorTransform
            let wrist = base * skeleton.joint(.wrist).anchorFromJointTransform
            let knuckle = base * skeleton.joint(.middleFingerKnuckle).anchorFromJointTransform
            let midpoint = (HandBridge.translation(of: wrist) + HandBridge.translation(of: knuckle)) / 2
            let pose = HandBridge.pose(rotation: HandBridge.rotation(of: wrist), translation: midpoint)
            bridge.observeHand(side, pose: pose, tracked: true, at: time)
        }
    }

    /// **V3-2b B6.** The 20 Hz half of the bridge: a provider that simply stops reporting (the `held(.stale)`
    /// case — no untracked observation ever arrives) has no observation to hang the substitution off, so the
    /// tick asks the bridge itself once `lossTimeout` has passed.
    private func stepHandBridge(at time: TimeInterval) {
        // **V3-6 §1**: `bridgeDrivesCard` is `--bridge`, `handBridgeEnabled` is `--no-hands`.
        guard handBridgeEnabled, bridgeDrivesCard, isRunning, effectiveMode != .image else { return }
        // **V3-5 §1.** A world holds the tracker paused: the object stream is *off*, not lost. Asking the
        // bridge here would burn its whole budget inside the world and leave nothing for the way out. (The
        // bridge itself refuses too — `HandBridge.decide` — so this is the cheap half, not the rule.)
        guard !isPaused else { return }
        // Only when the object stream has gone **silent**. While it is still arriving — tracked or not —
        // every observation already asks the bridge, and driving from here too would place the card twice.
        guard let last = lastObjectUpdate, time - last >= bridge.lossTimeout else { return }
        guard let drive = bridge.decide(at: time) else {
            endBridgeDriving(reason: bridge.expired ? String(format: "%.0f s up", bridgeMaxSeconds) : "the hand went too")
            return
        }
        driveBridged(drive, at: time)
    }

    /// The tail of `observeObject`: the desk gate, the gestures, the gravity snap, the low pass and the
    /// forward — everything that happens to a **screen-frame** pose whoever produced it. The hand bridge
    /// (B6) is a second producer, and it goes through exactly the same eleven lines so that a bridged second
    /// cannot behave differently from a tracked one anywhere downstream.
    /// (Whether this pose came from the camera or from the bridge is `bridgeDriving`, which is what `Σ src=`
    /// and `Σ bridged=` read — nothing in here needs to be told twice.)
    private func driveObject(screen raw: simd_float4x4, anchor anchorPosition: SIMD3<Float>,
                             isTracked: Bool, bridged: Bool = false, at time: TimeInterval) {
        latestRawScreenPose = raw
        if isTracked {
            // **V3-4 §3.** While the hand is carrying the card, "which way is the passport facing" is the
            // last thing the camera said, not what the wrist implies through a 10 cm lever.
            let tilt = bridged ? (bridgeFrozenTilt ?? PresenceGate.tilt(of: raw)) : PresenceGate.tilt(of: raw)
            objectTilt = tilt
            summaryLastObjectTilt = tilt
            // V3-1b: tilt alone said "desk" for a device held flat in a palm and could not tell a 27° rest
            // reading from a 27° carry. The gate now wants stillness and, when one is known, a plane under the
            // screen as well — see `DeskOrientationGate`. The position it judges is the **object anchor's**, so
            // a change of mapping (a `both`-mode calibration landing) is not mistaken for the device moving.
            if let change = deskGate.update(tilt: tilt, position: anchorPosition,
                                            planeBelow: planeDrop(below: raw),
                                            screenY: ObjectScreenCalibration.translation(of: raw).y,
                                            at: time) {
                print("[obj] desk gate → \(change.isOnDesk ? "desk" : "hand") (\(change.reason))")
            }
            // V3-2a H5: "flat but not settled yet" is the anticipation the put-down bloom needs to fill the
            // 0.4 s the stillness test costs.
            if deskGate.isCandidate != deskCandidate {
                deskCandidate = deskGate.isCandidate
                onDeskCandidate?(deskCandidate)
            }
            noteRawVelocity(of: raw, at: time)
            // v3 H2 §6: the same raw tilt the desk gate reads is what "turned face down" is read from.
            // V3-2b B4: …and the anticipation edge of the very same observation, first — the card starts
            // gathering at 120° and the fold itself still waits for 150° × 0.8 s.
            // **V3-4 §3.** A bridged second is not a measurement of how the passport is being turned: the
            // gestures are fed nothing at all while the hand carries the card, rather than fed a frozen angle
            // (which would let a flip that started before the loss complete on no evidence).
            if !bridged {
                if let event = gestures.updateAnticipation(tilt: tilt) { onGesture?(event) }
                if let event = gestures.update(tilt: tilt, at: time) { onGesture?(event) }
            }
        } else {
            // V3-4 §10: when the camera lost it, for the pick-up timing.
            // **V3-6 §4**: …and whose loss it is. A hand inside the attach radius makes this the start of a
            // pick-up; every wrist outside it makes it a desk loss, which is counted separately.
            lossClock.lost(handDistance: handDistance(near: raw, at: time), radius: bridgeAttachRadius,
                           carrying: presence.isCarrying, at: time)
            // A loss breaks every chain: the next pose is where the device is, not a filtered memory of it. The
            // desk gate keeps its *answer* (a device lost on a desk is still on the desk) but not its clocks.
            // (B6: a bridged observation never reaches here — it *is* tracked as far as everything below the
            // bridge is concerned, so the smoother, the gestures and the desk gate keep their state.)
            smoother.reset()
            // B4: a loss in the middle of a flip must put the card back — nothing else will.
            if let event = gestures.reset() { onGesture?(event) }
            deskGate.loseTracking()
            if deskCandidate { deskCandidate = false; onDeskCandidate?(false) }
            rawVelocity = .zero
            lastRawVelocitySample = nil
        }
        // On the desk the device is flat by definition: keep the screen pose's yaw and drop its pitch and roll.
        // **V3-1b:** the alignment is applied to the pose that is already in the screen frame, not to the object
        // pose it was derived from. `gravityAligned` forces the input's +Y straight up, and on the headset's
        // Z-thin bounding box the object's +Y is the 95 mm long axis — aligning *that* stood the passport on end
        // (`tilt=90.0°` beside `objTilt=3.7°` for a whole trial). In the screen frame +Y is the screen normal and
        // +Z the reader axis by construction, so the snap is flat and `yaw(of:)` reads the real heading. The cost
        // is that the offset's 4.25 mm lever arm now turns with the tracker's pitch/roll noise: ≈ 1.5 mm at the
        // 20° worst case measured on the headset.
        let placed = deskGate.isOnDesk ? TrackingFusion.gravityAligned(raw) : raw
        // …then rule 3: the split-τ low pass (0.03 s in the hand, 0.08 s on the desk). The image path never sees this.
        smoother.tauPosition = presence.isCarrying ? ObjectPoseSmoother.tauPositionHand : ObjectPoseSmoother.tauPositionDesk
        let screen = isTracked ? smoother.smooth(placed, at: time) : placed
        // `latestRawScreenPose` stays the *unsmoothed* pose in both cases (set above), so `Σ lag=` keeps
        // meaning "how far is the drawn card from the last thing that said where the device is" — whether
        // that was the camera or, for a bridged second, the wearer's hand.
        latestObjectPose = screen
        fusion.note(object: TrackingFusion.Sample(pose: screen, isTracked: isTracked, time: time,
                                                  onDesk: deskGate.isOnDesk))
        forward(candidate: .object, at: time)
    }

    /// The drop from a screen pose's origin down to the nearest **known** horizontal surface, or nil when none is.
    /// "Known" means a scripted `--fake-track` desk height or a detected `PlaneAnchor` — never `updateSurface`'s
    /// "image plane minus device thickness" fallback, which is derived from the card's own height and would hand
    /// the desk gate a plane under every device in the room, palm included.
    private func planeDrop(below screenPose: simd_float4x4) -> Float? {
        let p = ObjectScreenCalibration.translation(of: screenPose)
        if let y = fakeSurfaceY { return p.y - y }
        var best: Float?
        for plane in planes.values {
            let m = plane.originFromAnchorTransform
            let extent = plane.geometry.extent
            let center = m * extent.anchorFromExtentTransform
            let local = center.inverse * SIMD4<Float>(p.x, p.y, p.z, 1)
            let margin: Float = 0.12
            guard abs(local.x) <= extent.width / 2 + margin, abs(local.z) <= extent.height / 2 + margin else { continue }
            let drop = p.y - center.columns.3.y
            // **V3-4 §5.** −2 cm → −4 cm: ARKit's plane for the real desk came in 1.9 cm *above* the
            // passport's screen on the headset, and this filter threw it away before the gate ever saw it.
            guard drop > -0.04, drop < deskMaxDrop else { continue }
            if best == nil || drop < best! { best = drop }
        }
        return best
    }

    /// Raw screen-frame velocity: a finite difference over the last two tracked observations, low-passed at
    /// `velocityTau`. It is deliberately taken **before** the desk snap and the smoother, because it is the thing
    /// the smoother and the follower are both going to lag behind — a velocity measured on their own output would
    /// be exactly as late as they are and could not lead anything.
    private func noteRawVelocity(of raw: simd_float4x4, at time: TimeInterval) {
        let p = ObjectScreenCalibration.translation(of: raw)
        defer { lastRawVelocitySample = (p, time) }
        guard let previous = lastRawVelocitySample else { return }
        let dt = Float(min(ObjectPoseSmoother.maxStep, max(0, time - previous.time)))
        guard dt > 1e-4 else { return }
        let instant = (p - previous.position) / dt
        guard instant.x.isFinite, instant.y.isFinite, instant.z.isFinite else { return }
        let alpha = 1 - exp(-dt / CardTracker.velocityTau)
        rawVelocity += (instant - rawVelocity) * alpha
    }

    /// `objectToScreen`: the converged offset, or the object's own bounding box until there is one. The fallback
    /// is deliberately never enough to *switch* source (`TrackingFusion` waits for `calibrated`) — it is what the
    /// `Σ` line and `--tracker object` look at, and it is only ever as good as Create ML's choice of origin.
    private var objectToScreen: simd_float4x4 {
        // `both` keeps v2's answer: a converged co-observation beats a frame read off the scan, because it
        // measured this device against the image anchor everything downstream was written for.
        if effectiveMode == .both, calibration.isConverged, let offset = calibration.offset { return offset }
        // v3 H1: otherwise the frame derived from the anchor's own bounding box — available from the very
        // first observation, with no image tracker involved.
        return screenFrame?.offset ?? matrix_identity_float4x4
    }

    /// Ask the fusion which source owns this tick, then forward the observation **only** if it came from that
    /// source. Everything downstream — presence gate, continuity gate, pose follower — is untouched by G: it sees
    /// one pose stream, exactly as before.
    private func forward(candidate: TrackingFusion.Source, at time: TimeInterval) {
        let previous = fusion.source
        // 工作包 G2, rule 5: the fusion needs to know the device is in a hand, because that is when the image is
        // the source that lies and its veto has to stand down.
        fusion.isCarrying = presence.isCarrying
        let decision = fusion.decide(at: time)
        if decision.logVeto, let disagreement = decision.disagreement {
            print(String(format: "[obj] sources disagree %.1f cm; staying on %@", disagreement * 100, previous.rawValue))
        }
        if decision.switched {
            // A hand-over is not a tracking step: the jitter chain restarts, exactly as it does when the active
            // reference image changes, and the object's low pass starts again from wherever the device now is.
            lastJitterPose = nil
            smoother.reset()
            activeSource = decision.source
            applyAcceptancePolicy()
            let apart = decision.disagreement.map { String(format: " (%.1f cm apart)", $0 * 100) } ?? ""
            print("[obj] source → \(decision.source.rawValue)\(apart)")
            // Rule 4: the object was placing the card on its bounding box and the image has just arrived with a
            // better answer. Anything past the continuity threshold is handed to the gate as a jump, which holds
            // it for `jumpAcceptAfter` and then glides the card over — worth a line, because on the headset this
            // is the one moment an object-first session visibly corrects itself.
            if decision.leadEnded, let correction = decision.disagreement, correction > gate.jumpDistance {
                print(String(format: "[obj] object-first correction %.1f cm; the gate glides it", correction * 100))
            }
        }
        guard decision.source == candidate, let pose = decision.pose else { return }
        ingest(pose: pose, isTracked: decision.isTracked, at: time)
    }

    /// One co-observation of the same rigid body by both trackers. `inverse(objectPose) · imagePose` is the fixed
    /// offset between the two frames; averaging enough of them removes both trackers' noise. Sampled only while
    /// the **image** is the source (so the pose it is measured against is one the continuity gate accepted) and
    /// the card is standing still on the desk — a pose taken mid-carry would fold the two trackers' latencies
    /// into the offset.
    private func updateCalibration(objectPose: simd_float4x4, at time: TimeInterval) {
        // 工作包 G2, rule 2: the card has to have been standing still on the desk for `calibrationSettle`, and
        // that is the *only* state gate left — the offset keeps being refreshed after it converges, so an offset
        // measured during a bad minute (the headset's first was 12–22° of object tilt) heals in place instead of
        // being outvoted by its own history until the app is reinstalled.
        guard presence == .expanded, let since = expandedSince,
              time - since >= CardTracker.calibrationSettle else { return }
        guard let image = fusion.image, image.isTracked, time - image.time <= CardTracker.calibrationPairing else { return }
        let imagePose: simd_float4x4
        if fusion.source == .image {
            // The image is driving: use the pose the gate **accepted**, and only while it is still accepting them.
            // `gate.acceptedPose` on its own is a trap — while the continuity gate is holding a jump (which is
            // exactly what the seconds after an object-first correction look like) it keeps returning the *old*
            // accepted pose, and pairing that with a fresh object pose measures an offset that is wrong by the
            // size of the correction.
            guard let accepted = lastAcceptedImage,
                  time - accepted.time <= CardTracker.calibrationPairing else { return }
            imagePose = accepted.pose
        } else {
            // The object is driving, so the gate's accepted pose **is** the object's — calibrating against it
            // would be calibrating the object against itself. The image's own observation is the only independent
            // reference left; `ObjectScreenCalibration` throws it out if it does not read like a card lying flat.
            imagePose = image.pose
        }
        let converged = calibration.add(objectPose: objectPose, imagePose: imagePose)
        guard let offset = calibration.offset else { return }
        if converged {
            let t = ObjectScreenCalibration.translation(of: offset) * 1000
            print(String(format: "[obj] calibrated: offset (%.1f, %.1f, %.1f) mm, yaw %.1f°, N=%d",
                         t.x, t.y, t.z, calibration.meanYaw * 180 / .pi, calibration.count))
            // `objectToScreen` changes underneath the object stream on this very observation: the bounding-box
            // guess is replaced by the measurement. That is a change of *frame*, not the device moving, so the
            // low pass starts again from the new mapping instead of gliding the correction in over τ (which would
            // hand the fusion two sources that disagree by the size of the correction for a third of a second).
            smoother.reset()
            fusion.calibrated = true
            saveCalibration(offset: offset, at: time, force: true)
        } else if calibration.isConverged {
            saveCalibration(offset: offset, at: time, force: false)
        }
    }

    /// Everything 工作包 G carries between observations. A session (re)start forgets the anchors and the source,
    /// but **not** the calibration: the offset is a property of the trained object, not of this session.
    private func resetFusion() {
        fusion = TrackingFusion()
        fusion.mode = effectiveMode
        fusion.calibrated = effectiveMode == .both && calibration.isConverged
        // `objectLeadAfter` counts from here: a teardown must not inherit "the image was seen once, last session".
        fusion.beginSession(at: startTime)
        deskGate.reset()
        smoother.reset()
        gestures.reset()
        expandedSince = nil
        lastAcceptedImage = nil
        activeSource = fusion.source
        applyAcceptancePolicy()
        activeObjectID = nil
        screenFrame = nil
        frameDecisionDeadline = nil
        objectBoxOffset = nil
        latestObjectPose = nil
        latestObjectRawPose = nil
        latestRawScreenPose = nil
        rawVelocity = .zero
        lastRawVelocitySample = nil
        objectTilt = nil
        objectTracked = false
        lastObjectUpdate = nil
        objectUpdateCount = 0
        summaryObjectUpdates = 0
        summaryObjectUpdatesAll = 0
        objectTrail.removeAll()
        objectTrailLast = -.infinity
        summaryLastObjectTilt = nil
    }

    /// The single ingest point for image poses: the real `ImageAnchor` updates and the scripted `--fake-track`
    /// runner both come through here, so the gate, the pose follower, the dead zone and the relocation rule are
    /// exercised in the simulator exactly as they are on the headset.
    ///
    /// `latestPose` — what the hologram follows — is written **only** for observations the gate accepts. A pose the
    /// continuity gate rejected is ARKit drift on the tiny self-lit target, and showing it (the card jumping 9.8 cm
    /// sideways and folding into `carrying`) was the visible failure of device round 1.
    private func ingest(pose: simd_float4x4, isTracked: Bool, at time: TimeInterval) {
        defer { wasTrackedLastObservation = isTracked }
        guard isTracked else {
            self.isTracked = false
            gate.observe(pose: pose, isTracked: false, isFlat: directorMode || isFlat, at: time)
            return
        }
        self.isTracked = true
        // v3 H2 §7. `always` brings a dismissed card back on the next **re-acquisition** — not on the next
        // observation: with the object tracker running at 13–30 Hz the very next frame after a dismiss is
        // 40 ms later, and "comes back on the next detection" taken literally would make dismissing impossible.
        if autoShow == .always, gate.isDismissed, !wasTrackedLastObservation {
            print("[gate] --auto-show always: re-acquired while dismissed → show")
            gate.requestShow(at: time)
        }
        if firstDetectionTime == nil {
            firstDetectionTime = time
            timeline["firstDetection"] = time - startTime
            print("[timing] first detection \(String(format: "%.2f", time - startTime)) s after start")
        }
        hasTrackedOnce = true
        updateFlatGate(pose: pose)
        updateViewGate()
        // **V3-5 §4.** `jitter=` is measured *here*, on the pose the fusion forwarded — which for the object
        // source has already been through `ObjectPoseSmoother`. (The comment that used to stand here said
        // "the raw stream"; it has not been true since the object path gained its own low pass.) `Σ
        // jitterRaw=` is the unsmoothed one, so the filter can actually be judged.
        noteTrackedObservation(pose: pose, at: time)
        if gate.observe(pose: pose, isTracked: true, isFlat: directorMode || isFlat, at: time) {
            latestPose = pose
            summaryLastAccepted = pose
            // The calibration's reference: an image pose that survived the continuity gate, with the moment it did.
            if fusion.source == .image { lastAcceptedImage = (pose, time) }
        }
    }

    /// **V3-4 §5.** How long the remembered desk height survives without a single tracked observation.
    /// Twenty seconds is far longer than any dropout in the hand and far shorter than "the wearer got up and
    /// went to another room" — and a desk in another room is very likely to be within the 3 cm tolerance of
    /// this one (every desk is 72–76 cm), which is exactly when a stale memory would be worth something it
    /// has not earned.
    static let deskMemoryTimeout: TimeInterval = 20

    private func tick() {
        let time = now
        forgetDeskHeightIfStale(at: time)
        readHandAnchors(at: time)
        stepLossKind(at: time)
        stepHandBridge(at: time)
        updateViewGate()
        gate.setInView(directorMode || isInView, at: time)
        gate.tick(at: time)
        updateSurface(at: time)
        updateHintPose(at: time)
        if let pose = devicePose() { latestDevicePose = pose }
        updateHandOver(at: time)
        sync()
        summarize(at: time)
        stepTrackingWatch(at: time)
    }

    /// **v4 B2 §3.2.** One tick of `[track] in view but untracked …` (object source only: it is the object stream
    /// whose silence the line explains).
    private func stepTrackingWatch(at time: TimeInterval) {
        guard isRunning, objectProvider != nil || objectUpdateCount > 0 else { return }
        let context = V4.TrackingWatch.Context(
            head: devicePose(), lastPose: latestRawScreenPose ?? latestObjectPose,
            lastTracked: lastObjectTrackedUpdate, handDistance: handDistance(near: nil, at: time),
            strip: stripProvider?() ?? nil, backlight: deviceBacklight, paused: isPaused)
        for line in watch.tick(context, at: time) { print(line) }
    }

    /// **v4 B2 §3.2.** The presence moved: a desk / hand segment may have ended.
    private func noteTrackingSegment(_ presence: PresenceGate.Presence, at time: TimeInterval) {
        let resting = presence == .acquiring || presence == .expanded || presence == .settling
        let kind = V4.TrackingWatch.segment(carrying: presence.isCarrying, resting: resting, held: presence.isHeld,
                                            world: presence == .held(.world) || isPaused, current: watch.segment)
        if let summary = watch.enter(kind, at: time) { print(summary) }
    }

    /// The passport has not been seen for `deskMemoryTimeout`: whatever desk it was lying on, that is not
    /// evidence about where it is now. (`deskGate.reset()` only runs on a session restart, so without this
    /// the memory would live for the whole session — including across a walk to another room.)
    private func forgetDeskHeightIfStale(at time: TimeInterval) {
        guard deskGate.rememberedHeight != nil else { return }
        guard let last = lastObjectTrackedUpdate else { return }
        guard time - last > CardTracker.deskMemoryTimeout else { return }
        deskGate.forgetDeskHeight()
        print(String(format: "[obj] desk height forgotten (%.0f s without a tracked observation)", time - last))
    }

    // MARK: - Handing it to someone else (V3-3 C4 / plan §4 E9)

    /// Far enough away that somebody else is holding it: 0.6 m is past the wearer's own reach with the
    /// elbow bent, and 0.5 m coming back is the same distance with the hysteresis a shoulder's worth of
    /// sway needs. A whole second of it, because reaching across a table to point at something is not
    /// handing the passport over.
    static let handOverFar: Float = 0.6
    static let handOverNear: Float = 0.5
    static let handOverDwell: TimeInterval = 1

    /// When the far hold started, and whether it has already been reported.
    @ObservationIgnored private var farHoldSince: TimeInterval?
    @ObservationIgnored private var farHoldReported = false

    /// **V3-3 C4 / plan §4 E9 — 递给别人.** Nothing visual: the object anchor already goes with the device,
    /// and `hinged` facing already keeps the card's front toward the wearer (who is the camera), so a
    /// passport in a friend's hand needs no code at all. What it needs is a **line in the log**, so that
    /// when the S5 shot is reviewed there is a way to say which seconds of it were the handover and hold
    /// the Σ window over them up against `objTracked`.
    ///
    /// Measured between the two poses the tracker already has: `latestPose` (the screen, in world space)
    /// and `latestDevicePose` (the head). Only while `carrying` — the desk is 0.8 m away in every one of
    /// these scripts, and "the passport is on the table" is not a handover.
    private func updateHandOver(at time: TimeInterval) {
        guard presence.isCarrying, let card = latestPose, let head = latestDevicePose else {
            // Not in a hand any more: the dwell starts over and the latch clears **silently**. A settle is
            // not the device coming back to the wearer, so printing `near again` for it would be a lie.
            farHoldSince = nil
            farHoldReported = false
            return
        }
        let cardPosition = SIMD3<Float>(card.columns.3.x, card.columns.3.y, card.columns.3.z)
        let headPosition = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let distance = simd_length(cardPosition - headPosition)
        guard distance.isFinite else { return }
        if farHoldReported {
            guard distance < CardTracker.handOverNear else { return }
            farHoldReported = false
            farHoldSince = nil
            print(String(format: "[hand] near again (%.2f m)", distance))
            return
        }
        guard distance > CardTracker.handOverFar else {
            farHoldSince = nil
            return
        }
        guard let since = farHoldSince else {
            farHoldSince = time
            return
        }
        guard time - since >= CardTracker.handOverDwell else { return }
        farHoldReported = true
        print(String(format: "[hand] far hold %.2f m", distance))
    }

    // MARK: - Gate summary (`[gate] Σ`, every 5 s)

    /// One tracked observation of the **forwarded** stream — whichever source the fusion picked (工作包 G). This
    /// is what `Σ tracked=` and `Σ jitter=` are measured on, so both keep meaning "how steadily is the card being
    /// placed", not "how is the image doing". The per-source rates are counted separately (`Σ img=` in
    /// `observeImage`, `Σ obj=` in `observeObject`). Jitter is the RMS step between consecutive tracked poses —
    /// with the card lying still it *is* the tracking noise, which is the number the recognition experiments compare.
    private func noteTrackedObservation(pose: simd_float4x4, at time: TimeInterval) {
        lastObservationTime = time
        // **V3-5 §4.** The drawn card's own step, on **this** observation — the same chain, the same
        // instants, so `jitter=` and `jitterOut=` are two measurements of one thing and their ratio means
        // something. (Until V3-5 `jitterOut` was sampled on the 20 Hz tick while `jitterOut`'s input came in
        // at 30 Hz, which by itself made the ratio ≈ 1.5 and is most of why every headset window read
        // `jitterOut ≥ jitter`.)
        if activeSource == .object, let raw = latestRawScreenPose {
            let p = ObjectScreenCalibration.translation(of: raw)
            if let previous = lastRawJitterPose {
                let step = simd_length(p - previous)
                if step.isFinite {
                    summaryJitterRawSum += Double(step) * Double(step)
                    summaryJitterRawCount += 1
                }
            }
            lastRawJitterPose = p
        }
        if let rendered = renderedPosition?() {
            if let previous = lastRenderedJitter {
                let step = simd_length(rendered - previous)
                if step.isFinite {
                    summaryJitterOutSum += Double(step) * Double(step)
                    summaryJitterOutCount += 1
                }
            }
            lastRenderedJitter = rendered
        }
        if let previous = lastJitterPose {
            let (step, turn) = PresenceGate.delta(from: previous, to: pose)
            summaryJitterSum += Double(step) * Double(step)
            summaryJitterCount += 1
            // v3: the same chain, measured in degrees. On the desk this is the orientation noise the gravity
            // snap is supposed to have removed; in the hand it is what the split-τ smoother has to swallow.
            let degrees = Double(turn) * 180 / .pi
            summaryRotJitterSum += degrees * degrees
            summaryRotJitterCount += 1
        }
        lastJitterPose = pose
    }

    /// Accumulates the window and prints one line every `summaryPeriod` seconds. Driven by the 20 Hz tick on the
    /// device and by the 10 Hz preview loop, so both produce the same evidence.
    private func summarize(at time: TimeInterval) {
        guard isRunning else { return }
        guard let start = summaryStart else {
            summaryStart = time
            summaryRelocBase = gate.relocateCount
            summaryOutlierBase = gate.outlierCount
            return
        }
        summaryTicks += 1
        if let last = lastObservationTime, time - last < gate.staleSoft { summaryFreshTicks += 1 }
        if presence.isCarrying {
            summaryCarryTicks += 1
            // V3-1b `Σ lag=`: how far the card being **drawn** is from the last raw observation of the screen —
            // the smoother's delay plus the follower's, minus whatever the velocity lead bought back. Measured
            // only while carrying, because on the desk both poses are the same standing-still number.
            if let rendered = renderedPosition?(), let raw = latestRawScreenPose {
                let d = simd_length(rendered - ObjectScreenCalibration.translation(of: raw))
                if d.isFinite {
                    summaryLagSum += Double(d)
                    summaryLagCount += 1
                }
            }
        }
        if let lag = deckLag?(), lag.isFinite {
            summaryDeckLagPeak = max(summaryDeckLagPeak ?? 0, lag)
        }
        if bridgeDriving { summaryBridgedTicks += 1 }
        switch presence {
        case .held(.stale), .held(.untracked): summaryStaleTicks += 1
        default: break
        }
        // A frozen or untracked pose is not a jitter sample: the next tracked pose starts a new chain.
        // V3-5 §4: the drawn card's chain breaks with it, since it is now sampled on the same observations.
        if presence.isHeld || !isTracked {
            lastJitterPose = nil
            lastRenderedJitter = nil
            lastRawJitterPose = nil
        }

        let window = time - start
        guard window >= CardTracker.summaryPeriod else { return }
        let ticks = Double(max(1, summaryTicks))
        let jitterMM = summaryJitterCount > 0 ? (summaryJitterSum / Double(summaryJitterCount)).squareRoot() * 1000 : 0
        // V3-4 §7. `-` when the window held nothing drawn to measure.
        let jitterOutField = summaryJitterOutCount > 0
            ? String(format: "%.1fmm", (summaryJitterOutSum / Double(summaryJitterOutCount)).squareRoot() * 1000)
            : "-"
        // V3-5 §4. Appended after `jitterOut=`; every field before it keeps its place.
        let jitterRawField = summaryJitterRawCount > 0
            ? String(format: "%.1fmm", (summaryJitterRawSum / Double(summaryJitterRawCount)).squareRoot() * 1000)
            : "-"
        // `tilt` is the angle between the accepted pose's image normal and gravity. `PresenceGate.acceptTiltMax`
        // (6°) and the relocation sanity check both assume a flat card reads close to 0 here; if the headset is
        // systematically off by more, a relocation would silently never confirm — this is the number that says so
        // before that happens.
        let tilt = summaryLastAccepted.map { String(format: "%.1f°", PresenceGate.tilt(of: $0) * 180 / .pi) } ?? "-"
        // 工作包 G: `src` is the provider that is actually placing the card, `obj` its update rate and `cal`
        // whether the object→screen offset has converged. All three read `-` in a run that has no object source
        // at all, which is what the app does until the Create ML scan lands.
        let hasObject = objectProvider != nil || objectUpdateCount > 0
        let objectRate = hasObject ? String(format: "%.1f/s", Double(summaryObjectUpdates) / max(0.001, window)) : "-"
        let calibrated = hasObject ? (calibration.isConverged ? "yes" : "no") : "-"
        // G2: `objTilt` is the same angle taken from the **object** source before the desk snap. `tilt` ≈ 0 next
        // to `objTilt` ≈ 15° is the snap working; the two reading the same large number is the snap not engaging
        // (the desk gate thinks the device is in a hand), which is the first thing to check on the headset.
        let objectTiltField = summaryLastObjectTilt.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "-"
        // v3 H1 §6. `objTracked` is how much of the object stream was actually locked on (the number V3-1 is
        // accepted on: ≥ 80 % while the passport is in a hand), `rotJitter` the RMS *angle* step of the same
        // chain `jitter` measures, and `inHand` the share of the window the gate spent in `carrying` — so one
        // line says both "was it in a hand" and "how well was it tracked while it was".
        let objectTrackedField = summaryObjectUpdatesAll > 0
            ? String(format: "%.0f%%", 100 * Double(summaryObjectUpdates) / Double(summaryObjectUpdatesAll)) : "-"
        let rotJitter = summaryRotJitterCount > 0
            ? (summaryRotJitterSum / Double(summaryRotJitterCount)).squareRoot() : 0
        // V3-1b §8. `-` when the window held no carrying tick to measure on.
        let lagField = summaryLagCount > 0
            ? String(format: "%.0fmm", summaryLagSum / Double(summaryLagCount) * 1000) : "-"
        // V3-2b B2. Appended after `lag=`; every field before it keeps its place.
        let deckLagField = summaryDeckLagPeak.map { String(format: "%.0fmm", $0 * 1000) } ?? "-"
        // V3-2b B6. Appended after `deckLag=`; `src=` says `hand` for the same ticks.
        let bridgedField = String(format: "%.0f%%", 100 * Double(summaryBridgedTicks) / ticks)
        // v4 B5 §6. Appended after `jitterRaw=`; every field before it keeps its place.
        print(String(format: "[gate] Σ state=%@ src=%@ img=%.1f/s obj=%@ cal=%@ tracked=%.0f%% stale=%.0f%% jitter=%.1fmm tilt=%@ objTilt=%@ reloc=%d cand=%@ outliers=%d theme=%@ bl=%@ hands=%@ objTracked=%@ rotJitter=%.1f° inHand=%.0f%% lag=%@ deckLag=%@ bridged=%@ jitterOut=%@ jitterRaw=%@ %@",
                     presence.label,
                     // B6: while the hand is carrying the card the source really is the hand, and the one
                     // field that says which provider placed it has to say so. A Σ line covers five seconds,
                     // so it reads `hand` for a window the bridge drove **any** of — `bridged=` right next
                     // to it says how much. `activeSource` itself is untouched: the object is still the
                     // tracker this session is running on, and it takes the card back the moment it can.
                     (bridgeDriving || summaryBridgedTicks > 0) ? "hand" : activeSource.label,
                     Double(summaryUpdates) / max(0.001, window),
                     objectRate,
                     calibrated,
                     100 * Double(summaryFreshTicks) / ticks,
                     100 * Double(summaryStaleTicks) / ticks,
                     jitterMM,
                     tilt,
                     objectTiltField,
                     gate.relocateCount - summaryRelocBase,
                     gate.hasRelocateCandidate ? "yes" : "no",
                     gate.outlierCount - summaryOutlierBase,
                     activeReferenceName,
                     deviceBacklight.map { "\($0)" } ?? "-",
                     handsSummary,
                     objectTrackedField,
                     rotJitter,
                     100 * Double(summaryCarryTicks) / ticks,
                     lagField,
                     deckLagField,
                     bridgedField,
                     jitterOutField,
                     jitterRawField,
                     summaryNormal.field))
        summaryStart = time
        summaryUpdates = 0
        summaryObjectUpdates = 0
        summaryObjectUpdatesAll = 0
        summaryTicks = 0
        summaryFreshTicks = 0
        summaryStaleTicks = 0
        summaryCarryTicks = 0
        summaryJitterSum = 0
        summaryJitterCount = 0
        summaryRotJitterSum = 0
        summaryRotJitterCount = 0
        summaryRelocBase = gate.relocateCount
        summaryOutlierBase = gate.outlierCount
        summaryLastAccepted = nil
        summaryLastObjectTilt = nil
        summaryLagSum = 0
        summaryLagCount = 0
        summaryDeckLagPeak = nil
        summaryBridgedTicks = 0
        summaryJitterOutSum = 0
        summaryJitterOutCount = 0
        summaryJitterRawSum = 0
        summaryJitterRawCount = 0
        summaryNormal = V4.ViewAngleWindow()
    }

    /// **V3-4 §10.** The bridge's two candidates: how long each hand has been continuously holding the
    /// passport, `*` on the one that is carrying the card and `+` on one that could. `-·-` with hand
    /// tracking off or nothing seen. This is the field that would have shown, in the first headset round,
    /// that the hand the bridge picked had been in the circle for 0.0 s.
    private var handsSummary: String {
        guard handBridgeEnabled else { return "-·-" }
        return bridge.handsSummary(at: now)
    }

    /// Reference image the pose is currently coming from (`Σ theme=`).
    private var activeReferenceName: String {
        activeAnchorID.flatMap { anchors[$0]?.imageName } ?? currentTheme.referenceImage
    }

    private func resetSummary() {
        summaryStart = nil
        summaryUpdates = 0
        summaryObjectUpdates = 0
        summaryObjectUpdatesAll = 0
        summaryTicks = 0
        summaryFreshTicks = 0
        summaryStaleTicks = 0
        summaryCarryTicks = 0
        summaryJitterSum = 0
        summaryJitterCount = 0
        summaryRotJitterSum = 0
        summaryRotJitterCount = 0
        summaryRelocBase = 0
        summaryOutlierBase = 0
        summaryLastAccepted = nil
        summaryLastObjectTilt = nil
        summaryLagSum = 0
        summaryLagCount = 0
        lastObservationTime = nil
        lastJitterPose = nil
    }

    /// Publish the gate's presence and derive the status / timing prints.
    private func sync() {
        if gateEventCount != gate.eventCount { gateEventCount = gate.eventCount }
        if isDismissed != gate.isDismissed { isDismissed = gate.isDismissed }
        let new = gate.presence
        if presence != new {
            let wasCarrying = presence.isCarrying
            presence = new
            // v4 B2 §3.2: a desk / hand segment may have ended.
            noteTrackingSegment(new, at: now)
            // **V3-4 §10.** "Pick it up → the card is in the hand form" was unmeasurable in the first headset
            // round: the gate → `hand form` half had a timestamp and the grab → gate half did not. The grab
            // announces itself as an object-tracking loss (a hand closing over the passport), so that is
            // where the clock starts.
            if new.isCarrying, !wasCarrying, let seconds = lossClock.carried(at: now) {
                print(String(format: "[timing] pick-up: loss → carrying %.2f s", seconds))
            }
            // **V3-6 §4.** …and a loss that ends back at rest on the desk was never a pick-up. Dropped
            // silently: the occlusion at a put-down (a hand over the passport as it lands) is the case, and
            // it must not leave a clock running for the *next* pick-up to print.
            if new == .settling || new == .absent { lossClock.settled() }
            // G2 rule 2: how long the card has been standing still, which is what the calibration samples against.
            expandedSince = new == .expanded ? now : nil
            // …and since when it has been away, which is what holds the `.lost` hint back for `searchCueAfter`.
            if new == .absent { absentSince = now }
            if new == .expanded, timeline["firstExpanded"] == nil {
                let t = now - startTime
                timeline["firstExpanded"] = t
                if let first = timeline["firstDetection"] {
                    print("[timing] expanded \(String(format: "%.2f", t - first)) s after first detection")
                }
            }
        }
        refreshStatus()
    }

    // MARK: - Desk plane

    private func handle(_ update: AnchorUpdate<PlaneAnchor>) {
        switch update.event {
        case .added, .updated:
            guard update.anchor.alignment == .horizontal else { return }
            planes[update.anchor.id] = update.anchor
        case .removed:
            planes.removeValue(forKey: update.anchor.id)
        }
    }

    /// Project the image anchor straight down onto the nearest horizontal plane that contains it;
    /// fall back to "image plane minus device thickness" after `deskSearchTimeout`.
    private func updateSurface(at time: TimeInterval) {
        updateFloor()
        guard let pose = latestPose else { return }
        // `--fake-track` may script the desk height; otherwise the plane search / thickness fallback below runs.
        if let y = fakeSurfaceY {
            surfaceY = y
            return
        }
        let p = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z)
        var best: (y: Float, drop: Float)?
        for plane in planes.values {
            let m = plane.originFromAnchorTransform
            let extent = plane.geometry.extent
            let center = m * extent.anchorFromExtentTransform
            let inv = center.inverse
            let local = inv * SIMD4<Float>(p.x, p.y, p.z, 1)
            let margin: Float = 0.12
            guard abs(local.x) <= extent.width / 2 + margin, abs(local.z) <= extent.height / 2 + margin else { continue }
            let planeY = center.columns.3.y
            let drop = p.y - planeY
            guard drop > -0.02, drop < deskMaxDrop else { continue }
            if best == nil || drop < best!.drop {
                best = (planeY, drop)
            }
        }
        if let best {
            if !surfaceIsDetectedPlane, let first = firstDetectionTime {
                print("[timing] desk plane found \(String(format: "%.2f", time - first)) s after first detection (drop \(String(format: "%.3f", best.drop)) m)")
                timeline["deskPlane"] = time - startTime
            }
            surfaceIsDetectedPlane = true
            surfaceY = best.y
        } else if !surfaceIsDetectedPlane {
            if let first = firstDetectionTime, time - first >= deskSearchTimeout {
                surfaceY = p.y - CardTracker.fallbackDeviceThickness
            } else if surfaceY == nil {
                // Until the desk is known, sit the effects just under the image so nothing is missing.
                surfaceY = p.y - CardTracker.fallbackDeviceThickness
            }
        }
    }

    /// Floor = the largest horizontal plane at least 0.9 m below the head (classification .floor preferred).
    private func updateFloor() {
        guard let d = devicePose() else { return }
        let headY = d.columns.3.y
        var best: (y: Float, area: Float)?
        for plane in planes.values {
            let y = plane.originFromAnchorTransform.columns.3.y
            guard headY - y > 0.9 else { continue }
            let area = plane.geometry.extent.width * plane.geometry.extent.height
            let boosted = plane.surfaceClassification == .floor ? area * 4 : area
            if best == nil || boosted > best!.area { best = (y, boosted) }
        }
        if let best, floorY != best.y { floorY = best.y }
    }

    // MARK: - Gates

    /// Is the card lying flat? `PresenceGate` turns "not flat" into `carrying(.notFlat)`, i.e. the hand form.
    ///
    /// **V3-1b: the object source answers with the desk gate, not with the presented pose.** Reading the tilt of
    /// the pose the card is drawn at is circular once the desk snap exists — on the desk the snap *makes* it
    /// flat, so the gate only ever re-measured its own output, and when the snap was wrong (V3-1) the answer was
    /// wrong for a whole session. The other direction matters just as much: a device resting at the 25° the
    /// object tracker reports on a thin slab would pass this hysteresis un-snapped and be drawn `expanded` with
    /// the tracker's pitch error on show. The desk gate is the one place that decides, and it decides on
    /// evidence (tilt, stillness, a plane). The image source keeps the 30°/42° hysteresis it was measured with.
    private func updateFlatGate(pose: simd_float4x4) {
        if activeSource == .object {
            isFlat = deskGate.isOnDesk
            return
        }
        let normal = simd_normalize(SIMD3<Float>(pose.columns.1.x, pose.columns.1.y, pose.columns.1.z))
        let tilt = acos(max(-1, min(1, simd_dot(normal, SIMD3<Float>(0, 1, 0)))))
        if isFlat {
            if tilt > flatExitAngle { isFlat = false }
        } else if tilt < flatEnterAngle {
            isFlat = true
        }
    }

    private func devicePose() -> simd_float4x4? {
        if let fakeHeadPose { return fakeHeadPose }
        guard let world = worldProvider, world.state == .running,
              let device = world.queryDeviceAnchor(atTimestamp: CACurrentMediaTime()) else { return nil }
        return device.originFromAnchorTransform
    }

    /// Angle between where the wearer looks (device -Z) and the direction to the card.
    private func updateViewGate() {
        guard let pose = latestPose, let d = devicePose() else {
            isInView = true
            return
        }
        let eye = SIMD3<Float>(d.columns.3.x, d.columns.3.y, d.columns.3.z)
        let forward = -simd_normalize(SIMD3<Float>(d.columns.2.x, d.columns.2.y, d.columns.2.z))
        let target = SIMD3<Float>(pose.columns.3.x, pose.columns.3.y, pose.columns.3.z) - eye
        guard simd_length(target) > 0.05 else { return }
        let angle = acos(max(-1, min(1, simd_dot(forward, simd_normalize(target)))))
        if isInView {
            if angle > viewExitAngle { isInView = false }
        } else if angle < viewEnterAngle {
            isInView = true
        }
    }

    private func updateHintPose(at time: TimeInterval) {
        guard status.showsHint else {
            if hintDevicePose != nil { hintDevicePose = nil }
            return
        }
        guard time - lastHintPoseTime >= 0.2 else { return }
        lastHintPoseTime = time
        hintDevicePose = devicePose()
    }

    // MARK: - Session events

    private func handle(_ event: ARKitSession.Event) {
        switch event {
        case .authorizationChanged(type: let type, status: let newStatus):
            if type == .worldSensing && newStatus == .denied {
                // Same teardown as a failure, so the retry after re-granting in Settings starts a fresh session.
                teardown()
                status = .authorizationDenied
                print("[gate] world sensing denied; session torn down")
            }
        case .dataProviderStateChanged(dataProviders: let providers, newState: let newState, error: let error):
            // Plane detection is optional: if only it fails we keep tracking with the fallback surface.
            if newState == .stopped, let error, providers.contains(where: { $0 is ImageTrackingProvider }) {
                teardown()
                status = .failed(String(describing: error))
                scheduleRetry()
                return
            }
            // 工作包 G: the object provider is the *optional* half of the hybrid. Losing it must never take image
            // tracking down with it — the card goes straight back to the image source and the run continues.
            if newState == .stopped, providers.contains(where: { $0 is ObjectTrackingProvider }) {
                guard self.provider != nil else {
                    // v3 H1: in `--tracker object` there is no image provider to fall back *to* — dropping the
                    // object source would leave the card frozen wherever it last stood, for ever. Treat it the
                    // way a dead image provider is treated: tear the session down and retry.
                    print("[obj] provider stopped (\(error.map { String(describing: $0) } ?? "no error")); no image source to fall back to")
                    teardown()
                    status = .failed(error.map { String(describing: $0) } ?? "object tracking stopped")
                    scheduleRetry()
                    return
                }
                print("[obj] provider stopped (\(error.map { String(describing: $0) } ?? "no error")); image only from here")
                objectTask?.cancel()
                objectTask = nil
                objectProvider = nil
                fusion.dropObject()
                activeSource = fusion.source
                applyAcceptancePolicy()
            }
        default:
            break
        }
    }

    private func refreshStatus() {
        guard isRunning else { return }
        if case .failed = status { return }
        if case .authorizationDenied = status { return }
        let newStatus: Status
        switch presence {
        case .absent:
            // Nothing has been seen yet: the acquisition hint. Otherwise the card has gone away, and the hint
            // waits for the same 3 s the gate waits before it shows its search shimmer — a blink of "看不到设备"
            // on every momentary drop is what made the wearer reach for a way out in the first trial.
            if !hasTrackedOnce {
                newStatus = .searching
            } else if isDismissed, (objectTrackedPercent(over: 1) ?? 0) > 0 {
                // v4 B3: collapsed on purpose, and the passport is in plain sight — the gold point (v3: the socket light)
                // is the whole picture, and "看不到设备" over it would be untrue. A collapsed passport that really is
                // lost still gets the hint after the same 3 s.
                newStatus = .held
            } else {
                newStatus = now - absentSince >= gate.searchCueAfter ? .lost : .held
            }
        case .acquiring: newStatus = .tracking
        case .expanded, .settling: newStatus = isInView ? .tracking : .outOfView
        case .carrying(.moving): newStatus = .moving
        case .carrying(.notFlat):
            // v3: with the object source the tilted device *is* the intended state — the card is in the
            // wearer's hand, which is where v3 wants it. "把名片平放到桌面上" would be telling them to undo it.
            newStatus = activeSource == .object ? .tracking : .notFlat
        case .held: newStatus = .held
        }
        if status != newStatus {
            status = newStatus
        }
    }
}
