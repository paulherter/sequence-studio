import Foundation
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession

/// Program monitor Full Screen (Mac `ProgramPresentation`) as shell state: the window shows only the Program picture over
/// everything (SQAppShell `MonitorCardHost.drawFullScreen`), Esc leaves, other keys go through the normal routing. The platform
/// may also hide its window chrome through `onFullScreenChange`.
extension ShellHost {
    /// Enters Full Screen. False without a sequence (nothing to show).
    @discardableResult
    public func enterProgramFullScreen() -> Bool {
        guard !isProgramFullScreen, session.activeTimeline != nil else { return false }
        isProgramFullScreen = true
        fullScreenStarted = ProcessInfo.processInfo.systemUptime
        onFullScreenChange?(true)
        return true
    }

    public func exitProgramFullScreen() {
        guard isProgramFullScreen else { return }
        isProgramFullScreen = false
        onFullScreenChange?(false)
    }

    /// Esc in Full Screen leaves it and nothing else sees that key (the Mac key monitor's first rule). True = taken.
    public func fullScreenKey(_ e: InputEvent) -> Bool {
        guard isProgramFullScreen, case .keyDown(let k, let m) = e, k == .escape, m.isEmpty else { return false }
        exitProgramFullScreen()
        return true
    }

    /// The picture's rectangle: the sequence's frame fitted into the window, centered.
    public static func fullScreenPictureRect(in size: CGSize, picture: (width: Int, height: Int)) -> CGRect {
        guard picture.width > 0, picture.height > 0, size.width > 0, size.height > 0 else { return CGRect(origin: .zero, size: size) }
        let k = min(size.width / CGFloat(picture.width), size.height / CGFloat(picture.height))
        let w = (CGFloat(picture.width) * k).rounded(), h = (CGFloat(picture.height) * k).rounded()
        return CGRect(x: ((size.width - w) / 2).rounded(), y: ((size.height - h) / 2).rounded(), width: w, height: h)
    }
}
