import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
import SQExport
@testable import SQDrawShell

private struct NoFrames: FrameSource {
    let frameCount = 50
    let frameDuration = Time(1, 25)
    func frame(at index: Int) async throws -> ExportFrame { throw FrameSourceError.indexOutOfRange(index) }
}

/// Writes an empty file where the queue asks (no pixels needed to test the shell flow).
private final class FakeEncoder: ExportEncoding, @unchecked Sendable {
    var written: [(URL, ExportSettings)] = []
    func export(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        try Data().write(to: url)
        written.append((url, settings))
        progress(1)
        return nil
    }
}

/// Writes its file, then waits until it is canceled (a running export).
private final class HangingEncoder: ExportEncoding, @unchecked Sendable {
    func export(video: any FrameSource, audio: (any AudioSource)?, settings: ExportSettings, to url: URL,
                progress: @escaping @Sendable (Double) -> Void) async throws -> LoudnessReport? {
        try Data([1]).write(to: url)
        progress(0.3)
        while true { try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(5)) }
    }
}

@MainActor
@Suite struct ShellExportTests {
    /// The Mac progress window's Stop confirmation: Cancel on a running export asks "Stop the export?"; Keep Exporting leaves
    /// it running, Stop Export cancels it and the partial file is gone.
    @Test func stoppingARunningExportAsksFirst() async throws {
        let h = ShellHost(session: Self.session(), map: .premiereDefault)
        var flows: [Task<Void, Never>] = []
        h.spawn = { f in flows.append(Task { @MainActor in await f() }) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-stop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let q = ExportQueue(encoder: HangingEncoder(), freeSpaceProbe: { _ in nil })
        h.exportQueue = q
        let job = ExportJob(name: "Main", settings: ExportPreset.all[0].settings, outputDirectory: dir) { ExportSources(video: NoFrames()) }
        let id = await q.enqueue(job)
        let run = Task { await q.runAll() }
        for _ in 0..<400 { if case .running? = await q.status(id)?.state { break }; try await Task.sleep(for: .milliseconds(5)) }
        let url = try #require(await q.status(id)?.outputURL)
        h.spawn { _ = await h.stopExport(id) }
        for _ in 0..<400 where h.dialog == nil { try await Task.sleep(for: .milliseconds(5)) }
        let keep = try #require(h.dialog)
        #expect(keep.messageText == "Stop the export?" && keep.informativeText == "The partial file is deleted.")
        keep.press(.first)                                       // Keep Exporting
        for t in flows { await t.value }
        if case .running? = await q.status(id)?.state {} else { Issue.record("export should still run") }
        flows = []
        h.spawn { _ = await h.stopExport(id) }
        for _ in 0..<400 where h.dialog == nil || h.dialog === keep { try await Task.sleep(for: .milliseconds(5)) }
        h.dialog?.press(.second)                                 // Stop Export
        for t in flows { await t.value }
        await run.value
        if case .cancelled? = await q.status(id)?.state {} else { Issue.record("export should be canceled") }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    static func session(inOut: Bool = false) -> EditorSession {
        let clip = Clip(name: "c", media: UUID(), kind: .video, source: TimeRange(start: .zero, duration: Time(2, 1)), start: .zero)
        var tl = Timeline(name: "Main", frameDuration: Time(1, 25), tracks: [Track(kind: .video, clips: [clip]), Track(kind: .audio)])
        if inOut { tl.inOut = TimeRange(start: Time(1, 2), duration: Time(1, 2)) }
        return EditorSession(project: Project(name: "P", timelines: [tl]))
    }

    static func model(_ s: EditorSession) -> ExportDialogModel {
        ExportDialogModel(sequences: ExportDialogModel.sequenceItems(for: s), initialPreset: nil, freeSpace: { _ in nil }) { _, _ in
            ExportSources(video: NoFrames())
        }
    }

    @Test func presetsAreTheVideoPresetsTheEncoderWrites() {
        let p = ShellExport.presets(codecs: [.h264, .hevc])
        #expect(!p.isEmpty)
        #expect(p.allSatisfy { !$0.settings.video.codec.isProRes && $0.settings.audioOnly == nil && $0.settings.frameOutput == nil })
        #expect(p.contains { $0.id == ExportPreset.youtube1080.id })
        #expect(!p.contains { $0.id == ExportPreset.proRes.id || $0.id == ExportPreset.gif.id })
    }

    @Test func fileOutputsAddTheAudioGIFAndSequencePresets() {
        let p = ShellExport.presets(codecs: [.h264, .hevc], fileOutputs: true)
        for id in [ExportPreset.audioM4A.id, ExportPreset.audioWAV.id, ExportPreset.audioFLAC.id, ExportPreset.gif.id,
                   ExportPreset.imageSequence.id] {
            #expect(p.contains { $0.id == id })
        }
        #expect(!p.contains { $0.id == ExportPreset.proRes.id })
    }

    static func sheet(_ m: ExportDialogModel, codecs: [VideoCodec] = [.h264, .hevc], fileOutputs: Bool = false) -> ShellExportSheet {
        let s = ShellExportSheet(model: m, codecs: codecs, fileOutputs: fileOutputs)
        s.layout(CGRect(x: 0, y: 0, width: 860, height: 572), measure: TextMeasure(atlas: nil, scale: 1))
        return s
    }

    static func titles(_ s: ExportSection) -> [String] { s.rows.map(\.title) }

    /// The sections and rows of the Mac sheet (`ExportDialogView.reload`), in its order; Advanced starts closed.
    @Test func sheetHasTheMacSectionsAndVideoRows() throws {
        let m = Self.model(Self.session())
        m.presetID = ExportPreset.youtube1080.id
        let sheet = Self.sheet(m)
        #expect(sheet.sections.map(\.title) == ["Video", "Audio", "Captions", "Range", "Output", "Advanced"])
        #expect(sheet.sections.map(\.defaultOpen) == [true, true, true, true, true, false])
        let video = try #require(sheet.sections.first)
        #expect(Self.titles(video).prefix(5) == ["Codec", "Profile", "Size", "Frame Rate", "Rate Control"])
        #expect(Self.titles(video).contains("Encoder Speed"))
        #expect(Self.titles(video).last == "Color Space")
        let output = try #require(sheet.sections.first { $0.title == "Output" })
        #expect(Self.titles(output) == ["File Name", "Folder"])
        let range = try #require(sheet.sections.first { $0.title == "Range" })
        #expect(Self.titles(range).first == "Range")
        #expect(Self.titles(range).contains("Duration"))
    }

    /// Rows edit the model: the codec popup lists only what the encoder writes, Custom size adds the size fields.
    @Test func sheetRowsEditTheModel() throws {
        let m = Self.model(Self.session())
        m.presetID = ExportPreset.youtube1080.id
        let sheet = Self.sheet(m)
        let codec = try #require(sheet.sections[0].rows.first { $0.title == "Codec" }?.items.first)
        guard case .popup(let names, _, _) = codec.kind else { Issue.record("codec is no popup"); return }
        #expect(names == ["H.264", "HEVC"])
        codec.action?(.index(1))
        #expect(m.codec == .hevc)
        #expect(sheet.sections[0].rows.contains { $0.title == "Color Space" })
        let size = try #require(sheet.sections[0].rows.first { $0.title == "Size" }?.items.first)
        guard case .popup(let sizes, _, _) = size.kind else { Issue.record("size is no popup"); return }
        size.action?(.index(sizes.count - 1))
        #expect(sheet.sections[0].rows.contains { $0.title == "Custom Size" })
        let audio = try #require(sheet.sections.first { $0.title == "Audio" })
        let include = try #require(audio.rows.first { $0.title == "Include Audio" }?.items.first)
        include.action?(.bool(false))
        #expect(!m.settings.audio.enabled)
    }

    /// Audio-only and image-sequence outputs drop the sections the Mac sheet drops.
    @Test func sheetSectionsFollowTheOutputKind() {
        let m = Self.model(Self.session())
        m.presetID = ExportPreset.audioWAV.id
        var sheet = Self.sheet(m, fileOutputs: true)
        #expect(!sheet.sections.contains { $0.title == "Video" })
        m.presetID = ExportPreset.imageSequence.id
        sheet = Self.sheet(m, fileOutputs: true)
        #expect(!sheet.sections.contains { $0.title == "Audio" })
        #expect(sheet.sections.first.map(Self.titles)?.first == "Image Format")
    }

    @Test func stemRowsNeedStemPlans() {
        let m = Self.model(Self.session())
        func hasStems() -> Bool {
            Self.sheet(m).sections.first { $0.title == "Audio" }?.rows.contains { $0.title == "Stems" } ?? false
        }
        #expect(!hasStems())
        var tl = Timeline(name: "T", frameDuration: Time(1, 25), tracks: [])
        let c = Clip(name: "c", media: UUID(), kind: .audio, source: TimeRange(start: .zero, duration: Time(1, 1)), start: .zero)
        var d = Track(kind: .audio, clips: [c]); d.audioRole = .dialogue
        var mu = Track(kind: .audio, clips: [c]); mu.audioRole = .music
        tl.tracks = [d, mu]
        m.stemPlans = [m.selectedID: StemPlan.stems(for: tl)]
        m.stemAudio = { _, _, _ in throw CancellationError() }
        #expect(hasStems())
    }

    @Test func rangeChoicesFollowTheSequence() {
        #expect(ShellExport.ranges(Self.model(Self.session())).map(\.mode) == [0])
        let m = Self.model(Self.session(inOut: true))
        #expect(ShellExport.ranges(m).map(\.mode) == [0, 1])
        #expect(m.rangeMode == 1)   // Premiere: with In/Out set the export covers that range
    }

    @Test func statusLines() {
        #expect(ShellExport.statusLine(name: "Main", state: .running, progress: 0.426) == "Exporting “Main”: 42%")
        #expect(ShellExport.statusLine(name: "Main", state: .failed("disk full"), progress: 0) == "Export of “Main” failed: disk full")
    }

    @Test func exportFlowQueuesTheJobAndReportsTheFile() async throws {
        let s = Self.session()
        let h = ShellHost(session: s, map: .premiereDefault)
        var flows: [@MainActor () async -> Void] = []
        h.spawn = { flows.append($0) }
        h.size = CGSize(width: 1000, height: 700)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = FakeEncoder()
        h.exportQueue = ExportQueue(encoder: encoder, freeSpaceProbe: { _ in nil })
        h.exportSources = { _, _ in ExportSources(video: NoFrames()) }
        h.exportDirectory = dir
        var lines: [String] = []
        h.onStatus = { lines.append($0) }
        #expect(h.execute(.export))
        let flow = Task { @MainActor in await flows[0]() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        let d = try #require(h.dialog)
        #expect(d.messageText == "Export")
        #expect(d.content is ShellExportSheet)
        #expect((d.content as? ShellExportSheet)?.model.outputDirectory == dir)
        d.press(.first)
        await flow.value
        #expect(encoder.written.count == 1)
        // Compared by component: on Windows the parent URL keeps a trailing slash the folder URL lacks.
        #expect(encoder.written.first?.0.deletingLastPathComponent().standardizedFileURL.pathComponents
                == dir.standardizedFileURL.pathComponents)
        #expect(lines.last == "Exported “\(encoder.written.first?.0.lastPathComponent ?? "")”")
    }

    /// ExportCoordinator.preflightAndSubmit: a file already in the folder asks Keep Both / Replace / Cancel; Cancel brings the
    /// sheet back over the same settings, Replace writes under the same name.
    @Test func existingFileAsksAndCancelReopensTheSheet() async throws {
        let s = Self.session()
        let h = ShellHost(session: s, map: .premiereDefault)
        var flows: [@MainActor () async -> Void] = []
        h.spawn = { flows.append($0) }
        h.size = CGSize(width: 1000, height: 700)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-shell-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let encoder = FakeEncoder()
        h.exportQueue = ExportQueue(encoder: encoder, freeSpaceProbe: { _ in nil })
        h.exportSources = { _, _ in ExportSources(video: NoFrames()) }
        h.exportDirectory = dir
        #expect(h.execute(.export))
        let flow = Task { @MainActor in await flows[0]() }
        func nextDialog(after old: ShellDialog?) async -> ShellDialog? {
            for _ in 0..<400 where h.dialog == nil || h.dialog === old { try? await Task.sleep(for: .milliseconds(5)) }
            return h.dialog
        }
        let sheetDialog = try #require(await nextDialog(after: nil))
        let model = try #require((sheetDialog.content as? ShellExportSheet)?.model)
        let job = try #require(model.buildJobs(outputDirectory: dir).first)
        try Data([1]).write(to: dir.appendingPathComponent("\(job.name).\(job.settings.fileExtension)"))
        sheetDialog.press(.first)
        let question = try #require(await nextDialog(after: sheetDialog))
        #expect(question.messageText.hasSuffix("already exists in this folder"))
        question.press(.third)                                   // Cancel
        let again = try #require(await nextDialog(after: question))
        #expect((again.content as? ShellExportSheet)?.model === model)
        #expect(encoder.written.isEmpty)
        again.press(.first)
        let second = try #require(await nextDialog(after: again))
        second.press(.second)                                    // Replace
        await flow.value
        #expect(encoder.written.count == 1)
        #expect(encoder.written.first?.0.lastPathComponent == "\(job.name).\(job.settings.fileExtension)")
    }

    /// The Mac sheet keeps Export disabled while something is invalid: the press does nothing and the sheet stays.
    @Test func invalidSizeKeepsTheDialogOpen() async throws {
        let h = ShellHost(session: Self.session(), map: .premiereDefault)
        var flows: [@MainActor () async -> Void] = []
        h.spawn = { flows.append($0) }
        h.exportQueue = ExportQueue(encoder: FakeEncoder(), freeSpaceProbe: { _ in nil })
        h.exportSources = { _, _ in ExportSources(video: NoFrames()) }
        h.execute(.export)
        let flow = Task { @MainActor in await flows[0]() }
        for _ in 0..<200 where h.dialog == nil { await Task.yield() }
        let d = try #require(h.dialog)
        let sheet = try #require(d.content as? ShellExportSheet)
        sheet.model.width = 1279
        #expect(!d.isEnabled(0))
        d.press(.first)
        #expect(h.dialog === d)
        #expect(sheet.model.validationMessages.first == "Width and height must be even numbers greater than 0.")
        d.press(.second)
        await flow.value
        #expect(h.dialog == nil)
    }
}

#if canImport(CoreVideo)
import CoreVideo

/// 10 frames of a 4 x 2 BGRA buffer.
private struct TenFrames: FrameSource {
    let frameCount = 10
    let frameDuration = Time(1, 25)
    func frame(at index: Int) async throws -> ExportFrame {
        var b: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 2, kCVPixelFormatType_32BGRA, nil, &b)
        guard let b else { throw FrameSourceError.bufferCreationFailed(0) }
        return b
    }
}

@MainActor
@Suite struct ShellExportPreviewTests {
    /// `ExportPreviewModel` on the canvas: the sheet loads the model's preview source, shows its frame in image slot 1 at
    /// the output's aspect, scrubs and steps; without a source or a frame conversion it keeps "No preview available".
    @Test func sheetShowsThePreviewFrameAndStepsIt() async throws {
        let m = ShellExportTests.model(ShellExportTests.session())
        let none = ShellExportSheet(model: m, codecs: [.h264], fileOutputs: false)
        #expect(none.preview.note == "No preview available")
        m.previewSource = { _, settings in
            #expect(settings.audio.enabled == false && max(settings.video.width, settings.video.height) <= 640)
            return TenFrames()
        }
        let s = ShellExportSheet(model: m, codecs: [.h264], fileOutputs: false)
        s.preview.frameImage = { _ in RGBAImage(width: 4, height: 2, fill: .white) }
        s.rebuild()
        for _ in 0..<200 where s.preview.image == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(s.preview.image?.width == 4 && s.preview.frameCount == 10)
        #expect(s.preview.note == nil && s.preview.timecode.hasSuffix(":00"))
        s.layout(CGRect(x: 0, y: 0, width: 860, height: 572), measure: TextMeasure(atlas: nil, scale: 1))
        _ = s.handle(.keyDown(.right, modifiers: []), scale: 1)
        for _ in 0..<200 where s.preview.currentIndex != 1 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(s.preview.currentIndex == 1 && s.preview.timecode.hasSuffix(":01"))
        let bar = s.scrubFrame
        _ = s.handle(.mouseDown(x: Float(bar.maxX - 8), y: Float(bar.midY), modifiers: []), scale: 1)
        _ = s.handle(.mouseUp(x: Float(bar.maxX - 8), y: Float(bar.midY)), scale: 1)
        #expect(s.preview.fraction == 1)
        var c = Canvas(width: 860, height: 572, atlas: nil, scale: 1)
        s.draw(&c, theme: DrawTheme())
        #expect(c.list.quads.contains { $0.kind == DrawQuad.Kind.image.rawValue && Int($0.pad) == ShellExportPreview.slot })
        // 16:9 output in the 288 x 204 box: full width, centered.
        let pic = ExportPreviewMath.pictureRect(box: CGRect(x: 0, y: 0, width: 288, height: 204), width: 1920, height: 1080)
        #expect(pic.width == 288 && pic.height == 162 && pic.minY == 21)
        s.preview.close()
    }

