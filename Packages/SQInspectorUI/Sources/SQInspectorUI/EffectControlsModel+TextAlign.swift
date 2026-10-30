import Foundation
import SQCore
import SQText
import SQEditorSession

extension EffectControlsModel {
    /// Arrange: moves the selected text clip so its laid-out text lines up with a frame edge or center, one undo step
    /// through Transform (the Mac host's `alignSelectedText`, App/Sources/EditorPanels+Captions.swift). Nothing happens
    /// when the shown clip is not that text clip or the text would not move.
    public func alignText(_ a: FrameAlignment, session: EditorSession) {
        guard let clip = session.displayedSelectedClip, let ref = clip.generator, ref.kind == GeneratorRef.text,
              let (template, _) = try? TextGenerator.decode(ref), let tl = session.displayTimeline,
              self.clip?.id == clip.id,
              let o = OverlayTarget.make(clip: clip, project: session.project, timeline: tl, at: session.playhead) else { return }
        let layout = TextLayout.layout(text: template.text, style: template.style, maxWidth: template.box?.width,
                                       boxHeight: template.box?.height)
        guard !layout.lines.isEmpty else { return }
        let base = o.baseTransform
        var moved = base
        moved.position = TextAlignToFrame.position(a, layout: layout, position: base.position, scale: o.displayTransform.scale,
                                                   rotation: o.displayTransform.rotation, canvasWidth: Double(tl.format.displayWidth),
                                                   canvasHeight: Double(tl.format.height))
        guard moved.position != base.position else { return }
        session.stopPlayback()
        beginGesture()
        _ = setTransform(moved, from: base)
        endGesture()
    }
}
