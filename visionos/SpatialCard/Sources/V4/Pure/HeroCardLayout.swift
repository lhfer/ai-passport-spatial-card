import Foundation
import simd

extension V4 {
    /// The two formats the brief asks to compare (`--card-shape square|portrait`).
    enum HeroCardShape: String, CaseIterable {
        /// v3's plate: 0.27 × 0.27 m.
        case square
        /// A collectible's 5 : 7: 0.20 × 0.28 m.
        case portrait
    }

    /// An axis-aligned rectangle in the card's own frame, metres.
    struct HeroCardRect: Equatable {
        var minX: Float
        var minY: Float
        var width: Float
        var height: Float

        var maxX: Float { minX + width }
        var maxY: Float { minY + height }
        var midX: Float { minX + width / 2 }
        var midY: Float { minY + height / 2 }
        var center: SIMD2<Float> { [midX, midY] }

        init(minX: Float, minY: Float, width: Float, height: Float) {
            self.minX = minX
            self.minY = minY
            self.width = width
            self.height = height
        }

        init(centerX: Float, top: Float, width: Float, height: Float) {
            self.init(minX: centerX - width / 2, minY: top - height, width: width, height: height)
        }

        func inset(by d: Float) -> HeroCardRect {
            HeroCardRect(minX: minX + d, minY: minY + d, width: width - 2 * d, height: height - 2 * d)
        }
    }

    /// Every dimension of the hero card, in metres, in the card's own frame: origin at the centre of the slab's
    /// **front face**, +X right, +Y up the card, +Z out of the face towards the reader.
    ///
    /// One value feeds both halves of the card — the RealityKit slab, gold line, panel and avatar layers, and the
    /// SwiftUI type (through `points(_:)`) — so the art window's gold frame drawn by SwiftUI and the painted sky
    /// mounted by RealityKit can never drift apart, and the gold dust knows which digit column it is popping over.
    ///
    /// The card is a 12 mm crystal slab whose face is a **pale, luminous frost** (the approved A1 direction,
    /// 2026-09-26): frost right up to the edge, a gold line 1.5 mm in, a warm edge light. Type is readable on it by
    /// typography alone — ink #1A2238 for the words, deep gold for the numerals — never by a dark backing plate
    /// (round 1–8 had a midnight panel; it read as dark smoked glass, which the direction rules out).
    struct HeroCardLayout: Equatable {
        let shape: HeroCardShape
        /// Outer size of the slab.
        let size: SIMD2<Float>
        let cornerRadius: Float
        /// The content box: where the art and the type sit, 7 mm in from the slab's edge.
        let panel: HeroCardRect
        let panelCornerRadius: Float
        /// The frosted face itself — the whole front, 0.6 mm in from the edge.
        var face: HeroCardRect {
            HeroCardRect(minX: -size.x / 2, minY: -size.y / 2, width: size.x, height: size.y).inset(by: Self.faceInset)
        }
        var faceCornerRadius: Float { max(0.002, cornerRadius - Self.faceInset) }
        /// The painted sky's window (back layer, 3 mm), with a gold hairline around it.
        let artWindow: HeroCardRect
        let artCornerRadius: Float
        /// The square the three 540 × 540 avatar layers are drawn on — they register pixel-for-pixel, so the figure's
        /// hair can stand out of the window's top edge (the pop-out) while the sky stays inside it.
        let avatarQuad: HeroCardRect
        /// The type column: left / right edges and the top of the name (metres, card frame). Below the name the column
        /// flows (SwiftUI stacks it with the two gaps, in points), because a type block's height is its font's line
        /// box, not a number to guess — round 2 guessed, and the count landed on the tags. The rig learns where the
        /// count actually is from SwiftUI (`HeroCardFaceModel.countFrame`).
        let textLeft: Float
        let textRight: Float
        let nameTop: Float
        /// Points between the handle line and the count, and between the count's labels and the tags.
        let statsGap: Float
        let tagsGap: Float
        /// Where the count's top is expected before SwiftUI has reported it (panel texture, first dust placement).
        var statsTopEstimate: Float { nameTop - 0.043 }
        /// Font sizes, in points (`pointsPerMeter` = 1360, visionOS's attachment scale).
        let nameSize: Float
        let detailSize: Float
        let followerSize: Float
        let likesSize: Float
        let labelSize: Float
        let tagSize: Float

        static let thickness: Float = 0.012
        /// Gold line: 1.5 mm in from the slab's edge (brief), 1 mm wide.
        static let goldInset: Float = 0.0015
        static let goldWidth: Float = 0.0010
        /// The content box's inset from the slab's edge (art window and type margins are measured from it).
        static let panelInset: Float = 0.0070
        /// The frost's inset: a hair inside the slab's outline, so the edge light and the rim sit on its border.
        static let faceInset: Float = 0.0006
        /// The three avatar layers' heights above the face (brief: 3 / 10 / 18 mm).
        static let layerHeights: [Float] = [0.003, 0.010, 0.018]
        /// Rise: the card's centre ends 0.22 m above the screen (v3 `cardCenterHeight`).
        static let riseHeight: Float = 0.22
        static let pointsPerMeter: Float = 1360
        /// The part of the 540 px avatar the window shows (fractions of the image, top-left origin): the full width,
        /// and from 10 % down to 96 % — above 10 % the hair pops out over the frame; the figure's fade (baked by
        /// `Tools/v4/v4-avatar-layers.swift`, 89.5 → 95.5 %) is over before the window ends, below the hands.
        static let windowV0: Float = 0.10
        static let windowV1: Float = 0.96