    /// The source is ready but its first frame still renders (off the main thread on Windows): the box keeps saying
    /// "Loading preview…" instead of going blank, until the picture arrives.
    @Test func firstFrameKeepsTheLoadingNoteUntilItArrives() async throws {
        let gate = Gate()
        let m = ShellExportTests.model(ShellExportTests.session())
        m.previewSource = { _, _ in SlowFrames(gate: gate) }
        let s = ShellExportSheet(model: m, codecs: [.h264], fileOutputs: false)
        s.preview.frameImage = { _ in RGBAImage(width: 4, height: 2, fill: .white) }
        s.rebuild()
        for _ in 0..<200 where s.preview.frameCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(s.preview.frameCount == 10 && s.preview.image == nil)
        #expect(s.preview.note == "Loading preview\u{2026}")
        gate.open()
        for _ in 0..<200 where s.preview.image == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(s.preview.image != nil && s.preview.note == nil)
        s.preview.close()
    }
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.lock(); isOpen = true; lock.unlock() }
    var opened: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
}

/// `TenFrames` whose frames wait for the gate.
private struct SlowFrames: FrameSource {
    let gate: Gate
    let frameCount = 10
    let frameDuration = Time(1, 25)
    func frame(at index: Int) async throws -> ExportFrame {
        while !gate.opened { try await Task.sleep(for: .milliseconds(5)) }
        return try await TenFrames().frame(at: index)
    }
}
#endif
