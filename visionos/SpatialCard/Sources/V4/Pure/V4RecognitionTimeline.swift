import Foundation
import simd

extension V4 {
    /// **"认出" — the recognition key visual's clock and flight path** (v4 A2, style frame ①).
    ///
    /// One continuous fairy ribbon leaves the device's screen, circles the device once while climbing, and
    /// draws the card's rounded-rectangle outline above it; the outline closes with one four-point glint and
    /// the ribbon breaks up into gold dust. Everything here is in the screen frame **S** (origin at the centre
    /// of the screen, +Y the screen normal, +Z toward the reader) — the same frame as `stage.deviceFrame` in the
    /// lab and `anchorRoot` in the product — so the path drops into either unchanged.
    ///
    /// | t (s) | beat |
    /// | --- | --- |
    /// | 0.00–0.15 | the screen's own star burst (`ScreenBurst`; the real LCD plays it on the device) |
    /// | 0.10–1.20 | the ribbon rises out of the screen centre and spirals once round the device: radius 8 → 12 cm, height 2 → 20 cm, slow then fast |
    /// | 1.20–1.90 | it draws the card outline (0.27 × 0.27 m, 30 mm corners, centre 0.22 m up, leaning back 6°) |
    /// | 1.90–2.20 | the outline closes: one glint "ding", the ribbon dissolves into gold dust |
    /// | 1.90–2.40 | the drawn outline glows on for 0.5 s (the product hands over to A1's dissolve here) |
    /// | 2.40–2.70 | …and fades |
    ///
    /// The spiral hands over to the outline **at the outline's own speed** (the spiral's timing curve is
    /// solved for its end speed), so the one moment the path changes character is not also a change of pace.
    struct RecognitionTimeline {
        struct Geometry: Equatable {
            /// The card outline: mirrors `HologramLayout.cardWidth` / `cardHeight` / `cardCornerRadius` /
            /// `cardCenterHeight` / `cardTiltDegrees` (the app builds it from those; this file cannot see them —
            /// `HologramLayout` reads the bundle).
            var cardWidth: Float = 0.27
            var cardHeight: Float = 0.27
            var cornerRadius: Float = 0.030
            var cardCenterHeight: Float = 0.22
            var cardTiltDegrees: Float = -6
            /// Where the ribbon is born: just above the screen (the burst layer is 0.6 mm up).
            var launchLift: Float = 0.0012
            /// The bend from straight up into the spiral: wider than the ribbon's half width, so it never folds.
            var launchBendRadius: Float = 0.014
            /// Which way the bend leans over: from the spiral's start (+X) this many degrees toward the device's
            /// top edge (−Z), so the lead into the spiral turns evenly instead of all at its end. With the lead's
            /// handles (0.8 / 1.5 × its chord) no bend of the launch is tighter than the 14 mm bend itself and the
            /// climb never sags (a grid search over heading, handles and radius; see the A2 report).
            var launchHeadingDegrees: Float = 20
            /// The spiral, around S's +Y axis.
            var spiralStartRadius: Float = 0.08
            var spiralEndRadius: Float = 0.12
            var spiralStartHeight: Float = 0.02
            var spiralEndHeight: Float = 0.20
            var spiralTurns: Float = 1
            /// Share of the climb that is linear; the rest is quadratic, so the ribbon climbs ever faster and
            /// meets the card's right edge already heading up.
            var climbLinearShare: Float = 0.35

            static let standard = Geometry()

            var tilt: Float { cardTiltDegrees * .pi / 180 }
            var cardCenter: SIMD3<Float> { [0, cardCenterHeight, 0] }
            /// The card's right and up axes in S (a rotation of `tilt` about +X, the product's convention).
            var cardRight: SIMD3<Float> { [1, 0, 0] }
            var cardUp: SIMD3<Float> { [0, cos(tilt), sin(tilt)] }
            var cardNormal: SIMD3<Float> { [0, -sin(tilt), cos(tilt)] }

            /// A point of the card's plane from card-local (x right, y up) metres.
            func onCard(_ x: Float, _ y: Float) -> SIMD3<Float> {
                cardCenter + x * cardRight + y * cardUp
            }

            /// The desk card's outline frame.
            var outline: Outline {
                Outline(center: cardCenter, right: cardRight, up: cardUp, normal: cardNormal,
                        width: cardWidth, height: cardHeight, cornerRadius: cornerRadius)
            }
        }

