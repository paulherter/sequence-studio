import Foundation
import SQCore
import SQEditorSession
import SQMedia

/// Create Angles Clip: where each angle's file time 0 lies on the common clock for the sync the sheet chose. Translated from
/// the Mac `AnglesOrigins` (AppController+Angles): Timecode reads the start timecodes (the host's reader first, then
/// `SourceTimecode`, as Sync Audio does), Audio matches the sound envelopes of the host's waveform cache through SQCore
/// `AnglesAudioSync`. The edit itself is `EditorSession.createAnglesClip`.
extension ShellHost {
    /// `origins` nil: keep the timeline positions. Empty: line up by In point. An angle without an entry: its In point at the
    /// start. `note`: what could not be lined up, for the status line.
    public func anglesOrigins(sync: AngleSyncMode, angles: [AngleCandidate]) async -> (origins: [MediaRef.ID: Time]?, note: String?) {
        switch sync {
        case .timelinePositions: return (nil, nil)
        case .inPoints: return ([:], nil)
        case .timecode:
            var origins: [MediaRef.ID: Time] = [:]
            var missing = 0
            for a in angles {
                guard let id = a.media, let ref = session.project.media(id),
                      let t = await syncFacts(ref, waveform: nil).startTimecode else { missing += 1; continue }
                origins[id] = t
            }
            // An angle without timecode gets no origin: its In point goes to the start (`AnglesOffsets.starts`).
            if origins.count < 2 { return ([:], SQL10n.string("No timecode found: lined up by In point.")) }
            return (origins, missing > 0 ? SQL10n.format("%@ without timecode: lined up by In point.", String(missing)) : nil)
        case .audio:
            var ids: [MediaRef.ID] = []
            for a in angles where a.hasAudio { if let id = a.media, !ids.contains(id) { ids.append(id) } }
            let shapes = await waveforms(ids)
            var envelopes: [(id: MediaRef.ID, envelope: [Float])] = []
            var unread = 0
            for id in ids {
                guard let e = shapes[id]?.envelope(), !e.isEmpty else { unread += 1; continue }
                envelopes.append((id, e))
            }
            guard envelopes.count >= 2 else { return ([:], SQL10n.string("The sound could not be read: lined up by In point.")) }
            let report = await Task.detached(priority: .userInitiated) {
                AnglesAudioSync.report(envelopes: envelopes, rate: WaveformData.envelopeRate)
            }.value
            let names = Dictionary(angles.compactMap { a in a.media.map { ($0, a.name) } }, uniquingKeysWith: { a, _ in a })
            let failed = report.failed.map { id -> (name: String, confidence: Double?) in
                if case .notSynced(let c)? = report.outcomes[id] { return (names[id] ?? "Angle", c) }
                return (names[id] ?? "Angle", nil)
            }
            let synced: [Double] = report.outcomes.values.compactMap { if case .synced(let c) = $0 { c } else { nil } }
            let note = AnglesAudioSync.note(failed: failed, synced: synced, silent: angles.filter { !$0.hasAudio }.count, unreadable: unread)
            return (report.origins, note)
        }
    }
}
