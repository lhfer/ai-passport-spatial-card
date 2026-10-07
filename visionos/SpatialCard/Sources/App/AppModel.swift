import Foundation
import Observation
import RealityKit
import SwiftUI

/// App-wide state shared by the immersive space and its in-space controls.
@MainActor
@Observable
final class AppModel {
    static let immersiveSpaceID = "SpatialCardSpace"
    static let returnWindowID = "SpatialCardReturn"

    /// Bound to the ImmersiveSpace's `immersionStyle(selection:)`; written only from `wantsFullImmersion`.
    var immersionStyle: ImmersionStyle = .mixed
    /// Whole-passthrough tint (`preferredSurroundingsEffect(.colorMultiply)`); nil = untouched.
    var surroundingsTint: Color?
    /// Dev-only P0 platform probes (visionOS 27 assumptions); see `P0Probes`.
    let probes = P0Probes()
    /// `--reveal pixel|scan` forces a reveal choreography for A/B testing; nil = the default (ink).
    var revealOverride: RevealKind?
    /// 异世界 engine: worlds behind desk coins (design doc §5). Only the two shipped worlds unless `--all-worlds`.
    let worlds: WorldEngine
    /// True while the immersive space is on screen (set by ImmersiveView); used to reopen it after Safari.
    var immersiveSpaceIsOpen = false
    /// The user left the space with one of our 退出 buttons (not Safari / the system): the return window
    /// must wait for a tap instead of reopening the space by itself.
    var userDismissedSpace = false
    /// Places the hologram in front of the user without tracking (simulator / no device at hand).
    /// Launch with `--preview` (optionally `--preview-pose <height> <distance>`).
    var previewMode = CommandLine.arguments.contains("--preview")
    /// Keep the card turned toward the wearer (`BillboardComponent`). `--face-user off` pins it to the device's
    /// own orientation instead — the only way to see the slab's 12 mm edge, since a billboarded card turns its
    /// thickness away from whoever is looking at it.
    var faceUser = true

    /// Where preview mode parks the virtual device (surface height, distance in front), meters.
    var previewSurfaceHeight: Float = HologramLayout.previewSurfaceHeight
    var previewDistance: Float = HologramLayout.previewDistance
    /// Seconds before preview mode starts "observing" the virtual card (`--preview-delay`), so the space is open first.
    var previewDelay: Double = 2.5
    /// `--world <id> [stay-seconds]` (preview only): enter a world 3 s after the reveal and leave after `stay`.
    var previewWorld: String?
    var previewWorldStay: Double = 10
    /// `--exit-after <seconds>` (debug): trigger the in-space 退出 path automatically, to check the return window.
    var debugExitAfter: Double?
    /// `--abort-world-after <seconds>` (debug): the Digital Crown path — `WorldEngine.abort()` in place, with the
    /// space left open, so the instant restore (mini card back at full size, well dimmed) can actually be seen.
    var debugAbortWorldAfter: Double?
    /// `--mini-hint`: pin the mini card's "返回桌面" capsule on. The simulator has no gaze, so this is the only
    /// way to look at the hint's legibility before the headset.
    var forceMiniHint = CommandLine.arguments.contains("--mini-hint")
    /// `--preview-reacquire <s>` (preview only): seconds after a world unpauses the tracker before the virtual card is
    /// "seen" again — simulates the real re-detection delay so the return-through-`held(.stale)` path can be watched.
    var previewReacquireDelay: Double = 0

    // MARK: Director controls (plan §8 C4)

    /// `--replay-after <s>`: hide and play the cinematic again.
    var replayAfter: Double?
    /// `--celebrate <delta> [<after-s>]`: one celebration.
    var celebrateDelta: Int?
    var celebrateAfter: Double = 8
    /// `--celebrate-every <s>`: a +1 celebration on a timer (rehearsals).
    var celebrateEvery: Double?
    /// `--theme <id>`: reference image / screen to expect at start.
    var initialThemeID: String?
    /// `--director`: grace never expires, flat / view demotions and hints off.
    var directorMode = false {
        didSet { tracker.directorMode = directorMode }
    }
    /// `--no-ble`: no CoreBluetooth at all.
    var noBLE = false
    /// `--fake-device <path>`: scripted device for the simulator (absolute, or a name bundled from `Tools/`).
    var fakeDevicePath: String?
    /// `--fake-notes <path>`: a `/api/notes` payload from a file instead of the hub (simulator, no Mac).
    var fakeNotesPath: String?
    /// `--preview-note <index>`: pinch the index-th note card 2 s after the fan lands. The simulator has no
    /// gaze, so this is the only way to see the preview before the headset.
    var previewNoteIndex: Int?
    /// `--carry-lead <s>` (V3-1b): the follower's velocity feed-forward while the device is carried.
    /// **V3-4 §7**: the default drops 0.05 → 0.03 now that the 1€ filter has less lag to make up for.
    var carryLead: Float = CardTracker.carryLeadDefault
    /// **V3-4 §7** `--filter euro|lowpass`. **V3-5 §4: the default is `lowpass` again** — see
    /// `ObjectPoseSmoother.Kind` for the headset evidence that took it back.
    var filterMode: ObjectPoseSmoother.Kind = .lowpass
    /// **V3-4 §7** `--screen-offset <x mm> <z mm>`: the measured shell→LCD correction, in S millimetres.
    var screenOffsetMM: SIMD2<Float> = .zero
    /// **V3-4 §7** `--hinge-glow on|off`: a soft line of light along the device's top edge, so 2–3 mm of
    /// registration error at the hinge is a glow rather than a visible gap.
    var hingeGlow = true
    /// **V3-4 §9** `--trail-rate <f>` (default 1.0): a multiplier on the card's and the deck's pixie-dust
    /// birth rates, so the impact pass can be turned down without a rebuild. 0 = no dust at all.
    var trailRate: Float = 1
    /// **V3-4 §9** `--raise-flourish on|off` (default on): the bloom + beam flare when a deck card arrives
    /// over the name card.
    var raiseFlourish = true
    /// **V3-4 §8** `--sleep-fx on|off` (default on).
    var sleepFX = true
    /// **V3-4 §10** `--detection-rate <hz>` (default 5): how often the tracker asks for a re-detection after
    /// a loss. 10 is the experiment the first headset round's 7.6 / 15 / 18 s re-detections ask for.
    var detectionRate: Float = 5
    /// `--fake-track <path>`: scripted **image poses** for the simulator, fed through the real ingest point. Runs
    /// instead of ARKit (and instead of `--preview`, which parks the card and never calls `apply(pose:)`), so the
    /// pose follower, the continuity gate, the relocation rule and the light well can be watched without a headset.
    var fakeTrackPath: String?
    /// `--hub ws://host:8787/vp`: the Mac hub's one-way broadcast, for when the device is off USB. Without it
    /// (and without a bundled `hub.json` carrying `vpURL`) the WebSocket link stays off.
    var hubURLString: String?
    /// `--fake-hub <path>`: scripted `/vp` frames for the simulator (same script format as `--fake-device`).
    var fakeHubPath: String?
    /// `--overlay-lit off`: skip the paper / lit registration layers (LCD ghosting check).
    var overlayLit = true
    /// `--card-glass plate|feathered|plain`: which glass treatment the SwiftUI card uses behind its white
    /// frosting. `plate` (the default) is the thick-plate look the reference image asks for; the other two are
    /// there because only the headset can say whether a plate reads as "acrylic" or as "a floating window".
    var cardGlass: CardGlass = .plate
    /// `--legacy-hide`: v1's timed disappearance (6 s grace, 8 s theme / 6 s world windows) instead of v2's
    /// "a lost image only freezes, it never hides".
    var legacyHide = false
    /// `--mesh-at-start`: scene reconstruction from the first frame, in the main session (experiment E2). By
    /// default no world the wearer can reach needs the room mesh, so the provider never runs.
    var meshAtStart = false
    /// `--refs base,neon-city`: register only these themes' reference images (experiment E3).
    var referenceThemes: [String] = []
    /// `--tracker image|object|both`: which tracker may place the card. **v3 default: `object`** — the screen
    /// frame is read off the scan, so the object source places the card from its first observation, in any
    /// pose. `both` is v2's calibrated hybrid and `image` the original image-only path.
    var trackerMode: TrackingFusion.Mode = .object
    /// `--object <path>`: a `.referenceobject` from somewhere other than the bundled `objects/` folder.
    var objectPath: String?
    /// `--recalibrate`: throw away the stored object→screen offset before this run.
    var recalibrate = false
    /// `--auto-show first|always|never` (v3 H2 §7).
    var autoShow: CardTracker.AutoShow = .first
    /// `--hand-facing device|hybrid|billboard|hinged` (v3 H2 §2): which way the hand-held card turns.
    /// V3-2a: `hinge` form implies `hinged` unless the flag says otherwise.
    var handFacing: HandFacing = .hinged
    /// `--hand-form hinge|hover` (V3-2a H2): the hinged card on the device's top edge, or V3-1's hover.
    var handForm: HandForm = .hinge
    /// `--hand-scale <f>` (0.42…0.55): how big the hand card is.
    var handScale: Float = 0.5
    /// `--well-level-hand <f>`: the edge glow's level while the passport is in the hand (the desk uses
    /// `HologramLayout.wellIdleLevel`).
    ///
    /// **V3-5 §7c: 0.5 → 0.35.** On camera the steady in-hand ring is bright enough and wide enough to
    /// drown the button wave running through it — which is the one piece of feedback the wearer's own thumb
    /// is not covering. The ring is context; the wave is the answer to a press.
    var wellLevelHand: Float = 0.35
    /// `--deck off|<n>` (V3-2a H3): how many note cards ride in the hand deck (plus the two world cards).
    var deckNoteCount = 5
    var deckEnabled = true
    /// `--footprint-check`: audit the tree once a second for virtual geometry on the real hardware.
    /// **V3-4 §10**: on by default from this round (it only prints), `--footprint-check off` turns it off.
    var footprintCheck = true
    /// **V3-4 §4** `--device-taps on|off` (default **off**): whether the two things drawn on the hardware —
    /// the projector's base ring and the socket light — accept a gaze + pinch. Off, because a thumb on the
    /// side key and a hand closing round the passport both read as one to visionOS.
    var deviceTaps = false
    /// **V3-6 §2** `--hand-cones on|off` (default **off**): whether the projector's three volumetric cone
    /// layers and its base dust are drawn while the card is in the wearer's hand. Off is the performance
    /// answer — see `ProjectorRig.handConesEnabled` for the measurement it comes from.
    var handCones = false
    /// **v4 B2 §3.3** `--pickup-fold on|off` (default **on**): a loss with a hand on the passport folds the card into
    /// the device's last position (a gold point) instead of leaving it over the desk; see `V4.PickupFold`.
    var pickupFold = true
    /// **V3-2b B2** `--deck-dynamics on|off`: the hand of cards trails the name card (plan §4 E5). `off` is
    /// V3-2a2's rigid attachment, kept so the two can be compared on the headset.
    var deckDynamics = true
    /// **V3-2b B6** `--no-hands`: no `HandTrackingProvider` and no hand bridge (plan H4). The app is then
    /// exactly what it was before B6 — an object-tracking loss in the hand freezes the card.
    var handBridge = !CommandLine.arguments.contains("--no-hands")
    /// **V3-4 §3** `--bridge-orientation frozen|hand` (default `frozen`) and `--bridge-max <s>`.
    /// **V3-5 §1**: the default budget is 3 s → **6 s** and the attach radius 10 cm → **15 cm**
    /// (`--bridge-radius <m>`); both defaults live on `HandBridge` itself, this only carries the flags.
    var bridgeOrientation: HandBridge.Orientation = .frozen
    var bridgeMaxSeconds: Double = HandBridge().maxBridge
    var bridgeRadius: Float = HandBridge().attachRadius
    /// **V3-6 §1** `--bridge on|off`, default **off** — the user's call after the third headset round.
    ///
    /// "理论上手部不要接管，一直跟随设备卡就好了。" Eight bridges that round all picked the right hand and
    /// five of them ran the full six seconds with `jitterRaw 25–32 mm`, `lag 29–35 mm`, `deckLag 52–57 mm`:
    /// past about 30° off axis the card was following a **wrist** and it looked like it. One of them started
    /// as the passport was being *put down* (the hand occluded it for 1.2 s) and walked the card 30 cm away
    /// with the retreating hand for 1.9 s.
    ///
    /// Off does **not** mean `--no-hands`: the provider still runs (§8's "the card notices your hand" and
    /// `Σ hands=` both need it) and the bridge still learns the grip. Only `driveBridged` is unplugged, so
    /// `Σ src=` never reads `hand` and `bridged=` is always 0 %. `--bridge on` is the A/B, with V3-5's
    /// `--bridge-radius` / `--bridge-max` / `--bridge-orientation` still on top of it.
    var bridgeDrives = false
    /// **V3-3 C1** `--fresnel on|off` (plan §4 E14a): the rim brightens as the card turns edge-on.
    var fresnelEnabled = true
    /// **V3-3 C2** `--parallax on|off` (plan §4 E14b): the avatar and the tags stand +8 / +4 mm off the
    /// card's face, so turning the passport moves them against the type. `off` puts all three layers at z 0,
    /// which is pixel-for-pixel V3-2b's single attachment.
    var parallaxEnabled = true
    /// **V3-3 C3** `--back-face on|off` (plan §4 E14c): turning the card right over shows its back.
    var backFaceEnabled = true
    /// **V3-2a2 S1** `--box-scan on|off`: the recognition wireframe on the device's own edges.
    var boxScanEnabled = true
    /// **S2** `--glow on|off`: ask the real LCD to sweep a white bar with the virtual band.
    var glowEnabled = true
    /// **S3** `--button-glint on|off` and `--button-edge +x|-x` (persisted: the side the keys are on is not
    /// written down in anything the app can read, so it is calibrated once on the headset).
    var buttonGlintEnabled = true
    var buttonEdge: ButtonGlintLayout.Edge = .plusX
    /// **V3-4 §1** `--button-fx wave|dot|off` (default `wave`): the edge wave + spark cone + the card's
    /// answer, V3-2a2's dot alone, or nothing. `dot` is what the first headset round ran.
    var buttonFX: ButtonGlintLayout.FX = .wave

