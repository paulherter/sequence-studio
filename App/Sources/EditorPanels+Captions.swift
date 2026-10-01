import AppKit
import SQCore
import SQEditorUI
import SQText

extension EditorPanels {
    /// Right-click on a caption segment in the timeline.
    func captionMenu() -> NSMenu {
        let items = TimelineContextMenu.captionItems(timeline: timelineView.timeline, captionSelection: timelineView.captionSelection,
                                                     playhead: session.playhead)
        return TimelineContextMenu.makeMenu(items: items) { [weak self] action in
            guard let self else { return }
            switch action {
            case .editCaption: if let id = session.captionSelection.first { timelineView.onEditCaptionText?(id) }
            case .splitCaption: session.splitCaption()
            case .mergeCaptions: session.mergeSelectedCaptions()
            case .delete: session.deleteSelectedCaptions()
            default: break
            }
        }
    }

    // MARK: Align to frame (Text section of Effect Controls)

    /// One of the six align buttons: the selected text clip's block is moved against the frame edge or centred. One undo step.
    func alignSelectedText(_ a: FrameAlignment) {
        guard let clip = session.singleSelectedClip, let ref = clip.generator, ref.kind == GeneratorRef.text,
              let (template, _) = try? TextGenerator.decode(ref), let tl = session.activeTimeline,
              effectModel.clip?.id == clip.id,
              let o = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead) else { return }
        let layout = TextLayout.layout(text: template.text, style: template.style, maxWidth: template.box?.width,
                                       boxHeight: template.box?.height)
        guard !layout.lines.isEmpty else { return }
        let base = o.baseTransform
        var moved = base
        moved.position = TextAlignToFrame.position(a, layout: layout, position: base.position, scale: o.displayTransform.scale,
                                                   rotation: o.displayTransform.rotation, canvasWidth: Double(tl.format.width),
                                                   canvasHeight: Double(tl.format.height))
        guard moved.position != base.position else { return }
        session.stopPlayback()
        effectModel.beginGesture()
        _ = effectModel.setTransform(moved, from: base)
        effectModel.endGesture()
    }

    // MARK: Caption editing in the Program monitor

    struct CaptionEdit { var id: CaptionItem.ID; var first = true }

    /// True when a caption's text lies under `p` (sequence px from the canvas centre) and captions are shown.
    func captionHit(_ p: Vec2) -> Bool {
        guard session.engine.showsCaptions, let tl = session.activeTimeline else { return false }
        return CaptionMonitorHit.caption(at: p, in: tl, time: session.playhead) != nil
    }

    /// Double-click on a caption in the monitor: the text field opens over it, typing is one undo step.
    func beginCaptionEditing(at p: Vec2) {
        guard let tl = session.activeTimeline, let id = CaptionMonitorHit.caption(at: p, in: tl, time: session.playhead) else { return }
        beginCaptionEditing(id)
    }

    func beginCaptionEditing(_ id: CaptionItem.ID) {
        guard let item = session.captionItem(id), let tl = session.activeTimeline else { return }
        session.stopPlayback()
        session.select(clips: [], captions: [id])
        let e = CaptionMonitorHit.editTarget(for: item, canvas: tl.format)
        captionEditing = CaptionEdit(id: id)
        surface.beginTextEditing(text: item.lines.joined(separator: "\n"), style: e.style, box: e.box, target: e.target, selectAll: false)
    }

    /// Text typed into the monitor field while a caption is being edited. False when no caption is being edited.
    func captionEdited(_ text: String) -> Bool {
        guard var e = captionEditing else { return false }
        session.setCaptionText(e.id, text, continuesGesture: !e.first)
        e.first = false
        captionEditing = e
        return true
    }

    func captionEditEnded(_ text: String) -> Bool {
        guard captionEditing != nil else { return false }
        captionEditing = nil
        return true
    }
}
