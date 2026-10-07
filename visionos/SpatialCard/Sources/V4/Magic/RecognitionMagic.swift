import Foundation
import QuartzCore
import RealityKit
import UIKit

/// **"认出" — the recognition key visual** (v4 A2, style frame ①), as one rig in the screen frame S.
///
/// The screen bursts; a fairy ribbon rises out of the screen centre, circles the device once while climbing,
/// and draws the card's rounded-rectangle outline above it, shedding gold dust all the way; the outline closes
/// with one four-point glint and the ribbon breaks up into dust, leaving the drawn outline glowing for half a
/// second — which is where the product hands over to the card's own reveal (A1's dissolve). The beats and the
/// flight path are `V4.RecognitionTimeline` (pure, unit-tested); this class only turns them into entities:
///
///     root (S: parent it to `stage.deviceFrame` / the product's `anchorRoot`)
///     ├─ v4.screenBurst            the LCD's own burst (stand-in for the firmware animation)
///     ├─ v4.ribbon                 the fairy ribbon (LowLevelMesh strip + head glow)
///     ├─ v4.ribbon (outline)       the line the head draws
///     ├─ v4.dust.trail / .dissolve / .sparkle
///     └─ v4.glints                 the closing "ding"
///
/// One clock drives everything (`time`, advanced by an `EngineTickComponent` on `root`), so a still frame
/// is exact: `freeze(at:)` stops the clock on a given beat and pauses every mote in the air.
///
/// **v4 B1 follow-up — the hand-over hold** (`V4.HandOverHold`): `hold(at:)` makes the clock wait at a beat without
/// freezing anything — the outline breathes, a trickle of dust keeps leaving it, the motes in the air drift on —
/// until `resumeFromHold()`. The product holds the hand-over there while A1's materials finish loading.
@MainActor
final class RecognitionMagic {
    enum Beat: String, CaseIterable {
        case burst, launch, outline, closure, dissolved, handOver, done
    }

    let root = Entity()
    /// The flight playing (or last played): the desk's, or — **v4 B4 §1** — the hand's, built for one run by `run(_:)`.
    private(set) var timeline: V4.RecognitionTimeline
    /// The desk's flight, built once (it is the same every time).
    let deskTimeline: V4.RecognitionTimeline
    /// What a run flies.
    enum Flight: Equatable {
        /// The desk's: a spiral round the screen normal, the card standing 0.22 m over the screen.
        case desk
        /// The hand's (v4 B4 §1): over the top edge, round the hand card's up axis, the outline on the hinge.
        case hand(V4.RecognitionTimeline.HandGeometry)
    }
    /// The fairy ribbon's width for this run, as a share of its style's (the hand's is narrower).
    private var widthScale: Float = 1
    let ribbon: RibbonTrail
    let outline: RibbonTrail
    let glints: StarGlint
    let burst: ScreenBurst
    let spec: V4.GoldDustSpec
    private let trailDust: GoldDustEmitter
    private let dissolveDust: GoldDustEmitter
    private let sparkleDust: GoldDustEmitter
    /// v4 B1 follow-up: the hold's lingering dust (`V4.GoldDustSpec.linger`).
    private let lingerDust: GoldDustEmitter

    /// World-space eye position (the lab: the simulator's eye; the product: the head pose).
    var cameraPosition: () -> SIMD3<Float>? = { nil } {
        didSet {
            ribbon.cameraPosition = cameraPosition
            outline.cameraPosition = cameraPosition
        }
    }
    /// Called once per beat per run, with the rig's time.
    var onBeat: ((Beat, Float) -> Void)?
    /// **v4 B1**: the virtual screen burst stands in for the firmware's own animation. On the headset the real LCD
    /// plays the `glow` itself, so the product turns this layer off there (`--screen-burst`).
    var screenBurstEnabled = true

    private(set) var time: Float = 0
    private(set) var isRunning = false
    private(set) var isFrozen = false
    private var freezeAt: Float?
    private var fired: Set<Beat> = []
    /// The ribbon's body as it was at the closure: the dissolve sweeps its dust back along it.
    private var dissolvePath: [V4.RibbonSample] = []
    /// The hand-over hold's numbers (the breath, the cap the product applies).
    let hold = V4.HandOverHold.standard
    /// Where the clock waits (nil = it does not): it arrives there as usual, beats and all, then holds.
    private(set) var holdAt: Float?
    /// The clock has reached `holdAt` and is waiting.
    private(set) var isHolding = false
    /// The outline breathes and sheds dust while the clock waits (until `endHoldBreathing()`).
    private var breathing = false
    private var heldSeconds: Float = 0
    /// All the time the clock has waited this run. The outline's own clock skips none of it, so its shimmer runs on
    /// and nothing on it jumps when the clock resumes.
    private var outlineClockOffset: Float = 0
    /// The breath's level when it ended, easing back to 1 (`V4.HandOverHold.settled`).
    private var settleFrom: Float?
    private var sinceSettle: Float = 0
    /// Per-frame CPU of this rig (its whole tick: two strips, dust, glints, burst).
    private(set) var perf = MagicPerfWindow()
    /// The same, only across the heaviest stretch (outline + dissolve, 1.20–2.20 s: both strips at full length).
    private(set) var perfPeak = MagicPerfWindow()

