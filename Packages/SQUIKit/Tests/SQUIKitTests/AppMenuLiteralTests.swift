import Foundation
import Testing
@testable import SQUIKit

/// A menu title typed as a literal in `App/Sources` has no German key (A15). Wrap it in `SQL10n.string` and list it in
/// `SQL10n.appMenuKeys`.
@Suite("App menu literals")
struct AppMenuLiteralTests {
    /// Literal menu titles that stay English on purpose.
    private static let allowlist: Set<String> = []

    @Test func everyMenuLiteralInTheAppGoesThroughTheCatalog() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        root.appendPathComponent("App/Sources")
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"\b(?:NSMenuItem|NSMenu)\(title: "([^"]*)""#)
        var bare: [String] = []
        for f in files {
            let text = try String(contentsOf: f, encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let title = String(text[Range(m.range(at: 1), in: text)!])
                if !title.isEmpty, !Self.allowlist.contains(title) { bare.append("\(f.lastPathComponent): \(title)") }
            }
        }
        #expect(bare.isEmpty, "Menu literals without SQL10n.string: \(bare)")
    }

    @Test func appMenuKeysAreTranslated() {
        #expect(SQL10n.missingKeys(in: "de", required: SQL10n.appMenuKeys).isEmpty)
    }
}
