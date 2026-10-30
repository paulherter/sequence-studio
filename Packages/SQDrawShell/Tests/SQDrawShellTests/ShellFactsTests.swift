import Foundation
import Testing
import SQCore
import SQUIKit
import SQDrawKit
import SQEditorSession
@testable import SQDrawShell

/// The facts the menu rules read are derived by the shell and filled by the host pieces, so a row enables like the Mac's
/// `commandEnabled` / `validateMenuItem`.
@MainActor
@Suite struct ShellFactsTests {
    func host() -> (ShellHost, Clip) { ShellMainMenuWalkTests.host(.premiereDefault) }

    @Test func aProviderFillsTheFactsItOwns() {
        let (h, _) = host()
        h.focus = .graphics
        #expect(h.menuEnabled(.delete) == true)                      // not reported: stays enabled
        h.factProviders.append { $0.graphicsHasSelection = false; $0.graphicsHasLayers = false }
        #expect(!h.menuEnabled(.delete))
        #expect(!h.menuEnabled(.selectAll))
        h.factProviders.append { $0.graphicsHasSelection = true }
        #expect(h.menuEnabled(.delete))
    }

    @Test func gradeCopyAndPasteComeFromTheColorPanels() {
        let (h, _) = host()
        h.focus = .colorInspector
        h.factProviders.append { $0.canCopyGrade = true; $0.canPasteGrade = false }
        #expect(h.menuEnabled(.copy))
        #expect(!h.menuEnabled(.paste))
    }

    @Test func controlsFactsGateTheGraphEditorAndEase() {
        let (h, _) = host()
        #expect(!h.enabled(.toggleGraphEditor))
        h.factProviders.append { $0.effectControlsClip = true; $0.effectSelectionEmpty = false }
        #expect(h.enabled(.toggleGraphEditor))
        #expect(h.enabled(.easyEase))                                // a selected property accepts the ease
    }

    @Test func anglesAndVoiceOverAreReadFromTheSession() {
        let (h, _) = host()
        #expect(!h.currentFacts().hasAnglesClip)
        #expect(!h.enabled(.switchAngle(1)))
        #expect(h.currentFacts().recordingVoiceOver == false)
    }

    @Test func projectSelectionDrivesPlaceFillReelAndSubclip() throws {
        let (list, _, h) = ProjectListViewTests().view()
        h.panels.panelsLoaded = true
        h.focus = .project
        #expect(!h.enabled(.insert))
        #expect(!h.enabled(.makeSubclip))
        let seq = try #require(h.session.project.timelines.first?.id)
        list.selection = [.sequence(seq)]
        let f = h.currentFacts()
        #expect(f.projectSelectedSequences == 1)
        #expect(f.projectSelectedMedia == 0)
        #expect(f.canPlaceSource)                                    // a selected sequence nests
        #expect(h.enabled(.insert))
        #expect(!h.enabled(.makeSubclip))                            // needs one media item
        let media = MediaRef(name: "a.mov", path: "/nonexistent/a.mov", fingerprint: MediaFingerprint(size: 1), duration: Time(2, 1))
        h.session.perform("Add Media") { $0.media.append(media) }
        list.selection = [.media(media.id)]
        #expect(h.currentFacts().projectSelectedMedia == 1)
        #expect(h.enabled(.makeSubclip))
        #expect(h.enabled(.placeOnTop))
        #expect(h.enabled(.editOriginal))                            // Project focus: the selected item's file
        list.selection = []
        #expect(!h.enabled(.editOriginal))
    }
}

/// The Mac `validateMenuItem` rules for a typing text field and for Effect Controls.
@MainActor
@Suite struct ShellTextAndControlsRulesTests {
    func host(_ focus: PanelID?) -> (ShellHost, Clip) {
        let (h, clip) = ShellMainMenuWalkTests.host(.premiereDefault)
        h.focus = focus
        return (h, clip)
    }

    @Test func aTypingFieldTakesTheTextVerbsAndUndoAndRedo() {
        let (h, _) = host(.timeline)
        #expect(!h.menuEnabled(.undo))                               // nothing to undo
        #expect(!h.menuEnabled(.redo))
        h.factProviders.append { $0.textEditing = true }
        for c in [EditorCommand.cut, .copy, .paste, .delete, .selectAll, .undo, .redo, .deleteProjectItems] { #expect(h.menuEnabled(c), "\(c)") }
        for c in [EditorCommand.find, .setPosterFrame, .clearPosterFrame, .toggleHoverScrub] { #expect(!h.menuEnabled(c), "\(c)") }
    }

    @Test func panelOnlyCommandShortcutsAreOffWhileTyping() {
        let (h, clip) = host(.timeline)
        h.session.select(clips: [clip.id])
        let blocked = [EditorCommand.addEdit, .link, .speedDuration, .deselectAll, .nudgeLeft]
        for c in blocked { #expect(MenuKeys.blockedWhileTyping(c, h.map)) }
        let before = blocked.map(h.menuEnabled)
        #expect(before.contains(true))
        h.factProviders.append { $0.textEditing = true }
        for c in blocked { #expect(!h.menuEnabled(c), "\(c)") }
        #expect(h.menuEnabled(.save))
    }

    @Test func undoEnablesAfterAnEdit() {
        let (h, clip) = host(.timeline)
        h.session.select(clips: [clip.id])
        h.session.perform("Test") { $0.name = "Changed" }
        #expect(h.menuEnabled(.undo))
    }

    @Test func effectControlsTakeCopyCutPasteWhenTheyHaveSomethingToDo() {
        let (h, _) = host(.effectControls)
        #expect(!h.menuEnabled(.paste))                              // no clip data: the timeline rules say no
        h.factProviders.append { $0.effectCanCut = true; $0.effectCanCopy = true; $0.effectCanPaste = true }
        #expect(h.menuEnabled(.cut)); #expect(h.menuEnabled(.copy)); #expect(h.menuEnabled(.paste))
        let (other, _) = host(.timeline)
        other.factProviders.append { $0.effectCanPaste = true }
        #expect(!other.menuEnabled(.paste))                          // only while Controls has the focus
    }

    @Test func deleteInControlsFollowsTheSelectionNotTheTimeline() {
        let (h, clip) = host(.effectControls)
        h.session.select(clips: [clip.id])
        h.factProviders.append { $0.effectCanDelete = false }
        #expect(!h.menuEnabled(.delete))
        #expect(!h.menuEnabled(.rippleDelete))
        h.factProviders.append { $0.effectCanDelete = true }
        #expect(h.menuEnabled(.delete))
    }
}
