import Foundation

extension V4 {
    /// **Where the head is when** (v4 A2): distance along a `RibbonSpline` as a function of time.
    ///
    /// A timing is a list of pieces, each running from `(t0, s0)` to `(t1, s1)` along a normalised curve
    /// f: 0…1 → 0…1. Two kinds of curve:
    /// - `.eased`: any curve of the app's shared `Easing` library (what `play(path:duration:easing:)` takes);
    /// - `.cubic`: f(x) = a·x + b·x² + c·x³ with f(1) = 1 — the curve the recognition uses, because it can be
    ///   solved for a *given end speed*, which is how the spiral hands over to the outline without a jolt.
    ///
    /// The ribbon's body needs the inverse too — "when did the head pass this point?" is the age of that point
    /// of the ribbon, and the age is what fades it — so the timing keeps a table of distance at 480 Hz, made
    /// monotonic (an overshooting easing never walks the head backwards through its own trail), and inverts it
    /// by binary search.
    struct RibbonTiming {
        enum Curve {
            case eased(Easing)
            /// f(x) = a·x + b·x² + c·x³; the caller guarantees a + b + c = 1 (see `speedMatched`).
            case cubic(a: Float, b: Float, c: Float)

            func apply(_ x: Float) -> Float {
                let x = max(0, min(1, x))
                switch self {
                case .eased(let easing): return easing.apply(x)
                case .cubic(let a, let b, let c): return ((c * x + b) * x + a) * x
                }
            }

            /// f'(x), used by the speed checks (numeric for the eased curves).
            func slope(_ x: Float) -> Float {
                switch self {
                case .eased(let easing):
                    let h: Float = 1e-3
                    let lo = max(0, x - h), hi = min(1, x + h)
                    return (easing.apply(hi) - easing.apply(lo)) / max(1e-6, hi - lo)
                case .cubic(let a, let b, let c):
                    return a + 2 * b * x + 3 * c * x * x
                }
            }
        }

        struct Piece {
            var t0: Float
            var t1: Float
            var s0: Float
            var s1: Float
            var curve: Curve
        }

        let pieces: [Piece]
        /// Table resolution. 480 Hz keeps the age of a ribbon point within ≈ 1 ms at any head speed.
        static let tableRate: Float = 480
        private let tableStart: Float
        private let distances: [Float]

        init(pieces: [Piece]) {
            self.pieces = pieces.sorted { $0.t0 < $1.t0 }
            let start = self.pieces.first?.t0 ?? 0
            let end = self.pieces.last?.t1 ?? start
            tableStart = start
            let count = max(2, Int(ceil((end - start) * Self.tableRate)) + 1)
            var table: [Float] = []
            table.reserveCapacity(count)
            var running = -Float.greatestFiniteMagnitude
            for k in 0..<count {
                let t = start + Float(k) / Self.tableRate
                running = max(running, Self.rawDistance(self.pieces, at: min(t, end)))
                table.append(running)
            }
            distances = table
        }

        /// A single eased run over a path of `length`: the `play(path:duration:easing:)` timing.
        static func eased(length: Float, duration: Float, delay: Float = 0, easing: Easing = .easeInOutCubic) -> RibbonTiming {
            RibbonTiming(pieces: [Piece(t0: delay, t1: delay + max(0.001, duration), s0: 0, s1: length, curve: .eased(easing))])
        }

        /// The cubic that starts at relative speed `startSlope` and ends at `endSlope` (both as f'(x), i.e.
        /// multiples of the piece's average speed). It is a Hermite cubic with those end slopes, so the
        /// Fritsch–Carlson bound applies: with both slopes ≥ 0 and startSlope² + endSlope² ≤ 9 it never runs
        /// backwards — `V4RibbonTimingTests` checks the recognition's slopes against it.
        static func speedMatched(startSlope: Float, endSlope: Float) -> Curve {
            let a = startSlope
            let c = endSlope + startSlope - 2
            let b = 1 - a - c
            return .cubic(a: a, b: b, c: c)
        }

        var start: Float { pieces.first?.t0 ?? 0 }
        var end: Float { pieces.last?.t1 ?? 0 }
        var totalDistance: Float { distances.last ?? 0 }

        /// Distance of the head at time `t` (clamped before the start and after the end).
        func distance(at t: Float) -> Float {
            let x = (t - tableStart) * Self.tableRate
            if x <= 0 { return distances[0] }
            let i = Int(x)
            if i >= distances.count - 1 { return distances[distances.count - 1] }
            let f = x - Float(i)
            return distances[i] + (distances[i + 1] - distances[i]) * f
        }

        /// Head speed (distance per second) at `t`, from the exact curve rather than the table.
        func speed(at t: Float) -> Float {
            guard let piece = pieces.first(where: { t >= $0.t0 && t <= $0.t1 }) else { return 0 }
            let span = max(1e-6, piece.t1 - piece.t0)
            return (piece.s1 - piece.s0) / span * piece.curve.slope((t - piece.t0) / span)
        }

        /// `time(atDistance:)` walking from `hint` (a table index) — for distances that move monotonically from
        /// one call to the next, as a ribbon's samples do. Same result as the bisection.
        func time(atDistance s: Float, hint: inout Int) -> Float {
            let last = distances.count - 1
            if s <= distances[0] { hint = 0; return tableStart }
            if s >= distances[last] { return time(atDistance: s) }
            var lo: Int
            if hint < 0 || hint > last - 1 {
                // No usable hint (the first call): bisect for the last entry below s.
                lo = 0
                var hi = last
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if distances[mid] < s { lo = mid } else { hi = mid }
                }
            } else {
                lo = hint
            }
            // Invariant sought: distances[lo] < s <= distances[lo + 1] (the first entry to reach s).
            while lo > 0, distances[lo] >= s { lo -= 1 }
            while lo < last - 1, distances[lo + 1] < s { lo += 1 }
            hint = lo
            let span = distances[lo + 1] - distances[lo]
            let f = span > 1e-9 ? (s - distances[lo]) / span : 0
            return tableStart + (Float(lo) + f) / Self.tableRate
        }

        /// The first time the head reached distance `s` (the start time for s ≤ the first distance).
        func time(atDistance s: Float) -> Float {
            if s <= distances[0] { return tableStart }
            if s >= distances[distances.count - 1] {
                // First table entry that reached the end.
                var lo = 0, hi = distances.count - 1
                let target = distances[distances.count - 1]
                while hi - lo > 1 {
                    let mid = (lo + hi) / 2
                    if distances[mid] >= target { hi = mid } else { lo = mid }
                }
                return tableStart + Float(hi) / Self.tableRate
            }
            var lo = 0, hi = distances.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if distances[mid] < s { lo = mid } else { hi = mid }
            }
            let span = distances[hi] - distances[lo]
            let f = span > 1e-9 ? (s - distances[lo]) / span : 0
            return tableStart + (Float(lo) + f) / Self.tableRate
        }

        private static func rawDistance(_ pieces: [Piece], at t: Float) -> Float {
            guard let first = pieces.first else { return 0 }
            if t <= first.t0 { return first.s0 }
            for piece in pieces where t <= piece.t1 {
                if t < piece.t0 { return piece.s0 }
                let span = max(1e-6, piece.t1 - piece.t0)
                return piece.s0 + (piece.s1 - piece.s0) * piece.curve.apply((t - piece.t0) / span)
            }
            return pieces.last?.s1 ?? 0
        }
    }
}
