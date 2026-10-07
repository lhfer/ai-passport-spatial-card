import Foundation
import RealityKit
import UIKit

/// Owns the RealityKit entity tree for the hologram and applies app state (pose, presence, style) to it.
///
/// Tree (meters):
///
///     root (world)
///     ├─ surface                     ← ON THE DESK under the card (world pose from CardTracker.surfaceY)
///     │  ├─ haloDisc                 ← low-saturation background glow, breathing (0.30 m)
///     │  ├─ event ripples            ← single-shot rings spawned by the choreography
///     │  └─ coinGroup                ← world coins on the outer arc (+ exit chip)
///     ├─ hintHolder                  ← floating status label (BillboardComponent)
///     └─ anchorRoot                  ← follows the ImageAnchor pose (or the preview pose); spatial audio source
///        ├─ devicePlaceholder        ← dark slab standing in for the device (preview mode only)
///        ├─ overlay                  ← RegistrationOverlay: paper / lit / holo quads, scan line, socket glow
///        ├─ acquire                  ← one-shot "seen" glint at first detection: flash + ring on the image
///        ├─ particleEntity           ← steady-state particles + event bursts
///        └─ hologram                 ← BloomComponent(hierarchical)
///           ├─ shaft                 ← projector rig from the image up to the card
///           ├─ notes.group           ← the ten note cards + the two world cards (the gallery / the deck)
///           ├─ handPivot             ← the hinge on the device's TOP edge (V3-2a H2), base orientation
///           │  └─ hingeGroup         ← the hinge ARM: origin on the hinge, rotation = the hinge angle (B0b)
///           │     └─ cardGroup       ← …mounted at (0, cardHalfHeight, 0) while the passport is in a hand
///           └─ cardGroup             ← frosted slab + rim + landing glow + SwiftUI card (on the desk)
///              ├─ cardFaceGroup      ← V3-3 C2: the card's FRONT, cross-faded as one by the back-face flip
///              │  ├─ card.attachment        z +2 mm  (plate, glass, all type)
///              │  ├─ card.attachment.tags   z +6 mm  (the capsule row)
///              │  └─ card.attachment.avatar z +10 mm (the hero image)
///              └─ card.back          ← V3-3 C3: the QR code, behind the slab, facing the card's −Z
///
/// Presence (plan §8 C2) drives everything through `apply(presence:transition:)`: the cinematic reveal plays
/// once per session, later appearances are a short `reentry`, picking the device up shrinks the card into a
/// `carry` that rides along, putting it down `settle`s it, losing the image only `freeze`s the pose (with a
/// searching shimmer) until a `thaw` glides it to where the card is seen again, and only an explicit
/// dismiss / replay / teardown `hide`s.
@MainActor
final class HologramController {
    static let cardAttachmentID = CardLayers.baseAttachmentID
    /// **V3-3 C2 / plan §4 E14b**: the two sheets that float off the card's face. Same view, same `mode`,
    /// different `layer` — see `CardLayers`, which owns the ids and the depths for both sides.
    static let cardAvatarAttachmentID = CardLayers.avatarAttachmentID
    static let cardTagsAttachmentID = CardLayers.tagsAttachmentID
    /// **V3-3 C3 / plan §4 E14c**: the card's back — a QR of the profile link, behind the slab.
    static let cardBackAttachmentID = CardLayers.backAttachmentID
    static let hintAttachmentID = "hint"
    /// Name of the tappable card so the RealityView gesture can recognise it.
    static let panelEntityName = "hologram.panel"

    let root = Entity()

    /// The screen frame **S**: origin at the centre of the LCD's lit area on the device's top face, +Y its normal,
    /// +Z towards the bottom edge (the reader). Follows the tracked pose.
    let anchorRoot = Entity()
    /// **v4 B1 §1.** The case frame **C** — the case's top-face centre, same axes — hung off S at
    /// `V4.ScreenOffset.caseCenter` (1.64 mm right and 11.52 mm towards the reader on the real AI Passport). Every
    /// effect that follows the *shell* lives here: the recognition wireframe, the key glints and the edge wave, the
    /// hinge's contact light, the sleeping dust, the device ring; and the H0 audit measures in it.
    let caseRoot = Entity()
    /// Where C's origin is in S (metres). Zero is v3's single frame.
    private(set) var caseCenter: SIMD3<Float> = .zero
    /// **v4 B1**: A4's hero card + A2's recognition, mounted inside v3's card frame (`HologramController+V4`). Nil with
    /// `--v3-card` (and until `installV4` has run): every v3 path is then exactly v3.
    var v4: V4CardIntegration?
    /// The v4 path was asked for at init (the card's geometry below is sized for the hero card from the start).
    let isV4Card: Bool
    /// The name card's size in the card frame: the hero card's 0.20 × 0.28 m in v4, v3's 0.27 m square otherwise.
    let cardSize: SIMD2<Float>
    /// **v4 B1 §2**: the recognition's first beat (`.burst`) — the real LCD is asked for its `glow`. Set by `ImmersiveView`.
    var onRecognitionBurst: (() -> Void)?
    /// **v4 B1 follow-up**: the desk is busy though no presence event says so (the hand-over hold) — the world engine's
    /// idle prebuild (a 200 ms main-actor stall) must not land in it. Set by `ImmersiveView`.
    var onDeskBusy: (() -> Void)?
    /// **v4 B4 §1.** What the recognition's place is decided from, at `acquiring`: the device's raw tilt, the desk gate's
    /// answer, and the tracker's latest **raw** pose of the device (`apply(pose:)` runs after the transition, so
    /// `anchorRoot` may not be on the device yet at a first detection — and the accepted pose is still snapped flat by the
    /// desk gate's prior then). Set by `ImmersiveView`.
    var recognitionStateProvider: (() -> (tilt: Float?, deskGateOnDesk: Bool, device: simd_float4x4?))?
    /// **v4 B4 §1.** The place decided at `absent → acquiring` (before the desk lights), for the recognition that starts in
    /// the same transition — decided once, consumed by `startV4Recognition`.
    var pendingRecognitionDecision: V4.RecognitionPlan.Decision?
    /// `--recognition-place` (smokes only): the place every recognition takes off on, whatever the tilt says.
    var recognitionPlaceOverride: V4.RecognitionPlace?
    /// **v4 B4 §1.** The hand's reveal holds the hinge at the angle the outline was drawn at (frozen at take-off) until the
    /// card has dissolved in and the outline is gone; then the facing tick takes over from that same angle.
    var handRevealHingeFrozen = false
    /// **v4 B4 §1.** The next deck rise waits at least this long (the hand's reveal: the deck comes out of a card that is
    /// there). Consumed by `morphGalleryToDeck`.
    var nextDeckRiseDelay: Float?
    let surface = Entity()
    private let hintHolder = Entity()
    let hologram = Entity()
    private let shaft = Entity()
    let cardGroup = Entity()
    /// **The hinge** (V3-2a H2). A frame on the device's top edge, turned so +X runs across the device,
    /// +Y up the card and +Z out of the screen: the card and the whole hand deck live in it while the
    /// passport is in the wearer's hand, so a flick of the wrist moves all eight of them together.
    let handPivot = Entity()
    /// **The hinge arm** (V3-2b B0b; V3-2a2 S0b before it). A frame whose origin *is* the hinge and whose
    /// rotation is the hinge angle — and the card hangs off it at (0, `hingeCardPosition.y`, 0). That is what
    /// makes the cover a real hinge: it pivots about its own **bottom edge**, which therefore never leaves the
    /// device's top edge, however far it opens toward the wearer.
    ///
    /// (V3-2a2 wrote the angle onto `cardGroup` itself, whose position stayed at (0, halfHeight, 0) — a
    /// rotation about the card's *centre*, which swung its bottom edge ≈ 41 mm off the hinge at the ±35°
    /// clamp. The deck's frame then had to reproduce that same motion, `position = c − R·c`, to stay glued to
    /// the card. With the arm, both are the one frame: the deck's slots are struck in it and the card is
    /// mounted in it, so they open together by construction.)
    ///
    /// The deck's holders are **not** parented to it — they stay in the fan's own group and their targets are
    /// converted out of this frame (`HologramController+Deck`), which is `HandDeckLayout`'s space: origin at
    /// the card's bottom edge, +Y up the card, +Z out of its face.
    let hingeGroup = Entity()
    /// **V3-3 C2.** The card's face, as three sheets at three depths (`HologramCardLayer`). They hang off one
    /// group so the back-face flip has a single opacity to cross-fade and so every write the choreography
    /// already makes to `cardAttachmentHolder` keeps its old meaning.
    let cardFaceGroup = Entity()
    private let cardAttachmentHolder = Entity()
    private let cardTagsHolder = Entity()
    private let cardAvatarHolder = Entity()
    /// **V3-3 C3.** The other side of the plate: turned to face the card's −Z, and cross-faded against
    /// `cardFaceGroup` when the passport is turned right over.
    let cardBackHolder = Entity()
    let particleEntity = Entity()
    private let acquire = Entity()
    /// One-shot spark emitter at the avatar (celebration).
    let avatarSparks = Entity()

    let fx = FXTextures.shared
    let audio = FXAudio.shared
    private let sortGroup = ModelSortGroup(depthPass: nil)

    // Registration layer + pixel cloud (per theme screen)
    var overlay: RegistrationOverlay
    let pixels: PixelCloud
    private(set) var theme: PassportManifest.Theme
    /// Which reveal to play (`AppModel.revealOverride`, else ink).
    var revealKind: RevealKind = .inkExtraction
    /// `--overlay-lit off`: skip the paper / lit backlight layers (LCD ghosting check), reveal starts at the holo stage.
    var litLayers: Bool {
        get { overlay.litLayers }
        set { overlay.litLayers = newValue }
    }

    // Surface
    private let haloDisc: ModelEntity
    /// World coins (glass buttons) on the outer desk arc (and the 退出 / 笔记 chips at its two ends).
    let coinGroup = Entity()
    private var coinHolders: [Entity] = []
    private var coinBasePositions: [SIMD3<Float>] = []
    /// Name + subtitle capsules floating 6 cm above the coins (one shown at a time, the highlighted one).
    private var coinLabelHolders: [Entity] = []
    private(set) var highlightedCoin: Int?
    /// A world's colour blended over the look's rim tint: 0.35 while its coin is highlighted (preview),
    /// 1 while it is active — and after it, until the next highlight / entry (the device keeps its screen).
    private var worldTint: UIColor?
    private var worldTintStrength: Float = 1
    /// Holder for the dev P0 probe orb (`--p0`); the three style orbs that used to live here are gone.
    private let orbGroup = Entity()
    // Card
    /// The frosted slab: a 12 mm plate of milky glass, 6 mm larger than the SwiftUI card on every side so its
    /// edge stays visible head-on (a billboarded card hides its own thickness).
    let slab: ModelEntity
    /// Bright inner edge running around the slab's front face — and the one surface a world's colour reaches.
    let rim: ModelEntity
    /// Soft pool of light inside the slab's lower edge: the glass blurs it into "the beam enters the plate here".
    /// A seated reader never sees the slab's underside, so the light has to bleed up through the face.
    /// (Internal: the note preview dims its `PulseComponent` base while a card is being read.)
    let landing: ModelEntity
    let tapTarget: ModelEntity
    let idleScan: ModelEntity
    // Projector (rays + base) between the image and the card
    let projector: ProjectorRig
    /// Portal shaft under the image: the ink / pixels rise out of it (round 4, item 3).
    let well: LightWell
    /// **V3-2a2 S1 / plan §4 E1**: the recognition wireframe on the real shell's own edges.
    let boxScan: BoxScanRig
    /// **V3-4 §1.** The 24-segment ring the button wave runs round the device's outline.
    private let buttonWave: ButtonWaveRig
    private let devicePlaceholder: ModelEntity
    // Acquire cue
    private let flash: ModelEntity
    private let acquireRing: ModelEntity

    /// The ten recent-note cards and the preview panel (工作包 D, `HologramController+Notes.swift`).
    let notes = NoteFanRig()
    /// **v4 B2 §3.3** — the pick-up fold (`HologramController+PickupFold.swift`): its gold point and its state. **v4 B3**:
    /// the same point is the collapsed card's (`HologramController+Collapse.swift`), beside the case's top edge in C.
    let pickup = PickupFoldRig()
    /// **v4 B3 §2** — the collapse into the gold point, and the two hints (`HologramController+Collapse.swift`).
    let collapse = CollapseRig()
    /// **v4 B4 §3.5** — `cmd perf`'s switches (`HologramController+Perf.swift`).
    let perf = PerfSwitchRig()
    /// `--pickup-fold on|off` (default on).
    var pickupFoldEnabled = true
    /// What the fold's grab rule reads from the tracker at 10 Hz: the nearest tracked wrist to where the passport was last
    /// seen (`CardTracker.nearestHandDistance`, nil = no hand data), the attach radius `LossClock` classifies with
    /// (`bridgeAttachRadius`), and the tracker's clock. Set by `ImmersiveView`.
    /// **v4 B4 §2**: and the hand's height above the passport's last position, for the pick-up watch's evidence.
    var lossStateProvider: (() -> (handDistance: Float?, handHeight: Float?, radius: Float, now: TimeInterval))?
    /// The app's half of a fold (`true`) and of its end (`false`): the gallery, the desk ring, the strip.
    var onPickupFold: ((Bool) -> Void)?
    /// The one look (v2 工作包 B): a frosted slab. `applyLook()` paints it once.
    let look = HologramLook.desk
    private var lookApplied = false
    private(set) var currentPresence: PresenceGate.Presence = .absent
    private var faceUser = false
    private var billboardSuspended = false
    private(set) var hasPose = false
    private var lastAppliedPose: simd_float4x4?
    private var hasSurfacePose = false
    private var previewActive = false
    /// The **screen's** footprint (36.7 × 49 mm): what the registration overlay, the pixel cloud and the light
    /// well's portal are built on. Not the device's — see `deviceFootprint`.
    let footprint: SIMD2<Float>
    /// The **device's** footprint in the screen frame S (60 × 95 mm on the AI Passport), read from the object
    /// anchor's box at runtime. V3-2a H0: nothing persistent may live in the prism over this rectangle.
    private(set) var deviceFootprint = DeviceFootprint.aiPassport
    /// `--footprint-check`: walk the tree once a second and report anything that stays on the hardware.
    var footprintCheck = false {
        didSet {
            guard footprintCheck != oldValue else { return }
            auditDriver.isEnabled = footprintCheck
            guard footprintCheck else { return }
            print(String(format: "[footprint] check on (device %.1f × %.1f mm + %.0f mm, y %.0f…+%.0f mm)",
                         deviceFootprint.size.x * 1000, deviceFootprint.size.y * 1000,
                         deviceFootprint.margin * 1000, deviceFootprint.yMin * 1000, deviceFootprint.yMax * 1000))
            // V3-2a2 S0a: the prism has two zones now, and the hard one is the screen itself — at its offset on
            // the case since v4 B1.
            print(String(format: "[footprint] lcd %.1f × %.1f mm hard zone at (%+.1f, %+.1f) mm on the case (bezel soft zone takes the hinged card's %.0f mm overhang)",
                         deviceFootprint.lcd.x * 1000, deviceFootprint.lcd.y * 1000,
                         deviceFootprint.lcdCenter.x * 1000, deviceFootprint.lcdCenter.y * 1000,
                         HologramController.hingeOverhangDepth * 1000))
        }
    }
    private let auditor = FootprintAuditor()
    private let auditDriver = Entity()
    var choreography: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var bloomTask: Task<Void, Never>?
    /// The pick-up morph's own staged beats (V3-2a H4) — a separate slot from `choreography`, which the
    /// reveal owns and `cancelChoreography()` clears on every transition.
    private var handMorphTask: Task<Void, Never>?
    /// The socket ring's summon flare (H0), so a second summon does not leave a stale settle in flight.
    private var socketFlare: Task<Void, Never>?
    /// **V3-2a2 S4**: the 0.2 s the deck takes to tuck into the card before the fold itself starts.
    private var foldTask: Task<Void, Never>?
    /// **V3-2a H5**: told 0.35 s into the settle, while the card is still springing back, so the deck's five
    /// cards fly to the gallery under it rather than after it.
    var onSettleBloom: (() -> Void)?
    /// How the next `apply(pose:)` should reach the thawed pose.
    private enum GlideKind {
        /// Ordinary thaw: the presence time constant, no landing cue.
        case presence
        /// The card came back somewhere else: the relocation τ + speed limit, and (unless the return-from-world
        /// light already played one) a landing ripple + chord when the follower actually arrives.
        /// `worldLight` = this thaw also owes the desk its return-from-world light, and the glide is long enough
        /// that playing it now would light up the spot the card is *leaving*: it waits for the arrival instead.
        /// `hand` = the device is in the wearer's hand, so this is not a desk glide (see `beginRelocation`).
        case relocate(distance: Float, cue: Bool, worldLight: Bool, hand: Bool)
    }
    /// Which tracker produced the last pose (`apply(pose:source:)`): the in-hand relocation rule asks, because a
    /// `carrying` presence driven by the *image* source is the v2 desk case and keeps the desk glide.
    private var lastPoseSource: TrackingFusion.Source = .image
    /// Where the card is being drawn right now, for `CardTracker`'s `Σ lag=` (nil before the first pose).
    var renderedPosition: SIMD3<Float>? { hasPose ? anchorRoot.position : nil }
    /// Set by a thaw, consumed by the next `apply(pose:)` — a thaw whose correction lands inside the dead zone
    /// drops it instead, so the arrival hook can never fire on some unrelated pose later on.
    private var pendingGlide: GlideKind?
    /// One continuous follower for `anchorRoot`: the pose stream only ever *retargets* it (see `PoseFollower`).
    private var follower = PoseFollower(tau: HologramController.followTauExpanded)
    /// Driver for the follower, permanently enabled (`hologram` is not: RealityKit does not tick components of
    /// disabled entities, and `hologram.isEnabled = false` is how the hide paths work).
    private let followerDriver = Entity()
    /// Second always-enabled driver, for the in-world mini card's lazy head follow (工作包 C). Separate from
    /// `followerDriver` so the desk's pose follower keeps exactly the behaviour M1b shipped.
    private let miniDriver = Entity()
    /// v3 OPTIONAL D: root-space holder for a note preview opened from the **hand** card. The fan's own
    /// group hangs off `hologram`, i.e. off the device — a 35 cm preview panel parented there rides every
    /// tremor of the wearer's hand 1:1, which is unreadable. A preview is a thing you stop and read, so it is
    /// world-locked at the pose it opens at, exactly like the in-world mini card's holder.
    private let notePreviewRoot = Entity()
    /// Root-space holder the card hangs from while it is a mini card inside a world. It exists so the card can
    /// leave `hologram` **without** anything touching `anchorRoot` / the pose follower, and still keep the
    /// hierarchical bloom and the spatial audio source that make the slab read as glass in a dark world.
    private let miniHolder = Entity()
    /// The card is (or is becoming) the small in-world card.
    private(set) var isMiniCard = false
    /// Lazy head follow, live only once the shrink tween has landed.
    private var miniFollow = MiniCardFollow()
    private var miniFollowActive = false
    private var miniTask: Task<Void, Never>?
    /// The wearer's head, live (`CardTracker.latestDevicePose`, or preview mode's synthetic reader). Set by
    /// `ImmersiveView`; the mini card is the only thing that reads it every frame.
    var headPoseProvider: (() -> simd_float4x4?)?
    /// V3-2a H3: which world card is raised over the name card, so `AppModel` can rebuild its attachment
    /// with the 「按 OK 进入」 capsule and tint the rim.
    var onWorldCardRaised: ((String?) -> Void)?
    /// A relocation glide has landed (工作包 A 设备联动: the device's confirmation `tick` belongs here, not to the
    /// thaw that started the glide). Set by `ImmersiveView`.
    var onRelocationLanded: (() -> Void)?
    /// A relocation glide is in flight: τ / maxSpeed stay at the relocation values until the follower arrives.
    private var relocating = false
    private var relocateElapsed: Float = 0
    /// The relocation in flight, kept so V3-2a H1 can retune it when the device changes hands mid-glide
    /// (the arrival closure reads these rather than capturing them, so a retune is actually seen).
    private var relocationHand = false
    private var relocationCue = false
    private var relocationWorldLight = false
    private var onFollowerArrival: (() -> Void)?
    private var followerWasArrived = true
    /// The desk still owes the card its return-from-world light: the thaw that should have played it handed the
    /// card a long relocation glide instead, and a light played then would flash on the spot the card is leaving.
    /// It survives a freeze in mid-glide (the card simply has not landed yet — the next thaw pays it) and is
    /// dropped by a hide, because a reentry or a replay relights everything anyway.
    private var owesReturnFromWorldLight = false
    /// The card is in its shrunken "carried" form (carry played, settle not yet). Read by the note fan: it
    /// may only be thrown at a card that is standing on the desk, and `presence == .expanded` is the wrong
    /// test (a long OK arrives as a button press, which the gate answers with `held(.button)` first).
    var carriedVisual = false
    /// v3 H2: the card is (or is becoming) the **hand form** — a half-size pane lying 35 mm above the device's
    /// screen, facing wherever `handFacing` says. Set by `runCarry` / `unfoldFromDevice`, cleared by the
    /// settle, the reentry, a reveal and every hide.
    private(set) var isHandForm = false {
        // V3-4 §7: the hinge's contact light only exists while the card is *on* the hinge.
        didSet {
            hingeGlowStrip.isEnabled = hingeGlowEnabled && isHandForm && handForm == .hinge
            // v4 B2: the desk's resident motes stand down in the hand (and come back with the desk).
            if isHandForm != oldValue { updateParticleRate() }
            // v4 B4 §1: whatever takes the card out of the hand ends the hand reveal's frozen hinge with it.
            if !isHandForm { handRevealHingeFrozen = false }
        }
    }
    /// **V3-4 §7** `--hinge-glow on|off`: a 3 mm soft line of light along the device's **outside** top edge,
    /// where the hinged card meets the hardware. The object anchor is good to a few millimetres and the
    /// wearer reads the gap between the card's bottom edge and the real shell as "the fit is not precise";
    /// a soft light in that seam turns a hard 2 mm gap into a glow. It is outside the footprint prism
    /// entirely (2 mm past its own margin), so H0 is untouched.
    var hingeGlowEnabled = true {
        didSet { hingeGlowStrip.isEnabled = hingeGlowEnabled && isHandForm }
    }
    private let hingeGlowStrip: ModelEntity
    /// **V3-4 §8** `--sleep-fx on|off`: the folded card's "sleeping magic" — the outline breathing, star dust
    /// circling the shell, a slow light patrolling the ring every six seconds, and the whole cloud rushing
    /// into the LCD when the wearer summons the card back.
    var sleepFXEnabled = true
    /// **V3-4 §9** `--raise-flourish on|off`: the raised deck card's arrival gets a bloom and the hinge's
    /// light doubles for 0.4 s, so UP / DOWN land with some weight rather than a card simply appearing.
    var raiseFlourish = true
    /// The star-dust cloud. A plain `Entity` with nothing but a `ParticleEmitterComponent`: the footprint
    /// auditor judges `ModelEntity`s with meshes, so a particle system is outside its remit by construction —
    /// and the torus it emits from is outside the prism by geometry as well.
    private let sleepDust = Entity()
    private var sleepAwake = false
    /// The wearer's hand came inside `sleepNoticeRadius`: the ring brightens and the dust doubles its speed.
    private var sleepNoticed = false
    /// **V3-6 §1.** How long the object has to be gone before the card admits it, and how far down it goes.
    ///
    /// The product decision behind this is that the card follows the **device**, full stop: `--bridge off` is
    /// the default from this round, so a loss is no longer something the hand can hide. What is left is to
    /// make the loss look deliberate — the card holds its place, dims to 0.6 and breathes on the rim at the
    /// searching rate — instead of looking like a dropped frame. 0.3 s, not the gate's 3 s `.search`: three
    /// seconds of a card sitting there at full brightness *not* following the passport is the tell.
    static let holdingCueAfter: Double = 0.3
    static let holdingOpacity: Float = 0.6
    /// How far a wrist has to come before the device notices it.
    static let sleepNoticeRadius: Float = 0.12
    /// How many motes circle the shell, and how often the slow light goes round.
    static let sleepDustCount: Float = 24
    static let sleepPatrolPeriod: Double = 6
    /// Polls the nearest wrist while the card is folded. 4 Hz is plenty for "it noticed you".
    private var sleepPollAt: Float = 0
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    /// Asked for the distance from the device to the nearer wrist, or nil when no hand is tracked.
    var nearestHandDistance: (() -> Float?)?
    /// Whether a carry should become the hand form at all: v3's `--tracker object` (and `both` once the object
    /// source has the card) puts the card *on the device*; `--tracker image` keeps v2's shrink-and-ride, which
    /// is what the image tracker's accuracy in the hand can actually support. Written by `ImmersiveView`.
    var usesHandForm = false
    /// `--hand-facing device|hybrid|billboard`.
    var handFacing: HandFacing = .hinged
    /// `--hand-form` (V3-2a H2): the hinged card on the device's top edge, or V3-1's 35 mm hover.
    var handForm: HandForm = .hinge
    /// `--hand-scale` (V3-2a H2): 0.42…0.55.
    var handScale: Float = HologramController.handScale
    /// `--well-level-hand` (E15): the edge glow's level while the passport is in the hand.
    var wellLevelHand: Float = 0.5
    /// **V3-2a2 S0b**: the hinge angle the *deck* is hung from — the card's own, once it has stopped being
    /// tweened into place. See `syncHingeGroup`.
    private(set) var hingeRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

    // MARK: - The recognition scan (V3-2a2 S1)

    /// `--box-scan on|off`.
    var boxScanEnabled = true
    /// The device's thickness, i.e. how deep the wireframe's vertical rods are (v4: 8 mm by ruler; an object
    /// anchor's own box still overrides it, see `setDeviceFootprint`).
    private(set) var deviceThickness: Float = V4.ScreenOffset.caseThickness
    /// The scan is holding the card's entrance back until its convergence beat.
    var scanPending = BoxScanTimeline.Pending()
    private var scanTimeline = BoxScanTimeline.fullVersion
    /// The transition the scan is holding, with everything `apply(presence:…)` needs to replay it.
    struct HeldIntro {
        var transition: PresenceGate.Transition
        var label: BoxScanTimeline.Intro
        var previous: PresenceGate.Presence
        var firstAcquire: Bool
        var resumeFromWorld: Bool
        var animated: Bool
    }
    var heldIntro: HeldIntro?
    /// The scan is holding an entrance back. Read by `AppModel`, whose half of that same event is stashed
    /// alongside: a transition the scan *passes* (a `.freeze` — the scan finishes on the frozen pose) must
    /// not look like "nothing is pending" and throw the stash away.
    var isHoldingEntrance: Bool { heldIntro != nil }
    /// The next `absent → acquiring` is a **summon** (OK, or a tap on the socket light), so the scan is the
    /// short one and it is the button's own feedback. Consumed by the scan that it starts.
    private var summonPending = false
    /// 0.35 s into the full scan / 0.15 s into the summon: the moment the real LCD is told to sweep a bar of
    /// its own, so the two run together on camera (`DeviceCoordinator.sendGlow`). Set by `ImmersiveView`.
    var onScanGlow: (() -> Void)?
    /// The convergence beat: the device's `connect` (first scan of the session) or `tick` (a summon).
    var onScanConverged: (() -> Void)?
    /// …and, right after the held entrance has started, the app's own half of that same presence event
    /// (`AppModel.noteCard`: the card mode, the fan, the deck's rise).
    var onScanEntranceStarted: (() -> Void)?

    // MARK: - Button glints (V3-2a2 S3)

    /// `--button-glint on|off`.
    var buttonGlintEnabled = true
    /// **V3-4 §1** `--button-fx wave|dot|off`: `wave` (the default) is the edge wave + spark cone + the
    /// card's own answer, `dot` is V3-2a2's glint alone, `off` is nothing. The first headset round pressed
    /// keys 37 times and the wearer saw the dot none of those times, so the default had to change.
    var buttonFX: ButtonGlintLayout.FX = .wave
    /// `--button-edge +x|-x` — which long side the three keys are on (persisted; calibrated on the headset).
    var buttonEdge: ButtonGlintLayout.Edge = .plusX {
        didSet {
            layoutButtonGlints()
            // v4 B3: 「OK · 唤醒」 stands on the keys' side.
            layoutGoldPoint()
        }
    }
    /// The three 6 mm dots at the physical keys, permanently mounted and invisible at rest.
    private var buttonGlints: [ButtonGlintLayout.Key: ModelEntity] = [:]
    private let buttonGlintGroup = Entity()
    /// A long press's hold, cancelled by the next press on the same key.
    private var buttonGlintTasks: [ButtonGlintLayout.Key: Task<Void, Never>] = [:]
    /// The desk furniture is faded out because the card is in a hand: `igniteSurface` must not light it back up
    /// behind the wearer's back (the `absent → acquiring` step on the way to an unfold runs it).
    // MARK: - Angle visuals (V3-3 / plan §4 E14)

