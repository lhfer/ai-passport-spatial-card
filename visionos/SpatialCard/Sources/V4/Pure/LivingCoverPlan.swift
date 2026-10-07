import Foundation
import simd

extension V4 {
    /// How a note cover is shown (A3 目标 2).
    enum CoverMode: String, CaseIterable, Sendable {
        /// Apple's spatial scene: `ImagePresentationComponent.Spatial3DImage` generated from the flat cover.
        case scene
        /// The subject cut out (Vision's foreground instance mask) and lifted off a blurred background.
        case lift
        /// The cover as a flat texture — always possible.
        case flat
    }

    /// What `--cover-mode` (or the product) asks for.
    enum CoverRequest: String, CaseIterable, Sendable {
        case auto, scene, lift, flat

        /// `--cover-mode <value>`; anything unknown is `auto`.
        init(argument: String?) {
            self = argument.flatMap(CoverRequest.init(rawValue:)) ?? .auto
        }
    }

    /// What this device turned out to be able to do. Each capability starts `.unknown` and the first attempt settles
    /// it: on the simulator `Spatial3DImage.generate()` throws `unableToGenerateSpatial3DImage` within a millisecond
    /// and Vision cannot create its inference context, so every later cover skips those attempts instead of paying
    /// for them again (and the log says why, once).
    struct CoverCapabilities: Equatable, Sendable {
        enum State: Equatable, Sendable {
            case unknown
            case available
            case unavailable(String)

            var isUnavailable: Bool {
                if case .unavailable = self { return true }
                return false
            }
        }

        var scene: State = .unknown
        /// Vision's foreground instance mask, run live on this device.
        var liveMask: State = .unknown
    }

    enum CoverPlanner {
        /// The modes to try for a request, best first.
        ///
        /// - `auto`: spatial scene unless it is known to fail here, then subject lift, then flat.
        /// - `lift`: the lift, and flat when there is no liftable subject.
        /// - `scene`: only the scene. An explicit request is a test of the presentation itself, so a failed
        ///   generate leaves the `ImagePresentationComponent` showing its mono image rather than quietly swapping
        ///   in another mode (the log carries the error).
        /// - `flat`: flat.
        static func attempts(for request: CoverRequest, capabilities: CoverCapabilities) -> [CoverMode] {
            switch request {
            case .flat: return [.flat]
            case .lift: return [.lift, .flat]
            case .scene: return [.scene]
            case .auto:
                return capabilities.scene.isUnavailable ? [.lift, .flat] : [.scene, .lift, .flat]
            }
        }
    }

    /// Statistics of a foreground mask, and whether what it found is a *subject* worth lifting.
    ///
    /// Vision's foreground model happily returns things that are not subjects. On the bundled fake covers it picks
    /// the diagonal light band of covers 1 and 2 — a strip that runs from the left edge to the right edge — and on a
    /// photo filled by its subject it returns 90 % of the frame. Lifting either is worse than not lifting: the band
    /// floats as a ribbon cut off at both frame edges, the full-frame mask just moves the whole picture forward.
    struct CoverMaskStats: Equatable, Sendable {
        /// Fraction of pixels at or above the threshold.
        var coverage: Float
        /// Normalised bounds (minX, minY, maxX, maxY; y down), nil when the mask is empty.
        var bounds: SIMD4<Float>?
        /// Fraction of each edge's pixels inside the mask: left, right, top, bottom.
        var edgeContact: SIMD4<Float>

        enum Verdict: Equatable, Sendable {
            case lift
            case empty
            case tooSmall
            case tooLarge
            /// The mask reaches two opposite edges: a band or a backdrop, not a subject.
            case spansFrame
        }

        struct Limits: Equatable, Sendable {
            var minCoverage: Float = 0.02
            var maxCoverage: Float = 0.80
            /// An edge counts as touched when at least this fraction of it is in the mask.
            var edgeTouch: Float = 0.05
        }

