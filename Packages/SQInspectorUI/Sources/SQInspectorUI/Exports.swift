// The inspector layer sits on SQTimelineUI and SQMonitorUI (and through them SQEditorSession, SQUIKit): visible in every
// file here (DECISIONS "SQEditorUI split").
#if canImport(AppKit)
@_exported import SQTimelineUI
@_exported import SQMonitorUI
#else
// Windows: only the portable models build (Package.swift); they see the session and the portable SQUIKit vocabulary.
@_exported import SQEditorSession
@_exported import SQUIKit
// The Graphics panel's layer list rules (LayerListLogic, LayerDrop) are SQTimelineUI's portable part.
@_exported import SQTimelineUI
#endif
