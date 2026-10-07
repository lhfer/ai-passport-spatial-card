import RealityKit
import SwiftUI

/// The whole app: runs image tracking while visible and mirrors `AppModel` / `CardTracker` into the hologram.
/// Tapping the card throws the note fan out or takes it back (see `tapCard`); the coins on the desk arc open
/// the worlds.
struct ImmersiveView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.openURL) private var openURL
    @Environment(\.dismissImmersiveSpace) private var dismissImmersiveSpace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.scenePhase) private var scenePhase
    /// Created once per space open, inside the RealityView's make closure. (A `@State` initialised with
    /// `HologramController()` ran the init — 9 CoreImage textures, 3 pixel sets, audio preload — on every
    /// evaluation of the App body, i.e. on each immersion-style flip, and threw the result away.)
    @State private var controller: HologramController?
    @State private var isExiting = false

    var body: some View {
        RealityView { content, attachments in
            // v4 B1: the hero card unless `--v3-card` (the shoot's insurance: v3's box scan and card, exactly).
            let controller = self.controller ?? HologramController(v4Card: !appModel.v3Card)
            self.controller = controller
            content.add(controller.root)
            appModel.controller = controller
            // The mini card is the one thing that reads the head every frame (its lazy follow); everything else
            // works off the poses the gate accepted.
            controller.headPoseProvider = { [appModel] in appModel.headPose }
            // V3-1b §7/§8: the follower's velocity lead, and the `Σ lag=` probe the tracker samples every tick.
            controller.carryLead = appModel.carryLead
            appModel.tracker.renderedPosition = { [weak controller] in controller?.renderedPosition }
            // V3-2b B2: `--deck-dynamics`, and the `Σ deckLag=` probe on the same tick.
            controller.deckDynamics = appModel.deckDynamics
            appModel.tracker.deckLag = { [weak controller] in controller?.deckLagNow }
            controller.litLayers = appModel.overlayLit
            if P0Probes.isEnabled {
                // Dev only (`--p0`): the white probe orb was mistaken for a world button in user testing.
                content.add(appModel.probes.rig)
                controller.addDeskButton(name: P0Probes.orbName, tint: UIColor(white: 0.92, alpha: 1), angleDegrees: -72)
            }
            if let p0Label = attachments.entity(for: P0Probes.labelAttachmentID) {
                appModel.probes.attachLabel(p0Label)
            }
            if let p0Sample = attachments.entity(for: P0Probes.swiftUIAttachmentID) {
                appModel.probes.attachSwiftUI(p0Sample)
            }
            if let card = attachments.entity(for: HologramController.cardAttachmentID) {
                controller.attachCard(card)
            }
            // V3-3 C2: the same card, twice more, on two clear sheets 8 mm and 4 mm off the plate.
            if let avatar = attachments.entity(for: HologramController.cardAvatarAttachmentID) {
                controller.attachCardAvatar(avatar)
            }
            if let tags = attachments.entity(for: HologramController.cardTagsAttachmentID) {
                controller.attachCardTags(tags)
            }
            // V3-3 C3: …and the card's back, behind the slab.
            if let back = attachments.entity(for: HologramController.cardBackAttachmentID) {
                controller.attachCardBack(back)
            }
            if let hint = attachments.entity(for: HologramController.hintAttachmentID) {
                controller.attachHint(hint)
            }
            if let exitChip = attachments.entity(for: HologramController.exitChipAttachmentID) {
                controller.attachExitChip(exitChip)
            }
            if let notesChip = attachments.entity(for: HologramController.notesChipAttachmentID) {
                controller.attachNotesChip(notesChip)
            }
            if let ringHint = attachments.entity(for: HologramController.ringHintAttachmentID) {
                controller.attachDeskRingHint(ringHint)
            }
            // v4 B3: 「OK · 唤醒」 beside the keys after a collapse, and 「按 OK 回到桌面」 under the mini card.
            if let wakeHint = attachments.entity(for: HologramController.wakeHintAttachmentID) {
                controller.attachWakeHint(wakeHint)
            }
            if let miniHint = attachments.entity(for: HologramController.miniHintAttachmentID) {
                controller.attachMiniHint(miniHint)
            }
            // The note fan (工作包 D): the card's own steady state is its cue, and its choreography tells the
            // world engine to keep its 4 s prebuild out of the way.
            controller.notes.onIdle = { [appModel] in appModel.noteCardSettled() }
            controller.onWorldCardRaised = { [appModel] id in appModel.setRaisedWorldCard(id) }
            // V3-2a H5: the deck's half of the put-down bloom, 0.35 s into the settle.
            controller.onSettleBloom = { [appModel, weak controller] in
                controller?.morphDeckToGallery(allIDs: appModel.recentNotes.map(\.id))
            }
            // …and its anticipation, from the desk gate's "flat but not yet still".
            appModel.tracker.onDeskCandidate = { [weak controller] on in controller?.setDeckAnticipation(on) }
            // 工作包 A 设备联动: the relocation `tick` belongs to the landing, which only the follower knows about.
            controller.onRelocationLanded = { [appModel] in appModel.noteCardLanded() }
            // V3-2a2 S1 / S2: the recognition scan's two beats — the real LCD's own bar, 60 ms of BLE
            // before the virtual band reaches the screen area, and the convergence the device answers.
            controller.onScanGlow = { [appModel] in
                appModel.device.sendGlow(reason: "box scan")
            }
            controller.onScanConverged = { [appModel] in appModel.noteScanConverged() }
            controller.onScanEntranceStarted = { [appModel] in appModel.noteScanEntranceStarted() }
            controller.notes.onActivity = { [appModel] in appModel.worlds.noteDeskActivity() }
            // Worlds: engine root (shell, environments, exit button) in world space; coins on the desk arc.
            let worlds = appModel.worlds
            content.add(worlds.root)
            // V3-5 §5: the two subtrees `[perf] scene:` counts. Both are in the scene from here on.
            PerfLog.sceneRoots = { [weak controller, weak worlds] in
                [controller?.root, worlds?.root].compactMap { $0 }
            }
            // v4 B5 §1: every window says which `cmd perf` state it was measured in.
            PerfLog.windowNote = { [weak controller] in controller?.perfWindowNote() }
            // v4 B5 §2: the launch's choices for the look switches.
            controller.perf.launchQuickFade = appModel.launchQuickFade
            controller.perf.launchHoldDim = appModel.launchHoldDim
            controller.perf.launchLiteMotes = appModel.launchLiteMotes
            if appModel.launchLiteMotes { controller.applyResidentMotes() }
            worlds.meshAnchorsProvider = { [tracker = appModel.tracker] in tracker.meshAnchors }
            for (index, descriptor) in worlds.descriptors.enumerated() {
                if let coin = attachments.entity(for: WorldEngine.coinAttachmentID(descriptor.id)) {
                    controller.attachWorldCoin(coin, index: index, count: worlds.descriptors.count)
                }
                if let label = attachments.entity(for: WorldEngine.nameLabelAttachmentID(descriptor.id)) {
                    controller.attachWorldNameLabel(label, index: index)
                }
            }
            if let exitButton = attachments.entity(for: WorldEngine.exitAttachmentID) {
                worlds.exitHolder.addChild(exitButton)
            }
            if let title = attachments.entity(for: WorldEngine.titleAttachmentID) {
                worlds.titleHolder.addChild(title)
            }
            controller.applyLook()
            // **v4 B1.** The recognition's first beat asks the real LCD for its own burst (`--lcd-burst flash|sweep`).
            controller.onRecognitionBurst = { [appModel] in
                V4LCDBurst.send(on: appModel.device, kind: appModel.lcdBurstKind)
            }
            // v4 B1 follow-up: a hand-over hold is desk activity (the world prebuild waits for the desk to be quiet).
            controller.onDeskBusy = { [appModel] in appModel.worlds.noteDeskActivity() }
            // v4 B2 §3.3: the pick-up fold applies LossClock's grab rule per hold (the hand, the radius, the clock), and
            // its app half is the fan's.
            controller.pickupFoldEnabled = appModel.pickupFold
            controller.lossStateProvider = { [tracker = appModel.tracker] in
                let hand = tracker.nearestHand
                return (handDistance: hand?.distance, handHeight: hand?.height, radius: tracker.bridgeAttachRadius,
                        now: tracker.clock)
            }
            controller.onPickupFold = { [appModel] folded in appModel.notePickupFold(folded) }
            controller.recognitionPlaceOverride = appModel.recognitionPlaceOverride
            // v4 B4 §1: what decides, at `acquiring`, whether the recognition flies the desk's path or the hand's.
            controller.recognitionStateProvider = { [tracker = appModel.tracker] in
                // The raw screen pose: at a first detection the desk gate's prior is the desk, so `latestPose` is still
                // snapped flat for its first 0.15 s while the passport is at 60° in the hand.
                (tilt: tracker.objectTilt, deskGateOnDesk: tracker.deskGateOnDesk,
                 device: tracker.latestRawScreenPose ?? tracker.latestPose)
            }
            // …and the hero card + the ribbon are built here (0.66–0.77 s in the simulator: textures and material
            // programs, alongside the A1 preload), before `update` applies the first presence event — the tracker
            // queues its transitions until then.
            if !appModel.v3Card, controller.v4 == nil {
                let integration = await V4CardIntegration.make(.init(
                    card: appModel.card, followers: appModel.stats.followers, screen: controller.footprint,
                    ribbonWidth: appModel.ribbonWidthMM.map { $0 / 1000 }, dustScale: appModel.ribbonDust,
                    screenBurst: appModel.screenBurst))
                controller.installV4(integration)
                controller.v4?.freezeAt = appModel.v4FreezeAt
                controller.v4?.freezeRun = appModel.v4FreezeRun
                controller.v4?.hitchThreshold = appModel.v4HitchMS / 1000
            }
            if appModel.deviceProxy { controller.installDeviceProxy() }
            if LabLaunch.night, appModel.deviceProxy { controller.installNightDome() }
        } update: { _, attachments in
            // Re-runs whenever any observable state read below changes.
            guard let controller else { return }
            let tracker = appModel.tracker
            let worlds = appModel.worlds
            // Notes arrive from the hub seconds after the space opened, so their attachments are made long
            // after the closure above ran: this is the only way they ever reach the fan. Before the world
            // guard, because a list that lands while the wearer is inside a world must still be mounted when
            // they come back. Idempotent — everything it does is an identity check.
            controller.syncNoteAttachments(ids: appModel.recentNotes.map(\.id)) { attachments.entity(for: $0) }
            // V3-2a H3: the two world cards at the ends of the hand deck.
            controller.syncWorldCardAttachments(ids: appModel.worlds.descriptors.map(\.id)) { attachments.entity(for: $0) }
            controller.revealKind = appModel.revealOverride ?? .inkExtraction
            // The highlighted world previews its colour on the frame (0.35); an active / just-left world owns it fully.
            // A world page on the hand card previews that world's colour on the rim without touching the
            // desk carousel's highlight — which is what OK's precedence reads (v3 H2 §4).
            if let handTint = appModel.handPageTint {
                controller.setWorldTint(handTint, strength: 0.5)
            } else {
                controller.setWorldTint(worlds.hologramTint, strength: worlds.hologramTintStrength)
            }
            // Desk controls are inert inside a world; the card is not — as the mini card it is the exit.
            controller.setInteractive(desk: !worlds.isActive, card: !worlds.isActive || appModel.cardMode == .mini)
            controller.setFaceUser(appModel.faceUser)
            // v3 H2: which carry the card plays (the object source puts it *on* the device) and which way it
            // faces while it is there.
            controller.usesHandForm = appModel.usesHandForm
            controller.handFacing = appModel.handFacing
            controller.handForm = appModel.handForm
            controller.handScale = appModel.handScale
            controller.wellLevelHand = appModel.wellLevelHand
            controller.footprintCheck = appModel.footprintCheck
            // V3-3 C1 / C2 / C3 (plan §4 E14): the rim's Fresnel, the three parallax layers' depth and
            // whether the card has a back at all.
            controller.fresnelEnabled = appModel.fresnelEnabled
            controller.parallaxEnabled = appModel.parallaxEnabled
            controller.backFaceEnabled = appModel.backFaceEnabled
            controller.boxScanEnabled = appModel.boxScanEnabled
            controller.buttonGlintEnabled = appModel.buttonGlintEnabled
            controller.buttonFX = appModel.buttonFX
            controller.hingeGlowEnabled = appModel.hingeGlow
            controller.sleepFXEnabled = appModel.sleepFX
            controller.raiseFlourish = appModel.raiseFlourish
            // V3-4 §8: the folded card asks the tracker how near the wearer's hands are, four times a second.
            if controller.nearestHandDistance == nil {
                controller.nearestHandDistance = { [weak tracker] in tracker?.nearestHandDistance }
            }
            if controller.buttonEdge != appModel.buttonEdge { controller.buttonEdge = appModel.buttonEdge }
            // V3-2a H0: the audited prism is the object anchor's own box, so `--fake-box scan` and any
            // future device measure themselves. V3-2a2 S1 takes the third dimension too: the recognition
            // wireframe is the box, not just its footprint.
            if let frame = tracker.screenFrame {
                let box = frame.screenFootprint
                controller.setDeviceFootprint(width: box.x, length: box.y, thickness: frame.screenThickness)
            }
            controller.setTheme(tracker.currentTheme)
            controller.litLayers = appModel.overlayLit
            // v4 B1 §3: the hero card's count is the live one — a change rolls only the digits that change.
            controller.setHeroFollowers(appModel.stats.followers)
            // Inside a world the hologram is the world's business: nothing is forwarded until the world releases the
            // desk (exit progress ≥ 0.8, so the return glint is on the card while the last of the black lifts).
            // Picking the card up inside a world no longer exits it (persistence rule 5): the exits are the device's
            // long OK, the exit button and the Digital Crown.
            // A hint capsule that was up when the world started must not float over it.
            if worlds.isActive { controller.setHint(visible: false, devicePose: nil) }
            guard !worlds.isActive || worlds.hologramReleased else { return }
            _ = tracker.presence
            // Same-presence events (`.search`) change nothing else observable; without this the closure would not
            // re-run and the event would wait in the gate's FIFO until the thaw drained it.
            _ = tracker.gateEventCount
            if appModel.previewMode {
                controller.applyPreviewPose(surfaceHeight: appModel.previewSurfaceHeight, distance: appModel.previewDistance)
                while let event = tracker.takeTransition() {
                    // V3-2a2 S1: the recognition scan may be holding this entrance back until its
                    // convergence beat — the app's half of the event waits with it.
                    let held = controller.apply(presence: event.presence, transition: event.transition, hideKind: event.hideKind,
                                                firstAcquire: event.firstAcquire, resumeFromWorld: event.resumeFromWorld)
                    if held {
                        appModel.holdCardEvent(presence: event.presence, transition: event.transition)
                    } else {
                        appModel.noteCard(presence: event.presence, transition: event.transition)
                    }
                    worlds.noteDeskActivity()
                }
                controller.setHint(visible: false, devicePose: nil)
            } else {
                controller.leavePreview()
                while let event = tracker.takeTransition() {
                    // V3-2a2 S1: the recognition scan may be holding this entrance back until its
                    // convergence beat — the app's half of the event waits with it.
                    let held = controller.apply(presence: event.presence, transition: event.transition, hideKind: event.hideKind,
                                                firstAcquire: event.firstAcquire, resumeFromWorld: event.resumeFromWorld)
                    if held {
                        appModel.holdCardEvent(presence: event.presence, transition: event.transition)
                    } else {
                        appModel.noteCard(presence: event.presence, transition: event.transition)
                    }
                    worlds.noteDeskActivity()
                }
                if let pose = tracker.latestPose {
                    // 工作包 G2: the dead zone depends on which tracker produced this pose (the object source is
                    // the noisy one), so the controller is told.
                    controller.apply(pose: pose, source: tracker.activeSource, velocity: tracker.rawVelocity)
                    // v3 H2 §7: the card is folded away and there is nothing on screen to fold — leave the
                    // socket light burning on the device, because OK is the only way back.
                    if tracker.isDismissed { controller.armDismissedSocket() }
                    if let surfaceY = tracker.surfaceY {
                        controller.applySurface(under: pose, surfaceY: surfaceY)
                    }
                }
                controller.setHint(visible: tracker.status.showsHint && !appModel.directorMode && !worlds.isActive, devicePose: tracker.hintDevicePose)
            }
        } attachments: {
            // **V3-3 C2 / plan §4 E14b.** The card's face is three attachments now, and `CardLayers.sheets`
            // is what says so: the *same* view, the *same* `mode` and the *same* `page`, three times over —
            // so a mode change (`.full` / `.mini` / `.hand`) cross-fades all three together and the sheets
            // can never show two different cards. Only the plate is tappable; a sheet in front of it would
            // catch every pinch meant for the card.
            // **v4 B1 §3**: the hero card's type is its own (A4's `HeroCardFaceView`, mounted in code); the three v3
            // sheets exist only on the `--v3-card` path.
            ForEach(appModel.v3Card ? CardLayers.sheets(mode: appModel.cardMode, parallax: appModel.parallaxEnabled) : [],
                    id: \.id) { sheet in
                Attachment(id: sheet.id) {
                    HologramCardView(card: appModel.card, stats: appModel.stats, delta: appModel.deltaBadge,
                                     accent: cardAccent, glass: appModel.cardGlass, mode: sheet.mode,
                                     page: appModel.handPageContent, layer: sheet.layer, parallax: sheet.parallax,
                                     forcesMiniHint: appModel.forceMiniHint, onTap: tapCard)
                        // Inside a world every desk control is inert — except the mini card, which is the way out.
                        .allowsHitTesting(sheet.tappable && (!appModel.worlds.isActive || appModel.cardMode == .mini))
                }
            }
            // **V3-3 C3 / plan §4 E14c.** The fourth attachment: the other side of the plate.
            Attachment(id: HologramController.cardBackAttachmentID) {
                if appModel.v3Card {
                    HologramCardBackView(card: appModel.card, accent: cardAccent)
                } else {
                    // v4 B1: the back of the portrait hero card.
                    HologramCardBackView(card: appModel.card, accent: cardAccent,
                                         size: V4.HeroCardLayout(shape: .portrait).size,
                                         cornerRadius: V4.HeroCardLayout(shape: .portrait).cornerRadius)
                }
            }
            Attachment(id: HologramController.hintAttachmentID) {
                HintLabel(status: appModel.tracker.status, showsExit: appModel.tracker.status.showsExit,
                          onExit: { exitSpace() }, onOpenSettings: { appModel.tracker.openSettings() })
            }
            Attachment(id: HologramController.exitChipAttachmentID) {
                ExitChipView(enabled: !appModel.worlds.isActive) { exitSpace() }
                    .allowsHitTesting(!appModel.worlds.isActive)
            }
            // 工作包 D: the ten covers, the panel one of them grows into, and the chip that stands in for the
            // device's long OK when nothing is linked.
            ForEach(appModel.recentNotes) { note in
                Attachment(id: HologramController.noteAttachmentID(note.id)) {
                    // v4 B2 §2: the desk ring's highlight is the card's gold rim.
                    NoteCardView(note: note, coverURL: appModel.coverURL(for: note),
                                 highlighted: appModel.deskRingNoteID == note.id,
                                 base: appModel.noteBase) { appModel.tapNote(note.id) }
                        .allowsHitTesting(!appModel.worlds.isActive && appModel.noteFan.isInteractive)
                }
            }
            Attachment(id: HologramController.notePreviewAttachmentID) {
                if let note = appModel.previewedNote {
                    NotePreviewView(note: note, coverURL: appModel.coverURL(for: note),
                                    onOpen: { if let url = appModel.openNote(note) { openURL(url) } },
                                    onClose: { appModel.closePreview(via: $0) },
                                    onDisappear: { appModel.notePreviewDisappeared() })
                        .allowsHitTesting(!appModel.worlds.isActive)
                }
            }
            // v4 B2 §2: 「▲▼ 选择 · OK 打开」 beside the device, the first time a gallery stands on the desk.
            Attachment(id: HologramController.ringHintAttachmentID) {
                DeskRingHintView()
            }
            Attachment(id: HologramController.wakeHintAttachmentID) {
                WakeHintView()
            }
            Attachment(id: HologramController.miniHintAttachmentID) {
                MiniCardHintView()
            }
            Attachment(id: HologramController.notesChipAttachmentID) {
                if appModel.showsNotesChip {
                    NotesChipView(count: appModel.recentNotes.count, isOut: appModel.noteFan != .collapsed) {
                        appModel.toggleNotesFan(via: "notes chip")
                    }
                    .allowsHitTesting(!appModel.worlds.isActive)
                }
            }
            // V3-2a H3: the same two worlds as **cards** at the ends of the hand deck.
            ForEach(appModel.worlds.descriptors) { descriptor in
                Attachment(id: HologramController.worldCardAttachmentID(descriptor.id)) {
                    WorldCardView(descriptor: descriptor, raised: appModel.raisedWorldCard == descriptor.id,
                                  base: appModel.noteBase)
                }
            }
            ForEach(appModel.worlds.descriptors) { descriptor in
                Attachment(id: WorldEngine.coinAttachmentID(descriptor.id)) {
                    // Press = carousel highlight (coin springs, name label, frame tint); release 140 ms later = enter.
                    WorldCoinView(descriptor: descriptor, enabled: !appModel.worlds.isActive,
                                  onPress: { appModel.worlds.highlight(id: descriptor.id) },
                                  onRelease: { appModel.worlds.enterHighlighted() })
                    .allowsHitTesting(!appModel.worlds.isActive)
                }
            }
            ForEach(appModel.worlds.descriptors) { descriptor in
                Attachment(id: WorldEngine.nameLabelAttachmentID(descriptor.id)) {
                    WorldNameLabel(descriptor: descriptor, selected: appModel.worlds.highlightedDescriptor?.id == descriptor.id)
                }
            }
            Attachment(id: WorldEngine.exitAttachmentID) {
                if appModel.worlds.showsExitButton, let label = appModel.worlds.exitLabel,
                   let id = appModel.worlds.state.worldID, let d = appModel.worlds.descriptor(id) {
                    WorldExitButton(label: label, tint: d.primaryColor) { appModel.exitWorld() }
                }
            }
            Attachment(id: WorldEngine.titleAttachmentID) {
                NebulaTitleView(followers: appModel.worlds.title.followers, caption: appModel.worlds.title.caption,
                                tint: appModel.worlds.state.worldID.flatMap { appModel.worlds.descriptor($0) }?.accentColor ?? .white)
            }
            Attachment(id: P0Probes.labelAttachmentID) {
                P0Label(text: appModel.probes.label)
            }
            Attachment(id: P0Probes.swiftUIAttachmentID) {
                P0SwiftUISample()
            }
        }
        .preferredSurroundingsEffect(surroundingsEffect)
        .onChange(of: appModel.wantsFullImmersion) { _, wantsFull in
            // Only once the shell is opaque (entry) / while it is still opaque (exit), so the switch is never seen.
            appModel.immersionStyle = wantsFull ? .full : .mixed
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Back from Safari / Settings: a denied or failed session restarts, the BLE link rescans.
            appModel.tracker.retryIfNeeded()
            appModel.device.rescan()
        }
        .gesture(
            SpatialTapGesture()
                .targetedToAnyEntity()
                .onEnded { value in
                    // The mini card is routed *before* the world guard: inside a world a pinch on the card is
                    // how the wearer comes back (the RealityKit panel catches what the SwiftUI card does not).
                    if appModel.cardMode == .mini, value.entity.name == HologramController.panelEntityName {
                        tapCard()
                        return
                    }
                    // Inside a world only the world's own controls may react; desk entities are inert.
                    guard !appModel.worlds.isActive else { return }
                    if value.entity.name == P0Probes.orbName {
                        appModel.probes.advance(devicePose: appModel.tracker.latestDevicePose)
                    } else if value.entity.name == ProjectorRig.baseName {
                        // The base ring is the card's off switch: fold it into the device (工作包 A 显式隐藏/显示).
                        //
                        // **V3-4 §4.** Both of these sit *on the hardware*, and to visionOS a thumb on the side
                        // key — or a hand closing round the passport to pick it up — is "looking at the device
                        // and pinching". Two headset logs hold four `dismiss` / `show` pairs with no `button`
                        // line anywhere near them. They are off by default now (`--device-taps on` puts them
                        // back for a demo with no hardware); the line is printed either way so a stray tap is
                        // visible in the log rather than being inferred from a missing button press.
                        print("[tap] base ring → dismiss")
                        guard appModel.deviceTaps else { return }
                        controller?.playDismissFeedback()
                        appModel.collapseCard(reason: "base ring tap")
                    } else if value.entity.name == RegistrationOverlay.socketName {
                        // … and the socket light left burning on the screen is the way back.
                        print("[tap] socket → show")
                        guard appModel.deviceTaps else { return }
                        controller?.playShowFeedback()
                        appModel.requestShowCard()
                    } else if value.entity.name == HologramController.panelEntityName, appModel.tracker.presence == .expanded {
                        // Taps on the glass content are handled by the SwiftUI card; this catches the RealityKit panel.
                        tapCard()
                    }
                }
        )
        .task {
            if let seconds = appModel.debugExitAfter {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    exitSpace()
                }
            }
            if let seconds = appModel.debugAbortWorldAfter {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    // The Digital Crown path, with the space left open: `abort()` is exactly what
                    // `onDisappear` calls, so the instant restore can be watched instead of guessed at.
                    print("[world] --abort-world-after \(seconds): aborting in place")
                    appModel.worlds.abort()
                }
            }
            if let seconds = appModel.replayAfter {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(seconds))
                    print("[gate] --replay-after \(seconds)")
                    appModel.tracker.requestReplay()
                }
            }
            if let delta = appModel.celebrateDelta {
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(appModel.celebrateAfter))
                    appModel.celebrate(delta: delta, followers: nil, fromDevice: false)
                }
            }
            if let every = appModel.celebrateEvery, every > 0 {
                Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(every))
                        appModel.celebrate(delta: 1, followers: nil, fromDevice: false)
                    }
                }
            }
            if let path = appModel.fakeTrackPath, !appModel.previewMode {
                // Scripted image poses instead of ARKit: same gate, same ingest point, same `apply(pose:)`.
                appModel.tracker.startFakeTrack(scriptURL: ScriptFile.url(path))
                return
            }
            if appModel.previewMode {
                try? await Task.sleep(for: .milliseconds(Int(appModel.previewDelay * 1000)))
                // The virtual card is "observed" by the tracker's preview loop: same gate, same transitions.
                let pose = Transform(translation: [0, appModel.previewSurfaceHeight, -appModel.previewDistance]).matrix
                appModel.tracker.startPreview(pose: pose, reacquireDelay: appModel.previewReacquireDelay)
                if let world = appModel.previewWorld {
                    try? await Task.sleep(for: .milliseconds(3300))
                    if appModel.worlds.descriptor(world) == nil {
                        print("[world] --world \(world): not a shipped world (add --all-worlds)")
                    }
                    // Let the desk prebuild the world once the reveal has settled, so the entry is a re-parent
                    // (bounded wait: the slow path still works, it just spikes). The window is 12 s because the
                    // note fan's own `noteDeskActivity()` (工作包 D) pushes the desk's idle timer ~4 s past the
                    // fan-out — on the headset the wearer presses OK long after that, but this harness enters
                    // 3.3 s after the reveal and would otherwise race the prebuild and pay for it at entry.
                    var waited = 0
                    while !appModel.worlds.isPrebuilt(world), waited < 120 {
                        try? await Task.sleep(for: .milliseconds(100))
                        waited += 1
                    }
                    // The two beats of the device: highlight (coin, label, tint), then OK.
                    appModel.worlds.highlight(id: world)
                    try? await Task.sleep(for: .milliseconds(600))
                    appModel.worlds.enterHighlighted()
                    // Stay is counted from the moment the world is fully inside (entries vary with room size).
                    for _ in 0..<600 {
                        if case .inside = appModel.worlds.state { break }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                    try? await Task.sleep(for: .seconds(appModel.previewWorldStay))
                    appModel.exitWorld()
                }
                return
            }
            await appModel.tracker.start()
        }
        .onAppear {
            appModel.immersiveSpaceIsOpen = true
            appModel.userDismissedSpace = false
            WorldKit.preheat()
            appModel.worlds.preloadAssets()
            if appModel.previewMode, appModel.meshAtStart {
                // The simulator has no scene reconstruction, so a synthetic room stands in for it — but only when
                // this run would have had a room mesh at all. By default v2 starts no mesh provider, and building
                // the fake room anyway would make the simulator disagree with the headset about the one thing this
                // milestone changes. `AppModel.onNeedsRoomMesh` builds it on demand, like the real provider.
                appModel.worlds.fission.prepareSynthetic(center: [0, 0, -0.4], floorY: appModel.previewSurfaceHeight - 0.72)
            }
            appModel.device.start()
        }
        .onDisappear {
            appModel.immersiveSpaceIsOpen = false
            appModel.handleFan(.spaceDismissed)
            appModel.probes.stop()
            appModel.tracker.stop()
            appModel.worlds.abort()
            appModel.controller = nil
        }
    }

    /// The card's accent: the desk look's near-white blue, warmed toward the highlighted / active world's
    /// colour. It is the only colour a world puts on the card face (a 40 pt gradient along the bottom edge).
    private var cardAccent: Color {
        let look = HologramLook.desk
        // Blended from the look's own tint, not from `rimColor`'s white: with no world the accent would be pure
        // white, and the "+N" badge is a capsule of it on a white card.
        guard let world = appModel.worlds.hologramTint else { return look.accentColor }
        return Color(uiColor: look.tint.mixed(with: world.withAlphaComponent(1),
                                              by: CGFloat(max(0, min(1, appModel.worlds.hologramTintStrength)))))
    }

    /// Passthrough tint: the P0 probe's ramp wins over the app's own (worlds) tint.
    private var surroundingsEffect: SurroundingsEffect? {
        if let tint = appModel.probes.surroundingsTint ?? appModel.surroundingsTint {
            return .colorMultiply(tint)
        }
        return nil
    }

    /// The one tap the card has: on the desk it throws the note fan out (or takes it back, or closes an open
    /// preview) — what a long press on the device's OK button did before v4 B3 (long OK collapses the card now, and a
    /// pinch must not). As the in-world mini card it leaves the world.
    ///
    /// It used to open the profile in Safari, which takes the immersive space away: on the first on-device trial
    /// that happened by accident, and losing the whole session is not something a stray tap should be able to do.
    /// The one deliberate way out to the web is the 「在小红书打开」 button inside a note's preview.
    private func tapCard() {
        if appModel.cardMode == .mini {
            appModel.exitWorld()
            return
        }
        appModel.toggleNotesFan(via: "card tap")
    }

    /// 退出 from the hint capsule or the desk chip: keep a scene alive (the return window) so one tap brings the
    /// space back, then dismiss. `userDismissedSpace` stops the window from reopening the space on its own.
    private func exitSpace() {
        guard !isExiting else { return }
        isExiting = true
        appModel.userDismissedSpace = true
        openWindow(id: AppModel.returnWindowID)
        Task { @MainActor in
            await dismissImmersiveSpace()
            print("[exit] space dismissed by the user; return window is up")
            isExiting = false
        }
    }
}

