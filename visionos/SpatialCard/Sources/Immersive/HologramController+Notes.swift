import Foundation
import RealityKit
import simd
import UIKit

/// Everything the note fan owns (工作包 D 笔记扇出). A Swift extension cannot add stored properties, so the
/// fan's entities and its bookkeeping live here and `HologramController` holds exactly one of them.
///
/// The group hangs off `hologram`, which means it rides the **frozen anchor pose** like the card does — a lost
/// image freezes the gallery where it is instead of dragging it around, and folding the card away takes it
/// with it. The card's `BillboardComponent` sits on `cardGroup`, not on `hologram`, so nothing here turns with
/// the head: the cards are **yawed** toward the wearer once, when they are placed, and then they stay put — a
/// gallery that swung around with every glance would stop being a place.
@MainActor
final class NoteFanRig {
    /// Parent of every note card, of the twinkle field and of the preview panel (so the group's drift moves
    /// all of them together).
    let group = Entity()
    let previewHolder = Entity()
    /// One holder per note id; the RealityView attachment is its only child.
    var holders: [String: Entity] = [:]
    /// One pixie-dust emitter per note id, **sibling** to the holder (see `NoteTrailComponent`): a holder's
    /// `OpacityComponent` would fade the trail out with the card, and its `isEnabled = false` on landing would
    /// kill the sparks still in the air.
    var trails: [String: Entity] = [:]
    /// The slow twinkle field that hangs in the air around the settled gallery.
    let twinkle = Entity()
    /// **v4 B4 §3.4.** The gallery's trails rest with their cards: the poll's clock, when each card last flew, and
    /// whether the rest has been logged since the last flight.
    var deskTrailPoll: Float = 0
    var trailLastFlight: [String: CFTimeInterval] = [:]
    var deskTrailsParkedLogged = false
    /// The whole group's very slow drift is installed once, so a second fan-out does not restart its phase.
    var driftInstalled = false
    /// The ids in fan order (index 0 = leftmost slot).
    var order: [String] = []
    /// The card currently enlarged in front of the wearer.
    var previewID: String?
    /// The fan is out (fanned or previewing).
    var isOut = false
    /// Staggered cues / crossfades of the choreography in flight.
    var task: Task<Void, Never>?
    /// **V3-4 §2(c).** The preview's own tail — the reparent home and the `deck restored` check — on a
    /// handle of its own. `sinkNotes` and `collapseNotes` both cancel `task` on the line after they end the
    /// preview; sharing one handle meant an animated close left its cards in `notePreviewRoot` for good.
    var previewTask: Task<Void, Never>?
    /// **V3-6 §3.** The delayed park of the gallery trails the deck does not hold, so the five cards folding
    /// into the card still trail for the 0.45 s their fold takes.
    var deckTrailPark: Task<Void, Never>?
    /// **V3-4 §2(a).** The debounced "where did the deck land" check: armed by a preview closing, postponed
    /// by every deck event after it (a raise, a re-layout), fired 1 s after the last of them.
    var restoredTask: Task<Void, Never>?
    var restoredArmed = false
    /// `HologramController.startIdle()` — every steady state on the desk ends there, which is the fan's cue.
    var onIdle: (() -> Void)?
    /// Told at the start and the end of a fan-out, so the world engine can keep its 4 s prebuild out of it.
    var onActivity: (() -> Void)?
    /// The landing pool's own resting brightness, remembered while the preview dims it.
    var landingLevel: Float?
    /// v3 H2 §8: the preview on screen came from the hand card's note page, so it goes home *into the card*.
    var directPreview = false

    // MARK: - The hand deck (V3-2a H3)

    /// One holder per world, permanent residents of the group like the note holders: the two `WorldCardView`
    /// attachments that take the outer slots of the hand deck. **Not** coins — `setCoinHighlight` tweens
    /// every coin back to its place on the desk arc, which would yank one out of the wearer's hand.
    var worldHolders: [String: Entity] = [:]
    /// The deck is standing in the hand.
    var deckOut = false
    /// Which deck card is raised over the name card.
    var deckRaised: String?
    /// The deck in slot order (the first world, the five newest notes, the second world).
    var deckOrder: [HandDeckLayout.Item] = []
    /// The group's desk drift, parked while the deck rides a hand.
    var parkedDrift: FloatComponent?
    /// The desk gate's "a put-down is coming" anticipation is playing.
    var deckAnticipating = false
    /// The preview on screen came out of the **deck**, so it goes home to its raised slot (H6).
    var fromDeck = false
    /// **V3-4 §2(b).** The other four notes, while one of them is open: they leave the hand and line up on a
    /// thumbnail strip under the big card, in deck order, in `notePreviewRoot` — the same world-locked space
    /// the big card is in. Empty whenever no deck preview is open.
    var stripIDs: [String] = []
    /// **V3-2b B2.** One pixie-dust emitter per **world** card, the note cards' `trails` for the two holders
    /// the desk gallery never had: in the hand all seven cards trail, not just the five notes.
    var worldTrails: [String: Entity] = [:]
    /// **v4 B2.** The debounced park of the deck's own trails once the hand is still and nothing is in flight.
    var idleTrailPark: Task<Void, Never>?
    /// …and whether the park has said so this session (once is enough for the log).
    var idleTrailsParkedLogged = false
    /// **v4 B2 §2.** The gallery card the desk's button ring rests on (lifted, 6 % larger, gold rim).
    var highlightedID: String?
    /// The delayed re-lift after a preview closes (the card first has to land back in its slot).
    var highlightTask: Task<Void, Never>?
    /// **v4 B2 §2.** The first-gallery hint 「▲▼ 选择 · OK 打开」, standing on the desk beside the device.
    let ringHintHolder = Entity()

    /// The trail entity of any card the deck can hold, note or world.
    func trail(for id: String) -> Entity? { trails[id] ?? worldTrails[id] }

    /// Every holder the hand could be holding: the ten note cards and the two world cards. **V3-2a2 S0b**
    /// walks this once a frame to keep whatever carries a `DeckAnchorComponent` glued to the cover, so it
    /// is a lazy sequence over the two dictionaries rather than a fresh array twelve times a frame.
    func forEachHolder(_ body: (Entity) -> Void) {
        for holder in holders.values { body(holder) }
        for holder in worldHolders.values { body(holder) }
    }
}

extension HologramController {
    // MARK: - Constants

    static func noteAttachmentID(_ id: String) -> String { "note-\(id)" }
    static let notePreviewAttachmentID = "note-preview"
    static let notesChipAttachmentID = "notes-chip"

    /// Fan-out: 0.55 s per card, 60 ms apart, from the middle of the gallery outward (both rows at once).
    static let noteFanDuration: Float = 0.55
    static let noteFanStagger: Double = 0.06
    /// Collapse: 0.35 s per card, 40 ms apart, from the ends inward.
    static let noteCollapseDuration: Float = 0.35
    static let noteCollapseStagger: Double = 0.04
    /// From `fanOutNotes()` to the last card standing still (9 × 60 ms + 550 ms, rounded up).
    static let fanSettleSeconds: Double = 1.2
    /// Preview: 0.55 m along the wearer's gaze, 5 cm below it, and 2.6 × the card (= the panel's own size).
    static let notePreviewDistance: Float = 0.55
    static let notePreviewDrop: Float = 0.05
    static let notePreviewScale: Float = 2.6
    /// Where the preview goes when there is no head pose at all (`--preview` in the simulator before world
    /// tracking exists): straight in front of a standing wearer.
    static let notePreviewFallback: SIMD3<Float> = [0, 1.35, -1]
    /// While a note is previewed the card behind it steps out of the way — it is the light, not the content.
    static let notePreviewCardOpacity: Float = 0.35
    /// …and 0.6 while the preview came out of the hand deck (plan §4 E7).
    static let deckPreviewCardOpacity: Float = 0.6
    static let notePreviewLandingLevel: Float = 0.18
    /// **V3-4 §2(b), the thumbnail strip.** How far under the big card's **bottom edge** the strip hangs
    /// (the card is 0.13 m × 2.6 = 34 cm tall, so measuring from its centre would put the row inside it),
    /// how far apart the thumbnails stand, how big they are relative to a deck slot, and how far they lean
    /// back toward the eye.
    static let noteStripDrop: Float = 0.06
    /// Half the big card's own height, which the drop is measured from.
    static var notePreviewHalfHeight: Float { NoteFanLayout.cardSize.y * notePreviewScale / 2 }
    static let noteStripSpacing: Float = 0.08
    static let noteStripScale: Float = HandDeckLayout.slotScale * 0.9
    static let noteStripPitch: Float = -10 * .pi / 180
    /// One thumbnail's flight, and the stagger between them.
    static let noteStripDuration: Float = 0.45
    static let noteStripStagger: Double = 0.04
    /// Paging inside a preview: the big card sinks in 0.35 s and the next one lifts 0.1 s into that.
    static let notePageSink: Float = 0.35
    static let notePageOverlap: Double = 0.1

    /// The other cards, while one of them is being read: a little further out, a little smaller.
    static let noteStepBackRadius: Float = 0.03
    static let noteStepBackScale: Float = 0.92

    // MARK: - Constants (idle life and pixie dust)

    /// The gallery is never quite still: each card bobs ±8 mm on its own 5–7 s period (phased by index) and
    /// sways ±2° in roll and pitch, while the whole group drifts ±10 mm on 11 s.
    static let noteBobAmplitude: Float = 0.008
    static let noteBobPeriod: ClosedRange<Float> = 5...7
    static let noteSwayDegrees: Float = 2
    static let noteTiltPeriod: ClosedRange<Float> = 8.5...10.2
    static let noteGroupDrift: Float = 0.010
    static let noteGroupDriftPeriod: Float = 11
    /// Not straight up: a drift with a little sideways in it reads as air, not as a lift.
    static let noteGroupDriftAxis = simd_normalize(SIMD3<Float>(0.34, 0.92, 0.19))

