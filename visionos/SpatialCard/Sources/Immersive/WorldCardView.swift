import SwiftUI

/// A world at the end of the hand deck (V3-2a H3 / plan §4 E4).
///
/// On the desk a world is a glass coin on the arc. In the hand there is no arc, so the two worlds take the
/// two outer slots of the deck as **cards** — the same 136 × 177 pt glass body as a note cover, so the fan
/// reads as one hand and not as a coin someone glued to it. It is deliberately *not* a coin: `coinHolders`
/// hang off `surface.coinGroup` and `setCoinHighlight` tweens every coin back to `coinBasePositions`, so a
/// coin borrowed by the deck would be yanked back to the desk the moment OK highlighted a world.
///
/// Raised (UP / DOWN put it over the name card) it gains the 「按 OK 进入」 capsule and a brighter border —
/// plain opacity and colour on a permanently mounted view, because a `transition` inside a RealityView
/// attachment is not reliable.
struct WorldCardView: View {
    static let size = NoteCardView.size
    static let cornerRadius = NoteCardView.cornerRadius

    let descriptor: WorldDescriptor
    var raised = false
    /// **v4 B5 §2.** The same ground as the note cards it stands with in the deck (`NoteCardBase`).
    var base: NoteCardBase = .frost

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WorldCardView.cornerRadius, style: .continuous)
    }

    private var tint: Color { Color(uiColor: descriptor.primaryColor) }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                shape.inset(by: 6)
                    .fill(tint.opacity(0.35))
                Image(systemName: descriptor.icon)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 4, y: 1)
            }
            .frame(height: 104)
            VStack(alignment: .leading, spacing: 3) {
                Text(descriptor.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(descriptor.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(white: 0.35))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 9)
            .padding(.top, 5)
            Spacer(minLength: 0)
            Text("按 OK 进入")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(0.85)))
                .padding(.bottom, 8)
                .opacity(raised ? 1 : 0)
                .animation(.easeOut(duration: 0.22), value: raised)
        }
        .frame(width: WorldCardView.size.width, height: WorldCardView.size.height)
        .modifier(NoteCardGround(base: base, shape: shape))
        .overlay(shape.strokeBorder(.white.opacity(raised ? 0.9 : 0.28), lineWidth: raised ? 1.5 : 1)
            .animation(.easeOut(duration: 0.22), value: raised))
        .allowsHitTesting(false)
    }
}
