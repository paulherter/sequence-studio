// Swift: ShellMenuBar.swift (the AppKit import is not ported)
//! What a shell menu row does, the state the menus show and the main menu itself: `MenuBuilder.build` of the Mac app
//! translated from NSMenu to `SQMenuItem` trees. Same structure, same order, same key texts (Windows names on Windows).

use sq_core_color::ColorSpaceIdExt;
use sq_core_model::{ColorSpaceID, OutsideMediaMode, PixelAspect, ShapeKind};
use sq_core_project::support_policy::{SupportEntry, SupportLinks};
use sq_core_time::Timestamp;
use sq_editor_session::{CommandRouting, RecentEntry, editor_command_menu_help};
use sq_os::Platform;
use sq_uikit::autosave_version_label;
use sq_uikit::command_map::CommandMap;
use sq_uikit::editor_command::EditorCommand;
use sq_uikit::key_binding::{Key, KeyBinding, KeyModifiers};
use sq_uikit::key_binding_text::KeyBindingText;
use sq_uikit::localization::SQL10n;
use sq_uikit::menu_spec::{EditorMenus, Item, PROJECT_SUBMENU_TITLE};
use sq_uikit::panel_id::PanelID;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuItem, SQMenuItemKind, SQMenuTint};
use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::rc::Rc;

/// What a shell menu row does. The Mac shell sends these as AppKit selectors on `AppController`; here they are values the
/// host performs (`ShellMenuBar::build`'s `perform`), so the same menu works on any platform.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum ShellAction {
    /// A catalog command.
    Command(EditorCommand),
    // App menu and Help
    About,
    Quit,
    /// Mac app menu: the system's Hide.
    Hide,
    /// Mac app menu: the system's Hide Others.
    HideOthers,
    /// Mac app menu: the system's Show All.
    ShowAll,
    Support(SupportEntry),
    SendFeedback,
    /// What's new > Report on GitHub: a new issue with version and system filled in.
    ReportIssue,
    RevealLogs,
    WelcomeTour,
    CheckForUpdates,
    // File
    OpenRecent {
        path: String,
    },
    ClearRecents,
    RestoreAutosave {
        path: String,
    },
    SaveCheckpoint,
    RelinkMedia,
    ImportChecklist,
    ImportStyleKit,
    ExportStyleKit,
    UseKitCaptionStyle,
    /// File > Collect Files into Project Folder.
    CollectFiles,
    /// File > Media Management: the outside-files mode.
    OutsideMedia(OutsideMediaMode),
    ToggleCopyLibraryItems,
    ToggleWatchFolder,
    // Sequence > Format, Layer
    ChangeFormat,
    DuplicateAsFormat,
    NewSequenceFromTemplate,
    SaveSequenceAsTemplate,
    ProjectInputColor(Option<ColorSpaceID>),
    NewShape(ShapeKind),
    NewGraphicsClip,
    NewAdjustmentLayer,
    NewColorMatte,
    // Clip > Replace and Fit > Pixel Aspect
    PixelAspect(Option<PixelAspect>),
    CustomPixelAspect,
    // Window
    SelectWorkspace(String),
    SaveWorkspaceAs,
    RenameWorkspace,
    DeleteWorkspace,
    ResetLayout,
    ResetAllWorkspaces,
    TogglePanel(PanelID),
    Minimize,
    Zoom,
    History,
    StartWindow,
    BringAllToFront,
}

/// One autosave version as the menu needs it (`EditorSession::autosave_versions` element).
#[derive(Clone, Debug, PartialEq)]
pub struct AutosaveVersionRow {
    /// The version's package path.
    pub path: String,
    /// When it was written.
    pub date: Timestamp,
    /// The checkpoint name; `None` for a timed autosave.
    pub name: Option<String>,
}

/// Clip > Replace and Fit > Pixel Aspect rows (the pure part of the Mac `PixelAspectMenuTarget`).
#[derive(Clone, Debug, PartialEq)]
pub struct PixelAspectRows {
    /// The preset rows.
    pub rows: Vec<PixelAspectRow>,
    /// The Custom row's title.
    pub custom_title: String,
    /// The Custom row's check.
    pub custom_checked: bool,
}

