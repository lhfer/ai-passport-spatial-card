import Foundation

extension V4 {
    /// **The follower count's odometer**: 0 → target over 1.2 s, fast then slow (brief §5), as reels.
    ///
    /// The value follows an ease-out of power 4, so most of the number arrives in the first half second and the last
    /// few followers tick in one by one — the slot-machine landing that makes a count feel *earned*.
    ///
    /// Each reel counts the steps its column has taken — column c steps every time the count crosses a multiple of
    /// 10^c — and **every step is a roll of `rollDuration` that starts the moment the count crosses it**:
    ///
    ///     W_c(t) = Σ_k s((t − t_k) / d),   t_k = when the count reaches k · 10^c,   s = smoothstep,   d = 90 ms
    ///
    /// so a reel is never ahead of the count (round 3's value-based "lazy carry" read 4,991 while the count was
    /// 3,891) and never jumps (a carry into the thousands at 14,000 followers/s would otherwise be an 8 ms cut).
    /// Consequences:
    /// - a slow column rests on its digit and rolls to the next in 90 ms;
    /// - a fast column's rolls overlap into a continuous spin — the view blurs it by `speed(column:at:)`, and the reels
    ///   come into focus left to right as the count decelerates (hundreds ≈ 0.7 s, tens ≈ 1.0, ones ≈ 1.1);
    /// - every reel lands exactly on its digit of the target, one roll after the count ends (`landing`).
    ///
    /// Where many steps fall inside one roll (a column spinning at hundreds of digits a second) the sum is replaced
    /// by its continuum, E[value(t − d·U)] / 10^c with U ~ s′ — a smoothing of the count, so it can never be ahead of
    /// it either — blended in smoothly between `denseSteps` × ⅔ and × 4⁄3 steps per roll, where the view has the
    /// column fully blurred. (Round 3's first cut subtracted the floor's average half-step from the continuum and
    /// switched abruptly: the reel jumped back 0.6 of a digit at the switch.)
    ///
    /// Leading zeros are drawn as dim "ghost" reels that light up as the count rolls into them: the layout never
    /// jumps (a real odometer shows every wheel), and 0,00**0** still reads as "0".
    struct HeroCardOdometer: Equatable {
        var target: Int
        /// **v4 B1**: where the count starts. 0 for the entrance (A4); the number already on the card when the live
        /// follower count changes (`HeroCardRig.setFollowers(from:to:)`), so only the columns that change roll —
        /// +1 on 4,401 turns the ones reel one step and leaves 4,40 standing.
        var start: Int = 0
        var duration: Double = 1.2
        /// Power of the ease-out (4 = quart).
        var exponent: Double = 4
        /// How long one digit takes to roll to the next.
        var rollDuration: Double = 0.09
        /// Above this many steps inside one roll, a column is summed as a continuum.
        var denseSteps = 24

        /// A count **down** (a lost follower) is not rolled: the reels would have to run backwards through the sum
        /// below, which is written for a count that only grows. It snaps to the target instead (`start` = `target`).
        init(target: Int, duration: Double = 1.2, start: Int = 0) {
            self.target = max(0, target)
            self.start = min(max(0, start), self.target)
            self.duration = duration
        }

        /// When the last reel has finished rolling onto the target.
        var landing: Double { duration + rollDuration }

        var digitCount: Int { max(1, String(target).count) }

        /// Followers the count adds, start → target.
        var span: Double { Double(target - start) }

        /// Normalised progress 0…1 of the count.
        func progress(at t: Double) -> Double {
            guard duration > 0 else { return 1 }
            let x = min(max(t / duration, 0), 1)
            return 1 - pow(1 - x, exponent)
        }

        /// The count as a continuous number (start … target).
        func value(at t: Double) -> Double { Double(start) + span * progress(at: t) }

        /// What the count reads at `t`, as an integer (for the numericText variant and for logs).
        func displayed(at t: Double) -> Int { min(target, Int(value(at: t).rounded(.down))) }

        /// d value / dt, followers per second.
        func rate(at t: Double) -> Double {
            guard duration > 0, t > 0, t < duration else { return 0 }
            let x = t / duration
            return span * exponent * pow(1 - x, exponent - 1) / duration
        }

        /// When the count reaches `v` (inverse of `value`).
        func time(reaching v: Double) -> Double {
            guard span > 0 else { return 0 }
            let f = min(max((v - Double(start)) / span, 0), 1)
            return duration * (1 - pow(1 - f, 1 / exponent))
        }

        /// Where reel `column` stands before the count starts: on the start value's digit.
        func startPosition(column: Int) -> Double {
            floor(Double(start) / pow(10, Double(column)) + 1e-9)
        }

        // MARK: Reels

        /// Steps column `column` has taken by `t` (a step = the count crossing a multiple of 10^column).
        func steps(column: Int, at t: Double) -> Double {
            floor(value(at: t) / pow(10, Double(column)) + 1e-9)
        }

