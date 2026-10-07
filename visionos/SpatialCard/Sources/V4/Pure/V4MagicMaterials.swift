import Foundation
import simd

// MARK: - Palette and rules (art bible §1–§2)

extension V4 {
    /// The night-gold palette (`docs/art-direction/night-gold/README.md` §1), as the sRGB hex the bible writes.
    enum MagicPalette {
        static let night = "#0B1230"
        static let deepNight = "#060A1C"
        static let gold = "#FFD58A"
        static let goldHot = "#FFF3D6"
        static let oldGold = "#C9A45C"
        static let crystal = "#F4F7FF"
        /// Text on a light ground.
        static let ink = "#1A2238"
        /// Warm white leaning gold: the slab's edge light (between `goldHot` and `gold`).
        static let rimWarmWhite = "#FFE9C2"
        /// The foil's view-dependent shift, in order; the ramp is cyclic (the last stop blends back into the first).
        static let foilStops = ["#7FE7FF", "#B18CFF", "#FF9ED8", "#FFE08A"]
    }

    /// The numbers the art bible fixes, in one place, with the curves the graphs implement — so the unit tests can hold
    /// the shader to the bible without a GPU.
    enum MagicMaterialRules {
        /// §2: the foil may never be stronger than this seen square-on …
        static let foilFacingCap: Float = 0.12
        /// … nor than this seen edge-on (it must never cover the avatar or the numbers).
        static let foilGrazingCap: Float = 0.45
        /// < 1 so the foil wakes up at the angles a wrist actually turns to (35° → 0.21), not only at 80°.
        static let foilCapExponent: Float = 0.75
        /// How far the foil's hues are lifted toward white (a pastel sheen, never a saturated film).
        static let foilPastel: Float = 0.3

        /// The foil's ceiling for a view at `|n·v| = facing` (1 square-on, 0 edge-on).
        static func foilCap(facing: Float) -> Float {
            let g = max(0, min(1, 1 - Swift.abs(facing)))
            return foilFacingCap + (foilGrazingCap - foilFacingCap) * Float(Foundation.pow(Double(g), Double(foilCapExponent)))
        }

        /// §2: the slab's edge light, square-on and edge-on.
        static let rimFacing: Float = 0.45
        static let rimGrazing: Float = 0.9
        /// The same exponent as v3's `RimFresnel`: the middle of a turn stays quiet, the edge catches the light late.
        static let rimExponent: Float = 1.5

        static func rimLevel(facing: Float, rimFacing: Float = rimFacing, rimGrazing: Float = rimGrazing) -> Float {
            let g = max(0, min(1, 1 - Swift.abs(facing)))
            return rimFacing + (rimGrazing - rimFacing) * Float(Foundation.pow(Double(g), Double(rimExponent)))
        }

        /// §1 wrote the slab body as 6–12 % opaque — a clear plate. Review of the A1 lab (2026-09-26) raised it: at
        /// 9 % the slab read as dark smoked glass in the dark and all but vanished in a lit room. The body's frosted
        /// white (`opacity`, square-on, before the inner glow) is now 35–50 %, over a frost that blurs the scene behind
        /// — so it reads as frosted crystal, not as a white sheet.
        static let slabOpacityRange: ClosedRange<Float> = 0.35...0.5
        static let slabOpacity: Float = 0.42
        /// The bible's original clear-plate range, kept for a "clear" variant (e.g. a card over a busy world).
        static let clearSlabOpacityRange: ClosedRange<Float> = 0.06...0.12
        /// How much of the scene seen through the slab is replaced by its blurred copy (the frost itself).
        static let slabFrost: Float = 0.75

        /// §2: the gold line sits 1.5 mm inside the outline.
        static let goldInset: Float = 0.0015
        static let goldLineWidth: Float = 0.0009

        /// The ink plate behind gold type on the pale crystal: opacity at its centre.
        static let inkVeilOpacity: Float = 0.92

        /// WCAG relative luminance of a *linear* RGB colour.
        static func luminance(linear c: SIMD3<Float>) -> Float { 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z }

        /// WCAG contrast ratio of two relative luminances (≥ 4.5 : 1 for body text).
        static func contrast(_ a: Float, _ b: Float) -> Float {
            (Swift.max(a, b) + 0.05) / (Swift.min(a, b) + 0.05)
        }

        /// Luminance behind a glyph that sits on the ink veil, over a background of luminance `behind`.
        static func luminanceThroughInkVeil(behind: Float, opacity: Float = inkVeilOpacity) -> Float {
            let ink = luminance(linear: V4.ShadeGraph.linear(hex: MagicPalette.ink))
            return ink * opacity + behind * (1 - opacity)
        }

