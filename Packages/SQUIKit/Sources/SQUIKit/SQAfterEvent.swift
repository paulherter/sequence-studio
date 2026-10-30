import AppKit

/// Runs work on the main thread once the current event is done, also while a modal dialog is open.
/// `DispatchQueue.main.async` does not: a modal session started from a main-queue block (a menu action, a `Task`)
/// holds that serial queue until the dialog closes, so a block queued inside the dialog would run only afterwards.
@MainActor
public enum SQAfterEvent {
    public static func run(_ body: @escaping @MainActor () -> Void) {
        let loop = CFRunLoopGetMain()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated { body() } }
        CFRunLoopWakeUp(loop)
    }
}
