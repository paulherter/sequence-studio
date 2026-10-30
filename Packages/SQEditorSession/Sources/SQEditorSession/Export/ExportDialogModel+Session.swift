import Foundation
import SQCore
import SQExport

/// The Export dialog's sequence list from the session, shared by the Mac sheet (`ExportCoordinator.makeModel`) and the
/// Windows canvas form (SQDrawShell `ShellExport`): every pickable sequence with its In/Out, format, platform, variants,
/// cover marker, voice and sync warnings, the active sequence's selected clips and the delivery-chip traits.
public extension ExportDialogModel {
    @MainActor
    static func sequenceItems(for session: EditorSession) -> [SequenceItem] {
        let underVoice = session.project.sequencesNestedUnderDisguiseVoice()
        let selected = session.selection
        let activeID = session.activeTimelineID
        return session.project.pickableTimelines.map {
            SequenceItem(id: $0.id, name: $0.name, duration: $0.duration, inOut: $0.exportRange, format: $0.format,
                         deliveryTarget: $0.deliveryTarget, variants: $0.variants,
                         coverTime: CoverFrame.time(markers: $0.markers),
                         nestedUnderDisguiseVoice: underVoice.contains($0.id),
                         unsyncedAudioClips: unsyncedAudioCount(in: $0),
                         selectedClips: $0.id == activeID ? selectedRanges(in: $0, selection: selected) : [],
                         markers: $0.markers, sourceTraits: sourceTraits(of: $0, in: session.project),
                         hdrTarget: hdrTarget(of: $0))
        }
    }

    /// The HDR transfer the picture clips target (`ClipColor.targetSpace`), for the dialog's HDR delivery suggestion.
    static func hdrTarget(of timeline: Timeline) -> HDRDelivery.Transfer? {
        HDRDelivery.Transfer.suggested(for: timeline.tracks.flatMap(\.clips).filter { $0.kind != .audio }.map { $0.footageColor.targetSpace })
    }

    /// Audio clips that play out of sync with their linked picture (the audio check warns about them).
    static func unsyncedAudioCount(in timeline: Timeline) -> Int {
        let offsets = timeline.syncOffsets()
        guard !offsets.isEmpty else { return 0 }
        return timeline.tracks.flatMap(\.clips).filter { $0.kind == .audio && offsets[$0.id] != nil }.count
    }

    /// Whether the picture clips of the timeline use variable frame rate or interlaced media.
    static func sourceTraits(of timeline: Timeline, in project: Project) -> DeliveryCheck.SourceTraits {
        var t = DeliveryCheck.SourceTraits()
        for id in Set(timeline.tracks.flatMap(\.clips).filter { $0.kind != .audio }.map(\.media)) {
            guard let v = project.media(id)?.info?.video else { continue }
            if v.isVariableFrameRate { t.hasVariableFrameRate = true }
            if v.isInterlaced { t.hasInterlaced = true }
        }
        if let zone = timeline.deliveryTarget?.platform.safeZonePlatform {
            let f = timeline.format
            let aspect = f.height > 0 ? Double(f.displayWidth) / Double(f.height) : 9.0 / 16
            t.captionsInZone = CutCheck.analyze(timeline, platform: zone, frameAspect: aspect,
                                                captionBounds: { EditorSession.captionBox($0, canvas: f) })
                .filter { $0.kind == .captionOutsideSafeZone }.count
        }
        return t
    }

    /// Video-side clips of the timeline selection (a linked audio clip would repeat its picture's span), as spans.
    static func selectedRanges(in timeline: Timeline, selection: Set<Clip.ID>) -> [SelectedClipRange] {
        guard !selection.isEmpty else { return [] }
        let picked = timeline.tracks.flatMap(\.clips).filter { selection.contains($0.id) }
        let hasVideo = picked.contains { $0.kind != .audio }
        return picked.filter { !hasVideo || $0.kind != .audio }
            .map { SelectedClipRange(name: $0.name, range: $0.timeline) }
    }
}
