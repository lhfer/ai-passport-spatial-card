import Foundation
import simd

extension V4 {
    /// **The hero card's entrance, idle and exit, as pure functions of time** (seconds since the entrance started).
    ///
    /// Beats (art bible §3; the brief: rise, then the pop-up, then the count — ≤ 2.5 s in all):
    ///
    ///     0.00  the card fades in flat on the LCD at the screen's size and squashes 5 % (anticipation, 100 ms)
    ///     0.10  it rises to 0.22 m on a forward-bowed arc, growing to full size — the bible's spring (0.50 / 0.65)
    ///           chasing a 0.45 s ramp: 2.6 % over, settled by ≈ 0.9 s
    ///     0.12  …scale follows 20 ms later, and 0.16 it stands up to face the reader (follow-through, 60 ms late)
    ///     0.62  the pop-up opens: steam, figure, sky leave the face 40 ms apart, each with a 5 % dip first
    ///           (spring 0.42 / 0.68: 5.4 % over) and settle at 18 / 10 / 3 mm
    ///     0.92  the follower count starts rolling (1.2 s, fast then slow — `HeroCardOdometer`)
    ///     2.21  the last reel lands (one 90 ms roll after the count): one four-point sparkle; 2.26 the first light
    ///           sweep crosses the foil
    ///     2.31  entrance complete → idle (breath 1 mm / 5 s, a sweep every 8–12 s)
    ///
    /// Nothing here knows about RealityKit: the rig samples these every frame and writes transforms, which is why the
    /// lab can freeze any instant for a screenshot and the tests can check the numbers the bible sets.
    struct HeroCardTimeline: Equatable {
        // MARK: Entrance kind (v4 B1)

        /// How the card arrives. `.rise` is A4's entrance: lifted off the screen. **`.inPlace`** (v4 B1) is the first
        /// recognition's: the ribbon has already drawn the card's outline where it will stand, so the card does not
        /// travel — it is dissolved into that outline (A1's MagicDissolve, driven by `dissolveProgress(at:)`), and the
        /// pop-up and the count overlap the dissolve so the whole recognition lands inside the bible's 3.5 s.
        enum Entrance: Equatable {
            case rise
            case inPlace
        }

        var entrance: Entrance = .rise
        /// `.inPlace`: how long the dissolve takes to fill the card from its outline inward (brief: 0.6–0.8 s).
        var dissolveDuration: Double = 0.70
        /// `.inPlace`: the type and the art are faded in across this part of the dissolve (0…1 of its progress):
        /// the front has passed the type by then, and nothing floats in front of an empty outline. (0.35 was too early:
        /// on the night-blue dark even a 2 % overlay of the art reads through the unfilled middle — sRGB lifts it.)
        var contentFadeRange: ClosedRange<Double> = 0.55...0.92
        /// When false the count is not played: the reels stand on the target from the first frame and the landing
        /// flourish (sparkle, glint) is skipped — a reentry re-shows a number the wearer has already seen counted.
        var countsUp = true

        /// **v4 B1: the first recognition's entrance.** t = 0 is the ribbon's closure (A2's `.closure`, 1.90 s into
        /// the recognition): the dissolve runs 0 → 0.70 s, the type and art come up behind its front (0.38–0.6 s), the
        /// pop-up leaves the face at 0.50 s (steam, figure, sky 40 ms apart) while the last of the dissolve finishes,
        /// and the count starts at 0.30 s so that it lands at 0.30 + 1.2 + 0.09 = 1.59 s — 3.49 s after the
        /// recognition started (bible §3: first recognition ≤ 3.5 s). The count's first fifth runs under the fade, so
        /// what is seen is the reels already rolling as the card solidifies — overlapping action, and the price of the
        /// 3.5 s budget (strictly after the pop-up it would land at ≈ 3.8 s).
        static func revealInPlace() -> HeroCardTimeline {
            var t = HeroCardTimeline()
            t.entrance = .inPlace
            t.dissolveDuration = 0.70
            t.layerStart = 0.50
            t.odometerStart = 0.30
            return t
        }

        /// **v4 B1: reentry / summon / after a put-down.** A4's rise off the screen and the pop-up, without the count
        /// (the number is already known) — idle takes over once the pop-up has settled.
        static func riseWithoutCount() -> HeroCardTimeline {
            var t = HeroCardTimeline()
            t.countsUp = false
            return t
        }

        // MARK: Card rise