/// One preset row of [`PixelAspectRows`].
#[derive(Clone, Debug, PartialEq)]
pub struct PixelAspectRow {
    /// Shown title.
    pub title: String,
    /// The ratio; `None` = from file.
    pub aspect: Option<PixelAspect>,
    /// Check mark.
    pub checked: bool,
}

/// The state the menus show (what `validateMenuItem` and the `NSMenuDelegate` fills read on the Mac).
#[derive(Clone, Debug, PartialEq)]
pub struct ShellMenuState {
    /// Open Recent rows.
    pub recents: Vec<RecentEntry>,
    /// `session.autosaveVersions`, newest first.
    pub autosave_versions: Vec<AutosaveVersionRow>,
    /// Workspace names.
    pub workspaces: Vec<String>,
    /// The current workspace.
    pub current_workspace: Option<String>,
    /// Panels with a check in the Window menu.
    pub visible_panels: HashSet<PanelID>,
    /// Panels whose Window row is disabled (shown, not stored: Steps while the Color grade is Simple).
    pub unavailable_panels: HashSet<PanelID>,
    /// The open window's name (the project's display name, as the Mac `window.title`): the Mac Window menu ends with the
    /// system window list, one checked row for the key window. `None`: no row (start screen).
    pub window_name: Option<String>,
    /// The project's input color space.
    pub project_input_color: Option<ColorSpaceID>,
    /// The Mac `validateMenuItem` rules of the shell rows: Format needs a sequence ...
    pub has_sequence: bool,
    /// ... Reconnect Media missing files ...
    pub can_relink: bool,
    /// ... Rename / Delete Workspace a user workspace ...
    pub can_rename_workspace: bool,
    /// ... Reset to Saved Layout a changed one ...
    pub can_reset_workspace: bool,
    /// ... Import Checklist a Premiere import.
    pub has_import_checklist: bool,
    /// File > Media Management checks: the effective outside-files mode ...
    pub outside_media: OutsideMediaMode,
    /// ... library copies ...
    pub copy_library_items: bool,
    /// ... and folder watching; the last two need a project in its own folder (`MediaMenuTarget.validateMenuItem`).
    pub watch_folder: bool,
    /// The project sits in its own folder.
    pub in_project_folder: bool,
    /// Toggle commands shown with a check mark (View > Audio Scrubbing, Safe Margins...).
    pub checked_commands: HashSet<EditorCommand>,
    /// Pixel aspect rows of the selected Project items; `None` = no media selection (the submenu rows are disabled).
    pub pixel_aspect: Option<PixelAspectRows>,
    /// Name of the step Undo would undo.
    pub undo_name: Option<String>,
    /// Name of the step Redo would redo.
    pub redo_name: Option<String>,
    /// Titles that replace a command's own while it runs: "Cancel Anonymize" (the Mac `validateMenuItem`).
    pub titles: HashMap<EditorCommand, String>,
    /// Why a command cannot run now: shown as the help line under its row while the row is disabled.
    pub reasons: HashMap<EditorCommand, String>,
    /// The project chooser is up: only commands that start or open a project (and app-level items) work.
    pub chooser_shown: bool,
    /// A dialog waits for an answer: nothing reaches the project behind it.
    pub modal_shown: bool,
    /// The time the version labels count from (the host sets it from its clock).
    pub now: Timestamp,
}

