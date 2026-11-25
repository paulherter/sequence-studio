// Swift: ShellStart.swift, ShellStartWindows.swift (the `ShellHost` side)
//! The start screen translated from the Mac `StartWindowView` (design "Start Screen B", `StartScreenTokens`): a top bar with
//! the search field, the rail (New project, Open…, the Browse tabs, Support card, "Open last project on launch", links),
//! one pane (Home, Recent, Templates, Learn) and a status bar. It covers the window under the menu bar while no project is
//! open (the Mac shows it as its own window and hides the editor). Same models: `RecentProjects::listing`, `StartLabels`,
//! `StartProjectInfo`, `ProjectTemplate::built_in`, `TemplateFolder`, the same keys (`sq.start.tab`, `sq.start.sort`,
//! `sq.start.listLayout`, `sq.reopenLastOnLaunch`).
//! No Appearance popover and no hover … button on template cards (right click only): both match Swift's
//! `ShellStartScreen`. Card pictures come from the host's `start_poster` hook through [`StartEnv::poster`] (Swift `startPoster`).
//!
//! Mapping (docs/rust/session-ui-design.md section 2): the screen does not know the host. Everything the Swift code read
//! from `host` comes in a [`StartEnv`]; everything it did to the host (`execute`, `perform`, open, menus, settings) is a
//! [`StartAction`] the host applies after the call ([`ShellHost::apply_start_actions`]). Persisted settings leave as
//! [`ShellEvent::Setting`]. Pip (`drawsStartMascots`) is drawn when `ShellHost::draws_start_mascots` is set.
//! `reload` reads the recents' files on the calling thread (Swift ran it detached): upgrade with the executor's blocking pool.

use crate::project_list_view::ProjectPoster;
use crate::shell_host::{ShellCx, ShellEvent, ShellFlow, ShellHost, StartSettings};
use crate::shell_mascot_stage::ShellMascotStage;
use crate::shell_menu_bar::ShellAction;
use crate::shell_platform_text::ShellPlatformText;
use crate::shell_start_windows::{ShellStartWindows, StartWindowState, StartWindowStep};
use sq_core_project::media_grouping::GroupingCalendar;
use sq_core_project::project_template::{ProjectTemplate, TemplateFolder};
use sq_core_project::support_policy::{StartOverlayPolicy, SupportEntry, SupportLinks};
use sq_core_time::{Id, Timestamp};
use sq_draw::scroll::ScrollBody;
use sq_draw::{Alignment, InputEvent, InputKey, InputModifiers, TextFieldControl, TextMeasure, UiCx};
use sq_editor_session::{RecentEntry, RecentOrder, RecentProjects, StartLabels, StartProjectInfo};
use sq_os::Platform;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::rc::Rc;

/// The Browse tabs of the rail.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartTab {
    /// Continue, size tiles and your templates.
    Home,
    /// The recent projects.
    Recent,
    /// Built-in and saved templates.
    Templates,
    /// The short lessons.
    Learn,
    /// What to test and what changed.
    WhatsNew,
}

impl StartTab {
    /// All tabs in rail order.
    pub const ALL: [StartTab; 5] =
        [StartTab::Home, StartTab::Recent, StartTab::Templates, StartTab::Learn, StartTab::WhatsNew];

    /// The title and stored value.
    pub fn raw(self) -> &'static str {
        match self {
            StartTab::Home => "Home",
            StartTab::Recent => "Recent",
            StartTab::Templates => "Templates",
            StartTab::Learn => "Learn",
            StartTab::WhatsNew => "What's New",
        }
    }

    /// The tab stored under `raw`.
    pub fn from_raw(raw: &str) -> Option<StartTab> {
        Self::ALL.into_iter().find(|t| t.raw() == raw)
    }

    pub(crate) fn icon(self) -> SQIcon {
        match self {
            StartTab::Home => SQIcon::Home,
            StartTab::Recent => SQIcon::Clock,
            StartTab::Templates => SQIcon::Layout,
            StartTab::Learn => SQIcon::Book,
            StartTab::WhatsNew => SQIcon::Sparkles,
        }
    }
}

/// The order of the Recent pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StartSort {
    /// Newest first.
    Opened,
    /// By name.
    Name,
    /// Largest frame first.
    Size,
}

impl StartSort {
    /// All orders in menu order.
    pub const ALL: [StartSort; 3] = [StartSort::Opened, StartSort::Name, StartSort::Size];

    /// The title and stored value.
    pub fn raw(self) -> &'static str {
        match self {
            StartSort::Opened => "Last opened",
            StartSort::Name => "Name",
            StartSort::Size => "Frame size",
        }
    }

    /// The order stored under `raw`.
    pub fn from_raw(raw: &str) -> Option<StartSort> {
        Self::ALL.into_iter().find(|s| s.raw() == raw)
    }
}

/// What a press lands on.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StartHit {
    /// Rail: New project.
    NewProject,
    /// Rail: Open…
    OpenOther,
    /// Empty pane: New project.
    EmptyNew,
    /// Empty pane: Open…
    EmptyOpen,
    /// A rail tab.
    Tab(StartTab),
    /// "Open last project on launch".
    ReopenLast,
    /// The Appearance link.
    Appearance,
    /// The feedback link.
    Feedback,
    /// A support link.
    Support(SupportEntry),
    /// What's new > Report on GitHub.
    ReportIssue,
    /// The search field.
    Search,
    /// The search field's clear button.
    ClearSearch,
    /// The sort popup.
    Sort,
    /// The grid / list toggle of Recent (`true` = list).
    Layout(bool),
    /// A project card or row (the path).
    Card(String),
    /// A card's "…" (the path).
    CardMore(String),
    /// Home: the Open button of Continue.
    ContinueOpen,
    /// Home: a size tile (the template id).
    QuickSize(String),
    /// Home: "All formats…".
    AllFormats,
    /// A template card (the template id).
    Template(String),
    /// A lesson (its index).
    Lesson(usize),
    /// What's new: the Try button of a test row (its index).
    Try(usize),
}

/// One drawn part of the pane, in window points (scrolled).
#[derive(Clone, Debug)]
pub(crate) enum Element {
    Heading(String, CGRect),
    /// A section of the pane: a heading (may be empty) and the `border-row` line on the rect's top edge, inset 16.
    Section(String, CGRect),
    Card(RecentEntry, CGRect),
    /// The list layout of Recent (`ListHeader`, `ProjectListRow`).
    ListHeader(CGRect),
    ListRow(RecentEntry, CGRect),
    ContinueBox(RecentEntry, CGRect),
    Quick(Option<ProjectTemplate>, CGRect),
    TemplateCard(ProjectTemplate, CGRect),
    Lesson(usize, CGRect),
    Button(String, StartHit, CGRect, bool),
    /// Text on one line: size, tone, semibold.
    Txt(String, CGRect, f64, Tone, bool),
    /// The same, centered.
    TxtC(String, CGRect, f64, Tone, bool),
    /// Wrapped text: size, tone (16 pt lines).
    Wrapped(String, CGRect, f64, Tone),
    /// Wrapped text with every line centered in the rect.
    WrappedC(String, CGRect, f64, Tone),
    /// A lane-colored well (empty states).
    Lane(CGRect),
    /// A glyph centered in the rect: size, tone.
    Glyph(SQIcon, CGRect, f64, Tone),
    /// A raised square with a glyph (lesson and test rows).
    IconSq(SQIcon, CGRect, f64),
    /// A row line along the bottom edge.
    Rule(CGRect),
    /// A small dot (change list bullet).
    Dot(CGRect),
    /// A label chip: text, `true` = experimental (orange).
    Tag(String, CGRect, bool),
}

/// The text colors of the design (`text` to `text-4`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Tone {
    Text,
    Text2,
    Text3,
    Text4,
}

impl Element {
    fn offset(&self, dy: f64) -> Element {
        let o = |r: &CGRect| CGRect::new(r.x, r.y + dy, r.width, r.height);
        match self {
            Element::Heading(s, r) => Element::Heading(s.clone(), o(r)),
            Element::Section(s, r) => Element::Section(s.clone(), o(r)),
            Element::Card(e, r) => Element::Card(e.clone(), o(r)),
            Element::ListHeader(r) => Element::ListHeader(o(r)),
            Element::ListRow(e, r) => Element::ListRow(e.clone(), o(r)),
            Element::ContinueBox(e, r) => Element::ContinueBox(e.clone(), o(r)),
            Element::Quick(t, r) => Element::Quick(t.clone(), o(r)),
            Element::TemplateCard(t, r) => Element::TemplateCard(t.clone(), o(r)),
            Element::Lesson(i, r) => Element::Lesson(*i, o(r)),
            Element::Button(s, h, r, p) => Element::Button(s.clone(), h.clone(), o(r), *p),
            Element::Txt(s, r, z, t, b) => Element::Txt(s.clone(), o(r), *z, *t, *b),
            Element::TxtC(s, r, z, t, b) => Element::TxtC(s.clone(), o(r), *z, *t, *b),
            Element::Wrapped(s, r, z, t) => Element::Wrapped(s.clone(), o(r), *z, *t),
            Element::WrappedC(s, r, z, t) => Element::WrappedC(s.clone(), o(r), *z, *t),
            Element::Lane(r) => Element::Lane(o(r)),
            Element::Glyph(i, r, z, t) => Element::Glyph(*i, o(r), *z, *t),
            Element::IconSq(i, r, z) => Element::IconSq(*i, o(r), *z),
            Element::Rule(r) => Element::Rule(o(r)),
            Element::Dot(r) => Element::Dot(o(r)),
            Element::Tag(s, r, e) => Element::Tag(s.clone(), o(r), *e),
        }
    }
}

/// 11.5 pt matches the left ink of the same bar (the first menu title), so both ends measure alike (scripts/r8-inset-check.py).
/// The in-bar search field's right edge sits this far from the bar's right end (a window caption's buttons shift the bar end, see `start_bar_right_inset`).
pub const START_BAR_EDGE: f64 = 11.5;

