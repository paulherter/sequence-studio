//! Command-line test modes: headless runs of the app that need no window (the Swift `SQ_*` shot and dump modes).

use std::path::PathBuf;

/// The parsed command line: what to run and which project to open.
#[derive(Debug, PartialEq)]
pub struct Cli {
    pub mode: Mode,
    /// A `.sqproj` given as a plain argument; `None` opens an empty project.
    pub project: Option<PathBuf>,
}

/// Optional poses for a shot, so panels that need a selection or the Color page show without clicks.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Pose {
    /// A clip of the active timeline by index (in track order) or by name.
    pub select: Option<String>,
    /// Show the Color page.
    pub color_page: bool,
    /// Clicks in points, run in order before the frame is drawn (`--click x,y`; `--dclick x,y` is two).
    pub clicks: Vec<(f32, f32)>,
    /// Key presses run after the clicks (`--key cmd+m`, `--key cmd+,`, `--key escape`): menus, dialogs, sheets.
    /// `ctrl` is the user's Ctrl: the Mac Control key on the Mac, the command modifier on Windows and Linux (`ctrl+,` = `cmd+,` there).
    pub keys: Vec<(sq_draw::InputKey, sq_draw::InputModifiers)>,
    /// Modifier keys tapped alone (`--key alt`, `ctrl`, `shift`: press and release), run after `keys`. Only a lone Alt does
    /// something (it focuses the menu bar, like the window's lone Alt tap).
    pub lone_modifiers: Vec<LoneModifier>,
    /// The panel that has the keyboard focus before the keys (`--focus program|source|project|timeline|effect-controls|effects`),
    /// so a panel-scoped chord can be pressed.
    pub focus: Option<sq_uikit::panel_id::PanelID>,
    /// Right-clicks in points (`--click-right x,y`), after the clicks and before the keys: the menu stays open in the shot.
    pub right_clicks: Vec<(f32, f32)>,
    /// A menu-bar menu to open by title (`--menu Edit`); `--menu all` opens none but writes every menu as text.
    pub menu: Option<String>,
    /// Right-click a grid of points over the window and write every distinct menu as text (`--menu-grid`): the Rust
    /// counterpart of the Swift `SQ_SHOT_ONLY=menu` sweep, `<stem>-<n>-<x>x<y>.txt` beside the PNG.
    pub menu_grid: bool,
    /// Named states run after the keys, in order (`--pose max-ec --pose mask`; see `AppHost::shot_pose`).
    pub poses: Vec<String>,
    /// Show the first-run Welcome tour (`--tour`): the shot does not mark it seen. Steps: `--key enter` per step.
    pub tour: bool,
    /// Ordered steps run after the poses (see [`STEP_HELP`]): the flags above run all clicks before all keys, so a flow that
    /// alternates between a click and typing needs these.
    pub steps: Vec<Step>,
    /// The shot's PNG path, set by the runner: a menu that is open is written as text beside it (`<stem>.txt`).
    pub outline_beside: Option<PathBuf>,
}

/// The steps `--step` takes, for the harness help and the bad-step message.
pub const STEP_HELP: &str = "click:x,y (press and release), hover:x,y (move the pointer, no press, then draw), type:text, \
key:cmd+s, select:name (a clip), wait:ms (let loads finish), import:path (a file drop on the Project panel), \
drag:x1,y1,x2,y2[,ms] (press, move in ~16 ms steps over ms, default 300, release), \
wheel:x,y,dy[,dx][,pad] (one wheel event of dy lines, negative = up, dx positive = right; `pad` is a trackpad swipe that \
can pull past the end and spring back: follow it with wait:ms), \
flick:x,y,dy[,frames[,until_ms]][,move=X2:Y2@k][,route=win] (a real trackpad flick: finger moves, lift, momentum tail, the winit \
event sequence; stops until_ms after its start when given; `move` puts the pointer on X2,Y2 just before tail event k; \
`route=win` sends the phase-less wheel messages of a Windows precision touchpad through the Windows route)";

/// The longest `wait:` the harness accepts, in milliseconds: a step that never ends would hang the sweep.
const MAX_WAIT_MS: u64 = 60_000;

