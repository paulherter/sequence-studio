import AppKit
import SQUIKit

/// Pure state of the startup log (DECISIONS 2026-10-03 "Startscreen: variant 3"): the steps reported so far, the fading
/// three-line window and the progress fraction. No UI, no clock.
public struct StartupLog: Equatable, Sendable {
    public struct Line: Equatable, Sendable {
        public var text: String
        /// 1 for the newest line, then 0.5 and 0.25 (the fade of the proposal).
        public var opacity: Double
    }

    /// Steps the launch normally reports; the bar fills as `steps.count / expected` (never reaches 1 before `finish`).
    public let expected: Int
    public private(set) var steps: [String] = []
    public private(set) var isFinished = false
    public static let visibleCount = 3
    static let opacities: [Double] = [0.25, 0.5, 1]

    public init(expected: Int) { self.expected = max(1, expected) }

    public mutating func begin(_ step: String) {
        guard !isFinished else { return }
        steps.append(step)
    }

    public mutating func finish() { isFinished = true }

    /// 0...1. The running step counts half, so the bar moves when a step starts and again when the next one does.
    public var progress: Double {
        if isFinished { return 1 }
        let done = max(0, Double(steps.count) - 0.5)
        return min(0.98, done / Double(expected))
    }

    /// Oldest first, at most three. Completed steps read plainly; the newest one (still running) ends in an ellipsis.
    public var visible: [Line] {
        let tail = steps.suffix(Self.visibleCount)
        let n = tail.count
        return tail.enumerated().map { i, s in
            let fromEnd = n - 1 - i
            let isLast = fromEnd == 0 && !isFinished
            return Line(text: isLast ? s + "…" : s, opacity: Self.opacities[Self.opacities.count - 1 - fromEnd])
        }
    }
}

/// When the splash may appear. Threshold 0 (2026-10-14): every start shows it fully, the sequencer holds it for the minimum.
public enum StartupSplashGate {
    public static let threshold: TimeInterval = 0
    public static func shouldShow(elapsed: TimeInterval, alreadyShown: Bool, finished: Bool) -> Bool {
        !alreadyShown && !finished && elapsed >= threshold
    }
}

/// The surface the reporter drives (the window in the app, a spy in tests).
@MainActor public protocol StartupSplashPresenting: AnyObject {
    func show()
    func update(_ log: StartupLog)
    /// Startup is done: run to Ready and fade out, then call `onGone` (the window is off screen by then).
    func close()
    var onGone: (() -> Void)? { get set }
}

/// Startup-step reporter: AppController launch phases call `step(_:)`; one NSLog line per step, and the splash (if
/// loading takes longer than 150 ms) shows the last three. `finish()` closes it instantly; it is safe to call twice.
@MainActor public final class StartupReporter {
    public static let shared = StartupReporter(expected: 12, presenter: nil, makePresenter: { StartupSplashWindow() })

    public private(set) var log: StartupLog
    private let clock: () -> TimeInterval
    private let emit: (String) -> Void
    private var start: TimeInterval?
    private var shown = false
    private var presenter: (any StartupSplashPresenting)?
    private var gone = false
    private var pending: [@MainActor (_ fadeIn: Bool) -> Void] = []
    private let makePresenter: (() -> any StartupSplashPresenting)?

    public init(expected: Int, presenter: (any StartupSplashPresenting)?,
                makePresenter: (() -> any StartupSplashPresenting)? = nil,
                clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                emit: @escaping (String) -> Void = { NSLog("%@", $0) }) {
        log = StartupLog(expected: expected)
        self.presenter = presenter
        self.makePresenter = makePresenter
        self.clock = clock
        self.emit = emit
    }

    /// Starts the clock (first call wins); `step` starts it too.
    public func begin() { if start == nil { start = clock() } }

    public func step(_ name: String) {
        begin()
        let elapsed = clock() - (start ?? clock())
        emit(String(format: "SQStartup +%.0f ms %@", elapsed * 1000, name))
        log.begin(name)
        if StartupSplashGate.shouldShow(elapsed: elapsed, alreadyShown: shown, finished: log.isFinished) {
            if presenter == nil { presenter = makePresenter?() }
            shown = presenter != nil
            presenter?.show()
        }
        if shown { presenter?.update(log) }
    }

    /// Main window is ready (or launch failed): close the splash at once.
    public func finish() {
        guard !log.isFinished else { return }
        log.finish()
        emit("SQStartup done")
        if shown, let p = presenter {
            p.onGone = { [weak self] in self?.splashGone() }
            p.close()   // the presenter keeps itself alive until the fade is over
        } else {
            splashGone()
        }
        presenter = nil
    }

    private func splashGone() {
        gone = true
        let blocks = pending
        pending = []
        for b in blocks { b(true) }
    }

    /// Runs `block` once no splash covers the screen: at once when none was shown (`fadeIn` false), else after its fade
    /// has completed (`fadeIn` true: the caller shows its window with a plain alpha fade). Launch windows go through here
    /// so the main window never appears behind the splash (DECISIONS 2026-10-14).
    public func whenSplashGone(_ block: @escaping @MainActor (_ fadeIn: Bool) -> Void) {
        if shown && !gone { pending.append(block) } else { block(false) }
    }

    public var isSplashShown: Bool { shown && !log.isFinished }
}

