import SwiftUI

/// Circular avatar from the bundled `Avatar` image set: a white stroke and a soft drop shadow, so it sits
/// *on* the frosted plate rather than being printed into it.
struct AvatarView: View {
    let diameter: CGFloat

    var body: some View {
        Image("Avatar")
            .resizable()
            .scaledToFill()
            .frame(width: diameter, height: diameter)
            .clipShape(Circle())
            .overlay(Circle().strokeBorder(.white, lineWidth: 3))
            .shadow(color: .black.opacity(0.18), radius: diameter * 0.09, y: 2)
    }
}

/// One tag with its SF Symbol: a faint grey capsule cut into the glass, not a coloured chip.
struct TagPill: View {
    let text: String
    let symbol: String

    var body: some View {
        // Never wrap: one line, natural width; the row below scales the whole set down if needed.
        Label(text, systemImage: symbol)
            .font(.system(size: 14, weight: .medium))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(Color(white: 0.22))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            // A touch heavier than a hairline: the capsules have to hold against the white plate *and* against
            // the beam's glow spilling up from the bottom edge.
            .background(Capsule().fill(.black.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.black.opacity(0.14), lineWidth: 1))
    }
}

// `HologramCardMode` and `HologramCardLayer` live in `Model/CardLayers.swift` (V3-3 C2): the three sheets'
// contract — one mode, three ids, three depths — is a pure value the test target checks.

/// What the hand card is showing right now (v3 H2 §8) — the pager's page, resolved into the strings and the
/// colour the view needs, so the view stays free of `WorldEngine` and `RecentNote`.
struct HandPageContent: Equatable {
    enum Kind: Equatable {
        case profile
        /// A world coin's page: its name, its one-line subtitle and its colour on the rim.
        case world(name: String, subtitle: String, tint: Color)
        /// A recent note: its cover, its title and its likes.
        case note(title: String, likes: Int, cover: URL?)
    }

    var kind: Kind = .profile
    /// Position in the ring, for the dots along the bottom edge.
    var index = 0
    var count = 1
    /// V3-2a H3: false while the hand **deck** is on — the card is then the profile, full stop, and the
    /// pages live on the seven cards fanned out behind it.
    var paged = true
}

/// The frosted card face that sits on the slab. Tap anywhere to open the profile link in Safari — or, once the
/// card has shrunk into a world (`mode == .mini`), to leave the world.
///
/// It is deliberately **light**: milky white with dark grey type, forced to `.light` so the system's dark
/// materials cannot turn it into a black pane. The colour of the active world only ever reaches it as a soft
/// 40 pt wash along the bottom edge — the same light the beam brings into the slab from below.
///
/// **Both layouts are always mounted** and cross-faded by opacity: a `transition` inside a RealityView
/// attachment is unreliable (the attachment is re-hosted, and a view that leaves the hierarchy takes its
/// texture with it), so the mini card would flicker instead of dissolve. The mini layout is typeset at 1/0.35
/// of the full one, because the entity it rides on is scaled to `HologramLayout.miniCardScale`.
struct HologramCardView: View {
    let card: CardData
    let stats: CardStats
    /// Celebration badge ("+N") while non-nil.
    var delta: Int? = nil
    /// The one accent colour on the card: the desk look's near-white blue, warmed by the active world.
    let accent: Color
    /// `--card-glass`: which glass treatment sits behind the frosting.
    var glass: CardGlass = .plate
    /// Desk card, in-world mini card or hand card.
    var mode: HologramCardMode = .full
    /// v3 H2 §8: which page the hand card is showing. Ignored outside `.hand`.
    var page: HandPageContent = HandPageContent()
    /// **V3-3 C2**: which of the three parallax sheets this copy is. `.base` is the whole card as it was
    /// before V3-3 minus the hero image and the chips; the other two are those two things alone, on a clear
    /// sheet of exactly the same size.
    var layer: HologramCardLayer = .base
    /// `--parallax off`: the three sheets are mounted at the same depth, so a partition would let the
    /// plate's own background occlude whichever coplanar sheet the renderer happens to draw first. Off, the
    /// base sheet therefore draws the **whole** card and the other two draw nothing — which is V3-2b's
    /// single attachment, pixel for pixel, with the tree left the same shape.
    var parallax = true
    /// `--mini-hint`: pin the "返回桌面" hint on, for screenshots and for judging its legibility without gaze.
    var forcesMiniHint = false
    let onTap: () -> Void

    private let shape = RoundedRectangle(cornerRadius: HologramLayout.points(HologramLayout.cardCornerRadius), style: .continuous)

    /// Full layout out over 0–0.2 s; mini layout in over 0.3–0.55 s (and the reverse on the way back, where the
    /// full layout's rows also re-stagger 60 ms apart — see `rowDelay`).
    private var isMini: Bool { mode == .mini }
    private var isHand: Bool { mode == .hand }

