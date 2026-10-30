import Foundation
import Testing
@testable import SQUIKit

@Suite struct AppVersionTests {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func displayJoinsNumberAndStage() {
        #expect(AppVersion.display(number: "0.1") == "0.1 Alpha")
        #expect(AppVersion.number(from: ["CFBundleShortVersionString": "0.10"]) == "0.10")
        #expect(AppVersion.number(from: nil) == AppVersion.fallbackNumber)
    }

    @Test func plistReadsProjectVersion() throws {
        let plist = try String(contentsOf: root.appendingPathComponent("App/Info.plist"), encoding: .utf8)
        #expect(plist.contains("<string>$(MARKETING_VERSION)</string>"))
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        #expect(yml.contains("MARKETING_VERSION: \"\(AppVersion.fallbackNumber)\""))
    }

    /// No source outside AppVersion spells out the version or reads the bundle version key.
    @Test func noHardCodedVersionStrings() throws {
        var hits: [String] = []
        let pattern = try NSRegularExpression(pattern: "0\\.9 Alpha|CFBundleShortVersionString|\"Version 1\\.0")
        for dir in ["App/Sources", "Packages"] {
            guard let en = FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "swift" {
                let p = url.path
                if p.contains("/.build/") || p.contains("/Tests/") || url.lastPathComponent == "AppVersion.swift" { continue }
                let text = try String(contentsOf: url, encoding: .utf8)
                for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                    let s = String(line)
                    if s.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                    if pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil { hits.append("\(url.lastPathComponent):\(i + 1)") }
                }
            }
        }
        #expect(hits.isEmpty, "hard-coded version, use AppVersion: \(hits)")
    }
}