    /// **C1** `--fresnel on|off` (default on): the rim's brightness follows the angle the card is seen at
    /// (`RimFresnel`). `off` leaves `rim`'s `PulseComponent` at the 0.6 base it has carried since v1.
    var fresnelEnabled = true
    /// **C2** `--parallax on|off` (default on): how far the two floating sheets stand off the plate. `off`
    /// puts all three at the single attachment's old z, which is V3-2b's card exactly.
    var parallaxEnabled = true {
        didSet { if parallaxEnabled != oldValue { layoutCardLayers() } }
    }
    /// **C3** `--back-face on|off` (default on): turning the passport right over shows the card's back —
    /// a QR code of the profile link — instead of a front the wearer cannot read.
    var backFaceEnabled = true
    /// `dot(card normal, direction to the eyes)`, recomputed once per rendered frame and shared by C1's rim
    /// and C3's flip so the two can never disagree about which way the card is pointing. Nil when there is
    /// no head pose yet (the first frames of a session, and `--preview` before its stand-in head is placed).
    private var cardFacingDot: Float?
    /// Which side of the card is up, with its hysteresis: the whole rule is `Model/CardLayers.swift`'s
    /// `BackFaceFlip`, so it is a value type the test target checks rather than three ifs in a tick.
    private var backFace = BackFaceFlip()
    var backFaceShown: Bool { backFace.showsBack }

    // MARK: - Deck dynamics (V3-2b B2 / plan §4 E5)

    /// `--deck-dynamics on|off` (default on): the hand of cards trails the name card by a few frames instead
    /// of being written to its slot every frame. `off` is V3-2a2 S0b's rigid attachment, unchanged.
    var deckDynamics = true
    /// The widest gap between a rendered deck card and its slot, this frame, in metres — `Σ deckLag=`. Nil
    /// whenever the deck is not being followed (outside the hand, or `--deck-dynamics off`).
    var deckLagNow: Float?
    /// **V3-2b B4 / plan §4 E12.** The card is gathered up because the wearer has started turning the
    /// passport over. A prediction, not a state: it is undone by `setFoldAnticipation(false)`.
    var foldAnticipating = false
    /// How far the card dims while it waits to see whether the flip becomes a fold, and over how long.
    static let foldAnticipationOpacity: Float = 0.55
    static let foldAnticipationDuration: Float = 0.25
    /// `[perf] hand form 5 s`, once per hand session (armed 1 s after the card reaches the hinge).
    private var handPerfTask: Task<Void, Never>?
    private var handPerfArmed = false

    private var deskFaded = false
    /// The desk is faded out (the hand, a world, a collapse): read by `cmd perf`'s restore.
    var deskIsFaded: Bool { deskFaded }
    /// The pixie-dust emitter that trails the hand card, and its on/off hysteresis.
    private let handTrail = Entity()
    private var handTrailOn = false
    /// v4 B2: read by the deck's idle-trail park (`HologramController+Deck`).
    var handTrailIsOn: Bool { handTrailOn }
    /// Socket-only state after a dismiss with nothing on screen (`--auto-show never`, `cmd hide` before the
    /// reveal): armed once, cleared by anything that brings the card back.
    private var socketArmed = false
    /// v4 B3: the card was already the pick-up fold's gold point when this hide arrived (`runHide` collapses without an arc).
    private var pickupWasPointAtHide = false
    /// v3 FIX B: the card was the **hand form** when a world took it. The gate is still `held(.world)` while
    /// the exit runs, so its presence cannot answer "where does the card go home to" — this can.
    private(set) var returnsToHand = false
    /// The card has been put on screen at least once this session (a reveal, a reentry or an unfold). Read by
    /// the settle's fallback — see `runSettle`.
    var hasShownCard = false
    private(set) var isSearching = false
    /// **V3-6 §1.** The card is *waiting* for the passport rather than following it: the object has been lost
    /// for `holdingCueAfter` and the bridge is not allowed to paper over it any more.
    private(set) var isHolding = false
    /// The presence says the object is gone (before the 0.3 s has elapsed).
    private var holdingArmed = false
    /// When the current loss began, for `[reveal] following again (N.N s)`.
    private var holdingSince: TimeInterval?
    private var holdingTask: Task<Void, Never>?
    /// A reveal / collapse is driving the pixel cloud and the registration textures: theme swaps wait.
    private var pixelsInFlight = false
    private var pendingTheme: PassportManifest.Theme?
    /// Instances created in this process (device logs prove the init runs once per space open).
    private(set) static var instanceCount = 0

    // Layout constants for the effects (meters)
    private static let haloDiameter: Float = 0.30
    /// Inner edge of the desk annulus, as a fraction of the plane's half size: 0.5 × 0.15 m = 7.5 cm.
    static let haloInner: Float = 0.5
    private static let orbRadius: Float = 0.014
    static let orbArcRadius: Float = 0.17
    private static let cardRestY: Float = 0.03
    /// Height of the shrunken card while the device is carried (v2's carry; the hand form uses `handY`).
    private static let carryY: Float = 0.16
    /// v3 H2 §1 — the hand form. Half size (13.5 cm of card), 35 mm above the screen, lying parallel to it.
    /// 35 mm is the smallest gap that still reads as "floating above" rather than "printed on" at arm's length
    /// and keeps the 12 mm slab clear of the wearer's thumb on the device's edge.
    static let handScale: Float = 0.5
    /// How far **outside** the device's top edge the hinge sits.
    ///
    /// **V3-2a2 S0: 0.** The card's bottom edge sits on the real top edge (z = −length/2), which is what the
    /// plan asks for and what makes the card read as growing out of the seam rather than floating 8 mm off
    /// it. The 12 mm slab then overhangs the hinge by ~3 mm — over the device's top *bezel*, 23 mm of dark
    /// plastic above the 36.7 × 49 mm LCD — and the audit is told about it rather than talked out of it:
    /// `DeviceFootprint` now has an LCD **hard** zone (nothing, ever) and a bezel **soft** zone that takes
    /// the hinged card's overhang and nothing else (`FootprintProbeComponent.hingeOverhang`).
    static let hingeClearance: Float = 0
    /// How far the hinged card's slab may hang back over the bezel before the audit calls it a state rather
    /// than an overhang.
    ///
    /// **V3-3 C3 corrects this number, and it is the one H0 constant this round moves.** V3-2a2 set it to
    /// 6 mm reasoning that "the slab reaches 3 mm at the open angle and *less* at every other hinge angle".
    /// That is true of the **opening** direction only. The clamp is ±35°, and its negative half — the cover
    /// hyperextending past flat, which `HandFacing.hingeAngle` asks for the moment the wearer's eyes end up
    /// *behind* the card's face, i.e. every time the passport is turned over, which is exactly what C3 is
    /// for — rotates the plate's own 6.5 mm of depth (the 12 mm slab's far face, at the 0.5 hand scale)
    /// into z as well:
    ///
    ///     3 mm · cos 35° + 6.5 mm · sin 35° = 2.46 + 3.73 = 6.19 mm
    ///
    /// So 6 mm was 0.2 mm short of the geometry it was meant to describe, and the first script that turns
    /// the passport over reports `card.slab inside` for as long as it is held there (measured: 4 findings on
    /// `fake-track-v33-backface.json`, and zero with `--hand-facing device`, which pins the hinge at 0).
    /// 7 mm is the same rule stated for the whole clamp, with 0.8 mm to spare.
    ///
    /// It loosens nothing that matters: the **LCD hard zone** is not governed by this number at all (the
    /// slab's z reach is −41 mm, 14 mm clear of the hard zone's −27.5 mm edge), and the oracle it has to keep
    /// catching — V3-1's hover form lying over the screen — reaches z ≈ +67 mm.
    static let hingeOverhangDepth: Float = 0.007
    /// The hinge's height above the top face: the 12 mm plate's back lines up with the device's own.
    static let hingeLift: Float = 0.006
    static let handY: Float = 0.035
    /// The card's orientation on the device: `HandFacing.base`, which is also `foldIntoDevice`'s end state.
    private static var handBaseOrientation: simd_quatf { HandFacing.base }
    /// How quickly the card turns toward the reader (τ, s): slow enough that head motion never jitters it.
    private static let handFacingTau: Float = 0.12
    /// The motion trail comes on above this speed and goes off below the second one (hysteresis, so a card
    /// hovering at the threshold does not stutter).
    /// **V3-4 §9** `--trail-rate`: 0.15 / 0.10 m/s sat exactly on the natural speed of a hand holding
    /// something still — the first headset round switched the trail on and off **61 times in eight minutes**.
    /// 0.25 / 0.15 leaves the dust off while the wearer is simply holding the passport and on while they are
    /// actually moving it, which is the distinction the effect is for.
    static var handTrailOnSpeed: Float = 0.25
    static var handTrailOffSpeed: Float = 0.15
    /// **V3-2b B2**: 60 → 40/s. The card is no longer the only thing trailing — the deck's seven add
    /// `deckTrailBirthRate` each on the same hysteresis, and the plan's budget for the whole hand is 260
    /// particles alive (7 × 25 × 0.8 s + 40 × 0.8 s ≈ 172).
    /// **V3-4 §9.** 40 → 120 a second. On the headset the card's dust was, in the wearer's words, "not that
    /// amazing"; three times the motes at twice the size is the cheapest thing that changes that. Scaled by
    /// `--trail-rate <f>` for the A/B.
    static var handTrailBirthRate: Float = 120
    /// **V3-5 §7a.** Sprite size for the **continuous** dust (the card's and the deck's trails): 5 mm → 3 mm,
    /// with the round mote instead of the star. The end-of-life multiplier is V3-4's 0.25, unchanged.
    static let trailDustSize: Float = 0.0030
    /// …and the one-shot bursts keep V3-4's 5 mm star.
    static let burstDustSize: Float = 0.0050
    private static let cardTilt: Float = HologramLayout.cardTiltDegrees * .pi / 180
    private static var shaftHeight: Float { HologramLayout.cardCenterHeight - HologramLayout.cardHeight / 2 + 0.02 }
    /// Thickness of the rim band (the visible hairline, not the slab).
    private static let rimThickness: Float = 0.0022
    /// Size of the landing pool at the slab's lower edge. Deliberately wide and **short**: the beam lights the
    /// bottom *edge* of the plate, and a 7 cm tall pool put its brightest part straight behind the tag capsules,
    /// which washed the middle one out.
    private static let landingSize: SIMD2<Float> = [0.22, 0.022]
    /// Centre of the pool. Low enough that its top edge (−0.113) clears the tag capsules (whose baseline sits
    /// around −0.107 on the 0.27 m card) by ≥ 6 mm, and high enough that its bottom edge (−0.135) stays inside
    /// the slab, which reaches −0.141.
    private static let landingCenterY: Float = -0.124
    /// Steady-state brightness of the pool (the `PulseComponent` base, `resetCardLayers` and every tween's
    /// resting value all use it — they have to agree or the pulse and the tweens fight).
    private static let landingLevel: Float = 0.45