    var body: some View {
        ZStack {
            fullLayout
                .opacity(mode == .full ? 1 : 0)
                .animation(.easeInOut(duration: mode == .full ? 0.25 : 0.2).delay(mode == .full ? 0.3 : 0), value: mode)
            miniLayout
                .opacity(isMini ? 1 : 0)
                .animation(.easeInOut(duration: isMini ? 0.25 : 0.2).delay(isMini ? 0.3 : 0), value: mode)
            handLayout
                .opacity(isHand ? 1 : 0)
                .animation(.easeInOut(duration: isHand ? 0.25 : 0.2).delay(isHand ? 0.3 : 0), value: mode)
        }
        .frame(width: HologramLayout.points(HologramLayout.cardWidth), height: HologramLayout.points(HologramLayout.cardHeight))
        // Frosting first, glass behind it: the white is what makes the plate milky instead of a clear window,
        // and the world's light washes up from the bottom edge under it.
        // **V3-3 C2**: the plate belongs to `.base`. The two floating sheets are clear glass — anything opaque
        // on them would hide the layer below instead of parallaxing over it.
        .background {
            if layer == .base {
                shape.fill(.white.opacity(0.52))
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [accent.opacity(0.18), accent.opacity(0)],
                                       startPoint: .bottom, endPoint: .top)
                            .frame(height: 40)
                    }
                    .clipShape(shape)
            }
        }
        .cardGlass(layer == .base ? glass : .plain, in: shape)
        // A 1 pt hairline, not a gradient stroke: the bright edge is the RealityKit rim's job, not the view's.
        .overlay(shape.strokeBorder(.white.opacity(layer == .base ? 0.55 : 0), lineWidth: 1))
        .environment(\.colorScheme, .light)
        .contentShape(shape)
        .hoverEffect()
        // One hover group for the whole card, so looking anywhere on it (not only at the capsule itself)
        // is what brings the "返回桌面" hint up.
        .hoverEffectGroup()
        .onTapGesture(perform: onTap)
        // Only the plate is tappable: the two sheets in front of it would otherwise catch every pinch meant
        // for the card (and the hover highlight with it).
        .allowsHitTesting(layer == .base)
    }

    /// `1` when this element belongs to the sheet being drawn, `0` otherwise. Opacity rather than `if`, so
    /// all three sheets lay out identically down to the pixel — an element that is merely invisible still
    /// takes up its space, which is the whole reason the three line up when they are 8 mm apart.
    private func on(_ which: HologramCardLayer) -> Double {
        guard parallax else { return layer == .base ? 1 : 0 }
        return layer == which ? 1 : 0
    }

    // MARK: - Layouts

    /// The desk card. Spacing hierarchy: avatar → 14 → name → 4 → handle → 12 → location → 10 → followers → 12 → tags.
    /// Coming back from a world each row fades in 60 ms after the one above it (motion principle 3), which is the
    /// "content re-stagger" of the return.
    private var fullLayout: some View {
        VStack(spacing: 0) {
            AvatarView(diameter: 104)
                .opacity(on(.avatar))
                .modifier(RowStagger(index: 0, mode: mode))
            Spacer().frame(height: 14)
            Text(card.name)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color(white: 0.10))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(on(.base))
                .modifier(RowStagger(index: 1, mode: mode))
            Spacer().frame(height: 4)
            Text(card.handle)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(white: 0.38))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .opacity(on(.base))
                .modifier(RowStagger(index: 2, mode: mode))
            Spacer().frame(height: 12)
            Label(card.location, systemImage: "mappin.and.ellipse")
                .font(.system(size: 15))
                .foregroundStyle(Color(white: 0.38))
                .lineLimit(1)
                .opacity(on(.base))
                .modifier(RowStagger(index: 3, mode: mode))
            Spacer().frame(height: 10)
            StatsRowView(followers: stats.followers, delta: delta, accent: accent)
                .opacity(on(.base))
                .modifier(RowStagger(index: 4, mode: mode))
            Spacer().frame(height: 12)
            // Tags: one row, never wrapping; the row scales down uniformly if the texts are long.
            HStack(spacing: 8) {
                ForEach(Array(card.tags.prefix(3).enumerated()), id: \.offset) { index, tag in
                    TagPill(text: tag, symbol: CardData.symbol(forTagAt: index))
                }
            }
            .fixedSize()
            .frame(maxWidth: HologramLayout.points(HologramLayout.cardWidth) - 40)
            .scaleEffect(chipScale, anchor: .center)
            .frame(height: 34)
            .opacity(on(.tags))
            .modifier(RowStagger(index: 5, mode: mode))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
    }

    /// The in-world mini card: avatar, name, follower count — nothing that cannot be read at 9.5 cm wide, 0.6 m
    /// away. Every size is the desk value ÷ 0.35, because the entity is scaled to 0.35: 130 pt of avatar here is
    /// 3.3 cm of avatar in the world.
    private var miniLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AvatarView(diameter: 130)
                .opacity(on(.avatar))
            Spacer().frame(height: 16)
            Text(card.name)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(Color(white: 0.10))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(on(.base))
            Spacer().frame(height: 8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stats.followers.formatted())
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(stats.followers)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: stats.followers)
                    .foregroundStyle(Color(white: 0.10))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("粉丝")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(Color(white: 0.38))
            }
            .opacity(on(.base))
            Spacer(minLength: 0)
            returnHint
                .opacity(on(.base))
        }
        // The whole mini layout has to fit the same 367 pt plate as the desk one: at 1/0.35 type sizes that
        // leaves no room for generous padding, and an overflowing VStack would push the hint off the glass.
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - Hand layout (v3 H2)

    /// The card while the passport is in the wearer's hand: half the size, 35 mm off the screen, and 40 cm
    /// from their eyes instead of 60. Everything that needs a second look on a desk card comes off — the
    /// location line, the celebration badge, the third tag — because the reason to look at this one is
    /// "the card is on the device", not "read my details".
    ///
    /// **V3-2a H3**: with the hand *deck* on (`--deck` ≠ off) the card is the profile and nothing else —
    /// UP / DOWN raise a real card out of the fan behind it instead of swapping this one's contents, so the
    /// world / note pages and the ring dots have nothing left to say. `--deck off` (and `--hand-form hover`)
    /// keep V3-1's pager, which is what `page.paged` reports.
    private var handLayout: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            if page.paged {
                switch page.kind {
                case .profile: handProfile
                case .world(let name, let subtitle, let tint): handWorld(name: name, subtitle: subtitle, tint: tint)
                case .note(let title, let likes, let cover): handNote(title: title, likes: likes, cover: cover)
                }
            } else {
                handProfile
            }
            Spacer(minLength: 0)
            if page.paged { pageDots.opacity(on(.base)) }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var handProfile: some View {
        VStack(spacing: 0) {
            AvatarView(diameter: 96)
                .opacity(on(.avatar))
            Spacer().frame(height: 12)
            Text(card.name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color(white: 0.10))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(on(.base))
            Spacer().frame(height: 6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(stats.followers.formatted())
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(stats.followers)))
                    .animation(.spring(response: 0.45, dampingFraction: 0.75), value: stats.followers)
                    .foregroundStyle(Color(white: 0.10))
                Text("粉丝")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(white: 0.38))
            }
            .opacity(on(.base))
            // **V3-2b B5 / plan §4 E13.** New followers while the passport is in the wearer's hand: the
            // half-size card gets the same 「+N」 capsule the desk card has. It is the one place the hand
            // layout says a number *changed* — the rolling follower count above it only says what it is now.
            if let delta {
                Spacer().frame(height: 8)
                DeltaBadge(delta: delta, accent: accent)
                    .transition(.scale.combined(with: .opacity))
                    .opacity(on(.base))
            }
            Spacer().frame(height: 12)
            // Two tags, not three: the third one is what makes the row wrap at this width.
            HStack(spacing: 6) {
                ForEach(Array(card.tags.prefix(2).enumerated()), id: \.offset) { index, tag in
                    TagPill(text: tag, symbol: CardData.symbol(forTagAt: index))
                }
            }
            .fixedSize()
            .scaleEffect(0.82, anchor: .center)
            .opacity(on(.tags))
        }
    }

    /// A world's page: its colour, its name, and what OK will do — the coin arc's information without the arc.
    private func handWorld(name: String, subtitle: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(tint.opacity(0.85))
                .frame(width: 54, height: 54)
                .overlay(Circle().strokeBorder(.white.opacity(0.8), lineWidth: 2))
                .shadow(color: tint.opacity(0.35), radius: 10)
                .opacity(on(.avatar))
            Spacer().frame(height: 14)
            Text(name)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(Color(white: 0.10))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .opacity(on(.base))
            Spacer().frame(height: 6)
            Text(subtitle)
                .font(.system(size: 16))
                .foregroundStyle(Color(white: 0.40))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .opacity(on(.base))
            Spacer().frame(height: 14)
            Label("按 OK 进入", systemImage: "arrow.right.circle")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(white: 0.22))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(.black.opacity(0.08)))
                .overlay(Capsule().strokeBorder(.black.opacity(0.14), lineWidth: 1))
                .opacity(on(.tags))
        }
    }

    /// A recent note: the cover the gallery would have shown, its title, and its likes — the three things the
    /// device's own bottom strip echoes when OK opens it.
    private func handNote(title: String, likes: Int, cover: URL?) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.88))
                .frame(width: 104, height: 130)
                .overlay {
                    if let cover {
                        AsyncImage(url: cover) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "photo")
                                .font(.system(size: 26))
                                .foregroundStyle(Color(white: 0.55))
                        }
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 26))
                            .foregroundStyle(Color(white: 0.55))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.7), lineWidth: 1))
                .opacity(on(.avatar))
            Spacer().frame(height: 10)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color(white: 0.12))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .opacity(on(.base))
            Spacer().frame(height: 6)
            Label(likes.formatted(), systemImage: "heart.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(red: 0.85, green: 0.24, blue: 0.35))
                .opacity(on(.tags))
        }
    }

    /// Where in the ring the wearer is. Small and low: a page indicator that competes with the content is a
    /// page indicator nobody needed.
    @ViewBuilder
    private var pageDots: some View {
        if page.count > 1 {
            HStack(spacing: 6) {
                ForEach(0..<page.count, id: \.self) { index in
                    Circle()
                        .fill(Color(white: index == page.index ? 0.25 : 0.25).opacity(index == page.index ? 0.85 : 0.22))
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.top, 8)
            .animation(.easeOut(duration: 0.2), value: page.index)
        }
    }

    /// "返回桌面": invisible until the wearer looks at the card, then 0.18 s in. The closure form of
    /// `hoverEffect` is the only one that can drive opacity from the hover state without a state round-trip
    /// through the app (which would re-render the whole attachment on every glance).
    private var returnHint: some View {
        Label("返回桌面", systemImage: "arrow.uturn.backward")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(Color(white: 0.22))
            .lineLimit(1)
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(Capsule().fill(.black.opacity(0.08)))
            .overlay(Capsule().strokeBorder(.black.opacity(0.16), lineWidth: 2))
            // The capsule is authored *visible*; the effect is what hides it when nothing is looking. (The other
            // way round — base opacity 0, effect 1 — would depend on whether a hover effect's opacity replaces
            // the view's own alpha or multiplies with it, and multiplying would mean the hint never appears.)
            // `--mini-hint` goes through the same closure rather than through `isEnabled:`, which leaves the
            // effect's resting state (opacity 0) applied and was why the pinned hint stayed invisible.
            .hoverEffect { effect, isActive, _ in
                effect.animation(.easeInOut(duration: 0.18)) {
                    $0.opacity(isActive || forcesMiniHint ? 1 : 0)
                }
            }
    }

    /// Rough width estimate of the tag row (CJK ≈ 14 pt, Latin ≈ 8 pt per character, icon + padding ≈ 44 pt);
    /// scales the row down when it would exceed the card's inner width.
    private var chipScale: CGFloat {
        let available = HologramLayout.points(HologramLayout.cardWidth) - 40
        var width: CGFloat = 0
        for tag in card.tags.prefix(3) {
            let text = tag.reduce(CGFloat(0)) { $0 + (($1.isASCII) ? 8 : 14) }
            width += text + 44
        }
        width += CGFloat(max(0, min(3, card.tags.count) - 1)) * 8
        return width > available ? max(0.78, available / width) : 1
    }
}