        /// A sweep parameter 0…1 → the band centre along the card's diagonal (0 = top-left corner, 1 = bottom-right),
        /// overshooting both ends so the band enters and leaves the card completely.
        static let sweepOvershoot: Float = 0.15
        static func sweepCenter(_ sweep: Float) -> Float { -sweepOvershoot + (1 + 2 * sweepOvershoot) * sweep }

        /// Where a point of the card (normalised to −1…1 on both axes, +y up) lies along the sweep diagonal.
        static func sweepCoordinate(_ q: SIMD2<Float>) -> Float { (q.x - q.y) * 0.25 + 0.5 }
    }
}

// MARK: - The four graphs

extension V4 {
    /// The v4 material library as ShaderGraph graphs. Each graph works in its mesh's **object space, metres**:
    /// the card lies in the X-Y plane, +Z is the face normal (`FXMeshes.roundedSlab` / `roundedRectRing` and
    /// `MagicMeshes.roundedPlane` all follow it), so line widths and insets are real millimetres at any entity scale.
    enum MagicMaterialGraphs {
        typealias G = V4.ShadeGraph

        /// `--card-frost plain|blur` (**default `plain` since v4 B4**, the user's call after round 2): whether the
        /// crystal's frost samples RealityKit's background blur, or shows a flat pale tone with no blur pass at all
        /// (the node is left out of the graph, so the renderer never schedules the blur). Headset round 1 ran the whole
        /// app at 45 fps from the moment the frosted card appeared (B2 report); round 2's run 2 (`plain`) took the
        /// nebula from 46 to 90 fps and the recognition in the hand from 74–85 to 89.7, and the wearer could not tell
        /// the two cards apart. `blur` stays as the switch back. Both graphs that sample the frost — CrystalSlab and
        /// MagicDissolve, which share `crystalLight` — follow it; the only other `background_blur` in the target is the
        /// materials lab's probe (`MaterialXProbe` Q18). Read once, before the preload builds the graphs.
        static var backgroundBlur: Bool = frostSamplesBlur(CommandLine.arguments)

        /// `--card-frost`'s rule: only an explicit `blur` puts the background-blur pass back (anything else is `plain`).
        static func frostSamplesBlur(_ args: [String]) -> Bool {
            guard let i = args.firstIndex(of: "--card-frost"), i + 1 < args.count else { return false }
            return args[i + 1].lowercased() == "blur"
        }

        /// Parameter names — the only strings the RealityKit wrappers and the graphs share.
        enum Param {
            static let tint = "tint"
            static let rimColor = "rimColor"
            static let rimFacing = "rimFacing"
            static let rimGrazing = "rimGrazing"
            static let opacity = "opacity"
            static let frost = "frost"
            static let reflection = "reflection"
            static let halfSize = "halfSize"
            static let cornerRadius = "cornerRadius"
            static let thickness = "thickness"
            static let strength = "strength"
            static let sweep = "sweep"
            static let bands = "bands"
            static let flow = "flow"
            static let intensity = "intensity"
            static let baseColor = "baseColor"
            static let hotColor = "hotColor"
            static let inset = "inset"
            static let lineWidth = "lineWidth"
            static let outerGlow = "outerGlow"
            static let progress = "progress"
            static let edgeWidth = "edgeWidth"
            static let edgeColor = "edgeColor"
            static let noiseScale = "noiseScale"
            static let glow = "glow"
            static let softness = "softness"
        }

        /// The name card's slab outline (HologramLayout: card 0.27 m + 6 mm border, corner 30 + 6 mm).
        static let slabHalfSize: SIMD2<Float> = [0.141, 0.141]
        static let slabCornerRadius: Float = 0.036
        static let slabThickness: Float = 0.012
        /// The card face inside the border (where the SwiftUI sheets and the foil live).
        static let cardHalfSize: SIMD2<Float> = [0.135, 0.135]
        static let cardCornerRadius: Float = 0.030

        static let crystalSlabName = "V4CrystalSlab"
        static let holoFoilName = "V4HoloFoil"
        static let goldEdgeName = "V4GoldEdge"
        static let magicDissolveName = "V4MagicDissolve"
        static let sweepGlintName = "V4SweepGlint"
        static let inkVeilName = "V4InkVeil"

        // MARK: CrystalSlab

        /// The frosted slab: an even 6–12 % veil whose scattered light is edge-lit (strong near the outline, weak in
        /// the middle) with a millimetre frost; a weak IBL reflection plus a view-driven sheen that grow toward
        /// grazing; a glass glint when the `sweep` crosses; and the warm edge light — a crisp 1.5 mm line over a 10 mm
        /// halo on the face, the side band's two arrises lit — whose level follows the card's angle to the eye
        /// (0.45 square-on → 0.9 edge-on). Premultiplied: the body veils what is behind it by its opacity, the light
        /// only adds.
        /// `blur`: whether the frost samples the background blur (`--card-frost`; v4 B4's `cmd perf material=` builds the
        /// other variant on demand).
        static func crystalSlab(halfSize: SIMD2<Float> = slabHalfSize, cornerRadius: Float = slabCornerRadius,
                                blur: Bool = backgroundBlur) -> G {
            var g = G(name: crystalSlabName)
            let inputs = crystalParameters(&g, halfSize: halfSize, cornerRadius: cornerRadius)
            let light = crystalLight(&g, inputs, blur: blur)
            g.setSurface(g.unlitSurface(color: light.color.s, opacity: light.alpha.s, premultiplied: true))
            return g
        }

