import Foundation

extension V4 {
    /// **v4 B5 §2 — how many particles are alive, frame by frame.**
    ///
    /// RealityKit reports no live particle count. The `[perf] scene:` census multiplies each emitting emitter's
    /// `birthRate × lifeSpan` — the *steady state* an emitter settles at — which is right for the resident motes and
    /// badly wrong for a transition: ten note trails switch on for 0.55 s each, 60 ms apart, and a spark lives 0.8 s, so
    /// none of them is ever in its steady state. The ledger keeps what was actually born and when (emitters per frame,
    /// bursts as they fire) and counts what has not yet lived out its life — the number the brief asks for at the peak of
    /// a fan-out.
    struct ParticleLedger {
        /// One batch of births: when, how many, and how long each lives.
        private struct Batch {
            var time: Double
            var count: Double
            var life: Double
        }

        private var batches: [Batch] = []

        init() {}

        /// An emitter emitted for `dt` seconds at `rate` per second (its main emitter, plus whatever its spawned emitter
        /// adds — the caller folds that into `rate` and `life`).
        mutating func emit(rate: Double, dt: Double, life: Double, at time: Double) {
            guard rate > 0, dt > 0, life > 0, rate.isFinite, dt.isFinite, life.isFinite else { return }
            batches.append(Batch(time: time, count: rate * dt, life: life))
        }

        /// A one-shot burst (`ParticleEmitterComponent.burst()`): `count` particles at once.
        mutating func burst(count: Double, life: Double, at time: Double) {
            guard count > 0, life > 0, count.isFinite, life.isFinite else { return }
            batches.append(Batch(time: time, count: count, life: life))
        }

        /// Particles born and not yet dead at `time` (and the dead are forgotten).
        mutating func alive(at time: Double) -> Double {
            batches.removeAll { time - $0.time >= $0.life }
            return batches.reduce(0) { $0 + $1.count }
        }

        var isEmpty: Bool { batches.isEmpty }
    }

    /// **v4 B5 §2.** Peaks and averages of one quantity over a window's frames.
    struct FrameStat: Equatable {
        private(set) var frames = 0
        private(set) var sum: Double = 0
        private(set) var peak: Double = 0

        init() {}

        mutating func add(_ value: Double) {
            guard value.isFinite else { return }
            frames += 1
            sum += value
            peak = max(peak, value)
        }

        var average: Double { frames > 0 ? sum / Double(frames) : 0 }
    }
}
