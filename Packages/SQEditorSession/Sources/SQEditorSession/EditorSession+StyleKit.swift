import Foundation
import SQCore
import SQText

/// W8.3 project style kit: brand tokens that captions, token-bound text and new motion effects follow. One undo step per call.
extension EditorSession {
    /// Replaces the project's kit; every token-bound text clip is re-resolved in the same undo step and captions in the kit
    /// style follow on the next frame (`syncStyleKit`).
    public func setStyleKit(_ kit: StyleKit?, name: String = "Change Style Kit") {
        guard kit != project.styleKit else { return }
        perform(name) { p in p.styleKit = kit }        // `perform` re-resolves the token-bound text clips
    }

    /// Imports a `.sqstyle`: adds its tokens and looks without overwriting the project's own brand tokens.
    @discardableResult
    public func importStyleKit(from url: URL) throws -> StyleKitMergeReport {
        let other = try StyleKitFile.read(from: url)
        let (merged, report) = (project.styleKit ?? StyleKit()).merging(other)
        setStyleKit(merged, name: "Import Style Kit")
        return report
    }

    /// Imports the bundled "the maintainer's Kit" (`StyleKit.pauls`) like a `.sqstyle`: the project's own tokens stay.
    @discardableResult
    public func importPaulsKit() -> StyleKitMergeReport {
        let (merged, report) = (project.styleKit ?? StyleKit()).merging(.pauls)
        setStyleKit(merged, name: "Imported Kit")
        return report
    }

    /// Writes the project's kit (the starter kit when the project has none) as a `.sqstyle`.
    public func exportStyleKit(to url: URL) throws {
        try StyleKitFile.write(project.styleKit ?? .starter(legacyFont: project.usesLegacyBuiltInFont), to: url)
    }

    /// Every caption of the active sequence uses the kit caption style (one undo step). False without a kit caption style.
    @discardableResult
    public func useKitCaptionStyle() -> Bool {
        guard project.styleKit?.caption != nil else { return false }
        return setCaptionStyle(styleRef: StyleKit.captionStyleRef, animationRef: StyleKit.captionAnimationRef)
    }

    /// Saves the caption look on screen (`currentCaptionLook`) into the project's kit under `name` (one undo step; a project
    /// without a kit gets one holding just the look). A kit look with that name is replaced. Returns the kit look id, whose
    /// caption refs are `StyleKit.lookID(id)` through `CaptionLook.styleID/animationID`; nil without captions.
    @discardableResult
    public func saveCaptionLookToKit(name: String) -> String? {
        guard let look = currentCaptionLook() else { return nil }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        var kit = project.styleKit ?? StyleKit()
        let existing = kit.looks.first { $0.value.name == clean }?.key
        let id = existing ?? Self.uniqueKitLookID(for: clean, in: kit)
        guard (try? kit.addLook(look, id: id, name: clean)) != nil else { return nil }
        setStyleKit(kit, name: "Save Look to Style Kit")
        return id
    }

    private static func uniqueKitLookID(for name: String, in kit: StyleKit) -> String {
        let slug = name.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let base = slug.isEmpty ? "look" : slug
        var id = base, n = 2
        while kit.looks[id] != nil { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// Every edit ends here (`perform`): token-bound text clips take the kit's current values.
    static func resolveStyleTokens(_ p: inout Project) { p.resolveTextTokens() }

    /// Hands the project's kit to this session's engine (the monitor draws captions through it, so two open projects with
    /// different kits do not clash) and to the process-wide caption library the inspectors read (the project being edited).
    /// When the kit changed, the engine gets the sequence again so the monitor redraws the captions in the new style.
    func syncStyleKit() {
        engine.captionStyleKit = project.styleKit
        engine.captionLegacyFont = project.usesLegacyBuiltInFont
        if CaptionLookRegistry.shared.setStyleKit(project.styleKit, legacyFont: project.usesLegacyBuiltInFont) { pushTimeline(force: true) }
    }
}
