//! Small pure helpers of the session core: monitor quality and its governor, the offline card, the cache strip gate,
//! hover scrub maths, layer detail, save status, the delete key policy, tool hold and the command audit.

use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use sq_core_effects::evaluation::LayerRequest;
use sq_core_model::{Timeline, TrackKind};
use sq_core_time::{Id, Time, TimeRange, Timestamp};
use sq_media::video_decoding::DecodeScale;
use sq_uikit::command_catalog::CommandCatalog;
use sq_uikit::command_map::{CommandMap, Entry};
use sq_uikit::command_support::CommandSupport;
use sq_uikit::editor_command::{EditorCommand, EditorTool};
use sq_uikit::key_binding::Key;
use sq_uikit::keyboard_listing::KeyboardListing;
use sq_uikit::menu_spec::{EditorMenus, Item};

/// Playback quality. The fixed cases map 1:1 to `DecodeScale`; `Auto` is a monitor-only choice that the monitor
/// resolves to a fixed quality before it reaches the engine.
// Swift: MonitorQuality.swift:7
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum MonitorQuality {
    Full,
    Half,
    Quarter,
    Auto,
}

impl MonitorQuality {
    /// The fixed qualities (Settings lists these; Auto is its own entry there).
    // Swift: MonitorQuality.swift:10
    pub fn all_cases() -> [MonitorQuality; 3] {
        [MonitorQuality::Full, MonitorQuality::Half, MonitorQuality::Quarter]
    }

    /// Monitor popup rows: the fixed qualities, then Auto.
    // Swift: MonitorQuality.swift:12
    pub fn menu_cases() -> [MonitorQuality; 4] {
        [MonitorQuality::Full, MonitorQuality::Half, MonitorQuality::Quarter, MonitorQuality::Auto]
    }

    /// The raw value stored in settings.
    pub fn raw_value(self) -> &'static str {
        match self {
            MonitorQuality::Full => "full",
            MonitorQuality::Half => "half",
            MonitorQuality::Quarter => "quarter",
            MonitorQuality::Auto => "auto",
        }
    }

    // Swift: MonitorQuality.swift:13
    pub fn divisor(self) -> i64 {
        match self {
            MonitorQuality::Full | MonitorQuality::Auto => 1,
            MonitorQuality::Half => 2,
            MonitorQuality::Quarter => 4,
        }
    }

    // Swift: MonitorQuality.swift:17
    pub fn title(self) -> &'static str {
        match self {
            MonitorQuality::Full => "Full",
            MonitorQuality::Half => "1/2",
            MonitorQuality::Quarter => "1/4",
            MonitorQuality::Auto => "Auto",
        }
    }

    // Swift: MonitorQuality.swift:20
    pub fn decode_scale(self) -> DecodeScale {
        match self {
            MonitorQuality::Full | MonitorQuality::Auto => DecodeScale::Full,
            MonitorQuality::Half => DecodeScale::Half,
            MonitorQuality::Quarter => DecodeScale::Quarter,
        }
    }

    /// The quality of a decode scale (Swift `init(_ scale:)`).
    // Swift: MonitorQuality.swift:27
    pub fn from_scale(scale: DecodeScale) -> MonitorQuality {
        match scale {
            DecodeScale::Full => MonitorQuality::Full,
            DecodeScale::Half => MonitorQuality::Half,
            DecodeScale::Quarter => MonitorQuality::Quarter,
        }
    }

    /// Corner-badge form: "½", "¼"; none for full quality (the badge then shows only the zoom).
    // Swift: MonitorQuality.swift:32
    pub fn badge_symbol(self) -> Option<&'static str> {
        match self {
            MonitorQuality::Full => None,
            MonitorQuality::Half => Some("½"),
            MonitorQuality::Quarter => Some("¼"),
            MonitorQuality::Auto => Some("Auto"),
        }
    }

    /// The quality a sequence stores as its own preview quality.
    pub fn from_sequence(q: sq_core_model::SequencePreviewQuality) -> MonitorQuality {
        match q {
            sq_core_model::SequencePreviewQuality::Full => MonitorQuality::Full,
            sq_core_model::SequencePreviewQuality::Half => MonitorQuality::Half,
            sq_core_model::SequencePreviewQuality::Quarter => MonitorQuality::Quarter,
        }
    }

    /// A stored raw value; the retired "eighth" and "sixteenth" (old builds) read as quarter, what they decoded at.
    // Swift: MonitorQuality.swift:39
    pub fn stored(raw: &str) -> Option<MonitorQuality> {
        match raw {
            "eighth" | "sixteenth" | "quarter" => Some(MonitorQuality::Quarter),
            "full" => Some(MonitorQuality::Full),
            "half" => Some(MonitorQuality::Half),
            "auto" => Some(MonitorQuality::Auto),
            _ => None,
        }
    }

    /// `Auto` as a concrete quality (full); every other case is itself.
    fn fixed(self) -> MonitorQuality {
        if self == MonitorQuality::Auto { MonitorQuality::Full } else { self }
    }
}