/// Start screen tokens (`StartScreenTokens`: Theme.Metrics.start*; spacing, radii and type are the shared ladders).
pub(crate) mod m {
    use sq_uikit::design_tokens::sq_tokens::{height, radius, spacing, type_size};
    pub(crate) const S1: f64 = spacing::XS as f64;
    pub(crate) const S2: f64 = spacing::SM as f64;
    pub(crate) const S3: f64 = spacing::MD as f64;
    pub(crate) const S4: f64 = spacing::LG as f64;
    pub(crate) const S6: f64 = spacing::XL as f64;
    pub(crate) const RAIL: f64 = 256.0;
    pub(crate) const STATUS: f64 = 24.0;
    pub(crate) const TOP: f64 = 40.0;
    pub(crate) const PANE_HEADER: f64 = 56.0;
    /// The 2 pt seam around the pane (the window background shows through).
    pub(crate) const SEAM: f64 = 2.0;
    /// A project tile of Recent: 184 wide, a 104 high picture and the text under it.
    pub(crate) const TILE_W: f64 = 184.0;
    pub(crate) const TILE_H: f64 = 154.0;
    pub(crate) const MEDIA_H: f64 = 104.0;
    /// Room the Mac window buttons take at the left of the start window's top bar (`Theme.Metrics.startLights`).
    pub(crate) const LIGHTS: f64 = 90.0;
    pub(crate) const CONTROL: f64 = height::LARGE as f64;
    pub(crate) const CONTROL_SMALL: f64 = height::NORMAL as f64;
    pub(crate) const SEARCH: f64 = 280.0;
    /// The in-bar search field shrinks to this, then hides.
    pub(crate) const SEARCH_MIN: f64 = 120.0;
    /// Between the last menu title and the in-bar search field.
    pub(crate) const SEARCH_GAP: f64 = 12.0;
    pub(crate) const CONTINUE_WIDTH: f64 = 352.0;
    /// The narrowest a size row gets before the rows go to one column.
    pub(crate) const QUICK_MIN: f64 = 240.0;
    /// The least width the facts beside the Continue poster keep.
    pub(crate) const CONTINUE_FACTS_MIN: f64 = 230.0;
    pub(crate) const BADGE: f64 = 18.0;
    pub(crate) const R_CTL: f64 = radius::CONTROL as f64;
    pub(crate) const R_INNER: f64 = radius::SMALL as f64;
    pub(crate) const F_CAP: f64 = type_size::BODY as f64;
    pub(crate) const F_LAB: f64 = type_size::LIST as f64;
    pub(crate) const F_HEAD: f64 = type_size::TITLE as f64;
    pub(crate) const ICON_BODY: f64 = type_size::TITLE as f64;
    /// Support card: title row, three lines of the tagline, padding.
    pub(crate) const SUPPORT_CARD: f64 = 128.0;
    /// How far Pip peeks over the support card's top edge (`SQMascotPlace.startProjects`).
    pub(crate) const PIP_PEEK: f64 = 52.0;
}

/// `StartWindowView.lessons`: only the keyboard map has a page behind it.
pub(crate) const LESSONS: [(&str, &str, SQIcon, &str); 6] = [
    ("Keyboard map", "Every tool and its key.", SQIcon::Keyboard, "Open Shortcuts"),
    (
        "Start from a template",
        "A size tile or a saved template makes the project in one click.",
        SQIcon::Layout,
        "See templates",
    ),
    (
        "Keep your setup",
        "Save Current as Template keeps format, tracks and Looks for the next video.",
        SQIcon::Star,
        "",
    ),
    ("Fast Cut", "Choose it in New project for the magnetic timeline.", SQIcon::Magnet, ""),
    (
        "Outside files",
        "New project decides whether files from elsewhere are copied, moved or linked.",
        SQIcon::Folder,
        "",
    ),
    ("Drag an effect onto a clip", "Effects and transitions land where you drop them.", SQIcon::Sparkles, ""),
];

/// Keys that reach the shell while the start screen is up (`ShellMenuBar.allowed` for a shown chooser).
pub(crate) const ALLOWED_COMMANDS: [EditorCommand; 4] = [
    EditorCommand::NewProject,
    EditorCommand::OpenProject,
    EditorCommand::Preferences,
    EditorCommand::KeyboardShortcuts,
];

/// The settings keys (`AppController.reopenLastKey` and the start screen's own).
pub const TAB_KEY: &str = "sq.start.tab";
/// Stored sort order.
pub const SORT_KEY: &str = "sq.start.sort";
/// Stored Recent layout.
pub const LIST_LAYOUT_KEY: &str = "sq.start.listLayout";
/// Reopen the last project at launch.
/// The version whose What's new page was opened last (the rail dot shows until it matches).
pub const WHATS_NEW_SEEN_KEY: &str = "sq.start.whatsNewSeen";
pub const REOPEN_LAST_KEY: &str = "sq.reopenLastOnLaunch";

/// What the screen reads from its host at each call.
pub struct StartEnv<'a, 'm> {
    /// Open Recent.
    pub recents: &'a [RecentEntry],
    /// Text measure at the window's scale.
    pub measure: &'a TextMeasure<'m>,
    /// Wall-clock time (the card captions).
    pub now: Timestamp,
    /// Steady seconds (scroll physics).
    pub steady: f64,
    /// The calendar the day labels use.
    pub calendar: &'a dyn GroupingCalendar,
    /// A project other than the empty untitled one is open.
    pub has_real_project: bool,
    /// The projects folder, as shown in the status bar.
    pub projects_root: &'a str,
    /// The open project's name, empty while none is open.
    pub open_name: &'a str,
    /// The frame of a poster media at a time (`ShellHost::start_poster`); `None` draws the empty look.
    pub poster: Option<&'a crate::shell_host::StartPosterFn>,
}

/// What the screen asks its host to do.
#[derive(Clone, Debug)]
pub enum StartAction {
    /// `host.execute(command)`.
    Execute(EditorCommand),
    /// `host.perform(action)`.
    Perform(ShellAction),
    /// Open the project file.
    Open(String),
    /// "Locate…" on a missing recent.
    Locate(String),
    /// `quickCreate` with the built-in or saved template of this id.
    QuickCreate(String),
    /// A template card: asks for the name first, then creates (the template id).
    CreateNamed(String),
    /// Show the file in the file browser.
    Reveal(String),
    /// Remove one recent.
    RemoveRecent(String),
    /// Remove all recents.
    ClearRecents,
    /// A sort row was picked.
    SetSort(StartSort),
    /// Show a menu.
    Menu {
        /// The rows.
        items: Vec<SQMenuItem>,
        /// Top-left corner.
        point: CGPoint,
        /// The control's top edge, so the menu can flip above it.
        anchor_top: Option<f64>,
        /// The pointer (a context menu).
        pointer: Option<CGPoint>,
    },
    /// Rename the saved template.
    RenameTemplate(String),
    /// Delete the saved template.
    DeleteTemplate(String),
    /// Close the screen.
    Hide,
}

/// The start screen.
pub struct ShellStartScreen {
    /// The area under the menu bar, window points.
    pub frame: CGRect,
    /// The window bar the search field moves into (the Mac start window keeps its title and search in the title bar);
    /// `None`: the screen's own top row holds the title and the search (Windows, whose bar ends in the caption buttons).
    pub bar_frame: Option<CGRect>,
    /// Width of the in-bar search field; `None`: the full one. 0 hides it (a window too narrow for the menus and the field).
    pub search_width: Option<f64>,
    /// Where the top bar's "Sequence Studio" starts: after the window buttons in the Mac start window (`startLights`).
    pub title_inset: f64,
    tab: StartTab,
    sort: StartSort,
    list_layout: bool,
    /// The grid/list toggle has the keyboard focus (Tab moves it there, Left/Right choose, Escape leaves).
    pub(crate) toggle_focus: bool,
    reopen_last: bool,
    /// Paths of recents whose file is gone: grayed, "Locate…".
    pub missing: BTreeSet<String>,
    /// Frame size, rate and length per recent path (read in the background).
    pub infos: BTreeMap<String, StartProjectInfo>,
    /// The user's templates (`TemplateFolder.standard`); the built-ins come first.
    pub user_templates: Vec<ProjectTemplate>,
    /// Row chosen with Up/Down (`None` = the newest, which Return opens).
    pub selected_path: Option<String>,
    pub(crate) scroll_body: ScrollBody,
    /// What the pointer is over.
    pub hover: Option<StartHit>,
    pub(crate) mascots: ShellMascotStage,
    pub(crate) search: TextFieldControl,
    queue: Rc<RefCell<Vec<StartAction>>>,
    settings: Vec<(String, crate::shell_host::SettingValue)>,
    /// The What's new page, read from the shipped changelog at start.
    pub(crate) whats_new: crate::shell_whats_new::WhatsNew,
    whats_new_seen: Option<String>,
}

impl ShellStartScreen {
    /// A screen with the stored settings.
    pub fn new(s: &StartSettings) -> ShellStartScreen {
        let mut search = TextFieldControl::new("");
        search.bare = true;
        search.alignment = Alignment::Left;
        search.font_size = m::F_LAB;
        let mut screen = ShellStartScreen {
            frame: CGRect::default(),
            bar_frame: None,
            search_width: None,
            title_inset: m::S3,
            tab: s.tab.as_deref().and_then(StartTab::from_raw).unwrap_or(StartTab::Recent),
            sort: s.sort.as_deref().and_then(StartSort::from_raw).unwrap_or(StartSort::Opened),
            list_layout: s.list_layout,
            toggle_focus: false,
            reopen_last: s.reopen_last,
            missing: BTreeSet::new(),
            infos: BTreeMap::new(),
            user_templates: Vec::new(),
            selected_path: None,
            scroll_body: ScrollBody::default(),
            hover: None,
            mascots: ShellMascotStage::sleeping(),
            search,
            queue: Rc::new(RefCell::new(Vec::new())),
            settings: Vec::new(),
            whats_new: crate::shell_whats_new::WhatsNew::bundled(),
            whats_new_seen: s.whats_new_seen.clone(),
        };
        if screen.tab == StartTab::WhatsNew {
            screen.mark_whats_new_seen();
        }
        screen
    }

    /// The rail dot shows while this release's page was not opened yet.
    pub fn whats_new_unseen(&self) -> bool {
        self.whats_new.unseen(self.whats_new_seen.as_deref())
    }

    fn mark_whats_new_seen(&mut self) {
        if self.whats_new_unseen() {
            let v = self.whats_new.version.clone();
            self.settings.push((WHATS_NEW_SEEN_KEY.into(), crate::shell_host::SettingValue::Text(v.clone())));
            self.whats_new_seen = Some(v);
        }
    }

    /// The open tab.
    pub fn tab(&self) -> StartTab {
        self.tab
    }

    /// Opens a tab (stored; the pane scrolls back to the top).
    pub fn set_tab(&mut self, t: StartTab) {
        self.tab = t;
        if t == StartTab::WhatsNew {
            self.mark_whats_new_seen();
        }
        self.settings.push((TAB_KEY.into(), crate::shell_host::SettingValue::Text(t.raw().into())));
        self.scroll_body.assign(0.0);
    }

    /// The order of Recent.
    pub fn sort(&self) -> StartSort {
        self.sort
    }

    /// Orders Recent (stored).
    pub fn set_sort(&mut self, s: StartSort) {
        self.sort = s;
        self.settings.push((SORT_KEY.into(), crate::shell_host::SettingValue::Text(s.raw().into())));
    }

    /// Recent as a list (`sq.start.listLayout`, the Mac key).
    pub fn list_layout(&self) -> bool {
        self.list_layout
    }

