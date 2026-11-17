# sq-app-hosts

The panel hosts of the app (Swift `SQAppShell` `*Host` classes). A host owns a drawn panel from a panel crate, runs it as
an `AppHost` and turns the panel's event enum into session calls and `AppEvent`s that `App::dispatch` handles. The panel
crates depend on `sq-app-shell`, so the hosts live in this crate above both.

- `LibraryHost` (AS1): Library panel. Preset apply, built-in graphic and CTA templates and the preview-stops-playback rule
  run here; requests that need a dialog, a file chooser, a menu or the timeline panel are queued for the app
  (`take_deferred`). Notes: `PORTING-NOTES.md`. Check: `cargo xtask check sq-app-hosts`.
- `MonitorHost` (AS2): Monitor card. Pick clip, seek and scrub run in the session; menus, tabs, drags, text and shape
  tools and format choices queue in `take_deferred`.
- `TimelinePanelHost` (AS3): wraps `TimelineAppHost`; its host hooks become `TimelineHostEvent`s (`take_events`) and
  status lines.
- `AppRoot` (AS4): one `AppHost` owning the three hosts above. Fixed split (Monitor top left, Library top right,
  Timeline below), input Timeline, Library, Monitor; queued requests get a status line until their dialogs, menus and
  editors are ported.
