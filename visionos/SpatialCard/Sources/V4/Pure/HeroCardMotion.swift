import Foundation

extension V4 {
    /// The hero card's motion curves, closed-form and in **seconds** (art bible §3).
    ///
    /// Why not `Easing.spring` or `TweenComponent`: the entrance is evaluated as a pure function of time — the lab
    /// scrubs it, freezes it for screenshots (`--card-freeze`) and restarts it on a tap — and the tests ask exact
    /// questions of it ("how far past the target does the card go?"). `Easing.spring` squeezes a spring into a 0…1
    /// tween, so its overshoot and settle depend on the tween's duration; here `response` and `damping` mean exactly
    /// what they mean in SwiftUI's `.spring(response:dampingFraction:)`, whatever the clock.
    enum HeroCardMotion {
        /// Step response of an under-damped spring released from rest at 0 towards 1.
        ///
        ///     x(t) = 1 − e^(−ζωt) · (cos ω_d t + ζ/√(1−ζ²) · sin ω_d t),  ω = 2π / response,  ω_d = ω√(1−ζ²)
        ///
        /// 0 for t ≤ 0. Peak overshoot is `overshoot(damping:)`, reached at t = π / ω_d.
        static func spring(_ t: Double, response: Double, damping: Double) -> Double {
            guard t > 0 else { return 0 }
            let zeta = min(max(damping, 0.05), 0.999)
            let omega = 2 * Double.pi / max(response, 0.01)
            let root = (1 - zeta * zeta).squareRoot()
            let wd = omega * root
            return 1 - exp(-zeta * omega * t) * (cos(wd * t) + zeta / root * sin(wd * t))
        }

        /// The same spring **chasing a target that ramps from 0 to 1 over `ramp` seconds** instead of jumping there.
        ///
        /// A spring released onto a step does 90 % of its travel in ≈ 0.25 s at the bible's slowest response (0.50):
        /// right for a pop, too abrupt for the card's 22 cm rise out of the screen (a big move: 0.8–1.6 s). Driving it
        /// along a ramp keeps the spring's character — the zero-velocity start, the 2–6 % overshoot, the settle — and
        /// stretches the travel. Closed form: with I(u) = ∫₀ᵘ (1 − step(s)) ds (the step response's accumulated lag),
        /// G(u) = u − I(u) and y(t) = (G(t) − G(t − ramp)) / ramp.
        static func rampedSpring(_ t: Double, ramp: Double, response: Double, damping: Double) -> Double {
            guard t > 0 else { return 0 }
            guard ramp > 1e-4 else { return spring(t, response: response, damping: damping) }
            let zeta = min(max(damping, 0.05), 0.999)
            let omega = 2 * Double.pi / max(response, 0.01)
            let a = zeta * omega, b = omega * (1 - zeta * zeta).squareRoot()
            func lag(_ u: Double) -> Double {           // I(u)
                guard u > 0 else { return 0 }
                let e = exp(-a * u)
                return (e * ((b - a * a / b) * sin(b * u) - 2 * a * cos(b * u)) + 2 * a) / (omega * omega)
            }
            func g(_ u: Double) -> Double { u > 0 ? u - lag(u) : 0 }
            return (g(t) - g(t - ramp)) / ramp
        }

        /// How far past 1 a spring goes (0.038 = 3.8 %). The bible asks for 2–6 %.
        static func overshoot(damping: Double) -> Double {
            let zeta = min(max(damping, 0.05), 0.999)
            return exp(-zeta * Double.pi / (1 - zeta * zeta).squareRoot())
        }

        /// Anticipation, then the spring (the bible's "预备 60–120 ms、3–6 % 的反向动作").
        ///
        /// Over `lead` seconds the value eases from 0 to −`depth` (sine in-out: it arrives with zero velocity, so the
        /// spring that takes over from there starts from rest and nothing kinks), then springs from −`depth` to 1.
        static func anticipatedSpring(_ t: Double, lead: Double, depth: Double, response: Double, damping: Double) -> Double {
            guard t > 0 else { return 0 }
            if t < lead { return -depth * easeInOutSine(t / lead) }
            return -depth + (1 + depth) * spring(t - lead, response: response, damping: damping)
        }

        static func easeInOutSine(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return 0.5 - 0.5 * cos(Double.pi * c)
        }

        static func easeInCubic(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return c * c * c
        }

        static func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> Double {
            guard e1 != e0 else { return x < e0 ? 0 : 1 }
            let t = min(max((x - e0) / (e1 - e0), 0), 1)
            return t * t * (3 - 2 * t)
        }

        /// A bump that is 0 at both ends of [0, 1] and 1 in the middle: sin(π x). The arc of a flight.
        static func arc(_ x: Double) -> Double {
            sin(Double.pi * min(max(x, 0), 1))
        }
    }
}
