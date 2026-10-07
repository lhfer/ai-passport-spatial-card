import Foundation
import QuartzCore
import RealityKit
import SwiftUI

/// **v4 B5 §2 — what this app's own ECS systems cost the main thread, frame by frame.**
///
/// Every system of ours brackets its `update` with `start()` / `stop(_:since:)`; `PerfProbeSystem` takes the sums once a
/// frame, so between two of its updates each other system has run exactly once — whatever order RealityKit runs them in.
/// Two clock reads per system per frame: cheap enough to stay on in every build.
enum FrameCPU {
    /// Seconds each system spent since `take()` last ran.
    static var spent: [String: Double] = [:]

    @inline(__always) static func start() -> CFTimeInterval { CACurrentMediaTime() }

    @inline(__always) static func stop(_ name: String, since start: CFTimeInterval) {
        spent[name, default: 0] += CACurrentMediaTime() - start
    }

    static func take() -> [String: Double] {
        let taken = spent
        spent.removeAll(keepingCapacity: true)
        return taken
    }
}

/// **v4 B5 §2 — `--perf-census`: what is moving and drawing, frame by frame, inside every `[perf]` window.**
///
/// The brief: before saving anything in a desk transition, say what is in flight in it — entities, attachments,
/// emitters, particles, translucent layers, tweens — as per-frame peaks. The `[perf] scene:` census is one walk at the
/// end of a window (and its particle number is a steady state); this walks the scene **every frame** while it is on and
/// keeps peaks and averages per window, plus the systems' CPU (`FrameCPU`) and how often the gallery's SwiftUI views
/// were re-evaluated. It is a simulator / diagnostic flag: the walk itself costs main-thread time (reported as
/// `walk`), so it is off unless asked for.
enum PerfCensus {
    static var enabled = false
    /// Births and bursts, for the alive-particle count.
    static var ledger = V4.ParticleLedger()

    /// v4 B5 §2: the gallery's SwiftUI side, counted where it happens (`NoteCardView` / `NoteCoverView`).
    static var noteCardBodies = 0
    static var coverBodies = 0
    /// A cover's `AsyncImage` entered `.empty` (a load started: the shimmer appeared) — a cover reloading.
    static var coverLoadsStarted = 0
    static var coversShown = 0

    /// One frame of the walk.
    struct Frame {
        var entities = 0
        var attachments = 0
        /// Attachments under an accumulated opacity of 0.01–0.99: a SwiftUI layer drawn see-through.
        var translucentAttachments = 0
        /// …named by their nearest named ancestor (`note-…` holders folded into `note-*`).
        var translucentNames: [String: Int] = [:]
        /// Drawables (a mesh or an attachment) that are enabled but faded to nothing (accumulated opacity < 0.01): drawn,
        /// or at least submitted, for no pixel. Named like the translucent ones.
        var invisible = 0
        var invisibleNames: [String: Int] = [:]
        /// Entities carrying a `TweenComponent` (each one written every frame by `TweenSystem`).
        var tweens = 0
        /// Attachments inside a subtree a tween is moving.
        var tweeningAttachments = 0
        var emitters = 0
        var emitterNames: [String: Int] = [:]
        var particles: Double = 0
        var walkSeconds: Double = 0
    }

    /// What an emitter that sets nothing gets (the beam's dust, the worlds' emitters): said once, with `--perf-census`.
    static func describeDefaults() -> String {
        let p = ParticleEmitterComponent()
        return "a ParticleEmitterComponent left to its defaults sorts \(p.mainEmitter.sortOrder), blends \(p.mainEmitter.blendMode)"
    }

    /// A burst fired (`ParticleEmitterComponent.burst()`): the ledger counts it, since no component state says so.
    static func noteBurst(_ count: Int, life: Double) {
        guard enabled else { return }
        ledger.burst(count: Double(count), life: life, at: CACurrentMediaTime())
    }

