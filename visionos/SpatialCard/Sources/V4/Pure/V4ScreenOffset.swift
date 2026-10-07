import Foundation
import simd

extension V4 {
    /// **Where the LCD is on the case** (v4 B1 §1) — the one number that splits v3's single frame into the case frame
    /// **C** and the screen frame **S**.
    ///
    /// v3 treated "the case's centre" and "the screen's centre" as one frame, so every effect that follows the case
    /// (the recognition wireframe, the key glints, the top-edge hinge, the H0 prism, the edge and socket rings) and
    /// every effect that follows the screen (the card, the ribbon, the well's mouth, the LCD sync) sat on the same
    /// origin. On the real AI Passport the lit area is not in the middle of the shell: measured by ruler on
    /// 2026-09-25 (`docs/v4/tracking-and-perf.md` §4) its centre is 1.64 mm to the left and 11.52 mm towards the
    /// lanyard end. That is the "手持时名片和 LCD 贴合不精确" the wearer kept seeing.
    ///
    /// The product keeps `anchorRoot` as **S** (the image tracker has always reported S; the object tracker gets there
    /// through `ObjectScreenFrame.userOffset`, post-multiplied) and hangs **C** off it at `caseCenter(offset:)`.
    ///
    /// **One source.** `resolve` is the whole rule: a value given on the command line (`--screen-offset <x> <z>`, mm,
    /// v3's flag, still persisted per device) wins, then the persisted one, then the ruler measurement.
    enum ScreenOffset {
        /// The case, by ruler: 60 × 96 × 8 mm (the trained model and the headset's anchor box say 60 × 95 × 8.5).
        static let caseSize: SIMD2<Float> = [0.060, 0.096]
        static let caseThickness: Float = 0.008
        /// The LCD's lit area (card.json `device.activeAreaMm`, nominal).
        static let lcdSize: SIMD2<Float> = [0.03672, 0.04896]
        /// By ruler: the lit area starts 10 mm from the case's left edge and 12 mm from its top (lanyard) edge.
        static let lcdLeftMargin: Float = 0.010
        static let lcdTopMargin: Float = 0.012

        /// The lit area's centre relative to the case's centre, in S (+X right, +Z towards the reader), metres:
        /// x = −30 + 10 + 18.36 = −1.64 mm, z = −48 + 12 + 24.48 = −11.52 mm.
        static let measured: SIMD2<Float> = fromEdges(caseSize: caseSize, lcdSize: lcdSize,
                                                      leftMargin: lcdLeftMargin, topMargin: lcdTopMargin)

        /// The offset from two edge margins taken with a ruler (the way the numbers above were taken).
        static func fromEdges(caseSize: SIMD2<Float>, lcdSize: SIMD2<Float>, leftMargin: Float, topMargin: Float) -> SIMD2<Float> {
            [-caseSize.x / 2 + leftMargin + lcdSize.x / 2, -caseSize.y / 2 + topMargin + lcdSize.y / 2]
        }

        enum Source: String, Equatable {
            /// `--screen-offset <x mm> <z mm>` on this launch (and persisted for the next).
            case flag = "--screen-offset"
            /// Persisted by an earlier `--screen-offset`.
            case stored
            /// The ruler measurement above.
            case measured = "measured"
        }

        /// The rule, in one place: flag > stored > measured. Inputs in metres.
        static func resolve(flag: SIMD2<Float>?, stored: SIMD2<Float>?) -> (offset: SIMD2<Float>, source: Source) {
            if let flag, flag.x.isFinite, flag.y.isFinite { return (flag, .flag) }
            if let stored, stored.x.isFinite, stored.y.isFinite { return (stored, .stored) }
            return (measured, .measured)
        }

        /// Where the case frame C's origin sits in S: the case's top-face centre, i.e. the offset turned round.
        static func caseCenter(offset: SIMD2<Float>) -> SIMD3<Float> { [-offset.x, 0, -offset.y] }

        /// The log line: `[obj] screen offset (x −1.6, z −11.5 mm, measured)`.
        static func describe(_ offset: SIMD2<Float>, source: Source) -> String {
            String(format: "[obj] screen offset (x %+.2f, z %+.2f mm, %@) — S = C + offset; case frame C at (%+.2f, %+.2f) mm in S",
                   offset.x * 1000, offset.y * 1000, source.rawValue, -offset.x * 1000, -offset.y * 1000)
        }
    }
}
