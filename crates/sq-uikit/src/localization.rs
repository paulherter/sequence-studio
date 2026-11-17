// Swift: Localization.swift
//! UI string lookup. American English is the source language: the English text is the key, so an untranslated string
//! shows English (fallback) and code stays readable. Catalogs are `resources/Localization/<lang>.lproj/Localizable.strings`.
//! The language follows the system preference list unless `sq.language` in the settings holds a supported code.
//! Add a language: put a `<code>.lproj` folder next to `de.lproj`, add it to `SQL10n::bundled` and append the code to `SUPPORTED`.
//!
//! Instead of the `Bundle` and `UserDefaults` reads, a `Catalogs` value holds the loaded catalogs and the interface
//! language. `SQL10n` is the process-wide front the rest of the code calls (like Swift's `SQL10n`): the app installs the
//! catalogs once at launch (`SQL10n::install`); without that the language is English unless `SQ_LANGUAGE` says otherwise.

use std::collections::BTreeMap;
use std::collections::HashSet;
use std::error::Error;
use std::sync::OnceLock;

use crate::editor_command::EditorCommand;
use crate::menu_spec::{EditorMenus, Item};
use crate::panel_id::PanelID;
use crate::sqaccessibility_text::SQAccessibilityText;
use sq_core_time::text::graphemes;

/// Settings key of the language override.
pub const DEFAULTS_KEY: &str = "sq.language";
/// The language of the keys.
pub const SOURCE_LANGUAGE: &str = "en";
/// Languages the interface offers.
pub const SUPPORTED: [&str; 2] = ["en", "de"];

/// The app is English only for now (the German strings stay in code for later): the interface language is English
/// whatever the system or `sq.language` say, and Settings hides the Interface Language row. Set it `false` to bring both back.
pub const ENGLISH_ONLY: bool = true;

/// The German catalog that ships with the app.
const GERMAN_STRINGS: &str = include_str!("../resources/Localization/de.lproj/Localizable.strings");

/// Key to translation of one language.
pub type Table = BTreeMap<String, String>;

/// Language code to use. `override_language` is the `sq.language` value ("system", `None` or unsupported means: follow `preferred`).
pub fn resolve_language(override_language: Option<&str>, preferred: &[&str]) -> String {
    if let Some(o) = override_language.filter(|o| *o != "system") {
        return if SUPPORTED.contains(&o) { o.to_string() } else { SOURCE_LANGUAGE.to_string() };
    }
    for tag in preferred {
        let code = tag.split(['-', '_']).find(|p| !p.is_empty()).unwrap_or("").to_lowercase();
        if SUPPORTED.contains(&code.as_str()) {
            return code;
        }
    }
    SOURCE_LANGUAGE.to_string()
}

/// The `sq.language` override to use: the environment variable `SQ_LANGUAGE` (a code or "system") beats the stored value
/// only outside an app bundle (scripts/test.sh sets it to `en` so tests that compare English UI text pass on a German
/// Mac). Inside the shipped .app an inherited environment variable must never force a language.
pub fn effective_override<'a>(env: Option<&'a str>, stored: Option<&'a str>, is_app_bundle: bool) -> Option<&'a str> {
    if let Some(e) = env.filter(|e| !is_app_bundle && !e.is_empty()) {
        return Some(e);
    }
    stored
}

/// The language the user has chosen right now: the system preference list plus the `sq.language` override, with the
/// environment variable `SQ_LANGUAGE` as `effective_override` takes it.
pub fn selected_language(env: Option<&str>, stored: Option<&str>, is_app_bundle: bool, preferred: &[&str]) -> String {
    if ENGLISH_ONLY {
        return SOURCE_LANGUAGE.to_string();
    }
    resolve_language(effective_override(env, stored, is_app_bundle), preferred)
}

/// One `%@` key as a pattern: the literal parts around the arguments, and the translation to fill.
#[derive(Clone, Debug)]
struct PatternEntry {
    parts: Vec<String>,
    translation: String,
    /// Length of the regular expression the Swift code builds; the longer literal text is tried first.
    pattern_length: usize,
}

/// Length of `s` after `NSRegularExpression.escapedPattern(for:)` (a backslash before each metacharacter).
fn escaped_length(s: &str) -> usize {
    graphemes(s)
        .map(|g| {
            if matches!(g, "\\" | "*" | "?" | "+" | "[" | "(" | ")" | "{" | "}" | "^" | "$" | "|" | "." | "/") {
                2
            } else {
                1
            }
        })
        .sum()
}

impl PatternEntry {
    fn new(key: &str, translation: &str) -> PatternEntry {
        let parts: Vec<String> = key.split("%@").map(str::to_string).collect();
        // "^" + parts joined with "(.+?)" + "$"
        let pattern_length = 2 + parts.iter().map(|p| escaped_length(p)).sum::<usize>() + 5 * (parts.len() - 1);
        PatternEntry { parts, translation: translation.to_string(), pattern_length }
    }

    /// The captured arguments when `text` is this key with `%@` filled in: the regex `^p0(.+?)p1(.+?)...pn$` with `.` matching newlines.
    fn captures(&self, text: &str) -> Option<Vec<String>> {
        let chars: Vec<char> = text.chars().collect();
        let parts: Vec<Vec<char>> = self.parts.iter().map(|p| p.chars().collect()).collect();
        if !chars.starts_with(&parts[0]) {
            return None;
        }
        let mut out = Vec::new();
        Self::match_after(&chars, &parts, 0, parts[0].len(), &mut out).then_some(out)
    }

    /// `parts[i]` has matched up to `pos`: matches the rest, each argument taking the fewest characters (at least one)
    /// that let the rest match.
    fn match_after(chars: &[char], parts: &[Vec<char>], i: usize, pos: usize, out: &mut Vec<String>) -> bool {
        let Some(next) = parts.get(i + 1) else { return pos == chars.len() };
        for end in (pos + 1)..=chars.len() {
            if !chars[end..].starts_with(next) {
                continue;
            }
            out.push(chars[pos..end].iter().collect());
            if Self::match_after(chars, parts, i + 1, end + next.len(), out) {
                return true;
            }
            out.pop();
        }
        false
    }
}

/// The loaded catalogs and the interface language.
#[derive(Clone, Debug)]
pub struct Catalogs {
    current_language: String,
    tables: BTreeMap<String, Table>,
    patterns: BTreeMap<String, Vec<PatternEntry>>,
    platform: sq_os::Platform,
}

impl Catalogs {
    /// Catalogs given as `(language, Localizable.strings text)`; `current_language` is fixed for the whole run, so one
    /// window never mixes two languages (a new choice applies at the next launch).
    pub fn new(current_language: &str, catalogs: &[(&str, &str)]) -> Catalogs {
        let mut tables = BTreeMap::new();
        let mut patterns = BTreeMap::new();
        for (language, text) in catalogs {
            let table = parse_strings(text);
            let mut entries: Vec<PatternEntry> =
                table.iter().filter(|(k, _)| k.contains("%@")).map(|(k, v)| PatternEntry::new(k, v)).collect();
            // Longer literal text first: the most specific key wins.
            entries.sort_by_key(|e| std::cmp::Reverse(e.pattern_length));
            patterns.insert(language.to_string(), entries);
            tables.insert(language.to_string(), table);
        }
        Catalogs {
            current_language: current_language.to_string(),
            tables,
            patterns,
            platform: sq_os::Platform::current(),
        }
    }