    // MARK: v4 B1 (recognition + hero card)

    /// **v4 B1 §4** `--v3-card`: the whole v3 recognition (the box scan) and card (slab, rim, SwiftUI sheets) path —
    /// the shoot's insurance. Without it the device is recognised by A2's ribbon and the card is A4's hero card in
    /// A1's materials.
    let v3Card = CommandLine.arguments.contains("--v3-card")
    /// `--ribbon-width <mm>` and `--ribbon-dust <×>`: headset knobs for the recognition ribbon. The defaults are
    /// A2's (11 mm, ×1): bloom only exists on the headset, so the width is decided there, not here.
    var ribbonWidthMM: Float?
    var ribbonDust: Float = 1
    /// `--lcd-burst flash|sweep`: which `glow` the real LCD plays on the recognition's first beat (`.burst`).
    /// `flash` by default: the virtual stand-in is a starburst over the whole screen, and a bar running up it
    /// (`sweep`) reads as a scan instead. Firmware ≥ 0.2.0 does both, so it is an A/B for the headset round.
    var lcdBurstKind = "flash"
    /// `--screen-burst on|off`: the virtual `ScreenBurst` layer over the LCD. On in the simulator (there is no
    /// screen), off on the headset, where the real LCD plays the `glow` itself (brief B1 §2).
    var screenBurst: Bool = {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }()
    /// `--v4-freeze <s>` (screenshots): stop the recognition's clock at `s` seconds — and the card's, if `s` is past
    /// the closure — so a still of any moment can be taken in the product path.
    var v4FreezeAt: Float?
    /// **v4 B3** `--v4-freeze-run <n>` (screenshots): `--v4-freeze` holds only the session's `n`-th recognition — a summon's
    /// ribbon is run 2 after one collapse — instead of every one.
    var v4FreezeRun: Int?
    /// **v4 B4 §1** `--recognition-place hand|desk` (smokes only): force the place the recognition decides on at take-off,
    /// whatever the tilt says — so the closure's two fallbacks (a hand flight that lands on the desk rises off the screen;
    /// a desk flight that lands in the hand unfolds) can be scripted without racing the gate.
    var recognitionPlaceOverride: V4.RecognitionPlace?
    /// **v4 B4 §3.5** `cmd perf`: the desk's layers and the card's material as the director last set them (read by the
    /// note cards' glass, the controller and the world engine).
    var perfSwitches = V4.PerfSwitches()
    @ObservationIgnored private var lastPerfCommand: (arg: String, at: TimeInterval)?
    /// **v4 B5 §2** `--note-base glass|frost`: the note cards' (and the deck's world cards') ground at launch. **Frost by
    /// default since 10-06** — the user's decision on the B5 stills (the static frost, `NoteCardBase`, instead of a
    /// background blur per card); `--note-base glass` launches with the system glass.
    var launchNoteBase: NoteCardBase = .frost
    /// The ground the cards draw: the launch's, or the system glass while `cmd perf gallery-glass=on` holds.
    var noteBase: NoteCardBase { perfSwitches.isOn(.galleryGlass) ? .glass : launchNoteBase }
    /// **v4 B5 §2** `--note-fade full|quick`: the gallery cards fade across their whole flight (default) or in a fifth of it.
    var launchQuickFade = false
    /// **v4 B5 §2** `--hold-dim on|off`: the lost-passport cue dims the card and the gallery (default) or only breathes.
    var launchHoldDim = true
    /// **v4 B5 §3** `--resident-motes full|lite`: the three resident emitters at full rate (default) or two-thirds.
    var launchLiteMotes = false
    /// `--v4-hitch-ms <ms>` (real-device checks): log every frame whose wall-clock gap exceeds this (default 100 ms),
    /// with what the recognition and the card were doing — `[perf]` only reports a window's worst frame.
    var v4HitchMS: Double = 100
    /// `--device-proxy` (simulator screenshots): draw a stand-in for the passport — the smoked case in C, the lit LCD in
    /// S — so a still shows where the ribbon, the card and the case effects are relative to the hardware.
    let deviceProxy = CommandLine.arguments.contains("--device-proxy")

    // MARK: Data

    let card: CardData = CardData.loadFromBundle()
    /// Follower counts: seeded from `card.json`, overwritten by the device (`hello` / `stats`, newest wins).
    var stats: CardStats
    /// "+N" badge on the glass card while a celebration runs.
    var deltaBadge: Int?
    var deviceConnected = false
    var deviceBattery: Int?

    // MARK: Recent notes (工作包 D 笔记扇出)

    /// The ten most recent notes, newest first, pinned last — exactly the hub's list.
    var recentNotes: [RecentNote] = []
    /// The hub's list revision the app is showing (0 = nothing fetched yet).
    var recentNotesRev = 0
    /// The rules that decide when the fan is out; the views read `noteFan`, the choreography reads the outcome.
    private var fan = NoteFanMachine()
    /// The rules that decide when the *device* rings along with the card (工作包 A 设备联动).
    @ObservationIgnored private var cues = DeviceCueRules()
    var noteFan: NoteFanState { fan.state }
    /// The wearer took the fan back by hand (long OK): it stays back until they ask for it again.
    var fanSuppressed: Bool { fan.suppressed }
    var previewedNote: RecentNote? {
        guard let id = fan.state.previewID else { return nil }
        return recentNotes.first { $0.id == id }
    }
    /// The desk's 「笔记」 chip stands in for the device's long OK when no device is linked.
    var showsNotesChip: Bool { !deviceConnected && !recentNotes.isEmpty }
    @ObservationIgnored private var fanTask: Task<Void, Never>?
    @ObservationIgnored private var previewNoteFired = false
    /// `--preview-tap-card`: script two taps on the desk card (the simulator cannot tap it).
    var previewTapsCard = false
    @ObservationIgnored private var previewCardTapFired = false

    let tracker = CardTracker()
    let device = DeviceCoordinator()
    /// The hologram controller lives with the RealityView (`ImmersiveView`); set while the space is open.
    @ObservationIgnored weak var controller: HologramController?

    // MARK: Mini card (工作包 C)

    /// Which layout the one card attachment shows. Flipped the moment the shrink starts, so the desk layout is
    /// already gone (0.2 s) by the time the card is small. `.mini` (inside a world) always wins over `.hand`.
    var cardMode: HologramCardMode = .full

    // MARK: Hand pager (v3 H2 §8)

    /// The ring UP / DOWN walk while the passport is in the wearer's hand.
    @ObservationIgnored private var pager = HandPager()
    /// The page the **card** is showing. It lags `pager.page` by half the flip, so the content is swapped
    /// while the plate is squashed to 8 % of its width and the swap itself is never seen.
    private(set) var handPageShown: HandPage = .profile
    @ObservationIgnored private var handPageTask: Task<Void, Never>?
    /// Half of the 0.35 s page flip.
    static let handPageSwapDelay: Double = 0.175

    /// The pager is live: the card is in its hand form, on the desk's side of a world.
    var isHandPagerActive: Bool { cardMode == .hand && !worlds.isActive }

    /// What the hand card renders (`HologramCardView(page:)`), resolved from `handPageShown`.
    var handPageContent: HandPageContent {
        let all = pager.pages
        let index = all.firstIndex(of: handPageShown) ?? 0
        // V3-2a H3: with the deck on, the card is the profile and the pages are the cards behind it.
        guard !isDeckActive else { return HandPageContent(kind: .profile, index: 0, count: 1, paged: false) }
        switch handPageShown {
        case .profile:
            return HandPageContent(kind: .profile, index: index, count: all.count)
        case .world(let id):
            guard let d = worlds.descriptor(id) else { return HandPageContent(index: index, count: all.count) }
            return HandPageContent(kind: .world(name: d.name, subtitle: d.subtitle,
                                                tint: Color(uiColor: d.hologramTintColor)),
                                   index: index, count: all.count)
        case .note(let id):
            guard let note = recentNotes.first(where: { $0.id == id }) else {
                return HandPageContent(index: index, count: all.count)
            }
            return HandPageContent(kind: .note(title: note.title, likes: note.likes, cover: coverURL(for: note)),
                                   index: index, count: all.count)
        }
    }

    /// A world page tints the card's rim while it is up, without touching `WorldEngine.highlight` — which is
    /// what OK's precedence reads, and highlighting from the pager would make OK on a *note* page enter a
    /// world instead of opening the note.
    var handPageTint: UIColor? {
        if isDeckActive {
            // V3-2a H3: a raised world card tints the card's rim 0.5, exactly as its page used to.
            guard let id = raisedWorldCard else { return nil }
            return worlds.descriptor(id)?.hologramTintColor
        }
        guard isHandPagerActive, case .world(let id) = handPageShown else { return nil }
        return worlds.descriptor(id)?.hologramTintColor
    }
    /// Cancellable wait between "the world started" and `take.miniCardAt`.
    @ObservationIgnored private var miniCardTask: Task<Void, Never>?
    /// The passport was in the wearer's hand when this world started (v3 FIX B). Latched for the world's
    /// whole life: the gate is `held(.world)` throughout and cannot be asked.
    @ObservationIgnored private var handFormBeforeWorld = false

    /// Where the wearer's head is. On the headset that is the device anchor the tracker polls at 20 Hz; in
    /// preview mode it is the same synthetic seated reader the worlds are built around, so the mini card and the
    /// world agree about where "in front of you" is.
    var headPose: simd_float4x4? {
        previewMode ? previewHeadPose : tracker.latestDevicePose
    }

    /// Preview mode's stand-in head: a seated reader's eyes above the desk surface, looking down −Z at the
    /// virtual card. The world layout (`poseProvider`) and the mini card both read it from here, so the
    /// simulator can never place "in front of you" in two different spots.
    var previewHeadPose: simd_float4x4 {
        Transform(translation: [0, previewSurfaceHeight + 0.45, 0]).matrix
    }

    /// Single writer of the immersion style: only the world engine asks for `.full` (the P0 probes no longer do).
    var wantsFullImmersion: Bool { worlds.wantsFull }