    private init(timeline: V4.RecognitionTimeline, ribbon: RibbonTrail, outline: RibbonTrail, glints: StarGlint,
                 burst: ScreenBurst, spec: V4.GoldDustSpec) {
        self.timeline = timeline
        deskTimeline = timeline
        self.ribbon = ribbon
        self.outline = outline
        self.glints = glints
        self.burst = burst
        self.spec = spec
        trailDust = GoldDustEmitter(.trail, name: "v4.dust.trail", spec: spec)
        dissolveDust = GoldDustEmitter(.dissolve, name: "v4.dust.dissolve", spec: spec)
        sparkleDust = GoldDustEmitter(.sparkle, name: "v4.dust.sparkle", spec: spec)
        var lingerSpec = spec
        lingerSpec.trail = spec.linger
        lingerDust = GoldDustEmitter(.trail, name: "v4.dust.linger", spec: lingerSpec)
        root.name = "v4.recognition"
        outline.root.name = "v4.ribbon.outline"
        for child in [burst.entity, outline.root, ribbon.root, trailDust.entity, dissolveDust.entity,
                      sparkleDust.entity, lingerDust.entity, glints.root] {
            root.addChild(child)
        }
        root.components.set(EngineTickComponent(tick: { [weak self] dt in self?.tick(dt: dt) }))
    }

    /// - Parameters:
    ///   - geometry: the card outline + spiral, in S (the app passes `HologramLayout`'s numbers).
    ///   - screenSize: the LCD's lit area (m), for the burst layer.
    ///   - screenLift: the burst layer's height above S's origin (the proxy screen sits at 0.3 mm; the burst
    ///     0.3 mm above that).
    ///   - ribbonWidth: **v4 B1** `--ribbon-width`: the fairy ribbon's head width (m); nil = A2's 11 mm.
    static func make(geometry: V4.RecognitionTimeline.Geometry = .fromHologramLayout,
                     screenSize: SIMD2<Float>, screenLift: Float = 0.0006,
                     spec: V4.GoldDustSpec = .standard, ribbonWidth: Float? = nil) async throws -> RecognitionMagic {
        let timeline = V4.RecognitionTimeline(geometry: geometry)
        var fairy = RibbonTrail.Style.fairy
        if let ribbonWidth, ribbonWidth.isFinite, ribbonWidth > 0 { fairy.profile.width = ribbonWidth }
        let ribbon = try await RibbonTrail.make(style: fairy)
        let outline = try await RibbonTrail.make(style: .stroke)
        let glints = await StarGlint.make()
        let burst = await ScreenBurst.make(size: screenSize, lift: screenLift)
        return RecognitionMagic(timeline: timeline, ribbon: ribbon, outline: outline, glints: glints, burst: burst,
                                spec: spec)
    }

    // MARK: - Control

    /// Play the recognition from its first beat. **v4 B4 §1**: the flight is chosen — and, for the hand, its path built —
    /// here, once, before the first frame: nothing recomputes it while the ribbon flies (a hand that moves the passport
    /// moves S, and the whole flight with it).
    func run(_ flight: Flight = .desk) {
        switch flight {
        case .desk:
            timeline = deskTimeline
            widthScale = 1
        case .hand(let geometry):
            timeline = V4.RecognitionTimeline(hand: geometry, beats: deskTimeline.beats)
            widthScale = geometry.ribbonWidthScale
        }
        time = 0
        fired.removeAll()
        dissolvePath.removeAll()
        isRunning = true
        setFrozen(false)
        clearHold()
        let path = timeline.path, timing = timeline.timing
        ribbon.play(path: path, timing: timing)
        ribbon.intensityScale = 1
        ribbon.widthScale = widthScale
        ribbon.headGlowScale = widthScale
        outline.stroke(path: path, timing: timing, range: timeline.outlineStart...timeline.outlineEnd)
        outline.intensityScale = 1
        glints.hideAll()
        if screenBurstEnabled { burst.play() } else { burst.stop() }
        trailDust.stop()
        dissolveDust.stop()
        render()
    }