    /// The same catalogs worded for `platform` (the Mac wording becomes computer, Ctrl and Alt elsewhere).
    pub fn with_platform(mut self, platform: sq_os::Platform) -> Catalogs {
        self.platform = platform;
        self
    }

    /// The catalogs that ship with the app.
    pub fn bundled(current_language: &str) -> Catalogs {
        Catalogs::new(current_language, &[("de", GERMAN_STRINGS)])
    }

    /// Language in effect now.
    pub fn current_language(&self) -> &str {
        &self.current_language
    }

    /// Key to translation of one language (empty for English and unknown codes).
    pub fn table(&self, language: &str) -> &Table {
        static EMPTY: Table = BTreeMap::new();
        self.tables.get(language).unwrap_or(&EMPTY)
    }

    /// Translated text, or `key` itself when the language is English or the key is missing.
    pub fn string(&self, key: &str, language: Option<&str>) -> String {
        crate::platform_wording::PlatformWording::adapt(&self.string_raw(key, language), self.platform)
    }

    fn string_raw(&self, key: &str, language: Option<&str>) -> String {
        let lang = language.unwrap_or(&self.current_language);
        if lang == SOURCE_LANGUAGE {
            return key.to_string();
        }
        self.table(lang).get(key).cloned().unwrap_or_else(|| key.to_string())
    }

    /// Translates a finished English message whose arguments are already filled in (an engine error text, a stored status
    /// line): the exact key first, then every `%@` key matched as a pattern; its captured arguments are translated the same
    /// way (a nested message). English or no match: the text itself. The media and export crates cannot import this one, so
    /// their errors carry English and the display sink calls this.
    pub fn localized(&self, text: &str, language: Option<&str>) -> String {
        crate::platform_wording::PlatformWording::adapt(&self.localized_raw(text, language), self.platform)
    }

    fn localized_raw(&self, text: &str, language: Option<&str>) -> String {
        let lang = language.unwrap_or(&self.current_language);
        if lang == SOURCE_LANGUAGE {
            return text.to_string();
        }
        if let Some(t) = self.table(lang).get(text) {
            return t.clone();
        }
        for entry in self.patterns.get(lang).into_iter().flatten() {
            let Some(args) = entry.captures(text) else { continue };
            let args: Vec<String> = args.iter().map(|a| self.localized_raw(a, Some(lang))).collect();
            return format_string(&entry.translation, &args);
        }
        text.to_string()
    }

    /// The message of `error` in the interface language (`localized` over its description).
    pub fn error_text(&self, error: &dyn Error, language: Option<&str>) -> String {
        self.localized(&error.to_string(), language)
    }

    /// `string(format)` with `%@` arguments substituted.
    pub fn format(&self, format: &str, args: &[&str], language: Option<&str>) -> String {
        format_string(&self.string(format, language), args)
    }

    /// Keys of `required` that have no non-empty translation in `language`.
    pub fn missing_keys<'a>(&self, language: &str, required: &'a [String]) -> Vec<&'a String> {
        let t = self.table(language);
        required.iter().filter(|k| t.get(*k).is_none_or(|v| v.is_empty())).collect()
    }
}

static GLOBAL: OnceLock<Catalogs> = OnceLock::new();

/// The process-wide front of the lookup (Swift's static `SQL10n`). The `language` forms (`*_in`) translate into another
/// language than the interface one.
pub enum SQL10n {}

impl SQL10n {
    /// Installs the bundled catalogs for the interface language of this run; false when a language is already in effect.
    pub fn install(current_language: &str) -> bool {
        GLOBAL.set(Catalogs::bundled(current_language)).is_ok()
    }

    fn global() -> &'static Catalogs {
        GLOBAL.get_or_init(|| {
            let env = std::env::var("SQ_LANGUAGE").ok();
            Catalogs::bundled(&selected_language(env.as_deref(), None, false, &[]))
        })
    }

    /// The language of the keys.
    pub const SOURCE_LANGUAGE: &str = SOURCE_LANGUAGE;

    /// Language in effect now.
    pub fn current_language() -> String {
        Self::global().current_language().to_string()
    }

    /// Key to translation of one language (empty for English and unknown codes).
    pub fn table(language: &str) -> &'static Table {
        Self::global().table(language)
    }

    /// Translated text, or `key` itself when the language is English or the key is missing.
    pub fn string(key: &str) -> String {
        Self::global().string(key, None)
    }

    /// `string` for a given language.
    pub fn string_in(key: &str, language: &str) -> String {
        Self::global().string(key, Some(language))
    }

    /// Translates a finished English message whose arguments are already filled in, see `Catalogs::localized`.
    pub fn localized(text: &str) -> String {
        Self::global().localized(text, None)
    }

    /// `localized` for a given language.
    pub fn localized_in(text: &str, language: &str) -> String {
        Self::global().localized(text, Some(language))
    }

    /// The message of `error` in the interface language.
    pub fn error_text(error: &dyn Error) -> String {
        Self::global().error_text(error, None)
    }

    /// `string(format)` with `%@` arguments substituted.
    pub fn format(format: &str, args: &[&str]) -> String {
        Self::global().format(format, args, None)
    }

    /// `format` for a given language.
    pub fn format_in(format: &str, args: &[&str], language: &str) -> String {
        Self::global().format(format, args, Some(language))
    }

    /// Keys of `required` that have no non-empty translation in `language`.
    pub fn missing_keys<'a>(language: &str, required: &'a [String]) -> Vec<&'a String> {
        Self::global().missing_keys(language, required)
    }

    /// App menu, Help menu, Settings window and its page names.
    pub const CHROME_KEYS: &[&str] = CHROME_KEYS;
    /// Settings rows: row titles, group captions, checkbox texts and help lines of the Settings window.
    pub const SETTINGS_KEYS: &[&str] = SETTINGS_KEYS;
    /// Dialog titles, notes and buttons, dialog form rows and inspector labels.
    pub const DIALOG_KEYS: &[&str] = DIALOG_KEYS;

    /// The strings every supported language must translate (first vertical slice): menu and submenu titles, panel names,
    /// every menu command, app/Help/Settings chrome. The localization test fails when one is missing.
    pub fn required_keys() -> Vec<String> {
        fn walk(items: &[Item], keys: &mut Vec<String>) {
            for item in items {
                if let Item::Submenu(title, sub) = item {
                    keys.push(title.clone());
                    walk(sub, keys);
                }
            }
        }
        let mut keys: Vec<String> = Vec::new();
        for spec in EditorMenus::all() {
            keys.push(spec.title.clone());
            walk(&spec.items, &mut keys);
        }
        keys.extend(EditorMenus::all().iter().flat_map(|m| m.commands()).map(|c| c.title()));
        keys.extend(PanelID::ALL.iter().map(|p| EditorCommand::panel_title(*p).to_string()));
        for list in [
            Self::CHROME_KEYS,
            Self::SETTINGS_KEYS,
            Self::DIALOG_KEYS,
            Self::APP_MENU_KEYS,
            Self::UNDO_PATTERNS,
            Self::UNDO_NAMES,
            Self::SESSION_UNDO_NAMES,
            Self::STATUS_KEYS,
            Self::COUNT_KEYS,
            SQAccessibilityText::KEYS.as_slice(),
        ] {
            keys.extend(list.iter().map(|k| k.to_string()));
        }
        let mut seen = HashSet::new();
        keys.retain(|k| !k.is_empty() && seen.insert(k.clone()));
        keys
    }
}

