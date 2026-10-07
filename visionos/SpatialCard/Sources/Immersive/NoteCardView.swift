import SwiftUI

/// The recent-notes fan (工作包 D): ten cover cards on an arc behind the frosted card, and the one that is
/// enlarged when the wearer pinches it.
///
/// Both are RealityView attachments, so their sizes are physical: 1 m = 1360 pt. A card is 136 × 177 pt
/// (10 × 13 cm) and the preview is exactly 2.6 × that (354 × 460 pt = 26 × 33.8 cm), which is why the small
/// card can fly to the preview's place at scale 2.6 and cross-fade into it without changing size.
///
/// `glassBackgroundEffect` — not `glassEffect`: SwiftUI's Liquid Glass is `@available(visionOS, unavailable)`
/// on this SDK (see `HologramCardView.cardGlass`).

/// One cover card in the fan.
struct NoteCardView: View {
    static let size = CGSize(width: 136, height: 177)
    static let cornerRadius: CGFloat = 18
    /// How much bigger the preview is (`NotePreviewView.size / size`).
    static let previewScale: CGFloat = 2.6

    let note: RecentNote
    /// Resolved by `AppModel.coverURL(for:)` — the hub's proxy, or a bundled file in the `--fake-notes` set.
    let coverURL: URL?
    /// **v4 B2 §2.** The desk's button ring rests on this card: its rim turns warm gold and glows (art bible §2's gold
    /// edge; the lift and the ×1.06 are the controller's, on the same beat).
    var highlighted = false
    /// **v4 B5 §2** the card's ground (`NoteCardBase`): the static frost (the default since 10-06), or the system glass
    /// (`--note-base glass`, `cmd perf gallery-glass=on`) — so the headset can price the glass apart from the gallery.
    var base: NoteCardBase = .frost
    let onTap: () -> Void

    private let shape = RoundedRectangle(cornerRadius: NoteCardView.cornerRadius, style: .continuous)
    /// The card and its glint are one hover **group**: gaze lands on the card (which lifts), and the band —
    /// decorative and not hit-testable — follows it. visionOS renders hover out of process, so this is the only
    /// way to hang a second effect off the same gaze; the app is never told where the wearer is looking.
    @Namespace private var hoverSpace

    var body: some View {
        // v4 B5 §2 (`--perf-census`): how often the gallery's cards are re-evaluated inside a `[perf]` window.
        PerfCensus.noteCardBodies += 1
        let group = HoverEffectGroup(hoverSpace)
        return VStack(spacing: 0) {
            NoteCoverView(url: coverURL, isVideo: note.type == .video, cornerRadius: NoteCardView.cornerRadius - 4,
                          size: CGSize(width: NoteCardView.size.width - 12, height: 108))
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 5) {
                    NoteLikeBadge(text: note.likesLabel, size: 11)
                    if note.pinned { NotePinBadge(size: 10) }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            Spacer(minLength: 0)
        }
        .frame(width: NoteCardView.size.width, height: NoteCardView.size.height)
        .modifier(NoteCardGround(base: base, shape: shape))
        .overlay(shape.strokeBorder(highlighted ? HeroCardPalette.SwiftUIColors.gold : .white.opacity(0.28),
                                    lineWidth: highlighted ? 2.5 : 1))
        .shadow(color: HeroCardPalette.SwiftUIColors.gold.opacity(highlighted ? 0.75 : 0), radius: highlighted ? 9 : 0)
        .animation(.easeOut(duration: 0.25), value: highlighted)
        .overlay { glint(in: group) }
        .contentShape(shape)
        .hoverEffect(.lift, in: group)
        .onTapGesture(perform: onTap)
    }

