import AppKit
import SQEditorUI

/// Entry point. The shell is plain AppKit (docs/UX.md section 1): NSWindow + unified toolbar, NSSplitViews, real menus.
@main
enum SequenceStudioApp {
    @MainActor private static var controller: AppController?
    @MainActor private static var shared: SharedUIController?

    static func main() {
        MainActor.assumeIsolated {
            if SharedUIController.isRequested {   // default: the shared draw-list UI (App/Sources/SharedUI); SQ_APPKIT_UI=1 falls back to AppKit
                let app = NSApplication.shared
                app.setActivationPolicy(ProcessInfo.processInfo.environment["SQ_SHARED_UI_SHOT"] == nil ? .regular : .prohibited)
                let c = SharedUIController()
                shared = c
                app.delegate = c
                app.run()
                return
            }
            StartupReporter.shared.step("Fonts")
            FontFamilyList.warm()      // the text inspector needs the font list before the first window
            let app = NSApplication.shared
            app.setActivationPolicy(RenderPanels.isRequested ? .prohibited : .regular)   // lets the splash window appear before `applicationDidFinishLaunching`
            let c = AppController()
            controller = c
            app.delegate = c
            app.run()
        }
    }
}
