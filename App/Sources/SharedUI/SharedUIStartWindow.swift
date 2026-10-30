import AppKit
import SQDrawShell
import SQEditorUI
import SQUIKit

/// The shared UI's start window (the Mac `StartWindowController` on the shared draw list): the start screen in a window of
/// its own, 1100 x 720 (min 820 x 520, frame remembered as "SequenceStudioStart"), with the system traffic lights in its
/// top bar. The shell's start screen, its dialogs and menus draw here while it is up (`SharedUIController.frame(role:)`);
/// `sync` applies the portable lifecycle (`ShellStartWindows`) to this window and the editor window after each frame.
/// Pip peeks over the support card and sits above the empty Recent pane (`SQMascotPlace.startProjects` / `.startEmpty`).
@MainActor
final class SharedUIStartWindow: NSObject {
    static let autosaveName = "SequenceStudioStart"
    let window: NSWindow
    let view: SharedUIView
    private let peekClip = NSView()
    private let peek = SQMascotPlace.startProjects.makeView()
    private let empty = SQMascotPlace.startEmpty.makeView()

    init(controller: SharedUIController) {
        let size = Theme.Metrics.startWindowSize
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        view = SharedUIView(controller: controller, role: .start)
        super.init()
        window.isReleasedWhenClosed = false
        window.title = "Sequence Studio"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.appearance = Theme.windowAppearance
        window.backgroundColor = Theme.Colors.canvas
        window.contentMinSize = Theme.Metrics.startWindowMinSize
        window.tabbingMode = .disallowed
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = root.bounds
        view.autoresizingMask = [.width, .height]
        root.addSubview(view)
        // Pip's bottom tucks `peekTuck` behind the card's top edge: the clip ends at that edge.
        peekClip.wantsLayer = true
        peekClip.layer?.masksToBounds = true
        peekClip.isHidden = true
        if let peek { peekClip.addSubview(peek) }
        root.addSubview(peekClip)
        if let empty { empty.isHidden = true; root.addSubview(empty) }
        window.contentView = root
        window.delegate = controller
        window.setFrameAutosaveName(Self.autosaveName)
        if !window.setFrameUsingName(Self.autosaveName) { window.center() }
        window.initialFirstResponder = view
    }

    var isVisible: Bool { window.isVisible }

    /// The system close / miniaturize / zoom buttons in the start top bar (the bar leaves `ShellStartScreen.M.lights`).
    func positionLights() {
        SQWindowLights.install(in: window, layout: .init(barHeight: Theme.Metrics.startTop,
                                                         firstCenterX: Theme.Metrics.startS4 + 7,
                                                         pitch: 14 + Theme.Metrics.startS2 - 2))
    }

    func show() {
        NSLog("[SharedUI] start window %ld shown", window.windowNumber)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        positionLights()
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.positionLights() } }
    }

    func hide() { window.orderOut(nil) }

    /// The windows follow the shell (`ShellHost.startWindowSteps`): called after every frame of either window.
    func sync(shell: ShellHost, editor: NSWindow?, showEditor: () -> Void) {
        // A minimized window counts as shown (bringing it back is the user's call).
        let steps = shell.startWindowSteps(startVisible: isVisible || window.isMiniaturized,
                                           editorVisible: editor.map { $0.isVisible || $0.isMiniaturized } ?? false)
        for s in steps {
            switch s {
            case .showStart: show()
            case .hideStart: hide()
            case .showEditor: showEditor()
            case .hideEditor: editor?.orderOut(nil)
            }
        }
        placeMascots(shell: shell)
    }

    /// Pip over the support card (projects) or above the empty pane's title (none yet); hidden while a dialog or menu
    /// covers the start screen. Points in the flipped view, converted into the root.
    private func placeMascots(shell: ShellHost) {
        let s = shell.startScreen
        let covered = shell.dialog != nil || shell.menuBar.controller.isOpen
        guard let root = window.contentView else { return }
        if let peek, let card = s?.mascotCard, !covered {
            let w = peek.frame.width, h = peek.frame.height
            let top = SQMascotPlace.peekTop(cardTop: card.minY, height: h)
            let clipPt = CGRect(x: card.maxX - 16 - w, y: top, width: w, height: card.minY - top)
            let c = view.convert(clipPt, to: root)
            if peekClip.frame != c { peekClip.frame = c }
            // The clip is unflipped: Pip's bottom (minY in the root) sits below the clip's bottom edge.
            let f = NSRect(x: 0, y: c.height - h, width: w, height: h)
            if peek.frame != f { peek.frame = f }
            if peekClip.isHidden { peekClip.isHidden = false }
        } else if !peekClip.isHidden {
            peekClip.isHidden = true
        }
        if let empty, let base = s?.emptyMascotBase, !covered {
            let w = empty.frame.width, h = empty.frame.height
            let f = view.convert(CGRect(x: base.x - w / 2, y: base.y - h, width: w, height: h), to: root)
            if empty.frame != f { empty.frame = f }
            if empty.isHidden { empty.isHidden = false }
        } else if let empty, !empty.isHidden {
            empty.isHidden = true
        }
    }
}
