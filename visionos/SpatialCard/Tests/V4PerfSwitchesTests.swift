import XCTest

/// **v4 B4 §3.5** — `cmd perf`: one string of `layer=on|off` words that **sets** a state (the same command over BLE and the
/// Hub's WebSocket is one scene), `reset`, `all=…`, `material=…`, and the defaults (everything drawn, the prebuilt worlds
/// out of the tree since B4).
final class V4PerfSwitchesTests: XCTestCase {
    typealias Switches = V4.PerfSwitches
    typealias Layer = V4.PerfLayer

    func testTheDefaultsDrawEverythingAndKeepTheWorldsOutOfTheTree() {
        let s = Switches()
        for layer in Layer.allCases where layer != .worlds && layer != .galleryGlass { XCTAssertTrue(s.isOn(layer), layer.rawValue) }
        XCTAssertFalse(s.isOn(.worlds))
        XCTAssertFalse(s.isOn(.galleryGlass), "10-06: the note cards stand on the frost by default")
        XCTAssertNil(s.material)
        XCTAssertEqual(s.summary, "defaults")
    }

    func testAStringOfSwitchesSetsTheirStates() {
        var s = Switches()
        let c = Switches.parse("cones=off, well=off gallery-glass=on material=placeholder worlds=on")
        XCTAssertTrue(c.unknown.isEmpty)
        s.apply(c)
        XCTAssertFalse(s.isOn(.cones))
        XCTAssertFalse(s.isOn(.well))
        XCTAssertTrue(s.isOn(.galleryGlass))
        XCTAssertTrue(s.isOn(.gallery), "the gallery itself is not the glass")
        XCTAssertTrue(s.isOn(.worlds))
        XCTAssertEqual(s.material, .placeholder)
        XCTAssertEqual(s.summary, "worlds in the tree · cones off · well off · gallery-glass on · material placeholder")
    }

    /// The same command twice (BLE + the Hub's WebSocket) is the same state — it sets, it never toggles.
    func testTheSameCommandTwiceIsTheSameState() {
        var once = Switches(), twice = Switches()
        let c = Switches.parse("cones=off trails=off")
        once.apply(c)
        twice.apply(c)
        twice.apply(c)
        XCTAssertEqual(once, twice)
        twice.apply(Switches.parse("cones=on"))
        XCTAssertTrue(twice.isOn(.cones))
        twice.apply(Switches.parse("cones=on"))
        XCTAssertTrue(twice.isOn(.cones), "on is on, however often")
    }

    func testResetAllAndOrder() {
        var s = Switches()
        s.apply(Switches.parse("all=off desk=on"))
        for layer in Layer.allCases where layer != .desk { XCTAssertFalse(s.isOn(layer), layer.rawValue) }
        XCTAssertTrue(s.isOn(.desk), "all first, then the named layers")
        s.apply(Switches.parse("material=blur"))
        s.apply(Switches.parse("reset"))
        XCTAssertEqual(s, Switches(), "reset is the defaults, material included")
        s.apply(Switches.parse("all=on"))
        XCTAssertTrue(s.isOn(.worlds), "all=on puts the worlds back in the tree too")
    }

    func testMeasureOnlyAndUnknownWords() {
        XCTAssertTrue(Switches.parse(nil).isMeasureOnly)
        XCTAssertTrue(Switches.parse("").isMeasureOnly)
        XCTAssertTrue(Switches.parse("status").isMeasureOnly)
        let c = Switches.parse("cones=maybe warp=off fog material=chrome glass=off")
        XCTAssertEqual(c.unknown, ["cones=maybe", "warp=off", "fog", "material=chrome"])
        XCTAssertEqual(c.set[.galleryGlass], false, "aliases: glass = gallery-glass")
        XCTAssertNil(c.material)
    }

    // MARK: - v4 B5 §1: the settle, the rehearsal