    /// Pixie dust. A card throws `noteTrailBirthRate` sparks/s for the 0.55 s of its flight; ten cards 60 ms
    /// apart emit ≈ 520 over 1.09 s and a spark lives 0.8 s, so ≈ 385 are alive at the peak — with the ≈ 55 of
    /// the twinkle field and the card's own 30/s field that is comfortably inside the 600 budget.
    static let noteTrailBirthRate: Float = 95
    static let notePreviewBurst = 60
    /// Warm gold and aurora blue: the two colours every spark is drawn from.
    static let noteDustGold = UIColor(hex: "#FFE2A0")
    static let noteDustAurora = UIColor(hex: "#BFD4FF")
    /// The box the twinkle field fills — the gallery's own extent plus a hand's width of air around it.
    static let noteTwinkleCenter: SIMD3<Float> = [
        0,
        HologramLayout.cardCenterHeight + NoteFanLayout.riseAboveCard + NoteFanLayout.rowRise / 2,
        NoteFanLayout.wearerEstimate.z - (NoteFanLayout.nearRadius + NoteFanLayout.farRadius) / 2 + 0.02
    ]
    static let noteTwinkleSize: SIMD3<Float> = [0.74, 0.34, 0.20]
    /// ≈ 55 motes alive: 10 born per second, each living 5.6 s on average — well inside the 120 idle budget.
    static let noteTwinkleBirthRate: Float = 10

    // MARK: - Attachments

    /// Called from the RealityView's **update** closure, before the world guard: attachments for notes that
    /// arrived after the view was made (the usual case — the hub answers seconds after the space opens) have
    /// no other way in. Idempotent and cheap: everything below is an identity check.
    func syncNoteAttachments(ids: [String], lookup: (String) -> Entity?) {
        updateNoteHolders(ids: ids)
        for (id, holder) in notes.holders {
            guard let entity = lookup(HologramController.noteAttachmentID(id)), entity.parent !== holder else { continue }
            entity.transform = .identity
            holder.addChild(entity)
        }
        if let panel = lookup(HologramController.notePreviewAttachmentID), panel.parent !== notes.previewHolder {
            panel.transform = .identity
            notes.previewHolder.addChild(panel)
        }
    }

    /// The desk's 「笔记」 chip, mirroring the 退出 chip at the other end of the coin arc (−90°). It only
    /// matters when no device is linked: the fan is normally the device's long OK.
    func attachNotesChip(_ entity: Entity) {
        if coinGroup.parent == nil {
            coinGroup.position = [0, 0.003, 0]
            surface.addChild(coinGroup)
        }
        let angle: Float = -90 * .pi / 180
        let radius: Float = HologramController.orbArcRadius + 0.09
        let holder = Entity()
        holder.position = [sin(angle) * radius, 0.02, cos(angle) * radius]
        holder.orientation = simd_quatf(angle: angle * 0.5, axis: [0, 1, 0]) * simd_quatf(angle: -30 * .pi / 180, axis: [1, 0, 0])
        holder.addChild(entity)
        coinGroup.addChild(holder)
    }

