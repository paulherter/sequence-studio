import Foundation

/// Everything the Sequence Settings dialog edits on one sequence, as one value: the dialog reads `Timeline.settings`, the
/// session writes the result back with `Project.setSettings(_:of:)` in a single undo step.
public struct SequenceSettings: Sendable, Hashable {
    public var name: String
    public var format: SequenceFormat
    public var deliveryTarget: DeliveryTarget?
    public var editMode: TimelineEditMode
    public var timecodeStart: Time
    public var timecodeDisplay: TimecodeDisplay
    /// nil = follow the app setting.
    public var previewQuality: SequencePreviewQuality?
    public var channelLayout: ChannelLayout

    public init(name: String, format: SequenceFormat, deliveryTarget: DeliveryTarget? = nil, editMode: TimelineEditMode = .normal,
                timecodeStart: Time = .zero, timecodeDisplay: TimecodeDisplay = .timecode, previewQuality: SequencePreviewQuality? = nil,
                channelLayout: ChannelLayout = .stereo) {
        self.name = name; self.format = format; self.deliveryTarget = deliveryTarget; self.editMode = editMode
        self.timecodeStart = timecodeStart; self.timecodeDisplay = timecodeDisplay; self.previewQuality = previewQuality
        self.channelLayout = channelLayout
    }
}

extension Timeline {
    public var settings: SequenceSettings {
        SequenceSettings(name: name, format: format, deliveryTarget: deliveryTarget, editMode: editMode,
                          timecodeStart: timecodeStart, timecodeDisplay: timecodeDisplay, previewQuality: previewQuality,
                          channelLayout: channelLayout)
    }
}

extension Project {
    /// Applies Sequence Settings to one sequence. A blank name keeps the old one. Clips are not touched (they keep their
    /// scale and position); switching to Fast Cut derives the attachments like the timeline header does.
    public mutating func setSettings(_ s: SequenceSettings, of id: Timeline.ID) throws {
        guard s.format.isValid else { throw EditError.invalidFormat }
        guard let i = timelines.firstIndex(where: { $0.id == id }) else { throw EditError.timelineNotFound }
        timelines[i].format = s.format
        timelines[i].formatLocked = true
        timelines[i].deliveryTarget = s.deliveryTarget
        let name = s.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { timelines[i].name = name }
        if timelines[i].editMode != s.editMode { timelines[i].setEditMode(s.editMode) }
        timelines[i].timecodeStart = s.timecodeStart   // after the format: snaps to the new frame rate
        timelines[i].timecodeDisplay = s.timecodeDisplay
        timelines[i].previewQuality = s.previewQuality
        timelines[i].channelLayout = s.channelLayout
    }
}
