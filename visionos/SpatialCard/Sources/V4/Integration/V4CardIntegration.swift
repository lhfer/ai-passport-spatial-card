import Foundation
import QuartzCore
import RealityKit
import UIKit

/// **v4 B1 — the hero card and the recognition, wired into the product.**
///
/// Everything the v4 path adds to `HologramController` lives here (state) and in `HologramController+V4` (glue), so
/// the 3,900-line controller only gains a handful of `if let v4` hooks and `--v3-card` is exactly v3.
///
///     cardGroup                     ← v3's card frame: the rest pose, the pick-up onto the hinge, the fold, the mini
///     └─ cardFaceGroup                card, the billboard — every v3 choreography keeps moving this, untouched
///        └─ mount (inverse rest)    ← A4's rig writes its pose in the screen frame S; this undoes cardGroup's rest
///           └─ rig.root               pose so the two agree, and fades the whole card for the placeholder's reveal
///
/// The rig hangs under `cardFaceGroup` so the back-face flip (V3-3 C3) cross-fades it against the QR for free.
@MainActor
final class V4CardIntegration {
    let rig: HeroCardRig
    let mount = Entity()
    let geometry: V4.HeroCardMount
    /// A2's recognition, or nil if it could not be built (the first detection then plays v3's box scan).
    let recognition: RecognitionMagic?
    private let placeholder: PlaceholderCardSurfaceStyle
    /// A1's materials, once they have loaded (`V4MaterialPreload`); nil until then — the placeholder dresses the card.
    private(set) var magic: MagicCardSurfaceStyle?
    private var magicInstalled = false
    /// A1's materials failed to load: there is nothing to wait for (the hand-over hold releases at once).
    private(set) var magicFailed = false
    /// A1's style is not on the card yet but can still come (loading, or loaded and not yet installed).
    /// v4 B2: never under `--card-style placeholder` (the first reveal does not hold its hand-over for materials that
    /// are not coming).
    var magicMayStillArrive: Bool { !magicInstalled && !magicFailed && !V4MaterialPreload.placeholderOnly }

    /// **The hand-over hold in progress** (`V4.HandOverHold`): the closure found A1's style missing, the recognition
    /// waits with its outline breathing, and the entrance stays held until `HologramController.stepHandOverHold`
    /// releases it.
    struct HandOverHoldState {
        /// Wall clock at the closure (the cap and the logged hold are measured from it).
        let startedAt: CFTimeInterval
        /// The recognition's time at the closure (for the release's log line).
        let closureTime: Float
    }
    var handOverHold: HandOverHoldState?
    /// After a hold's release: the recognition's clock runs on when the card's entrance clock reaches `cardClock` — or,
    /// with no reveal to follow, `V4.HandOverHold.resumeGrace` after `releasedAt`.
    struct RecognitionResume {
        let cardClock: Double
        let releasedAt: CFTimeInterval
    }
    var recognitionResume: RecognitionResume?

    /// Seconds since the current entrance started (the rig samples its timeline at this).
    private(set) var clock: Double = 0
    /// An entrance is playing (the recognition's in-place reveal, or a rise): the billboard is held at 0 so the card
    /// stays exactly in the outline the ribbon drew / on its path off the screen.
    private(set) var entranceKind: EntranceKind = .idle
    enum EntranceKind: String { case idle, reveal, rise }
    /// The recognition has started and not yet reached its closure: presence entrances are held for the beat
    /// (`BoxScanTimeline.Pending`, unchanged). `RecognitionMagic.isRunning` lasts 0.8 s past the closure and must
    /// not be used for this.
    var recognitionHolding = false
    /// The billboard's blend (0 = the card's own orientation, 1 = facing the wearer), eased after every entrance.
    private(set) var billboardBlend: Float = 1
    /// The first frame after an entrance has ended: the blend eases 0 → 1 over this.
    static let billboardEase: Float = 0.5