/// One step of an ordered `--step` flow.
#[derive(Clone, Debug, PartialEq)]
pub enum Step {
    /// A press and release at a point in points.
    Click(f32, f32),
    /// The pointer moves to a point in points with no button down, then a frame is drawn (hover states, tooltips).
    Hover(f32, f32),
    /// The app keeps drawing for this many milliseconds (loads, posters and thumbnails arrive).
    Wait(u64),
    /// A file dropped on the window: the same import as a drop on the Project panel, with no native dialog.
    Import(PathBuf),
    /// A chord, as `--key` takes it.
    Key(sq_draw::InputKey, sq_draw::InputModifiers),
    /// Text typed into the field that has the keyboard, one character at a time.
    Type(String),
    /// A clip of the active timeline by index or name, as `--select`.
    Select(String),
    /// A press at the first point, moves in about 16 ms steps to the second over `ms`, and a release there.
    Drag { from: (f32, f32), to: (f32, f32), ms: u64 },
    /// The pointer at a point and one wheel event of `dy` lines (negative = up) and `dx` lines (positive = right). With
    /// `pad` it is a trackpad swipe (pixels, then the fingers lift), which pulls past the end of a list and springs back.
    Wheel { at: (f32, f32), dy: f32, dx: f32, pad: bool },
    /// A replayed trackpad flick of `dy` lines (negative = up) over `frames` finger moves, then the momentum tail; the
    /// replay stops `until_ms` after its start when given.
    /// `move_to` puts the pointer at a point just before the tail event with that index; `win` replays the Windows
    /// route (phase-less wheel messages and the idle end) instead of the Mac phases.
    Flick { at: (f32, f32), dy: f32, frames: usize, until_ms: Option<u64>, move_to: Option<FlickMove>, win: bool },
}

/// A pointer move inside a flick's momentum tail: to `to` just before tail event `tail_frame` (0 = the first).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct FlickMove {
    pub to: (f32, f32),
    pub tail_frame: usize,
}

/// How long a `drag:` takes when the step names no time, in milliseconds.
pub(crate) const DEFAULT_DRAG_MS: u64 = 300;

/// One `--step` text, see [`STEP_HELP`].
pub(crate) fn parse_step(text: &str) -> Option<Step> {
    let (kind, rest) = text.split_once(':')?;
    let point = || {
        let (x, y) = rest.split_once(',')?;
        Some((x.parse().ok()?, y.parse().ok()?))
    };
    match kind {
        "click" => point().map(|(x, y)| Step::Click(x, y)),
        "hover" => point().map(|(x, y)| Step::Hover(x, y)),
        "wait" => rest.parse().ok().filter(|ms| *ms <= MAX_WAIT_MS).map(Step::Wait),
        "import" if !rest.is_empty() => Some(Step::Import(PathBuf::from(rest))),
        "key" => parse_key(rest).map(|(key, modifiers)| Step::Key(key, modifiers)),
        "type" => Some(Step::Type(rest.to_string())),
        "select" => Some(Step::Select(rest.to_string())),
        "drag" => {
            let mut f = rest.split(',');
            let mut n = || f.next()?.trim().parse::<f32>().ok();
            let (x1, y1, x2, y2) = (n()?, n()?, n()?, n()?);
            let ms = match f.next() {
                Some(ms) => ms.trim().parse().ok().filter(|ms| *ms <= MAX_WAIT_MS)?,
                None => DEFAULT_DRAG_MS,
            };
            f.next().is_none().then_some(Step::Drag { from: (x1, y1), to: (x2, y2), ms })
        }
        "wheel" => {
            let mut f = rest.split(',');
            let mut n = || f.next()?.trim().parse::<f32>().ok();
            let (x, y, dy) = (n()?, n()?, n()?);
            let (mut dx, mut pad) = (0.0, false);
            for extra in f {
                match extra.trim() {
                    "pad" => pad = true,
                    number => dx = number.parse().ok()?,
                }
            }
            Some(Step::Wheel { at: (x, y), dy, dx, pad })
        }
        "flick" => {
            let mut f = rest.split(',');
            let mut n = || f.next()?.trim().parse::<f32>().ok();
            let (x, y, dy) = (n()?, n()?, n()?);
            let (mut frames, mut until_ms, mut move_to, mut win) = (None, None, None, false);
            for tok in f {
                let tok = tok.trim();
                if let Some(m) = tok.strip_prefix("move=") {
                    let (xy, k) = m.split_once('@')?;
                    let (x2, y2) = xy.split_once(':')?;
                    let to = (x2.trim().parse().ok()?, y2.trim().parse().ok()?);
                    move_to = Some(FlickMove { to, tail_frame: k.trim().parse().ok().filter(|k| *k <= 200)? });
                } else if let Some(r) = tok.strip_prefix("route=") {
                    win = match r {
                        "win" => true,
                        "mac" => false,
                        _ => return None,
                    };
                } else if frames.is_none() {
                    frames = Some(tok.parse().ok().filter(|n| (1..=200).contains(n))?);
                } else if until_ms.is_none() {
                    until_ms = Some(tok.parse().ok().filter(|ms| *ms <= MAX_WAIT_MS)?);
                } else {
                    return None;
                }
            }
            Some(Step::Flick { at: (x, y), dy, frames: frames.unwrap_or(8), until_ms, move_to, win })
        }
        _ => None,
    }
}