        /// **The card the ribbon draws**, in S: its centre, its right / up / face-normal axes, its size and corners.
        /// The desk's card stands 0.22 m over the screen leaning back 6°; the hand's lies on the top-edge hinge at the
        /// hinge angle (v4 B4, `HandGeometry`).
        struct Outline: Equatable {
            var center: SIMD3<Float>
            var right: SIMD3<Float>
            var up: SIMD3<Float>
            var normal: SIMD3<Float>
            var width: Float
            var height: Float
            var cornerRadius: Float

            /// A point of the card's plane from card-local (x right, y up) metres.
            func on(_ x: Float, _ y: Float) -> SIMD3<Float> { center + x * right + y * up }

            /// The rectangle's four corners (before rounding): top-right, top-left, bottom-left, bottom-right.
            var corners: [SIMD3<Float>] {
                let ax = width / 2, ay = height / 2
                return [on(ax, ay), on(-ax, ay), on(-ax, -ay), on(ax, -ay)]
            }

            /// Signed distance from `p` (projected into the card's plane) to the rounded rectangle's edge, and `p`'s
            /// distance off that plane.
            func distance(to p: SIMD3<Float>) -> (edge: Float, offPlane: Float) {
                let d = p - center
                let x = simd_dot(d, right), y = simd_dot(d, up)
                let r = min(cornerRadius, min(width, height) / 2)
                let qx = abs(x) - width / 2 + r, qy = abs(y) - height / 2 + r
                let sdf = simd_length(SIMD2<Float>(max(qx, 0), max(qy, 0))) + min(max(qx, qy), 0) - r
                return (sdf, simd_dot(d, normal))
            }
        }

        struct Beats: Equatable {
            var burstStart: Float = 0
            var burstEnd: Float = 0.15
            var launch: Float = 0.10
            var outlineStart: Float = 1.20
            var closure: Float = 1.90
            var dissolveEnd: Float = 2.20
            /// The drawn outline glows this long after the closure…
            var outlineHold: Float = 0.5
            /// …and then fades over this.
            var outlineFade: Float = 0.3
            /// The ribbon's speed at launch, as a share of the spiral's average speed ("先慢后快").
            var launchSlope: Float = 0.3
            /// The outline piece's end speed, as a share of its start speed: the head eases into the closure.
            var closureSlope: Float = 0.65

            static let standard = Beats()

            var outlineGone: Float { closure + outlineHold + outlineFade }
            /// The recognition proper (the brief's ≤ 2.2 s); the outline's afterglow is the hand-over.
            var total: Float { dissolveEnd }
        }

        /// The desk geometry this timeline was built from. **A hand timeline** (`init(hand:)`) keeps the standard desk
        /// geometry here with only the outline's size and corner copied in (for the log lines that print them): where
        /// its card stands is `outline` (and `hand`), never `geometry.cardCenter`.
        let geometry: Geometry
        let beats: Beats
        /// Which flight this is: the desk's (the card stands 0.22 m over the screen) or the hand's (on the top-edge hinge).
        let place: RecognitionPlace
        /// The hand flight's geometry (nil for the desk's).
        let hand: HandGeometry?
        /// The card the ribbon draws, in S — the authoritative frame for either flight.
        let outline: Outline
        let path: RibbonSpline
        let timing: RibbonTiming
        /// Distances along `path` where each part starts: the spiral, the transition to the card, the outline.
        let spiralStart: Float
        let transitionStart: Float
        let outlineStart: Float
        var outlineEnd: Float { path.length }
        /// Where the outline starts and closes: the top of the card's right edge, where its top-right corner
        /// begins — so the closing glint lands on the card's corner, where a real card catches the light.
        var closurePoint: SIMD3<Float> { path.end }
        /// The spiral curve's end slope (f'(1) of its timing), solved for speed continuity.
        let spiralEndSlope: Float