    /// Switches Recent between the grid and the list (stored; scrolls to the top).
    pub fn set_list_layout(&mut self, list: bool) {
        self.list_layout = list;
        self.settings.push((LIST_LAYOUT_KEY.into(), crate::shell_host::SettingValue::Flag(list)));
        self.scroll_body.assign(0.0);
    }

    /// "Open last project on launch".
    pub fn reopen_last(&self) -> bool {
        self.reopen_last
    }

    /// The scroll offset.
    pub fn scroll(&mut self) -> f64 {
        self.scroll_body.position()
    }

    /// The settings changed since the last call.
    pub fn take_settings(&mut self) -> Vec<(String, crate::shell_host::SettingValue)> {
        std::mem::take(&mut self.settings)
    }

    /// The requests since the last call.
    pub fn take_actions(&mut self) -> Vec<StartAction> {
        std::mem::take(&mut *self.queue.borrow_mut())
    }

    fn push(&self, a: StartAction) {
        self.queue.borrow_mut().push(a);
    }

    /// The picture of the card of `path`: the poster media's frame at the poster time. `None` while it is not decoded, when
    /// the project has no poster media, when the project or its media file is missing, or when the host has no hook.
    pub fn card_poster(&self, env: &StartEnv, path: &str) -> Option<ProjectPoster> {
        let info = self.infos.get(path).filter(|i| !i.media_missing)?;
        if self.missing.contains(path) {
            return None;
        }
        let media = info.poster_path.as_deref()?;
        (env.poster?)(media, info.poster_seconds)
    }

    // MARK: Model

    /// The text in the search field.
    pub fn query(&self) -> String {
        self.search.editor().map_or_else(|| self.search.text.clone(), |e| e.string())
    }

    fn trimmed_query(&self) -> String {
        self.query().trim_matches(|c: char| c == ' ' || c == '\t').to_string()
    }

    /// `StartWindowView.shown`.
    pub fn shown(&self, env: &StartEnv) -> Vec<RecentEntry> {
        let order = match self.sort {
            StartSort::Name => RecentOrder::Name,
            StartSort::Size => RecentOrder::Size,
            StartSort::Opened => RecentOrder::Opened,
        };
        RecentProjects::listing(env.recents, &self.query(), order, |p| self.infos.get(p).map(|i| i.width * i.height))
    }

    pub(crate) fn current(&self, env: &StartEnv) -> Option<RecentEntry> {
        env.recents.iter().find(|e| !self.missing.contains(&e.path)).cloned()
    }

    pub(crate) fn highlighted_path(&self, env: &StartEnv) -> Option<String> {
        self.selected_path.clone().or_else(|| self.current(env).map(|e| e.path))
    }

    /// Sets the search text (and shows Recent).
    pub fn set_query(&mut self, s: &str) {
        self.search.cancel();
        self.search.text = s.to_string();
        self.query_changed();
    }

    fn query_changed(&mut self) {
        if !self.trimmed_query().is_empty() && self.tab != StartTab::Recent {
            self.set_tab(StartTab::Recent);
        }
        self.scroll_body.assign(0.0);
    }

    // MARK: Layout

    pub(crate) fn top_bar(&self) -> CGRect {
        CGRect::new(
            self.frame.min_x(),
            self.frame.min_y(),
            self.frame.width,
            if self.bar_frame.is_none() { m::TOP } else { 0.0 },
        )
    }

    pub(crate) fn status_bar(&self) -> CGRect {
        CGRect::new(self.frame.min_x(), self.frame.max_y() - m::STATUS, self.frame.width, m::STATUS)
    }

    /// Between the top bar and the status bar; the rail and the pane sit in it on 2 pt seams.
    fn body(&self) -> CGRect {
        let (t, s) = (self.top_bar(), self.status_bar());
        CGRect::new(self.frame.min_x(), t.max_y(), self.frame.width, (s.min_y() - t.max_y()).max(0.0))
    }

    pub(crate) fn rail_rect(&self) -> CGRect {
        let b = self.body();
        CGRect::new(b.min_x(), b.min_y(), m::RAIL - m::SEAM, b.height)
    }

    pub(crate) fn pane_rect(&self) -> CGRect {
        let (b, r) = (self.body(), self.rail_rect());
        CGRect::new(
            r.max_x() + m::SEAM,
            b.min_y() + m::SEAM,
            (b.max_x() - r.max_x() - 2.0 * m::SEAM).max(0.0),
            (b.height - 2.0 * m::SEAM).max(0.0),
        )
    }

    pub(crate) fn pane_header(&self) -> CGRect {
        let p = self.pane_rect();
        CGRect::new(p.min_x(), p.min_y(), p.width, m::PANE_HEADER)
    }

    /// The scrolling part of the pane.
    pub(crate) fn content_rect(&self) -> CGRect {
        let (p, h) = (self.pane_rect(), self.pane_header());
        CGRect::new(p.min_x(), h.max_y(), p.width, (p.max_y() - h.max_y()).max(0.0))
    }

    pub(crate) fn search_rect(&self) -> CGRect {
        let bar = self.bar_frame.unwrap_or_else(|| self.top_bar());
        let mut w = self.search_width.unwrap_or(m::SEARCH);
        if w <= 0.0 && self.search.is_editing() {
            w = m::SEARCH_MIN; // Find in a window too narrow for the field shows it while it has the focus
        }
        CGRect::new(
            bar.max_x() - START_BAR_EDGE - w,
            (bar.mid_y() - m::CONTROL_SMALL / 2.0).round(),
            w,
            m::CONTROL_SMALL,
        )
    }

    /// The width the bar's search field gets and the room its menu titles keep (`None`: no limit) when the bar is
    /// `right` wide, the titles start at `origin_x` and would end at `natural_right`. The field shrinks first, below
    /// `SEARCH_MIN` it hides (width 0), then the titles fold into the overflow menu. A title is never cut.
    pub(crate) fn bar_split(right: f64, origin_x: f64, natural_right: f64) -> (f64, Option<f64>) {
        let edge = right - START_BAR_EDGE;
        let room = edge - natural_right - m::SEARCH_GAP;
        if room >= m::SEARCH {
            return (m::SEARCH, None);
        }
        if room >= m::SEARCH_MIN {
            return (room, None);
        }
        (0.0, Some((edge - origin_x).max(0.0)))
    }

    pub(crate) fn search_clear_rect(&self) -> CGRect {
        let s = self.search_rect();
        CGRect::new(s.max_x() - 22.0, s.mid_y() - 8.0, 16.0, 16.0)
    }

    /// The rail's buttons, tab rows and option rows (the design's rail: 16 in, 28 high rows, 30 apart).
    pub(crate) fn rail_spots(&self) -> Vec<(CGRect, StartHit)> {
        let rail = self.rail_rect();
        let (x, w) = (rail.min_x() + 16.0, m::RAIL - 32.0);
        let mut out = vec![
            (CGRect::new(x, rail.min_y() + 12.0, w - 2.0, 28.0), StartHit::NewProject),
            (CGRect::new(x, rail.min_y() + 46.0, w - 2.0, 28.0), StartHit::OpenOther),
        ];
        for (i, t) in StartTab::ALL.into_iter().enumerate() {
            out.push((CGRect::new(x, rail.min_y() + 110.0 + 30.0 * i as f64, w, 28.0), StartHit::Tab(t)));
        }
        // The check row and the link row hang from the bottom (the design's rail is 656 high).
        out.push((CGRect::new(x, rail.max_y() - 68.0, w, 24.0), StartHit::ReopenLast));
        if self.support_card_visible() {
            let card = self.support_card_rect();
            out.push((
                CGRect::new(card.min_x() + 14.0, card.min_y() + 92.0, 93.0, 22.0),
                StartHit::Support(SupportEntry::Support),
            ));
        }
        let mut lx = rail.min_x() + 12.0;
        let mut hits = vec![StartHit::Appearance, StartHit::Feedback];
        hits.extend(SupportEntry::visible(SupportLinks::DISCORD).into_iter().rev().map(StartHit::Support));
        for h in hits {
            out.push((CGRect::new(lx, rail.max_y() - 36.0, 24.0, 24.0), h));
            lx += 28.0;
        }
        out
    }

    /// Whether the support card (with Pip over it) has room under the last tab row: in a small window it goes, the tabs and
    /// the rail's own rows never sit under it.
    pub(crate) fn support_card_visible(&self) -> bool {
        let tabs_bottom = self.rail_rect().min_y() + 110.0 + 30.0 * StartTab::ALL.len() as f64;
        self.support_card_rect().min_y() - m::PIP_PEEK >= tabs_bottom
    }

    pub(crate) fn support_card_rect(&self) -> CGRect {
        let rail = self.rail_rect();
        CGRect::new(rail.min_x() + 16.0, rail.max_y() - 212.0, m::RAIL - 34.0, m::SUPPORT_CARD)
    }

    /// The card Pip peeks over (`SQMascotPlace.startProjects`, the Mac `supportCard` background): in every view of the
    /// design, also the first start; `None` only where the empty Recent pane has its own Pip. The host draws him: his bottom tucks `SQMascotPlace.peekTuck` behind the card's top edge, 16
    /// in from its right edge.
    pub fn mascot_card(&self, env: &StartEnv) -> Option<CGRect> {
        if self.empty_mascot_base(env).is_some() || !self.support_card_visible() {
            None
        } else {
            Some(self.support_card_rect())
        }
    }

    /// The empty Recent pane's Pip (`SQMascotPlace.startEmpty`, above the title): the point his bottom center sits on.
    pub fn empty_mascot_base(&self, env: &StartEnv) -> Option<CGPoint> {
        if self.tab != StartTab::Recent || !env.recents.is_empty() {
            return None;
        }
        let c = self.content_rect();
        Some(CGPoint::new(c.mid_x(), c.mid_y() - 40.0 - m::S3))
    }

    /// The sort button of the design: 24 high, "Sort" and the order with a small chevron, 24 from the pane edge.
    pub(crate) fn sort_rect(&self, env: &StartEnv) -> CGRect {
        let w = 9.0
            + env.measure.width("Sort", m::F_LAB, 0).ceil()
            + 6.0
            + env.measure.width(self.sort.raw(), m::F_LAB, 0).ceil()
            + 6.0
            + 9.0
            + 9.0;
        let p = self.pane_rect();
        CGRect::new(p.max_x() - 24.0 - w, p.min_y() + 18.0, w, 24.0)
    }

    /// The icon segments: two 28 x 20 segments in a 2 pt well, 176 from the pane edge.
    pub(crate) fn layout_toggle_rect(&self, _env: &StartEnv) -> CGRect {
        let p = self.pane_rect();
        CGRect::new(p.max_x() - 176.0 - 62.0, p.min_y() + 16.0, 62.0, 24.0)
    }

    pub(crate) fn layout_segment(&self, env: &StartEnv, list: bool) -> CGRect {
        let t = self.layout_toggle_rect(env);
        CGRect::new(t.min_x() + 2.0 + if list { 30.0 } else { 0.0 }, t.min_y() + 2.0, 28.0, 20.0)
    }