/// `String(format:)` for the specifiers the catalogs use: `%@` and the integer forms take the next argument, `%%` is a percent sign.
fn format_string(format: &str, args: &[impl AsRef<str>]) -> String {
    let mut out = String::new();
    let mut next = args.iter();
    let mut chars = format.chars().peekable();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.peek() {
            Some('%') => {
                chars.next();
                out.push('%');
            }
            Some('@') => {
                chars.next();
                out.extend(next.next().map(|a| a.as_ref().to_string()));
            }
            Some('l' | 'd') => {
                while chars.next_if(|c| *c == 'l').is_some() {}
                if chars.next_if(|c| *c == 'd').is_some() {
                    out.extend(next.next().map(|a| a.as_ref().to_string()));
                } else {
                    out.push('%');
                }
            }
            _ => out.push('%'),
        }
    }
    out
}

/// Reads a `Localizable.strings` text: `"key" = "value";` pairs with `/* */` and `//` comments and the `\"`, `\\`, `\n`,
/// `\t` escapes. A malformed rest of the file is ignored.
pub fn parse_strings(text: &str) -> Table {
    let mut table = Table::new();
    let mut chars = text.chars().peekable();
    let quoted = |chars: &mut std::iter::Peekable<std::str::Chars>| -> Option<String> {
        loop {
            match chars.next()? {
                '"' => break,
                '/' if chars.peek() == Some(&'*') => {
                    let mut prev = ' ';
                    for c in chars.by_ref() {
                        if prev == '*' && c == '/' {
                            break;
                        }
                        prev = c;
                    }
                }
                '/' if chars.peek() == Some(&'/') => {
                    for c in chars.by_ref() {
                        if c == '\n' {
                            break;
                        }
                    }
                }
                _ => {}
            }
        }
        let mut s = String::new();
        loop {
            match chars.next()? {
                '"' => return Some(s),
                '\\' => match chars.next()? {
                    'n' => s.push('\n'),
                    't' => s.push('\t'),
                    other => s.push(other),
                },
                c => s.push(c),
            }
        }
    };
    while let Some(key) = quoted(&mut chars) {
        let Some(value) = quoted(&mut chars) else { break };
        table.insert(key, value);
    }
    table
}

