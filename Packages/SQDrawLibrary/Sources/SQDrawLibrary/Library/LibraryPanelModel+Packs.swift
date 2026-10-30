import Foundation
#if canImport(CoreText)
import CoreText
#endif
import SQLibrary
import SQInspectorUI
import SQEditorSession
import SQText

/// What an import did, for the confirmation line.
public struct LibraryPackImportSummary: Sendable, Equatable {
    public var packName: String
    public var added = 0
    public var replaced = 0
    public var skipped = 0
    public var workspaces = 0
    public var assets = 0
    /// Entries of kinds made by a newer version of the app: left out.
    public var unreadable = 0
}

/// `.sqpack` export and import of the Library (format and validation: SQLibrary `SQPackFormat`).
extension LibraryPanelModel {
    /// The kinds this build can read: every preset kind plus workspaces. A later kind (multi-layer text templates)
    /// registers its validator here and needs no format change.
    public static var packRegistry: SQPackKindRegistry {
        var r = SQPackKindRegistry.standard
        WorkspacePackKind.register(in: &r)
        return r
    }

    /// Names of the pack folders in the Library, sorted.
    public var packNames: [String] {
        Array(Set(presets.compactMap(\.pack))).sorted { $0.compare($1, options: [.numeric, .caseInsensitive]) == .orderedAscending }
    }

    public func presetIDs(inPack name: String) -> [UUID] { presets.filter { $0.pack == name }.map(\.id) }

    /// Writes the presets `ids` (and the LUTs their payloads name) as one pack.
    public func exportPack(ids: [UUID], manifest: SQPackManifest, to url: URL) async throws {
        let items = presets.filter { ids.contains($0.id) }
        var assets: [SQPackAsset] = [], refs: [UUID: [String]] = [:]
        let lutDir = LUTLibrary.defaultDirectory()
        for item in items {
            for name in SQPackAssetScanner.lutFileNames(in: item.payload) {
                let path = "luts/" + name
                guard let data = try? Data(contentsOf: lutDir.appendingPathComponent(name)) else { continue }
                if !assets.contains(where: { $0.path == path }) { assets.append(SQPackAsset(path: path, data: data)) }
                refs[item.id, default: []].append(path)
            }
        }
        let pack = try await presetStore.makePack(ids: items.map(\.id), manifest: manifest, assets: assets, assetRefs: refs)
        let registry = Self.packRegistry
        try await Task.detached { try SQPackFormat.write(pack, to: url, registry: registry) }.value
    }

    /// Reads and validates a pack file off the main thread.
    public func readPack(at url: URL) async throws -> SQPackReadResult {
        let registry = Self.packRegistry
        return try await Task.detached { try SQPackFormat.read(from: url, registry: registry) }.value
    }

    /// Names in `pack` that already exist in its folder.
    public func packConflicts(_ pack: SQPack) async -> [String] { await presetStore.conflicts(in: pack) }

    /// Installs LUTs and fonts, adds the presets in a folder named after the pack, hands workspaces to the host, and
    /// shows the new folder. Presets work right away (the Library reloads before this returns).
    @discardableResult
    public func importPack(_ read: SQPackReadResult, conflict: SQPackConflict) async throws -> LibraryPackImportSummary {
        let pack = read.pack
        var summary = LibraryPackImportSummary(packName: pack.manifest.name, unreadable: read.skipped.count)
        let fontDir = LibraryStores.supportDirectory.appendingPathComponent("Packs", isDirectory: true)
            .appendingPathComponent(Self.safeFolderName(pack.manifest.name), isDirectory: true)
        let installed = try SQPackInstaller.install(pack.assets, lutDirectory: LUTLibrary.defaultDirectory(), fontDirectory: fontDir)
        summary.assets = installed.luts.count + installed.fonts.count
        Self.registerFonts(installed.fonts)
        let result = try await presetStore.importPack(pack, conflict: conflict, registry: Self.packRegistry)
        summary.added = result.added.count; summary.replaced = result.replaced; summary.skipped = result.skipped
        let workspaces = result.deferred.compactMap(WorkspacePackKind.workspace(from:))
        summary.workspaces = workspaces.count
        if !workspaces.isEmpty { onImportWorkspaces?(workspaces) }
        await reloadPresets()
        if packNames.contains(pack.manifest.name) { selection = .pack(pack.manifest.name) }
        return summary
    }

    public static func safeFolderName(_ name: String) -> String {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let s = String(t.map { "/\\:".contains($0) ? "-" : $0 })
        return s.isEmpty ? "Pack" : s
    }

    /// Makes pack fonts usable in this session (the fonts stay on disk; `registerInstalledPackFonts` re-registers them at launch).
    public static func registerFonts(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        #if canImport(CoreText)
        CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, nil)
        TextGenerator.resetFailedLayouts()      // a text that failed for a missing font is tried again
        #else
        // shortcut: pack fonts are not registered with the Windows font system yet; text with a pack font falls back
        // until the Windows text backend (DirectWrite private collection) takes font URLs.
        _ = urls
        #endif
    }

    /// At launch: registers the fonts of every imported pack.
    public static func registerInstalledPackFonts() {
        let root = LibraryStores.supportDirectory.appendingPathComponent("Packs", isDirectory: true)
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        let fonts = en.compactMap { $0 as? URL }.filter { ["ttf", "otf"].contains($0.pathExtension.lowercased()) }
        registerFonts(fonts)
    }
}