        struct CrystalInputs {
            var tint, rimColor, rimFacing, rimGrazing, opacity, frost, reflection, halfSize, cornerRadius, thickness, sweep: G.Port
        }

        static func crystalParameters(_ g: inout G, halfSize: SIMD2<Float>, cornerRadius: Float,
                                      thickness: Float = slabThickness) -> CrystalInputs {
            CrystalInputs(
                tint: g.parameter(Param.tint, .srgb(MagicPalette.crystal)),
                rimColor: g.parameter(Param.rimColor, .srgb(MagicPalette.rimWarmWhite)),
                rimFacing: g.parameter(Param.rimFacing, .float(MagicMaterialRules.rimFacing)),
                rimGrazing: g.parameter(Param.rimGrazing, .float(MagicMaterialRules.rimGrazing)),
                opacity: g.parameter(Param.opacity, .float(MagicMaterialRules.slabOpacity)),
                frost: g.parameter(Param.frost, .float(MagicMaterialRules.slabFrost)),
                reflection: g.parameter(Param.reflection, .float(0.35)),
                halfSize: g.parameter(Param.halfSize, .vector2(halfSize)),
                cornerRadius: g.parameter(Param.cornerRadius, .float(cornerRadius)),
                thickness: g.parameter(Param.thickness, .float(thickness)),
                // 1 = the band rests past the far corner (invisible); the stack drives it with the foil's.
                sweep: g.parameter(Param.sweep, .float(1)))
        }