    /// Create the holders a new list needs and retire the ones it dropped. New holders start folded into the
    /// card, so whatever runs next (a fan-out, a re-layout) has something to animate from.
    private func updateNoteHolders(ids: [String]) {
        guard notes.order != ids else { return }
        let wanted = Set(ids)
        for (id, holder) in notes.holders where !wanted.contains(id) {
            notes.holders[id] = nil
            if let trail = notes.trails.removeValue(forKey: id) {
                // The dust outlives the card by a beat when it is flying home, and goes at once otherwise.
                if notes.isOut {
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(1200))
                        trail.removeFromParent()
                    }
                } else {
                    trail.removeFromParent()
                }
            }
            if notes.isOut {
                // Removed by a new rev while the fan is out: it flies back into the card and is gone.
                let fromOpacity = holder.components[OpacityComponent.self]?.opacity ?? 1
                holder.components.set(TweenComponent(
                    scale: (from: holder.scale, to: [0.55, 0.55, 0.55]),
                    position: (from: holder.position, to: noteCollapsedTransform.translation),
                    orientation: (from: holder.orientation, to: noteCollapsedTransform.rotation),
                    opacity: (from: fromOpacity, to: 0),
                    duration: HologramController.noteCollapseDuration, easing: .easeInCubic, removeWhenDone: true,
                    opacityWindow: noteFadeWindow(from: fromOpacity, to: 0)))
            } else {
                holder.removeFromParent()
            }
        }
        for id in ids where notes.holders[id] == nil {
            let holder = Entity()
            holder.name = HologramController.noteAttachmentID(id)
            holder.transform = noteCollapsedTransform
            holder.components.set(OpacityComponent(opacity: 0))
            notes.group.addChild(holder)
            notes.holders[id] = holder
            let trail = Entity()
            // V3-6 §2: a family name — see the deck's trail (`trail.deck`).
            trail.name = "trail.note"
            trail.position = holder.position
            trail.components.set(HologramController.noteTrailEmitter(sprite: fx.mote,
                                                                     size: HologramController.trailDustSize))
            trail.components.set(NoteTrailComponent(target: holder, birthRate: HologramController.noteTrailBirthRate))
            trail.isEnabled = notes.isOut
            notes.group.addChild(trail)
            notes.trails[id] = trail
        }
        notes.order = ids
    }

    // MARK: - Idle life

    /// Give a holder its slow life around `transform`: the bob's period and phase come from the card's index,
    /// so ten cards never breathe in step. `SwayComponent` sits dormant while a `TweenComponent` is on the
    /// entity and picks up from this base the frame the flight ends — which is why every path that retargets a
    /// card (fan-out, re-layout, step-back, end-of-preview) has to call this with its new resting pose.
    func installNoteSway(_ holder: Entity, index: Int, transform: Transform) {
        let spread = Float(index % max(1, notes.order.count)) / Float(max(1, notes.order.count))
        let bob = HologramController.noteBobPeriod
        let tilt = HologramController.noteTiltPeriod
        holder.components.set(SwayComponent(
            basePosition: transform.translation,
            baseOrientation: transform.rotation,
            bobAmplitude: HologramController.noteBobAmplitude,
            bobPeriod: bob.lowerBound + (bob.upperBound - bob.lowerBound) * spread,
            tiltAmplitude: HologramController.noteSwayDegrees * .pi / 180,
            tiltPeriod: tilt.lowerBound + (tilt.upperBound - tilt.lowerBound) * spread,
            // The golden angle: ten phases that never bunch up.
            phase: Float(index) * 2.399963))
    }

    /// **v4 B4 §3.4 — the gallery's ten trails rest when their cards do.** B3 run 2's desk at rest had all ten
    /// `trail.note` emitters alive (`emitters: … trail.note×10`) though a card on its slot emits nothing
    /// (`NoteTrailSystem` only gives a trail a birth rate while its card's position tween runs). The hand's deck has
    /// parked its trails since B2; this is the desk's half: 0.9 s after a card lands (every spark in the air has
    /// finished) its trail leaves the tree, and the poll brings it back the moment the card has a flight again — a
    /// fan-out, the put-down bloom, a preview, the ring's lift (`NoteTrailSystem` emits from the flight's first frame
    /// past its delay). Not while the deck is out: the hand has its own rule (`parkIdleDeckTrails`).
    func stepDeskNoteTrails(dt: Float) {
        guard !notes.deckOut, notes.isOut else { return }
        notes.deskTrailPoll += dt
        guard notes.deskTrailPoll >= 0.1 else { return }
        notes.deskTrailPoll = 0
        let now = CACurrentMediaTime()
        var parked = 0
        for (id, trail) in notes.trails {
            guard let holder = notes.holders[id] else { continue }
            if holder.components[TweenComponent.self]?.position != nil {
                notes.trailLastFlight[id] = now
                if !trail.isEnabled, holder.isEnabled {
                    trail.isEnabled = true
                    notes.deskTrailsParkedLogged = false
                }
                continue
            }
            guard trail.isEnabled, now - (notes.trailLastFlight[id] ?? 0) > 0.9,
                  trail.components[NoteTrailComponent.self]?.isOn != true else { continue }
            trail.isEnabled = false
            parked += 1
        }
        // v4 B5 §2: …and the deck's two world-card trails (`trail.deck`), which the put-down left on: their cards fold back
        // into the name card and go out of the tree, so on the desk they never fly — yet round 3's every desk scene line
        // (and the nebula's, inside the world) still listed `trail.deck×2` among the emitters alive.
        for (id, trail) in notes.worldTrails where trail.isEnabled {
            guard let holder = notes.worldHolders[id] else { continue }
            if holder.isEnabled, holder.components[TweenComponent.self]?.position != nil {
                notes.trailLastFlight[id] = now
                continue
            }
            guard now - (notes.trailLastFlight[id] ?? 0) > 0.9,
                  trail.components[NoteTrailComponent.self]?.isOn != true else { continue }
            trail.isEnabled = false
            print("\(PerfLog.prefix) deck world-card trail parked on the desk (\(id))")
        }
        guard parked > 0, !notes.deskTrailsParkedLogged else { return }
        let resting = notes.trails.values.filter { !$0.isEnabled }.count
        guard resting == notes.trails.count else { return }
        notes.deskTrailsParkedLogged = true
        print("\(PerfLog.prefix) gallery trails parked at rest (\(resting)); a card's flight brings its own back")
    }

    /// Turn the pixie dust on (the gallery is out, or on its way home) or off. The per-card trails are driven
    /// by `NoteTrailSystem` — this only gates them.
    func setNoteTrails(_ on: Bool) {
        // v4 B5 §2: off takes the deck's two world-card trails with it (the gallery is going away, and with it any deck it
        // could become); on leaves them to the deck, which switches its own trails on when it flies.
        for trail in on ? Array(notes.trails.values) : Array(notes.trails.values) + Array(notes.worldTrails.values) {
            trail.isEnabled = on
            guard !on, var state = trail.components[NoteTrailComponent.self], state.isOn else { continue }
            state.isOn = false
            trail.components.set(state)
            guard var emitter = trail.components[ParticleEmitterComponent.self] else { continue }
            emitter.mainEmitter.birthRate = 0
            trail.components.set(emitter)
        }
    }

    /// The ~40 motes that drift around a gallery that is standing still. Built on first use — a session that
    /// never throws the fan never pays for it.
    func setNoteTwinkle(_ on: Bool) {
        if on, notes.twinkle.parent == nil {
            notes.twinkle.position = HologramController.noteTwinkleCenter
            notes.twinkle.name = "notes.twinkle"
            notes.twinkle.components.set(HologramController.noteTwinkleEmitter(sprite: fx.sparkle))
            notes.group.addChild(notes.twinkle)
        }
        guard var emitter = notes.twinkle.components[ParticleEmitterComponent.self] else { return }
        emitter.isEmitting = on
        // v4 B5 §3: the resident motes' rate (`motes`).
        emitter.mainEmitter.birthRate = HologramController.noteTwinkleBirthRate * residentMotesScale
        notes.twinkle.components.set(emitter)
        notes.twinkle.isEnabled = on
    }

    private func setNoteDust(_ on: Bool) {
        setNoteTrails(on)
        setNoteTwinkle(on)
    }

    // MARK: - Geometry

    /// Where a card waits while the fan is folded: inside the card's own outline, 2 cm behind its face.
    var noteCollapsedTransform: Transform {
        Transform(scale: [0.55, 0.55, 0.55],
                  rotation: simd_quatf(angle: HologramLayout.cardTiltDegrees * .pi / 180, axis: [1, 0, 0]),
                  translation: [0, HologramLayout.cardCenterHeight, -0.02])
    }

    func noteSlotTransform(index: Int, count: Int, radiusOffset: Float = 0, scale: Float = 1) -> Transform {
        let slot = NoteFanLayout.slot(index: index, count: count, cardCenterHeight: HologramLayout.cardCenterHeight)
        return Transform(scale: [scale, scale, scale],
                         rotation: simd_quatf(angle: noteYaw(for: slot), axis: [0, 1, 0]) * simd_quatf(angle: slot.pitch, axis: [1, 0, 0]),
                         translation: slot.position + slot.outward * radiusOffset)
    }

    /// The yaw that turns a card toward the wearer. `NoteFanLayout` already aims the gallery at its own
    /// `wearerEstimate` (a pure value type cannot see a head), so a run with no head pose still gets a sane
    /// angle; when there **is** one — the headset, or `--preview`'s synthetic head — the real head wins. It is
    /// read once per placement, not every frame: this is a yaw, not a `BillboardComponent`.
    private func noteYaw(for slot: NoteFanLayout.Slot) -> Float {
        guard let head = headPoseProvider?() else { return slot.yaw }
        let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
        let local = notes.group.convert(position: eye, from: nil)
        let dx = local.x - slot.position.x, dz = local.z - slot.position.z
        guard simd_length(SIMD2<Float>(dx, dz)) > 0.05 else { return slot.yaw }
        // The card's face is its local +Z, and a yaw of φ about +Y sends +Z to (sin φ, 0, cos φ).
        return atan2(dx, dz)
    }

    /// Cards leave in the order the eye reads them: the middle of the arc first, then outward on both sides.
    func noteLaunchOrder(count: Int) -> [Int] {
        (0..<count).sorted {
            let a = abs(NoteFanLayout.angle(index: $0, count: count)), b = abs(NoteFanLayout.angle(index: $1, count: count))
            return a == b ? $0 < $1 : a < b
        }
    }

    /// The preview's pose, in the fan group's space: 0.55 m along the wearer's gaze, 5 cm below it, turned to
    /// face them. `--preview` in the simulator has a synthetic head; a run with no head pose at all falls back
    /// to a fixed spot in front of the wearer.
    private func notePreviewTransform(in space: Entity? = nil) -> Transform {
        if let head = headPoseProvider?() {
            let eye = SIMD3<Float>(head.columns.3.x, head.columns.3.y, head.columns.3.z)
            var forward = -SIMD3<Float>(head.columns.2.x, head.columns.2.y, head.columns.2.z)
            forward = simd_length(forward) < 0.001 ? [0, 0, -1] : simd_normalize(forward)
            let position = eye + forward * HologramController.notePreviewDistance - SIMD3<Float>(0, HologramController.notePreviewDrop, 0)
            return noteWorldTransform(at: position, facing: eye, in: space)
        }
        let position = HologramController.notePreviewFallback
        return noteWorldTransform(at: position, facing: position + [0, HologramController.notePreviewDrop, HologramController.notePreviewDistance], in: space)
    }

    /// A world-space "stand here, look at that" turned into the fan group's space.
    private func noteWorldTransform(at position: SIMD3<Float>, facing eye: SIMD3<Float>, in space: Entity? = nil) -> Transform {
        var toEye = eye - position
        toEye = simd_length(toEye) < 0.001 ? [0, 0, 1] : simd_normalize(toEye)
        // The card's face is its +Z (the SwiftUI attachment sits in front), so the shortest arc from +Z to the
        // wearer is the whole rotation — no roll, and no gimbal case to guard.
        let world = Transform(scale: [1, 1, 1], rotation: simd_quatf(from: [0, 0, 1], to: toEye), translation: position)
        return (space ?? notes.group).convert(transform: world, from: nil)
    }

    // MARK: - Fan out / collapse

    /// The ten covers leave the card and take their places on the arc (t = 0 at the call):
    ///
    /// 0.00 the middle pair leaves, then outward 60 ms apart; each card 0.55 s, spring 0.45 / 0.75, scale
    ///      0.55 → 1, bowed 6 cm upward, opacity 0 → 1
    /// 0.00 / 0.18 / 0.36 `chip0` / `chip1` / `chip2` + 12 particles, as the 1st, 4th and 7th card leave
    /// 0.60 the rim breathes, the bloom peaks, a ripple crosses the desk and the `settle` chord lands
    ///
    /// The guard is `showsHologram && !carriedVisual` on purpose and **not** `presence == .expanded`: a long OK
    /// arrives as a button press, which the gate answers with `held(.button)` before anything else happens.
    func fanOutNotes(ids: [String]) {
        guard hologram.isEnabled, currentPresence.showsHologram, !carriedVisual, !isMiniCard, !ids.isEmpty else {
            print("[notes] fan out skipped (\(currentPresence.label)\(carriedVisual ? ", carried" : "")\(isMiniCard ? ", in a world" : ""))")
            return
        }
        updateNoteHolders(ids: ids)
        clearDeckAnchors()
        forgetNoteHighlight()
        notes.task?.cancel()
        if notes.deckOut { tuckDeck(duration: 0.25) }
        resetDeckState()
        // Safety net for the root-space preview (v3 OPTIONAL D): a card the hand form borrowed must be back
        // under the fan's group before the arc places it, whatever happened to the cleanup task.
        for holder in notes.holders.values where holder.parent !== notes.group {
            holder.setParent(notes.group, preservingWorldTransform: false)
            holder.transform = noteCollapsedTransform
        }
        if notes.previewHolder.parent !== notes.group {
            notes.previewHolder.setParent(notes.group, preservingWorldTransform: false)
            notes.previewHolder.transform = .identity
        }
        notes.isOut = true
        notes.group.isEnabled = true
        notes.group.components.set(OpacityComponent(opacity: 1))
        notes.onActivity?()
        if !notes.driftInstalled {
            // Replaces the 2 mm / 7 s hover `HologramController` gives the group at build time: the gallery is
            // wider and farther away, so it wants a slower, bigger breath with a little sideways in it.
            notes.group.components.set(FloatComponent(basePosition: .zero, axis: HologramController.noteGroupDriftAxis,
                                                      amplitude: HologramController.noteGroupDrift,
                                                      period: HologramController.noteGroupDriftPeriod))
            notes.driftInstalled = true
        }
        setNoteDust(true)
        let launch = noteLaunchOrder(count: ids.count)
        for (rank, index) in launch.enumerated() {
            guard let holder = notes.holders[ids[index]] else { continue }
            let target = noteSlotTransform(index: index, count: ids.count)
            holder.isEnabled = true
            installNoteSway(holder, index: index, transform: target)
            let fromOpacity = holder.components[OpacityComponent.self]?.opacity ?? 0
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                opacity: (from: fromOpacity, to: 1),
                arcOffset: [0, 0.06, 0],
                delay: Float(Double(rank) * HologramController.noteFanStagger),
                duration: HologramController.noteFanDuration, easing: .spring(response: 0.45, damping: 0.75),
                opacityWindow: noteFadeWindow(from: fromOpacity, to: 1)))
        }
        print("[notes] fan out \(ids.count) cards")
        // **V3-4 §10.** The desk's own fan-out probe: ten attachment opacity tweens, no deck following the
        // hand and no hand trail. If this reads 45 fps too, the cost is the attachments; if it reads 90, the
        // pick-up morph's 45 fps is the deck's alone.
        // v4 B5 §1: a `cmd perf rehearse=fanout` names its own window (and prints the scene when it reports).
        let rehearsal = perf.fanOutProbeLabel
        perf.fanOutProbeLabel = nil
        startPerfProbe(rehearsal ?? "desk fan out", duration: 1.2, reportsScene: rehearsal != nil, carrier: "desk fan out")
        notes.task = Task { @MainActor [weak self] in
            for cue in 0..<3 {
                guard let self, !Task.isCancelled, self.notes.isOut else { return }
                // v4 B5 §2 `flourish=off`: the chimes play, the sparks, the pulse, the bloom peak and the ripple do not.
                if self.playsGalleryFlourish { self.burst(count: 12) }
                self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][cue], on: self.anchorRoot)
                try? await Task.sleep(for: .milliseconds(180))
            }
            guard let self, !Task.isCancelled, self.notes.isOut else { return }
            try? await Task.sleep(for: .milliseconds(60))
            if self.playsGalleryFlourish {
                self.pulseRim(scale: 1.03)
                self.setBloom(strength: self.look.bloomStrength, peak: 0.7, decay: 0.6)
                self.spawnRipple(at: [0, 0.0025, 0], tint: self.look.secondaryTint, startScale: 0.12, endScale: 1.1, duration: 0.8, peak: 0.55)
            }
            self.audio.play(.settle, on: self.anchorRoot)
            try? await Task.sleep(for: .milliseconds(Int(HologramController.fanSettleSeconds * 1000) - 600))
            guard !Task.isCancelled else { return }
            self.notes.onActivity?()
        }
    }

    /// **V3-2a H5.** Fan out *only* these ids, onto their slots in a gallery of `allIDs`.
    ///
    /// The public `fanOutNotes` re-flies all ten, which is exactly wrong during the put-down bloom: five of
    /// them have just landed on the front row and would take off again. Everything else — the stagger, the
    /// sway, the dust, the three chips and the settling ripple — is the same beat.
    func fanOut(ids: [String], allIDs: [String], cues: Bool) {
        guard !ids.isEmpty else { return }
        clearDeckAnchors()
        notes.isOut = true
        notes.group.isEnabled = true
        setNoteTrails(true)
        setNoteTwinkle(true)
        let launch = ids.compactMap { id -> (Int, Entity)? in
            guard let index = allIDs.firstIndex(of: id), let holder = notes.holders[id] else { return nil }
            return (index, holder)
        }.sorted { abs(NoteFanLayout.angle(index: $0.0, count: allIDs.count)) < abs(NoteFanLayout.angle(index: $1.0, count: allIDs.count)) }
        for (rank, entry) in launch.enumerated() {
            let (index, holder) = entry
            let target = noteSlotTransform(index: index, count: allIDs.count)
            holder.isEnabled = true
            installNoteSway(holder, index: index, transform: target)
            let fromOpacity = holder.components[OpacityComponent.self]?.opacity ?? 0
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                opacity: (from: fromOpacity, to: 1),
                arcOffset: [0, 0.06, 0],
                delay: Float(Double(rank) * HologramController.noteFanStagger),
                duration: HologramController.noteFanDuration, easing: .spring(response: 0.45, damping: 0.75),
                opacityWindow: noteFadeWindow(from: fromOpacity, to: 1)))
        }
        print("[notes] fan out \(launch.count) cards (back row)")
        guard cues else { return }
        notes.task = Task { @MainActor [weak self] in
            for cue in 0..<3 {
                guard let self, !Task.isCancelled, self.notes.isOut else { return }
                if self.playsGalleryFlourish { self.burst(count: 12) }
                self.audio.play([FXAudio.Cue.chip0, .chip1, .chip2][cue], on: self.anchorRoot)
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
    }

    /// The gallery's slow drift is a desk effect; on the hinge it swings the whole hand of cards a
    /// centimetre against a device the wearer is holding still.
    func freezeNotesDrift(_ frozen: Bool) {
        if frozen {
            guard let drift = notes.group.components[FloatComponent.self] else { return }
            notes.parkedDrift = drift
            notes.group.components.remove(FloatComponent.self)
            notes.group.position = drift.basePosition
        } else if let drift = notes.parkedDrift {
            notes.parkedDrift = nil
            notes.group.components.set(drift)
        }
    }

    /// The twinkle field belongs to a gallery standing on a desk; the deck has its own dust.
    func setNoteTwinkleForDeck(_ on: Bool) { setNoteTwinkle(on) }

    /// The fan goes back into the card, ends first and outside-in (0.35 s each, 40 ms apart).
    func collapseNotes(animated: Bool = true) {
        guard notes.isOut || notes.previewID != nil || notes.deckOut else { return }
        forgetNoteHighlight()
        // V3-2a H3: the two world cards belong to the deck, and a collapse is one of the ways it ends.
        // V3-2b B3: entering a world is *the* collapse the deck has an opinion about — the raised world card
        // is the door, so it goes 0.4 s after the rest (plan §4 E11).
        if notes.deckOut { tuckDeck(duration: animated ? 0.25 : 0, raisedDelay: animated ? 0.4 : 0) }
        resetDeckState()
        // **V3-4 §2(c).** A preview that is open when the card leaves flies home over a quarter of a second
        // instead of being cut in one frame (the deck's own tuck already skips the cards the preview borrowed
        // — `tween(_:toHinge:)` will not aim a hinge-space pose at a holder that is not in the fan's space).
        endPreviewNote(animated: animated, duration: 0.25)
        notes.task?.cancel()
        notes.isOut = false
        guard animated else { return resetNotesIntoCard() }
        // The twinkle field belongs to a gallery that is standing there; the trails stay on so the dust runs
        // back into the card with the covers, and are silenced once the last one is home.
        setNoteTwinkle(false)
        let inward = Array(noteLaunchOrder(count: notes.order.count).reversed())
        let collapsed = noteCollapsedTransform
        for (rank, index) in inward.enumerated() where notes.order.indices.contains(index) {
            guard let holder = notes.holders[notes.order[index]] else { continue }
            holder.components.remove(SwayComponent.self)
            let fromOpacity = holder.components[OpacityComponent.self]?.opacity ?? 1
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: collapsed.scale),
                position: (from: holder.position, to: collapsed.translation),
                orientation: (from: holder.orientation, to: collapsed.rotation),
                opacity: (from: fromOpacity, to: 0),
                delay: Float(Double(rank) * HologramController.noteCollapseStagger),
                duration: HologramController.noteCollapseDuration, easing: .easeInCubic, disableWhenDone: true,
                opacityWindow: noteFadeWindow(from: fromOpacity, to: 0)))
        }
        print("[notes] fan collapsed")
        audio.play(.tick, on: anchorRoot)
        // Ends first, 40 ms apart, 0.35 s each: the last card is home at 0.35 + 9 × 0.04 ≈ 0.71 s.
        let tail = Int((Double(HologramController.noteCollapseDuration)
                        + HologramController.noteCollapseStagger * Double(max(0, notes.order.count - 1))) * 1000) + 120
        notes.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(tail))
            guard let self, !Task.isCancelled, !self.notes.isOut else { return }
            self.setNoteTrails(false)
        }
    }

    /// Every card back inside the card, in one frame: the end of a sink, and the instant collapse.
    private func resetNotesIntoCard() {
        let collapsed = noteCollapsedTransform
        for holder in notes.worldHolders.values {
            holder.components.remove(TweenComponent.self)
            holder.transform = collapsed
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
        }
        for holder in notes.holders.values {
            holder.components.remove(TweenComponent.self)
            holder.components.remove(SwayComponent.self)
            holder.transform = collapsed
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
        }
        setNoteDust(false)
    }

    /// The card itself is leaving (a fold, a dismiss, a teardown): the fan has no choreography of its own here,
    /// it simply goes down with the light.
    func sinkNotes() {
        forgetNoteHighlight()
        resetDeckState()
        // V3-4 §2(c): the same 0.25 s flight home the collapse gets (see `collapseNotes`).
        endPreviewNote(animated: true, duration: 0.25)
        notes.task?.cancel()
        notes.isOut = false
        // The light is going, so the dust goes with it — no sparks left hanging where the gallery used to be.
        setNoteDust(false)
        notes.group.components.set(TweenComponent(
            opacity: (from: notes.group.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
            duration: 0.35, easing: .easeInCubic))
        notes.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(360))
            guard let self, !Task.isCancelled, !self.notes.isOut else { return }
            // Straight to `resetNotesIntoCard`: `collapseNotes` would refuse (the fan is already "not out"),
            // and cards left standing at their slots would make the next fan-out appear instead of fly out.
            self.resetNotesIntoCard()
            self.notes.group.components.remove(TweenComponent.self)
            self.notes.group.components.set(OpacityComponent(opacity: 1))
        }
    }

    /// A new rev while the fan is out: the ids that stayed glide to their new slots (0.4 s), the new ones fan
    /// out of the card, and the ones that left have already been sent home by `updateNoteHolders`.
    func relayoutNotes(ids: [String]) {
        guard notes.isOut else { return }
        forgetNoteHighlight()
        clearDeckAnchors()
        let known = Set(notes.order)
        updateNoteHolders(ids: ids)
        var newcomers: [Int] = []
        for (index, id) in ids.enumerated() {
            guard let holder = notes.holders[id] else { continue }
            let target = noteSlotTransform(index: index, count: ids.count)
            guard known.contains(id) else {
                newcomers.append(index)
                continue
            }
            guard id != notes.previewID else { continue }      // the card being read stays where it is
            installNoteSway(holder, index: index, transform: target)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                duration: 0.4, easing: .easeInOutCubic))
        }
        for (rank, index) in newcomers.enumerated() {
            guard let holder = notes.holders[ids[index]] else { continue }
            let target = noteSlotTransform(index: index, count: ids.count)
            holder.isEnabled = true
            installNoteSway(holder, index: index, transform: target)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                opacity: (from: 0, to: 1), arcOffset: [0, 0.06, 0],
                delay: Float(Double(rank) * HologramController.noteFanStagger),
                duration: HologramController.noteFanDuration, easing: .spring(response: 0.45, damping: 0.75),
                opacityWindow: noteFadeWindow(from: 0, to: 1)))
        }
        print("[notes] re-laid out \(ids.count) cards (\(newcomers.count) new)")
    }

    // MARK: - The desk ring (v4 B2 §2)

    static let ringHintAttachmentID = "desk-ring-hint"
    /// Art bible §2 / §3: the highlighted card stands 10 mm up (the brief's 8–12) and 6 % larger, on a 0.3 s spring
    /// inside the bible's response / damping band. Its rim turning gold is the SwiftUI card's own
    /// (`NoteCardView.highlighted`), so the light and the lift land in the same frame.
    static let ringLift: Float = 0.010
    static let ringScale: Float = 1.06
    static let ringDuration: Float = 0.3

    /// The desk ring rests on `id` (nil = on nothing, or on a world coin): that card lifts, the previous one settles.
    /// `after` delays the lift — a preview that has just closed has to land its card back in its slot first.
    func setNoteHighlight(_ id: String?, after delay: Double = 0) {
        notes.highlightTask?.cancel()
        notes.highlightTask = nil
        guard delay <= 0 else {
            notes.highlightTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
                guard let self, !Task.isCancelled else { return }
                self.setNoteHighlight(id)
            }
            return
        }
        let old = notes.highlightedID
        guard old != id else { return }
        notes.highlightedID = id
        if let old { placeGalleryCard(old, lifted: false) }
        if let id { placeGalleryCard(id, lifted: true) }
    }

    /// One gallery card to its slot, lifted or not — only while the gallery stands on the desk with nothing open (a
    /// preview, the deck and a collapse all own the cards' poses themselves).
    private func placeGalleryCard(_ id: String, lifted: Bool) {
        guard notes.isOut, !notes.deckOut, notes.previewID == nil,
              let index = notes.order.firstIndex(of: id), let holder = notes.holders[id],
              holder.parent === notes.group, holder.isEnabled else { return }
        let slot = noteSlotTransform(index: index, count: notes.order.count)
        let k: Float = lifted ? HologramController.ringScale : 1
        let target = Transform(scale: slot.scale * k, rotation: slot.rotation,
                               translation: slot.translation + [0, lifted ? HologramController.ringLift : 0, 0])
        installNoteSway(holder, index: index, transform: target)
        holder.components.set(TweenComponent(
            scale: (from: holder.scale, to: target.scale),
            position: (from: holder.position, to: target.translation),
            orientation: (from: holder.orientation, to: target.rotation),
            opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
            duration: HologramController.ringDuration, easing: .spring(response: 0.4, damping: 0.72)))
        if lifted {
            sweepNoteGlint(on: holder)
            audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index % 3], on: anchorRoot)
        }
    }

    /// Something else is placing the gallery's cards (a fan-out, a collapse, a sink, a re-layout, a preview, the
    /// morph into the hand): the lifted card goes with the rest, and the ring's next move lifts afresh.
    func forgetNoteHighlight() {
        notes.highlightTask?.cancel()
        notes.highlightTask = nil
        notes.highlightedID = nil
    }

    /// Where the hint stands: beside the device on the side its keys are on (`buttonEdge`), 13 cm out and 3 cm up — the
    /// words next to the buttons they are about, clear of the footprint prism (a 14 cm capsule spans 6–20 cm out).
    var ringHintPosition: SIMD3<Float> { [buttonEdge.sign * 0.13, 0.03, 0] }

    func attachDeskRingHint(_ entity: Entity) {
        let holder = notes.ringHintHolder
        holder.name = "desk.ringHint"
        if holder.parent == nil {
            holder.position = ringHintPosition
            holder.components.set(BillboardComponent())
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
            surface.addChild(holder)
        }
        holder.children.forEach { $0.removeFromParent() }
        entity.transform = .identity
        holder.addChild(entity)
    }

    /// Fade the hint in (0.35 s, after the gallery has landed) or out (0.25 s, then out of the tree).
    func setDeskRingHint(visible: Bool) {
        let holder = notes.ringHintHolder
        guard holder.parent != nil else { return }
        let from = holder.isEnabled ? (holder.components[OpacityComponent.self]?.opacity ?? 0) : 0
        if visible {
            holder.position = ringHintPosition
            holder.isEnabled = true
            holder.components.set(TweenComponent(scale: (from: [0.9, 0.9, 0.9], to: [1, 1, 1]), opacity: (from: from, to: 1),
                                                 duration: 0.35, easing: .easeOutCubic))
        } else if holder.isEnabled {
            holder.components.set(TweenComponent(opacity: (from: from, to: 0), duration: 0.25, easing: .easeInCubic,
                                                 disableWhenDone: true))
        }
    }

    // MARK: - Preview

    /// One card is enlarged where the wearer is looking (t = 0 at the pinch):
    ///
    /// 0.00 it leaves the arc for eye + gaze · 0.55 − 0.05 m, scale 1 → 2.6, bowed, 0.55 s spring 0.5 / 0.78;
    ///      the others step 3 cm further out and shrink to 0.92; the card and its landing pool dim; the beam
    ///      flares, a ripple crosses the desk, `liftOff`
    /// 0.55 the preview panel (pre-placed, transparent, the same physical size) fades in over 0.18 s while it
    ///      grows 0.97 → 1, and the flown card grows 2.6 → 2.68 and fades out under it
    func previewNote(id: String) {
        previewNote(id: id, steppingBackOthers: true)
    }

    /// v3 H2 §8: OK on a note page of the hand card. The fan is **not** thrown — the holder flies straight out
    /// of the card it is folded inside, and `endPreviewNote` flies it back in there rather than to an arc slot
    /// that does not exist. Everything else (the panel crossfade, the strip on the device) is the same path.
    func previewNoteFromCard(id: String) {
        guard let holder = notes.holders[id] else {
            print("[notes] no card for \(id.prefix(6)) yet")
            return
        }
        // A preview is already open (the wearer pressed OK on a second note page): close it *synchronously*
        // first. The two live in different spaces, and overlapping them is how a card gets stranded in one.
        if notes.previewID != nil { endPreviewNote(animated: false, restoreOthers: false) }
        notes.directPreview = true
        notes.fromDeck = notes.deckOut && notes.deckRaised == id
        if notes.fromDeck {
            // **V3-4 §2(b).** The other four notes do not stay in the hand a little dimmer any more: they come
            // out of it and line up on a thumbnail strip under the big card, so the wearer can see what the
            // next UP / DOWN will open. The two world cards do stay — a world is not something a preview can
            // show, so they keep their slots at 0.6.
            let strip = deckItems().filter { !$0.isWorld && $0.id != id }.map(\.id)
            print("[notes] preview \(id.prefix(6)) (from deck, strip \(strip.count))")
            stepBackDeck(except: id, ignoring: Set(strip), back: true)
            raiseNoteStrip(ids: strip)
        }
        // v3 OPTIONAL D: park the card and the panel in **root** space before they fly, so the preview is
        // world-locked at the pose it opens at instead of riding the hand that is holding the passport.
        // `preservingWorldTransform` means the reparent itself moves nothing.
        holder.components.remove(DeckAnchorComponent.self)
        holder.setParent(notePreviewSpace, preservingWorldTransform: true)
        notes.previewHolder.setParent(notePreviewSpace, preservingWorldTransform: true)
        previewNote(id: id, steppingBackOthers: false)
    }

    private func previewNote(id: String, steppingBackOthers: Bool) {
        guard let holder = notes.holders[id], notes.isOut || notes.directPreview else { return }
        notes.task?.cancel()
        // v4 B2 §2: the card leaves its (lifted) slot for the preview; closing puts the highlight back afresh.
        forgetNoteHighlight()
        notes.previewID = id
        let target = notePreviewTransform(in: notes.directPreview ? notePreviewSpace : nil)
        let scale = HologramController.notePreviewScale
        holder.isEnabled = true
        // The card leaves its slot: no sway to drag it back while it is being read, and a burst of dust plus
        // one highlight crossing the cover as it goes.
        holder.components.remove(SwayComponent.self)
        burstNoteDust(at: holder.position)
        sweepNoteGlint(on: holder)
        holder.components.set(TweenComponent(
            scale: (from: holder.scale, to: [scale, scale, scale]),
            position: (from: holder.position, to: target.translation),
            orientation: (from: holder.orientation, to: target.rotation),
            opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
            arcOffset: [0, 0.05, 0],
            duration: HologramController.noteFanDuration, easing: .spring(response: 0.5, damping: 0.78)))
        // The panel waits at the same pose, transparent, so the crossfade has nothing to move.
        notes.previewHolder.components.remove(TweenComponent.self)
        notes.previewHolder.isEnabled = true
        notes.previewHolder.transform = Transform(scale: [0.97, 0.97, 0.97], rotation: target.rotation, translation: target.translation)
        notes.previewHolder.components.set(OpacityComponent(opacity: 0))
        if steppingBackOthers { stepBackNotes(except: id, back: true) }
        dimCardForNote(preview: true)
        flareBeam()
        spawnRipple(at: [0, 0.0025, 0], tint: look.secondaryTint, startScale: 0.15, endScale: 1.2, duration: 0.85, peak: 0.6)
        audio.play(.liftOff, on: anchorRoot)
        print("[notes] preview \(id.prefix(6))")
        notes.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(HologramController.noteFanDuration * 1000)))
            guard let self, !Task.isCancelled, self.notes.previewID == id else { return }
            self.notes.previewHolder.components.set(TweenComponent(
                scale: (from: [0.97, 0.97, 0.97], to: [1, 1, 1]),
                opacity: (from: 0, to: 1), duration: 0.18, easing: .easeOutCubic))
            let grown = scale * 1.03
            holder.components.set(TweenComponent(
                scale: (from: [scale, scale, scale], to: [grown, grown, grown]),
                opacity: (from: 1, to: 0), duration: 0.18, easing: .easeOutCubic, disableWhenDone: true))
        }
    }

    /// Back to the arc (0.45 s), the panel dissolving over it. `restoreOthers: false` is the card-switch path:
    /// the rest of the fan stays stepped back and the card behind stays dim, because another preview is 0.1 s
    /// behind this one.
    func endPreviewNote(animated: Bool = true, restoreOthers: Bool = true, duration override: Float? = nil) {
        guard let id = notes.previewID else { return }
        notes.previewID = nil
        notes.task?.cancel()
        if notes.directPreview, let holder = notes.holders[id] {
            // Straight back inside the card it came out of: there is no arc to return to. The card is in
            // root space (see `previewNoteFromCard`), so the card's own collapsed pose is converted into it
            // for the flight and both entities are handed back to the fan once they land.
            //
            // **V3-2a H6**: out of the *deck* it goes back to its **raised** slot instead — the wearer is
            // still on that card and the next OK has to open it again, not the one after it.
            notes.directPreview = false
            let toDeck = notes.fromDeck && notes.deckOut
            let deckHome = toDeck ? deckRaisedTransform() : noteCollapsedTransform
            let home = notePreviewSpace.convert(transform: deckHome, from: notes.group)
            let duration: Float = override ?? (toDeck ? 0.45 : HologramController.noteCollapseDuration)
            holder.components.remove(SwayComponent.self)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: toDeck ? home.scale : home.scale * 0.55),
                position: (from: holder.position, to: home.translation),
                orientation: (from: holder.orientation, to: home.rotation),
                opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: toDeck ? 1 : 0),
                duration: animated ? duration : 0,
                easing: toDeck ? .spring(response: 0.45, damping: 0.78) : .easeInCubic,
                disableWhenDone: !toDeck))
            // **V3-4 §2(b).** The four thumbnails fly home with it — to their own deck slots when the hand
            // is still there, into the card when it is not (a fold, a world, a put-down).
            sendNoteStripHome(duration: animated ? duration : 0, toDeck: toDeck)
            if toDeck {
                // The hinge anchor is **not** set here: the holder is still in root space and this flight's
                // target is written in it. `rehomeDirectPreview(toDeck:)` sets it once the card is back under
                // `notes.group`, which is the only space the anchor means anything in.
                stepBackDeck(except: id, back: false)
                print("[notes] preview ended → deck slot \(deckSlot(of: id).map(String.init) ?? "-") (strip home)")
            }
            guard animated else {
                notes.previewTask?.cancel()
                rehomePreviewSet(holder: holder, toDeck: toDeck)
                return
            }
            notes.previewTask?.cancel()
            notes.previewTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(duration * 1000) + 60))
                guard let self, !Task.isCancelled, self.notes.previewID == nil else { return }
                self.rehomePreviewSet(holder: holder, toDeck: toDeck)
                guard toDeck else { return }
                // **V3-4 §2(a).** The bug this replaces flew the five notes to the *desk arc* on every close.
                // The log then says where they actually are, so a smoke can assert it instead of a person
                // having to watch for cards vanishing.
                self.armDeckRestoredCheck(start: true)
            }
        } else if let index = notes.order.firstIndex(of: id), let holder = notes.holders[id] {
            let target = noteSlotTransform(index: index, count: notes.order.count)
            holder.isEnabled = true
            holder.components.set(OpacityComponent(opacity: 1))
            installNoteSway(holder, index: index, transform: target)
            if animated {
                holder.components.set(TweenComponent(
                    scale: (from: holder.scale, to: target.scale),
                    position: (from: holder.position, to: target.translation),
                    orientation: (from: holder.orientation, to: target.rotation),
                    opacity: (from: 1, to: 1), arcOffset: [0, 0.05, 0],
                    duration: 0.45, easing: .spring(response: 0.45, damping: 0.78)))
            } else {
                holder.components.remove(TweenComponent.self)
                holder.transform = target
            }
        }
        if animated {
            notes.previewHolder.components.set(TweenComponent(
                scale: (from: notes.previewHolder.scale, to: [0.97, 0.97, 0.97]),
                opacity: (from: notes.previewHolder.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
                duration: restoreOthers ? 0.18 : 0.12, easing: .easeInCubic, disableWhenDone: true))
        } else {
            notes.previewHolder.components.remove(TweenComponent.self)
            notes.previewHolder.components.set(OpacityComponent(opacity: 0))
            notes.previewHolder.isEnabled = false
        }
        guard restoreOthers else { return }
        stepBackNotes(except: nil, back: false)
        dimCardForNote(preview: false, animated: animated)
        print("[notes] preview ended")
    }

    /// Reading another card: the one in front goes home at once and the next one leaves 0.1 s later, so the two
    /// flights overlap instead of queueing.
    func switchPreviewNote(from: String, to: String) {
        endPreviewNote(animated: true, restoreOthers: false)
        notes.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.previewNote(id: to, steppingBackOthers: false)
        }
    }

    /// Both entities out of root space and back under the fan's own group, where every other path expects
    /// to find them (`fanOutNotes` places cards with `notes.group`-space transforms).
    private func rehomeDirectPreview(holder: Entity, toDeck: Bool = false) {
        holder.components.remove(TweenComponent.self)
        holder.setParent(notes.group, preservingWorldTransform: false)
        if toDeck, notes.deckOut {
            holder.components.set(DeckAnchorComponent(local: deckRaisedLocal()))
            holder.transform = deckRaisedTransform()
            holder.components.set(OpacityComponent(opacity: 1))
            holder.isEnabled = true
            notes.fromDeck = false
            rehomePreviewPanel()
            return
        }
        notes.fromDeck = false
        holder.transform = noteCollapsedTransform
        holder.components.set(OpacityComponent(opacity: 0))
        holder.isEnabled = false
        rehomePreviewPanel()
    }

    private func rehomePreviewPanel() {
        notes.previewHolder.components.remove(TweenComponent.self)
        notes.previewHolder.setParent(notes.group, preservingWorldTransform: false)
        notes.previewHolder.transform = .identity
        notes.previewHolder.components.set(OpacityComponent(opacity: 0))
        notes.previewHolder.isEnabled = false
    }

    // MARK: - The thumbnail strip (V3-4 §2b)

    /// Is a deck preview showing its strip right now? `AppModel` asks before routing UP / DOWN: with a strip
    /// on screen the buttons page **inside** the preview, without one they raise a deck card as before.
    var hasNoteStrip: Bool { !notes.stripIDs.isEmpty }

    /// Where the `index`-th thumbnail stands, **in `notePreviewRoot`** — the same world-locked space the big
    /// card is in, so the strip is pinned where it opened instead of riding the hand holding the passport.
    ///
    /// It hangs `noteStripDrop` under the big card along the card's own down axis and spreads along its own
    /// right axis, so the row stays square to the card however the wearer's head was turned when it opened.
    func noteStripTransform(index: Int, count: Int) -> Transform {
        let base = notePreviewTransform(in: notePreviewSpace)
        let right = base.rotation.act(SIMD3<Float>(1, 0, 0))
        let down = base.rotation.act(SIMD3<Float>(0, -1, 0))
        let offset = (Float(index) - Float(max(1, count) - 1) / 2) * HologramController.noteStripSpacing
        let drop = HologramController.notePreviewHalfHeight + HologramController.noteStripDrop
        let position = base.translation + down * drop + right * offset
        // Leaning back 10°: the strip is below the eye, so tipping its face up is what points it at the eye.
        let rotation = base.rotation * simd_quatf(angle: HologramController.noteStripPitch, axis: [1, 0, 0])
        let scale = HologramController.noteStripScale
        return Transform(scale: [scale, scale, scale], rotation: rotation, translation: position)
    }

    /// The four notes that are not being read leave the hand for the strip: 0.45 s spring, 40 ms apart.
    ///
    /// **Space discipline.** Every target below is written in `notePreviewRoot`, so each holder is reparented
    /// into it *first* (`preservingWorldTransform: true`, which moves nothing) and its hinge anchor dropped —
    /// a `DeckAnchorComponent` left on a card in this space is exactly how `followDeckToHinge` strands one.
    private func raiseNoteStrip(ids: [String]) {
        notes.stripIDs = ids
        for (index, id) in ids.enumerated() {
            guard let holder = notes.holders[id] else { continue }
            holder.components.remove(SwayComponent.self)
            holder.components.remove(DeckAnchorComponent.self)
            holder.components.remove(DeckFollowComponent.self)
            holder.setParent(notePreviewSpace, preservingWorldTransform: true)
            holder.isEnabled = true
            let target = noteStripTransform(index: index, count: ids.count)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
                arcOffset: [0, 0.03, 0],
                delay: Float(Double(index) * HologramController.noteStripStagger),
                duration: HologramController.noteStripDuration,
                easing: .spring(response: 0.45, damping: 0.78)))
        }
    }

    /// Re-centre the strip on whatever it holds now (one card has just left it, or joined it).
    private func relayoutNoteStrip(duration: Float, stagger: Double = 0) {
        for (index, id) in notes.stripIDs.enumerated() {
            guard let holder = notes.holders[id], holder.parent === notePreviewSpace else { continue }
            let target = noteStripTransform(index: index, count: notes.stripIDs.count)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
                delay: Float(Double(index) * stagger),
                duration: duration, easing: .easeInOutCubic))
        }
    }

    /// The preview is closing: every thumbnail flies back to the slot it came out of — its own deck slot when
    /// the hand is still holding the deck, the inside of the name card when it is not.
    private func sendNoteStripHome(duration: Float, toDeck: Bool) {
        guard !notes.stripIDs.isEmpty else { return }
        let items = deckItems()
        let count = items.count
        for (rank, id) in notes.stripIDs.enumerated() {
            guard let holder = notes.holders[id], holder.parent === notePreviewSpace else { continue }
            let deckHome = toDeck && items.contains(where: { $0.id == id })
                ? deckSlotTransform(index: items.firstIndex { $0.id == id } ?? 0, count: count)
                : noteCollapsedTransform
            let home = notePreviewSpace.convert(transform: deckHome, from: notes.group)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: toDeck ? home.scale : home.scale * 0.55),
                position: (from: holder.position, to: home.translation),
                orientation: (from: holder.orientation, to: home.rotation),
                opacity: (from: holder.components[OpacityComponent.self]?.opacity ?? 1, to: toDeck ? 1 : 0),
                delay: duration > 0 ? Float(Double(rank) * HologramController.noteStripStagger) : 0,
                duration: duration,
                easing: toDeck ? .spring(response: 0.45, damping: 0.78) : .easeInCubic))
        }
    }

    /// The big card **and** the strip handed back to the fan's own group, where every other path expects to
    /// find them. One entry point, because a rehome that forgot the strip is a stranded card.
    private func rehomePreviewSet(holder: Entity, toDeck: Bool) {
        rehomeDirectPreview(holder: holder, toDeck: toDeck)
        rehomeNoteStrip(toDeck: toDeck)
    }

    /// Every thumbnail out of `notePreviewRoot` and back under `notes.group`, re-anchored to its deck slot
    /// (the hand still has the deck) or folded into the card (it does not).
    private func rehomeNoteStrip(toDeck: Bool) {
        guard !notes.stripIDs.isEmpty else { return }
        let items = deckItems()
        let count = items.count
        for id in notes.stripIDs {
            guard let holder = notes.holders[id] else { continue }
            holder.components.remove(TweenComponent.self)
            holder.setParent(notes.group, preservingWorldTransform: false)
            if toDeck, notes.deckOut, let index = items.firstIndex(where: { $0.id == id }) {
                let local = deckSlotLocal(index: index, count: count)
                holder.components.set(DeckAnchorComponent(local: local))
                holder.transform = inFan(local)
                holder.components.set(OpacityComponent(opacity: 1))
                holder.isEnabled = true
            } else {
                holder.transform = noteCollapsedTransform
                holder.components.set(OpacityComponent(opacity: 0))
                holder.isEnabled = false
            }
        }
        notes.stripIDs = []
    }

    /// **V3-4 §2(a).** Arm — or postpone — the "where did the deck land" check.
    ///
    /// A fixed delay after the close was wrong, and both reviewer gate runs caught it: the deck script closes
    /// the preview on OK at 17 s and raises the next card on UP at 18 s, so a check half a second after the
    /// close landed in the middle of the next card's raise-and-sink and reported
    /// `5 within 3 mm of their slots, worst 75 mm`. On the headset the wearer pages within a second of
    /// closing *every* time, so that would have read as a failure of the thing it exists to prove.
    ///
    /// So it is a debounce instead: only a close arms it, and every deck event after that pushes it out
    /// another second. `start: false` therefore does nothing at all unless a close is already waiting —
    /// a raise on its own is not something this line has an opinion about.
    func armDeckRestoredCheck(start: Bool = false) {
        guard start || notes.restoredArmed else { return }
        notes.restoredArmed = true
        notes.restoredTask?.cancel()
        notes.restoredTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(1000))
            guard let self, !Task.isCancelled else { return }
            self.notes.restoredArmed = false
            self.reportDeckRestored()
        }
    }

    /// The deck is gone: nothing left to report on.
    func cancelDeckRestoredCheck() {
        notes.restoredTask?.cancel()
        notes.restoredTask = nil
        notes.restoredArmed = false
    }

    /// The deck is *about to* end (a fold, a world, a put-down): if a check was still waiting, report **now**,
    /// while the seven cards are still standing where the last close and raise left them.
    ///
    /// The debounce alone is not enough: `fake-device-v32-hand-deck.json` closes the preview at 17 s, raises
    /// at 18 / 19 / 19.6 s and dismisses at 20 s, so a check pushed out to 20.6 s would be cancelled by the
    /// fold 0.6 s before it fired and the line the smoke asserts would never appear at all. Called from
    /// `tuckDeck` and `resetDeckState`, both of which run *before* `deckOut` goes false and before the tuck's
    /// own tweens are set — so what it measures is the deck as the wearer last left it.
    func flushDeckRestoredCheck() {
        let armed = notes.restoredArmed
        cancelDeckRestoredCheck()
        guard armed else { return }
        reportDeckRestored()
    }

    /// **V3-4 §2(a)'s assertion.** Where the seven cards actually are once the hand has stopped moving them.
    /// The bug this line exists to catch moved five of them to the desk arc 30 cm away, so a count of how
    /// many are on their own slots is the one thing a smoke can grep for.
    ///
    /// A card a choreography still owns is **not** measured — it is by definition not where it is going yet —
    /// but it is counted and named, so "7 within 3 mm" cannot be reached by quietly skipping six of them.
    private func reportDeckRestored() {
        guard notes.deckOut else { return }
        let items = deckItems()
        let count = items.count
        var within = 0
        var inFlight = 0
        var worst: Float = 0
        for (index, item) in items.enumerated() {
            guard item.holder.parent === notes.group else { continue }
            // A tween that claims **position or orientation** owns where the card is, so it is not where it
            // is going yet and it is not measured. A tween that claims neither is §9's 6 % pop on UP / DOWN —
            // scale only, 0.5 s, staggered 40 ms — and `stepDeckDynamics` goes on driving the card's position
            // underneath it. Counting those as "in flight" is what made this line read
            // `5 within 3 mm, worst 0 mm, 2 in flight` on the deck script: the two stragglers were not moving
            // at all, they were still finishing a pop.
            if let tween = item.holder.components[TweenComponent.self],
               tween.position != nil || tween.orientation != nil {
                inFlight += 1
                continue
            }
            let target = item.id == notes.deckRaised
                ? deckRaisedTransform()
                : deckSlotTransform(index: index, count: count)
            let distance = simd_distance(item.holder.position, target.translation)
            guard distance.isFinite else { continue }
            worst = max(worst, distance)
            if distance <= 0.003 { within += 1 }
        }
        guard within < count || inFlight > 0 else {
            return print("[notes] deck restored (\(within) within 3 mm of their slots)")
        }
        let flight = inFlight > 0 ? String(format: ", %d in flight", inFlight) : ""
        print(String(format: "[notes] deck restored (%d within 3 mm of their slots, worst %.0f mm%@)",
                     within, worst * 1000, flight))
    }

    /// **V3-4 §2(b).** UP / DOWN while a note is open: the big card sinks back into its own place on the
    /// strip and its neighbour comes up out of it, the two flights overlapping by 0.1 s. The strip re-centres
    /// under both of them, so the row never jumps.
    ///
    /// Deliberately **not** `switchPreviewNote`: that one is the gallery's, it ends the preview first, and a
    /// deck preview lives in a different space from an arc one. And deliberately not
    /// `endPreviewNote(animated: false)` either — a cut is exactly what this replaces.
    func pagePreviewNote(from: String, to id: String) {
        guard notes.previewID == from, let leaving = notes.holders[from], notes.holders[id] != nil else {
            return previewNoteFromCard(id: id)
        }
        notes.task?.cancel()
        // **The two have to stay in step.** The machine is already on `to`; leaving `notes.previewID` nil for
        // the 0.1 s the two flights overlap is a real desync, and a thumb double-tapping UP / DOWN finds it
        // in one run: an `endPreviewNote` arriving inside that window returns immediately at its
        // `guard let id = notes.previewID`, the machine goes to `.deck(raised:)` — and then this task fires
        // and opens a preview the machine no longer believes in, with no OK that can close it again.
        notes.previewID = id
        // The panel goes out over the card that is leaving and comes back under the one arriving.
        notes.previewHolder.components.set(TweenComponent(
            scale: (from: notes.previewHolder.scale, to: [0.97, 0.97, 0.97]),
            opacity: (from: notes.previewHolder.components[OpacityComponent.self]?.opacity ?? 1, to: 0),
            duration: 0.12, easing: .easeInCubic))
        // The new strip is the deck's notes minus the one about to be read, in deck order; the card that is
        // leaving takes the place the arriving one is vacating.
        var strip = deckItems().filter { !$0.isWorld && $0.id != id }.map(\.id)
        if !strip.contains(from) { strip.append(from) }
        notes.stripIDs = strip
        guard let slot = strip.firstIndex(of: from) else { return }
        leaving.components.remove(SwayComponent.self)
        let sink = noteStripTransform(index: slot, count: strip.count)
        leaving.components.set(TweenComponent(
            scale: (from: leaving.scale, to: sink.scale),
            position: (from: leaving.position, to: sink.translation),
            orientation: (from: leaving.orientation, to: sink.rotation),
            opacity: (from: leaving.components[OpacityComponent.self]?.opacity ?? 1, to: 1),
            duration: HologramController.notePageSink, easing: .easeInOutCubic))
        relayoutNoteStrip(duration: HologramController.notePageSink)
        print("[notes] preview → \(id.prefix(6)) (paged in preview)")
        notes.task = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(HologramController.notePageOverlap * 1000)))
            // …and the arriving flight is skipped outright if the preview ended while it was waiting.
            guard let self, !Task.isCancelled, self.notes.previewID == id else { return }
            // The arriving card is already in `notePreviewRoot` (it was on the strip), so the preview flight
            // below is written in the space it is in — no reparent, nothing to strand.
            self.notes.directPreview = true
            self.notes.fromDeck = true
            self.previewNoteFromStrip(id: id)
        }
    }

    /// The arriving half of a page: the thumbnail lifts out of the strip to the preview pose. It is the same
    /// flight `previewNote` flies, minus the reparent (the card is already in the preview's space) and minus
    /// the dust and the ripple, which would fire four times in a row while the wearer pages.
    private func previewNoteFromStrip(id: String) {
        guard let holder = notes.holders[id] else { return }
        notes.stripIDs.removeAll { $0 == id }
        relayoutNoteStrip(duration: HologramController.notePageSink)
        previewNote(id: id, steppingBackOthers: false)
    }

    /// New followers while the fan is out: the cards answer the celebration in a wave (40 ms apart, 6 % pop).
    /// The card being read is left alone — it is what the wearer is looking at.
    func rippleNoteFan() {
        guard notes.isOut else { return }
        for (rank, id) in notes.order.enumerated() {
            guard id != notes.previewID, let holder = notes.holders[id], holder.isEnabled,
                  holder.components[TweenComponent.self] == nil else { continue }
            holder.components.set(TweenComponent(
                scale: (from: holder.scale * 1.06, to: holder.scale),
                delay: Float(Double(rank) * 0.04), duration: 0.5, easing: .spring(response: 0.35, damping: 0.7)))
        }
    }

    // MARK: - Private

    /// The rest of the fan while one card is read: 3 cm further out, 8 % smaller (and back again).
    private func stepBackNotes(except id: String?, back: Bool) {
        // **V3-4 §2(a), the "the other cards suddenly disappeared" bug.** `noteSlotTransform` is the **desk
        // arc** — radius 0.30 m, 0.36 m above the surface. With the deck in the wearer's hand, sending the
        // five note holders there throws them out of the wearer's view, installs a sway on cards that are
        // supposed to be riding the hinge, and leaves `stepDeckDynamics` fighting a `SwayComponent` for them.
        // `endPreviewNote` called this unconditionally after the `toDeck` branch had already put the deck
        // back; the deck path has `stepBackDeck`, and this one belongs to the gallery alone.
        guard !notes.deckOut else { return }
        let count = notes.order.count
        for (index, other) in notes.order.enumerated() {
            guard other != id, let holder = notes.holders[other], holder.isEnabled else { continue }
            let target = noteSlotTransform(index: index, count: count,
                                           radiusOffset: back ? HologramController.noteStepBackRadius : 0,
                                           scale: back ? HologramController.noteStepBackScale : 1)
            installNoteSway(holder, index: index, transform: target)
            holder.components.set(TweenComponent(
                scale: (from: holder.scale, to: target.scale),
                position: (from: holder.position, to: target.translation),
                orientation: (from: holder.orientation, to: target.rotation),
                duration: 0.35, easing: .easeOutCubic))
        }
    }

    /// A preview opening: 60 sparkles thrown off the card it came from. Its **own** one-shot emitter rather
    /// than the card's trail — `NoteTrailSystem` writes that one the moment the preview flight starts, and a
    /// burst triggered on a component the next frame overwrites is a burst that never happens.
    private func burstNoteDust(at position: SIMD3<Float>) {
        let entity = Entity()
        entity.name = "burst.note"
        entity.position = position
        var emitter = HologramController.noteBurstEmitter(sprite: fx.sparkle)
        emitter.burstCount = HologramController.notePreviewBurst
        emitter.burst()
        PerfCensus.noteBurst(HologramController.notePreviewBurst, life: emitter.mainEmitter.lifeSpan)
        entity.components.set(emitter)
        notes.group.addChild(entity)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            entity.removeFromParent()
        }
    }

    /// One highlight crossing the cover, left to right, in 0.45 s. The quad is a child of the holder, so it
    /// rides the flight and grows with the card instead of hanging in the air where the card used to be; it is
    /// a leaning band on a **skewed** mesh, so its travel stays horizontal while the light itself is diagonal.
    ///
    /// Every number here is chosen to keep the band inside the card's own outline at 2.6 × scale: nothing clips
    /// a RealityKit quad to a SwiftUI attachment, so a band that travelled the full width would leave a bright
    /// bar hanging in the air beside the preview (which is exactly what the first cut did).
    private func sweepNoteGlint(on holder: Entity) {
        let width = NoteFanLayout.cardSize.x, height = NoteFanLayout.cardSize.y
        let quad = ModelEntity(mesh: FXMeshes.skewedQuad(width: width * 0.22, height: height, skew: height * 0.22),
                               materials: [FXMaterials.glow(fx.glint, tint: HologramController.noteDustGold, opacity: 1)])
        let reach = width * 0.30
        let from = SIMD3<Float>(-reach, 0, 0.0016), to = SIMD3<Float>(reach, 0, 0.0016)
        quad.position = from
        quad.components.set(OpacityComponent(opacity: 0))
        quad.components.set(GlintSweepComponent(from: from, to: to, duration: 0.45, peakOpacity: 0.42))
        holder.addChild(quad)
    }

    // MARK: - Emitters

    /// The dust one card leaves behind it. `particlesInheritTransform = false` is the whole trick: the sparks
    /// stay in the air where they were born instead of riding the card to its slot.
    static func noteTrailEmitter(sprite: TextureResource,
                                 size: Float = HologramController.burstDustSize) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .sphere
        p.emitterShapeSize = [0.035, 0.045, 0.012]
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, -1, 0]
        p.speed = 0.035
        p.speedVariation = 0.028
        p.particlesInheritTransform = false
        p.isEmitting = true
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 0.8
        p.mainEmitter.lifeSpanVariation = 0.2
        // **V3-4 §9**: 3.4 mm → 5 mm sprites (the star texture reads as a spark at ~2 mm of bright core) and
        // they hold their size longer, so a trail is a trail rather than a fizz.
        // **V3-5 §7a**: …and the *trail* callers pass 3 mm with the round mote instead, because on camera
        // 5 mm stars at 120/s read as falling snow. The one-shot bursts keep both (12–20 sparks that are
        // each meant to be seen). `sizeVariation` keeps V3-4's 36 % ratio either way.
        p.mainEmitter.size = size
        p.mainEmitter.sizeVariation = size * 0.36
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.25
        p.mainEmitter.acceleration = [0, -0.05, 0]
        p.mainEmitter.spreadingAngle = .pi
        p.mainEmitter.angularSpeed = 1.1
        p.mainEmitter.angularSpeedVariation = 1.4
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        p.mainEmitter.color = .evolving(start: .random(a: noteDustGold, b: noteDustAurora),
                                        end: .single(noteDustAurora.withAlphaComponent(0)))
        return p
    }

    /// The 60 sparkles a preview throws off the card it opened from: one shot, out in every direction, gone in
    /// under a second.
    private static func noteBurstEmitter(sprite: TextureResource) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .sphere
        p.emitterShapeSize = SIMD3<Float>(repeating: 0.05)
        p.birthLocation = .surface
        p.birthDirection = .normal
        p.speed = 0.20
        p.speedVariation = 0.10
        p.particlesInheritTransform = false
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = 0
        p.mainEmitter.lifeSpan = 0.9
        p.mainEmitter.lifeSpanVariation = 0.25
        p.mainEmitter.size = 0.0036
        p.mainEmitter.sizeVariation = 0.0014
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.1
        p.mainEmitter.acceleration = [0, -0.10, 0]
        p.mainEmitter.dampingFactor = 1.6
        p.mainEmitter.angularSpeed = 1.4
        p.mainEmitter.angularSpeedVariation = 1.8
        p.mainEmitter.opacityCurve = .quickFadeInOut
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        p.mainEmitter.color = .evolving(start: .random(a: noteDustGold, b: noteDustAurora),
                                        end: .single(noteDustGold.withAlphaComponent(0)))
        return p
    }

    /// The twinkle field: ~55 motes drifting inside the gallery's own box, each fading up and down over five
    /// seconds. One emitter, not fifty-five entities.
    private static func noteTwinkleEmitter(sprite: TextureResource) -> ParticleEmitterComponent {
        var p = ParticleEmitterComponent()
        p.emitterShape = .box
        p.emitterShapeSize = noteTwinkleSize
        p.birthLocation = .volume
        p.birthDirection = .local
        p.emissionDirection = [0, 1, 0]
        p.speed = 0.010
        p.speedVariation = 0.009
        p.particlesInheritTransform = true
        p.isEmitting = false
        p.mainEmitter.image = sprite
        p.mainEmitter.blendMode = .additive
        p.mainEmitter.birthRate = noteTwinkleBirthRate
        p.mainEmitter.lifeSpan = 5.6
        p.mainEmitter.lifeSpanVariation = 1.8
        p.mainEmitter.size = 0.0032
        p.mainEmitter.sizeVariation = 0.0014
        p.mainEmitter.sizeMultiplierAtEndOfLifespan = 0.7
        p.mainEmitter.acceleration = [0, 0.003, 0]
        p.mainEmitter.spreadingAngle = .pi
        p.mainEmitter.angularSpeed = 0.5
        p.mainEmitter.angularSpeedVariation = 0.8
        // Fades up and down across its whole life: forty slow sinusoids without a system of their own.
        p.mainEmitter.opacityCurve = .gradualFadeInOut
        p.mainEmitter.noiseStrength = 0.010
        p.mainEmitter.noiseScale = 1.6
        p.mainEmitter.noiseAnimationSpeed = 0.12
        p.mainEmitter.isLightingEnabled = false
        p.mainEmitter.sortOrder = .unsorted
        p.mainEmitter.color = .evolving(start: .random(a: noteDustGold, b: noteDustAurora),
                                        end: .random(a: noteDustAurora, b: noteDustGold))
        return p
    }

    /// The frosted card behind the preview, and the pool of light along its bottom edge. The pool breathes on a
    /// `PulseComponent`, which would write its own brightness straight back over a tween — so its *base* moves.
    /// `animated: false` is the path where the card itself is leaving (a carry, a fold, a world): it already
    /// has a `TweenComponent` of its own, and an entity only holds one — writing an opacity tween here would
    /// throw that choreography away, so the opacity is put back in one frame instead.
    private func dimCardForNote(preview: Bool, animated: Bool = true) {
        let from = cardGroup.components[OpacityComponent.self]?.opacity ?? 1
        // H6: in the hand the card is the anchor the preview hangs off — 0.35 would read as it leaving.
        let target: Float = preview
            ? (notes.deckOut ? HologramController.deckPreviewCardOpacity : HologramController.notePreviewCardOpacity)
            : 1
        if animated {
            cardGroup.components.set(TweenComponent(opacity: (from: from, to: target), duration: 0.35, easing: .easeOutCubic))
        } else {
            cardGroup.components.set(OpacityComponent(opacity: target))
        }
        guard var pulse = landing.components[PulseComponent.self] else { return }
        if preview {
            if notes.landingLevel == nil { notes.landingLevel = pulse.baseOpacity }
            pulse.baseOpacity = HologramController.notePreviewLandingLevel
        } else {
            pulse.baseOpacity = notes.landingLevel ?? pulse.baseOpacity
            notes.landingLevel = nil
        }
        landing.components.set(pulse)
    }
}
