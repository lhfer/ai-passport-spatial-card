import Foundation
import SwiftUI
import UIKit

/// Data side of a world (design doc §5.1): everything a world needs that is not code lives in
/// `Resources/worlds/<id>.json`. Adding a world = one JSON + one `World` implementation registered
/// in `WorldRegistry`. Everything after the palette is the tuning surface for the shots: durations,
/// shell, audio, art, follower mapping (`stats`) and take timing (`take`).
struct WorldDescriptor: Codable, Identifiable, Equatable {
    struct Palette: Codable, Equatable {
        var background: String
        var primary: String
        var secondary: String
        var highlight: String
        var accent: String
    }
    struct Transition: Codable, Equatable {
        var kind: String
        var duration: Float
    }
    struct Immersion: Codable, Equatable {
        /// Shell opacity while inside (0 = see the room, 1 = fully covered).
        var shellOpacity: Float
        /// Hex of the shell colour while inside.
        var shellColor: String
        /// Legacy field ("mixedShell"); every world stays in .mixed behind the shell and asks for .full only
        /// once the shell is opaque, so it is optional and unused.
        var mode: String?
    }
    struct Audio: Codable, Equatable {
        var ambient: String
        var entry: String
        var exit: String
    }
    /// Legacy budget hints (unused by the engine; kept optional so old JSON still decodes).
    struct Budget: Codable, Equatable {
        var maxParticles: Int
        var bloomStrength: Float
    }
    /// How follower counts map onto the world (star count, ticker digits, celebration caps).
    struct Stats: Codable, Equatable {
        var starsMin: Int = 500
        var starsMax: Int = 20000
        /// Most stars / flaps one celebration injects.
        var celebrateCap: Int = 300
        var tickerDigits: Int = 6

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            starsMin = try c.decodeIfPresent(Int.self, forKey: .starsMin) ?? 500
            starsMax = try c.decodeIfPresent(Int.self, forKey: .starsMax) ?? 20000
            celebrateCap = try c.decodeIfPresent(Int.self, forKey: .celebrateCap) ?? 300
            tickerDigits = try c.decodeIfPresent(Int.self, forKey: .tickerDigits) ?? 6
        }
    }
    /// Shot timing inside a world (seconds from the moment the world is fully inside).
    struct Take: Codable, Equatable {
        var trainPeriod: Float = 16
        var trainFirst: Float = 1.5
        var cometPeriod: Float = 18
        var cometFirst: Float = 4
        /// Seconds after the world is fully inside before the hero shot starts (数据星云: the galactic disc tilts).
        var heroAt: Float = 3.5
        /// Degrees the hero shot tilts to, over 4 s, and then holds.
        var heroTilt: Float = 14
        /// **Entry progress** (0…1, not seconds) at which the desk card shrinks into the in-world mini card
        /// (工作包 C). It has to be late enough that the shell is already opaque — the shrink is a desk event and
        /// must not be seen through a half-open shell — and early enough that the card is parked before the
        /// world's own first beat: 数据星云 0.72 (shell is 1.0 by p 0.25), 霓虹雨城 0.80 (the portal fills at 0.78).
        var miniCardAt: Float = 0.72

        init() {}
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            trainPeriod = try c.decodeIfPresent(Float.self, forKey: .trainPeriod) ?? 16
            trainFirst = try c.decodeIfPresent(Float.self, forKey: .trainFirst) ?? 1.5
            cometPeriod = try c.decodeIfPresent(Float.self, forKey: .cometPeriod) ?? 18
            cometFirst = try c.decodeIfPresent(Float.self, forKey: .cometFirst) ?? 4
            heroAt = try c.decodeIfPresent(Float.self, forKey: .heroAt) ?? 3.5
            heroTilt = try c.decodeIfPresent(Float.self, forKey: .heroTilt) ?? 14
            miniCardAt = try c.decodeIfPresent(Float.self, forKey: .miniCardAt) ?? 0.72
        }
    }

    var id: String
    var name: String
    var subtitle: String
    var icon: String
    var palette: Palette
    var immersion: Immersion
    var entry: Transition
    var exit: Transition
    var audio: Audio
    var exitLabel: String
    var hologramTint: String
    var budget: Budget?
    // Phase B art (all optional): see WorldAssets.swift.
    var environment: WorldEnvironment?
    var placements: [WorldPlacement]?
    var scatters: [WorldScatter]?
    var fog: [WorldFogLayer]?
    /// Loose textures (jpg/png stems in `worlds/<id>/`) the world code uses; preloaded by `WorldAssetLibrary`.
    var textures: [String]?
    /// USDZ stems the world code clones itself (animated pieces); preloaded like placements.
    var extraAssets: [String]?
    var stats: Stats?
    var take: Take?

    /// Follower mapping with defaults.
    var statsRules: Stats { stats ?? Stats() }
    /// Shot timing with defaults.
    var takeTiming: Take { take ?? Take() }

    // MARK: Colours

    var primaryColor: UIColor { UIColor(hex: palette.primary) }
    var secondaryColor: UIColor { UIColor(hex: palette.secondary) }
    var highlightColor: UIColor { UIColor(hex: palette.highlight) }
    var accentColor: UIColor { UIColor(hex: palette.accent) }
    var backgroundColor: UIColor { UIColor(hex: palette.background) }
    var shellColor: UIColor { UIColor(hex: immersion.shellColor) }
    var hologramTintColor: UIColor { UIColor(hex: hologramTint) }

    // MARK: Loading

    /// All `worlds/*.json` in the bundle, in the design doc's order.
    static func loadAll() -> [WorldDescriptor] {
        let order = ["code-sea", "neon-city", "deep-sea", "paper-valley", "data-nebula"]
        var found: [String: WorldDescriptor] = [:]
        for id in order {
            guard let url = Bundle.main.url(forResource: id, withExtension: "json", subdirectory: "worlds")
                    ?? Bundle.main.url(forResource: id, withExtension: "json"),
                  let data = try? Data(contentsOf: url) else {
                print("[worlds] descriptor \(id).json missing")
                continue
            }
            do {
                found[id] = try JSONDecoder().decode(WorldDescriptor.self, from: data)
            } catch {
                print("[worlds] descriptor \(id).json invalid: \(error)")
            }
        }
        return order.compactMap { found[$0] }
    }
}

extension UIColor {
    /// `#RRGGBB` or `#RRGGBBAA`.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xFF) / 255; g = CGFloat((value >> 16) & 0xFF) / 255
            b = CGFloat((value >> 8) & 0xFF) / 255; a = CGFloat(value & 0xFF) / 255
        } else {
            r = CGFloat((value >> 16) & 0xFF) / 255; g = CGFloat((value >> 8) & 0xFF) / 255
            b = CGFloat(value & 0xFF) / 255; a = 1
        }
        self.init(red: r, green: g, blue: b, alpha: a)
    }

    /// Linear blend toward `other` in RGBA (`k` = 0 keeps self, 1 = `other`).
    func mixed(with other: UIColor, by k: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        let t = max(0, min(1, k))
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: a1 + (a2 - a1) * t)
    }
}