    init() {
        stats = card.stats
        let args = CommandLine.arguments
        worlds = WorldEngine(allWorlds: args.contains("--all-worlds"))
        func value(after flag: String) -> String? {
            guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let index = args.firstIndex(of: "--preview-pose"), index + 2 < args.count,
           let height = Float(args[index + 1]), let distance = Float(args[index + 2]) {
            previewSurfaceHeight = height
            previewDistance = distance
        }
        if let delay = value(after: "--preview-delay").flatMap(Double.init) { previewDelay = delay }
        if let kind = value(after: "--reveal").flatMap(RevealKind.init(rawValue:)) { revealOverride = kind }
        if let quality = value(after: "--quality") {
            worlds.initialQuality = ["low": WorldQuality.low, "medium": .medium, "high": .high][quality] ?? .high
        }
        // **v4 B5 §2** `--note-base glass|frost`: the gallery cards' ground (the system glass, or the static frost).
        if let base = value(after: "--note-base").flatMap(NoteCardBase.init(rawValue:)) {
            launchNoteBase = base
            print("[notes] --note-base \(base.rawValue)")
        } else {
            print("[notes] note base frost (the default since 10-06; --note-base glass or cmd perf gallery-glass=on = the system glass)")
        }
        if let fade = value(after: "--note-fade")?.lowercased(), fade == "full" || fade == "quick" {
            launchQuickFade = fade == "quick"
            print("[notes] --note-fade \(fade)")
        }
        // **v4 B5 §3** `--resident-motes full|lite`: the three resident emitters at full rate, or two-thirds of it.
        if let motes = value(after: "--resident-motes")?.lowercased(), motes == "full" || motes == "lite" {
            launchLiteMotes = motes == "lite"
            print("[notes] --resident-motes \(motes)")
        }
        if let dim = value(after: "--hold-dim")?.lowercased(), dim == "on" || dim == "off" {
            launchHoldDim = dim == "on"
            print("[reveal] --hold-dim \(dim)")
        }
        // **v4 B5 §5** `--prebuild-slice-ms <ms>`: how much of one frame a desk prebuild may take (1–8, default 6).
        if let ms = value(after: "--prebuild-slice-ms").flatMap(Double.init) {
            worlds.prebuildSlice = max(1, min(8, ms)) / 1000
            print(String(format: "[worlds] --prebuild-slice-ms %.0f", worlds.prebuildSlice * 1000))
        }
        if let seconds = value(after: "--exit-after").flatMap(Double.init) { debugExitAfter = seconds }
        if let seconds = value(after: "--abort-world-after").flatMap(Double.init) { debugAbortWorldAfter = seconds }
        if let seconds = value(after: "--preview-reacquire").flatMap(Double.init) { previewReacquireDelay = seconds }
        if let index = args.firstIndex(of: "--world"), index + 1 < args.count {
            previewWorld = args[index + 1]
            if index + 2 < args.count, let stay = Double(args[index + 2]) { previewWorldStay = stay }
        }
        if let seconds = value(after: "--replay-after").flatMap(Double.init) { replayAfter = seconds }
        if let index = args.firstIndex(of: "--celebrate"), index + 1 < args.count, let delta = Int(args[index + 1]) {
            celebrateDelta = delta
            if index + 2 < args.count, let after = Double(args[index + 2]) { celebrateAfter = after }
        }
        if let seconds = value(after: "--celebrate-every").flatMap(Double.init) { celebrateEvery = seconds }
        if let theme = value(after: "--theme") { initialThemeID = theme }
        if args.contains("--director") { directorMode = true }
        if args.contains("--no-ble") { noBLE = true }
        if let path = value(after: "--fake-device") { fakeDevicePath = path }
        if let path = value(after: "--fake-notes") { fakeNotesPath = path }
        if let index = value(after: "--preview-note").flatMap(Int.init) { previewNoteIndex = index }
        if let seconds = value(after: "--tap-preview-close").flatMap(Double.init) { tapPreviewCloseAfter = max(0, seconds) }
        if args.contains("--preview-tap-card") { previewTapsCard = true }
        if let path = value(after: "--fake-track") { fakeTrackPath = path }
        if let level = value(after: "--well-level").flatMap(Float.init) {
            HologramLayout.wellIdleLevel = max(0, min(1, level))
            print("[reveal] well idle level = \(HologramLayout.wellIdleLevel)")
        }
        if let url = value(after: "--hub") { hubURLString = url }
        if let path = value(after: "--fake-hub") { fakeHubPath = path }
        if let lit = value(after: "--overlay-lit"), lit.lowercased() == "off" { overlayLit = false }
        if let glass = value(after: "--card-glass").flatMap(CardGlass.init(rawValue:)) { cardGlass = glass }
        if let face = value(after: "--face-user"), face.lowercased() == "off" { faceUser = false }
        if args.contains("--legacy-hide") { legacyHide = true }
        if args.contains("--mesh-at-start") { meshAtStart = true }
        if let refs = value(after: "--refs") {
            referenceThemes = refs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        if let mode = value(after: "--tracker").flatMap(TrackingFusion.Mode.init(rawValue:)) { trackerMode = mode }
        if let path = value(after: "--object") { objectPath = path }
        if args.contains("--recalibrate") { recalibrate = true }
        if let mode = value(after: "--auto-show").flatMap(CardTracker.AutoShow.init(rawValue:)) { autoShow = mode }
        if let mode = value(after: "--hand-facing").flatMap(HandFacing.init(rawValue:)) { handFacing = mode }
        // V3-2a H0 / H2 / H3.
        if let form = value(after: "--hand-form").flatMap(HandForm.init(rawValue:)) {
            handForm = form
            if form == .hover, value(after: "--hand-facing") == nil { handFacing = .hybrid }
        }
        if let scale = value(after: "--hand-scale").flatMap(Float.init) {
            handScale = max(0.42, min(0.55, scale))
        }
        if let deck = value(after: "--deck") {
            if deck.lowercased() == "off" {
                deckEnabled = false
            } else if let n = Int(deck) {
                deckNoteCount = max(0, min(5, n))
                deckEnabled = deckNoteCount > 0
            }
        }
        if let mode = value(after: "--well").flatMap(LightWell.Mode.init(rawValue:)) {
            LightWell.mode = mode
            print("[reveal] light well = \(mode.rawValue)")
        }
        if let level = value(after: "--well-level-hand").flatMap(Float.init) {
            wellLevelHand = max(0, min(1, level))
        }
        if let socket = value(after: "--socket")?.lowercased(), socket == "ring" || socket == "off" {
            RegistrationOverlay.socketEnabled = socket == "ring"
            print("[reveal] socket = \(socket)")
        }
        if let check = value(after: "--footprint-check")?.lowercased(), check == "on" || check == "off" {
            footprintCheck = check == "on"
        } else if args.contains("--footprint-check") {
            footprintCheck = true
        }
        if let taps = value(after: "--device-taps")?.lowercased(), taps == "on" || taps == "off" {
            deviceTaps = taps == "on"
        }
        RegistrationOverlay.deviceTapsEnabled = deviceTaps
        ProjectorRig.deviceTapsEnabled = deviceTaps
        print("[tap] device taps \(deviceTaps ? "on" : "off")")
        // **V3-6 §2.** The hand form's cones, which the third headset round's 45 fps window put on the stand.
        if let cones = value(after: "--hand-cones")?.lowercased(), cones == "on" || cones == "off" {
            handCones = cones == "on"
        }
        ProjectorRig.handConesEnabled = handCones
        print("[reveal] hand cones \(handCones ? "on" : "off")")
        if !handBridge { print("[hand] bridge = off (--no-hands)") }
        tracker.handBridgeEnabled = handBridge
        // **V3-4 §3.** Where the card's rotation comes from while the hand carries it, and how long the
        // bridge may carry it at all. `frozen` / 3 s are the defaults; both are flags because only the
        // headset can say whether a longer bridge is worth the risk of the card following a hand that has
        // already put the passport down.
        if let mode = value(after: "--bridge-orientation").flatMap(HandBridge.Orientation.init(rawValue:)) {
            bridgeOrientation = mode
        }
        if let seconds = value(after: "--bridge-max").flatMap(Double.init) {
            bridgeMaxSeconds = max(0.5, min(10, seconds))
        }
        // **V3-5 §1.** How close a wrist has to be to count as holding the passport. 5–30 cm: below 5 cm no
        // real grip is ever learned, above 30 cm the *other* hand's wrist is inside the circle.
        if let metres = value(after: "--bridge-radius").flatMap(Float.init) {
            bridgeRadius = max(0.05, min(0.30, metres))
        }
        // **V3-6 §1.** Whether any of that may place the card at all.
        if let drives = value(after: "--bridge")?.lowercased(), drives == "on" || drives == "off" {
            bridgeDrives = drives == "on"
        }
        tracker.bridgeOrientation = bridgeOrientation
        tracker.bridgeMaxSeconds = bridgeMaxSeconds
        tracker.bridgeAttachRadius = bridgeRadius
        tracker.bridgeDrivesCard = bridgeDrives && handBridge
        if handBridge, bridgeDrives {
            print(String(format: "[hand] bridge orientation %@, max %.1f s, radius %.0f cm",
                         bridgeOrientation.rawValue, bridgeMaxSeconds, bridgeRadius * 100))
        } else if handBridge {
            print("[hand] bridge off (the card follows the device only)")
        }
        // v4 B2 §3.3: `--pickup-fold on|off` (default on).
        if let fold = value(after: "--pickup-fold")?.lowercased(), fold == "on" || fold == "off" {
            pickupFold = fold == "on"
        }
        print(pickupFold ? "[reveal] pick-up fold on (a grab loss past \(V4.PickupFold.after) s folds the card into the device's last position)"
                         : "[reveal] pick-up fold off (--pickup-fold off: a lost card waits where it was, dimmed)")
        if let dynamics = value(after: "--deck-dynamics")?.lowercased(), dynamics == "on" || dynamics == "off" {
            deckDynamics = dynamics == "on"
            print("[reveal] deck dynamics = \(dynamics)")
        }
        // V3-2b B1: how long a deck card has to stay raised before the real bottom strip follows it.
        if let dwell = value(after: "--strip-dwell").flatMap(Double.init) {
            stripDwell.seconds = max(0, min(3, dwell))
            print(String(format: "[notes] strip dwell = %.2f s", stripDwell.seconds))
        }
        // V3-3 C1 / C2 / C3 (plan §4 E14): the three angle visuals, each with its own A/B switch because
        // each of them is a bet on how a 13.5 cm card reads at arm's length on a real headset.
        if let fresnel = value(after: "--fresnel")?.lowercased(), fresnel == "on" || fresnel == "off" {
            fresnelEnabled = fresnel == "on"
            print("[reveal] fresnel = \(fresnel)")
        }
        if let parallax = value(after: "--parallax")?.lowercased(), parallax == "on" || parallax == "off" {
            parallaxEnabled = parallax == "on"
            print("[reveal] parallax = \(parallax)")
        }
        if let back = value(after: "--back-face")?.lowercased(), back == "on" || back == "off" {
            backFaceEnabled = back == "on"
            print("[reveal] back face = \(back)")
        }
        // V3-2a2 S1 / S2 / S3.
        if let scan = value(after: "--box-scan")?.lowercased(), scan == "on" || scan == "off" {
            boxScanEnabled = scan == "on"
            print("[reveal] box scan = \(scan)")
        }
        if let glow = value(after: "--glow")?.lowercased(), glow == "on" || glow == "off" {
            glowEnabled = glow == "on"
            print("[ble] glow = \(glow)")
        }
        if let glint = value(after: "--button-glint")?.lowercased(), glint == "on" || glint == "off" {
            buttonGlintEnabled = glint == "on"
            print("[fx] button glint = \(glint)")
        }
        if let stored = UserDefaults.standard.string(forKey: ButtonGlintLayout.Edge.defaultsKey),
           let edge = ButtonGlintLayout.Edge(rawValue: stored) {
            buttonEdge = edge
        }
        if let edge = value(after: "--button-edge")?.lowercased(),
           let parsed = ButtonGlintLayout.Edge(rawValue: edge) {
            buttonEdge = parsed
            UserDefaults.standard.set(parsed.rawValue, forKey: ButtonGlintLayout.Edge.defaultsKey)
        }
        if let fx = value(after: "--button-fx").flatMap(ButtonGlintLayout.FX.init(rawValue:)) { buttonFX = fx }
        if buttonGlintEnabled { print("[fx] button glints on the \(buttonEdge.rawValue) edge") }
        print("[fx] button fx \(buttonGlintEnabled ? buttonFX.rawValue : "off")")
        // v4 B1: the ribbon's two headset knobs, the LCD's answer to the burst, and the virtual burst layer.
        if let mm = value(after: "--ribbon-width").flatMap(Float.init), mm.isFinite {
            ribbonWidthMM = max(2, min(30, mm))
        }
        if let k = value(after: "--ribbon-dust").flatMap(Float.init), k.isFinite {
            ribbonDust = max(0, min(3, k))
        }
        if let kind = value(after: "--lcd-burst")?.lowercased(), kind == "flash" || kind == "sweep" {
            lcdBurstKind = kind
        }
        if let burst = value(after: "--screen-burst")?.lowercased(), burst == "on" || burst == "off" {
            screenBurst = burst == "on"
        }
        if let t = value(after: "--v4-freeze").flatMap(Float.init), t.isFinite, t >= 0 {
            v4FreezeAt = t
            print(String(format: "[v4] --v4-freeze %.2f s", t))
        }
        if let n = value(after: "--v4-freeze-run").flatMap(Int.init), n >= 1 {
            v4FreezeRun = n
            print("[v4] --v4-freeze-run \(n): only recognition #\(n) freezes")
        }
        if let place = value(after: "--recognition-place").flatMap({ V4.RecognitionPlace(rawValue: $0.lowercased()) }) {
            recognitionPlaceOverride = place
            print("[v4] --recognition-place \(place.rawValue): every recognition takes off on the \(place.rawValue)'s path (smoke override)")
        }
        if let ms = value(after: "--v4-hitch-ms").flatMap(Double.init), ms.isFinite {
            v4HitchMS = max(5, min(1000, ms))
            print(String(format: "[v4] --v4-hitch-ms %.0f", v4HitchMS))
        }
        if v3Card {
            print("[v4] --v3-card: v3 box scan + v3 card (the v4 ribbon and hero card are off)")
        } else {
            print(String(format: "[v4] hero card + ribbon recognition (ribbon %@ mm, dust ×%.2f, lcd %@, screen burst %@; app model %.0f ms after launch)",
                         ribbonWidthMM.map { String(format: "%.1f", $0) } ?? "11.0 (A2)", ribbonDust, lcdBurstKind,
                         screenBurst ? "on" : "off", V4LaunchClock.sinceLaunch * 1000))
            // A1's materials are already loading: `SpatialCardApp` starts them before this model is built
            // (`V4MaterialPreload.startAtLaunch`). This call is a no-op then, and a safety net otherwise.
            V4MaterialPreload.start()
        }
        device.glowEnabled = glowEnabled
        // v4 B2 §3.1: the AR session's backlight (100 % = DC by default; `85` is the firmware's PWM level, `keep` sends
        // nothing). A value that does not parse keeps the default and says so.
        if let text = value(after: "--ar-backlight") {
            if let parsed = V4.ARBacklight.parse(text) {
                device.arBacklight = parsed
            } else {
                print("[ble] --ar-backlight \(text): not 1–100 or keep; the default (100) stands")
            }
        }
        print(device.arBacklight.flagLine)
        // v3 H1: the two signs a bounding box cannot give. `+y` / `0` are the frame as derived.
        if let side = value(after: "--screen-side")?.lowercased(), side == "+y" || side == "-y" {
            tracker.screenSideFlipOverride = side == "-y"
        }
        if let yaw = value(after: "--screen-yaw").flatMap(Int.init), yaw == 0 || yaw == 180 {
            tracker.screenYawFlipOverride = yaw == 180
        }
        // V3-1b: which bounding box `--fake-track` reports. `headset` is the Z-thin box the device really sends;
        // `scan` is the Y-thin one the offline usdz analysis produced. **v4 B1**: the default is `measured`, the
        // same Z-thin box at the case's ruler size (60 × 96 × 8 mm), so the simulator runs on the numbers the
        // case frame is built from.
        if let box = value(after: "--fake-box")?.lowercased(), ["headset", "scan", "measured"].contains(box) {
            tracker.fakeBox = box == "scan" ? .aiPassport : (box == "headset" ? .aiPassportHeadset : .aiPassportMeasured)
            print("[obj] --fake-box \(box)")
        }
        // V3-1b §7: how far ahead of the measured velocity the carried card is aimed (0 = no feed-forward).
        let carryLeadGiven = args.contains("--carry-lead")
        if let lead = value(after: "--carry-lead").flatMap(Float.init) {
            carryLead = max(0, min(0.3, lead))
        }
        // **V3-4 §7.** The filter, the measured screen offset (persisted per reference object, so it is
        // given once with a ruler and then forgotten), and the hinge's contact light.
        if let mode = value(after: "--filter").flatMap(ObjectPoseSmoother.Kind.init(rawValue:)) {
            filterMode = mode
        }
        // **V3-5 §4.** The lead exists to cancel the smoother's delay. Under `euro` the velocity feed-forward
        // and the filter's own speed term are the *same* correction applied twice — the retuned filter's lag
        // is already 4× the low pass's, and leading on top of it overshoots every stop. So `euro` leads by 0
        // unless the flag says otherwise; `lowpass` keeps V3-4's 0.03 s.
        if filterMode == .euro, !carryLeadGiven { carryLead = 0 }
        // **v4 B1 §1.** The one source of the LCD's offset on the case (`V4.ScreenOffset.resolve`): the flag wins
        // (and is persisted per device, as in V3-4), then a persisted value, then the ruler measurement. Applied
        // to the object pose (`ObjectScreenFrame.userOffset`, so the tracked pose is the screen frame S) and read
        // by the hologram controller to hang the case frame C off S.
        let offsetKey = ObjectScreenFrame.offsetDefaultsKey(object: "ai-passport")
        var storedOffset: SIMD2<Float>?
        if let stored = UserDefaults.standard.array(forKey: offsetKey) as? [Double], stored.count == 2 {
            storedOffset = [Float(stored[0]), Float(stored[1])] / 1000
        }
        var flagOffset: SIMD2<Float>?
        if let index = args.firstIndex(of: "--screen-offset"), index + 2 < args.count,
           let x = Float(args[index + 1]), let z = Float(args[index + 2]) {
            flagOffset = [x, z] / 1000
            UserDefaults.standard.set([Double(x), Double(z)], forKey: offsetKey)
        }
        let resolved = V4.ScreenOffset.resolve(flag: flagOffset, stored: storedOffset)
        screenOffsetMM = resolved.offset * 1000
        ObjectScreenFrame.userOffset = resolved.offset
        print(V4.ScreenOffset.describe(resolved.offset, source: resolved.source))
        if let glow = value(after: "--hinge-glow")?.lowercased(), glow == "on" || glow == "off" {
            hingeGlow = glow == "on"
        }
        // **V3-4 §8 / §9 / §10.** Each of the impact-pass numbers has its own switch, so the headset round
        // can A/B them one at a time instead of judging the whole pass at once.
        if let rate = value(after: "--trail-rate").flatMap(Float.init) {
            trailRate = max(0, min(4, rate))
            HologramController.handTrailBirthRate *= trailRate
            HologramController.deckTrailBirthRate *= trailRate
            print(String(format: "[fx] trail rate ×%.2f (card %.0f/s, deck %.0f/s)", trailRate,
                         HologramController.handTrailBirthRate, HologramController.deckTrailBirthRate))
        }
        if let flourish = value(after: "--raise-flourish")?.lowercased(), flourish == "on" || flourish == "off" {
            raiseFlourish = flourish == "on"
        }
        if let fx = value(after: "--sleep-fx")?.lowercased(), fx == "on" || fx == "off" {
            sleepFX = fx == "on"
        }
        // **V3-5 §5.** `--perf-tag <name>`: every `[perf]` line becomes `[perf:name]`, so two runs of one
        // build started from `devicectl` as an A/B can be told apart in a single log.
        if let tag = value(after: "--perf-tag") {
            PerfLog.tag = tag
            print("\(PerfLog.prefix) tag on (every [perf] line carries it)")
        }
        // **v4 B5 §2.** `--perf-census`: every `[perf]` window also walks the scene every frame and reports per-frame peaks
        // (tweens, attachments and the translucent ones, emitters, particles alive, SwiftUI re-evaluations). A diagnostic
        // for the simulator: the walk costs main-thread time of its own, so the headset runs without it.
        if args.contains("--perf-census") {
            PerfCensus.enabled = true
            print("\(PerfLog.prefix) --perf-census: every window walks the scene each frame (peaks of tweens, attachments, emitters, particles)")
            print("\(PerfLog.prefix) --perf-census: \(PerfCensus.describeDefaults())")
        }
        if let hz = value(after: "--detection-rate").flatMap(Float.init) {
            detectionRate = max(1, min(30, hz))
        }
        tracker.detectionRate = detectionRate
        print(String(format: "[obj] detection rate %.0f Hz", detectionRate))
        tracker.filterMode = filterMode
        // V3-5 §4: the lead is part of the filter's answer, so the line says both.
        print(String(format: "[obj] filter %@ (carry lead %.0f ms)", filterMode.rawValue, carryLead * 1000))
        // The device's own screen is what the object tracker was trained on, so the app leaves it alone.
        if args.contains("--theme-follow-worlds") { device.themeFollowsWorlds = true }

        cues.scanDriven = boxScanEnabled

        CardTracker.referenceThemeFilter = referenceThemes
        tracker.carryLead = carryLead
        tracker.trackerMode = trackerMode
        tracker.autoShow = autoShow
        tracker.objectPath = objectPath
        tracker.recalibrate = recalibrate
        tracker.legacyHide = legacyHide
        tracker.meshAtStart = meshAtStart
        tracker.directorMode = directorMode
        if let theme = initialThemeID { tracker.setExpectedTheme(theme, reason: "--theme") }
        device.app = self
        // v4 B2 §3.2: `[track] in view but untracked … strip …` says what the device's bottom strip showed.
        tracker.stripProvider = { [weak device] in device?.stripOverride }
        worlds.stats = stats
        // v3 H2 §6: the passport turned face down folds the card away.
        tracker.onGesture = { [weak self] event in self?.handleGesture(event) }

        // World ↔ tracker ↔ device wiring (the engine only exposes hooks; the policy lives here).
        worlds.onShellOpaque = { [weak self] id in
            guard let self else { return }
            let theme = PassportManifest.shared.theme(forWorld: id).id
            // The physical screen stays on the theme the `.referenceobject` was scanned with; the world's colour
            // reaches the virtual card only (`--theme-follow-worlds` puts the old behaviour back).
            print("[world] shell opaque: \(self.device.themeFollowsWorlds ? "set_theme \(theme)" : "device screen locked"), tracker paused")
            self.device.sendThemeUnlessLocked(theme, reason: "world \(id)")
            self.tracker.setPaused(true)
        }
        worlds.onMixedRestored = { [weak self] id in
            guard let self else { return }
            self.tracker.setPaused(false)
            // The card flies home at the *start* of the exit (0.6 s), so it is back on its frozen desk pose long
            // before the gate releases the hologram at exit progress 0.8 and the thaw glides it the last
            // millimetres. Going the other way round would land the card while the room is already back.
            self.cancelMiniCardWait()
            // v3 FIX B: "home" is the hand form when the passport never left the wearer's hand.
            self.cardMode = self.returnsToHandForm ? .hand : .full
            self.controller?.leaveMiniCard(from: id)
        }
        worlds.onReturnedToDesk = { [weak self] in
            // The hologram comes back through the thaw (replay light), on whichever theme screen the device shows now.
            self?.tracker.setWorldActive(false)
            self?.noteReturnedFromWorld()
        }
        worlds.onAborted = { [weak self] id in
            guard let self else { return }
            // The space was dismissed mid-world: the two hooks above never ran. Give the tracker its pause and
            // world hold back (already done when the view stopped the session first — `ImmersiveView.onDisappear`
            // — so this is the safety net, not the normal path) and take the device off the world's screen: no
            // exit choreography means nothing else will.
            self.tracker.setPaused(false)
            self.tracker.setWorldActive(false)
            print("[gate] world \(id) aborted: tracker paused = \(self.tracker.isPaused), world hold released")
            self.device.restoreBaseTheme(reason: "abort \(id)")
            // Digital Crown: no exit choreography ran, so the card is put back at full size on the desk in one
            // frame rather than flown home.
            self.cancelMiniCardWait()
            self.cardMode = self.returnsToHandForm ? .hand : .full
            self.controller?.leaveMiniCard(animated: false, from: id)
            self.noteReturnedFromWorld()
        }
        // Poses the engine freezes at entry (and prebuilds against at the desk): the tracker's, or the synthesized
        // seated reader in front of the preview card.
        worlds.poseProvider = { [weak self] in
            guard let self else { return WorldEntryPose() }
            if self.previewMode {
                return WorldEntryPose(head: self.previewHeadPose,
                                      card: Transform(translation: [0, self.previewSurfaceHeight, -self.previewDistance]).matrix,
                                      floorY: self.tracker.floorY, surfaceY: self.previewSurfaceHeight,
                                      deskAtRest: self.tracker.presence == .expanded)
            }
            // V3-2b B3 / plan §4 E11: whether the world is growing out of a card on the desk or out of the
            // one in the wearer's hand. Computed here rather than read off `handFormBeforeWorld`, which
            // `onEnterStarted` latches *after* this closure has already been asked for the pose.
            return WorldEntryPose(head: self.tracker.latestDevicePose, card: self.tracker.latestPose,
                                  floorY: self.tracker.floorY, surfaceY: self.tracker.surfaceY,
                                  inHand: self.cardMode == .hand
                                      || (self.usesHandForm && self.tracker.presence.isCarrying),
                                  stillSeconds: self.tracker.stillSeconds,
                                  // v4 B2: a prebuild may only stall a card that is standing on the desk, tracked.
                                  deskAtRest: self.tracker.presence == .expanded)
        }
        worlds.onEnterStarted = { [weak self] id, index in
            guard let self else { return }
            // The context is already frozen; now the gate holds the pose and the desk answers the coin. The desk's
            // light well closes here (the first hook of the entry, before the shell darkens): the v1 frozen card
            // already sits inside the world, and a lit shaft at the desk would be clutter inside it.
            self.controller?.playCoinFeedback(index: index, count: self.worlds.descriptors.count)
            self.controller?.enterWorldShell()
            // v4 B2 §2: the desk ring rests on nothing inside a world.
            self.clearDeskRing(reason: nil)
            self.parkDeskHint()
            self.dismissWakeHint(reason: "a world")
            // The note fan is a desk thing: it goes back into the card before the shell closes over it, and
            // so is the pager — the card is about to become the world's mini card.
            self.handleFan(.worldEntered)
            self.setHandPage(.profile, animated: false)
            self.handFormBeforeWorld = self.cardMode == .hand || (self.usesHandForm && self.tracker.presence.isCarrying)
            self.tracker.setWorldActive(true)
            self.startMiniCardWait(for: id)
        }
        worlds.onHighlightChanged = { [weak self] index in
            self?.controller?.setCoinHighlight(index: index)
        }
        // A hidden world that converts the real room is coming up: scene reconstruction starts now, in its own
        // session, instead of running from the first frame against image tracking.
        worlds.onNeedsRoomMesh = { [weak self] in
            guard let self else { return }
            guard !self.previewMode else {
                // Preview mode has no ARKit at all: the synthetic room is the stand-in, built on the same trigger
                // so the simulator and the headset agree about which worlds get a room.
                print("[mesh] preview: building the synthetic room instead of scene reconstruction")
                self.worlds.fission.prepareSynthetic(center: [0, 0, -0.4], floorY: self.previewSurfaceHeight - 0.72)
                return
            }
            self.tracker.startSceneReconstruction(reason: "world needs the room mesh")
        }
    }

    // MARK: - Mini card

    /// A world entry has started: wait out its `take.miniCardAt` share of the entry — the shell has to be opaque
    /// before the desk card visibly shrinks — and then shrink the card into the world's mini card. The wait is a
    /// task rather than an engine callback because the shrink is a *desk* event: the engine does not know about
    /// the hologram, and the world's own choreography must not have to carry it.
    private func startMiniCardWait(for id: String) {
        cancelMiniCardWait()
        guard let descriptor = worlds.descriptor(id) else { return }
        let fraction = max(0, min(1, descriptor.takeTiming.miniCardAt))
        // `entry.duration` is the engine's `entryDuration` for both shipped worlds (neither converts the room).
        // A hidden `--all-worlds` world whose fission runs longer would start its mini card a little early in
        // *progress* terms — still well after its shell is opaque, which is what the timing is really about.
        let delay = Double(descriptor.entry.duration * fraction)
        miniCardTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled, self.worlds.isActive else { return }
            // The layout swap starts with the shrink (full out 0–0.2 s, mini in 0.3–0.55 s), so the desk layout
            // is gone by the time the card is small enough for it to be unreadable.
            self.cardMode = .mini
            self.controller?.enterMiniCard(head: self.headPose)
        }
    }

    private func cancelMiniCardWait() {
        miniCardTask?.cancel()
        miniCardTask = nil
    }

    // MARK: - Hand pager + OK (v3 H2 §4 / §8)

    /// Whether a carry should become the hand form: the object source places the card **on** the device, so
    /// that is where it goes. `--tracker image` keeps v2's carry, which is all the image tracker's accuracy
    /// in a hand can support.
    var usesHandForm: Bool { tracker.activeSource == .object }
    /// V3-2a H3: the hand deck is live (the card is in its hand form and `--deck` is not off).
    var isDeckActive: Bool { deckEnabled && cardMode == .hand && !worlds.isActive }
    /// Which world card is raised over the name card, so its attachment can show the 「按 OK 进入」 capsule.
    private(set) var raisedWorldCard: String?
    /// The deck's own ring: profile → the first world → the five newest notes → the second world → profile.
    private var deckPager = HandPager()
    /// How long the deck waits before rising out of the card when nothing was on the desk to morph (a
    /// summon: 0.2 s; coming home from a world: 0.5 s, clear of the exit's frame cost).
    @ObservationIgnored private var pendingDeckRiseDelay: Float = 0.2
    /// Plan §4 E2's 1 s cooldown on the pick-up `tick`.
    @ObservationIgnored private var lastCarryTick = Date.distantPast
    /// **V3-2a2 S1**: the presence event the recognition scan is holding until its convergence beat.
    @ObservationIgnored private var heldCardEvent: (presence: PresenceGate.Presence, transition: PresenceGate.Transition?)?
    /// **V3-2b B1 / plan §4 E8.** The strip follows whatever the deck has raised, after a dwell.
    @ObservationIgnored private var stripDwell = StripDwell()
    @ObservationIgnored private var deckStripTask: Task<Void, Never>?

    // MARK: The desk ring (v4 B2 §2)

    /// The one ring UP / DOWN walk on the desk: the gallery's notes (gallery order), then the two world coins.
    @ObservationIgnored private var deskRing = V4.DeskRing()
    /// The gallery card the ring rests on — the one `NoteCardView` draws with the gold rim (nil = none, or a coin).
    private(set) var deskRingNoteID: String?
    @ObservationIgnored private var deskRingExpiry: Task<Void, Never>?
    /// The first-gallery hint 「▲▼ 选择 · OK 打开」: shown once a gallery stands on the desk and a device is linked,
    /// faded at the first press, never again this session.
    private enum DeskHint { case pending, showing, done }
    @ObservationIgnored private var deskHint = DeskHint.pending
    /// A preview that closes on the desk leaves the ring on the note just read, so the strip keeps its `♥N`.
    @ObservationIgnored private var stripStaysOnClose = false
    /// When the open preview was opened (paging inside it keeps the time): `[notes] preview closed …` says how long it was
    /// up (v4 B3 §3.2).
    @ObservationIgnored private var previewOpenedAt: TimeInterval?
    /// **v4 B3 §3.2.** What was going on when a preview closed. Run A's `preview closed (× button)` (lines 761–762) came
    /// 1.6 s after an unasked-for open, on the frame the passport went `held(untracked)`, with a left hand just tracked:
    /// a real pinch on the ×, but by which hand, doing what? The gate's state, how long the panel was up and how far the
    /// nearest tracked wrist was from the passport tell a deliberate close from a hand that brushed it on the way to the
    /// device.
    private var previewCloseContext: String {
        let open = previewOpenedAt.map { String(format: "open %.1f s", uptime - $0) } ?? "open ?"
        let hand = tracker.nearestHandDistance.map { String(format: "hand %.0f cm from the passport", $0 * 100) } ?? "hand -"
        return "gate \(tracker.presence.label) · \(open) · \(hand)"
    }
    /// `--tap-preview-close <s>` (simulator): the preview panel's × button action, `s` seconds after a preview opens —
    /// the simulator cannot pinch the button, so the smoke calls the very closure the button calls.
    var tapPreviewCloseAfter: Double?
    @ObservationIgnored private var tapPreviewCloseFired = false
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// The deck raised something: the device's bottom strip says so `--strip-dwell` seconds later, if the
    /// wearer is still on it. Flipping past three notes sends one strip, not three.
    private func armDeckStrip(_ request: StripDwell.Request, reason: String = "deck dwell") {
        let generation = stripDwell.raise(request, at: Date().timeIntervalSinceReferenceDate)
        deckStripTask?.cancel()
        let seconds = stripDwell.seconds
        deckStripTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard let self, !Task.isCancelled else { return }
            guard let due = self.stripDwell.due(generation, at: Date().timeIntervalSinceReferenceDate) else { return }
            self.device.sendStrip(due.text, reason: reason)
        }
    }

