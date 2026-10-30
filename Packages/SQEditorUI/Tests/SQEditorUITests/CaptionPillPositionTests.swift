import AppKit
import Foundation
import Testing
import SQCore
import SQText
import SQTranscribe
@testable import SQEditorSession
@testable import SQEditorUI
@testable import SQInspectorUI

@MainActor private func makeSession(_ items: [CaptionItem]) -> EditorSession {
    let t = Timeline(name: "Main", frameDuration: Time(1, 30), tracks: [Track(kind: .video), Track(kind: .audio)])
    let s = EditorSession(project: Project(name: "P", timelines: [t]))
    s.replaceCaptions(items)
    return s
}

private func item(_ text: String, _ a: Int64, _ b: Int64, style: String = "default") -> CaptionItem {
    CaptionItem(lines: [text], range: TimeRange(start: Time(a, 1), end: Time(b, 1)), styleRef: style)
}

private final class TwoWords: TranscriptionService, @unchecked Sendable {
    func transcribe(url: URL, locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        Transcript(language: "en-US", words: [
            TranscriptWord(text: "Hello", range: TimeRange(start: .zero, end: Time(1, 2))),
            TranscriptWord(text: "world", range: TimeRange(start: Time(1, 2), end: Time(1, 1))),
        ])
    }
}

/// FB-Y: the pill is one control group (on/off, color, size, corners) that always edits what is drawn, and the caption
/// position (top/middle/bottom, left/center/right, free offset) lives in the project's style kit.
@MainActor @Suite(.serialized) struct CaptionPillPositionTests {
    let lib = CaptionPresetLibrary.builtIn

    // MARK: Pill, all captions

    /// The bug: on the pill look, the padding fields did nothing until the pill was switched off and on again.
    @Test func pillLookSizeEditsTheDrawnPill() throws {
        var kit = CaptionStyleEdit.apply(.look(CaptionPill.styleID), to: StyleKit())
        #expect(kit.caption?.usesPill == true)
        let before = try #require(kit.captionStyle(base: lib)?.background)
        kit = CaptionStyleEdit.apply(.pillSize(0.8), to: kit)
        let style = try #require(kit.captionStyle(base: lib))
        let after = try #require(style.background)
        #expect(after.padding.horizontal == (style.size * 0.8).rounded())
        #expect(after.padding.horizontal > before.padding.horizontal)
        #expect(after.padding.vertical == (style.size * 0.8 * CaptionStyleEdit.pillAspect).rounded())
    }

    @Test func pillOffKeepsTheLookAndOnBringsTheSamePillBack() throws {
        var kit = CaptionStyleEdit.apply(.look(CaptionPill.styleID), to: StyleKit())
        kit = CaptionStyleEdit.apply(.pillSize(0.6), to: kit)
        let on = try #require(kit.captionStyle(base: lib))
        kit = CaptionStyleEdit.apply(.pill(nil), to: kit)
        let off = try #require(kit.captionStyle(base: lib))
        #expect(off.background == nil)
        #expect(kit.caption?.baseStyle == CaptionPill.styleID)                 // no jump to another look
        #expect(off.size == on.size && off.weight == on.weight)
        kit = CaptionStyleEdit.apply(.pill(CaptionPill.color), to: kit)
        #expect(kit.captionStyle(base: lib)?.background?.padding == on.background?.padding)
    }

    @Test func pillOffOnABoldBoxKeepsBoldBox() throws {
        var kit = CaptionStyleEdit.apply(.look("bold-box"), to: StyleKit())
        kit = CaptionStyleEdit.apply(.pill(nil), to: kit)
        #expect(kit.caption?.baseStyle == "bold-box")
        #expect(kit.captionStyle(base: lib)?.background == nil)
    }

    @Test func sizeOrCornersOnAPlainLookTurnThePillOn() throws {
        var kit = CaptionStyleEdit.apply(.look("default"), to: StyleKit())
        #expect(kit.captionStyle(base: lib)?.background == nil)
        kit = CaptionStyleEdit.apply(.pillCorners(8), to: kit)
        let s = try #require(kit.captionStyle(base: lib)?.background)
        #expect(s.cornerRadius == 8)
        kit = CaptionStyleEdit.apply(.pillCorners(nil), to: kit)
        #expect(kit.captionStyle(base: lib)?.background?.cornerRadius == 10_000)
    }

    // MARK: Pill, selected captions

    @Test func selectedScopeSizeAndCornersEditTheOwnStyle() throws {
        let style = lib.style(for: "default")
        let sized = CaptionStyleEdit.apply(.pillSize(0.5), to: style, library: lib)
        let bg = try #require(sized.background)
        #expect(bg.padding.horizontal == (style.size * 0.5).rounded())
        let cornered = CaptionStyleEdit.apply(.pillCorners(4), to: sized, library: lib)
        #expect(cornered.background?.cornerRadius == 4 && cornered.background?.padding == bg.padding)
    }

