import Foundation
import SQCore
import SQUIKit

/// The clip look commands that need nothing but the session: video fades, frame holds, Dynamic Zoom, blurred fill and
/// card, split screen, punch-in, subject mask. The AppKit app and the shell (Mac and Windows) call the same code, so
/// the edits, the status lines and the menu rules cannot drift apart. Commands with a long analysis or a sheet
/// (Auto Reframe, Stabilize, Find Scene Changes, Match Color) stay with the host.
@MainActor
public enum EditorLookCommands {
    public static func handles(_ c: EditorCommand) -> Bool {
        switch c {
        case .videoFadeIn, .videoFadeOut, .addFrameHold, .insertFrameHold, .dynamicZoomIn, .dynamicZoomOut, .splitScreen,
             .fitBlurredFill, .fitCard, .removeBlurredFill, .togglePunchIn, .addSubjectMask: true
        default: false
        }
    }

    /// Menu enabling; nil when `c` is not one of these.
    public static func enabled(_ c: EditorCommand, session s: EditorSession) -> Bool? {
        switch c {
        case .videoFadeIn, .videoFadeOut: !s.commandClipsForMenu(kind: .video).isEmpty
        case .addFrameHold, .insertFrameHold: s.commandClipsForMenu(kind: .video).contains { $0.timeline.contains(s.playhead) }
        case .splitScreen(let preset, _): s.splitScreenProblem(preset) == nil
        case .fitBlurredFill, .fitCard, .removeBlurredFill: s.blurredFillEnabled(c)
        case .togglePunchIn: s.punchInEnabled
        case .dynamicZoomIn, .dynamicZoomOut: !s.reframeTargets.isEmpty
        case .addSubjectMask: s.addSubjectMaskEnabled
        default: nil
        }
    }

    /// Runs the command. "" = done quietly, a line = status text to flash, nil = not one of these commands.
    public static func run(_ c: EditorCommand, session s: EditorSession) -> String? {
        switch c {
        case .videoFadeIn: return s.fadeVideo(.head) ? "" : "Select a video clip to fade in."
        case .videoFadeOut: return s.fadeVideo(.tail) ? "" : "Select a video clip to fade out."
        case .addFrameHold: return s.addFrameHold() ? "" : "Put the playhead on a video clip to hold its frame."
        case .insertFrameHold: return s.insertFrameHold() ? "" : "Put the playhead on a video clip to insert a frame hold."
        case .dynamicZoomIn, .dynamicZoomOut:
            return s.applyDynamicZoom(zoomIn: c == .dynamicZoomIn)
                ? "Dynamic Zoom: Scale and Position keys are in Effect Controls (Dynamic Zoom)." : "Select a video clip to zoom."
        case .fitBlurredFill: return s.applyBlurredFill(.fit) ? "" : "Select a video clip whose shape differs from the sequence frame."
        case .fitCard: return s.applyBlurredFill(.card) ? "" : "Select a video clip to put on a card."
        case .removeBlurredFill: return s.removeBlurredFill() ? "" : "Select a clip that has a blurred fill."
        case .togglePunchIn: return s.togglePunchIn() ? "" : "Select a video clip to punch in."
        case .addSubjectMask: return s.addSubjectMask() ? "" : "Select a video clip without a subject mask."
        case .splitScreen(let preset, let animated):
            switch s.splitScreenProblem(preset) {
            case .sameTrack: return "Select clips on different tracks"
            case .tooFewClips: return SQL10n.format("Select %@ video clips on stacked tracks for a split screen.", String(preset.cellCount))
            case nil:
                let extra = s.splitScreenExtraClips(preset)
                guard s.applySplitScreen(preset, animated: animated), extra > 0 else { return "" }
                return SQL10n.format(extra == 1 ? "%@ uses %@ clips (lowest tracks); %@ more selected clip was left unchanged."
                                                : "%@ uses %@ clips (lowest tracks); %@ more selected clips were left unchanged.",
                                     SQL10n.string(preset.title), String(preset.cellCount), String(extra))
            }
        default: return nil
        }
    }
}
