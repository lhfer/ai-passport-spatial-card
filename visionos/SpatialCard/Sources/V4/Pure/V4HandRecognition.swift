import Foundation
import simd

extension V4 {
    /// Where a recognition draws the card: standing 0.22 m over the screen of a passport lying on the desk, or on the
    /// top-edge hinge of one held in the hand (v4 B4 §1).
    enum RecognitionPlace: String, Equatable {
        case desk
        case hand
    }

    /// **v4 B4 §1 — which recognition plays, decided once, before the ribbon takes off.**
    ///
    /// Round 2 (B3 run 1): the recognition always flew the desk's path, written in the screen frame S with the device
    /// lying flat — a spiral round S's +Y (the screen normal) and an upright outline 0.22 m up it. In the hand the screen
    /// faces the eyes, so +Y points at the face: the ribbon flew out horizontally at the wearer and drew a card lying on
    /// its back, and then the card unfolded out of the device onto the hinge, somewhere else. The hand needs its own path
    /// (`RecognitionTimeline.init(hand:)`) and it has to be chosen before the ribbon leaves the screen at 0.10 s — the
    /// presence gate takes 22–158 ms after `acquiring` to say `carrying` or `expanded` (run 1 lines 99–106: launch at
    /// 0.10 s, verdict at 158 ms), so the decision cannot wait for it. It reads what is known at `acquiring`: the device's
    /// raw tilt against the desk gate's own "in a hand" angle, and the desk gate's current answer (a passport that has been
    /// in the hand is still "hand" to it at 40°; a fresh gate's prior is the desk). It is made once; if the gate later
    /// lands the other way, the closure falls back (`HologramController`: a rise on the desk, the unfold in the hand).
    enum RecognitionPlan {
        /// The desk gate's "this is in a hand" angle (`DeskOrientationGate.exitAngle`, 45°).
        static let handTilt: Float = DeskOrientationGate().exitAngle

        struct Decision: Equatable {
            var place: RecognitionPlace
            /// The raw tilt it read (rad), nil when no tracked object observation had a tilt yet.
            var tilt: Float?
            /// What decided it, for the log line.
            var reason: String
        }

        /// - Parameters:
        ///   - tilt: the screen normal's angle off world up (rad) — the raw tilt the desk gate judges (`CardTracker.objectTilt`).
        ///   - deskGateOnDesk: the desk gate's current answer.
        ///   - handFormAvailable: the hand form is the hinged card (`usesHandForm && handForm == .hinge`): without it the
        ///     hand path has no card to land on, and the closure keeps today's unfold.
        static func decide(tilt: Float?, deskGateOnDesk: Bool, handFormAvailable: Bool) -> Decision {
            let degrees = tilt.map { String(format: "%.0f°", $0 * 180 / .pi) } ?? "-"
            guard handFormAvailable else {
                return Decision(place: .desk, tilt: tilt, reason: "no hinged hand form (tilt \(degrees))")
            }
            if !deskGateOnDesk {
                return Decision(place: .hand, tilt: tilt, reason: "desk gate: hand (tilt \(degrees))")
            }
            if let tilt, tilt > handTilt {
                return Decision(place: .hand, tilt: tilt,
                                reason: String(format: "tilt %@ > %.0f°", degrees, handTilt * 180 / .pi))
            }
            return Decision(place: .desk, tilt: tilt,
                            reason: tilt == nil ? "no tilt yet (desk gate: desk)"
                                                : String(format: "tilt %@ ≤ %.0f°, desk gate: desk", degrees, handTilt * 180 / .pi))
        }
    }
}

extension HandFacing {
    /// **v4 B4 §1.** The hinge angle the hand form settles at for a head at `head` (hinge space): the facing tick's own
    /// fixed point (`HologramController.stepHandForm` aims at `hingeAngle` for the card *where it is* on its arc, which moves
    /// the card, which moves the angle — negative feedback that converges in a few steps). The recognition in the hand
    /// draws its outline at this angle and the card dissolves in at it, frozen from take-off; once the reveal is over the
    /// tick takes over from the same value, so nothing jumps.
    static func restingHingeAngle(weight: Float, halfHeight: Float, head: SIMD3<Float>?, iterations: Int = 8,
                                  clamp: Float = HandFacing.hingeClamp) -> Float {
        guard head != nil else { return 0 }
        var angle: Float = 0
        for _ in 0..<max(1, iterations) {
            angle = hingeAngle(weight: weight, card: cardCentre(angle: angle, halfHeight: halfHeight), head: head, clamp: clamp)
        }
        return angle
    }
}

