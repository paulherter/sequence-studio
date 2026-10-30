// SQEditorUI stays the top UI module: the app keeps `import SQEditorUI` and sees the split-out modules through it
// (DECISIONS "SQEditorUI split").
@_exported import SQUIKit
@_exported import SQEditorSession
@_exported import SQTimelineUI
@_exported import SQMonitorUI
@_exported import SQInspectorUI
@_exported import SQDrawLibrary

// SwiftUI (DeveloperToolsSupport) has a `LibraryItem` too; inside this module the Library panel item wins.
typealias LibraryItem = SQDrawLibrary.LibraryItem