/// App menu, Help menu, Settings window and its page names.
const CHROME_KEYS: &[&str] = &[
    "Sequence Studio",
    "About Sequence Studio",
    "Hide Sequence Studio",
    "Hide Others",
    "Show All",
    "Quit Sequence Studio",
    "Help",
    "Settings",
    "Settings…",
    "Keyboard Shortcuts…",
    "Done",
    "Cancel",
    "Send Feedback…",
    "Reveal Logs and Reports",
    "Welcome Tour…",
    "Check for Updates…",
    "Workspaces",
    "Tools",
    "Minimize",
    "Zoom",
    "History",
    "Start Window",
    "General",
    "Playback",
    "Editing",
    "Audio",
    "Media",
    "Advanced",
];
/// Settings rows: row titles, group captions, checkbox texts and help lines of the Settings window.
const SETTINGS_KEYS: &[&str] = &[
    "Audio Output",
    "Audio Scrubbing",
    "Autosave",
    "Background Work",
    "Cache",
    "Cache Folder",
    "Cache Size",
    "Card Import",
    "De-Click",
    "Default transition length",
    "Delete Key",
    "Dropped Frames",
    "Duck Timing",
    "Ducking",
    "Edit API",
    "Feedback",
    "Frame Cache",
    "Interface Size",
    "Library",
    "Library Folders",
    "Live Ducking",
    "Loudness",
    "New Sequences Start in",
    "New Text Length",
    "New items",
    "Outside Files",
    "Play around",
    "Postroll",
    "Preroll",
    "Preview Quality",
    "Project Folder",
    "Recovery",
    "Transcription",
    "Updates",
    "Your effect and transition defaults",
    "Offer to restore after an unclean quit",
    "Check for a newer version at launch",
    "Make proxies while you edit",
    "Play sound while dragging the playhead",
    "Show a dot when frames are dropped",
    "Duck music under dialogue while mixing",
    "Fade clip edges to prevent clicks",
    "Add new files in the project folder to the bin",
    "Open the import window when a card is connected",
    "Copy library items used in a sequence into the project",
    "Allow local tools to edit the open project",
    "Scales text and controls everywhere. Applies the next time Sequence Studio starts.",
    "Changed projects are saved to a recovery copy; your project file is only written when you save.",
    "After a crash, Sequence Studio offers the recovery copy the next time it starts.",
    "Not set up in this build yet: nothing is contacted.",
    "Asks one address for the newest version number; nothing else is sent.",
    "The language spoken in your footage. A project can pick another language in the Captions panel.",
    "The monitors' playback resolution at launch; change it any time in the monitor. Auto picks 1/2 on Macs with 8 GB or less and lowers the resolution while memory runs low. Export always uses full quality.",
    "Heavy clips get a lighter playback copy in the background. Turn off on a slow Mac to keep it quiet; it also pauses by itself when the Mac is hot or memory runs low.",
    "Seconds played before the marked range (Shift+Space) or the playhead (Shift+K).",
    "Seconds played after the marked range or the playhead.",
    "Where both monitors play sound. System Default follows the Mac's output; a device that is not connected falls back to it.",
    "A small dot in the Program monitor turns amber for two seconds when playback drops a frame. Hover it for the count of the last play.",
    "Closes the Gap removes the clip and pulls the rest of the track together. Leaves a Gap keeps the space empty. The other behavior is on Shift+Delete.",
    "Normal keeps classic tracks. Fast Cut closes gaps on the main track by itself and keeps clips above and below attached to their clip. You can switch any sequence later in the timeline header.",
    "Default length of transitions placed with Command-D, Shift-Command-D and Shift-D. Existing transitions do not change.",
    "A 3 ms fade at the start and end of every audio clip, so hard cuts never pop. Playback and export.",
    "Music-role tracks follow Dialogue-role tracks while mixing (playback and export). Off by default. A clip that also has baked Auto Duck keys ducks twice.",
    "Lookahead starts the duck early, Attack and Recovery are the ramps down and back up, Hold keeps the duck after speech, Minimum pause is the shortest gap that lets the music come back. Classic is the original 300 ms fade each way.",
    "Where the Normalize Loudness row of Audio Gain (G) starts. Match Loudness keeps its own targets per role: Dialogue -14, Music and SFX 6 dB lower.",
    "What happens to files dropped from outside the project folder. Files already inside the project folder are always used where they are. A project can override this in File > Media Management.",
    "New files and folders appear in the bin, linked in place; removed files go offline.",
    "You choose per import: copy the files into the Media folder next to your project, or use them directly from the card.",
    "Sounds, music, video, images and LUTs are copied to Files/Library in the background, once per unique file.",
    "Folders of sounds, music, graphics, video and LUTs. They appear in the Library panel of every project. Using an item in a sequence copies it into the project.",
    "Proxies are stored in the Proxies folder inside it. A new folder applies at the next launch; proxies already made stay in the old folder (Delete Cache there is safe, they are rebuilt when needed).",
    "Most disk the proxy cache may use. The least recently used proxies go first, never one a monitor is playing.",
    "Clearing the cache is safe: files are rebuilt when needed.",
    "Only programs on this Mac can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md.",
    "Only programs on this computer can connect (127.0.0.1), with a key that changes every launch. Each agent edit is one undo step. Details: docs/EDIT-API.md.",
    "Memory for decoded frames of both monitors (this computer: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your computer and shrinks when memory runs low.",
    "Interface Language",
    "System",
    "The language of menus, panels and settings. Applies the next time Sequence Studio starts.",
    "Restart Sequence Studio to apply the language.",
    "Restart",
];
/// Dialog titles, notes and buttons, dialog form rows and inspector labels. Dialogs, dialog forms, labels and inspector
/// section headers translate their text centrally, so a key here shows in German wherever it is used.
const DIALOG_KEYS: &[&str] = &[
    "Template",
    "Frame size",
    "Custom size",
    "Frame rate",
    "Outside files",
    "Location",
    "Choose…",
    "Normal",
    "Default from Preferences › Editing",
    "New project",
    "Acknowledgments",
    "Add",
    "Animation",
    "Anonymize",
    "Anonymize: Check These Frames",
    "Appearance",
    "Apply",
    "Audio Gain",
    "Author",
    "Back",
    "Bake Again",
    "Bake to Volume Keys",
    "Caption Gap",
    "Change Sequence Settings",
    "Channels",
    "Characters",
    "Check Cuts",
    "Check for Updates",
    "Clip Marker",
    "Clips",
    "Close",
    "Comment",
    "Cover",
    "Create",
    "Create Angles Clip",
    "Create Captions",
    "Custom Pixel Aspect",
    "Delete Marker",
    "Delete the selected clips?",
    "Discard",
    "Display",
    "Download",
    "Duration",
    "Ease",
    "Export FCPXML",
    "Export OpenTimelineIO",
    "Export as Pack",
    "Fill Reel",
    "Find",
    "Folders",
    "Format",
    "Frame Rate",
    "Frame Size",
    "Frames",
    "Frequency",
    "Go to First",
    "Insert at Playhead",
    "Keep Both",
    "Keep Each Side",
    "Keep Existing Settings",
    "Keyboard Shortcuts",
    "Later",
    "Level",
    "Lines",
    "Live Ducking for This Project",
    "Looks",
    "Mark for Review",
    "Marker",
    "Media is offline",
    "Min. Duration",
    "Min. Length",
    "Music Ducks Twice",
    "Name",
    "Name this video",
    "New Color Matte",
    "New Sequence from Template",
    "OK",
    "Pan",
    "Pattern",
    "Pixel Shape",
    "Position",
    "Preset",
    "Preview",
    "Project Notes",
    "Punch In Cuts",
    "Quality",
    "Ratio",
    "Recover",
    "Reject All",
    "Reconnect…",
    "Reconnect",
    "Remove",
    "Remove Checked",
    "Remove Keys",
    "Remove Silences",
    "Rename",
    "Rename Clip",
    "Rename Template",
    "Rename Track",
    "Rename Workspace",
    "Replace",
    "Replace Duck Keys?",
    "Replace the transcript?",
    "Reset",
    "Review Silences",
    "Safe Zone",
    "Sample Rate",
    "Save Curve",
    "Save Motion",
    "Save Sequence as Template",
    "Save Transition as Preset",
    "Save as New Workspace",
    "Save as Set",
    "Scope",
    "Selected Clips",
    "Sequence Volume",
    "Set Transition Duration",
    "Set for Project",
    "Skip Existing",
    "Speed",
    "Starts at",
    "Style",
    "Style Kit",
    "Switch",
    "Sync by",
    "Target",
    "Text",
    "That shortcut is not available",
    "Timecode",
    "Tone Settings",
    "Track Volume and Pan",
    "Transcribe Again",
    "Version",
    "Video",
    "Voice",
    "Voiceover from Text",
    "Volume",
    "With",
    "Working",
    "Your changes since the last save will be lost.",
    "Normal keeps classic tracks. Fast Cut closes gaps on the main track by itself.",
    "Starts at and Display change only what is shown. Quality is used while this sequence is open.",
    "Choose what to paste onto the selected clips. Everything else stays as it is.",
    "Click a step to go back to it. Dimmed steps were undone.",
    "Findings are marked on the timeline. Undo removes them.",
    "Name for the new easing preset.",
    "Select the clips and sequences that match.",
    "The preset inside the file is damaged.",
    "It is not a Sequence Studio preset.",
    "It was made by a newer version of Sequence Studio.",
    "The property keeps the value it has at the playhead.",
    "Transcribing again replaces the current transcript, including your edits. Media is not changed.",
    "Uncheck the pauses you want to keep. Checked ones are cut and the gaps closed.",
    "Width divided by height of one pixel. 1 is square, 2 is a 2x anamorphic lens.",
    "Captions are made from the transcript of the whole sequence.",
    "The voice is made on this computer and added as an audio clip at the playhead.",
    "This clip does not match the sequence settings.",
    "Saves the Edit and the Color layout together under one name.",
    "The Editing layout is shown afterwards.",
    "Adjust",
    "Analyze",
    "Anchor",
    "Angle",
    "Attack",
    "Automatic",
    "Background",
    "Blend",
    "Blur",
    "Both sides",
    "Bring Forward",
    "Bring to Front",
    "Compressor On",
    "Compressor",
    "Copy Grade",
    "Corners",
    "Correction",
    "Curve",
    "Default",
    "Denoise",
    "Distance",
    "Draw",
    "Edges",
    "Edit Text",
    "Edit in Text",
    "Favorite",
    "Fill",
    "Fit",
    "Font",
    "Height",
    "Hold",
    "In",
    "Out",
    "Incoming only",
    "Outgoing only",
    "Invert",
    "Inverted",
    "Kind",
    "Length",
    "Look",
    "Mark All",
    "Match",
    "Match case",
    "Middle",
    "Mix",
    "Mode",
    "Move Left",
    "Move Right",
    "New Caption Track",
    "New Graphics Clip",
    "Next Keyframe",
    "Previous Keyframe",
    "No clip selected",
    "No keyframes",
    "No layers yet",
    "No sequence open",
    "No transition selected",
    "Noise Gate",
    "None",
    "Not transcribed yet.",
    "Opacity",
    "Outline",
    "Padding",
    "Pick color",
    "Presets",
    "Radius",
    "Range",
    "Release",
    "Remove Effect",
    "Replace All",
    "Rotation",
    "Scale",
    "Send Backward",
    "Send to Back",
    "Shadow",
    "Shape",
    "Size",
    "Standard",
    "Update",
    "Warmth",
    "Width",
    "Role",
    "Sections",
    "Tidy Up",
    "Transcribe Sequence",
    "Translate Captions",
    "Word Highlight",
    "Merge Captions",
    "Add Caption at Playhead",
    "Split Caption at Playhead",
    "Reset Position",
    "Reset Section",
    "Reset Value at Playhead",
    "Delete Mask",
    "Color Graph",
    "Whole Clip",
    "Whole sequence",
    "Source LUT",
    "Look LUT",
    "Clear LUT",
    "Temporal Interpolation",
    "Spatial Interpolation",
    "Keyframe Easing",
    "Link Scale",
    "Paste Grade",
    "Show matte",
    "Output Gain (dB)",
    "Crossover (Hz)",
    "%@ Animation",
    "%@ Color",
    "%@ Font",
    "%@ Token",
    "%@ by",
    "%@ goes to %@; %@ did not get it.",
    "%@ moved from %@ to %@.",
    "%@ runs %@ in the %@ and %@ everywhere else.",
    "%@: %@ cannot be used as a shortcut here.",
    "%@: %@ is reserved by macOS or the app menu.",
    "%@: the key %@ in the file could not be read.",
    "+ Shape",
    "+ Text",
    "12 dB/oct",
    "24 dB/oct",
    "48 dB/oct",
    "Add Color Effect",
    "Add Effect…",
    "Add Layer Step",
    "Add Parallel Step",
    "Add Range Grade",
    "Add Serial Step",
    "Add Step Before",
    "Add a Step after the selected one",
    "Add step",
    "Align To",
    "All Edges",
    "All HF",
    "All Parameters",
    "Allow wider dynamics",
    "Alpha",
    "Amount",
    "Amount to Duotone",
    "Anchor X",
    "Anchor Y",
    "Animate",
    "Animate %@",
    "Animation from Text Clip",
    "Antialiasing (Best Quality)",
    "Applies to every untagged clip in the project that is set to Automatic.",
    "Apply to",
    "Apply to Selected Clip",
    "Auto Scale",
    "Auto Tone",
    "Background Reduction",
    "Balanced",
    "Band %@",
    "Band 1 Attack",
    "Band 1 Bypass",
    "Band 1 Frequency",
    "Band 1 Gain",
    "Band 1 On",
    "Band 1 Q",
    "Band 1 Ratio",
    "Band 1 Release",
    "Band 1 Solo",
    "Band 1 Threshold",
    "Band 2 Attack",
    "Band 2 Bypass",
    "Band 2 Frequency",
    "Band 2 Gain",
    "Band 2 On",
    "Band 2 Q",
    "Band 2 Ratio",
    "Band 2 Release",
    "Band 2 Solo",
    "Band 2 Threshold",
    "Band 3 Attack",
    "Band 3 Bypass",
    "Band 3 Frequency",
    "Band 3 Gain",
    "Band 3 On",
    "Band 3 Q",
    "Band 3 Ratio",
    "Band 3 Release",
    "Band 3 Solo",
    "Band 3 Threshold",
    "Band 4 Attack",
    "Band 4 Bypass",
    "Band 4 Frequency",
    "Band 4 Gain",
    "Band 4 On",
    "Band 4 Q",
    "Band 4 Ratio",
    "Band 4 Release",
    "Band 4 Solo",
    "Band 4 Threshold",
    "Band 5 Frequency",
    "Band 5 Gain",
    "Band 5 On",
    "Band 5 Q",
    "Band Height",
    "Basic",
    "Best",
    "Black & White",
    "Black level",
    "Blacks",
    "Bleed",
    "Blend Mode",
    "Blend With Original",
    "Blink",
    "Block Height",
    "Blue",
    "Both Sides",
    "Bottom",
    "Bottom Left",
    "Bottom Right",
    "Bounce",
    "Bounce In",
    "Bounce Out",
    "Brightness",
    "Brightness & Contrast",
    "Brights",
    "Bypass %@ Steps",
    "Band %@ On",
    "Caption Animation",
    "Caption Position",
    "Caption Track",
    "Center",
    "Center of Sphere",
    "Cents",
    "Channel",
    "Choose File…",
    "Chorus",
    "Chroma Bleed",
    "Chroma Split",
    "Click a neutral gray or white area in the Program monitor to set the white balance",
    "Clip Result Values",
    "Clockwise",
    "Close %@ Curve",
    "Coarse",
    "Collapse %@",
    "Color 1",
    "Color 2",
    "Color Key",
    "Color Strength",
    "Columns",
    "Composite",
    "Contrast",
    "Copy Grade",
    "Copy the grade of what is being graded",
    "Corner Radius",
    "Correct outside the range",
    "Could not import “%@”",
    "Counter-clockwise",
    "Create Captions…",
    "Creative",
    "Crop",
    "Crossover 1",
    "Crossover 2",
    "Crossover 3",
    "Curvature",
    "Curve channel",
    "Curves",
    "Custom",
    "Cuts picture",
    "Damping",
    "Darks",
    "Date Stamp",
    "Day",
    "De-Esser",
    "De-Hum",
    "De-Reverb",
    "Decay",
    "Deflicker",
    "Delay",
    "Delete %@ Steps",
    "Delete Mixer",
    "Delete Subject Mask",
    "Density",
    "Depth",
    "Dialogue Leveler",
    "Dialogue, Music or Effects: loads a voiced EQ, compressor and level for this track",
    "Difference",
    "Direction",
    "Directional Blur",
    "Disable %@",
    "Dot Size",
    "Drag a point: frequency and gain. Scroll or Option-drag: Q. Double-click: reset the band.",
    "Dragging one band moves all four by the same amount",
    "Drop Shadow",
    "Duotone",
    "EQ (3 band)",
    "Echoes",
    "Echoey Room",
    "Edge Feather",
    "Edit Curve",
    "Edit Curve…",
    "Edit Custom Setup",
    "Edit in Graphics",
    "Empty caption",
    "Enable %@",
    "Enable %@ on All Selected Clips",
    "End Color",
    "End Point",
    "Enhance Speech",
    "Expand %@",
    "Export SRT…",
    "Exposure",
    "Fade",
    "Fade Depth",
    "Fade Length",
    "Fast",
    "Fast Start",
    "Favorite LUT",
    "Feather",
    "Fill Alpha",
    "Fill Color",
    "Fill Mode",
    "Film Grain",
    "Find in transcript",
    "Fine",
    "Firm",
    "Firm In",
    "Firm Out",
    "Follow %@ Token",
    "Follows",
    "Frame Mode",
    "Frames Each Side",
    "From",
    "From Previous",
    "Gain",
    "Gate Weave",
    "Aged Film",
    "Dust",
    "Scratches",
    "Flicker",
    "Gentle",
    "Glitch Displace",
    "Glow",
    "Glow Color",
    "Glow Colors",
    "Grade Whole Clip",
    "Grade Whole Sequence",
    "Gradient",
    "Graph Editor",
    "Graphic EQ",
    "Green",
    "Halftone",
    "Harmonics",
    "Heavy",
    "Heavy In",
    "Heavy Out",
    "High",
    "High Cut",
    "High Frequency",
    "High Gain",
    "High Shelf Frequency",
    "High Shelf Gain",
    "High Shelf On",
    "High Shelf Q",
    "High-Pass Frequency",
    "High-Pass On",
    "Higher",
    "Highlight Color",
    "Highlight Tint Amount",
    "Highlight Tint Hue",
    "Highlight/Shadow Protect",
    "Highlights",
    "Highlights Amount",
    "Highlights Hue",
    "Highlights Luma",
    "Horizontal Decentering",
    "Horizontal Edges",
    "Horizontal Flip",
    "Hour",
    "How fast the gate closes",
    "How fast the gate opens",
    "How long the gate stays open after the sound drops below the threshold",
    "Hue Saturation Curves",
    "Hue Shift",
    "Ignore Alpha",
    "Import Color Decision…",
    "Import Subtitles…",
    "Import…",
    "In & Out",
    "Included",
    "Input Boost",
    "Input color",
    "Insert here",
    "Inside",
    "Intensity",
    "Interpret As",
    "Invert Alpha",
    "Item",
    "Its Steps become serial Steps in a row",
    "Joins As",
    "Kaleidoscope",
    "Corner Warp",
    "Keep Highlights",
    "Keep Original",
    "Keep Shadows",
    "Keep Spoken Words Lit",
    "Keep intro and outro",
    "Keep intro and outro when trimmed",
    "Keep spoken",
    "Keep this layer's edges at another layer's edges or at the frame.",
    "Key Hue",
    "Key Out",
    "LUT",
    "Layer Step",
    "Layout",
    "Left",
    "Lens Distortion",
    "Letter Spacing (pt)",
    "Lift Soft Dialogue",
    "Lift soft whispery sources",
    "Light",
    "Light In",
    "Light Leak",
    "Light Out",
    "Light Touch",
    "Lighten",
    "Limit to a color range",
    "Limiter",
    "Limiter Attack",
    "Limiter Margin",
    "Limiter Release",
    "Limiter Threshold",
    "Line Spacing",
    "Line Spacing (pt)",
    "Linear",
    "Link All Clips of This Source",
    "Link All Cuts",
    "Link Band Controls",
    "Link Grade to Selected Clips",
    "Link Width and Height",
    "Listen to Ess",
    "Listen to Hum",
    "Long Shadow",
    "Look Intensity",
    "Look Saturation",
    "Look Vibrance",
    "Look to Kit",
    "Loop",
    "Low",
    "Low Cut",
    "Low Frequency",
    "Low Gain",
    "Low Shelf Frequency",
    "Low Shelf Gain",
    "Low Shelf On",
    "Low Shelf Q",
    "Low-Pass Frequency",
    "Low-Pass On",
    "Lower",
    "Luma Key",
    "Luma Strength",
    "Mains",
    "Make Graphic",
    "Makes Layer Transparent",
    "Makeup Gain",
    "Map Black To",
    "Map White To",
    "Mask Only",
    "Matches",
    "Matte Contrast",
    "Matte Midpoint",
    "Maximum Amplitude",
    "Mid Frequency",
    "Mid Gain",
    "Mid Q",
    "Midpoint",
    "Midtones Amount",
    "Midtones Hue",
    "Midtones Luma",
    "Minute",
    "Mirror",
    "Mirror Edges",
    "Month",
    "More Color actions",
    "More Step actions",
    "More lift for low levels",
    "More viewer actions",
    "Mosaic",
    "Motion Analysis",
    "Motion Blur",
    "Motion Curve",
    "Motion Limit",
    "Motion Search",
    "Move",
    "Multiband Compressor",
    "Multiband Compressor On / Off",
    "Multiply",
    "Narrow",
    "Next match (Return)",
    "No Pro grade here",
    "No Pro grade yet",
    "No captions yet",
    "No keystones yet",
    "No settings",
    "No track",
    "Noise",
    "Noise Reduction",
    "Noise gate",
    "Noise reduction",
    "Noisy Location",
    "Notch",
    "Off",
    "Offset X",
    "Offset Y",
    "Opacity at Edge",
    "Open %@",
    "Open %@ Curve",
    "Operates on Color Only",
    "Optimize moderate levels",
    "Original Colors",
    "Out Duration (0 = same)",
    "Outline Color",
    "Outline Position",
    "Outline Width",
    "Output",
    "Output Gain",
    "Output Limiter (Brickwall)",
    "Output gain",
    "Output limiter: raises by margin minus threshold and holds the peaks at the margin",
    "Outside",
    "Overshoot",
    "Parallel Step",
    "Paste grade",
    "Paste the copied grade onto the selected clips",
    "Peak",
    "Peak at",
    "Period",
    "Phase",
    "Pick an item of this graphic to edit its Motion, Opacity and effects with keyframes",
    "Pick color from screen",
    "Picture and matte",
    "Picture of",
    "Pinning",
    "Pitch Shift",
    "Pop",
    "Position X",
    "Position Y",
    "Posterize",
    "Posterize Time",
    "Preserve Formants",
    "Preset name",
    "Presets…",
    "Previous match (Shift+Return)",
    "Project Input",
    "Property",
    "RGB Curves",
    "RGB Split",
    "Radial",
    "Radial Blur",
    "Random Strobe Probability",
    "Rate",
    "Reaction",
    "Recent",
    "Red",
    "Reduce Loud Dialogue",
    "Reduction",
    "Reduction dB",
    "Reflection Center",
    "Remove all %@ keyframes?",
    "Remove window",
    "Rename…",
    "Repeat Edge Pixels",
    "Replace With",
    "Reset %@",
    "Reset %@ to Your Default",
    "Reset Default to Factory",
    "Reset Step",
    "Reset Tone",
    "Reset every section of this effect",
    "Reset this grade",
    "Reset to Automatic",
    "Reset to Kit Position",
    "Reset to Track Look",
    "Reverb",
    "Right",
    "Room Size",
    "Rotation Strength",
    "Round",
    "Round In",
    "Round Out",
    "Rounded Corners",
    "Roundness",
    "Rows",
    "Saturation",
    "Save Current as Look",
    "Save Current as Look…",
    "Save Effects as Preset…",
    "Save Motion from Selected Clip…",
    "Save as New",
    "Save as New Look…",
    "Save as Preset",
    "Save as Preset…",
    "Save as Template…",
    "Sawtooth",
    "Scale Height",
    "Scale at Edge",
    "Scanlines",
    "Screen",
    "Second Line",
    "Seed",
    "Segments",
    "Semitones",
    "Send Simple Values to Pro",
    "Send Simple grade into Pro (copy)",
    "Sensitivity",
    "Serial Step",
    "Serial Step at the End",
    "Serial, in front of this Step",
    "Set Range to In/Out",
    "Set Reference",
    "Set a marker at every match, named after the search text",
    "Settle",
    "Shadow Color",
    "Shadow Only",
    "Shadow Tint Amount",
    "Shadow Tint Hue",
    "Shadows",
    "Shadows Amount",
    "Shadows Hue",
    "Shadows Luma",
    "Shake",
    "Sharp",
    "Sharp Colors",
    "Sharp In",
    "Sharp Out",
    "Sharpen",
    "Unsharp Mask",
    "Shift",
    "Show the spectrum going into the compressor instead of coming out",
    "Shrink / Grow",
    "Shutter Angle",
    "Simple: the guided controls. Pro: the Color Graph of Steps. The other grade keeps its values.",
    "Sine",
    "Size, fill, stroke and corner radius are rows of the Shape effect below, all keyframable.",
    "Slide Direction",
    "Slope",
    "Slow",
    "Ease In 100%",
    "Ease Out 100%",
    "Smoothness",
    "Soft",
    "Soft In",
    "Soft Out",
    "Soften",
    "Softness",
    "Solo / On",
    "Solo Band %@",
    "Source LUT Intensity",
    "Spacing",
    "Spatial Color",
    "Spatial Luma",
    "Spatial Size",
    "Spectrum at Input",
    "Spherize",
    "Spill",
    "Spill Range",
    "Spin",
    "Spread",
    "Spring",
    "Spring In",
    "Spring In Out",
    "Spring Out",
    "Square",
    "Squash",
    "Stagger",
    "Start Color",
    "Start Order",
    "Start Point",
    "Start empty",
    "Start from Simple grade",
    "Steady",
    "Step on",
    "Stereo Width",
    "Stinger Clip",
    "Stinger Cut Point",
    "Stop Animating %@",
    "Strength",
    "Strobe",
    "Strobe Color",
    "Strobe Duration",
    "Strobe Light",
    "Strobe Operator",
    "Strobe Period",
    "Strong",
    "Strong In",
    "Strong Out",
    "Style name",
    "Temperature",
    "Text %@",
    "Text Box Position",
    "Text Direction",
    "The Simple rules: the camera LUT or the built-in conversion",
    "The first and last moments keep their length when you trim or stretch the clip.",
    "The first and last moments of the title keep their length when you trim or stretch the clip.",
    "The other decisions were not applied.",
    "Thickness",
    "This Step is off. Its values are kept.",
    "Threshold",
    "Tidy for Short Video",
    "Tidy up",
    "Tile",
    "Tint",
    "Tint Balance",
    "To",
    "Tolerance",
    "Tone",
    "Top",
    "Top Left",
    "Top Right",
    "Toward Next",
    "Track",
    "Track Mask Backward",
    "Track Mask Forward",
    "Tracking Noise",
    "Trails",
    "Transcribes the speech of the whole sequence",
    "Transform",
    "Transparency",
    "Triangle",
    "Turn %@ Off",
    "Turn %@ On",
    "Turn On",
    "Turn On %@ Steps",
    "Twirl",
    "Twirl Center",
    "Twirl Radius",
    "Type",
    "Uniform Scale",
    "Unit Length",
    "Unlink Grade",
    "Update Look",
    "Update “%@”",
    "Use Color Noise",
    "Use Keyframe Easing",
    "Use Pro Grade (Color Graph)",
    "Use Simple Grade",
    "Use as Default for %@",
    "Vertical Decentering",
    "Vertical Edges",
    "Vertical Flip",
    "Vibrance",
    "Video Denoise",
    "Vignette",
    "Vignette Amount",
    "Vignette Feather",
    "Vignette Midpoint",
    "Vignette Roundness",
    "Warmth mix: 0 % is the dry sound, 100 % the fully warmed sound",
    "Wave Height",
    "Wave Speed",
    "Wave Type",
    "Wave Warp",
    "Wave Width",
    "Weight",
    "Wheels & Match",
    "Wheels Saturation",
    "White balance picker",
    "Whites",
    "Wide",
    "Wiggle",
    "Wind-Up",
    "Wind-Up Overshoot",
    "Window shape",
    "Year",
    "Your default",
];

