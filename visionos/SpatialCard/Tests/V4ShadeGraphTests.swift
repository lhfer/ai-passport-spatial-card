import XCTest
import simd

/// **v4 A1.** The USD ShaderGraph writer: nodedef resolution from operand types, the text it emits, and the
/// structural check that stands in for the importer's opaque `internalImportError`.
final class V4ShadeGraphTests: XCTestCase {
    typealias G = V4.ShadeGraph

    /// MaterialX names its arithmetic overloads by operand type: same type → `_<type>`, vector × float → `FA`,
    /// and there is no float × vector.
    func testBinaryNodedefNames() {
        XCTAssertEqual(G.binaryNodedef("multiply", .float, .float), "ND_multiply_float")
        XCTAssertEqual(G.binaryNodedef("multiply", .color3, .float), "ND_multiply_color3FA")
        XCTAssertEqual(G.binaryNodedef("add", .vector2, .vector2), "ND_add_vector2")
        XCTAssertEqual(G.binaryNodedef("divide", .vector3, .float), "ND_divide_vector3FA")
        XCTAssertNil(G.binaryNodedef("multiply", .float, .color3))
        XCTAssertNil(G.binaryNodedef("add", .color3, .vector3))
    }

    /// A float on the left of a colour is commuted for multiply and widened (converted) for subtract.
    func testFloatOnTheLeftIsCommutedOrWidened() {
        var g = G(name: "T")
        let c = g.parameter("c", .color3([1, 0.5, 0]))
        let product = g.mul(G.f(2), c.s)
        XCTAssertEqual(product.kind, .color3)
        XCTAssertEqual(g.nodes.last?.nodedef, "ND_multiply_color3FA")
        XCTAssertEqual(g.nodes.last?.inputs.first?.source, .port(c), "the colour moves to in1")

        let difference = g.sub(G.f(1), c.s)
        XCTAssertEqual(difference.kind, .color3)
        XCTAssertEqual(g.nodes[g.nodes.count - 2].nodedef, "ND_convert_float_color3")
        XCTAssertEqual(g.nodes.last?.nodedef, "ND_subtract_color3")
    }

    /// `mix(a, b, t)` reads "from a to b": MaterialX's `bg` is `a`, `fg` is `b`.
    func testMixArgumentOrder() {
        var g = G(name: "T")
        let a = g.parameter("a", .float(0.2))
        let b = g.parameter("b", .float(0.8))
        _ = g.mix(a.s, b.s, G.f(0.25))
        let inputs = Dictionary(uniqueKeysWithValues: g.nodes.last!.inputs.map { ($0.name, $0.source) })
        XCTAssertEqual(inputs["bg"], .port(a))
        XCTAssertEqual(inputs["fg"], .port(b))
        XCTAssertEqual(g.nodes.last?.nodedef, "ND_mix_float")
    }

    /// The emitted layer: Material inputs with their values, typed connections, uniforms, the surface output.
    func testUSDText() {
        var g = G(name: "Probe")
        let gain = g.parameter("gain", .float(0.5))
        let colour = g.mul(.value(.color3([1, 0.5, 0])), gain.s)
        g.setSurface(g.unlitSurface(color: colour.s, opacity: G.f(0), premultiplied: true))
        let text = g.usda()
        XCTAssertTrue(text.hasPrefix("#usda 1.0"))
        XCTAssertTrue(text.contains("def Material \"Probe\""))
        XCTAssertTrue(text.contains("float inputs:gain = 0.5"))
        XCTAssertTrue(text.contains("token outputs:mtlx:surface.connect = </Root/Probe/Surface.outputs:out>"))
        XCTAssertTrue(text.contains("uniform token info:id = \"ND_multiply_color3FA\""))
        XCTAssertTrue(text.contains("color3f inputs:in1 = (1, 0.5, 0)"))
        XCTAssertTrue(text.contains("float inputs:in2.connect = </Root/Probe.inputs:gain>"))
        XCTAssertTrue(text.contains("uniform bool inputs:hasPremultipliedAlpha = 1"))
        XCTAssertEqual(g.materialPath, "/Root/Probe")
        XCTAssertEqual(g.problems(), [])
    }

    /// What the importer would only call `internalImportError`: a dangling connection, no surface, a dead parameter.
    func testProblemsAreNamed() {
        var g = G(name: "Broken")
        _ = g.parameter("unused", .float(1))
        let ghost = G.Port(target: "</Root/Broken/Nowhere.outputs:out>", kind: .float)
        _ = g.add(ghost.s, G.f(1))
        let problems = g.problems()
        XCTAssertTrue(problems.contains { $0.contains("missing </Root/Broken/Nowhere.outputs:out>") }, "\(problems)")
        XCTAssertTrue(problems.contains("no surface"))
        XCTAssertTrue(problems.contains("parameter unused is never read"))
    }

    /// Literals are POSIX-formatted whatever the device locale (a comma decimal would break the layer).
    func testLiterals() {
        XCTAssertEqual(G.Value.float(0.5).usdLiteral, "0.5")
        XCTAssertEqual(G.Value.float(12).usdLiteral, "12")
        XCTAssertEqual(G.Value.vector2([0.141, 0.141]).usdLiteral, "(0.141, 0.141)")
        XCTAssertEqual(G.Value.boolean(false).usdLiteral, "0")
        XCTAssertEqual(G.Value.integer(3).usdLiteral, "3")
        XCTAssertEqual(G.Value.string("world").usdLiteral, "\"world\"")
        XCTAssertEqual(G.Value.float(.nan).usdLiteral, "0")
    }

    /// Colour constants are written linear (sRGB decoded), which is what `setParameter(.color(CGColor))` matches —
    /// the probe's R10 / R11 tiles render the same.
    func testSRGBDecoding() {
        XCTAssertEqual(G.linear(hex: "#FFFFFF"), [1, 1, 1])
        XCTAssertEqual(G.linear(hex: "#000000"), [0, 0, 0])
        let grey = G.linear(hex: "#808080")
        XCTAssertEqual(grey.x, 0.2158605, accuracy: 1e-5)
        XCTAssertEqual(grey, [grey.x, grey.x, grey.x])
        let gold = G.linear(hex: "FFD58A")
        XCTAssertEqual(gold.x, 1, accuracy: 1e-6)
        XCTAssertGreaterThan(gold.y, gold.z)
    }

    /// The rounded-rectangle distance the gold line and the dissolve are drawn from.
    func testRoundedRectDistance() {
        let half: SIMD2<Float> = [0.141, 0.141]
        XCTAssertEqual(G.roundedRectDistance([0, 0], halfSize: half, radius: 0.036), -0.141, accuracy: 1e-6)
        XCTAssertEqual(G.roundedRectDistance([0.141, 0], halfSize: half, radius: 0.036), 0, accuracy: 1e-6)
        XCTAssertEqual(G.roundedRectDistance([0.15, 0], halfSize: half, radius: 0.036), 0.009, accuracy: 1e-6)
        // The corner is round: the bounding box's corner is outside by (√2 − 1)·r.
        XCTAssertEqual(G.roundedRectDistance([0.141, 0.141], halfSize: half, radius: 0.036),
                       (sqrt(2) - 1) * 0.036, accuracy: 1e-5)
    }
}