    /// Walk the scene once (`PerfLog.sceneRoots`), feeding the ledger with what emitted over the last `dt`.
    static func sample(dt: Double) -> Frame? {
        guard enabled, let roots = PerfLog.sceneRoots?() else { return nil }
        let started = CACurrentMediaTime()
        var frame = Frame()
        for root in roots { walk(root, 1, false, "", dt, started, &frame) }
        frame.particles = ledger.alive(at: started)
        frame.walkSeconds = CACurrentMediaTime() - started
        return frame
    }

    private static func walk(_ entity: Entity, _ opacity: Float, _ underTween: Bool, _ named: String, _ dt: Double,
                             _ now: CFTimeInterval, _ frame: inout Frame) {
        guard entity.isEnabled else { return }
        frame.entities += 1
        let alpha = opacity * (entity.components[OpacityComponent.self]?.opacity ?? 1)
        let tweened = entity.components.has(TweenComponent.self)
        if tweened { frame.tweens += 1 }
        let moving = underTween || tweened
        let name = entity.name.isEmpty ? named : entity.name
        // An attachment is a `ViewAttachmentEntity` (the RealityView's) or any entity carrying a `ViewAttachmentComponent`
        // (the hero card's type layer is mounted that way).
        let isAttachment = entity is ViewAttachmentEntity || entity.components.has(ViewAttachmentComponent.self)
        if alpha < 0.01, isAttachment || (entity as? ModelEntity)?.model != nil {
            frame.invisible += 1
            let key = name.hasPrefix("note-") ? "note-*" : (name.isEmpty ? "(unnamed)" : name)
            frame.invisibleNames[key, default: 0] += 1
        }
        if isAttachment {
            frame.attachments += 1
            // Translucent = drawn see-through (0.01–0.99): a card faded to nothing is counted as "faded to nothing" below
            // instead (a gallery card waiting for its turn in a fan-out sits at 0 inside the name card).
            if alpha < 0.99, alpha >= 0.01 {
                frame.translucentAttachments += 1
                let key = name.hasPrefix("note-") ? "note-*" : (name.isEmpty ? "(unnamed)" : name)
                frame.translucentNames[key, default: 0] += 1
            }
            if moving { frame.tweeningAttachments += 1 }
        }
        if let emitter = entity.components[ParticleEmitterComponent.self], emitter.isEmitting {
            let main = emitter.mainEmitter
            if main.birthRate > 0 {
                frame.emitters += 1
                frame.emitterNames[entity.name.isEmpty ? "(unnamed)" : entity.name, default: 0] += 1
                ledger.emit(rate: Double(main.birthRate), dt: dt, life: main.lifeSpan, at: now)
                if let spawned = emitter.spawnedEmitter, spawned.birthRate > 0 {
                    // A spawned emitter fires on every death: its births trail the main ones by a life.
                    ledger.emit(rate: Double(main.birthRate * spawned.birthRate), dt: dt, life: spawned.lifeSpan, at: now)
                }
            }
        }
        for child in entity.children { walk(child, alpha, moving, name, dt, now, &frame) }
    }

    /// One window's worth of frames.
    struct Window {
        var entities = V4.FrameStat()
        var attachments = V4.FrameStat()
        var translucent = V4.FrameStat()
        var tweens = V4.FrameStat()
        var tweeningAttachments = V4.FrameStat()
        var emitters = V4.FrameStat()
        var particles = V4.FrameStat()
        var walk = V4.FrameStat()
        /// The most of each emitter name seen alive in one frame.
        var emitterNames: [String: Int] = [:]
        /// The most of each translucent attachment's name seen in one frame.
        var translucentNames: [String: Int] = [:]
        var invisible = V4.FrameStat()
        var invisibleNames: [String: Int] = [:]
        /// Our systems' CPU per frame, in total and per system.
        var cpu = V4.FrameStat()
        var cpuBySystem: [String: V4.FrameStat] = [:]
        var bodies0 = PerfCensus.noteCardBodies
        var coverBodies0 = PerfCensus.coverBodies
        var loads0 = PerfCensus.coverLoadsStarted
        var shown0 = PerfCensus.coversShown