#[cfg(test)]
mod tests {
    use super::*;

    fn l10n() -> Catalogs {
        Catalogs::bundled("en")
    }

    #[test]
    fn override_wins_over_system() {
        assert_eq!(resolve_language(Some("de"), &["en-US"]), "de");
        assert_eq!(resolve_language(Some("en"), &["de-DE"]), "en");
    }

    #[test]
    fn system_language_is_followed_when_supported() {
        assert_eq!(resolve_language(None, &["de-DE", "en-US"]), "de");
        assert_eq!(resolve_language(Some("system"), &["de-AT"]), "de");
        // First supported language in the preference list wins; unsupported ones are skipped.
        assert_eq!(resolve_language(None, &["fr-FR", "de-DE"]), "de");
    }

    #[test]
    fn unsupported_falls_back_to_english() {
        assert_eq!(resolve_language(None, &["fr-FR"]), "en");
        assert_eq!(resolve_language(Some("xx"), &["fr"]), "en");
        assert_eq!(resolve_language(None, &[]), "en");
    }

    #[test]
    fn environment_never_forces_a_language_inside_the_app() {
        // A shell or launcher that exports SQ_LANGUAGE=de must not turn the shipped app German over the user's choice.
        assert_eq!(effective_override(Some("de"), Some("en"), true), Some("en"));
        assert_eq!(effective_override(Some("de"), None, true), None);
        // Outside an app bundle (tests, scripts) the variable wins; empty means unset.
        assert_eq!(effective_override(Some("en"), Some("de"), false), Some("en"));
        assert_eq!(effective_override(Some(""), Some("de"), false), Some("de"));
    }