impl Default for ShellMenuState {
    fn default() -> ShellMenuState {
        ShellMenuState {
            recents: Vec::new(),
            autosave_versions: Vec::new(),
            workspaces: Vec::new(),
            current_workspace: None,
            visible_panels: HashSet::new(),
            unavailable_panels: HashSet::new(),
            window_name: None,
            project_input_color: None,
            has_sequence: true,
            can_relink: true,
            can_rename_workspace: true,
            can_reset_workspace: true,
            has_import_checklist: false,
            outside_media: OutsideMediaMode::Ask,
            copy_library_items: true,
            watch_folder: false,
            in_project_folder: false,
            checked_commands: HashSet::new(),
            pixel_aspect: None,
            undo_name: None,
            redo_name: None,
            titles: HashMap::new(),
            reasons: HashMap::new(),
            chooser_shown: false,
            modal_shown: false,
            now: Timestamp::from_unix_seconds(0.0),
        }
    }
}

/// One top-level menu of the bar.
#[derive(Clone, Debug, PartialEq)]
pub struct ShellMenu {
    /// Shown title.
    pub title: String,
    /// The rows.
    pub items: Vec<SQMenuItem>,
}

impl ShellMenu {
    /// A menu.
    pub fn new(title: &str, items: Vec<SQMenuItem>) -> ShellMenu {
        ShellMenu { title: title.to_string(), items }
    }
}

/// Runs a chosen row (the host queues the action and performs it after the menu closed).
pub type PerformAction = Rc<dyn Fn(ShellAction)>;

/// The enabled rule of a command row (`ShellCommands::enabled`, the Mac `commandEnabled`).
pub type ValidateCommand<'a> = Option<&'a dyn Fn(EditorCommand) -> bool>;

/// The main menu (Swift `ShellMenuBar`).
pub enum ShellMenuBar {}

impl ShellMenuBar {
    /// The main menu: app menu, `EditorMenus::visible` with the File, Sequence, Clip and Window extensions, Help. Mac-only
    /// system rows (Hide, Hide Others, Show All, Bring All to Front) are left out off the Mac. `validate`: the enabled rule
    /// of a command row; `None`: all enabled.
    pub fn build(
        state: &ShellMenuState,
        map: &CommandMap,
        platform: Platform,
        validate: ValidateCommand,
        perform: PerformAction,
    ) -> Vec<ShellMenu> {
        let b = Builder { state, map, platform, validate, perform };
        let mut out = vec![ShellMenu { title: SQL10n::string("Sequence Studio"), items: b.app_menu() }];
        for spec in EditorMenus::visible() {
            let mut items = b.items(&spec.items);
            if spec.title == "File" {
                b.extend_file(&mut items);
            }
            if spec.title == "Sequence" {
                b.extend_sequence(&mut items);
            }
            if spec.title == "Clip" {
                b.extend_clip(&mut items);
            }
            if spec.title == "Window" {
                b.window_menu(&mut items);
            }
            out.push(ShellMenu { title: SQL10n::string(&spec.title), items: Self::tidy(items) });
        }
        out.push(ShellMenu { title: SQL10n::string("Help"), items: b.help_menu() });
        out
    }

    /// Wired and worth a menu item (`MenuBuilder.isVisible`).
    pub fn is_visible(c: EditorCommand) -> bool {
        EditorMenus::always_shown().contains(&c) || CommandRouting::is_supported(&c)
    }

    /// Drops leading, trailing and doubled separators left behind by hidden items.
    pub fn tidy(items: Vec<SQMenuItem>) -> Vec<SQMenuItem> {
        let mut out: Vec<SQMenuItem> = Vec::new();
        for i in items {
            if i.kind == SQMenuItemKind::Separator && out.last().is_none_or(|l| l.kind == SQMenuItemKind::Separator) {
                continue;
            }
            out.push(i);
        }
        while out.last().is_some_and(|l| l.kind == SQMenuItemKind::Separator) {
            out.pop();
        }
        out
    }

    /// The support color of the heart row (`Theme.Colors.support`).
    fn support_tint() -> SQMenuTint {
        sq_uikit::redesign_tokens::color::SUPPORT.palette_color(true)
    }
}

struct Builder<'a> {
    state: &'a ShellMenuState,
    map: &'a CommandMap,
    platform: Platform,
    validate: ValidateCommand<'a>,
    perform: PerformAction,
}

