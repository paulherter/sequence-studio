# sq-draw-shell

The shell of the shared draw UI, first part of Swift `SQDrawShell`: the in-window menu bar and its menus, the dialog card,
the key route and `ShellHost`, the object that owns them. Design: `docs/rust/session-ui-design.md` sections 2 and 4 (task SH1).
No winit, no OS calls.

## Public API
- `ShellHost`: no stored session. Calls that need it take a `ShellCx { session, measure, ui, hooks }`.
  - `new(map, recents, clock, wall)`, `layout(session, hooks, measure)`, `handle(cx, event, scale) -> bool`, `execute(cx, command)`,
    `perform(cx, action)`, `menus(..)`, `menu_enabled(..)`, `enabled(..)`, `window_title(session)`, `owns_keyboard()`,
    `draw_bar`, `draw_overlays`, `key_up`, `release_held_keys`, `shuttle_wake_at` / `tick_shuttle`, `alt_tapped`.
  - Swift hooks that only notify are `ShellEvent`s (`take_events()`: `Status`, `ProjectChanged`, `Quit`, `RecentsChanged`).
  - Swift `spawn { await .. }` is a `ShellFlow` request (`take_flows()`); the app runs each with
    `ShellHost::run_flow(UiRef<dyn ShellRoot>, flow)`. `ShellRoot: SessionRoot` hands out `ShellParts { session, shell, files }`.
  - Hooks that return values are the methods of `ShellHooks` (`on_command`, `command_handler`, `on_action`, `fill_facts`, ...);
    `NoHooks` answers "not mine" to all.
  - Dialogs: `present(ShellDialog) -> ModalAsk<SQDialogResponse>`, `present_message`, `present_error`, `dialog()`.
- `ShellDialog`, `DialogForm`, `ShellDialogContent`: the card, its layout and key rules; a form or drawn content plugs in through
  the two traits (the form port implements `DialogForm`).
- `MenuBar`, `MenuController`, `MenuListView`: menus drawn in the window. They store no `TextMeasure` (it borrows the atlas):
  every call that lays out takes `&TextMeasure`. The bar rebuilds its menus right before one opens through a `MenuRefresh`
  the host lends with the call.
- `ShellMenuBar::build`, `ShellAction`, `ShellMenuState`, `ShellMenu`: the main menu as `SQMenuItem` trees. A picked row calls the
  `perform` closure (the host queues the action and performs it after the menu closed).
- `ShellKeys`, `AltTap`, `ShellWindowTitle`; `ShellPanelFacts`, `ShellCommands`.
- `ShellStartScreen` (+ `StartEnv`, `StartAction`, `StartHit`, `UtcCalendar`): the start screen; the host owns it (`ShellHost::start`),
  `show_start`, `hide_start`, `present_start_at_launch`, `start_window_steps`, `editor_window_activated`; `ShellStartWindows` is the
  two-window rule. `ShellAboutContent`/`AboutPage`, `ShellMascot`, `ShellMascotStage`, `ShellAppIcon`: About card and Pip.
  Settings the start screen stores leave as `ShellEvent::Setting`; links, reveal and clipboard as `OpenUrl`, `RevealFile`, `CopyText`.
- `ShellFilePicker`, `answered`: the platform's file choosers (moved here from `sq-app-shell`, which re-exports them).

Notes, mapping decisions and the list of pending pieces: `PORTING-NOTES.md`. Check: `cargo xtask check sq-draw-shell`.

## Form, dock and Project panel (SH2-8, part A)
- `ShellForm` (`FormRow`, `NumberField`, `Sidebar`, ...): the dialog body; implements `DialogForm`. Changes are read with
  `take_changes()`, typed values after the answer with `ShellHost::take_answered_form()`.
- `ShellDock` + `ShellFloating`: the dockable layout and floating panels; events in `DockEvent` (`ShellHost::take_dock_events`).
  `ShellHost::dock` is the shell's dock; Window menu rows and panel commands run through it.
- `ProjectListView`: the Project panel as a list or an icon grid; calls take a `ProjectListCx`, hooks are `ProjectListEvent`s.
- `ShellChangeFormat` (+ templates and Pixel Aspect flows), full-screen state (`enter_program_full_screen`), `ShellPlatformText`.