        init(geometry: Geometry = .standard, beats: Beats = .standard) {
            let g = geometry

            // The spiral: one turn round S's +Y axis. At φ = 0 it is on the device's right (+X) heading for the
            // reader (+Z), so the last half-turn runs across the back and ends on the right, climbing.
            let sweep = 2 * Float.pi * g.spiralTurns
            let r0 = g.spiralStartRadius, r1 = g.spiralEndRadius
            let h0 = g.spiralStartHeight, h1 = g.spiralEndHeight
            let lin = g.climbLinearShare
            func radius(_ phi: Float) -> Float { r0 + (r1 - r0) * phi / sweep }
            func height(_ phi: Float) -> Float {
                let x = phi / sweep
                return h0 + (h1 - h0) * (lin * x + (1 - lin) * x * x)
            }
            func helix(_ phi: Float) -> SIMD3<Float> {
                let r = radius(phi)
                return [r * cos(phi), height(phi), r * sin(phi)]
            }
            func helixSlope(_ phi: Float) -> SIMD3<Float> {
                let r = radius(phi), dr = (r1 - r0) / sweep
                let x = phi / sweep
                let dh = (h1 - h0) * (lin + 2 * (1 - lin) * x) / sweep
                return [dr * cos(phi) - r * sin(phi), dh, dr * sin(phi) + r * cos(phi)]
            }

            // 1 · Launch: straight up out of the screen centre, a 14 mm bend over toward the spiral that ends
            // climbing at the spiral's own starting angle (≈ 7°), and a Hermite into the spiral with matching
            // slopes at both ends — so the climb never overshoots and sags back, and no bend is tighter than
            // the ribbon is wide (a single Hermite could only do one or the other).
            let born = SIMD3<Float>(0, g.launchLift, 0)
            let spiralIn = helix(0)
            let heading = g.launchHeadingDegrees * .pi / 180
            let out = SIMD3<Float>(cos(heading), 0, -sin(heading))
            let spiralHeading = simd_normalize(helixSlope(0))
            let lean = asin(max(-1, min(1, spiralHeading.y)))
            let bendEndAngle = Float.pi / 2 - lean
            let bendCenter = born + out * g.launchBendRadius
            let skyward = SIMD3<Float>(0, 1, 0)
            let bend = RibbonSpline.arc(center: bendCenter, radius: g.launchBendRadius, u: -out, v: skyward,
                                        from: 0, to: bendEndAngle)
            let bendEnd = bendCenter + g.launchBendRadius * (cos(bendEndAngle) * -out + sin(bendEndAngle) * skyward)
            let bendHeading = sin(bendEndAngle) * out + cos(bendEndAngle) * skyward
            let leadChord = simd_length(spiralIn - bendEnd)
            let lead = RibbonSpline.hermite(bendEnd, bendHeading * 0.8 * leadChord, spiralIn, spiralHeading * 1.5 * leadChord)
            let launch = bend + [lead]
            // 2 · The spiral, eight Hermite pieces per turn (C¹, within ≈ 0.1 mm of the helix).
            let spiral = RibbonSpline.sampled(pieces: max(4, Int(ceil(8 * g.spiralTurns))), over: 0...sweep,
                                              helix, derivative: helixSlope)
            // 4 · The outline, drawn anticlockwise as the reader sees it, from the top of the right edge.
            let outline = Self.outlineSegments(g.outline)
            let ax = g.cardWidth / 2, ay = g.cardHeight / 2, r = min(g.cornerRadius, min(ax, ay))
            let up = g.cardUp
            // 3 · Transition: from the spiral's last heading into the outline's first (up the right edge).
            let spiralOut = helix(sweep), cardIn = g.onCard(ax, ay - r)
            let transitionChord = simd_length(cardIn - spiralOut)
            let transition = RibbonSpline.hermite(spiralOut, simd_normalize(helixSlope(sweep)) * 1.25 * transitionChord,
                                                  cardIn, up * 1.25 * transitionChord)

            self.init(geometry: g, beats: beats, place: .desk, hand: nil, outline: g.outline,
                      launch: launch, spiral: spiral, transition: [transition], outlineSegments: outline)
        }

        /// The four pieces of a flight, joined, and its clock — shared by the desk's flight and the hand's (`init(hand:)`,
        /// in `V4HandRecognition.swift`). Build a flight with one of those two, not with this.
        init(geometry: Geometry, beats: Beats, place: RecognitionPlace, hand: HandGeometry?, outline card: Outline,
                     launch: [RibbonSpline.Segment], spiral: [RibbonSpline.Segment],
                     transition: [RibbonSpline.Segment], outlineSegments: [RibbonSpline.Segment]) {
            self.geometry = geometry
            self.beats = beats
            self.place = place
            self.hand = hand
            self.outline = card
            let launchPath = RibbonSpline(segments: launch)
            let spiralPath = RibbonSpline(segments: spiral)
            let transitionPath = RibbonSpline(segments: transition)
            path = RibbonSpline(segments: launch + spiral + transition + outlineSegments)
            spiralStart = launchPath.length
            transitionStart = spiralStart + spiralPath.length
            outlineStart = transitionStart + transitionPath.length

            // Timing: the flight to the card eases in from `launchSlope`, and its end slope is solved so the
            // head arrives at the card at exactly the speed the outline starts with.
            let toCard = outlineStart
            let outlineLength = path.length - outlineStart
            let flight = beats.outlineStart - beats.launch
            let drawing = beats.closure - beats.outlineStart
            let outlineStartSpeed = outlineLength / drawing           // g'(0) = 1 for the closing curve
            spiralEndSlope = outlineStartSpeed * flight / max(1e-4, toCard)
            let closing = beats.closureSlope
            timing = RibbonTiming(pieces: [
                .init(t0: beats.launch, t1: beats.outlineStart, s0: 0, s1: toCard,
                      curve: RibbonTiming.speedMatched(startSlope: beats.launchSlope, endSlope: spiralEndSlope)),
                // g(x) = x + β·x² − β·x³: starts at slope 1, ends at slope 1 − β.
                .init(t0: beats.outlineStart, t1: beats.closure, s0: toCard, s1: path.length,
                      curve: .cubic(a: 1, b: 1 - closing, c: closing - 1)),
            ])
        }