        /// Unwrapped position of the reel for decimal column `column` (0 = ones): the digit shown is this mod 10,
        /// the fraction is how far it has rolled towards the next one.
        func reelPosition(column: Int, at t: Double) -> Double {
            guard t > 0 else { return startPosition(column: column) }
            let d = rollDuration
            let unit = pow(10, Double(column))
            // How many steps one roll spans at the current rate (continuous and, the rate only ever falling, the blend
            // only ever moves towards the exact sum). Not the steps inside the last roll: just after t = 0 that window
            // reaches back before the count began, and the weight swung while the two models disagreed.
            let span = rate(at: t) * d / unit
            let dense = Double(denseSteps)
            let w = HeroCardMotion.smoothstep(dense * 2 / 3, dense * 4 / 3, span)
            var exact = 0.0, continuum = 0.0
            if w < 1 {
                let now = steps(column: column, at: t)
                let before = steps(column: column, at: t - d)
                exact = before
                if now > before {
                    for k in Int(before) + 1...Int(now) {
                        exact += HeroCardMotion.smoothstep(0, 1, (t - time(reaching: Double(k) * unit)) / d)
                    }
                }
            }
            if w > 0 {
                // E[value(t − d·U)] / unit, U ~ s′ = 6u(1 − u): 5-point Gauss–Legendre on [0, 1] (weights sum to 1).
                let nodes: [(u: Double, w: Double)] = [(0.046910, 0.118463), (0.230765, 0.239314), (0.5, 0.284444),
                                                       (0.769235, 0.239314), (0.953090, 0.118463)]
                for node in nodes {
                    continuum += node.w * 6 * node.u * (1 - node.u) * value(at: t - d * node.u) / unit
                }
            }
            return exact * (1 - w) + continuum * w
        }

        /// The digit (0…9) a reel is on, and how far (0…1) it has rolled towards the next.
        func reel(column: Int, at t: Double) -> (digit: Int, roll: Double) {
            let p = reelPosition(column: column, at: t)
            let whole = floor(p)
            let digit = Int(whole.truncatingRemainder(dividingBy: 10))
            return ((digit + 10) % 10, p - whole)
        }

        /// Average spin rate of a reel, digits per second — what the view's motion blur keys on (the rolls lag the
        /// count by half a roll on average).
        func speed(column: Int, at t: Double) -> Double {
            rate(at: t - rollDuration / 2) / pow(10, Double(column))
        }

        /// 0 while column `column` is a leading zero, 1 once the count has grown into it (the ones column is always
        /// lit). The reel lights up while it rolls 0 → 1, so the digit and its light arrive together.
        func lit(column: Int, at t: Double) -> Double {
            guard column > 0 else { return 1 }
            return min(1, max(0, reelPosition(column: column, at: t)))
        }

        // MARK: Gold dust

        /// A moment the count carries into one of its two leading columns ("每进一位"), or lands.
        struct Pop: Equatable {
            var time: Double
            /// Decimal column the dust pops over (0 = ones).
            var column: Int
            /// Motes: 1 on a carry into the second column, 2 on one into the leading column and on the landing.
            var count: Int
            var isLanding: Bool
        }

        /// Carries into the two leading columns, thinned so no two pops are closer than `minSpacing` (the first
        /// thousand arrives in 75 ms — ten carries — which would otherwise be a spray, not a rhythm), then the landing.
        /// A carry pops half-way through its roll, as the new digit comes up; one that moves both leading columns
        /// (…999 → …000) pops over the higher one.
        func pops(minSpacing: Double = 0.08) -> [Pop] {
            guard target > start else { return [Pop(time: landing, column: 0, count: 2, isLanding: true)] }
            let top = digitCount - 1
            var carries: [Pop] = []
            for column in Swift.max(1, top - 1)...Swift.max(1, top) where column <= top {
                let unit = pow(10, Double(column))
                // v4 B1: only the carries this count actually crosses (from the start value up).
                let first = Int(Double(start) / unit) + 1
                let steps = Int(Double(target) / unit)
                guard steps >= first else { continue }
                for k in first...steps {
                    // Two motes when the leading digit turns over, one for the column under it.
                    carries.append(Pop(time: time(reaching: Double(k) * unit) + rollDuration / 2, column: column,
                                       count: column == top ? 2 : 1, isLanding: false))
                }
            }
            // Same instant in two columns → keep the higher column.
            carries.sort { $0.time == $1.time ? $0.column > $1.column : $0.time < $1.time }
            var kept: [Pop] = []
            for pop in carries {
                if let last = kept.last, pop.time - last.time < minSpacing {
                    // Too close: a new thousand beats the hundreds pop just before it (moving later only widens the
                    // gap to the pop before that one).
                    if pop.column > last.column {
                        kept[kept.count - 1] = pop
                    }
                    continue
                }
                kept.append(pop)
            }
            // The landing gets room of its own: drop a carry that would crowd it.
            while let last = kept.last, landing - last.time < minSpacing { kept.removeLast() }
            kept.append(Pop(time: landing, column: 0, count: 2, isLanding: true))
            return kept
        }
    }

    /// Compact follower / like counts the way Xiaohongshu prints them: 4,401 · 4.4万 · 1.2亿.
    enum HeroCardNumbers {
        static func grouped(_ n: Int) -> String {
            let digits = String(max(0, n))
            var out = ""
            for (i, ch) in digits.enumerated() {
                if i > 0, (digits.count - i) % 3 == 0 { out.append(",") }
                out.append(ch)
            }
            return out
        }

        /// 44000 → "4.4万", 9999 → "9,999", 120000000 → "1.2亿". One decimal, trailing ".0" dropped.
        static func compact(_ n: Int) -> String {
            func oneDecimal(_ x: Double) -> String {
                let rounded = (x * 10).rounded() / 10
                return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
            }
            if n >= 100_000_000 { return oneDecimal(Double(n) / 100_000_000) + "亿" }
            if n >= 10_000 { return oneDecimal(Double(n) / 10_000) + "万" }
            return grouped(n)
        }
    }
}
