import AppKit
import SQCore
import Testing
@testable import SQInspectorUI

@MainActor private func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }

/// WP-D: units, reset defaults, tooltips as names, menu order and the empty states of the text, caption and transition panels.
@MainActor @Suite struct WPDTextCaptionTests {
    @Test func everyTextInspectorFieldHasAUnitAndAResetValue() {
        let v = TextInspectorView(model: TextInspectorModel())
        let fields = allViews(v).compactMap { $0 as? ScrubField }.filter { !$0.isHidden }   // hidden = unused value slot of a switch row
        #expect(fields.count >= 15)
        // Tracking and line spacing are the only unitless fields (shared text block, board); a font axis value
        // (tooltip "Weight (wght)") is a bare number by nature.
        let axis = /\([A-Za-z ]{4}\)$/
        let unitless = fields.filter { $0.unit.isEmpty && !($0.sqToolTip ?? "").contains(axis) }
        #expect(unitless.count <= 2, "a field without a unit")
        for f in fields { #expect(f.defaultValue != nil, "a field without a reset value (\(f.unit))") }
    }

    @Test func textInspectorTooltipsAreNamesNotSentences() {
        let v = TextInspectorView(model: TextInspectorModel())
        for view in allViews(v) {
            guard let tip = view.sqToolTip else { continue }
            #expect(!tip.hasSuffix(".") && tip.split(separator: " ").count <= 5, "sentence tooltip: \(tip)")
        }
    }

    @Test func captionMenuEndsWithDelete() {
        let v = CaptionsTabView()
        let items = v.contextItems()
        let titles = items.filter { $0.kind == .action }.map(\.title)
        #expect(titles.last == "Delete")
        #expect(titles.firstIndex(of: "Export SRT…") ?? Int.max < titles.count - 1)
        #expect(items.last?.shortcut == "\u{232B}")
    }

    @Test func motionDurationBecomesWholeMilliseconds() {
        #expect(CaptionStyleTabView.motionTime(seconds: 0.5) == Time(500, 1000))
        #expect(CaptionStyleTabView.motionTime(seconds: 9999) == Time(600_000, 1000))
        #expect(CaptionStyleTabView.motionTime(seconds: 0) == nil)
        #expect(CaptionStyleTabView.motionTime(seconds: .nan) == nil)
    }

    @Test func captionsPanelWithoutSequenceHasTheEmptyState() {
        let v = TextPanelView(session: EditorSession(project: Project(name: "p", timelines: [])))
        #expect(allViews(v).contains { $0 is EmptyStateView })
    }
}
