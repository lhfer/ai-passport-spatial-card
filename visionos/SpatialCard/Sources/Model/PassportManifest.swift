import Foundation
import simd

/// Which part of the card bitmap a pixel belongs to. The ink / pixel reveals typeset the named bands onto
/// the glass card; the rest becomes dust, frame or edge sparks.
enum PassportBand: Int {
    case avatar = 0
    case name = 1
    case handle = 2
    case location = 3
    case tags = 4
    /// Ink that has no place on the glass card (bullets, decoration): drifts to the card's foot and dissolves.
    case otherInk = 5
    /// Background of the bitmap ("paper"): turns to dust.
    case paper = 6
    /// Outside the LCD's rounded-rect mask (the BSP blacks these pixels): flies off as edge sparks.
    case border = 7
    /// Background near the edge that re-forms as the glass card's bevel frame.
    case frame = 8
    /// The dynamic followers strip: typesets onto the stats row.
    case followers = 9
}

/// `Resources/passport-manifest.json`, written by the hub's `pnpm screens` pipeline: the physical size of the
/// AI Passport's active area, the pixel layout shared by the LCD bitmap (1×) and the ARKit reference images
/// (`referenceScale`×), and one entry per theme screen with its reference image, imageset and content regions
/// in normalised image coordinates (u right, vTop down). Read-only for the app; never edited by hand.
struct PassportManifest: Codable, Equatable {
    struct Region: Codable, Equatable {
        /// `[cu, cvTop, r]` — `r` is a fraction of the image *width* (`r * 240 = px`), on a 3:4 frame.
        var circle: [Float]?
        /// `[u0, v0, u1, v1]`.
        var rect: [Float]?

        /// `aspect` = height / width of the image, so the circle test happens in width units on both axes.
        func contains(u: Float, vTop: Float, aspect: Float) -> Bool {
            if let c = circle, c.count >= 3 {
                let dx = (u - c[0]), dy = (vTop - c[1]) * aspect
                return dx * dx + dy * dy <= c[2] * c[2]
            }
            if let r = rect, r.count >= 4 {
                return u >= r[0] && u <= r[2] && vTop >= r[1] && vTop <= r[3]
            }
            return false
        }
    }

    struct Theme: Codable, Equatable, Identifiable {
        var id: String
        var label: String
        /// World this theme screen belongs to (nil for the plain card).
        var world: String?
        /// Name inside `CardReference.arresourcegroup`.
        var referenceImage: String
        /// Imageset name of the same bitmap (registration layer, pixel cloud).
        var bitmap: String
        var regions: [String: Region]

        /// Named region containing the point, in typesetting priority (avatar first, followers strip last).
        /// `aspect` = image height / width (see `Region.contains`).
        func band(u: Float, vTop: Float, aspect: Float) -> PassportBand? {
            for (name, band) in PassportManifest.regionBands where regions[name]?.contains(u: u, vTop: vTop, aspect: aspect) == true {
                return band
            }
            return nil
        }
    }

    struct DynamicRegion: Codable, Equatable {
        /// `[x, y, w, h]` in bitmap pixels (1×).
        var rect: [Int]
    }

    var schema: Int
    var generatedBy: String?
    var physicalWidthMeters: Float
    var physicalHeightMeters: Float
    /// `[w, h]` of the LCD bitmap (1×).
    var pixelSize: [Int]
    /// Reference images are `referenceScale` × `pixelSize`.
    var referenceScale: Int
    /// Corner radius of the LCD's rounded-rect mask, in 1× pixels.
    var cornerRadiusPx: Int
    var dynamicRegion: DynamicRegion
    var themes: [Theme]

    static let resourceName = "passport-manifest"
    /// Region name → band, in the order `Theme.band` tests them.
    static let regionBands: [(String, PassportBand)] = [
        ("avatar", .avatar), ("name", .name), ("handle", .handle), ("location", .location), ("tags", .tags), ("followers", .followers),
    ]

    /// The bundled manifest; a built-in seed (same numbers as the shipped JSON) if it is missing or malformed.
    static let shared: PassportManifest = load()

    static func load(bundle: Bundle = .main) -> PassportManifest {
        if let url = bundle.url(forResource: resourceName, withExtension: "json"),
           let data = try? Data(contentsOf: url) {
            do {
                return try JSONDecoder().decode(PassportManifest.self, from: data)
            } catch {
                print("[theme] passport-manifest.json invalid: \(error)")
            }
        } else {
            print("[theme] passport-manifest.json missing — using the built-in seed")
        }
        return .seed
    }

    /// Physical size (m) of the tracked image; identical for every theme.
    var footprint: SIMD2<Float> { [physicalWidthMeters, physicalHeightMeters] }

    var defaultTheme: Theme { themes.first ?? PassportManifest.seed.themes[0] }

    func theme(id: String) -> Theme? { themes.first { $0.id == id } }

