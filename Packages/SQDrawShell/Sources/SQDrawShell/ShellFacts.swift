import Foundation
import SQCore
import SQUIKit
import SQEditorSession

extension ShellHost {
    /// The facts the menu rules read, as the Mac `AppController.commandEnabled` reads them from its panels: what the shell
    /// itself knows (session, Project list, focus) is derived here, so every host shows the same rows; what only a panel
    /// knows (Controls clip, Graphics selection, grade copy and paste) comes from `factProviders`. A fact nobody reports
    /// keeps the value in `panels`.
    public func currentFacts() -> ShellPanelFacts {
        var p = panels
        p.hasAnglesClip = session.activeTimeline?.tracks.contains { $0.clips.contains(where: \.isAnglesClip) } ?? false
        #if !os(Windows)
        p.recordingVoiceOver = session.voiceRecorder.isBusy       // no voice recorder on Windows yet
        #endif
        if let list = projectList {
            var media: [MediaRef.ID] = [], sequences = 0
            for ref in list.selection {
                if case .media(let id) = ref { media.append(id) } else if case .sequence = ref { sequences += 1 }
            }
            p.projectSelectedMedia = media.count
            p.projectSelectedSequences = sequences
            p.fillReelEnabled = session.reelSlotCount > 0 && !media.isEmpty
            // Edit Original: the Project selection when it has focus, else the selected clips' files, else the Source clip.
            if focus == .project {
                p.editOriginalAvailable = media.contains { session.project.media($0) != nil }
            } else {
                p.editOriginalAvailable = !session.originalFilesOfSelection.isEmpty || p.sourceMediaLoaded
            }
        } else if focus != .project {
            p.editOriginalAvailable = p.editOriginalAvailable || !session.originalFilesOfSelection.isEmpty
        }
        if p.panelsLoaded {
            // Insert / Overwrite: the Source clip, else the Project selection (the Mac `placeSource`).
            p.canPlaceSource = PlaceSource.resolve(sourceLoaded: p.sourceMediaLoaded, focus: focus, selectedMedia: p.projectSelectedMedia,
                                                   selectedSequences: p.projectSelectedSequences) != .nothing
        }
        if mediaClipboard != nil {
            let media = mediaRoute()
            p.canPasteMedia = media == .importFiles || media == .importImage
        }
        for fill in factProviders { fill(&p) }
        return p
    }
}
