import Foundation
import RealityKit

/// Short synthesized sound cues for the choreography (design doc §4.3: "声音是运动的一半").
/// Everything is generated procedurally into 16-bit WAV files in Caches on first use, so the app
/// ships no audio assets; swap in CC0 samples later by dropping files with the same names.
@MainActor
final class FXAudio {
    enum Cue: String, CaseIterable {
        case powerOn      // registration layer lights up
        case scan         // scan line sweep (0.6 s)
        case liftOff      // wireframe pries off the paper
        case chip0, chip1, chip2
        case settle       // card lands: soft chord
        case orbTap
        case collapse     // card sucked back into the paper
        case acquire      // first detection glint
        case celebrate    // new followers: two rising glints + soft major chord tail
        case tick         // coin highlight moved (device UP / DOWN)
        case chime        // data nebula: a star per new follower
        case charge       // data nebula: the card charges before the star burst (rising hum, 0.7 s)
        case carry        // card picked up: short soft whoosh down
        // Worlds
        case modem        // code sea entry: dial-up chatter
        case reflow       // code sea exit: reverse sweep + ticks
        case tear         // neon city entry: cloth tear + bass drop
        case crtOff       // neon city exit: CRT power-down slide
        case waterRise    // deep sea entry: rising water swell + bubbles
        case surface      // deep sea exit: breaking the surface
        case paperFlip    // paper valley entry/exit: paper flips
        case pop          // paper pop-up
        case powerDown    // data nebula entry: mains cut + failing transformer
        case dawn         // data nebula exit: rising pad
        case starBurst    // 4313 stars burst
        case whoosh       // generic transition whoosh
        case worldCodeAmbient, worldRainAmbient, worldSeaAmbient, worldPaperAmbient, worldSpaceAmbient   // 4 s loops

        var isLoop: Bool { rawValue.hasPrefix("world") }
    }

    static let shared = FXAudio()

    private var resources: [Cue: AudioFileResource] = [:]
    private let sampleRate = 44_100

    private init() {}

    /// Load lazily; a failed synthesis just mutes that cue.
    func play(_ cue: Cue, on entity: Entity) {
        if resources[cue] == nil {
            resources[cue] = load(cue)
        }
        guard let resource = resources[cue] else { return }
        entity.playAudio(resource)
    }

    func preload() {
        for cue in Cue.allCases where resources[cue] == nil && !cue.isLoop {
            resources[cue] = load(cue)
        }
    }

    /// Ambient loop; returns the controller so the caller can fade/stop it.
    @discardableResult
    func playLoop(_ cue: Cue, on entity: Entity, fadeIn: Double) -> AudioPlaybackController? {
        if resources[cue] == nil { resources[cue] = load(cue) }
        guard let resource = resources[cue] else { return nil }
        let controller = entity.playAudio(resource)
        controller.gain = -40
        controller.fade(to: -12, duration: fadeIn)
        return controller
    }

    // MARK: - Synthesis

    private func load(_ cue: Cue) -> AudioFileResource? {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("fx-\(cue.rawValue)-v1.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            let samples = synthesize(cue)
            do { try FXAudio.writeWAV(samples, sampleRate: sampleRate, to: url) } catch {
                print("[audio] could not write \(cue): \(error)")
                return nil
            }
        }
        do {
            return try AudioFileResource.load(contentsOf: url, withName: cue.rawValue,
                                              configuration: .init(shouldLoop: cue.isLoop, normalization: nil))
        } catch {
            print("[audio] could not load \(cue): \(error)")
            return nil
        }
    }