/// A modifier key pressed and released with nothing in between.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LoneModifier {
    Alt,
    Ctrl,
    Shift,
}

/// `alt`, `ctrl` or `shift` alone (a spec with no `+`).
pub(crate) fn parse_lone_modifier(text: &str) -> Option<LoneModifier> {
    match text {
        "alt" => Some(LoneModifier::Alt),
        "ctrl" => Some(LoneModifier::Ctrl),
        "shift" => Some(LoneModifier::Shift),
        _ => None,
    }
}

/// `cmd+shift+z` style key spec: modifiers joined by `+`, then a named key or one character.
pub(crate) fn parse_key(text: &str) -> Option<(sq_draw::InputKey, sq_draw::InputModifiers)> {
    parse_key_for(sq_os::Platform::current(), text)
}

/// [`parse_key`] for a given system. `ctrl` is the key the user presses: the Mac's Control key on the Mac, but the
/// command modifier on Windows and Linux (where the real window maps Ctrl to Command, `sq_draw::pointer::modifiers_for`).
pub(crate) fn parse_key_for(
    platform: sq_os::Platform,
    text: &str,
) -> Option<(sq_draw::InputKey, sq_draw::InputModifiers)> {
    use sq_draw::{InputKey, InputModifiers};
    let (mods, key) = match text.strip_suffix("++") {
        Some(rest) => (rest, "+"),
        None => text.rsplit_once('+').map_or(("", text), |(m, k)| (m, k)),
    };
    let mut modifiers = InputModifiers::NONE;
    for m in mods.split('+').filter(|m| !m.is_empty()) {
        modifiers = modifiers
            | match m {
                "cmd" => InputModifiers::COMMAND,
                "shift" => InputModifiers::SHIFT,
                "opt" => InputModifiers::OPTION,
                "ctrl" if platform.command_is_cmd_key() => InputModifiers::CONTROL,
                "ctrl" => InputModifiers::COMMAND,
                _ => return None,
            };
    }
    let key = match key {
        "space" => InputKey::Space,
        "escape" => InputKey::Escape,
        "enter" => InputKey::Enter,
        "left" => InputKey::Left,
        "right" => InputKey::Right,
        "up" => InputKey::Up,
        "down" => InputKey::Down,
        "delete" => InputKey::Delete,
        "backspace" => InputKey::Backspace,
        "home" => InputKey::Home,
        "end" => InputKey::End,
        "pageup" => InputKey::PageUp,
        "pagedown" => InputKey::PageDown,
        k if k.len() <= 3 && k.starts_with('f') && matches!(k[1..].parse::<u8>(), Ok(1..=12)) => {
            InputKey::Function(k[1..].parse().ok()?)
        }
        "plus" => InputKey::Plus,
        "minus" => InputKey::Minus,
        k if k.chars().count() == 1 => InputKey::Character(k.chars().next()?),
        _ => return None,
    };
    Some((key, modifiers))
}

/// The panel a `--focus` name stands for.
pub(crate) fn parse_focus(name: &str) -> Option<sq_uikit::panel_id::PanelID> {
    use sq_uikit::panel_id::PanelID;
    Some(match name {
        "program" => PanelID::ProgramMonitor,
        "source" => PanelID::SourceMonitor,
        "project" => PanelID::Project,
        "timeline" => PanelID::Timeline,
        "effect-controls" => PanelID::EffectControls,
        "effects" => PanelID::Effects,
        _ => return None,
    })
}