        /// Anticipation: squash + a 1 mm dip into the screen, before the rise.
        var anticipation: Double = 0.10
        var anticipationSquash: Double = 0.05
        var anticipationDip: Float = 0.001
        var fadeIn: Double = 0.12
        /// The rise is the bible's spring (response 0.50, damping 0.65) chasing a target that ramps up over 0.45 s
        /// (`HeroCardMotion.rampedSpring`): 2.6 % over, 10 → 90 % in ≈ 0.35 s, settled ≈ 0.8 s after lift-off — a
        /// big move (bible 0.8–1.6 s). Released onto a step (round 6) it did 90 % in 0.2 s: a pop, not a rise.
        var riseResponse: Double = 0.50
        var riseDamping: Double = 0.65
        var riseRamp: Double = 0.45
        /// The scale channel starts 20 ms and the stand-up 60 ms after the climb (follow-through).
        var scaleLag: Double = 0.02
        var standLag: Double = 0.06
        /// The arc: the path bows 30 mm towards the reader (14 % of the 0.22 m climb; bible: 10–25 %).
        var arcBow: Float = 0.030
        var arcDuration: Double = 0.70
        /// Final lean, radians about the card's X: the top 6° away from the reader (v3's `cardTiltDegrees`).
        var finalPitch: Float = -6 * .pi / 180
        /// Start height of the card's centre above the screen, where it lies flat.
        var startHeight: Float = 0.0025
        var riseHeight: Float = HeroCardLayout.riseHeight

        // MARK: Pop-up layers

        /// As the rise settles (it is at ≈ 97 % by then): follow-through, not a queue.
        var layerStart: Double = 0.62
        /// Bible: same-level elements 30–60 ms apart; the brief: 40 ms.
        var layerStagger: Double = 0.040
        /// Front to back: the steam leaps first and pulls the scene up after it. Bottom-up cannot work with a dip —
        /// the sky, already rising, passes through the figure while the figure is still dipping (≈ 70 ms in, both at
        /// ≈ 1.3 mm). Front to back, each layer dips while the one below it is still flat, then rises away from it.
        var layerPopOrder: [Int] = [2, 1, 0]
        var layerLead: Double = 0.06
        var layerDip: Double = 0.05
        var layerResponse: Double = 0.42
        var layerDamping: Double = 0.68
        /// Heights while the pop-up is closed: flat on the face, stacked in order, above the type (0.9 mm), and far
        /// enough apart that each layer's dip (5 % of its climb) stays above the flat layer under it.
        var layerFlatHeights: [Float] = [0.0011, 0.0017, 0.0026]
        var layerHeights: [Float] = HeroCardLayout.layerHeights
        /// Each layer also grows from 96 % as it lifts, so the pop reads as a pop and not only as parallax.
        var layerStartScale: Float = 0.96

        // MARK: Count, finale

        var odometerStart: Double = 0.92
        var odometerDuration: Double = 1.2
        /// The reels land one roll (90 ms) after the count itself ends (`HeroCardOdometer.rollDuration`).
        var odometerRoll: Double = 0.09
        var sparkleDuration: Double = 0.35
        /// The gold glint that crosses the landed count (the numerals are ink; gold rides on the accents).
        var glintDuration: Double = 0.6
        var firstSweepDelay: Double = 0.05
        var settleTail: Double = 0.10

        // MARK: Idle

        /// Bible: breath 0.5–1.5 mm over 4–6 s.
        var breathAmplitude: Float = 0.0010
        var breathPeriod: Double = 5.0
        var breathRampIn: Double = 1.0
        /// A light sweep every 8–12 s, 1 s across.
        var sweepIntervalRange: ClosedRange<Double> = 8...12
        var sweepDuration: Double = 1.0

        // MARK: Exit (the lab's loop reset)

        var exitDuration: Double = 0.40

        init() {}

        var odometerEnd: Double { odometerStart + odometerDuration }
        /// The last digit is on its place: the landing beat.
        var countLanding: Double { odometerEnd + odometerRoll }
        var sparkleTime: Double { countLanding }
        var firstSweepTime: Double { countsUp ? countLanding + firstSweepDelay : entranceDuration + 0.3 }
        /// How long the last pop-up layer takes to settle once it has left the face (spring 0.42 / 0.68).
        var popSettle: Double = 0.55
        /// When the entrance is over and idle begins (brief: ≤ 2.5 s). Without the count it is over once the rise
        /// and the pop-up have settled.
        var entranceDuration: Double {
            guard countsUp else {
                let lastLayer = layerPopOrder.map(layerStartTime).max() ?? layerStart
                return max(anticipation + 1.30, lastLayer + popSettle)
            }
            return countLanding + settleTail
        }

