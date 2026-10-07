import Observation
import SwiftUI
import UIKit

/// What the card says — the user's real data (`card.json` through `CardData`), plus the one demo override the brief
/// asks for (followers 4,401 in the lab; the seed in `card.json` is 4,313).
struct HeroCardContent: Equatable {
    var name: String
    var handle: String
    var location: String
    var tags: [String]
    var tagSymbols: [String]
    var followers: Int
    var likes: Int

    init(card: CardData, followers: Int? = nil) {
        name = card.name
        handle = card.handle
        location = card.location
        tags = Array(card.tags.prefix(3))
        tagSymbols = tags.indices.map(CardData.symbol(forTagAt:))
        self.followers = followers ?? card.stats.followers
        likes = card.stats.likes
    }
}

/// Which odometer draws the follower count (`--odometer wheel|numeric`): the brief asks for both and keeps the better.
enum HeroCardOdometerStyle: String {
    /// Custom mechanical reels (`HeroCardOdometer`): value-driven, smooth carries, motion blur by reel speed, dim
    /// leading zeros that light up as the count grows into them.
    case wheel
    /// SwiftUI's `.contentTransition(.numericText(value:))`, fed the count at 20 Hz.
    case numeric
}

/// The one piece of card state SwiftUI observes. Only the odometer's body reads `countTime` / `numericValue`, so
/// the per-frame writes during the 1.2 s count re-render the reels and nothing else.
@MainActor
@Observable
final class HeroCardFaceModel {
    let layout: V4.HeroCardLayout
    let content: HeroCardContent
    /// v4 B1: replaced (and re-rendered) when the live follower count changes — `HeroCardRig.setFollowers`.
    var odometer: V4.HeroCardOdometer
    var style: HeroCardOdometerStyle
    /// Seconds into the count (negative: not started — the reels read 0).
    var countTime: Double = -1
    /// `.numeric`: the value shown, stepped by the rig.
    var numericValue: Int = 0
    /// The gold glint crossing the landed count, 0…1 while it plays, negative otherwise.
    var glint: Double = -1
    /// Where SwiftUI actually laid the count out, in the card view's points (origin top-left) — the rig moves the gold
    /// dust and the sparkle onto it. Written by the view, read by the rig; no view reads it, so it never re-renders.
    @ObservationIgnored var countFrame: CGRect?
    /// Height of the whole type column, points — logged, and checked against the panel.
    @ObservationIgnored var columnHeight: CGFloat = 0

    init(layout: V4.HeroCardLayout, content: HeroCardContent, style: HeroCardOdometerStyle) {
        self.layout = layout
        self.content = content
        self.style = style
        odometer = V4.HeroCardOdometer(target: content.followers)
    }
}

/// Type faces (art bible §6). PingFang SC is asked for by name; where the runtime has no public PingFang (the
/// visionOS 27 simulator ships only the private `.PingFangUI` system face), the system font is used, whose CJK glyphs
/// *are* PingFang — the Latin ones are then SF instead of PingFang's own. Logged once so the report can say which.
enum HeroCardFonts {
    static let pingFangAvailable: Bool = {
        let ok = UIFont(name: "PingFangSC-Semibold", size: 12) != nil
        print("[card] PingFang SC by name: \(ok ? "available" : "not in this runtime — system font (PingFang UI for CJK)")")
        return ok
    }()

    static func sans(_ size: Float, _ weight: Font.Weight) -> Font {
        let s = CGFloat(size)
        guard pingFangAvailable else { return .system(size: s, weight: weight) }
        switch weight {
        case .semibold, .bold, .heavy, .black: return .custom("PingFangSC-Semibold", size: s)
        case .medium: return .custom("PingFangSC-Medium", size: s)
        default: return .custom("PingFangSC-Regular", size: s)
        }
    }

    /// New York — the numbers.
    static func serif(_ size: Float, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: CGFloat(size), weight: weight, design: .serif)
    }
}

