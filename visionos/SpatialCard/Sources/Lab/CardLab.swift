import Foundation
import QuartzCore
import RealityKit

/// **`--lab card`** (v4 A4): the hero card rising out of the proxy passport, on a loop — entrance (2.1 s), 6 s of idle,
/// a 0.4 s exit back into the screen, a beat of nothing, again. Tap the card to replay the entrance at once.
///
/// - `--card-shape square|portrait` — the two formats the brief compares (default portrait).
/// - `--odometer wheel|numeric` — custom reels or SwiftUI's numericText (default wheel).
/// - `--card-followers <n>` — the count to roll to (default 4401, the brief's demo value; `card.json`'s seed is 4313).
/// - `--card-freeze <t>` — hold the entrance clock at `t` seconds (stills: 1.35 = mid-count, 3 = landed).
/// - `--card-yaw <degrees>` — turn the card about the vertical, for oblique views (the simulator camera is fixed).
/// - `--odometer numeric` / `--card-foil-gain <x>` / `--card-no-shadow` — the A/Bs the report compares.
@MainActor
enum CardLab {
    static func run(_ stage: LabStage) async {
        let args = Arguments()
        let card = CardData.loadFromBundle()
        let content = HeroCardContent(card: card, followers: args.followers)
        let style = await PlaceholderCardSurfaceStyle.make()
        if let gain = args.foilGain { style.foilGain = gain }
        let built = CACurrentMediaTime()
        let rig = await HeroCardRig.make(shape: args.shape, content: content, style: style,
                                         odometerStyle: args.odometer, screen: LabStage.screenSize)
        rig.yaw = args.yaw * .pi / 180
        if args.noShadow {
            // A/B for the desk shadow (`GroundingShadowComponent` on the slab and the caster).
            rig.surface.slab.components.remove(GroundingShadowComponent.self)
            rig.shadowCaster.components.remove(GroundingShadowComponent.self)
        }
        if args.shadowProbe { addShadowProbe(to: stage) }
        // The simulator's eye: ≈ 1.59 m up at the immersive space's origin (see `LabLaunch`).
        rig.viewerPosition = { [0, 1.59, 0] }
        stage.deviceFrame.addChild(rig.root)
        let size = rig.layout.size
        stage.makeTappable(rig.root, shape: .generateBox(width: size.x, height: size.y, depth: 0.03))
        stage.log(String(format: "card: %@ %.0f × %.0f mm, odometer %@, style %@, %d → followers, %d entities, built in %.0f ms",
                         args.shape.rawValue, size.x * 1000, size.y * 1000, args.odometer.rawValue, style.name,
                         content.followers, rig.entityCount, (CACurrentMediaTime() - built) * 1000))
        _ = HeroCardFonts.pingFangAvailable

        let player = Player(rig: rig, stage: stage, freeze: args.freeze)
        stage.onTap { entity in
            guard entity === rig.root else { return }
            stage.log("card: tap → replay entrance")
            player.restart()
        }
        stage.onTick { dt in player.step(Double(dt)) }
    }