        /// `.inPlace`: the dissolve's progress 0…1 at `t` (eased in and out); `.rise` never dissolves (1).
        func dissolveProgress(at t: Double) -> Double {
            guard entrance == .inPlace else { return 1 }
            return HeroCardMotion.smoothstep(0, dissolveDuration, t)
        }

        /// `.inPlace`: how much of the type and the art is up at `t` (they arrive behind the dissolve's front).
        func contentOpacity(at t: Double) -> Double {
            guard entrance == .inPlace else { return 1 }
            return HeroCardMotion.smoothstep(contentFadeRange.lowerBound, contentFadeRange.upperBound, dissolveProgress(at: t))
        }

        /// `.inPlace`: A4's shadow caster — an opaque plate just behind the slab, the only thing that casts the desk
        /// shadow — is held back until the dissolve has closed over it: through the unfilled middle of the dissolve it
        /// would read as a grey board behind the glass.
        func casterOpacity(at t: Double) -> Double {
            guard entrance == .inPlace else { return 1 }
            return HeroCardMotion.smoothstep(0.8, 1.0, dissolveProgress(at: t))
        }

        /// When layer `index` (0 sky, 1 figure, 2 steam) starts its pop.
        func layerStartTime(_ index: Int) -> Double {
            layerStart + Double(layerPopOrder.firstIndex(of: index) ?? index) * layerStagger
        }

        // MARK: - Card pose

        /// The card root's pose in the device's screen frame S (+Y the screen normal, +Z towards the reader).
        struct Pose: Equatable {
            var position: SIMD3<Float>
            /// Rotation about S's +X: −π/2 = lying flat face-up on the screen, `finalPitch` = standing.
            var pitch: Float
            var scale: Float
            var opacity: Float
        }

        /// The rise, from the screen (`startScale`: the card at the LCD's size) to 0.22 m. `.inPlace`: the card stands
        /// where it will rest from the first frame (the dissolve makes it appear).
        func pose(at t: Double, startScale: Float) -> Pose {
            if entrance == .inPlace { return restPose }
            let m = HeroCardMotion.self
            func rise(_ lag: Double) -> Float {
                Float(m.rampedSpring(t - anticipation - lag, ramp: riseRamp, response: riseResponse, damping: riseDamping))
            }
            let lift = rise(0), grow = rise(scaleLag), stand = rise(standLag)
            // Anticipation: squash and a small dip into the screen, both easing in and back out over the lead.
            let pre = m.easeInOutSine(t / anticipation)
            let squash = t < anticipation ? Float(anticipationSquash * pre) : Float(anticipationSquash)
            let dip = t < anticipation ? anticipationDip * Float(sin(Double.pi * min(max(t / anticipation, 0), 1))) : 0
            let squashed = startScale * (1 - squash)
            let y = startHeight + (riseHeight - startHeight) * lift - dip
            let z = arcBow * Float(m.arc((t - anticipation) / arcDuration))
            let pitch = -Float.pi / 2 + (finalPitch + Float.pi / 2) * stand
            let scale = squashed + (1 - squashed) * grow
            let opacity = Float(m.smoothstep(0, fadeIn, t))
            return Pose(position: [0, y, z], pitch: pitch, scale: scale, opacity: opacity)
        }

        /// The resting pose the entrance lands on (and idle breathes around).
        var restPose: Pose {
            Pose(position: [0, riseHeight, 0], pitch: finalPitch, scale: 1, opacity: 1)
        }

        /// The exit (the lab's loop reset): shrink back into the screen, lying down, fading — ease-in, 0.4 s.
        func exitPose(at t: Double, from pose: Pose, startScale: Float) -> Pose {
            let e = Float(HeroCardMotion.easeInCubic(t / exitDuration))
            let fade = Float(1 - HeroCardMotion.smoothstep(exitDuration * 0.35, exitDuration, t))
            return Pose(position: simd_mix(pose.position, [0, startHeight + 0.01, 0], SIMD3<Float>(repeating: e)),
                        pitch: pose.pitch + (-Float.pi / 2 - pose.pitch) * e,
                        scale: pose.scale + (startScale - pose.scale) * e,
                        opacity: pose.opacity * fade)
        }

        // MARK: - Pop-up layers

        /// One avatar layer: height above the card face and scale.
        struct Layer: Equatable {
            var height: Float
            var scale: Float
            /// 0 flat … 1 fully up (can overshoot past 1 with the spring).
            var lift: Float
        }

