import Foundation
import Testing
@testable import SQDrawEditor
import SQDrawKit

/// The Color page's grade text in the drawn status bar (the Mac `StatusBar.setGrade` and its layout).
@Suite struct StatusGradeTests {
    let bar = DrawRect(x: 0, y: 900, w: 1200, h: 28)

    @Test func theGradeSitsRightBeforeTheFormatText() throws {
        let r = try #require(EditorScreen.gradeFrame(statusBar: bar, pad: 12, statusWidth: 80, formatWidth: 100, gradeWidth: 120))
        #expect(r.x == 1200 - 12 - 100 - 12 - 120)
        #expect(r.y == bar.y && r.h == bar.h)
    }

    @Test func aNarrowBarDropsTheGrade() {
        #expect(EditorScreen.gradeFrame(statusBar: DrawRect(x: 0, y: 0, w: 300, h: 28), pad: 12, statusWidth: 120, formatWidth: 100,
                                        gradeWidth: 120) == nil)
        #expect(EditorScreen.gradeFrame(statusBar: bar, pad: 12, statusWidth: 0, formatWidth: 100, gradeWidth: 0) == nil)
    }
}
