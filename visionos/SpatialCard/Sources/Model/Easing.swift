import Foundation

/// The curve library every tween in the app shares (`TweenComponent.easing`, the box scan's clock, the
/// deck's springs). Pure `Foundation` maths and nothing else, so the timelines that depend on its exact
/// shape — `BoxScanTimelineTests` asks where the scan band stands at 0.5 s — can be checked without a
/// RealityKit scene. It used to live at the top of `Effects/FXSystems.swift`, which cannot be compiled
/// into the test target because the rest of that file is components and systems.
enum Easing {
    case linear
    case easeOutCubic
    case easeInCubic
    case easeInOutCubic
    case easeOutQuint
    /// Overshoots the target slightly before settling (classic "back" ease).
    case easeOutBack
    /// Softer overshoot for large panels.
    case easeOutBackSoft
    case easeInQuint
    /// Analytic damped spring (SwiftUI-style response/damping). `t` is normalised so the spring
    /// settles within the tween duration; ~3 % overshoot at damping 0.8.
    case spring(response: Float, damping: Float)

    func apply(_ t: Float) -> Float {
        let t = max(0, min(1, t))
        switch self {
        case .linear: return t
        case .easeOutCubic: return 1 - pow(1 - t, 3)
        case .easeInCubic: return t * t * t
        case .easeInOutCubic: return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        case .easeOutQuint: return 1 - pow(1 - t, 5)
        case .easeInQuint: return t * t * t * t * t
        case .easeOutBack:
            let c1: Float = 1.70158, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .easeOutBackSoft:
            let c1: Float = 0.9, c3 = c1 + 1
            return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
        case .spring(let response, let damping):
            // Under-damped oscillator: x(t) = 1 - e^{-ζωt}(cos ωd t + (ζω/ωd) sin ωd t), scaled so the
            // motion has essentially settled at t = 1 for the given response.
            let omega = 2 * Float.pi / max(0.05, response)
            let zeta = max(0.05, min(0.999, damping))
            let wd = omega * sqrt(1 - zeta * zeta)
            let time = t * response * 1.9
            let decay = exp(-zeta * omega * time)
            let x = 1 - decay * (cos(wd * time) + (zeta * omega / wd) * sin(wd * time))
            // Blend the last 10 % toward exactly 1 so tweens end clean.
            let settle = max(0, (t - 0.9) / 0.1)
            return x * (1 - settle) + settle
        }
    }
}