    /// `rehearse=fanout` is an action (not a state), `wait=` is how long the switch settles; both parse with their aliases,
    /// and nonsense is reported, not guessed at.
    func testRehearseAndWaitParse() {
        let c = Switches.parse("cones=off rehearse=fanout wait=3")
        XCTAssertTrue(c.unknown.isEmpty)
        XCTAssertEqual(c.rehearse, .fanout)
        XCTAssertEqual(c.wait, 3)
        XCTAssertEqual(c.set[.cones], false)
        XCTAssertFalse(c.isMeasureOnly)
        XCTAssertEqual(Switches.parse("rehearse=fan").rehearse, .fanout)
        XCTAssertEqual(Switches.parse("rehearsal=fan-out").rehearse, .fanout)
        XCTAssertFalse(Switches.parse("rehearse=fanout").isMeasureOnly, "a rehearsal is something to do")
        XCTAssertEqual(Switches.parse("settle=1.5s").wait, 1.5)
        XCTAssertEqual(Switches.parse("wait=99").wait, Switches.maxSettle, "clamped to 10 s")
        XCTAssertEqual(Switches.parse("wait=0").wait, 0)
        let bad = Switches.parse("rehearse=pickup wait=soon wait=-1")
        XCTAssertEqual(bad.unknown, ["rehearse=pickup", "wait=soon", "wait=-1"])
        XCTAssertNil(bad.rehearse)
        XCTAssertNil(bad.wait)
        XCTAssertTrue(Switches.parse("wait=4").isMeasureOnly, "a wait alone changes nothing")
    }

    /// The rehearsal and the wait never change the state: the same command twice is the same scene.
    func testARehearsalIsNotAState() {
        var s = Switches()
        s.apply(Switches.parse("rehearse=fanout wait=4"))
        XCTAssertEqual(s, Switches())
        XCTAssertEqual(s.summary, "defaults")
    }

    /// Round 3 opened every window on the frame of its switch. A command that changed the scene waits 2 s now; one that
    /// changed nothing (a measure, the same state again) does not; `wait=` overrides both.
    func testTheSwitchSettlesBeforeItsWindow() {
        XCTAssertEqual(Switches.defaultSettle, 2)
        XCTAssertEqual(Switches.settle(for: Switches.parse("cones=off"), changedState: true), 2)
        XCTAssertEqual(Switches.settle(for: Switches.parse(""), changedState: false), 0)
        XCTAssertEqual(Switches.settle(for: Switches.parse("cones=off"), changedState: false), 0, "already off: nothing to settle")
        XCTAssertEqual(Switches.settle(for: Switches.parse("cones=off wait=3.5"), changedState: true), 3.5)
        XCTAssertEqual(Switches.settle(for: Switches.parse("wait=1"), changedState: false), 1)
        XCTAssertEqual(Switches.settle(for: Switches.parse("rehearse=fanout"), changedState: false), 0)
        XCTAssertEqual(Switches.settle(for: Switches.parse("trails=off rehearse=fanout"), changedState: true), 2)
    }

    /// A rehearsal is the card's own pinch twice, so it only plays where that pinch means "gallery in, gallery out":
    /// anywhere else the director is told why not (and the pinch's other meanings — leave a world, close a preview —
    /// never fire).
    func testWhereARehearsalMayPlay() {
        typealias Context = V4.PerfRehearsalContext
        XCTAssertNil(Context().refusal, "the card on the desk with its gallery out")
        XCTAssertNotNil(Context(spaceOpen: false).refusal)
        XCTAssertEqual(Context(inWorld: true, previewOpen: true).refusal?.hasPrefix("a world is open"), true, "the world first")
        XCTAssertEqual(Context(cardShown: false).refusal, "the card is put away")
        XCTAssertEqual(Context(inHand: true).refusal?.hasPrefix("the passport is in the hand"), true)
        XCTAssertEqual(Context(previewOpen: true).refusal?.hasPrefix("a note preview is open"), true)
        XCTAssertEqual(Context(busy: true).refusal?.hasPrefix("the card is still busy"), true)
        XCTAssertEqual(Context(galleryOut: false).refusal, "the gallery is not out on the desk")
    }

