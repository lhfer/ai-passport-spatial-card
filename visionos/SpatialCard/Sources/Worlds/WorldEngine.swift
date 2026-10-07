import ARKit
import Foundation
import Observation
import RealityKit
import SwiftUI
import UIKit

// MARK: - Context

/// Everything a world needs to place itself: the wearer's head, the desk/card, floor height and
/// the forward direction (head → card, horizontal). Frozen at entry so nothing depends on tracking
/// inside a world (P0-3: image tracking stops under .full; we stay .mixed anyway, but worlds never
/// follow the anchor).
struct WorldContext {
    var headPose: simd_float4x4
    var cardPose: simd_float4x4
    var floorY: Float
    var surfaceY: Float
    /// Follower counts frozen at entry (a live update arrives through `World.onStats`).
    var stats: CardStats = .zero
    /// **V3-2b B3 / plan §4 E11.** How far above the card the world tears itself open. On the desk the card
    /// stands 22 cm over the passport and the seam belongs at eye level for a seated reader (0.45 m); in the
    /// hand the card is already up near the wearer's face, so the same 45 cm would open the portal above
    /// their head — 0.25 m puts it where they are looking. Frozen with the rest of the context, so a world
    /// prebuilt for the desk is not silently reused for an entry from the hand (`isClose`).
    var seamRise: Float = WorldContext.seamRiseDesk
    static let seamRiseDesk: Float = 0.45
    static let seamRiseHand: Float = 0.25

    var headPosition: SIMD3<Float> { SIMD3(headPose.columns.3.x, headPose.columns.3.y, headPose.columns.3.z) }
    var cardPosition: SIMD3<Float> { SIMD3(cardPose.columns.3.x, cardPose.columns.3.y, cardPose.columns.3.z) }
    /// Horizontal unit vector from the head toward the card (falls back to −Z of the head).
    var forward: SIMD3<Float> {
        var f = cardPosition - headPosition
        f.y = 0
        if simd_length(f) < 0.05 {
            f = -SIMD3(headPose.columns.2.x, 0, headPose.columns.2.z)
        }
        return simd_length(f) < 0.001 ? [0, 0, -1] : simd_normalize(f)
    }
    var right: SIMD3<Float> { simd_normalize(simd_cross(forward, [0, 1, 0])) }
    /// World origin: head projected to the floor.
    var origin: SIMD3<Float> { SIMD3(headPosition.x, floorY, headPosition.z) }
    var yaw: simd_quatf { simd_quatf(angle: atan2(-forward.x, -forward.z), axis: [0, 1, 0]) }

    /// `seamRise` encodes which form the card is in, and it is the one thing a prebuilt world can never be
    /// reused across: a world torn open 45 cm above a card on the desk is not the world for a card in a hand.
    var isInHand: Bool { seamRise == WorldContext.seamRiseHand }

    /// Whether a world built for `other` can be shown for this context without the wearer noticing.
    ///
    /// **On the desk** (unchanged): the card, the desk and the floor are where they were (the portal seam and
    /// the star origin sit on the card), and the head has not wandered far (it only shifts the world origin /
    /// dome centre, invisible at 30 m scale; a seated reader leaning in stays well inside 35 cm).
    ///
    /// **In the hand** (V3-4 §6 follow-up): the card is *expected* to move — it is in the wearer's hand, and
    /// the 5 cm test below turned every carry into build → `dropped: the wearer moved` → rebuild, 24 builds
    /// and 21 drops in eight minutes on the headset. So the card is not tested at all here; `enter` slides the
    /// finished world horizontally onto wherever the card is by then. What is still tested is everything a
    /// translation **cannot** fix: the head (it is the dome's and the world origin's anchor), the floor and the
    /// desk surface, and the form the card is in.
    func isClose(to other: WorldContext) -> Bool {
        guard seamRise == other.seamRise,
              simd_distance(headPosition, other.headPosition) < (isInHand ? 0.5 : 0.35) else { return false }
        // **V3-5 §2.** In the hand the desk and the floor are not measurements either. With no detected
        // plane the tracker's `surfaceY` is "the device's own height minus its thickness", so it rides up
        // and down with the wearer's arm; against a 3 cm tolerance that is a `dropped: the desk moved`
        // every few seconds — three of them in one held stretch on the headset — and each drop is a ~1 500
        // entity teardown followed by a 90–210 ms rebuild. `floorY` falls out of `surfaceY` when no plane
        // is known, so it goes the same way. (The engine also freezes `surfaceY` at the last desk value
        // while the passport is in the hand, so what a hand build *is* struck against is the real desk.)
        guard isInHand || (abs(floorY - other.floorY) < 0.05 && abs(surfaceY - other.surfaceY) < 0.03) else {
            return false
        }
        guard !isInHand else { return true }
        // **v4 B4 §3.3.** On the desk the card may have been nudged and the wearer's view of it may have turned:
        // neither needs a rebuild — `enter` turns the finished world about the card by the drift and slides it onto
        // the card (`WorldEngine.reuseTransform`), the way V3-4 slid the hand's builds. B3 run 2 dropped and rebuilt
        // the desk builds every time the head→card direction drifted past 6° (`prebuilt … dropped: the wearer moved`,
        // 100–180 ms on the main thread each). What still needs a rebuild is what a rigid move cannot fix: another
        // desk or floor, the head gone far, or the card carried far across the room.
        return simd_distance(cardPosition, other.cardPosition) < WorldContext.deskReuseCardMove
    }

    /// **v4 B4 §3.3.** How far the card may have moved on the same desk and its world still be reused (slid onto it).
    static let deskReuseCardMove: Float = 0.30

    /// Why a prebuilt world cannot be reused, for the log — said as it is (B3's round 2 logged "the wearer moved" for a
    /// 6° turn of the view).
    func dropReason(against other: WorldContext) -> String {
        if seamRise != other.seamRise { return "the card changed form" }
        let head = simd_distance(headPosition, other.headPosition)
        if head >= (isInHand ? 0.5 : 0.35) { return String(format: "the wearer moved %.0f cm", head * 100) }
        // V3-5 §2: neither of these is a reason to drop a build made in the hand — see `isClose`.
        if !isInHand, abs(floorY - other.floorY) >= 0.05 {
            return String(format: "the floor moved %.0f cm", abs(floorY - other.floorY) * 100)
        }
        if !isInHand, abs(surfaceY - other.surfaceY) >= 0.03 {
            return String(format: "the desk moved %.0f cm", abs(surfaceY - other.surfaceY) * 100)
        }
        let card = simd_distance(cardPosition, other.cardPosition)
        if !isInHand, card >= WorldContext.deskReuseCardMove {
            return String(format: "the card moved %.0f cm", card * 100)
        }
        return "reusable"
    }

    /// The yaw between two contexts' forward directions, in radians — what a translation cannot correct.
    func yawDrift(from other: WorldContext) -> Float {
        abs(signedYawDrift(from: other))
    }

    /// **v4 B4 §3.3.** The same, signed: the rotation about world up that takes `other`'s forward onto this one's.
    func signedYawDrift(from other: WorldContext) -> Float {
        let a = atan2(-forward.x, -forward.z), b = atan2(-other.forward.x, -other.forward.z)
        var d = a - b
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }
}

/// Poses the engine freezes into a `WorldContext` when a world is entered (from the tracker, or synthesized in
/// preview mode). Supplied by `WorldEngine.poseProvider`; nil fields fall back to a seated reader at the desk.
struct WorldEntryPose {
    var head: simd_float4x4?
    var card: simd_float4x4?
    var floorY: Float?
    var surfaceY: Float?
    /// **V3-2b B3**: the passport is in the wearer's hand, so the world grows out of the card they are
    /// holding rather than out of a card standing on a desk (`WorldContext.seamRise`).
    var inHand = false
    /// **V3-5 §2.** How long the passport has been standing still, from the desk gate's own 0.3 s windowed
    /// speed estimate. A prebuild in the hand is a 180–210 ms stall of the main actor and the wearer is
    /// looking straight at the card while it happens — so it waits for a moment when they are not moving.
    var stillSeconds: TimeInterval = 0
    /// **v4 B2.** The card is standing on the desk and being tracked (`expanded`) — the only state a prebuild may
    /// stall. Round 1 built both worlds at the desk while the passport was lost (`held(untracked)`) and the wearer
    /// was paging through note previews: 133 and 102 ms of frozen frames in the middle of reading.
    var deskAtRest = false

    init(head: simd_float4x4? = nil, card: simd_float4x4? = nil, floorY: Float? = nil, surfaceY: Float? = nil,
         inHand: Bool = false, stillSeconds: TimeInterval = 0, deskAtRest: Bool = false) {
        self.head = head
        self.card = card
        self.floorY = floorY
        self.surfaceY = surfaceY
        self.inHand = inHand
        self.stillSeconds = stillSeconds
        self.deskAtRest = deskAtRest
    }
}

// MARK: - World protocol

