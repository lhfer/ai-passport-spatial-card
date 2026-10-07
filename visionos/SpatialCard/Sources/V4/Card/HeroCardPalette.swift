import SwiftUI
import UIKit

/// The night-gold palette (art bible §1), for the hero card. Hex strings are the bible's, verbatim, so a reviewer
/// can grep them.
enum HeroCardPalette {
    static let night = UIColor(hex: "#0B1230")
    static let deepNight = UIColor(hex: "#060A1C")
    static let indigo = UIColor(hex: "#1B2A6B")
    static let gold = UIColor(hex: "#FFD58A")
    static let goldHot = UIColor(hex: "#FFF3D6")
    static let oldGold = UIColor(hex: "#C9A45C")
    static let crystal = UIColor(hex: "#F4F7FF")
    static let xhsRed = UIColor(hex: "#FF2442")
    static let ink = UIColor(hex: "#1A2238")
    /// Holo foil gradient — a hue shift that flows with the view, never a base colour.
    static let foil: [UIColor] = [UIColor(hex: "#7FE7FF"), UIColor(hex: "#B18CFF"), UIColor(hex: "#FF9ED8"), UIColor(hex: "#FFE08A")]

    /// Deep gold for numerals on the pale frost (the approved direction: "around #A67C2E"), and the two ends of its
    /// foil-stamped gradient — a touch lighter at the top, a touch deeper at the foot, ≈ 3.5:1 on the frost.
    static let deepGold = UIColor(hex: "#A67C2E")
    static let deepGoldTop = UIColor(hex: "#B38837")
    static let deepGoldFoot = UIColor(hex: "#7C581C")

    enum SwiftUIColors {
        static let goldHot = Color(uiColor: HeroCardPalette.goldHot)
        static let gold = Color(uiColor: HeroCardPalette.gold)
        static let oldGold = Color(uiColor: HeroCardPalette.oldGold)
        static let night = Color(uiColor: HeroCardPalette.night)
        static let xhsRed = Color(uiColor: HeroCardPalette.xhsRed)
        static let ink = Color(uiColor: HeroCardPalette.ink)
        /// Secondary type (handle, labels): a **solid** slate, not ink at an opacity. Measured on the frost (stroke
        /// cores, night and lit alike): ink at 68–72 % composited to 2.3–2.6:1, #474D66 to 4.2–4.5:1 (thin strokes
        /// never reach their fill colour), this tone to ≥ 4.5:1.
        static let inkSecondary = Color(uiColor: UIColor(hex: "#3A4058"))
        static let deepGold = Color(uiColor: HeroCardPalette.deepGold)
        /// Foil-stamped deep gold for the numbers on the frost.
        static let metallic = LinearGradient(colors: [Color(uiColor: HeroCardPalette.deepGoldTop), deepGold,
                                                      Color(uiColor: HeroCardPalette.deepGoldFoot)],
                                             startPoint: .top, endPoint: .bottom)
    }
}
