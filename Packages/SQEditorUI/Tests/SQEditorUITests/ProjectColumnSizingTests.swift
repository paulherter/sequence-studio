import AppKit
import Foundation
import SQCore
import Testing
@testable import SQEditorUI
@testable import SQInspectorUI

/// Compact default column widths of the Project list: Name fits its longest entry (clamped), the rest follow tightly.
@MainActor
struct ProjectColumnSizingTests {
    typealias C = ProjectPanelModel.Column
    private func chrome(depth: Int = 0) -> CGFloat { ProjectColumnSizing.nameChrome(maxDepth: depth) }

    @Test func nameFitsTheLongestEntry() {
        let w = ProjectColumnSizing.width(of: .name, header: 30, content: 90, maxDepth: 0)
        #expect(w == 90 + chrome())
    }

    @Test func nameIsClamped() {
        #expect(ProjectColumnSizing.width(of: .name, header: 30, content: 5, maxDepth: 0) == ProjectColumnSizing.nameRange.lowerBound)
        #expect(ProjectColumnSizing.width(of: .name, header: 30, content: 5000, maxDepth: 0) == ProjectColumnSizing.nameRange.upperBound)
    }

    @Test func deeperFoldersWidenTheName() {
        #expect(chrome(depth: 3) == chrome(depth: 0) + 3 * ProjectPanelView.levelIndent)
    }

    @Test func otherColumnsWrapTheirTextWithThemeSpacing() {
        let w = ProjectColumnSizing.width(of: .duration, header: 40, content: 64, maxDepth: 0)
        #expect(w == 64 + 2 * Theme.Spacing.xs)
    }

    @Test func headerKeepsTheTitleReadable() {
        let w = ProjectColumnSizing.width(of: .frameRate, header: 70, content: 20, maxDepth: 0)
        #expect(w >= 70 + ProjectColumnSizing.headerExtra + 2 * Theme.Spacing.xs)
    }

    @Test func otherColumnsNeverFallBelowTheirMinimum() {
        #expect(ProjectColumnSizing.width(of: .duration, header: 0, content: 0, maxDepth: 0) == C.duration.minWidth)
    }

    @Test func totalFitsATypicalPanelWithoutScrolling() {
        // Name (long) + Format + Duration at typical widths stays under a 480 pt panel.
        let name = ProjectColumnSizing.width(of: .name, header: 30, content: 5000, maxDepth: 1)
        let rest = ProjectColumnSizing.width(of: .format, header: 40, content: 110, maxDepth: 1)
            + ProjectColumnSizing.width(of: .duration, header: 50, content: 70, maxDepth: 1)
        #expect(name + rest <= 480)
    }

    @Test func userWidthWinsOverTheAutomaticOne() {
        var l = ProjectColumnLayout(visible: [.name, .duration])
        #expect(l.userWidth(of: .duration) == nil)
        l.setWidth(150, for: .duration)
        #expect(l.userWidth(of: .duration) == 150)
        #expect(l.userWidth(of: .name) == nil)
    }
}