    func stop() {
        isRunning = false
        freezeAt = nil
        setFrozen(false)
        clearHold()
        ribbon.clear()
        outline.clear()
        burst.stop()
        glints.hideAll()
        trailDust.stop()
        dissolveDust.stop()
    }

    /// Stop the clock the moment it reaches `t` (this run or the next), holding every mote where it is.
    func freeze(at t: Float) { freezeAt = t }

    func resume() {
        freezeAt = nil
        setFrozen(false)
    }

    /// **The hand-over hold.** The clock runs on to `t` as usual (its beats fire), then waits there — not frozen: the
    /// outline breathes (`V4.HandOverHold.breath`) and sheds a trickle of dust, and the motes in the air drift on —
    /// until `resumeFromHold()`.
    func hold(at t: Float) {
        holdAt = t
        breathing = true
        heldSeconds = 0
    }

    /// The wait is over (the card's reveal starts from the outline): the breath settles and the dust stops; the clock
    /// itself waits on until `resumeFromHold()`, so the outline and the card stay in step.
    func endHoldBreathing() {
        guard breathing else { return }
        breathing = false
        settleFrom = isHolding ? hold.breath(held: heldSeconds) : 1
        sinceSettle = 0
        lingerDust.stop()
    }

    /// Run on from the hold point — `catchUp` seconds past it (≤ 0.1): the frames the caller's own clock ran on before
    /// it could say so, so the two stay in step to the frame.
    func resumeFromHold(catchUp: Float = 0) {
        endHoldBreathing()
        if isHolding, let at = holdAt { time = at + max(0, min(0.1, catchUp)) }
        holdAt = nil
        isHolding = false
    }

    private func clearHold() {
        holdAt = nil
        isHolding = false
        breathing = false
        heldSeconds = 0
        outlineClockOffset = 0
        settleFrom = nil
        sinceSettle = 0
        lingerDust.stop()
    }

    func resetPerf() {
        perf.reset()
        perfPeak.reset()
    }

    /// One line of state for the lab log (the trail emitter as RealityKit sees it).
    var dustDebug: String {
        let p = trailDust.entity.components[ParticleEmitterComponent.self]
        let w = trailDust.entity.position(relativeTo: nil)
        return String(format: "t %.2f trail emitting %@ (flag %@) state %@ at world (%.3f, %.3f, %.3f) enabled %@",
                      time, String(describing: p?.isEmitting), String(describing: trailDust.isEmitting),
                      String(describing: p?.simulationState), w.x, w.y, w.z,
                      String(describing: trailDust.entity.isEnabledInHierarchy))
    }

    private func setFrozen(_ on: Bool) {
        isFrozen = on
        for emitter in [trailDust, dissolveDust, sparkleDust, lingerDust] { emitter.pause(on) }
        glints.pause(on)
    }

    // MARK: - The tick

    private func tick(dt: Float) {
        guard isRunning else { return }
        let started = CACurrentMediaTime()
        defer {
            let ms = (CACurrentMediaTime() - started) * 1000
            perf.add(milliseconds: ms)
            if !isHolding, time >= timeline.beats.outlineStart, time <= timeline.beats.dissolveEnd {
                perfPeak.add(milliseconds: ms)
            }
        }
        if !isFrozen {
            var next = time + dt
            if let stop = freezeAt, time < stop, next >= stop {
                next = stop
                time = next
                advance(dt: dt)
                setFrozen(true)
                return
            }
            if let at = holdAt, next >= at {
                if time < at {
                    // Arrive exactly on the hold point: its beats fire as usual.
                    time = at
                } else {
                    // The clock waits; the outline's own clock, the breath and the air do not.
                    heldSeconds += dt
                    outlineClockOffset += dt
                }
                isHolding = true
                advance(dt: dt)
                return
            }
            time = next
            advance(dt: dt)
        } else {
            // Still frame: the clock holds, but the strips keep facing the camera.
            ribbon.rebuild()
            outline.rebuild()
        }
    }

    private func advance(dt: Float) {
        if settleFrom != nil {
            sinceSettle += dt
            if sinceSettle >= hold.settle { settleFrom = nil }
        }
        glints.update(dt: dt)
        render()
        fireBeats()
    }

    /// The outline's breath: breathing while the clock waits, settling back to 1 after the hold, else 1.
    private var outlineBreath: Float {
        if breathing, isHolding { return hold.breath(held: heldSeconds) }
        if let settleFrom { return hold.settled(from: settleFrom, elapsed: sinceSettle) }
        return 1
    }

