import Foundation

extension V4 {
    /// **The name card's idle sweep** (art bible §2: "每 8–12 s 一道斜向扫光"): a diagonal light crosses the card
    /// every 8–12 s, drawn from a seeded generator so a take can be reproduced frame for frame. The value it returns is
    /// the materials' `sweep` parameter: 0 → 1 across the card in `duration` seconds, then resting at 1 (past the far
    /// corner, invisible) until the next one; the jump back to 0 happens off the card, so it never pops.
    struct SweepSchedule {
        static let interval: ClosedRange<Double> = 8...12
        static let duration: Double = 1.4

        private var state: UInt64
        private(set) var time: Double = 0
        /// When the current (or next) sweep starts.
        private(set) var start: Double

        /// `firstDelay`: how long after the card settles the first sweep comes (the reveal has its own light).
        init(seed: UInt64 = 0x5EED_CA4D, firstDelay: Double = 2.5) {
            state = seed
            start = firstDelay
        }

        /// Advances by `dt` seconds and returns the sweep parameter for this frame.
        mutating func advance(by dt: Double) -> Float {
            time += max(0, dt)
            while time >= start + Self.duration {
                start += nextInterval()
            }
            guard time >= start else { return 1 }
            let x = Float((time - start) / Self.duration)
            return V4.MaterialsLabClock.easeInOut(x)
        }

        /// Start-to-start time to the next sweep, uniform in `interval` (always longer than a sweep lasts).
        private mutating func nextInterval() -> Double {
            // SplitMix64: tiny, fast, good enough to decorrelate intervals, and identical on every device.
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            let unit = Double(z >> 11) / Double(1 << 53)
            return Self.interval.lowerBound + unit * (Self.interval.upperBound - Self.interval.lowerBound)
        }
    }
}
