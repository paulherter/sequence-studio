import Foundation
import SQAppShell
import SQEditorSession

/// Frame capture for Match Color to Clip on Windows: the Program engine's composite read back as linear RGB.
/// The engine shows a newly soloed clip a few ticks later, so this polls `linearFrame` until the picture is the exact
/// one (`isPictureSettled`), then reads it. shortcut: polls every 30 ms for at most 2 s then reads whatever is shown;
/// upgrade to a "picture shown" callback on the engine.
@MainActor final class WinFrameSampler: ProgramFrameSampling {
    private let engine: WinProgramEngine
    private var tasks: [String: Task<Void, Never>] = [:]
    init(engine: WinProgramEngine) { self.engine = engine }

    func sampleLinear(width: Int, key: String, done: @escaping @MainActor ([SIMD3<Float>]?) -> Void) {
        tasks[key]?.cancel()   // a newer capture with the same key replaces it
        tasks[key] = Task { @MainActor [weak self] in
            var waited = 0
            while let self, !Task.isCancelled, !self.engine.isPictureSettled, waited < 2000 {
                self.engine.redraw()
                try? await Task.sleep(for: .milliseconds(30))
                waited += 30
            }
            guard let self, !Task.isCancelled else { return }
            self.tasks[key] = nil
            guard let f = self.engine.linearFrame(width: width) else { return done(nil) }
            done(f.pixels)
        }
    }
}