    /// The glint: one leaning highlight band parked off the card's left edge, clipped to the card so nothing of
    /// it shows at rest. When the group activates it travels to just past the right edge over 0.5 s — the card
    /// catches the light once — and back again when the gaze leaves. No `@State`, no timer, nothing per frame.
    private func glint(in group: HoverEffectGroup) -> some View {
        LinearGradient(colors: [.clear, .white.opacity(0.10), .white.opacity(0.38), .white.opacity(0.10), .clear],
                       startPoint: .leading, endPoint: .trailing)
            .frame(width: NoteCardView.size.width * 0.44, height: NoteCardView.size.height * 1.7)
            .rotationEffect(.degrees(20))
            .offset(x: -NoteCardView.size.width)
            .hoverEffect(in: group.behavior(.followsGroup)) { effect, isActive, _ in
                effect.animation(.easeInOut(duration: 0.5)) {
                    $0.offset(x: isActive ? NoteCardView.size.width * 2 : 0)
                }
            }
            .frame(width: NoteCardView.size.width, height: NoteCardView.size.height)
            .clipShape(shape)
            .allowsHitTesting(false)
    }
}

/// The enlarged note: same card, three times the type, plus the one action it has.
struct NotePreviewView: View {
    static let size = CGSize(width: 354, height: 460)
    static let cornerRadius: CGFloat = 28
    /// The cover area. Tall enough that a 3-line title, the action row and (v4 B2) the key hint still fit inside
    /// 460 pt, and the cover itself is **fitted** into it (never cropped — the cover is what the wearer opened the
    /// note for), with the same image blurred behind it filling the letterbox.
    static let coverSize = CGSize(width: 354 - 28, height: 255)

    let note: RecentNote
    let coverURL: URL?
    /// 「在小红书打开」 — the hub's absolute link, `xsec_token` and all. nil = the note has no link.
    var onOpen: () -> Void = {}
    /// **v4 B2 §2.** The ways out a wearer can *see*: the × in the corner and a tap anywhere else on the panel (the
    /// 「在小红书打开」 button keeps its own tap). The argument says which, for the log.
    var onClose: (String) -> Void = { _ in }
    /// The panel left the space (Safari, or the preview ended): the device's bottom strip goes back to the
    /// follower count, a second time, because this is the one path the choreography does not see.
    var onDisappear: () -> Void = {}

    private let shape = RoundedRectangle(cornerRadius: NotePreviewView.cornerRadius, style: .continuous)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            NoteCoverView(url: coverURL, isVideo: note.type == .video, cornerRadius: NotePreviewView.cornerRadius - 8,
                          size: NotePreviewView.coverSize, contentMode: .fit)
            Text(note.title)
                .font(.system(size: 22, weight: .semibold))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
            Spacer(minLength: 4)
            HStack(spacing: 10) {
                NoteLikeBadge(text: note.likesLabel, size: 17)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.3), value: note.likes)
                if note.pinned { NotePinBadge(size: 14) }
                Spacer(minLength: 0)
                if note.link != nil {
                    Button(action: onOpen) {
                        Label("在小红书打开", systemImage: "arrow.up.forward.app")
                            .font(.system(size: 15, weight: .semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                    .glassBackgroundEffect(in: Capsule())
                    .hoverEffect()
                }
            }
            // v4 B2 §2: the way back, said on the panel itself — 「按 OK 返回 · ▲▼ 翻页」 in ink and gold.
            KeyHintLine(parts: [.text("按"), .key("OK"), .text("返回 ·"), .key("▲▼"), .text("翻页")], size: 13)
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
        }
        .padding(14)
        .frame(width: NotePreviewView.size.width, height: NotePreviewView.size.height)
        .glassBackgroundEffect(in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.3), lineWidth: 1))
        .overlay(alignment: .topTrailing) {
            PreviewCloseButton { onClose("× button") }
                .padding(10)
        }
        // A tap on the panel itself closes it too — the one tap B2 turns on (the device's base ring and socket stay
        // off: V3-5 found a hand closing round the passport reads as a pinch on them).
        .contentShape(shape)
        .onTapGesture { onClose("panel tap") }
        .onDisappear(perform: onDisappear)
    }
}