    #[test]
    fn english_choice_beats_a_german_system() {
        let o = effective_override(None, Some("en"), true);
        assert_eq!(resolve_language(o, &["de-DE", "en-US"]), "en");
        // "System" (stored as no value) follows the system.
        let s = effective_override(None, None, true);
        assert_eq!(resolve_language(s, &["de-DE", "en-US"]), "de");
        // English only for now: whatever the system says, the app's language is English.
        assert_eq!(selected_language(None, None, true, &["de-DE"]), "en");
        assert_eq!(selected_language(None, Some("de"), true, &["de-DE"]), "en");
    }

    #[test]
    fn lookup_translates_and_falls_back() {
        let t = l10n();
        assert_eq!(t.string("File", Some("de")), "Datei");
        assert_eq!(t.string("File", Some("en")), "File");
        assert_eq!(t.string("No such key anywhere", Some("de")), "No such key anywhere");
    }

    #[test]
    fn format_lookup_substitutes() {
        assert_eq!(l10n().format("Show %@", &["Timeline"], Some("en")), "Show Timeline");
    }

    #[test]
    fn german_catalog_has_no_empty_values_or_stray_keys() {
        let t = l10n();
        let table = t.table("de");
        assert!(!table.is_empty());
        for (key, value) in table {
            assert!(!value.is_empty(), "empty German value for {key}");
            // Format specifiers must match the English source.
            assert_eq!(key.split("%@").count(), value.split("%@").count(), "specifier mismatch: {key}");
        }
    }

