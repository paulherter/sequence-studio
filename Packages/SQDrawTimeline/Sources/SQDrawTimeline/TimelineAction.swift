import Foundation
import SQCore
import SQEditorSession
import SQTimelineUI
import SQUIKit

/// What the timeline panel asks of the host: one case per Mac `TimelineView` callback (`onCommit`, `onSeek`,
/// `onToggle`, ...). `TimelineSessionBridge` applies them through the `EditorSession` API like App/EditorPanels does
/// on the Mac; the panel never edits the model itself.
public enum TimelineAction: Sendable, Equatable {
    /// A finished gesture (move, trim, ripple, roll, slip, slide, razor, rate stretch, marquee delete...).
    case commit(TimelineCommit)
    case select(clips: Set<Clip.ID>, captions: Set<CaptionItem.ID>)
    case seek(Time)
    case beginScrub
    case scrub(Time)
    case endScrub
    /// A track header button or target chip; `shift` / `option` as held (Shift = every track of the kind).
    case toggleTrack(Track.ID, TrackToggle, shift: Bool, option: Bool)
    case addTrack(TrackKind)
    /// A source patch chip clicked (`solo`: Option, this stream only) or dragged onto a track (`both`: Shift).
    case sourcePatchClick(TrackKind, solo: Bool)
    case sourcePatchMove(TrackKind, to: Track.ID, both: Bool)
    case moveMarker(Marker.ID, to: Time)
    case setMarkerDuration(Marker.ID, to: Time)
    case moveInOut(TimeRange, part: MarkedRangeDragPart)
    case selectTransition(Transition.ID?, keepClips: Bool)
    /// One step of a transition box drag; `continues` coalesces the steps of one drag into one undo step.
    case changeTransition(Transition.ID, TransitionLayout.Change, continues: Bool)
    /// Double-click a transition box: the duration dialog.
    case editTransition(Transition.ID)
    /// A transition layer's cut marker dragged to `to`, or its end (`symmetric`: the other end mirrors it); `continues`
    /// coalesces the steps of one drag into one undo step.
    case transitionLayerCut(Clip.ID, to: Time, continues: Bool)
    case transitionLayerResize(Clip.ID, ClipEdge, to: Time, symmetric: Bool, continues: Bool)
    case openNestedSequence(Timeline.ID)
    /// Double-click an edit with the Selection tool; `pointerBefore` = the outgoing side was clicked.
    case openTrimMode(TrimPoint, pointerBefore: Bool)
    case editTextClip(Clip.ID)
    case editToneClip(Clip.ID)
    case openGraphicLayers(Clip.ID)
    case openInSource(UUID)
    case editMarker(Marker.ID)
    /// Double-click a clip marker flag: the clip marker editor.
    case editClipMarker(clip: Clip.ID, marker: Marker.ID)
    /// A dragged clip marker flag.
    case moveClipMarker(clip: Clip.ID, marker: Marker.ID, to: Time)
    /// One step of a volume / opacity band or fade handle drag: the first opens the undo step `undoName`, later ones
    /// continue it (`EditorSession.replaceClip`).
    case replaceClip(Clip, undoName: String, continues: Bool)
    /// The band drag that sent `.replaceClip` ended: its undo step closes (`EditorSession.endGesture`).
    case endGesture
    /// A key on a band was clicked (`extend`: Shift toggles it in the picked set); nil drops the picked keys.
    case lineKeyClick(LineKeyRef?, extend: Bool)
    /// One phase of a speed band drag (`EditorSession.applySpeedEdit` makes the drag one undo step).
    case speedEdit(clip: Clip.ID, keys: SpeedKeys, phase: SpeedEditPhase, keepingKeys: Bool)
    /// Esc during a speed band drag: the sequence goes back to `restoring`, the drag leaves no undo step.
    case cancelSpeedEdit(clip: Clip.ID, restoring: Timeline)
    /// A key glyph on a selected clip's key lane: Effect Controls picks the keys at `time` (`extend`: Shift).
    case keyLaneClick(clip: Clip.ID, time: Time, extend: Bool)
    /// A right press at a panel point: the host shows `TimelineMenus.items(at:...)` there.
    case contextMenu(at: CGPoint)
    /// A shell command the panel triggers itself (the ` tap in Fast Cut: Maximize Panel Under Pointer).
    case command(EditorCommand)
    /// `onSkim`: the Fast Cut skimmer moved to a frame (nil: it is hidden).
    case skim(Time?)
    /// Slip drag: the two-up the Program monitor shows (nil = back to normal), with the preview timeline it reads.
    case slipTwoUp(SlipTwoUp?, Timeline)
    /// Project-panel media dropped on the panel: on `track` (nil = the targeted tracks) or on a new track of `newTrack`.
    case dropMedia([UUID], time: Time, track: Track.ID?, newTrack: TrackKind?, insert: Bool, streams: SourceStreams)
    /// A keystone dropped on a clip at `span` (clip-local; the Mac `onDropKeystone`), one undo step; the bar shows.
    case dropKeystone(Keystone, clip: Clip.ID, span: KeystoneSpan)
    /// The bar of the keystone applied last was stretched (the Mac `onRestretchKeystone`), one undo step.
    case restretchKeystone(clip: Clip.ID, from: KeystoneSpan, to: KeystoneSpan, name: String)
    /// Items picked in a clip's item lanes (the Mac `onItemLaneSelect`): the clip is selected, the host's item selection
    /// (monitor, Controls) follows.
    case selectItems(clip: Clip.ID, items: Set<UUID>)
    /// The disclosure arrow of a text or shape clip: it becomes a Graphic first (`onItemLanesMakeGraphic`).
    case makeGraphic(Clip.ID)
    /// A lane name dropped within its Graphic: the items go to `toIndex` (bottom first), one undo step.
    case reorderItems(clip: Clip.ID, ids: [UUID], toIndex: Int)
    /// A lane name dropped on another Graphic or a free video stretch (`onItemLaneMoveOut`); `copy` keeps the originals.
    case moveItemsOut(clip: Clip.ID, ids: [UUID], to: GraphicsLayerDestination, copy: Bool)
    /// Fast Cut: the attached clip's attach point moved to `time` (thread drag or Cmd+Opt click), one undo step.
    case setAttachPoint(clip: Clip.ID, time: Time)
    /// `onToggleCaptionTrackVisibility`: the eye in a caption track's header.
    case toggleCaptionTrackVisibility(CaptionTrack.ID)
    /// A caption double-click: the word under the pointer (inline word field) or, without one, the Text panel.
    case editCaption(CaptionItem.ID, word: CaptionWordRef?)
    /// A refused gesture's reason or a hint for the status line.
    case status(String)
}