    func theme(forReferenceImage name: String) -> Theme? { themes.first { $0.referenceImage == name } }

    /// Theme screen a world shows on the device (worlds without their own screen map to the base theme).
    func theme(forWorld world: String?) -> Theme {
        guard let world, let t = themes.first(where: { $0.world == world }) else { return defaultTheme }
        return t
    }

    /// Whether a normalised point lies outside the rounded-rect mask the LCD driver applies (those pixels are black).
    func isMasked(u: Float, vTop: Float) -> Bool {
        guard pixelSize.count >= 2, pixelSize[0] > 0, pixelSize[1] > 0 else { return false }
        let w = Float(pixelSize[0]), h = Float(pixelSize[1]), r = Float(cornerRadiusPx)
        let px = u * w, py = vTop * h
        if px < 0 || py < 0 || px > w || py > h { return true }
        // Distance test against the nearest corner circle centre.
        let cx = px < r ? r : (px > w - r ? w - r : px)
        let cy = py < r ? r : (py > h - r ? h - r : py)
        let dx = px - cx, dy = py - cy
        return dx * dx + dy * dy > r * r + 0.001
    }

    /// Image height / width (3:4 → 1.333): circle radii are fractions of the width.
    var aspect: Float {
        guard pixelSize.count >= 2, pixelSize[0] > 0 else { return 4.0 / 3.0 }
        return Float(pixelSize[1]) / Float(pixelSize[0])
    }

    /// Band of a bitmap pixel for `theme`: outside the mask → `.border`; a named region → its band; else `.otherInk`.
    /// (Whether it is background "paper" or edge "frame" depends on the colour and is decided by the pixel cloud.)
    func band(u: Float, vTop: Float, theme: Theme) -> PassportBand {
        if isMasked(u: u, vTop: vTop) { return .border }
        return theme.band(u: u, vTop: vTop, aspect: aspect) ?? .otherInk
    }

    /// Normalised rect of the dynamic (followers) strip: `[u0, v0, u1, v1]`.
    var dynamicStrip: [Float] {
        guard pixelSize.count >= 2, dynamicRegion.rect.count >= 4 else { return [0, 0.85, 1, 1] }
        let w = Float(pixelSize[0]), h = Float(pixelSize[1])
        let r = dynamicRegion.rect.map(Float.init)
        return [r[0] / w, r[1] / h, (r[0] + r[2]) / w, (r[1] + r[3]) / h]
    }

    /// Built-in copy of the seed manifest (keeps preview / tests working without the bundle resource).
    static let seed = PassportManifest(
        schema: 1,
        generatedBy: "built-in seed",
        physicalWidthMeters: 0.03672,
        physicalHeightMeters: 0.04896,
        pixelSize: [240, 320],
        referenceScale: 2,
        cornerRadiusPx: 30,
        dynamicRegion: DynamicRegion(rect: [0, 272, 240, 48]),
        themes: [
            Theme(id: "base", label: "名片", world: nil, referenceImage: "passport-base", bitmap: "PassportBase", regions: [
                "avatar": Region(circle: [0.50, 0.24, 0.19], rect: nil),
                "name": Region(circle: nil, rect: [0.08, 0.47, 0.92, 0.56]),
                "handle": Region(circle: nil, rect: [0.08, 0.56, 0.92, 0.61]),
                "location": Region(circle: nil, rect: [0.08, 0.61, 0.92, 0.66]),
                "tags": Region(circle: nil, rect: [0.08, 0.68, 0.92, 0.80]),
                "followers": Region(circle: nil, rect: [0.00, 0.85, 1.00, 1.00]),
            ]),
            Theme(id: "neon-city", label: "霓虹雨城", world: "neon-city", referenceImage: "passport-neon-city", bitmap: "PassportNeonCity", regions: [
                "avatar": Region(circle: [0.24, 0.72, 0.13], rect: nil),
                "name": Region(circle: nil, rect: [0.40, 0.66, 0.95, 0.74]),
                "handle": Region(circle: nil, rect: [0.40, 0.74, 0.95, 0.79]),
                "tags": Region(circle: nil, rect: [0.08, 0.10, 0.92, 0.22]),
                "followers": Region(circle: nil, rect: [0.00, 0.85, 1.00, 1.00]),
            ]),
            Theme(id: "data-nebula", label: "数据星云", world: "data-nebula", referenceImage: "passport-data-nebula", bitmap: "PassportDataNebula", regions: [
                "avatar": Region(circle: [0.66, 0.34, 0.16], rect: nil),
                "name": Region(circle: nil, rect: [0.08, 0.62, 0.92, 0.70]),
                "handle": Region(circle: nil, rect: [0.08, 0.70, 0.92, 0.75]),
                "tags": Region(circle: nil, rect: [0.08, 0.08, 0.60, 0.20]),
                "followers": Region(circle: nil, rect: [0.00, 0.85, 1.00, 1.00]),
            ]),
        ]
    )
}