    pub(crate) const LIST_THUMB: CGSize = CGSize { width: 40.0, height: 32.0 };
    pub(crate) const LIST_ROW_HEIGHT: f64 = 44.0;
    /// The least width a list row keeps for the project name before a column goes.
    pub(crate) const LIST_NAME_MIN: f64 = 120.0;
    /// Width of the "Locate…" button on a missing project's row.
    pub(crate) const LOCATE_W: f64 = 76.0;

    /// `ListCol`: the right-hand columns of a list row (name takes the rest), `gapM` 12 apart, 8 inside the row.
    pub(crate) fn list_columns(r: CGRect) -> ListColumns {
        let (pad, gap) = (m::S2, m::S3);
        let mut x = r.max_x() - pad;
        let more = CGRect::new(x - m::CONTROL, r.min_y(), m::CONTROL, r.height);
        x = more.min_x() - gap;
        let name_x = r.min_x() + pad + Self::LIST_THUMB.width + gap;
        // From the right: a column stays while the name keeps `LIST_NAME_MIN`; a narrow window drops the left ones first.
        let mut place = |w: f64| -> Option<f64> {
            let left = x - w;
            (left - gap >= name_x + Self::LIST_NAME_MIN).then(|| {
                x = left - gap;
                left
            })
        };
        let edited = place(96.0);
        let length = if edited.is_some() { place(64.0) } else { None };
        let rate = if length.is_some() { place(92.0) } else { None };
        let aspect = if rate.is_some() { place(64.0) } else { None };
        let size = if aspect.is_some() { place(110.0) } else { None };
        ListColumns {
            name: CGRect::new(name_x, r.min_y(), (x - name_x).max(0.0), r.height),
            size,
            aspect,
            rate,
            length,
            edited,
            more,
        }
    }

    /// The "Locate…" button of a missing project's row and the name's room left of it. The button takes the Frame rate
    /// column, else the Edited one, else the room left of the "…"; the name ends one gap before it (it truncates there, at
    /// a word boundary), so the button never covers the name, at any width.
    pub(crate) fn locate_row_parts(col: &ListColumns, r: CGRect) -> (CGRect, CGRect) {
        let x = col.rate.or(col.edited).unwrap_or(col.more.min_x() - m::S3 - Self::LOCATE_W);
        let button = CGRect::new(x, r.mid_y() - m::CONTROL / 2.0, Self::LOCATE_W, m::CONTROL);
        let room = (button.min_x() - m::S3 - col.name.min_x()).clamp(0.0, col.name.width);
        (CGRect::new(col.name.min_x(), col.name.min_y(), room, col.name.height), button)
    }

    pub(crate) fn built_in() -> Vec<ProjectTemplate> {
        ProjectTemplate::built_in()
    }