/// The engine's counters since the last `play`: frame positions shown, skipped, and shown with a stand-in layer (late),
/// the run number (changes at Play, at a seek while playing and at a loop wrap) and whether the clock runs yet.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct PlayCounts {
    pub shown: u64,
    pub skipped: u64,
    pub late: u64,
    pub run: u64,
    /// False while Play waits for its first picture (the pre-roll).
    pub clock_running: bool,
}

impl PlayCounts {
    fn positions(self) -> u64 {
        self.shown + self.skipped
    }
    fn bad(self) -> u64 {
        self.skipped + self.late
    }
}

/// Where the Auto governor is in a play run.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum GovernorPhase {
    /// Not playing.
    Idle,
    /// Playing, ignoring the pre-roll (until the clock runs) and then `SETTLE_SECONDS` more (first decodes, and the
    /// re-decode after a step). `since` is set once the clock runs.
    Settling { run: u64, since: Option<f64> },
    /// Counting one `WINDOW_SECONDS` window from `since`.
    Watching { run: u64, since: f64, from: PlayCounts },
}

/// Playback quality "Auto": starts at `base` and steps one quality down (never below 1/4, the decoder floor) when a whole
/// `WINDOW_SECONDS` window of play had `LATE_SHARE_PERCENT` % or more of its frame positions skipped or late. The pre-roll
/// and `SETTLE_SECONDS` after it are not counted (also after a seek and after a step), and one bad frame never steps. A new
/// run (Play, seek, loop wrap: `PlayCounts::run`) restarts the window. A step stays across play runs but goes back to
/// `base` after `RESET_IDLE_SECONDS` without playing; `set_base` (settings, machine or sequence changed) starts over.
/// Pure: the host feeds the engine's counters and a clock.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct AutoQualityGovernor {
    base: MonitorQuality,
    current: MonitorQuality,
    phase: GovernorPhase,
    idle_since: Option<f64>,
}

impl AutoQualityGovernor {
    pub const SETTLE_SECONDS: f64 = 0.5;
    pub const WINDOW_SECONDS: f64 = 2.0;
    pub const LATE_SHARE_PERCENT: u64 = 10;
    pub const RESET_IDLE_SECONDS: f64 = 5.0;
    const LADDER: [MonitorQuality; 3] = [MonitorQuality::Full, MonitorQuality::Half, MonitorQuality::Quarter];

    pub fn new(base: MonitorQuality) -> AutoQualityGovernor {
        AutoQualityGovernor {
            base: base.fixed(),
            current: base.fixed(),
            phase: GovernorPhase::Idle,
            idle_since: None,
        }
    }

    /// The quality Auto starts at (the machine's pick, `auto_start_scale`).
    pub fn base(&self) -> MonitorQuality {
        self.base
    }

    /// The quality now.
    pub fn current(&self) -> MonitorQuality {
        self.current
    }

    pub fn phase(&self) -> GovernorPhase {
        self.phase
    }

    /// Re-bases the ladder (settings, machine pick or sequence changed).
    pub fn set_base(&mut self, q: MonitorQuality) {
        self.base = q.fixed();
        self.current = self.base;
        self.phase = GovernorPhase::Idle;
        self.idle_since = None;
    }

    /// One poll at `now` seconds.
    pub fn update(&mut self, counts: PlayCounts, is_playing: bool, now: f64) {
        if !is_playing {
            if self.phase != GovernorPhase::Idle || self.idle_since.is_none() {
                self.idle_since = Some(now);
            }
            self.phase = GovernorPhase::Idle;
            if self.idle_since.is_some_and(|t| now - t >= Self::RESET_IDLE_SECONDS) {
                self.current = self.base;
            }
            return;
        }
        self.idle_since = None;
        // A new run (or the first poll of play) restarts the window.
        let run = match self.phase {
            GovernorPhase::Idle => None,
            GovernorPhase::Settling { run, .. } | GovernorPhase::Watching { run, .. } => Some(run),
        };
        if run != Some(counts.run) {
            self.phase = GovernorPhase::Settling { run: counts.run, since: None };
        }
        if let GovernorPhase::Settling { run, since } = self.phase {
            // The settle time starts when the clock is released, not at Play.
            let since = match since {
                None if counts.clock_running => Some(now),
                other => other,
            };
            self.phase = match since {
                Some(t) if now - t >= Self::SETTLE_SECONDS => GovernorPhase::Watching { run, since: now, from: counts },
                _ => GovernorPhase::Settling { run, since },
            };
            return;
        }
        if let GovernorPhase::Watching { run, since, from } = self.phase
            && now - since >= Self::WINDOW_SECONDS
        {
            let positions = counts.positions().saturating_sub(from.positions());
            let bad = counts.bad().saturating_sub(from.bad());
            self.phase = if positions > 0 && bad * 100 >= positions * Self::LATE_SHARE_PERCENT {
                self.step_down();
                GovernorPhase::Settling { run, since: Some(now) }
            } else {
                GovernorPhase::Watching { run, since: now, from: counts }
            };
        }
    }