extension V4.RecognitionTimeline {
    /// **v4 B4 §1 — the recognition in the hand**, in the screen frame S.
    ///
    /// The ribbon still leaves the real screen (its burst is the LCD's own flash): it climbs 2–3 cm straight out along the
    /// screen normal, bends over toward the top edge (the lanyard end), and circles three quarters of a turn round the
    /// **hand card's up axis** — the line up the card from its hinge — climbing as it goes, then runs up the card's right
    /// edge and draws the outline **where the hand card will stand**: its bottom edge on the hinge at the case's top edge,
    /// the hand form's size (the hero card × 0.5 = 0.10 × 0.14 m), at the hinge angle the hand form will settle at
    /// (`HandFacing.restingHingeAngle`, frozen at take-off). Then the card dissolves in place in that outline (the desk's
    /// `.reveal`, on the hinge) — no unfold.
    ///
    /// The card frame on the hinge is `HandFacing.base · HandFacing.hinged(angle:)`: +X across the device, `cardUp` =
    /// (0, sin α, −cos α) (past the top edge, lifting toward the screen normal as the hinge opens), `cardNormal` =
    /// (0, cos α, sin α) (the screen's normal at α = 0, turning toward the reader as it opens).
    ///
    /// The numbers are the desk flight's at about half scale, chosen (a grid search over the start / end heights and
    /// radii and the joins' handles, across hinge angles 0–35°) so that no bend is tighter than ≈ 9.5 mm — wider than the
    /// ribbon's 5.5 mm half width (A2's rule: then the strip never folds on itself) — and so that nothing after the
    /// launch passes through the device's H0 prism. The launch itself crosses the top of the device for its first ≈ 0.2 s,
    /// inside the recognition's audit pause (the brief's exemption for the ribbon leaving the screen).
    struct HandGeometry: Equatable {
        /// The hinge — the hand card's bottom-edge centre — in S (`HologramController.hingePosition`).
        var hinge: SIMD3<Float>
        /// The hinge angle (rad) the card stands at: 0 = lying in the screen's plane past the top edge.
        var hingeAngle: Float
        /// The hand card: the hero card × the hand scale.
        var cardWidth: Float = 0.10
        var cardHeight: Float = 0.14
        var cornerRadius: Float = 0.009
        /// Where the ribbon is born: just above the screen, as on the desk.
        var launchLift: Float = 0.0012
        /// The straight climb out of the screen before the bend: with the bend the ribbon is 2.3–2.5 cm off the screen
        /// when it heads for the top edge (the brief's 2–3 cm).
        var riseStraight: Float = 0.010
        /// The bend over toward the top edge: the desk launch's 14 mm.
        var launchBendRadius: Float = 0.014
        /// The spiral round the card's up axis (from the hinge), starting in front of the card and going three quarters of
        /// a turn — front → left → back → right — so it ends beside the right edge heading for the reader, like the desk's.
        var spiralStartRadius: Float = 0.035
        var spiralEndRadius: Float = 0.060
        /// Heights along the card's up axis, from the hinge.
        var spiralStartHeight: Float = 0.035
        var spiralEndHeight: Float = 0.070
        var spiralTurns: Float = 0.75
        /// The fairy ribbon's width in the hand as a share of the desk's 11 mm: the card is half the size and 35–45 cm from
        /// the eyes, where 11 mm read twice as thick against it (8.8 mm, inside the bible's 6–12 mm).
        var ribbonWidthScale: Float = 0.8

        var cardRight: SIMD3<Float> { [1, 0, 0] }
        var cardUp: SIMD3<Float> { [0, sin(hingeAngle), -cos(hingeAngle)] }
        var cardNormal: SIMD3<Float> { [0, cos(hingeAngle), sin(hingeAngle)] }
        var cardCenter: SIMD3<Float> { hinge + cardUp * (cardHeight / 2) }

        var outline: Outline {
            Outline(center: cardCenter, right: cardRight, up: cardUp, normal: cardNormal,
                    width: cardWidth, height: cardHeight, cornerRadius: cornerRadius)
        }
    }