/// One world = procedural environment + the four choreographies. Progress values are 0…1 over the
/// descriptor's durations; `inside` runs every frame while the wearer is in the world.
@MainActor
protocol World: AnyObject {
    var descriptor: WorldDescriptor { get }
    var root: Entity { get }
    func build(ctx: WorldContext, engine: WorldEngine)
    /// **v4 B5 §5.** The same build as named steps, for a desk prebuild spread over frames (`WorldBuildJob`). Default: the
    /// whole `build` as one step (the worlds only `--all-worlds` reaches are never prebuilt).
    func buildSteps(ctx: WorldContext, engine: WorldEngine) -> [WorldBuildStep]
    /// How this world converts and breaks away the real room (see `RoomFission`); nil = the world's own transition
    /// carries the whole entry (no competing motion).
    func fissionRecipe(ctx: WorldContext) -> RoomFission.Recipe?
    /// Quality tier changed (auto-degrade or `--quality`): scale particles / instances / extras.
    func applyQuality(_ tier: WorldQuality)
    func entry(progress: Float, dt: Float, ctx: WorldContext, engine: WorldEngine)
    func inside(dt: Float, ctx: WorldContext, engine: WorldEngine)
    func exit(progress: Float, dt: Float, ctx: WorldContext, engine: WorldEngine)
    func teardown()
    /// A prebuilt world waits in the scene, enabled but parked 4 km behind the wearer (out of view and culled);
    /// worlds pause their emitters and clocks while parked (default: nothing).
    func setParked(_ parked: Bool)
    /// New follower counts (default: ignore). Arrives before `onCelebrate` for the same event, so implementations
    /// set targets idempotently and let `onCelebrate` own the fanfare.
    func onStats(_ stats: CardStats, engine: WorldEngine)
    /// New followers while inside (default: ignore). `stats` already includes the delta.
    func onCelebrate(delta: Int, stats: CardStats, engine: WorldEngine)
}

extension World {
    func buildSteps(ctx: WorldContext, engine: WorldEngine) -> [WorldBuildStep] {
        [WorldBuildStep("build") { [weak self] in self?.build(ctx: ctx, engine: engine) }]
    }
    func applyQuality(_ tier: WorldQuality) {}
    func setParked(_ parked: Bool) {}
    func onStats(_ stats: CardStats, engine: WorldEngine) {}
    func onCelebrate(delta: Int, stats: CardStats, engine: WorldEngine) {}
}

// MARK: - Shell sphere

/// Inward-facing sphere around the wearer. It is the only thing that dims or recolours the passthrough
/// (P0-2: `colorMultiply` updates at 7–9 Hz), and it can split into two half-shells for the CRT exit.
@MainActor
final class ShellSphere {
    let root = Entity()
    let upper: ModelEntity
    let lower: ModelEntity
    private(set) var color: UIColor = .black

    /// `split` = two tall cylinder bands (upper from the eye line up, lower from the eye line down) that slide
    /// in from above/below to meet at the eye line (CRT shutter); otherwise one seamless sphere.
    init(split: Bool = false) {
        if split {
            upper = ModelEntity(mesh: FXMeshes.cylinderBand(radius: 4, yMin: 0, yMax: 12), materials: [ShellSphere.material(.black)])
            lower = ModelEntity(mesh: FXMeshes.cylinderBand(radius: 4, yMin: -12, yMax: 0), materials: [ShellSphere.material(.black)])
            upper.position.y = 12
            lower.position.y = -12
            root.addChild(upper)
            root.addChild(lower)
        } else {
            let mesh = MeshResource.generateSphere(radius: 4)
            upper = ModelEntity(mesh: mesh, materials: [ShellSphere.material(.black)])
            lower = ModelEntity(mesh: mesh, materials: [ShellSphere.material(.black)])
            root.addChild(upper)
        }
        root.components.set(OpacityComponent(opacity: 0))
        root.isEnabled = false
        pinSortOrder()
    }

    private static func material(_ color: UIColor) -> UnlitMaterial {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        m.color = .init(tint: color, texture: nil)
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        m.faceCulling = .none            // seen from inside
        m.writesDepth = false
        return m
    }

    /// Transparent entities sort by bounds centre; the shell's centre is the head, so it would be drawn last and
    /// cover every other transparent thing. Pin it to the front of the world sort group instead.
    private func pinSortOrder() {
        for e in [upper, lower] {
            e.components.set(ModelSortGroupComponent(group: WorldEngine.sortGroup, order: WorldEngine.shellOrder))
        }
    }

    func setColor(_ color: UIColor) {
        self.color = color
        upper.model?.materials = [ShellSphere.material(color)]
        lower.model?.materials = [ShellSphere.material(color)]
    }

    var opacity: Float { root.components[OpacityComponent.self]?.opacity ?? 0 }

    func set(opacity: Float) {
        root.isEnabled = opacity > 0.001
        root.components.set(OpacityComponent(opacity: max(0, min(1, opacity))))
    }

    /// Follow the head so the sphere is always centred on the wearer.
    func follow(_ head: SIMD3<Float>) {
        root.position = head
    }

    /// Radius in metres (the mesh is 4 m; worlds with distant scenery use it as a sky dome).
    func setRadius(_ radius: Float) {
        let k = radius / 4
        root.scale = [k, k, k]
    }

    /// Textured dome (star field etc.) instead of a flat colour.
    func setTexture(_ texture: TextureResource?, tint: UIColor) {
        var m = UnlitMaterial(applyPostProcessToneMap: false)
        m.color = .init(tint: tint, texture: texture.map { .init($0) })
        m.blending = .transparent(opacity: .init(floatLiteral: 1))
        m.faceCulling = .none
        m.writesDepth = false
        upper.model?.materials = [m]
        lower.model?.materials = [m]
    }

    /// CRT shutter: 0 = bands parked out of view above/below, 1 = band edges meet at the eye line.
    func setShutter(_ amount: Float) {
        let park = 12 * (1 - max(0, min(1, amount)))
        upper.position.y = park
        lower.position.y = -park
    }
}

// MARK: - Title state

/// Observable text a world shows in a SwiftUI attachment (`NebulaTitleView`): the follower count rolls with
/// `numericText`, so the world writes the number at the beat it wants the roll.
@MainActor
@Observable
final class WorldTitleState {
    var followers = 0
    var caption = ""
}

// MARK: - Engine

@MainActor
@Observable
final class WorldEngine {
    enum State: Equatable {
        case desk
        case entering(String)
        case inside(String)
        case exiting(String)

        var worldID: String? {
            switch self {
            case .desk: return nil
            case .entering(let id), .inside(let id), .exiting(let id): return id
            }
        }
    }

    /// One sort group for everything a world draws: shell first (order 0), a world's own sky dome while it fades
    /// (order 1), room cells and world content after (order 2).
    static let sortGroup = ModelSortGroup(depthPass: nil)
    static let shellOrder: Int32 = 0
    static let domeOrder: Int32 = 1
    static let worldOrder: Int32 = 2

    static let exitAttachmentID = "world-exit"
    static let titleAttachmentID = "world-title"
    static func coinAttachmentID(_ id: String) -> String { "world-coin-\(id)" }
    static func nameLabelAttachmentID(_ id: String) -> String { "world-name-\(id)" }

    /// Worlds polished for the video; the other descriptors only appear with `--all-worlds`.
    static let shippedIDs = ["neon-city", "data-nebula"]
    /// Seconds of the exit during which the shell is clamped opaque: the space switches back to `.mixed` at exit
    /// start and there is no completion callback, so the passthrough must not be visible before the switch lands.
    static let mixedRestoreHold: Float = 0.6
    /// Exit progress at which the desk hologram is released (`onReturnedToDesk`): the glint is already on the card
    /// while the last of the black lifts.
    static let returnRevealProgress: Float = 0.8
    /// Seconds the desk must be quiet (no presence transition) before a world is prebuilt: the reveal (3.3–3.4 s)
    /// and its settle tail must never share a frame with a build.
    static let deskIdleAfter: TimeInterval = 4.0

    private(set) var state: State = .desk
    /// 0…1 inside entering/exiting.
    private(set) var progress: Float = 0
    /// Every descriptor in the bundle (for `--all-worlds`).
    let allDescriptors: [WorldDescriptor]
    /// Worlds the coins / carousel / preload use: the shipped two unless `--all-worlds`.
    let descriptors: [WorldDescriptor]
    let allWorlds: Bool
    /// Tint the hologram should take (nil = the style's own): the highlighted world's at `hologramTintStrength`
    /// 0.35, the active world's at 1 — and it stays after an exit until the next highlight / entry / `clearTheme()`,
    /// because the device keeps showing that world's screen.
    private(set) var hologramTint: UIColor?
    private(set) var hologramTintStrength: Float = 1
    /// Themed exit button text (nil = hidden).
    private(set) var exitLabel: String?
    /// Index into `descriptors` of the coin the carousel rests on (device UP / DOWN, coin press).
    private(set) var highlightedIndex: Int?
    /// Uptime of the last highlight (v3 H2 §4): OK enters the highlighted world only while the wearer's
    /// UP / DOWN is still recent, so a coin highlighted a minute ago cannot swallow an OK that was meant for
    /// the card. Nil = nothing has been highlighted this session.
    private(set) var highlightedAt: TimeInterval?
    /// …and the window that "recent" means.
    static let highlightWindow: TimeInterval = 5
    var highlightedRecently: Bool {
        guard highlightedIndex != nil, let at = highlightedAt else { return false }
        return ProcessInfo.processInfo.systemUptime - at <= WorldEngine.highlightWindow
    }
    var highlightedDescriptor: WorldDescriptor? { highlightedIndex.flatMap { descriptors.indices.contains($0) ? descriptors[$0] : nil } }
    /// True once a world has given the desk back (exit progress ≥ `returnRevealProgress`, and at the desk): the
    /// hologram may resume presence / pose updates even though `state` is still `.exiting`.
    private(set) var hologramReleased = true