    fn step_down(&mut self) {
        let at = Self::LADDER.iter().position(|q| *q == self.current).unwrap_or(0);
        self.current = Self::LADDER[(at + 1).min(Self::LADDER.len() - 1)];
    }
}

impl Default for AutoQualityGovernor {
    fn default() -> AutoQualityGovernor {
        AutoQualityGovernor::new(MonitorQuality::Full)
    }
}

/// The monitor's "Media offline" card: which file to name for the picture at `time`.
pub enum MediaOfflineCard {}

impl MediaOfflineCard {
    /// File name of the topmost visible video clip under `time` whose media is offline. `offline_name` returns the
    /// file name for an offline media id and `None` for online media.
    // Swift: AutoQualityGovernor.swift:54
    pub fn file_name(timeline: &Timeline, time: Time, offline_name: impl Fn(Id) -> Option<String>) -> Option<String> {
        for track in timeline.tracks.iter().rev().filter(|t| t.kind == TrackKind::Video && t.is_visible) {
            let Some(clip) = track.clips().iter().find(|c| c.timeline().contains(time)) else { continue };
            if let Some(name) = offline_name(clip.media) {
                return Some(name);
            }
        }
        None
    }
}

/// Poll gate for the timeline's render-cache strip: asks the engine for its cached spans at most every `interval`
/// seconds, and only when the frame cache, the sequence length or the undo step changed since the last look.
// Swift: CacheStripGate.swift:6
#[derive(Clone, Debug)]
pub struct CacheStripGate {
    // Swift: CacheStripGate.swift:7
    pub interval: f64,
    last_key: Option<(i64, Option<Time>, Option<String>)>,
    last_check: f64,
}

impl CacheStripGate {
    // Swift: CacheStripGate.swift:10
    pub fn new(interval: f64) -> CacheStripGate {
        CacheStripGate { interval, last_key: None, last_check: f64::NEG_INFINITY }
    }

    /// The new spans, or `None` when nothing needs updating.
    // Swift: CacheStripGate.swift:12
    pub fn spans(
        &mut self,
        now: f64,
        generation: i64,
        duration: Option<Time>,
        undo_name: Option<&str>,
        fetch: impl FnOnce() -> Vec<TimeRange>,
    ) -> Option<Vec<TimeRange>> {
        if now - self.last_check < self.interval {
            return None;
        }
        self.last_check = now;
        let key = (generation, duration, undo_name.map(str::to_string));
        if self.last_key.as_ref() == Some(&key) {
            return None;
        }
        self.last_key = Some(key);
        Some(fetch())
    }
}

impl Default for CacheStripGate {
    fn default() -> CacheStripGate {
        CacheStripGate::new(0.5)
    }
}

/// Pure maths of hover scrubbing an icon: where the pointer is inside the thumbnail picks the time in the media.
pub enum HoverScrub {}

impl HoverScrub {
    /// Time at `fraction` (0...1, clamped) of `duration`, snapped to `frame_duration`, never past the last frame.
    // Swift: HoverScrub.swift:6
    pub fn time(fraction: f64, duration: Time, frame_duration: Time) -> Time {
        if duration <= Time::ZERO || frame_duration.value() <= 0 {
            return Time::ZERO;
        }
        let f = fraction.clamp(0.0, 1.0);
        let scale: i64 = 1_000;
        let raw = Time::new((f * scale as f64).round() as i64 * duration.value(), scale * duration.timescale());
        let last = (duration - frame_duration).max(Time::ZERO);
        raw.snapped(frame_duration).min(last)
    }

    /// Poster frame: 10 % into the media, at most 2 s (a clip often starts black).
    // Swift: HoverScrub.swift:16
    pub fn poster(duration: Time, frame_duration: Time) -> Time {
        HoverScrub::time(0.1, duration, frame_duration).min(Time::new(2, 1))
    }
}

/// The detail a layer needs while playing or scrubbing: a layer drawn at half its native size or less on its
/// sequence's canvas is decoded at half, a quarter or less at a quarter. Tilted layers keep full detail.
pub enum PlaybackLayerDetail {}

impl PlaybackLayerDetail {
    /// Scale margin: a layer up to 10 % above half (quarter) size still uses the half (quarter) picture.
    const MARGIN: f64 = 1.1;

    /// 1, 2 or 4: the divisor of the layer's picture size.
    // Swift: PlaybackLayerDetail.swift:13
    pub fn divisor(l: &LayerRequest) -> i64 {
        if l.transform.is_tilted() {
            return 1;
        }
        let mut s = drawn_scale(&l.transform);
        for g in &l.groups {
            if g.transform.is_tilted() {
                return 1;
            }
            s *= drawn_scale(&g.transform);
        }
        if s <= 0.25 * Self::MARGIN {
            4
        } else if s <= 0.5 * Self::MARGIN {
            2
        } else {
            1
        }
    }
}

