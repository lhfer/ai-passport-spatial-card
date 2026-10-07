import XCTest
import simd

/// **v4 A1.** The four material graphs hold together (no dangling connection, the parameters the wrappers set), and
/// the numbers the art bible fixes are the numbers the graphs are built from.
final class V4MagicMaterialsTests: XCTestCase {
    typealias Graphs = V4.MagicMaterialGraphs
    typealias Rules = V4.MagicMaterialRules
    typealias P = V4.MagicMaterialGraphs.Param

    private var all: [V4.ShadeGraph] {
        [Graphs.crystalSlab(), Graphs.holoFoil(), Graphs.goldEdge(), Graphs.magicDissolve(), Graphs.sweepGlint(),
         Graphs.inkVeil()]
    }

    func testEveryGraphIsWellFormed() {
        for graph in all {
            XCTAssertEqual(graph.problems(), [], graph.name)
            XCTAssertNotNil(graph.surface, graph.name)
            XCTAssertEqual(Set(graph.nodes.map(\.name)).count, graph.nodes.count, "\(graph.name): unique node names")
            XCTAssertTrue(graph.usda().contains("def Material \"\(graph.name)\""))
        }
    }

    /// The parameters the brief names (and the wrappers set) exist on each graph.
    func testBriefParametersExist() {
        let crystal = Set(Graphs.crystalSlab().parameterNames)
        XCTAssertTrue(crystal.isSuperset(of: [P.tint, P.rimColor, P.rimFacing, P.rimGrazing, P.opacity]))
        let foil = Set(Graphs.holoFoil().parameterNames)
        XCTAssertTrue(foil.isSuperset(of: [P.strength, P.sweep]))
        let edge = Set(Graphs.goldEdge().parameterNames)
        XCTAssertTrue(edge.isSuperset(of: [P.sweep, P.baseColor, P.hotColor, P.inset, P.lineWidth]))
        let dissolve = Set(Graphs.magicDissolve().parameterNames)
        XCTAssertTrue(dissolve.isSuperset(of: [P.progress, P.edgeWidth, P.edgeColor, P.noiseScale]))
    }

    /// A finished dissolve *is* the slab: it carries every CrystalSlab parameter, so the product can swap the two
    /// materials at progress 1 with the same values set on both.
    func testDissolveCarriesTheSlab() {
        let crystal = Set(Graphs.crystalSlab().parameterNames)
        let dissolve = Set(Graphs.magicDissolve().parameterNames)
        XCTAssertTrue(dissolve.isSuperset(of: crystal))
    }

    /// Every graph is additive / premultiplied (a body and a glow share one material) and not tone-mapped.
    func testSurfacesArePremultipliedUnlit() {
        for graph in all {
            let surface = graph.nodes.first { $0.name == "Surface" }
            XCTAssertEqual(surface?.nodedef, "ND_realitykit_unlit_surfaceshader", graph.name)
            let uniforms = Dictionary(uniqueKeysWithValues: (surface?.inputs ?? []).filter(\.uniform).map { ($0.name, $0.source) })
            XCTAssertEqual(uniforms["hasPremultipliedAlpha"], .value(.boolean(true)), graph.name)
            XCTAssertEqual(uniforms["applyPostProcessToneMap"], .value(.boolean(false)), graph.name)
        }
    }

    // MARK: Art bible numbers

    /// §2: foil ≤ 0.12 square-on, ≤ 0.45 edge-on, monotonic in between.
    func testFoilCap() {
        XCTAssertEqual(Rules.foilCap(facing: 1), 0.12, accuracy: 1e-6)
        XCTAssertEqual(Rules.foilCap(facing: -1), 0.12, accuracy: 1e-6, "the back of the card is square-on too")
        XCTAssertEqual(Rules.foilCap(facing: 0), 0.45, accuracy: 1e-6)
        var previous = Rules.foilCap(facing: 1)
        for degrees in stride(from: Float(0), through: 90, by: 5) {
            let cap = Rules.foilCap(facing: cos(degrees * .pi / 180))
            XCTAssertGreaterThanOrEqual(cap, previous - 1e-6)
            XCTAssertLessThanOrEqual(cap, 0.45 + 1e-6)
            XCTAssertGreaterThanOrEqual(cap, 0.12 - 1e-6)
            previous = cap
        }
        // The wrist's own range: at the lab's 35° the foil may rise to about 0.21.
        XCTAssertEqual(Rules.foilCap(facing: cos(35 * .pi / 180)), 0.2116, accuracy: 1e-3)
    }

