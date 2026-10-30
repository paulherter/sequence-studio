import Foundation
import SQCore
import SQText

/// "Select text, click a saved template, the text takes that style": the first text layer of a Library title template
/// (style plus its in and out animation) is given to the single selected text clip or text layer of a graphic clip.
/// Text and box stay. Same target as the Look API (`lookTarget`), one undo step. With captions as the target the
/// template becomes the style of a caption track (or all tracks): shadow and animation included.
extension EditorSession {
    /// True when the selection is one text item or captions are the target (the template-style pick applies there).
    public var canApplyTemplateStyle: Bool {
        switch lookTarget {
        case .textClip?, .graphicText?, .captions?: true
        case nil: false
        }
    }

    /// `captionTrack`: with captions as the target, only that track takes the style (default: every caption track).
    @discardableResult
    public func applyTemplateStyle(_ template: TitleTemplate, captionTrack: CaptionTrack.ID? = nil) -> Bool {
        guard let target = lookTarget, let style = TemplateTextStyle(template: template) else { return false }
        if target == .captions { return applyCaptionTemplateStyle(style, template: template, track: captionTrack) }
        guard let (text, anims) = textContent(target) else { return false }
        let given = style.giving(to: text, animations: anims)
        return writeText(target, template: given.template, animations: given.animations)
    }

    /// The template becomes a project Look named like it (re-applying updates that Look); the track follows it, so new
    /// captions on the track inherit style, shadow and animation.
    /// shortcut: a caption plays one animation, so of the template's in and out only the in animation (else the out) is
    /// kept; upgrade when captions get a separate outro slot.
    private func applyCaptionTemplateStyle(_ style: TemplateTextStyle, template: TitleTemplate, track: CaptionTrack.ID?) -> Bool {
        let id = "template-" + template.name
        let animation = style.animations?.animationIn ?? style.animations?.animationOut
        let look = Look(id: id, name: template.name, style: style.style, animation: animation)
        var kit = project.styleKit ?? StyleKit()
        guard (try? kit.setLook(look)) != nil else { return false }
        let token = StyleKit.lookID(id)
        return giveCaptionTracks(look: look, styleToken: token, rememberedToken: token, kit: kit, track: track)
    }
}