/// What the binary was asked to do.
#[derive(Debug, PartialEq)]
pub enum Mode {
    /// Open the window.
    Window,
    /// Render one frame offscreen with the software renderer and write a PNG (`SQ_SHARED_UI_SHOT`).
    UiShot {
        out: PathBuf,
        width: u32,
        height: u32,
        scale: f32,
        playhead_ms: i64,
        pose: Pose,
    },
    /// The click sweep of the use pass (check U1): opens every main screen, clicks every control it finds and writes
    /// `u1-states.tsv`, `u1-controls.tsv` and crops of the controls that did nothing into `out` (`use_pass`).
    UsePass {
        out: PathBuf,
        width: u32,
        height: u32,
        /// The step of the pointer sweep in points.
        pitch: u32,
        /// Screens to sweep (`--states a,b`); empty is all of them.
        states: Vec<String>,
        /// Controls that do nothing on purpose (`--known <file>`).
        known: Option<PathBuf>,
    },
    /// Write the accessibility nodes of one frame as text, one line per node.
    A11yDump {
        out: PathBuf,
        width: u32,
        height: u32,
    },
    /// Plays the project for a few seconds through the real engine and the UI frame loop, writes frames per second and
    /// the time the UI frames took.
    PlayBench {
        out: PathBuf,
        width: u32,
        height: u32,
    },
    /// First Play after the open and after a switch to a second sequence, through the real session and engine without a
    /// window: time from Play to the first new picture, with the engine's phase notes on stderr (`play_start`).
    PlayStart {
        out: PathBuf,
    },
    /// Soak: plays, scrubs, edits and undoes in a loop for `SQ_SOAK_SECS` (default 1200) seconds and logs frames and
    /// pictures every 30 s (`headless::soak`); memory is sampled from outside.
    Soak {
        out: PathBuf,
        width: u32,
        height: u32,
    },
    /// Plays the clip given as the project argument through the Program engine without a window and writes the frame,
    /// drop, monitor-upload, CPU and scrub numbers (`play_bench`).
    EngineBench {
        out: PathBuf,
    },
    PresentCheck {
        out: PathBuf,
    },
    /// Renders the start-failure screen with the software renderer and writes a PNG, no window: the failure of
    /// `SQ_FAULT_INJECT` (the graphics one without it), `--theme dark|light`, `--scale`.
    StartErrorShot {
        out: PathBuf,
        scale: f32,
        light: bool,
    },
    /// Writes the fixed many-layers test project and its five copies without one heavy element each, over the media
    /// that `scripts/perf-media.sh` made in `media` (`perf_project`).
    PerfProject {
        out: PathBuf,
        media: PathBuf,
    },
    /// Tracks a click through the clip given as the project argument with the real Magic Mask model and writes IoU numbers
    /// against a synthetic disk when `disk` is given (`--eval-click x,y --eval-disk x,y,vx,vy,r`, frame fractions).
    MaskEval {
        out: PathBuf,
        click: (f64, f64),
        disk: Option<String>,
    },
    /// Exports the project's active sequence to `out` through the pipeline of the Export sheet (`export_cli::run`).
    Export(ExportArgs),
    /// Prints the preset names of the Export sheet, one per line.
    ListPresets,
    /// Linux AppImage: `--desktop-entry add|remove|status` writes, deletes or reports the applications-menu entry.
    DesktopEntry(DesktopEntryCommand),
}

/// What `--desktop-entry` does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DesktopEntryCommand {
    Add,
    Remove,
    Status,
}

/// The options of `--export`.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct ExportArgs {
    pub out: PathBuf,
    /// A preset name or id as listed by `--list-presets`; `None` is the sheet's default for the sequence.
    pub preset: Option<String>,
    /// In and out in milliseconds of the sequence (`--range 1.5,4`).
    pub range_ms: Option<(i64, i64)>,
    pub size: Option<(u32, u32)>,
    /// `hlg` or `pq`.
    pub hdr: Option<String>,
    pub no_hardware: bool,
    /// Export the entire sequence even when it has In/Out marks (the sheet's "Entire sequence").
    pub entire: bool,
    /// Replace an existing file (the sheet's "Replace"); without it a number is added ("Keep Both").
    pub overwrite: bool,
    /// "Use proxies when exporting", read from the stored preferences once when the CLI starts the export (`headless.rs`) (not a flag).
    pub use_proxies: bool,
}

const DEFAULT_SIZE: (u32, u32) = (1440, 900);

