import Foundation
import simd

extension V4 {
    /// **Gold dust, as numbers** (v4 A2, art bible §4 金尘): the three emitters the ribbon uses, kept here so
    /// the budget and the bible's ranges are checked by unit tests against the very values `GoldDust` feeds
    /// RealityKit.
    ///
    /// The bible: 1–3 mm **round soft points** (never snowflakes or stars), twinkling at random 3–8 Hz, living
    /// 0.6–1.6 s, gold → white-gold → transparent, a slight fall with drag, 40–120 a second behind a trail.
    /// The twinkle is an image sequence (`GoldDust` draws the frames: one soft round dot at eight
    /// brightnesses) played in a loop from a random frame at a random rate — so every mote pulses on its own.
    struct GoldDustSpec: Equatable {
        struct Emitter: Equatable {
            /// Births per second while emitting (0 for a pure burst).
            var birthRate: Float
            /// Seconds this emitter emits per recognition (for the budget).
            var emitSeconds: Float
            /// One-shot births per recognition.
            var burstCount: Int = 0
            var lifeSpan: Float
            var lifeSpanVariation: Float
            /// Sprite size (m) ± variation. The dot's visible core is ≈ 60 % of the sprite.
            var size: Float
            var sizeVariation: Float
            var speed: Float
            var speedVariation: Float
            /// Slight fall (m/s², −Y in the emitter's space) and drag.
            var fall: Float
            var damping: Float
            /// Radius of the birth sphere around the emitter (m).
            var spread: Float
            /// Length (m) of the birth box along the direction of travel; 0 = a sphere. A head doing 1.4 m/s
            /// moves ≈ 16 mm a frame, and motes born at one point per frame would sit in visible clumps: the
            /// box is stretched along the path so each frame's births fill the stretch it actually flew.
            var streak: Float = 0

            var maxLife: Float { lifeSpan + lifeSpanVariation }
            var minLife: Float { lifeSpan - lifeSpanVariation }

            /// The most motes this emitter can have alive at once: every birth of the last `maxLife` seconds
            /// (or of its whole emission, if shorter), plus its burst.
            var peakAlive: Int {
                Int(ceil(birthRate * min(emitSeconds, maxLife))) + burstCount
            }
        }

        /// Behind the ribbon's head while it flies (0.10–1.90 s).
        var trail: Emitter
        /// Swept back along the ribbon's body as it breaks up (1.90–2.20 s).
        var dissolve: Emitter
        /// The closing glint's handful of motes (1.90 s).
        var sparkle: Emitter

        /// Twinkle: the eight frames' brightnesses (one soft dot each) and the rate range in Hz.
        var twinkleFrames: [Float]
        var twinkleHz: ClosedRange<Float>

        static let standard = GoldDustSpec(
            trail: Emitter(birthRate: 95, emitSeconds: 1.8, lifeSpan: 1.1, lifeSpanVariation: 0.5,
                           size: 0.0026, sizeVariation: 0.0009, speed: 0.012, speedVariation: 0.010,
                           fall: 0.030, damping: 2.2, spread: 0.004, streak: 0.016),
            dissolve: Emitter(birthRate: 560, emitSeconds: 0.30, lifeSpan: 0.95, lifeSpanVariation: 0.35,
                              size: 0.0024, sizeVariation: 0.0007, speed: 0.020, speedVariation: 0.014,
                              fall: 0.040, damping: 1.8, spread: 0.005, streak: 0.032),
            sparkle: Emitter(birthRate: 0, emitSeconds: 0, burstCount: 22, lifeSpan: 0.8, lifeSpanVariation: 0.2,
                             size: 0.0028, sizeVariation: 0.0008, speed: 0.060, speedVariation: 0.030,
                             fall: 0.050, damping: 2.6, spread: 0.003),
            // A twinkle is a quick brightening and a slower fall-off: bright, then down, then back up.
            twinkleFrames: [1.00, 0.72, 0.46, 0.30, 0.24, 0.32, 0.52, 0.80],
            twinkleHz: 3...8)

        /// The budget line: every mote the recognition can have alive at once, all emitters together.
        var peakAlive: Int { trail.peakAlive + dissolve.peakAlive + sparkle.peakAlive }

        /// **v4 B1** `--ribbon-dust <×>`: the same motes, `k` times as many — birth rates and the closing burst scale,
        /// sizes, lives and motion do not (so ×1 is exactly `standard`, and the budget line scales with it: A2's 342
        /// peak leaves room up to ≈ ×1.16 inside the scene's 400).
        func scaled(by k: Float) -> GoldDustSpec {
            let k = k.isFinite ? max(0, k) : 1
            guard k != 1 else { return self }
            var s = self
            s.trail.birthRate *= k
            s.dissolve.birthRate *= k
            s.sparkle.burstCount = Int((Float(s.sparkle.burstCount) * k).rounded())
            return s
        }

        /// Image-sequence frame rate (frames/s) and its ± variation that spans `twinkleHz`.
        var frameRate: Float { Float(twinkleFrames.count) * (twinkleHz.lowerBound + twinkleHz.upperBound) / 2 }
        var frameRateVariation: Float { Float(twinkleFrames.count) * (twinkleHz.upperBound - twinkleHz.lowerBound) / 2 }
    }
}
