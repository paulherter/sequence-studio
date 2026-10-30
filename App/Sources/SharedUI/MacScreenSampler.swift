import AppKit
import SQAppShell
import SQDrawMonitor
import SQUIKit

/// The shared hosts' eyedropper seam (SQAppShell `AppScreenSampler`) on the Mac: the AppKit UI's own loupe (`SQLoupe`: a
/// catcher window over every screen, ScreenCaptureKit samples) runs the pointer, loupe and click; the host only waits.
@MainActor
final class MacScreenSampler: AppScreenSampler {
    /// The running loupe (SQLoupe must be kept until one of its callbacks fires).
    private var loupe: SQLoupe?

    var ownEyedropper: ((_ done: @escaping @MainActor (SQColorValue?) -> Void) -> Void)? {
        { [weak self] done in
            guard let self else { return done(nil) }
            loupe?.cancel()
            loupe = SQLoupe.begin(onPick: { [weak self] c in self?.loupe = nil; done(c) },
                                  onCancel: { [weak self] in self?.loupe = nil; done(nil) })
        }
    }

    // The loupe window samples itself; the host never asks per event on the Mac.
    func colorUnderPointer() -> SQColorValue? { nil }
    func loupeUnderPointer() -> ColorLoupe? { nil }
}