/// **The card's type layer**: one SwiftUI view the size of the card (1360 pt/m), mounted in code with
/// `ViewAttachmentComponent(rootView:)` 0.9 mm in front of the frost. It draws only type on a clear background — the
/// frost, the art, the frame and the foil are RealityKit's — and it is placed from the same `HeroCardLayout` the
/// RealityKit half is built from, so the gold dust knows which digit it pops over.
///
/// Contrast comes from typography, not from a backing plate (the approved direction): **ink #1A2238 for everything
/// that has to be read, numerals included** — on the frost it measures ≥ 4.5:1 in both rooms, where deep gold #A67C2E
/// measures 1.5–2.3:1 (A1 §6.3) — the bible's "浅色卡面用墨色字". Gold rides on the accents: a 0.5 pt old-gold crisp
/// shadow under the numerals (decoration, not contrast), a gold underline under the count, the glint that crosses it
/// as it lands, the gold dust and the sparkle, the frame and the gold line. The frost is unlit, so the same colours
/// hold in the dark dome and in a lit room.
struct HeroCardFaceView: View {
    let model: HeroCardFaceModel

    private var layout: V4.HeroCardLayout { model.layout }
    private var content: HeroCardContent { model.content }
    private static let text = HeroCardPalette.SwiftUIColors.ink

    static let space = "heroCard"

    var body: some View {
        ZStack(alignment: .topLeading) {
            // (The art window's gold frame is RealityKit geometry — `HeroCardRig.frame` — not drawn here: a SwiftUI
            // attachment is composited after the card's sorted see-through layers, so a frame drawn on this sheet
            // showed through the popped-out hair, 9 mm in front of it.)
            VStack(alignment: .leading, spacing: 0) {
                nameBlock
                statsBlock
                    .padding(.top, CGFloat(layout.statsGap))
                tagsRow
                    .padding(.top, CGFloat(layout.tagsGap))
            }
            .frame(width: pts(layout.textRight - layout.textLeft), alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.columnHeight = $0 }
            .offset(x: x(layout.textLeft), y: y(layout.nameTop))
        }
        .frame(width: pts(layout.size.x), height: pts(layout.size.y), alignment: .topLeading)
        .coordinateSpace(.named(Self.space))
        .environment(\.colorScheme, .light)
        .allowsHitTesting(false)
    }

    // MARK: - Pieces

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(content.name)
                .font(HeroCardFonts.sans(layout.nameSize, .semibold))
                .foregroundStyle(Self.text)
                .lineLimit(1)
            Text("\(content.handle)  ·  \(content.location)")
                .font(HeroCardFonts.sans(layout.detailSize, .medium))
                .foregroundStyle(HeroCardPalette.SwiftUIColors.inkSecondary)
                .lineLimit(1)
        }
        .fixedSize()
    }

    /// The count and the likes, their labels on one baseline. Nothing here may wrap: a wrapped label makes its column
    /// taller and drags the count down onto the tags (it did, in the first round).
    private var statsBlock: some View {
        HStack(alignment: .lastTextBaseline, spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                HeroCardOdometerView(model: model)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { model.countFrame = $0 }
                // The gold under the ink count: a hairline that fades out to the right.
                Capsule()
                    .fill(LinearGradient(colors: [HeroCardPalette.SwiftUIColors.deepGold,
                                                  HeroCardPalette.SwiftUIColors.oldGold.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: countWidth * 0.92, height: 1.3)
                    .padding(.leading, 2)
                    .padding(.bottom, 2)
                Text("粉丝")
                    .font(HeroCardFonts.sans(layout.labelSize, .medium))
                    .foregroundStyle(HeroCardPalette.SwiftUIColors.inkSecondary)
                    .padding(.leading, 2)
            }
            .fixedSize()
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                Text(V4.HeroCardNumbers.compact(content.likes))
                    .font(HeroCardFonts.serif(layout.likesSize))
                    .monospacedDigit()
                    .foregroundStyle(Self.text)
                    .modifier(CrispShadow())
                HStack(spacing: 3) {
                    Image(systemName: "heart.fill")
                        .font(.system(size: CGFloat(layout.labelSize) * 0.8, weight: .semibold))
                        .foregroundStyle(HeroCardPalette.SwiftUIColors.xhsRed)
                    Text("获赞与收藏")
                        .font(HeroCardFonts.sans(layout.labelSize, .medium))
                        .foregroundStyle(HeroCardPalette.SwiftUIColors.inkSecondary)
                }
            }
            .lineLimit(1)
            .fixedSize()
        }
    }

    /// Three gold-rimmed capsules; if the three do not fit the column with their icons, they drop the icons.
    private var tagsRow: some View {
        ViewThatFits(in: .horizontal) {
            tags(icons: true)
            tags(icons: false)
        }
    }

    private func tags(icons: Bool) -> some View {
        HStack(spacing: 5) {
            ForEach(Array(content.tags.enumerated()), id: \.offset) { index, tag in
                HStack(spacing: 3) {
                    if icons {
                        Image(systemName: content.tagSymbols[index])
                            .font(.system(size: CGFloat(layout.tagSize) * 0.82, weight: .semibold))
                            .foregroundStyle(HeroCardPalette.SwiftUIColors.deepGold)
                    }
                    Text(tag)
                        .font(HeroCardFonts.sans(layout.tagSize, .medium))
                        .foregroundStyle(Self.text)
                }
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                // A lighter pill on the frost, rimmed in deep gold.
                .background(Capsule().fill(.white.opacity(0.42)))
                .overlay(Capsule().strokeBorder(HeroCardPalette.SwiftUIColors.deepGold.opacity(0.75), lineWidth: 1))
            }
        }
        .fixedSize()
    }

    /// Width of the count's reels, points.
    private var countWidth: CGFloat {
        CGFloat(V4.HeroCardDigitLayout(target: model.odometer.target).widthEm * layout.followerSize)
    }

    // MARK: - Card frame → view points

    private func pts(_ meters: Float) -> CGFloat { CGFloat(V4.HeroCardLayout.points(meters)) }
    private func x(_ cardX: Float) -> CGFloat { pts(cardX + layout.size.x / 2) }
    private func y(_ cardY: Float) -> CGFloat { pts(layout.size.y / 2 - cardY) }
}

