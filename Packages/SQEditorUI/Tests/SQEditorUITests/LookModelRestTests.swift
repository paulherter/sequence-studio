import Foundation
import SQCore
import SQLibrary
import SQText
import Testing
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

private let red = TextStyle(fontName: "Menlo", size: 50, weight: .bold, color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1))

@MainActor private func graphicSession() throws -> (EditorSession, GraphicsEditor, Clip.ID, UUID, UUID) {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    let ref = try TextGenerator.makeRef(template: TextTemplate(name: "t", text: "Hi", style: red), animations: nil)
    let text = GraphicsLayer.text(ref)
    let shape = GraphicsLayer.shape(.rectangle, canvasWidth: 1920, canvasHeight: 1080)
    let clip = try #require(s.addGraphicsClip(layers: [shape, text]))
    s.select(clips: [clip])
    let editor = GraphicsEditor(session: s)
    editor.sync()
    editor.select([text.id])
    return (s, editor, clip, text.id, shape.id)
}

@MainActor private func layerTemplate(_ s: EditorSession, _ clip: Clip.ID, _ layer: UUID) throws -> TextTemplate {
    let c = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clip })
    guard case .text(let ref)? = c.graphics?.layer(layer)?.content else { throw CancellationError() }
    return try TextGenerator.decode(ref).0
}

@MainActor private func setStyleSize(_ s: EditorSession, _ clip: Clip.ID, _ layer: UUID, _ size: Double) throws {
    var t = try layerTemplate(s, clip, layer)
    t.style.size = size
    let ref = try TextGenerator.makeRef(template: t, animations: nil)
    #expect(s.editGraphics(clip, name: "Edit") { $0.update(layer) { $0.content = .text(ref: ref) } })
}

@MainActor @Suite(.serialized) struct GraphicTextLookTests {
    @Test func graphicTextTakesALookWithOneUndoStepEach() throws {
        let (s, ed, clip, layer, _) = try graphicSession()
        defer { withExtendedLifetime(ed) {} }
        let store = LookStore(url: nil)
        #expect(s.lookTarget == .graphicText(clip, layer))
        #expect(s.lookState(store: store) == .none)
        var depth = s.undoDepth
        #expect(s.applyLook(LookRef(scope: .builtIn, id: "title"), store: store))
        #expect(s.undoDepth == depth + 1)
        #expect(try layerTemplate(s, clip, layer).style == LookLibrary.builtIns[0].style)
        #expect(s.lookState(store: store) == .applied("title"))

        try setStyleSize(s, clip, layer, 33)
        #expect(s.lookState(store: store) == .edited("title"))
        depth = s.undoDepth
        let saved = try #require(try s.saveLookAsNew(name: "Mine", store: store))
        #expect(s.undoDepth == depth + 1)
        #expect(s.lookState(store: store) == .applied(saved.id))

        try setStyleSize(s, clip, layer, 44)
        depth = s.undoDepth
        #expect(try s.updateLook(saved, store: store))
        #expect(s.undoDepth <= depth + 1)
        #expect(store.library.look(saved.id)?.style.size == 44)
        #expect(s.lookState(store: store) == .applied(saved.id))
    }

    @Test func aCopyOfTheClipWithTheSameLayerIdsNeverTakesTheLook() throws {
        let (s, editor, clip, layer, _) = try graphicSession()
        let store = LookStore(url: nil)
        let c = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == clip })
        let twin = try #require(s.addGraphicsClip(at: Time(30, 1), duration: Time(2, 1), layers: c.graphics?.layers ?? []))
        s.select(clips: [twin])
        #expect(s.lookTarget == nil)
        #expect(!s.applyLook(LookRef(scope: .builtIn, id: "title"), store: store))
        s.select(clips: [clip])
        editor.select([layer])
        #expect(s.lookTarget == .graphicText(clip, layer))
    }

    @Test func releasingTheEditorClearsTheLayerSelection() throws {
        let s: EditorSession
        do {
            let made = try graphicSession()
            s = made.0
            #expect(s.graphicLayerSelection != nil)
        }
        #expect(s.graphicLayerSelection == nil)
        #expect(s.lookTarget == nil)
    }

    @Test func shapeLayerOrManyLayersTakeNoLook() throws {
        let (s, editor, _, layer, shape) = try graphicSession()
        editor.select([shape])
        #expect(s.lookTarget == nil)
        editor.select([shape, layer])
        #expect(s.lookTarget == nil)
    }
}