    /// The pane's parts at scroll 0 and the content height (the design's start views, positions as in the artifact).
    pub(crate) fn pane_layout(&self, env: &StartEnv) -> (Vec<Element>, f64) {
        let content = self.content_rect();
        let x0 = content.min_x() + m::S6;
        let w = (content.width - 2.0 * m::S6).max(0.0);
        let top = content.min_y();
        let mut y = top;
        let mut out: Vec<Element> = Vec::new();
        let txt = |s: &str, r: CGRect, size: f64, tone: Tone, bold: bool| Element::Txt(s.into(), r, size, tone, bold);
        let ctxt = |s: &str, r: CGRect, size: f64, tone: Tone, bold: bool| Element::TxtC(s.into(), r, size, tone, bold);
        // A grid of fixed-size cells from `y`: returns the bottom.
        fn grid<T>(
            out: &mut Vec<Element>,
            items: &[T],
            (x0, w, y): (f64, f64, f64),
            (cw, ch, gx, gy): (f64, f64, f64, f64),
            make: impl Fn(&T, CGRect) -> Element,
        ) -> f64 {
            if items.is_empty() {
                return y;
            }
            let n = (((w + gx) / (cw + gx)) as usize).max(1);
            for (i, it) in items.iter().enumerate() {
                out.push(make(
                    it,
                    CGRect::new(x0 + (i % n) as f64 * (cw + gx), y + (i / n) as f64 * (ch + gy), cw, ch),
                ));
            }
            let rows = items.len().div_ceil(n);
            y + rows as f64 * ch + (rows - 1) as f64 * gy
        }
        // A card of the design: the group box and its title (12 semibold at 16, 14).
        let card = |out: &mut Vec<Element>, r: CGRect, title: &str| {
            out.push(Element::Section(title.into(), r));
        };
        match self.tab {
            StartTab::Recent => {
                y += 2.0;
                let list = self.shown(env);
                if env.recents.is_empty() || list.is_empty() {
                    return (Vec::new(), 0.0);
                }
                if self.list_layout {
                    out.push(Element::ListHeader(CGRect::new(x0, y, w, m::CONTROL)));
                    y += m::CONTROL;
                    for e in list {
                        out.push(Element::ListRow(e, CGRect::new(x0, y, w, Self::LIST_ROW_HEIGHT)));
                        y += Self::LIST_ROW_HEIGHT;
                    }
                } else if self.sort == StartSort::Opened {
                    let groups: Vec<(&str, Vec<RecentEntry>)> = StartLabels::GROUPS
                        .iter()
                        .map(|g| {
                            (
                                *g,
                                list.iter()
                                    .filter(|e| StartLabels::group(e.opened, env.now, env.calendar) == *g)
                                    .cloned()
                                    .collect::<Vec<_>>(),
                            )
                        })
                        .filter(|(_, v)| !v.is_empty())
                        .collect();
                    for g in &groups {
                        out.push(Element::Heading(g.0.to_string(), CGRect::new(x0, y, w, 16.0)));
                        y += 18.0;
                        y = grid(&mut out, &g.1, (x0, w, y), (m::TILE_W, m::TILE_H, m::S4, m::S4), |e, r| {
                            Element::Card(e.clone(), r)
                        }) + 18.0;
                    }
                    y -= 18.0;
                } else {
                    y = grid(&mut out, &list, (x0, w, y), (m::TILE_W, m::TILE_H, m::S4, m::S4), |e, r| {
                        Element::Card(e.clone(), r)
                    });
                }
            }
            StartTab::Home => {
                // Sections sit 16 left of the title edge, so their content starts on it (r8:512).
                let (x0, w) = (x0 - 16.0, w + 32.0);
                y += 4.0;
                // With a project to continue the card grows to the Continue box (it stacks in a narrow window).
                let box_h = if self.current(env).is_some() { Self::continue_height(w - 32.0) } else { 186.0 };
                let c1 = CGRect::new(x0, y, w, 58.0 + box_h);
                card(&mut out, c1, "Continue");
                let pic = CGRect::new(x0 + 16.0, y + 42.0, w - 32.0, box_h);
                if let Some(last) = self.current(env) {
                    out.push(Element::ContinueBox(last, CGRect::new(pic.min_x(), pic.min_y(), pic.width, pic.height)));
                } else {
                    out.push(Element::Lane(pic));
                    out.push(Element::Glyph(
                        SQIcon::Clock,
                        CGRect::new(pic.mid_x() - 11.0, pic.mid_y() - 21.0, 22.0, 22.0),
                        22.0,
                        Tone::Text4,
                    ));
                    out.push(ctxt(
                        "Projects you open appear here.",
                        CGRect::new(pic.min_x(), pic.mid_y() + 7.0, pic.width, 16.0),
                        m::F_LAB,
                        Tone::Text2,
                        false,
                    ));
                }
                y += c1.height + 16.0;
                let mut items: Vec<Option<ProjectTemplate>> = Self::built_in().into_iter().map(Some).collect();
                items.push(None);
                // Two columns of up to 372 pt when they fit (20 pt apart), else one.
                let avail = w - 20.0;
                let cols = if avail >= 2.0 * m::QUICK_MIN + 20.0 { 2 } else { 1 };
                let cell = ((avail - 20.0 * (cols - 1) as f64) / cols as f64).min(372.0);
                let intro = "Creates the project in the projects folder and opens it.";
                let intro_lines = env.measure.lines(intro, w - 32.0, m::F_CAP).len().max(1) as f64;
                let top_of_rows = 44.0 + 16.0 * intro_lines;
                let c2 = CGRect::new(x0, y, w, top_of_rows + items.len().div_ceil(cols) as f64 * 56.0 + 12.0);
                card(&mut out, c2, "Start from a size");
                out.push(Element::Wrapped(
                    intro.into(),
                    CGRect::new(x0 + 16.0, y + 34.0, w - 32.0, 16.0 * intro_lines),
                    m::F_CAP,
                    Tone::Text3,
                ));
                for (i, t) in items.iter().enumerate() {
                    out.push(Element::Quick(
                        t.clone(),
                        CGRect::new(
                            x0 + 10.0 + (i % cols) as f64 * (cell + 20.0),
                            y + top_of_rows + (i / cols) as f64 * 56.0,
                            cell,
                            44.0,
                        ),
                    ));
                }
                y += c2.height;
                // `StartTemplatesModel.yourTemplates` (SQEditorUI): the first four of the user's own.
                let shown: Vec<ProjectTemplate> = self.user_templates.iter().take(4).cloned().collect();
                if !shown.is_empty() {
                    y += 16.0;
                    let per_row = (((w - 32.0 + 10.0) / (258.0 + 10.0)) as usize).max(1);
                    let rows = shown.len().div_ceil(per_row) as f64;
                    let c3 = CGRect::new(x0, y, w, 60.0 + rows * 190.0 - 10.0 + 16.0);
                    card(&mut out, c3, "Your templates");
                    out.push(txt(
                        "Click one, name the video, press Return.",
                        CGRect::new(x0 + 16.0, y + 34.0, w - 32.0, 16.0),
                        m::F_CAP,
                        Tone::Text3,
                        false,
                    ));
                    grid(&mut out, &shown, (x0 + 16.0, w - 32.0, y + 60.0), (258.0, 180.0, 10.0, 10.0), |t, r| {
                        Element::TemplateCard(t.clone(), r)
                    });
                    y += c3.height;
                }
            }
            StartTab::Templates => {
                y += 4.0;
                out.push(txt("Built in", CGRect::new(x0, y, w, 16.0), m::F_LAB, Tone::Text2, true));
                y = grid(&mut out, &Self::built_in(), (x0, w, y + 22.0), (258.0, 180.0, 10.0, 10.0), |t, r| {
                    Element::TemplateCard(t.clone(), r)
                });
                y += 20.0;
                out.push(txt("Yours", CGRect::new(x0, y, w, 16.0), m::F_LAB, Tone::Text2, true));
                y += 22.0;
                if self.user_templates.is_empty() {
                    let body = "Open a project and save its sequence as a template. It shows up here.";
                    let lines = env.measure.lines(body, w - 32.0, m::F_CAP).len().max(1) as f64;
                    let button_y = 76.0 + 16.0 * lines + 10.0;
                    out.push(Element::Section(
                        String::new(),
                        CGRect::new(x0 - 16.0, y, w + 32.0, button_y + 22.0 + 26.0),
                    ));
                    let mx = x0 + w / 2.0;
                    out.push(Element::Glyph(
                        SQIcon::Layout,
                        CGRect::new(mx - 11.0, y + 26.0, 22.0, 22.0),
                        22.0,
                        Tone::Text4,
                    ));
                    out.push(ctxt(
                        "No templates of your own yet",
                        CGRect::new(x0 + 16.0, y + 54.0, w - 32.0, 16.0),
                        m::F_LAB,
                        Tone::Text,
                        true,
                    ));
                    out.push(Element::WrappedC(
                        body.into(),
                        CGRect::new(x0 + 16.0, y + 76.0, w - 32.0, 16.0 * lines),
                        m::F_CAP,
                        Tone::Text3,
                    ));
                    out.push(Element::Button(
                        "How to save a template".into(),
                        StartHit::Lesson(2),
                        CGRect::new(mx - 88.0, y + button_y, 176.0, 22.0),
                        false,
                    ));
                    y += button_y + 22.0 + 26.0;
                } else {
                    y = grid(&mut out, &self.user_templates, (x0, w, y), (258.0, 180.0, 10.0, 10.0), |t, r| {
                        Element::TemplateCard(t.clone(), r)
                    });
                }
            }
            StartTab::Learn => {
                y += 4.0;
                let idx: Vec<usize> = (0..LESSONS.len()).collect();
                y = grid(&mut out, &idx, (x0, w, y), (258.0, 156.0, 10.0, 14.0), |i, r| Element::Lesson(*i, r));
                // Under the cards, and at least where the design has it (three cards wide); a narrow pane stacks the cards.
                let foot = (y + 16.0).max(top + 544.0);
                out.push(Element::Wrapped(
                    "The newest project is one click away in Home and Recent.".into(),
                    CGRect::new(
                        x0,
                        foot,
                        w,
                        16.0 * env
                            .measure
                            .lines("The newest project is one click away in Home and Recent.", w, m::F_CAP)
                            .len()
                            .max(1) as f64,
                    ),
                    m::F_CAP,
                    Tone::Text3,
                ));
                y = (foot + 16.0).max(top + 560.0);
            }
            StartTab::WhatsNew => {
                let (x0, w) = (x0 - 16.0, w + 32.0);
                y += 4.0;
                // Two columns of up to 389 pt when each keeps 320 pt, else the cards stack, each as wide as the pane.
                let gap = 16.0;
                let two = w >= 2.0 * 320.0 + gap;
                let cw = if two { ((w - gap) / 2.0).min(389.0) } else { w };
                let lines_of = |s: &str, width: f64, size: f64| env.measure.lines(s, width, size).len().max(1) as f64;
                // Help test: its rows wrap their description, so a row is as tall as its lines.
                let intro = "These changed recently or are still experimental. Try them and tell us how it went.";
                let intro_h = 16.0 * lines_of(intro, cw - 32.0, m::F_CAP);
                let rows = self.whats_new.help_rows();
                let mut row_y = 34.0 + intro_h + 6.0;
                let mut row_rects: Vec<CGRect> = Vec::new();
                for test in &rows {
                    // The description sits under the name, left of the Try button.
                    let what_w = cw - 32.0 - 44.0 - 48.0;
                    let h = 27.0 + 16.0 * lines_of(test.what.as_str(), what_w, m::F_CAP) + 9.0;
                    row_rects.push(CGRect::new(x0 + 16.0, y + row_y, cw - 32.0, h));
                    row_y += h + 6.0;
                }
                let help = CGRect::new(x0, y, cw, (row_y - 6.0 + 28.0).max(if two { 384.0 } else { 0.0 }));
                card(&mut out, help, "Help test");
                out.push(Element::Wrapped(
                    intro.into(),
                    CGRect::new(help.min_x() + 16.0, help.min_y() + 35.0, cw - 32.0, intro_h),
                    m::F_CAP,
                    Tone::Text3,
                ));
                for (i, test) in rows.iter().enumerate() {
                    let (icon, name, what, exp) =
                        (&test.icon, test.name.as_str(), test.what.as_str(), &test.experimental);
                    let row = row_rects[i];
                    out.push(Element::IconSq(*icon, CGRect::new(row.min_x(), row.min_y() + 10.0, 32.0, 32.0), 16.0));
                    let nx = row.min_x() + 44.0;
                    out.push(txt(name, CGRect::new(nx, row.min_y() + 10.0, 200.0, 16.0), m::F_LAB, Tone::Text, false));
                    let nw = env.measure.width(name, m::F_LAB, 0).ceil();
                    let (label, w_tag) = if *exp { ("Experimental", 92.0) } else { ("New", 30.0) };
                    out.push(Element::Tag(
                        label.into(),
                        CGRect::new(nx + nw + 6.0, row.min_y() + 10.0, w_tag, 16.0),
                        *exp,
                    ));
                    out.push(Element::Wrapped(
                        what.into(),
                        CGRect::new(nx, row.min_y() + 27.0, row.max_x() - 48.0 - nx, row.height - 36.0),
                        m::F_CAP,
                        Tone::Text3,
                    ));
                    out.push(Element::Button(
                        "Try".into(),
                        StartHit::Try(i),
                        CGRect::new(row.max_x() - 36.0, row.min_y() + (row.height - 24.0) / 2.0, 36.0, 24.0),
                        false,
                    ));
                    if i + 1 < rows.len() {
                        out.push(Element::Rule(row));
                    }
                }
                // Found something?: text, the two buttons (side by side when they fit, else one under the other), a hint.
                let found_y = y + help.height + 12.0;
                let found_text = "Report bugs and ideas on GitHub, or talk to us and other editors on Discord. A screenshot or a short clip helps the most.";
                // The kit reserves three text lines above the buttons (Recent/What's new kit match: the buttons sat 16 px high).
                let found_h = 16.0 * lines_of(found_text, cw - 32.0, m::F_CAP).max(3.0);
                let buttons_y = 34.0 + found_h + 10.0;
                let side_by_side = cw - 32.0 >= 142.0 + 8.0 + 122.0;
                let hint = "Experimental labels can be turned off in Settings \u{203A} General.";
                let hint_h = 16.0 * lines_of(hint, cw - 32.0, m::F_CAP);
                let hint_y = buttons_y + if side_by_side { 28.0 } else { 28.0 + 8.0 + 28.0 } + 16.0;
                let found = CGRect::new(x0, found_y, cw, (hint_y + hint_h + 20.0).max(if two { 172.0 } else { 0.0 }));
                card(&mut out, found, "Found something?");
                out.push(Element::Wrapped(
                    found_text.into(),
                    CGRect::new(found.min_x() + 16.0, found.min_y() + 35.0, cw - 32.0, found_h),
                    m::F_CAP,
                    Tone::Text3,
                ));
                out.push(Element::Button(
                    "Report on GitHub".into(),
                    StartHit::ReportIssue,
                    CGRect::new(found.min_x() + 16.0, found.min_y() + buttons_y, 142.0, 28.0),
                    false,
                ));
                let (discord_x, discord_y) =
                    if side_by_side { (166.0, buttons_y) } else { (16.0, buttons_y + 28.0 + 8.0) };
                out.push(Element::Button(
                    "Open Discord".into(),
                    StartHit::Support(SupportEntry::Discord),
                    CGRect::new(found.min_x() + discord_x, found.min_y() + discord_y, 122.0, 28.0),
                    false,
                ));
                out.push(Element::Wrapped(
                    hint.into(),
                    CGRect::new(found.min_x() + 16.0, found.min_y() + hint_y, cw - 32.0, hint_h),
                    m::F_CAP,
                    Tone::Text4,
                ));
                // Changes: the right column, or under the other two cards.
                let (changes_x, changes_y) = if two { (x0 + cw + gap, y) } else { (x0, found.max_y() + 12.0) };
                let mut changes = CGRect::new(changes_x, changes_y, cw, 568.0);
                let mut changes_els: Vec<Element> = Vec::new();
                let mut cy = changes.min_y() + 41.0;
                for (n, group) in self.whats_new.changes.iter().enumerate() {
                    let (icon, name, items) = (&group.icon, group.title.as_str(), &group.items);
                    if n > 0 {
                        cy += 17.0;
                    }
                    changes_els.push(Element::Glyph(
                        *icon,
                        CGRect::new(changes.min_x() + 16.0, cy + 1.0, 14.0, 14.0),
                        14.0,
                        Tone::Text2,
                    ));
                    changes_els.push(txt(
                        name,
                        CGRect::new(changes.min_x() + 36.0, cy, 200.0, 16.0),
                        m::F_LAB,
                        Tone::Text2,
                        true,
                    ));
                    cy += 20.0;
                    for line in items {
                        // The design wraps a long line inside the card: 16 pt lines, 4 pt above and below.
                        let rows = env.measure.lines(line, cw - 52.0, m::F_LAB).len().max(1) as f64;
                        changes_els.push(Element::Dot(CGRect::new(changes.min_x() + 22.0, cy + 10.0, 4.0, 4.0)));
                        changes_els.push(Element::Wrapped(
                            line.clone(),
                            CGRect::new(changes.min_x() + 36.0, cy + 4.0, cw - 52.0, 16.0 * rows),
                            m::F_LAB,
                            Tone::Text,
                        ));
                        cy += 16.0 * rows + 8.0;
                    }
                }
                // Side by side the right card is as tall as the left column (the design's 568 pt) or its own text.
                let left_h = found.max_y() - y;
                changes.height =
                    if two { (cy - changes.min_y() + 8.0).max(left_h).max(568.0) } else { cy - changes.min_y() + 8.0 };
                card(&mut out, changes, &format!("Changes in {}", self.whats_new.version));
                out.extend(changes_els);
                y = if two { y + changes.height.max(left_h) } else { changes.max_y() };
            }
        }
        (out, y - top + m::S6)
    }

    /// The empty Recent pane (`emptyState`): title, text and its buttons, centered in the content.
    pub(crate) fn empty_state(&self, env: &StartEnv) -> Option<(String, String, Vec<Element>)> {
        if self.tab != StartTab::Recent || !(env.recents.is_empty() || self.shown(env).is_empty()) {
            return None;
        }
        let title = if env.recents.is_empty() {
            "No projects yet".to_string()
        } else {
            SQL10n::format("No projects match “%@”", &[&self.trimmed_query()])
        };
        let text = if env.recents.is_empty() {
            "Start with a frame size, or drop a video here and the project takes that clip's size and frame rate."
        } else {
            "Search looks at project names."
        };
        let c = self.content_rect();
        let (mx, my) = (c.mid_x(), c.mid_y());
        let bw = 120.0;
        let buttons = if env.recents.is_empty() {
            vec![
                Element::Button(
                    "New Project".into(),
                    StartHit::EmptyNew,
                    CGRect::new(mx - bw - m::S1, my + 24.0, bw, m::CONTROL),
                    true,
                ),
                Element::Button(
                    "Open…".into(),
                    StartHit::EmptyOpen,
                    CGRect::new(mx + m::S1, my + 24.0, bw, m::CONTROL),
                    false,
                ),
            ]
        } else {
            vec![Element::Button(
                "Clear search".into(),
                StartHit::ClearSearch,
                CGRect::new(mx - bw / 2.0, my + 24.0, bw, m::CONTROL),
                false,
            )]
        };
        Some((title, text.to_string(), buttons))
    }