/// The one shadow the numerals get: a crisp old-gold offset half a point down-right — a foil-stamp register, pure
/// decoration (the ink carries the contrast on its own).
struct CrispShadow: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: HeroCardPalette.SwiftUIColors.oldGold.opacity(0.75), radius: 0, x: 0.5, y: 0.6)
    }
}

/// The follower count, in whichever style the model asks for.
struct HeroCardOdometerView: View {
    let model: HeroCardFaceModel

    var body: some View {
        switch model.style {
        case .wheel: HeroCardReels(model: model)
        case .numeric: HeroCardNumericCount(model: model)
        }
    }
}

/// SwiftUI's own rolling digits, for the A/B (`--odometer numeric`).
struct HeroCardNumericCount: View {
    let model: HeroCardFaceModel

    var body: some View {
        let size = CGFloat(model.layout.followerSize)
        Text(V4.HeroCardNumbers.grouped(model.numericValue))
            .font(HeroCardFonts.serif(model.layout.followerSize))
            .monospacedDigit()
            .foregroundStyle(HeroCardPalette.SwiftUIColors.ink)
            .modifier(CrispShadow())
            .contentTransition(.numericText(value: Double(model.numericValue)))
            .animation(.snappy(duration: 0.14), value: model.numericValue)
            .frame(height: size * HeroCardReels.rowEm, alignment: .center)
            .fixedSize()
    }
}

/// The custom odometer: fixed-width reels (so the gold dust can find each column) of New York digits in ink.
/// Each reel shows its digit and the next one sliding up from below as it rolls; a fast reel is smeared by its spin
/// rate; a leading zero is a dim ghost until the count grows into it. As the count lands, a gold glint crosses it:
/// the same reels drawn in bright gold, seen only through a moving diagonal band.
struct HeroCardReels: View {
    let model: HeroCardFaceModel
    /// Reel height, ems: tall enough that the 0.7 em lining figures are never touched by the 10 % edge fades at rest.
    static let rowEm: CGFloat = 0.94
    /// The glint's gold: white-gold in the core, warm gold at the flanks.
    static let glintGold = LinearGradient(colors: [Color(uiColor: HeroCardPalette.goldHot), Color(uiColor: HeroCardPalette.gold),
                                                   Color(uiColor: UIColor(hex: "#E0A93A"))],
                                          startPoint: .top, endPoint: .bottom)

    var body: some View {
        let glint = model.glint
        row(gold: false)
            .overlay {
                if glint >= 0, glint <= 1 {
                    row(gold: true).mask(band(glint))
                }
            }
    }

