import CoreFoundation
import Foundation
import RealityKit
import simd
import UIKit

/// **V3-2a2 S0b.** A deck holder's pose in hinge space — the frame glued to the name card. Its presence is
/// what makes a card "in the hand": `followDeckToHinge` re-aims it at the cover once a frame, and every path
/// that sends the card somewhere else (the gallery, the inside of the card, a preview in root space) removes
/// it, because those poses are not the cover's to move.
struct DeckAnchorComponent: Component {
    var local: Transform
}

/// **V3-2b B2 / plan §4 E5.** One deck card's own follower, in **world** space.
///
/// A hand of cards does not move as one rigid object: the card you are holding arrives first and the others
/// catch up over the next few frames, which is what makes seven planes read as *cards in a hand* rather than
/// as a decal on the passport. So every slot is a critically damped follower toward its own pose, with a time
/// constant that grows from the middle of the fan outward (0.05 s + 0.01 s per slot): the outer cards swing
/// furthest, exactly as they would if they were hinged at the wearer's thumb.
///
/// World space, and not the fan's own, for a reason worth writing down: `notes.group` hangs off `hologram`,
/// which the pose follower moves under the whole rig every frame. A slot expressed in that frame is a fixed
/// point — a follower stepping toward it converges in the first half second and then shows *nothing* however
/// fast the wearer moves the passport. The lag only exists when the target is measured in the room.
struct DeckFollowComponent: Component {
    var follower: PoseFollower
}

/// **The hand deck** (V3-2a H3–H6 / plan §4 E2, E4, E7, E10).
///
/// On the desk the ten recent notes are a gallery in the air and the two worlds are coins on an arc. The
/// moment the passport is picked up all of that becomes *a hand of cards*: the five newest notes fan out
/// behind the name card on its hinge, the other five fold into it, and the two worlds slide out from behind
/// it to take the two outer slots. Putting the passport down runs the same morph backwards.
///
/// Three rules this file exists to keep:
///
/// 1. **Nothing is ever switched off to change state.** Every card gets a tween from where it actually is,
///    so a morph interrupted halfway (the desk gate flickering at its threshold) folds back rather than
///    popping.
/// 2. **No holder changes parent.** The cards stay under `notes.group` — the fan's own space, where
///    `fanOutNotes`, `relayoutNotes` and `collapseNotes` all expect to find them — and the deck's slots are
///    computed in `hingeGroup` — the frame glued to the name card — and converted across. A reparent here
///    is how a card gets stranded in a space some other path does not know about.
/// 3. **The deck never enters the device's footprint** (H0): its fan is struck from the hinge, which is
///    already outside the prism, and every slot is further out still.
extension HologramController {
    // MARK: - Attachments

    static func worldCardAttachmentID(_ id: String) -> String { "world-card-\(id)" }

    /// Called from the RealityView's update closure, like `syncNoteAttachments`: the two world cards are
    /// permanent residents of the fan's group, transparent until the deck rises.
    func syncWorldCardAttachments(ids: [String], lookup: (String) -> Entity?) {
        for id in ids where notes.worldHolders[id] == nil {
            let holder = Entity()
            holder.name = HologramController.worldCardAttachmentID(id)
            holder.transform = noteCollapsedTransform
            holder.components.set(OpacityComponent(opacity: 0))
            holder.isEnabled = false
            notes.group.addChild(holder)
            notes.worldHolders[id] = holder
            // B2: the world cards trail like the note cards do — a **sibling** emitter, for the two reasons
            // `NoteTrailComponent` documents (the holder's opacity is hierarchical and it is disabled on
            // landing, either of which would cut the sparks already in the air).
            let trail = Entity()
            // **V3-6 §2.** A family name, not a per-id one: `[perf] scene:` dedupes its emitter list by name,
            // so seven deck trails read as `trail.deck×7` instead of seven unrepeatable strings. Nothing
            // looks these up — `notes.trail(for:)` is a dictionary on the id.
            trail.name = "trail.deck"
            trail.position = holder.position
            trail.components.set(HologramController.noteTrailEmitter(sprite: fx.mote,
                                                                     size: HologramController.trailDustSize))
            trail.components.set(NoteTrailComponent(target: holder, birthRate: HologramController.deckTrailBirthRate))
            trail.isEnabled = false
            notes.group.addChild(trail)
            notes.worldTrails[id] = trail
        }
        for (id, holder) in notes.worldHolders where !ids.contains(id) {
            holder.removeFromParent()
            notes.worldHolders[id] = nil
            notes.worldTrails[id]?.removeFromParent()
            notes.worldTrails[id] = nil
        }
        for (id, holder) in notes.worldHolders {
            guard let entity = lookup(HologramController.worldCardAttachmentID(id)), entity.parent !== holder else { continue }
            entity.transform = .identity
            holder.addChild(entity)
        }
    }

    // MARK: - Geometry

    /// Where a deck card stands, **in hinge space** — `hingeGroup`, the frame glued to the name card
    /// (V3-2a2 S0b). `HandDeckLayout`'s numbers are struck in exactly this frame: the origin is the card's
    /// bottom edge on the device's top edge, +Y runs up the card and +Z out of its face.
    func deckSlotLocal(index: Int, count: Int, spread: Float = 1, scale: Float = 1) -> Transform {
        var slot = HandDeckLayout.slot(index: index, count: count)
        if spread != 1 {
            let theta = slot.angle * spread
            slot.angle = theta
            slot.position = [sin(theta) * HandDeckLayout.radius, cos(theta) * HandDeckLayout.radius, slot.position.z]
        }
        slot.scale *= scale
        return Transform(scale: SIMD3<Float>(repeating: slot.scale),
                         rotation: simd_quatf(angle: -slot.roll, axis: [0, 0, 1]),
                         translation: slot.position + [0, deckLift, 0])
    }