    #[test]
    fn filled_in_engine_messages_translate_by_pattern() {
        let t = l10n();
        assert_eq!(t.localized("“Beach.mov” was not found.", Some("de")), "„Beach.mov“ wurde nicht gefunden.");
        assert_eq!(t.localized("This item has no sound.", Some("de")), "Dieses Medium hat keinen Ton.");
        // Nested: the captured reason is translated too.
        assert_eq!(
            t.localized("The file could not be written: The file has no audio track.", Some("de")),
            "Die Datei konnte nicht geschrieben werden: Die Datei hat keine Audiospur."
        );
        assert_eq!(t.localized("Unknown engine text", Some("de")), "Unknown engine text");
        assert_eq!(t.localized("This item has no sound.", Some("en")), "This item has no sound.");
    }

    #[test]
    fn interpolated_alerts_and_status_lines_translate() {
        let t = l10n();
        assert_eq!(t.format("Delete “%@”?", &["Mix"], Some("de")), "„Mix“ löschen?");
        assert_eq!(t.format("%@ needs %@.", &["Blur", "einen Videoclip"], Some("de")), "Blur braucht einen Videoclip.");
        assert_eq!(t.format("Remove In and Out: %@", &["I / O"], Some("de")), "Ein und Aus entfernen: I / O");
    }