    let root = Entity()                 // world-space root for environments
    let assets = WorldAssetLibrary()    // USDZ / HDRI / sky cache (Phase B)
    let fission = RoomFission()         // the real room, chunked, converted and broken away per world
    /// Current quality tier; starts at `initialQuality`, steps down when the watchdog sees < 80 fps inside a world.
    private(set) var quality: WorldQuality = WorldEngine.defaultQuality
    /// **v4 B5 §4** `cmd perf tier=`: a tier the director holds a world at (the watchdog leaves it alone); nil = none.
    private(set) var forcedQuality: WorldQuality?
    var initialQuality: WorldQuality = WorldEngine.defaultQuality
    /// Where a world starts when `--quality` says nothing. The headset draws two eyes at 90 Hz and measured
    /// 45 fps inside 霓虹雨城 at `high`, so the device starts one tier down — `medium` keeps every hero piece and
    /// gives up the high-only art (the last of the far towers), a third of the rain, one of the two cloud
    /// sheets — and the watchdog can still fall to `low`. The simulator, where the look is judged and there is
    /// no compositor budget to miss, stays at `high`. `--quality` overrides both (AppModel only writes
    /// `initialQuality` when the flag is present).
    static let defaultQuality: WorldQuality = {
        #if targetEnvironment(simulator)
        return .high
        #else
        return .medium
        #endif
    }()
    private var fpsWindow: (frames: Int, seconds: Float) = (0, 0)
    private var lastDegrade: Float = -10
    /// A degrade just happened: print the next full window so the log says whether the new tier helped.
    private var reportNextWindow = false
    /// The first 2 s window after entry is discarded (upload / warm-up frames are not the steady state).
    private var watchdogWarm = false
    private var assetLayer: Entity?
    let shell = ShellSphere()           // sky / passthrough cover (radius per world)
    /// True while the space should be `.full` (set once the shell is opaque; cleared at exit start, before it opens).
    private(set) var wantsFull = false
    private var entryDuration: Float = 1
    private var exitDuration: Float = 1
    private var hasFission = false
    let shutter = ShellSphere(split: true)   // near black shell for CRT-style closes (radius 3 m)
    let exitHolder = Entity()           // holds the exit-button attachment (billboard)
    /// Holds the world title attachment (`NebulaTitleView`); worlds place, scale and fade it.
    let titleHolder = Entity()
    let title = WorldTitleState()
    private var active: World?
    private var ctx: WorldContext?
    /// **v4 B4 §3.3.** The live context at the entry: what is placed off the wearer's head outside the world's root (the
    /// shell, the shutter, the exit button) uses it — a reused build's `ctx` is the build's, and its root has been turned
    /// and slid onto the live card.
    private var placementContext: WorldContext?
    /// **v4 B4 §3.2.** The prebuilt world a highlighted coin brought back into the tree ahead of an entry.
    private var warmedWorld: String?
    /// **v4 B4 §3.2.** The world an entry is starting on. The entry's own first hook (`onEnterStarted` →
    /// `AppModel.clearDeskRing`) clears the desk's highlight while the engine is still at the desk; that must not take
    /// the warmed world back out of the tree a moment before the entry puts it in again.
    private var enteringWorld: String?
    /// **v4 B4 §3.5** `cmd perf worlds=on`: keep the desk's prebuilt worlds in the scene tree (B3's desk).
    private var prebuiltInTree = false
    private var elapsed: Float = 0
    private var ambient: AudioPlaybackController?
    private var reducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Called once per exit when the world has given the desk back (progress ≥ `returnRevealProgress`).
    var onReturnedToDesk: (() -> Void)?
    /// The shell has just been measured opaque (once per entry, before `wantsFull` flips): the device may change
    /// its screen now (`set_theme`) and the tracker pauses.
    var onShellOpaque: ((String) -> Void)?
    /// `exit()` has switched the space back toward `.mixed` (shell still opaque): the tracker may resume.
    var onMixedRestored: ((String) -> Void)?
    /// The space was dismissed mid-world (Digital Crown), so no exit choreography ran and neither
    /// `onMixedRestored` nor `onReturnedToDesk` fired: the tracker takes its pause / world hold back and the
    /// device leaves the world's screen. Fires from `abort()` only when a world was active.
    var onAborted: ((String) -> Void)?
    /// A world entry begins (id, coin index): the gate takes its hold, the desk answers the coin.
    var onEnterStarted: ((String, Int) -> Void)?
    /// The carousel moved (index into `descriptors`, nil = nothing highlighted): the desk shows it.
    var onHighlightChanged: ((Int?) -> Void)?
    /// Where the wearer, the card, the floor and the desk are right now (frozen into the `WorldContext`).
    var poseProvider: (() -> WorldEntryPose)?
    /// Follower counts for the worlds (set by AppModel; frozen into `WorldContext.stats` at entry, forwarded to
    /// `World.onStats` while inside).
    var stats: CardStats = .zero {
        didSet {
            guard stats != oldValue, case .inside = state else { return }
            active?.onStats(stats, engine: self)
        }
    }
    /// Themed exit button inside a world; false while the device is connected (long OK exits instead).
    var showsExitButton = true {
        didSet { if case .inside = state { exitHolder.isEnabled = showsExitButton } }
    }
    private var pendingCelebrations: [Int] = []
    /// Supplies the current room mesh anchors (from CardTracker's SceneReconstructionProvider). Empty until
    /// something starts that provider — which, since v2, only happens on demand (see `onNeedsRoomMesh`).
    var meshAnchorsProvider: (() -> [UUID: MeshAnchor])?
    /// A world that converts the real room (`RoomFission`) is about to be prebuilt or highlighted, so the room
    /// mesh will be needed shortly: `CardTracker` starts scene reconstruction in a second session.
    ///
    /// Fires at most once per engine, and only for a world **outside the shipped set** (which means only under
    /// `--all-worlds`, since `descriptors` is filtered otherwise). The two shipped worlds must never start that
    /// provider — it is what image tracking was competing with in the first device test. Note that data-nebula's
    /// recipe is still non-nil today: with no mesh its cells list is empty and `RoomFission.coverage` falls back
    /// to its time ramp, which is exactly what 工作包 C makes permanent by dropping the recipe.
    var onNeedsRoomMesh: (() -> Void)?
    private var askedForRoomMesh = false
    private var deskAccumulator: Float = 0
    private var lastDeskActivity = Date()
    /// Worlds built ahead of time at the desk for the pose the wearer is in now (`[perf] enter <id>: world.build ≤ 8 ms`).
    private var prebuiltWorlds: [String: Prebuilt] = [:]
    private var lastPrebuild = Date.distantPast
    /// **v4 B5 §5.** The desk build in flight (one at a time): its steps, and what it is filling — a whole world for the
    /// desk, or an art layer for whichever build wants it next.
    private var buildJob: WorldBuildJob?
    private var buildJobWorld: (world: World, layer: Entity, ctx: WorldContext)?
    private var buildJobLayer: (layer: Entity, descriptor: WorldDescriptor)?
    /// **v4 B5 §5** `--prebuild-slice-ms`: the main-thread time a desk build may take in one frame (s). 6 ms by default,
    /// at most 8 (the brief's ceiling): a 90 Hz frame is 11.1 ms, and the rest of the frame is the app's own work.
    var prebuildSlice: Double = 0.006

    private struct Prebuilt {
        let world: World
        let layer: Entity
        let ctx: WorldContext
    }
    /// Where a prebuilt world waits: far behind the wearer and below the horizon, so it is never in view. (V3-4 kept it
    /// registered there — "enabling a 1 500-entity subtree costs ~150 ms; moving its root costs nothing". The worlds
    /// are 312 and 36 entities now, B2 measured the switch back on at 0–1 ms on the headset, and **v4 B4 §3.2** keeps
    /// them out of the tree until a highlighted coin or the entry wants them: `[perf] enter …: world.enable` measures it.)
    private static func parkOffset(_ ctx: WorldContext) -> SIMD3<Float> { ctx.forward * -4000 + SIMD3<Float>(0, -60, 0) }

    /// The horizontal part of "the card has moved since this world was built". Y is dropped on purpose — see
    /// the note in `enter`.
    static func horizontalDelta(from built: SIMD3<Float>, to live: SIMD3<Float>) -> SIMD3<Float> {
        [live.x - built.x, 0, live.z - built.z]
    }

    /// **v4 B4 §3.3.** The rigid move that puts a world built for `built` onto `live`: a turn about world up through the
    /// card by the view's drift, then the card's horizontal move. The build-time height is kept (see `enter`). Every
    /// point the build placed off the card — the seam, the street, the dome's centre — moves with the root; what is
    /// placed off the *head* is off by `|card − head| · (1 − cos drift)` (≈ 1 cm at 0.7 m and 10°).
    static func reuseTransform(from built: WorldContext, to live: WorldContext) -> (rotation: simd_quatf, translation: SIMD3<Float>, drift: Float) {
        let drift = live.signedYawDrift(from: built)
        let rotation = simd_quatf(angle: drift, axis: [0, 1, 0])
        let pivot = rotation.act(built.cardPosition)
        let card = live.cardPosition
        return (rotation, [card.x - pivot.x, 0, card.z - pivot.z], drift)
    }

    init(allWorlds: Bool = false) {
        self.allWorlds = allWorlds
        allDescriptors = WorldDescriptor.loadAll()
        descriptors = allWorlds ? allDescriptors : allDescriptors.filter { WorldEngine.shippedIDs.contains($0.id) }
        root.addChild(shell.root)
        root.addChild(fission.root)
        // v4 B4 §3.2: the room fission's root waits out of the tree until an entry `begin`s it — the state every exit
        // leaves it in (`RoomFission.end`), so a fresh desk no longer counts an empty `world.fission` in its scene.
        fission.root.isEnabled = false
        shutter.setRadius(3)
        root.addChild(shutter.root)
        exitHolder.components.set(BillboardComponent())
        exitHolder.isEnabled = false
        root.addChild(exitHolder)
        titleHolder.components.set(BillboardComponent())
        titleHolder.isEnabled = false
        root.addChild(titleHolder)
        root.components.set(EngineTickComponent(tick: { [weak self] dt in self?.tick(dt: dt) }))
        // v4 B2: names for `[perf] scene detail:` (the worlds themselves are named at assembly).
        for (entity, name) in [(root, "worlds"), (shell.root, "world.shell"), (fission.root, "world.fission"),
                               (shutter.root, "world.shutter"), (exitHolder, "world.exit"),
                               (titleHolder, "world.title")] as [(Entity, String)] where entity.name.isEmpty {
            entity.name = name
        }
    }