    /// The pane's parts moved by the scroll.
    pub(crate) fn scrolled_elements(&mut self, env: &StartEnv) -> Vec<Element> {
        if let Some(e) = self.empty_state(env) {
            return e.2;
        }
        let scroll = self.scroll();
        self.pane_layout(env).0.iter().map(|e| e.offset(-scroll)).collect()
    }

    /// The press target at `p` (window points).
    pub fn hit_at(&mut self, p: CGPoint, env: &StartEnv) -> Option<StartHit> {
        if !(self.frame.contains(p) || self.search_rect().contains(p)) {
            return None;
        }
        if self.search_rect().contains(p) {
            return Some(if !self.query().is_empty() && self.search_clear_rect().contains(p) {
                StartHit::ClearSearch
            } else {
                StartHit::Search
            });
        }
        if self.rail_rect().contains(p) {
            return self.rail_spots().into_iter().find(|s| s.0.contains(p)).map(|s| s.1);
        }
        if self.tab == StartTab::Recent && !env.recents.is_empty() {
            if self.sort_rect(env).contains(p) {
                return Some(StartHit::Sort);
            }
            if self.layout_toggle_rect(env).contains(p) {
                return Some(StartHit::Layout(
                    self.layout_segment(env, true).contains(p) || p.x > self.layout_segment(env, false).max_x(),
                ));
            }
        }
        if !self.content_rect().contains(p) {
            return None;
        }
        for e in self.scrolled_elements(env) {
            match e {
                Element::Card(entry, r) if r.contains(p) => {
                    return Some(if Self::more_rect(r).contains(p) {
                        StartHit::CardMore(entry.path)
                    } else {
                        StartHit::Card(entry.path)
                    });
                }
                Element::ListRow(entry, r) if r.contains(p) => {
                    return Some(if Self::list_columns(r).more.contains(p) {
                        StartHit::CardMore(entry.path)
                    } else {
                        StartHit::Card(entry.path)
                    });
                }
                Element::ContinueBox(_, r) if Self::open_rect(r).contains(p) => return Some(StartHit::ContinueOpen),
                Element::Quick(t, r) if r.contains(p) => {
                    return Some(t.map_or(StartHit::AllFormats, |t| StartHit::QuickSize(t.id)));
                }
                Element::TemplateCard(t, r) if r.contains(p) => return Some(StartHit::Template(t.id)),
                Element::Lesson(i, r) if r.contains(p) => {
                    return if LESSONS[i].3.is_empty() { None } else { Some(StartHit::Lesson(i)) };
                }
                Element::Button(_, h, r, _) if r.contains(p) => return Some(h),
                _ => {}
            }
        }
        None
    }

    /// A tile's "…" sits at the right of the name row, below the picture.
    pub(crate) fn more_rect(card: CGRect) -> CGRect {
        CGRect::new(
            card.max_x() - m::CONTROL_SMALL,
            card.min_y() + m::MEDIA_H + 4.0,
            m::CONTROL_SMALL,
            m::CONTROL_SMALL,
        )
    }

    /// The Continue box in `b`: the poster beside the facts when there is room, else the facts under the poster.
    pub(crate) fn continue_parts(b: CGRect) -> ContinueParts {
        let side = b.width >= m::CONTINUE_WIDTH + 24.0 + m::CONTINUE_FACTS_MIN;
        if side {
            let x = b.min_x() + m::CONTINUE_WIDTH + 24.0;
            return ContinueParts {
                poster: CGRect::new(b.min_x(), b.min_y(), m::CONTINUE_WIDTH, b.height),
                facts_x: x,
                facts_w: (b.max_x() - x).min(378.0),
                title_y: b.min_y() + 2.0,
                open: CGRect::new(x, b.min_y() + 154.0, 84.0, m::CONTROL_SMALL + 4.0),
            };
        }
        let poster_h = Self::continue_poster_height(b.width);
        let title_y = b.min_y() + poster_h + 12.0;
        ContinueParts {
            poster: CGRect::new(b.min_x(), b.min_y(), b.width, poster_h),
            facts_x: b.min_x(),
            facts_w: b.width,
            title_y,
            open: CGRect::new(b.min_x(), title_y + 24.0 + 4.0 * 26.0 + 10.0, 84.0, m::CONTROL_SMALL + 4.0),
        }
    }

    /// The poster's height when it sits above the facts: the beside-layout's 186 pt at 352 pt wide, in that aspect.
    fn continue_poster_height(width: f64) -> f64 {
        (width * 186.0 / m::CONTINUE_WIDTH).clamp(0.0, 186.0).round()
    }

    /// The height of the Continue box in a pane `width` pt wide inside its card.
    pub(crate) fn continue_height(width: f64) -> f64 {
        if width >= m::CONTINUE_WIDTH + 24.0 + m::CONTINUE_FACTS_MIN {
            186.0
        } else {
            Self::continue_poster_height(width) + 12.0 + 24.0 + 4.0 * 26.0 + 10.0 + m::CONTROL_SMALL + 4.0
        }
    }

    /// The Open button under the four fact rows of the Continue card.
    pub(crate) fn open_rect(b: CGRect) -> CGRect {
        Self::continue_parts(b).open
    }

    // MARK: Events

