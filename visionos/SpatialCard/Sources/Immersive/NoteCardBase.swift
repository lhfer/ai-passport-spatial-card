import SwiftUI

/// **v4 B5 §2 — the note card's ground: the system glass, or a cheap frost painted once.**
///
/// `glassBackgroundEffect` is a live background blur: every frame the system samples what is behind each card and blurs
/// it, ten cards on the desk, twelve in a fan-out, while they fly. Round 2's run 2 showed one background blur (the card's
/// own frost) halving the frame rate inside a world. The frost is what the glass *looks* like in the night scene —
/// a cool translucent slate, lighter at the top, a fine specular rim — drawn as a static gradient, so the attachment
/// is rasterised once and then only moved.
///
/// **No structural switch.** B4's `gallery-glass=off` swapped `glassBackgroundEffect` for a fill inside an `if` / `else`:
/// that gives the card's whole content a new identity, so SwiftUI rebuilt all ten cards (their `AsyncImage` covers
/// started loading again, the shimmer animated) in the very window that was meant to price the fill — round 3's 45.9 fps
/// (worst 66.7 ms) for "the glass off". Here the glass is always in the tree with a display mode, and only the frost
/// layer behind the content comes and goes.
///
/// **10-06: the frost is the default** (the user's decision on the B5 stills, `b5-glass-vs-frost-night.jpg`); the glass
/// stays one switch away (`--note-base glass`, `cmd perf gallery-glass=on`).
enum NoteCardBase: String, CaseIterable {
    /// The system glass (`--note-base glass`, `cmd perf gallery-glass=on`).
    case glass
    /// The static frost (`NoteCardFrost`) — the default since 10-06.
    case frost

    /// What the glass reads as over the night (`#0B1230`): sampled from the simulator's night dome, the glass cards at rest
    /// are a cool slate from (73, 73, 85) under the cover to (61, 62, 78) at the foot (sRGB). The frost reproduces that at
    /// `frostOpacity` over the same night — so the room still shows through it a little, as it does through the glass.
    /// (The headset's glass over a real dark room is the reference the user judges it against.)
    static let frostTop = Color(red: 0.354, green: 0.353, blue: 0.392)
    static let frostBottom = Color(red: 0.272, green: 0.280, blue: 0.337)
    /// One constant: 1.0 makes the ground opaque (no blending under the card at all), if the headset says the
    /// translucency itself is what costs.
    static let frostOpacity: Double = 0.86
}

/// The ground behind a card's content: the glass, or the frost.
struct NoteCardGround<S: InsettableShape>: ViewModifier {
    let base: NoteCardBase
    let shape: S

    func body(content: Content) -> some View {
        content
            .background {
                // Only this layer changes with the base: the content above it keeps its identity (and its covers).
                if base == .frost { NoteCardFrost(shape: shape) }
            }
            .glassBackgroundEffect(in: shape, displayMode: base == .glass ? .always : .never)
    }
}

/// The frost: a vertical gradient of the night slate the glass shows, and the glass's slightly brighter upper edge — all
/// static. The card's own rim (`NoteCardView`'s stroke) is drawn over either ground, so the frost adds none of its own.
struct NoteCardFrost<S: InsettableShape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(LinearGradient(colors: [NoteCardBase.frostTop, NoteCardBase.frostBottom], startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0)],
                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))))
            .opacity(NoteCardBase.frostOpacity)
    }
}
