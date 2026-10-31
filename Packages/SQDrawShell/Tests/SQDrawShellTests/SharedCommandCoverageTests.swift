import Foundation
import Testing
import SQCore
import SQUIKit
import SQEditorSession
@testable import SQDrawShell

/// Fails when a command in the catalog, a key map or a menu is neither run by the shared app nor listed as not yet shared.
@MainActor
@Suite struct SharedCommandCoverageTests {
    private static var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func sourceFiles() -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let e = fm.enumerator(at: sourcesRoot, includingPropertiesForKeys: nil) else { return out }
        for case let u as URL in e where u.pathExtension == "swift" && u.path.contains("/Sources/") {
            out[u.lastPathComponent, default: ""] += (try? String(contentsOf: u, encoding: .utf8)) ?? ""
        }
        return out
    }

    @Test func everyAuditedCommandHasARoute() {
        var missing: [String] = []
        for map in [CommandMap.premiereDefault] {
            for c in CommandCatalog.audited(map) where SharedCommandCoverage.route(c) == nil {
                missing.append(SharedCommandCoverage.name(c))
            }
        }
        #expect(missing.isEmpty, "No shared route (add the owner to SharedCommandCoverage.owners or list it as not yet shared): \(Set(missing).sorted())")
    }

    @Test func ownersExistAndNameTheirCommand() {
        let files = Self.sourceFiles()
        guard !files.isEmpty else { return }
        var bad: [String] = []
        for (name, file) in SharedCommandCoverage.owners {
            guard let text = files[file] else { bad.append("\(name): \(file) not found"); continue }
            if !text.contains(".\(name)") { bad.append("\(name): not named in \(file)") }
        }
        #expect(bad.isEmpty, "\(bad.sorted())")
    }

    @Test func notYetSharedListMatchesTheHostSet() {
        let host = Set(ShellHost.notYetShared.map(SharedCommandCoverage.name))
        #expect(host == Set(SharedCommandCoverage.notYetShared.keys))
    }
}

@MainActor
@Suite struct SharedCommandFixesTests {
    @Test func audioGainWithoutAClipSaysSo() {
        let s = ShellCommandsTests.session()
        #expect(ShellCommands.run(.audioGainUp, session: s) == "Select an audio clip first.")
    }

    @Test func beatEditsNeedBeatMarkers() {
        let s = ShellCommandsTests.session()
        #expect(ShellCommands.run(.cutToBeats, session: s) == "Run Markers on Beat on the music first.")
        #expect(ShellCommands.run(.snapToBeats, session: s) == "Run Markers on Beat on the music first.")
    }

    @Test func switchAngleWithoutAnglesClipSaysSo() {
        let s = ShellCommandsTests.session()
        #expect(ShellCommands.run(.switchAngle(2), session: s) == "No Angles clip is selected or under the playhead.")
    }
}