    /// Where the one raised card stands, in hinge space: centred over the name card, 5 mm above its top
    /// edge, leaning 10° toward the wearer.
    func deckRaisedLocal() -> Transform {
        let slot = HandDeckLayout.raised(index: 0)
        return Transform(scale: SIMD3<Float>(repeating: slot.scale),
                         rotation: simd_quatf(angle: HologramController.deckRaisedPitch, axis: [1, 0, 0]),
                         translation: slot.position + [0, deckLift, 0])
    }

    /// A hinge-space pose in the fan group's own space, which is where every holder actually lives.
    func inFan(_ local: Transform) -> Transform {
        notes.group.convert(transform: local, from: hingeGroup)
    }

    func deckSlotTransform(index: Int, count: Int, spread: Float = 1, scale: Float = 1) -> Transform {
        inFan(deckSlotLocal(index: index, count: count, spread: spread, scale: scale))
    }

    func deckRaisedTransform() -> Transform { inFan(deckRaisedLocal()) }

    // MARK: - Riding the hinge (V3-2a2 S0b)

    /// One frame of "the hand of cards is glued to the cover". Every holder that has a hinge-space anchor is
    /// re-converted out of `hingeGroup`: one that is standing still is written straight, one that is still
    /// flying has its tween's destination re-aimed (`from` and `elapsed` untouched), so an opening cover
    /// never snaps the fan at the end of a tween.
    ///
    /// `dt` is the rendered frame (V3-2b B2): with it, a holder standing still is not written straight but
    /// *followed* — see `stepDeckDynamics`. Nil (a choreography beat, `--deck-dynamics off`) snaps.
    func followDeckToHinge(dt: Float? = nil) {
        guard let dt, deckDynamics, notes.deckOut else { return snapDeckToHinge() }
        // V3-4 §10: timed into `[perf] hand form steps` while the hand-form probe is armed.
        let start = CFAbsoluteTimeGetCurrent()
        stepDeckDynamics(dt: dt)
        noteStepTime(\.deckDynamics, since: start)
    }

    /// V3-2a2 S0b's rule, unchanged: every anchored holder is written straight to the re-converted target.
    /// This is what a choreography beat and `--deck-dynamics off` both get.
    private func snapDeckToHinge() {
        // Walked every frame while the card is in the hand, so it iterates the two dictionaries in place
        // rather than building an array of their values.
        notes.forEachHolder { holder in
            guard let anchor = holder.components[DeckAnchorComponent.self] else { return }
            // …and only while the holder is actually in the fan's space. A card that is flying home from a
            // preview is still parented to `notePreviewRoot` and its tween's target is in **root** space:
            // re-aiming that at a `notes.group`-space point would throw it at the floor for 0.45 s.
            guard holder.parent === notes.group else { return }
            reaim(holder, at: anchor.local, snap: true)
        }
        deckLagNow = nil
    }

    /// One rendered frame of E5. Each slot is followed rather than written: the name card arrives first and
    /// the hand catches up over the next few frames. A card a choreography still owns keeps its tween (whose
    /// destination is re-aimed at the cover, S0b) and its follower rides along, so the frame the tween ends
    /// the follow continues from where it left off instead of popping back.
    private func stepDeckDynamics(dt: Float) {
        let items = deckItems()
        let middle = Float(max(0, items.count - 1)) / 2
        var peak: Float = 0
        var measured = false
        var stepped = Set<ObjectIdentifier>()
        for (index, item) in items.enumerated() {
            let holder = item.holder
            stepped.insert(ObjectIdentifier(holder))
            guard let anchor = holder.components[DeckAnchorComponent.self], holder.parent === notes.group else { continue }
            var follow: PoseFollower
            if let existing = holder.components[DeckFollowComponent.self]?.follower {
                follow = existing
            } else {
                // Born where the card already is — a follower that started at the world origin would report a
                // metre and a half of "lag" on its first frame and glide in from the floor.
                follow = PoseFollower(tau: HologramController.deckFollowTau(slot: index, middle: middle))
                let here = notes.group.convert(transform: holder.transform, to: nil)
                follow.snap(position: here.translation, rotation: here.rotation)
            }
            follow.tau = HologramController.deckFollowTau(slot: index, middle: middle)
            follow.tauRotation = HologramController.deckFollowTauRotation
            if let running = holder.components[TweenComponent.self], running.position != nil || running.orientation != nil {
                reaim(holder, at: anchor.local, snap: false)
                // The tween owns the card this frame; the follower simply stays on it.
                let world = notes.group.convert(transform: holder.transform, to: nil)
                follow.snap(position: world.translation, rotation: world.rotation)
            } else if let running = holder.components[TweenComponent.self] {
                // A tween that claims neither position nor orientation (E13's 6 % pop): the card keeps
                // following the wearer's hand underneath it, and only its scale is the tween's.
                reaim(holder, at: anchor.local, snap: false)
                let target = hingeGroup.convert(transform: anchor.local, to: nil)
                follow.retarget(position: target.translation, rotation: target.rotation)
                follow.step(dt: dt)
                let world = Transform(scale: notes.group.convert(transform: holder.transform, to: nil).scale,
                                      rotation: follow.rotation, translation: follow.position)
                let local = notes.group.convert(transform: world, from: nil)
                holder.position = local.translation
                holder.orientation = local.rotation
                _ = running
                let lag = simd_length(follow.position - target.translation)
                if lag.isFinite { peak = max(peak, lag); measured = true }
            } else {
                // The slot **in the room**: `hingeGroup` rides the device, so this target moves whenever the
                // wearer's hand does — which is the only reason a follower can lag behind it at all.
                let target = hingeGroup.convert(transform: anchor.local, to: nil)
                follow.retarget(position: target.translation, rotation: target.rotation)
                follow.step(dt: dt)
                let world = Transform(scale: target.scale, rotation: follow.rotation, translation: follow.position)
                holder.transform = notes.group.convert(transform: world, from: nil)
                let lag = simd_length(follow.position - target.translation)
                if lag.isFinite { peak = max(peak, lag); measured = true }
            }
            holder.components.set(DeckFollowComponent(follower: follow))
        }
        // Anything still anchored that the deck no longer lists (a card on its way out) keeps S0b's rule.
        notes.forEachHolder { holder in
            guard !stepped.contains(ObjectIdentifier(holder)),
                  let anchor = holder.components[DeckAnchorComponent.self],
                  holder.parent === notes.group else { return }
            reaim(holder, at: anchor.local, snap: true)
        }
        deckLagNow = measured ? peak : nil
    }

