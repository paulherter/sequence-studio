# palmier-pro: what we can learn (2026-09-30)
palmier-pro (github.com/palmier-io/palmier-pro, GPL-3.0; see THIRD_PARTY.md) is a Premiere-like Swift editor built on AVPlayer/AVComposition.
Our engine (own VideoToolbox path, rational Time, audio master clock, Metal compositor) is different, so no wholesale import.

| Area | palmier-pro | Use for us |
|---|---|---|
| Shell | NSDocument (`VideoProject`), SwiftUI panels via NSViewRepresentable (`EditorPanel/EditorPanelGroup.swift`, `WorkspaceLayout.swift`), fixed layout | NSViewRepresentable bridge pattern; our docking stays own (SSEditorUI WorkspaceDocking) |
| Document/undo | NSDocument UndoManager, off-main save queue (`Project/VideoProject.swift`) | Off-main serialised save queue for autosave; keep our snapshot `History` |
| Playback | AVPlayer + time observer (`Preview/VideoEngine.swift`) | Nothing (we own frame scheduling) |
| Viewer | AVPlayerLayer + AVVideoCompositing (`Preview/PreviewNSView.swift`) | Nothing (CAMetalLayer + SSRender Compositor) |
| Drag & drop | `Timeline/TimelineView.swift` performDragOperation; `MediaPanel/MediaTab/MediaPanelDropArea.swift` DropHostingView | Directly: NSDraggingDestination registration, pasteboard payload pattern (T-06, U-05) |
| Audio | AVAudioEngine + AVAudioPlayerNode on userInteractive queue, lock-free `ScrubAudioPendingState` (`Preview/ScrubAudioOutput.swift`) | Lock-free pending-state pattern for E-12 scrub grains; keep AVAudioSourceNode + ring buffer as clock |