    var isActive: Bool { state != .desk }

    func descriptor(_ id: String) -> WorldDescriptor? { descriptors.first { $0.id == id } }

    func isShipped(_ d: WorldDescriptor) -> Bool { WorldEngine.shippedIDs.contains(d.id) }

    // MARK: Carousel (device UP / DOWN / OK, coin press)

    /// Rest the carousel on coin `index` (nil = none): the desk highlights it, the hologram frame previews its
    /// colour at 0.35, a hidden world starts loading. Ignored while a world is active.
    @discardableResult
    func highlight(_ index: Int?) -> WorldDescriptor? {
        guard state == .desk else { return nil }
        guard let index, descriptors.indices.contains(index) else {
            highlightedIndex = nil
            highlightedAt = nil
            clearTheme()
            warmPrebuilt(nil)
            onHighlightChanged?(nil)
            return nil
        }
        highlightedIndex = index
        highlightedAt = ProcessInfo.processInfo.systemUptime
        let d = descriptors[index]
        warmPrebuilt(d.id)
        hologramTint = d.hologramTintColor
        hologramTintStrength = 0.35
        if !isShipped(d) { assets.preload(d) }
        requestRoomMeshIfNeeded(for: d)
        onHighlightChanged?(index)
        return d
    }

    @discardableResult
    func highlight(id: String) -> WorldDescriptor? {
        guard let index = descriptors.firstIndex(where: { $0.id == id }) else { return nil }
        return highlight(index)
    }

    /// Device DOWN: the next coin (the first when nothing is highlighted).
    @discardableResult
    func highlightNext() -> WorldDescriptor? {
        guard !descriptors.isEmpty else { return nil }
        return highlight(highlightedIndex.map { ($0 + 1) % descriptors.count } ?? 0)
    }

    /// Device UP: the previous coin (the last when nothing is highlighted).
    @discardableResult
    func highlightPrevious() -> WorldDescriptor? {
        guard !descriptors.isEmpty else { return nil }
        return highlight(highlightedIndex.map { ($0 + descriptors.count - 1) % descriptors.count } ?? descriptors.count - 1)
    }

    /// Device OK / coin release: enter the highlighted world with the poses `poseProvider` reports now.
    @discardableResult
    func enterHighlighted() -> Bool {
        guard let d = highlightedDescriptor else { return false }
        return enter(d.id)
    }

    /// Enter `id` with the poses `poseProvider` reports now (a seated reader at the desk when it has none).
    @discardableResult
    func enter(_ id: String) -> Bool {
        if let d = descriptor(id) { requestRoomMeshIfNeeded(for: d) }
        let pose = poseProvider?() ?? WorldEntryPose()
        return enter(id, head: pose.head, card: pose.card, floorY: pose.floorY,
                     surfaceY: deskSurfaceY(for: pose), inHand: pose.inHand)
    }

    /// **V3-5 §2.** The desk's height, frozen while the passport is in the wearer's hand.
    ///
    /// `CardTracker.surfaceY` falls back to "the image plane minus the device's thickness" when no plane is
    /// detected, which in the hand is the wearer's arm, not a desk. Every world the engine strikes — the
    /// floor, the dome's base, the star origin — is measured off it, and so is the 3 cm test that decides
    /// whether a prebuilt world is still usable. So the last height measured with the passport **on** a
    /// desk is the one a hand build (and a hand entry) is struck against.
    private func deskSurfaceY(for pose: WorldEntryPose) -> Float? {
        guard pose.inHand else {
            if let y = pose.surfaceY { lastDeskSurfaceY = y }
            return pose.surfaceY
        }
        return lastDeskSurfaceY ?? pose.surfaceY
    }

    private var lastDeskSurfaceY: Float?

    /// Device long OK / exit button / hub.
    func exitToDesk() {
        exit()
    }

    /// Drop the persisted world tint (the device went back to the base screen).
    func clearTheme() {
        hologramTint = nil
        hologramTintStrength = 1
    }

    // MARK: Lifecycle

    /// Freeze `head`/`card`/`floorY`/`surfaceY` into the context and start the entry choreography. Prefer the
    /// carousel API; this is the primitive behind it.
    @discardableResult
    func enter(_ id: String, head: simd_float4x4?, card: simd_float4x4?, floorY: Float?, surfaceY: Float?,
               inHand: Bool = false) -> Bool {
        guard state == .desk, let descriptor = descriptor(id) else { return false }
        var context = WorldEngine.context(head: head, card: card, floorY: floorY, surfaceY: surfaceY,
                                          stats: stats, inHand: inHand)
        // **V3-2b B3 / plan §4 E11.** Which card the world is growing out of — the one on the desk, or the one
        // in the wearer's hand — and therefore where its seam tears open.
        print(String(format: "[world] entering %@ (from the %@, seam +%.2f m)", id,
                     inHand ? "hand" : "desk", context.seamRise))
        // The card where it is **now**, kept across the `context = pre.ctx` overwrite below.
        let liveCardPosition = context.cardPosition
        let index = descriptors.firstIndex { $0.id == id } ?? 0
        if highlightedIndex != index { highlightedIndex = index; onHighlightChanged?(index) }
        var t0 = Date()
        func mark(_ what: String) { let now = Date(); print(String(format: "\(PerfLog.prefix) enter %@: %@ %.0f ms", id, what, now.timeIntervalSince(t0) * 1000)); t0 = now }
        // The gate freezes its pose *after* the context was read from the tracker, never before.
        enteringWorld = id
        defer { enteringWorld = nil }
        onEnterStarted?(id, index)
        pendingCelebrations.removeAll()
        hologramReleased = false
        let world: World
        let layer: Entity
        // v4 B5 §5: a desk build of this world still in flight finishes now (only what is left of it) — unless the entry
        // is from the hand, which a desk build cannot serve (`isClose`): that one waits, and the hand builds live.
        finishBuildJob(for: id, wholeWorld: !inHand)
        let pre = prebuiltWorlds.removeValue(forKey: id)
        if let pre, pre.ctx.isClose(to: context) {
            world = pre.world
            layer = pre.layer
            // **V3-4 §6 follow-up.** A world prebuilt in the hand was built for the card as it was *then*, and
            // the hand has moved since — that is the whole point of not dropping it for card motion. Everything
            // the build placed off the card (the portal seam and its two light edges, the nebula's core and
            // ring) is a child of `world.root`, so sliding the root horizontally by Δcard puts all of it back
            // on the card without rebuilding anything.
            //
            // **x and z only.** The build-time y is kept deliberately: the floor, the puddles and the street
            // are struck from `ctx.origin` (the head projected to `floorY`), and lifting the root with a card
            // that was raised would sink or float the ground the world stands on. The card's own height is
            // absorbed by the seam's `seamRise`, which is already the hand's 0.25 m.
            //
            // What this does **not** fix is the yaw: everything is oriented at the build-time `ctx.yaw`
            // (head → card, horizontal), and a wearer who has swung the passport across their body since the
            // build enters a world turned by that angle. The drift is logged next to the translation so the
            // headset round has the number rather than an argument.
            // v4 B4 §3.3: turned about the card by the view's drift and slid onto it — no rebuild for a turn of the head.
            let move = WorldEngine.reuseTransform(from: pre.ctx, to: context)
            // v4 B4 §3.2: a desk build waits out of the scene tree (and v4 B2's hand parking does the same); it comes
            // back here, unless a highlighted coin already brought it back (`warmPrebuilt`).
            if !world.root.isEnabled {
                world.root.isEnabled = true
                mark("world.enable (out of the tree until the entry)")
            }
            world.root.transform = Transform(scale: [1, 1, 1], rotation: move.rotation, translation: move.translation)
            world.setParked(false)
            warmedWorld = nil
            let frozenStats = pre.ctx.stats
            placementContext = context
            context = pre.ctx
            context.stats = stats
            mark("world.build (prebuilt)")
            if simd_length(move.translation) > 0.005 || abs(move.drift) > 0.5 * .pi / 180 {
                print(String(format: "[world] prebuilt root moved %.0f cm and turned %+.0f° about the card to the current view (no rebuild)",
                             simd_length(move.translation) * 100, move.drift * 180 / .pi))
            }
            if frozenStats != stats { world.onStats(stats, engine: self) }
        } else {
            if let pre {
                pre.world.teardown()
                pre.world.root.removeFromParent()
                print("\(PerfLog.prefix) prebuilt \(id) discarded: the pose drifted since the desk build")
            }
            let built = assemble(descriptor, ctx: context, mark: mark)
            world = built.world
            layer = built.layer
            placementContext = context
        }
        ctx = context
        active = world
        assetLayer = layer
        elapsed = 0
        progress = 0
        shell.setColor(descriptor.shellColor)
        shell.setRadius(descriptor.environment?.skyRadius ?? 4)
        // The head-centred shells follow the head as it is now (a reused build's context is the build's).
        shell.follow(placementContext?.headPosition ?? context.headPosition)
        shell.set(opacity: 0)
        if let env = descriptor.environment, env.skyOnShell, let sky = assets.sky(for: id) {
            shell.setTexture(sky, tint: env.skyTint.map { UIColor(hex: $0) } ?? .white)
        } else {
            shell.setTexture(nil, tint: descriptor.shellColor)
        }
        shutter.setColor(.black)
        shutter.follow(placementContext?.headPosition ?? context.headPosition)
        shutter.set(opacity: 0)
        shutter.setShutter(0)
        quality = forcedQuality ?? initialQuality
        WorldLighting.applyTier(quality, to: layer)
        world.applyQuality(quality)
        if world.root.parent !== root { root.addChild(world.root) }
        mark("tier+add")
        if let recipe = world.fissionRecipe(ctx: context) {
            // V3-4 §6 follow-up: the room fission tears the *real* room open at the card, so it takes the live
            // card rather than `context`'s (which is the build-time one whenever a prebuilt world was reused).
            // Neither shipped world has a recipe and only shipped worlds are prebuilt, so this cannot bite
            // today — it is here so that it cannot start biting when a hidden world becomes prebuildable.
            fission.begin(recipe: recipe, origin: liveCardPosition)
            hasFission = true
        } else {
            hasFission = false
        }
        // The world's own choreography is normalised; give it at least the time the room needs to leave (capped).
        entryDuration = min(4.0, max(descriptor.entry.duration, hasFission ? fission.runDuration * 0.9 : 0))
        hologramTint = descriptor.hologramTintColor
        hologramTintStrength = 1
        exitLabel = nil
        fpsWindow = (0, 0)
        lastDegrade = -10
        watchdogWarm = false
        reportNextWindow = false
        state = .entering(id)
        root.components.set(PerfProbeComponent(label: "world \(id) entry", duration: descriptor.entry.duration))
        FXAudio.shared.play(FXAudio.Cue(rawValue: descriptor.audio.entry) ?? .liftOff, on: root)
        ambient = FXAudio.shared.playLoop(FXAudio.Cue(rawValue: descriptor.audio.ambient) ?? .worldCodeAmbient, on: root, fadeIn: 2.0)
        print("[world] entering \(id)")
        return true
    }

