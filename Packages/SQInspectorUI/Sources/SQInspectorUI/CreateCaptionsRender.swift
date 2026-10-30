import AppKit

/// Render harness entry: the Create Captions dialog is private to the Captions tab; the harness opens it through this.
@MainActor
public enum CreateCaptionsRender {
    public static func present(on window: NSWindow, model: CaptionsPanelModel) {
        CreateCaptionsDialog.present(on: window, model: model) { _ in }
    }
}
