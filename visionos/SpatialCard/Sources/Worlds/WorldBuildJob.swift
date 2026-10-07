import Foundation
import QuartzCore
import RealityKit

/// **v4 B5 §5.** One named piece of a world's build (a world's `buildSteps`, a slice of its art layer's clones).
struct WorldBuildStep {
    let name: String
    let run: () -> Void

    init(_ name: String, run: @escaping () -> Void) {
        self.name = name
        self.run = run
    }
}

/// **v4 B5 §5 — a desk prebuild spread over frames.**
///
/// B4 took the prebuilt worlds out of the scene tree but still built each one in a single main-thread block: 79–239 ms on
/// the headset (`world.build`), which the wearer saw as a frozen frame while looking at a still desk (round 3:
/// `frame hitch 194 ms`, `236 ms` right after `prebuilt … at the desk`; B3 run 2: 114–251 ms). A job is the same build as
/// a list of steps; the engine gives it a slice of every frame (`slice(budget:)`), so no frame carries more than the
/// budget plus the one step that started inside it. Nothing it makes is in the scene until the last step: the world's
/// root joins the engine's root, disabled, as before.
@MainActor
final class WorldBuildJob {
    enum Kind: String {
        /// `WorldAssets.prebuild`'s art layer (the clone storm), kept for whichever build wants it next.
        case artLayer = "art layer"
        /// A whole world for the desk (`WorldEngine.prebuildIfIdle`).
        case world
    }

    let id: String
    let kind: Kind
    private let steps: [WorldBuildStep]
    private var next = 0
    let started = CACurrentMediaTime()

    /// Each step's time (ms), in order.
    private(set) var stepTimes: [(name: String, ms: Double)] = []
    /// Frames that ran a slice, all the work they did, and the longest single slice (s).
    private(set) var frames = 0
    private(set) var work: Double = 0
    private(set) var worstSlice: Double = 0
    /// How many frames the job waited (the desk was not at rest / not quiet, or the passport was in the hand).
    var pausedFrames = 0 { didSet { lastSliceEnd = nil } }

    /// When the last slice ended, and what it ran: a long gap before the next slice is a frame that stalled *after*
    /// those steps had returned — work RealityKit does with what they made once the frame is handed over, which a
    /// step's own time cannot show. (Reset when the job waits: a paused frame is not a stall.)
    private var lastSliceEnd: CFTimeInterval?
    private var lastSliceNames = "the job's creation"
    /// Gaps longer than this between two slices are logged (s).
    static let stallGap: CFTimeInterval = 0.04
    /// The stalls seen (the steps before them, ms).
    private(set) var stalls: [(after: String, ms: Double)] = []

    init(id: String, kind: Kind, steps: [WorldBuildStep]) {
        self.id = id
        self.kind = kind
        self.steps = steps
        lastSliceEnd = CACurrentMediaTime()
    }

    var isDone: Bool { next >= steps.count }
    var stepCount: Int { steps.count }
    var stepsDone: Int { next }

    /// The longest single step so far (s): another step only starts in a slice while the time used plus this still
    /// fits — the steps are uneven (six clone steps of 1 ms, then a 5 ms one), and an average would overrun the budget.
    private(set) var longestStep: Double = 0
    /// Steps that took longer than the budget on their own (name, ms): the ones to split further.
    private(set) var overBudget: [(name: String, ms: Double)] = []

    /// Run steps for at most `budget` seconds of this frame: at least one step, then another only while the time used
    /// plus the longest step so far still fits. Returns the slice's length (s).
    @discardableResult
    func slice(budget: Double) -> Double {
        guard !isDone else { return 0 }
        frames += 1
        let sliceStart = CACurrentMediaTime()
        if let end = lastSliceEnd, sliceStart - end > WorldBuildJob.stallGap {
            stalls.append((lastSliceNames, (sliceStart - end) * 1000))
            print(String(format: "\(PerfLog.prefix) prebuild %@: %.0f ms passed between the slice of %@ and the next — the frame after it stalled",
                         id, (sliceStart - end) * 1000, lastSliceNames))
        }
        let firstStep = next
        repeat {
            let ms = runNext()
            if ms / 1000 > budget {
                overBudget.append((stepTimes.last?.name ?? "?", ms))
                print(String(format: "\(PerfLog.prefix) prebuild %@: the step \"%@\" took %.1f ms on its own (budget %.0f ms a frame)",
                             id, stepTimes.last?.name ?? "?", ms, budget * 1000))
            }
            let used = CACurrentMediaTime() - sliceStart
            if used + longestStep > budget { break }
        } while !isDone
        let spent = CACurrentMediaTime() - sliceStart
        work += spent
        worstSlice = max(worstSlice, spent)
        lastSliceEnd = CACurrentMediaTime()
        lastSliceNames = stepTimes[firstStep..<next].map { "\"\($0.name)\"" }.joined(separator: ", ")
        if spent > 0.008 {
            // Over the brief's 8 ms: say which steps shared the frame.
            let names = stepTimes[firstStep..<next].map { String(format: "%@ %.1f", $0.name, $0.ms) }.joined(separator: ", ")
            print(String(format: "\(PerfLog.prefix) prebuild %@: one frame's slice took %.1f ms (%@)", id, spent * 1000, names))
        }
        return spent
    }

    /// Everything that is left, now (an entry wants this world this frame). Returns the time it took (s).
    @discardableResult
    func finish() -> Double {
        let t0 = CACurrentMediaTime()
        while !isDone { runNext() }
        let spent = CACurrentMediaTime() - t0
        work += spent
        return spent
    }

    @discardableResult
    private func runNext() -> Double {
        let step = steps[next]
        let t0 = CACurrentMediaTime()
        step.run()
        let seconds = CACurrentMediaTime() - t0
        stepTimes.append((step.name, seconds * 1000))
        longestStep = max(longestStep, seconds)
        next += 1
        return seconds * 1000
    }

    /// The steps that took longest (ms), for the log.
    func slowestSteps(_ n: Int) -> String {
        stepTimes.sorted { $0.ms > $1.ms }.prefix(n).map { String(format: "%@ %.1f", $0.name, $0.ms) }.joined(separator: ", ")
    }
}