        func verdict(_ limits: Limits = Limits()) -> Verdict {
            guard bounds != nil, coverage > 0 else { return .empty }
            if coverage < limits.minCoverage { return .tooSmall }
            if coverage > limits.maxCoverage { return .tooLarge }
            let touch = edgeContact .>= SIMD4<Float>(repeating: limits.edgeTouch)
            if (touch[0] && touch[1]) || (touch[2] && touch[3]) { return .spansFrame }
            return .lift
        }

        /// Measures an 8-bit mask (`rowBytes` may exceed `width` for padded buffers).
        static func measure(_ pixels: [UInt8], width: Int, height: Int, rowBytes: Int? = nil,
                            threshold: UInt8 = 128) -> CoverMaskStats {
            let stride = rowBytes ?? width
            guard width > 0, height > 0, pixels.count >= stride * (height - 1) + width else {
                return CoverMaskStats(coverage: 0, bounds: nil, edgeContact: .zero)
            }
            var count = 0
            var minX = width, minY = height, maxX = -1, maxY = -1
            var left = 0, right = 0, top = 0, bottom = 0
            for y in 0..<height {
                let row = y * stride
                for x in 0..<width where pixels[row + x] >= threshold {
                    count += 1
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                    if x == 0 { left += 1 }
                    if x == width - 1 { right += 1 }
                    if y == 0 { top += 1 }
                    if y == height - 1 { bottom += 1 }
                }
            }
            let contact = SIMD4<Float>(Float(left) / Float(height), Float(right) / Float(height),
                                       Float(top) / Float(width), Float(bottom) / Float(width))
            guard count > 0 else { return CoverMaskStats(coverage: 0, bounds: nil, edgeContact: contact) }
            let bounds = SIMD4<Float>(Float(minX) / Float(width), Float(minY) / Float(height),
                                      Float(maxX + 1) / Float(width), Float(maxY + 1) / Float(height))
            return CoverMaskStats(coverage: Float(count) / Float(width * height), bounds: bounds, edgeContact: contact)
        }
    }

    /// Geometry of the two-layer lift (brief: 前景层抬高 8–15 mm，背景层轻微放大并模糊).
    struct CoverParallax: Equatable, Sendable {
        /// The cover's size in the frame (metres).
        var size: SIMD2<Float>
        /// How far the cut-out subject floats in front of the background (the brief's 8–15 mm).
        var lift: Float = 0.012
        /// Largest viewing angle the layers must hold without the subject visibly sliding off its hole: the
        /// lab's ±20° sway plus head motion.
        var maxAngle: Float = 35 * .pi / 180

        static let liftRange: ClosedRange<Float> = 0.008...0.015

        /// The lift, clamped into the brief's range.
        var clampedLift: Float { min(max(lift, Self.liftRange.lowerBound), Self.liftRange.upperBound) }

        /// Sideways slide of the subject over its background at `maxAngle` (metres): lift · tan(angle).
        var maxSlide: Float { clampedLift * tan(maxAngle) }

        /// Zoom of the background texture. The hole the subject leaves is filled with blurred surroundings, but its
        /// rim still carries some of the subject's colour; zooming the background by the slide the subject can make
        /// pushes that rim outwards as fast as the subject moves over it, so what the eye sees at an angle is fill,
        /// not a ghost. Kept between 2 % and 8 % — beyond that the zoom reads as a crop.
        var backgroundZoom: Float {
            let fraction = 2 * maxSlide / max(1e-4, min(size.x, size.y))
            return 1 + min(0.08, max(0.02, fraction))
        }

        /// Width of the fade that dissolves the subject into the frame near the cover's border, as a fraction of the
        /// shorter side: at least the slide, so a subject cut by the frame edge never shows its cut at an angle.
        var borderFade: Float {
            min(0.12, max(0.03, maxSlide / max(1e-4, min(size.x, size.y)) * 1.5))
        }

        /// Offset of the subject's soft shadow on the background (metres in the cover's plane, +x right, +y up): a key
        /// light from above and a little to the left — the desk lamp of the style frames — so the shadow falls down
        /// and slightly right, growing with the lift like a real one.
        var shadowOffset: SIMD2<Float> { [0.08 * clampedLift, -0.16 * clampedLift] }
    }
}