    /// Every event while the start screen is up (it is modal over the editor). `scale` turns pixels into points.
    pub fn handle(&mut self, e: &InputEvent, scale: f32, env: &StartEnv, ui: &mut UiCx) -> bool {
        self.mascots.wake(env.steady);
        let k = f64::from(scale.max(0.01));
        if self.empty_state(env).is_none() {
            let content = self.pane_layout(env).1;
            let vp = self.content_rect();
            if self.scroll_body.scroller_event(e, scale, vp, content, env.steady) {
                return true;
            }
        }
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x) / k, f64::from(y) / k);
        match *e {
            InputEvent::MouseDown { x, y, modifiers } => {
                let p = pt(x, y);
                self.toggle_focus = false;
                let h = self.hit_at(p, env);
                crate::shell_log::info(&format!("start press at {:.0},{:.0} pt: {h:?}", p.x, p.y));
                if h != Some(StartHit::Search) && self.search.is_editing() {
                    let _ = self.search.commit();
                }
                // Empty space on the screen is the screen's (modal), except its own top bar (the Mac start window): empty bar
                // space belongs to the window, so a drag or a double-click there reaches the window.
                let Some(h) = h else {
                    return self.frame.contains(p) && !(self.bar_frame.is_none() && self.top_bar().contains(p));
                };
                if modifiers.contains(InputModifiers::SECONDARY) {
                    match &h {
                        StartHit::Card(path) => {
                            self.recheck(path);
                            self.push_menu(self.recent_menu(path), p);
                        }
                        StartHit::Template(id) => {
                            if let Some(t) = self.user_templates.iter().find(|t| &t.id == id) {
                                self.push_menu(self.template_menu(t), p);
                            }
                        }
                        _ => {}
                    }
                    return true;
                }
                self.press(&h, p, env);
                true
            }
            InputEvent::MouseMoved { x, y } => {
                self.hover = self.hit_at(pt(x, y), env);
                // A project tile or row: the full name and the path (the label may be cut).
                let tip = match &self.hover {
                    Some(StartHit::Card(path) | StartHit::CardMore(path)) => env
                        .recents
                        .iter()
                        .find(|e| &e.path == path)
                        .map(|e| format!("{} \u{b7} {}", e.name, ShellPlatformText::abbreviating_home(path))),
                    Some(
                        h @ (StartHit::NewProject
                        | StartHit::OpenOther
                        | StartHit::EmptyOpen
                        | StartHit::ContinueOpen
                        | StartHit::Search),
                    ) => crate::shell_start_draw::key_tip(h),
                    _ => None,
                };
                ui.hover.offer_tip(tip.as_deref());
                true
            }
            InputEvent::Scroll { x, y, dx, dy, .. } => {
                if !self.content_rect().contains(pt(x, y)) {
                    return true;
                }
                let content = self.pane_layout(env).1;
                let vp = self.content_rect();
                let max_scroll = (content - vp.height).max(0.0);
                self.scroll_body.wheel(Some(ui.gesture_or_wheel(dx, dy)), dx, dy, k, max_scroll, vp.height, env.steady);
                true
            }
            InputEvent::KeyDown { key, modifiers } => self.key_down(key, modifiers, env, ui),
            _ => true,
        }
    }

    fn push_menu(&self, items: Vec<SQMenuItem>, at: CGPoint) {
        self.push(StartAction::Menu { items, point: at, anchor_top: None, pointer: None });
    }

    /// The grid/list toggle by keyboard: Tab focuses it, Left (grid) and Right (list) choose, Escape leaves. True when handled.
    pub(crate) fn key_toggle(&mut self, key: InputKey) -> bool {
        match key {
            InputKey::Character('\t') => {
                self.toggle_focus = !self.toggle_focus;
                true
            }
            InputKey::Left | InputKey::Right if self.toggle_focus => {
                self.set_list_layout(key == InputKey::Right);
                true
            }
            InputKey::Escape if self.toggle_focus => {
                self.toggle_focus = false;
                true
            }
            InputKey::Up | InputKey::Down => {
                self.toggle_focus = false;
                false
            }
            _ => false,
        }
    }

    fn key_down(&mut self, key: InputKey, m: InputModifiers, env: &StartEnv, ui: &mut UiCx) -> bool {
        if self.search.is_editing() {
            if key == InputKey::Escape {
                if self.query().is_empty() {
                    self.search.cancel();
                } else {
                    self.set_query("");
                    self.search.mouse_down(None, 1);
                }
                return true;
            }
            if key == InputKey::Down || key == InputKey::Up || key == InputKey::Enter {
                let _ = self.search.commit();
            } else {
                let _ = self.search.key(key, m, ui);
                self.query_changed();
                return true;
            }
        }
        if self.tab == StartTab::Recent && !env.recents.is_empty() && self.key_toggle(key) {
            return true;
        }
        match key {
            InputKey::Character('f' | 'F') if m == InputModifiers::COMMAND => {
                self.search.mouse_down(None, 1);
                true
            }
            InputKey::Escape => {
                if StartOverlayPolicy::escape_closes(env.has_real_project) {
                    self.push(StartAction::Hide);
                }
                true
            }
            // The cards read in order, so the arrow keys step through them the same way in the grid and in the list.
            InputKey::Up | InputKey::Down | InputKey::Left | InputKey::Right => {
                let list: Vec<RecentEntry> =
                    self.shown(env).into_iter().filter(|e| !self.missing.contains(&e.path)).collect();
                if list.is_empty() {
                    return true;
                }
                let hp = self.highlighted_path(env);
                let i = list.iter().position(|e| Some(&e.path) == hp.as_ref()).unwrap_or(0) as i64;
                let forward = matches!(key, InputKey::Down | InputKey::Right);
                let next = (i + if forward { 1 } else { -1 }).clamp(0, list.len() as i64 - 1) as usize;
                self.selected_path = Some(list[next].path.clone());
                true
            }
            InputKey::Enter => {
                if let Some(path) = self.highlighted_path(env) {
                    // Return opens the highlighted (else the newest) project, as in Swift; logged because a stray
                    // Return after a dialog looks like "a different project opened by itself".
                    crate::shell_log::info(&format!("start Return opens {path}"));
                    self.open(&path);
                }
                true
            }
            _ => false,
        }
    }

    pub(crate) fn press(&mut self, h: &StartHit, p: CGPoint, env: &StartEnv) {
        match h {
            StartHit::NewProject | StartHit::EmptyNew | StartHit::AllFormats => {
                self.push(StartAction::Execute(EditorCommand::NewProject));
            }
            StartHit::OpenOther | StartHit::EmptyOpen => self.push(StartAction::Execute(EditorCommand::OpenProject)),
            StartHit::Tab(t) => self.set_tab(*t),
            StartHit::ReopenLast => {
                self.reopen_last = !self.reopen_last;
                self.settings.push((REOPEN_LAST_KEY.into(), crate::shell_host::SettingValue::Flag(self.reopen_last)));
            }
            // Appearance opens Preferences (its Appearance row): matches Swift (`ShellStart.press`, no popover in the shared shell).
            StartHit::Appearance => self.push(StartAction::Execute(EditorCommand::Preferences)),
            StartHit::Feedback => self.push(StartAction::Perform(ShellAction::SendFeedback)),
            StartHit::ReportIssue => self.push(StartAction::Perform(ShellAction::ReportIssue)),
            StartHit::Support(s) => self.push(StartAction::Perform(ShellAction::Support(*s))),
            StartHit::Search => self.search.mouse_down(None, 1),
            StartHit::ClearSearch => self.set_query(""),
            StartHit::Sort => {
                let items = StartSort::ALL
                    .iter()
                    .map(|s| {
                        let mut i = SQMenuItem::new(s.raw());
                        i.is_checked = *s == self.sort;
                        let (q, s) = (Rc::clone(&self.queue), *s);
                        i.action = Some(Rc::new(move || q.borrow_mut().push(StartAction::SetSort(s))));
                        i
                    })
                    .collect();
                let r = self.sort_rect(env);
                self.push(StartAction::Menu {
                    items,
                    point: CGPoint::new(r.min_x(), r.max_y()),
                    anchor_top: None,
                    pointer: Some(p),
                });
            }
            StartHit::Layout(list) => self.set_list_layout(*list),
            StartHit::Card(path) => self.open(path),
            StartHit::CardMore(path) => {
                self.recheck(path);
                self.push_menu(self.recent_menu(path), p);
            }
            StartHit::ContinueOpen => {
                if let Some(c) = self.current(env) {
                    self.open(&c.path);
                }
            }
            StartHit::QuickSize(id) => {
                if Self::built_in().iter().any(|t| &t.id == id) {
                    self.push(StartAction::QuickCreate(id.clone()));
                }
            }
            StartHit::Template(id) => {
                if Self::built_in().iter().chain(self.user_templates.iter()).any(|t| &t.id == id) {
                    self.push(StartAction::CreateNamed(id.clone()));
                }
            }
            StartHit::Lesson(1) => self.set_tab(StartTab::Templates),
            // "How to save a template" in Yours: the Learn card "Keep your setup" explains it.
            StartHit::Lesson(2) => self.set_tab(StartTab::Learn),
            StartHit::Lesson(_) => self.push(StartAction::Execute(EditorCommand::KeyboardShortcuts)),
            // The Try button runs the command the changelog names, through the same routing as a menu pick.
            StartHit::Try(i) => {
                if let Some(c) = self.whats_new.help_rows().get(*i).and_then(|t| t.command) {
                    // The feature lives in the editor: leave the start window first.
                    self.push(StartAction::Hide);
                    self.push(StartAction::Execute(c));
                }
            }
        }
    }

    /// Looks at `path` again before a click, a right click or Return acts on it: the recents are read when the window
    /// shows, and the file can be moved, renamed or deleted while the window is up. A file that is gone now gets the
    /// "File not found" card and the Locate… menu, like one that was gone at launch.
    fn recheck(&mut self, path: &str) {
        if !self.missing.contains(path) && !std::path::Path::new(path).exists() {
            self.infos.remove(path);
            self.missing.insert(path.to_string());
        }
    }

    /// A card's click: open, or locate a project file that is gone.
    fn open(&mut self, path: &str) {
        self.recheck(path);
        self.push(if self.missing.contains(path) {
            StartAction::Locate(path.into())
        } else {
            StartAction::Open(path.into())
        });
    }

    fn item(&self, title: &str, action: StartAction) -> SQMenuItem {
        let mut i = SQMenuItem::new(title);
        let q = Rc::clone(&self.queue);
        i.action = Some(Rc::new(move || q.borrow_mut().push(action.clone())));
        i
    }

    /// `StartWindowView.recentMenu`.
    pub(crate) fn recent_menu(&self, path: &str) -> Vec<SQMenuItem> {
        let gone = self.missing.contains(path);
        let mut reveal_item = self.item(Platform::current().reveal_title(), StartAction::Reveal(path.into()));
        reveal_item.is_enabled = !gone;
        vec![
            if gone {
                self.item("Locate…", StartAction::Locate(path.into()))
            } else {
                self.item("Open", StartAction::Open(path.into()))
            },
            reveal_item,
            SQMenuItem::separator(),
            self.item("Remove from Recents", StartAction::RemoveRecent(path.into())),
            self.item("Remove All from Recents", StartAction::ClearRecents),
        ]
    }

    /// `StartWindowView.templateMenu` for a saved template (a right click on its card; built-ins have no menu).
    pub(crate) fn template_menu(&self, t: &ProjectTemplate) -> Vec<SQMenuItem> {
        vec![
            self.item("Create Project", StartAction::CreateNamed(t.id.clone())),
            SQMenuItem::separator(),
            self.item("Rename…", StartAction::RenameTemplate(t.id.clone())),
            self.item("Delete Template", StartAction::DeleteTemplate(t.id.clone())),
        ]
    }

    /// Reads the recents' files (`pruneRecentsInBackground`): which are gone, frame size and length; and the user's templates.
    pub fn reload(&mut self, recents: &[RecentEntry], folder: Option<&TemplateFolder>) {
        let paths: Vec<String> = recents.iter().map(|e| e.path.clone()).collect();
        if let Some(f) = folder {
            // shortcut: ids only matter when a saved id collides with another; a fresh sequence stands in for the app's id source.
            self.user_templates = f.load(&mut sq_core_time::SequentialIds::default());
        }
        let gone: BTreeSet<String> = paths.iter().filter(|p| !std::path::Path::new(p).exists()).cloned().collect();
        let alive: Vec<String> = paths.into_iter().filter(|p| !gone.contains(p)).collect();
        self.infos = StartProjectInfo::read(&alive);
        self.missing = gone;
    }
}

/// Where the parts of the Continue box sit (see `continue_parts`).
pub(crate) struct ContinueParts {
    pub(crate) poster: CGRect,
    pub(crate) facts_x: f64,
    pub(crate) facts_w: f64,
    pub(crate) title_y: f64,
    pub(crate) open: CGRect,
}

/// `ListCol`: the columns of a list row.
pub(crate) struct ListColumns {
    pub(crate) name: CGRect,
    /// The left edge of each column, `None` when the row is too narrow for it.
    pub(crate) size: Option<f64>,
    pub(crate) aspect: Option<f64>,
    pub(crate) rate: Option<f64>,
    pub(crate) length: Option<f64>,
    pub(crate) edited: Option<f64>,
    pub(crate) more: CGRect,
}

/// The calendar of the day labels: the machine's time zone.
pub use sq_editor_session::es07_project_panel::LocalCalendar;

impl ShellHost {
    /// Pip on the start screen plays on its own clock: the loop must keep drawing frames while this is true.
    pub fn start_mascot_animating(&self) -> bool {
        self.draws_start_mascots && self.start.as_ref().is_some_and(|s| s.mascots.animating())
    }

    /// The start screen is up.
    pub fn is_start_shown(&self) -> bool {
        self.start.is_some()
    }

    /// The environment the start screen reads.
    pub(crate) fn start_env<'a, 'm>(
        &'a self,
        measure: &'a TextMeasure<'m>,
        has_real_project: bool,
        projects_root: &'a str,
        open_name: &'a str,
    ) -> StartEnv<'a, 'm> {
        StartEnv {
            recents: self.recents.entries(),
            measure,
            now: self.wall_now(),
            steady: self.now_seconds(),
            calendar: &LocalCalendar,
            has_real_project,
            projects_root,
            open_name,
            poster: self.start_poster.as_deref(),
        }
    }

    /// Window > Start Window, and the launch without a project.
    pub(crate) fn show_start(&mut self, cx: &mut ShellCx) {
        self.menu_bar.dismiss();
        let mut s = self.start.take().unwrap_or_else(|| ShellStartScreen::new(&self.start_settings));
        self.start_shown_for = Some(cx.session.project().id);
        self.start_shown_empty = cx.session.is_empty_untitled();
        s.reload(self.recents.entries(), self.template_folder.as_ref());
        self.start = Some(s);
        self.start_layout();
    }