    /// Any exit affordance (button, device long OK, hub).
    func exit() {
        guard case .inside(let id) = state, let descriptor = descriptor(id), let ctx else { return }
        elapsed = 0
        progress = 0
        exitLabel = nil
        exitHolder.isEnabled = false
        exitDuration = descriptor.exit.duration
        // Back to .mixed while the shell is still opaque: the passthrough returns unseen, then the room re-forms.
        wantsFull = false
        onMixedRestored?(id)
        if hasFission && !fission.cells.isEmpty { fission.beginReverse(origin: ctx.cardPosition) }
        state = .exiting(id)
        root.components.set(PerfProbeComponent(label: "world \(id) exit", duration: descriptor.exit.duration))
        FXAudio.shared.play(FXAudio.Cue(rawValue: descriptor.audio.exit) ?? .collapse, on: root)
        ambient?.fade(to: -60, duration: 1.5)
        print("[world] exiting \(id)")
    }

    /// New followers: forwarded to the world while inside, queued while entering, dropped on the desk / exiting.
    func celebrate(delta: Int) {
        switch state {
        case .inside:
            active?.onCelebrate(delta: delta, stats: stats, engine: self)
        case .entering:
            pendingCelebrations.append(delta)
        case .desk, .exiting:
            break
        }
    }

    private func world(for id: String) -> World? { active?.descriptor.id == id ? active : nil }

    /// Every *transparent* ModelEntity of a world draws after the shell (same sort group, higher order). Opaque
    /// meshes stay out of the group; they are already ordered by the depth buffer.
    ///
    /// Measured on the visionOS 27 simulator, because the comment this replaces guessed the other way: a member of
    /// this group (`depthPass: nil`) *is* still depth-tested against opaque geometry — an opaque prop three metres
    /// away hides the star quads behind it, group or no group. What the group fixes is the order against **other
    /// transparent draws**, and that order ignores distance. So anything that turns a prop translucent (an
    /// `OpacityComponent` anywhere above it) drops it out of the depth buffer and lets the whole star field be
    /// composited over it — which is why the nebula fades its props through their materials instead
    /// (`DataNebulaWorld.setArtOpacity`).
    static func applySortOrder(to root: Entity) {
        for child in root.children {
            if let model = child as? ModelEntity, model.components[ModelSortGroupComponent.self] == nil,
               let materials = model.model?.materials, materials.contains(where: isTransparent) {
                model.components.set(ModelSortGroupComponent(group: sortGroup, order: worldOrder))
            }
            applySortOrder(to: child)
        }
    }

    private static func isTransparent(_ material: any RealityKit.Material) -> Bool {
        if let m = material as? UnlitMaterial {
            if case .opaque = m.blending { return false }
            return true
        }
        if let m = material as? PhysicallyBasedMaterial {
            if case .opaque = m.blending { return false }
            return true
        }
        return material is PortalMaterial ? false : true
    }

    /// Digital Crown / space dismissed: drop everything without choreography.
    func abort() {
        // nil = the space was dismissed at the desk: nothing was borrowed, so there is nothing to hand back.
        let aborted = state.worldID
        wantsFull = false
        fission.end()
        active?.teardown()
        active?.root.removeFromParent()
        active = nil
        ambient?.stop()
        ambient = nil
        shell.set(opacity: 0)
        shutter.set(opacity: 0)
        exitHolder.isEnabled = false
        titleHolder.isEnabled = false
        clearTheme()
        exitLabel = nil
        hologramReleased = true
        state = .desk
        if let aborted {
            // Entering / inside / exiting: `exit()` never finished, so this hook is the only thing that gives the
            // tracker and the device screen back (the desk itself is already clean above).
            print("[world] aborted \(aborted)")
            onAborted?(aborted)
        }
    }

    // MARK: Assembly (entry or prebuild)

    /// A `WorldContext` from optional poses: a seated reader 0.6 m behind the card when nothing is tracked.
    private static func context(head: simd_float4x4?, card: simd_float4x4?, floorY: Float?, surfaceY: Float?,
                                stats: CardStats, inHand: Bool = false) -> WorldContext {
        let headPose = head ?? matrix_identity_float4x4
        let cardPose = card ?? Transform(translation: [headPose.columns.3.x, (surfaceY ?? 0.9), headPose.columns.3.z - 0.6]).matrix
        let surf = surfaceY ?? cardPose.columns.3.y
        return WorldContext(headPose: headPose, cardPose: cardPose, floorY: floorY ?? (surf - 0.72), surfaceY: surf,
                            stats: stats,
                            seamRise: inHand ? WorldContext.seamRiseHand : WorldContext.seamRiseDesk)
    }

    /// Art layer + world build + IBL + tiers + sort order, off the scene. `[perf]` marks name each step.
    private func assemble(_ descriptor: WorldDescriptor, ctx: WorldContext, mark: (String) -> Void) -> (world: World, layer: Entity) {
        let world = WorldRegistry.make(descriptor)
        // v4 B2: `[perf] scene detail:` names a parked world by what it is (its art layer keeps its own `assets` name,
        // which the worlds look up).
        if world.root.name.isEmpty { world.root.name = "world.\(descriptor.id)" }
        let layer = assets.instantiate(descriptor, ctx: ctx)
        if let fog = descriptor.fog, !fog.isEmpty { layer.addChild(WorldLighting.fogLayers(fog)) }
        world.root.addChild(layer)
        mark("art layer")
        world.build(ctx: ctx, engine: self)
        mark("world.build")
        if let env = descriptor.environment, let ibl = assets.environment(for: descriptor.id) {
            WorldLighting.applyIBL(ibl, intensity: env.iblIntensity, to: world.root)
        }
        WorldEngine.applySortOrder(to: world.root)
        mark("ibl+sort")
        print("\(PerfLog.prefix) world \(descriptor.id) assets: \(WorldLighting.triangleCount(layer)) triangles in the art layer, quality \(initialQuality)")
        return (world, layer)
    }

    func isPrebuilt(_ id: String) -> Bool { prebuiltWorlds[id] != nil }

    /// Ask for the room mesh if `descriptor`'s world breaks the real room apart (once per engine, hidden worlds only).
    private func requestRoomMeshIfNeeded(for descriptor: WorldDescriptor) {
        guard !askedForRoomMesh, !isShipped(descriptor), WorldRegistry.usesRoomFission(descriptor.id) else { return }
        askedForRoomMesh = true
        print("[mesh] \(descriptor.id) converts the real room: asking for scene reconstruction")
        onNeedsRoomMesh?()
    }

    private func discardPrebuilt(_ id: String) {
        guard let pre = prebuiltWorlds.removeValue(forKey: id) else { return }
        pre.world.teardown()
        pre.world.root.removeFromParent()
    }

