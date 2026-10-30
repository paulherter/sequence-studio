import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// An editor or dialog the timeline opens but does not own: the Inspector, the monitors, the Library and the shell's
/// dialogs provide them (the Mac `EditorPanels` hooks `onNest`, `onFrameSize`, `editMarker`, `presentTrackMix`, ...).
public enum TimelineEditorRequest: Sendable, Equatable {
    case editTransitionDuration(Transition.ID)
    case saveTransitionPreset(Transition.ID)
    case trimMode(TrimPoint, pointerBefore: Bool)
    case textClip(Clip.ID)
    case toneClip(Clip.ID)
    case graphicLayers(Clip.ID)
    case source(media: UUID)
    case marker(Marker.ID)
    case clipMarker(clip: Clip.ID, marker: Marker.ID)
    case captionText(CaptionItem.ID)
    /// The inline field over one caption word (the Mac `beginWordEditing`); the Text panel opens when no host has it.
    case captionWord(CaptionWordRef)
    /// Find and replace in the caption tracks (the Mac `CaptionSearchPopup`).
    case captionFindReplace
    case revealInProject(media: UUID)
    case trackMix(Track.ID)
    case sequenceVolume
    case saveClipPreset
    case newColorMatte
    case saveTitleBlock
    case saveTemplate
    case createAnglesClip
    /// The curve editor of a speed transition (the Mac `EasingCurvePopover` over `SpeedRampEaseSource`), at panel point `at`.
    case speedCurve(clip: Clip.ID, segment: Int, at: CGPoint)
    /// Picks the keys at `time` of the section Effect Controls shows (the Mac `effectModel.selectKeyLaneKey`).
    case keyLaneKey(clip: Clip.ID, time: Time, extend: Bool)

    /// The status line when no host provides it.
    public var unavailable: String {
        let name: String
        switch self {
        case .editTransitionDuration: name = "Transition duration dialog"
        case .saveTransitionPreset, .saveClipPreset: name = "Saving presets"
        case .trimMode: name = "Trim mode"
        case .textClip: name = "Text editing"
        case .toneClip: name = "Tone settings"
        case .graphicLayers: name = "Graphic layers"
        case .source: name = "Source monitor"
        case .marker: name = "Marker editing"
        case .clipMarker: name = "Clip marker editing"
        case .captionText: name = "Caption text editing"
        case .captionWord: name = "Caption word editing"
        case .captionFindReplace: name = "Find and Replace in Captions"
        case .revealInProject: name = "Reveal in Project"
        case .trackMix: name = "Track mix"
        case .sequenceVolume: name = "Sequence volume"
        case .newColorMatte: name = "New Color Matte"
        case .saveTitleBlock: name = "Saving title blocks"
        case .saveTemplate: name = "Saving templates"
        case .createAnglesClip: name = "Create Angles Clip"
        case .speedCurve: name = "Speed transition curve"
        case .keyLaneKey: name = "Picking lane keys"
        }
        return "\(name) is not available here yet"
    }
}

/// A one-line text prompt (the Mac `SQDialog` with one field: Rename Track, Rename Clip, Combine).
public struct TimelinePrompt: Sendable, Equatable {
    public var title: String
    public var message: String
    public var text: String
    public var placeholder: String
    public init(title: String, message: String = "", text: String, placeholder: String = "") {
        self.title = title; self.message = message; self.text = text; self.placeholder = placeholder
    }
}

/// What the host gives the timeline: the menu commands, the other panels' editors and a text prompt. Every hook is
/// optional; a missing one turns into a status line, so a host can grow its editors one at a time.
@MainActor
public final class TimelineHost {
    /// A menu command through the host's command route (the Mac `onCommand`, the Windows `ShellHost.execute`).
    public var command: ((EditorCommand) -> Void)?
    /// Opens an editor; false = the host has none for it.
    public var open: ((TimelineEditorRequest) -> Bool)?
    /// A one-field text prompt; nil answer = Cancel.
    public var prompt: ((TimelinePrompt) async -> String?)?
    /// A line for the status bar.
    public var status: ((String) -> Void)?
    /// The Slip two-up for the Program monitor (nil = hide); unset = the monitor does not show one.
    public var slipTwoUp: ((SlipTwoUp?, Timeline) -> Void)?
    /// Items picked in a clip's item lanes: the monitor and Controls select the same items (the Mac `graphics.select`).
    /// The host calls `TimelinePanel.setItemSelection` the other way round.
    public var itemSelection: ((Clip.ID, Set<UUID>) -> Void)?

    /// Runs a change on the host's panel (a menu row that sets the panel's own state: Beat Snap, Place Sequences as Clips).
    public var panel: ((_ change: (inout TimelinePanel) -> Void) -> Void)?

    public init() {}

    func editPanel(_ change: (inout TimelinePanel) -> Void) { panel?(change) }

    func run(_ c: EditorCommand) {
        if let command { command(c) } else { status?("This command is not available here yet") }
    }

    /// Opens `r` or reports that it is missing; returns the status line (nil when it opened).
    @discardableResult
    func request(_ r: TimelineEditorRequest) -> String? {
        if open?(r) == true { return nil }
        status?(r.unavailable)
        return r.unavailable
    }

    /// Asks for a line of text, then runs `done` with it (nothing on Cancel or without a prompt).
    func ask(_ p: TimelinePrompt, missing: String, _ done: @escaping @MainActor (String) -> Void) {
        guard let prompt else { status?(missing); return }
        Task { @MainActor in if let s = await prompt(p) { done(s) } }
    }
}