    /// Re-aim a holder at a hinge-space pose: a running tween has its **destination** moved (`from` and
    /// `elapsed` untouched, so an opening cover never snaps the fan at the end of a tween), a standing one is
    /// written straight when `snap`.
    private func reaim(_ holder: Entity, at local: Transform, snap: Bool) {
        let target = inFan(local)
        if var tween = holder.components[TweenComponent.self] {
            if tween.position != nil { tween.position?.to = target.translation }
            if tween.orientation != nil { tween.orientation?.to = target.rotation }
            if tween.scale != nil { tween.scale?.to = target.scale }
            holder.components.set(tween)
        } else if snap {
            holder.transform = target
        }
    }

    /// Nothing in the hand any more: no holder is the cover's to move, and no follower is chasing it.
    func clearDeckAnchors() {
        notes.forEachHolder {
            $0.components.remove(DeckAnchorComponent.self)
            $0.components.remove(DeckFollowComponent.self)
        }
        deckLagNow = nil
    }

    // MARK: - E5's numbers

    /// Position τ for slot `index`: 0.05 s in the middle of the fan, 0.01 s more per slot outward — so the
    /// ends swing furthest and the hand reads as one object with give in it rather than seven rigid planes.
    static func deckFollowTau(slot index: Int, middle: Float) -> Float {
        0.05 + 0.01 * abs(Float(index) - middle)
    }

    /// …and one rotation τ for all of them.
    static let deckFollowTauRotation: Float = 0.08

    /// The deck's own pixie dust while the hand is moving (the card's is `handTrailBirthRate`).
    /// **V3-4 §9**: 25 → 60 a second, for the same reason the card's went to 120.
    static var deckTrailBirthRate: Float = 60

    /// Turn the deck's trails on / off with the same speed hysteresis the card's trail uses (> 0.15 m/s on,
    /// < 0.10 m/s off). `nil` hands them back to the fan's own rule — a tween-driven flight — which is what
    /// the gallery on the desk expects.
    func setDeckTrails(_ on: Bool?) {
        for item in deckItems() {
            guard let trail = notes.trail(for: item.id) else { continue }
            var state = trail.components[NoteTrailComponent.self]
                ?? NoteTrailComponent(target: item.holder, birthRate: HologramController.noteTrailBirthRate)
            state.target = item.holder
            state.birthRate = on == nil ? HologramController.noteTrailBirthRate : HologramController.deckTrailBirthRate
            state.forceFlying = on
            // v4 B2: `false` no longer switches a parked trail back on — a hand that stopped has nothing to trail,
            // and `parkIdleDeckTrails` takes the entity out a beat later. `true` brings it back.
            trail.isEnabled = on == true || trail.isEnabled
            trail.components.set(state)
            // `NoteTrailSystem` only rewrites the emitter on a state change, so an emitter that is already on
            // has to be re-rated here or it would keep the gallery's 95/s in the hand.
            if state.isOn, var emitter = trail.components[ParticleEmitterComponent.self] {
                emitter.mainEmitter.birthRate = state.birthRate
                trail.components.set(emitter)
            }
        }
    }

    /// **v4 B2.** The deck's own seven trails, once the hand has stopped (0.9 s after `[hand] trail off`, so every
    /// spark already in the air finishes): the entity goes out of the tree, which is what takes it out of
    /// `[perf] scene: … emitters alive`. The next `[hand] trail on` switches it back on (`setDeckTrails(true)`),
    /// exactly as the card's own trail has always done.
    func parkIdleDeckTrails() {
        guard notes.deckOut else { return }
        var parked = 0
        for item in deckItems() {
            guard let trail = notes.trail(for: item.id), trail.isEnabled,
                  let state = trail.components[NoteTrailComponent.self], state.forceFlying != true, !state.isOn else { continue }
            // A card still on a flight of its own (a raise, a sink) keeps its dust until it lands.
            if let tween = item.holder.components[TweenComponent.self], tween.position != nil { continue }
            trail.isEnabled = false
            parked += 1
        }
        guard parked > 0, !notes.idleTrailsParkedLogged else { return }
        notes.idleTrailsParkedLogged = true
        print("\(PerfLog.prefix) deck trails parked while the hand is still (\(parked)); a flight or the next [hand] trail on brings them back")
    }

