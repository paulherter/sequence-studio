import Foundation
import SQCore
import SQEditorSession
import SQText
import SQTranscribe

/// Puts the default Caption Look into the Create Captions dialog's preset list (first entry) and adds a "No Animation"
/// preset; the user's own pick stays selected.
@MainActor
enum NamedLookPreset {
    static let kitPresetName = "Project Kit"

    /// W8.3: a project whose kit has a caption style creates captions in that style by default (it wins over the global
    /// default look: the kit belongs to this project). Returns whether a default (kit or look) was installed.
    @discardableResult
    static func install(into m: CaptionsPanelModel, library: CaptionLookLibrary, kit: StyleKit? = nil) -> Bool {
        let noAnim = "Standard, No Animation"
        let picked = m.presets.indices.contains(m.selectedPresetIndex) ? m.presets[m.selectedPresetIndex].name : nil
        if !m.presets.contains(where: { $0.name == noAnim }) {
            var p = CaptionPreset.standard; p.animationRef = "none"
            m.presets.append(CaptionsPanelModel.NamedPreset(name: noAnim, preset: p))
        }
        GeneratedCaptionPresets.add(to: m)
        m.presets.removeAll { $0.name == kitPresetName }
        if kit?.caption != nil {
            var p = CaptionPreset.standard
            (p.styleRef, p.animationRef) = (StyleKit.captionStyleRef, StyleKit.captionAnimationRef)
            m.presets.insert(CaptionsPanelModel.NamedPreset(name: kitPresetName, preset: p), at: 0)
            let keep = (picked == nil || picked == "Standard" || picked == kitPresetName) ? kitPresetName : picked
            m.selectedPresetIndex = m.presets.firstIndex { $0.name == keep } ?? 0
            return true
        }
        guard let l = library.defaultLook else { return false }
        m.presets.removeAll { $0.name == l.name }
        m.presets.insert(CaptionsPanelModel.NamedPreset(name: l.name, preset: library.applyDefault(to: l.segmentation)), at: 0)
        // The user's pick stays; an untouched "Standard" (or the look itself) moves to the default look.
        let keep = (picked == nil || picked == "Standard" || picked == l.name) ? l.name : picked
        m.selectedPresetIndex = m.presets.firstIndex { $0.name == keep } ?? 0
        return true
    }
}