    /// `v4Card` (v4 B1): size the card's own furniture — the beam's aim, the landing pool, the tap target, the QR
    /// back — for A4's portrait hero card, which `installV4` mounts once it is built. False is v3, exactly.
    init(v4Card: Bool = false) {
        HologramController.instanceCount += 1
        print("[hologram] controller #\(HologramController.instanceCount) init\(v4Card ? " (v4 hero card)" : "")")
        let white = UIColor.white
        let manifest = PassportManifest.shared
        let hero: V4.HeroCardMount? = v4Card ? V4.HeroCardMount(layout: V4.HeroCardLayout(shape: .portrait)) : nil
        isV4Card = v4Card
        cardSize = hero?.size ?? [HologramLayout.cardWidth, HologramLayout.cardHeight]
        footprint = manifest.footprint
        theme = manifest.defaultTheme
        overlay = RegistrationOverlay(footprint: footprint, theme: theme)
        pixels = PixelCloud(footprint: footprint, theme: theme)
        // The beam aims at the slab, not at the SwiftUI card: its lower edge and its mid-plane (z −0.007). v4: the hero
        // card's slab (0.20 × 0.28 m, front face at z 0, so its mid-plane is at −6 mm).
        if let hero {
            projector = ProjectorRig(shaftHeight: hero.shaftHeight, cardWidth: hero.size.x,
                                     cardHeight: hero.size.y, targetZ: hero.rayTargetZ)
        } else {
            projector = ProjectorRig(shaftHeight: Self.shaftHeight, cardWidth: HologramLayout.slabWidth,
                                     cardHeight: HologramLayout.slabHeight, targetZ: -0.007)
        }
        well = LightWell(footprint: footprint)
        boxScan = BoxScanRig(box: [DeviceFootprint.aiPassport.size.x, V4.ScreenOffset.caseThickness,
                                   DeviceFootprint.aiPassport.size.y],
                             screen: footprint, tint: HologramLook.desk.highlight)
        buttonWave = ButtonWaveRig(footprint: DeviceFootprint.aiPassport, tint: HologramLook.desk.highlight)
        // V3-4 §7: the hinge's contact light — the device's own width, 3 mm along +Z, a soft disc gradient.
        hingeGlowStrip = ModelEntity(
            mesh: .generatePlane(width: DeviceFootprint.aiPassport.size.x * 0.9, depth: 0.003),
            materials: [FXMaterials.glow(FXTextures.shared.softDisc, tint: HologramLook.desk.highlight, opacity: 1)])
        // V3-2a H0: the desk halo was brightest exactly under the device. It is an annulus now, with a
        // 7.5 cm clear middle — well outside the 6.0 cm half-diagonal of the footprint prism.
        haloDisc = ModelEntity(mesh: .generatePlane(width: Self.haloDiameter, depth: Self.haloDiameter),
                               materials: [FXMaterials.glow(fx.softRing(inner: Self.haloInner, outer: 1), tint: white, opacity: 0.45)])
        let slabW = HologramLayout.slabWidth, slabH = HologramLayout.slabHeight, slabR = HologramLayout.slabCornerRadius
        slab = ModelEntity(mesh: FXMeshes.roundedSlab(width: slabW, height: slabH, depth: HologramLayout.cardThickness, radius: slabR),
                           materials: [HologramController.slabMaterial(look: HologramLook.desk)])
        rim = ModelEntity(mesh: FXMeshes.roundedRectRing(width: slabW, height: slabH, radius: slabR, thickness: Self.rimThickness),
                          materials: [HologramController.emissive(white, intensity: 5, opacity: 0.6)])
        // v4 B1: the pool is kept (it is where the beam enters the plate), gold — the bible's one light colour — and
        // sized to the hero card's bottom margin, under its type column.
        let landingSize = hero?.landingSize ?? Self.landingSize
        let landingTint = hero == nil ? white : UIColor(hex: "#FFD58A")
        landing = ModelEntity(mesh: .generatePlane(width: landingSize.x, height: landingSize.y, cornerRadius: landingSize.y / 2),
                              materials: [HologramController.emissive(landingTint, texture: FXTextures.shared.softDisc, intensity: 2.2, opacity: 0.9)])
        tapTarget = ModelEntity(mesh: .generatePlane(width: cardSize.x, height: cardSize.y,
                                                     cornerRadius: hero?.cornerRadius ?? HologramLayout.cardCornerRadius),
                                materials: [HologramController.unlit(white, opacity: 0.001)])
        idleScan = ModelEntity(mesh: .generatePlane(width: HologramLayout.cardWidth + 0.02, height: 0.004),
                               materials: [HologramController.emissive(white, intensity: 2.5, opacity: 0.18)])
        devicePlaceholder = ModelEntity(
            mesh: .generateBox(width: footprint.x, height: 0.004, depth: footprint.y, cornerRadius: 0.004),
            materials: [HologramController.unlit(UIColor(white: 0.12, alpha: 1), opacity: 0.9)]
        )
        flash = ModelEntity(mesh: .generatePlane(width: footprint.x * 1.6, depth: footprint.y * 1.6),
                            materials: [FXMaterials.glow(fx.softDisc, tint: white, opacity: 1)])
        acquireRing = ModelEntity(mesh: .generatePlane(width: 0.2, depth: 0.2),
                                  materials: [FXMaterials.glow(fx.ring, tint: white, opacity: 1)])

        root.addChild(surface)
        root.addChild(hintHolder)
        root.addChild(anchorRoot)
        // v4 B1 §1: the case frame C, hung off S at the measured offset (`V4.ScreenOffset`, one source, resolved by
        // `AppModel` into `ObjectScreenFrame.userOffset` before this controller exists). The LCD hard zone of the
        // H0 prism sits at the same offset inside the case.
        caseRoot.name = "caseRoot"
        caseCenter = V4.ScreenOffset.caseCenter(offset: ObjectScreenFrame.userOffset)
        caseRoot.position = caseCenter
        deviceFootprint.lcdCenter = ObjectScreenFrame.userOffset
        auditor.footprint = deviceFootprint
        anchorRoot.addChild(caseRoot)
        anchorRoot.addChild(devicePlaceholder)
        anchorRoot.addChild(overlay.root)
        anchorRoot.addChild(well.root)
        caseRoot.addChild(boxScan.root)
        caseRoot.addChild(buttonWave.root)
        caseRoot.addChild(buttonGlintGroup)
        buttonGlintGroup.name = "buttonGlints"
        overlay.configure(device: deviceFootprint.size, caseCenter: caseCenter)
        well.configure(device: deviceFootprint.size, caseCenter: caseCenter)
        projector.configure(device: deviceFootprint.size, caseCenter: caseCenter)
        boxScan.configure(box: [deviceFootprint.size.x, deviceThickness, deviceFootprint.size.y], screen: footprint,
                          screenCenter: deviceFootprint.lcdCenter)
        anchorRoot.addChild(pixels.root)
        pixels.root.components.set(BloomComponent(scope: .hierarchical))
        anchorRoot.addChild(acquire)
        anchorRoot.addChild(particleEntity)
        anchorRoot.addChild(hologram)
        anchorRoot.components.set(SpatialAudioComponent(gain: -6))
        // The follower is stepped once per rendered frame by `EngineTickSystem`. It hangs off `root`, which is
        // never disabled, so the tick keeps running through every hide / carry / world.
        root.addChild(followerDriver)
        followerDriver.components.set(EngineTickComponent(tick: { [weak self] dt in
            self?.stepFollower(dt: dt)
            self?.stepSleepFX(dt: dt)
        }))
        // Mini card: its holder and its own tick, both on `root` and both permanently enabled.
        root.addChild(miniHolder)
        miniHolder.components.set(BloomComponent(scope: .hierarchical))
        miniHolder.components.set(SpatialAudioComponent(gain: -6))
        root.addChild(miniDriver)
        miniDriver.components.set(EngineTickComponent(tick: { [weak self] dt in self?.stepMiniCard(dt: dt) }))
        // V3-2a H0: the footprint audit, off unless `--footprint-check` enables its driver.
        root.addChild(auditDriver)
        auditDriver.components.set(EngineTickComponent(tick: { [weak self] dt in self?.stepFootprintAudit(dt: dt) }))
        auditDriver.isEnabled = false
        // S0a: the audit checks the parent chain itself rather than trusting a "the card is hinged" flag.
        auditor.hinge = handPivot
        root.addChild(notePreviewRoot)
        notePreviewRoot.components.set(BloomComponent(scope: .hierarchical))
        notePreviewRoot.components.set(SpatialAudioComponent(gain: -6))

        hologram.addChild(shaft)
        hologram.addChild(cardGroup)
        hologram.addChild(handPivot)
        handPivot.name = "handPivot"
        handPivot.orientation = HandFacing.base
        handPivot.position = hingePosition
        handPivot.addChild(hingeGroup)
        // **V3-4 §7.** A child of `anchorRoot`, **not** of the hinge. The hinge turns (the card opens 180°
        // about it), and a plane that turns with it sweeps its bounding box back over the device — the first
        // cut hung it off `handPivot` and the audit reported `hinge.glow inside` 14–19 times a run. Pinned 4 mm
        // beyond the prism's own top edge, it is outside by geometry rather than by argument. **v4 B1**: in the
        // case frame C — it is the case's top edge it lights.
        hingeGlowStrip.name = "hinge.glow"
        hingeGlowStrip.position = [0, 0.002, -(deviceFootprint.half.y + 0.004)]
        hingeGlowStrip.components.set(OpacityComponent(opacity: 0))
        hingeGlowStrip.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.01,
                                                     baseOpacity: 0.32, opacityAmplitude: 0.10, period: 3.1))
        hingeGlowStrip.isEnabled = false
        caseRoot.addChild(hingeGlowStrip)
        // V3-4 §8. A torus of motes around the shell's outline, stretched to the device's 60 × 95 proportion
        // by a non-uniform scale on the entity itself (an ellipse the emitter shapes cannot express), and
        // circling it with `vortexStrength` rather than with 24 entities on 24 orbits.
        sleepDust.name = "sleep.dust"
        sleepDust.scale = [1, 1, DeviceFootprint.aiPassport.size.y / DeviceFootprint.aiPassport.size.x]
        sleepDust.position = [0, 0.004, 0]
        sleepDust.components.set(HologramController.sleepDustEmitter(sprite: FXTextures.shared.sparkle,
                                                                    tint: HologramLook.desk.highlight))
        sleepDust.isEnabled = false
        // v4 B1: it circles the shell's outline, so it is centred on the case.
        caseRoot.addChild(sleepDust)
        hingeGroup.name = "hingeGroup"
        // v3 H2 §3: the hand card's dust. A **sibling** of the card, for the two reasons `NoteTrailComponent`
        // documents — the card carries an `OpacityComponent` (hierarchical: it would fade the sparks out with
        // it) and it is disabled the moment it folds away (which would kill every spark still in the air).
        hologram.addChild(handTrail)
        handTrail.name = "trail.card"
        handTrail.components.set(HologramController.noteTrailEmitter(sprite: fx.mote,
                                                                     size: Self.trailDustSize))
        handTrail.components.set(NoteTrailComponent(target: cardGroup, birthRate: Self.handTrailBirthRate,
                                                    forceFlying: false))
        handTrail.isEnabled = false
        // The note fan hangs off the hologram too, so it rides the frozen anchor pose and goes away with the
        // card; its own 2 mm / 7 s drift keeps the arc from looking printed on the air.
        hologram.addChild(notes.group)
        // v4 B2 §3.3 / v4 B3 §2: the gold point (off until a pick-up fold or a collapse lands on it). In the case frame C,
        // beside the top edge — not under `hologram`, which a collapse switches off (and which `runCarry` reads as "the
        // card is on screen") — with its own bloom, since `hologram`'s does not reach it here.
        caseRoot.addChild(pickup.point)
        pickup.point.components.set(BloomComponent(scope: .hierarchical))
        layoutGoldPoint()
        notes.group.addChild(notes.previewHolder)
        notes.group.components.set(FloatComponent(basePosition: .zero, amplitude: 0.002, period: 7))
        notes.previewHolder.isEnabled = false
        hologram.components.set(BloomComponent(scope: .hierarchical))
        surface.components.set(BloomComponent(scope: .hierarchical))

        devicePlaceholder.position = [0, -0.002, 0]
        devicePlaceholder.name = "devicePlaceholder"
        // It *is* the hardware in a run that has none (`--preview`), so the rule cannot apply to it.
        devicePlaceholder.components.set(FootprintProbeComponent(.exempt))
        devicePlaceholder.isEnabled = false
        particleEntity.position = [0, 0.01, 0]
        particleEntity.name = "card.particles"

        // --- Surface: one breathing background glow; ripples are spawned per event ---
        surface.addChild(haloDisc)
        haloDisc.name = "surface.halo"
        configureHalo()
        haloDisc.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.04, baseOpacity: 1, opacityAmplitude: 0.15, period: 4.2))
        haloDisc.components.set(ModelSortGroupComponent(group: sortGroup, order: 0))
        orbGroup.position = [0, 0.0025, 0]
        surface.addChild(orbGroup)
        surface.isEnabled = false

        // --- Acquire glint (on the image plane) ---
        flash.position = [0, 0.0015, 0]
        acquireRing.position = [0, 0.0018, 0]
        flash.name = "acquire.flash"
        acquireRing.name = "acquire.ring"
        acquire.addChild(flash)
        acquire.addChild(acquireRing)
        acquire.isEnabled = false

        // --- Card: rim, invisible tap target, SwiftUI card in front ---
        cardGroup.name = ProjectorRig.cardEntityName
        cardGroup.position = [0, HologramLayout.cardCenterHeight, 0]
        cardGroup.orientation = simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0])
        // Depth order on the card (all of it depth-read-only, so the sort group is what actually decides):
        // slab −0.007 / 25 → landing / 28 → rim −0.001 / 31 → tapTarget −0.006 → idleScan +0.003
        // → SwiftUI attachment +0.002 → avatarSparks +0.012. The slab is 12 mm thick, so its front face sits
        // at −0.001 — exactly where the rim draws, and 3 mm behind the attachment.
        //
        // The landing pool is the one place this departs from the plan's z list (−0.0005): a RealityView
        // attachment is not refractive glass, it is an opaque quad, so a pool *behind* it is simply invisible —
        // and "the bottom of the card glows" is the whole point of the beam. It sits 2.5 mm in front of the
        // card face instead, where the soft falloff reads as light that came up through the plate.
        slab.position = [0, 0, -0.007]
        landing.position = hero?.landingCenter ?? [0, Self.landingCenterY, 0.0045]
        rim.position = [0, 0, -0.001]
        tapTarget.position = [0, 0, -0.006]
        tapTarget.name = HologramController.panelEntityName
        tapTarget.components.set(InputTargetComponent())
        tapTarget.components.set(HoverEffectComponent())
        let tapBox = hero?.tapCollision ?? [0.29, 0.29, 0.02]
        tapTarget.components.set(CollisionComponent(shapes: [
            .generateBox(width: tapBox.x, height: tapBox.y, depth: tapBox.z),
        ]))
        idleScan.position = [0, -HologramLayout.cardHeight / 2, 0.003]
        idleScan.isEnabled = false
        layoutCardLayers()
        // Avatar centre on the glass card (see PixelCloud.glassTarget: v ≈ 0.80 of the 86 % typeset area).
        avatarSparks.position = [0, (0.80 - 0.5) * 0.86 * HologramLayout.cardHeight, 0.012]
        avatarSparks.name = "avatar.sparks"
        avatarSparks.components.set(HologramController.avatarSparkEmitter(sprite: fx.particle, tint: white))
        slab.name = "card.slab"
        rim.name = "card.rim"
        // V3-2a2 S0a: the four layers that reach the device's top bezel once the hinge sits on the edge —
        // the slab (3 mm of overhang), the rim, the tap target and the landing pool, whose bottom edge *is*
        // the card's. They are tolerated only while the card hangs off the hinge and only within 6 mm of
        // the edge; the hover form, which lies over the LCD, is caught by the same probe (the oracle A/B).
        for layer in [slab, rim, tapTarget, landing] {
            layer.components.set(FootprintProbeComponent(.hingeOverhang(maxDepth: Self.hingeOverhangDepth)))
        }
        landing.name = "card.landing"
        idleScan.name = "card.idleScan"
        cardAttachmentHolder.name = "card.attachment"
        cardTagsHolder.name = "card.attachment.tags"
        cardAvatarHolder.name = "card.attachment.avatar"
        cardFaceGroup.name = "card.face"
        cardBackHolder.name = "card.back"
        // **V3-3 C2 / C3 H0**: the two new sheets and the back are part of the hinged card — same probe as
        // the slab and the rim, so if the audit ever learns to judge a hosted attachment they are judged by
        // the same rule and not exempt by omission. (Today `FootprintAuditor` only reports `ModelEntity`s
        // that carry a mesh, and a `ViewAttachmentEntity` is neither; the oracle run's 141 findings name
        // `card.slab` / `card.rim` / `hologram.panel` and never an attachment.)
        for layer in [cardAttachmentHolder, cardTagsHolder, cardAvatarHolder, cardBackHolder] {
            layer.components.set(FootprintProbeComponent(.hingeOverhang(maxDepth: Self.hingeOverhangDepth)))
        }
        slab.components.set(ModelSortGroupComponent(group: sortGroup, order: 25))
        landing.components.set(ModelSortGroupComponent(group: sortGroup, order: 28))
        rim.components.set(ModelSortGroupComponent(group: sortGroup, order: 31))
        cardGroup.addChild(slab)
        cardGroup.addChild(landing)
        cardGroup.addChild(rim)
        cardGroup.addChild(tapTarget)
        cardGroup.addChild(idleScan)
        // The three sheets hang off one group so that C3's flip has a single opacity to cross-fade, and so
        // that every existing write to `cardAttachmentHolder` (the reveal's, the fold's, `resetCardLayers`')
        // keeps meaning exactly what it meant when there was one of them.
        cardGroup.addChild(cardFaceGroup)
        cardFaceGroup.addChild(cardAttachmentHolder)
        cardFaceGroup.addChild(cardTagsHolder)
        cardFaceGroup.addChild(cardAvatarHolder)
        // C3: behind the slab, turned right round. It starts invisible and stays that way until the card is
        // actually turned away. **v4 B5 §3**: and out of the tree while it is — `--perf-census` found it enabled at
        // opacity 0 in every frame of every desk and hand window (a card-sized SwiftUI layer handed to the renderer for
        // no pixel). The flip still is a fade (plan §0 rule 3): it switches the holder on *before* fading it in, and
        // takes it out only when the fade back to the front has ended (`crossFadeCardSides`).
        cardGroup.addChild(cardBackHolder)
        // v4 B1: behind the hero card's 12 mm slab and its opaque shadow caster.
        cardBackHolder.position = [0, 0, hero?.backZ ?? CardLayers.backZ]
        cardBackHolder.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])
        cardBackHolder.components.set(OpacityComponent(opacity: 0))
        cardBackHolder.isEnabled = false
        cardFaceGroup.components.set(OpacityComponent(opacity: 1))
        cardGroup.addChild(avatarSparks)
        rim.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0, baseOpacity: 0.6, opacityAmplitude: 0.08, period: 10))
        landing.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0, baseOpacity: Self.landingLevel, opacityAmplitude: 0.12, period: 1.7))

        // --- Projector: base disk + ring on the image, rays fanning up to the card ---
        shaft.position = [0, HologramLayout.beamBaseHeight, 0]
        shaft.addChild(projector.root)
        shaft.isEnabled = true

        hintHolder.components.set(BillboardComponent())
        hintHolder.isEnabled = false

        buildButtonGlints()
        // v4 B2: names for `[perf] scene detail:` (nothing looks these up; the card's own `hologram.cardGroup` and the
        // tappable names are untouched).
        for (entity, name) in [(anchorRoot, "anchorRoot"), (hologram, "hologram"), (surface, "surface"),
                               (hintHolder, "hint"), (shaft, "shaft"), (projector.root, "projector"),
                               (notes.group, "notes.group"), (notes.previewHolder, "notes.preview"),
                               (overlay.root, "overlay"), (well.root, "well"), (pixels.root, "pixels"),
                               (acquire, "acquire"), (miniHolder, "miniHolder"), (notePreviewRoot, "notePreviewRoot"),
                               (followerDriver, "driver.follower"), (miniDriver, "driver.mini"),
                               (auditDriver, "driver.audit"), (coinGroup, "coins"), (orbGroup, "orbs")] as [(Entity, String)]
        where entity.name.isEmpty {
            entity.name = name
        }
        hologram.isEnabled = false
        setFaceUser(true)
        audio.preload()
        // All three theme screens derived now, so a handover is a material swap.
        overlay.prepare(themes: manifest.themes)
        pixels.prepare(themes: manifest.themes)
    }

    // MARK: - Attachments

    func attachCard(_ entity: Entity) {
        cardAttachmentHolder.children.forEach { $0.removeFromParent() }
        cardAttachmentHolder.addChild(entity)
    }

    /// **V3-3 C2**: the hero-image sheet, 8 mm off the plate.
    func attachCardAvatar(_ entity: Entity) {
        cardAvatarHolder.children.forEach { $0.removeFromParent() }
        cardAvatarHolder.addChild(entity)
    }

    /// **V3-3 C2**: the capsule sheet, 4 mm off the plate.
    func attachCardTags(_ entity: Entity) {
        cardTagsHolder.children.forEach { $0.removeFromParent() }
        cardTagsHolder.addChild(entity)
    }

    /// **V3-3 C3**: the back of the card, behind the slab and facing the other way.
    func attachCardBack(_ entity: Entity) {
        cardBackHolder.children.forEach { $0.removeFromParent() }
        cardBackHolder.addChild(entity)
    }

    func attachHint(_ entity: Entity) {
        hintHolder.children.forEach { $0.removeFromParent() }
        hintHolder.addChild(entity)
    }

    /// Base-ring tap: the wearer is putting the card away. The fold itself goes through
    /// `CardTracker.requestDismiss()`, so the gate stays the single writer of presence; this is only the blip
    /// and the ring under the finger that says the tap was heard.
    func playDismissFeedback() {
        spawnRipple(at: [0, 0.0025, 0], tint: look.secondaryTint, startScale: 0.08, endScale: 0.55, duration: 0.5, peak: 0.9)
        audio.play(.orbTap, on: anchorRoot)
    }

    /// **V3-2a2 S1**: the next detection is a summon, not a re-acquisition — it gets the 0.6 s scan, and the
    /// entrance waits for its convergence beat. Set by every `requestShow()` the wearer asked for (OK, a tap
    /// on the socket light, the director's `cmd show`); cleared by the scan that consumes it.
    func noteSummonRequested() {
        summonPending = true
    }

    /// Socket tap while the card is folded away: the light under the finger answers before the reentry starts.
    func playShowFeedback() {
        noteSummonRequested()
        overlay.socket.components.set(TweenComponent(scale: (from: [1.12, 1, 1.12], to: [1, 1, 1]),
                                                     opacity: (from: 0.9, to: 0.5), duration: 0.5, easing: .easeOutCubic))
        audio.play(.orbTap, on: anchorRoot)
    }

    /// Persist the light well at `HologramLayout.wellIdleLevel` (no-op at level 0, or with the card hidden).
    /// Every steady state ends here, so the shaft under the device stays open — dimmed — for the whole life of
    /// the card instead of sealing at the end of the reveal.
    func showWellDimmed(animated: Bool) {
        // E15: the screen is the card's only light source in the hand, so the ring burns a little brighter
        // there than it does on the desk.
        let level = isHandForm ? wellLevelHand : HologramLayout.wellIdleLevel
        guard level > 0, hologram.isEnabled else { return }
        well.showDimmed(level: level, animated: animated)
    }

    /// A world is opening (`WorldEngine.onEnterStarted`): close the desk's shaft, so a lit well is not left
    /// glowing under the frozen card inside the world. The return path re-opens it dimmed.
    func enterWorldShell() {
        guard well.isOpen else { return }
        print("[reveal] desk light well closed for the world")
        well.close(duration: 0.3)
    }

    // MARK: - In-world mini card (工作包 C)

    /// Shrink the desk card into the small card that rides along inside a world (started at the world's
    /// `take.miniCardAt`, once its shell is opaque).
    ///
    /// 0.00 the choreography is cancelled, `FloatComponent` comes off (the float system would write the desk
    ///      position straight back over the tween), the billboard is suspended, the projector switches off and
    ///      the desk surface + socket fade over 0.3 s; the card leaves `hologram` for a **root-space** holder,
    ///      so nothing here touches `anchorRoot` or the pose follower (M1b) — the frozen desk pose is still
    ///      exactly where the world left it when the card comes home.
    /// 0.00–0.60 one tween: to head + forward·0.60 + (0, −0.20, 0), yaw-only facing + 8° pitch, scale → 0.35,
    ///      bowed 6 cm upward (`arcOffset`), spring 0.45 / 0.75 · `carry` at 0.00, `tick` at 0.55.
    /// 0.61 the lazy head follow takes over from the tween's landing position (no pop).
    func enterMiniCard(head: simd_float4x4?) {
        guard !isMiniCard, hologram.isEnabled else { return }
        guard let headPose = head ?? headPoseProvider?() else {
            print("[reveal] mini card skipped: no head pose")
            return
        }
        // v4 B2 §3.3: a world entered while the card was folded: the mini card grows out of the point.
        endPickupFold(to: nil)
        isMiniCard = true
        miniFollowActive = false
        v4?.settleForV3Choreography(reason: "mini card")
        // Remember what form the card had, so the exit knows whether home is the desk or the wearer's hand.
        returnsToHand = isHandForm
        isHandForm = false
        disarmHandFormProbe()
        setHandTrail(false)
        // Whatever form the card was in (a reveal in flight, or the carried form if the wearer pressed OK with
        // the device in hand), from here it is the mini card.
        carriedVisual = false
        cancelChoreography()
        miniTask?.cancel()
        setSearching(false)
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        suspendBillboard(true)
        resetCardLayers()
        cardGroup.components.set(OpacityComponent(opacity: 1))
        // Out of the (frozen) hologram, into root space, without moving a pixel.
        cardGroup.setParent(miniHolder, preservingWorldTransform: true)
        projector.setVisible(false, animated: true)
        fadeDesk(visible: false, animated: true)
        let target = MiniCardTarget.pose(head: headPose)
        print(String(format: "[reveal] mini card in the world: %.2f m ahead, %.2f m below the eyes, scale %.2f → (%.2f, %.2f, %.2f)",
                     MiniCardTarget.forwardDistance, MiniCardTarget.dropHeight, HologramLayout.miniCardScale,
                     target.position.x, target.position.y, target.position.z))
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: SIMD3<Float>(repeating: HologramLayout.miniCardScale)),
            position: (from: cardGroup.position, to: target.position),
            orientation: (from: cardGroup.orientation, to: target.orientation),
            opacity: (from: cardGroup.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
            arcOffset: [0, 0.06, 0], duration: 0.6, easing: .spring(response: 0.45, damping: 0.75)))
        // v4 B3 §1: 「按 OK 回到桌面」 under the mini card (B1 §6 listed it missing from the hero card).
        setMiniHint(visible: true)
        audio.play(.carry, on: anchorRoot)
        miniTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(550))
            guard let self, !Task.isCancelled, self.isMiniCard else { return }
            self.audio.play(.tick, on: self.miniHolder)
            try? await Task.sleep(for: .milliseconds(70))
            guard !Task.isCancelled, self.isMiniCard else { return }
            // Hand over at exactly where the tween left the card: the follow starts at rest, not with a jump.
            self.miniFollow.place(at: self.cardGroup.position, head: self.headPoseProvider?() ?? headPose)
            self.miniFollowActive = true
        }
    }

    /// Fly the mini card back onto the desk (the world's exit, or a Digital Crown abort with `animated: false`).
    ///
    /// 0.00–0.60 the reverse tween to the frozen desk pose (scale → 1, `arcOffset` 5 cm), converted out of
    ///      `hologram`'s space so it lands exactly on the pose the follower is holding
    /// 0.35 the light well comes back dimmed, the projector switches on, the desk surface + socket fade in
    /// 0.63 the card is `setParent(hologram)`-ed home, the billboard and the idle float resume, and the SwiftUI
    ///      card re-staggers its rows; whatever error is left is corrected by the normal thaw glide at 0.8.
    func leaveMiniCard(animated: Bool = true, from worldID: String? = nil) {
        guard isMiniCard else { return }
        isMiniCard = false
        setMiniHint(visible: false)
        miniFollowActive = false
        miniTask?.cancel()
        // v3 FIX B: the passport is still in the wearer's hand, so "home" is the hand form on the device —
        // not the desk transform 22 cm above a desk they are not looking at.
        let toHand = returnsToHand
        let home: Transform
        if toHand, handForm == .hinge {
            // V3-2a H2: "home" in the hand is the hinge on the device's top edge, expressed in `hologram`
            // space so the flight and the hand-off below stay in one frame. **B0b**: the arm is put back at
            // its resting angle first and the card's home is read out of *it* — the card's centre is on an
            // arc about the hinge now, not at a fixed point above it.
            placeHandPivot()
            syncHingeGroup(HandFacing.hinged(weight: HandFacing.hingeWeight,
                                             card: hingeCardPosition, head: headInHinge()))
            let onArm = Transform(scale: SIMD3<Float>(repeating: handScale),
                                  rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                  translation: hingeCardPosition)
            home = hologram.convert(transform: onArm, from: hingeGroup)
        } else if toHand {
            home = Transform(scale: SIMD3<Float>(repeating: handScale), rotation: Self.handBaseOrientation,
                             translation: [0, Self.handY, 0])
        } else {
            home = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0]),
                             translation: [0, HologramLayout.cardCenterHeight, 0])
        }
        guard animated else {
            cardGroup.components.remove(TweenComponent.self)
            cardGroup.setParent(hologram, preservingWorldTransform: false)
            cardGroup.transform = home
            if toHand {
                if handForm == .hinge { attachCardToHinge() }
                restoreHandFormAfterMini(animated: false, from: worldID)
            } else {
                restoreDeskAfterMini(animated: false)
                print("[reveal] mini card back on the desk (instant, aborted)")
            }
            return
        }
        let target = miniHolder.convert(transform: home, from: hologram)
        print(toHand ? "[reveal] mini card back into the hand (0.6 s)" : "[reveal] mini card back on the desk (0.6 s)")
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: target.scale),
            position: (from: cardGroup.position, to: target.translation),
            orientation: (from: cardGroup.orientation, to: target.rotation),
            arcOffset: [0, 0.05, 0], duration: 0.6, easing: .spring(response: 0.45, damping: 0.75)))
        audio.play(.carry, on: miniHolder)
        miniTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled else { return }
            // The light the card is flying back into is waiting for it before it arrives (motion principle 7).
            // Into the hand, the only light it has is the well at the screen: the desk and the projector rays
            // stay where the hand form left them, which is off.
            self.showWellDimmed(animated: true)
            if !toHand {
                self.projector.setVisible(true, animated: true)
                self.fadeDesk(visible: true, animated: true)
            }
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled, !self.isMiniCard else { return }
            self.cardGroup.setParent(self.hologram, preservingWorldTransform: false)
            self.cardGroup.transform = home
            if toHand {
                if self.handForm == .hinge { self.attachCardToHinge() }
                self.restoreHandFormAfterMini(animated: true, from: worldID)
            } else {
                self.restoreDeskAfterMini(animated: true)
            }
        }
    }

    /// The card has flown out of the world and back onto the passport the wearer is still holding. Every
    /// steady-state value the hand form owns is put back explicitly — and **`startIdle()` is deliberately not
    /// called**: it is the desk's idle, and the first thing it does is tell the note fan it may throw itself,
    /// which would fan ten cards off a card floating 35 mm above a device in someone's hand.
    private func restoreHandFormAfterMini(animated: Bool, from worldID: String?) {
        cardGroup.components.remove(TweenComponent.self)
        returnsToHand = false
        isHandForm = true
        // v4 B2: into the hand from a world — the rig's hand form (its cones parked), even though it stays off here.
        syncProjectorForm()
        armHandFormProbe()
        carriedVisual = true
        deskFaded = true
        resetCardLayers()
        cardGroup.components.set(OpacityComponent(opacity: 1))
        suspendBillboard(true)
        surface.components.remove(TweenComponent.self)
        fadeDesk(visible: false, animated: false)
        projector.setVisible(false, animated: false)
        showWellDimmed(animated: animated)
        setHandTrail(false)          // armed again by the speed hysteresis on the next frame it moves
        print("[reveal] back in the hand from \(worldID ?? "the world")")
    }

    /// One rendered frame of the mini card's lazy head follow (`EngineTickComponent` on `miniDriver`). Silent
    /// until the shrink tween has landed, and a no-op whenever there is no head pose (the simulator has no
    /// `WorldTrackingProvider`, so the card simply stays parked where it was placed).
    private func stepMiniCard(dt: Float) {
        guard miniFollowActive, isMiniCard, let head = headPoseProvider?() else { return }
        cardGroup.position = miniFollow.step(dt: dt, head: head)
        cardGroup.orientation = miniFollow.orientation(head: head)
    }

    /// The desk's own furniture (halo, coins, exit chip, and the socket light on the device) while the card is
    /// away in a world: they are frozen at the desk and would otherwise hang in the middle of the world.
    private func fadeDesk(visible: Bool, animated: Bool) {
        let duration: Float = animated ? 0.3 : 0
        // **v4 B2.** A faded desk leaves the tree once it is dark (the halo, the two coins and their labels, the
        // chips, whatever ripples are running): at opacity 0 it cost nothing to look at and still cost every frame.
        // Every way back fades it in from here, so it is switched on first.
        if visible { surface.isEnabled = true }
        let from = surface.isEnabled ? (surface.components[OpacityComponent.self]?.opacity ?? 1) : 0
        surface.components.set(TweenComponent(opacity: (from: from, to: visible ? 1 : 0),
                                              duration: duration, easing: visible ? .easeOutCubic : .easeInCubic,
                                              disableWhenDone: !visible))
        let socketFrom = overlay.socket.components[OpacityComponent.self]?.opacity ?? 0.4
        overlay.socket.components.set(TweenComponent(opacity: (from: socketFrom, to: visible ? 0.4 : 0),
                                                     duration: duration, easing: visible ? .easeOutCubic : .easeInCubic))
    }

    /// **v4 B2 §3.3.** The pick-up fold takes the desk's light away (the card has left the desk); the next entrance —
    /// the hand form, or `cardIsComingBack` on the way to a rise — puts it back. **v4 B3 §2 / §3.3**: so does the collapse,
    /// and the surface leaves the tree when the fade ends (`fadeDesk`), halo and all.
    func setDeskFaded(animated: Bool = true) {
        deskFaded = true
        fadeDesk(visible: false, animated: animated)
    }

    /// **v4 B3 §2.** What `foldCard` does to the card's state before it lies down, for the gold-point collapse: off the
    /// hinge (the arc is written in `hologram` space), out of the hand form, no trail, no anticipation, billboard held.
    func releaseCardForCollapse() {
        detachCardFromHinge()
        setHandTrail(false)
        isHandForm = false
        disarmHandFormProbe()
        foldAnticipating = false
        cardGroup.components.remove(FloatComponent.self)
        suspendBillboard(true)
        idleScan.isEnabled = false
        pixels.hide()
    }

    /// **v4 B2 §3.3.** The `--v3-card` path's desk unfold after a pick-up fold: v3's reentry.
    func runDeskReentryAfterFold() {
        runReentry(animated: true)
    }

    /// Back home: every steady-state value the mini card borrowed is put back explicitly (an aborted return
    /// must not leave an invisible desk behind for the next `runReentry` to re-enable).
    private func restoreDeskAfterMini(animated: Bool) {
        cardGroup.components.remove(TweenComponent.self)
        returnsToHand = false
        carriedVisual = false
        deskFaded = false
        resetCardLayers()
        cardGroup.components.set(OpacityComponent(opacity: 1))
        suspendBillboard(false)
        surface.components.remove(TweenComponent.self)
        surface.components.set(OpacityComponent(opacity: 1))
        // v4 B2: the world's fade took the desk out of the tree (`fadeDesk`).
        surface.isEnabled = true
        overlay.socket.components.remove(TweenComponent.self)
        overlay.socket.components.set(OpacityComponent(opacity: 0.4))
        // v4 B2: a world entered from the hand comes home to the desk with the rig still in its hand form otherwise.
        syncProjectorForm()
        projector.setVisible(true, animated: animated)
        showWellDimmed(animated: animated)
        startIdle()
    }

    /// Return-from-world light: the hologram re-reveals with the acquire glint + settle so the desk feels "back".
    func replayAfterWorld() {
        guard hologram.isEnabled else { return }
        showWellDimmed(animated: true)
        playAcquireCue()
        audio.play(.settle, on: hologram)
        spawnRipple(at: [0, 0.0025, 0], tint: look.secondaryTint, startScale: 0.1, endScale: 1.2, duration: 0.9, peak: 0.8)
    }

    /// World coin `index` of `count` on an outer arc (radius 0.26 m) on the reader's side, leaning back 30°.
    func attachWorldCoin(_ entity: Entity, index: Int, count: Int) {
        if coinGroup.parent == nil {
            coinGroup.position = [0, 0.003, 0]
            surface.addChild(coinGroup)
        }
        let spread: Float = 30 * .pi / 180
        let angle = (Float(index) - Float(count - 1) / 2) * spread
        let radius: Float = Self.orbArcRadius + 0.09
        let holder = Entity()
        holder.position = [sin(angle) * radius, 0.024, cos(angle) * radius]
        holder.orientation = simd_quatf(angle: angle * 0.5, axis: [0, 1, 0]) * simd_quatf(angle: -30 * .pi / 180, axis: [1, 0, 0])
        holder.addChild(entity)
        coinGroup.addChild(holder)
        while coinHolders.count <= index { coinHolders.append(Entity()); coinBasePositions.append(.zero) }
        coinHolders[index].removeFromParent()
        coinHolders[index] = holder
        coinBasePositions[index] = holder.position
    }

    static let exitChipAttachmentID = "exit-chip"

    /// Small exit chip at the right end of the coin arc (+90°): same glass family, out of the way but findable.
    func attachExitChip(_ entity: Entity) {
        if coinGroup.parent == nil {
            coinGroup.position = [0, 0.003, 0]
            surface.addChild(coinGroup)
        }
        let angle: Float = 90 * .pi / 180
        let radius: Float = Self.orbArcRadius + 0.09
        let holder = Entity()
        holder.position = [sin(angle) * radius, 0.02, cos(angle) * radius]
        holder.orientation = simd_quatf(angle: angle * 0.5, axis: [0, 1, 0]) * simd_quatf(angle: -30 * .pi / 180, axis: [1, 0, 0])
        holder.addChild(entity)
        coinGroup.addChild(holder)
    }

    /// `WorldNameLabel` attachment for coin `index`: a billboarded holder 6 cm above the coin, hidden until the
    /// carousel rests on that coin.
    func attachWorldNameLabel(_ entity: Entity, index: Int) {
        if coinGroup.parent == nil {
            coinGroup.position = [0, 0.003, 0]
            surface.addChild(coinGroup)
        }
        let holder = Entity()
        holder.components.set(BillboardComponent())
        holder.components.set(OpacityComponent(opacity: 0))
        holder.isEnabled = false
        holder.addChild(entity)
        coinGroup.addChild(holder)
        while coinLabelHolders.count <= index { coinLabelHolders.append(Entity()) }
        coinLabelHolders[index].removeFromParent()
        coinLabelHolders[index] = holder
        if coinBasePositions.indices.contains(index) { holder.position = coinBasePositions[index] + [0, 0.06, 0] }
    }

    /// Device UP / DOWN carousel (three staggered beats): the highlighted coin scales 1 → 1.18 (spring 0.4 / 0.72)
    /// and lifts 1.5 cm while the others dim to 0.55 (0 ms); its name capsule rises in 6 cm above it (90 ms) and
    /// the subtitle follows inside the capsule (150 ms); a ripple under the coin and a `tick`. `nil` restores every coin.
    func setCoinHighlight(index: Int?) {
        highlightedCoin = index
        for (i, holder) in coinHolders.enumerated() where coinBasePositions.indices.contains(i) {
            let on = index == i
            let base = coinBasePositions[i]
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: on ? [1.18, 1.18, 1.18] : [1, 1, 1]),
                position: (from: holder.position, to: base + [0, on ? 0.015 : 0, 0]),
                opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: index == nil ? 1 : (on ? 1 : 0.55)),
                duration: 0.42, easing: .spring(response: 0.4, damping: 0.72)))
        }
        for (i, label) in coinLabelHolders.enumerated() where coinBasePositions.indices.contains(i) {
            let base = coinBasePositions[i]
            let current = label.components[OpacityComponent.self]?.opacity ?? 0
            if index == i {
                label.isEnabled = true
                label.components.set(TweenComponent(
                    scale: (from: [0.7, 0.7, 0.7], to: [1, 1, 1]),
                    position: (from: base + [0, 0.045, 0], to: base + [0, 0.06, 0]),
                    opacity: (from: current, to: 1),
                    delay: 0.09, duration: 0.35, easing: .spring(response: 0.4, damping: 0.72)))
            } else if label.isEnabled {
                label.components.set(TweenComponent(
                    scale: (from: label.scale, to: [0.85, 0.85, 0.85]),
                    opacity: (from: current, to: 0),
                    duration: 0.2, easing: .easeInCubic, disableWhenDone: true))
            }
        }
        guard let index, coinBasePositions.indices.contains(index) else { return }
        let base = coinBasePositions[index]
        spawnRipple(at: [base.x, 0.0025, base.z], tint: look.secondaryTint, startScale: 0.08, endScale: 0.5, duration: 0.5, peak: 0.85)
        audio.play(.tick, on: surface)
    }

    /// Desk controls accept gaze + pinch only when no world is active. Inside a world they would otherwise sit
    /// in the gaze line to the world's exit button and swallow the pinch (→ Safari).
    ///
    /// The card is **not** one of them any more: inside a world it is the mini card, and a pinch on it is how the
    /// wearer leaves the world (`ImmersiveView` routes that tap before its world guard). So the two halves are
    /// switched separately — `card` follows the mini card, `desk` follows the world.
    private(set) var isInteractive = true
    private(set) var isCardInteractive = true

    func setInteractive(_ enabled: Bool) {
        setInteractive(desk: enabled, card: enabled)
    }

    func setInteractive(desk: Bool, card: Bool) {
        if card != isCardInteractive {
            isCardInteractive = card
            tapTarget.components[InputTargetComponent.self]?.isEnabled = card
            tapTarget.components[HoverEffectComponent.self] = card ? HoverEffectComponent() : nil
        }
        guard desk != isInteractive else { return }
        isInteractive = desk
        projector.setInteractive(desk)
        for child in orbGroup.children where child.name == P0Probes.orbName {
            child.components[InputTargetComponent.self]?.isEnabled = desk
        }
    }

    /// Recolour the rim, the desk glow and the beam with a world's colour blended over the look's own at
    /// `strength` (0.35 = carousel preview, 1 = the world's; nil restores the look). The slab itself never takes
    /// a world colour: the plan's rule is that a world only tints the edge light and the beam.
    func setWorldTint(_ tint: UIColor?, strength: Float = 1) {
        guard worldTint != tint || worldTintStrength != strength else { return }
        worldTint = tint
        worldTintStrength = strength
        // Only the tinted surfaces are re-materialised (a full `applyLook()` rebuilds particles and the pixel
        // cloud: ~120 ms, which would land on the entry frame).
        if let tint {
            applyWorldTintOverride(tint, strength: strength)
        } else {
            restoreLookTint()
        }
        if hologram.isEnabled {
            // A colour change is a light event: the rim breathes once and the bloom peaks with it.
            rim.components.set(TweenComponent(scale: (from: [1.03, 1.03, 1.03], to: [1, 1, 1]), duration: 0.45, easing: .spring(response: 0.35, damping: 0.7)))
            setBloom(strength: look.bloomStrength, peak: 0.7 + 0.15 * strength, decay: 0.5)
        }
    }

    /// The look's own colours on the tinted surfaces (the world tint was dropped).
    private func restoreLookTint() {
        haloDisc.model?.materials = [FXMaterials.glow(fx.softRing(inner: Self.haloInner, outer: 1), tint: look.background, opacity: 0.55)]
        flash.model?.materials = [FXMaterials.glow(fx.softDisc, tint: look.tint, opacity: 1)]
        acquireRing.model?.materials = [FXMaterials.glow(fx.ring, tint: look.secondaryTint, opacity: 1)]
        applyRimColor(look.rimColor(tint: nil, strength: 0))
        projector.apply(look: look)
        well.apply(look: look)
    }

    /// The device shows another theme screen: swap the registration layer + pixel cloud to its bitmap. While a
    /// reveal / collapse is driving the pixel cloud the swap is deferred to its end (a mid-flight swap would flip
    /// the particles and the line art).
    func setTheme(_ theme: PassportManifest.Theme) {
        guard theme.id != self.theme.id else {
            pendingTheme = nil
            return
        }
        guard !pixelsInFlight else {
            pendingTheme = theme
            return
        }
        pendingTheme = nil
        self.theme = theme
        overlay.configure(theme: theme)
        pixels.configure(theme: theme)
        print("[theme] hologram textures → \(theme.id)")
    }

    /// The pixel cloud is free again: apply a theme that arrived mid-reveal.
    private func endPixelsInFlight() {
        pixelsInFlight = false
        if let pending = pendingTheme {
            pendingTheme = nil
            setTheme(pending)
        }
    }

    // MARK: - State

    /// Paint the one look onto every surface. v1 re-ran this whenever the wearer tapped a style orb; v2 has a
    /// single look, so it runs **once** and only `setWorldTint` changes a colour afterwards.
    func applyLook() {
        guard !lookApplied else { return }
        lookApplied = true
        haloDisc.model?.materials = [FXMaterials.glow(fx.softRing(inner: Self.haloInner, outer: 1), tint: look.background, opacity: 0.55)]
        applyRimColor(look.highlight)
        idleScan.model?.materials = [HologramController.emissive(look.highlight, intensity: 2.5, opacity: 0.18)]
        projector.apply(look: look)
        pixels.apply(look: look)
        flash.model?.materials = [FXMaterials.glow(fx.softDisc, tint: look.tint, opacity: 1)]
        acquireRing.model?.materials = [FXMaterials.glow(fx.ring, tint: look.secondaryTint, opacity: 1)]
        overlay.apply(look: look)
        well.apply(look: look)
        setBloom(strength: look.bloomStrength)
        particleEntity.components.set(look.makeParticles(footprint: footprint, spriteSheet: fx.spriteSheet))
        if var sparks = avatarSparks.components[ParticleEmitterComponent.self] {
            sparks.mainEmitter.color = .evolving(start: .random(a: look.highlight, b: look.tint), end: .single(look.secondaryTint.withAlphaComponent(0)))
            avatarSparks.components.set(sparks)
        }
        updateParticleRate()
        if let worldTint { applyWorldTintOverride(worldTint, strength: worldTintStrength) }
    }

    /// Coin tap: the desk answers where the finger was (ripple under the coin) and a blip, before the world entry
    /// starts — so the entry reads as caused by the tap, not as a cut.
    func playCoinFeedback(index: Int, count: Int) {
        let spread: Float = 30 * .pi / 180
        let angle = (Float(index) - Float(count - 1) / 2) * spread
        let radius: Float = Self.orbArcRadius + 0.09
        let at = SIMD3<Float>(sin(angle) * radius, 0.0025, cos(angle) * radius)
        spawnRipple(at: at, tint: look.secondaryTint, startScale: 0.1, endScale: 0.6, duration: 0.55, peak: 0.9)
        audio.play(.orbTap, on: surface)
    }

    /// Recolours the tinted surfaces (rim, desk halo, beam, well) with a world's colour, blended over the look's
    /// own by `strength` (a 0.35 preview keeps the desk recognisable).
    private func applyWorldTintOverride(_ tint: UIColor, strength: Float) {
        let k = CGFloat(max(0, min(1, strength)))
        let full = tint.withAlphaComponent(1)
        let halo = look.background.mixed(with: full, by: k)
        let secondary = look.secondaryTint.mixed(with: full, by: k)
        let primary = look.tint.mixed(with: full, by: k)
        haloDisc.model?.materials = [FXMaterials.glow(fx.softRing(inner: Self.haloInner, outer: 1), tint: halo, opacity: 0.55 - 0.05 * Float(k))]
        flash.model?.materials = [FXMaterials.glow(fx.softDisc, tint: primary, opacity: 1)]
        acquireRing.model?.materials = [FXMaterials.glow(fx.ring, tint: secondary, opacity: 1)]
        applyRimColor(look.rimColor(tint: tint, strength: strength))
        projector.apply(tint: primary)
        well.apply(tint: primary, highlight: .white)
    }

    /// Landing kick: the rays flare **and** the pool where they enter the slab flashes with them, so the beat
    /// lands on the card rather than only in the air below it.
    func flareBeam() {
        projector.flare()
        landing.components.set(TweenComponent(scale: (from: [1.06, 1.06, 1], to: [1, 1, 1]),
                                              opacity: (from: Self.landingLevel + 0.3, to: Self.landingLevel),
                                              duration: 0.45, easing: .easeOutCubic))
    }

    /// A single breath of the rim: the "something happened" beat, used by celebrations and colour changes.
    func pulseRim(scale: Float) {
        rim.components.set(TweenComponent(scale: (from: [scale, scale, scale], to: [1, 1, 1]),
                                                duration: 0.4, easing: .spring(response: 0.35, damping: 0.65)))
    }

    /// The rim is the one part of the card a world's colour ever reaches.
    private func applyRimColor(_ color: UIColor) {
        rim.model?.materials = [HologramController.emissive(color, intensity: 5, opacity: 0.6)]
    }

    /// Uniform pose dead zone (v2): below 4 mm / 1.5° a "new" pose is image-tracking noise on a 37 mm target, not
    /// the card moving. It applies on **every** path — expanded, carrying and the thaw glide — because a path that
    /// bypassed it was visible as a shimmy the moment the wearer held still (the thaw used to re-target a 0.3 s
    /// `move(to:)` for a 1 mm correction).
    static let poseDeadZone: Float = 0.004
    static let poseDeadZoneAngle: Float = 1.5 * .pi / 180
    /// 工作包 G2: the object source is noisier than the image one (2–4 mm against 0.1–0.5 mm on the headset), so
    /// its retargets need a wider dead zone — the τ 0.12 s low pass in `CardTracker` takes out the fast part and
    /// this takes out what is left. The image path keeps the 4 mm / 1.5° it was measured with.
    static let poseDeadZoneObject: Float = 0.006
    static let poseDeadZoneObjectAngle: Float = 2.5 * .pi / 180

    /// Follower time constants (s). A resting card is followed a little softer than a carried one; a relocation
    /// glide is slower still and speed-limited, so a card that comes back 30 cm away travels at a readable pace.
    static let followTauExpanded: Float = 0.25
    /// **V3-1b: 0.18 → 0.08.** The carried card hangs 35 mm over a screen the wearer is holding, so the follower's
    /// own ramp lag (v·τ) is read directly against the passport: 0.18 s cost 5.4 cm at 0.3 m/s. The tracking noise
    /// it used to absorb is now taken out upstream by the smoother (τ 0.03 s in the hand) and the object dead zone.
    static let followTauCarrying: Float = 0.08
    static let followTauRelocate: Float = 0.35
    static let followRelocateSpeed: Float = 0.6
    /// **In-hand relocation (V3-1b §6).** A device in a hand is not a card that was moved across a desk while
    /// nobody was looking: the wearer is holding the thing the card belongs to, and a 0.35 s speed-limited glide
    /// reads as the card being *lost* (the V3-1 trial glided 11.7 cm over 3.60 s while the passport was in a
    /// hand). Under `handRelocateMin` the thaw is an ordinary retarget; above it the glide keeps the τ of a hand
    /// follow, drops the speed limit and says nothing when it lands.
    static let handRelocateMin: Float = 0.05
    static let followTauRelocateHand: Float = 0.10
    /// `--carry-lead <s>`: the follower is retargeted this far along the measured raw velocity while the device
    /// is carried (0 disables). The extrapolation is capped so a tracking glitch cannot throw the card.
    var carryLead: Float = 0.05
    static let carryLeadMaxDistance: Float = 0.04

    private static func followTau(for presence: PresenceGate.Presence) -> Float {
        if case .carrying = presence { return followTauCarrying }
        return followTauExpanded
    }

    /// One rendered frame of the pose follower (`EngineTickComponent` on `followerDriver`). Preview mode parks
    /// `anchorRoot` itself every frame, so the driver stays out of its way.
    private func stepFollower(dt: Float) {
        // **V3-3 C1 / C3.** Which angle the card is being seen at is a property of the *drawn* frame, not of
        // the follower — so it is read before the preview guard, and `--preview` (which parks `anchorRoot`
        // itself every frame and never reaches the follower) gets the rim's Fresnel too.
        //
        // **V3-4 §10**: each of the four per-frame steps is timed while the hand-form probe is armed, so the
        // 45 fps morph and the 85–90 fps steady state can be attributed to a named step rather than guessed
        // at from a single frame-time number.
        let angleStart = stepClock
        stepAngleVisuals(dt: dt)
        noteStepTime(\.angleVisuals, since: angleStart)
        // v4 B1: the hero card's own frame (entrance / idle, the reveal's dissolve, the billboard's blend).
        stepV4(dt: dt)
        // v4 B2 §3.3: a grab loss that has gone on long enough folds the card into the device's last position.
        stepPickupFold(dt: dt)
        // v4 B4 §3.4: the gallery's trails rest when their cards do.
        stepDeskNoteTrails(dt: dt)
        // v4 B4 §3.5: `cmd perf` holds its `off` layers out of the tree whatever the choreography does.
        if perf.holdsAnyLayer { enforcePerfSwitches() }
        guard !previewActive, hasPose else { return }
        follower.step(dt: dt)
        // Position + orientation rather than `transform`: `anchorRoot`'s scale stays whatever it is (1).
        anchorRoot.position = follower.position
        anchorRoot.orientation = follower.rotation
        if relocating { relocateElapsed += min(PoseFollower.maxStep, max(0, dt)) }
        if follower.arrived, !followerWasArrived {
            let hook = onFollowerArrival
            onFollowerArrival = nil
            hook?()
        }
        followerWasArrived = follower.arrived
        let handFormStart = stepClock
        stepHandForm(dt: dt)
        noteStepTime(\.handForm, since: handFormStart)
    }

    /// One rendered frame of the hand form (v3 H2 §2 / §3): which way the card faces, and whether it is moving
    /// fast enough to leave a trail. Both are per-frame because both follow the *device*, which the pose
    /// follower is moving underneath the card — there is no tween to hang them off.
    private func stepHandForm(dt: Float) {
        guard isHandForm, hologram.isEnabled else {
            if handTrailOn { setHandTrail(false) }
            return
        }
        defer { syncHingeGroup(dt: dt) }
        // v4 B4 §1: the hand reveal holds the hinge at the outline's angle until the card is in and the outline is gone.
        if handRevealHingeFrozen, handRevealIsOver { releaseHandRevealHinge() }
        // The entry spring, the unfold and a page flip all own `cardGroup` while they run; the facing picks up
        // where they leave it rather than fighting them for the same transform.
        if cardGroup.components[TweenComponent.self] == nil, !handRevealHingeFrozen {
            let target: simd_quatf
            if handForm == .hinge {
                // Only the hinge angle follows the eyes: yaw and roll are the device's, so turning the
                // passport turns the card exactly as a real flip-open cover would. **B0b**: it is written to
                // the *arm*, and the direction to the eyes is taken from where the card actually is — on an
                // arc about the hinge, not at a fixed point above it. (Opening the cover moves the card both
                // up and toward the wearer, which *lowers* the angle it wants: negative feedback, so the
                // fixed point this iterates toward is stable.)
                let weight = handFacing == .hinged ? HandFacing.hingeWeight : handFacing.weight
                let card = hingeRotation.act(hingeCardPosition)
                let rest = HandFacing.hinged(weight: weight, card: card, head: headInHinge())
                hingeRotation = HandFacing.step(current: hingeRotation, target: rest,
                                                dt: dt, tau: Self.handFacingTau)
                // The card itself stays square on the arm.
                target = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
            } else {
                let head = headPoseProvider?().map { world -> SIMD3<Float> in
                    let p = SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
                    return anchorRoot.convert(position: p, from: nil)
                }
                target = HandFacing.orientation(mode: handFacing, card: cardGroup.position, head: head)
            }
            cardGroup.orientation = HandFacing.step(current: cardGroup.orientation, target: target,
                                                    dt: dt, tau: Self.handFacingTau)
        }
        let speed = simd_length(follower.velocity)
        if handTrailOn, speed < Self.handTrailOffSpeed {
            setHandTrail(false, speed: speed)
        } else if !handTrailOn, speed > Self.handTrailOnSpeed {
            setHandTrail(true, speed: speed)
        }
    }

    // MARK: - Angle visuals (V3-3 C1 / C2 / C3, plan §4 E14)

    /// How long the two sides take to trade places. (The thresholds themselves are `BackFaceFlip`'s.)
    static let backFaceFade: Float = 0.2

    /// **C2**: the card's face used to be one holder, and the choreography wrote to it by name — the ink
    /// reveal hides it and fades it up, the fold takes it down, the unfold brings it back, `resetCardLayers`
    /// squares it away. Every one of those writes goes through here now, so the three sheets are one card
    /// and there is no path that can fade the plate's type without its avatar.
    private func setCardFace(_ write: (Entity) -> Void) {
        write(cardAttachmentHolder)
        write(cardTagsHolder)
        write(cardAvatarHolder)
    }

    /// Put the three sheets at their depths. Called once at build time and again whenever `--parallax`
    /// changes; `off` collapses all three onto the base z, which is V3-2b's single attachment.
    private func layoutCardLayers() {
        cardAttachmentHolder.position = [0, 0, CardLayers.z(.base, parallax: parallaxEnabled)]
        cardTagsHolder.position = [0, 0, CardLayers.z(.tags, parallax: parallaxEnabled)]
        cardAvatarHolder.position = [0, 0, CardLayers.z(.avatar, parallax: parallaxEnabled)]
    }


    /// One rendered frame of "which angle is this card being seen at": **C1's** Fresnel rim and **C3's** flip
    /// to the back face, both off the same dot product so the two can never disagree about where the card is
    /// pointing. Cheap by construction — one matrix read, one dot, and a component write only when the number
    /// actually moved.
    private func stepAngleVisuals(dt: Float) {
        guard let (normal, view) = cardFacing() else {
            cardFacingDot = nil
            return
        }
        cardFacingDot = simd_dot(normal, view)
        // C1: through `PulseComponent.baseOpacity`, never by rebuilding the material. The pulse system
        // re-derives `OpacityComponent` from this base every frame (and stands down while a tween owns the
        // rim, which is exactly the behaviour the reveal and the fold already rely on). **v4 B1**: no v3 rim —
        // the hero card's edge light is its own (A1's crystal per pixel, or A4's placeholder from the same curve).
        if fresnelEnabled, v4 == nil, var pulse = rim.components[PulseComponent.self] {
            let target = RimFresnel.opacity(normal: normal, view: view)
            if abs(pulse.baseOpacity - target) > 0.0005 {
                pulse.baseOpacity = target
                rim.components.set(pulse)
            }
        }
        let backFaceStart = stepClock
        stepBackFace()
        noteStepTime(\.backFace, since: backFaceStart)
    }

    /// **C3 / plan §4 E14c.** The flip. One number, two thresholds: the card's face has to be pointing more
    /// than 100° away before its back comes up, and back inside ≈ 93° before the front returns.
    ///
    /// Only the hand can reach it — on the desk the billboard keeps the card square to the reader, so the
    /// dot never goes near zero, let alone past −0.17. That is a property of the geometry, not a guard: a
    /// run with `--face-user off` on the desk can turn the card over and will get its back, correctly.
    private func stepBackFace() {
        guard backFaceEnabled, let dot = cardFacingDot, let change = backFace.update(facing: dot) else { return }
        crossFadeCardSides(change)
    }

    /// Cross-fade the card's two sides over 0.2 s. The **group** carries the fade, not the three sheets —
    /// so the reveal's and the fold's own writes to them (`setCardFace`) keep working underneath, and the
    /// two opacities multiply the way the auditor already reads them.
    private func crossFadeCardSides(_ change: BackFaceFlip.Change) {
        let shown = change == .toBack
        func opacity(of entity: Entity) -> Float { entity.components[OpacityComponent.self]?.opacity ?? 1 }
        cardFaceGroup.components.set(TweenComponent(opacity: (from: opacity(of: cardFaceGroup), to: shown ? 0 : 1),
                                                    duration: Self.backFaceFade, easing: .easeInOutCubic))
        // v4 B5 §3: the back is in the tree only while it is (becoming) visible.
        let backFrom: Float = cardBackHolder.isEnabled ? opacity(of: cardBackHolder) : 0
        if shown { cardBackHolder.isEnabled = true }
        cardBackHolder.components.set(TweenComponent(opacity: (from: backFrom, to: shown ? 1 : 0),
                                                     duration: Self.backFaceFade, easing: .easeInOutCubic,
                                                     disableWhenDone: !shown))
        print("[reveal] \(shown ? "back" : "front") face")
    }

    /// Every path that squares the card away goes through `resetCardLayers`, and every one of them has to
    /// put the card back on its front: one that folded while the wearer was reading its QR would otherwise
    /// come back with `cardFaceGroup` at opacity 0 — an invisible card with a working tap target.
    private func resetBackFace() {
        cardFaceGroup.components.remove(TweenComponent.self)
        cardBackHolder.components.remove(TweenComponent.self)
        cardFaceGroup.components.set(OpacityComponent(opacity: 1))
        cardBackHolder.components.set(OpacityComponent(opacity: 0))
        cardBackHolder.isEnabled = false
        guard backFace.reset() != nil else { return }
        print("[reveal] front face (card reset)")
    }

    /// The card's own normal (its local +Z, the face the attachment layers are on) and the direction from the
    /// card to the wearer's eyes, both unit length and both in world space. Nil when there is nothing to
    /// measure: no head pose yet, or no card on screen.
    ///
    /// On the desk `cardGroup` carries a `BillboardComponent`, which RealityKit applies at draw time without
    /// writing the rotation back — so what this returns there is the *authored* normal, which points at the
    /// reader anyway. That is the plan's "billboard makes it ≈ constant"; in the hand, where the card is
    /// rigidly on the hinge arm, the number is exact.
    private func cardFacing() -> (normal: SIMD3<Float>, view: SIMD3<Float>)? {
        // `isEnabledInHierarchy`, not `hologram.isEnabled`: inside a world the card hangs off `miniHolder`
        // instead, and while it is folded away the whole hologram is disabled above it. One question covers
        // both — is this card on screen at all.
        guard cardGroup.isEnabledInHierarchy, let head = headPoseProvider?() else { return nil }
        let m = cardGroup.transformMatrix(relativeTo: nil)
        let normal = SIMD3<Float>(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        let centre = SIMD3<Float>(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let view = eye - centre
        let nl = simd_length(normal), vl = simd_length(view)
        guard nl > 1e-6, vl > 1e-4, nl.isFinite, vl.isFinite else { return nil }
        return (normal / nl, view / vl)
    }

    /// The card's pixie dust, and — **V3-2b B2** — the deck's, on the same hysteresis: one hand, one rule.
    /// `speed` is given only by the hysteresis itself, so the log carries the number that decided it and the
    /// forced calls (a settle, a fold, a world) stay silent.
    private func setHandTrail(_ on: Bool, speed: Float? = nil) {
        handTrailOn = on
        handTrail.isEnabled = on || handTrail.isEnabled
        var trail = handTrail.components[NoteTrailComponent.self]
            ?? NoteTrailComponent(target: cardGroup, birthRate: Self.handTrailBirthRate)
        trail.birthRate = Self.handTrailBirthRate
        trail.forceFlying = on
        handTrail.components.set(trail)
        if notes.deckOut { setDeckTrails(on) }
        if let speed { print(String(format: "[hand] trail %@ (%.2f m/s)", on ? "on" : "off", speed)) }
        if !on {
            // The sparks already in the air outlive the card by their own life span; the emitter itself is
            // parked a beat later so nothing is cut off mid-flight.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(900))
                guard let self, !self.handTrailOn else { return }
                self.handTrail.isEnabled = false
                // v4 B2: the deck's seven trails go the same way (they were left enabled — `emitting` at 0/s —
                // for as long as the deck stood in the hand: `trail.deck×2, trail.note×5` in every round-1 window).
                if self.notes.deckOut { self.parkIdleDeckTrails() }
            }
        }
    }

    // MARK: - Footprint audit (V3-2a H0)

    /// The real device's size in the screen frame, from the object anchor's own bounding box. Everything the
    /// H0 rule sizes — the light well's edge glow, the socket ring, the desk annulus' hole, the projector's
    /// origins — is rebuilt from it, so `--fake-box scan` and a future device are handled by the same code.
    func setDeviceFootprint(width: Float, length: Float, thickness: Float = 0.0085) {
        let size = SIMD2<Float>(max(0.01, width), max(0.01, length))
        let depth = max(0.001, thickness)
        guard size != deviceFootprint.size || depth != deviceThickness else { return }
        deviceFootprint.size = size
        deviceThickness = depth
        auditor.footprint = deviceFootprint
        well.configure(device: size, caseCenter: caseCenter)
        overlay.configure(device: size, caseCenter: caseCenter)
        projector.configure(device: size, caseCenter: caseCenter)
        // S1: the wireframe *is* the anchor box, so it is re-cut with it (in C; it contracts onto the screen at
        // the LCD's offset on the case).
        boxScan.configure(box: [size.x, depth, size.y], screen: footprint, screenCenter: deviceFootprint.lcdCenter)
        buttonWave.configure(footprint: deviceFootprint)
        // V3-4 §7: the contact light sits on the measured device's own top edge, 4 mm beyond the prism.
        hingeGlowStrip.model?.mesh = .generatePlane(width: size.x * 0.9, depth: 0.003)
        hingeGlowStrip.position = [0, 0.002, -(deviceFootprint.half.y + 0.004)]
        layoutButtonGlints()
        configureHalo()
        handPivot.position = hingePosition
        // v4 B3: the gold point stands beside the measured case's own top edge.
        layoutGoldPoint()
        print(String(format: "[footprint] device %.1f × %.1f × %.1f mm (+ %.0f mm margin)",
                     size.x * 1000, size.y * 1000, depth * 1000, deviceFootprint.margin * 1000))
    }

    /// Where the hinge stands in `hologram` space (S), from the device's own measured length: on the **case's** top
    /// edge (v4 B1 — `caseCenter` is where the case is in S; v3 put it at S's origin ± half a length).
    var hingePosition: SIMD3<Float> {
        caseCenter + [0, Self.hingeLift, -(deviceFootprint.size.y / 2 + Self.hingeClearance)]
    }

    /// The card's resting place **on the arm**: its bottom edge on the hinge (the arm's origin), so its
    /// centre is half a card up. `HandDeckLayout.cardTop` is the same number doubled (for v3's 0.27 m card; the
    /// v4 hero card is 0.28 m tall, and the deck is lifted by the difference — `deckLift`).
    var hingeCardPosition: SIMD3<Float> { [0, cardSize.y * handScale / 2, 0] }

    /// v4 B1: how far the hand deck is raised above `HandDeckLayout`'s slots, which are struck for v3's 0.27 m card —
    /// so the raised card keeps its 5 mm over the taller hero card and the fan the same band above its top edge.
    var deckLift: Float { (cardSize.y - HologramLayout.cardHeight) * handScale }

    /// **V3-2b B0b.** Put the arm at the hinge angle. Everything the hand holds — the card, mounted on the
    /// arm, and the deck, whose slots are struck in the arm's frame and converted across once a frame — turns
    /// with it about the device's own top edge.
    ///
    /// `rotation` is a choreography writing the card's *resting* angle: the deck then aims at the pose the
    /// card is arriving in rather than at the one it is leaving. With no argument the arm keeps the angle
    /// `stepHandForm` last wrote (and goes flat whenever the card is not on it at all).
    func syncHingeGroup(_ rotation: simd_quatf? = nil, dt: Float? = nil) {
        if let rotation {
            hingeRotation = rotation
        } else if cardGroup.parent !== hingeGroup {
            hingeRotation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        // …and otherwise `hingeRotation` is whatever the facing tick put there (or the destination a running
        // tween was given): the arm *is* the angle now, so there is nothing to mirror off the card.
        hingeGroup.orientation = hingeRotation
        followDeckToHinge(dt: dt)
    }

    /// Put the hinge frame where the device says it is. Split out of `attachCardToHinge` because the arm has
    /// to be placed **before** the resting angle is computed (`headInHinge` reads `handPivot`).
    func placeHandPivot() {
        handPivot.position = hingePosition
        handPivot.orientation = HandFacing.base
        handPivot.isEnabled = true
    }

    /// Hand the card (and with it the deck) to the hinge arm, without moving anything on screen. The arm is
    /// expected to be **already** at the angle the card is arriving in — a caller that sets it afterwards
    /// would swing the card through that angle in one frame.
    func attachCardToHinge() {
        placeHandPivot()
        hingeGroup.orientation = hingeRotation
        guard cardGroup.parent !== hingeGroup else { return }
        cardGroup.setParent(hingeGroup, preservingWorldTransform: true)
    }

    /// Give the card back to `hologram` (the desk, the fold): again without moving anything on screen, so
    /// whatever tween runs next starts from the values that are actually on screen.
    func detachCardFromHinge() {
        guard cardGroup.parent === hingeGroup else { return }
        cardGroup.setParent(hologram, preservingWorldTransform: true)
    }

    /// **V3-2b B2.** One five-second frame probe per hand session, armed a second after the card reaches the
    /// hinge so the entry spring's own cost is not what it measures. The budget is ≥ 90 fps with seven
    /// followers, seven trails and the card's own.
    // MARK: - Perf probes (V3-4 §10 follow-up)

    /// One carrier entity per probe label, hung off `root` (never disabled, never audited — they have no
    /// mesh and they are not under `anchorRoot`).
    ///
    /// **Why they need one each.** `PerfProbeComponent` is a component, and an entity holds one component of
    /// a type. All four of the fan's probes used to live on `notes.group`: the desk fan-out arms a 1.2 s
    /// probe, the wearer picks the passport up ~1.1 s later, `morphGalleryToDeck` sets the pick-up morph's
    /// probe on the **same entity** — and `[perf] desk fan out` is gone before it ever reported. That is
    /// exactly what the desk-hand-desk smoke showed: `[notes] fan out 10 cards` with no `[perf]` line after it.
    ///
    /// `carrier` (v4 B4 §3.5): the carrier's key when it is not the label — `cmd perf` prints a different label after
    /// every switch, and one carrier per label would leave an empty entity behind for each state the director tried
    /// (the scene line would creep up by one per command, in a tool whose whole point is comparing scene lines).
    private var probeCarriers: [String: Entity] = [:]

    func startPerfProbe(_ label: String, duration: Float, reportsScene: Bool = false, carrier key: String? = nil) {
        let key = key ?? label
        let carrier: Entity
        if let existing = probeCarriers[key] {
            carrier = existing
        } else {
            carrier = Entity()
            carrier.name = "perf.\(key)"
            root.addChild(carrier)
            probeCarriers[key] = carrier
        }
        carrier.components.set(PerfProbeComponent(label: label, duration: duration, reportsScene: reportsScene))
    }

    /// v4 B1: drop a probe still in flight (its scene changed under it — e.g. the desk-idle window when the passport
    /// is picked up inside it). Returns whether one was running.
    @discardableResult
    func cancelPerfProbe(_ label: String) -> Bool {
        guard let carrier = probeCarriers[label], carrier.components.has(PerfProbeComponent.self) else { return false }
        carrier.components.remove(PerfProbeComponent.self)
        return true
    }

    /// v4 B1: a probe still in flight whose scene got longer (or shorter) under it — the hand-over hold. The window's
    /// duration changes by `seconds`; nothing else about it does.
    func extendPerfProbe(_ label: String, by seconds: Float) {
        guard let carrier = probeCarriers[label], var probe = carrier.components[PerfProbeComponent.self] else { return }
        probe.duration = max(probe.elapsed, probe.duration + seconds)
        carrier.components.set(probe)
    }

    // MARK: - Per-step timing (V3-4 §10)

    /// Microseconds spent in each of the four per-frame steps while the hand-form probe is armed.
    struct StepTimes {
        var angleVisuals: Double = 0
        var handForm: Double = 0
        var deckDynamics: Double = 0
        var backFace: Double = 0
        var worstAngleVisuals: Double = 0
        var worstHandForm: Double = 0
        var worstDeckDynamics: Double = 0
        var worstBackFace: Double = 0
        var frames = 0
    }

    private var stepTimes = StepTimes()
    private var stepTimingOn = false
    private var stepClock: Double { CFAbsoluteTimeGetCurrent() }

    /// One step's time, in the accumulator the `hand form 5 s` line reports.
    func noteStepTime(_ key: WritableKeyPath<StepTimes, Double>, since start: Double) {
        guard stepTimingOn else { return }
        let micros = (CFAbsoluteTimeGetCurrent() - start) * 1_000_000
        guard micros.isFinite, micros >= 0 else { return }
        stepTimes[keyPath: key] += micros
        switch key {
        case \.angleVisuals: stepTimes.worstAngleVisuals = max(stepTimes.worstAngleVisuals, micros)
        case \.handForm: stepTimes.worstHandForm = max(stepTimes.worstHandForm, micros)
        case \.deckDynamics: stepTimes.worstDeckDynamics = max(stepTimes.worstDeckDynamics, micros)
        case \.backFace: stepTimes.worstBackFace = max(stepTimes.worstBackFace, micros)
        default: break
        }
        if key == \.angleVisuals { stepTimes.frames += 1 }
    }

    private func startStepTiming() {
        stepTimes = StepTimes()
        stepTimingOn = true
    }

    /// The companion to `[perf] hand form 5 s`: which of the four steps the frame time went into.
    private func reportStepTiming() {
        guard stepTimingOn else { return }
        stepTimingOn = false
        let n = Double(max(1, stepTimes.frames))
        print(String(format: "\(PerfLog.prefix) hand form steps (avg/worst µs per tick): fresnel %.0f/%.0f · handForm %.0f/%.0f · deckDynamics %.0f/%.0f · backFace %.0f/%.0f",
                     stepTimes.angleVisuals / n, stepTimes.worstAngleVisuals,
                     stepTimes.handForm / n, stepTimes.worstHandForm,
                     stepTimes.deckDynamics / n, stepTimes.worstDeckDynamics,
                     stepTimes.backFace / n, stepTimes.worstBackFace))
    }

    /// **V3-5 §5.** One 5 s window every 10 s for as long as the passport is in the hand, numbered.
    ///
    /// V3-4 armed the probe once per hand session, and six minutes on the headset produced **three**
    /// windows — one of which (44.3 fps, 218 of 222 frames over 13.3 ms) is the whole reason the next round
    /// is an `xctrace` capture. Three samples cannot say whether that was the pick-up, the deck, a prebuild
    /// or the ring. A window every ten seconds can, and a run of numbered windows is also what a trace has
    /// to be lined up against.
    private func armHandFormProbe() {
        guard !handPerfArmed else { return }
        handPerfArmed = true
        handPerfTask?.cancel()
        handPerfTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            var window = 0
            while !Task.isCancelled {
                guard let controller = self, controller.isHandForm else { return }
                window += 1
                controller.followerDriver.components.set(PerfProbeComponent(label: "hand form 5 s #\(window)",
                                                                            duration: 5, reportsScene: true))
                // V3-4 §10: the per-step breakdown runs over the same five seconds and reports right after it.
                controller.startStepTiming()
                try? await Task.sleep(for: .milliseconds(5100))
                guard !Task.isCancelled else { return }
                controller.reportStepTiming()
                // …and the next window starts five seconds later, i.e. one every ten.
                try? await Task.sleep(for: .milliseconds(4900))
            }
        }
    }

    /// The card has left the hand (a settle, a fold, a world): the next hand session gets its own probe.
    private func disarmHandFormProbe() {
        handPerfTask?.cancel()
        handPerfTask = nil
        handPerfArmed = false
        stepTimingOn = false
        followerDriver.components.remove(PerfProbeComponent.self)
    }

    /// The desk annulus' hole has to clear the footprint, so it is rebuilt with the device.
    private func configureHalo() {
        haloDisc.components.set(FootprintProbeComponent(.circularHole(Self.haloInner * Self.haloDiameter / 2)))
    }

    /// A brief effect is about to cross the screen on purpose (the ink cinematic's first rise, the fold, the
    /// unfold): the audit stands down for its duration rather than reporting it as a state.
    func pauseFootprintAudit(_ seconds: Float, reason: String) {
        guard footprintCheck else { return }
        auditor.pause(seconds, reason: reason)
    }

    private func stepFootprintAudit(dt: Float) {
        guard footprintCheck else { return }
        // v4 B1: measured in the case frame — the prism is the case, the LCD hard zone sits at its offset in it.
        auditor.step(dt: dt, roots: [anchorRoot, surface], space: caseRoot)
    }

    /// Tracked pose. Ignored while held (the frozen pose *is* the hold, and an in-flight glide keeps running in
    /// the tick); a pending thaw glide kind is consumed here.
    func apply(pose: simd_float4x4, source: TrackingFusion.Source = .image, velocity: SIMD3<Float> = .zero) {
        previewActive = false
        lastPoseSource = source
        devicePlaceholder.isEnabled = false
        guard pendingGlide != nil || !currentPresence.isHeld else { return }
        let target = Transform(matrix: pose)
        if hasPose, let last = lastAppliedPose {
            let (distance, angle) = PresenceGate.delta(from: last, to: pose)
            let deadZone = source == .object ? HologramController.poseDeadZoneObject : HologramController.poseDeadZone
            let deadZoneAngle = source == .object ? HologramController.poseDeadZoneObjectAngle
                                                 : HologramController.poseDeadZoneAngle
            if distance < deadZone && angle < deadZoneAngle {
                // Inside the dead zone: do not even retarget. This is what removes the shimmy — the dead zone now
                // gates *retargeting*, not an animation restart. A thaw this small has already arrived, so its
                // glide is dropped rather than left to fire on a later pose — but a return-from-world light that
                // was deferred to the landing has to be paid: the card is already standing on it.
                if case .relocate(_, _, true, _)? = pendingGlide { playReturnFromWorldLight(reason: "no glide left") }
                pendingGlide = nil
                return
            }
        }
        let glide = pendingGlide
        pendingGlide = nil
        guard hasPose else {
            // First pose of the session, or the first after a hide / preview: be there, do not fly in from the
            // place the card used to be. A snap *is* the landing, so a deferred return-from-world light plays now.
            if case .relocate(_, _, true, _)? = glide { playReturnFromWorldLight(reason: "snapped into place") }
            endRelocation()
            follower.snap(position: target.translation, rotation: target.rotation)
            anchorRoot.position = follower.position
            anchorRoot.orientation = follower.rotation
            followerWasArrived = true
            hasPose = true
            lastAppliedPose = pose
            return
        }
        if case .relocate(let distance, let cue, let worldLight, let hand)? = glide {
            beginRelocation(distance: distance, cue: cue, worldLight: worldLight, hand: hand)
        } else if !relocating {
            follower.tau = HologramController.followTau(for: currentPresence)
            follower.maxSpeed = .infinity
        }
        // V3-1b §7: velocity feed-forward. The smoother and the follower each lag a moving device by v·τ; leading
        // the target by the measured raw velocity pays part of that back without tightening either filter (which
        // is what would make the card twitch when the device is standing still — at rest v is millimetres per
        // second and the lead is invisible). Carry only: on the desk there is nothing to lead.
        follower.retarget(position: target.translation + carryLeadOffset(velocity: velocity),
                          rotation: target.rotation)
        lastAppliedPose = pose
    }

    /// How far ahead of the pose the follower is aimed, given the tracker's raw velocity.
    private func carryLeadOffset(velocity: SIMD3<Float>) -> SIMD3<Float> {
        guard carryLead > 0, currentPresence.isCarrying else { return .zero }
        var lead = velocity * carryLead
        guard lead.x.isFinite, lead.y.isFinite, lead.z.isFinite else { return .zero }
        let distance = simd_length(lead)
        if distance > HologramController.carryLeadMaxDistance {
            lead *= HologramController.carryLeadMaxDistance / distance
        }
        return lead
    }

    /// The card is somewhere else: glide there slowly and speed-limited, and answer the landing when the follower
    /// reports it has arrived (rather than after a duration guessed up front).
    ///
    /// `hand` is the V3-1b case: the device is in the wearer's hand, where a speed-limited 0.35 s crawl reads as
    /// the card having come unstuck from it. The glide keeps a hand follow's τ, is not speed-limited, and lands
    /// silently — the card simply catches up with the passport.
    private func beginRelocation(distance: Float, cue: Bool, worldLight: Bool, hand: Bool) {
        follower.tau = hand ? HologramController.followTauRelocateHand : HologramController.followTauRelocate
        follower.maxSpeed = hand ? .infinity : HologramController.followRelocateSpeed
        relocating = true
        relocateElapsed = 0
        relocationHand = hand
        relocationCue = cue
        relocationWorldLight = worldLight
        followerWasArrived = false
        print(String(format: "[follow] relocate %.1f cm τ=%.2f%@", distance * 100, follower.tau, hand ? " (hand)" : ""))
        onFollowerArrival = { [weak self] in
            guard let self else { return }
            print(String(format: "[follow] arrived after %.2f s", self.relocateElapsed))
            let cue = self.relocationCue, worldLight = self.relocationWorldLight
            self.endRelocation()
            self.onRelocationLanded?()
            // The card came back from a world *and* somewhere else: the return light belongs on the card the
            // wearer is looking at, not on the place it just left. It replaces the landing ripple (it has a
            // bigger one of its own), which is why `cue` is false whenever this is true.
            if worldLight {
                self.playReturnFromWorldLight(reason: "on the landed card")
                return
            }
            guard cue, self.revealMayContinue, self.hologram.isEnabled else { return }
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint,
                             startScale: 0.1, endScale: 0.9, duration: 0.7, peak: 0.6)
            self.audio.play(.settle, on: self.anchorRoot)
        }
    }

    /// The one place the return-from-world light is played, so the immediate and the deferred paths cannot drift
    /// apart. Silent when the card is not on screen (a hide cancelled the glide before it landed).
    private func playReturnFromWorldLight(reason: String) {
        owesReturnFromWorldLight = false
        guard revealMayContinue, hologram.isEnabled else { return }
        print("[reveal] return-from-world light (\(reason))")
        replayAfterWorld()
    }

    /// **V3-2a H1.** A relocation is started with the parameters of the state the card was in when the thaw
    /// arrived — and the headset showed what that costs: a 12 cm desk glide (τ 0.35, capped at 0.6 m/s) was
    /// still running 137 ms later when the passport was picked up, so the card crawled after the hand for
    /// 3.81 s and Σ read `lag=157mm`. Every presence change now re-asks which regime the glide is in.
    ///
    /// Under `handRelocateMin` in the hand there is nothing left to glide: the card simply catches up on the
    /// next pose, which is exactly what `runThaw` would have done had the pick-up come one frame earlier.
    func retuneRelocationForPresence() {
        guard relocating else { return }
        let hand = isHandForm || (currentPresence.isCarrying && lastPoseSource == .object)
        guard hand != relocationHand else { return }
        let remaining = follower.distanceToTarget
        if hand, remaining < HologramController.handRelocateMin {
            print(String(format: "[follow] relocate ended in the hand (%.1f cm left)", remaining * 100))
            let worldLight = relocationWorldLight
            endRelocation()
            if worldLight { playReturnFromWorldLight(reason: "picked up mid-glide") }
            return
        }
        relocationHand = hand
        follower.tau = hand ? HologramController.followTauRelocateHand : HologramController.followTauRelocate
        follower.maxSpeed = hand ? .infinity : HologramController.followRelocateSpeed
        // A landing chime belongs to a card settling on a desk, not to one catching up with a moving hand.
        if hand { relocationCue = false }
        print(String(format: "[follow] relocate retuned → %@ τ=%.2f (%.1f cm left)",
                     hand ? "hand" : "desk", follower.tau, remaining * 100))
    }

    /// Back to the presence time constant, no speed limit, no pending landing.
    private func endRelocation() {
        relocating = false
        relocateElapsed = 0
        onFollowerArrival = nil
        follower.tau = HologramController.followTau(for: currentPresence)
        follower.maxSpeed = .infinity
    }

    /// The next pose snaps instead of gliding: after a hide or a reentry the old spot means nothing.
    func resetFollower() {
        hasPose = false
        lastAppliedPose = nil
        pendingGlide = nil
        endRelocation()
    }

    /// World pose for the desk effects: directly under the image, at the detected desk height, rotated to match the
    /// image's yaw so the style orbs sit on the reader's side. Frozen while the device is carried or the pose is held.
    func applySurface(under pose: simd_float4x4, surfaceY: Float) {
        if case .carrying = currentPresence, hasSurfacePose { return }
        if currentPresence.isHeld, hasSurfacePose { return }
        let p = SIMD3<Float>(pose.columns.3.x, surfaceY + 0.0015, pose.columns.3.z)
        var forward = SIMD3<Float>(pose.columns.2.x, 0, pose.columns.2.z)
        if simd_length(forward) < 0.01 { forward = [0, 0, 1] }
        let yaw = atan2(forward.x, forward.z)
        let target = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: yaw, axis: [0, 1, 0]), translation: p)
        if hasSurfacePose {
            surface.move(to: target, relativeTo: nil, duration: 0.3, timingFunction: .easeInOut)
        } else {
            surface.transform = target
            hasSurfacePose = true
        }
    }

    /// Preview mode: park the virtual device in front of the user (default ~0.6 m away at desk height), no tracking involved.
    func applyPreviewPose(surfaceHeight: Float = HologramLayout.previewSurfaceHeight, distance: Float = HologramLayout.previewDistance) {
        guard !previewActive else { return }
        previewActive = true
        hasPose = false
        hasSurfacePose = false
        devicePlaceholder.isEnabled = true
        let pose = Transform(translation: [0, surfaceHeight, -distance])
        anchorRoot.transform = pose
        // The driver skips preview frames, but snap anyway so leaving preview never glides in from a stale spot.
        endRelocation()
        follower.snap(position: pose.translation, rotation: pose.rotation)
        followerWasArrived = true
        lastAppliedPose = pose.matrix
        hasPose = true
        applySurface(under: pose.matrix, surfaceY: surfaceHeight - CardTracker.fallbackDeviceThickness)
    }

    func leavePreview() {
        guard previewActive else { return }
        previewActive = false
        devicePlaceholder.isEnabled = false
        resetFollower()
        hasSurfacePose = false
    }

    /// Floating hint: ~1 m in front of the head, a little below eye level, easing toward new positions.
    func setHint(visible: Bool, devicePose: simd_float4x4?) {
        guard visible else {
            if hintHolder.isEnabled, hintHolder.components[TweenComponent.self] == nil {
                hintHolder.components.set(TweenComponent(scale: (from: [1, 1, 1], to: [0.94, 0.94, 0.94]), opacity: (from: 1, to: 0), duration: 0.18, easing: .easeInCubic, disableWhenDone: true))
            }
            return
        }
        let target: SIMD3<Float>
        if let d = devicePose {
            let eye = SIMD3<Float>(d.columns.3.x, d.columns.3.y, d.columns.3.z)
            var forward = -SIMD3<Float>(d.columns.2.x, d.columns.2.y, d.columns.2.z)
            forward.y = 0
            if simd_length(forward) < 0.01 { forward = [0, 0, -1] }
            forward = simd_normalize(forward)
            target = eye + forward * 1.0 + SIMD3<Float>(0, -0.18, 0)
        } else {
            // No head pose yet (session not started: unsupported / permission denied / simulator): park the hint
            // 1 m ahead of the launch origin at eye height so the message — and its 退出 button — is still reachable.
            target = [0, 1.35, -1.0]
        }
        if hintHolder.isEnabled {
            hintHolder.move(to: Transform(translation: target), relativeTo: nil, duration: 0.5, timingFunction: .easeInOut)
        } else {
            hintHolder.position = target
            hintHolder.isEnabled = true
            hintHolder.components.set(TweenComponent(scale: (from: [0.92, 0.92, 0.92], to: [1, 1, 1]), opacity: (from: 0, to: 1), duration: 0.28, easing: .easeOutCubic))
        }
    }

    // MARK: - Presence

    /// Every presence change from the gate arrives here, in order, with the transition that carries it.
    /// `firstAcquire` = the session's (or replay's) first detection: the acquire glint plays only then.
    /// Returns **true** when the recognition scan is holding this transition back until its convergence
    /// beat, so the caller's own half of the same event (`AppModel.noteCard`, which raises the deck) can
    /// wait with it instead of running under the wireframe.
    @discardableResult
    func apply(presence: PresenceGate.Presence, transition: PresenceGate.Transition?, hideKind: PresenceGate.HideKind? = nil,
               firstAcquire: Bool = false, resumeFromWorld: Bool = false, animated: Bool = true) -> Bool {
        let previous = currentPresence
        guard presence != previous || transition != nil else { return false }
        // Safety net: every choreography below assumes the card hangs under `hologram` at the desk. Nothing
        // normally reaches here while the card is a mini card (the gate holds inside a world and `ImmersiveView`
        // forwards nothing), but a `cmd hide` / teardown that did would fold a card that is not there.
        if isMiniCard, transition != nil { leaveMiniCard(animated: false) }
        currentPresence = presence
        // v4 B4 §2: a put-down has just settled — for 2 s a hand leaving the passport is letting go of it.
        if previous == .settling, presence == .expanded { notePickupSettled() }
        // **V3-2a2 S1.** A scan owns the first second of a detection: on the headset the unfold follows the
        // first detection by 34 ms, and without this it would run *underneath* the wireframe. The rules are
        // `BoxScanTimeline.Pending`'s, so they are checked in the test target rather than here.
        // **v4 B1 §2**: the ribbon recognition holds entrances exactly like the scan did (the same `Pending`), from
        // its start until its closure beat — not until it is gone (its outline glows on 0.8 s past the closure).
        let recognising = v4?.recognitionHolding == true
        if boxScan.isRunning || recognising,
           let arrival = BoxScanRig.arrival(for: transition, cardOnScreen: hologram.isEnabled) {
            switch scanPending.handle(arrival) {
            case .hold:
                heldIntro = HeldIntro(transition: transition!, label: arrival.intro ?? .cinematic,
                                      previous: previous, firstAcquire: firstAcquire,
                                      resumeFromWorld: resumeFromWorld, animated: animated)
                retuneRelocationForPresence()
                updateParticleRate()
                return true
            case .pass:
                break
            case .drop:
                heldIntro = nil
                if recognising {
                    cancelV4Recognition()
                } else {
                    boxScan.stop(fade: 0.2)
                    print("[reveal] box scan cancelled (hide)")
                }
            }
        }
        runTransition(transition, previous: previous, hideKind: hideKind, firstAcquire: firstAcquire,
                      resumeFromWorld: resumeFromWorld, animated: animated)
        // **V3-6 §1.** After the choreography, so a thaw / carry / reveal has already put the opacity where
        // it wants it and the restore is the last word.
        updateHoldingCue(animated: animated)
        // V3-2a H1: the state the glide was tuned for may have just changed under it.
        retuneRelocationForPresence()
        updateParticleRate()
        return false
    }

    /// One presence transition, run for real. Split out of `apply(presence:…)` so the box scan can hold an
    /// entrance back and hand the very same call to the convergence beat.
    func runTransition(_ transition: PresenceGate.Transition?, previous: PresenceGate.Presence,
                               hideKind: PresenceGate.HideKind?, firstAcquire: Bool,
                               resumeFromWorld: Bool, animated: Bool) {
        let presence = currentPresence
        switch transition {
        case .cinematic?:
            cancelChoreography()
            runReveal(animated: animated)
        case .reentry?:
            cancelChoreography()
            runReentry(animated: animated)
        case .carry?:
            cancelChoreography()
            runCarry(animated: animated)
        case .settle?:
            cancelChoreography()
            runSettle(animated: animated)
        case .freeze?:
            // A reveal in flight keeps going; only the pose stops. A glide granted by an earlier thaw must not fire
            // on a pose that arrives during this hold.
            // v2: a freeze is *visually silent* — losing the image for 0.8 s is normal and must not be advertised.
            // The shimmer is turned on by `.search` alone (3 s of not being seen while in view), and by nothing else.
            pendingGlide = nil
            endRelocation()
            setSearching(false)
        case .search?:
            // The one visible consequence of a lost image, and only after `searchCueAfter`. Printed because
            // "did anything light up while the card was just sitting there?" is the whole M1a question.
            print("[reveal] search shimmer on (\(presence.label))")
            setSearching(true)
        case .thaw(let glide)?:
            runThaw(glide: glide, from: previous, fromWorld: resumeFromWorld, animated: animated)
        case .hide?:
            pendingGlide = nil
            // v4 B2 §3.3: a folded card that is dismissed (or torn down) folds on from the point. v4 B3: a dismiss / replay
            // collapses into that very point, so it stays lit (`collapseIntoPoint` takes it over).
            let wasPoint = pickup.folded && collapsesIntoPoint(hideKind)
            endPickupFold(to: nil, keepPoint: wasPoint)
            if !collapsesIntoPoint(hideKind) { releaseGoldPoint(reason: "hide", animated: animated) }
            pickupWasPointAtHide = wasPoint
            // The card is leaving: a return-from-world light that never landed is simply not owed any more
            // (whatever brings the card back — reentry, replay, cinematic — lights the desk itself).
            owesReturnFromWorldLight = false
            endRelocation()
            cancelChoreography()
            runHide(from: previous, kind: hideKind, animated: animated)
        case nil:
            if presence == .acquiring, previous == .absent {
                let ribbon = firstAcquire && willRecogniseWithRibbon(animated: animated)
                // v4 B4 §1: where this recognition draws the card — on the desk or on the hinge of a passport in the
                // hand — is decided here, once, before anything lights (the ribbon leaves the screen at 0.10 s; the gate
                // says `carrying` / `expanded` up to 158 ms after this). `startV4Recognition` consumes it.
                pendingRecognitionDecision = ribbon ? decideRecognitionPlace() : nil
                if pendingRecognitionDecision?.place == .hand {
                    // The card is coming to the wearer's hand: the desk stays dark (B3 §7 item 5 — a summon in the hand
                    // used to light it for 1.9 s and put it out again at the unfold).
                    print("[v4] the desk stays dark: the card is coming to the hand")
                } else {
                    // v4 B3 §2: a summon's recognition lights the desk the way the session's first one does — the
                    // collapse took the whole surface down (`setDeskFaded`), and `igniteSurface` will not light a faded desk.
                    if ribbon, deskFaded {
                        deskFaded = false
                        fadeDesk(visible: true, animated: animated)
                    }
                    surface.isEnabled = true
                    igniteSurface(level: 0.5, animated: animated)
                }
                // v4 B1: the ribbon's screen burst is the "seen" beat (and plays the acquire chime); v3's white flash
                // and ring over the LCD are only for the v3 path.
                if firstAcquire, !willRecogniseWithRibbon(animated: animated) { playAcquireCue() }
                startBoxScan(firstAcquire: firstAcquire, animated: animated)
            } else if case .held = presence, previous.isHeld {
                // Hold upgraded (stale → button / theme / world) or released into `held(.stale)` by `endHold`:
                // silent in every direction. Only `.search` lights the shimmer.
                setSearching(false)
            }
        }
    }

    // MARK: - The recognition scan (V3-2a2 S1 / plan §4 E1)

    /// First detection (and every summon): draw the wireframe on the real shell before anything virtual
    /// stands up out of it. `firstAcquire` gives the full 1.2 s version; a summon gives the 0.6 s one.
    private func startBoxScan(firstAcquire: Bool, animated: Bool) {
        let summon = summonPending
        summonPending = false
        guard boxScanEnabled, animated, firstAcquire || summon else { return }
        // **v4 B1 §2**: a first detection is recognised by A2's ribbon (a summon keeps v3's 0.6 s short scan).
        if firstAcquire, startV4Recognition() { return }
        let timeline = BoxScanTimeline(full: firstAcquire)
        scanTimeline = timeline
        scanPending = BoxScanTimeline.Pending()
        heldIntro = nil
        // The wireframe is on the hardware on purpose, and it is gone inside 1.2 s: H0's first exemption.
        pauseFootprintAudit(timeline.total + 0.3, reason: "box scan")
        if timeline.full {
            print(String(format: "[reveal] box scan start (%.1f×%.1f×%.1f mm, %.1f s)",
                         deviceFootprint.size.x * 1000, deviceFootprint.size.y * 1000,
                         deviceThickness * 1000, timeline.total))
        } else {
            print(String(format: "[reveal] box scan (summon, %.1f s)", timeline.total))
        }
        overlay.root.isEnabled = true
        // `acquire`@0 — but only when nothing else has played it: a first detection already got one from
        // `playAcquireCue()` in the same frame.
        if !firstAcquire { audio.play(.acquire, on: anchorRoot) }
        boxScan.run(timeline,
                    onGlow: { [weak self] in self?.onScanGlow?() },
                    onConverge: { [weak self] in self?.boxScanConverged() })
        // `scan`@0.2 and the hand-over to the socket light / the well at the contraction, both on the
        // scan's own clock rather than on the rig's (they are the device's lights, not the wireframe's).
        choreography?.cancel()
        choreography = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(timeline.bandStart * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.audio.play(.scan, on: self.anchorRoot)
            let toContract = timeline.contractStart - timeline.bandStart
            try? await Task.sleep(for: .milliseconds(Int(toContract * 1000)))
            guard !Task.isCancelled else { return }
            // 0.80–1.05: the wireframe collapses onto the screen rectangle **and becomes** the socket light.
            self.overlay.showSocket(true)
            self.overlay.socket.components.set(TweenComponent(
                opacity: (from: self.overlay.socket.components[OpacityComponent.self]?.opacity ?? 0, to: 0.5),
                duration: timeline.handover, easing: .easeOutCubic))
            self.well.open(duration: timeline.handover)
        }
    }

    /// The convergence beat: the chip, the device's own answer, and the entrance the scan was holding.
    private func boxScanConverged() {
        audio.play(.chip0, on: anchorRoot)
        // The device answers *first* — that is the beat: the wireframe becomes the socket light, the
        // hardware rings, and only then does anything virtual stand up out of it.
        onScanConverged?()
        guard scanPending.take() != nil, let held = heldIntro else { return }
        heldIntro = nil
        print(String(format: "[reveal] box scan → %@ at %.2f s", held.label.rawValue, scanTimeline.converge))
        runTransition(held.transition, previous: held.previous, hideKind: nil,
                      firstAcquire: held.firstAcquire, resumeFromWorld: held.resumeFromWorld,
                      animated: held.animated)
        retuneRelocationForPresence()
        updateParticleRate()
        // …and the app's own half of the same event last, so the deck rises out of a card that is already
        // on its way up rather than out of a device that is still closed.
        onScanEntranceStarted?()
    }

    // MARK: - Button glints (V3-2a2 S3 / plan §4 E6)

    /// Three 6 mm dots at the physical key positions, mounted once and left at opacity 0. They are the one
    /// effect whose whole point is that the light comes on **on the hardware, under the thumb** — so the
    /// cause of what happens next is visibly in the wearer's hand and not on the card.
    private func buildButtonGlints() {
        for key in ButtonGlintLayout.Key.allCases {
            let dot = ModelEntity(mesh: .generatePlane(width: ButtonGlintLayout.size, height: ButtonGlintLayout.size),
                                  materials: [FXMaterials.glow(fx.coreDisc, tint: look.highlight, opacity: 1)])
            dot.name = "buttonGlint.\(key.rawValue)"
            dot.components.set(BillboardComponent())
            dot.components.set(OpacityComponent(opacity: 0))
            // v4 B2: dark until a press switches it on (`flashButtonDot`), and out of the tree while it is.
            dot.isEnabled = false
            // H0: the dot's whole plane sits outside the audited prism, so this is checked, not assumed.
            dot.components.set(FootprintProbeComponent(.points([.zero])))
            buttonGlintGroup.addChild(dot)
            buttonGlints[key] = dot
        }
        layoutButtonGlints()
    }

    /// Re-place them: the edge flag flipped, or the device measured itself.
    private func layoutButtonGlints() {
        for (key, dot) in buttonGlints {
            dot.position = ButtonGlintLayout.position(key, edge: buttonEdge, footprint: deviceFootprint)
        }
    }

    /// **The same frame a `button` line arrives** (`DeviceCoordinator.handleButton`): the key answers.
    ///
    /// **V3-4 §1, button feedback 2.0.** V3-2a2 put a 6 mm dot on the key and the headset round proved it
    /// invisible — visionOS draws the wearer's real hand over virtual content and the app may not set
    /// `upperLimbVisibility`, so a dot under the thumb is a dot nobody sees. The feedback therefore has to
    /// *leave* the thumb and draw the causal chain: key → the device's own outline → the card the press acts
    /// on. Four things happen on the same frame:
    ///
    /// 1. the wave: two fronts leave the key along the outline at 1 m/s and meet on the far side;
    /// 2. the edge glow itself pulses ×1.4 over half a second, so the whole ring is brighter, not just the
    ///    segment the wave is on;
    /// 3. a cone of sparks off the key, aimed **out of the shell and up** — out from under the thumb;
    /// 4. the thing the press acts on answers: OK the name card's rim, UP / DOWN the raised deck card (a
    ///    dozen sparks fly to it and a highlight crosses it as they land).
    ///
    /// A click is 0.25 s; a long press keeps sending laps until it ends.
    func flashButton(_ key: ButtonGlintLayout.Key, long: Bool) {
        guard buttonGlintEnabled, buttonFX != .off else { return }
        // Kept exactly as it was: the acceptance sheet counts presses with this line, and the headset round's
        // 37/37 is only comparable against the same spelling.
        print("[fx] button glint \(ButtonGlintLayout.logSuffix(key, edge: buttonEdge))")
        flashButtonDot(key, long: long)
        guard buttonFX == .wave else { return }
        print("[fx] button wave \(ButtonWaveLayout.logSuffix(key, edge: buttonEdge, footprint: deviceFootprint, count: buttonWave.segmentCount))")
        buttonWave.stopHold()
        buttonWave.flash(key: key, edge: buttonEdge)
        if long { buttonWave.startHold(key: key, edge: buttonEdge) }
        well.pulseEdge(multiplier: 1.4, duration: 0.5)
        sparksOffTheKey(key)
        switch key {
        case .ok:
            // The name card answers: one bright breath of the rim, 0.15 s.
            setBloom(strength: look.bloomStrength, peak: 0.7, decay: 0.15)
            pulseRim(scale: 1.03)
        case .up, .down:
            sparksToRaisedCard(key)
            rippleDeck()
        }
    }

    /// V3-2a2's dot, unchanged except for where it stands and how big it is (`ButtonGlintLayout`): the wave's
    /// visible starting point. `--button-fx dot` is this and nothing else.
    private func flashButtonDot(_ key: ButtonGlintLayout.Key, long: Bool) {
        guard let dot = buttonGlints[key] else { return }
        dot.isEnabled = true
        dot.components.remove(TweenComponent.self)
        buttonGlintTasks[key]?.cancel()
        let small = SIMD3<Float>(repeating: 0.6), big = SIMD3<Float>(repeating: 1.4)
        burstAtButton(dot)
        guard long else {
            dot.components.set(OpacityComponent(opacity: 0))
            // v4 B2: out of the tree once it has faded (it is switched on again above for the next press).
            dot.components.set(TweenComponent(scale: (from: small, to: big),
                                              opacity: (from: 0.95, to: 0), duration: 0.25, easing: .easeOutCubic,
                                              disableWhenDone: true))
            return
        }
        dot.components.set(TweenComponent(scale: (from: small, to: big),
                                          opacity: (from: 0, to: 0.9), duration: 0.12, easing: .easeOutCubic))
        buttonGlintTasks[key] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, let dot = self.buttonGlints[key] else { return }
            dot.components.set(TweenComponent(scale: (from: big, to: big),
                                              opacity: (from: 0.9, to: 0), duration: 0.2, easing: .easeInCubic,
                                              disableWhenDone: true))
        }
    }

    /// A long press ended (or the card is going away): stop the laps.
    func endButtonHold() { buttonWave.stopHold() }

    /// **V3-4 §9.** A deck card has arrived over the name card: one bright breath of the whole rig and the
    /// hinge's contact light at double strength for 0.4 s — the light that holds the card up gets brighter
    /// when something lands on it.
    func playRaiseFlourish() {
        guard raiseFlourish else { return }
        setBloom(strength: look.bloomStrength, peak: 0.7, decay: 0.15)
        guard hingeGlowStrip.isEnabled, var pulse = hingeGlowStrip.components[PulseComponent.self] else { return }
        let base = pulse.baseOpacity
        pulse.baseOpacity = min(1, base * 2)
        hingeGlowStrip.components.set(pulse)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, var back = self.hingeGlowStrip.components[PulseComponent.self] else { return }
            back.baseOpacity = base
            self.hingeGlowStrip.components.set(back)
        }
    }

    /// Twelve sparks off the key itself. Deliberately not `burst(count:)`: that emitter lives at the screen's
    /// centre, and the whole point of this effect is that the light is where the thumb is.
    private func burstAtButton(_ dot: Entity) {
        let entity = Entity()
        entity.name = "burst.button"
        entity.position = dot.position
        var emitter = HologramController.noteTrailEmitter(sprite: fx.sparkle)
        emitter.burstCount = 12
        emitter.burst()
        PerfCensus.noteBurst(12, life: emitter.mainEmitter.lifeSpan)
        entity.components.set(emitter)
        buttonGlintGroup.addChild(entity)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            entity.removeFromParent()
        }
    }

    /// **V3-4 §1.** Twenty 2 mm sparks off the key, in a cone aimed out of the shell's side face and up, at
    /// 0.3 m/s — i.e. out from under the thumb and into the wearer's view. Half a second and they are gone.
    private func sparksOffTheKey(_ key: ButtonGlintLayout.Key) {
        let entity = Entity()
        entity.position = ButtonGlintLayout.position(key, edge: buttonEdge, footprint: deviceFootprint)
        let outward = simd_normalize(SIMD3<Float>(buttonEdge.sign, 1.1, 0))
        var emitter = HologramController.buttonSparkEmitter(sprite: fx.sparkle, direction: outward,
                                                            tint: look.highlight)
        emitter.burstCount = HologramController.buttonSparkCount
        emitter.burst()
        PerfCensus.noteBurst(HologramController.buttonSparkCount, life: emitter.mainEmitter.lifeSpan)
        entity.components.set(emitter)
        buttonGlintGroup.addChild(entity)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(900))
            entity.removeFromParent()
        }
    }

    /// **V3-4 §1.** UP / DOWN raised a card: a dozen sparks arc from the key to it in 0.35 s, and a highlight
    /// crosses it as they land. This is the half of the effect that says *what the press did*.
    private func sparksToRaisedCard(_ key: ButtonGlintLayout.Key) {
        guard notes.deckOut, let raised = notes.deckRaised,
              let holder = notes.holders[raised] ?? notes.worldHolders[raised] else { return }
        let origin = ButtonGlintLayout.position(key, edge: buttonEdge, footprint: deviceFootprint)
        let target = buttonGlintGroup.convert(position: deckRaisedTransform().translation, from: notes.group)
        let entity = Entity()
        entity.name = "burst.toRaised"
        entity.position = origin
        var emitter = HologramController.noteTrailEmitter(sprite: fx.sparkle)
        emitter.mainEmitter.birthRate = 240
        emitter.mainEmitter.lifeSpan = 0.35
        emitter.isEmitting = true
        entity.components.set(emitter)
        buttonGlintGroup.addChild(entity)
        entity.components.set(TweenComponent(position: (from: origin, to: target),
                                             arcOffset: [0, 0.03, 0], duration: 0.35, easing: .easeOutCubic))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            if var e = entity.components[ParticleEmitterComponent.self] {
                e.mainEmitter.birthRate = 0
                entity.components.set(e)
            }
            self.sweepDeckGlint(on: holder)
            try? await Task.sleep(for: .milliseconds(700))
            entity.removeFromParent()
        }
    }

    /// The cone of sparks a key throws: 20 of them, 2 mm, white going to the look's tint.
    static let buttonSparkCount = 20

    static func buttonSparkEmitter(sprite: TextureResource, direction: SIMD3<Float>,
                                   tint: UIColor) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .cone
        p.emitterShapeSize = [0.004, 0.004, 0.004]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = direction
        p.speed = 0.30
        p.speedVariation = 0.12
        p.particlesInheritTransform = false
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 0.5
        p.mainEmitter.lifeSpanVariation = 0.15
        p.mainEmitter.size = 0.002
        p.mainEmitter.sizeVariation = 0.0008
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.1
        p.mainEmitter.acceleration = [0, -0.12, 0]
        p.mainEmitter.spreadingAngle = .pi / 5
        p.mainEmitter.angularSpeed = 1.2
        p.mainEmitter.angularSpeedVariation = 1.4
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        p.mainEmitter.color = .evolving(start: .single(.white), end: .single(tint.withAlphaComponent(0)))
        return p
    }

    /// Undo whatever the fold left behind: the billboard is the reader's again and the socket stops being a
    /// button (the projector's base ring sits on the same spot and must get the taps back).
    func cardIsComingBack() {
        stopSleepFX()
        // v4 B3: whatever brings the card back takes the collapsed card's point with it (a summon's ribbon already has).
        releaseGoldPoint(reason: "the card is back")
        suspendBillboard(false)
        overlay.setSocketTappable(false)
        socketArmed = false
        haloDisc.components.set(OpacityComponent(opacity: 1))
        // v3 H2: whatever the hand form faded out belongs to the desk again. (`unfoldFromDevice` calls this
        // first and then fades the desk back out — it is the one path that comes back *into* a hand.)
        isHandForm = false
        syncProjectorForm()
        setHandTrail(false)
        if deskFaded {
            deskFaded = false
            fadeDesk(visible: true, animated: false)
        }
    }

    /// **v4 B2 — the cone regression.** The projector's form follows the card's, on every path into or out of the
    /// hand, so `--hand-cones off` (V3-6 §2: the cones were the 45 fps pick-up window) holds whichever way the card
    /// got there. Before this only `runHandForm` and `runSettle` told the rig: the first recognition of round 1
    /// happened in the hand, went through the unfold, and the rig spent the whole session in its desk form. (The
    /// unfold also switches the projector off, so the cones were not actually drawn there — but `[perf] scene:`
    /// said `cones on`, and a summon, a world's return into the hand or any later `setVisible(true)` would have
    /// drawn them.) `runHandForm` keeps its own call 0.25 s in, after the rays have retracted (V3-2a H4).
    func syncProjectorForm() {
        let hand = isHandForm && handForm == .hinge
        guard projector.isHandMode != hand else { return }
        projector.setHandMode(hand)
    }

    /// The card is folded away and there is nothing on screen to fold — `--auto-show never`, or a `cmd hide`
    /// before the first reveal. Leave the socket light burning on the device so OK (or a tap on it) is a
    /// visible way back rather than a thing the wearer has to know about. Idempotent.
    func armDismissedSocket() {
        guard !socketArmed, !hologram.isEnabled else { return }
        socketArmed = true
        // v4 B3 §2: the collapsed card's one resting picture is the gold point — no socket light, no sleeping dust.
        if isV4Card { return armCollapsedPoint() }
        print("[reveal] socket light only (card folded away)")
        overlay.hideAll(keepSocket: true)
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        overlay.socket.components.remove(TweenComponent.self)
        overlay.socket.components.set(OpacityComponent(opacity: RegistrationOverlay.socketFolded))
        overlay.setSocketTappable(true)
        startSleepFX()
    }

    // MARK: - The sleeping magic (V3-4 §8)

    /// The card is folded away and the device is left with its socket light. Give it a life of its own: the
    /// outline breathes 0.35 → 0.6 over four seconds, two dozen motes of star dust circle the shell, and the
    /// button wave's ring sends one slow, dim light round every six seconds.
    ///
    /// All of it is **outside the footprint prism** — the dust's torus, the wave's ring, and the socket,
    /// which is the one thing the H0 rule always allowed on the screen.
    func startSleepFX() {
        guard sleepFXEnabled, !sleepAwake else { return }
        sleepAwake = true
        sleepNoticed = false
        sleepDust.isEnabled = true
        setSleepDust(rate: HologramController.sleepDustCount, vortex: 0.35, attraction: 0)
        overlay.socket.components.remove(TweenComponent.self)
        overlay.socket.components.set(PulseComponent(baseScale: 1, scaleAmplitude: 0.012,
                                                     baseOpacity: 0.475, opacityAmplitude: 0.125, period: 4))
        buttonWave.startPatrol(period: HologramController.sleepPatrolPeriod, edge: buttonEdge, peak: 0.3)
        print(String(format: "[reveal] sleep fx on (%.0f sparkles, patrol %.0f s)",
                     HologramController.sleepDustCount, HologramController.sleepPatrolPeriod))
    }

    /// The card is coming back (a summon, an unfold, a teardown): everything the sleep owned goes quiet.
    func stopSleepFX() {
        guard sleepAwake else { return }
        sleepAwake = false
        sleepNoticed = false
        buttonWave.stopHold()
        overlay.socket.components.remove(PulseComponent.self)
        setSleepDust(rate: 0, vortex: 0, attraction: 0)
        sleepTask?.cancel()
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !self.sleepAwake else { return }
            self.sleepDust.isEnabled = false
        }
    }

    /// **The wake.** The wearer pressed OK: the dust that has been circling the shell is pulled into the LCD
    /// over 0.3 s and the recognition wireframe starts out of it. `ParticleEmitterComponent.ParticleEmitter`
    /// carries `attractionCenter` / `attractionStrength` on visionOS 27 (checked in the SDK interface), so
    /// this is the emitter's own gravity rather than two dozen tweened entities.
    func wakeSleepFX() {
        guard sleepAwake else { return }
        print("[reveal] wake: sparkles into the screen")
        setSleepDust(rate: HologramController.sleepDustCount * 3, vortex: 0.1, attraction: 6)
        sleepTask?.cancel()
        sleepTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.stopSleepFX()
        }
    }

    /// One poll of "is a hand near the device", at 4 Hz while the card is folded: inside 12 cm the ring goes
    /// to 0.8 and the dust doubles its speed, outside it they go back. It is the smallest possible piece of
    /// "it noticed you", and it is the only thing the device does while it is asleep that the wearer causes.
    private func stepSleepFX(dt: Float) {
        guard sleepAwake else { return }
        sleepPollAt += dt
        guard sleepPollAt >= 0.25 else { return }
        sleepPollAt = 0
        let near = (nearestHandDistance?()).map { $0 <= HologramController.sleepNoticeRadius } ?? false
        guard near != sleepNoticed else { return }
        sleepNoticed = near
        setSleepDust(rate: HologramController.sleepDustCount * (near ? 1.6 : 1),
                     vortex: near ? 0.7 : 0.35, attraction: 0)
        if var pulse = overlay.socket.components[PulseComponent.self] {
            pulse.baseOpacity = near ? 0.8 : 0.475
            pulse.opacityAmplitude = near ? 0.12 : 0.125
            overlay.socket.components.set(pulse)
        }
        print("[reveal] sleep fx: \(near ? "a hand came within 12 cm" : "the hand went away")")
    }

    private func setSleepDust(rate: Float, vortex: Float, attraction: Float) {
        guard var emitter = sleepDust.components[ParticleEmitterComponent.self] else { return }
        emitter.mainEmitter.birthRate = rate
        emitter.mainEmitter.vortexStrength = vortex
        emitter.mainEmitter.attractionStrength = attraction
        emitter.isEmitting = rate > 0
        sleepDust.components.set(emitter)
    }

    /// The sleeping device's star dust: 24 motes a second, 1.5 mm, circling the shell's outline on the
    /// emitter's own vortex and living four seconds each — so ~24 of them are in the air at any moment,
    /// well inside §8's budget of 40.
    static func sleepDustEmitter(sprite: TextureResource, tint: UIColor) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .torus
        // A ring 38 mm across the device's short axis — the prism's 33 mm plus 5 mm — with a 4 mm tube, and
        // the entity's own Z scale stretches it to the shell's 95 mm length.
        p.emitterShapeSize = [0.038, 0.004, 0.038]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.004
        p.speedVariation = 0.003
        p.particlesInheritTransform = false
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 4.0
        p.mainEmitter.lifeSpanVariation = 1.2
        p.mainEmitter.size = 0.0015
        p.mainEmitter.sizeVariation = 0.0006
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.5
        p.mainEmitter.opacityCurve = .gradualFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        // visionOS 27: the emitter can circle its own axis and be pulled toward a point, which is the whole
        // of "they orbit the shell" and "they rush into the screen".
        p.mainEmitter.vortexDirection = [0, 1, 0]
        p.mainEmitter.vortexStrength = 0
        p.mainEmitter.attractionCenter = [0, 0, 0]
        p.mainEmitter.attractionStrength = 0
        p.mainEmitter.color = .evolving(start: .single(.white), end: .single(tint.withAlphaComponent(0)))
        return p
    }

    /// The socket ring's summon beat (V3-2a H0): up to `RegistrationOverlay.socketSummon` in 0.15 s, held
    /// while the card rises, then down to the level the state it is arriving in wants.
    func flareSocketForSummon(animated: Bool, settlingTo level: Float) {
        let from = overlay.socket.components[OpacityComponent.self]?.opacity ?? 0
        guard animated else {
            overlay.socket.components.remove(TweenComponent.self)
            overlay.socket.components.set(OpacityComponent(opacity: level))
            return
        }
        overlay.socket.components.set(TweenComponent(opacity: (from: from, to: RegistrationOverlay.socketSummon),
                                                     duration: 0.15, easing: .easeOutCubic))
        socketFlare?.cancel()
        socketFlare = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, !Task.isCancelled else { return }
            self.overlay.socket.components.set(TweenComponent(
                opacity: (from: RegistrationOverlay.socketSummon, to: level), duration: 0.35, easing: .easeInOutCubic))
        }
    }

    func cancelChoreography() {
        choreography?.cancel()
        choreography = nil
        foldTask?.cancel()
        foldTask = nil
        idleTask?.cancel()
        idleTask = nil
        if pixelsInFlight { endPixelsInFlight() }
    }

    /// The reveal / collapse tasks keep running through holds; they stop when the card is gone or carried.
    var revealMayContinue: Bool {
        switch currentPresence {
        case .expanded, .settling, .held: return true
        case .absent, .acquiring, .carrying: return false
        }
    }

    /// Full cinematic reveal (once per session / after a replay).
    private func runReveal(animated: Bool) {
        surface.isEnabled = true
        hasShownCard = true
        carriedVisual = false
        setSearching(false)
        cardIsComingBack()
        // v4 B1 §3: the hero card is dissolved into the outline the ribbon drew (HologramController+V4).
        if let v4 {
            // v4 B4 §1: the ribbon drew the outline on the hinge (it took off with the passport in the hand) but the gate
            // settled on the desk: there is no outline at the desk card's place to dissolve into — it rises off the screen.
            if let plan = v4.handRecognition {
                print("[v4] the recognition flew the hand's path (\(plan.decision.reason)) but the gate settled on the desk: the card rises off the screen (fallback)")
                return runV4Reentry(animated: animated)
            }
            return runV4Reveal(animated: animated)
        }
        pixelsInFlight = animated
        if animated { print("[reveal] \(revealKind.rawValue) start") }
        switch revealKind {
        case .inkExtraction:
            runCloudReveal(mode: .inkLift, animated: animated)
        case .pixelReassembly:
            runCloudReveal(mode: .reassembly, animated: animated)
        case .scanDissolve:
            runScanDissolveReveal(animated: animated)
        }
    }

    /// Reappearance after a hide (≤ 1 s): the card rises out of the device at 0.55 and springs to size while the
    /// projector comes on; chips split off staggered; settle chord. No pixel / ink choreography.
    private func runReentry(animated: Bool) {
        // v4 B1 §3: A4's rise off the screen (a reentry, a summon on the desk, a put-down that brings the card back).
        if v4 != nil { return runV4Reentry(animated: animated) }
        pauseFootprintAudit(animated ? 1.6 : 0.2, reason: "reentry")
        detachCardFromHinge()
        surface.isEnabled = true
        hasShownCard = true
        carriedVisual = false
        setSearching(false)
        cardIsComingBack()
        overlay.hideAll()
        pixels.hide()
        well.hide()
        resetFollower()          // the card is being rebuilt: the next pose places it, it does not glide there
        igniteSurface(level: 1, animated: animated)
        hologram.isEnabled = true
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.orientation = simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0])
        resetCardLayers()
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        // V3-2a H0: the ring flares to `socketSummon` as the card comes back — the summon's first visible
        // beat happens **on the device** — and settles to the desk-idle level behind it.
        flareSocketForSummon(animated: animated, settlingTo: 0.4)
        guard animated else {
            cardGroup.transform = Transform(scale: [1, 1, 1], rotation: cardGroup.orientation, translation: [0, HologramLayout.cardCenterHeight, 0])
            cardGroup.components.set(OpacityComponent(opacity: 1))
            projector.setVisible(true, animated: false)
            startIdle()
            return
        }
        cardGroup.components.set(TweenComponent(
            scale: (from: [0.55, 0.55, 0.55], to: [1, 1, 1]),
            position: (from: [0, Self.cardRestY, 0], to: [0, HologramLayout.cardCenterHeight, 0]),
            opacity: (from: 0, to: 1), duration: 0.7, easing: .spring(response: 0.45, damping: 0.75)))
        audio.play(.liftOff, on: anchorRoot)
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func wait(_ seconds: Float) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if Task.isCancelled { return false }
                return self.revealMayContinue
            }
            guard await wait(0.25) else { return }
            self.projector.setVisible(true, animated: true)
            self.showWellDimmed(animated: true)
            guard await wait(0.3) else { return }
            self.rim.components.set(TweenComponent(scale: (from: [1.03, 1.03, 1.03], to: [1, 1, 1]), duration: 0.35, easing: .spring(response: 0.35, damping: 0.7)))
            self.flareBeam()
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.1, endScale: 1.1, duration: 0.8, peak: 0.7)
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    /// Device picked up (0.25 s): the card shrinks to 0.55 and tucks toward the device, chips fold in, the
    /// projector switches off. The desk effects stay where the device last rested (`applySurface` is ignored).
    private func runCarry(animated: Bool) {
        setSearching(false)
        // v4 B2 §3.3: found again in a hand after a pick-up fold — the hand form below grows the card out of the point.
        if pickup.folded { endPickupFold(to: "hand") }
        // v3 H2 §5: a `.carry` with nothing on screen is the card being **summoned** into a hand that is
        // already holding the device (OK after a dismiss). That is the unfold, not a carry.
        guard hologram.isEnabled else {
            guard usesHandForm else { return }
            // v4 B4 §1: the recognition drew the outline on the hinge — the card dissolves in there. A recognition that
            // flew the desk's path (the gate went to the hand after take-off) keeps today's unfold.
            if let plan = v4?.handRecognition, handForm == .hinge {
                runV4HandReveal(plan, animated: animated)
            } else {
                if let decision = v4?.closingRecognitionDecision, decision.place == .desk {
                    print("[v4] the recognition flew the desk's path (\(decision.reason)) but the gate went to the hand: unfold from the device (fallback)")
                }
                unfoldFromDevice(animated: animated)
            }
            return
        }
        guard !usesHandForm else {
            runHandForm(animated: animated)
            return
        }
        carriedVisual = true
        detachCardFromHinge()
        overlay.hideAll()
        pixels.hide()
        well.hide()
        idleScan.isEnabled = false
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.set(OpacityComponent(opacity: 1))
        resetCardLayers()
        let k: Float = animated ? 1 : 0
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: [0.55, 0.55, 0.55]),
            position: (from: cardGroup.position, to: [0, Self.carryY, 0]),
            duration: k * 0.25, easing: .easeInCubic))
        projector.setVisible(false, animated: animated)
        audio.play(.carry, on: anchorRoot)
    }

    /// **The hand form** (v3 H2 §1). The device has been picked up and the card goes with it — not as v2's
    /// shrunken thing riding above a desk that is still lit somewhere behind it, but as a half-size pane lying
    /// 35 mm off the screen, turned by `handFacing`, with the desk furniture gone and the light well left open
    /// at the screen as the card's only light source.
    ///
    /// 0.00 the desk (halo, coins, socket) fades over 0.3 s, the projector rays switch off, the billboard is
    ///      suspended (the facing tick owns the orientation from here) and the trail is armed
    /// 0.00–0.35 one spring to scale 0.5 / (0, 0.035, 0) / parallel to the screen
    private func runHandForm(animated: Bool) {
        // v4 B1: a rise off the screen cannot be carried onto the hinge half-way; the reveal's dissolve can.
        v4?.settleForV3Choreography(reason: "pick-up")
        carriedVisual = true
        isHandForm = true
        armHandFormProbe()
        overlay.hideAll(keepSocket: true)
        pixels.hide()
        idleScan.isEnabled = false
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.set(OpacityComponent(opacity: 1))
        resetCardLayers()
        // The desk is where the card *was*; it is not where the card is any more.
        suspendBillboard(true)
        deskFaded = true
        // E2: the ten threads run back into the outline first (0.25 s), the landing pool flashes as the card
        // takes off, and the desk furniture only goes **after** the card has left — 0.3 s later, so the eye
        // follows the card and finds the desk already dark when it comes back.
        handMorphTask?.cancel()
        projector.retractRays()
        flashLandingPool()
        handMorphTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(animated ? 250 : 0))
            guard let self, !Task.isCancelled, self.isHandForm else { return }
            self.projector.setHandMode(self.handForm == .hinge)
            if self.handForm == .hinge {
                self.projector.setVisible(true, animated: false)
                self.projector.growRays()
            } else {
                self.projector.setVisible(false, animated: true)
            }
            try? await Task.sleep(for: .milliseconds(animated ? 50 : 0))
            guard !Task.isCancelled, self.isHandForm else { return }
            self.fadeDesk(visible: false, animated: animated)
        }
        if !animated { fadeDesk(visible: false, animated: false) }
        // …and the light well stays open at the device: in the hand it is the one light the card still has.
        showWellDimmed(animated: animated)
        let hand = SIMD3<Float>(repeating: handScale)
        guard handForm == .hinge else { return runHoverForm(animated: animated, hand: hand) }
        let target = hingeCardPosition
        // B0b, in this order: place the hinge, put the **arm** at the resting angle, and only then hand the
        // card to it (the hand-over preserves the world transform, so an arm moved afterwards would swing the
        // card through that angle in one frame). S0b: the deck's slots are struck in the pose the card is
        // arriving in, not the desk pose it leaves.
        placeHandPivot()
        let rest = HandFacing.hinged(weight: handFacing == .hinged ? HandFacing.hingeWeight : handFacing.weight,
                                     card: target, head: headInHinge())
        syncHingeGroup(rest)
        attachCardToHinge()
        // On the arm the card is square: the arm carries the whole hinge angle.
        let square = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        guard animated else {
            cardGroup.components.remove(TweenComponent.self)
            cardGroup.transform = Transform(scale: hand, rotation: square, translation: target)
            return
        }
        // S0a: the hinge is the device's own top edge now, and the slab's 3 mm overhang lands on the bezel.
        print(String(format: "[reveal] hand form: hinge (0, %.0f, %.1f) mm = top edge, slab overhang %.0f mm over the bezel, open 180°, facing %@ %.1f, scale %.2f",
                     Self.hingeLift * 1000, hingePosition.z * 1000,
                     (isV4Card ? 0 : (HologramLayout.slabHeight - HologramLayout.cardHeight) / 2) * handScale * 1000,
                     handFacing.rawValue,
                     handFacing == .hinged ? HandFacing.hingeWeight : handFacing.weight, handScale))
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: hand),
            position: (from: cardGroup.position, to: target),
            orientation: (from: cardGroup.orientation, to: square),
            arcOffset: [0, 0.04, 0],
            duration: 0.35, easing: .spring(response: 0.4, damping: 0.75)))
        audio.play(.carry, on: anchorRoot)
    }

    /// `--hand-form hover`: V3-1's pane lying 35 mm above the screen. Kept so the two can be compared on
    /// the headset — it is the form the H0 audit reports, by construction.
    private func runHoverForm(animated: Bool, hand: SIMD3<Float>) {
        detachCardFromHinge()
        guard animated else {
            cardGroup.components.remove(TweenComponent.self)
            cardGroup.transform = Transform(scale: hand, rotation: Self.handBaseOrientation, translation: [0, Self.handY, 0])
            return
        }
        print(String(format: "[reveal] hand form (scale %.2f, %.0f mm above the screen, facing %@)",
                     handScale, Self.handY * 1000, handFacing.rawValue))
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: hand),
            position: (from: cardGroup.position, to: [0, Self.handY, 0]),
            orientation: (from: cardGroup.orientation, to: Self.handBaseOrientation),
            duration: 0.35, easing: .spring(response: 0.4, damping: 0.75)))
        audio.play(.carry, on: anchorRoot)
    }

    /// E2: the pool of light along the card's bottom edge flares as the card takes off from the desk.
    private func flashLandingPool() {
        guard let pulse = landing.components[PulseComponent.self] else { return }
        let base = pulse.baseOpacity
        landing.components.set(TweenComponent(opacity: (from: base, to: 0.9), duration: 0.12, easing: .easeOutCubic))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, self.isHandForm else { return }
            self.landing.components.set(TweenComponent(opacity: (from: 0.9, to: base), duration: 0.18, easing: .easeInCubic))
        }
    }

    /// The wearer's eyes in hinge space (nil when there is no head pose at all).
    private func headInHinge() -> SIMD3<Float>? {
        headPoseProvider?().map { world in
            let p = SIMD3<Float>(world.columns.3.x, world.columns.3.y, world.columns.3.z)
            return handPivot.convert(position: p, from: nil)
        }
    }

    /// **The unfold** (v3 H2 §5): OK while the passport is in the hand and the card is away. The reverse of
    /// `foldIntoDevice`, at the hand scale — the well brightens first, then the plate stands up out of the
    /// screen it was lying on and its content fades in behind it.
    ///
    /// 0.00 the well opens bright (0.15 s), the card is placed exactly where the fold left it
    /// 0.00–0.50 it rises to the hand form; content in over 0.20–0.50
    /// 0.15 `burst(12)` + `liftOff`
    private func unfoldFromDevice(animated: Bool) {
        pauseFootprintAudit(animated ? 1.4 : 0.2, reason: "unfold")
        // V3-4 §8: the dust goes into the screen and the card comes out of it.
        wakeSleepFX()
        hasShownCard = true
        // v4 B1: the unfold is v3's (the plate stands up out of the screen); the hero card rides it at rest.
        v4?.settleForV3Choreography(reason: "unfold")
        cardIsComingBack()
        socketArmed = false
        carriedVisual = true
        isHandForm = true
        // v4 B2: the rig learns the card is in a hand (`--hand-cones off` parks its cones); the unfold keeps it off.
        syncProjectorForm()
        armHandFormProbe()
        setSearching(false)
        resetFollower()          // the card is being rebuilt: the next pose places it, it does not glide there
        hologram.isEnabled = true
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        resetCardLayers()
        suspendBillboard(true)
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        flareSocketForSummon(animated: animated, settlingTo: RegistrationOverlay.socketFolded)
        // The desk stays out of this: the card is on the device, in a hand, and lighting a desk somewhere
        // behind it would be the v2 mistake this whole milestone is undoing.
        fadeDesk(visible: false, animated: false)
        deskFaded = true
        projector.setVisible(false, animated: false)
        let hand = SIMD3<Float>(repeating: handScale)
        let folded = Self.foldedScale(from: handScale)
        // The card starts exactly where the fold left it — lying on the screen, in `hologram` space — and
        // ends on the hinge (V3-2a H2), so the hand-off happens first and the whole rise is one tween.
        detachCardFromHinge()
        cardGroup.transform = Transform(scale: folded, rotation: Self.handBaseOrientation,
                                        translation: [0, Self.cardRestY * 0.2, 0])
        let hinge = handForm == .hinge
        // B0b: the arm takes the resting angle first, then the card is handed to it where it lies (the whole
        // rise is still one tween, and in the arm's frame its destination is simply "square, half a card up").
        let restPosition = hinge ? hingeCardPosition : SIMD3<Float>(0, Self.handY, 0)
        if hinge { placeHandPivot() }
        let armRest = hinge
            ? HandFacing.hinged(weight: handFacing == .hinged ? HandFacing.hingeWeight : handFacing.weight,
                                card: hingeCardPosition, head: headInHinge())
            : simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        syncHingeGroup(armRest)
        if hinge { attachCardToHinge() }
        let restRotation = hinge ? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1) : Self.handBaseOrientation
        guard animated else {
            cardGroup.components.remove(TweenComponent.self)
            cardGroup.transform = Transform(scale: hand, rotation: restRotation, translation: restPosition)
            cardGroup.components.set(OpacityComponent(opacity: 1))
            showWellDimmed(animated: false)
            return
        }
        print("[reveal] unfold from device (0.5 s)\(hinge ? " → hinge" : "")")
        well.open(duration: 0.15)
        cardGroup.components.set(OpacityComponent(opacity: 0.15))
        setCardFace { $0.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: 0.2,
                                                       duration: 0.3, easing: .easeOutCubic)) }
        cardGroup.components.set(TweenComponent(
            scale: (from: folded, to: hand),
            position: (from: cardGroup.position, to: restPosition),
            orientation: (from: cardGroup.orientation, to: restRotation),
            opacity: (from: 0.15, to: 1), duration: 0.5, easing: .spring(response: 0.45, damping: 0.78)))
        audio.play(.liftOff, on: anchorRoot)
        choreography = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled, self.isHandForm else { return }
            self.burst(count: 12)
            self.pulseRim(scale: 1.05)
            self.setBloom(strength: self.look.bloomStrength, peak: 0.7, decay: 0.5)
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self.isHandForm else { return }
            // Hand-form idle: the well is the card's light source and stays open at the screen.
            self.showWellDimmed(animated: true)
        }
    }

    /// **v4 B4 §1 — the hand's reveal.** The recognition drew the card's outline where the hand form puts the card — on
    /// the top-edge hinge, at the hinge angle it froze at take-off, at the hand scale — so at its closure the card is put
    /// exactly there and dissolves in place, as the desk card dissolves into its outline (`.reveal`). No unfold.
    ///
    /// The end state is `unfoldFromDevice`'s (the hand form, the projector in its hand form and off, the billboard held,
    /// the socket at its folded level, the desk dark, the well open as the card's light); the hinge stays at the frozen
    /// angle until the dissolve is in and the outline gone, then the facing tick takes it from there (τ 0.12 s, so it
    /// eases rather than jumps); the deck rises out of the card as the dissolve completes (`nextDeckRiseDelay`).
    private func runV4HandReveal(_ plan: V4CardIntegration.HandRecognition, animated: Bool) {
        guard let v4 else { return unfoldFromDevice(animated: animated) }
        hasShownCard = true
        // The gold point, the billboard, the socket's tap… and it fades the desk back in, which the hand does not want:
        // put out again in the same frame (as the unfold does).
        cardIsComingBack()
        socketArmed = false
        carriedVisual = true
        isHandForm = true
        syncProjectorForm()
        armHandFormProbe()
        setSearching(false)
        hologram.isEnabled = true
        cardGroup.isEnabled = true
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.remove(TweenComponent.self)
        resetCardLayers()
        suspendBillboard(true)
        overlay.root.isEnabled = true
        overlay.showSocket(true)
        overlay.socket.components.remove(TweenComponent.self)
        overlay.socket.components.set(OpacityComponent(opacity: RegistrationOverlay.socketFolded))
        fadeDesk(visible: false, animated: false)
        deskFaded = true
        projector.setVisible(false, animated: false)
        // On the hinge, at the frozen angle and the hand scale: where the outline was drawn.
        placeHandPivot()
        syncHingeGroup(HandFacing.hinged(angle: plan.hingeAngle))
        attachCardToHinge()
        cardGroup.transform = Transform(scale: SIMD3<Float>(repeating: handScale), rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                                        translation: hingeCardPosition)
        cardGroup.components.set(OpacityComponent(opacity: 1))
        setCardFace { $0.components.set(OpacityComponent(opacity: 1)) }
        guard animated else {
            v4.showAtRest()
            showWellDimmed(animated: false)
            return
        }
        handRevealHingeFrozen = true
        // `--v4-freeze` (stills) holds the card's clock, not the wall's: the deck waits rather than rising round a frozen card.
        nextDeckRiseDelay = v4.freezesThisRun ? 60 : Float(v4.rig.timeline.dissolveDuration)
        beginV4HandRevealEntrance(plan)
    }

    /// **The page flip** (v3 H2 §8), 0.35 s: the plate turns edge-on and back, a highlight crosses it as it
    /// opens again, and twenty sparks come off the edge. The *content* is swapped by `AppModel` at the
    /// midpoint, while the card is 8 % of its width and there is nothing to see.
    ///
    /// Scale only: the facing tick owns the orientation, and a tween that wrote it too would fight it.
    func playPageFlip() {
        guard isHandForm, hologram.isEnabled else { return }
        let hand = SIMD3<Float>(repeating: handScale)
        let edge = SIMD3<Float>(handScale * 0.08, handScale, handScale)
        cardGroup.components.set(TweenComponent(scale: (from: cardGroup.scale, to: edge),
                                                duration: 0.175, easing: .easeInCubic))
        audio.play(.chip1, on: anchorRoot)
        choreography = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(175))
            guard let self, !Task.isCancelled, self.isHandForm else { return }
            self.cardGroup.components.set(TweenComponent(scale: (from: edge, to: hand),
                                                         duration: 0.175, easing: .spring(response: 0.3, damping: 0.8)))
            self.burst(count: 20)
            self.sweepCardGlint()
            self.audio.play(.chip2, on: self.anchorRoot)
        }
    }

    /// Where a hand-card preview lives while it is open (root space, so it does not ride the hand).
    var notePreviewSpace: Entity { notePreviewRoot }

    /// One highlight travelling across the card's own face (the note fan has the same thing per cover).
    private func sweepCardGlint() {
        let width = cardSize.x, height = cardSize.y
        let quad = ModelEntity(mesh: FXMeshes.skewedQuad(width: width * 0.22, height: height, skew: height * 0.22),
                               materials: [FXMaterials.glow(fx.glint, tint: .white, opacity: 1)])
        let reach = width * 0.32
        let from = SIMD3<Float>(-reach, 0, 0.006), to = SIMD3<Float>(reach, 0, 0.006)
        quad.position = from
        quad.components.set(OpacityComponent(opacity: 0))
        quad.components.set(GlintSweepComponent(from: from, to: to, duration: 0.4, peakOpacity: 0.5))
        cardGroup.addChild(quad)
    }

    /// The scale `foldIntoDevice` leaves the card at, given the scale it started from. The fold is written in
    /// *relative* terms so it reads the same from the desk card (1) and from the hand form (0.5) — squashing
    /// a half-size card to an absolute [0.92, 0.06, 1] would make it grow on its way down.
    static func foldedScale(from scale: Float) -> SIMD3<Float> { [0.5 * scale, 0.02 * scale, 0.5 * scale] }

    /// Device put down (0.45 s spring): the card springs back to size and height, chips split off 60 / 120 / 180 ms
    /// apart, projector on, settle chord; the desk effects glide to the new place through `applySurface`.
    private func runSettle(animated: Bool) {
        // V3-2a H2: everything below works in `hologram` space, and the hand form left the card on the
        // hinge. The hand-back preserves the world transform, so the spring starts where the card is.
        detachCardFromHinge()
        guard hologram.isEnabled, carriedVisual else {
            // v3 FIX C: the gate now counts the first `acquiring → carrying` as the reveal, so a settle can
            // be the session's first appearance. With the object source the unfold already introduced the
            // card and a reentry is right; with `--tracker image` (no unfold — `runCarry` returns early with
            // the hologram disabled) nothing has been shown at all, and that first appearance is still owed
            // the full cinematic, exactly as it was before v3.
            if hasShownCard {
                runReentry(animated: animated)
            } else {
                runReveal(animated: animated)
            }
            return
        }
        carriedVisual = false
        let wasHandForm = isHandForm
        isHandForm = false
        disarmHandFormProbe()
        // B4: the flip ended in a put-down rather than a fold. The gesture's own `anticipation(false)` has
        // usually fired by now (flat is < 110°), but a settle inside the same 0.25 s would otherwise land a
        // card at 0.55 on the desk.
        if foldAnticipating {
            foldAnticipating = false
            cardGroup.components.set(OpacityComponent(opacity: 1))
        }
        setHandTrail(false)
        setSearching(false)
        surface.isEnabled = true
        if wasHandForm {
            // v3 H2 §1: the hand form took the desk away and turned the card's orientation over to the facing
            // tick. The settle is where both come back — and `fadeDesk` has to be undone explicitly, because
            // `igniteSurface` tweens the halo, not the `surface` opacity the fade zeroed.
            fadeDesk(visible: true, animated: animated)
            deskFaded = false
            suspendBillboard(false)
        }
        igniteSurface(level: 1, animated: animated)
        cardGroup.components.set(TweenComponent(
            scale: (from: cardGroup.scale, to: [1, 1, 1]),
            position: (from: cardGroup.position, to: [0, HologramLayout.cardCenterHeight, 0]),
            orientation: wasHandForm ? (from: cardGroup.orientation,
                                        to: simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0])) : nil,
            arcOffset: wasHandForm ? [0, 0.05, 0] : .zero,
            duration: animated ? 0.45 : 0, easing: .spring(response: 0.45, damping: 0.75)))
        handMorphTask?.cancel()
        projector.setHandMode(false)
        projector.setVisible(true, animated: animated)
        projector.growRays()
        guard animated else {
            onSettleBloom?()
            startIdle()
            return
        }
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            // 0.35 s: the deck's five fly to the gallery's front row while the card is still springing back,
            // the world cards fold in, and the other five fan out of the card (plan §4 E10).
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, self.revealMayContinue else { return }
            self.onSettleBloom?()
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, self.revealMayContinue else { return }
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.1, endScale: 1.0, duration: 0.7, peak: 0.6)
            self.flareBeam()
            self.showWellDimmed(animated: true)
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    /// Hold over: resume following the pose. The glide itself belongs to the follower — this only decides its
    /// *kind*, which the next `apply(pose:)` consumes. After a world the desk gets its return light; a relocation
    /// gets the slow, speed-limited glide and a landing ripple when the follower reports it has arrived.
    /// The well is deliberately untouched here: a thaw is not a reveal.
    private func runThaw(glide: Float, from previous: PresenceGate.Presence, fromWorld: Bool, animated: Bool) {
        setSearching(false)
        // The hand form is the visible state; `carrying` on the object source is the same thing one frame before
        // `runCarry` has run (a thaw that *arrives* as a carry), so both count. **v4 B2 §3.3**: so does a card folded by
        // a pick-up — the loss was a hand taking the passport, and its gold point has to catch up with that hand, not
        // crawl across a desk at the relocation's 0.6 m/s with a landing chime (V3-2a H1's crawl).
        let handRelocation = isHandForm || (currentPresence.isCarrying && lastPoseSource == .object) || pickup.folded
        notePickupFoldThaw()
        let worldLight = fromWorld || previous == .held(.world) || owesReturnFromWorldLight
        var deferredWorldLight = false
        if !animated {
            // Instant restore: be at the new pose on the next observation instead of gliding to it.
            resetFollower()
        } else if handRelocation, glide < HologramController.handRelocateMin {
            // V3-1b §6: the device is in a hand and the card is a few centimetres behind it. That is a retarget,
            // not a relocation — no glide mode, no speed limit, no landing cue. A return-from-world light is not
            // deferred either: there is no landing to defer it to.
            pendingGlide = .presence
        } else if glide > PresenceGate.relocateDistanceDefault {
            // The card is coming back somewhere else. When it also owes the desk its return-from-world light,
            // the light waits for the landing: played now it would flash on the spot the card is about to leave
            // and be over before it gets to the new one. (The ordinary case — the world gave the desk back and
            // the card never moved — is a sub-2 cm glide and still plays immediately, which is what keeps the
            // light under the rising black curtain where the take script puts it.)
            deferredWorldLight = worldLight
            owesReturnFromWorldLight = worldLight
            pendingGlide = .relocate(distance: glide, cue: !worldLight && !handRelocation,
                                     worldLight: worldLight, hand: handRelocation)
        } else {
            pendingGlide = .presence
        }
        if worldLight, !deferredWorldLight {
            // Directly from held(.world), or after the wait in held(.stale) when the card was not in view when the
            // world released the desk: the return light plays either way.
            playReturnFromWorldLight(reason: "\(previous.label) → \(currentPresence.label)")
        } else if deferredWorldLight {
            print(String(format: "[reveal] return-from-world light waits for the %.1f cm landing", glide * 100))
        }
    }

    /// Gone. The card only ever leaves on purpose, and the purpose decides how: a dismiss or a replay **folds**
    /// it into the device (v1 dissolved it into pixel dust, which read as "it broke"), a teardown fades the whole
    /// presentation out. A dismiss leaves the socket light burning on the screen — that is the way back.
    private func runHide(from previous: PresenceGate.Presence, kind: PresenceGate.HideKind?, animated: Bool) {
        setSearching(false)
        carriedVisual = false
        switch kind {
        case .dismiss?, .replay?:
            // **v4 B3 §2.** Into the gold point beside the top edge (the B2 pick-up fold's picture), not v3's squash and
            // drop; the point is the collapsed card's only resting picture. `--v3-card` keeps v3's fold below.
            if collapsesIntoPoint(kind), let kind {
                guard hologram.isEnabled else {
                    hideEverything(animated: false)
                    if kind == .dismiss { armCollapsedPoint() }
                    return
                }
                collapseIntoPoint(kind: kind, alreadyPoint: pickupWasPointAtHide, animated: animated)
                return
            }
            // There may be nothing to fold: a `cmd hide` can arrive before the card has ever been revealed.
            guard hologram.isEnabled else {
                hideEverything(animated: false)
                if kind == .dismiss {
                    // Still leave the way back on the device, so a dismiss is always undoable by a tap.
                    overlay.hideAll(keepSocket: true)
                    overlay.socket.components.set(OpacityComponent(opacity: RegistrationOverlay.socketFolded))
                    overlay.setSocketTappable(true)
                }
                return
            }
            foldIntoDevice(animated: animated, keepSocket: kind == .dismiss)
        default:
            hideEverything(animated: animated && previous != .absent)
        }
    }

    /// Fold into the device (plan 工作包 B 折叠隐藏), 0.5 s — the card is *put away*, not destroyed:
    /// 0.00 `collapse` cue, rim bounces, billboard off, the shaft opens under the card, bloom peaks at 0.75
    /// 0.00–0.22 the plate squashes to [0.92, 0.06, 1] while its content fades out over 0.15 s
    /// 0.18–0.46 it drops onto the device and turns flat; the rays shorten with it; projector off at 0.30
    /// 0.42 12-particle burst + ripple + the shaft seals (0.30) + desk halo out (and the socket, unless kept)
    /// 0.50 the hologram is disabled.
    private func foldIntoDevice(animated: Bool, keepSocket: Bool) {
        // **V3-2a2 S4 / plan §4 E12**: the hand of cards goes into the card *before* the card goes into the
        // device — 0.2 s of "everything gathers up", then the existing 0.5 s fold. Without it the deck is
        // still fanned out behind a card that is already lying down.
        let tuck: Float = (animated && notes.deckOut) ? 0.2 : 0
        if tuck > 0 {
            tuckDeck(duration: tuck)
            foldTask?.cancel()
            foldTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(tuck * 1000)))
                guard let self, !Task.isCancelled, self.currentPresence == .absent else { return }
                self.foldCard(animated: animated, keepSocket: keepSocket, alreadyPaused: true)
            }
            // The whole 0.2 s tuck + 1.2 s fold is one brief effect as far as the audit is concerned, and
            // it is announced once rather than twice.
            pauseFootprintAudit(tuck + 1.2, reason: "fold")
            return
        }
        foldCard(animated: animated, keepSocket: keepSocket, alreadyPaused: false)
    }

    private func foldCard(animated: Bool, keepSocket: Bool, alreadyPaused: Bool) {
        // H0: the card lying down onto the screen is exactly the kind of brief effect the rule exempts.
        if !alreadyPaused { pauseFootprintAudit(animated ? 1.2 : 0.2, reason: "fold") }
        v4?.settleForV3Choreography(reason: "fold")
        // The fold's end pose is written in `hologram` space (it is where the unfold picks it up again).
        detachCardFromHinge()
        setHandTrail(false)
        isHandForm = false
        disarmHandFormProbe()
        // B4: the flip became a fold, so there is nothing left to predict.
        foldAnticipating = false
        overlay.hideAll(keepSocket: keepSocket)
        overlay.setSocketTappable(keepSocket)
        pixels.hide()
        idleScan.isEnabled = false
        cardGroup.components.remove(FloatComponent.self)
        suspendBillboard(true)
        audio.play(.collapse, on: anchorRoot)
        guard animated else {
            hologram.isEnabled = false
            well.hide()
            haloDisc.isEnabled = false          // v4 B3 §3.3, as at the end of the animated fold
            if !keepSocket { surface.isEnabled = false }
            return
        }
        print("[reveal] fold into device (\(keepSocket ? "dismiss" : "replay"))")
        // V3-4 §8: the star dust is born out of the LCD's edge over the 0.5 s the card takes to lie down, so
        // the light the card loses is visibly going into the device rather than simply going out.
        if sleepFXEnabled, keepSocket {
            sleepDust.isEnabled = true
            setSleepDust(rate: HologramController.sleepDustCount * 2, vortex: 0.2, attraction: 0)
        }
        pulseRim(scale: 1.05)
        setBloom(strength: look.bloomStrength, peak: 0.75, decay: 0.5)
        // Light continuity: the shaft opens *before* the card comes down, so the light the card is about to lose
        // is already waiting for it in the device.
        well.open(duration: 0.15)
        if keepSocket {
            overlay.showSocket(true)
            overlay.socket.components.set(TweenComponent(opacity: (from: overlay.socket.components[OpacityComponent.self]?.opacity ?? 0.4,
                                                                    to: RegistrationOverlay.socketFolded),
                                                         duration: 0.3, easing: .easeOutCubic))
        }
        // 0–0.22 squash, content out. Both scales are relative to where the card started (1 on the desk,
        // `handScale` in the hand), so a half-size card lies down instead of growing on its way to the screen.
        let k = max(0.01, cardGroup.scale.x)
        let squashed = SIMD3<Float>(0.92 * k, 0.06 * k, 1 * k)
        let folded = Self.foldedScale(from: k)
        cardGroup.components.set(TweenComponent(scale: (from: cardGroup.scale, to: squashed),
                                                duration: 0.22, easing: .easeInCubic))
        setCardFace { $0.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: 0.15, easing: .easeInCubic)) }
        landing.components.set(TweenComponent(opacity: (from: Self.landingLevel, to: 0), duration: 0.15, easing: .easeInCubic))
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func step(_ ms: Int) async -> Bool {
                try? await Task.sleep(for: .milliseconds(ms))
                return !Task.isCancelled && self.currentPresence == .absent
            }
            // 0.18–0.46 fall and lie down on the screen.
            guard await step(180) else { return }
            self.cardGroup.components.set(TweenComponent(
                scale: (from: squashed, to: folded),
                position: (from: self.cardGroup.position, to: [0, Self.cardRestY * 0.2, 0]),
                orientation: (from: self.cardGroup.orientation, to: HandFacing.base),
                // B4: 1 was hardcoded here; with the anticipation the card is already at 0.55 and a tween
                // that started from 1 would flash it back to full brightness on its way down.
                opacity: (from: self.cardGroup.components[OpacityComponent.self]?.opacity ?? 1, to: 0.15),
                duration: 0.28, easing: .easeInOutCubic))
            guard await step(120) else { return }
            self.projector.setVisible(false, animated: true)
            // 0.42 landing: the burst, the ripple, and the shaft sealing over it.
            guard await step(120) else { return }
            self.burst(count: 12)
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.1, endScale: 0.8, duration: 0.6, peak: 0.7)
            self.well.close(duration: 0.30)
            // v4 B3 §3.3: out of the tree when it is dark. Before, its `PulseComponent` (base 1) relit it to full the frame
            // the tween ended, and `applySurface` kept walking the dismissed desk after the device — round 2 run A's
            // `[footprint] surface.halo inside for 2.0 s` was that halo while the passport was lifted at 58–72°.
            // `igniteSurface` switches it back on.
            self.haloDisc.components.set(TweenComponent(scale: (from: self.haloDisc.scale, to: [0.6, 1, 0.6]),
                                                        opacity: (from: 1, to: 0), duration: 0.35, easing: .easeInCubic,
                                                        disableWhenDone: true))
            if !keepSocket {
                self.overlay.socket.components.set(TweenComponent(opacity: (from: 0.4, to: 0), duration: 0.3, easing: .easeInCubic, disableWhenDone: true))
            }
            guard await step(80) else { return }
            self.hologram.isEnabled = false
        }
    }

    /// Every steady-state opacity of the card, in one place. v1 scattered five copies of this through the
    /// choreography and they drifted apart. It deliberately says **nothing** about the light well: the well's
    /// level belongs to `showWellDimmed` / `startIdle`, and a reset that touched it would fight them.
    /// (`rim` and `landing` also carry a `PulseComponent`, whose `baseOpacity` matches these values — the pulse
    /// system re-writes their `OpacityComponent` every frame, so the two must agree.)
    func resetCardLayers() {
        // A cancelled reveal can leave a delayed tween on these layers; it would keep writing their opacity
        // (and, on `rim` / `landing`, keep the pulse suppressed) long after the card has moved on.
        let layers: [Entity] = [slab, rim, landing, cardAttachmentHolder, cardTagsHolder, cardAvatarHolder]
        for layer in layers { layer.components.remove(TweenComponent.self) }
        slab.components.set(OpacityComponent(opacity: 1))
        slab.scale = [1, 1, 1]
        rim.components.set(OpacityComponent(opacity: 0.6))
        landing.components.set(OpacityComponent(opacity: Self.landingLevel))
        setCardFace { $0.components.set(OpacityComponent(opacity: 1)) }
        // V3-3 C3: …and on its front. See `resetBackFace`.
        resetBackFace()
    }

    /// Searching shimmer while frozen (fades in over the first second): rim pulse 0.08 → 0.2, projector
    /// flicker, particles × 0.6, a scan line every 2 s.
    func setSearching(_ on: Bool) {
        guard on != isSearching else { return }
        isSearching = on
        applyRimBreath()
        projector.setSearching(on)
        searchTask?.cancel()
        searchTask = nil
        guard on else { return }
        searchTask = Task { @MainActor [weak self] in
            var first = true
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(first ? 1000 : 2000))
                first = false
                guard let self, !Task.isCancelled, self.isSearching, self.hologram.isEnabled else { return }
                self.idleScan.isEnabled = true
                self.idleScan.components.set(TweenComponent(
                    position: (from: [0, -HologramLayout.cardHeight / 2, 0.003], to: [0, HologramLayout.cardHeight / 2, 0.003]),
                    opacity: (from: 0.3, to: 0), duration: 0.5, easing: .easeInOutCubic, disableWhenDone: true))
            }
        }
    }

    /// The rim's breath: 0.08 / 10 s at rest, 0.2 / 2.4 s while the card is either searching (the gate's 3 s
    /// `.search`) or **holding** (V3-6 §1's 0.3 s). One writer, so the two cannot fight over it — the holding
    /// cue almost always lights first and the shimmer must not be able to turn the breath off under it.
    private func applyRimBreath() {
        let breathing = isSearching || isHolding
        var pulse = rim.components[PulseComponent.self] ?? PulseComponent(baseScale: 1, scaleAmplitude: 0, baseOpacity: 0.6, opacityAmplitude: 0.08, period: 10)
        pulse.opacityAmplitude = breathing ? 0.2 : 0.08
        pulse.period = breathing ? 2.4 : 10
        rim.components.set(pulse)
    }

    /// **V3-6 §1.** The card (and the hand of cards with it) goes to `holdingOpacity` over 0.5 s and comes
    /// back over 0.25 s. Opacity only — the pose is frozen by the gate, which is the point: the card stays
    /// exactly where the passport was last seen instead of being walked away by a wrist.
    private func setHolding(_ on: Bool, animated: Bool) {
        guard on != isHolding else { return }
        isHolding = on
        // v4 B2 §3.3: a folded card's opacity belongs to the fold (and then to whatever unfolds it) — the 0.6 dim and
        // its restore would fight both, and the restore would light a card still scaled down to the point.
        guard !pickup.folded else {
            applyRimBreath()
            return
        }
        let duration: Float = animated ? (on ? 0.5 : 0.25) : 0
        // v4 B5 §2 `hold-dim=off`: the rim's breath alone says "lost"; the card and the gallery stay opaque.
        let target: Float = on && holdDims ? Self.holdingOpacity : 1
        // **Never on top of a choreography that already owns the entity.** `updateHoldingCue` runs *after*
        // `runTransition`, and a fold (`runHide` → `foldCard`), a thaw or a carry has a scale + position
        // tween on `cardGroup` at that moment: replacing it with an opacity-only tween would cancel the
        // fold. When one is in flight the level is written straight to the `OpacityComponent` instead —
        // a tween that animates opacity overwrites it on its next frame (which is what we want), and one
        // that does not leaves it standing (which is also what we want).
        dim(cardGroup, to: target, duration: duration)
        if notes.isOut || notes.deckOut { dim(notes.group, to: target, duration: duration) }
        applyRimBreath()
    }

    /// **v4 B5 §2.** `cmd perf hold-dim=` changed while the passport is lost: the dim follows at once.
    func refreshHoldingDim() {
        guard isHolding, !pickup.folded else { return }
        let target: Float = holdDims ? Self.holdingOpacity : 1
        dim(cardGroup, to: target, duration: 0.25)
        if notes.isOut || notes.deckOut { dim(notes.group, to: target, duration: 0.25) }
    }

    /// One entity's share of the holding cue — see `setHolding` for why an in-flight tween is left alone.
    private func dim(_ entity: Entity, to target: Float, duration: Float) {
        guard entity.components[TweenComponent.self] == nil else {
            entity.components.set(OpacityComponent(opacity: target))
            return
        }
        let from = entity.components[OpacityComponent.self]?.opacity ?? 1
        entity.components.set(TweenComponent(opacity: (from: from, to: target),
                                             duration: duration, easing: .easeInOutCubic))
    }

    /// **V3-6 §1.** Watches the presence for "the camera cannot see the passport": `held(.untracked)` (ARKit
    /// says the anchor is not tracked) and `held(.stale)` (it stopped reporting at all, which is also where
    /// `held(.world) → held(.stale)` lands when a world ends on a passport nobody can see). A hold for a
    /// button, a theme change or a world is **not** a loss and must stay silent.
    private func updateHoldingCue(animated: Bool) {
        var lost = false
        if case .held(let reason) = currentPresence, reason == .untracked || reason == .stale, hologram.isEnabled {
            lost = true
        }
        guard lost != holdingArmed else { return }
        holdingArmed = lost
        holdingTask?.cancel()
        holdingTask = nil
        guard lost else {
            guard isHolding else { holdingSince = nil; return }
            let seconds = holdingSince.map { Date().timeIntervalSinceReferenceDate - $0 } ?? 0
            holdingSince = nil
            setHolding(false, animated: animated)
            // A card that is *leaving* (a dismiss, a teardown) is not following anything again: restore the
            // opacity it borrowed, silently. Only a card that is back on the passport says so.
            guard currentPresence != .absent else { return }
            print(String(format: "[reveal] following again (%.1f s)", seconds))
            return
        }
        holdingSince = Date().timeIntervalSinceReferenceDate
        holdingTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(HologramController.holdingCueAfter * 1000)))
            guard let self, !Task.isCancelled, self.holdingArmed, self.hologram.isEnabled else { return }
            print("[reveal] holding (object lost)")
            self.setHolding(true, animated: true)
        }
    }

    func setFaceUser(_ enabled: Bool) {
        guard enabled != faceUser else { return }
        faceUser = enabled
        applyBillboard()
    }

    /// The fold happens in the **device's** frame — the card lies down onto the screen — so the billboard is off
    /// for its duration no matter what the app asks for. (The RealityView re-applies `faceUser` on every
    /// observable change, which lands right in the middle of the fold.)
    private func suspendBillboard(_ suspended: Bool) {
        guard suspended != billboardSuspended else { return }
        billboardSuspended = suspended
        applyBillboard()
    }

    private func applyBillboard() {
        if faceUser, !billboardSuspended {
            var billboard = BillboardComponent()
            // v4 B1: held at 0 while an entrance plays (the card stays in the ribbon's outline / on its path off
            // the screen), eased back to 1 after it (`V4CardIntegration.step`).
            if let v4 {
                billboard.blendFactor = v4.currentBillboardBlend
                v4.billboardReset()
            }
            cardGroup.components.set(billboard)
        } else {
            cardGroup.components.remove(BillboardComponent.self)
        }
    }

    // MARK: - Desk buttons

    /// Extra tappable orb on the desk arc (used by the dev P0 probe). `angleDegrees` 0 = straight toward the reader.
    @discardableResult
    func addDeskButton(name: String, tint: UIColor, angleDegrees: Float) -> Entity {
        let angle = angleDegrees * .pi / 180
        let position = SIMD3<Float>(sin(angle) * Self.orbArcRadius, Self.orbRadius + 0.004, cos(angle) * Self.orbArcRadius)
        let orb = ModelEntity(mesh: .generateSphere(radius: Self.orbRadius * 0.8), materials: [HologramController.emissive(tint, intensity: 0.8, opacity: 1)])
        orb.name = name
        orb.position = position
        orb.components.set(InputTargetComponent())
        orb.components.set(HoverEffectComponent())
        orb.components.set(CollisionComponent(shapes: [.generateSphere(radius: Self.orbRadius * 1.6)]))
        orbGroup.addChild(orb)
        return orb
    }

    // MARK: - Events

    /// One-shot expanding ring on the desk (event ripple), removed when finished.
    func spawnRipple(at position: SIMD3<Float>, tint: UIColor, startScale: Float, endScale: Float, duration: Float, peak: Float) {
        // v4 B2: a desk that is out of the tree (the card is in a hand, a world or folded into the device) has no one
        // to show a ripple to — and a ripple parked on it would play, stale, the moment the desk came back.
        guard surface.isEnabled else { return }
        let ring = ModelEntity(mesh: .generatePlane(width: 0.34, depth: 0.34), materials: [FXMaterials.glow(fx.ring, tint: tint, opacity: 1)])
        ring.position = position
        ring.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        ring.components.set(RippleComponent(startScale: startScale, endScale: endScale, period: duration, peakOpacity: peak, repeats: false, removeWhenDone: true))
        surface.addChild(ring)
    }

    /// **V3-2b B5 / plan §4 E13.** The celebration ring for a passport that is *in the wearer's hand*: it
    /// comes out of the **device** (the screen frame S, 1 mm above its face) instead of the desk, which in
    /// the hand form is faded out and metres away.
    ///
    /// Diameters, not scales: the ring's band sits at 0.42 of the mesh (`FXTextures.ring`), and the number
    /// that matters is where its clear middle starts — the prism's half-diagonal is 60.3 mm on the AI
    /// Passport, so the plan's 0.12 m start would put the band 0.3 mm inside it. 0.13 m clears it outright
    /// and the `.circularHole` probe can say so without an argument about a boundary.
    func spawnDeviceRing(tint: UIColor, startDiameter: Float, endDiameter: Float, duration: Float, peak: Float) {
        let plane: Float = 0.34
        let band = 0.42 * plane
        let ring = ModelEntity(mesh: .generatePlane(width: plane, depth: plane),
                               materials: [FXMaterials.glow(fx.ring, tint: tint, opacity: 1)])
        ring.name = "celebrate.ring"
        ring.position = [0, 0.001, 0]
        ring.components.set(ModelSortGroupComponent(group: sortGroup, order: 1))
        ring.components.set(FootprintProbeComponent(.circularHole(startDiameter / 2)))
        ring.components.set(RippleComponent(startScale: startDiameter / 2 / band,
                                            endScale: endDiameter / 2 / band,
                                            period: duration, peakOpacity: peak,
                                            repeats: false, removeWhenDone: true))
        // v4 B1: a ring *around the device*, so it is centred on the case.
        caseRoot.addChild(ring)
    }

    func burst(count: Int) {
        guard var particles = particleEntity.components[ParticleEmitterComponent.self] else { return }
        particles.burstCount = count
        particles.burst()
        PerfCensus.noteBurst(count, life: particles.mainEmitter.lifeSpan)
        particleEntity.components.set(particles)
    }

    /// Bloom strength on both bloomed subtrees; `peak` flashes to a higher value and eases back.
    func setBloom(strength: Float, peak: Float? = nil, decay: Float = 0.6) {
        bloomTask?.cancel()
        func write(_ value: Float) {
            var options = BloomOptionsComponent()
            options.strength = value
            options.threshold = 1.0
            options.blurRadius = 2
            hologram.components.set(options)
            surface.components.set(options)
            // The mini card's holder is the third bloomed subtree: the card keeps its rim glow when it is not
            // hanging under `hologram`.
            miniHolder.components.set(options)
            // v4 B3: and the gold point, which hangs off the case frame.
            pickup.point.components.set(options)
        }
        guard let peak else { write(strength); return }
        write(peak)
        bloomTask = Task { @MainActor in
            let steps = max(1, Int(decay * 30))
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(33))
                if Task.isCancelled { return }
                let t = Float(step) / Float(steps)
                write(peak + (strength - peak) * (1 - pow(1 - t, 2)))
            }
        }
    }

    // MARK: - Choreography

    /// First detection: a quick flash of the image footprint and a ring leaving the device. The
    /// registration layer's "backlight" is deliberately saved for the reveal (design doc §3.0).
    func playAcquireCue() {
        acquire.isEnabled = true
        flash.isEnabled = true
        flash.components.set(TweenComponent(
            scale: (from: [0.9, 1, 0.9], to: [1.2, 1, 1.2]),
            opacity: (from: 0.7, to: 0), duration: 0.4, easing: .easeOutCubic, disableWhenDone: true))
        acquireRing.isEnabled = true
        acquireRing.components.set(TweenComponent(
            scale: (from: [0.25, 1, 0.25], to: [2.0, 1, 2.0]),
            opacity: (from: 0.9, to: 0), delay: 0.03, duration: 0.55, easing: .easeOutCubic, disableWhenDone: true))
        audio.play(.acquire, on: anchorRoot)
    }

    /// Desk glow on (background halo, orbs); `level` 0.5 = detected-but-moving, 1 = presenting.
    func igniteSurface(level: Float, animated: Bool) {
        // v3 H2: on the way to an unfold the gate passes through `absent → acquiring`, which lands here — and
        // the desk it would light is 40 cm away on a table the wearer is no longer looking at.
        guard !deskFaded else { return }
        let d: Float = animated ? 0.6 : 0
        // v4 B3 §3.3: a fold leaves the halo out of the tree (`foldCard`).
        haloDisc.isEnabled = true
        haloDisc.components.set(TweenComponent(
            scale: (from: [0.5, 1, 0.5], to: [1, 1, 1]),
            opacity: (from: 0, to: level), duration: d, easing: .easeOutCubic))
        var pulse = haloDisc.components[PulseComponent.self] ?? PulseComponent(baseScale: 1, scaleAmplitude: 0.04, baseOpacity: 1, opacityAmplitude: 0.15, period: 4.2)
        pulse.baseOpacity = level
        pulse.opacityAmplitude = 0.15 * level
        haloDisc.components.set(pulse)
        orbGroup.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: animated ? 0.1 : 0, duration: animated ? 0.5 : 0, easing: .easeOutCubic))
    }

    /// A1 timeline (t = 0 at `.expanded`), design doc §3.1:
    /// 0.00–0.35 registration layer lights up (paper → lit, flicker at 0.20)   · powerOn
    /// 0.35–0.95 scan line sweeps bottom → top, bitmap becomes wireframe, sparks · scan; ripple + 60 particles at the top
    /// 0.95–1.25 wireframe pries off 2.5 cm, tilts, edge light leaks, paper ghost fades · liftOff, 120 particles, bloom peak
    /// 1.25–2.05 wireframe flies a backward arc to the card pose while growing; cross-fades into the glass card 1.55–1.95
    ///            shaft grows from 1.35; chips split off the card at 1.90 / 2.03 / 2.16 with 12 sparks each · chip dings
    /// 2.05–2.40 spring settle, frame breathing, idle float                    · settle chord
    private func runScanDissolveReveal(animated: Bool) {
        pauseFootprintAudit(animated ? 4 : 0.2, reason: "scan reveal")
        detachCardFromHinge()
        let k: Float = animated ? 1 : 0
        overlay.resetForReveal()
        pixels.hide()
        hologram.isEnabled = true
        projector.setVisible(false, animated: false)
        cardGroup.isEnabled = true
        cardGroup.transform = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0]),
                                        translation: [0, HologramLayout.cardCenterHeight, 0])
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.set(OpacityComponent(opacity: 0))
        resetCardLayers()
        igniteSurface(level: 0.5, animated: false)

        let footprint = self.footprint
        let holoScale = HologramLayout.cardHeight / footprint.y
        let standing = simd_quatf(angle: .pi / 2 + Self.cardTilt, axis: [1, 0, 0])   // lying XZ quad → upright, facing the reader
        let pried = simd_quatf(angle: 12 * .pi / 180, axis: [1, 0, 0])               // top edge lifts toward the reader

        if !animated {
            overlay.hideAll()
            overlay.root.isEnabled = true
            overlay.showSocket(true)
            overlay.socket.components.set(OpacityComponent(opacity: 0.4))
            cardGroup.components.set(OpacityComponent(opacity: 1))
            projector.setVisible(true, animated: false)
            startIdle()
            return
        }

        // 0.00–0.35 backlight (skipped with --overlay-lit off: the scan starts at once)
        let lit = overlay.litLayers
        if lit {
            overlay.paper.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: 0.2 * k, easing: .easeOutCubic))
            overlay.lit.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: 0.05 * k, duration: 0.3 * k, easing: .easeOutCubic))
        }
        overlay.showSocket(true)
        overlay.socket.components.set(TweenComponent(opacity: (from: 0, to: 0.4), duration: 0.35 * k, easing: .easeOutCubic))
        audio.play(.powerOn, on: anchorRoot)

        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func wait(_ seconds: Float) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if Task.isCancelled { return false }
                return self.revealMayContinue
            }
            if lit {
                // Old-screen flicker at 0.20 s.
                guard await wait(0.2) else { return }
                self.overlay.lit.components.set(TweenComponent(opacity: (from: 0.85, to: 1), duration: 0.08, easing: .easeOutCubic))
                guard await wait(0.15) else { return }
            } else {
                guard await wait(0.1) else { return }
            }

            // 0.35–0.95 scan
            self.overlay.root.components.set(ScanRevealComponent(width: footprint.x, depth: footprint.y, duration: 0.6))
            self.audio.play(.scan, on: self.anchorRoot)

            guard await wait(0.6) else { return }
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.35, endScale: 1.45, duration: 1.1, peak: 0.6)
            self.burst(count: 60)

            // 0.95–1.25 lift-off
            self.overlay.edge.isEnabled = true
            self.overlay.edge.components.set(TweenComponent(opacity: (from: 0, to: 0.8), duration: 0.3, easing: .easeOutCubic))
            self.overlay.holoGroup.components.set(TweenComponent(
                position: (from: .zero, to: [0, 0.025, 0]),
                orientation: (from: simd_quatf(angle: 0, axis: [1, 0, 0]), to: pried),
                duration: 0.3, easing: .easeOutCubic))
            if lit {
                self.overlay.lit.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: 0.25, easing: .easeInCubic, disableWhenDone: true))
                self.overlay.paper.components.set(TweenComponent(opacity: (from: 1, to: 0), delay: 0.1, duration: 0.3, easing: .easeInCubic, disableWhenDone: true))
            }
            self.igniteSurface(level: 1, animated: true)
            self.setBloom(strength: self.look.bloomStrength, peak: 0.9, decay: 0.6)
            self.burst(count: 120)
            self.audio.play(.liftOff, on: self.anchorRoot)

            // 1.25–2.05 grow: backward arc, uniform scale to card height, spring landing
            guard await wait(0.3) else { return }
            self.overlay.holoGroup.components.set(TweenComponent(
                scale: (from: [1, 1, 1], to: [holoScale, holoScale, holoScale]),
                position: (from: [0, 0.025, 0], to: [0, HologramLayout.cardCenterHeight, 0]),
                orientation: (from: pried, to: standing),
                arcOffset: [0, 0, -0.06],
                duration: 0.85, easing: .spring(response: 0.55, damping: 0.8)))
            self.overlay.edge.components.set(TweenComponent(opacity: (from: 0.8, to: 0.35), duration: 0.8, easing: .easeOutCubic))

            // projector from 1.35
            guard await wait(0.1) else { return }
            self.projector.setVisible(true, animated: true)

            // cross-fade 1.55–1.95
            guard await wait(0.2) else { return }
            self.overlay.holo.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: 0.4, easing: .easeInOutCubic))
            self.overlay.edge.components.set(TweenComponent(opacity: (from: 0.35, to: 0), duration: 0.4, easing: .easeInOutCubic, disableWhenDone: true))
            self.cardGroup.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: 0.4, easing: .easeInOutCubic))

            // chips split off the card 1.90 / 2.03 / 2.16
            guard await wait(0.35) else { return }
            for index in 0..<3 {
                if index > 0 { guard await wait(0.13) else { return } }
                self.burst(count: 12)
                self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index], on: self.anchorRoot)
            }

            // landing follow-through: frame flare + projector rays flare once
            self.rim.components.set(TweenComponent(scale: (from: [1.04, 1.04, 1.04], to: [1, 1, 1]), duration: 0.35, easing: .spring(response: 0.35, damping: 0.7)))
            self.flareBeam()
            self.overlay.holoGroup.isEnabled = false
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    /// A4 "pixel reassembly". Normalised timeline over 2.7 s (see `PixelCloud.evaluate`):
    /// 0.00–0.27 s backlight on the paper · powerOn
    /// 0.27–1.2 s pixels lift row by row and start to swirl (lit quad fades under them) · scan hiss, 60-particle burst
    /// 1.2–1.9 s vortex at full height, bloom peak, desk halo to 1 · liftOff whoosh, 120 particles
    /// 1.9–2.43 s pixels gather onto the card face at card size · gather tone
    /// 2.43–2.7 s pixels fade, glass card + frame cross-fade in, projector on, chips split off · dings, settle
    private func runCloudReveal(mode: PixelCloud.Mode, animated: Bool) {
        // The ink cinematic's first rise comes out of the screen on purpose (brief FX, ≤ 4 s).
        pauseFootprintAudit(animated ? 4 : 0.2, reason: "ink cinematic")
        detachCardFromHinge()
        pixels.mode = mode
        let ink = mode == .inkLift
        overlay.resetForReveal()
        // V3-2a H0: `resetForReveal` arms the scan-dissolve's holo quad over the screen. The ink / pixel path
        // never touches it (the cloud *is* the reveal) — it only sat there for the rest of the session,
        // clipped to nothing but present. Off it goes, so the audit and the camera agree.
        overlay.holoGroup.isEnabled = false
        hologram.isEnabled = true
        projector.setVisible(false, animated: false)
        cardGroup.isEnabled = true
        cardGroup.transform = Transform(scale: [1, 1, 1], rotation: simd_quatf(angle: Self.cardTilt, axis: [1, 0, 0]),
                                        translation: [0, HologramLayout.cardCenterHeight, 0])
        cardGroup.components.remove(FloatComponent.self)
        cardGroup.components.set(OpacityComponent(opacity: 0))
        resetCardLayers()
        igniteSurface(level: 0.5, animated: false)

        if !animated {
            overlay.hideAll()
            overlay.root.isEnabled = true
            overlay.showSocket(true)
            overlay.socket.components.set(OpacityComponent(opacity: 0.4))
            cardGroup.components.set(OpacityComponent(opacity: 1))
            projector.setVisible(true, animated: false)
            startIdle()
            return
        }

        let total = ink ? PixelRevealSystem.inkDuration : PixelRevealSystem.revealDuration
        // Backlight, then the pixels take over from the lit bitmap (no backlight with --overlay-lit off).
        if overlay.litLayers {
            overlay.paper.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: 0.2, easing: .easeOutCubic))
            overlay.lit.components.set(TweenComponent(opacity: (from: 0, to: 1), delay: 0.05, duration: 0.22, easing: .easeOutCubic))
        }
        overlay.showSocket(true)
        overlay.socket.components.set(TweenComponent(opacity: (from: 0, to: 0.4), duration: 0.3, easing: .easeOutCubic))
        audio.play(.powerOn, on: anchorRoot)

        pixels.root.isEnabled = true
        pixels.write(t: 0, ghostLag: 0, cardGroup: cardGroup, flatOrientation: simd_quatf(angle: -.pi / 2, axis: [1, 0, 0]))
        pixels.root.components.set(PixelRevealComponent(cloud: pixels, cardGroup: cardGroup, direction: 1, duration: total, onFinish: { [weak self] in
            self?.pixels.hide()
        }))
        pixels.root.components.set(PerfProbeComponent(label: "\(ink ? "ink" : "pixel") reveal (\(pixels.instanceCount) instances)", duration: total))

        if ink {
            runInkBeats(total: total)
            return
        }
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func wait(_ seconds: Float) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if Task.isCancelled { return false }
                return self.revealMayContinue
            }
            // Lift begins (t = 0.10): lit bitmap dissolves under the departing pixels.
            guard await wait(total * PixelCloud.liftStart) else { return }
            if self.overlay.litLayers {
                self.overlay.lit.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: total * PixelCloud.liftSpan, easing: .easeInCubic, disableWhenDone: true))
                self.overlay.paper.components.set(TweenComponent(opacity: (from: 1, to: 0), delay: 0.2, duration: total * PixelCloud.liftSpan, easing: .easeInCubic, disableWhenDone: true))
            }
            self.audio.play(.scan, on: self.anchorRoot)
            self.burst(count: 60)

            // Full vortex (t ≈ 0.45): the desk lights up, bloom peaks.
            guard await wait(total * (PixelCloud.liftStart + PixelCloud.liftSpan) - total * PixelCloud.liftStart) else { return }
            self.igniteSurface(level: 1, animated: true)
            self.setBloom(strength: self.look.bloomStrength, peak: 0.95, decay: 0.8)
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.35, endScale: 1.45, duration: 1.1, peak: 0.6)
            self.burst(count: 120)
            self.audio.play(.liftOff, on: self.anchorRoot)

            // Gather (t = 0.70).
            guard await wait(total * (PixelCloud.gatherStart - PixelCloud.liftStart - PixelCloud.liftSpan)) else { return }
            self.audio.play(.acquire, on: self.anchorRoot)

            // Landing (t = 0.90): glass card fades in while the pixels fade out; projector switches on.
            guard await wait(total * (PixelCloud.gatherEnd - PixelCloud.gatherStart)) else { return }
            self.cardGroup.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: total * (1 - PixelCloud.gatherEnd), easing: .easeInOutCubic))
            self.projector.setVisible(true, animated: true)
            self.rim.components.set(TweenComponent(scale: (from: [1.04, 1.04, 1.04], to: [1, 1, 1]), delay: 0.2, duration: 0.4, easing: .spring(response: 0.35, damping: 0.7)))

            // Chips split off the card edge.
            guard await wait(total * (1 - PixelCloud.gatherEnd) * 0.6) else { return }
            for index in 0..<3 {
                if index > 0 { guard await wait(0.13) else { return } }
                self.burst(count: 12)
                self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index], on: self.anchorRoot)
            }
            self.flareBeam()
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    /// Event beats for the ink-extraction reveal (see `PixelCloud.evaluateInk` for the motion):
    /// 0.12 lit bitmap fades as the ink lifts · scan hiss · 0.25 paper dusts · 0.32 flip: desk ignites, bloom peak,
    /// ripple, whoosh · 0.55–0.92 glyph bands typeset with a glint each · 0.92 glass card fades in, projector on, chips.
    private func runInkBeats(total: Float) {
        choreography = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func wait(_ seconds: Float) async -> Bool {
                try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                if Task.isCancelled { return false }
                return self.revealMayContinue
            }
            guard await wait(total * PixelCloud.inkLiftStart) else { return }
            if self.overlay.litLayers {
                self.overlay.lit.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: total * 0.18, easing: .easeInCubic, disableWhenDone: true))
                self.overlay.paper.components.set(TweenComponent(opacity: (from: 1, to: 0), delay: total * 0.13, duration: total * 0.25, easing: .easeInCubic, disableWhenDone: true))
            }
            // The light well drops open beneath the lifting ink (light continuity: the glow the paper had is now depth).
            self.well.open(duration: total * 0.4)
            self.audio.play(.scan, on: self.anchorRoot)

            guard await wait(total * (PixelCloud.inkFlipStart - PixelCloud.inkLiftStart)) else { return }
            self.igniteSurface(level: 1, animated: true)
            self.setBloom(strength: self.look.bloomStrength, peak: 0.9, decay: 0.8)
            self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.35, endScale: 1.45, duration: 1.1, peak: 0.6)
            self.burst(count: 80)
            self.audio.play(.liftOff, on: self.anchorRoot)

            // Typeset glints: avatar, name, handle, location, followers, chips.
            guard await wait(total * (PixelCloud.inkTypesetStart - PixelCloud.inkFlipStart)) else { return }
            let span = total * (PixelCloud.inkTypesetEnd - PixelCloud.inkTypesetStart)
            for i in 0..<5 {
                self.audio.play(i % 2 == 0 ? .acquire : .chip0, on: self.anchorRoot)
                self.burst(count: 10)
                guard await wait(span * 0.75 / 5) else { return }
            }

            // Formation (motion principle: the card forms from the particles, it does not crossfade over them).
            // 1) hold: every particle sits in the card's silhouette (glyphs on the layout, paper on the frame outline);
            // 2) the frame resolves where the frame particles are, and they shrink into it;
            // 3) the glass body resolves under the glyph particles, which shrink into the type.
            guard await wait(span * 0.25) else { return }
            let hold = total * (PixelCloud.inkHoldEnd - PixelCloud.inkTypesetEnd)
            let frameResolve = total * (PixelCloud.inkFrameResolveEnd - PixelCloud.inkHoldEnd)
            let bodyResolve = total * (1 - PixelCloud.inkFrameResolveEnd)
            self.cardGroup.components.set(OpacityComponent(opacity: 1))
            self.setCardFace { $0.components.set(OpacityComponent(opacity: 0)) }
            // The slab has no thickness yet: it is a sheet in the plane the ink is standing in, and it *swells*
            // into a 12 mm plate as it resolves (outline continuity — the card is not cross-faded over the ink).
            self.slab.components.set(OpacityComponent(opacity: 0))
            self.slab.scale = [1, 1, 0.2]
            // `rim` and `landing` breathe (`PulseComponent`), and the pulse system re-writes their opacity every
            // frame unless a tween owns the entity — so "stay dark until your beat" has to *be* a tween, installed
            // now with the wait baked in as a delay. A bare `OpacityComponent(0)` here popped both on at once.
            self.rim.components.set(TweenComponent(scale: (from: [1.02, 1.02, 1.02], to: [1, 1, 1]),
                                                   opacity: (from: 0, to: 0.6), delay: hold, duration: frameResolve, easing: .easeOutCubic))
            self.landing.components.set(TweenComponent(opacity: (from: 0, to: Self.landingLevel),
                                                       delay: hold + frameResolve + bodyResolve * 0.3,
                                                       duration: bodyResolve, easing: .easeOutCubic))
            // The shaft stays open at the idle level for the rest of the card's life instead of sealing here.
            if HologramLayout.wellIdleLevel > 0 {
                self.well.dim(to: HologramLayout.wellIdleLevel, duration: hold + frameResolve)
            } else {
                self.well.close(duration: hold + frameResolve)
            }
            guard await wait(hold) else { return }
            self.audio.play(.acquire, on: self.anchorRoot)
            guard await wait(frameResolve) else { return }
            // Body: the sheet thickens into the slab while the type fades up on it, and the beam's landing pool
            // lights under the lower edge as the projector comes on.
            self.slab.components.set(TweenComponent(scale: (from: [1, 1, 0.2], to: [1, 1, 1]), opacity: (from: 0, to: 1),
                                                    duration: bodyResolve, easing: .easeOutCubic))
            self.setCardFace { $0.components.set(TweenComponent(opacity: (from: 0, to: 1), duration: bodyResolve, easing: .easeInOutCubic)) }
            self.projector.setVisible(true, animated: true)
            guard await wait(bodyResolve * 0.6) else { return }
            for index in 0..<3 {
                if index > 0 { guard await wait(0.13) else { return } }
                self.burst(count: 12)
                self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index], on: self.anchorRoot)
            }
            self.flareBeam()
            self.audio.play(.settle, on: self.anchorRoot)
            self.startIdle()
        }
    }

    /// Idle: ±1.5 mm float, rim breathing (PulseComponent already on `rim`), a faint scan
    /// line across the glass every 8–12 s.
    func startIdle() {
        if pixelsInFlight { endPixelsInFlight() }
        // Every steady state on the desk ends here — which is exactly when the note fan may be thrown.
        notes.onIdle?()
        // Convergence point of every steady-state path (both reveals, reentry, settle, celebration): whatever got
        // the card here, the shaft ends up open at the idle level.
        if !well.isOpen { showWellDimmed(animated: false) }
        idleTask?.cancel()
        // v4 B1: the hero card breathes and sweeps by itself (A4's idle: 1 mm / 5 s, a sweep every 8–12 s) — v3's
        // float would be a second breath, and v3's scan line is the sweep's v3 ancestor.
        if v4 != nil { return noteV4Idle() }
        cardGroup.components.set(FloatComponent(basePosition: [0, HologramLayout.cardCenterHeight, 0], amplitude: 0.0015, period: 5))
        idleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let delay = 8.0 + Double.random(in: 0...4)
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard let self, !Task.isCancelled, self.currentPresence == .expanded, !self.isSearching else { return }
                self.idleScan.isEnabled = true
                self.idleScan.components.set(TweenComponent(
                    position: (from: [0, -HologramLayout.cardHeight / 2, 0.003], to: [0, HologramLayout.cardHeight / 2, 0.003]),
                    opacity: (from: 0.35, to: 0), duration: 0.4, easing: .easeInOutCubic, disableWhenDone: true))
            }
        }
    }

    /// Fade the whole presentation out (card + shaft + surface) and disable it.
    private func hideEverything(animated: Bool) {
        let k: Float = animated ? 1 : 0
        acquire.isEnabled = false
        overlay.hideAll()
        if animated { well.close(duration: 0.4) } else { well.hide() }
        resetFollower()          // whatever comes back next is placed, not glided in from here
        cardGroup.components.remove(FloatComponent.self)
        if hologram.isEnabled {
            cardGroup.components.set(TweenComponent(
                scale: (from: cardGroup.scale, to: [0.8, 0.8, 0.8]),
                position: (from: cardGroup.position, to: cardGroup.position + [0, 0.03, 0]),
                opacity: (from: 1, to: 0), duration: k * 0.4, easing: .easeInCubic))
            projector.setVisible(false, animated: animated)
            pixels.hide()
        }
        if surface.isEnabled {
            haloDisc.components.set(TweenComponent(scale: (from: haloDisc.scale, to: [0.5, 1, 0.5]),
                                                   opacity: (from: 1, to: 0), duration: k * 0.45, easing: .easeInCubic))
            orbGroup.components.set(TweenComponent(opacity: (from: 1, to: 0), duration: k * 0.35, easing: .easeInCubic))
        }
        choreography = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(k * 480)))
            guard let self, !Task.isCancelled, self.currentPresence == .absent else { return }
            self.hologram.isEnabled = false
            self.surface.isEnabled = false
        }
    }

    // MARK: - Private

    func updateParticleRate() {
        guard var particles = particleEntity.components[ParticleEmitterComponent.self] else { return }
        var scale: Float
        switch currentPresence {
        case .absent, .acquiring: scale = 0
        case .carrying: scale = 0.35
        case .expanded, .settling: scale = 1
        case .held: scale = isSearching ? 0.6 : 1
        }
        // v4 B1: v3's resident white motes stand down while the ribbon flies and the card dissolves in — the gold dust
        // is the one particle language of that moment (bible §3: ≤ 3 things competing for attention).
        if v4?.quietsDeskParticles == true { scale = 0 }
        // **v4 B2.** …and in the hand form. They rise out of a box around the screen: the desk's ambient life, and in
        // round 1 one of the twelve emitters still alive in every 45 fps hand window. The one-shot bursts the hand
        // uses (the unfold's 12, a page flip's 20) go through `burst(count:)`, which fires with `isEmitting` off.
        if isHandForm { scale = 0 }
        particles.isEmitting = scale > 0
        // v4 B5 §3: …times the resident motes' share (`motes`).
        particles.mainEmitter.birthRate = look.particleBirthRate * scale * residentMotesScale
        particleEntity.components.set(particles)
    }

    /// One-shot sparks from the avatar disc (celebration): 48 particles over ≈ 0.7 s.
    private static func avatarSparkEmitter(sprite: TextureResource, tint: UIColor) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .sphere
        p.emitterShapeSize = SIMD3<Float>(repeating: 0.02)
        p.birthLocation = .surface
        p.birthDirection = .normal
        p.speed = 0.16
        p.speedVariation = 0.08
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 0.7
        p.mainEmitter.lifeSpanVariation = 0.2
        p.mainEmitter.size = 0.0022
        p.mainEmitter.sizeVariation = 0.001
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.3
        p.mainEmitter.acceleration = [0, -0.12, 0]
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.color = .evolving(start: .single(tint), end: .single(tint.withAlphaComponent(0)))
        return p
    }

    // MARK: - Materials

    static func unlit(_ color: UIColor, opacity: Float) -> UnlitMaterial {
        var material = UnlitMaterial()
        material.color = .init(tint: color, texture: nil)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    /// The frosted slab: milky white, mostly transparent, clear-coated so the edge catches a highlight, and
    /// with a **low emissive floor** — inside an opaque world shell there is no light at all, and a purely lit
    /// PBR plate would go black there. 0.22 is under the bloom threshold, so it glows without burning.
    static func slabMaterial(look: HologramLook) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: UIColor(white: 0.97, alpha: 1), texture: nil)
        material.roughness = .init(floatLiteral: 0.35)
        material.metallic = .init(floatLiteral: 0)
        material.clearcoat = .init(floatLiteral: 1.0)
        material.clearcoatRoughness = .init(floatLiteral: 0.06)
        material.emissiveColor = .init(color: UIColor.white.mixed(with: look.tint, by: 0.5), texture: nil)
        material.emissiveIntensity = 0.22
        material.blending = .transparent(opacity: .init(floatLiteral: look.slabOpacity))
        // Back faces culled (a transparent solid drawn twice reads as a double-exposure) and no depth writes,
        // so the sort group above decides what is in front of what.
        material.faceCulling = .back
        material.writesDepth = false
        return material
    }

    /// Emissive PBR with a falloff texture: a soft glow Bloom can still pick up (`FXMaterials.glow` is unlit
    /// and therefore never blooms).
    static func emissive(_ color: UIColor, texture: TextureResource, intensity: Float, opacity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color, texture: .init(texture))
        material.emissiveColor = .init(color: color, texture: .init(texture))
        material.emissiveIntensity = intensity
        material.roughness = .init(floatLiteral: 0.5)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.opacityThreshold = nil
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }

    /// Emissive PBR: the bright things Bloom picks up (threshold 1.0 → intensity > 1 blooms).
    static func emissive(_ color: UIColor, intensity: Float, opacity: Float) -> PhysicallyBasedMaterial {
        var material = PhysicallyBasedMaterial()
        material.baseColor = .init(tint: color, texture: nil)
        material.emissiveColor = .init(color: color, texture: nil)
        material.emissiveIntensity = intensity
        material.roughness = .init(floatLiteral: 0.5)
        material.blending = .transparent(opacity: .init(floatLiteral: opacity))
        material.faceCulling = .none
        material.writesDepth = false
        return material
    }
}