fn drawn_scale(t: &sq_core_model::ClipTransform) -> f64 {
    t.scale.x.abs().max(t.scale.y.abs())
}

/// What kind of status the save line shows.
// Swift: SaveStatus.swift:8
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SaveStatusKind {
    Saved,
    Edited,
    UnsavedNew,
    Empty,
}

/// The status bar's save state, one pure function of what is true on disk.
// Swift: SaveStatus.swift:8
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SaveStatus {
    // Swift: SaveStatus.swift:9
    pub kind: SaveStatusKind,
    // Swift: SaveStatus.swift:10
    pub text: String,
}

impl SaveStatus {
    /// `is_dirty`: edits since the last write to the project file. `has_file`: saved to a file at least once.
    /// `last_edit` / `last_backup`: when the project changed / the recovery copy was written. `utc_offset_seconds`
    /// is the time zone of the backup clock text (Swift `timeZone`).
    // Swift: SaveStatus.swift:16
    pub fn make(
        is_dirty: bool,
        has_file: bool,
        last_edit: Option<Timestamp>,
        last_backup: Option<Timestamp>,
        utc_offset_seconds: i64,
    ) -> SaveStatus {
        if !is_dirty {
            return if has_file {
                SaveStatus { kind: SaveStatusKind::Saved, text: "Saved".into() }
            } else {
                SaveStatus { kind: SaveStatusKind::Empty, text: "No changes".into() }
            };
        }
        let mut text = (if has_file { "Edited" } else { "Not saved" }).to_string();
        // A backup counts only when it was written after the last edit; an older one does not cover the change.
        if let Some(b) = last_backup
            && last_edit.is_none_or(|e| b.unix_seconds() >= e.unix_seconds())
        {
            text.push_str(" · Backup ");
            text.push_str(&Self::clock(b, utc_offset_seconds));
        }
        let kind = if has_file { SaveStatusKind::Edited } else { SaveStatusKind::UnsavedNew };
        SaveStatus { kind, text }
    }

    /// The status of a project repaired from a damaged file, not saved yet: says so instead of a bare "Not saved".
    pub fn repaired(mut self) -> SaveStatus {
        if self.kind == SaveStatusKind::UnsavedNew {
            self.text = self.text.replacen("Not saved", "Repaired copy, not saved", 1);
        }
        self
    }

    /// "HH:mm" in the zone.
    fn clock(date: Timestamp, utc_offset_seconds: i64) -> String {
        let day = (date.unix_seconds().floor() as i64 + utc_offset_seconds).rem_euclid(86_400);
        format!("{:02}:{:02}", day / 3600, day % 3600 / 60)
    }
}

/// What the app's key monitor does with a Delete / Forward-Delete key event that the key router has no action for.
pub enum DeleteKeyPolicy {}

/// Where a Delete key event goes.
// Swift: DeleteKeyPolicy.swift:9
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeleteRoute {
    /// Leave the event to the responder (an editable text view or a list that deletes by itself).
    PassToResponder,
    /// The router already handled or deliberately swallowed it.
    Consume,
    /// Try the Edit menu's Delete item: handled -> consume silently; refused -> pass on (error beep).
    MenuThenBeepIfRefused,
}

/// The responder that has the key focus.
// Swift: DeleteKeyPolicy.swift:15
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DeleteResponder {
    EditableText,
    DeletingList,
    Other,
}

impl DeleteKeyPolicy {
    // Swift: DeleteKeyPolicy.swift:18
    pub fn route(responder: DeleteResponder, router_consumed: bool, router_has_actions: bool) -> DeleteRoute {
        if responder != DeleteResponder::Other {
            return DeleteRoute::PassToResponder;
        }
        if router_consumed || router_has_actions {
            return DeleteRoute::Consume;
        }
        DeleteRoute::MenuThenBeepIfRefused
    }

    /// True = the menu did the delete: swallow the key down (and its key up) silently.
    // Swift: DeleteKeyPolicy.swift:26
    pub fn swallow(menu_handled: bool) -> bool {
        menu_handled
    }
}

/// Hold-to-temp tools. A tool key switches immediately on key down; a tap (up before `THRESHOLD`) leaves it as a
/// normal sticky switch, a longer hold reverts to the tool that was active before on key up.
// Swift: ToolHold.swift:6
#[derive(Clone, Copy, Debug, Default)]
pub struct ToolHold {
    active: Option<HeldKey>,
}

#[derive(Clone, Copy, Debug)]
struct HeldKey {
    key: Key,
    tool: EditorTool,
    previous: EditorTool,
    start: f64,
}

impl ToolHold {
    // Swift: ToolHold.swift:7
    pub const THRESHOLD: f64 = 0.25;

    // Swift: ToolHold.swift:9
    pub fn new() -> ToolHold {
        ToolHold { active: None }
    }