    /// A fixed set of recent projects and a tab, for the `--pose start-*` shots (`home`, `recent`, `empty`, `templates`, `learn`,
    /// `new`). `false` when the start screen is not up or the view is unknown.
    pub fn present_sample_start(&mut self, view: &str) -> bool {
        // `real`: the Recent tab over the recents the app really loaded (shot setup for the website: demo projects in a support
        // folder's recents.json, their posters read from the project files); nothing is replaced.
        if view == "real" {
            let Some(screen) = self.start.as_mut() else { return false };
            screen.selected_path = None;
            screen.set_tab(StartTab::Recent);
            return true;
        }
        let tab = match view {
            "home" | "empty" => StartTab::Home,
            "recent" => StartTab::Recent,
            "templates" => StartTab::Templates,
            "learn" => StartTab::Learn,
            "new" => StartTab::WhatsNew,
            _ => return false,
        };
        let now = self.wall_now().unix_seconds();
        let rows: [(&str, i64, i64, i64, f64); 6] = [
            ("T2", 1080, 1920, 44, 600.0),
            ("TCL C7L x Paul Herter", 1920, 1080, 0, 86_400.0),
            ("C2171", 1080, 1350, 0, 3.0 * 86_400.0),
            ("C2170", 1080, 1920, 0, 4.0 * 86_400.0),
            ("Sequence 01", 1080, 1080, 0, 13.0 * 86_400.0),
            ("Beep", 0, 0, 0, 31.0 * 86_400.0),
        ];
        let entries: Vec<RecentEntry> = if view == "empty" {
            Vec::new()
        } else {
            rows.iter()
                .map(|r| {
                    RecentEntry::new(format!("/sample/{}.sqproj", r.0), r.0, Timestamp::from_unix_seconds(now - r.4))
                })
                .collect()
        };
        self.recents = RecentProjects::new(entries);
        let Some(screen) = self.start.as_mut() else { return false };
        screen.infos.clear();
        screen.missing.clear();
        // shortcut: real poster frames only when `SQ_START_SAMPLE_MEDIA` names a folder with `<n>.mp4` per row (a test tool, the
        // shots on a machine that has made them with ffmpeg); without it the cards keep their empty look. Upgrade when the
        // pose should ship its own pictures.
        let media_dir = std::env::var("SQ_START_SAMPLE_MEDIA").ok();
        for (n, r) in rows.iter().enumerate().filter(|_| view != "empty") {
            let path = format!("/sample/{}.sqproj", r.0);
            if r.1 == 0 {
                screen.missing.insert(path);
            } else {
                let poster = media_dir.as_ref().map(|d| format!("{d}/{n}.mp4"));
                screen.infos.insert(path, StartProjectInfo::new(r.1, r.2, 30.0, r.3, poster, 0.0));
            }
        }
        screen.selected_path = None;
        screen.set_tab(tab);
        true
    }

    /// Closes the start screen.
    pub fn hide_start(&mut self) {
        self.start = None;
    }

    /// Launch: reopen the last project when the user asked for it (`reopenLastOnLaunch`), otherwise the start screen.
    pub fn present_start_at_launch(&mut self, cx: &mut ShellCx) {
        if self.start_settings.reopen_last
            && let Some(last) = self.recents.entries().first()
            && last.url().exists()
        {
            let url = last.url();
            self.start_flow(ShellFlow::OpenProject(url));
        } else {
            self.show_start(cx);
        }
    }

    /// The start screen's controls that sit in the window's bar row (its search field): a drawn window caption must not
    /// take a press there as a window drag. Empty while the start screen is hidden or has its top row of its own.
    pub fn start_bar_controls(&self) -> Vec<CGRect> {
        match self.start.as_ref() {
            Some(s) if s.bar_frame.is_some() => vec![s.search_rect()],
            _ => Vec::new(),
        }
    }

    pub(crate) fn start_layout(&mut self) {
        let size = self.size();
        let bar_h = self.menu_bar.height();
        let (own, in_bar, lights) = (self.start_window_size, self.start_search_in_bar, self.window_lights);
        let inset = self.start_bar_right_inset;
        let Some(s) = self.start.as_mut() else { return };
        if let Some(own) = own {
            s.frame = CGRect::new(0.0, 0.0, own.width, own.height);
            s.bar_frame = None;
            s.title_inset = m::LIGHTS;
            return;
        }
        s.frame = CGRect::new(0.0, bar_h, size.width, (size.height - bar_h).max(0.0));
        s.title_inset = if lights { m::LIGHTS } else { m::S3 };
        s.bar_frame = if in_bar { Some(CGRect::new(0.0, 0.0, (size.width - inset).max(0.0), bar_h)) } else { None };
    }

    /// The start screen follows the project: it goes once a project is opened or created, and comes back after Close
    /// Project (the Mac `closeStartWindow` / `showStartWindow` calls in the file flows).
    pub fn sync_start(&mut self, cx: &mut ShellCx) {
        let id: Id = cx.session.project().id;
        let empty = cx.session.is_empty_untitled();
        let last = self.start_project_id.replace(id);
        // The start screen's "open project" line follows the session on its own (no layout pass runs in the app host).
        self.start_open_name = if empty { String::new() } else { cx.session.display_name() };
        self.start_has_project = !empty;
        if self.start.is_some() {
            if !empty && (Some(id) != self.start_shown_for || self.start_shown_empty) {
                self.hide_start();
            }
        } else if last.is_some_and(|l| l != id) && empty {
            self.show_start(cx);
        }
    }

    /// The steps for the host's windows now (`ShellStartWindows.steps` with this shell's start screen and project).
    pub fn start_window_steps(
        &self,
        session: &sq_editor_session::EditorSession,
        start_visible: bool,
        editor_visible: bool,
    ) -> Vec<StartWindowStep> {
        ShellStartWindows::steps(StartWindowState {
            start_shown: self.is_start_shown(),
            start_visible,
            editor_visible,
            has_real_project: !session.is_empty_untitled(),
        })
    }

    /// The start window's close button (`startWindowClosedByUser`): back to the open project, or quit (with the unsaved
    /// changes question) when there is none.
    pub fn start_window_closed_by_user(&mut self, cx: &mut ShellCx) {
        if cx.session.is_empty_untitled() {
            self.perform(cx, ShellAction::Quit);
        } else {
            self.hide_start();
        }
    }

    /// The editor window became the key window while the start window is up over a real project: the start window goes.
    /// The start window closes here and does not stay open behind the editor: matches Swift (`editorWindowActivated`), because
    /// the shell has one modal start screen that would otherwise take the editor's keys.
    pub fn editor_window_activated(&mut self, session: &sq_editor_session::EditorSession) {
        if self.start_window_size.is_some() && self.is_start_shown() && !session.is_empty_untitled() {
            self.hide_start();
        }
    }

    /// "Locate…" on a missing recent: choose the project file's new place; the entry moves there and the project opens.
    pub async fn locate_recent<R: crate::shell_flows::ShellRoot + ?Sized>(
        h: sq_runtime::UiRef<R>,
        url: std::path::PathBuf,
    ) {
        let Some(ask) = h.with(|r| r.shell_parts().files.choose_project()) else { return };
        let Some(new) = ask.await else { return };
        let path = url.to_string_lossy().into_owned();
        let moved = h.with(|r| {
            let shell = r.shell_parts().shell;
            shell.recents.relocate(&path, &new);
            shell.emit(ShellEvent::RecentsChanged);
            if let Some(s) = shell.start.as_mut() {
                s.missing.remove(&path);
            }
        });
        if moved.is_some() {
            Self::open_project(h, new).await;
        }
    }

    /// Forgets one recent and persists the list.
    pub fn remove_recent(&mut self, path: &str) {
        self.recents.remove(path);
        self.emit(ShellEvent::RecentsChanged);
    }

    /// Draws the start screen over the panels (under the menus), when it is up.
    pub(crate) fn draw_start(&mut self, c: &mut sq_draw::Canvas, t: &sq_draw::DrawTheme) {
        let Some(mut s) = self.start.take() else { return };
        let m = TextMeasure::new(c.atlas(), c.scale);
        let root = ShellPlatformText::abbreviating_home(&self.start_projects_root());
        {
            let env = self.start_env(&m, self.start_has_project, &root, &self.start_open_name);
            // shortcut: a fresh `UiCx` per draw (the search field only reads it for the clipboard and key repeat).
            s.draw(c, t, &env, &mut UiCx::new(), self.draws_start_mascots);
        }
        self.start = Some(s);
    }

    /// Applies what the start screen asked for.
    pub(crate) fn apply_start_actions(&mut self, cx: &mut ShellCx) {
        let Some(s) = self.start.as_mut() else { return };
        let (actions, settings) = (s.take_actions(), s.take_settings());
        for (key, value) in settings {
            self.emit(ShellEvent::Setting { key, value });
        }
        for a in actions {
            match a {
                StartAction::Execute(c) => {
                    self.execute(cx, c);
                }
                StartAction::Perform(a) => self.perform(cx, a),
                StartAction::Open(p) => self.start_flow(ShellFlow::OpenProject(p.into())),
                StartAction::Locate(p) => self.start_flow(ShellFlow::LocateRecent(p.into())),
                StartAction::QuickCreate(id) => self.start_flow(ShellFlow::QuickCreate(id)),
                StartAction::CreateNamed(id) => self.start_flow(ShellFlow::CreateNamed(id)),
                StartAction::Reveal(p) => self.emit(ShellEvent::RevealFile(p.into())),
                StartAction::RemoveRecent(p) => self.remove_recent(&p),
                StartAction::ClearRecents => self.perform(cx, ShellAction::ClearRecents),
                StartAction::SetSort(sort) => {
                    if let Some(s) = self.start.as_mut() {
                        s.set_sort(sort);
                    }
                }
                StartAction::Menu { items, point, anchor_top, pointer } => {
                    self.menu_bar.controller.present(items, point, None, anchor_top, pointer, &cx.measure);
                }
                StartAction::RenameTemplate(id) => self.start_flow(ShellFlow::RenameTemplate(id)),
                StartAction::DeleteTemplate(id) => self.start_flow(ShellFlow::DeleteTemplate(id)),
                StartAction::Hide => self.hide_start(),
            }
        }
        // A sort pick or a tab change made inside the loop leaves settings behind.
        if let Some(s) = self.start.as_mut() {
            for (key, value) in s.take_settings() {
                self.emit(ShellEvent::Setting { key, value });
            }
        }
    }

    /// One event for the start screen (the host calls it while the screen is up). True: taken.
    pub(crate) fn handle_start(&mut self, cx: &mut ShellCx, e: &InputEvent, scale: f32) -> bool {
        let Some(mut s) = self.start.take() else { return false };
        let root = ShellPlatformText::abbreviating_home(&self.start_projects_root());
        let name = if cx.session.is_empty_untitled() { String::new() } else { cx.session.display_name() };
        let took = {
            let env = self.start_env(&cx.measure, !cx.session.is_empty_untitled(), &root, &name);
            s.handle(e, scale, &env, cx.ui)
        };
        self.start = Some(s);
        self.apply_start_actions(cx);
        if took {
            return true;
        }
        // The screen is modal over its own area, but a press it did not take lies outside it: the window's bar row (the
        // menu titles took theirs already). Empty bar space is the window's (drag, double-click), never swallowed here.
        if matches!(e, InputEvent::MouseDown { .. }) {
            return false;
        }
        // The start screen is modal: its own keys first, then only the commands that start or open a project.
        if let InputEvent::KeyDown { key, modifiers } = *e
            && let Some(c) = crate::keys::ShellKeys::command(key, modifiers, self.focus, &self.map, self.mac_keys)
            && ALLOWED_COMMANDS.contains(&c)
        {
            self.execute(cx, c);
        }
        true
    }
}