impl Builder<'_> {
    fn key_text(&self, b: &KeyBinding) -> String {
        KeyBindingText::text(b, self.platform)
    }

    fn row(
        &self,
        title: &str,
        a: ShellAction,
        shortcut: &str,
        enabled: bool,
        checked: bool,
        help: Option<&str>,
    ) -> SQMenuItem {
        let perform = Rc::clone(&self.perform);
        let mut item = SQMenuItem::new(title);
        item.shortcut = shortcut.to_string();
        item.is_enabled = enabled && self.allowed(&a);
        item.is_checked = checked;
        item.help = help.map(str::to_string);
        item.action = Some(Rc::new(move || perform(a.clone())));
        item
    }

    fn plain(&self, title: &str, a: ShellAction) -> SQMenuItem {
        self.row(title, a, "", true, false, None)
    }

    fn sub(&self, title: &str, items: Vec<SQMenuItem>) -> SQMenuItem {
        let mut item = SQMenuItem::new(title);
        item.submenu = Some(items);
        item
    }

    /// `validateMenuItem`'s gate: a dialog blocks everything, the project chooser lets only project starts and app items through.
    fn allowed(&self, a: &ShellAction) -> bool {
        if self.state.modal_shown {
            return false;
        }
        if !self.state.chooser_shown {
            return true;
        }
        match a {
            ShellAction::Command(c) => {
                matches!(
                    c,
                    EditorCommand::NewProject
                        | EditorCommand::OpenProject
                        | EditorCommand::Preferences
                        | EditorCommand::KeyboardShortcuts
                )
            }
            ShellAction::OpenRecent { .. }
            | ShellAction::ClearRecents
            | ShellAction::About
            | ShellAction::Quit
            | ShellAction::Support(_)
            | ShellAction::SendFeedback
            | ShellAction::ReportIssue
            | ShellAction::RevealLogs
            | ShellAction::Hide
            | ShellAction::HideOthers
            | ShellAction::ShowAll
            | ShellAction::Minimize
            | ShellAction::Zoom
            | ShellAction::StartWindow => true,
            _ => false,
        }
    }

    /// `MenuBuilder.menuItem(for:)`: title, help line and the binding text.
    fn command(&self, c: EditorCommand) -> SQMenuItem {
        let mut title = c.title();
        if c == EditorCommand::Undo {
            title = self
                .state
                .undo_name
                .as_deref()
                .map_or_else(|| "Undo".to_string(), |n| SQL10n::format("Undo %@", &[&SQL10n::undo_name(n)]));
        }
        if c == EditorCommand::Redo {
            title = self
                .state
                .redo_name
                .as_deref()
                .map_or_else(|| "Redo".to_string(), |n| SQL10n::format("Redo %@", &[&SQL10n::undo_name(n)]));
        }
        if let Some(running) = self.state.titles.get(&c) {
            title = running.clone();
        }
        let mut enabled = self.validate.is_none_or(|v| v(c));
        if c == EditorCommand::Undo {
            enabled = self.state.undo_name.is_some();
        }
        if c == EditorCommand::Redo {
            enabled = self.state.redo_name.is_some();
        }
        let shortcut = self.map.shown_binding_for(&c, self.platform).map(|b| self.key_text(&b)).unwrap_or_default();
        let why = if enabled { None } else { self.state.reasons.get(&c).map(String::as_str) };
        self.row(
            &title,
            ShellAction::Command(c),
            &shortcut,
            enabled,
            self.state.checked_commands.contains(&c),
            why.or_else(|| editor_command_menu_help(c)),
        )
    }

    fn items(&self, spec: &[Item]) -> Vec<SQMenuItem> {
        let mut out = Vec::new();
        for item in spec {
            match item {
                Item::Separator => out.push(SQMenuItem::separator()),
                Item::Command(c) => {
                    if ShellMenuBar::is_visible(*c) {
                        out.push(self.command(*c));
                    }
                }
                Item::Submenu(title, s) => {
                    let m = ShellMenuBar::tidy(self.items(s));
                    if !m.is_empty() {
                        out.push(self.sub(title, m));
                    }
                }
            }
        }
        out
    }

    fn app_menu(&self) -> Vec<SQMenuItem> {
        let mac = self.platform == Platform::Mac;
        let mut m = vec![
            self.plain("About Sequence Studio", ShellAction::About),
            SQMenuItem::separator(),
            self.command(EditorCommand::Preferences),
            self.command(EditorCommand::KeyboardShortcuts),
            SQMenuItem::separator(),
        ];
        if mac {
            m.push(self.row(
                "Hide Sequence Studio",
                ShellAction::Hide,
                &self.key_text(&KeyBinding::new(Key::Char('h'), KeyModifiers::COMMAND)),
                true,
                false,
                None,
            ));
            m.push(self.row(
                "Hide Others",
                ShellAction::HideOthers,
                &self.key_text(&KeyBinding::new(Key::Char('h'), KeyModifiers::OPTION | KeyModifiers::COMMAND)),
                true,
                false,
                None,
            ));
            m.push(self.plain("Show All", ShellAction::ShowAll));
            m.push(SQMenuItem::separator());
        }
        // Mac Cmd+Q, Linux Ctrl+Q (the desktop convention; the shell takes the key itself), Windows Alt+F4 (the system's).
        let quit = if mac || self.platform == Platform::Linux {
            KeyBinding::new(Key::Char('q'), KeyModifiers::COMMAND)
        } else {
            KeyBinding::new(Key::Function(4), KeyModifiers::OPTION)
        };
        m.push(self.row(
            if mac { "Quit Sequence Studio" } else { "Exit" },
            ShellAction::Quit,
            &self.key_text(&quit),
            true,
            false,
            None,
        ));
        m
    }

    fn help_menu(&self) -> Vec<SQMenuItem> {
        let mut m = Vec::new();
        for e in SupportEntry::visible(SupportLinks::DISCORD) {
            let mut i = self.plain(&e.help_title(), ShellAction::Support(e));
            if let Some(icon) = SQIcon::from_raw(e.symbol()) {
                i = i.with_leading(icon, (e == SupportEntry::Support).then(ShellMenuBar::support_tint));
            }
            m.push(i);
        }
        m.push(SQMenuItem::separator());
        m.push(self.command(EditorCommand::KeyboardShortcuts));
        m.push(self.plain("Send Feedback…", ShellAction::SendFeedback));
        m.push(self.plain("Reveal Logs and Reports", ShellAction::RevealLogs));
        m.push(self.plain("Welcome Tour…", ShellAction::WelcomeTour));
        m.push(self.plain("Check for Updates…", ShellAction::CheckForUpdates));
        m
    }

    /// Open Recent right after Open Project; the stateful project items join File > Project.
    fn extend_file(&self, items: &mut Vec<SQMenuItem>) {
        let mut recent: Vec<SQMenuItem> = self
            .state
            .recents
            .iter()
            .map(|e| {
                let name = Path::new(&e.path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                self.row(&name, ShellAction::OpenRecent { path: e.path.clone() }, "", true, false, Some(&e.path))
            })
            .collect();
        if !recent.is_empty() {
            recent.push(SQMenuItem::separator());
        }
        recent.push(self.row("Clear Menu", ShellAction::ClearRecents, "", !self.state.recents.is_empty(), false, None));
        let open = SQL10n::string(&EditorCommand::OpenProject.title());
        let at = items.iter().position(|i| i.title == open).map_or(items.len(), |i| i + 1);
        items.insert(at, self.sub("Open Recent", recent));

        let project_title = SQL10n::string(PROJECT_SUBMENU_TITLE);
        let pi = items.iter().position(|i| i.submenu.is_some() && i.title == project_title);
        let mut project: Vec<SQMenuItem> = pi.and_then(|i| items[i].submenu.clone()).unwrap_or_default();
        if !project.is_empty() {
            project.push(SQMenuItem::separator());
        }
        // Control-Command-S on the Mac (Command-S is Save, Shift Save As, Option Save a Copy). Command is Ctrl on Windows and
        // Linux, so the same chord would read Ctrl+S, the Save key: the item is menu only there.
        let checkpoint_key = if self.platform == Platform::Mac {
            self.key_text(&KeyBinding::new(Key::Char('s'), KeyModifiers::CONTROL | KeyModifiers::COMMAND))
        } else {
            String::new()
        };
        project.push(self.row("Save Checkpoint…", ShellAction::SaveCheckpoint, &checkpoint_key, true, false, None));
        project.push(self.sub("Autosave Versions", self.autosave_rows()));
        project.push(self.row("Reconnect Media…", ShellAction::RelinkMedia, "", self.state.can_relink, false, None));
        project.push(self.row(
            "Import Checklist…",
            ShellAction::ImportChecklist,
            "",
            self.state.has_import_checklist,
            false,
            None,
        ));
        project.push(self.sub(
            "Style Kit",
            vec![
                self.plain("Import Style Kit…", ShellAction::ImportStyleKit),
                self.plain("Export Style Kit…", ShellAction::ExportStyleKit),
                self.plain("Use Brand Caption Style", ShellAction::UseKitCaptionStyle),
            ],
        ));
        match pi {
            Some(i) => items[i].submenu = Some(project),
            None => items.push(self.sub(PROJECT_SUBMENU_TITLE, project)),
        }
        // `AppController.installFileExtras`: Collect and Media Management close the File menu.
        items.push(SQMenuItem::separator());
        items.push(self.plain("Collect Files into Project Folder", ShellAction::CollectFiles));
        items.push(self.sub("Media Management", self.media_rows()));
    }

    /// `MediaMenuTarget.items`: the four outside-file modes, then library copies and folder watching.
    fn media_rows(&self) -> Vec<SQMenuItem> {
        let modes = [
            (OutsideMediaMode::Ask, "Ask About Outside Files"),
            (OutsideMediaMode::Copy, "Copy Outside Files Into Project"),
            (OutsideMediaMode::Move, "Move Outside Files Into Project"),
            (OutsideMediaMode::Leave, "Leave Outside Files Where They Are"),
        ];
        let mut rows: Vec<SQMenuItem> = modes
            .iter()
            .map(|(mode, title)| {
                self.row(title, ShellAction::OutsideMedia(*mode), "", true, self.state.outside_media == *mode, None)
            })
            .collect();
        rows.push(SQMenuItem::separator());
        rows.push(self.row(
            "Copy Library Items Into Project",
            ShellAction::ToggleCopyLibraryItems,
            "",
            self.state.in_project_folder,
            self.state.copy_library_items,
            None,
        ));
        rows.push(self.row(
            "Watch Project Folder",
            ShellAction::ToggleWatchFolder,
            "",
            self.state.in_project_folder,
            self.state.watch_folder,
            None,
        ));
        rows
    }

    /// `fillAutosaveMenu`: named checkpoints first (bookmark icon), then the timed autosaves; "Latest" marks the newest.
    fn autosave_rows(&self) -> Vec<SQMenuItem> {
        let all = &self.state.autosave_versions;
        let versions: Vec<&AutosaveVersionRow> =
            all.iter().filter(|v| v.name.is_some()).chain(all.iter().filter(|v| v.name.is_none())).collect();
        let newest_plain = all.iter().find(|v| v.name.is_none());
        let mut out: Vec<SQMenuItem> = versions
            .iter()
            .map(|v| {
                let absolute = absolute_time(v.date);
                let title = match &v.name {
                    Some(name) => autosave_version_label::checkpoint_title(name, &absolute),
                    None => autosave_version_label::title(
                        &absolute,
                        v.date,
                        self.state.now,
                        newest_plain.is_some_and(|n| n == *v),
                    ),
                };
                let r = self.plain(&title, ShellAction::RestoreAutosave { path: v.path.clone() });
                if v.name.is_some() { r.with_leading(SQIcon::BookmarkFilled, None) } else { r }
            })
            .collect();
        if out.is_empty() {
            let mut none = SQMenuItem::new("No Versions Yet");
            none.is_enabled = false;
            out.push(none);
        }
        out
    }

    /// Clip > Replace and Fit > Pixel Aspect.
    fn extend_clip(&self, items: &mut Vec<SQMenuItem>) {
        let rows: Vec<SQMenuItem> = if let Some(p) = &self.state.pixel_aspect {
            let mut rows: Vec<SQMenuItem> = p
                .rows
                .iter()
                .map(|r| self.row(&r.title, ShellAction::PixelAspect(r.aspect), "", true, r.checked, None))
                .collect();
            if rows.len() > 1 {
                rows.insert(1, SQMenuItem::separator());
            }
            rows.push(SQMenuItem::separator());
            rows.push(self.row(&p.custom_title, ShellAction::CustomPixelAspect, "", true, p.custom_checked, None));
            rows
        } else {
            let disabled = |title: &str| {
                let mut i = SQMenuItem::new(title);
                i.is_enabled = false;
                i
            };
            vec![disabled("From File"), SQMenuItem::separator(), disabled("Custom Ratio…")]
        };
        let host = self.sub("Pixel Aspect", rows);
        let fit = SQL10n::string("Replace and Fit");
        match items.iter().position(|i| i.submenu.is_some() && i.title == fit) {
            Some(i) => {
                if let Some(s) = items[i].submenu.as_mut() {
                    s.push(host);
                }
            }
            None => items.push(host),
        }
    }

    /// Sequence > Format after Sequence Settings, and New > Layer.
    fn extend_sequence(&self, items: &mut Vec<SQMenuItem>) {
        let s = &self.state;
        let mut color = vec![
            self.row(
                "None (as tagged)",
                ShellAction::ProjectInputColor(None),
                "",
                true,
                s.project_input_color.is_none(),
                None,
            ),
            SQMenuItem::separator(),
        ];
        color.extend(ColorSpaceID::ALL.iter().map(|c| {
            self.row(
                c.display_name(),
                ShellAction::ProjectInputColor(Some(*c)),
                "",
                true,
                s.project_input_color == Some(*c),
                None,
            )
        }));
        let format = vec![
            self.row("Change Format…", ShellAction::ChangeFormat, "", s.has_sequence, false, None),
            self.row("Duplicate as Format…", ShellAction::DuplicateAsFormat, "", s.has_sequence, false, None),
            SQMenuItem::separator(),
            self.plain("New Sequence from Template…", ShellAction::NewSequenceFromTemplate),
            self.plain("Save Sequence as Template…", ShellAction::SaveSequenceAsTemplate),
            self.sub("Project Input Color Space", color),
        ];
        let settings = SQL10n::string(&EditorCommand::SequenceSettings.title());
        let at = items.iter().position(|i| i.title == settings).map_or(0, |i| i + 1);
        let at = at.min(items.len());
        items.insert(at, self.sub("Format", format));
        let layer = vec![
            self.sub(
                "New Shape",
                ShapeKind::ALL.iter().map(|k| self.plain(k.title(), ShellAction::NewShape(*k))).collect(),
            ),
            self.plain("New Graphics Clip", ShellAction::NewGraphicsClip),
            self.plain("New Adjustment Layer", ShellAction::NewAdjustmentLayer),
            self.plain("New Color Matte…", ShellAction::NewColorMatte),
        ];
        let new = SQL10n::string("New");
        let layer = self.sub("Layer", layer);
        match items.iter().position(|i| i.submenu.is_some() && i.title == new) {
            Some(i) => {
                if let Some(sm) = items[i].submenu.as_mut() {
                    sm.push(layer);
                }
            }
            None => items.push(layer),
        }
    }

    /// Window: Workspaces, one checkable item per panel (Tools after Timeline), More Panels, then the plain commands and
    /// App Windows.
    fn window_menu(&self, items: &mut Vec<SQMenuItem>) {
        let s = &self.state;
        let mut ws: Vec<SQMenuItem> = s
            .workspaces
            .iter()
            .map(|w| {
                self.row(
                    &sq_uikit::platform_wording::PlatformWording::workspace_name(w, self.platform),
                    ShellAction::SelectWorkspace(w.clone()),
                    "",
                    true,
                    s.current_workspace.as_deref() == Some(w),
                    None,
                )
            })
            .collect();
        ws.push(SQMenuItem::separator());
        ws.push(self.plain("Save as New Workspace…", ShellAction::SaveWorkspaceAs));
        ws.push(self.row("Rename Workspace…", ShellAction::RenameWorkspace, "", s.can_rename_workspace, false, None));
        ws.push(self.row("Delete Workspace", ShellAction::DeleteWorkspace, "", s.can_rename_workspace, false, None));
        ws.push(self.row(
            "Reset to Saved Layout",
            ShellAction::ResetLayout,
            &self.key_text(&KeyBinding::new(Key::Char('0'), KeyModifiers::OPTION | KeyModifiers::SHIFT)),
            s.can_reset_workspace,
            false,
            None,
        ));
        ws.push(self.plain("Reset All Workspaces", ShellAction::ResetAllWorkspaces));
        // The row shows the panel's Focus Panel key (Shift+1..9) while a click toggles the panel: the frozen Swift menu does the
        // same (ShellMenuBar.swift windowMenu `panel`, `.togglePanel` with the `.focusPanel` binding), so the Rust row keeps it.
        let panel = |p: PanelID| {
            let shortcut = self
                .map
                .shown_binding_for(&EditorCommand::FocusPanel(p), self.platform)
                .map(|b| self.key_text(&b))
                .unwrap_or_default();
            self.row(
                &EditorCommand::localized_panel_title(p),
                ShellAction::TogglePanel(p),
                &shortcut,
                !s.unavailable_panels.contains(&p),
                s.visible_panels.contains(&p),
                None,
            )
        };
        let mut head = vec![self.sub("Workspaces", ws), SQMenuItem::separator()];
        for p in EditorMenus::primary_window_panels() {
            head.push(panel(*p));
        }
        head.push(self.sub("More Panels", EditorMenus::secondary_window_panels().into_iter().map(panel).collect()));
        head.push(SQMenuItem::separator());
        let mac = self.platform == Platform::Mac;
        let mut windows = vec![
            self.plain("Minimize", ShellAction::Minimize),
            self.plain(if mac { "Zoom" } else { "Maximize" }, ShellAction::Zoom),
            SQMenuItem::separator(),
            self.plain("History", ShellAction::History),
            self.plain("Start Window", ShellAction::StartWindow),
        ];
        if mac {
            windows.push(SQMenuItem::separator());
            windows.push(self.plain("Bring All to Front", ShellAction::BringAllToFront));
        }
        let rest = std::mem::take(items);
        *items = head;
        items.extend(rest);
        items.push(SQMenuItem::separator());
        items.push(self.sub("App Windows", windows));
        // The window list macOS appends to `NSApp.windowsMenu`: the project window, checked as the key window.
        if mac && let Some(name) = s.window_name.as_deref().filter(|n| !n.is_empty()) {
            items.push(SQMenuItem::separator());
            items.push(self.row(name, ShellAction::BringAllToFront, "", true, true, None));
        }
    }
}

/// The write time of an autosave version: abbreviated date and standard time in the user's zone and language order.
pub fn absolute_time(t: Timestamp) -> String {
    sq_uikit::local_format::date_time_standard(t)
}

#[cfg(test)]
mod absolute_time_tests {
    use super::*;

    #[test]
    fn the_autosave_time_reads_in_the_local_zone_with_seconds() {
        let text = absolute_time(Timestamp::from_unix_seconds(1_794_332_036.0));
        // "Nov 10, 2026, 5:33:56 PM" in en, "10.11.2026, 17:33:56" in de, shifted by the zone: date, comma, clock with seconds.
        assert!(text.contains(", ") && text.matches(':').count() == 2, "{text}");
    }
}