    /// Desk idle work: build one shipped world for the wearer's current pose (only when its assets are cached, the
    /// desk has been quiet for `deskIdleAfter`, and at most one build per 1.5 s). A prebuilt world whose pose drifted
    /// (the wearer moved) is dropped and built again on a later tick.
    private func prebuildIfIdle() {
        guard let pose = poseProvider?(), pose.card != nil else { return }
        // **V3-4 §6.** Nothing is prebuilt while the passport is in the wearer's hand.
        //
        // `WorldContext.isClose` wants the card within 5 cm of where the world was built for, which is right
        // for a card standing on a desk and impossible for one in a hand: the first headset round built 24
        // worlds and threw 21 of them away in eight minutes (`prebuilt … dropped: the wearer moved`, then a
        // 90–160 ms rebuild four seconds later), and both 111 ms worst frames inside `[perf] hand form` fell
        // in one of those windows. The discard is not free either — it is a teardown of ~1 500 entities.
        //
        // This returns before either, so a prebuild made at the desk is **kept** (it costs nothing to hold
        // and is exactly what a put-down will want).
        //
        // **V3-4 §6 follow-up.** Not prebuilding in the hand at all was the safe half of the fix and it cost
        // too much: the entry then ran a live `world.build` of 193 ms **inside the tear-open frame** of the
        // hero shot (`[perf] world neon-city entry: worst 327.8 ms`, against `world.build (prebuilt) 2 ms`).
        // So the hand prebuilds too — once per world, and it is **not** dropped when the card moves, because
        // the card moving is what a hand does. `enter` slides the finished root onto the live card instead.
        //
        // **V3-5 §2.** …and in the hand it waits for the wearer to hold still. A build is a 180–210 ms
        // stall of the main actor, and in the hand form the card is 35 cm from the wearer's eyes and
        // following their hand: the second headset round's `prebuilt neon-city in the hand in 182 ms` and
        // `prebuilt data-nebula … 212 ms` fell inside the same window as `hand form 5 s: worst 230 ms`.
        //
        // **v4 B2: nothing at all in the hand — no build, no drop.** Waiting for a still hand (V3-5 §2) was not
        // enough: v4's first headset round still built both worlds in the hand (`prebuilt neon-city in the hand
        // (still 1.7 s) in 173 ms`, `data-nebula … 212 ms`) and those were the session's worst frames (`frame
        // hitch 180 ms`, `228 ms`) — a held frame 35 cm from the wearer's eyes is a visible stutter, still or not.
        // A desk build is kept while the passport is in the hand (dropping it is a teardown of its own), and the
        // desk builds themselves wait for the card to be standing there **tracked** (`deskAtRest`): round 1 also
        // built both at the desk while the passport was lost and the wearer was reading note previews.
        //
        // The price: a world entered **from the hand** is no longer prebuilt (a desk build is for a 0.45 m seam
        // over a card on the desk, `isClose` refuses it for the hand's 0.25 m), so that entry builds live — one
        // stall at the OK press instead of two or three in the hand before it. `[perf] enter <id>: world.build`
        // measures it.
        guard !pose.inHand, pose.deskAtRest else { return }
        guard Date().timeIntervalSince(lastDeskActivity) > WorldEngine.deskIdleAfter, Date().timeIntervalSince(lastPrebuild) > 1.5 else { return }
        // `cmd perf worlds=on` (B3's desk): a build the hand switched off comes back in a quiet desk moment, as B2 did.
        if prebuiltInTree, let (id, pre) = prebuiltWorlds.first(where: { !$0.value.world.root.isEnabled }) {
            pre.world.root.isEnabled = true
            lastPrebuild = Date()
            print("\(PerfLog.prefix) prebuilt \(id) back in the scene tree at the desk (cmd perf worlds=on)")
            return
        }
        let context = WorldEngine.context(head: pose.head, card: pose.card, floorY: pose.floorY,
                                          surfaceY: deskSurfaceY(for: pose), stats: stats, inHand: false)
        for d in descriptors where isShipped(d) {
            if let pre = prebuiltWorlds[d.id] {
                if context.isClose(to: pre.ctx) { continue }
                // Another desk, the wearer gone far, the card carried away: what a rigid move cannot fix. Drop it and
                // earn the idle window again (no rebuild thrash while they move about).
                discardPrebuilt(d.id)
                lastDeskActivity = Date()
                print("\(PerfLog.prefix) prebuilt \(d.id) dropped: \(context.dropReason(against: pre.ctx))")
                continue
            }
            guard assets.isReady(d) else { continue }
            requestRoomMeshIfNeeded(for: d)
            lastPrebuild = Date()
            // v4 B5 §5: the build is a job of steps now, a few milliseconds of every quiet desk frame (`stepBuildJob`).
            startWorldBuildJob(d, ctx: context)
            return
        }
    }

    // MARK: Desk builds over frames (v4 B5 §5)

    /// A desk build may only advance while the desk is quiet (no presence change, key, fan-out or preview for
    /// `deskIdleAfter`) and the passport is not in the hand; a world build also wants the card standing tracked on the
    /// desk (`deskAtRest`, the rule a build always waited for). Otherwise it waits where it is.
    private func stepBuildJob() {
        guard let job = buildJob else { return }
        let pose = poseProvider?()
        let quiet = Date().timeIntervalSince(lastDeskActivity) > WorldEngine.deskIdleAfter
        let allowed: Bool
        switch job.kind {
        case .artLayer: allowed = !(pose?.inHand ?? false) && quiet
        case .world: allowed = !(pose?.inHand ?? false) && (pose?.deskAtRest ?? false) && quiet
        }
        guard allowed else {
            job.pausedFrames += 1
            return
        }
        job.slice(budget: prebuildSlice)
        if job.isDone { completeBuildJob(job) }
    }

    /// The art layer's clones for `d`, a few per step, kept by `WorldAssets` for the next build.
    private func startArtLayerJob(_ d: WorldDescriptor) {
        let (layer, steps) = assets.canonicalSteps(d)
        buildJobLayer = (layer, d)
        buildJob = WorldBuildJob(id: d.id, kind: .artLayer, steps: steps)
        print(String(format: "\(PerfLog.prefix) prebuilding the %@ art layer over frames: %d steps, ≤ %.0f ms a frame",
                     d.id, steps.count, prebuildSlice * 1000))
    }

    /// A whole world for the desk: its art layer (the kept one, or its clones as steps), the world's own steps, the
    /// lighting and sort order, and last the disabled root joining the engine's.
    private func startWorldBuildJob(_ d: WorldDescriptor, ctx: WorldContext) {
        let created = CACurrentMediaTime()
        defer {
            print(String(format: "\(PerfLog.prefix) prebuild %@: the job (the world object, its art layer, its steps) made in %.1f ms",
                         d.id, (CACurrentMediaTime() - created) * 1000))
        }
        let world = WorldRegistry.make(d)
        if world.root.name.isEmpty { world.root.name = "world.\(d.id)" }
        var steps: [WorldBuildStep] = []
        let layer: Entity
        if assets.hasPrebuilt(d) {
            layer = assets.instantiate(d, ctx: ctx)
        } else {
            let canonical = assets.canonicalSteps(d)
            layer = canonical.layer
            steps += canonical.steps
            steps.append(WorldBuildStep("art layer: place") {
                layer.position = ctx.origin
                layer.orientation = ctx.yaw
            })
        }
        steps.append(WorldBuildStep("art layer: fog, attach") { [weak world] in
            if let fog = d.fog, !fog.isEmpty { layer.addChild(WorldLighting.fogLayers(fog)) }
            world?.root.addChild(layer)
        })
        steps += world.buildSteps(ctx: ctx, engine: self)
        steps.append(WorldBuildStep("ibl") { [weak self, weak world] in
            guard let self, let world, let env = d.environment, let ibl = self.assets.environment(for: d.id) else { return }
            WorldLighting.applyIBL(ibl, intensity: env.iblIntensity, to: world.root)
        })
        steps.append(WorldBuildStep("sort order") { [weak world] in
            guard let world else { return }
            WorldEngine.applySortOrder(to: world.root)
        })
        steps.append(WorldBuildStep("park") { [weak self, weak world] in
            // Out of the scene tree until an entry wants it (B4 §3.2): disabled *before* it joins the engine's root.
            guard let self, let world else { return }
            world.root.position = WorldEngine.parkOffset(ctx)
            world.setParked(true)
            world.root.isEnabled = self.prebuiltInTree
            self.root.addChild(world.root)
        })
        buildJobWorld = (world, layer, ctx)
        buildJob = WorldBuildJob(id: d.id, kind: .world, steps: steps)
        print(String(format: "\(PerfLog.prefix) prebuilding %@ at the desk over frames: %d steps, ≤ %.0f ms a frame%@", d.id,
                     steps.count, prebuildSlice * 1000, assets.hasPrebuilt(d) ? "" : " (its art layer's clones included)"))
    }

    /// The last step ran: hand the result to whoever keeps it, and say what it cost.
    private func completeBuildJob(_ job: WorldBuildJob) {
        buildJob = nil
        lastPrebuild = Date()
        let stalls = job.stalls.map { String(format: "; the frame after %@ stalled %.0f ms", $0.after, $0.ms) }.joined()
        let summary = String(format: "%.0f ms of work over %d frames (worst frame %.1f ms, %d frames waited; slowest steps: %@%@)",
                             job.work * 1000, job.frames, job.worstSlice * 1000, job.pausedFrames, job.slowestSteps(3), stalls)
        switch job.kind {
        case .artLayer:
            if let pending = buildJobLayer { assets.storePrebuilt(pending.layer, for: pending.descriptor) }
            buildJobLayer = nil
            print("[assets] \(job.id) art layer prebuilt in \(summary)")
        case .world:
            guard let built = buildJobWorld else { return }
            buildJobWorld = nil
            prebuiltWorlds[job.id] = Prebuilt(world: built.world, layer: built.layer, ctx: built.ctx)
            print("\(PerfLog.prefix) prebuilt \(job.id) at the desk in \(summary) — "
                  + (prebuiltInTree ? "in the scene tree, cmd perf worlds=on" : "out of the scene tree until an entry"))
            print("\(PerfLog.prefix) world \(job.id) assets: \(WorldLighting.triangleCount(built.layer)) triangles in the art layer, quality \(forcedQuality ?? initialQuality)")
        }
    }

