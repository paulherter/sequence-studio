import Foundation
import SQCore
import Testing
@testable import SQUIKit

/// A command id that an imported key set (Final Cut, Premiere, Resolve) or the catalog can reach must be supported,
/// otherwise the key flashes "not available yet" (the "...5" and "...10" twins of the Shift = 10 frames rule).
@Suite struct ImportedCommandSupportTests {
    @Test func everyImportTableCommandIsSupported() {
        let tables: [(String, [String: ForeignKeymap.Target])] =
            [("FCP", FCPCommandTable.rows), ("Premiere", PremiereCommandTable.rows), ("Resolve", ResolveCommandTable.rows)]
        for (table, rows) in tables {
            for (name, target) in rows {
                guard case .command(let id) = target, let c = EditorCommand(id: id) else { continue }
                #expect(CommandSupport.isSupported(c), "\(table) \(name) -> \(id) is not supported")
            }
        }
    }

    /// A default key must never flash "not available yet": every command the Premiere default map binds is wired.
    @Test func everyDefaultKeyCommandIsSupported() {
        for e in CommandMap.premiereDefault.entries {
            #expect(CommandSupport.isSupported(e.command), "\(e.command.title) is bound but not supported")
        }
    }

    @Test func shiftTwinsAreSupported() {
        let twins: [EditorCommand] = [.stepBackward5, .stepForward5, .stepBackward10, .stepForward10, .nudgeLeft5, .nudgeRight5,
                                      .nudgeLeft10, .nudgeRight10, .trimBackward5, .trimForward5, .slideLeft5, .slipRight5]
        for c in twins { #expect(CommandSupport.isSupported(c), "\(c)") }
    }
}
