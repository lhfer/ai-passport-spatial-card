import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

/// **V3-3 C3 / plan §4 E14c.** QR codes for the card's back, generated once and kept.
///
/// `CIQRCodeGenerator` renders at one module per pixel — a 33 × 33 image for a URL this length — so the
/// output is scaled up with **nearest-neighbour** sampling (`CIAffineTransform` on a
/// `.nearest`-sampled image would still resample; `UIGraphicsImageRenderer` with interpolation off is the
/// one that keeps the modules square). A blurred QR is a QR that a phone camera has to work at, and the
/// whole point of this face is that someone else's phone reads it off the wearer's screen recording.
///
/// Cached by string: the profile URL never changes inside a session, and rebuilding a CIContext per frame
/// (or per attachment rebuild — the RealityView re-evaluates this view on every observable change) would
/// cost milliseconds on the main actor for a picture that is always the same.
enum QRCodeImage {
    private static var cache: [String: UIImage] = [:]
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// `points` is the edge length the image is rasterised at, in points.
    @MainActor
    static func make(_ string: String, points: CGFloat = 320) -> UIImage? {
        let key = "\(string)#\(Int(points))"
        if let hit = cache[key] { return hit }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // `H` (30 % recovery): the code is being read off a photograph of a hologram, at an angle, so the
        // extra redundancy is worth the denser modules.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: CGSize(width: points, height: points), format: format).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            ctx.cgContext.translateBy(x: 0, y: points)
            ctx.cgContext.scaleBy(x: 1, y: -1)
            ctx.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: points, height: points))
        }
        cache[key] = image
        return image
    }
}

/// **V3-3 C3 / plan §4 E14c — the card's back.**
///
/// Turning the passport right over used to show the back of a card that has no back: the slab's rear face
/// and, through it, type running the wrong way. It has one now, and what is on it is the one thing a card's
/// back is *for* — the code the person you are showing it to points their phone at.
///
/// Deliberately almost empty: a QR of the profile link, the name, and four characters saying what to do
/// with it. At 13.5 cm in the hand the code is ≈ 7 cm across, which is comfortably above the 2 cm a phone
/// needs at arm's length.
struct HologramCardBackView: View {
    let card: CardData
    /// The same near-white the front's bottom-edge wash uses, so the two faces belong to one object.
    let accent: Color
    /// **v4 B1**: the plate it is the back of — v3's 0.27 m square by default, A4's 0.20 × 0.28 m hero card in v4.
    var size: SIMD2<Float> = [HologramLayout.cardWidth, HologramLayout.cardHeight]
    var cornerRadius: Float = HologramLayout.cardCornerRadius

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: HologramLayout.points(cornerRadius), style: .continuous)
    }

    /// The profile link from `card.json` (`links[0]`), falling back to the Xiaohongshu user id and finally
    /// to the handle — the code is never blank, because a blank code reads as a bug rather than as "no link".
    private var payload: String {
        if let url = card.primaryLink?.url, !url.isEmpty { return url }
        if let id = card.xhsUserID, !id.isEmpty { return "https://www.xiaohongshu.com/user/profile/\(id)" }
        return card.handle
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Group {
                if let image = QRCodeImage.make(payload) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.none)
                        .scaledToFit()
                } else {
                    // A device with no CoreImage QR generator is not a thing, but a blank white square with
                    // the line under it still says "this is the back of the card" rather than "this broke".
                    RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.92))
                }
            }
            .frame(width: 190, height: 190)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.black.opacity(0.10), lineWidth: 1))
            Spacer().frame(height: 18)
            Text("\(card.name) · 扫码关注")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color(white: 0.14))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        // Exactly the front's plate, so the two faces are the same object seen from two sides.
        .frame(width: HologramLayout.points(size.x), height: HologramLayout.points(size.y))
        .background {
            shape.fill(.white.opacity(0.62))
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [accent.opacity(0.16), accent.opacity(0)],
                                   startPoint: .bottom, endPoint: .top)
                        .frame(height: 40)
                }
                .clipShape(shape)
        }
        .overlay(shape.strokeBorder(.white.opacity(0.55), lineWidth: 1))
        .environment(\.colorScheme, .light)
        // The back is a picture, not a control: every pinch belongs to the front's plate.
        .allowsHitTesting(false)
    }
}