        /// The slab's premultiplied light (shared by CrystalSlab and MagicDissolve, so a finished dissolve *is* the slab).
        static func crystalLight(_ g: inout G, _ i: CrystalInputs, blur: Bool = backgroundBlur) -> (color: G.Port, alpha: G.Port) {
            let p3 = g.position(space: "object")
            let p = g.convert(p3.s, to: .vector2)
            let q = g.div(p.s, i.halfSize.s)
            let qx = g.extract(q.s, 0), qy = g.extract(q.s, 1)
            let nObject = g.normal(space: "object")
            let nWorld = g.normal(space: "world")
            let view = g.viewDirection(space: "world")
            let viewObject = g.viewDirection(space: "object")

            // Face (|n.z| ≈ 1) vs the side band (n.z ≈ 0).
            let face = g.smoothstep(G.f(0.35), G.f(0.85), g.abs(g.extract(nObject.s, 2).s).s)
            let side = g.oneMinus(face.s)

            // The card's own angle to the eye drives the rim level (v3 RimFresnel's curve, now per pixel on the GPU).
            let cardNormal = g.normalize(g.transformVector(.value(.vector3([0, 0, 1])), from: "object", to: "world").s)
            let cardFacing = g.clamp(g.abs(g.dot(cardNormal.s, view.s).s).s)
            let cardGrazing = g.pow(g.oneMinus(cardFacing.s).s, G.f(MagicMaterialRules.rimExponent))
            let rimLevel = g.mix(i.rimFacing.s, i.rimGrazing.s, cardGrazing.s)

            // Edge light. Face: a crisp 1.5 mm line at the outline over a 10 mm halo. Side band: the two arrises
            // bright (where a real plate's edge catches light), the flat of the band dimmer, the front arris strongest.
            let distance = g.roundedRectDistance(p.s, halfSize: i.halfSize.s, radius: i.cornerRadius.s)
            let inward = g.max(g.mul(distance.s, G.f(-1)).s, G.f(0))
            let core = g.oneMinus(g.smoothstep(G.f(0.0003), G.f(0.0018), inward.s).s)
            let haloLinear = g.oneMinus(g.smoothstep(G.f(0), G.f(0.010), inward.s).s)
            let halo = g.mul(haloLinear.s, haloLinear.s)
            let faceGlow = g.add(core.s, g.mul(halo.s, G.f(0.3)).s)
            let z = g.extract(p3.s, 2)
            let across = g.div(g.abs(z.s).s, g.mul(i.thickness.s, G.f(0.5)).s)
            let arris = g.smoothstep(G.f(0.55), G.f(0.95), across.s)
            let frontBias = g.add(G.f(0.7), g.mul(g.smoothstep(G.f(-0.001), G.f(0.001), z.s).s, G.f(0.3)).s)
            let sideGlow = g.mul(g.add(G.f(0.3), g.mul(arris.s, G.f(0.7)).s).s, frontBias.s)
            let glowMask = g.add(g.mul(face.s, faceGlow.s).s, g.mul(side.s, sideGlow.s).s)
            let rim = g.mul(i.rimColor.s, g.mul(glowMask.s, rimLevel.s).s)

            // Glass reflectance (Schlick-like, 6 % → 100 %) over the scene's IBL, kept weak by `reflection` …
            let facing = g.clamp(g.abs(g.dot(nWorld.s, view.s).s).s)
            let fresnel = g.pow(g.oneMinus(facing.s).s, G.f(4))
            let reflectance = g.add(G.f(0.06), g.mul(fresnel.s, G.f(0.94)).s)
            let environment = g.environmentRadiance(normal: nWorld.s, roughness: 0.12)
            let reflection = g.mul(environment.specular.s, g.mul(reflectance.s, i.reflection.s).s)
            // … plus a soft sheen that slides across the face as the eye moves: the glass cue that survives a dark
            // room, where the IBL has nothing to show. It runs along the other diagonal from the sweep ("\" against
            // the sweep's "/"), so the resting reflection and the passing light never read as the same stripe.
            let sheenCoordinate = g.add(g.mul(g.add(qx.s, qy.s).s, G.f(0.5)).s,
                                        g.mul(g.add(g.extract(viewObject.s, 0).s, g.extract(viewObject.s, 1).s).s, G.f(1.2)).s)
            let wide = g.oneMinus(g.smoothstep(G.f(0), G.f(0.3), g.abs(g.sub(sheenCoordinate.s, G.f(0.2)).s).s).s)
            let thin = g.oneMinus(g.smoothstep(G.f(0), G.f(0.07), g.abs(g.add(sheenCoordinate.s, G.f(0.3)).s).s).s)
            let sheenLevel = g.mul(g.mul(g.add(g.mul(g.mul(wide.s, wide.s).s, G.f(0.16)).s, g.mul(g.mul(thin.s, thin.s).s, G.f(0.04)).s).s,
                                         i.reflection.s).s, face.s)
            let sheen = g.mul(i.rimColor.s, sheenLevel.s)
            // The sweep (bible §2: a diagonal sweep every 8–12 s) as the glass itself catching a passing light: a soft
            // warm band with a hot core. It is reflection, not foil, so the foil's cap does not apply to it.
            let sweepLinear = sweepBand(&g, qx: qx, qy: qy, sweep: i.sweep, width: 0.1)
            let sweepSoft = g.pow(sweepLinear.s, G.f(3))
            let sweepCore = g.pow(sweepLinear.s, G.f(14))
            let glint = g.mul(i.rimColor.s, g.mul(g.add(g.mul(sweepSoft.s, G.f(0.1)).s, g.mul(sweepCore.s, G.f(0.26)).s).s,
                                                   face.s).s)

            // Body: frosted crystal, two layers. (1) Frost: `frost` of what is seen through the slab is replaced by
            // the same scene *blurred* (RealityKit's background blur) — the room survives only as soft colour.
            // (2) Milk: over it, the crystal white at `opacity` (a little more at grazing — a plate's path length),
            // with a soft inner glow brighter toward the edges, warming toward the rim colour, and a 1 mm grain.
            // Premultiplied: alpha = 1 − (1 − frost)(1 − milk), colour = blur·frost·(1 − milk) + white·milk.
            // So in a dark room the slab is a pale luminous plate and in a lit room a frosted pane brighter than the
            // wall behind it — an object in both lights (A1 review, 2026-09-26). If the blur ever samples nothing, the
            // body is just the milk: still pale, never dark.
            let edgeProximity = g.pow(g.oneMinus(g.smoothstep(G.f(0), G.f(0.06), inward.s).s).s, G.f(1.4))
            let grain = g.noise3d(g.mul(p3.s, G.f(950)).s, amplitude: 0.5, pivot: 0.5)
            let frostGrain = g.add(G.f(0.86), g.mul(grain.s, G.f(0.28)).s)
            let innerGlow = g.add(G.f(0.72), g.mul(edgeProximity.s, G.f(0.75)).s)
            let milk = g.clamp(g.mul(g.mul(i.opacity.s, innerGlow.s).s, g.add(G.f(1), g.mul(fresnel.s, G.f(0.6)).s).s).s)
            let milkWhite = g.mul(g.mix(i.tint.s, i.rimColor.s, g.mul(edgeProximity.s, G.f(0.5)).s).s, frostGrain.s)
            let behind = blur ? g.backgroundBlur() : g.mul(i.tint.s, G.f(0.5))
            let frost = g.clamp(i.frost.s)
            let keptThrough = g.mul(g.oneMinus(frost.s).s, g.oneMinus(milk.s).s)
            let alpha = g.oneMinus(keptThrough.s)
            let blurred = g.mul(behind.s, g.mul(frost.s, g.oneMinus(milk.s).s).s)
            let body = g.add(blurred.s, g.mul(milkWhite.s, milk.s).s)

            let color = g.add(g.add(g.add(g.add(body.s, reflection.s).s, sheen.s).s, glint.s).s, rim.s)
            return (color, alpha)
        }