    // MARK: - The desk ring (v4 B2 §2)

    /// What the ring holds right now: the gallery's notes while the gallery is out on the desk, and the worlds.
    private func syncDeskRing() {
        let galleryOut = noteFan == .fanned || (noteFan.previewID != nil && !isDeckActive)
        deskRing.sync(notes: galleryOut ? recentNotes.map(\.id) : [], worlds: worlds.descriptors.map(\.id))
        if deskRing.highlighted?.noteID != deskRingNoteID {
            deskRingNoteID = deskRing.highlighted?.noteID
        }
    }

    /// **UP / DOWN with the passport on the desk** (`DeviceCoordinator.handleButton`; DOWN = +1). With a note open they
    /// turn its page — on the desk the gallery arc *is* the strip: the card that leaves goes back to its slot and the
    /// next one lifts out of its own (the gallery's own switch, `switchPreviewNote`). Otherwise the ring moves.
    func stepDesk(_ delta: Int) {
        syncDeskRing()
        if let current = noteFan.previewID {
            guard let next = deskRing.adjacentNote(to: current, delta: delta) else {
                print("[notes] preview: only one note to page through")
                return
            }
            deskRing.jump(to: .note(next), at: uptime)
            deskRingNoteID = next
            print("[desk] preview → note \(next.prefix(6)) (paged in preview)")
            handleFan(.tapped(next))
            armDeskRingExpiry()
            return
        }
        // v4 B3 §1: a highlight past its window is gone (its card has settled, or is settling): the next step starts from
        // nothing, so DOWN — and OK with no highlight, which is DOWN — lands on the ring's first item.
        if deskRing.hasLapsed(at: uptime) { deskRing.clear() }
        guard let item = deskRing.step(delta, at: uptime) else {
            print("[desk] ring: nothing to highlight (no gallery, no worlds)")
            return
        }
        let position = (deskRing.index ?? 0) + 1
        print("[desk] ring → \(item.label) (\(position)/\(deskRing.items.count))")
        applyDeskRing(item)
        armDeskRingExpiry()
    }