/// Small glass chip in the coin family that leaves the space.
private struct ExitChipView: View {
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .semibold))
            Text("退出")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: 46, height: 46)
        .glassBackgroundEffect(in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .contentShape(Circle())
        .hoverEffect()
        .opacity(enabled ? 1 : 0.35)
        .onTapGesture { if enabled { onTap() } }
    }
}

/// The only "UI" outside the hologram: a one-line status hint floating in front of the wearer.
private struct HintLabel: View {
    let status: CardTracker.Status
    var showsExit = false
    var onExit: () -> Void = {}
    var onOpenSettings: () -> Void = {}

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Label(status.label, systemImage: symbol)
                    .font(.system(size: 17, weight: .medium))
                if status == .authorizationDenied {
                    Divider().frame(height: 20)
                    Button(action: onOpenSettings) {
                        Label("打开设置", systemImage: "gear")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Capsule())
                    .hoverEffect()
                }
                if showsExit {
                    Divider().frame(height: 20)
                    Button(action: onExit) {
                        Label("退出", systemImage: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Capsule())
                    .hoverEffect()
                }
            }
            if showsExit {
                Text(status == .authorizationDenied ? "允许「周围环境感知」后会自动重新开始识别" : "按数码旋钮也可退出")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var symbol: String {
        switch status {
        case .searching, .starting: return "viewfinder"
        case .notFlat: return "rectangle.portrait.rotate"
        case .moving: return "hand.raised"
        case .lost: return "questionmark.circle"
        case .authorizationDenied, .unsupported, .missingReferenceImage, .failed: return "exclamationmark.triangle"
        default: return "circle"
        }
    }
}