        init(shape: HeroCardShape) {
            self.shape = shape
            switch shape {
            case .portrait:
                size = [0.20, 0.28]
                cornerRadius = 0.018
                // 160 mm of type column = 218 pt: a 48 pt count (132 pt of reels) leaves room for 4.4万 beside it.
                nameSize = 25; detailSize = 13; followerSize = 48; likesSize = 22; labelSize = 12; tagSize = 11
                (panel, artWindow, avatarQuad) = Self.frame(size: size, quadWidth: 0.146, windowTopGap: 0.0150)
                textLeft = panel.minX + 0.0130
                textRight = panel.maxX - 0.0130
                nameTop = artWindow.minY - 0.0075
                statsGap = 3; tagsGap = 5
            case .square:
                size = [0.27, 0.27]
                cornerRadius = 0.030                      // v3's plate
                // Same stack as the portrait, 10 mm less tall: the art has to shrink (128 mm vs 146) to fit.
                nameSize = 26; detailSize = 13.5; followerSize = 52; likesSize = 24; labelSize = 12.5; tagSize = 12
                (panel, artWindow, avatarQuad) = Self.frame(size: size, quadWidth: 0.128, windowTopGap: 0.0135)
                textLeft = panel.minX + 0.0190
                textRight = panel.maxX - 0.0190
                nameTop = artWindow.minY - 0.0070
                statsGap = 3; tagsGap = 5
            }
            panelCornerRadius = max(0.004, cornerRadius - Self.panelInset)
            artCornerRadius = 0.007
        }

        /// Panel, art window and avatar quad for a card of `size`: the window is centred, `windowTopGap` below the
        /// panel's top edge (room for the hair that pops out above it), and shows `windowV0…windowV1` of the image.
        private static func frame(size: SIMD2<Float>, quadWidth: Float, windowTopGap: Float)
            -> (HeroCardRect, HeroCardRect, HeroCardRect) {
            let panel = HeroCardRect(minX: -size.x / 2, minY: -size.y / 2, width: size.x, height: size.y).inset(by: panelInset)
            let windowTop = panel.maxY - windowTopGap
            let window = HeroCardRect(centerX: 0, top: windowTop, width: quadWidth,
                                      height: quadWidth * (windowV1 - windowV0))
            let quad = HeroCardRect(centerX: 0, top: windowTop + quadWidth * windowV0, width: quadWidth, height: quadWidth)
            return (panel, window, quad)
        }

        /// Metres → SwiftUI points on the card's attachment.
        static func points(_ meters: Float) -> Double { Double(meters * pointsPerMeter) }

        /// The card's own frame → the SwiftUI view's (origin top-left, y down), points.
        func viewPoint(_ p: SIMD2<Float>) -> (x: Double, y: Double) {
            (Self.points(p.x + size.x / 2), Self.points(size.y / 2 - p.y))
        }

        /// The UV of a point of the card face in the avatar's image (u right, v down), so the window mesh can sample
        /// exactly the part of the sky that sits under it.
        func avatarUV(_ p: SIMD2<Float>) -> SIMD2<Float> {
            [(p.x - avatarQuad.minX) / avatarQuad.width, (avatarQuad.maxY - p.y) / avatarQuad.height]
        }

        /// Where the start of the entrance puts the card: flat on the screen at the size of the LCD's lit area, so it
        /// reads as the screen's own picture lifting off.
        func screenScale(screen: SIMD2<Float>) -> Float {
            min(screen.x / size.x, screen.y / size.y)
        }
    }

    /// Where the odometer's digit columns sit — fixed-width reels, so the gold dust can pop over the exact column.
    struct HeroCardDigitLayout: Equatable {
        /// Number of digit reels (the target's digit count, at least 1).
        let digitCount: Int
        /// Reel and comma widths as fractions of the font size (New York's lining figures are ≈ 0.6 em wide).
        static let reelEm: Float = 0.62
        static let commaEm: Float = 0.26

        init(target: Int) {
            digitCount = max(1, String(max(0, target)).count)
        }

        /// Is a thousands separator drawn right after reel `index` (0 = leftmost)?
        func commaAfter(_ index: Int) -> Bool {
            let fromRight = digitCount - 1 - index
            return fromRight > 0 && fromRight % 3 == 0
        }

        var commaCount: Int { (0..<digitCount).filter(commaAfter).count }

        /// Total width in ems.
        var widthEm: Float { Float(digitCount) * Self.reelEm + Float(commaCount) * Self.commaEm }

        /// Centre of reel `index` (0 = leftmost), ems from the number's left edge.
        func centerEm(ofReel index: Int) -> Float {
            let commasBefore = (0..<index).filter(commaAfter).count
            return Float(index) * Self.reelEm + Float(commasBefore) * Self.commaEm + Self.reelEm / 2
        }

        /// Reel index of a decimal column (0 = ones).
        func reel(ofColumn column: Int) -> Int { digitCount - 1 - column }
    }
}