    /// When the rig's in-place reveal last wrote the slab / the mount (so the end of it is written exactly once).
    private var revealApplied: Float = -1
    /// An entrance (or `showAtRest`) has put the card on screen at least once: before that the rig stands at A4's
    /// first frame (flat on the screen, transparent) and a v3 choreography must not pick it up from there.
    private(set) var hasEntered = false
    /// The `[perf] v4 desk idle` window: armed the first time the card rests on the desk, dropped (and re-armed at the
    /// next rest) when the desk scene ends inside it.
    var deskIdleProbeArmed = false
    var deskIdleProbeTask: Task<Void, Never>?
    /// Wall-clock time of the last rendered frame (the hitch log).
    var lastTickAt: CFTimeInterval?
    /// A frame whose wall-clock gap exceeds this is logged (`--v4-hitch-ms`, default 100 ms).
    var hitchThreshold: CFTimeInterval = 0.1
    /// `--v4-freeze` (screenshots): the recognition-clock moment to hold. Once the reveal has started the card's own
    /// clock is held at the same moment (minus the closure), so a still is exactly that instant of the product path.
    var freezeAt: Float?
    /// **v4 B3** `--v4-freeze-run <n>`: freeze only the session's `n`-th recognition (1 = the first; a summon is 2), so a
    /// still of a summon's ribbon can be taken after a real collapse. Nil = every run (B1's behaviour).
    var freezeRun: Int?
    /// How many recognitions this session has started (`startV4Recognition`).
    var recognitionRuns = 0
    /// **v4 B4 §1.** A recognition flying the hand's path: what decided it, the hinge angle frozen at take-off and the
    /// flight's geometry. Set by `startV4Recognition`; read at the closure (the hand reveal, or the desk's fallback rise),
    /// cleared after it and by a hide.
    struct HandRecognition {
        let decision: V4.RecognitionPlan.Decision
        let hingeAngle: Float
        let geometry: V4.RecognitionTimeline.HandGeometry
    }
    var handRecognition: HandRecognition?
    /// **v4 B4 §1.** The decision of the recognition now running (desk or hand), until its closure has run — for the
    /// fallback's log line when the gate lands the other way.
    var closingRecognitionDecision: V4.RecognitionPlan.Decision?
    /// Does `--v4-freeze` apply to the recognition running now?
    var freezesThisRun: Bool { freezeAt != nil && (freezeRun == nil || freezeRun == recognitionRuns) }
    private var cardFreeze: Double?

    private init(rig: HeroCardRig, geometry: V4.HeroCardMount, recognition: RecognitionMagic?,
                 placeholder: PlaceholderCardSurfaceStyle) {
        self.rig = rig
        self.geometry = geometry
        self.recognition = recognition
        self.placeholder = placeholder
        mount.name = "v4.heroMount"
        let rest = V4.HeroCardMount.inverseRest
        mount.transform = Transform(scale: [1, 1, 1], rotation: rest.rotation, translation: rest.translation)
        mount.addChild(rig.root)
        Self.splitSortGroupAroundTheType(rig)
    }