    private func synthesize(_ cue: Cue) -> [Float] {
        let sr = Float(sampleRate)
        func env(_ t: Float, attack: Float, hold: Float, release: Float) -> Float {
            if t < attack { return t / attack }
            if t < attack + hold { return 1 }
            let r = (t - attack - hold) / release
            return r >= 1 ? 0 : (1 - r) * (1 - r)
        }
        func render(duration: Float, _ f: (Float) -> Float) -> [Float] {
            let n = Int(duration * sr)
            var out = [Float](repeating: 0, count: n)
            var seed: UInt32 = 0x9E3779B9
            for i in 0..<n {
                let t = Float(i) / sr
                _ = seed
                out[i] = max(-1, min(1, f(t)))
                seed = seed &* 1664525 &+ 1013904223
            }
            return out
        }
        var noiseSeed: UInt32 = 12345
        func noise() -> Float {
            noiseSeed = noiseSeed &* 1664525 &+ 1013904223
            return Float(noiseSeed >> 8) / Float(1 << 24) * 2 - 1
        }
        let twoPi = 2 * Float.pi

        switch cue {
        case .powerOn:
            return render(duration: 0.45) { t in
                let e = env(t, attack: 0.08, hold: 0.1, release: 0.27)
                let hum = sin(twoPi * 90 * t) * 0.5 + sin(twoPi * 180 * t) * 0.25 + sin(twoPi * 270 * t) * 0.1
                return (hum + noise() * 0.04) * e * 0.55
            }
        case .scan:
            var lp: Float = 0
            return render(duration: 0.62) { t in
                let e = env(t, attack: 0.04, hold: 0.5, release: 0.08)
                let pitch = 600 + 900 * (t / 0.62)
                lp += (noise() - lp) * 0.18
                return (sin(twoPi * pitch * t) * 0.18 + lp * 0.5) * e * 0.4
            }
        case .liftOff:
            return render(duration: 0.5) { t in
                let click = t < 0.006 ? noise() * 0.9 : 0
                let e = env(t, attack: 0.02, hold: 0.12, release: 0.36)
                let f = 120 + 120 * min(1, t / 0.25)
                let swell = sin(twoPi * f * t) * 0.5 + sin(twoPi * f * 2 * t) * 0.25 + sin(twoPi * f * 3 * t) * 0.12
                return click + swell * e * 0.6
            }
        case .chip0, .chip1, .chip2:
            let base: Float = cue == .chip0 ? 880 : (cue == .chip1 ? 1108.7 : 1318.5)
            return render(duration: 0.3) { t in
                let e = env(t, attack: 0.003, hold: 0.02, release: 0.27)
                return (sin(twoPi * base * t) * 0.6 + sin(twoPi * base * 2.01 * t) * 0.25) * e * 0.5
            }
        case .settle:
            let chord: [Float] = [261.63, 329.63, 392.0, 493.88]
            return render(duration: 1.0) { t in
                let e = env(t, attack: 0.12, hold: 0.25, release: 0.6)
                var s: Float = 0
                for (i, f) in chord.enumerated() { s += sin(twoPi * f * t) * (0.25 - Float(i) * 0.03) }
                return s * e * 0.45
            }
        case .orbTap:
            return render(duration: 0.16) { t in
                let e = env(t, attack: 0.002, hold: 0.02, release: 0.13)
                return sin(twoPi * 1200 * t) * e * 0.4
            }
        case .collapse:
            return render(duration: 0.42) { t in
                let e = env(t, attack: 0.01, hold: 0.05, release: 0.36)
                let f = 800 - 650 * min(1, t / 0.35)
                return (sin(twoPi * f * t) * 0.4 + noise() * 0.08) * e * 0.5
            }
        case .acquire:
            return render(duration: 0.22) { t in
                let e = env(t, attack: 0.002, hold: 0.03, release: 0.18)
                let f = 2000 + 1000 * min(1, t / 0.1)
                return (sin(twoPi * f * t) * 0.5 + sin(twoPi * f * 1.5 * t) * 0.2) * e * 0.35
            }
        case .celebrate:
            // Two rising glints (1320 → 1980 Hz) and a soft major chord tail (0.9 s).
            let chord: [Float] = [523.25, 659.25, 783.99, 1046.5]
            return render(duration: 1.25) { t in
                let g1 = t < 0.22 ? sin(twoPi * 1320 * t) * env(t, attack: 0.004, hold: 0.04, release: 0.16) : 0
                let t2 = t - 0.12
                let g2 = t2 >= 0 && t2 < 0.26 ? sin(twoPi * 1980 * t2) * env(t2, attack: 0.004, hold: 0.05, release: 0.2) : 0
                let ct = t - 0.25
                var tail: Float = 0
                if ct > 0 {
                    for (i, f) in chord.enumerated() { tail += sin(twoPi * f * ct) * (0.2 - Float(i) * 0.035) }
                    tail *= env(ct, attack: 0.06, hold: 0.3, release: 0.62)
                }
                return (g1 * 0.45 + g2 * 0.42 + tail * 0.5) * 0.7
            }
        case .tick:
            return render(duration: 0.09) { t in
                let e = env(t, attack: 0.001, hold: 0.012, release: 0.075)
                return (sin(twoPi * 1600 * t) * 0.5 + sin(twoPi * 2400 * t) * 0.15) * e * 0.4
            }
        case .chime:
            // Bell-like: fundamental + inharmonic partials, long decay.
            return render(duration: 0.9) { t in
                let e = env(t, attack: 0.002, hold: 0.02, release: 0.86)
                let s = sin(twoPi * 1760 * t) * 0.5 + sin(twoPi * 1760 * 2.76 * t) * 0.18 * max(0, 1 - t / 0.4) + sin(twoPi * 1760 * 5.4 * t) * 0.08 * max(0, 1 - t / 0.2)
                return s * e * 0.45
            }
        case .charge:
            // Rising hum with a soft shimmer on top: 180 → 720 Hz over 0.7 s, swelling then handing off to the burst.
            return render(duration: 0.75) { t in
                let e = env(t, attack: 0.25, hold: 0.35, release: 0.15)
                let f = 180 + 540 * pow(min(1, t / 0.6), 1.6)
                let hum = sin(twoPi * f * t) * 0.45 + sin(twoPi * f * 2 * t) * 0.18
                let shimmer = sin(twoPi * (2400 + 600 * sin(t * 31)) * t) * 0.06 * min(1, t / 0.3)
                return (hum + shimmer + noise() * 0.02) * e * 0.5
            }
        case .carry:
            var lp: Float = 0
            return render(duration: 0.28) { t in
                let e = env(t, attack: 0.01, hold: 0.06, release: 0.2)
                lp += (noise() - lp) * (0.5 - 0.3 * t / 0.28)
                let f = 520 - 300 * min(1, t / 0.25)
                return (lp * 0.35 + sin(twoPi * f * t) * 0.25) * e * 0.45
            }
        case .modem:
            return render(duration: 0.7) { t in
                let e = env(t, attack: 0.01, hold: 0.55, release: 0.14)
                let step = Int(t * 28) % 7
                let f: Float = [1200, 2400, 1800, 980, 2100, 1500, 2600][step]
                return (sin(twoPi * f * t) * 0.35 + noise() * 0.06) * e * 0.5
            }
        case .reflow:
            var lp: Float = 0
            return render(duration: 1.0) { t in
                let e = env(t, attack: 0.02, hold: 0.7, release: 0.28)
                let pitch = 1600 - 1200 * (t / 1.0)
                lp += (noise() - lp) * 0.2
                let tick: Float = (t * 18).truncatingRemainder(dividingBy: 1) < 0.08 ? 0.35 : 0
                return (sin(twoPi * pitch * t) * 0.2 + lp * 0.4 + tick * sin(twoPi * 3000 * t)) * e * 0.45
            }
        case .tear:
            var lp: Float = 0
            return render(duration: 1.4) { t in
                let e = env(t, attack: 0.03, hold: 0.9, release: 0.47)
                lp += (noise() - lp) * (0.35 + 0.4 * t)
                let bass = t > 0.9 ? sin(twoPi * (70 - 30 * min(1, (t - 0.9) / 0.5)) * t) * 0.6 * min(1, (t - 0.9) / 0.15) : 0
                return (lp * 0.7 + bass) * e * 0.6
            }
        case .crtOff:
            return render(duration: 0.9) { t in
                let e = env(t, attack: 0.005, hold: 0.1, release: 0.78)
                let f = 800 * pow(0.075, min(1, t / 0.7))    // 800 → 60 Hz slide
                return (sin(twoPi * f * t) * 0.6 + noise() * 0.05 * (1 - t)) * e * 0.55
            }
        case .waterRise:
            var lp: Float = 0
            return render(duration: 1.6) { t in
                let e = env(t, attack: 0.3, hold: 0.9, release: 0.4)
                lp += (noise() - lp) * 0.08
                let bubble = sin(twoPi * (300 + 200 * sin(t * 9)) * t) * 0.12 * (0.5 + 0.5 * sin(t * 23))
                return (lp * 0.9 + bubble) * e * 0.55
            }
        case .surface:
            var lp: Float = 0
            return render(duration: 0.8) { t in
                let e = env(t, attack: 0.005, hold: 0.15, release: 0.62)
                lp += (noise() - lp) * 0.6
                return (lp * 0.8 + sin(twoPi * 180 * t) * 0.2 * (1 - t)) * e * 0.6
            }
        case .paperFlip:
            var lp: Float = 0
            return render(duration: 0.35) { t in
                let e = env(t, attack: 0.004, hold: 0.06, release: 0.28)
                lp += (noise() - lp) * 0.7
                return lp * e * 0.55
            }
        case .pop:
            return render(duration: 0.14) { t in
                let e = env(t, attack: 0.002, hold: 0.01, release: 0.12)
                return sin(twoPi * (420 - 200 * t / 0.14) * t) * e * 0.5
            }
        case .powerDown:
            return render(duration: 1.6) { t in
                let e = env(t, attack: 0.005, hold: 0.05, release: 1.5)
                let thud = t < 0.05 ? sin(twoPi * 55 * t) : 0
                let hum = sin(twoPi * (120 * pow(0.5, t)) * t) * 0.3 * max(0, 1 - t / 1.2)
                return (thud * 0.9 + hum) * e * 0.6
            }
        case .dawn:
            let chord: [Float] = [174.6, 261.6, 329.6, 392.0, 523.3]
            return render(duration: 2.2) { t in
                let e = env(t, attack: 1.2, hold: 0.4, release: 0.6)
                var s: Float = 0
                for (i, f) in chord.enumerated() { s += sin(twoPi * f * t) * (0.2 - Float(i) * 0.025) }
                return s * e * 0.5
            }
        case .starBurst:
            var lp: Float = 0
            return render(duration: 1.2) { t in
                let e = env(t, attack: 0.01, hold: 0.2, release: 0.99)
                lp += (noise() - lp) * 0.5
                let boom = sin(twoPi * 48 * t) * max(0, 1 - t / 0.5)
                let sparkle = sin(twoPi * (3000 + 800 * sin(t * 40)) * t) * 0.15 * (1 - t / 1.2)
                return (boom * 0.7 + lp * 0.25 + sparkle) * e * 0.6
            }
        case .whoosh:
            var lp: Float = 0
            return render(duration: 0.7) { t in
                let e = env(t, attack: 0.15, hold: 0.1, release: 0.45)
                lp += (noise() - lp) * (0.1 + 0.5 * t)
                return lp * e * 0.5
            }
        case .worldCodeAmbient:
            var lp: Float = 0
            return render(duration: 4.0) { t in
                lp += (noise() - lp) * 0.25
                return (sin(twoPi * 60 * t) * 0.18 + lp * 0.22) * 0.5
            }
        case .worldRainAmbient:
            var lp: Float = 0
            return render(duration: 4.0) { t in
                lp += (noise() - lp) * 0.45
                let rumble = sin(twoPi * 42 * t) * 0.12
                return (lp * 0.35 + rumble) * 0.55
            }
        case .worldSeaAmbient:
            var lp: Float = 0
            return render(duration: 4.0) { t in
                lp += (noise() - lp) * 0.04
                return (lp * 1.2 + sin(twoPi * 36 * t) * 0.15) * 0.5
            }
        case .worldPaperAmbient:
            var lp: Float = 0
            return render(duration: 4.0) { t in
                lp += (noise() - lp) * 0.15
                return (lp * 0.12 + sin(twoPi * 523.3 * t) * 0.03 * max(0, sin(t * 1.6))) * 0.4
            }
        case .worldSpaceAmbient:
            return render(duration: 4.0) { t in
                let pad = sin(twoPi * 65.4 * t) * 0.2 + sin(twoPi * 98 * t) * 0.12 + sin(twoPi * 130.8 * t) * 0.08
                return pad * (0.7 + 0.3 * sin(t * 1.5)) * 0.45
            }
        }
    }

    private static func writeWAV(_ samples: [Float], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func append<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let pcm = samples.map { Int16(max(-1, min(1, $0)) * 32767) }
        let dataSize = UInt32(pcm.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36 + dataSize))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(dataSize)
        for s in pcm { append(s) }
        try data.write(to: url, options: .atomic)
    }
}