    /// The ring came to rest on `item`: a note lifts (gold rim, 10 mm, ×1.06, a chip) and the strip follows it 0.4 s
    /// later; a world coin is v3's carousel highlight (spring, name capsule, tint, its name spoken) and the strip goes
    /// back to the follower count.
    private func applyDeskRing(_ item: V4.DeskRing.Item) {
        switch item {
        case .note(let id):
            deskRingNoteID = id
            controller?.setNoteHighlight(id)
            if worlds.highlightedIndex != nil { worlds.highlight(nil) }
            if let note = recentNotes.first(where: { $0.id == id }) { armDeckStrip(.likes(note.stripText), reason: "ring dwell") }
        case .world(let id):
            deskRingNoteID = nil
            controller?.setNoteHighlight(nil)
            if let descriptor = worlds.highlight(id: id) { device.speak(descriptor.name) }
            armDeckStrip(.restore, reason: "ring dwell")
        }
    }

    /// The highlight lapses `V4.DeskRing.window` after the last press: it fades, so what OK will do is what the wearer
    /// sees (v4 B3: with nothing lifted, OK is DOWN — the ring's first item comes up).
    private func armDeskRingExpiry() {
        deskRingExpiry?.cancel()
        deskRingExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((V4.DeskRing.window + 0.05) * 1000)))
            guard let self, !Task.isCancelled, self.deskRing.hasLapsed(at: self.uptime),
                  self.noteFan.previewID == nil else { return }
            self.clearDeskRing(reason: String(format: "lapsed after %.0f s", V4.DeskRing.window))
        }
    }

    /// The ring rests on nothing: the lifted card settles, a coin's highlight goes, the strip is the follower count.
    /// `reason` nil = silently (the card is leaving the desk and everything else is being torn down anyway).
    func clearDeskRing(reason: String?) {
        deskRingExpiry?.cancel()
        deskRingExpiry = nil
        let had = deskRing.highlighted != nil
        deskRing.clear()
        deskRingNoteID = nil
        controller?.setNoteHighlight(nil)
        guard had else { return }
        if worlds.highlightedIndex != nil, !worlds.isActive { worlds.highlight(nil) }
        if let reason {
            cancelDeckStrip()
            device.sendStrip(nil)
            print("[desk] ring highlight off (\(reason))")
        }
    }

    /// **v4 B2 §2.** Close the open preview — OK, long OK, the panel's ×, a tap on the panel — the same way from
    /// everywhere. On the desk the ring stays on the note just read (its card lifts once it has landed back in its
    /// slot, and the strip keeps its `♥N`); in the hand the card goes back to its raised deck slot (V3-2a H6).
    func closePreview(via source: String) {
        guard let id = noteFan.previewID else { return }
        let onDesk = !isDeckActive && !isHandPagerActive
        syncDeskRing()
        let keepsHighlight = onDesk && deskRing.items.contains(.note(id))
        stripStaysOnClose = keepsHighlight
        handleFan(.closePreview)
        stripStaysOnClose = false
        print("[notes] preview closed (\(source)) · \(previewCloseContext)")
        previewOpenedAt = nil
        guard keepsHighlight else { return }
        deskRing.jump(to: .note(id), at: uptime)
        deskRingNoteID = id
        controller?.setNoteHighlight(id, after: 0.5)
        armDeskRingExpiry()
    }

    /// **v4 B2 §3.3.** The controller folded the card into the device's last position (a pick-up loss): the gallery and
    /// an open preview go down with it (the fan's `.hidden`, so the rise or the hand deck brings them back as usual), the
    /// desk ring rests on nothing, the strip is the follower count again.
    func notePickupFold(_ folded: Bool) {
        guard folded else { return }
        clearDeskRing(reason: nil)
        parkDeskHint()
        cancelDeckStrip()
        device.sendStrip(nil)
        handleFan(.hidden)
    }

    /// The preview panel left the space (the preview ended, Safari, the space closing): the strip goes back to the follower
    /// count — unless the desk ring is resting on a note, whose `♥N` it is showing on purpose (v4 B2 §2).
    func notePreviewDisappeared() {
        guard deskRingNoteID == nil || !immersiveSpaceIsOpen else { return }
        device.sendStrip(nil)
    }

    /// **v4 B2 §2.** The first gallery on the desk, with a device to press: 「▲▼ 选择 · OK 打开」 beside it, until the
    /// first press. Not in the hand (the deck has its own rule) and never again once pressed.
    private func showDeskHintIfFirstGallery() {
        guard deskHint == .pending, deviceConnected, cardMode != .hand, !worlds.isActive else { return }
        deskHint = .showing
        controller?.setDeskRingHint(visible: true)
        print("[desk] hint 「▲▼ 选择 · OK 打开」 (first gallery)")
    }

    /// **v4 B4 §3.5 — `cmd perf <switches>`**, from the Hub's `POST /api/cmd` (over its WebSocket, and relayed by the
    /// device over BLE: the same command can arrive twice). It **sets** a state (`V4.PerfSwitches`), so a second arrival
    /// changes nothing; within a second it does not open a second window either. Every command opens a fresh 5 s `[perf]`
    /// window and prints the scene line as it stands.
    func applyPerfCommand(_ arg: String?, source: String) {
        let raw = (arg ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let now = uptime
        // v4 B5 §1: this also keeps a rehearsal — an action — from playing twice when its command arrives twice.
        if let last = lastPerfCommand, last.arg == raw, now - last.at < 1.0 {
            print("[perf] cmd perf \"\(raw)\" again (\(source)) within 1 s: the same command, applied once")
            return
        }
        lastPerfCommand = (raw, now)
        let command = V4.PerfSwitches.parse(raw)
        var next = perfSwitches
        next.apply(command)
        let changed = next != perfSwitches
        let baseBefore = noteBase
        // Only a real change is written: an observed property set to the same value still re-runs every view that reads
        // it — the ten gallery cards re-evaluated on a measure-only command (`--perf-census`: note card bodies +10).
        if changed { perfSwitches = next }
        // v4 B5 §2: which ground the gallery's SwiftUI cards draw is otherwise invisible in the log.
        if noteBase != baseBefore { print("[notes] note base → \(noteBase.rawValue) (cmd perf)") }
        worlds.setPrebuiltInTree(next.isOn(.worlds))
        // v4 B5 §4: a world's tier, forced (now if inside one, else at the next entry).
        worlds.setForcedQuality(next.tier.flatMap { ["low": WorldQuality.low, "medium": .medium, "high": .high][$0.rawValue] })
        controller?.applyPerfSwitches(next)
        let unknown = command.unknown.isEmpty ? "" : " — ignored: \(command.unknown.joined(separator: " "))"
        print("[perf] cmd perf \"\(raw)\" (\(source)) → \(next.summary)\(unknown)")
        if changed, rehearsalTask != nil {
            rehearsalStraddled = true
            print("[perf] cmd perf: rehearsal #\(rehearsalCount) is still playing — its windows now straddle this switch")
        }
        // v4 B5 §1: the window opens once the switch has settled (2 s unless `wait=` says otherwise).
        let settle = V4.PerfSwitches.settle(for: command, changedState: changed)
        if let kind = command.rehearse {
            rehearse(kind, after: settle)
        } else {
            controller?.startPerfSwitchWindow(label: next.summary, settle: settle)
        }
    }

    // MARK: cmd perf rehearse (v4 B5 §1)

    @ObservationIgnored private var rehearsalTask: Task<Void, Never>?
    @ObservationIgnored private var rehearsalCount = 0
    /// A switch arrived while a rehearsal was playing: its windows are not clean, and its log says so.
    @ObservationIgnored private var rehearsalStraddled = false
    /// From the rehearsal's collapse to its fan-out. The collapse's last card is home at ≈ 0.71 s and its dust is silenced
    /// at ≈ 0.83 s (`collapseNotes`); 1.6 s leaves the desk at rest for a beat before the fan is thrown again.
    static let rehearsalGap: Double = 1.6

    /// Where the card is, as a rehearsal sees it (`V4.PerfRehearsalContext`).
    private func rehearsalContext(galleryMustBeOut: Bool = true) -> V4.PerfRehearsalContext {
        let card = controller?.rehearsalCardState
        return V4.PerfRehearsalContext(
            spaceOpen: immersiveSpaceIsOpen && controller != nil,
            inWorld: worlds.isActive,
            cardShown: card?.shown ?? false,
            inHand: (card?.inHand ?? false) || isDeckActive,
            previewOpen: noteFan.previewID != nil,
            busy: card?.busy ?? false,
            galleryOut: !galleryMustBeOut || noteFan == .fanned)
    }

    /// **v4 B5 §1 — `cmd perf rehearse=fanout`.** One real collapse and fan-out of the desk gallery, timed by the fan-out's
    /// own `[perf] desk fan out` window: the director replays the transition in whatever state the layers are in while
    /// the wearer sits looking at the desk. It goes through `toggleNotesFan` — the card's own pinch — twice, so every rule
    /// the fan-out is welded to (`NoteFanMachine`'s suppression and preview guards, the trails' rest rule, the world
    /// engine's quiet window) runs exactly as it does for a wearer. One at a time; refused, with the reason, anywhere the
    /// pinch would mean something else.
    private func rehearse(_ kind: V4.PerfRehearsal, after settle: Double) {
        guard rehearsalTask == nil else {
            print("[perf] rehearse \(kind.rawValue): #\(rehearsalCount) is still playing — ignored (send it again after its window)")
            return
        }
        if let refusal = rehearsalContext().refusal {
            print("[perf] rehearse \(kind.rawValue) refused: \(refusal)")
            return
        }
        // A state window an earlier command opened would straddle the rehearsal.
        controller?.cancelPerfSwitchWindow(reason: "the rehearsal")
        rehearsalCount += 1
        rehearsalStraddled = false
        let number = rehearsalCount
        let summary = perfSwitches.summary
        print(String(format: "[perf] rehearse fanout #%d (%@): in %.1f s the gallery goes back into the card, and %.1f s later it "
                     + "fans out again — toggleNotesFan, the card's own pinch, twice", number, summary, settle, AppModel.rehearsalGap))
        rehearsalTask = Task { @MainActor [weak self] in
            if settle > 0 { try? await Task.sleep(for: .milliseconds(Int(settle * 1000))) }
            guard let self else { return }
            defer { self.rehearsalTask = nil }
            guard !Task.isCancelled else { return }
            if let refusal = self.rehearsalContext().refusal {
                print("[perf] rehearse #\(number) refused after the settle: \(refusal)")
                return
            }
            self.controller?.printPerfScene("rehearse #\(number), before the collapse · \(summary)")
            self.controller?.startPerfProbe("desk collapse (rehearse #\(number) · \(summary))", duration: 0.8,
                                            carrier: "rehearse collapse")
            self.toggleNotesFan(via: "cmd perf rehearse #\(number)")
            try? await Task.sleep(for: .milliseconds(Int(AppModel.rehearsalGap * 1000)))
            guard !Task.isCancelled else { return }
            // Only the fan-out is left. If the desk changed under it (the passport picked up, a world opened), the app
            // owns the gallery now — but the collapse was the director's, so it must not stay suppressed.
            if self.noteFan != .collapsed || self.rehearsalContext(galleryMustBeOut: false).refusal != nil {
                let reason = self.rehearsalContext(galleryMustBeOut: false).refusal ?? "the fan is \(self.noteFan.label)"
                print("[perf] rehearse #\(number): no fan-out — \(reason); the collapse's suppression is lifted")
                self.handleFan(.unsuppress)
                return
            }
            let straddled = self.rehearsalStraddled ? ", a switch came in during it" : ""
            self.controller?.perf.fanOutProbeLabel = "desk fan out (rehearse #\(number) · \(summary)\(straddled))"
            self.toggleNotesFan(via: "cmd perf rehearse #\(number)")
            if self.noteFan != .fanned {
                self.controller?.perf.fanOutProbeLabel = nil
                print("[perf] rehearse #\(number): the fan did not go out (\(self.noteFan.label))")
                self.handleFan(.unsuppress)
                return
            }
            // Still "playing" until the fan-out's 1.2 s window has reported: a second rehearsal must not overlap it.
            try? await Task.sleep(for: .milliseconds(1400))
        }
    }

    /// Any key: the hint has done its job (and so has 「OK · 唤醒」, v4 B3 §2).
    func noteButtonPressed() {
        // v4 B4 §2: a hand leaving the passport in the next 1.5 s is the hand that pressed the key, not a pick-up.
        controller?.notePickupKey()
        dismissWakeHint(reason: "a key")
        guard deskHint != .done else { return }
        let wasShowing = deskHint == .showing
        deskHint = .done
        guard wasShowing else { return }
        controller?.setDeskRingHint(visible: false)
        print("[desk] hint faded (first press)")
    }

    /// The gallery left the desk before anything was pressed: the hint goes with it and waits for the next gallery.
    private func parkDeskHint() {
        guard deskHint == .showing else { return }
        deskHint = .pending
        controller?.setDeskRingHint(visible: false)
    }

    /// `--tap-preview-close <s>`: the × button's own action, once, `s` seconds after the first preview opens.
    private func scheduleDebugPreviewClose() {
        guard let seconds = tapPreviewCloseAfter, !tapPreviewCloseFired else { return }
        tapPreviewCloseFired = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard let self, self.noteFan.previewID != nil else { return }
            print("[notes] --tap-preview-close \(seconds): tapping the panel's ×")
            self.closePreview(via: "× button")
        }
    }

    /// Something else is writing the strip (a preview opening, a fold, a put-down, leaving the hand): a dwell
    /// in flight must not come back 0.3 s later and paint over it.
    private func cancelDeckStrip() {
        deckStripTask?.cancel()
        deckStripTask = nil
        stripDwell.cancel()
    }

    /// The strip the deck would ask for right now: the raised note's `♥N`, or the follower count.
    private var deckStripRequest: StripDwell.Request {
        raisedDeckNote.map { .likes($0.stripText) } ?? .restore
    }

    /// v3 FIX B: a world is giving the desk back and the passport is still in the wearer's hand, so the card
    /// goes home to the hand form. The gate is *still* `held(.world)` when the exit choreography runs — its
    /// presence cannot answer this — so the controller's memory of what form the world took is the fallback.
    private var returnsToHandForm: Bool {
        guard usesHandForm else { return false }
        // `handFormBeforeWorld` is latched at entry and lives for the whole world, because the controller
        // clears its own flag the moment the card lands and `onReturnedToDesk` can fire either side of that.
        return handFormBeforeWorld || tracker.presence.isCarrying || controller?.returnsToHand == true
    }

    /// A world has given the desk back. The note fan is a **desk** thing: coming home into the wearer's hand
    /// must not throw ten cards off a card floating above a device they are holding. It waits for the
    /// put-down, which reaches the fan through `settled` like any other landing.
    private func noteReturnedFromWorld() {
        let intoHand = returnsToHandForm
        handFormBeforeWorld = false
        guard !intoHand else {
            print("[notes] back in the hand: the fan waits for the card to be put down")
            // V3-2a H3 / plan §4 E11: …but the **deck** does come back, half a second after the card lands
            // on the hinge, so the hand is not empty. The delay keeps it out of the world exit's 55 fps.
            guard deckEnabled, usesHandForm else { return }
            fan.deckEnabled = true
            deckPager.deck = true
            deckPager.reset()
            // Half a second, so the rise is not competing with the world exit's own 55 fps.
            pendingDeckRiseDelay = 0.5
            handleFan(.carried)
            return
        }
        handleFan(.returnedFromWorld)
    }

    /// Device DOWN (`+1`) / UP (`-1`) while the passport is in the wearer's hand.
    func stepHandPage(_ delta: Int) {
        guard !isDeckActive else { return stepDeck(delta) }
        pager.sync(worlds: worlds.descriptors.map(\.id), notes: recentNotes.map(\.id))
        guard let page = pager.step(delta) else {
            print("[hand] only one page (no worlds, no notes)")
            return
        }
        print("[hand] page → \(page.label)")
        setHandPage(page, animated: true)
        controller?.playPageFlip()
        device.playCue(.tick, reason: "hand page")
    }

    /// **V3-2a H3.** UP / DOWN with the deck in the hand: the name card does not change at all — one of the
    /// seven cards behind it rises over it (or, back at the profile, none of them does).
    func stepDeck(_ delta: Int) {
        deckPager.deck = true
        deckPager.sync(worlds: worlds.descriptors.map(\.id), notes: recentNotes.map(\.id))
        // **V3-4 §2(b).** With a note open in front of the wearer, UP / DOWN turn the page *inside* the
        // preview: the big card sinks back into the thumbnail strip and its neighbour comes up out of it.
        // The ring is the five notes only — a world card is not something a preview can show — and it is the
        // deck's own order, so paging and the strip agree about what "next" means.
        //
        // The order of the next three lines is the whole of it: `previewNoteFromCard` decides whether the
        // preview came out of the deck by asking whether `deckRaised == id`, so the raise has to land first.
        if let current = noteFan.previewID, controller?.hasNoteStrip == true {
            guard let next = adjacentDeckNote(to: current, delta: delta) else {
                print("[notes] preview: only one note to page through")
                return
            }
            deckPager.jump(to: .note(next))
            controller?.raiseDeckCard(next)
            handleFan(.previewDirect(next))
            device.playCue(.tick, reason: "preview page")
            return
        }
        guard let page = deckPager.step(delta) else {
            print("[hand] only one page (no worlds, no notes)")
            return
        }
        let id: String?
        switch page {
        case .profile: id = nil
        case .world(let worldID): id = worldID
        case .note(let noteID): id = noteID
        }
        handleFan(.raiseDeck(id))
        let slot = controller?.raiseDeckCard(id)
        if let slot {
            print("[hand] raise → \(page.label) (slot \(slot))")
        } else {
            print("[hand] raise → none")
        }
        device.playCue(.tick, reason: "deck raise")
        // **B1 / plan §4 E8**: and the real bottom strip follows it — 0.4 s later, so flipping past a card
        // never reaches the device. A world card and the profile both mean "give the follower count back".
        armDeckStrip(deckStripRequest)
    }

    /// The deck's five notes, in deck order — the ring a preview pages inside (V3-4 §2b).
    private var deckNoteIDs: [String] {
        deckPager.pages.compactMap { page in
            if case .note(let id) = page { return id }
            return nil
        }
    }

    /// The note `delta` steps from `id` in the deck's own order, wrapping both ways.
    private func adjacentDeckNote(to id: String, delta: Int) -> String? {
        let ids = deckNoteIDs
        guard ids.count > 1, let index = ids.firstIndex(of: id) else { return nil }
        return ids[((index + delta) % ids.count + ids.count) % ids.count]
    }

    /// What the raised deck card is, if it is a note (H6's OK target).
    private var raisedDeckNote: RecentNote? {
        guard case .note(let id) = deckPager.page else { return nil }
        return recentNotes.first { $0.id == id }
    }

    private var raisedDeckWorld: String? {
        guard case .world(let id) = deckPager.page else { return nil }
        return id
    }

    /// The pager's page, and the card's, with the 0.175 s the flip needs between them.
    private func setHandPage(_ page: HandPage, animated: Bool) {
        handPageTask?.cancel()
        handPageTask = nil
        guard animated else {
            if page.isProfile { pager.reset() }
            handPageShown = page
            return
        }
        handPageTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(AppModel.handPageSwapDelay * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.handPageShown = page
        }
    }

    // MARK: - The keys (v4 B3 §1)

    /// **Where a press lands right now** (`V4.ButtonMap.Context`), in the table's order of precedence: a world, an open
    /// preview, the collapsed card, a recognition still holding the entrance, a pick-up fold, the hand, the desk.
    var keyContext: V4.ButtonMap.Context {
        if worlds.isActive {
            if case .inside = worlds.state { return .world(inside: true) }
            return .world(inside: false)
        }
        if noteFan.previewID != nil { return .preview }
        if tracker.isDismissed { return .collapsed }
        if controller?.isArriving == true { return .arriving }
        if controller?.pickup.folded == true { return .pickupFolded }
        if isHandPagerActive { return .hand(raised: handRaised) }
        if tracker.presence.showsHologram {
            syncDeskRing()
            let ring = deskRing.current(at: uptime) != nil
            let coin = worlds.highlightedDescriptor != nil && worlds.highlightedRecently
            let held: Bool
            if case .held(let reason) = tracker.presence { held = reason == .stale || reason == .untracked } else { held = false }
            return .desk(highlight: ring || coin, held: held)
        }
        return .nothing
    }

    /// Something other than the profile is up in the hand: a raised deck card, or (`--deck off`) a world / note page.
    private var handRaised: Bool {
        if isDeckActive { return raisedDeckWorld != nil || raisedDeckNote != nil }
        return !handPageShown.isProfile
    }

    /// **One press of a device key** (`DeviceCoordinator.handleButton`): the table in `V4.ButtonMap`, and one
    /// `[keys]` line that says what the press was taken to mean.
    func handleKey(_ key: V4.ButtonMap.Key) {
        let context = keyContext
        let action = V4.ButtonMap.action(key, in: context)
        print(V4.ButtonMap.line(key, context, action))
        switch action {
        case .exitWorld:
            print("[ble] \(key.rawValue) → leave \(worlds.state.worldID ?? "?")")
            worlds.exitToDesk()
        case .ignore:
            break
        case .closePreview:
            print("[ble] \(key == .ok ? "ok" : "long ok") → close preview")
            closePreview(via: key == .ok ? "OK" : "long OK")
        case .pagePreview(let delta):
            if isHandPagerActive { stepHandPage(delta) } else { stepDesk(delta) }
        case .deskStep(let delta):
            if key == .ok, case .desk(_, let held) = context, held {
                print("[desk] ok on a lost card (\(tracker.presence.label)): the ring's first item, as DOWN would")
            }
            stepDesk(delta)
        case .deskOpen:
            openDeskHighlight()
        case .handStep(let delta):
            stepHandPage(delta)
        case .handOpen:
            openHandRaised()
        case .collapse:
            collapseCard(reason: "long OK")
        case .summon:
            print("[ble] ok → show")
            controller?.playShowFeedback()
            requestShowCard()
        }
    }

    /// OK on the desk ring's fresh highlight: open the note or enter the world it rests on (v4 B2 §2) — or a world coin
    /// v3's carousel highlighted in the last 5 s.
    private func openDeskHighlight() {
        syncDeskRing()
        if let item = deskRing.current(at: uptime) {
            switch item {
            case .note(let id):
                print("[ble] ok → open \(id.prefix(6)) (desk ring)")
                deskRingExpiry?.cancel()
                handleFan(.tapped(id))
            case .world(let id):
                print("[ble] ok → enter \(id) (desk ring)")
                worlds.highlight(id: id)
                worlds.enterHighlighted()
            }
            return
        }
        if let descriptor = worlds.highlightedDescriptor, worlds.highlightedRecently {
            print("[ble] ok → enter \(descriptor.id)")
            worlds.enterHighlighted()
        }
    }

    /// OK on what is raised in the hand (V3-2a H6): a world card enters its world, a note card opens its preview. With
    /// `--deck off` the same for v3's pager pages.
    private func openHandRaised() {
        if isDeckActive {
            if let id = raisedDeckWorld {
                print("[ble] ok → enter \(id)")
                worlds.highlight(id: id)
                worlds.enterHighlighted()
            } else if let note = raisedDeckNote {
                print("[ble] ok → open \(note.id.prefix(6))")
                handleFan(.previewDirect(note.id))
            }
            return
        }
        switch handPageShown {
        case .world(let id):
            print("[ble] ok → enter \(id)")
            worlds.highlight(id: id)
            worlds.enterHighlighted()
        case .note(let id):
            print("[ble] ok → open \(id.prefix(6))")
            handleFan(.previewDirect(id))
        case .profile:
            break
        }
    }

    // MARK: - Collapse and the wake hint (v4 B3 §2)

    /// How many collapses this session has had (`V4.Collapse.showsWakeHint`: the first three get 「OK · 唤醒」).
    @ObservationIgnored private var collapseCount = 0
    @ObservationIgnored private var wakeHintTask: Task<Void, Never>?
    @ObservationIgnored private var wakeHintShowing = false

    /// **Collapse** (long OK, the passport face down for 0.8 s, `cmd hide`): the gate hides the card with `.dismiss`
    /// and the controller folds it into the device's gold point (`--v3-card`: v3's fold and socket light). The first
    /// three of a session get 「OK · 唤醒」 beside the keys 1.5 s later.
    func collapseCard(reason: String) {
        guard !tracker.isDismissed else { return }
        print("[desk] collapse (\(reason))")
        tracker.requestDismiss()
        guard tracker.isDismissed else { return }
        collapseCount += 1
        scheduleWakeHint()
    }

    private func scheduleWakeHint() {
        wakeHintTask?.cancel()
        let nth = collapseCount
        guard V4.Collapse.showsWakeHint(collapse: nth) else { return }
        wakeHintTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(V4.Collapse.wakeHintDelay * 1000)))
            // A key to press needs a device to press it on (B2's first-gallery hint has the same rule).
            guard let self, !Task.isCancelled, self.tracker.isDismissed, !self.worlds.isActive,
                  self.deviceConnected else { return }
            self.wakeHintShowing = true
            self.controller?.setWakeHint(visible: true)
            print("[desk] hint 「OK · 唤醒」 (collapse \(nth) of the first \(V4.Collapse.wakeHintCollapses))")
        }
    }

    /// A key, or the card coming back by any other way: the hint has done its job (or is moot).
    private func dismissWakeHint(reason: String) {
        wakeHintTask?.cancel()
        wakeHintTask = nil
        guard wakeHintShowing else { return }
        wakeHintShowing = false
        controller?.setWakeHint(visible: false)
        print("[desk] hint 「OK · 唤醒」 faded (\(reason))")
    }

    /// The passport was turned face down for 0.8 s (`DeviceGestures`), or is on its way there (B4).
    func handleGesture(_ event: DeviceGestures.Event) {
        switch event {
        case .faceDown:
            guard !tracker.isDismissed, tracker.presence.showsHologram else { return }
            print("[gesture] face down 0.8 s → dismiss")
            collapseCard(reason: "face down")
        case .anticipation(let on):
            // **V3-2b B4 / plan §4 E12.** Past 120° the card gathers itself up: it is the *cause* of the fold
            // made visible 0.6 s before the fold, which is what makes the flip read as the wearer closing a
            // laptop rather than as the app reacting to one. Turning back cancels it; nothing else changes.
            guard !tracker.isDismissed, tracker.presence.showsHologram else { return }
            if on {
                let tilt = (tracker.objectTilt ?? 0) * 180 / .pi
                print(String(format: "[gesture] face down: anticipation (tilt %.0f°)", tilt))
            } else {
                print("[gesture] anticipation cancelled")
            }
            controller?.setFoldAnticipation(on)
        }
    }

    // MARK: - Worlds

    /// Coin tap / `--world` harness: highlight, then enter with the poses `poseProvider` reports.
    func enterWorld(_ id: String) {
        guard !worlds.isActive, worlds.descriptor(id) != nil else { return }
        worlds.highlight(id: id)
        worlds.enterHighlighted()
    }

    func exitWorld() {
        worlds.exitToDesk()
    }

    // MARK: - Recent notes (工作包 D)

    /// A new list from the hub (or `--fake-notes`). Same rev = the caller never got here.
    func applyNotes(_ payload: RecentNotesPayload, source: String) {
        let previous = recentNotesRev
        recentNotes = payload.notes
        recentNotesRev = payload.rev
        // The hand pager's note pages come from this list; a page for a note that has gone falls back to the
        // profile rather than rendering an empty frame.
        pager.sync(worlds: worlds.descriptors.map(\.id), notes: payload.notes.map(\.id))
        if !pager.pages.contains(handPageShown) { handPageShown = .profile }
        // v4 B2 §2: a new list re-lays the gallery out; the ring starts over rather than lifting a card that moved.
        if payload.notes.map(\.id) != recentNotes.map(\.id) || previous != payload.rev { clearDeskRing(reason: nil) }
        print("[notes] \(payload.notes.count) notes (\(source), rev \(previous) → \(payload.rev))")
        handleFan(.notesChanged(ids: payload.notes.map(\.id)))
    }

    /// A pinch on one of the cards.
    func tapNote(_ id: String) {
        handleFan(.tapped(id))
    }

    /// **A pinch on the desk card, or the desk's 「笔记」 chip** (no device linked): inside a world it is the way out, in a
    /// preview it is the way back to the arc, otherwise it throws or takes back the fan (`NoteFanMachine.longOK`).
    ///
    /// v4 B3 §1: this used to be the device's long OK as well. Long OK is the collapse now (`handleKey`), and these two
    /// keep the fan toggle — routed here, not through the key table, or a pinch on the card would put it away.
    func toggleNotesFan(via source: String) {
        if worlds.isActive {
            worlds.exitToDesk()
            return
        }
        // v4 B2 §2: the same close as OK's (the ring stays on the note just read).
        if noteFan.previewID != nil {
            closePreview(via: source)
            return
        }
        handleFan(.longOK)
    }

    /// 「在小红书打开」: the strip goes back to the follower count *before* Safari takes the space away.
    func openNote(_ note: RecentNote) -> URL? {
        cancelDeckStrip()
        device.sendStrip(nil)
        return note.link
    }

    /// Where a cover comes from: the hub's proxy for a relative path, a bundled file for the `--fake-notes` set.
    func coverURL(for note: RecentNote) -> URL? {
        guard let path = note.coverURL, !path.isEmpty else { return nil }
        if path.hasPrefix("/") { return device.notesClient?.coverURL(for: note) }
        if let absolute = URL(string: path), absolute.scheme != nil { return absolute }
        return ScriptFile.url(path)
    }

    /// The card reached a steady state on the desk (`HologramController.startIdle`). Inside a world that is the
    /// mini card coming home, which `onReturnedToDesk` already covers.
    func noteCardSettled() {
        guard !worlds.isActive || worlds.hologramReleased else { return }
        handleFan(.settled)
        // v4 B2 §2: once the gallery has landed (the reveal's fan-out, or the put-down bloom), the first-gallery hint.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((AppModel.autoFanDelay + HologramController.fanSettleSeconds + 0.2) * 1000)))
            guard let self, self.noteFan == .fanned else { return }
            self.showDeskHintIfFirstGallery()
        }
    }

    /// Presence transitions the gate produced: the two that take the card away concern the fan, and
    /// `DeviceCueRules` reads the whole stream to decide when the device rings along (工作包 A 设备联动).
    func noteCard(presence: PresenceGate.Presence, transition: PresenceGate.Transition?) {
        // Anything that reaches here for real supersedes an event a scan was holding (a `.hide` that
        // cancels the scan, say): there is only ever one entrance in flight. **Unless** the scan is still
        // holding one — a `.freeze` is passed through while the scan finishes on the frozen pose, and it
        // must not throw away the entrance that is waiting for the beat.
        if controller?.isHoldingEntrance != true { heldCardEvent = nil }
        // v4 B3 §2: the card is back (by any way — OK, `cmd show`, a replay): 「OK · 唤醒」 has nothing left to say.
        switch transition {
        case .cinematic?, .reentry?, .carry?: dismissWakeHint(reason: "the card is back")
        default: break
        }
        switch transition {
        case .carry?:
            // v4 B2 §2: the desk ring and its hint are desk things; the hand has the deck.
            clearDeskRing(reason: nil)
            parkDeskHint()
            cancelDeckStrip()
            if noteFan.previewID != nil { device.sendStrip(nil) }
            // Plan §4 E2: the device answers the pick-up in the hand that did it — but a summon into a hand
            // arrives as a `.carry` too, and it already has `liftOff`, so one tick per second is the rule.
            let now = Date()
            if now.timeIntervalSince(lastCarryTick) > 1 {
                lastCarryTick = now
                device.playCue(.tick, reason: "picked up")
            }
            // V3-2a H3: the gallery becomes the deck rather than folding away, but only when the hand form
            // is reachable at all (`--tracker image` keeps v2's shrink-and-ride) and `--deck` is on.
            fan.deckEnabled = deckEnabled && usesHandForm && !worlds.isActive
            deckPager.deck = true
            deckPager.reset()
            raisedWorldCard = nil
            handleFan(.carried)
            // v3 H2 §1: the device is in a hand, so the card becomes the hand form — and the pager with it.
            if usesHandForm, !worlds.isActive {
                setHandPage(.profile, animated: false)
                cardMode = .hand
            }
        case .settle?:
            cancelDeckStrip()
            if noteFan.previewID != nil { device.sendStrip(nil) }
            if cardMode == .hand { cardMode = .full }
            handFormBeforeWorld = false
            setHandPage(.profile, animated: false)
            deckPager.reset()
            raisedWorldCard = nil
            // **V3-5 §7b.** The headset recording: a world card raised in the hand tints the edge ring its
            // colour, and after the put-down the desk ring was still purple. The deck is gone at a settle
            // and so is what was raised on it, so the tint goes with them — unless a **desk coin** is
            // highlighted, which is the wearer's own live choice and outlives the put-down.
            if worlds.hologramTint != nil,
               !(worlds.highlightedDescriptor != nil && worlds.highlightedRecently) {
                worlds.clearTheme()
                print("[reveal] world tint reset (settled)")
            }
        case .hide?:
            clearDeskRing(reason: nil)
            parkDeskHint()
            cancelDeckStrip()
            handleFan(.hidden)
            if cardMode == .hand { cardMode = .full }
            setHandPage(.profile, animated: false)
            deckPager.reset()
            raisedWorldCard = nil
        default: break
        }
        if let cue = cues.handle(presence: presence, transition: transition) {
            device.playCue(cue, reason: transition?.label ?? presence.label)
        }
    }

    /// V3-2a H3: the deck raised (or dropped) a world card — its attachment gains the 「按 OK 进入」 capsule
    /// and the card's rim takes the world's colour at 0.5.
    func setRaisedWorldCard(_ id: String?) {
        guard raisedWorldCard != id else { return }
        raisedWorldCard = id
    }

    /// **V3-2a2 S1.** A summon the wearer asked for: the next detection draws the short scan instead of
    /// going straight to the entrance, and the entrance waits for its convergence beat.
    ///
    /// **v4 B3 §2.** Without `--v3-card` the summon is the *whole* recognition again: the gate forgets it has revealed
    /// the card (`replayRecognition`), so the next detection is a first acquire and `startBoxScan` runs the ribbon — the
    /// same path as the session's first recognition, cinematic on the desk, unfold in the hand. The device's `connect`
    /// stays once per session (`DeviceCueRules.revealed`, which this does not touch): every summon rings `tick`.
    func requestShowCard() {
        dismissWakeHint(reason: "summoned")
        controller?.noteSummonRequested()
        tracker.requestShow(replayRecognition: !v3Card)
    }

    /// **V3-2a2 S1.** The recognition scan converged: the wireframe has become the socket light. The one
    /// `connect` of the session belongs here (a summon gets a `tick`), and so does the `[obj] glow window`
    /// measurement's second half, which `DeviceCoordinator` schedules from the send.
    func noteScanConverged() {
        guard let cue = cues.scanConverged() else { return }
        device.playCue(cue, reason: "box scan converged")
        // A summon into a hand arrives as a `.carry` too, and the pick-up's own `tick` would land on the
        // very same beat. The scan's is the one the wearer asked for, so it takes the cooldown with it.
        if cue == .tick { lastCarryTick = Date() }
    }

    /// **V3-2a2 S1.** The scan held a presence event back (the controller said so) — the app's half of it
    /// waits for the convergence beat too, or the hand of cards rises out of a device that is still closed.
    func holdCardEvent(presence: PresenceGate.Presence, transition: PresenceGate.Transition?) {
        heldCardEvent = (presence, transition)
    }

    /// The entrance the scan was holding has started: run the app's half of it now.
    func noteScanEntranceStarted() {
        guard let held = heldCardEvent else { return }
        heldCardEvent = nil
        noteCard(presence: held.presence, transition: held.transition)
    }

    /// The pose follower landed a relocation glide: the card is standing on its new place now.
    func noteCardLanded() {
        if let cue = cues.landed() { device.playCue(cue, reason: "relocation landed") }
    }

    /// One event through the machine, and the one thing its outcome asks the choreography to do.
    func handleFan(_ event: NoteFanMachine.Event) {
        // V3-4 §2(b): what was open *before* the machine ran is what tells a page apart from an opening.
        let previewBefore = fan.state.previewID
        let outcome = fan.handle(event)
        guard outcome != .none else { return }
        // v4 B2: the wearer is reading, or has just stopped: a world prebuild (a 100–200 ms stall) must not land on
        // the page they are looking at. Round 1 built both worlds between two previews.
        switch outcome {
        case .preview, .switchPreview, .endPreview: worlds.noteDeskActivity()
        default: break
        }
        // A fan thrown by itself waits out the settle's own choreography; one the wearer asked for does not.
        let delay: Double
        switch event {
        case .longOK, .tapped, .previewDirect, .raiseDeck, .carried: delay = 0
        default: delay = AppModel.autoFanDelay
        }
        switch outcome {
        case .fanOut:
            worlds.noteDeskActivity()
            fanTask?.cancel()
            let ids = recentNotes.map(\.id)
            fanTask = Task { @MainActor [weak self] in
                if delay > 0 { try? await Task.sleep(for: .milliseconds(Int(delay * 1000))) }
                guard let self, !Task.isCancelled, self.noteFan == .fanned else { return }
                self.controller?.fanOutNotes(ids: ids)
                self.scheduleDebugPreview(ids: ids)
                self.scheduleDebugCardTaps()
            }
        case .collapse:
            fanTask?.cancel()
            cancelDeckStrip()
            device.sendStrip(nil)
            controller?.collapseNotes(animated: true)
        case .sink:
            fanTask?.cancel()
            cancelDeckStrip()
            device.sendStrip(nil)
            controller?.sinkNotes()
        case .relayout:
            controller?.relayoutNotes(ids: recentNotes.map(\.id))
        case .morphToDeck:
            fanTask?.cancel()
            cancelDeckStrip()
            device.sendStrip(nil)
            let riseDelay = pendingDeckRiseDelay
            pendingDeckRiseDelay = 0.2
            controller?.morphGalleryToDeck(worlds: worlds.descriptors.map(\.id),
                                           noteIDs: recentNotes.map(\.id), riseDelay: riseDelay)
        case .relayoutDeck:
            controller?.relayoutDeck(worlds: worlds.descriptors.map(\.id), noteIDs: recentNotes.map(\.id))
        case .preview(let id):
            // The preview is immediate (plan §4 E7): it is the wearer asking for *this* card, not flipping
            // past it — and whatever dwell was in flight belongs to the same card anyway.
            cancelDeckStrip()
            if let note = recentNotes.first(where: { $0.id == id }) { device.sendStrip(note.stripText) }
            // v4 B3 §3.2: a new preview (not a page inside an open one) starts the clock `preview closed` reports.
            if previewBefore == nil { previewOpenedAt = uptime }
            // v3 H2 §8: a preview the hand card opened has no fan behind it — the note flies straight out of
            // the card and back into it.
            if case .previewDirect = event {
                if let from = previewBefore, from != id, controller?.hasNoteStrip == true {
                    // A page inside an open preview, not a new one: the big card sinks into the strip and
                    // the next one lifts out of it (V3-4 §2b).
                    controller?.pagePreviewNote(from: from, to: id)
                } else {
                    controller?.previewNoteFromCard(id: id)
                }
            } else {
                controller?.previewNote(id: id)
            }
            scheduleDebugPreviewClose()
        case .switchPreview(let from, let to):
            cancelDeckStrip()
            if let note = recentNotes.first(where: { $0.id == to }) { device.sendStrip(note.stripText) }
            controller?.switchPreviewNote(from: from, to: to)
        case .endPreview:
            cancelDeckStrip()
            // v4 B2 §2: a desk close leaves the ring on the note just read, so its `♥N` stays on the strip.
            if !stripStaysOnClose { device.sendStrip(nil) }
            controller?.endPreviewNote()
            // B1: the card the preview came from is still raised over the hand, and the strip follows what is
            // raised — so the dwell re-arms and `♥N` comes back 0.4 s after the panel has gone. (The brief
            // does not say; this is the reading that keeps one rule instead of two.)
            if isDeckActive { armDeckStrip(deckStripRequest) }
        case .none:
            break
        }
    }

    /// `--preview-tap-card`: the simulator cannot tap the desk card either, and the desk card's tap is no longer
    /// a link into Safari — it is the note fan's toggle (`ImmersiveView.tapCard` → `toggleNotesFan`). Two scripted
    /// taps three seconds apart, so one run shows it taking the fan back and throwing it out again.
    private func scheduleDebugCardTaps() {
        guard previewTapsCard, !previewCardTapFired else { return }
        previewCardTapFired = true
        Task { @MainActor [weak self] in
            for beat in 0..<2 {
                let wait = beat == 0 ? HologramController.fanSettleSeconds + 2 : 3
                try? await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                guard let self else { return }
                print("[notes] --preview-tap-card: tapping the desk card (fan is \(self.noteFan == .collapsed ? "collapsed" : "out"))")
                self.toggleNotesFan(via: "card tap")
            }
        }
    }

    /// `--preview-note <index>`: the simulator cannot pinch a card, so one tap is scripted, once, two seconds
    /// after the fan has landed.
    private func scheduleDebugPreview(ids: [String]) {
        guard let index = previewNoteIndex, !previewNoteFired, ids.indices.contains(index) else { return }
        previewNoteFired = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((HologramController.fanSettleSeconds + 2) * 1000)))
            guard let self, self.noteFan == .fanned else { return }
            print("[notes] --preview-note \(index): pinching \(ids[index].prefix(6))")
            self.tapNote(ids[index])
        }
    }

    /// How long after the card settles the fan is thrown by itself.
    static let autoFanDelay: Double = 0.6

    // MARK: - Stats / celebration

    /// Newer sample wins (the device de-duplicates by `ts` the same way).
    func apply(stats new: CardStats) {
        guard stats.shouldAccept(new) else {
            print("[stats] ignoring older sample (\(new.source) ts \(new.ts) ≤ \(stats.ts))")
            return
        }
        stats = new
        worlds.stats = new
        print("[stats] followers \(new.followers) likes \(new.likes) notes \(new.notes) (\(new.source))")
    }

    /// New followers: desk choreography (or the world's own), the number rolls, the badge shows. Nothing is
    /// echoed back to the link it came from: `fromDevice` celebrations are not sent to the device (the firmware
    /// forwards BLE celebrations, which would loop), while `fromHub` ones (device off USB) and local director
    /// triggers are relayed down to the device so its LCD count and chime follow. `/vp` is one-way, so a hub
    /// celebration has nothing to echo back to.
    /// `relayToDevice` overrides that rule for the one case where the origin does not decide it: a director
    /// `cmd celebrate` runs the choreography only (the hub drives the device over its own link).
    func celebrate(delta: Int, followers: Int?, fromDevice: Bool, fromHub: Bool = false, relayToDevice: Bool? = nil) {
        let target = followers ?? (stats.followers + delta)
        let origin = fromDevice ? "device" : (fromHub ? "hub" : "director")
        let updated = CardStats(followers: target, likes: stats.likes, notes: stats.notes, delta: delta, updatedAt: Date(), source: origin)
        print("[celebrate] +\(delta) → \(target) (\(fromDevice ? "device" : (fromHub ? "hub" : "local")))\(worlds.isActive ? " inside \(worlds.state.worldID ?? "?")" : "")")
        if relayToDevice ?? !fromDevice, device.isConnected {
            device.sendStats(updated)
            device.sendCelebrate(delta: delta)
        }
        if worlds.isActive {
            stats = updated
            worlds.stats = updated
            worlds.celebrate(delta: delta)
            return
        }
        guard let controller else {
            stats = updated
            worlds.stats = updated
            return
        }
        controller.playCelebration(delta: delta, hooks: CelebrationHooks(
            writeStats: { [weak self] in
                self?.stats = updated
                self?.worlds.stats = updated
            },
            showBadge: { [weak self] in self?.deltaBadge = delta },
            hideBadge: { [weak self] in self?.deltaBadge = nil }))
    }
}