/// Parses the arguments after the program name.
pub fn parse(args: &[String]) -> Result<Cli, String> {
    let mut project = None;
    let mut mode: Option<(&str, PathBuf)> = None;
    let mut size = DEFAULT_SIZE;
    let mut scale = 1.0_f32;
    let mut playhead_ms = 0_i64;
    let mut pose = Pose::default();
    let mut eval_click = (0.5_f64, 0.5_f64);
    let mut eval_disk: Option<String> = None;
    let mut media_folder: Option<PathBuf> = None;
    let mut export = ExportArgs::default();
    let mut list_presets = false;
    let mut desktop_entry = None;
    let mut size_given = None;
    let mut light = false;
    let mut pitch = 6_u32;
    let mut states: Vec<String> = Vec::new();
    let mut known: Option<PathBuf> = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = |what: &str| it.next().ok_or_else(|| format!("{arg} needs {what}"));
        match arg.as_str() {
            "--ui-shot" | "--a11y-dump" | "--soak" | "--play-bench" | "--play-start" | "--engine-bench"
            | "--present-check" | "--mask-eval" | "--perf-project" | "--start-error-shot" | "--use-pass" => {
                mode = Some((arg.as_str(), PathBuf::from(value("an output path")?)))
            }
            "--pitch" => pitch = value("a number")?.parse::<u32>().ok().filter(|p| *p >= 2).ok_or("bad --pitch")?,
            "--known" => known = Some(PathBuf::from(value("a file")?)),
            "--states" => {
                states = value("a comma list")?.split(',').filter(|n| !n.is_empty()).map(String::from).collect()
            }
            "--eval-click" => {
                let text = value("x,y")?;
                let bad = || format!("bad click {text}, expected x,y");
                let (x, y) = text.split_once(',').ok_or_else(bad)?;
                eval_click = (x.parse().map_err(|_| bad())?, y.parse().map_err(|_| bad())?);
            }
            "--eval-disk" => eval_disk = Some(value("x,y,vx,vy,r")?.clone()),
            "--media" => media_folder = Some(PathBuf::from(value("a folder")?)),
            "--size" => {
                size = parse_size(value("WxH")?)?;
                size_given = Some(size);
            }
            "--export" => {
                export.out = PathBuf::from(value("an output file")?);
                mode = Some(("--export", export.out.clone()));
            }
            "--list-presets" => list_presets = true,
            "--desktop-entry" => {
                desktop_entry = Some(match value("add, remove or status")?.as_str() {
                    "add" => DesktopEntryCommand::Add,
                    "remove" => DesktopEntryCommand::Remove,
                    "status" => DesktopEntryCommand::Status,
                    _ => return Err("bad --desktop-entry, expected add, remove or status".into()),
                });
            }
            "--preset" => export.preset = Some(value("a preset name")?.clone()),
            "--hdr" => match value("hlg or pq")?.as_str() {
                h @ ("hlg" | "pq") => export.hdr = Some(h.to_string()),
                _ => return Err("bad --hdr, expected hlg or pq".into()),
            },
            "--no-hardware" => export.no_hardware = true,
            "--entire" => export.entire = true,
            "--overwrite" => export.overwrite = true,
            "--range" => {
                let text = value("in,out")?;
                let bad = || format!("bad --range {text}, expected in,out in seconds");
                let secs = |t: &str| t.parse::<f64>().ok().filter(|s| s.is_finite() && *s >= 0.0);
                let (a, b) = text.split_once(',').ok_or_else(bad)?;
                let (a, b) = (secs(a).ok_or_else(bad)?, secs(b).ok_or_else(bad)?);
                if b <= a {
                    return Err(bad());
                }
                export.range_ms = Some(((a * 1000.0).round() as i64, (b * 1000.0).round() as i64));
            }
            "--playhead" => {
                let secs = value("seconds")?.parse::<f64>().ok().filter(|s| s.is_finite() && *s >= 0.0);
                playhead_ms = (secs.ok_or("bad --playhead")? * 1000.0).round() as i64;
            }
            "--select" => pose.select = Some(value("a clip index or name")?.clone()),
            "--page" => match value("edit or color")?.as_str() {
                "color" => pose.color_page = true,
                "edit" => {}
                _ => return Err("bad --page".into()),
            },
            "--click" | "--dclick" => {
                let at = value("x,y")?.split_once(',').and_then(|(x, y)| Some((x.parse().ok()?, y.parse().ok()?)));
                let at = at.ok_or("bad --click, expected x,y")?;
                pose.clicks.extend(std::iter::repeat_n(at, if arg == "--dclick" { 2 } else { 1 }));
            }
            "--click-right" => {
                let at = value("x,y")?.split_once(',').and_then(|(x, y)| Some((x.parse().ok()?, y.parse().ok()?)));
                pose.right_clicks.push(at.ok_or("bad --click-right, expected x,y")?);
            }
            "--step" => {
                let text = value(STEP_HELP)?;
                pose.steps.push(parse_step(text).ok_or_else(|| format!("bad --step {text}, expected {STEP_HELP}"))?);
            }
            "--menu" => pose.menu = Some(value("a menu title or all")?.clone()),
            "--tour" => pose.tour = true,
            "--focus" => {
                let name = value("program, source, project, timeline, effect-controls or effects")?;
                pose.focus = Some(parse_focus(name).ok_or_else(|| format!("bad --focus {name}"))?);
            }
            "--menu-grid" => pose.menu_grid = true,
            "--pose" => pose.poses.push(value("a pose name")?.clone()),
            "--key" => {
                let text = value("a key like cmd+m")?;
                match parse_lone_modifier(text) {
                    Some(m) => pose.lone_modifiers.push(m),
                    None => pose.keys.push(parse_key(text).ok_or_else(|| format!("bad --key {text}"))?),
                }
            }
            "--theme" => match value("dark or light")?.as_str() {
                "dark" => light = false,
                "light" => light = true,
                _ => return Err("bad --theme, expected dark or light".into()),
            },
            "--scale" => {
                scale = value("a number")?.parse::<f32>().ok().filter(|s| *s > 0.0).ok_or("bad --scale")?;
            }
            other if !other.starts_with("--") && project.is_none() => project = Some(PathBuf::from(other)),
            other => return Err(format!("unknown argument {other}")),
        }
    }
    export.size = size_given;
    let mode = match mode {
        None if list_presets => Mode::ListPresets,
        None if desktop_entry.is_some() => Mode::DesktopEntry(desktop_entry.unwrap_or(DesktopEntryCommand::Status)),
        None => Mode::Window,
        Some(("--export", _)) => Mode::Export(export),
        Some(("--ui-shot", out)) => Mode::UiShot { out, width: size.0, height: size.1, scale, playhead_ms, pose },
        Some(("--use-pass", out)) => Mode::UsePass { out, width: size.0, height: size.1, pitch, states, known },
        Some(("--soak", out)) => Mode::Soak { out, width: size.0, height: size.1 },
        Some(("--play-bench", out)) => Mode::PlayBench { out, width: size.0, height: size.1 },
        Some(("--play-start", out)) => Mode::PlayStart { out },
        Some(("--engine-bench", out)) => Mode::EngineBench { out },
        Some(("--present-check", out)) => Mode::PresentCheck { out },
        Some(("--start-error-shot", out)) => Mode::StartErrorShot { out, scale, light },
        Some(("--perf-project", out)) => {
            Mode::PerfProject { out, media: media_folder.ok_or("--perf-project needs --media <folder>")? }
        }
        Some(("--mask-eval", out)) => Mode::MaskEval { out, click: eval_click, disk: eval_disk },
        Some((_, out)) => Mode::A11yDump { out, width: size.0, height: size.1 },
    };
    Ok(Cli { mode, project })
}

