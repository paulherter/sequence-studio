import Foundation
import SQUIKit

/// First-run welcome content (Help > Welcome Tour): where to start and the few keys worth knowing. Plain data so a test
/// pins its shape; the Mac draws it in an `SQDialog`, the Windows shell in a `ShellDialog`. Key names follow the platform
/// (Cmd on the Mac, Ctrl elsewhere).
public enum OnboardingContent {
    public struct Tip: Sendable, Equatable {
        public let title: String
        public let detail: String
    }

    public static let title = "Welcome to Sequence Studio"
    public static let intro = "A short start. You can skip this and find everything in the menus."
    public static var tips: [Tip] { tips(for: .current) }

    public static func tips(for platform: KeyPlatform) -> [Tip] {
        let mod = platform == .mac ? "Cmd" : "Ctrl"
        return [
            Tip(title: "Import", detail: "File > Import Media (\(mod)+I), or drop files into the Project panel."),
            Tip(title: "Edit", detail: "Drag a clip to the timeline. K stops, J and L play backward and forward, C cuts at the playhead."),
            Tip(title: "Undo", detail: "\(mod)+Z steps back. Window > History lists every step, click one to jump to it."),
            Tip(title: "Shortcuts", detail: "Help shows all keys, and every one can be changed in Keyboard Shortcuts."),
            Tip(title: "Export", detail: "\(mod)+M opens Export when the sequence is ready."),
        ]
    }

    public static let startButton = "Get Started"
    public static let skipButton = "Skip"
}