        func layer(_ index: Int, at t: Double) -> Layer {
            let u = Float(HeroCardMotion.anticipatedSpring(t - layerStartTime(index), lead: layerLead, depth: layerDip,
                                                         response: layerResponse, damping: layerDamping))
            let flat = layerFlatHeights[index], up = layerHeights[index]
            return Layer(height: flat + (up - flat) * u, scale: layerStartScale + (1 - layerStartScale) * u, lift: u)
        }

        /// Odometer progress clock: seconds into the roll (negative before it starts). Without the count the reels
        /// have always landed.
        func odometerTime(at t: Double) -> Double {
            guard countsUp else { return odometerDuration + odometerRoll + 1 }
            return t - odometerStart
        }

        /// Sparkle life, 0…1 while it plays, nil otherwise.
        func sparkle(at t: Double) -> Double? {
            guard countsUp else { return nil }
            let x = (t - sparkleTime) / sparkleDuration
            return (x >= 0 && x <= 1) ? x : nil
        }

        /// Glint progress across the count, 0…1 while it plays (from the landing), nil otherwise.
        func glint(at t: Double) -> Double? {
            guard countsUp else { return nil }
            let x = (t - countLanding) / glintDuration
            return (x >= 0 && x <= 1) ? x : nil
        }

        // MARK: - Idle

        /// Vertical breath offset, metres, at `idle` seconds after the entrance ended. Ramped in, so the card does
        /// not jump when idle takes over from the landed pose.
        func breath(atIdle idle: Double) -> Float {
            guard idle > 0 else { return 0 }
            let ramp = Float(HeroCardMotion.smoothstep(0, breathRampIn, idle))
            return breathAmplitude * ramp * Float(sin(2 * Double.pi * idle / breathPeriod))
        }

        /// Start times of the light sweeps, entrance clock: the first right after the count lands, then every
        /// 8–12 s (a seeded generator, so a run is reproducible and a test can hold the interval to the bible).
        func sweepTimes(until end: Double, seed: UInt64 = 0x4A4_CA2D) -> [Double] {
            var times: [Double] = []
            var t = firstSweepTime
            var rng = SplitMix64(seed: seed)
            while t <= end {
                times.append(t)
                let span = sweepIntervalRange.upperBound - sweepIntervalRange.lowerBound
                t += sweepIntervalRange.lowerBound + span * rng.nextUnit()
            }
            return times
        }

        /// Sweep progress 0…1 at time `t` (entrance clock), or nil between sweeps.
        func sweep(at t: Double, times: [Double]) -> Double? {
            for start in times.reversed() where t >= start {
                let x = (t - start) / sweepDuration
                return x <= 1 ? x : nil
            }
            return nil
        }
    }

    /// The foil and the rim as a function of viewing angle (art bible §2). `facing` = |n · v|: 1 square-on, 0 edge-on.
    enum HeroCardLook {
        /// Holo foil strength: ≤ 0.12 square-on, ≤ 0.45 grazing — never enough to cover the portrait or the numbers.
        static let foilFacing: Float = 0.12
        static let foilGrazing: Float = 0.45
        /// Rim (the slab's edge light): 0.45 square-on → 0.9 grazing, warm white-gold.
        static let rimFacing: Float = 0.45
        static let rimGrazing: Float = 0.90

        static func foil(facing: Float) -> Float { mix(foilFacing, foilGrazing, grazing(facing)) }
        static func rim(facing: Float) -> Float { mix(rimFacing, rimGrazing, grazing(facing)) }

        /// 0 square-on → 1 edge-on, with the middle held back (^1.5) so it reads as an edge catching light.
        static func grazing(_ facing: Float) -> Float {
            let f = min(max(facing.isFinite ? facing : 1, 0), 1)
            return pow(1 - f, 1.5)
        }

        /// |n · v| for a card normal and the direction to the eye; degenerate input reads as square-on.
        static func facing(normal: SIMD3<Float>, toViewer: SIMD3<Float>) -> Float {
            let nl = simd_length(normal), vl = simd_length(toViewer)
            guard nl > 1e-6, vl > 1e-6, nl.isFinite, vl.isFinite else { return 1 }
            return min(1, abs(simd_dot(normal / nl, toViewer / vl)))
        }

        private static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    }

    /// Tiny deterministic PRNG (SplitMix64) — reproducible sweep schedules and dust counts.
    struct SplitMix64 {
        private var state: UInt64
        init(seed: UInt64) { state = seed }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// Uniform in [0, 1).
        mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }
}