    /// The cap is in the graph (the facing value and the range it grows by are literal nodes), and `strength` is
    /// clamped to 1 there — no parameter can push the foil past the bible.
    func testFoilCapIsBuiltIntoTheGraph() {
        let text = Graphs.holoFoil().usda()
        XCTAssertTrue(text.contains("float inputs:in1 = 0.12"), "facing cap constant")
        XCTAssertTrue(text.contains("float inputs:in2 = 0.33"), "facing → grazing range constant")
        XCTAssertTrue(text.contains("float inputs:in2 = 0.75"), "cap exponent")
        let strengthClamp = Graphs.holoFoil().nodes.first { node in
            node.nodedef == "ND_clamp_float" && node.inputs.contains { input in
                if case .port(let port) = input.source { return port.target.hasSuffix(".inputs:strength>") }
                return false
            }
        }
        XCTAssertNotNil(strengthClamp, "strength must pass through a clamp to [0, 1]")
    }

    /// §2: the slab's edge light 0.45 square-on → 0.9 edge-on, v3's exponent.
    func testRimLevel() {
        XCTAssertEqual(Rules.rimLevel(facing: 1), 0.45, accuracy: 1e-6)
        XCTAssertEqual(Rules.rimLevel(facing: 0), 0.9, accuracy: 1e-6)
        XCTAssertEqual(Rules.rimLevel(facing: 0.5), 0.45 + 0.45 * pow(0.5, 1.5), accuracy: 1e-5)
        let crystal = Graphs.crystalSlab()
        let defaults = Dictionary(uniqueKeysWithValues: crystal.parameters.map { ($0.name, $0.value) })
        XCTAssertEqual(defaults[P.rimFacing], .float(0.45))
        XCTAssertEqual(defaults[P.rimGrazing], .float(0.9))
    }

    /// The body's frosted white is 35–50 % (review 2026-09-26, raised from the bible's 6–12 % clear plate) over a
    /// 75 % frost; the gold line sits 1.5 mm in.
    func testDefaults() {
        let crystal = Dictionary(uniqueKeysWithValues: Graphs.crystalSlab().parameters.map { ($0.name, $0.value) })
        guard case .float(let opacity)? = crystal[P.opacity] else { return XCTFail("opacity") }
        XCTAssertTrue(Rules.slabOpacityRange.contains(opacity))
        XCTAssertEqual(Rules.slabOpacityRange, 0.35...0.5)
        XCTAssertEqual(crystal[P.frost], .float(0.75))
        XCTAssertEqual(crystal[P.halfSize], .vector2([0.141, 0.141]), "HologramLayout.slabWidth / 2")
        let edge = Dictionary(uniqueKeysWithValues: Graphs.goldEdge().parameters.map { ($0.name, $0.value) })
        XCTAssertEqual(edge[P.inset], .float(0.0015))
        XCTAssertEqual(edge[P.baseColor], .srgb(V4.MagicPalette.oldGold))
        XCTAssertEqual(edge[P.hotColor], .srgb(V4.MagicPalette.gold))
    }

    /// The sweep enters past one corner and leaves past the other, top-left to bottom-right.
    func testSweepGeometry() {
        XCTAssertEqual(Rules.sweepCenter(0), -0.15, accuracy: 1e-6)
        XCTAssertEqual(Rules.sweepCenter(1), 1.15, accuracy: 1e-6)
        XCTAssertEqual(Rules.sweepCoordinate([-1, 1]), 0, accuracy: 1e-6)
        XCTAssertEqual(Rules.sweepCoordinate([1, -1]), 1, accuracy: 1e-6)
        XCTAssertEqual(Rules.sweepCoordinate([0, 0]), 0.5, accuracy: 1e-6)
    }

