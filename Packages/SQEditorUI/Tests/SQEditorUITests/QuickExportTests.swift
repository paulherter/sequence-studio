import Foundation
import Testing
import SQCore
import SQExport
@testable import SQEditorUI
@testable import SQInspectorUI

/// EXP-34: Quick Export decisions (folder, preset).
@MainActor @Suite struct QuickExportTests {
    private func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("sq-quick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private func model(_ target: DeliveryTarget?) -> ExportDialogModel {
        let item = ExportDialogModel.SequenceItem(name: "S", duration: Time(seconds: 10),
                                                  format: SequenceFormat(width: 1920, height: 1080, frameDuration: Time(1, 30)),
                                                  deliveryTarget: target)
        return ExportDialogModel(sequences: [item], initialPreset: nil) { _, _ in throw CancellationError() }
    }

    @Test func savedProjectExportsIntoItsExportsFolderAndCreatesIt() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Film.sqproj")
        let movies = root.appendingPathComponent("Movies")
        let dir = QuickExport.directory(projectFile: file, lastDirectory: root.path, moviesDirectory: movies)
        #expect(dir.lastPathComponent == MediaManagement.exportsFolderName)
        #expect(dir.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func unsavedProjectUsesLastFolderWhenItStillExists() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        let dir = QuickExport.directory(projectFile: nil, lastDirectory: root.path, moviesDirectory: movies)
        #expect(dir.standardizedFileURL == root.standardizedFileURL)
    }

    @Test func missingLastFolderFallsBackToMovies() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        let movies = root.appendingPathComponent("Movies")
        let gone = root.appendingPathComponent("gone").path
        #expect(QuickExport.directory(projectFile: nil, lastDirectory: gone, moviesDirectory: movies) == movies)
        #expect(QuickExport.directory(projectFile: nil, lastDirectory: nil, moviesDirectory: movies) == movies)
        #expect(QuickExport.directory(projectFile: nil, lastDirectory: nil, moviesDirectory: nil)
                == FileManager.default.temporaryDirectory)
    }

    @Test func unwritableExportsFolderFallsBackToLastFolder() throws {
        let root = try temp(); defer { try? FileManager.default.removeItem(at: root) }
        // The project's parent is a regular file, so `Exports/` cannot be created.
        let blocker = root.appendingPathComponent("blocker")
        try Data([0]).write(to: blocker)
        let file = blocker.appendingPathComponent("Film.sqproj")
        let dir = QuickExport.directory(projectFile: file, lastDirectory: root.path, moviesDirectory: nil)
        #expect(dir.standardizedFileURL == root.standardizedFileURL)
    }

    @Test func targetSequenceKeepsItsPlatformPreset() {
        let m = model(DeliveryTarget(platform: .tiktok))
        let own = m.presetID
        QuickExport.applyPreset(to: m, lastPresetID: ExportPreset.proRes.id)
        #expect(m.presetID == own)
        #expect(m.presetID == ExportPreset.preset(.tiktok, .h264).id)
        #expect(m.normalizeLoudness)
    }

    @Test func sequenceWithoutTargetUsesLastPreset() {
        let m = model(nil)
        QuickExport.applyPreset(to: m, lastPresetID: ExportPreset.proRes.id)
        #expect(m.presetID == ExportPreset.proRes.id)
    }

    @Test func unknownOrMissingLastPresetChangesNothing() {
        let m = model(nil)
        let before = m.presetID
        QuickExport.applyPreset(to: m, lastPresetID: "no-such-preset")
        #expect(m.presetID == before)
        QuickExport.applyPreset(to: m, lastPresetID: nil)
        #expect(m.presetID == before)
    }
}