    /// An entry wants `id` now: a desk build of it still in flight is finished on the spot (only what was left of it),
    /// and an art-layer job for it too, so the entry's own build can take the layer.
    private func finishBuildJob(for id: String, wholeWorld: Bool) {
        guard let job = buildJob, job.id == id, job.kind == .artLayer || wholeWorld else { return }
        let done = job.stepsDone, total = job.stepCount
        let ms = job.finish() * 1000
        print(String(format: "\(PerfLog.prefix) enter %@: its desk build was %d/%d steps in; the rest now in %.0f ms", id, done, total, ms))
        completeBuildJob(job)
    }

    /// **v4 B5 §4** `cmd perf tier=low|medium|high` (nil = back to the launch's): inside a world it applies at once; at
    /// the desk, from the next entry.
    func setForcedQuality(_ tier: WorldQuality?) {
        guard tier != forcedQuality else { return }
        forcedQuality = tier
        guard let world = active, let id = state.worldID else {
            print("\(PerfLog.prefix) world tier for the next entry: \(tier.map { "\($0)" } ?? "the launch's (\(initialQuality))")")
            return
        }
        quality = tier ?? initialQuality
        if let layer = assetLayer { WorldLighting.applyTier(quality, to: layer) }
        world.applyQuality(quality)
        print("\(PerfLog.prefix) world \(id) tier → \(quality) (cmd perf\(tier == nil ? ": the launch's" : ""))")
    }

    /// **v4 B4 §3.5** `cmd perf worlds=on|off`: the desk's prebuilt worlds in the scene tree (B3's desk, for the A/B on
    /// the headset) or out of it (B4's). Applies to the builds there are and to the ones still to come.
    func setPrebuiltInTree(_ inTree: Bool) {
        guard prebuiltInTree != inTree else { return }
        prebuiltInTree = inTree
        guard state == .desk else { return }
        for (id, pre) in prebuiltWorlds where id != warmedWorld {
            pre.world.root.isEnabled = inTree
        }
        print("\(PerfLog.prefix) prebuilt worlds \(inTree ? "in" : "out of") the scene tree (\(prebuiltWorlds.keys.sorted().joined(separator: ", ")))")
    }

    /// **v4 B4 §3.2.** A coin was highlighted (the desk ring, a coin's own highlight): its prebuilt world goes back into
    /// the tree now, so the entry's frame only moves its root; the one it replaces (if any) goes out again.
    private func warmPrebuilt(_ id: String?) {
        guard !prebuiltInTree else { return }
        if let warm = warmedWorld, warm != id, warm != enteringWorld, let pre = prebuiltWorlds[warm], state == .desk {
            pre.world.root.isEnabled = false
            warmedWorld = nil
            print("\(PerfLog.prefix) prebuilt \(warm) back out of the scene tree (the highlight moved on)")
        }
        guard let id, let pre = prebuiltWorlds[id], !pre.world.root.isEnabled else { return }
        let started = Date()
        pre.world.root.isEnabled = true
        warmedWorld = id
        print(String(format: "\(PerfLog.prefix) prebuilt %@ back in the scene tree for the highlighted coin in %.0f ms", id,
                     Date().timeIntervalSince(started) * 1000))
    }

    /// The desk changed (a presence transition drained by the view): the prebuild waits for `deskIdleAfter` again.
    func noteDeskActivity() {
        lastDeskActivity = Date()
    }

    /// **v4 B2.** With the passport in the wearer's hand no desk build can be used (`isClose` refuses a desk seam for a
    /// hand entry), so a prebuilt world in the tree there buys nothing. **v4 B4 §3.2**: desk builds wait out of the tree
    /// anyway; this takes out one a highlighted coin had brought back.
    private func parkPrebuiltForHand() {
        var parked: [String] = []
        for (id, pre) in prebuiltWorlds where pre.world.root.isEnabled {
            pre.world.root.isEnabled = false
            parked.append(id)
        }
        warmedWorld = nil
        guard !parked.isEmpty else { return }
        print("\(PerfLog.prefix) prebuilt \(parked.sorted().joined(separator: ", ")) switched off for the hand")
    }

    // MARK: Tick

    private func tick(dt: Float) {
        if state == .desk {
            // v4 B5 §5: a desk build in flight gets its slice of every frame it is allowed one.
            if buildJob != nil { stepBuildJob() }
            // Idle work while the wearer is at the desk, at 4 Hz: keep the room cells current, prebuild one art layer
            // / one world per tick, keep textures and IBLs warm.
            deskAccumulator += dt
            guard deskAccumulator >= 0.25 else { return }
            deskAccumulator = 0
            if let anchors = meshAnchorsProvider?() { fission.prepare(anchors: anchors) }
            // v4 B2: the art layer's clone storm (20–33 ms on the headset) waits for the hand too. Before the first
            // detection there is no card at all, so the layers still build at launch as they always did.
            let pose = poseProvider?()
            let inHand = pose?.inHand ?? false
            if inHand { parkPrebuiltForHand() }
            if buildJob != nil {
                // One build at a time: the one in flight finishes first.
            } else if !inHand, let d = descriptors.first(where: { assets.isReady($0) && !assets.hasPrebuilt($0) && !isPrebuilt($0.id) && isShipped($0) }) {
                // v4 B5 §5: the clone storm over frames too (no card yet = the launch: still one block, as before).
                if pose?.card == nil { assets.prebuild(d) } else { startArtLayerJob(d) }
            } else {
                prebuildIfIdle()
            }
            for d in descriptors { if let env = assets.environment(for: d.id) { assets.warmIBL(env, in: root, key: d.id) } }
            assets.warmTextures(in: root)
            // v4 B5 §5: the first use of a textured lit material (the wet asphalt) — 66 ms the frame after, in the
            // simulator — before there is a card at all (the headset's launch: textures in ≤ 2.0 s after start, the first
            // detection ≥ 3.2 s, in all six logged sessions), or else on a quiet desk at rest like a prebuild: never
            // inside a recognition, a reveal, a carry.
            let quiet = Date().timeIntervalSince(lastDeskActivity) > WorldEngine.deskIdleAfter
            if pose?.card == nil || (!inHand && (pose?.deskAtRest ?? false) && quiet) {
                for d in descriptors where isShipped(d) { WorldRegistry.warmMaterials(d, assets: assets, in: root) }
            }
            return
        }
        guard let world = active, let ctx, let descriptor = descriptor(state.worldID ?? "") else { return }
        switch state {
        case .entering(let id):
            elapsed += dt
            let duration = reducedMotion ? min(1.2, descriptor.entry.duration) : entryDuration
            progress = min(1, elapsed / max(0.1, duration))
            if reducedMotion {
                // Comfort fallback: plain cross-fade through the shell.
                shell.set(opacity: progress * descriptor.immersion.shellOpacity)
                world.root.components.set(OpacityComponent(opacity: progress))
            } else {
                world.entry(progress: progress, dt: dt, ctx: ctx, engine: self)
                if hasFission {
                    // Room fission: as cells break away the opaque shell closes in behind them.
                    fission.update(elapsed: elapsed, dt: dt, reverse: false)
                    shell.set(opacity: max(shell.opacity, fission.coverage * descriptor.immersion.shellOpacity))
                }
            }
            let measuredOpaque = shell.opacity >= 0.97 * descriptor.immersion.shellOpacity
            if !wantsFull && (measuredOpaque || (hasFission && fission.coverage >= 0.97) || progress >= 0.85) {
                shell.set(opacity: descriptor.immersion.shellOpacity)
                onShellOpaque?(id)
                wantsFull = true
                print("[world] shell opaque → .full")
            }
            if progress >= 1 {
                state = .inside(id)
                exitLabel = descriptor.exitLabel
                placeExitButton(ctx: placementContext ?? ctx)
                // V3-5 §5: this one carries the scene census (see `PerfLog`).
                exitHolder.components.set(PerfProbeComponent(label: "world \(id) inside", duration: 4,
                                                             reportsScene: true))
                elapsed = 0
                print("[world] inside \(id)")
                for delta in pendingCelebrations { world.onCelebrate(delta: delta, stats: stats, engine: self) }
                pendingCelebrations.removeAll()
            }
        case .inside:
            elapsed += dt
            world.inside(dt: dt, ctx: ctx, engine: self)
            watchdog(dt: dt, world: world)
            if hasFission {
                if fission.coverage < 1 { fission.update(elapsed: entryDuration + elapsed, dt: dt, reverse: false) } else if fission.root.isEnabled { fission.end() }
            }
        case .exiting(let id):
            elapsed += dt
            let duration = reducedMotion ? min(1.2, descriptor.exit.duration) : exitDuration
            progress = min(1, elapsed / max(0.1, duration))
            if reducedMotion {
                shell.set(opacity: (1 - progress) * descriptor.immersion.shellOpacity)
                world.root.components.set(OpacityComponent(opacity: 1 - progress))
            } else {
                world.exit(progress: progress, dt: dt, ctx: ctx, engine: self)
                if hasFission {
                    // Reverse fission scaled to the exit: far cells fly back first, the room re-forms in the world's
                    // material, and the cells nearest the card are the last to fade into the passthrough.
                    fission.update(elapsed: progress * fission.runDuration, dt: dt, reverse: true)
                }
                let open = max(0, (progress - 0.72) / 0.28)
                shell.set(opacity: min(shell.opacity, (1 - open * open) * descriptor.immersion.shellOpacity))
            }
            if elapsed < WorldEngine.mixedRestoreHold {
                // The `.mixed` switch is in flight: whatever the world does, the passthrough stays covered.
                shell.set(opacity: max(shell.opacity, 0.97 * descriptor.immersion.shellOpacity))
            }
            if progress >= WorldEngine.returnRevealProgress && !hologramReleased {
                hologramReleased = true
                onReturnedToDesk?()
            }
            if progress >= 1 {
                fission.end()
                world.teardown()
                world.root.removeFromParent()
                active = nil
                ambient?.stop()
                ambient = nil
                shell.set(opacity: 0)
                shutter.set(opacity: 0)
                titleHolder.isEnabled = false
                // `hologramTint` stays: the desk hologram keeps the world's colour while the device shows its screen.
                state = .desk
                lastDeskActivity = Date()
                print("[world] back on the desk from \(id)")
            }
        case .desk:
            break
        }
    }

    /// Perf gate inside a world: 2 s windows; below 80 fps the tier steps down (at most every 4 s) and the world,
    /// the art layer and the fog drop their optional load. `[perf] … degrade` in the console is the evidence.
    /// The first window after entry only warms up (uploads, first draws).
    private func watchdog(dt: Float, world: World) {
        fpsWindow.frames += 1
        fpsWindow.seconds += dt
        guard fpsWindow.seconds >= 2 else { return }
        let fps = Float(fpsWindow.frames) / fpsWindow.seconds
        fpsWindow = (0, 0)
        guard watchdogWarm else { watchdogWarm = true; return }
        if reportNextWindow {
            // The window that followed the last degrade: without it a log only says the tier fell, never whether
            // it bought anything.
            reportNextWindow = false
            print(String(format: "\(PerfLog.prefix) world %@ after degrade → %@: %.1f fps window", state.worldID ?? "?", quality.description, fps))
        }
        // v4 B5 §4: a tier the director forced is held (the windows are still reported above).
        if forcedQuality == nil, fps < 80 && quality > WorldQuality.low && elapsed - lastDegrade > 4 {
            quality = WorldQuality(rawValue: quality.rawValue - 1) ?? .low
            lastDegrade = elapsed
            if let layer = assetLayer { WorldLighting.applyTier(quality, to: layer) }
            world.applyQuality(quality)
            reportNextWindow = true
            print(String(format: "\(PerfLog.prefix) world %@ degrade → %@ (%.1f fps window)", state.worldID ?? "?", quality.description, fps))
        }
    }

    /// Warm the caches for the shipped worlds while the wearer is at the desk (called once when the space opens);
    /// hidden worlds load lazily when highlighted. CoreText textures are rendered in the background as well.
    func preloadAssets() {
        for d in descriptors where isShipped(d) { assets.preload(d) }
        WorldKit.preheatText(descriptors.filter { isShipped($0) }.flatMap { WorldRegistry.preheatJobs($0) })
        // v4 B5 §5: the sprites and meshes a desk build would otherwise make on the main thread, made ahead.
        for d in descriptors where isShipped(d) { WorldRegistry.prewarm(d) }
        // Ambient loops are loaded on first play (30–50 ms of WAV decode); start and stop them once now.
        for d in descriptors where isShipped(d) {
            if let cue = FXAudio.Cue(rawValue: d.audio.ambient) { FXAudio.shared.playLoop(cue, on: root, fadeIn: 0)?.stop() }
        }
    }

    private func placeExitButton(ctx: WorldContext) {
        // 1 m ahead at eye level + 8 cm: above the hologram card, so the gaze line to it never crosses the desk controls.
        exitHolder.position = ctx.headPosition + ctx.forward * 1.0 + SIMD3<Float>(0, 0.08, 0)
        exitHolder.isEnabled = showsExitButton
        exitHolder.components.set(TweenComponent(scale: (from: [0.6, 0.6, 0.6], to: [1, 1, 1]), opacity: (from: 0, to: 1), duration: 0.4, easing: .easeOutBackSoft))
    }
}

// MARK: - Tick system

struct EngineTickComponent: Component {
    var tick: (Float) -> Void
}

final class EngineTickSystem: System {
    private static let query = EntityQuery(where: .has(EngineTickComponent.self))

    init(scene: RealityKit.Scene) {}

    func update(context: SceneUpdateContext) {
        let cpuStart = FrameCPU.start()
        defer { FrameCPU.stop("engineTick", since: cpuStart) }
        let dt = Float(min(0.05, context.deltaTime))
        for entity in context.entities(matching: EngineTickSystem.query, updatingSystemWhen: .rendering) {
            entity.components[EngineTickComponent.self]?.tick(dt)
        }
    }
}

// MARK: - Registry

@MainActor
enum WorldRegistry {
    static func make(_ descriptor: WorldDescriptor) -> World {
        switch descriptor.id {
        case "code-sea": return CodeSeaWorld(descriptor: descriptor)
        case "neon-city": return NeonCityWorld(descriptor: descriptor)
        case "deep-sea": return DeepSeaWorld(descriptor: descriptor)
        case "paper-valley": return PaperValleyWorld(descriptor: descriptor)
        default: return DataNebulaWorld(descriptor: descriptor)
        }
    }

    /// Whether this world's `fissionRecipe` converts the real room, answered **without** building the world:
    /// the recipes generate textures (`glyphGridTexture`, `causticsTexture`, …) the moment they are constructed, and
    /// the engine has to ask on every carousel step. Keep in sync with the `fissionRecipe` implementations —
    /// **both shipped worlds return nil** (neon-city: the portal tear is the whole transition; data-nebula lost
    /// its recipe in 工作包 C), which is what makes scene reconstruction unnecessary for everything the wearer
    /// can reach without `--all-worlds`.
    static func usesRoomFission(_ id: String) -> Bool {
        switch id {
        case "code-sea", "deep-sea", "paper-valley": return true
        default: return false      // neon-city, data-nebula
        }
    }

    /// **v4 B5 §5.** A world's textured lit materials, warmed once their textures are in (`WorldAssets.warmMaterial`).
    static func warmMaterials(_ descriptor: WorldDescriptor, assets: WorldAssetLibrary, in root: Entity) {
        switch descriptor.id {
        case "neon-city": NeonCityWorld.warmMaterials(descriptor, assets: assets, in: root)
        default: break
        }
    }

    /// **v4 B5 §5.** Star sprites and dome meshes a world's build would make on the main thread, made ahead (async).
    static func prewarm(_ descriptor: WorldDescriptor) {
        switch descriptor.id {
        case "data-nebula": DataNebulaWorld.prewarm(descriptor)
        case "neon-city": NeonCityWorld.prewarm(descriptor)
        default: break
        }
    }

    /// CoreText textures a world's `build` will ask for, so `WorldKit.preheatText` can render them early.
    static func preheatJobs(_ descriptor: WorldDescriptor) -> [WorldKit.TextJob] {
        switch descriptor.id {
        case "neon-city": return NeonCityWorld.preheatJobs(descriptor)
        case "data-nebula": return DataNebulaWorld.preheatJobs(descriptor)
        default: return []
        }
    }
}

// MARK: - SwiftUI pieces

/// Glass coin on the desk that opens a world: the press highlights it (carousel), the release after the press
/// enters — the same two beats as the device's UP/DOWN + OK.
struct WorldCoinView: View {
    let descriptor: WorldDescriptor
    let enabled: Bool
    let onPress: () -> Void
    let onRelease: () -> Void
    @State private var pressed = false

    var body: some View {
        VStack(spacing: 3) {
            Image(systemName: descriptor.icon)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color(uiColor: descriptor.primaryColor))
            Text(descriptor.name)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
        }
        .frame(width: 60, height: 60)
        .glassBackgroundEffect(in: Circle())
        .overlay(Circle().strokeBorder(Color(uiColor: descriptor.primaryColor).opacity(0.7), lineWidth: 1.5))
        .contentShape(Circle())
        .hoverEffect()
        .opacity(enabled ? 1 : 0.35)
        .scaleEffect(pressed ? 1.12 : 1)
        .animation(.spring(response: 0.28, dampingFraction: 0.55), value: pressed)
        .onTapGesture {
            guard enabled, !pressed else { return }
            pressed = true
            onPress()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(140))
                pressed = false
                onRelease()
            }
        }
    }
}