    /// The frost is RealityKit's background blur (probe Q18 / the lab's `--materials-blur-only`), not a white sheet.
    /// `--card-frost plain`: no graph that shows the card may schedule a background-blur pass.
    func testPlainFrostLeavesTheBlurPassOut() {
        let saved = Graphs.backgroundBlur
        defer { Graphs.backgroundBlur = saved }
        Graphs.backgroundBlur = false
        for graph in [Graphs.crystalSlab(), Graphs.magicDissolve()] {
            XCTAssertFalse(graph.nodes.contains { $0.nodedef == "ND_realitykit_background_blur_color3" }, graph.name)
        }
    }

    /// `--card-frost blur` (the switch back since v4 B4): both graphs that show the card frost with the background blur.
    func testBlurFrostsWithTheBackgroundBlur() {
        let saved = Graphs.backgroundBlur
        defer { Graphs.backgroundBlur = saved }
        Graphs.backgroundBlur = true
        for graph in [Graphs.crystalSlab(), Graphs.magicDissolve()] {
            XCTAssertTrue(graph.nodes.contains { $0.nodedef == "ND_realitykit_background_blur_color3" }, graph.name)
        }
    }

    /// **v4 B4 §3.1** — `plain` is the default (the user's call after round 2); only an explicit `blur` brings the pass back.
    func testPlainIsTheDefaultFrost() {
        XCTAssertFalse(Graphs.frostSamplesBlur([]))
        XCTAssertFalse(Graphs.frostSamplesBlur(["SpatialCard", "--fake-track", "x.json"]))
        XCTAssertFalse(Graphs.frostSamplesBlur(["SpatialCard", "--card-frost", "plain"]))
        XCTAssertFalse(Graphs.frostSamplesBlur(["SpatialCard", "--card-frost"]))
        XCTAssertFalse(Graphs.frostSamplesBlur(["SpatialCard", "--card-frost", "frosted"]))
        XCTAssertTrue(Graphs.frostSamplesBlur(["SpatialCard", "--card-frost", "blur"]))
        XCTAssertTrue(Graphs.frostSamplesBlur(["SpatialCard", "--card-frost", "BLUR"]))
    }

    /// The foil is a pastel sheen (hues lifted 30 % toward white), quiet square-on (its level starts at 0.42 of the
    /// cap and only reaches the cap edge-on) — never a saturated film, never a base colour.
    func testFoilIsPastelAndQuietSquareOn() {
        let text = Graphs.holoFoil().usda()
        XCTAssertTrue(text.contains("float inputs:mix = 0.3"), "pastel lift toward white")
        XCTAssertTrue(text.contains("float inputs:in1 = 0.42"), "square-on level")
        XCTAssertEqual(Rules.foilPastel, 0.3)
    }

    /// Gold numerals on the ink veil stay above WCAG 4.5 : 1 whatever is behind the card (dark room → white wall):
    /// the lab measured 8.2 : 1 (night) and 7.0 : 1 (day) medians on the rendered pixels.
    func testInkVeilKeepsGoldReadable() {
        let gold = Rules.luminance(linear: V4.ShadeGraph.linear(hex: V4.MagicPalette.gold))
        for step in 0...10 {
            let behind = Float(step) / 10
            let ground = Rules.luminanceThroughInkVeil(behind: behind)
            XCTAssertGreaterThanOrEqual(Rules.contrast(gold, ground), 4.5, "behind = \(behind)")
        }
        // Without the veil, gold on a pale card fails — which is why the veil exists.
        XCTAssertLessThan(Rules.contrast(gold, 0.6), 4.5)
    }

    /// During a reveal the line comes before the foil, and both are fully up at the end.
    func testRevealRamps() {
        XCTAssertEqual(Rules.revealEdgeIntensity(0), 0)
        XCTAssertEqual(Rules.revealEdgeIntensity(1), 1)
        XCTAssertEqual(Rules.revealFoilStrength(0.7), 0)
        XCTAssertEqual(Rules.revealFoilStrength(1), 1)
        XCTAssertGreaterThan(Rules.revealEdgeIntensity(0.85), Rules.revealFoilStrength(0.85))
    }
}