    /// **The type layer under the frost (found in the hand-form stills).** A4's rig draws its fourteen see-through pieces
    /// in one sort group; its type is a SwiftUI attachment. Square-on (the desk card, billboarded) the attachment is
    /// composited after the group, but seen at an angle — the hand form — it went *under* the 42 % frost: faint in one
    /// run, gone in the next. A3 found the same flip at ≈ 20° and the fix: put the meshes in
    /// `ModelSortGroup.planarUIAlwaysBehind` (orders unchanged), so planar UI always composites after them. Measured
    /// with `--card-sort` (hand + desk stills, `b1-sort-ab.jpg`): `a4` and two splits of the group around the type lose
    /// the type in the hand (and a split shows A4's opaque shadow caster as a grey board); `ui-behind` keeps it crisp in
    /// both poses. The deck and the gallery — attachments *behind* the card — still stay behind it: the card's opaque
    /// pieces (the shadow caster, the sky layer) write depth and occlude them.
    /// `--card-sort ui-behind|a4|split` (the A/B; `ui-behind` is the product's).
    static var sortMode: String = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--card-sort"), i + 1 < args.count else { return "ui-behind" }
        return args[i + 1]
    }()

    private static func splitSortGroupAroundTheType(_ rig: HeroCardRig) {
        let mode = sortMode
        guard mode != "a4" else {
            print("[v4] card sort: A4's single group (--card-sort a4)")
            return
        }
        let behind = mode == "ui-behind" ? ModelSortGroup.planarUIAlwaysBehind : ModelSortGroup(depthPass: nil)
        let front = mode == "ui-behind" ? ModelSortGroup.planarUIAlwaysBehind : ModelSortGroup(depthPass: nil)
        // The surface's six (slab, frost, foil, halo / rim, gold line, sweep) are orders 0…5 (`HeroCardRig.init`).
        let lastBehind: Int32 = 5
        var moved = (behind: 0, front: 0)
        func walk(_ entity: Entity) {
            if var sort = entity.components[ModelSortGroupComponent.self], sort.group == rig.sortGroup {
                if sort.order <= lastBehind { sort.group = behind; moved.behind += 1 } else { sort.group = front; moved.front += 1 }
                entity.components.set(sort)
            }
            entity.children.forEach(walk)
        }
        walk(rig.root)
        print("[v4] card sort (\(mode)): \(moved.behind + moved.front) meshes\(mode == "ui-behind" ? " in planarUIAlwaysBehind (type always on top)" : " split around the type")")
    }

    struct Options {
        var card: CardData
        var followers: Int
        /// The LCD's lit area (the rig's start size, and the burst layer).
        var screen: SIMD2<Float>
        var ribbonWidth: Float?
        var dustScale: Float = 1
        var screenBurst = true
    }

    /// Builds the rig (≈ 150–210 ms: textures + two async programs) with A4's placeholder style, and A2's recognition
    /// with the portrait card's outline. A1's style is swapped in when its materials are loaded (`installMagicIfReady`).
    static func make(_ options: Options) async -> V4CardIntegration {
        let started = CACurrentMediaTime()
        let placeholder = await PlaceholderCardSurfaceStyle.make()
        let rig = await HeroCardRig.make(shape: .portrait,
                                         content: HeroCardContent(card: options.card, followers: options.followers),
                                         style: placeholder, odometerStyle: .wheel, screen: options.screen)
        let geometry = V4.HeroCardMount(layout: rig.layout)
        var recognition: RecognitionMagic?
        do {
            let magic = try await RecognitionMagic.make(geometry: .heroCard(rig.layout), screenSize: options.screen,
                                                        screenLift: 0.0006,
                                                        spec: V4.GoldDustSpec.standard.scaled(by: options.dustScale),
                                                        ribbonWidth: options.ribbonWidth)
            magic.screenBurstEnabled = options.screenBurst
            recognition = magic
        } catch {
            print("[v4] recognition rig failed to build (\(error)); the first detection keeps v3's box scan")
        }
        let integration = V4CardIntegration(rig: rig, geometry: geometry, recognition: recognition, placeholder: placeholder)
        print(String(format: "[v4] hero card built in %.0f ms (%@ %.2f × %.2f m, %d entities, style %@); recognition %@ (ribbon %.1f mm, dust peak %d)",
                     (CACurrentMediaTime() - started) * 1000, rig.layout.shape.rawValue, rig.layout.size.x, rig.layout.size.y,
                     rig.entityCount, rig.style.name, recognition == nil ? "off" : "ready",
                     (recognition?.ribbon.style.profile.width ?? 0) * 1000, recognition?.spec.peakAlive ?? 0))
        return integration
    }

    // MARK: - Materials

    /// Loads A1's style (instant once `V4MaterialPreload` is done) and keeps it for the next safe moment.
    func loadMagic() async {
        guard magic == nil else { return }
        guard !V4MaterialPreload.placeholderOnly else {
            print("[v4] --card-style placeholder: A1's materials are not loaded; the card keeps A4's placeholder style (the perf A/B)")
            return
        }
        await V4MaterialPreload.wait()
        do {
            magic = try await MagicCardSurfaceStyle.make()
            print("[v4] A1 materials ready (style a1-magic)")
        } catch {
            magicFailed = true
            print("[v4] A1 materials failed (\(error)); the card keeps A4's placeholder style")
        }
    }

    /// Swap to A1's style — only when nothing on screen can pop: before the first entrance, or at the start of one.
    @discardableResult
    func installMagicIfReady() -> Bool {
        guard let magic, !magicInstalled else { return magicInstalled }
        magicInstalled = true
        rig.setStyle(magic)
        print("[v4] card style → a1-magic")
        return true
    }

    var styleName: String { rig.style.name }

    // MARK: - cmd perf (v4 B4 §3.5)

    /// The other frost's A1 style, built the first time `cmd perf material=` asks for it.
    private var otherFrostMagic: MagicCardSurfaceStyle?
    /// A material switch waiting for the card to be at rest (an entrance in flight owns its slab).
    private var pendingPerfMaterial: V4.PerfCardMaterial??

    /// **v4 B4 §3.5** `cmd perf material=plain|blur|placeholder` (nil = back to the launch's): the card's own material,
    /// live. Applied when the card is at rest (an entrance in flight finishes first). The other frost loads on first use.
    func setPerfMaterial(_ material: V4.PerfCardMaterial?) async {
        guard entranceKind == .idle else {
            pendingPerfMaterial = .some(material)
            print("[perf] material switch waits for the card's entrance to finish")
            return
        }
        switch material {
        case .placeholder?:
            rig.setStyle(placeholder)
            print("[perf] card material → placeholder (A4's style, no A1 graph)")
        case .plain?, .blur?:
            let blur = material == .blur
            if blur == V4.MagicMaterialGraphs.backgroundBlur {
                guard let magic else { return print("[perf] card material: A1's style is not loaded (yet)") }
                rig.setStyle(magic)
            } else {
                if otherFrostMagic == nil {
                    let started = CACurrentMediaTime()
                    do {
                        otherFrostMagic = try await MagicCardSurfaceStyle.make(frostBlur: blur)
                        print(String(format: "[perf] card material: the %@ frost's graphs loaded in %.0f ms (first use)",
                                     blur ? "blur" : "plain", (CACurrentMediaTime() - started) * 1000))
                    } catch {
                        return print("[perf] card material: the \(blur ? "blur" : "plain") frost failed to load (\(error))")
                    }
                }
                guard let other = otherFrostMagic, entranceKind == .idle else { return }
                rig.setStyle(other)
            }
            print("[perf] card material → a1-magic, frost \(blur ? "blur" : "plain")")
        case nil:
            if let magic, magicInstalled { rig.setStyle(magic) } else { rig.setStyle(placeholder) }
            print("[perf] card material → the launch's (\(rig.style.name), frost \(V4.MagicMaterialGraphs.backgroundBlur ? "blur" : "plain"))")
        }
    }

    /// A material switch that waited for an entrance, now that it is over.
    func applyPendingPerfMaterial() {
        guard entranceKind == .idle, let pending = pendingPerfMaterial else { return }
        pendingPerfMaterial = nil
        Task { @MainActor [weak self] in await self?.setPerfMaterial(pending) }
    }

    // MARK: - Entrances

    /// Start an entrance from its first frame. `.reveal` = the recognition's in-place dissolve (the count rolls up);
    /// `.rise` = off the screen without the count (a reentry, a summon on the desk, a put-down that brings it back).
    func beginEntrance(_ kind: EntranceKind) {
        installMagicIfReady()
        hasEntered = true
        entranceKind = kind
        clock = 0
        revealApplied = -1
        billboardBlend = 0
        writtenBlend = -1
        cardFreeze = nil
        switch kind {
        case .reveal:
            rig.restart(with: .revealInPlace())
            if let freezeAt, freezesThisRun, let closure = recognition?.timeline.beats.closure, freezeAt >= closure {
                cardFreeze = Double(freezeAt - closure)
            }
        case .rise: rig.restart(with: .riseWithoutCount())
        case .idle: break
        }
        applyReveal()
    }

    /// Straight to the resting card (an instant restore, `animated: false`).
    func showAtRest() {
        installMagicIfReady()
        hasEntered = true
        entranceKind = .idle
        rig.restart(with: .riseWithoutCount())
        clock = rig.timeline.entranceDuration + 0.01
        revealApplied = -1
        applyReveal(force: true)
        rig.apply(at: clock)
        billboardBlend = 1
        writtenBlend = -1
    }

    /// A v3 choreography (the pick-up onto the hinge, the fold, the mini card, the unfold) is about to move the card.
    /// A rise off the screen is written against the desk's rest pose and cannot be carried half-way — it is cut to its
    /// resting frame; a card never shown is put at rest. The in-place reveal (the pose *is* the rest) plays on.
    func settleForV3Choreography(reason: String) {
        onLeaveDeskIdle?(reason)
        guard !hasEntered || entranceKind == .rise else { return }
        showAtRest()
        print("[v4] card at rest for the \(reason)")
    }

    /// Told when a v3 choreography takes the card off the desk (the controller drops its desk-idle `[perf]` window).
    var onLeaveDeskIdle: ((String) -> Void)?

    /// v3's resident desk motes are quiet from the recognition's start to the end of the reveal.
    var quietsDeskParticles: Bool { recognitionHolding || entranceKind == .reveal }

    /// Set when an entrance has just completed (the controller re-evaluates what it quieted for it, then clears it).
    var entranceJustCompleted = false

    /// Seconds from the start of the current entrance to the moment the card is complete (count landed / popped).
    var entranceDuration: Double { rig.timeline.entranceDuration }
    /// For the in-place reveal: when the count lands.
    var countLanding: Double { rig.timeline.countLanding }

    /// One rendered frame. `visible` = the card is on screen (its hologram enabled): off screen the rig is not sampled
    /// at all. Returns the billboard blend to write (nil = unchanged).
    func step(dt: Float, viewer: SIMD3<Float>?, visible: Bool) -> Float? {
        guard visible else { return nil }
        clock += Double(max(0, min(dt, 0.1)))
        if let hold = cardFreeze, clock >= hold {
            if clock - Double(max(0, min(dt, 0.1))) < hold {
                print(String(format: "[v4] card frozen at %.2f s into the reveal (--v4-freeze)", hold))
            }
            clock = hold
        }
        if let viewer { rig.viewerPosition = { viewer } }
        applyReveal()
        rig.apply(at: clock)
        if entranceKind != .idle, clock >= rig.timeline.entranceDuration {
            print(String(format: "[v4] entrance (%@) complete at %.2f s", entranceKind.rawValue, clock))
            entranceKind = .idle
            entranceJustCompleted = true
            applyPendingPerfMaterial()
        }
        // The billboard: held at 0 through the entrance, then eased to 1.
        let target: Float = entranceKind == .idle ? 1 : 0
        if billboardBlend != target {
            let step = Float(dt) / Self.billboardEase
            billboardBlend = target > billboardBlend ? min(target, billboardBlend + step) : max(target, billboardBlend - step)
        }
        let eased = currentBillboardBlend
        guard eased != writtenBlend else { return nil }
        writtenBlend = eased
        return eased
    }

    /// The blend the billboard should carry right now (the controller writes it whenever it re-creates the component).
    var currentBillboardBlend: Float { V4.smoothstep(0, 1, billboardBlend) }
    private var writtenBlend: Float = -1

    /// The controller re-created the billboard: the next frame writes the blend again.
    func billboardReset() { writtenBlend = -1 }

    /// The in-place reveal's slab: A1's dissolve when the magic style is on, else a plain fade of the whole card
    /// (the placeholder has no dissolve). Written only while it changes.
    private func applyReveal(force: Bool = false) {
        let p = Float(rig.timeline.dissolveProgress(at: clock))
        guard force || abs(p - revealApplied) > 0.0005 else { return }
        revealApplied = p
        // The style on the card decides (v4 B4: `cmd perf` can put the placeholder or the other frost on it).
        if let magic = rig.style as? MagicCardSurfaceStyle {
            magic.setReveal(p < 1 ? p : nil, on: rig.surface)
            mount.components.set(OpacityComponent(opacity: 1))
        } else {
            mount.components.set(OpacityComponent(opacity: p))
        }
    }

    // MARK: - Followers

    /// The live count (`AppModel.stats`): rolled on screen, set off it.
    func setFollowers(_ followers: Int, visible: Bool) {
        rig.setFollowers(followers, animated: visible && entranceKind == .idle)
    }

    // MARK: - H0

    /// Every mesh of the hero card is part of the hinged card: tolerated over the top bezel while (and only while) it
    /// hangs off the hinge, like v3's slab and rim (`FootprintProbeComponent.hingeOverhang`).
    func probeForHinge(maxDepth: Float) {
        func walk(_ entity: Entity) {
            if let model = entity as? ModelEntity, model.model != nil {
                model.components.set(FootprintProbeComponent(.hingeOverhang(maxDepth: maxDepth)))
            }
            entity.children.forEach(walk)
        }
        walk(rig.root)
    }
}

extension V4.RecognitionTimeline.Geometry {
    /// **v4 B1 §2**: the ribbon draws the **portrait** hero card — 0.20 × 0.28 m, A4's corners — where the card will
    /// stand: 0.22 m above the screen, leaning back 6° (the rig's rest pose).
    static func heroCard(_ layout: V4.HeroCardLayout) -> Self {
        var g = Self.standard
        g.cardWidth = layout.size.x
        g.cardHeight = layout.size.y
        g.cornerRadius = layout.cornerRadius
        g.cardCenterHeight = V4.HeroCardMount.restHeight
        g.cardTiltDegrees = V4.HeroCardMount.restPitch * 180 / .pi
        return g
    }
}
