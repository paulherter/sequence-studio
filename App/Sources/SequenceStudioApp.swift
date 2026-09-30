import AppKit

/// Entry point. The shell is plain AppKit (docs/UX.md section 1): NSWindow + unified toolbar, NSSplitViews, real menus.
@main
enum SequenceStudioApp {
    @MainActor private static var controller: AppController?

    static func main() {
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let c = AppController()
            controller = c
            app.delegate = c
            app.run()
        }
    }
}