    /// A tool key went down. `previous` is the tool that was active before this press. Auto-repeats of the held key are
    /// ignored; a second tool key during a hold keeps the tool from before the chain.
    // Swift: ToolHold.swift:14
    pub fn press(&mut self, key: Key, tool: EditorTool, previous: EditorTool, time: f64) {
        match self.active {
            Some(a) if a.key == key => {}
            Some(a) => self.active = Some(HeldKey { key, tool, previous: a.previous, start: time }),
            None => self.active = Some(HeldKey { key, tool, previous, start: time }),
        }
    }

    /// The key came up. Returns the tool to go back to when it was a hold that changed the tool.
    // Swift: ToolHold.swift:24
    pub fn release(&mut self, key: Key, time: f64) -> Option<EditorTool> {
        let a = self.active.filter(|a| a.key == key)?;
        self.active = None;
        (time - a.start >= Self::THRESHOLD && a.previous != a.tool).then_some(a.previous)
    }

    /// Focus loss: the held key's key-up will not come. Ends the hold as if it came now.
    // Swift: ToolHold.swift:31
    pub fn release_all(&mut self, time: f64) -> Option<EditorTool> {
        let a = self.active?;
        self.release(a.key, time)
    }

    // Swift: ToolHold.swift:35
    pub fn clear(&mut self) {
        self.active = None;
    }
}

/// One row per command: where it sits in the menus, which keys it has per scope, whether the app wires it.
// Swift: CommandAudit.swift:5
#[derive(Clone, Debug)]
pub struct CommandAuditRow {
    // Swift: CommandAudit.swift:6
    pub command: EditorCommand,
    // Swift: CommandAudit.swift:7
    pub menu_path: Option<String>,
    // Swift: CommandAudit.swift:8
    pub keys: Vec<Entry>,
    // Swift: CommandAudit.swift:9
    pub supported: bool,
}

/// The audit of commands against menus and keys (parity tests, the dev aid that prints the table).
pub enum CommandAudit {}

impl CommandAudit {
    /// "Menu > Submenu" per command listed in the editor menus (Window panel items map to the Window menu).
    // Swift: CommandAudit.swift:14
    pub fn menu_paths() -> std::collections::HashMap<EditorCommand, String> {
        fn walk(items: &[Item], path: &str, out: &mut std::collections::HashMap<EditorCommand, String>) {
            for item in items {
                match item {
                    Item::Command(c) => {
                        out.entry(*c).or_insert_with(|| path.to_string());
                    }
                    Item::Separator => {}
                    Item::Submenu(t, sub) => walk(sub, &format!("{path} > {t}"), out),
                }
            }
        }
        let mut out = std::collections::HashMap::new();
        for m in EditorMenus::all() {
            walk(&m.items, &m.title, &mut out);
        }
        for p in EditorMenus::window_panels() {
            out.entry(EditorCommand::FocusPanel(*p)).or_insert_with(|| "Window".to_string());
        }
        out
    }

    // Swift: CommandAudit.swift:29
    pub fn rows(map: &CommandMap) -> Vec<CommandAuditRow> {
        let paths = Self::menu_paths();
        CommandCatalog::audited(map)
            .into_iter()
            .map(|c| CommandAuditRow {
                menu_path: paths.get(&c).cloned(),
                keys: map.entries.iter().filter(|e| e.command == c).copied().collect(),
                supported: CommandSupport::is_supported(&c),
                command: c,
            })
            .collect()
    }

    /// Plain-text table, one line per command.
    // Swift: CommandAudit.swift:39
    pub fn table(map: &CommandMap) -> String {
        Self::rows(map)
            .iter()
            .map(|r| {
                let keys = r
                    .keys
                    .iter()
                    .map(|k| {
                        format!("{}: {}", KeyboardListing::scope_name(k.scope), KeyboardListing::text_for(&k.binding))
                    })
                    .collect::<Vec<_>>()
                    .join("; ");
                format!(
                    "{} | {} | {} | {}",
                    r.command.title(),
                    r.menu_path.as_deref().unwrap_or("-"),
                    if keys.is_empty() { "-" } else { &keys },
                    if r.supported { "wired" } else { "NOT WIRED" }
                )
            })
            .collect::<Vec<_>>()
            .join("\n")
    }
}

/// A serial queue whose every job is answered by a deadline: the caller goes on with `None` when its job has not
/// finished (or not even started, behind a job that hangs) in time, and the late result is dropped. While a job is
/// overdue the queue is stuck: new jobs are answered with `None` at once, until the overdue job comes back. `restart`
/// moves on to a fresh queue instead, so one call that never returns cannot switch the queue off for good.
/// Blocking: the app runs it on the worker pool (Swift awaited a continuation instead).
// Swift: DeadlineQueue.swift:1
pub struct DeadlineQueue {
    state: Arc<Mutex<QueueState>>,
}

struct QueueState {
    sender: mpsc::Sender<Box<dyn FnOnce() + Send>>,
    generation: u64,
    /// Jobs of this generation that passed their deadline and have not come back.
    overdue: i64,
}

