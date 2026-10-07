import Foundation

extension V4 {
    /// **v4 B2 §3.1 — the AR session's backlight** (`--ar-backlight 100|85|keep`, default 100).
    ///
    /// v4's first headset round lost the object anchor for tens of seconds at a time once the passport had been put
    /// down (`expanded → held(untracked)` 1.2 s after the put-down, then `Σ obj=0.0/s`), while the first 40 s in the hand
    /// held 30/s on the same model and the same 85 % backlight. The one A/B that was never run: v3's third round moved
    /// the AR backlight from 100 % (DC) to 85 % (a 5 kHz / 10-bit PWM, `CONFIG_CARD_AR_BACKLIGHT_PERCENT`) and tracking got
    /// five times worse in the same round. A PWM-lit LCD can beat against the headset cameras' exposure; 100 % is direct
    /// current and has nothing to beat. So the app asks for 100 % for the session (`docs/protocol.md` 「backlight」: in AR
    /// mode it sets the level for this AR session, a button press does not clear it, `set_mode` and BLE edges do).
    ///
    /// The trade-off, from the firmware's own rule (`CONFIG_CARD_BUTTON_BLINK`): the key blink goes *toward* 100 while
    /// the level is below it; at exactly 100 there is nowhere up to go, so it falls back to the old dip toward dark
    /// (55 % for 60 ms, half-way, back over 120 ms) — the direction v3.4 called "reads like a fault". `85` puts the
    /// firmware default back (bright blink, PWM), `keep` sends nothing at all.
    enum ARBacklight: Equatable {
        /// Send `backlight` with this percent after `set_mode ar` (every link-up).
        case percent(Int)
        /// Send nothing: the firmware's own AR level stands.
        case keep

        static let `default` = ARBacklight.percent(100)

        /// `--ar-backlight <v>`: `keep`, or a percent 1–100 (0 would blank the screen the object model was trained on —
        /// refused, as is anything that does not parse). Nil = the flag's value is not one of those.
        static func parse(_ text: String) -> ARBacklight? {
            let t = text.trimmingCharacters(in: .whitespaces).lowercased()
            if t == "keep" { return .keep }
            guard let p = Int(t.hasSuffix("%") ? String(t.dropLast()) : t), (1...100).contains(p) else { return nil }
            return .percent(p)
        }

        /// The percent to send, or nil for `keep`.
        var percent: Int? {
            if case .percent(let p) = self { return p }
            return nil
        }

        /// 100 = direct current, anything below it is a real PWM duty cycle (`docs/protocol.md` line 49).
        static func drive(_ percent: Int) -> String { percent >= 100 ? "DC" : "PWM" }

        /// `[ble] backlight 100 % (AR session, DC)` — the line the next headset round greps for.
        static func sentLine(_ percent: Int) -> String {
            "[ble] backlight \(percent) % (AR session, \(drive(percent)))"
        }

        /// What the key blink does at this level (the firmware's rule, restated so the log can say it once).
        static func blinkNote(_ percent: Int) -> String {
            percent >= 100 ? "key blink dips toward dark at 100 %" : "key blink brightens to 100 % and back"
        }

        /// The startup line for the flag.
        var flagLine: String {
            switch self {
            case .keep: return "[ble] --ar-backlight keep: the firmware's own AR level stands (85 % PWM by default)"
            case .percent(let p):
                return "[ble] --ar-backlight \(p): sent after set_mode ar on every link-up (\(ARBacklight.drive(p)); \(ARBacklight.blinkNote(p)))"
            }
        }
    }
}