    /// **v4 B2.** Park the idle trails once everything in flight has landed: `seconds` from now plus the 0.9 s every
    /// spark already in the air needs. Debounced — the latest flight decides.
    func scheduleIdleDeckTrailPark(after seconds: Float) {
        notes.idleTrailPark?.cancel()
        notes.idleTrailPark = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int((max(0, seconds) + 0.9) * 1000)))
            guard let self, !Task.isCancelled, !self.handTrailIsOn else { return }
            self.parkIdleDeckTrails()
        }
    }

    /// **V3-6 §3.** The gallery's *other* note trails, parked while the deck rides the wearer's hand.
    ///
    /// The third headset round's pick-up window reported `14 emitters alive` against 8–9 for every window
    /// after a summon, and with V3-6's named census the fourteen turned out to be
    /// `card.particles, rig.dust, trail.deck×2, trail.note×10` — **all ten** of the desk gallery's trail
    /// emitters, the five the deck took into the hand and the five that folded back into the card with it.
    /// `setDeckTrails` only ever walks `deckItems()`, so the folded five kept whatever the gallery left them
    /// (enabled, 95/s, a `NoteTrailComponent` still chasing a holder that is now invisible inside the card).
    ///
    /// Nothing has to put them back by hand: every path that opens the gallery again — `fanOutNotes` through
    /// `setNoteDust(true)`, and the put-down bloom's `fanOut` through `setNoteTrails(true)` — enables all ten.
    func parkOffDeckTrails() {
        let inDeck = Set(deckItems().map(\.id))
        var parked = 0
        for (id, trail) in notes.trails where !inDeck.contains(id) && trail.isEnabled {
            if var state = trail.components[NoteTrailComponent.self], state.isOn {
                state.isOn = false
                trail.components.set(state)
            }
            if var emitter = trail.components[ParticleEmitterComponent.self] {
                emitter.mainEmitter.birthRate = 0
                trail.components.set(emitter)
            }
            trail.isEnabled = false
            parked += 1
        }
        guard parked > 0 else { return }
        print("\(PerfLog.prefix) desk emitters parked in the hand (\(parked) note trails)")
    }

    static let deckRaisedPitch: Float = 10 * .pi / 180
    /// Raise / sink timings (plan §2 「UP / DOWN」).
    static let deckRaiseDuration: Float = 0.30
    /// Pick-up morph (plan §4 E2) and put-down bloom (E10).
    static let deckMorphDuration: Float = 0.30
    static let deckMorphStagger: Double = 0.030
    static let deckBloomStagger: Double = 0.040

    /// Every holder the deck owns, in slot order: the first world card, the notes, the second world card.
    func deckItems() -> [(id: String, holder: Entity, isWorld: Bool)] {
        notes.deckOrder.compactMap { item in
            switch item {
            case .world(let id):
                guard let holder = notes.worldHolders[id] else { return nil }
                return (id, holder, true)
            case .note(let id):
                guard let holder = notes.holders[id] else { return nil }
                return (id, holder, false)
            }
        }
    }

    /// The ids the deck would hold right now: the five newest notes and whatever worlds exist.
    func planDeck(worlds: [String], notes noteIDs: [String]) {
        notes.deckOrder = HandDeckLayout.items(worlds: worlds, notes: noteIDs)
    }

    // MARK: - Raise (plan §4 E4)

    /// UP / DOWN: `id` rises over the name card and whatever was raised sinks back to its slot. `nil` = the
    /// profile, with nothing raised.
    @discardableResult
    func raiseDeckCard(_ id: String?) -> Int? {
        guard notes.deckOut else { return nil }
        let items = deckItems()
        let count = items.count
        if let previous = notes.deckRaised, previous != id,
           let index = items.firstIndex(where: { $0.id == previous }) {
            tween(items[index].holder, toHinge: deckSlotLocal(index: index, count: count),
                  duration: HologramController.deckRaiseDuration, easing: .easeInCubic, opacity: 1)
            setWorldCardRaised(items[index], raised: false)
        }
        notes.deckRaised = id
        // V3-4 §2(a): a raise is a deck event — it pushes a pending "deck restored" check out another second
        // rather than letting it land in the middle of this card's flight.
        armDeckRestoredCheck()
        guard let id, let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let holder = items[index].holder
        holder.isEnabled = true
        holder.components.remove(SwayComponent.self)
        tween(holder, toHinge: deckRaisedLocal(), duration: HologramController.deckRaiseDuration,
              easing: .spring(response: 0.4, damping: 0.72), opacity: 1, arcOffset: [0, 0.02, 0])
        sweepDeckGlint(on: holder)
        burstDeckDust(at: holder.position)
        setWorldCardRaised(items[index], raised: true)
        audio.play([FXAudio.Cue.chip0, .chip1, .chip2][index % 3], on: anchorRoot)
        // V3-4 §9: the card lands with some weight — a bloom, and the hinge's light doubled for 0.4 s.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(HologramController.deckRaiseDuration * 1000)))
            self?.playRaiseFlourish()
        }
        return index
    }

    private func setWorldCardRaised(_ item: (id: String, holder: Entity, isWorld: Bool), raised: Bool) {
        guard item.isWorld else { return }
        onWorldCardRaised?(raised ? item.id : nil)
    }

    // MARK: - Morphs

    /// **E2, the pick-up morph.** The gallery becomes the deck in one continuous movement: the light rays
    /// retract into the device's outline, the front row flies to the fan, the back row folds into the card,
    /// and the two world cards slide out from behind it to the two ends.
    func morphGalleryToDeck(worlds: [String], noteIDs: [String], riseDelay: Float = 0.2) {
        // Nothing was on the desk to morph: this is a summon in the hand, and the deck simply rises out of
        // the card (plan §4 E12's 「牌堆从名片升起」) rather than reforming a gallery that is not there.
        let fromGallery = notes.isOut
        // v4 B2 §2: the desk ring's lifted card goes into the hand with the rest.
        forgetNoteHighlight()
        // A note may be open in front of the wearer when they pick the passport up. Its holder lives in
        // **root** space; every target below is in the fan's. End it first, in one frame, exactly as
        // `collapseNotes` does — otherwise the panel hangs in the air and the card stays dimmed.
        endPreviewNote(animated: false)
        planDeck(worlds: worlds, notes: noteIDs)
        notes.task?.cancel()
        // v4 B4 §1: the hand's reveal — the deck comes out of a card that has dissolved in, not out of its outline.
        let waitFor = nextDeckRiseDelay ?? 0
        nextDeckRiseDelay = nil
        guard fromGallery else { return riseDeck(worlds: worlds, noteIDs: noteIDs, delay: max(riseDelay, waitFor)) }
        notes.isOut = true
        notes.deckOut = true
        notes.deckRaised = nil
        notes.group.isEnabled = true
        notes.group.components.set(OpacityComponent(opacity: 1))
        // The gallery's ±10 mm drift is a desk effect: on the hinge it would swing the whole hand of cards
        // a centimetre against a device the wearer is holding still.
        freezeNotesDrift(true)
        setNoteTwinkleForDeck(false)
        // Any holder a previous path borrowed has to be back in the fan's own space before the slots land.
        for holder in notes.holders.values where holder.parent !== notes.group {
            holder.setParent(notes.group, preservingWorldTransform: false)
            holder.transform = noteCollapsedTransform
        }
        let items = deckItems()
        let count = items.count
        let deckIDs = Set(items.map(\.id))
        // Centre-out, so the middle of the hand arrives first and the ends follow.
        let order = items.indices.sorted { abs(Float($0) - Float(count - 1) / 2) < abs(Float($1) - Float(count - 1) / 2) }
        var folded = 0
        for (rank, index) in order.enumerated() {
            let item = items[index]
            item.holder.isEnabled = true
            item.holder.components.remove(SwayComponent.self)
            tween(item.holder, toHinge: deckSlotLocal(index: index, count: count),
                  delay: Float(Double(rank) * HologramController.deckMorphStagger),
                  duration: item.isWorld ? 0.35 : HologramController.deckMorphDuration,
                  easing: item.isWorld ? .spring(response: 0.4, damping: 0.75) : .easeInOutCubic,
                  opacity: 1)
            setWorldCardRaised(item, raised: false)
        }
        // Everything the deck does not hold folds into the card, outside-in.
        let collapsed = noteCollapsedTransform
        for (rank, id) in notes.order.enumerated() where !deckIDs.contains(id) {
            guard let holder = notes.holders[id] else { continue }
            holder.components.remove(SwayComponent.self)
            tween(holder, to: collapsed, delay: Float(Double(rank) * 0.02), duration: 0.35,
                  easing: .easeInCubic, opacity: 0, disableWhenDone: true)
            folded += 1
        }
        let worldCount = items.filter(\.isWorld).count
        print("[reveal] pick-up morph: gallery → deck (\(count - worldCount)) + fold (\(folded)) + world cards (\(worldCount))")
        print("[reveal] hand deck \(count) (\(worldCount) worlds + \(count - worldCount) notes)")
        // The probe lives on the fan's group: `hologram` already carries the celebration's.
        startPerfProbe("pick-up morph", duration: 0.6)
        // **V3-6 §3.** …and once the fold has landed (0.35 s + 0.02 × the last rank), the five trails that
        // went with it stop emitting. Delayed rather than immediate so the fold itself still has its dust.
        notes.deckTrailPark?.cancel()
        notes.deckTrailPark = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, !Task.isCancelled, self.notes.deckOut else { return }
            self.parkOffDeckTrails()
        }
    }

    /// **E10, the put-down bloom.** The deck's five notes fly to the gallery's front row, the two world
    /// cards fold into the card (their coins light up on the desk instead) and the back row fans out again.
    /// Deliberately **not** `fanOutNotes`: that would re-fly all ten, including the five that just landed.
    func morphDeckToGallery(allIDs: [String]) {
        guard notes.deckOut else { return }
        // Same the other way round: the passport can be put down with a deck preview open.
        endPreviewNote(animated: false)
        notes.task?.cancel()
        setDeckTrails(nil)
        notes.deckOut = false
        notes.deckRaised = nil
        notes.deckAnticipating = false
        onWorldCardRaised?(nil)
        freezeNotesDrift(false)
        let items = deckItems()
        let deckNotes = items.filter { !$0.isWorld }.map(\.id)
        let collapsed = noteCollapsedTransform
        // The five that were in the hand glide to their gallery slots, centre-out.
        let front = deckNotes.compactMap { id -> (Int, Entity)? in
            guard let index = allIDs.firstIndex(of: id), let holder = notes.holders[id] else { return nil }
            return (index, holder)
        }
        let order = front.indices.sorted { abs(Float($0) - Float(front.count - 1) / 2) < abs(Float($1) - Float(front.count - 1) / 2) }
        for (rank, slot) in order.enumerated() {
            let (index, holder) = front[slot]
            let target = noteSlotTransform(index: index, count: allIDs.count)
            holder.isEnabled = true
            installNoteSway(holder, index: index, transform: target)
            tween(holder, to: target, delay: Float(Double(rank) * HologramController.deckBloomStagger),
                  duration: 0.45, easing: .spring(response: 0.45, damping: 0.75), opacity: 1)
        }
        // The world cards go back inside the card; their coins are what the desk shows.
        for item in items where item.isWorld {
            tween(item.holder, to: collapsed, duration: 0.3, easing: .easeInCubic, opacity: 0, disableWhenDone: true)
        }
        // …and the other five fan out of the card again (the internal fan, not the public one).
        let rest = allIDs.filter { !deckNotes.contains($0) }
        fanOut(ids: rest, allIDs: allIDs, cues: true)
        print("[reveal] deck → gallery (\(front.count) front, \(rest.count) fan, \(items.filter(\.isWorld).count) world cards → coins)")
        startPerfProbe("put-down bloom", duration: 1.6)
    }

    /// The list changed while the deck is in the hand: every card glides to its new slot where it stands.
    func relayoutDeck(worlds: [String], noteIDs: [String]) {
        guard notes.deckOut else { return }
        planDeck(worlds: worlds, notes: noteIDs)
        let items = deckItems()
        let count = items.count
        for (index, item) in items.enumerated() {
            guard item.id != notes.deckRaised else { continue }
            item.holder.isEnabled = true
            tween(item.holder, toHinge: deckSlotLocal(index: index, count: count),
                  duration: 0.35, easing: .easeInOutCubic, opacity: 1)
        }
        armDeckRestoredCheck()
        print("[notes] deck re-laid out (\(count))")
    }

    /// Everything the deck owns goes back to "not in the hand", without moving anything: the paths that
    /// take the card away (a fold, a world, a teardown) have their own choreography for the holders.
    func resetDeckState() {
        clearDeckAnchors()
        flushDeckRestoredCheck()
        guard notes.deckOut || notes.deckAnticipating else { return }
        setDeckTrails(nil)
        notes.deckOut = false
        notes.deckRaised = nil
        notes.deckAnticipating = false
        onWorldCardRaised?(nil)
        freezeNotesDrift(false)
    }

    /// Where a tucked deck card waits: **inside the name card**, in the arm's own frame, so a deck that
    /// gathers up while the passport is in a hand does it behind the card the wearer is holding and not at
    /// the desk card's pose 22 cm above the device (V3-2b B3). On the desk it is the fan's own collapsed pose.
    func deckTuckLocal() -> Transform {
        Transform(scale: SIMD3<Float>(repeating: HandDeckLayout.slotScale * 0.55),
                  rotation: simd_quatf(ix: 0, iy: 0, iz: 0, r: 1),
                  translation: [0, hingeCardPosition.y, -0.02])
    }

    /// The deck folds into the card before the card itself goes (a fold, a world). No cue: it is the
    /// *anticipation* of something else.
    ///
    /// **V3-2b B3 / plan §4 E12**: the raised card is the *door* the wearer is about to walk through, so it
    /// waits `raisedDelay` and goes last.
    func tuckDeck(duration: Float = 0.25, raisedDelay: Float = 0) {
        guard notes.deckOut else { return }
        flushDeckRestoredCheck()
        setDeckTrails(nil)
        let raised = notes.deckRaised
        notes.deckOut = false
        notes.deckRaised = nil
        notes.deckAnticipating = false
        onWorldCardRaised?(nil)
        let inHand = isHandForm && handForm == .hinge
        let tucked = deckTuckLocal()
        let collapsed = noteCollapsedTransform
        for item in deckItems() {
            let delay = item.id == raised ? raisedDelay : 0
            if inHand {
                tween(item.holder, toHinge: tucked, delay: delay, duration: duration, easing: .easeInCubic,
                      opacity: 0, disableWhenDone: true)
            } else {
                tween(item.holder, to: collapsed, delay: delay, duration: duration, easing: .easeInCubic,
                      opacity: 0, disableWhenDone: true)
            }
        }
        print("[reveal] deck tucked into the card\(raised != nil && raisedDelay > 0 ? " (the raised card last)" : "")")
    }

    /// The deck rises out of the card: after a summon in the hand, and 0.5 s after coming back from a world.
    func riseDeck(worlds: [String], noteIDs: [String], cue: Bool = true, delay: Float = 0) {
        planDeck(worlds: worlds, notes: noteIDs)
        notes.isOut = true
        notes.deckOut = true
        notes.deckRaised = nil
        notes.group.isEnabled = true
        notes.group.components.set(OpacityComponent(opacity: 1))
        freezeNotesDrift(true)
        let items = deckItems()
        let count = items.count
        for (index, item) in items.enumerated() {
            item.holder.isEnabled = true
            item.holder.components.remove(SwayComponent.self)
            if item.holder.components[OpacityComponent.self]?.opacity ?? 0 > 0.5 {
                // Already on screen (a re-plan): glide, do not re-launch.
            } else {
                item.holder.transform = noteCollapsedTransform
                item.holder.components.set(OpacityComponent(opacity: 0))
            }
            tween(item.holder, toHinge: deckSlotLocal(index: index, count: count),
                  delay: delay + Float(Double(index) * 0.04), duration: 0.35,
                  easing: .spring(response: 0.4, damping: 0.75), opacity: 1, arcOffset: [0, 0.02, 0])
        }
        // **V3-6 §3.** A summon (or the way back from a world) never had a gallery in the air, so the five
        // the deck does not hold can be parked on the spot.
        notes.deckTrailPark?.cancel()
        parkOffDeckTrails()
        if cue { audio.play(.chip0, on: anchorRoot) }
        // **V3-4 §10.** The deck's own probe, so "is the 45 fps in the pick-up morph the deck or the ten
        // attachments' opacity tweens" can be answered from one log line instead of argued about.
        startPerfProbe("deck rises", duration: 0.8)
        let worldCount = items.filter(\.isWorld).count
        print("[reveal] deck rises (\(count))")
        print("[reveal] hand deck \(count) (\(worldCount) worlds + \(count - worldCount) notes)")
    }

    // MARK: - Anticipation (plan §4 E10)

    /// The desk gate says the passport is flat but not yet still: the hand opens 15 % wider for 0.2 s, so
    /// the put-down is announced rather than arriving 0.4 s after the wearer let go. Cancelled by motion.
    func setDeckAnticipation(_ on: Bool) {
        guard notes.deckOut, notes.deckAnticipating != on else { return }
        notes.deckAnticipating = on
        let items = deckItems()
        let count = items.count
        for (index, item) in items.enumerated() where item.id != notes.deckRaised {
            tween(item.holder, toHinge: deckSlotLocal(index: index, count: count, spread: on ? 1.15 : 1),
                  duration: 0.2, easing: .easeInOutCubic, opacity: 1)
        }
        if on { print("[reveal] settle anticipation (deck fan ×1.15)") }
    }

    /// **V3-2b B5 / plan §4 E13.** The hand of cards answers a celebration the way the gallery does: a 6 %
    /// pop, 40 ms apart, ends last. Scale only — the cards go on following the wearer's hand while they pop
    /// (`stepDeckDynamics` keeps driving position and rotation under a tween that does not claim them).
    func rippleDeck() {
        guard notes.deckOut else { return }
        for (rank, item) in deckItems().enumerated() {
            guard item.id != notes.previewID, item.holder.isEnabled,
                  item.holder.components[TweenComponent.self] == nil else { continue }
            item.holder.components.set(TweenComponent(
                scale: (from: item.holder.scale * 1.06, to: item.holder.scale),
                delay: Float(Double(rank) * HologramController.deckBloomStagger),
                duration: 0.5, easing: .spring(response: 0.35, damping: 0.7)))
        }
    }

    // MARK: - Fold anticipation (V3-2b B4 / plan §4 E12)

    /// The wearer has started turning the passport over. Everything in the air **gathers into the card** and
    /// the card itself dims to 0.55 — and every bit of it is reversible, because this is a prediction: turn
    /// the passport back and the same 0.25 s runs the other way.
    ///
    /// Deliberately **not** a state change. `notes.deckOut` / `notes.isOut` are untouched, no anchor is
    /// dropped and nothing is disabled when it lands, so a cancel has something to restore and the fold that
    /// may follow still finds the deck where it expects it.
    func setFoldAnticipation(_ on: Bool) {
        guard foldAnticipating != on else { return }
        foldAnticipating = on
        guard hologram.isEnabled, currentPresence.showsHologram else { return }
        // The card. An opacity channel is merged into whatever tween is already running rather than replacing
        // it — `components.set` on a live `TweenComponent` would drop its position and scale channels.
        let from = cardGroup.components[OpacityComponent.self]?.opacity ?? 1
        let to: Float = on ? HologramController.foldAnticipationOpacity : 1
        let duration = HologramController.foldAnticipationDuration
        if var running = cardGroup.components[TweenComponent.self] {
            running.opacity = (from: from, to: to)
            cardGroup.components.set(running)
        } else {
            cardGroup.components.set(TweenComponent(opacity: (from: from, to: to),
                                                    duration: duration, easing: .easeInOutCubic))
        }
        if notes.deckOut {
            // In the hand: the seven cards gather behind the name card and come back to their own slots.
            let items = deckItems()
            let count = items.count
            let tucked = deckTuckLocal()
            for (index, item) in items.enumerated() {
                let home = item.id == notes.deckRaised ? deckRaisedLocal() : deckSlotLocal(index: index, count: count)
                tween(item.holder, toHinge: on ? tucked : home, duration: duration,
                      easing: .easeInOutCubic, opacity: on ? 0 : 1)
            }
        } else if notes.isOut {
            // On the desk: the gallery does the same thing into the big card.
            let collapsed = noteCollapsedTransform
            for (index, id) in notes.order.enumerated() {
                guard let holder = notes.holders[id] else { continue }
                let home = noteSlotTransform(index: index, count: notes.order.count)
                if !on { installNoteSway(holder, index: index, transform: home) }
                holder.isEnabled = true
                tween(holder, to: on ? collapsed : home, duration: duration,
                      easing: .easeInOutCubic, opacity: on ? 0 : 1)
            }
        }
        print("[reveal] fold anticipation \(on ? "(card 0.55, everything gathers)" : "cancelled")")
    }

    // MARK: - Preview (plan §4 E7 / H6)

    /// The rest of the hand while one card is being read: a little smaller, a little dimmer. The name card
    /// dims too, but only to 0.6 — in the hand it is the anchor the preview hangs off, not scenery.
    func stepBackDeck(except id: String?, ignoring: Set<String> = [], back: Bool) {
        let items = deckItems()
        let count = items.count
        for (index, item) in items.enumerated() where item.id != id && !ignoring.contains(item.id) {
            var scaled = item.id == notes.deckRaised
                ? deckRaisedLocal()
                : deckSlotLocal(index: index, count: count)
            scaled.scale *= back ? HologramController.noteStepBackScale : 1
            tween(item.holder, toHinge: scaled, duration: 0.30, easing: .easeOutCubic, opacity: back ? 0.6 : 1)
        }
    }

    /// Which slot the raised card came from, for the log.
    func deckSlot(of id: String?) -> Int? {
        guard let id else { return nil }
        return deckItems().firstIndex { $0.id == id }
    }

    // MARK: - Helpers

    /// One tween, from wherever the holder actually is to a **hinge-space** pose: the card goes into the
    /// hand, so it is anchored to the cover and `followDeckToHinge` keeps it there (V3-2a2 S0b).
    func tween(_ holder: Entity, toHinge local: Transform, delay: Float = 0, duration: Float,
               easing: Easing, opacity: Float, arcOffset: SIMD3<Float> = .zero,
               disableWhenDone: Bool = false) {
        // **V3-4 §2(b), one guard for every deck path.** A card a preview borrowed lives in `notePreviewRoot`
        // and every flight it is on is written in *that* space. Aiming a hinge-space pose at it — which
        // `tuckDeck`, `raiseDeckCard`, `stepBackDeck`, `relayoutDeck` and `setFoldAnticipation` would all
        // otherwise do while a preview is open — is precisely how a card gets stranded in a space no other
        // path knows to look in. The preview owns its cards until it hands them back.
        guard holder.parent === notes.group else { return }
        // **Order matters** (V3-2b B2, a real bug in the S0b tree): the other overload *removes* the anchor,
        // because a target given in the fan's own space is by definition not the cover's. Setting the anchor
        // first and calling it second therefore threw the anchor away on the same line that created it — so
        // `followDeckToHinge` found nothing to follow and the whole hinge coupling was dead code. The deck
        // still rode the device (every holder hangs off `hologram`), which is why no smoke caught it: what
        // was missing was the hinge *angle*, and with B2 the lag as well.
        tween(holder, to: inFan(local), delay: delay, duration: duration, easing: easing,
              opacity: opacity, arcOffset: arcOffset, disableWhenDone: disableWhenDone)
        holder.components.set(DeckAnchorComponent(local: local))
    }

    /// One tween, from wherever the holder actually is to `target`. The single place the H0 rule "never a
    /// state change by `isEnabled = false`" is kept for deck cards. A target given in the fan's own space is
    /// by definition *not* the cover's, so the hinge anchor goes with it.
    func tween(_ holder: Entity, to target: Transform, delay: Float = 0, duration: Float,
               easing: Easing, opacity: Float, arcOffset: SIMD3<Float> = .zero,
               disableWhenDone: Bool = false) {
        holder.components.remove(DeckAnchorComponent.self)
        let fromOpacity = holder.components[OpacityComponent.self]?.opacity ?? 0
        holder.components.set(TweenComponent(
            scale: (from: holder.scale, to: target.scale),
            position: (from: holder.position, to: target.translation),
            orientation: (from: holder.orientation, to: target.rotation),
            opacity: (from: fromOpacity, to: opacity),
            arcOffset: arcOffset, delay: delay, duration: duration, easing: easing,
            disableWhenDone: disableWhenDone,
            // v4 B5 §2: the deck's cards fade like the gallery's (`note-fade`).
            opacityWindow: noteFadeWindow(from: fromOpacity, to: opacity)))
        // v4 B2: a flight has its dust (the card's trail comes back if the still hand parked it), and the trails are
        // parked again once it has landed.
        guard notes.deckOut else { return }
        for trail in Array(notes.trails.values) + Array(notes.worldTrails.values)
        where trail.components[NoteTrailComponent.self]?.target === holder {
            trail.isEnabled = true
        }
        scheduleIdleDeckTrailPark(after: delay + duration)
    }

    /// One highlight crossing a deck card. Internal rather than private: V3-4 §1's spark flight plays it
    /// from `HologramController.swift` when the sparks land on the card the key raised.
    func sweepDeckGlint(on holder: Entity) {
        let width = NoteFanLayout.cardSize.x, height = NoteFanLayout.cardSize.y
        let quad = ModelEntity(mesh: FXMeshes.skewedQuad(width: width * 0.22, height: height, skew: height * 0.22),
                               materials: [FXMaterials.glow(fx.glint, tint: HologramController.noteDustGold, opacity: 1)])
        quad.name = "deck.glint"
        let reach = width * 0.30
        let from = SIMD3<Float>(-reach, 0, 0.0016), to = SIMD3<Float>(reach, 0, 0.0016)
        quad.position = from
        quad.components.set(OpacityComponent(opacity: 0))
        quad.components.set(GlintSweepComponent(from: from, to: to, duration: 0.4, peakOpacity: 0.5))
        holder.addChild(quad)
    }

    private func burstDeckDust(at position: SIMD3<Float>) {
        let entity = Entity()
        entity.name = "burst.deck"
        entity.position = position
        var emitter = HologramController.noteTrailEmitter(sprite: fx.sparkle)
        emitter.burstCount = 20
        emitter.burst()
        PerfCensus.noteBurst(20, life: emitter.mainEmitter.lifeSpan)
        entity.components.set(emitter)
        notes.group.addChild(entity)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            entity.removeFromParent()
        }
    }
}
