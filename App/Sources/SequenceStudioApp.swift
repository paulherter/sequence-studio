import AppKit

/// Entry point: the Mac app runs the shared draw-list UI (App/Sources/SharedUI).
@main
enum SequenceStudioApp {
    @MainActor private static var shared: SharedUIController?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] == nil ? .regular : .prohibited)
            let c = SharedUIController()
            shared = c
            app.delegate = c
            app.run()
        }
    }
}
