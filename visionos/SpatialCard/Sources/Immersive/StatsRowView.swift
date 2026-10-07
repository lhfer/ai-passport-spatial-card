import SwiftUI

/// Follower count on the glass card (plan §9): monospaced digits that roll with `numericText`, a "粉丝" label,
/// and a "+N" badge that springs in during a celebration and eases out after it.
struct StatsRowView: View {
    let followers: Int
    /// Non-nil while the celebration badge is up.
    let delta: Int?
    let accent: Color
    /// Last delta shown, so the badge keeps its text while it eases out.
    @State private var shownDelta = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(followers.formatted())
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Color(white: 0.10))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(followers)))
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: followers)
                .lineLimit(1)
            Text("粉丝")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Color(white: 0.42))
        }
        .frame(height: 30)
        // The badge floats to the right of the row (never part of its layout) and is always in the hierarchy:
        // insertion / removal transitions are not reliable inside RealityView attachments, plain animated
        // opacity / scale / offset are.
        .overlay(alignment: .trailing) {
            DeltaBadge(delta: delta ?? shownDelta, accent: accent)
                .fixedSize()
                .alignmentGuide(.trailing) { d in d[.leading] - 8 }
                .opacity(delta == nil ? 0 : 1)
                .scaleEffect(delta == nil ? 0.6 : 1, anchor: .bottomLeading)
                .offset(y: delta == nil ? 8 : 0)
                .animation(delta == nil ? .easeIn(duration: 0.3) : .spring(response: 0.4, dampingFraction: 0.7), value: delta == nil)
        }
        .onChange(of: delta) { _, new in
            if let new { shownDelta = new }
        }
    }
}

/// "+N" capsule in the card's accent.
struct DeltaBadge: View {
    let delta: Int
    let accent: Color

    var body: some View {
        Text("+\(delta)")
            .font(.system(size: 14, weight: .bold, design: .rounded))
            .monospacedDigit()
            // Dark on the accent, not white: the accent is a near-white blue on a light card.
            .foregroundStyle(Color(white: 0.12))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule().fill(accent.opacity(0.85)))
            .overlay(Capsule().strokeBorder(.black.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 5, y: 1)
    }
}
