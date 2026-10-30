import AppKit
import SQCore
import SQEditorUI
import SQMedia

// F7.16 Angles clip: the Create Angles Clip sheet, the sync that reads the files (start timecode, sound) and the
// number keys' status messages. The edits themselves are `EditorSession+Angles`.
extension AppController {
    /// Clip > Angles > Create Angles Clip…: the selected timeline clips, else the media items selected in the Project panel.
    func requestAnglesClip() {
        if session.angleCandidatesOfSelection.count >= 2 { requestAnglesClip(media: nil); return }
        let media = panels?.projectView.selectedMediaIDs ?? []
        if session.angleCandidates(media: Array(media)).count >= 2 { requestAnglesClip(media: Array(media)); return }
        shell.statusBar.flash("Select at least two clips, in the timeline or in the Project panel.", seconds: 4)
    }

    /// `media` nil: from the timeline selection (the Angles clip takes the clips' place); else from these media items
    /// (the Angles clip appears in the Project panel).
    func requestAnglesClip(media: [MediaRef.ID]?) {
        // The timeline clips are taken once, here: the sync below is asynchronous and the selection may change meanwhile.
        let clips = session.angleSelection
        let angles = media.map { session.angleCandidates(media: $0) } ?? session.angleCandidates(clips: clips)
        guard angles.count >= 2 else {
            shell.statusBar.flash("An Angles clip needs at least two clips.", seconds: 4); return
        }
        AnglesDialog.present(on: window, angles: angles, fromTimeline: media == nil,
                             existingNames: session.project.timelines.map(\.name)) { [weak self] result in
            guard let self, let result else { return }
            let files = self.anglesFiles(angles)
            if result.sync == .timecode || result.sync == .audio { self.shell.statusBar.flash("Lining up the angles…", seconds: 30) }
            Task { @MainActor [weak self] in
                let found = await AnglesOrigins.find(sync: result.sync, files: files)
                guard let self else { return }
                let made: Timeline.ID?
                if let media {
                    made = self.session.createAnglesSequence(media: media, name: result.name, origins: found.origins ?? [:],
                                                             audioAngle: result.audioAngle, audioFollowsVideo: result.audioFollowsVideo)
                } else {
                    made = self.session.createAnglesClip(from: clips, name: result.name, origins: found.origins,
                                                         audioAngle: result.audioAngle, audioFollowsVideo: result.audioFollowsVideo)
                }
                guard made != nil else {
                    self.shell.statusBar.flash(self.session.lastError ?? "Could not create the Angles clip.", seconds: 4); return
                }
                let done = media == nil ? "Angles clip created: cut it and press 1 to 9 on a piece."
                    : "\(result.name) is in the Project panel: place it in a sequence, then press 1 to 9."
                self.shell.statusBar.flash(found.note.map { "\($0) \(done)" } ?? done, seconds: 6)
            }
        }
    }

    /// The file and frame rate of each angle's media, in angle order.
    private func anglesFiles(_ angles: [AngleCandidate]) -> [AnglesOrigins.File] {
        angles.map { a in
            let ref = a.media.flatMap { session.project.media($0) }
            let fd = ref?.info?.video?.nominalFrameDuration
            return AnglesOrigins.File(media: a.media, url: ref.map { URL(fileURLWithPath: $0.path) },
                                      hasAudio: a.hasAudio && ref?.info?.audio != nil,
                                      ntsc: fd.map { $0.value % 1001 == 0 } ?? false)
        }
    }

    /// Number key 1...9.
    func switchAngle(_ n: Int) {
        switch session.switchAngle(n) {
        case .switched, .unchanged: break
        case .noAnglesClip: shell.statusBar.flash("No Angles clip is selected or under the playhead.", seconds: 3)
        case .noSuchAngle(let count): shell.statusBar.flash(SQL10n.format("This Angles clip has %@ angles.", String(count)), seconds: 3)
        case .refused: shell.statusBar.flash(session.lastError ?? "Could not switch the angle.", seconds: 3)
        }
    }

    /// Whether the active sequence holds an Angles clip (the Switch to Angle menu items).
    var hasAnglesClip: Bool {
        session.activeTimeline?.tracks.contains { $0.clips.contains(where: \.isAnglesClip) } ?? false
    }
}

/// Where each angle's file time 0 lies on the common clock, for the sync chosen in the sheet.
enum AnglesOrigins {
    struct File: Sendable {
        var media: MediaRef.ID?
        var url: URL?
        var hasAudio: Bool
        var ntsc: Bool
    }

    struct Found: Sendable {
        /// nil: keep the timeline positions. Empty: line up by In point. An angle without an entry: its In point at the start.
        var origins: [MediaRef.ID: Time]?
        /// What could not be lined up, for the status bar.
        var note: String?
    }

    static func find(sync: AnglesDialog.Sync, files: [File]) async -> Found {
        switch sync {
        case .timelinePositions: return Found(origins: nil, note: nil)
        case .inPoints: return Found(origins: [:], note: nil)
        case .timecode:
            var origins: [MediaRef.ID: Time] = [:]
            var missing = 0
            for f in files {
                guard let id = f.media, let url = f.url, let t = await AnglesSync.startTimecode(url: url, ntsc: f.ntsc) else { missing += 1; continue }
                origins[id] = t
            }
            // An angle without timecode gets no origin: its In point goes to the start (`AnglesOffsets.starts`).
            if origins.count < 2 { return Found(origins: [:], note: "No timecode found: lined up by In point.") }
            return Found(origins: origins, note: missing > 0 ? "\(missing) without timecode: lined up by In point." : nil)
        case .audio:
            return await Task.detached(priority: .userInitiated) { await byAudio(files) }.value
        }
    }

    /// The first angle with sound is the reference; every other angle is placed where its sound matches best.
    private static func byAudio(_ files: [File]) async -> Found {
        var envelopes: [(MediaRef.ID, [Float])] = []
        var unread = 0
        var seen = Set<MediaRef.ID>()
        for f in files where f.hasAudio {
            guard let id = f.media, let url = f.url, seen.insert(id).inserted else { continue }
            guard let e = try? await AnglesSync.envelope(url: url), !e.isEmpty else { unread += 1; continue }
            envelopes.append((id, e))
        }
        guard envelopes.count >= 2 else {
            return Found(origins: [:], note: "The sound could not be read: lined up by In point.")
        }
        // Which angle gets an origin is decided (and tested) in SQCore: no origin = lined up by its In point.
        let report = AnglesAudioSync.report(envelopes: envelopes.map { (id: $0.0, envelope: $0.1) }, rate: AnglesSync.envelopeRate)
        let names = Dictionary(files.compactMap { f in f.media.map { ($0, f.url?.lastPathComponent ?? "Angle") } }, uniquingKeysWith: { a, _ in a })
        let failed = report.failed.map { id -> (name: String, confidence: Double?) in
            if case .notSynced(let c)? = report.outcomes[id] { return (names[id] ?? "Angle", c) }
            return (names[id] ?? "Angle", nil)
        }
        let synced: [Double] = report.outcomes.values.compactMap { if case .synced(let c) = $0 { c } else { nil } }
        let note = AnglesAudioSync.note(failed: failed, synced: synced, silent: files.filter { !$0.hasAudio }.count, unreadable: unread)
        return Found(origins: report.origins, note: note)
    }
}