/// **v4 B2 §2.** The preview's close button: a crystal-white disc, an ink ×, a thin gold ring (art bible §1: ink for type
/// on light, gold as the accent). 44 pt across on a panel shown at 1360 pt/m — 3.2 cm, an easy pinch.
struct PreviewCloseButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(HeroCardPalette.SwiftUIColors.ink)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color(uiColor: HeroCardPalette.crystal).opacity(0.92)))
                .overlay(Circle().strokeBorder(HeroCardPalette.SwiftUIColors.gold, lineWidth: 1.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .hoverEffect()
        .accessibilityLabel("关闭")
    }
}

/// **v4 B2 §2.** One line of "press this key" hint: ink words on a light capsule, each key a small gold keycap with an
/// ink glyph — gold as the accent, never as the type (art bible §1 / §6: deep gold on the frost only reaches
/// 1.5–2.3:1, ink 6.3–9.6:1). Shared by the preview panel and the desk's first-gallery hint.
struct KeyHintLine: View {
    enum Part: Hashable {
        case text(String)
        case key(String)
    }

    let parts: [Part]
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 0.35) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case .text(let text):
                    Text(text)
                        .font(.system(size: size, weight: .medium))
                        .foregroundStyle(HeroCardPalette.SwiftUIColors.ink)
                case .key(let key):
                    Text(key)
                        .font(.system(size: size * 0.92, weight: .bold))
                        .foregroundStyle(HeroCardPalette.SwiftUIColors.ink)
                        .padding(.horizontal, size * 0.4)
                        .padding(.vertical, size * 0.12)
                        .background(RoundedRectangle(cornerRadius: size * 0.35, style: .continuous)
                            .fill(HeroCardPalette.SwiftUIColors.gold))
                }
            }
        }
        .padding(.horizontal, size * 0.9)
        .padding(.vertical, size * 0.45)
        .background(Capsule().fill(Color(uiColor: HeroCardPalette.crystal).opacity(0.9)))
        .overlay(Capsule().strokeBorder(HeroCardPalette.SwiftUIColors.oldGold.opacity(0.8), lineWidth: 1))
    }
}

/// **v4 B2 §2.** The first-gallery hint beside the device: 「▲▼ 选择 · OK 打开」. Gone at the first key press, not shown
/// again that session (`AppModel.noteButtonPressed`).
struct DeskRingHintView: View {
    var body: some View {
        KeyHintLine(parts: [.key("▲▼"), .text("选择 ·"), .key("OK"), .text("打开")], size: 15)
    }
}

/// **v4 B3 §2.** 「OK · 唤醒」 beside the keys, 1.5 s after one of the session's first three collapses; gone at the next
/// key. B2's first-gallery hint's place and style (ink type, a gold keycap, a crystal capsule).
struct WakeHintView: View {
    var body: some View {
        KeyHintLine(parts: [.key("OK"), .text("· 唤醒")], size: 15)
    }
}

/// **v4 B3 §1.** 「按 OK 回到桌面」 under the in-world mini card (B1 §6: the hero card had lost v3's 「返回桌面」 capsule).
/// It hangs in the card's own frame, which a world scales by 0.35, so the type is drawn at 28 pt to read like the desk
/// hints' 15 pt at the mini card's 0.6 m (≈ 8 cm across in the world: about the card's width).
struct MiniCardHintView: View {
    var body: some View {
        KeyHintLine(parts: [.text("按"), .key("OK"), .text("回到桌面")], size: 28)
    }
}

/// The desk's 「笔记」 chip: the same family as the world coins and the 退出 chip, and the only way to throw
/// the fan when no device is linked (its long OK is what normally does it).
struct NotesChipView: View {
    let count: Int
    let isOut: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: isOut ? "rectangle.stack.fill" : "rectangle.stack")
                .font(.system(size: 15, weight: .semibold))
            Text("笔记")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: 46, height: 46)
        .glassBackgroundEffect(in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(isOut ? 0.55 : 0.35), lineWidth: 1))
        .contentShape(Circle())
        .hoverEffect()
        .opacity(count > 0 ? 1 : 0.35)
        .onTapGesture { if count > 0 { onTap() } }
    }
}

