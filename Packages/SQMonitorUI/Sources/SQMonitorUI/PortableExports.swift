// The monitor's portable logic (guides, safe margins, scopes graticule, transform / crop / mask / zoom / step-window
// geometry, text hit test, loudness range) lives in SQDrawKit/Monitor so the Windows app runs the same code; the Mac
// views keep using it through this re-export.
@_exported import SQDrawKit
// The monitor model, menus and command routing (MonitorPanelModel, MonitorMenus) moved to SQDrawMonitor for Windows.
@_exported import SQDrawMonitor
