import SQCore
import SQText
import SQTranscribe

/// Caption presets from the look generator (`GeneratedCaptionLooks`): the segmentation that suits the look's family plus
/// its style and entrance animation refs. TikTok families cut one short word at a time, YouTube families two lines of
/// about 32 characters, Professional ones the standard cut.
extension CaptionPreset {
    public static func generated(for look: CaptionStyleLook) -> CaptionPreset {
        var p: CaptionPreset
        switch look.category {
        case .tiktok?:
            p = .shortVideo
            p.emphasis = .none            // the look carries its own box or outline
        case .youtube?:
            p = .standard
            p.maxCharsPerLine = 32
        default:
            p = .standard
        }
        p.styleRef = look.styleRef
        p.animationRef = look.animationRef
        return p
    }
}

enum GeneratedCaptionPresets {
    static let namePrefix = "Look - "

    /// One named preset per generated caption look, in gallery order.
    static let named: [CaptionsPanelModel.NamedPreset] = (BuiltInTextLooks.isEnabled ? GeneratedCaptionLooks.all : []).map {
        CaptionsPanelModel.NamedPreset(name: namePrefix + $0.title, preset: .generated(for: $0))
    }

    /// Adds the presets the model does not list yet; the selection and the other presets stay.
    @MainActor static func add(to m: CaptionsPanelModel) {
        let have = Set(m.presets.map(\.name))
        m.presets.append(contentsOf: named.filter { !have.contains($0.name) })
    }
}