    // MARK: - v4 B5 §2: the transition switches

    /// The new look switches are layers like the rest: on by default (the look the user signed off), `off` = the cheap
    /// version, `reset` gives them back, `all=off` takes them too.
    func testTheTransitionSwitchesAreLayers() {
        let s = Switches()
        for layer in [Layer.noteFade, .flourish, .bloom, .holdDim, .motes] { XCTAssertTrue(s.isOn(layer), layer.rawValue) }
        XCTAssertEqual(Switches.parse("resident-motes=off").set[.motes], false)
        XCTAssertEqual(Switches.parse("motes=off").set[.motes], false)
        var t = Switches()
        let c = Switches.parse("note-fade=off flourish=off bloom=off hold-dim=off")
        XCTAssertTrue(c.unknown.isEmpty)
        t.apply(c)
        XCTAssertEqual(t.summary, "note-fade off · flourish off · bloom off · hold-dim off")
        t.apply(Switches.parse("reset"))
        XCTAssertEqual(t, Switches())
        XCTAssertEqual(Switches.parse("fade=off").set[.noteFade], false)
        XCTAssertEqual(Switches.parse("glow=off").set[.bloom], false)
        XCTAssertEqual(Switches.parse("dim=off").set[.holdDim], false)
        XCTAssertEqual(Switches.parse("flourishes=off").set[.flourish], false)
        var all = Switches()
        all.apply(Switches.parse("all=off"))
        XCTAssertFalse(all.isOn(.noteFade))
        XCTAssertFalse(all.isOn(.holdDim))
    }

    // MARK: - v4 B5 §4: a world's tier

    /// `tier=` is a state like the layers: it changes the state (so it is not measure-only), shows in the summary, stays
    /// until `reset`, and a word it does not know is reported, not guessed.
    func testTheWorldTierIsAState() {
        let c = Switches.parse("tier=low")
        XCTAssertEqual(c.tier, .low)
        XCTAssertFalse(c.isMeasureOnly)
        XCTAssertTrue(c.unknown.isEmpty)
        XCTAssertEqual(Switches.parse("quality=medium").tier, .medium)
        XCTAssertNil(Switches.parse("tier=ultra").tier)
        XCTAssertEqual(Switches.parse("tier=ultra").unknown, ["tier=ultra"])
        var s = Switches()
        s.apply(c)
        XCTAssertEqual(s.tier, .low)
        XCTAssertEqual(s.summary, "tier low")
        s.apply(Switches.parse("bloom=off"))
        XCTAssertEqual(s.tier, .low, "another switch leaves the tier alone")
        XCTAssertEqual(s.summary, "bloom off · tier low")
        s.apply(Switches.parse("reset"))
        XCTAssertNil(s.tier)
        XCTAssertEqual(s, Switches())
        s.apply(Switches.parse("reset tier=high"))
        XCTAssertEqual(s.tier, .high, "reset first, then the tier")
    }

    /// B4's ladder strings still parse to the same states (the layer list only grew at the end). Since 10-06
    /// `gallery-glass=off` is the default (the frost), so it no longer shows in the summary; `=on` is the glass.
    func testB4CommandsAreUnchanged() {
        var s = Switches()
        s.apply(Switches.parse("cones=off, well=off gallery-glass=off material=placeholder worlds=on"))
        XCTAssertEqual(s.summary, "worlds in the tree · cones off · well off · material placeholder")
        XCTAssertFalse(s.isOn(.galleryGlass))
        s.apply(Switches.parse("reset glass=on"))
        XCTAssertEqual(s.summary, "gallery-glass on")
        s.apply(Switches.parse("reset"))
        XCTAssertFalse(s.isOn(.galleryGlass), "reset is the frost again")
    }
}