        mutating func add(_ frame: Frame?, cpu spent: [String: Double]) {
            if let frame {
                entities.add(Double(frame.entities))
                attachments.add(Double(frame.attachments))
                translucent.add(Double(frame.translucentAttachments))
                tweens.add(Double(frame.tweens))
                tweeningAttachments.add(Double(frame.tweeningAttachments))
                emitters.add(Double(frame.emitters))
                particles.add(frame.particles)
                walk.add(frame.walkSeconds * 1000)
                for (name, count) in frame.emitterNames { emitterNames[name] = max(emitterNames[name] ?? 0, count) }
                for (name, count) in frame.translucentNames { translucentNames[name] = max(translucentNames[name] ?? 0, count) }
                invisible.add(Double(frame.invisible))
                for (name, count) in frame.invisibleNames { invisibleNames[name] = max(invisibleNames[name] ?? 0, count) }
            }
            cpu.add(spent.values.reduce(0, +) * 1000)
            for (name, seconds) in spent { cpuBySystem[name, default: V4.FrameStat()].add(seconds * 1000) }
        }

        /// `[perf] <label> census (N frames): …` (with `--perf-census`) and `[perf] <label> cpu: …` (always).
        func lines(label: String, census: Bool) -> [String] {
            func peak(_ s: V4.FrameStat) -> String { String(format: "%.0f (avg %.1f)", s.peak, s.average) }
            var out: [String] = []
            if census, entities.frames > 0 {
                let names = emitterNames.keys.sorted().map { emitterNames[$0]! > 1 ? "\($0)×\(emitterNames[$0]!)" : $0 }
                let clear = translucentNames.keys.sorted().map { translucentNames[$0]! > 1 ? "\($0)×\(translucentNames[$0]!)" : $0 }
                out.append("\(PerfLog.prefix) \(label) census (\(entities.frames) frames, per-frame peak): "
                           + "entities \(peak(entities)) · attachments \(peak(attachments)), translucent \(peak(translucent))"
                           + (clear.isEmpty ? "" : " [\(clear.joined(separator: ", "))]") + ", "
                           + "moving \(peak(tweeningAttachments)) · tweens \(peak(tweens)) · emitters \(peak(emitters))"
                           + (names.isEmpty ? "" : " [\(names.joined(separator: ", "))]")
                           + String(format: " · particles alive ≈ %.0f (avg %.0f) · the walk itself %.2f ms avg", particles.peak,
                                    particles.average, walk.average)
                           + " · enabled but faded to nothing \(peak(invisible))"
                           + (invisibleNames.isEmpty ? "" : " [\(invisibleNames.keys.sorted().map { invisibleNames[$0]! > 1 ? "\($0)×\(invisibleNames[$0]!)" : $0 }.joined(separator: ", "))]")
                           + " · SwiftUI: note card bodies +\(PerfCensus.noteCardBodies - bodies0), cover bodies +\(PerfCensus.coverBodies - coverBodies0), "
                           + "cover loads started +\(PerfCensus.coverLoadsStarted - loads0), covers shown +\(PerfCensus.coversShown - shown0)")
            }
            let top = cpuBySystem.sorted { $0.value.sum > $1.value.sum }.prefix(5)
                .map { String(format: "%@ %.2f/%.2f", $0.key, $0.value.average, $0.value.peak) }
            out.append("\(PerfLog.prefix) \(label) cpu: "
                       + String(format: "our systems %.2f ms per frame avg, %.2f ms peak (avg/peak ms: %@)", cpu.average, cpu.peak,
                                top.joined(separator: ", ")))
            return out
        }
    }
}