        // MARK: HoloFoil

        /// The holographic foil: ribbons of a cyclic cyan → violet → pink → gold ramp whose phase comes from the card's
        /// diagonal, the eye's lateral offset (so the colours flow when the head moves — no clock) and a soft fractal
        /// warp, plus a view-dependent glitter, calmer in the middle of the card. Pure additive light, never stronger
        /// than `MagicMaterialRules.foilCap` for the current angle (the cap is built into the graph; `strength` can
        /// only lower it). A diagonal `sweep` band lifts the foil to its cap and warms it toward white-gold.
        static func holoFoil(halfSize: SIMD2<Float> = cardHalfSize) -> G {
            var g = G(name: holoFoilName)
            let strength = g.parameter(Param.strength, .float(1))
            let sweep = g.parameter(Param.sweep, .float(0))
            let half = g.parameter(Param.halfSize, .vector2(halfSize))
            let bands = g.parameter(Param.bands, .float(1.15))
            let flow = g.parameter(Param.flow, .float(1.6))

            let p3 = g.position(space: "object")
            let q = g.div(g.convert(p3.s, to: .vector2).s, half.s)
            let qx = g.extract(q.s, 0), qy = g.extract(q.s, 1)
            let view = g.viewDirection(space: "object")
            let vx = g.extract(view.s, 0), vy = g.extract(view.s, 1), vz = g.extract(view.s, 2)

            // The cap (art bible §2), from the angle of the eye to this face.
            let grazing = g.oneMinus(g.clamp(g.abs(vz.s).s).s)
            let rules = MagicMaterialRules.self
            let cap = g.add(G.f(rules.foilFacingCap),
                            g.mul(g.pow(grazing.s, G.f(rules.foilCapExponent)).s, G.f(rules.foilGrazingCap - rules.foilFacingCap)).s)

            // Phase: diagonal bands + head motion + warp.
            let diagonal = g.mul(g.add(qx.s, qy.s).s, G.f(0.5))
            let viewTerm = g.add(g.mul(vx.s, G.f(0.8)).s, g.mul(vy.s, G.f(-0.6)).s)
            let warp = g.fractal3d(g.mul(p3.s, G.f(14)).s, octaves: 3, amplitude: 1)
            let flowing = g.mul(viewTerm.s, flow.s)
            let phase = g.fract(g.add(g.add(g.mul(diagonal.s, bands.s).s, flowing.s).s, g.mul(warp.s, G.f(0.1)).s).s)

            // A continuous pastel sheen (review 2026-09-26: ribbons with empty gaps read as dark aurora smoke). The
            // colours are lifted toward white, nothing drops to zero — a gentle ripple, bent by the warp and running at
            // its own frequency so brightness and colour do not move in lock-step — and the level itself rises with
            // the angle: square-on the foil is a whisper (under half of its 0.12 cap), edge-on it fills its 0.45.
            // It is a colour *shift* over the card, never the card's base colour (bible §1).
            let ripplePhase = g.add(g.add(g.mul(diagonal.s, g.mul(bands.s, G.f(1.6)).s).s, g.mul(flowing.s, G.f(0.9)).s).s,
                                    g.mul(warp.s, G.f(0.3)).s)
            let wave = g.add(G.f(0.5), g.mul(g.sin(g.mul(ripplePhase.s, G.f(2 * .pi)).s).s, G.f(0.5)).s)
            let ripple = g.add(G.f(0.72), g.mul(g.smoothstep(G.f(0.2), G.f(1), wave.s).s, G.f(0.28)).s)
            let angleLevel = g.add(G.f(0.42), g.mul(g.pow(grazing.s, G.f(0.6)).s, G.f(0.58)).s)

            // Cyclic four-stop ramp as a sum of hat functions: t = 4·phase, colour = Σ cᵢ·max(0, 1 − |t − i|), c₄ = c₀.
            let t = g.mul(phase.s, G.f(4))
            let stops = MagicPalette.foilStops + [MagicPalette.foilStops[0]]
            var ramp: G.Port?
            for (index, hex) in stops.enumerated() {
                let hat = g.max(g.oneMinus(g.abs(g.sub(t.s, G.f(Float(index))).s).s).s, G.f(0))
                let term = g.mul(.value(.srgb(hex)), hat.s)
                if let sum = ramp { ramp = g.add(sum.s, term.s) } else { ramp = term }
            }

            // Diffraction glitter: a fine noise that re-rolls as the eye moves.
            let glitterPosition = g.add(g.mul(p3.s, G.f(420)).s, g.mul(view.s, G.f(2.5)).s)
            let glitter = g.smoothstep(G.f(0.74), G.f(0.9), g.noise3d(glitterPosition.s, amplitude: 0.5, pivot: 0.5).s)

            // The sweep band, top-left → bottom-right (squared: a bright core with soft shoulders).
            let bandLinear = sweepBand(&g, qx: qx, qy: qy, sweep: sweep, width: 0.09)
            let band = g.mul(bandLinear.s, bandLinear.s)

            // Calmer in the middle of the card, where the avatar and the numbers sit.
            let radius = g.length(q.s)
            let vignette = g.add(G.f(0.7), g.mul(g.smoothstep(G.f(0.25), G.f(0.95), radius.s).s, G.f(0.3)).s)

            let base = g.mul(g.mul(angleLevel.s, ripple.s).s, vignette.s)
            let level = g.clamp(g.add(g.add(base.s, g.mul(glitter.s, G.f(0.25)).s).s, g.mul(band.s, G.f(0.7)).s).s)
            let intensity = g.mul(g.mul(level.s, cap.s).s, g.clamp(strength.s).s)
            // Pastel: the bible's four hues, half-way to white; the sweep warms them toward white-gold.
            let pastel = g.mix(ramp!.s, .value(.color3([1, 1, 1])), G.f(MagicMaterialRules.foilPastel))
            let sheen = g.mix(pastel.s, .value(.srgb(MagicPalette.goldHot)), g.mul(band.s, G.f(0.5)).s)
            let color = g.mul(sheen.s, intensity.s)
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(0), premultiplied: true))
            return g
        }

        // MARK: GoldEdge

        /// The inset gold line, drawn from the outline's signed distance: a `lineWidth` line `inset` inside the
        /// outline (anti-aliased over ±0.35 mm) with a 4.5 mm halo and `outerGlow` light spilling up to 6 mm past the
        /// outline, glowing `baseColor` (old gold) and running up to `hotColor` (gold) and a white-gold core where the
        /// diagonal `sweep` band crosses it. Additive; the line goes above 1 inside the band so bloom can catch it.
        /// Draw it on `MagicMeshes.goldEdgeRing` (7 mm in, 6 mm out of the outline).
        static func goldEdge(halfSize: SIMD2<Float> = slabHalfSize, cornerRadius: Float = slabCornerRadius) -> G {
            var g = G(name: goldEdgeName)
            let sweep = g.parameter(Param.sweep, .float(0))
            let intensity = g.parameter(Param.intensity, .float(1))
            let baseColor = g.parameter(Param.baseColor, .srgb(MagicPalette.oldGold))
            let hotColor = g.parameter(Param.hotColor, .srgb(MagicPalette.gold))
            let half = g.parameter(Param.halfSize, .vector2(halfSize))
            let radius = g.parameter(Param.cornerRadius, .float(cornerRadius))
            let inset = g.parameter(Param.inset, .float(MagicMaterialRules.goldInset))
            let lineWidth = g.parameter(Param.lineWidth, .float(MagicMaterialRules.goldLineWidth))
            let outerGlow = g.parameter(Param.outerGlow, .float(0.35))

            let p3 = g.position(space: "object")
            let p = g.convert(p3.s, to: .vector2)
            let distance = g.roundedRectDistance(p.s, halfSize: half.s, radius: radius.s)
            let halfLine = g.mul(lineWidth.s, G.f(0.5))
            let centre = g.mul(g.add(inset.s, halfLine.s).s, G.f(-1))
            let offset = g.abs(g.sub(distance.s, centre.s).s)
            let line = g.oneMinus(g.smoothstep(g.sub(halfLine.s, G.f(0.00035)).s, g.add(halfLine.s, G.f(0.00035)).s, offset.s).s)
            let haloLinear = g.oneMinus(g.smoothstep(G.f(0), G.f(0.0045), offset.s).s)
            let halo = g.mul(haloLinear.s, haloLinear.s)
            // Light spilling past the outline (the mesh reaches 6 mm outside it): what makes the card's edge read as
            // lit rather than drawn. The slab itself cannot draw it — it has no pixels there.
            let outsideMask = g.smoothstep(G.f(-0.0004), G.f(0.0004), distance.s)
            let spillLinear = g.oneMinus(g.smoothstep(G.f(0), G.f(0.006), g.max(distance.s, G.f(0)).s).s)
            let spill = g.mul(g.mul(g.mul(spillLinear.s, spillLinear.s).s, outsideMask.s).s, outerGlow.s)

            let q = g.div(p.s, half.s)
            let band = sweepBand(&g, qx: g.extract(q.s, 0), qy: g.extract(q.s, 1), sweep: sweep, width: 0.12)
            let hot = g.pow(band.s, G.f(3))
            let tone = g.mix(baseColor.s, hotColor.s, band.s)
            let lineLevel = g.mul(line.s, g.add(G.f(1), g.mul(band.s, G.f(1.6)).s).s)
            let haloLevel = g.mul(halo.s, g.add(G.f(0.22), g.mul(band.s, G.f(0.9)).s).s)
            let spillLevel = g.mul(spill.s, g.add(G.f(1), g.mul(band.s, G.f(1.2)).s).s)
            let level = g.mul(g.add(g.add(lineLevel.s, haloLevel.s).s, spillLevel.s).s, intensity.s)
            let core = g.mul(.value(.srgb(MagicPalette.goldHot)), g.mul(g.mul(line.s, hot.s).s, g.mul(intensity.s, G.f(1.2)).s).s)
            let color = g.add(g.mul(tone.s, level.s).s, core.s)
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(0), premultiplied: true))
            return g
        }

        // MARK: MagicDissolve

        /// Reveal / dissolve. The fill front moves from the outline inward (distance-to-outline, 68 %, warped by a
        /// fractal noise, 32 %), with a glowing gold band — hot core, sparks — riding the front. `progress` 0 is
        /// "fully transparent, only a glowing outline"; 1 is exactly `crystalSlab` (same light, same parameters),
        /// so the product can swap materials at the end without a pop.
        static func magicDissolve(halfSize: SIMD2<Float> = slabHalfSize, cornerRadius: Float = slabCornerRadius,
                                  blur: Bool = backgroundBlur) -> G {
            var g = G(name: magicDissolveName)
            let crystal = crystalParameters(&g, halfSize: halfSize, cornerRadius: cornerRadius)
            let progress = g.parameter(Param.progress, .float(1))
            let edgeWidth = g.parameter(Param.edgeWidth, .float(0.06))
            let edgeColor = g.parameter(Param.edgeColor, .srgb(MagicPalette.gold))
            let noiseScale = g.parameter(Param.noiseScale, .float(16))
            let glow = g.parameter(Param.glow, .float(1))

            let p3 = g.position(space: "object")
            let p = g.convert(p3.s, to: .vector2)
            let distance = g.roundedRectDistance(p.s, halfSize: crystal.halfSize.s, radius: crystal.cornerRadius.s)
            let reach = g.min(g.extract(crystal.halfSize.s, 0).s, g.extract(crystal.halfSize.s, 1).s)
            let inward = g.clamp(g.div(g.max(g.mul(distance.s, G.f(-1)).s, G.f(0)).s, reach.s).s)
            let noise = g.fractal3d(g.mul(p3.s, noiseScale.s).s, octaves: 4, amplitude: 1)
            let noise01 = g.clamp(g.add(g.mul(noise.s, G.f(0.5)).s, G.f(0.5)).s)
            let field = g.add(g.mul(inward.s, G.f(0.68)).s, g.mul(noise01.s, G.f(0.32)).s)

            let front = g.mul(progress.s, g.add(G.f(1), edgeWidth.s).s)
            let ahead = g.sub(front.s, field.s)
            let revealed = g.smoothstep(g.mul(edgeWidth.s, G.f(0.5)).s, edgeWidth.s, ahead.s)
            let rise = g.smoothstep(G.f(0), g.mul(edgeWidth.s, G.f(0.35)).s, ahead.s)
            let edge = g.mul(rise.s, g.oneMinus(revealed.s).s)
            let outline = g.mul(g.oneMinus(g.smoothstep(G.f(0), G.f(0.02), inward.s).s).s,
                                g.oneMinus(g.smoothstep(G.f(0.55), G.f(1), progress.s).s).s)
            let hotCore = g.pow(edge.s, G.f(3))
            let sparks = g.mul(g.smoothstep(G.f(0.72), G.f(0.88),
                                            g.noise3d(g.mul(p3.s, G.f(500)).s, amplitude: 0.5, pivot: 0.5).s).s, edge.s)
            // Gold, not white: the band stays below clipping except its core and the sparks, which is where bloom
            // should pick it up.
            let glowLevel = g.mul(g.add(g.add(g.add(g.mul(edge.s, G.f(0.6)).s, g.mul(hotCore.s, G.f(0.35)).s).s,
                                              g.mul(outline.s, G.f(0.9)).s).s, g.mul(sparks.s, G.f(1.1)).s).s, glow.s)
            let glowColor = g.add(g.mul(edgeColor.s, glowLevel.s).s,
                                  g.mul(.value(.srgb(MagicPalette.goldHot)), g.mul(g.mul(hotCore.s, glow.s).s, G.f(0.2)).s).s)

            let body = crystalLight(&g, crystal, blur: blur)
            let color = g.add(g.mul(body.color.s, revealed.s).s, glowColor.s)
            let alpha = g.mul(body.alpha.s, revealed.s)
            g.setSurface(g.unlitSurface(color: color.s, opacity: alpha.s, premultiplied: true))
            return g
        }

        // MARK: SweepGlint

        /// The sweep as a standalone light (for a card whose face is covered by an opaque panel, e.g. A4's hero card,
        /// where CrystalSlab's own glint would be hidden): the same warm band with a hot core as the slab's glint,
        /// additive, on a plane of `halfSize`. `sweep` 0…1 as everywhere; `intensity` scales it.
        static func sweepGlint(halfSize: SIMD2<Float> = cardHalfSize) -> G {
            var g = G(name: sweepGlintName)
            let sweep = g.parameter(Param.sweep, .float(1))
            let intensity = g.parameter(Param.intensity, .float(1))
            let half = g.parameter(Param.halfSize, .vector2(halfSize))
            let p3 = g.position(space: "object")
            let q = g.div(g.convert(p3.s, to: .vector2).s, half.s)
            let band = sweepBand(&g, qx: g.extract(q.s, 0), qy: g.extract(q.s, 1), sweep: sweep, width: 0.1)
            let soft = g.pow(band.s, G.f(3))
            let core = g.pow(band.s, G.f(14))
            let level = g.mul(g.add(g.mul(soft.s, G.f(0.1)).s, g.mul(core.s, G.f(0.26)).s).s, intensity.s)
            let color = g.mul(.value(.srgb(MagicPalette.rimWarmWhite)), level.s)
            g.setSurface(g.unlitSurface(color: color.s, opacity: G.f(0), premultiplied: true))
            return g
        }

        // MARK: InkVeil

        /// A soft ink plate behind type on a pale card (bible §1: `ink` is the colour for text on a light ground):
        /// `ink` at `opacity` inside a rounded rectangle of `halfSize` / `cornerRadius`, fading to nothing over
        /// `softness` metres past its edge. It is what keeps gold numerals above 4.5 : 1 over frosted crystal in a
        /// lit room (A1 review, 2026-09-26).
        static func inkVeil(halfSize: SIMD2<Float> = [0.1, 0.03], cornerRadius: Float = 0.02) -> G {
            var g = G(name: inkVeilName)
            let opacity = g.parameter(Param.opacity, .float(MagicMaterialRules.inkVeilOpacity))
            let ink = g.parameter(Param.tint, .srgb(MagicPalette.ink))
            let half = g.parameter(Param.halfSize, .vector2(halfSize))
            let radius = g.parameter(Param.cornerRadius, .float(cornerRadius))
            let softness = g.parameter(Param.softness, .float(0.012))
            let p = g.convert(g.position(space: "object").s, to: .vector2)
            let distance = g.roundedRectDistance(p.s, halfSize: half.s, radius: radius.s)
            let fade = g.oneMinus(g.smoothstep(g.mul(softness.s, G.f(-0.5)).s, softness.s, distance.s).s)
            let alpha = g.mul(fade.s, opacity.s)
            let color = g.mul(ink.s, alpha.s)
            g.setSurface(g.unlitSurface(color: color.s, opacity: alpha.s, premultiplied: true))
            return g
        }

        // MARK: Shared pieces

        /// 1 at the sweep band's centre, 0 beyond `width` (in sweep-diagonal units).
        static func sweepBand(_ g: inout G, qx: G.Port, qy: G.Port, sweep: G.Port, width: Float) -> G.Port {
            let s = g.add(g.mul(g.sub(qx.s, qy.s).s, G.f(0.25)).s, G.f(0.5))
            let rules = MagicMaterialRules.self
            let centre = g.add(G.f(-rules.sweepOvershoot), g.mul(sweep.s, G.f(1 + 2 * rules.sweepOvershoot)).s)
            return g.oneMinus(g.smoothstep(G.f(0), G.f(width), g.abs(g.sub(s.s, centre.s).s).s).s)
        }
    }
}

extension V4.ShadeGraph {
    /// Signed distance (metres) from a vector2 point to a rounded rectangle centred on the origin, negative inside:
    /// `length(max(q, 0)) + min(max(q.x, q.y), 0) − r` with `q = |p| − (halfSize − r)`.
    mutating func roundedRectDistance(_ p: Source, halfSize: Source, radius: Source) -> Port {
        let q = sub(abs(p).s, sub(halfSize, radius).s)
        let outside = length(max(q.s, Self.f(0)).s)
        let inside = min(max(extract(q.s, 0).s, extract(q.s, 1).s).s, Self.f(0))
        return sub(add(outside.s, inside.s).s, radius)
    }

    /// The same distance on the CPU (tests, and the lab's readouts).
    static func roundedRectDistance(_ p: SIMD2<Float>, halfSize: SIMD2<Float>, radius: Float) -> Float {
        let q = simd_abs(p) - (halfSize - SIMD2(repeating: radius))
        let outside = simd_length(simd_max(q, .zero))
        let inside = Swift.min(Swift.max(q.x, q.y), 0)
        return outside + inside - radius
    }
}