fn spawn_queue() -> mpsc::Sender<Box<dyn FnOnce() + Send>> {
    let (tx, rx) = mpsc::channel::<Box<dyn FnOnce() + Send>>();
    std::thread::spawn(move || {
        while let Ok(job) = rx.recv() {
            job();
        }
    });
    tx
}

impl DeadlineQueue {
    pub fn new() -> DeadlineQueue {
        DeadlineQueue { state: Arc::new(Mutex::new(QueueState { sender: spawn_queue(), generation: 0, overdue: 0 })) }
    }

    /// Runs `work` on the queue and returns its result, or `None` when `deadline` passed first or the queue is stuck.
    // Swift: DeadlineQueue.swift:32
    pub fn run<T: Send + 'static>(
        &self,
        deadline: Duration,
        restart: bool,
        work: impl FnOnce() -> Option<T> + Send + 'static,
    ) -> Option<T> {
        let (sender, generation) = {
            let mut s = self.state.lock().ok()?;
            if s.overdue > 0 {
                if !restart {
                    return None;
                }
                s.generation += 1;
                s.overdue = 0;
                s.sender = spawn_queue();
            }
            (s.sender.clone(), s.generation)
        };
        let (answer_tx, answer_rx) = mpsc::channel::<Option<T>>();
        let answered_late = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let late = Arc::clone(&answered_late);
        let state = Arc::clone(&self.state);
        let job = Box::new(move || {
            let r = work();
            if answer_tx.send(r).is_err() || late.load(std::sync::atomic::Ordering::SeqCst) {
                // Answered after its deadline: the queue works again.
                if let Ok(mut s) = state.lock()
                    && s.generation == generation
                {
                    s.overdue = (s.overdue - 1).max(0);
                }
            }
        });
        sender.send(job).ok()?;
        match answer_rx.recv_timeout(deadline) {
            Ok(r) => r,
            Err(_) => {
                answered_late.store(true, std::sync::atomic::Ordering::SeqCst);
                if let Ok(mut s) = self.state.lock()
                    && s.generation == generation
                {
                    s.overdue += 1;
                }
                None
            }
        }
    }
}