    /// `--card-shadow-probe`: which materials cast a grounding shadow onto the lab desk? Right of the device, four
    /// 4 cm cubes 5 cm up, all `castsShadow: true`: PBR opaque, unlit opaque, PBR 10 % transparent, unlit 90 %
    /// transparent. Left, the same four with `castsShadow: false` as the control. (Round 8: the card cast nothing —
    /// its slab is transparent PBR and its face is unlit.)
    private static func addShadowProbe(to stage: LabStage) {
        func material(_ kind: Int) -> RealityKit.Material {
            switch kind {
            case 0:
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: .white)
                return m
            case 1:
                return UnlitMaterial(color: .white)
            case 2:
                var m = PhysicallyBasedMaterial()
                m.baseColor = .init(tint: .white)
                m.blending = .transparent(opacity: .init(floatLiteral: 0.10))
                return m
            default:
                var m = UnlitMaterial(color: .white)
                m.blending = .transparent(opacity: .init(floatLiteral: 0.9))
                return m
            }
        }
        for kind in 0..<4 {
            for side in [Float(1), -1] {
                let cube = ModelEntity(mesh: .generateBox(size: 0.04), materials: [material(kind)])
                cube.position = [side * (0.14 + Float(kind) * 0.075), 0.07, 0.02]
                cube.components.set(GroundingShadowComponent(castsShadow: side > 0))
                stage.desk.addChild(cube)
            }
        }
        stage.log("card: shadow probe — right: PBR, unlit, PBR 10 %, unlit 90 % (cast); left: same, no cast")
    }

    /// The loop's clock and its beats.
    @MainActor
    final class Player {
        let rig: HeroCardRig
        let stage: LabStage
        let freeze: Double?
        private let idleSeconds = 6.0
        private let gapSeconds = 0.4
        /// The first entrance waits 1.2 s: visionOS fades the immersive space in as it opens, and an entrance started
        /// with the stage played half-hidden under that fade (the room showed through the dome for ≈ 0.7 s).
        private var t: Double = -1.2
        private var cycle = 1
        private var logged: Set<String> = []
        private var perfClock: Double = 0
        private var dustReplay: Double = 0

        init(rig: HeroCardRig, stage: LabStage, freeze: Double?) {
            self.rig = rig
            self.stage = stage
            self.freeze = freeze
            if let freeze {
                rig.apply(at: freeze)
                stage.log(String(format: "card: frozen at t = %.2f s (count reads %@)", freeze,
                                 V4.HeroCardNumbers.grouped(V4.HeroCardOdometer(target: rig.faceModel.content.followers)
                                    .displayed(at: rig.timeline.odometerTime(at: freeze)))))
            }
        }

        func restart() {
            t = 0
            cycle += 1
            logged.removeAll()
            rig.restart()
        }

        func step(_ dt: Double) {
            let column = rig.faceModel.columnHeight
            if column > 0, !logged.contains("layout") {
                let layout = rig.layout
                let room = V4.HeroCardLayout.points(layout.nameTop - layout.panel.minY)
                beat("layout", String(format: "card: type column %.0f pt tall, %.0f pt of panel below the name → %@ (%.1f mm to spare)",
                                      column, room, column <= room ? "fits" : "OVERFLOWS",
                                      Float(room - Double(column)) / V4.HeroCardLayout.pointsPerMeter * 1000))
            }
            perfClock += dt
            if perfClock >= 5 {
                perfClock = 0
                let perf = rig.takePerf()
                let slow = perf.slow.map { String(format: "%.2f ms @ t %.2f", $0.ms, $0.t) }.joined(separator: ", ")
                stage.log(String(format: "card perf: %d frames, own CPU avg %.3f ms, max %.3f ms%@", perf.frames,
                                 perf.averageMs, perf.maxMs, slow.isEmpty ? "" : " — over 0.4 ms: " + slow))
            }
            if let freeze {
                rig.apply(at: freeze)
                dustReplay += dt
                if dustReplay >= 0.8 {
                    dustReplay = 0
                    rig.replayRecentDust(at: freeze)
                }
                return
            }
            t += dt
            guard t >= 0 else {
                rig.apply(at: 0)                      // the entrance's first frame: invisible, flat on the screen
                return
            }
            let timeline = rig.timeline
            let idleEnd = timeline.entranceDuration + idleSeconds
            let exitEnd = idleEnd + timeline.exitDuration
            if t < idleEnd {
                rig.apply(at: t)
            } else if t < exitEnd {
                beat("exit", "card: exit — back into the screen")
                rig.applyExit(at: t - idleEnd, idleTime: idleSeconds)
            } else if t < exitEnd + gapSeconds {
                rig.applyExit(at: timeline.exitDuration, idleTime: idleSeconds)
            } else {
                restart()
                return
            }
            beat("rise", "card: cycle \(cycle) — rise from the screen")
            if t >= timeline.layerStart { beat("pop", "card: pop-up opens (steam → figure → sky, 40 ms apart)") }
            if t >= timeline.odometerStart { beat("count", "card: count starts") }
            if t >= timeline.countLanding {
                beat("landed", "card: count landed on \(V4.HeroCardNumbers.grouped(rig.faceModel.content.followers))")
            }
            if t >= timeline.entranceDuration { beat("idle", "card: idle (breath, sweeps)") }
        }

        private func beat(_ key: String, _ message: String) {
            guard !logged.contains(key) else { return }
            logged.insert(key)
            stage.log(message)
        }
    }

    struct Arguments {
        var shape: V4.HeroCardShape = .portrait
        var odometer: HeroCardOdometerStyle = .wheel
        var followers = 4401
        var freeze: Double?
        var yaw: Float = 0
        var foilGain: Float?
        var noShadow = false
        var shadowProbe = false

        init() {
            let args = CommandLine.arguments
            func value(_ flag: String) -> String? {
                guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
                return args[i + 1]
            }
            if let s = value("--card-shape").flatMap(V4.HeroCardShape.init(rawValue:)) { shape = s }
            if let o = value("--odometer").flatMap(HeroCardOdometerStyle.init(rawValue:)) { odometer = o }
            if let f = value("--card-followers").flatMap(Int.init) { followers = f }
            freeze = value("--card-freeze").flatMap(Double.init)
            if let y = value("--card-yaw").flatMap(Float.init) { yaw = y }
            foilGain = value("--card-foil-gain").flatMap(Float.init)
            noShadow = args.contains("--card-no-shadow")
            shadowProbe = args.contains("--card-shadow-probe")
        }
    }
}