    @Test func stateReportsPillSizeAndCorners() throws {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        #expect(s.editCaptionStyle(.look(CaptionPill.styleID), scope: .all))
        #expect(s.editCaptionStyle(.pillSize(0.7), scope: .all))
        #expect(s.editCaptionStyle(.pillCorners(12), scope: .all))
        let st = try #require(s.captionStyleState(scope: .all))
        #expect(st.hasPill)
        #expect(st.pillSize == 0.7)
        #expect(st.pillCorners == 12)
    }

    // MARK: Position

    @Test func positionIsOneUndoStepInTheKit() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1, style: "outline")])
        let depth = s.undoDepth
        let p = CaptionPosition(vertical: .top, horizontal: .left)
        s.setCaptionPosition(p)
        #expect(s.undoDepth == depth + 1)
        #expect(s.project.styleKit?.captionPosition == p)
        #expect(s.captionPosition == p)
        #expect(s.captionItems.allSatisfy { $0.styleRef == "outline" })       // the look is not touched
        #expect(CaptionLookRegistry.shared.library(for: s.project.styleKit).position == p)
        // offset drag: one gesture, one step
        s.setCaptionPosition(CaptionPosition(vertical: .top, horizontal: .left, offsetX: 0.01))
        s.setCaptionPosition(CaptionPosition(vertical: .top, horizontal: .left, offsetX: 0.02), continuesGesture: true)
        #expect(s.undoDepth == depth + 2)
        s.setCaptionPosition(.default)
        #expect(s.project.styleKit?.captionPosition == nil)
        s.undo()
        #expect(s.captionPosition.offsetX == 0.02)
    }

    // MARK: View

    @Test func backgroundSectionOfTheSharedInspectorEditsThePill() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let view = CaptionStyleTabView()
        view.session = s
        let m = view.inspectorModel
        #expect(m.style.background == nil)
        m.setBackgroundEnabled(true)
        #expect(s.captionStyleState(scope: .all)?.hasPill == true)
        let size = m.style.size
        m.setBackgroundPadding(horizontal: size * 0.9, vertical: size * 0.3)
        #expect(abs((s.captionStyleState(scope: .all)?.pillSize ?? 0) - 0.9) < 0.01)
        m.setBackgroundRadius(12)
        #expect(s.captionStyleState(scope: .all)?.pillCorners == 12)
        m.setBackgroundRadius(10_000)
        #expect(s.captionStyleState(scope: .all)?.pillCorners == nil)            // fully round
        m.setBackgroundEnabled(false)
        #expect(s.captionStyleState(scope: .all)?.hasPill == false)
    }

    @Test func positionControlsEditTheKitPosition() {
        defer { CaptionLookRegistry.shared.setStyleKit(nil) }
        let s = makeSession([item("a", 0, 1)])
        let view = CaptionStyleTabView()
        view.session = s
        #expect(view.verticalControl.selectedSegment == 2 && view.horizontalControl.selectedSegment == 1)
        view.verticalControl.selectedSegment = 0
        view.verticalControl.sendAction(view.verticalControl.action, to: view.verticalControl.target)
        view.horizontalControl.selectedSegment = 2
        view.horizontalControl.sendAction(view.horizontalControl.action, to: view.horizontalControl.target)
        view.offsetYField.onBegin?()
        view.offsetYField.value = -10
        view.offsetYField.onChange?(-10)
        view.offsetYField.onEnd?(-10)
        #expect(s.captionPosition == CaptionPosition(vertical: .top, horizontal: .right, offsetY: 0.1))   // Offset Y is shown up: -10 shown = 0.1 stored (down)
        view.refresh()
        #expect(view.offsetYField.value == -10)
    }

    // MARK: Transcript edit mode

    @Test func transcriptShowsItsEditModeAndEscLeavesIt() async throws {
        let m = CaptionsPanelModel(service: TwoWords())
        m.sourceURL = URL(fileURLWithPath: "/tmp/a.wav")
        let view = CaptionsPanelView(model: m)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 480), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        m.transcribe(); await m.waitForTranscription()
        let deadline = ContinuousClock.now + .seconds(5)
        while view.transcriptTextView.string.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!view.isInEditMode)
        #expect(view.transcriptScroll.layer?.borderWidth ?? 0 == 0)
        view.beginEditingWord(atCharacter: 1)
        #expect(view.isInEditMode)
        #expect(view.transcriptTextView.isEditable)
        #expect((view.transcriptScroll.layer?.borderWidth ?? 0) >= 2)
        #expect(view.transcriptTextView.backgroundColor != Theme.Colors.content)
        _ = view.textView(view.transcriptTextView, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        #expect(!view.isInEditMode)
        #expect(view.transcriptScroll.layer?.borderWidth ?? 0 == 0)
        #expect(view.transcriptTextView.backgroundColor == Theme.Colors.content)
    }
}