/// Name + subtitle capsule floating above the highlighted coin (carousel).
struct WorldNameLabel: View {
    let descriptor: WorldDescriptor
    let selected: Bool

    var body: some View {
        VStack(spacing: 2) {
            Text(descriptor.name)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color(uiColor: descriptor.primaryColor))
            Text(descriptor.subtitle)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: 210)
                // Third beat of the stagger (coin 0 ms, capsule 90 ms, subtitle 150 ms).
                .opacity(selected ? 1 : 0)
                .offset(y: selected ? 0 : 4)
                .animation(.easeOut(duration: 0.25).delay(selected ? 0.06 : 0), value: selected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color(uiColor: descriptor.primaryColor).opacity(0.6), lineWidth: 1))
    }
}

/// Themed exit button shown inside a world.
struct WorldExitButton: View {
    let label: String
    let tint: UIColor
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Label(label, systemImage: "arrow.uturn.backward")
                .font(.system(size: 20, weight: .semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .glassBackgroundEffect(in: Capsule())
        .overlay(Capsule().strokeBorder(Color(uiColor: tint).opacity(0.8), lineWidth: 1.5))
        .hoverEffect()
    }
}

/// "4,313 位粉丝 · 每颗星是一位粉丝": the count rolls with `numericText` when the world writes `WorldTitleState`.
struct NebulaTitleView: View {
    let followers: Int
    let caption: String
    let tint: UIColor

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(followers.formatted())
                .font(.system(size: 46, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(uiColor: tint))
                .contentTransition(.numericText(value: Double(followers)))
                .animation(.spring(response: 0.6, dampingFraction: 0.8), value: followers)
            Text("位粉丝")
                .font(.system(size: 26, weight: .semibold))
            if !caption.isEmpty {
                Text("·")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(caption)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .glassBackgroundEffect(in: Capsule())
    }
}