impl Default for DeadlineQueue {
    fn default() -> DeadlineQueue {
        DeadlineQueue::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A play session: polls every 0.5 s, `bad_per_poll` of each poll's 15 positions bad.
    struct Run {
        g: AutoQualityGovernor,
        c: PlayCounts,
        now: f64,
    }

    impl Run {
        fn new(base: MonitorQuality) -> Run {
            Run { g: AutoQualityGovernor::new(base), c: PlayCounts { run: 1, clock_running: true, ..Default::default() }, now: 0.0 }
        }
        fn play(&mut self, seconds: f64, bad_per_poll: u64) {
            for _ in 0..(seconds / 0.5).round() as u64 {
                self.now += 0.5;
                self.c.shown += 15 - bad_per_poll;
                self.c.skipped += bad_per_poll;
                self.g.update(self.c, true, self.now);
            }
        }
    }

    #[test]
    fn governor_ignores_a_hiccup_and_the_first_half_second() {
        let mut r = Run::new(MonitorQuality::Full);
        r.g.update(r.c, true, 0.0);
        r.play(0.5, 15); // all bad inside the settle time
        assert!(matches!(r.g.phase(), GovernorPhase::Watching { .. }));
        r.play(0.5, 1); // 1 bad of 60 in the window
        r.play(1.5, 0);
        assert_eq!(r.g.current(), MonitorQuality::Full);
    }

    #[test]
    fn governor_steps_down_on_a_sustained_window_and_keeps_it_across_runs() {
        let mut r = Run::new(MonitorQuality::Full);
        r.g.update(r.c, true, 0.0);
        r.play(0.5, 0);
        r.play(2.0, 3); // 20 % late
        assert_eq!(r.g.current(), MonitorQuality::Half);
        assert!(matches!(r.g.phase(), GovernorPhase::Settling { .. }), "a step settles again");
        r.play(2.5, 3);
        assert_eq!(r.g.current(), MonitorQuality::Quarter);
        r.play(5.0, 8);
        assert_eq!(r.g.current(), MonitorQuality::Quarter, "never below a quarter");
        // Stop for a moment and play again with new counters: the step stays.
        r.g.update(r.c, false, r.now);
        r.now += 2.0;
        r.c = PlayCounts { run: 2, clock_running: true, ..Default::default() };
        r.g.update(r.c, true, r.now);
        assert_eq!(r.g.current(), MonitorQuality::Quarter);
        r.g.set_base(MonitorQuality::Auto);
        assert_eq!((r.g.base(), r.g.current()), (MonitorQuality::Full, MonitorQuality::Full));
    }

    #[test]
    fn governor_goes_back_to_the_start_after_five_idle_seconds() {
        let mut r = Run::new(MonitorQuality::Half);
        r.g.update(r.c, true, 0.0);
        r.play(0.5, 0);
        r.play(2.0, 3);
        assert_eq!(r.g.current(), MonitorQuality::Quarter);
        r.g.update(r.c, false, r.now);
        r.g.update(r.c, false, r.now + 4.0);
        assert_eq!(r.g.current(), MonitorQuality::Quarter, "not yet");
        r.g.update(r.c, false, r.now + 5.5);
        assert_eq!(r.g.current(), MonitorQuality::Half);
    }

    #[test]
    fn governor_waits_for_the_clock_and_restarts_its_window_on_a_new_run() {
        let mut r = Run::new(MonitorQuality::Full);
        // A pre-roll of 3 s: the clock is held, every position late; nothing counts and nothing steps.
        r.c.clock_running = false;
        for _ in 0..6 {
            r.now += 0.5;
            r.c.skipped += 15;
            r.g.update(r.c, true, r.now);
        }
        assert_eq!(r.g.current(), MonitorQuality::Full);
        assert!(matches!(r.g.phase(), GovernorPhase::Settling { since: None, .. }));
        r.c.clock_running = true;
        r.play(1.0, 0); // settles 0.5 s from the release
        assert!(matches!(r.g.phase(), GovernorPhase::Watching { .. }));
        r.play(1.5, 3);
        // A seek: a new run, the window starts over, so 0.5 s later it is not judged.
        r.c.run += 1;
        r.play(0.5, 3);
        assert!(matches!(r.g.phase(), GovernorPhase::Settling { .. }));
        assert_eq!(r.g.current(), MonitorQuality::Full);
    }

    #[test]
    fn governor_counts_late_frames_like_skipped_ones_and_starts_from_the_base() {
        let mut r = Run::new(MonitorQuality::Half);
        r.g.update(r.c, true, 0.0);
        for _ in 0..5 {
            r.now += 0.5;
            r.c.shown += 15;
            r.c.late += 3;
            r.g.update(r.c, true, r.now);
        }
        assert_eq!(r.g.current(), MonitorQuality::Quarter);
    }

    #[test]
    fn governor_does_not_judge_a_pause() {
        let mut g = AutoQualityGovernor::new(MonitorQuality::Full);
        for i in 0..20 {
            g.update(PlayCounts { shown: 0, skipped: 99, late: 0, run: 1, clock_running: true }, false, i as f64);
        }
        assert_eq!((g.current(), g.phase()), (MonitorQuality::Full, GovernorPhase::Idle));
    }

    #[test]
    fn stored_quality_reads_retired_values_as_quarter() {
        assert_eq!(MonitorQuality::stored("sixteenth"), Some(MonitorQuality::Quarter));
        assert_eq!(MonitorQuality::stored("half"), Some(MonitorQuality::Half));
        assert_eq!(MonitorQuality::stored("x"), None);
        assert_eq!(MonitorQuality::Quarter.decode_scale(), DecodeScale::Quarter);
        assert_eq!(MonitorQuality::from_scale(DecodeScale::Half), MonitorQuality::Half);
        assert_eq!(MonitorQuality::menu_cases().last(), Some(&MonitorQuality::Auto));
    }

    #[test]
    fn cache_gate_polls_at_the_interval_and_only_on_change() {
        let mut g = CacheStripGate::new(0.5);
        let d = Some(Time::seconds(4));
        assert!(g.spans(0.0, 1, d, Some("a"), Vec::new).is_some());
        assert!(g.spans(0.2, 2, d, Some("a"), Vec::new).is_none());
        assert!(g.spans(0.6, 1, d, Some("a"), Vec::new).is_none());
        assert!(g.spans(1.2, 2, d, Some("a"), Vec::new).is_some());
        assert!(g.spans(1.8, 2, d, Some("b"), Vec::new).is_some());
    }

    #[test]
    fn hover_scrub_snaps_and_stays_before_the_last_frame() {
        let fd = Time::new(1, 10);
        let dur = Time::seconds(10);
        assert_eq!(HoverScrub::time(0.5, dur, fd), Time::seconds(5));
        assert_eq!(HoverScrub::time(2.0, dur, fd), Time::new(99, 10));
        assert_eq!(HoverScrub::time(-1.0, dur, fd), Time::ZERO);
        assert_eq!(HoverScrub::time(0.5, Time::ZERO, fd), Time::ZERO);
        assert_eq!(HoverScrub::poster(Time::seconds(100), fd), Time::seconds(2));
        assert_eq!(HoverScrub::poster(Time::seconds(10), fd), Time::seconds(1));
    }

    #[test]
    fn save_status_texts() {
        let t = |s: f64| Some(Timestamp::from_unix_seconds(s));
        assert_eq!(SaveStatus::make(false, true, None, None, 0).text, "Saved");
        assert_eq!(SaveStatus::make(false, false, None, None, 0).kind, SaveStatusKind::Empty);
        assert_eq!(SaveStatus::make(true, true, t(100.0), None, 0).text, "Edited");
        assert_eq!(SaveStatus::make(true, false, t(100.0), t(50.0), 0).text, "Not saved");
        assert_eq!(
            SaveStatus::make(true, false, t(100.0), t(50.0), 0).repaired().text,
            "Repaired copy, not saved",
            "a repaired copy says where it comes from"
        );
        assert_eq!(
            SaveStatus::make(true, true, None, None, 0).repaired().text,
            "Edited",
            "once it has a file, no change"
        );
        let s = SaveStatus::make(true, true, t(100.0), t(3600.0 * 13.0 + 60.0 * 5.0), 3600);
        assert_eq!((s.kind, s.text.as_str()), (SaveStatusKind::Edited, "Edited · Backup 14:05"));
        assert_eq!(SaveStatus::make(true, false, None, t(0.0), 0).text, "Not saved · Backup 00:00");
    }

    #[test]
    fn delete_key_policy_routes() {
        use DeleteResponder::*;
        assert_eq!(DeleteKeyPolicy::route(EditableText, true, true), DeleteRoute::PassToResponder);
        assert_eq!(DeleteKeyPolicy::route(Other, true, false), DeleteRoute::Consume);
        assert_eq!(DeleteKeyPolicy::route(Other, false, true), DeleteRoute::Consume);
        assert_eq!(DeleteKeyPolicy::route(Other, false, false), DeleteRoute::MenuThenBeepIfRefused);
        assert!(DeleteKeyPolicy::swallow(true) && !DeleteKeyPolicy::swallow(false));
    }

    #[test]
    fn tool_hold_reverts_only_after_a_long_hold() {
        use EditorTool::*;
        let mut h = ToolHold::new();
        h.press(Key::Char('b'), Ripple, Selection, 0.0);
        assert_eq!(h.release(Key::Char('b'), 0.1), None);
        h.press(Key::Char('b'), Ripple, Selection, 1.0);
        h.press(Key::Char('b'), Ripple, Selection, 1.1);
        h.press(Key::Char('c'), Razor, Ripple, 1.2);
        assert_eq!(h.release(Key::Char('b'), 2.0), None);
        assert_eq!(h.release(Key::Char('c'), 2.0), Some(Selection));
        h.press(Key::Char('c'), Razor, Selection, 3.0);
        assert_eq!(h.release_all(3.5), Some(Selection));
        h.press(Key::Char('c'), Razor, Selection, 4.0);
        h.clear();
        assert_eq!(h.release(Key::Char('c'), 9.0), None);
    }

    #[test]
    fn deadline_queue_answers_in_time_and_gives_up_on_a_stuck_job() {
        let q = DeadlineQueue::new();
        assert_eq!(q.run(Duration::from_secs(2), false, || Some(7)), Some(7));
        let slow = q.run(Duration::from_millis(20), false, || {
            std::thread::sleep(Duration::from_millis(300));
            Some(1)
        });
        assert_eq!(slow, None);
        // Stuck: answered at once.
        assert_eq!(q.run(Duration::from_secs(2), false, || Some(2)), None);
        // A restart moves on to a fresh queue.
        assert_eq!(q.run(Duration::from_secs(2), true, || Some(3)), Some(3));
    }

    #[test]
    fn menu_paths_name_the_menu_of_each_command() {
        let paths = CommandAudit::menu_paths();
        assert!(!paths.is_empty());
        assert!(paths.values().any(|p| p.contains(" > ")));
    }

    #[test]
    fn offline_card_names_the_topmost_offline_clip_under_the_playhead() {
        use sq_core_model::{Clip, SequenceFormat, Track};
        let mk = |media: u8, visible| {
            let mut t = Track::new(Id::fixed(100 + u64::from(media)), TrackKind::Video);
            t.is_visible = visible;
            let source = TimeRange::new(Time::ZERO, Time::seconds(4));
            let c = Clip::new(
                Id::fixed(200 + u64::from(media)),
                "c",
                Id::fixed(u64::from(media)),
                TrackKind::Video,
                source,
                Time::ZERO,
            );
            t.set_clips(vec![c]);
            t
        };
        let format = SequenceFormat::new(Time::new(1, 30));
        let tl = Timeline::new(Id::fixed(1), "T", format, vec![mk(1, true), mk(2, true), mk(3, false)]);
        let name = |id: Id| (1..=3).any(|n| id == Id::fixed(n)).then(|| "offline".to_string());
        // Track 3 is hidden, so the topmost visible offline clip is media 2: the card names it.
        let only2 = |id: Id| (id == Id::fixed(2)).then(|| "two".to_string());
        assert_eq!(MediaOfflineCard::file_name(&tl, Time::seconds(1), only2), Some("two".to_string()));
        assert_eq!(MediaOfflineCard::file_name(&tl, Time::seconds(1), name), Some("offline".to_string()));
        assert_eq!(MediaOfflineCard::file_name(&tl, Time::seconds(9), name), None);
        assert_eq!(MediaOfflineCard::file_name(&tl, Time::seconds(1), |_| None), None);
    }
}