@MainActor @Suite(.serialized) struct LookStoreNoticeTests {
    @Test func readOnlyStorePostsTheNoticeAndKeepsTheChange() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sq-looks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("looks.json")
        try Data("{\"formatVersion\": \(LookLibrary.formatVersion + 1), \"looks\": []}".utf8).write(to: url)
        let store = LookStore(url: url)
        var posted = 0
        let token = NotificationCenter.default.addObserver(forName: LookStore.writeFailed, object: store, queue: nil) { _ in posted += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        #expect(throws: LookStore.StoreError.readOnly) { try store.edit { _ = $0.add(name: "A", style: red) } }
        #expect(posted == 1)
        #expect(store.library.user.map(\.name) == ["A"])
        #expect(store.readOnlyMessage.contains(url.path) && store.readOnlyMessage.contains("cannot be saved"))
        #expect(!store.isLoaded)
        #expect(throws: LookStore.StoreError.readOnly) { try store.edit { _ = $0.add(name: "B", style: red) } }
        #expect(throws: LookStore.StoreError.readOnly) { try store.edit { _ = $0.add(name: "C", style: red) } }
        #expect(posted == 1)
    }
}

@MainActor @Suite(.serialized) struct UserLookOnCaptionsTests {
    private func session() -> EditorSession {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        s.replaceCaptions([CaptionItem(lines: ["a"], range: TimeRange(start: Time(0, 1), end: Time(1, 1)), styleRef: "default")])
        return s
    }

    /// The app's store (`LookStore.shared`) registers its Looks for caption drawing; a store without a registry (tests)
    /// does not, so a user Look cannot resolve through the caption registry there. The app path is not affected.
    @Test func aUserLookOnCaptionsResolvesWhenTheStoreRegistersIt() throws {
        let store = LookStore(url: nil, registry: .shared)
        let id = try #require(try store.edit { $0.add(name: "Mine", style: red) })
        defer { CaptionLookRegistry.shared.unregister(id: id) }
        let s = session()
        #expect(s.applyLook(LookRef(scope: .user, id: id), store: store))
        #expect(s.lookState(store: store) == .applied(id))
        let state = try #require(s.captionStyleState(scope: .all)?.style)
        #expect(state.fontName == red.fontName && state.size == red.size && state.color == red.color)
    }
}

@MainActor @Suite(.serialized) struct TextMultiSharedValuesTests {
    @Test func aMultiEditStartsFromTheSharedValuesAndKeepsTheMixedOnes() throws {
        let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .video)])
        let s = EditorSession(project: Project(name: "P", timelines: [t]))
        func style(_ font: String, _ size: Double) -> TextStyle { TextStyle(fontName: font, size: size, color: .white) }
        let a = try #require(s.addTextClip(template: TextTemplate(name: "A", text: "One", style: style("Helvetica-Bold", 80)), position: .zero))
        s.seek(to: Time(10, 1))
        let b = try #require(s.addTextClip(template: TextTemplate(name: "B", text: "Two", style: style("Georgia", 80)), position: .zero))
        s.select(clips: [a, b])
        #expect(!s.textMixedPaths.contains("style.size") && s.textMixedPaths.contains("style.fontName"))
        func template(_ id: Clip.ID) throws -> TextTemplate {
            let c = try #require(s.activeTimeline?.tracks.flatMap(\.clips).first { $0.id == id })
            return try TextGenerator.decode(try #require(c.generator)).0
        }
        let old = try template(a)
        var new = old; new.style.size = 90
        s.updateTextClips(primary: a, from: old, to: new, animations: nil, oldAnimations: nil, continuesGesture: false)
        #expect(try template(b).style.size == 90)
        #expect(try template(b).style.fontName == "Georgia")
        #expect(s.textMixedPaths.contains("style.fontName") && !s.textMixedPaths.contains("style.size"))
        // Setting the mixed field to the shown clip's own value copies it to all.
        let again = try template(a)
        s.updateTextClips(primary: a, from: again, to: again, animations: nil, oldAnimations: nil, continuesGesture: false,
                          forcing: ["style.fontName"])
        #expect(try template(b).style.fontName == "Helvetica-Bold")
        #expect(!s.textMixedPaths.contains("style.fontName"))
    }
}

@MainActor @Suite(.serialized) struct LookObserverTests {
    @Test func captionLookLibraryRemovesItsObserver() throws {
        let before = CaptionLookLibrary.liveObservers
        var lib: CaptionLookLibrary? = CaptionLookLibrary(looks: LookStore(url: nil), defaults: try #require(UserDefaults(suiteName: "sq.test.\(UUID())")))
        #expect(CaptionLookLibrary.liveObservers == before + 1)
        lib = nil
        #expect(lib == nil && CaptionLookLibrary.liveObservers == before)
    }
}

@MainActor @Suite(.serialized) struct LookCategoryTests {
    @Test func builtInsHaveCategoriesAndOldFilesRead() throws {
        #expect(LookLibrary.builtIns.allSatisfy { $0.category != nil })
        #expect(Set(LookLibrary.builtIns.compactMap(\.category)) == ["Bold", "Clean"])
        var look = Look(id: "x", name: "X", style: red)
        let plain = try JSONEncoder().encode(look)
        #expect(!String(decoding: plain, as: UTF8.self).contains("category"))
        #expect(try JSONDecoder().decode(Look.self, from: plain).category == nil)
        look.category = "Bold"
        #expect(try JSONDecoder().decode(Look.self, from: JSONEncoder().encode(look)).category == "Bold")
    }
}
