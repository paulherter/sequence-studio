import Foundation
import SQCore

extension EditorSession {
    /// Audio tracks the Voice Chain acts on: the tracks of the selected audio clips (and their linked partners).
    public var voiceChainTargets: [Track.ID] {
        guard let t = activeTimeline else { return [] }
        let ids = Set(audioGainTargets.map(\.id))
        return t.tracks.filter { $0.kind == .audio && $0.clips.contains { ids.contains($0.id) } }.map(\.id)
    }

    /// True when every target track already has the Dialogue role (the command then clears it).
    public var voiceChainActive: Bool {
        guard let t = activeTimeline else { return false }
        let ids = Set(voiceChainTargets)
        return !ids.isEmpty && t.tracks.filter { ids.contains($0.id) }.allSatisfy { $0.audioRole == .dialogue }
    }

    /// Loudness readout for the selected audio clips against the Dialogue target (-14 LUFS), nil when nothing is measurable.
    /// shortcut: measures the clips' source loudness (the same measurement Match Loudness uses), not the output after the
    /// track's voiced preset; upgrade by rendering `RoleChain`/`OfflineAudioFX` offline if the post-chain number matters.
    public func voiceChainReadout() async -> VoiceChainReadout? {
        var values: [Double?] = []
        for c in selectedAudioClips { values.append(await measureLoudness(of: c)) }
        return VoiceChainReadout(measuredLUFS: values)
    }

    /// One click: the target tracks get the Dialogue role, whose voiced preset is the existing EQ -> compressor -> noise
    /// reduction chain (`RoleVoicing`, shared by playback and export); they also take part in live ducking. Clicking
    /// again clears the role. One undo step; no second preset system.
    @discardableResult
    public func toggleVoiceChain() -> Bool {
        let ids = Set(voiceChainTargets)
        guard !ids.isEmpty else { return false }
        let role: AudioTag? = voiceChainActive ? nil : .dialogue
        return attempt(role == nil ? "Remove Voice Chain" : "Voice Chain") { t in
            for i in t.tracks.indices where ids.contains(t.tracks[i].id) { t.tracks[i].audioRole = role }
        }
    }
}
