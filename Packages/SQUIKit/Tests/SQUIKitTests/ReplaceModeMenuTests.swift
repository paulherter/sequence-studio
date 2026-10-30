import Testing
import SQCore
@testable import SQUIKit

struct ReplaceModeMenuTests {
    @Test func everyReplaceModeIsInTheClipMenuWithoutAKey() {
        let visible = EditorMenus.visible.flatMap(\.commands)
        for m in ReplaceMode.allCases {
            #expect(visible.contains(.replaceMode(m)))
            #expect(EditorCommand.replaceMode(m).title == m.title)
        }
    }
}