// MARK: - Pieces

/// The cover, in its three states: a shimmer while it loads (which **stops** the moment it does), the image
/// filled and cropped, or a quiet icon when the hub could not get it (`coverURL == nil`, 404 or a 502 the
/// proxy has negative-cached).
///
/// The size is passed in rather than inherited from the layout: `scaledToFill` deliberately overflows, and
/// only a fixed frame with `clipped()` **on the image itself** keeps the overflow out of the title below it.
private struct NoteCoverView: View {
    let url: URL?
    var isVideo = false
    var cornerRadius: CGFloat
    let size: CGSize
    /// `.fill` crops to the frame (the small fan cards, where the picture is a thumbnail); `.fit` shows the
    /// whole cover and fills the letterbox with a blurred, darkened copy of it (the preview).
    var contentMode: ContentMode = .fill

    var body: some View {
        PerfCensus.coverBodies += 1
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return Group {
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.25))) { phase in
                    switch phase {
                    case .success(let image):
                        if contentMode == .fit {
                            ZStack {
                                // Backdrop: the same picture, overscanned so the blur has pixels to sample at
                                // the edges, then darkened so it never competes with the cover in front of it.
                                image.resizable()
                                    .scaledToFill()
                                    .frame(width: size.width, height: size.height)
                                    .scaleEffect(1.25)
                                    .blur(radius: 24)
                                    .overlay(Color.black.opacity(0.28))
                                image.resizable()
                                    .scaledToFit()
                                    .frame(width: size.width, height: size.height)
                            }
                            .frame(width: size.width, height: size.height)
                            .clipped()
                        } else {
                            image.resizable()
                                .scaledToFill()
                                .frame(width: size.width, height: size.height)
                                .clipped()
                                .onAppear { PerfCensus.coversShown += 1 }
                        }
                    case .failure:
                        NoteCoverFallback(symbol: "photo.badge.exclamationmark")
                    case .empty:
                        NoteCoverShimmer()
                    @unknown default:
                        NoteCoverShimmer()
                    }
                }
            } else {
                NoteCoverFallback(symbol: "photo")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(shape)
        .overlay(alignment: .bottomTrailing) {
            if isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: cornerRadius * 0.55, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(cornerRadius * 0.35)
                    .background(Circle().fill(.black.opacity(0.35)))
                    .padding(6)
            }
        }
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
    }
}

/// Loading placeholder: one highlight band sweeping across a dim plate. It only exists while the image is in
/// flight — ten of these running forever would be ten animations per frame for nothing.
private struct NoteCoverShimmer: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.10))
            .overlay {
                GeometryReader { geometry in
                    LinearGradient(colors: [.clear, .white.opacity(0.22), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: geometry.size.width * 0.6)
                        .offset(x: phase * geometry.size.width * 1.6)
                }
            }
            .onAppear {
                // v4 B5 §2: a cover (re)loading — the shimmer only exists while an `AsyncImage` is in `.empty`.
                PerfCensus.coverLoadsStarted += 1
                withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) { phase = 1 }
            }
    }
}

private struct NoteCoverFallback: View {
    let symbol: String

    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(.white.opacity(0.55))
            }
    }
}

/// ♥ + the firmware's own number style, so the card and the device's bottom strip read the same.
private struct NoteLikeBadge: View {
    let text: String
    let size: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.85))
                .foregroundStyle(.pink.opacity(0.9))
            Text(text)
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
        }
    }
}

private struct NotePinBadge: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "pin.fill")
                .font(.system(size: size * 0.85))
            Text("置顶")
                .font(.system(size: size, weight: .medium))
        }
        .foregroundStyle(.secondary)
    }
}
