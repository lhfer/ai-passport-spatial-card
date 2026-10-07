import Foundation
import simd

/// **Where the three button glints sit** (V3-2a2 S3 / plan §4 E6).
///
/// The passport has three keys on one long side. When a `button` line arrives over BLE the app flashes a
/// 6 mm dot *at that key* — so the light comes on under the wearer's thumb, on the real hardware, and not
/// somewhere on the virtual card. That is the whole point of the effect: the cause is visibly in the hand.
///
/// Which side the keys are on is not written down in anything the app can read, so it is a flag
/// (`--button-edge +x|-x`, calibrated once on the headset and persisted). The z offsets are the plan's:
/// OK in the middle, UP toward the device's top edge, DOWN toward the reader.
///
/// Pure value type so `ButtonGlintTests` can check both the edge flag and the H0 margin without a scene.
enum ButtonGlintLayout {
    /// The three keys, named as the firmware names them.
    enum Key: String, Equatable, CaseIterable {
        case up, ok, down

        /// Along S +Z, from the device's centre: UP toward the top edge, DOWN toward the reader.
        var z: Float {
            switch self {
            case .up: return -0.020
            case .ok: return 0
            case .down: return 0.020
            }
        }

        /// How the log names the offset.
        var label: String { rawValue }
    }

    /// Which long side the keys are on.
    enum Edge: String, Equatable, CaseIterable {
        case plusX = "+x"
        case minusX = "-x"

        var sign: Float { self == .plusX ? 1 : -1 }
        /// `UserDefaults` key the headset calibration is remembered under.
        static let defaultsKey = "spatialcard.buttonEdge"
    }

    /// **V3-4 §1** `--button-fx wave|dot|off`. `dot` is V3-2a2's glint alone (kept for the A/B — it is what
    /// the headset round ran), `wave` adds the edge wave, the spark cone and the card's answer, `off` is no
    /// button feedback at all.
    enum FX: String, Equatable, CaseIterable {
        case wave, dot, off
    }

    /// A glint is a 10 mm plane. **V3-4 §1**: 6 mm at the key was invisible under the thumb that pressed it;
    /// the dot is now the wave's visible starting point rather than the whole effect, so it is bigger and it
    /// stands further off the shell.
    static let size: Float = 0.010
    /// How far **outside** the audited footprint prism a glint's centre sits.
    ///
    /// The plan puts the dot on the key itself (x ±30 mm = the shell's own side face). H0's prism is the
    /// footprint **plus 3 mm**, so a dot at ±30 mm — and a dot at the brief's ±33 mm, which lands exactly on
    /// the prism's boundary — is inside it. 3 mm outside the prism is the nearest place to the real key that
    /// leaves H0 untouched by argument rather than by rounding; on the AI Passport that is x = ±36 mm, i.e.
    /// 6 mm off the shell. See the report: this is the one number a headset take should re-judge.
    /// Set it to **0** to put the dot back on the brief's +/-33 mm (the shell's face + 3 mm): the audit
    /// would stay clean either way — a glint is opacity 0 at rest and lit for < 1.5 s, both of which the
    /// auditor skips — so this is a design choice about how far off the real key the light may sit, not an
    /// H0 necessity. It is 3 mm here so that the claim "nothing persistent is inside the prism" needs no
    /// argument about boundaries.
    ///
    /// **V3-4 §1** raises it from 3 mm to 15 mm (x = ±48 mm on the AI Passport, i.e. 18 mm off the shell).
    /// The first headset round proved the 3 mm version invisible: visionOS draws the real hand over virtual
    /// content, the app may not set `upperLimbVisibility`, and a dot 6 mm off the shell is under the thumb.
    /// 15 mm puts the dot clear of a thumb on the key, where it can act as the edge wave's origin.
    static let clearance: Float = 0.015
    /// A glint floats just under the screen plane, level with the keys themselves.
    static let y: Float = -0.004

    /// Where the glint for `key` stands in the screen frame S.
    static func position(_ key: Key, edge: Edge, footprint: DeviceFootprint) -> SIMD3<Float> {
        [edge.sign * (footprint.half.x + clearance), y, key.z]
    }

    /// The one line the log prints when a key is pressed: `[fx] button glint down (+x, z +20 mm)`.
    static func logSuffix(_ key: Key, edge: Edge) -> String {
        String(format: "%@ (%@, z %+.0f mm)", key.label, edge.rawValue, key.z * 1000)
    }
}
