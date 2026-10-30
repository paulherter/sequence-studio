import Foundation
import SQCore
import SQUIKit
import SQEditorSession

/// The File > Project, Sequence > Format and New > Layer rows the Mac `AppController` runs from its own selectors
/// (AppController+Shapes, +ProjectColor, +StyleKit, +Relink, +ImportChecklist, SequenceSettingsSheet, PixelAspectMenuTarget), translated to session calls the shell can make on any platform.
extension ShellHost {
    /// True when the row was handled here.
    func performProject(_ a: ShellAction) -> Bool {
        switch a {
        case .projectInputColor(let space):
            session.setProjectInputColorSpace(space)
        case .collectFiles:
            spawn { await self.collectFiles() }
        case .outsideMedia(let mode):
            changeMediaPolicy { $0.outside = mode }
            let text: String
            switch mode {
            case .ask: text = "Files from outside the project folder: ask."
            case .copy: text = "Files from outside the project folder: copy into project."
            case .move: text = "Files from outside the project folder: move into project."
            case .leave: text = "Files from outside the project folder: leave where it is."
            }
            flash(text)
        case .toggleCopyLibraryItems:
            let on = !(session.project.mediaPolicy?.copyLibraryItems ?? MediaSettings.defaults.copyLibraryItems)
            changeMediaPolicy { $0.copyLibraryItems = on }
        case .toggleWatchFolder:
            // shortcut: stores the choice only; the shared UI has no folder watcher yet (SharedUIController+Collect),
            // upgrade when it gets one (restart it here like `MediaMenuTarget.toggleWatch`).
            let on = !(session.project.mediaPolicy?.watchFolder ?? false)
            changeMediaPolicy { $0.watchFolder = on }
        case .newAdjustmentLayer:
            guard session.activeTimeline != nil else { flash("Open a sequence first."); return true }
            session.stopPlayback()
            if session.addAdjustmentLayer() == nil { flash(session.lastError ?? "Could not add the adjustment layer.") }
            else { session.seek(to: session.playhead) }
        case .newGraphicsClip:
            guard session.activeTimeline != nil else { flash("Open a sequence first."); return true }
            session.stopPlayback()
            if session.addGraphicsClip() == nil { flash(session.lastError ?? "Could not add the graphic.") }
            else { session.seek(to: session.playhead); dock.show(.graphics) }
        case .newShape(let kind):
            guard let tl = session.activeTimeline else { flash("Open a sequence first."); return true }
            if let onNewShape { onNewShape(kind); return true }
            // Hosts without the Create tool: a new Graphic with the kind's default box.
            session.stopPlayback()
            let layer = GraphicsLayer.shape(kind, canvasWidth: tl.format.width, canvasHeight: tl.format.height)
            let seconds = Int64(AppSettings.load().defaultTextSeconds)
            if session.addGraphicsClip(duration: Time(seconds, 1), layers: [layer], neverOverwrite: true) == nil {
                flash(session.lastError ?? "Could not add the graphic.")
            } else { session.seek(to: session.playhead) }
        case .useKitCaptionStyle:
            if !session.useKitCaptionStyle() { flash("This project's style kit has no caption style. Import a style kit that has one.") }
        case .exportStyleKit:
            spawn { await self.exportStyleKit() }
        case .importStyleKit:
            spawn { await self.importStyleKit() }
        case .relinkMedia where !session.canRelink:
            flash("All media is online.")
        case .relinkMedia:
            spawn { await self.relinkMedia() }
        case .importChecklist:
            spawn { await self.showImportChecklist() }
        case .changeFormat:
            spawn { await self.changeFormat(duplicate: false) }
        case .duplicateAsFormat:
            spawn { await self.changeFormat(duplicate: true) }
        case .newSequenceFromTemplate:
            spawn { await self.newSequenceFromTemplate() }
        case .saveSequenceAsTemplate:
            spawn { await self.saveSequenceAsTemplate() }
        case .pixelAspect(let a):
            setSelectionPixelAspect(a)
        case .customPixelAspect:
            spawn { await self.customSelectionPixelAspect() }
        default:
            return false
        }
        return true
    }

    func exportStyleKit() async {
        guard let url = await files?.chooseStyleKit(save: true, suggestedName: "\(session.displayName).\(StyleKitFile.fileExtension)")
        else { return }
        do { try session.exportStyleKit(to: url) } catch {
            onStatus?(SQL10n.format("Could not export the style kit: %@", SQL10n.errorText(error)))
        }
    }

    func importStyleKit() async {
        guard let url = await files?.chooseStyleKit(save: false, suggestedName: "") else { return }
        do {
            let r = try session.importStyleKit(from: url)
            var lines: [String] = []
            if !r.addedTokens.isEmpty { lines.append("Added: \(r.addedTokens.joined(separator: ", "))") }
            if !r.addedLooks.isEmpty { lines.append("Looks: \(r.addedLooks.joined(separator: ", "))") }
            if !r.keptTokens.isEmpty { lines.append("Kept yours: \(r.keptTokens.joined(separator: ", "))") }
            let d = ShellDialog(SQL10n.string(r.isEmpty ? "Nothing new in this style kit" : "Style kit imported"),
                                informative: lines.joined(separator: "\n"))
            d.addButton("OK")
            _ = await ask(d)
        } catch {
            onStatus?(SQL10n.format("Could not import “%@”: %@", url.lastPathComponent, SQL10n.errorText(error)))
        }
    }

    /// The Mac `validateMenuItem` facts of the shell rows.
    /// `MediaMenuTarget.change`: one undo step "Change Media Setting"; an empty policy is stored as nil.
    func changeMediaPolicy(_ edit: @escaping (inout MediaPolicy) -> Void) {
        session.perform("Change Media Setting") { p in
            var policy = p.mediaPolicy ?? MediaPolicy()
            edit(&policy)
            p.mediaPolicy = policy.isEmpty ? nil : policy
        }
    }

    func fillProjectState(_ s: inout ShellMenuState) {
        let d = MediaSettings.defaults
        s.outsideMedia = MediaManagement.outsideMode(of: session.project, defaults: d)
        s.copyLibraryItems = session.project.mediaPolicy?.copyLibraryItems ?? d.copyLibraryItems
        s.watchFolder = session.project.mediaPolicy?.watchFolder ?? false
        s.inProjectFolder = MediaManagement.projectFolder(forProjectAt: session.fileURL) != nil
        s.projectInputColor = session.project.inputColorSpace
        s.hasSequence = session.activeTimeline != nil
        s.canRelink = session.canRelink
        s.hasImportChecklist = importChecklist != nil
        s.pixelAspect = pixelAspectRows()
        s.canRenameWorkspace = dock.store.canRenameOrDeleteCurrent
        s.canResetWorkspace = dock.store.canResetCurrent
        s.checkedCommands = viewChecks().union(menuChecks.reduce(into: Set<EditorCommand>()) { $0.formUnion($1()) })
    }
}

extension ShellFilePicker {
    /// Default of the protocol requirement: not offered (nil).
    public func chooseStyleKit(save: Bool, suggestedName: String) async -> URL? { nil }
}
