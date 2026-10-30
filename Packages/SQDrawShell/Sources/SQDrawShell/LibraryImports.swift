import Foundation
import SQCore
import SQEditorSession
import SQLibrary
import SQPremiereImport

/// The file reading and library writing behind File > Import Motion Graphics Template… and Import Premiere Presets…,
/// shared by the AppKit app and the shared shell (Mac and Windows). Source files are never modified; a name that is
/// already in the library is not added again (docs/PRPROJ-IMPORT.md, docs/ENGINE-NOTES.md "Motion Graphics Templates").
public enum LibraryImports {
    public struct MogrtOutcome {
        public var added = 0, already = 0, dropped = 0
        public var report = PRImportReport()
        public var failures: [(file: String, error: Error)] = []

        /// The status line; nil when nothing was added and nothing was there already.
        public var statusLine: String? {
            guard added > 0 || already > 0 else { return nil }
            return SQL10n.plural(added, one: "Imported %@ template. Find it in the Library under Titles",
                                 other: "Imported %@ templates. Find them in the Library under Titles")
                + (already > 0 ? SQL10n.format(", %@ already in the library", String(already)) : "")
                + (dropped > 0 ? SQL10n.plural(dropped, one: ", %@ unsupported item left out.", other: ", %@ unsupported items left out.") : ".")
        }
        /// The alert title for the first failure (the first reason is shown in full, the rest only counted).
        public var failureTitle: String? {
            guard let first = failures.first else { return nil }
            return failures.count == 1 ? "Could not import “\(first.file)”" : "Could not import “\(first.file)” and \(failures.count - 1) more"
        }
    }

    /// Reads .mogrt files into the library as title templates.
    public static func importMogrts(_ urls: [URL], into store: PresetStore) async -> MogrtOutcome {
        var existing = TitleTemplatePreset.names(in: await store.all())
        var out = MogrtOutcome()
        for url in urls {
            let file = url.lastPathComponent
            SQLog.info("template import start: \(url.path)")
            do {
                let result = try await Task.detached(priority: .userInitiated) { try MogrtImporter.read(url: url) }.value
                let name = result.template.name
                if existing.contains(name) { out.already += 1; continue }
                try await store.add(try TitleTemplatePreset(template: result.template, thumbnail: result.thumbnail).presetItem(name: name))
                existing.insert(name)
                out.added += 1
                out.dropped += result.droppedCount
                out.report.note(name, result.droppedCount > 0 ? .approximated : .mapped,
                                "\(result.template.slots.count) editable text \(result.template.slots.count == 1 ? "field" : "fields")")
                for e in result.report.entries where e.status != .mapped {
                    for _ in 0..<e.count { out.report.note(urls.count > 1 ? "\(name): \(e.feature)" : e.feature, e.status, e.note) }
                }
                SQLog.info("template import ok: \(name), \(result.template.slots.count) slots, \(result.droppedCount) dropped")
            } catch {
                SQLog.error("template import failed: \(file): \(error)")
                out.failures.append((file, error))
            }
        }
        return out
    }

    public struct PresetOutcome {
        public var added = 0, already = 0, skipped = 0
        public var report = PRImportReport()
        /// The mapper's own report, for the log.
        public var mapperSummary = ""

        public func statusLine(fileName: String) -> String {
            SQL10n.format("Imported %@ presets from %@", String(added), fileName)
                + (already > 0 ? SQL10n.format(", %@ already in the library", String(already)) : "")
                + (skipped == 0 ? "." : SQL10n.format(", %@ skipped.", String(skipped)))
        }
    }

    /// Reads a Premiere effect preset file (.prfpset) into the user preset library. Throws when the file cannot be read.
    public static func importPremierePresets(at url: URL, into store: PresetStore) async throws -> PresetOutcome {
        SQLog.info("premiere presets import start: \(url.path)")
        let result = try await Task.detached(priority: .userInitiated) {
            PRPresetMapper.map(try PRPresetReader.read(url: url))
        }.value
        var existing = Set(await store.all().map(\.name))
        var out = PresetOutcome()
        for p in result.presets {
            if existing.contains(p.name) { out.already += 1; continue }
            try await store.add(try EditorSession.effectPresetItem(name: p.name, preset: p.preset))
            existing.insert(p.name)
            out.added += 1
            out.report.note(p.name, p.notes.isEmpty ? .mapped : .approximated, p.notes.joined(separator: "; "))
        }
        for s in result.skipped { out.report.note(s.path, .dropped, s.reason) }
        out.skipped = result.skipped.count
        out.mapperSummary = result.report.summary
        SQLog.info("premiere presets import ok: \(out.added) added, \(out.already) already there, \(out.skipped) skipped")
        return out
    }

    /// `~/Documents/Adobe/Premiere Pro/<version>/Profile-*/Effect Presets and Custom Items.prfpset`, best first: highest
    /// version, then the most recently changed (the user's own profile over a stock one).
    public static func premierePresetFiles(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let fm = FileManager.default
        let root = home.appendingPathComponent("Documents/Adobe/Premiere Pro", isDirectory: true)
        let versions = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var found: [(version: Double, date: Date, url: URL)] = []
        for v in versions {
            guard let number = Double(v.lastPathComponent) else { continue }
            let profiles = (try? fm.contentsOfDirectory(at: v, includingPropertiesForKeys: nil)) ?? []
            for p in profiles where p.lastPathComponent.hasPrefix("Profile-") {
                let f = p.appendingPathComponent("Effect Presets and Custom Items.prfpset")
                guard let a = try? fm.attributesOfItem(atPath: f.path), let date = a[.modificationDate] as? Date else { continue }
                found.append((number, date, f))
            }
        }
        return found.sorted { ($0.version, $0.date) > ($1.version, $1.date) }.map(\.url)
    }
}