    /// The hand's flight (see `HandGeometry`), on the desk flight's beats and clock: launch at 0.10 s, the outline from
    /// 1.20 s, the closure at 1.90 s — the speed solved so the head reaches the card at the outline's own pace.
    init(hand h: HandGeometry, beats: Beats = .standard) {
        let right = h.cardRight, up = h.cardUp, normal = h.cardNormal
        // The spiral: φ measured from the card's right (+X) toward its front (the normal); it starts in front (φ = π/2)
        // and turns three quarters to end on the right (φ = 2π), where the transition runs up the right edge.
        let phi0 = Float.pi / 2
        let sweep = 2 * Float.pi * h.spiralTurns
        let r0 = h.spiralStartRadius, r1 = h.spiralEndRadius
        let h0 = h.spiralStartHeight, h1 = h.spiralEndHeight
        func radius(_ s: Float) -> Float { r0 + (r1 - r0) * s / sweep }
        func height(_ s: Float) -> Float { h0 + (h1 - h0) * s / sweep }
        func helix(_ s: Float) -> SIMD3<Float> {
            let phi = phi0 + s
            return h.hinge + radius(s) * (cos(phi) * right + sin(phi) * normal) + height(s) * up
        }
        func helixSlope(_ s: Float) -> SIMD3<Float> {
            let phi = phi0 + s
            let dr = (r1 - r0) / sweep, dh = (h1 - h0) / sweep
            return dr * (cos(phi) * right + sin(phi) * normal) + radius(s) * (-sin(phi) * right + cos(phi) * normal)
                + dh * up
        }

        // 1 · Launch: straight out of the screen centre along its normal, then a 14 mm bend over toward the top edge that
        // ends heading up the card's own axis, and a Hermite into the spiral's first point (in front of the card).
        let born = SIMD3<Float>(0, h.launchLift, 0)
        let riseEnd = born + SIMD3<Float>(0, h.riseStraight, 0)
        let skyward = SIMD3<Float>(0, 1, 0)
        var toward = up - skyward * simd_dot(up, skyward)
        toward = simd_length(toward) > 1e-5 ? simd_normalize(toward) : SIMD3<Float>(0, 0, -1)
        let bendEndAngle = acos(max(-1, min(1, simd_dot(skyward, up))))
        let bendCenter = riseEnd + toward * h.launchBendRadius
        let bend = V4.RibbonSpline.arc(center: bendCenter, radius: h.launchBendRadius, u: -toward, v: skyward,
                                    from: 0, to: bendEndAngle)
        let bendEnd = bendCenter + h.launchBendRadius * (cos(bendEndAngle) * -toward + sin(bendEndAngle) * skyward)
        let bendHeading = sin(bendEndAngle) * toward + cos(bendEndAngle) * skyward
        let spiralIn = helix(0)
        let leadChord = simd_length(spiralIn - bendEnd)
        let lead = V4.RibbonSpline.hermite(bendEnd, bendHeading * 0.8 * leadChord,
                                        spiralIn, simd_normalize(helixSlope(0)) * 1.5 * leadChord)
        let launch = [V4.RibbonSpline.line(born, riseEnd)] + bend + [lead]
        // 2 · The spiral, eight Hermite pieces per turn (C¹).
        let spiral = V4.RibbonSpline.sampled(pieces: max(4, Int(ceil(8 * h.spiralTurns))), over: 0...sweep,
                                          helix, derivative: helixSlope)
        // 4 · The outline (the desk's eight pieces), on the hinge.
        let card = h.outline
        let outline = Self.outlineSegments(card)
        let ax = card.width / 2, ay = card.height / 2, r = min(card.cornerRadius, min(ax, ay))
        // 3 · Transition: from the spiral's end (beside the right edge, heading for the reader) up into the right edge.
        let spiralOut = helix(sweep), cardIn = card.on(ax, ay - r)
        let chord = simd_length(cardIn - spiralOut)
        let transition = V4.RibbonSpline.hermite(spiralOut, simd_normalize(helixSlope(sweep)) * 1.5 * chord,
                                              cardIn, up * 1.0 * chord)

        var geometry = Geometry.standard
        geometry.cardWidth = card.width
        geometry.cardHeight = card.height
        geometry.cornerRadius = card.cornerRadius
        geometry.launchLift = h.launchLift
        self.init(geometry: geometry, beats: beats, place: .hand, hand: h, outline: card,
                  launch: launch, spiral: spiral, transition: [transition], outlineSegments: outline)
    }
}
