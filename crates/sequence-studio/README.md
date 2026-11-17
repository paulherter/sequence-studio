# sequence-studio

The application binary: one window around the headless `App` of `sq-app-shell`, drawn with `sq-draw`'s `WgpuRenderer`
on a wgpu surface (Metal on the Mac, D3D12 on Windows). Window setup follows the G4 spike (`spikes/g4-window`).

- `main.rs`: the winit handler. Per loop turn: drain the inbox, poll the tasks, draw if the app asks, set the cursor,
  sleep until the next deadline or wake-up.
- `surface.rs`: the GPU, the surface and the renderer of the window.
- `input.rs`: winit events to `InputEvent` (pointer state, keys, modifiers, cursor shapes).
- `files.rs`: native file dialogs behind `ShellFilePicker` and `PanelFileChooser` (`rfd`); the system clipboard
  (`arboard`) goes into `UiCx.clipboard`.
- Platform crates: `sq-platform-mac` (menu bar), `sq-platform-win` (borderless chrome, opt in with `SQ_CHROME=1`).

Run: `cargo run -p sequence-studio`. `SQ_FONTS` overrides the Inter folder. Without a project argument the start window shows. State (dock layout, recents, presets) lives in the per-user support folder (`src/paths.rs`). Check: `cargo xtask check sequence-studio`.

## Test modes (no window)
- `sequence-studio --ui-shot out.png [--size WxH] [--scale S]`: one frame through the software renderer.
- `sequence-studio --a11y-dump out.txt [--size WxH]`: the accessibility tree as `role<TAB>label` lines.

## Accessibility
`src/a11y.rs` builds the accesskit tree; `accesskit_winit` serves it to the screen reader (tree pushed after each redraw while active). `ActionRequest`s go through `a11y::action_of` to `App::accessibility_action` and the host that pushed the node (`AppHost::a11y_action`); today the inspector sliders and project rows push nodes, the menu bar, tool strip, timeline and monitor controls still do not.