    #[test]
    fn import_and_voice_errors_translate_through_localized() {
        let t = l10n();
        // Descriptions of the SQPremiereImport / SQAnalysis errors (those packages cannot be imported here).
        assert_eq!(
            t.localized("The file could not be read: no sequence", Some("de")),
            "Die Datei konnte nicht gelesen werden: keine Sequenz"
        );
        assert_eq!(
            t.localized("Not a supported interchange file: not an FCPXML file", Some("de")),
            "Keine unterstützte Austauschdatei: keine FCPXML-Datei"
        );
        assert_eq!(
            t.localized("Not a supported interchange file: .abc", Some("de")),
            "Keine unterstützte Austauschdatei: .abc"
        );
        assert_eq!(
            t.localized("Not a supported interchange file: unknown format", Some("de")),
            "Keine unterstützte Austauschdatei: unbekanntes Format"
        );
        assert_eq!(
            t.localized("The file could not be read: no OpenTimelineIO timeline", Some("de")),
            "Die Datei konnte nicht gelesen werden: keine OpenTimelineIO-Timeline"
        );
        assert_eq!(
            t.localized("the file gave no frame at 1.250 s", Some("de")),
            "die Datei lieferte bei 1.250 s kein Bild"
        );
    }

    #[test]
    fn the_process_front_is_english_by_default() {
        assert_eq!(SQL10n::current_language(), "en");
        assert_eq!(SQL10n::string("File"), "File");
        assert_eq!(SQL10n::string_in("File", "de"), "Datei");
        assert_eq!(SQL10n::format("Show %@", &["Timeline"]), "Show Timeline");
        assert_eq!(SQL10n::format_in("Delete “%@”?", &["Mix"], "de"), "„Mix“ löschen?");
        assert_eq!(SQL10n::localized_in("This item has no sound.", "de"), "Dieses Medium hat keinen Ton.");
        assert!(!SQL10n::install("de"));
    }

    #[test]
    fn the_new_project_dialog_has_no_english_label_next_to_german_buttons() {
        for k in [
            "Template",
            "Frame size",
            "Custom size",
            "Frame rate",
            "Outside files",
            "Location",
            "Choose…",
            "New project",
        ] {
            assert_ne!(SQL10n::string_in(k, "de"), k, "{k} stays English in German");
        }
    }

    #[test]
    fn german_catalog_covers_the_first_slice() {
        let required = SQL10n::required_keys();
        let missing = SQL10n::missing_keys("de", &required);
        assert!(missing.is_empty(), "Missing German strings: {missing:?}");
    }

    #[test]
    fn required_keys_cover_menus_and_panels() {
        let keys: HashSet<String> = SQL10n::required_keys().into_iter().collect();
        for spec in EditorMenus::all() {
            assert!(keys.contains(&spec.title));
        }
        for p in PanelID::ALL {
            assert!(keys.contains(EditorCommand::panel_title(p)));
        }
        for c in EditorMenus::all().iter().flat_map(|m| m.commands()) {
            assert!(keys.contains(&c.title()), "menu command not required: {}", c.title());
        }
        for k in SQL10n::SETTINGS_KEYS {
            assert!(keys.contains(*k));
        }
    }

    #[test]
    fn strings_parser_reads_comments_escapes_and_pairs() {
        let t = parse_strings("/* c */\n// line \"x\"\n\"a\\\"b\" = \"c\\\\d\";\n\"k\" = \"v\\nw\";\n");
        assert_eq!(t.get("a\"b").map(String::as_str), Some("c\\d"));
        assert_eq!(t.get("k").map(String::as_str), Some("v\nw"));
        assert_eq!(t.len(), 2);
    }

    #[test]
    fn format_string_knows_percent_and_integer_specifiers() {
        assert_eq!(format_string("%@ %% of %lld, %d", &["a", "5", "7"]), "a % of 5, 7");
    }

    #[test]
    fn missing_keys_lists_untranslated_keys() {
        let required = vec!["File".to_string(), "No such key anywhere".to_string()];
        assert_eq!(l10n().missing_keys("de", &required), vec![&required[1]]);
    }

    /// The table keeps the last of two equal keys and hides the other: a duplicate is a translation nobody sees.
    #[test]
    fn the_german_strings_file_has_no_duplicate_keys() {
        let mut seen = std::collections::BTreeMap::new();
        let mut duplicates = Vec::new();
        for (n, line) in GERMAN_STRINGS.lines().enumerate() {
            let Some(rest) = line.strip_prefix('"') else { continue };
            let Some(end) = rest.find("\" = \"") else { continue };
            if let Some(first) = seen.insert(rest[..end].to_string(), n + 1) {
                duplicates.push(format!("{} (lines {first} and {})", &rest[..end], n + 1));
            }
        }
        assert!(duplicates.is_empty(), "duplicate keys: {duplicates:?}");
        assert!(seen.len() > 1000, "the scan reads the file ({} keys)", seen.len());
    }
}