    /// Everything as of `time`.
    private func render() {
        let t = time
        let beats = timeline.beats

        burst.set(time: t - beats.burstStart)

        // The ribbon: level and width ease out across the dissolve; the head flares on the closure.
        let dissolve = timeline.dissolveProgress(at: t)
        ribbon.clock = t
        ribbon.intensityScale = timeline.ribbonLevel(at: t)
        ribbon.widthScale = widthScale * (1 - 0.35 * dissolve)
        let sinceClosure = t - beats.closure
        let flare: Float = sinceClosure > 0 ? 1 + 0.7 * exp(-pow((sinceClosure - 0.05) / 0.07, 2)) : 1
        ribbon.headGlowScale = widthScale * flare
        ribbon.rebuild()

        outline.clock = t + outlineClockOffset
        outline.intensityScale = timeline.outlineLevel(at: t) * outlineBreath
        outline.rebuild()

        // The hold's lingering dust: born anywhere along the outline (the emitter hops to a new point every frame).
        if breathing, isHolding {
            let d = Float.random(in: timeline.outlineStart...timeline.outlineEnd)
            lingerDust.place(at: timeline.path.point(atDistance: d), along: timeline.path.tangent(atDistance: d))
            lingerDust.start()
        } else {
            lingerDust.stop()
        }

        // Dust behind the head while it flies, its birth box along the way it is going.
        if timeline.isFlying(at: t), let head = ribbon.body.first {
            trailDust.place(at: head.position, along: timeline.path.tangent(atDistance: head.distance))
            trailDust.start()
        } else {
            trailDust.stop()
        }

        // The dissolve: dust swept from the head back along the body the ribbon had at the closure.
        if t >= beats.closure, t < beats.dissolveEnd {
            if dissolvePath.isEmpty { dissolvePath = ribbon.body }
            if dissolvePath.count >= 2 {
                let x = dissolve * Float(dissolvePath.count - 1)
                let i = min(dissolvePath.count - 2, Int(x))
                let f = x - Float(i)
                let a = dissolvePath[i].position, b = dissolvePath[i + 1].position
                dissolveDust.place(at: a + (b - a) * f, along: a - b)
                dissolveDust.start()
            }
        } else {
            dissolveDust.stop()
        }
    }

    private func fireBeats() {
        let beats = timeline.beats
        let t = time
        func once(_ beat: Beat, _ at: Float, _ action: () -> Void = {}) {
            guard t >= at, !fired.contains(beat) else { return }
            fired.insert(beat)
            action()
            onBeat?(beat, t)
        }
        once(.burst, beats.burstStart)
        once(.launch, beats.launch)
        once(.outline, beats.outlineStart)
        once(.closure, beats.closure) {
            let point = timeline.closurePoint
            // The bible's 6–12 mm: 12 on the desk card, 9.6 on the half-size hand card.
            glints.flash(at: point, size: 0.012 * widthScale, duration: 0.36, spin: 0.35)
            sparkleDust.position = point
            sparkleDust.burst()
        }
        once(.dissolved, beats.dissolveEnd) {
            ribbon.clear()
        }
        once(.handOver, beats.closure + beats.outlineHold)
        once(.done, beats.outlineGone) {
            outline.clear()
            isRunning = false
        }
    }

    // MARK: - Budget

    /// Entities this rig keeps (itself included).
    var entityCount: Int {
        func count(_ e: Entity) -> Int { 1 + e.children.reduce(0) { $0 + count($1) } }
        return count(root)
    }
}

extension V4.RecognitionTimeline.Geometry {
    /// The card exactly as the product lays it out (`HologramLayout`), in S.
    static var fromHologramLayout: Self {
        var g = Self.standard
        g.cardWidth = HologramLayout.cardWidth
        g.cardHeight = HologramLayout.cardHeight
        g.cornerRadius = HologramLayout.cardCornerRadius
        g.cardCenterHeight = HologramLayout.cardCenterHeight
        g.cardTiltDegrees = HologramLayout.cardTiltDegrees
        return g
    }
}

/// A rolling window of per-frame CPU times (ms), for the lab's perf line.
struct MagicPerfWindow {
    private(set) var samples: [Double] = []
    var capacity = 600

    mutating func add(milliseconds: Double) {
        samples.append(milliseconds)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    mutating func reset() { samples.removeAll(keepingCapacity: true) }

    var average: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }
    var maximum: Double { samples.max() ?? 0 }
    var p95: Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }
}
