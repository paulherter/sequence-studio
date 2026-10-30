import Foundation
import Testing
@testable import SQCore

/// Folder-per-video start flow: the style kit travels with a user template, and a saved project exports into its own folder.
@Suite struct FolderPerVideoTests {
    private func kit() -> StyleKit {
        var k = StyleKit()
        k.colors["accent"] = EffectColor(red: 1, green: 0.5, blue: 0)
        return k
    }

    private func timeline() -> Timeline {
        Timeline(name: "S", format: SequenceFormat(width: 1080, height: 1920, frameDuration: Time(1, 30)),
                 tracks: Timeline.defaultTracks(video: 2, audio: 2))
    }

    @Test func templateCarriesStyleKitIntoNewProject() throws {
        let t = ProjectTemplate(capturing: timeline(), name: "Mine", styleKit: kit())
        let back = try JSONDecoder().decode(ProjectTemplate.self, from: JSONEncoder().encode(t))
        #expect(back == t)
        #expect(back.makeProject(name: "P").styleKit == kit())
    }

    @Test func templateWithoutKitLeavesProjectKitNil() throws {
        let t = ProjectTemplate(capturing: timeline(), name: "Plain")
        #expect(t.styleKit == nil)
        #expect(t.makeProject(name: "P").styleKit == nil)
        // An older template file (no styleKey) still loads.
        var obj = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(t)) as? [String: Any])
        obj.removeValue(forKey: "styleKit")
        let old = try JSONDecoder().decode(ProjectTemplate.self, from: JSONSerialization.data(withJSONObject: obj))
        #expect(old.styleKit == nil)
    }

    @Test func exportsFolderSitsNextToTheProject() {
        let url = URL(fileURLWithPath: "/Users/p/Movies/Sequence Studio/Reel/Reel.sqproj")
        #expect(MediaManagement.exportsFolder(forProjectAt: url).path == "/Users/p/Movies/Sequence Studio/Reel/Exports")
    }

    @Test func freeFolderNameCountsUp() {
        let taken: Set<String> = ["Untitled", "Untitled 2"]
        #expect(MediaManagement.freeFolderName("Untitled", exists: { taken.contains($0) }) == "Untitled 3")
        #expect(MediaManagement.freeFolderName("Reel", exists: { taken.contains($0) }) == "Reel")
        #expect(MediaManagement.freeFolderName("  a/b  ", exists: { _ in false }) == "a-b")
    }
}
