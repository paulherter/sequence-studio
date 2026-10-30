import Foundation
import Testing
import SQCore
@testable import SQText

/// Built-in caption styles moved from Helvetica to Inter. Captions store only a `styleRef`, so a project written before
/// that must keep resolving to Helvetica; `Project.builtInStyles` (absent in old files) says which set applies.
@Suite struct BuiltInFontGenerationTests {
    private let builtIns = ["default", "classic", "bold-box", "outline", "title", "tiktok", "youtube", CaptionPill.styleID]

    /// A project file as written before the field existed.
    private func oldProjectJSON() throws -> Data {
        let data = try JSONEncoder().encode(Project(name: "Old"))
        var obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["builtInStyles"] != nil)
        obj["builtInStyles"] = nil
        return try JSONSerialization.data(withJSONObject: obj)
    }

    @Test func oldProjectResolvesBuiltInCaptionStylesToHelvetica() throws {
        let old = try JSONDecoder().decode(Project.self, from: oldProjectJSON())
        #expect(old.builtInStyles == nil && old.usesLegacyBuiltInFont)
        let lib = CaptionLookRegistry.shared.library(for: old)
        for id in builtIns { #expect(lib.style(for: id).fontName == "Helvetica", "\(id)") }
        #expect(lib.style(for: nil).fontName == "Helvetica")
        // Everything but the font is the same style.
        var s = lib.style(for: "tiktok"); s.fontName = TextStyle.defaultFontName
        #expect(s == CaptionPresetLibrary.base.style(for: "tiktok"))
    }

    @Test func newProjectResolvesBuiltInCaptionStylesToInter() {
        let new = Project(name: "New")
        #expect(new.builtInStyles == Project.currentBuiltInStyles && !new.usesLegacyBuiltInFont)
        let lib = CaptionLookRegistry.shared.library(for: new)
        for id in builtIns { #expect(lib.style(for: id).fontName == InterFont.familyName, "\(id)") }
    }

    /// Saving an old project must not turn it into a new one; a new one keeps its marker.
    @Test func savingKeepsTheGeneration() throws {
        let old = try JSONDecoder().decode(Project.self, from: oldProjectJSON())
        let again = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(old))
        #expect(again.usesLegacyBuiltInFont)
        let new = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(Project(name: "New")))
        #expect(!new.usesLegacyBuiltInFont)
    }

    /// The kit caption style is built on the project's built-ins, and the starter kit follows them too.
    @Test func kitCaptionStyleAndStarterKitFollowTheGeneration() {
        var kit = StyleKit.starter(legacyFont: true)
        #expect(kit.font(StyleKit.brandFontToken) == "Helvetica")
        #expect(StyleKit.starter.font(StyleKit.brandFontToken) == InterFont.familyName)
        kit.fonts = [:]                                   // a kit without a brand font: the base style's font shows
        let legacy = CaptionLookRegistry.shared.library(for: kit, legacyFont: true)
        let modern = CaptionLookRegistry.shared.library(for: kit, legacyFont: false)
        #expect(legacy.style(for: StyleKit.captionStyleRef).fontName == "Helvetica")
        #expect(modern.style(for: StyleKit.captionStyleRef).fontName == InterFont.familyName)
    }
}
