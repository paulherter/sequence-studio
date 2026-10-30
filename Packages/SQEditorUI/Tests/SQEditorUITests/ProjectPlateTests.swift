import AppKit
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// Project panel label color: the type-icon box wears the clip fill; the glyph on it keeps >= 4.5:1.
@MainActor
struct ProjectPlateTests {
    @Test func textOnEveryLabelFillReaches45() {
        for l in LabelColor.allCases { #expect(l.onFillContrast >= 4.5, "\(l)") }
    }

    @Test func darkLabelsKeepTheClipTextColour() {
        #expect(LabelColor.blue.onFill == Theme.Colors.onClip)       // the type defaults read as on the timeline
        #expect(LabelColor.green.onFill == Theme.Colors.onClip)
        #expect(LabelColor.yellow.onFill != Theme.Colors.onClip)     // white would be 2.6:1
    }

    /// One-color clips: the name on the clip is drawn in `LabelColor.onFill`, so it passes 4.5:1 on every label.
    @Test func clipNameColourIsTheLabelOnFill() {
        for l in LabelColor.allCases {
            #expect(ClipStyle.label(l).onFill == l.onFill, "\(l)")
            #expect(l.onFillContrast >= 4.5, "\(l)")
        }
        #expect(ClipStyle.video.onFill == Theme.Colors.onClip && ClipStyle.audio.onFill == Theme.Colors.onClip)
    }

    @Test func plateColourIsTheTimelineClipFill() {
        for l in LabelColor.allCases { #expect(l.fill == ClipStyle.label(l).fill) }
    }

    @Test func rowIsPlainAndTheBoxCarriesTheLabel() {
        let box = ProjectIconBox(frame: NSRect(origin: .zero, size: ProjectIconBox.size))
        #expect(box.label == nil)
        box.label = .blue
        #expect(box.label == .blue)
        #expect(ProjectIconBox.size.width > ProjectIconBox.size.height)
    }
}