    private func row(gold: Bool) -> some View {
        let t = model.countTime
        let odometer = model.odometer
        let digits = V4.HeroCardDigitLayout(target: odometer.target)
        let size = CGFloat(model.layout.followerSize)
        return HStack(spacing: 0) {
            ForEach(0..<digits.digitCount, id: \.self) { index in
                let column = digits.digitCount - 1 - index
                let lit = odometer.lit(column: column, at: t)
                Reel(position: t < 0 ? odometer.startPosition(column: column) : odometer.reelPosition(column: column, at: t),
                     speed: t < 0 ? 0 : odometer.speed(column: column, at: t),
                     lit: lit, size: size, gold: gold)
                    .frame(width: size * CGFloat(V4.HeroCardDigitLayout.reelEm), height: size * Self.rowEm)
                if digits.commaAfter(index) {
                    Group {
                        if gold {
                            Text(",").foregroundStyle(Self.glintGold)
                        } else {
                            Text(",").foregroundStyle(HeroCardPalette.SwiftUIColors.ink).modifier(CrispShadow())
                        }
                    }
                    .font(HeroCardFonts.serif(model.layout.followerSize))
                    .opacity(0.10 + 0.90 * lit)
                    .frame(width: size * CGFloat(V4.HeroCardDigitLayout.commaEm), height: size * Self.rowEm)
                }
            }
        }
    }

    /// A soft diagonal band travelling left to right across the count as `progress` goes 0 → 1.
    private func band(_ progress: Double) -> some View {
        let centre = -0.25 + 1.5 * progress
        let half = 0.16
        func stop(_ x: Double, _ a: Double) -> Gradient.Stop {
            .init(color: .white.opacity(a), location: CGFloat(min(1, max(0, x))))
        }
        return LinearGradient(stops: [stop(centre - half, 0), stop(centre, 1), stop(centre + half, 0)],
                              startPoint: UnitPoint(x: 0, y: 0.2), endPoint: UnitPoint(x: 1, y: 0.8))
    }

    private struct Reel: View {
        let position: Double
        let speed: Double
        let lit: Double
        let size: CGFloat
        let gold: Bool

        var body: some View {
            let whole = floor(position)
            let digit = ((Int(whole) % 10) + 10) % 10
            let roll = CGFloat(position - whole)
            let row = size * HeroCardReels.rowEm
            // Motion blur along the drum: from 10 digits/s the reel is drawn as a vertical smear — copies spread over
            // up to ±0.45 of a row, each fainter — plus a light isotropic soften. (Round 4 used a plain 3.5 pt blur:
            // clipped to the reel it read as a censor block, not a spinning wheel.)
            let spin = CGFloat(min(1, max(0, (speed - 10) / 120)))
            let copies = spin > 0.02 ? 5 : 1
            ZStack {
                ForEach(0..<copies, id: \.self) { i in
                    let spread = copies == 1 ? 0 : (CGFloat(i) / CGFloat(copies - 1) - 0.5) * 0.9 * spin * row
                    ZStack {
                        glyph(digit).offset(y: -roll * row + spread)
                        glyph((digit + 1) % 10).offset(y: (1 - roll) * row + spread)
                        glyph((digit + 9) % 10).offset(y: (-1 - roll) * row + spread)
                    }
                    .opacity(copies == 1 ? 1 : 1.7 / Double(copies))
                }
            }
            .blur(radius: 0.8 * spin)
            .frame(width: nil, height: row)
            .clipped()
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.10),
                                         .init(color: .white, location: 0.90), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }

        @ViewBuilder
        private func glyph(_ d: Int) -> some View {
            if gold {
                // The glint's copy: only lit digits catch it.
                Text(String(d))
                    .foregroundStyle(HeroCardReels.glintGold)
                    .opacity(lit)
                    .font(.system(size: size, weight: .semibold, design: .serif))
                    .monospacedDigit()
                    .frame(height: size * HeroCardReels.rowEm)
            } else {
                inkGlyph(d)
            }
        }

        private func inkGlyph(_ d: Int) -> some View {
            ZStack {
                // Ghost of a leading zero: ink, faint — at 0.28 (round 5) the count read "0,000" before it had
                // started; this faint, the eye reads "0" and the wheels are still there to be discovered.
                Text(String(d))
                    .foregroundStyle(HeroCardPalette.SwiftUIColors.ink.opacity(0.10))
                    .opacity(1 - lit)
                Text(String(d))
                    .foregroundStyle(HeroCardPalette.SwiftUIColors.ink)
                    .modifier(CrispShadow())
                    .opacity(lit)
            }
            .font(.system(size: size, weight: .semibold, design: .serif))
            .monospacedDigit()
            .frame(height: size * HeroCardReels.rowEm)
        }
    }
}