fn parse_size(text: &str) -> Result<(u32, u32), String> {
    let bad = || format!("bad size {text}, expected WxH");
    let (w, h) = text.split_once('x').ok_or_else(bad)?;
    match (w.parse::<u32>(), h.parse::<u32>()) {
        (Ok(w), Ok(h)) if w > 0 && h > 0 => Ok((w, h)),
        _ => Err(bad()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn steps_keep_their_order_across_clicks_text_and_chords() {
        let spec = "--ui-shot o.png --step click:10,20.5 --step type:Hi_5 --step key:ctrl+s --step select:Title";
        let c = parse(&args(&spec.split(' ').collect::<Vec<_>>())).expect("parses");
        let Mode::UiShot { pose, .. } = c.mode else { panic!("a shot") };
        assert_eq!(pose.steps.len(), 4);
        assert_eq!(pose.steps[0], Step::Click(10.0, 20.5));
        assert_eq!(pose.steps[1], Step::Type("Hi_5".into()));
        assert!(matches!(pose.steps[2], Step::Key(sq_draw::InputKey::Character('s'), _)));
        assert_eq!(pose.steps[3], Step::Select("Title".into()));
        assert!(parse(&args(&["--ui-shot", "o.png", "--step", "tap:1,2"])).is_err());
    }

    #[test]
    fn hover_wait_and_import_steps_parse_and_bad_ones_fail() {
        assert_eq!(parse_step("hover:4,5.5"), Some(Step::Hover(4.0, 5.5)));
        assert_eq!(parse_step("wait:250"), Some(Step::Wait(250)));
        assert_eq!(parse_step("import:/tmp/a b/clip.mp4"), Some(Step::Import("/tmp/a b/clip.mp4".into())));
        assert_eq!(
            parse_step("drag:1,2,30,40"),
            Some(Step::Drag { from: (1.0, 2.0), to: (30.0, 40.0), ms: DEFAULT_DRAG_MS })
        );
        assert_eq!(parse_step("drag:1,2,30,40,500"), Some(Step::Drag { from: (1.0, 2.0), to: (30.0, 40.0), ms: 500 }));
        assert_eq!(parse_step("wheel:5,6,-3"), Some(Step::Wheel { at: (5.0, 6.0), dy: -3.0, dx: 0.0, pad: false }));
        assert_eq!(
            parse_step("wheel:5,6,-3,2,pad"),
            Some(Step::Wheel { at: (5.0, 6.0), dy: -3.0, dx: 2.0, pad: true })
        );
        assert_eq!(
            parse_step("flick:5,6,-20,6,300"),
            Some(Step::Flick { at: (5.0, 6.0), dy: -20.0, frames: 6, until_ms: Some(300), move_to: None, win: false })
        );
        assert_eq!(
            parse_step("flick:5,6,-20"),
            Some(Step::Flick { at: (5.0, 6.0), dy: -20.0, frames: 8, until_ms: None, move_to: None, win: false })
        );
        assert_eq!(parse_step("flick:5,6,-20,0"), None);
        assert_eq!(
            parse_step("flick:5,6,-20,8,300,move=70:80@5"),
            Some(Step::Flick {
                at: (5.0, 6.0),
                dy: -20.0,
                frames: 8,
                until_ms: Some(300),
                move_to: Some(FlickMove { to: (70.0, 80.0), tail_frame: 5 }),
                win: false
            })
        );
        assert_eq!(
            parse_step("flick:5,6,-20,route=win"),
            Some(Step::Flick { at: (5.0, 6.0), dy: -20.0, frames: 8, until_ms: None, move_to: None, win: true })
        );
        assert_eq!(parse_step("flick:5,6,-20,route=linux"), None);
        assert_eq!(parse_step("flick:5,6,-20,8,300,9"), None);
        assert_eq!(parse_step("flick:5,6,-20,move=70@5"), None);
        for bad in [
            "hover:4",
            "wait:soon",
            "wait:-1",
            "wait:61000",
            "import:",
            "drag:1,2,3",
            "drag:1,2,3,4,soon",
            "drag:1,2,3,4,5,6",
            "wheel:1,2",
            "wheel:1,2,3,fast",
        ] {
            assert_eq!(parse_step(bad), None, "{bad}");
        }
    }

    #[test]
    fn the_start_error_shot_takes_a_theme_and_a_scale() {
        let c = parse(&args(&["--start-error-shot", "e.png", "--theme", "light", "--scale", "2"])).expect("parses");
        assert_eq!(c.mode, Mode::StartErrorShot { out: "e.png".into(), scale: 2.0, light: true });
        let c = parse(&args(&["--start-error-shot", "e.png"])).expect("parses");
        assert_eq!(c.mode, Mode::StartErrorShot { out: "e.png".into(), scale: 1.0, light: false });
        assert!(parse(&args(&["--start-error-shot", "e.png", "--theme", "blue"])).is_err());
    }

    #[test]
    fn the_perf_project_mode_needs_its_media_folder() {
        let c = parse(&args(&["--perf-project", "out/perf-layers.sqproj", "--media", "m"])).expect("parses");
        assert_eq!(c.mode, Mode::PerfProject { out: "out/perf-layers.sqproj".into(), media: "m".into() });
        assert!(parse(&args(&["--perf-project", "out.sqproj"])).is_err());
    }

    #[test]
    fn export_options_parse() {
        let c = parse(&args(&[
            "p.sqproj",
            "--export",
            "o.mp4",
            "--preset",
            "YouTube 1080p Full HD",
            "--range",
            "1.5,4",
            "--size",
            "640x360",
            "--hdr",
            "hlg",
            "--no-hardware",
        ]))
        .expect("parses");
        let Mode::Export(e) = c.mode else { panic!("not an export") };
        assert_eq!(e.out, PathBuf::from("o.mp4"));
        assert_eq!(e.preset.as_deref(), Some("YouTube 1080p Full HD"));
        assert_eq!(
            (e.range_ms, e.size, e.hdr.as_deref(), e.no_hardware),
            (Some((1500, 4000)), Some((640, 360)), Some("hlg"), true)
        );
        assert_eq!(parse(&args(&["--list-presets"])).map(|c| c.mode), Ok(Mode::ListPresets));
        assert_eq!(
            parse(&args(&["--desktop-entry", "remove"])).map(|c| c.mode),
            Ok(Mode::DesktopEntry(DesktopEntryCommand::Remove))
        );
        assert!(parse(&args(&["--desktop-entry", "maybe"])).is_err());
        assert!(parse(&args(&["--export", "o.mp4", "--range", "4,1"])).is_err());
        assert!(parse(&args(&["--export", "o.mp4", "--hdr", "sdr"])).is_err());
    }

    #[test]
    fn key_specs_take_modifiers_and_named_keys() {
        use sq_draw::{InputKey, InputModifiers};
        assert_eq!(parse_key("cmd+,"), Some((InputKey::Character(','), InputModifiers::COMMAND)));
        assert_eq!(
            parse_key("cmd+opt+n"),
            Some((InputKey::Character('n'), InputModifiers::COMMAND | InputModifiers::OPTION))
        );
        assert_eq!(parse_key("escape"), Some((InputKey::Escape, InputModifiers::NONE)));
        assert_eq!(parse_key("foo+x"), None);
        assert_eq!(parse_key("alt"), None);
        assert_eq!(parse_lone_modifier("alt"), Some(LoneModifier::Alt));
        assert_eq!(parse_lone_modifier("ctrl"), Some(LoneModifier::Ctrl));
        assert_eq!(parse_lone_modifier("shift"), Some(LoneModifier::Shift));
        assert_eq!(parse_lone_modifier("cmd"), None);
        let mac = sq_os::Platform::Mac;
        assert_eq!(parse_key_for(mac, "ctrl+space"), Some((InputKey::Space, InputModifiers::CONTROL)));
        for p in [sq_os::Platform::Windows, sq_os::Platform::Linux] {
            assert_eq!(parse_key_for(p, "ctrl+,"), Some((InputKey::Character(','), InputModifiers::COMMAND)));
        }
        assert_eq!(
            parse_key("cmd+shift+f9"),
            Some((InputKey::Function(9), InputModifiers::COMMAND | InputModifiers::SHIFT))
        );
        assert_eq!(parse_key("f12"), Some((InputKey::Function(12), InputModifiers::NONE)));
        assert_eq!(parse_key("f13"), None);
        assert_eq!(parse_key("shift+home"), Some((InputKey::Home, InputModifiers::SHIFT)));
        assert_eq!(parse_key("cmd+pageup"), Some((InputKey::PageUp, InputModifiers::COMMAND)));
        assert_eq!(parse_key("cmd+backspace"), Some((InputKey::Backspace, InputModifiers::COMMAND)));
        assert_eq!(parse_key("end"), Some((InputKey::End, InputModifiers::NONE)));
        let f = parse(&args(&["--ui-shot", "a.png", "--focus", "program", "--key", "f"])).map(|c| c.mode);
        assert!(
            matches!(f, Ok(Mode::UiShot { pose, .. }) if pose.focus == Some(sq_uikit::panel_id::PanelID::ProgramMonitor))
        );
        assert!(parse(&args(&["--ui-shot", "a.png", "--focus", "nope"])).is_err());
        let c = parse(&args(&["--ui-shot", "a.png", "--key", "cmd+m", "--key", "escape"])).map(|c| c.mode);
        assert!(matches!(c, Ok(Mode::UiShot { pose, .. }) if pose.keys.len() == 2));
        let a = parse(&args(&["--ui-shot", "a.png", "--key", "alt"])).map(|c| c.mode);
        assert!(
            matches!(a, Ok(Mode::UiShot { pose, .. }) if pose.lone_modifiers == [LoneModifier::Alt] && pose.keys.is_empty())
        );
    }

    #[test]
    fn no_arguments_open_the_window() {
        assert_eq!(parse(&[]).map(|c| c.mode), Ok(Mode::Window));
    }

    #[test]
    fn ui_shot_takes_size_and_scale() {
        let m = parse(&args(&["--ui-shot", "a.png", "--size", "800x600", "--scale", "2"])).map(|c| c.mode);
        assert_eq!(
            m,
            Ok(Mode::UiShot {
                out: "a.png".into(),
                width: 800,
                height: 600,
                scale: 2.0,
                playhead_ms: 0,
                pose: Pose::default()
            })
        );
    }

    #[test]
    fn ui_shot_takes_a_playhead_in_seconds() {
        let m = parse(&args(&["--ui-shot", "a.png", "--playhead", "1.5"])).map(|c| c.mode);
        assert!(matches!(m, Ok(Mode::UiShot { playhead_ms: 1500, .. })));
    }

    #[test]
    fn poses_select_a_clip_open_the_color_page_and_click() {
        let m = parse(&args(&[
            "--ui-shot",
            "a.png",
            "--select",
            "3",
            "--page",
            "color",
            "--click",
            "1,2",
            "--dclick",
            "3,4",
        ]));
        let Ok(Cli { mode: Mode::UiShot { pose, .. }, .. }) = m else { panic!("not a shot") };
        assert_eq!(pose.select.as_deref(), Some("3"));
        assert!(pose.color_page);
        assert_eq!(pose.clicks, [(1.0, 2.0), (3.0, 4.0), (3.0, 4.0)]);
    }

    #[test]
    fn poses_right_click_open_a_menu_and_show_the_tour() {
        let m = parse(&args(&["--ui-shot", "a.png", "--click-right", "5,6", "--menu", "Edit", "--tour"]));
        let Ok(Cli { mode: Mode::UiShot { pose, .. }, .. }) = m else { panic!("not a shot") };
        assert_eq!(pose.right_clicks, [(5.0, 6.0)]);
        assert_eq!(pose.menu.as_deref(), Some("Edit"));
        assert!(pose.tour);
    }

    #[test]
    fn defaults_to_the_reference_size() {
        let m = parse(&args(&["--a11y-dump", "t.txt"])).map(|c| c.mode);
        assert_eq!(m, Ok(Mode::A11yDump { out: "t.txt".into(), width: 1440, height: 900 }));
    }

    #[test]
    fn a_plain_argument_is_the_project() {
        let c = parse(&args(&["demo.sqproj", "--ui-shot", "a.png"]));
        assert_eq!(c.map(|c| c.project), Ok(Some(PathBuf::from("demo.sqproj"))));
    }

    #[test]
    fn rejects_bad_input() {
        for bad in [
            &["--size", "0x5"][..],
            &["--ui-shot"],
            &["--size", "10"],
            &["--scale", "-1"],
            &["--playhead", "-2"],
            &["--nope"],
            &["--page", "x"],
            &["--click", "5"],
        ] {
            assert!(parse(&args(bad)).is_err(), "{bad:?}");
        }
    }
}