/// Staggered re-entry of the desk card's rows when the card comes back from a world: avatar → name → handle →
/// location → followers → tags, 60 ms apart (motion principle 3 — nothing ever "appears together"). Going the
/// other way (into the world) the whole layout leaves at once, under the 0.2 s fade the ZStack already applies.
private struct RowStagger: ViewModifier {
    let index: Int
    let mode: HologramCardMode

    func body(content: Content) -> some View {
        content
            .opacity(mode == .mini ? 0 : 1)
            .offset(y: mode == .mini ? 6 : 0)
            .animation(mode == .mini
                       ? .easeInCubic(duration: 0.18)
                       : .easeOutCubic(duration: 0.3).delay(0.3 + Double(index) * 0.06),
                       value: mode)
    }
}

private extension Animation {
    static func easeInCubic(duration: Double) -> Animation { .timingCurve(0.55, 0.055, 0.675, 0.19, duration: duration) }
    static func easeOutCubic(duration: Double) -> Animation { .timingCurve(0.215, 0.61, 0.355, 1, duration: duration) }
}

private extension View {
    /// `--card-glass`: `.plate` is the thick-plate treatment the reference image asks for; `.feathered` softens
    /// the border into the room; `plain` leaves only the white frosting. (`glassEffect` / `GlassEffectContainer`
    /// are `@available(visionOS, unavailable)`, so these are the whole menu.)
    @ViewBuilder
    func cardGlass(_ kind: CardGlass, in shape: some InsettableShape) -> some View {
        switch kind {
        case .plate: glassBackgroundEffect(.plate, in: shape)
        case .feathered: glassBackgroundEffect(.feathered(padding: 18, softEdgeRadius: 18), in: shape)
        case .plain: self
        }
    }
}