        /// The card's rounded rectangle, drawn anticlockwise as the reader sees it from the top of its right edge —
        /// so the closing glint lands on the card's top-right corner, where a real card catches the light. The same
        /// eight pieces for the desk's card and the hand's.
        static func outlineSegments(_ card: Outline) -> [RibbonSpline.Segment] {
            let ax = card.width / 2, ay = card.height / 2, r = min(card.cornerRadius, min(ax, ay))
            let right = card.right, up = card.up
            var outline: [RibbonSpline.Segment] = []
            outline += RibbonSpline.arc(center: card.on(ax - r, ay - r), radius: r, u: right, v: up, from: 0, to: .pi / 2)
            outline.append(RibbonSpline.line(card.on(ax - r, ay), card.on(-(ax - r), ay)))
            outline += RibbonSpline.arc(center: card.on(-(ax - r), ay - r), radius: r, u: right, v: up,
                                        from: .pi / 2, to: .pi)
            outline.append(RibbonSpline.line(card.on(-ax, ay - r), card.on(-ax, -(ay - r))))
            outline += RibbonSpline.arc(center: card.on(-(ax - r), -(ay - r)), radius: r, u: right, v: up,
                                        from: .pi, to: 1.5 * .pi)
            outline.append(RibbonSpline.line(card.on(-(ax - r), -ay), card.on(ax - r, -ay)))
            outline += RibbonSpline.arc(center: card.on(ax - r, -(ay - r)), radius: r, u: right, v: up,
                                        from: 1.5 * .pi, to: 2 * .pi)
            outline.append(RibbonSpline.line(card.on(ax, -(ay - r)), card.on(ax, ay - r)))
            return outline
        }

        // MARK: - What each beat is doing at time t

        /// How far the head has flown at `t`.
        func headDistance(at t: Float) -> Float { timing.distance(at: t) }

        func headPosition(at t: Float) -> SIMD3<Float> { path.point(atDistance: headDistance(at: t)) }

        /// Is the head flying (as opposed to not launched yet, or parked at the closure)?
        func isFlying(at t: Float) -> Bool { t > beats.launch && t < beats.closure }

        /// The ribbon's whole-body brightness: 1 while it flies, easing to 0 across the dissolve.
        func ribbonLevel(at t: Float) -> Float {
            guard t > beats.closure else { return 1 }
            let x = (t - beats.closure) / max(1e-4, beats.dissolveEnd - beats.closure)
            return x >= 1 ? 0 : 1 - x * x * (3 - 2 * x)
        }

        /// The dissolve's progress 0…1 (dust sweeps from the head back along the body).
        func dissolveProgress(at t: Float) -> Float {
            max(0, min(1, (t - beats.closure) / max(1e-4, beats.dissolveEnd - beats.closure)))
        }

        /// The drawn outline's whole-line brightness: on while it is drawn and held, then an ease-out fade.
        func outlineLevel(at t: Float) -> Float {
            let fadeStart = beats.closure + beats.outlineHold
            guard t > fadeStart else { return t >= beats.outlineStart ? 1 : 0 }
            let x = (t - fadeStart) / max(1e-4, beats.outlineFade)
            return x >= 1 ? 0 : (1 - x) * (1 - x)
        }

        /// Screen burst progress 0…1 across its 0.15 s (nil outside it).
        func burstProgress(at t: Float) -> Float? {
            guard t >= beats.burstStart, t <= beats.burstEnd else { return nil }
            return (t - beats.burstStart) / max(1e-4, beats.burstEnd - beats.burstStart)
        }
    }
}
