import Testing
import SQCore
@testable import SQEditorUI

/// Sequence > New Shape is a command alias of the Create tool's drag (E2): a centered box, lines horizontal.
@MainActor @Suite struct MenuShapeDragTests {
    @Test func boxIsCenteredThirdOfHeight() {
        let drag = GraphicsEditor.menuShapeDrag(.rectangle, canvas: Vec2(1920, 1080))
        #expect(drag.from == Vec2(-180, -180))
        #expect(drag.to == Vec2(180, 180))
    }

    @Test func lineAndArrowRunHorizontally() {
        for kind in [ShapeKind.line, .arrow] {
            let drag = GraphicsEditor.menuShapeDrag(kind, canvas: Vec2(1920, 1080))
            #expect(drag.from.y == 0 && drag.to.y == 0)
            #expect(drag.from.x == -180 && drag.to.x == 180)
        }
    }
}
