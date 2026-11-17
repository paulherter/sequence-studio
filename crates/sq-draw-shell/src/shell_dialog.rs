// Swift: ShellDialog.swift
//! `SQDialog` translated onto the canvas: title, message and the footer of buttons on the overlay card (radius 12, .5 px
//! edge) centered over the dimmed window. Button roles, order, Return/Esc and Ctrl-D/Ctrl-S are `SQDialogModel` and the
//! `SQModal.response` rule, unchanged; the layout numbers are `SQDialogMetrics` / `Theme.Sheet` / `Theme.Modal`.
//! A form dialog sets `form` (the `SQDialog.accessoryView` + `SQDialogForm` rows): it sits between the header and the
//! footer, takes Tab, clicks and typing; Return and Esc still answer the dialog.

use crate::menu_controller::MenuController;
use crate::menu_list_view::MenuListView;
use sq_core_model::LabelColor;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::{
    Canvas, Color, DrawTheme, InputEvent, InputKey, InputModifiers, TextAlign, TextFieldControl, TextMeasure, UiCx,
};
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::design_tokens::sq_tokens::radius;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogButton, SQDialogModel, SQDialogResponse, SQDialogRole};
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;
use std::collections::{BTreeMap, BTreeSet};

/// A popup list a form or content asks the dialog to show below one of its controls (Swift `openPopup`).
#[derive(Clone, Debug)]
pub struct PopupRequest {
    /// The rows.
    pub items: Vec<SQMenuItem>,
    /// The control the list drops from.
    pub below: CGRect,
}

/// The value of a form row (Swift `ShellForm.Value`).
#[derive(Clone, Debug, PartialEq)]
pub enum FormValue {
    /// A text field.
    Text(String),
    /// A chosen option, page or pressed button.
    Index(i64),
    /// A check box or toggle.
    Bool(bool),
    /// A number field or slider.
    Number(f64),
}

/// The form body of a dialog (Swift `ShellForm`): rows between the header and the footer.
/// The dialog drives it through this trait; a form that wants a popup list returns it from `take_popup`.
pub trait DialogForm {
    /// Moves the keyboard focus to the first text field; true when there is one.
    fn focus_first_text_field(&mut self) -> bool;
    /// The focused row.
    fn focused(&self) -> Option<usize>;
    /// The label column width this dialog wants (`ShellDialog::label_column`).
    fn set_fixed_label_column(&mut self, width: Option<f64>);
    /// The kit card form look (one grouped card of rows).
    fn set_kit_cards(&mut self, _on: bool) {}
    /// A sidebar form lays out its own top.
    fn has_sidebar(&self) -> bool;
    /// Whether the focus sits in the sidebar.
    fn sidebar_focused(&self) -> bool;
    /// The sidebar search field while the keyboard is in it, with its open editor (text, caret, selection). A page rebuilt
    /// for a new query hands it to the new form, so typing goes on: a fresh field opens with everything selected, and the next
    /// key replaced the whole query ("q", "x", "q" arrived as "q").
    fn take_search_editing(&mut self) -> Option<TextFieldControl> {
        None
    }
    /// The sidebar search field as laid out: its frame, whether the keyboard is in it, and its text; `None` without one.
    fn search_field(&self) -> Option<(CGRect, bool, String)> {
        None
    }
    /// Height of the whole form at `width`.
    fn height(&mut self, width: f64, m: &TextMeasure) -> f64;
    /// `extraGapBefore[0] ?? 0`: a first row drawn above the form top is negative.
    fn first_row_gap(&self) -> f64;
    /// How far the dialog scrolled the form (the sidebar stays put).
    fn set_sidebar_shift(&mut self, shift: f64);
    /// Extra height the sidebar column reaches below the form (a headerless dialog's footer: the kit's sidebar runs to the
    /// window's bottom and the footer sits under the content column only).
    fn set_sidebar_extra(&mut self, _h: f64) {}
    /// Height of the visible part.
    fn set_viewport_height(&mut self, h: f64);
    /// Lays the rows out from `origin`.
    fn layout(&mut self, origin: CGPoint, width: f64, m: &TextMeasure);
    /// Row frames in window points.
    fn row_frames(&self) -> &[CGRect];
    /// A picker list is open and takes the events.
    fn picker_open(&self) -> bool;
    /// A key while a picker is open.
    fn picker_key(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx);
    /// A press while a picker is open.
    fn picker_mouse_down(&mut self, p: CGPoint);
    /// A drag while a picker is open.
    fn picker_mouse_dragged(&mut self, p: CGPoint);
    /// A release while a picker is open.
    fn picker_mouse_up(&mut self);
    /// A key; true when the form took it.
    fn key(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx) -> bool;
    /// Ends text editing, keeping the typed value.
    fn commit_editing(&mut self);
    /// A press inside the viewport; true when a row took it.
    fn mouse_down(&mut self, p: CGPoint, m: &TextMeasure) -> bool;
    /// A drag.
    fn mouse_dragged(&mut self, p: CGPoint, m: &TextMeasure, cx: &mut UiCx);
    /// A release.
    fn mouse_up(&mut self, cx: &mut UiCx);
    /// The pointer moved (outside the viewport: (-1, -1)).
    fn mouse_moved(&mut self, p: CGPoint);
    /// The window rectangle popups may use.
    fn set_overlay_bounds(&mut self, window: CGRect);
    /// Draws the rows.
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx);
    /// Draws what sits above the dialog's buttons (open pickers).
    fn draw_overlay(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx);
    /// The values the user changed since the last call, in order (Swift `onChange`).
    fn take_changes(&mut self) -> Vec<(String, FormValue)>;
    /// Queues a change the footer raised (a button that keeps the dialog open): the flow reads it like any other.
    fn push_change(&mut self, _id: &str, _v: FormValue) {}
    /// The text under `id` (Swift `ShellForm.text`).
    fn text(&self, id: &str) -> Option<String>;
    /// The chosen option or pressed button under `id`.
    fn index(&self, id: &str) -> Option<i64>;
    /// The flag under `id`.
    fn bool(&self, id: &str) -> Option<bool>;
    /// The number under `id` (a text value is parsed).
    fn number(&self, id: &str) -> Option<f64>;
    /// The color of a color row.
    fn color(&self, id: &str) -> Option<sq_uikit::sqcolor_value::SQColorValue>;
    /// A popup list the form wants shown since the last call.
    fn take_popup(&mut self) -> Option<PopupRequest>;
    /// Sets a value from outside while the dialog is open (a file the flow chose). Default: nothing.
    fn set_value(&mut self, _id: &str, _v: FormValue) {}
    /// Replaces the text left of a buttons row's buttons (`ShellForm::set_detail`). Default: nothing.
    fn set_row_detail(&mut self, _id: &str, _detail: &str) {}
    /// R4e: the ids of the value rows (the Settings marks ask which of them have a changed value). Default: none.
    fn row_ids(&self) -> Vec<String> {
        Vec::new()
    }
    /// R4e: the rows with a changed value and the changed count per sidebar page. Default: nothing.
    fn set_marks(&mut self, _changed: std::collections::BTreeSet<String>, _counts: Vec<usize>) {}
    /// The text of the status line of row `id`.
    fn status_text(&self, _id: &str) -> Option<String> {
        None
    }
    /// Replaces the status line of row `id` (the Preferences Edit API line); false when the form has no such row.
    fn replace_status(&mut self, _id: &str, _status: crate::shell_form::Status) -> bool {
        false
    }
    /// Sets what the picture row shows (the Export preview): its size and whether the image slot holds the picture.
    /// Default: nothing.
    fn set_picture(&mut self, _width: i64, _height: i64, _ready: bool) {}
    /// Sets the scrub bar under the picture row. Default: nothing.
    fn set_preview_transport(&mut self, _t: crate::shell_form::PreviewTransport) {}
    /// The rows assistive tech reads and sets, top down. Default: none.
    fn a11y_fields(&self) -> Vec<FormField> {
        Vec::new()
    }
    /// Sets the row `id` like the user did (the change is queued for `take_changes`); false for an unknown row or a
    /// value of the wrong kind. Default: nothing.
    fn a11y_edit(&mut self, _id: &str, _v: FormValue) -> bool {
        false
    }
}

/// One form row as assistive tech sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct FormField {
    /// Value key.
    pub id: String,
    /// Row label.
    pub label: String,
    /// The current value.
    pub value: FormValue,
    /// The choices of a popup or segmented row, empty otherwise.
    pub options: Vec<String>,
}

/// The drawn part of a dialog under its form (`ShellDialog::content`). `handle` gets every event while the dialog shows
/// (presses only inside its frame); true = taken, the dialog's own keys and buttons do not see it.
pub trait ShellDialogContent {
    /// Height at `width`.
    fn height(&mut self, width: f64) -> f64;
    /// Height at `width` measured with the dialog's text measure (Swift contents kept a copy of the last measure; a Rust
    /// measure borrows the glyph atlas and cannot be stored). The default ignores the measure.
    fn height_measured(&mut self, width: f64, _m: &TextMeasure) -> f64 {
        self.height(width)
    }
    /// Places the content in `frame`.
    fn layout(&mut self, frame: CGRect, m: &TextMeasure);
    /// Draws the content.
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme);
    /// One event; true when taken.
    fn handle(&mut self, e: &InputEvent, scale: f32) -> bool;
    /// A popup list the content wants shown since the last call.
    fn take_popup(&mut self) -> Option<PopupRequest>;
    /// One event with the app's context (number fields scrub, type and copy through it); the default ignores the context.
    fn handle_cx(&mut self, e: &InputEvent, scale: f32, _cx: &mut UiCx) -> bool {
        self.handle(e, scale)
    }
    /// Draws with the app's context; the default ignores it.
    fn draw_cx(&mut self, c: &mut Canvas, t: &DrawTheme, _cx: &mut UiCx) {
        self.draw(c, t);
    }
    /// The content asks the dialog to answer with this button (a row action that also closes the card).
    fn take_close(&mut self) -> Option<SQDialogResponse> {
        None
    }
    /// The values the content changed since the last call (the flow of the dialog reads them like a form's changes).
    fn take_changes(&mut self) -> Vec<(String, FormValue)> {
        Vec::new()
    }
}

/// A state icon before the title (art.html `.dh .hi`: amber triangle on warnings, red on errors).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Tone {
    /// Amber triangle.
    Warning,
    /// Red circle with an exclamation mark.
    Error,
    /// A question or a note: the info icon in the accent color (`Icon-Farbe = Zustand`: nothing is wrong).
    Info,
}

/// The New Project footer text and preview (`NewProjectSheet` band).
#[derive(Clone, Debug, PartialEq)]
pub struct FooterSummary {
    /// Strong first line.
    pub line1: String,
    /// Caption line.
    pub line2: String,
    /// Width / height of the preview rectangle.
    pub aspect: f64,
}

mod kit_steps;
pub use kit_steps::{KeySeg, KitStep};

// `Theme.Modal` / `Theme.Sheet` / `Theme.Dialog` (OverlayTokens.swift and ThemeTokens.swift are AppKit).
pub(crate) mod m {
    pub(crate) const WIDTH_S: f64 = 440.0;
    pub(crate) const RADIUS: f64 = sq_uikit::design_tokens::sq_tokens::radius::CARD as f64;
    pub(crate) const SIDE_PAD: f64 = sq_uikit::design_tokens::sq_tokens::spacing::LG as f64;
    pub(crate) const HEADER_TOP: f64 = 20.0;
    pub(crate) const HEADER_BOTTOM: f64 = 12.0;
    pub(crate) const HEADER_GAP: f64 = 8.0;
    pub(crate) const TITLE_LINE: f64 = 13.0;
    pub(crate) const NOTE_LINE: f64 = 16.0;
    pub(crate) const BUTTON_HEIGHT: f64 = sq_uikit::design_tokens::sq_tokens::height::LARGE as f64;
    /// The sheet look of a dialog with a form or content: a header of at least 48 with its text centered, `SIDE_PAD` under the
    /// body, a 56 high `titlebar` band with the buttons centered.
    pub(crate) const BAND_HEADER_HEIGHT: f64 = 48.0;
    pub(crate) const BAND_FOOTER_HEIGHT: f64 = 56.0;
    pub(crate) const BAND_FOOTER_SUMMARY_HEIGHT: f64 = 70.0;
    /// The Settings sidebar column (`ShellForm::SIDEBAR_WIDTH`).
    pub(crate) const SIDEBAR_COLUMN: f64 = 212.0;
    /// The start sheet's header (title and note, kit `New Project`): 64 high.
    pub(crate) const START_HEADER_HEIGHT: f64 = 64.0;
    pub(crate) const BUTTON_PADDING: f64 = 14.0;
    /// The icon before a button's title and its gap to the text.
    pub(crate) const BUTTON_ICON: f64 = 14.0;
    pub(crate) const BUTTON_ICON_GAP: f64 = 6.0;
    /// art.html 09: Pip is 32 in the footer, smiling.
    pub(crate) const MASCOT_SIDE: f64 = 32.0;
    pub(crate) const BUTTON_GAP: f64 = sq_uikit::design_tokens::sq_tokens::spacing::SM as f64;
    pub(crate) const TITLE_FONT: f64 = sq_uikit::design_tokens::sq_tokens::type_size::TITLE as f64;
    pub(crate) const NOTE_FONT: f64 = sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64;
    pub(crate) const WRAP_SLACK: f64 = 5.0;
    pub(crate) const BUTTON_FONT: f64 = sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64;
    pub(crate) const SCRIM_ALPHA: f32 = 0.45;
    pub(crate) const SCRIM_ALPHA_LIGHT: f32 = 0.25;
    pub(crate) const SHADOW_BLUR: f64 = 64.0;
    pub(crate) const SHADOW_DY: f64 = 24.0;
    pub(crate) const SHADOW_ALPHA: f32 = 0.65;
    pub(crate) const SHADOW_ALPHA_LIGHT: f32 = 0.2;
    /// art.html `.db` padding: 14 above the first form row (a 22 pt field in its 26 pt row then sits 16 under the hairline).
    pub(crate) const FORM_TOP_PAD: f64 = 14.0;
    /// Header icon (art.html `.dh .hi`, 14 pt) and its gap to the title (`.dh` gap 10).
    pub(crate) const HEADER_ICON_SIZE: f64 = 14.0;
    pub(crate) const HEADER_ICON_GAP: f64 = 10.0;
    pub(crate) const HAIR_HEIGHT: f64 = 1.0;
    /// Space kept between a tall card and the window edge; the form scrolls inside the card instead (the Mac modal's
    /// scroll view around a long settings page).
    pub(crate) const WINDOW_MARGIN: f64 = 24.0;
    pub(crate) const SCROLL_BAR_WIDTH: f64 = 4.0;
}

/// The kit dialog card (`dialogs.html` `.d`): 420 wide, 10 radius, no bands. Alerts carry a 40 pt icon slot; a form sits 14
/// under the header; the footer is 16 above, 18 under its 24 pt buttons, right aligned 20 from the edge.
pub(crate) mod k {
    pub(crate) const WIDTH: f64 = 420.0;
    pub(crate) const RADIUS: f64 = 10.0;
    pub(crate) const PAD: f64 = 20.0;
    pub(crate) const ALERT_TOP: f64 = 20.0;
    pub(crate) const FORM_TOP: f64 = 18.0;
    pub(crate) const ICON: f64 = 40.0;
    pub(crate) const ICON_GAP: f64 = 14.0;
    pub(crate) const TITLE_LINE: f64 = 18.0;
    pub(crate) const NOTE_LINE: f64 = 17.0;
    pub(crate) const NOTE_GAP: f64 = 6.0;
    pub(crate) const NOTE_FONT: f64 = sq_uikit::design_tokens::sq_tokens::type_size::LIST as f64;
    pub(crate) const BODY_TOP: f64 = 14.0;
    pub(crate) const BODY_BOTTOM: f64 = 4.0;
    pub(crate) const FOOT_TOP: f64 = 16.0;
    pub(crate) const FOOT_BOTTOM: f64 = 18.0;
    pub(crate) const BUTTON_HEIGHT: f64 = sq_uikit::design_tokens::sq_tokens::height::NORMAL as f64;
    /// `.sbtn`: the secondary button.
    pub(crate) const SECONDARY_HEIGHT: f64 = 22.0;
    pub(crate) const SCRIM_ALPHA: f32 = 0.55;
    pub(crate) const SHADOW_BLUR: f64 = 48.0;
    pub(crate) const SHADOW_DY: f64 = 18.0;
    pub(crate) const SHADOW_ALPHA: f32 = 0.6;
}

/// The icon slot of a kit alert (`dialogs.html` `tone()`): the app icon, or a tinted tile with a state icon.
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) enum SlotIcon {
    App,
    Warn,
    Err,
    Ok,
    Info,
}

/// A footer button's list: the titles and the cell the picked position lands in.
pub type ButtonMenu = (Vec<String>, std::rc::Rc<std::cell::Cell<Option<usize>>>);

/// An in-window dialog (Swift `ShellDialog`).
pub struct ShellDialog {
    /// The title.
    pub message_text: String,
    /// The note under the title.
    pub informative_text: String,
    /// Buttons and their roles.
    pub model: SQDialogModel,
    /// Whether a response may close the dialog (a form that rejects its input).
    pub can_close: Option<Box<dyn Fn(SQDialogResponse) -> bool>>,
    /// Called once with the response that closed the dialog.
    pub completion: Option<Box<dyn FnOnce(SQDialogResponse)>>,
    /// A drawn part under the form (the card import browser): it gets its own frame, its events and its drawing.
    pub content: Option<Box<dyn ShellDialogContent>>,
    content_frame: CGRect,
    /// Form body (`SQDialog.accessoryView`), `None` for an alert.
    pub form: Option<Box<dyn DialogForm>>,
    /// Card width: `Theme.Modal.widthS` for alerts; form dialogs pick theirs (`widthM` 600 for the long forms).
    pub width: f64,
    /// A fixed card height (`SQDialog.cardHeight`, the L modal's 640): the card keeps it whatever the form's length, the
    /// form scrolls inside it or leaves room under it (Preferences keeps its size across pages). `None`: fits the content.
    pub card_height: Option<f64>,
    /// The content brings its own header (the Export sheet's title row): no title block, the content starts at the card's
    /// top and ends at the footer band.
    pub headerless: bool,
    /// Text at the left of the footer band (`ExportDialogView`'s output summary), read at every draw.
    pub footer_note: Option<Box<dyn Fn() -> String>>,
    /// A footer button that opens a list instead of answering (the Export sheet's "Other Formats\u{2026}"): the titles, and the
    /// cell the picked position lands in before the dialog answers with that button's response.
    pub button_menus: BTreeMap<usize, ButtonMenu>,
    menu_picks: std::rc::Rc<std::cell::RefCell<Vec<usize>>>,
    pending_popup: Option<PopupRequest>,
    /// A status line right aligned in the footer band, 8 pt left of the leftmost trailing button (Card Import's
    /// "N selected"), read at every draw.
    pub footer_status: Option<Box<dyn Fn() -> String>>,
    /// What Esc answers when the dialog has no Cancel button (Card Import closes with Esc only); `None` = the Cancel button's.
    pub escape_response: Option<SQDialogResponse>,
    /// Buttons that do not close the dialog: pressing one raises the form change `"button"` with its index.
    pub keep_open: Vec<usize>,
    /// The New Project footer: a 44 pt preview box with the aspect as a clip-colored rectangle, a strong first line and a
    /// caption line beside it; read at every draw, replaces `footer_note`.
    pub footer_summary: Option<Box<dyn Fn() -> FooterSummary>>,
    /// A close button at the right of the header (`SQButton(symbol: .close)`, tip "Close (Esc)"): answers like Esc.
    pub close_button: bool,
    /// Header type of the start-screen sheets (`NewProjectSheet`: title 15 semibold, note 12); `None` = the dialog's 13 / 12.
    pub heading_font_size: Option<f64>,
    close_frame: CGRect,
    /// Fixed button widths by index (`NewProjectSheet`: Create 104, Cancel 76); others fit their title.
    pub button_widths: BTreeMap<usize, f64>,
    /// A key hint drawn after a button's title (`"Create  ⏎"`), kept out of the localized title.
    pub button_hints: BTreeMap<usize, String>,
    /// An icon before a button's title (the Export sheet's primary: upload), white on the accent buttons.
    pub button_icons: BTreeMap<usize, SQIcon>,
    close_hovered: bool,
    close_pressed: bool,
    /// Whether button `i` takes clicks and Return (`SQButton.isEnabled`); `None`: all enabled.
    pub button_enabled: Option<Box<dyn Fn(usize) -> bool>>,
    /// An alert that the Mac shows as a sheet (band footer, 56 pt header: the Reconnect Media sheet) without a form or content.
    pub sheet_style: bool,
    /// Pip at the left of the footer band (the Mac `SQDialog.footerRow(left: [SQMascotPlace...makeView()])`): the host draws
    /// him over `mascot_frame` (26 pt, `SIDE_PAD` from the left, centered in the band); zero when off.
    pub footer_mascot: bool,
    mascot_frame: CGRect,
    /// Popup lists of the form's popup rows.
    pub menu: MenuController,
    card: CGRect,
    button_frames: BTreeMap<usize, CGRect>,
    /// A second, gray header word after the title (the Settings page name).
    pub header_subtitle: Option<String>,
    /// A state icon before the title.
    pub header_icon: Option<Tone>,
    /// Opt in to the kit card for a dialog with a form (`k`); alerts without a form or content always use it.
    pub kit_layout: bool,
    /// The kit welcome body: Pip beside the title, then these steps in one card (no form).
    pub kit_steps: Vec<KitStep>,
    steps_layout: kit_steps::StepsLayout,
    /// How far the welcome step list is scrolled when the window is too short for it.
    steps_scroll: f64,
    /// Buttons drawn as ghost (no fill at rest, art.html `.btn.ghost`), by index.
    pub ghost_buttons: BTreeSet<usize>,
    /// Kit footer with several answers: Cancel comes first of the right-hand group, then the answers, the main one last.
    pub cancel_first: bool,
    /// R4e: a quiet line in the footer after the leading buttons (Settings: "Changes apply right away.").
    pub footer_hint: Option<String>,
    /// Width of the hint as laid out (the leading button follows it).
    footer_hint_width: f64,
    /// This is the Save Changes question (a second close request must not replace it).
    pub asks_to_save: bool,
    auto_focused: bool,
    title_lines: Vec<String>,
    /// Height of the header band above its hairline (0 = no title).
    header_band: f64,
    /// Form sheets with a note: 48 pt title band, the note in the body below it (art.html `.dlg`).
    note_in_body: bool,
    note_lines: Vec<String>,
    hovered: Option<usize>,
    pressed: Option<usize>,
    /// Keyboard focus (Tab moves it): starts on Cancel in destructive dialogs (`initialFocusIndex`).
    focused: Option<usize>,
    finished: bool,
    /// The visible part of the form (window points).
    form_viewport: CGRect,
    form_scroll: f64,
    /// The grab point inside the scroller knob (points from its top) while it is dragged.
    scroll_grab: Option<f64>,
    form_height: f64,
    last_window: CGRect,
    text_top: f64,
}

impl ShellDialog {
    /// art.html `.frm` label columns by dialog title (each dialog has its own: 56 ... 104).
    fn label_column(title: &str) -> Option<f64> {
        Some(match title {
            "Rename Workspace" | "Save as New Workspace" => 56.0,
            "Marker"
            | "Clip Marker"
            | "Go to Timecode"
            | "New Color Matte"
            | "Track Volume and Pan"
            | "Sequence Volume"
            | "Punch In Cuts"
            | "Anonymize" => 64.0,
            "Tone Settings" | "Speed" => 72.0,
            "Change Format" | "Duplicate as Format" | "Create Captions" | "Remove Silences" | "New Sequence" => 96.0,
            "Create Angles Clip" | "Check Cuts" => 80.0,
            "Sequence Settings" => 104.0,
            _ => return None,
        })
    }

    /// A dialog with a title and a note.
    pub fn new(message: &str, informative: &str) -> ShellDialog {
        ShellDialog {
            message_text: message.to_string(),
            informative_text: informative.to_string(),
            model: SQDialogModel::default(),
            can_close: None,
            completion: None,
            content: None,
            content_frame: CGRect::default(),
            form: None,
            width: m::WIDTH_S,
            card_height: None,
            headerless: false,
            footer_note: None,
            button_menus: BTreeMap::new(),
            menu_picks: std::rc::Rc::default(),
            pending_popup: None,
            footer_status: None,
            escape_response: None,
            keep_open: Vec::new(),
            footer_summary: None,
            close_button: false,
            heading_font_size: None,
            close_frame: CGRect::default(),
            button_widths: BTreeMap::new(),
            button_hints: BTreeMap::new(),
            button_icons: BTreeMap::new(),
            close_hovered: false,
            close_pressed: false,
            button_enabled: None,
            sheet_style: false,
            footer_mascot: false,
            mascot_frame: CGRect::default(),
            menu: MenuController::new(),
            card: CGRect::default(),
            button_frames: BTreeMap::new(),
            header_subtitle: None,
            header_icon: None,
            kit_layout: false,
            kit_steps: Vec::new(),
            steps_layout: kit_steps::StepsLayout::default(),
            steps_scroll: 0.0,
            ghost_buttons: BTreeSet::new(),
            cancel_first: false,
            footer_hint: None,
            footer_hint_width: 0.0,
            asks_to_save: false,
            auto_focused: false,
            title_lines: Vec::new(),
            header_band: 0.0,
            note_in_body: false,
            note_lines: Vec::new(),
            hovered: None,
            pressed: None,
            focused: None,
            finished: false,
            form_viewport: CGRect::default(),
            form_scroll: 0.0,
            scroll_grab: None,
            form_height: 0.0,
            last_window: CGRect::default(),
            text_top: 0.0,
        }
    }

    /// The content's frame in window points.
    pub fn content_frame(&self) -> CGRect {
        self.content_frame
    }

    /// The close button's frame (zero when off).
    pub fn close_frame(&self) -> CGRect {
        self.close_frame
    }

    /// Pip's frame in the footer (zero when off).
    pub fn mascot_frame(&self) -> CGRect {
        self.mascot_frame
    }

    /// Sheet look (header band, footer band): every dialog with a form or a drawn content; alerts keep the plain card.
    pub fn is_sheet(&self) -> bool {
        self.form.is_some() || self.content.is_some() || self.sheet_style
    }

    /// The card.
    pub fn card(&self) -> CGRect {
        self.card
    }

    /// Whether the footer hint fits beside the buttons and is drawn.
    pub fn footer_hint_shown(&self) -> bool {
        self.footer_hint_width > 0.0
    }

    /// Button frames by index.
    pub fn button_frames(&self) -> &BTreeMap<usize, CGRect> {
        &self.button_frames
    }

    /// The wrapped note lines.
    pub fn note_lines(&self) -> &[String] {
        &self.note_lines
    }

    /// The button under the pointer.
    pub fn hovered(&self) -> Option<usize> {
        self.hovered
    }

    /// The button being pressed.
    pub fn pressed(&self) -> Option<usize> {
        self.pressed
    }

    /// The button with the keyboard focus.
    pub fn focused(&self) -> Option<usize> {
        self.focused
    }

    /// A response closed the dialog.
    pub fn finished(&self) -> bool {
        self.finished
    }

    /// The visible part of the form (window points).
    pub fn form_viewport(&self) -> CGRect {
        self.form_viewport
    }

    /// How far the form is scrolled.
    pub fn form_scroll(&self) -> f64 {
        self.form_scroll
    }

    /// The title's line height: `TITLE_LINE`, or 20 for a 15 pt heading (`NewProjectSheet` title frame).
    fn title_indent(&self) -> f64 {
        if self.header_icon.is_none() { 0.0 } else { m::HEADER_ICON_SIZE + m::HEADER_ICON_GAP }
    }

    fn title_line(&self) -> f64 {
        self.heading_font_size.map_or(m::TITLE_LINE, |s| (s + 5.0).round())
    }

    /// Adds a button; the response of a press is its index.
    pub fn add_button(&mut self, title: &str, role: SQDialogRole, leading: bool) {
        let mut b = SQDialogButton::new(title, role);
        b.leading = leading;
        self.model.buttons.push(b);
    }

    // MARK: Layout (`SQDialog.layout` + `cardContent` + `footerRow`, alert form: no band)

    /// Lays the card out centered in `window`.
    pub fn layout(&mut self, window: CGRect, tm: &TextMeasure) {
        if self.model.buttons.is_empty() {
            self.add_button("OK", SQDialogRole::Default, false);
        }
        if !self.auto_focused {
            self.auto_focused = true;
            if self.form.as_mut().is_some_and(|f| f.focus_first_text_field()) {
                self.focused = None;
            }
        }
        if self.focused.is_none() && self.form.as_ref().is_none_or(|f| f.focused().is_none()) {
            self.focused = self.model.initial_focus_index();
        }
        if self.kit_plain() {
            return self.layout_plain(window, tm);
        }
        let width = self.width_for_buttons(window, tm);
        let inner = width - 2.0 * m::SIDE_PAD;
        let title_size = self.heading_font_size.unwrap_or(m::TITLE_FONT);
        let title_line = self.title_line();
        self.title_lines = if self.message_text.is_empty() {
            Vec::new()
        } else {
            tm.lines(
                &SQL10n::string(&self.message_text),
                inner - if self.close_button { m::BUTTON_HEIGHT } else { 0.0 } - self.title_indent(),
                title_size,
            )
        };
        // The atlas kerns like the Mac (GPOS pairs), so a note wraps where the Mac's NSTextField wraps it.
        self.note_lines = if self.informative_text.is_empty() {
            Vec::new()
        } else {
            tm.lines(&SQL10n::string(&self.informative_text), inner, m::NOTE_FONT)
        };
        let sheet = self.is_sheet();
        if let Some(form) = self.form.as_mut() {
            form.set_fixed_label_column(Self::label_column(&self.message_text));
        }
        let mut text = m::HEADER_TOP + self.title_lines.len() as f64 * title_line;
        if !self.title_lines.is_empty() && !self.note_lines.is_empty() {
            text += m::HEADER_GAP;
        }
        text += self.note_lines.len() as f64 * m::NOTE_LINE + m::HEADER_BOTTOM;
        // The start-sheet header (`NewProjectSheet`): title at 15, note 21 below, in the 64 head, the form `SIDE_PAD` below it.
        if self.heading_font_size.is_some() && sheet {
            text = m::START_HEADER_HEIGHT + m::SIDE_PAD;
        }
        if self.headerless {
            self.title_lines = Vec::new();
            self.note_lines = Vec::new();
            text = 0.0;
        }
        // An alert has the sheet bands too (art.html `.dlg`): a 48 header with the title, the note in the body, a 56 footer.
        let alert = !sheet && !self.headerless;
        if alert {
            let body = if self.note_lines.is_empty() {
                0.0
            } else {
                m::SIDE_PAD + self.note_lines.len() as f64 * m::NOTE_LINE + m::SIDE_PAD
            };
            text = (if self.title_lines.is_empty() { 0.0 } else { m::BAND_HEADER_HEIGHT }) + body;
        }
        self.note_in_body = sheet
            && !self.headerless
            && self.heading_font_size.is_none()
            && !self.title_lines.is_empty()
            && !self.note_lines.is_empty();
        if self.note_in_body {
            text = m::BAND_HEADER_HEIGHT + m::SIDE_PAD + self.note_lines.len() as f64 * m::NOTE_LINE + m::HEADER_BOTTOM;
        }
        let mut h = if sheet && !self.headerless { text.max(m::BAND_HEADER_HEIGHT) } else { text };
        self.text_top = if self.heading_font_size.is_some() || alert || self.note_in_body {
            0.0
        } else {
            ((h - text) / 2.0).round()
        };
        self.header_band = if alert {
            if self.title_lines.is_empty() { 0.0 } else { m::BAND_HEADER_HEIGHT }
        } else if self.headerless || self.title_lines.is_empty() {
            0.0
        } else if self.heading_font_size.is_some() {
            m::START_HEADER_HEIGHT
        } else if self.note_in_body {
            m::BAND_HEADER_HEIGHT
        } else {
            h
        };
        // A form right under a plain 48 header (no note, no start-sheet heading) keeps `.db`'s 14 above its first row.
        if let Some(form) = &self.form
            && !form.has_sidebar()
            && self.heading_font_size.is_none()
            && !self.note_in_body
            && !self.headerless
            && !self.title_lines.is_empty()
        {
            h += m::FORM_TOP_PAD;
        }
        // The kit's first row sits 21 under the 64 head (the head plus `SIDE_PAD` leaves 8 more).
        let form_top = if sheet && self.heading_font_size.is_some() { h - 8.0 } else { h };
        self.last_window = window;
        self.form_height = 0.0;
        if let Some(form) = self.form.as_mut() {
            self.form_height = form.height(width, tm);
            h += self.form_height + if sheet { 0.0 } else { m::HEADER_BOTTOM };
        }
        let content_top = h;
        let mut content_height = self.content.as_mut().map_or(0.0, |c| c.height_measured(width, tm));
        let footer = if sheet {
            (if self.headerless { 0.0 } else { m::SIDE_PAD }) + self.band_height()
        } else {
            m::BAND_FOOTER_HEIGHT
        };
        if let Some(fixed) = self.card_height
            && self.content.is_some()
            && self.form.is_none()
        {
            // `SQDialog.cardHeight` with a drawn body: header and footer keep their height, the body takes the rest.
            let room =
                if window.height > 0.0 { fixed.min((window.height - 2.0 * m::WINDOW_MARGIN).max(0.0)) } else { fixed };
            content_height = (room - h - footer).max(120.0);
        }
        if self.content.is_some() {
            h += content_height;
        }
        h += footer;
        // A drawn body taller than the window less its margins gets a viewport (the body scrolls); the footer stays.
        if self.content.is_some() && self.form.is_none() && self.card_height.is_none() && window.height > 0.0 {
            let room = (window.height - 2.0 * m::WINDOW_MARGIN).max(0.0);
            if h > room {
                let cut = (h - room).min((content_height - 120.0).max(0.0));
                content_height -= cut;
                h -= cut;
            }
        }
        // A form taller than the window scrolls inside a card that keeps the window margin.
        let room = (window.height - 2.0 * m::WINDOW_MARGIN).max(0.0);
        let mut visible = self.form_height;
        if let Some(fixed) = self.card_height
            && self.form.is_some()
        {
            let target = if room > 0.0 { fixed.min(room) } else { fixed };
            visible = (self.form_height + (target - h)).max(self.form_height.min(80.0));
            h += visible - self.form_height;
        } else if self.form.is_some() && h > room && room > 0.0 {
            visible = (self.form_height - (h - room)).max(self.form_height.min(80.0));
            h -= self.form_height - visible;
        }
        self.form_scroll = self.form_scroll.max(0.0).min((self.form_height - visible).max(0.0));
        // The Mac sheet origin floors an odd half point.
        self.card = CGRect::new((window.mid_x() - width / 2.0).round(), (window.mid_y() - h / 2.0).floor(), width, h);
        // `NewProjectSheet`: the close button 12 from the right edge, centered in the 48 header.
        self.close_frame = if self.close_button && !self.headerless {
            CGRect::new(
                self.card.max_x() - 12.0 - m::BUTTON_HEIGHT,
                self.card.min_y()
                    + if self.heading_font_size.is_some() {
                        // The kit centers the X on the title line pair, 27 under the top edge.
                        (27.0 - m::BUTTON_HEIGHT / 2.0).round()
                    } else {
                        ((m::BAND_HEADER_HEIGHT - m::BUTTON_HEIGHT) / 2.0).round()
                    },
                m::BUTTON_HEIGHT,
                m::BUTTON_HEIGHT,
            )
        } else {
            CGRect::default()
        };
        // A first row drawn above the form top (`extraGapBefore[0] < 0`, the Mac accessory field's frame) is not clipped while unscrolled.
        let bleed = if self.form_scroll == 0.0 {
            self.form.as_ref().map_or(0.0, |f| (-f.first_row_gap()).max(0.0))
        } else {
            0.0
        };
        self.form_viewport =
            CGRect::new(self.card.min_x(), self.card.min_y() + form_top - bleed, width, visible + bleed);
        if let Some(form) = self.form.as_mut() {
            form.set_sidebar_shift(self.form_scroll);
            form.set_sidebar_extra(if self.headerless && form.has_sidebar() { m::BAND_FOOTER_HEIGHT } else { 0.0 });
            form.set_viewport_height(visible);
            form.layout(CGPoint::new(self.card.min_x(), self.card.min_y() + form_top - self.form_scroll), width, tm);
        }
        self.content_frame = CGRect::new(
            self.card.min_x(),
            self.card.min_y() + content_top - (self.form_height - visible),
            width,
            content_height,
        );
        if let Some(c) = self.content.as_mut() {
            c.layout(self.content_frame, tm);
        }
        self.menu.bounds = window;

        // Footer: leading buttons at the left edge, the rest right aligned, 8 apart; centered in the band of a sheet, at the
        // top of the alert footer otherwise.
        let band_h = self.band_height();
        let y = self.card.max_y() - band_h + ((band_h - m::BUTTON_HEIGHT) / 2.0).round();
        // A headerless sidebar dialog (Settings): the footer sits under the content column (kit: hint at the column's
        // padding, buttons 22 from the right edge).
        let (lead_pad, trail_pad) = self.footer_pads();
        let mut left = self.card.min_x() + lead_pad;
        self.mascot_frame = CGRect::default();
        if self.footer_mascot && sheet {
            self.mascot_frame = CGRect::new(
                left,
                y + ((m::BUTTON_HEIGHT - m::MASCOT_SIDE) / 2.0).round(),
                m::MASCOT_SIDE,
                m::MASCOT_SIDE,
            );
        }
        // Kit `.foot2`: the hint text first, then the leading button, the main button at the right edge.
        let order = self.model.display_order();
        let p = self.model.primary_index();
        let leading: Vec<usize> =
            order.iter().copied().filter(|&i| self.model.buttons[i].is_leading() && Some(i) != p).collect();
        let trailing: Vec<usize> = order.iter().copied().filter(|i| !leading.contains(i)).collect();
        self.button_frames = BTreeMap::new();
        let footer_w = self.card.width - lead_pad - trail_pad;
        let widths = self.fitted_button_widths(&order, footer_w.min(self.card.width - 2.0 * m::SIDE_PAD), tm);
        // The hint gets what the buttons leave (a ghost button reaches into the padding); a hint that does not fit whole is
        // left out, never cut, and the buttons never run into it or each other.
        let ghosts = leading.iter().filter(|i| self.ghost_buttons.contains(i)).count() as f64;
        let buttons_w = widths.values().sum::<f64>() + m::BUTTON_GAP * order.len().saturating_sub(1) as f64
            - ghosts * (m::BUTTON_PADDING - 1.0);
        let hint_w = self.footer_hint.as_ref().map_or(0.0, |h| tm.width(&SQL10n::string(h), 11.0, 0).ceil());
        self.footer_hint_width = if hint_w + 14.0 <= footer_w - buttons_w { hint_w } else { 0.0 };
        if self.footer_hint_width > 0.0 {
            left += self.footer_hint_width + 14.0;
        }
        for &i in &leading {
            let w = widths[&i];
            // art.html footer-left slot: a ghost button's label starts at the 17 pt inset (the box reaches into the padding).
            let ghost_shift = if self.ghost_buttons.contains(&i) { m::BUTTON_PADDING - 1.0 } else { 0.0 };
            self.button_frames.insert(i, CGRect::new(left - ghost_shift, y, w, m::BUTTON_HEIGHT));
            left += w + m::BUTTON_GAP - ghost_shift;
        }
        let mut right = self.card.max_x() - trail_pad;
        for &i in trailing.iter().rev() {
            let w = widths[&i];
            right -= w;
            self.button_frames.insert(i, CGRect::new(right, y, w, m::BUTTON_HEIGHT));
            right -= m::BUTTON_GAP;
        }
    }

    /// Footer padding (leading, trailing): a headerless sidebar dialog (Settings) starts under the content column.
    /// The footer band: 56 high, 70 with the summary (kit `New Project`: 13 above and below the 44 pt preview box).
    fn band_height(&self) -> f64 {
        if self.footer_summary.is_some() { m::BAND_FOOTER_SUMMARY_HEIGHT } else { m::BAND_FOOTER_HEIGHT }
    }

    fn footer_pads(&self) -> (f64, f64) {
        if self.headerless && self.form.as_ref().is_some_and(|f| f.has_sidebar()) {
            (m::SIDEBAR_COLUMN + m::SIDE_PAD, 22.0)
        } else {
            (m::SIDE_PAD, m::SIDE_PAD)
        }
    }

    /// The kit card: alerts, and forms that set `kit_layout` (`dialogs.html` `.d`).
    pub(crate) fn kit_plain(&self) -> bool {
        !self.headerless
            && self.heading_font_size.is_none()
            && !self.close_button
            && self.card_height.is_none()
            && (self.content.is_none() || self.kit_layout)
            && (self.kit_layout || !self.sheet_style)
    }

    /// `dialogs.html` `tone()`: the icon slot of an alert, from the given tone or the title.
    pub(crate) fn slot_icon(&self) -> SlotIcon {
        match self.header_icon {
            Some(Tone::Error) => return SlotIcon::Err,
            Some(Tone::Warning) => return SlotIcon::Warn,
            Some(Tone::Info) => return SlotIcon::Info,
            None => {}
        }
        let t = self.message_text.to_lowercase();
        let has = |words: &[&str]| words.iter().any(|w| t.contains(w));
        if has(&["fail", "could not", "cannot", "error", "missing", "not found"]) {
            SlotIcon::Err
        } else if has(&["finished", "done", "saved", "complete"]) {
            SlotIcon::Ok
        } else if t.ends_with('?') || has(&["stop", "replace", "discard", "delete", "space"]) {
            SlotIcon::Warn
        } else {
            SlotIcon::App
        }
    }

    fn layout_plain(&mut self, window: CGRect, tm: &TextMeasure) {
        let n = self.model.buttons.len();
        let row: f64 = (0..n).map(|i| self.button_width(i, tm)).sum::<f64>()
            + m::BUTTON_GAP * n.saturating_sub(1) as f64
            + 2.0 * k::PAD;
        let room = if window.width > 0.0 { window.width - 2.0 * m::WINDOW_MARGIN } else { f64::INFINITY };
        let width =
            (if self.width == m::WIDTH_S { k::WIDTH } else { self.width }).max(row.min(room)).min(room.max(0.0));
        let steps = !self.kit_steps.is_empty();
        let icon = self.form.is_none() && !steps && self.content.is_none();
        let text_x = if icon {
            k::ICON + k::ICON_GAP
        } else if steps {
            kit_steps::TEXT_X
        } else {
            0.0
        };
        let (title_font, title_line) =
            if steps { (kit_steps::TITLE_FONT, kit_steps::TITLE_LINE) } else { (m::TITLE_FONT, k::TITLE_LINE) };
        let tw = width - 2.0 * k::PAD - text_x;
        self.title_lines = if self.message_text.is_empty() {
            Vec::new()
        } else {
            tm.lines(&SQL10n::string(&self.message_text), tw, title_font)
        };
        self.note_lines = if self.informative_text.is_empty() {
            Vec::new()
        } else {
            tm.lines(&SQL10n::string(&self.informative_text), tw, k::NOTE_FONT)
        };
        // The kit has no subtitle: the clip or track a form works on is one more note line.
        if let Some(sub) = &self.header_subtitle {
            self.note_lines.extend(tm.lines(&SQL10n::string(sub), tw, k::NOTE_FONT));
        }
        if let Some(form) = self.form.as_mut() {
            form.set_fixed_label_column(Self::label_column(&self.message_text));
            form.set_kit_cards(true);
        }
        let mut text = self.title_lines.len() as f64 * title_line;
        if icon && !self.title_lines.is_empty() {
            text += 2.0;
        }
        if !self.note_lines.is_empty() {
            text += if self.title_lines.is_empty() { 0.0 } else { k::NOTE_GAP };
            text += self.note_lines.len() as f64 * k::NOTE_LINE;
        }
        self.text_top = if icon {
            k::ALERT_TOP
        } else if steps {
            kit_steps::HEAD_TOP
        } else {
            k::FORM_TOP
        };
        if steps {
            self.layout_steps(width, text, tm);
        }
        let head = if icon {
            text.max(k::ICON)
        } else if steps {
            self.steps_layout.head
        } else {
            text
        };
        self.header_band = 0.0;
        self.note_in_body = false;
        self.last_window = window;
        let has_content = self.content.is_some() && self.form.is_none();
        if has_content && self.title_lines.is_empty() {
            self.text_top = 0.0; // About: the body starts at the card top
        }
        let body_top = if steps {
            kit_steps::LIST_GAP
        } else if has_content && self.title_lines.is_empty() && self.note_lines.is_empty() {
            0.0
        } else {
            k::BODY_TOP
        };
        let form_top = self.text_top + head + body_top;
        self.form_height = 0.0;
        let mut h = self.text_top + head;
        if steps {
            h = form_top + self.steps_layout.list_h + k::BODY_BOTTOM;
        }
        let mut content_h = 0.0;
        if has_content && let Some(content) = self.content.as_mut() {
            content_h = content.height_measured(width, tm);
            h = form_top + content_h;
        }
        if let Some(form) = self.form.as_mut() {
            self.form_height = form.height(width, tm);
            h = form_top + self.form_height + k::BODY_BOTTOM;
        }
        h += k::FOOT_TOP + k::BUTTON_HEIGHT + k::FOOT_BOTTOM;
        let room_h = (window.height - 2.0 * m::WINDOW_MARGIN).max(0.0);
        // The welcome step list in a window too short for it scrolls inside its card; header and footer stay.
        if steps && h > room_h && room_h > 0.0 {
            let cut = (h - room_h).min((self.steps_layout.list_h - 80.0).max(0.0));
            self.steps_layout.view_h = self.steps_layout.list_h - cut;
            h -= cut;
        }
        self.steps_scroll =
            self.steps_scroll.clamp(0.0, (self.steps_layout.list_h - self.steps_layout.view_h).max(0.0));
        let mut visible = self.form_height;
        if self.form.is_some() && h > room_h && room_h > 0.0 {
            visible = (self.form_height - (h - room_h)).max(self.form_height.min(80.0));
            h -= self.form_height - visible;
        }
        // A drawn body taller than the window less its margins gets a viewport (the body scrolls); the footer stays.
        if has_content && self.form.is_none() && h > room_h && room_h > 0.0 {
            let cut = (h - room_h).min((content_h - 120.0).max(0.0));
            content_h -= cut;
            h -= cut;
        }
        self.form_scroll = self.form_scroll.max(0.0).min((self.form_height - visible).max(0.0));
        self.card = CGRect::new((window.mid_x() - width / 2.0).round(), (window.mid_y() - h / 2.0).floor(), width, h);
        self.close_frame = CGRect::default();
        self.mascot_frame = CGRect::default();
        self.content_frame = CGRect::default();
        if has_content {
            self.content_frame = CGRect::new(self.card.min_x(), self.card.min_y() + form_top, width, content_h);
            if let Some(content) = self.content.as_mut() {
                content.layout(self.content_frame, tm);
            }
        }
        let bleed = if self.form_scroll == 0.0 {
            self.form.as_ref().map_or(0.0, |f| (-f.first_row_gap()).max(0.0))
        } else {
            0.0
        };
        self.form_viewport =
            CGRect::new(self.card.min_x(), self.card.min_y() + form_top - bleed, width, visible + bleed);
        if let Some(form) = self.form.as_mut() {
            form.set_sidebar_shift(self.form_scroll);
            form.set_sidebar_extra(if self.headerless && form.has_sidebar() { m::BAND_FOOTER_HEIGHT } else { 0.0 });
            form.set_viewport_height(visible);
            form.layout(CGPoint::new(self.card.min_x(), self.card.min_y() + form_top - self.form_scroll), width, tm);
        }
        self.menu.bounds = window;
        let y = self.card.max_y() - k::FOOT_BOTTOM - k::BUTTON_HEIGHT;
        let order = self.footer_order();
        let p = self.model.primary_index();
        let leading: Vec<usize> =
            order.iter().copied().filter(|&i| self.model.buttons[i].is_leading() && Some(i) != p).collect();
        let trailing: Vec<usize> = order.iter().copied().filter(|i| !leading.contains(i)).collect();
        self.button_frames = BTreeMap::new();
        let widths = self.fitted_button_widths(&order, self.card.width - 2.0 * k::PAD, tm);
        let mut left = self.card.min_x() + k::PAD;
        for &i in &leading {
            self.button_frames.insert(i, self.kit_button_frame(i, left, y, widths[&i]));
            left += widths[&i] + m::BUTTON_GAP;
        }
        let mut right = self.card.max_x() - k::PAD;
        for &i in trailing.iter().rev() {
            right -= widths[&i];
            self.button_frames.insert(i, self.kit_button_frame(i, right, y, widths[&i]));
            right -= m::BUTTON_GAP;
        }
    }

    /// `display_order`, with Cancel moved to the front of the right-hand group when `cancel_first` is set.
    pub(crate) fn footer_order(&self) -> Vec<usize> {
        let mut order = self.model.display_order();
        if self.cancel_first
            && let Some(c) = order.iter().position(|&i| self.model.buttons[i].role == SQDialogRole::Cancel)
        {
            let at = order.iter().position(|&i| !self.model.buttons[i].is_leading()).unwrap_or(0);
            let cancel = order.remove(c);
            order.insert(at.min(order.len()), cancel);
        }
        order
    }

    /// Kit buttons: the primary and the red one are 24 high, the secondary (`.sbtn`) is 22, centered in the 24 pt row.
    fn kit_button_frame(&self, i: usize, x: f64, row_y: f64, w: f64) -> CGRect {
        if self.is_secondary_button(i) {
            CGRect::new(x, row_y + (k::BUTTON_HEIGHT - k::SECONDARY_HEIGHT) / 2.0, w, k::SECONDARY_HEIGHT)
        } else {
            CGRect::new(x, row_y, w, k::BUTTON_HEIGHT)
        }
    }

    /// True for the raised secondary button (not the primary, not red, not a quiet link).
    pub(crate) fn is_secondary_button(&self, i: usize) -> bool {
        let b = &self.model.buttons[i];
        let destructive = matches!(b.role, SQDialogRole::Destructive | SQDialogRole::DontSave);
        Some(i) != self.model.primary_index() && !destructive && !self.ghost_buttons.contains(&i)
    }

    fn draw_plain(&mut self, c: &mut Canvas, t: &DrawTheme, window: CGRect, cx: &mut UiCx) {
        let dark = t.palette.is_dark();
        c.fill(window, Color::new(0.0, 0.0, 0.0, if dark { k::SCRIM_ALPHA } else { m::SCRIM_ALPHA_LIGHT }));
        let card = self.card;
        c.shadow(
            card,
            k::RADIUS,
            k::SHADOW_BLUR,
            k::SHADOW_DY,
            Color::new(0.0, 0.0, 0.0, if dark { k::SHADOW_ALPHA } else { m::SHADOW_ALPHA_LIGHT }),
            true,
        );
        c.fill_rounded(card, k::RADIUS, t.panel());
        c.stroke_rounded(card.inset_by(0.25, 0.25), k::RADIUS, 0.5, MenuListView::overlay_edge(t));
        let steps = !self.kit_steps.is_empty();
        let icon = self.form.is_none() && !steps && self.content.is_none();
        let x0 = card.min_x() + k::PAD;
        let mut y = card.min_y() + self.text_top;
        let (title_font, title_line) =
            if steps { (kit_steps::TITLE_FONT, kit_steps::TITLE_LINE) } else { (m::TITLE_FONT, k::TITLE_LINE) };
        if steps {
            y += self.steps_layout.text_off;
        }
        let mut tx = if steps { x0 + kit_steps::TEXT_X } else { x0 };
        if icon {
            let slot = CGRect::new(x0, y, k::ICON, k::ICON);
            let tile = CGRect::new(slot.min_x() + 3.0, slot.min_y() + 3.0, 34.0, 34.0);
            let glyph = |c: &mut Canvas, i: SQIcon, col: Color| {
                c.fill_rounded(tile, 8.0, col.with_alpha(0.14));
                c.draw_icon(i, CGPoint::new(tile.mid_x() - 10.0, tile.mid_y() - 10.0), 20.0, col, None);
            };
            match self.slot_icon() {
                SlotIcon::App => crate::shell_app_icon::ShellAppIcon::draw(slot, c, false),
                SlotIcon::Warn => glyph(c, SQIcon::Warning, t.warning()),
                SlotIcon::Err => glyph(c, SQIcon::CloseCircle, t.err_text()),
                SlotIcon::Ok => glyph(c, SQIcon::CheckCircle, t.green()),
                SlotIcon::Info => glyph(c, SQIcon::Info, t.accent()),
            }
            tx += k::ICON + k::ICON_GAP;
            if !self.title_lines.is_empty() {
                y += 2.0;
            }
        }
        let w = card.max_x() - k::PAD - tx;
        let semibold = c.semibold();
        for l in &self.title_lines {
            c.draw_text_in(l, CGRect::new(tx, y, w, title_line), title_font, t.label(), TextAlign::Left, 0.0, semibold);
            y += title_line;
        }
        if !self.title_lines.is_empty() && !self.note_lines.is_empty() {
            y += k::NOTE_GAP;
        }
        for l in &self.note_lines {
            c.draw_text_in(
                l,
                CGRect::new(tx, y, w + m::WRAP_SLACK, k::NOTE_LINE),
                k::NOTE_FONT,
                t.label2(),
                TextAlign::Left,
                0.0,
                0,
            );
            y += k::NOTE_LINE;
        }
        if steps {
            self.draw_steps(c, t);
        }
        self.draw_form(c, t, window, cx);
        if let Some(content) = self.content.as_mut() {
            c.save_gstate();
            c.clip_to(self.content_frame);
            content.draw_cx(c, t, cx);
            c.restore_gstate();
        }
        self.draw_buttons(c, t);
        self.menu.draw(c, t);
        if let Some(form) = self.form.as_mut() {
            form.draw_overlay(c, t, cx);
        }
    }

    /// The scroller knob's frame while the form scrolls (tests and hosts that aim at it).
    pub fn scroll_knob_frame(&self) -> Option<CGRect> {
        self.scroll_knob().map(|(_, k)| k)
    }

    /// The scroller track and its knob (the form is taller than its viewport), in card points.
    fn scroll_knob(&self) -> Option<(CGRect, CGRect)> {
        if !self.form_scrolls() {
            return None;
        }
        let track = self.form_viewport.inset_by(0.0, 2.0);
        let knob_h = (track.height * self.form_viewport.height / self.form_height).max(24.0);
        let travel = (self.form_height - self.form_viewport.height).max(1.0);
        let ky = track.min_y() + (track.height - knob_h) * self.form_scroll / travel;
        let knob = CGRect::new(track.max_x() - m::SCROLL_BAR_WIDTH - 4.0, ky, m::SCROLL_BAR_WIDTH, knob_h);
        Some((track, knob))
    }

    /// The scroller: a press on the knob grabs it, a press in the gutter beside it pages toward the press, a drag moves
    /// the form with the knob. True when the event was the scroller's.
    fn scroller_event(&mut self, e: &InputEvent, p: CGPoint, tm: &TextMeasure) -> bool {
        match e {
            InputEvent::MouseDown { .. } => {
                let Some((track, knob)) = self.scroll_knob() else { return false };
                let gutter = CGRect::new(knob.min_x() - 6.0, track.min_y(), knob.width + 12.0, track.height);
                if !gutter.contains(p) {
                    return false;
                }
                if knob.min_y() <= p.y && p.y <= knob.max_y() {
                    self.scroll_grab = Some(p.y - knob.min_y());
                } else {
                    let page = self.form_viewport.height;
                    self.scroll_form(if p.y < knob.min_y() { -page } else { page }, tm);
                }
                true
            }
            InputEvent::MouseDragged { .. } => {
                let (Some(grab), Some((track, knob))) = (self.scroll_grab, self.scroll_knob()) else { return false };
                let room = (track.height - knob.height).max(1.0);
                let travel = (self.form_height - self.form_viewport.height).max(0.0);
                let want = ((p.y - grab - track.min_y()) / room).clamp(0.0, 1.0) * travel;
                self.scroll_form(want - self.form_scroll, tm);
                true
            }
            InputEvent::MouseUp { .. } => self.scroll_grab.take().is_some(),
            _ => false,
        }
    }

    /// True when the form is taller than its viewport.
    pub fn form_scrolls(&self) -> bool {
        self.form_height > self.form_viewport.height + 0.5
    }

    /// Scrolls the form by `dy` points (positive = further down) and lays it out again.
    pub fn scroll_form(&mut self, dy: f64, tm: &TextMeasure) {
        if !self.form_scrolls() {
            return;
        }
        self.form_scroll += dy;
        self.layout(self.last_window, tm);
    }

    /// Back to the top (a new Preferences page).
    pub fn reset_form_scroll(&mut self, tm: &TextMeasure) {
        if self.form_scroll == 0.0 {
            return;
        }
        self.form_scroll = 0.0;
        self.layout(self.last_window, tm);
    }

    /// Brings the focused row into the viewport (Tab through a long form).
    fn reveal_focused_row(&mut self, tm: &TextMeasure) {
        if !self.form_scrolls() {
            return;
        }
        let Some(form) = &self.form else { return };
        let Some(r) = form.focused().and_then(|f| form.row_frames().get(f).copied()) else { return };
        if r.min_y() < self.form_viewport.min_y() {
            self.scroll_form(r.min_y() - self.form_viewport.min_y(), tm);
        } else if r.max_y() > self.form_viewport.max_y() {
            self.scroll_form(r.max_y() - self.form_viewport.max_y(), tm);
        }
    }

    /// The card width: `self.width`, widened so the footer row shows every title in full (the Export finished card with the
    /// support reminder has four long buttons), up to the window less its margins.
    fn width_for_buttons(&self, window: CGRect, tm: &TextMeasure) -> f64 {
        let n = self.model.buttons.len();
        let row: f64 = (0..n).map(|i| self.button_width(i, tm)).sum::<f64>()
            + m::BUTTON_GAP * n.saturating_sub(1) as f64
            + 2.0 * m::SIDE_PAD;
        let room = if window.width > 0.0 { window.width - 2.0 * m::WINDOW_MARGIN } else { f64::INFINITY };
        // Never wider than the window less its margins: a 900 sheet in a 640 window shrinks and its body scrolls.
        self.width.max(row.min(room)).min(room.max(0.0))
    }

    /// The widths of the buttons `order` in `avail` points: a footer still wider than the card (a window too small to widen it) shrinks its widest titles; `draw_buttons` cuts them with an ellipsis.
    fn fitted_button_widths(&self, order: &[usize], avail: f64, tm: &TextMeasure) -> BTreeMap<usize, f64> {
        let natural: Vec<f64> = order.iter().map(|&i| self.button_width(i, tm)).collect();
        let fixed: Vec<bool> = order.iter().map(|i| self.button_widths.contains_key(i)).collect();
        let fitted = Self::shrink_widths(&natural, &fixed, avail, m::BUTTON_GAP, 2.0 * m::BUTTON_PADDING + 24.0);
        order.iter().copied().zip(fitted).collect()
    }

    /// Water-fills `natural` down to fit `avail` (gaps between): the widest non-fixed entries are cut to a common cap, none
    /// below `floor`.
    pub(crate) fn shrink_widths(natural: &[f64], fixed: &[bool], avail: f64, gap: f64, floor: f64) -> Vec<f64> {
        let room = avail - gap * natural.len().saturating_sub(1) as f64;
        let mut cap = f64::INFINITY;
        let total =
            |cap: f64| -> f64 { natural.iter().zip(fixed).map(|(&w, &f)| if f { w } else { w.min(cap) }).sum() };
        if total(cap) > room {
            let (mut lo, mut hi) = (floor, natural.iter().copied().fold(0.0, f64::max));
            for _ in 0..40 {
                let mid = (lo + hi) / 2.0;
                if total(mid) > room { hi = mid } else { lo = mid }
            }
            cap = lo.max(floor);
        }
        natural.iter().zip(fixed).map(|(&w, &f)| if f { w } else { w.min(cap).max(w.min(floor)) }).collect()
    }

    fn button_width(&self, i: usize, tm: &TextMeasure) -> f64 {
        // The Mac SQButton has no minimum width (`OK` is 46 pt). A set width is a minimum: a longer (German) title grows it.
        let icon = if self.button_icons.contains_key(&i) { m::BUTTON_ICON + m::BUTTON_ICON_GAP } else { 0.0 };
        let measured =
            tm.width(&self.button_title(i), m::BUTTON_FONT, tm.medium()).ceil() + icon + 2.0 * m::BUTTON_PADDING;
        self.button_widths.get(&i).map_or(measured, |w| w.max(measured))
    }

    /// The shown title of button `i`, with its key hint.
    pub(crate) fn button_title(&self, i: usize) -> String {
        let title = SQL10n::string(&self.model.buttons[i].title);
        match self.button_hints.get(&i) {
            Some(h) => format!("{title}  {h}"),
            None => title,
        }
    }

    // MARK: Responses

    /// `SQModal.response` with the shared-toolkit keys: Enter = the focused button else the main action, Esc and Ctrl-. =
    /// Cancel, Ctrl-D = Don't Save, Ctrl-S = Save.
    pub fn response(&self, key: InputKey, mods: InputModifiers) -> Option<SQDialogResponse> {
        if mods.contains(InputModifiers::OPTION) {
            return None;
        }
        if mods.contains(InputModifiers::COMMAND) {
            let InputKey::Character(c) = key else { return None };
            return match c.to_lowercase().to_string().as_str() {
                "." => self.model.response(false),
                "d" => self.model.dont_save_index().map(|i| SQDialogResponse(i as i64)),
                "s" => self.model.save_index().map(|i| SQDialogResponse(i as i64)),
                _ => None,
            };
        }
        match key {
            InputKey::Escape => {
                self.escape_response.or_else(|| self.model.response(false)).or_else(|| self.escape_fallback())
            }
            InputKey::Enter => self.focused.map(|f| SQDialogResponse(f as i64)).or_else(|| self.model.response(true)),
            InputKey::Space => self.focused.map(|f| SQDialogResponse(f as i64)),
            _ => None,
        }
    }

    /// Esc on a dialog with no Cancel and several buttons (About: Done + Acknowledgments): the Default button closes it. A
    /// dialog with neither answers nothing, so no Esc can run a Destructive or a Normal button.
    fn escape_fallback(&self) -> Option<SQDialogResponse> {
        self.model.buttons.iter().position(|b| b.role == SQDialogRole::Default).map(|i| SQDialogResponse(i as i64))
    }

    /// Whether button `i` takes clicks and Return.
    pub fn is_enabled(&self, i: usize) -> bool {
        self.button_enabled.as_ref().is_none_or(|f| f(i))
    }

    /// The form change a `keep_open` button raises.
    pub const BUTTON_CHANGE: &'static str = "button";

    /// Answers the dialog with `r` (a button press); the completion runs once.
    pub fn press(&mut self, r: SQDialogResponse) {
        let Ok(index) = usize::try_from(r.0) else { return };
        if self.finished || !self.is_enabled(index) {
            return;
        }
        if let Some((titles, picked)) = self.button_menus.get(&index)
            && picked.get().is_none()
        {
            if let Some(below) = self.button_frames.get(&index).copied() {
                let items = titles
                    .iter()
                    .enumerate()
                    .map(|(n, t)| {
                        let picks = std::rc::Rc::clone(&self.menu_picks);
                        let mut item = SQMenuItem::new(t);
                        item.action = Some(std::rc::Rc::new(move || picks.borrow_mut().push(n)));
                        item
                    })
                    .collect();
                self.pending_popup = Some(PopupRequest { items, below });
            }
            return;
        }
        if self.keep_open.contains(&index) {
            if let Some(f) = self.form.as_mut() {
                f.push_change(Self::BUTTON_CHANGE, FormValue::Index(index as i64));
            }
            return;
        }
        if let Some(can_close) = &self.can_close
            && !can_close(r)
        {
            return;
        }
        self.finished = true;
        if let Some(c) = self.completion.take() {
            c(r);
        }
    }

    fn collect_popups(&mut self, tm: &TextMeasure) {
        let mut requests = Vec::new();
        requests.extend(self.pending_popup.take());
        requests.extend(self.content.as_mut().and_then(|c| c.take_popup()));
        requests.extend(self.form.as_mut().and_then(|f| f.take_popup()));
        for p in requests {
            self.menu.pop_up(p.items, p.below, None, tm);
        }
    }

    /// Modal: the dialog takes every event while it shows.
    pub fn handle(&mut self, e: &InputEvent, scale: f32, tm: &TextMeasure, cx: &mut UiCx) {
        self.handle_event(e, scale, tm, cx);
        let pick = self.menu_picks.borrow_mut().pop();
        if let Some(n) = pick
            && let Some((&button, (_, cell))) = self.button_menus.iter().next()
        {
            cell.set(Some(n));
            self.press(SQDialogResponse(button as i64));
        }
        self.collect_popups(tm);
    }

    fn handle_event(&mut self, e: &InputEvent, scale: f32, tm: &TextMeasure, cx: &mut UiCx) {
        let pt = |x: f32, y: f32| CGPoint::new(f64::from(x / scale), f64::from(y / scale));
        if self.menu.is_open() {
            let _ = self.menu.handle(e, scale, tm);
            return;
        }
        if self.close_frame.width > 0.0 {
            match *e {
                InputEvent::MouseDown { x, y, .. } if self.close_frame.contains(pt(x, y)) => {
                    self.close_pressed = true;
                    return;
                }
                InputEvent::MouseUp { x, y } if self.close_pressed => {
                    self.close_pressed = false;
                    if self.close_frame.contains(pt(x, y))
                        && let Some(r) = self.model.response(false)
                    {
                        self.press(r);
                    }
                    return;
                }
                InputEvent::MouseMoved { x, y } | InputEvent::MouseDragged { x, y, .. } => {
                    self.close_hovered = self.close_frame.contains(pt(x, y));
                    if self.close_hovered {
                        cx.hover.offer_tip(Some(&SQL10n::string("Close (Esc)")));
                    }
                }
                _ => {}
            }
        }
        if let Some(content) = self.content.as_mut() {
            match *e {
                InputEvent::MouseDown { x, y, .. } if self.content_frame.contains(pt(x, y)) => {
                    let _ = content.handle_cx(e, scale, cx);
                    return;
                }
                InputEvent::MouseDown { .. } => {}
                _ => {
                    if content.handle_cx(e, scale, cx) {
                        if let Some(r) = content.take_close() {
                            self.press(r);
                        }
                        return;
                    }
                }
            }
        }
        if self.form.as_ref().is_some_and(|f| f.picker_open()) {
            if let Some(form) = self.form.as_mut() {
                match *e {
                    InputEvent::KeyDown { key, modifiers } => form.picker_key(key, modifiers, cx),
                    InputEvent::MouseDown { x, y, .. } => form.picker_mouse_down(pt(x, y)),
                    InputEvent::MouseDragged { x, y, .. } => form.picker_mouse_dragged(pt(x, y)),
                    InputEvent::MouseUp { .. } => form.picker_mouse_up(),
                    _ => {}
                }
            }
            return;
        }
        if self.form.is_some()
            && self.scroller_event(
                e,
                match *e {
                    InputEvent::MouseDown { x, y, .. }
                    | InputEvent::MouseDragged { x, y, .. }
                    | InputEvent::MouseUp { x, y } => pt(x, y),
                    _ => CGPoint::ZERO,
                },
                tm,
            )
        {
            return;
        }
        if self.form.is_some() {
            match *e {
                InputEvent::KeyDown { key, modifiers } => {
                    let tab = InputKey::Character('\t');
                    if let Some(form) = self.form.as_mut() {
                        if key == tab && form.focused().is_none() && !modifiers.contains(InputModifiers::SHIFT) {
                            self.focused = None;
                        }
                        if form.key(key, modifiers, cx) {
                            if form.focused().is_some() || form.sidebar_focused() {
                                self.focused = None;
                                self.reveal_focused_row(tm);
                            }
                            return;
                        }
                    }
                    if key == tab {
                        if self.focused.is_none() {
                            self.focused = self.model.primary_index();
                        }
                        return;
                    }
                    // A key no row used scrolls a long form (Windows: Down, Up, Page and Home / End did nothing).
                    if self.form_scrolls() && modifiers == InputModifiers::NONE {
                        let page = self.form_viewport.height - 40.0;
                        let by = match key {
                            InputKey::Down => Some(40.0),
                            InputKey::Up => Some(-40.0),
                            InputKey::PageDown => Some(page),
                            InputKey::PageUp => Some(-page),
                            InputKey::Home => Some(-self.form_scroll),
                            InputKey::End => Some(self.form_height),
                            _ => None,
                        };
                        if let Some(by) = by {
                            self.scroll_form(by, tm);
                            return;
                        }
                    }
                    if key == InputKey::Enter
                        && let Some(form) = self.form.as_mut()
                    {
                        form.commit_editing();
                    }
                }
                InputEvent::MouseDown { x, y, .. } => {
                    let p = pt(x, y);
                    if self.button_at(p).is_none() {
                        if self.form_viewport.contains(p)
                            && let Some(form) = self.form.as_mut()
                            && form.mouse_down(p, tm)
                        {
                            self.focused = None;
                        }
                        return;
                    }
                    if let Some(form) = self.form.as_mut() {
                        form.commit_editing();
                    }
                }
                InputEvent::MouseDragged { x, y, .. } => {
                    if let Some(form) = self.form.as_mut() {
                        form.mouse_dragged(pt(x, y), tm, cx);
                    }
                }
                InputEvent::MouseUp { .. } => {
                    if let Some(form) = self.form.as_mut() {
                        form.mouse_up(cx);
                    }
                }
                InputEvent::MouseMoved { x, y } => {
                    let p = pt(x, y);
                    let at = if self.form_viewport.contains(p) { p } else { CGPoint::new(-1.0, -1.0) };
                    if let Some(form) = self.form.as_mut() {
                        form.mouse_moved(at);
                    }
                }
                InputEvent::Scroll { dy, .. } => {
                    self.scroll_form(-f64::from(dy / scale), tm);
                    return;
                }
            }
        }
        match *e {
            InputEvent::KeyDown { key, modifiers } => {
                if key == InputKey::Character('\t') {
                    return;
                }
                if key == InputKey::Left || key == InputKey::Right {
                    let order = self.model.display_order();
                    let at: isize = self
                        .focused
                        .and_then(|f| order.iter().position(|&i| i == f))
                        .map_or(if key == InputKey::Left { order.len() as isize } else { -1 }, |p| p as isize);
                    let next = at + if key == InputKey::Right { 1 } else { -1 };
                    if let Ok(n) = usize::try_from(next)
                        && let Some(&i) = order.get(n)
                    {
                        self.focused = Some(i);
                    }
                    return;
                }
                if let Some(r) = self.response(key, modifiers) {
                    self.press(r);
                }
            }
            InputEvent::MouseMoved { x, y } => self.hovered = self.button_at(pt(x, y)),
            InputEvent::MouseDown { x, y, .. } => self.pressed = self.button_at(pt(x, y)),
            InputEvent::MouseDragged { x, y, .. } => self.hovered = self.button_at(pt(x, y)),
            InputEvent::MouseUp { x, y } => {
                if let Some(p) = self.pressed
                    && self.button_at(pt(x, y)) == Some(p)
                {
                    self.press(SQDialogResponse(p as i64));
                }
                self.pressed = None;
            }
            InputEvent::Scroll { dy, .. } => {
                if !self.kit_steps.is_empty() {
                    self.scroll_steps(-f64::from(dy / scale));
                }
            }
        }
    }

    fn button_at(&self, p: CGPoint) -> Option<usize> {
        self.button_frames.iter().find(|(_, r)| r.contains(p)).map(|(i, _)| *i)
    }

    // MARK: Drawing (`SQDialogCardView`, `SQButton`)

    /// Draws the scrim, the card and its parts.
    pub fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, window: CGRect, cx: &mut UiCx) {
        if self.kit_plain() {
            return self.draw_plain(c, t, window, cx);
        }
        let dark = t.palette.is_dark();
        c.fill(window, Color::new(0.0, 0.0, 0.0, if dark { m::SCRIM_ALPHA } else { m::SCRIM_ALPHA_LIGHT }));
        c.shadow(
            self.card,
            m::RADIUS,
            m::SHADOW_BLUR,
            m::SHADOW_DY,
            Color::new(0.0, 0.0, 0.0, if dark { m::SHADOW_ALPHA } else { m::SHADOW_ALPHA_LIGHT }),
            true,
        );
        // `SQDialogStyle.styleCard`: `panel` fill; a sheet's footer band is the card's bottom in `panel` with a hairline above.
        c.fill_rounded(self.card, m::RADIUS, t.panel());
        let card = self.card;
        if self.header_band > 0.0 {
            c.fill(
                CGRect::new(card.min_x(), card.min_y() + self.header_band - m::HAIR_HEIGHT, card.width, m::HAIR_HEIGHT),
                t.hair(),
            );
        }
        if !self.headerless {
            let band_h = self.band_height();
            let band = CGRect::new(card.min_x(), card.max_y() - band_h, card.width, band_h);
            c.save_gstate();
            c.clip_to(band);
            c.fill_rounded(card, m::RADIUS, t.panel());
            c.restore_gstate();
            c.fill(CGRect::new(band.min_x(), band.min_y(), band.width, m::HAIR_HEIGHT), t.hair());
            if let Some(status) = self.footer_status.as_ref().map(|f| f()) {
                let left = self
                    .model
                    .display_order()
                    .into_iter()
                    .filter(|&i| !(self.model.buttons[i].is_leading() && Some(i) != self.model.primary_index()))
                    .filter_map(|i| self.button_frames.get(&i).map(|r| r.min_x()))
                    .reduce(f64::min)
                    .unwrap_or(band.max_x() - m::SIDE_PAD);
                c.draw_text_in(
                    &status,
                    CGRect::new(
                        band.min_x() + m::SIDE_PAD,
                        band.min_y(),
                        (left - 8.0 - band.min_x() - m::SIDE_PAD).max(0.0),
                        band.height,
                    ),
                    m::NOTE_FONT,
                    t.label3(),
                    TextAlign::Right,
                    0.0,
                    0,
                );
            }
            if let Some(s) = self.footer_summary.as_ref().map(|f| f()) {
                self.draw_footer_summary(c, &s, band, t);
            } else if let Some(note) = self.footer_note.as_ref().map(|f| f()).filter(|n| !n.is_empty()) {
                let right = self.button_frames.values().map(|r| r.min_x()).reduce(f64::min).unwrap_or(band.max_x());
                c.draw_text_in(
                    &note,
                    CGRect::new(
                        band.min_x() + m::SIDE_PAD,
                        band.min_y(),
                        (right - band.min_x() - 2.0 * m::SIDE_PAD).max(0.0),
                        band.height,
                    ),
                    m::NOTE_FONT,
                    t.label2(),
                    TextAlign::Left,
                    0.0,
                    0,
                );
            }
        }
        c.stroke_rounded(card.inset_by(0.25, 0.25), m::RADIUS, 0.5, MenuListView::overlay_edge(t));
        let sheet = self.is_sheet();
        let start_header = self.heading_font_size.is_some() && sheet;
        let alert = !sheet && !self.headerless;
        let title_line = self.title_line();
        let mut y = card.min_y()
            + if start_header {
                15.0
            } else if alert || self.note_in_body {
                ((m::BAND_HEADER_HEIGHT - title_line) / 2.0).round() + 1.0
            } else {
                self.text_top + m::HEADER_TOP
            };
        // The start sheet's header labels are NSTextFields: 2 pt of cell padding before the text.
        let x0 = card.min_x() + m::SIDE_PAD + if start_header { 2.0 } else { 0.0 };
        let x = x0 + self.title_indent();
        let w = card.width - 2.0 * m::SIDE_PAD - self.title_indent();
        if let Some(tone) = self.header_icon
            && !self.title_lines.is_empty()
        {
            let iy = y - 1.0 + ((title_line - m::HEADER_ICON_SIZE) / 2.0).round();
            if tone == Tone::Error {
                // art.html 01: a circle with an exclamation mark (ring, bar, dot), drawn from primitives.
                let r = CGRect::new(x0, iy, m::HEADER_ICON_SIZE, m::HEADER_ICON_SIZE);
                c.stroke_rounded(r.inset_by(0.75, 0.75), r.width / 2.0, 1.5, t.err_text());
                let bar = CGRect::new(r.mid_x() - 0.75, r.min_y() + 3.5, 1.5, 4.5);
                let dot = CGRect::new(r.mid_x() - 0.85, r.min_y() + 9.0, 1.7, 1.7);
                c.fill_rounded(bar, bar.width / 2.0, t.err_text());
                c.fill_rounded(dot, dot.width / 2.0, t.err_text());
            } else if tone == Tone::Info {
                c.draw_icon(SQIcon::Info, CGPoint::new(x0, iy), m::HEADER_ICON_SIZE, t.accent(), None);
            } else {
                let p = t.palette.warning;
                let warning = Color::new((p.r / 255.0) as f32, (p.g / 255.0) as f32, (p.b / 255.0) as f32, p.a as f32);
                c.draw_icon(SQIcon::Warning, CGPoint::new(x0, iy), m::HEADER_ICON_SIZE, warning, None);
            }
        }
        // `Theme.Sheet.alertTitleFont`: 13 semibold.
        let title_size = self.heading_font_size.unwrap_or(m::TITLE_FONT);
        let semibold = c.semibold();
        for l in &self.title_lines {
            c.draw_text_in(
                l,
                CGRect::new(x, y - 1.0, w, title_line),
                title_size,
                t.label(),
                TextAlign::Left,
                0.0,
                semibold,
            );
            y += title_line;
        }
        // Settings: the page name after the title, `t3` (art.html `.dh` subtitle).
        if let Some(sub) = &self.header_subtitle
            && let Some(first) = self.title_lines.first()
        {
            let tw = c.size_of(first, title_size, semibold).width;
            c.draw_text_in(
                &SQL10n::string(sub),
                CGRect::new(
                    x + tw + 10.0,
                    y - title_line * self.title_lines.len() as f64 - 1.0,
                    (w - tw - 10.0).max(0.0),
                    title_line,
                ),
                m::NOTE_FONT,
                t.label3(),
                TextAlign::Left,
                0.0,
                0,
            );
        }
        if alert || self.note_in_body {
            y = card.min_y() + self.header_band + m::SIDE_PAD + 1.0;
        } else if !self.title_lines.is_empty() && !self.note_lines.is_empty() {
            y += if start_header { 1.0 } else { m::HEADER_GAP };
        }
        // art.html 00/01/02/09: the body of an alert sits at the card's left padding, under the icon's edge, not under the title.
        let note_x = if alert || self.note_in_body { x0 } else { x };
        let note_w =
            card.width - 2.0 * m::SIDE_PAD - if alert || self.note_in_body { 0.0 } else { self.title_indent() };
        for l in &self.note_lines {
            c.draw_text_in(
                l,
                CGRect::new(note_x, if start_header { y } else { y - 1.0 }, note_w + m::WRAP_SLACK, m::NOTE_LINE),
                m::NOTE_FONT,
                if start_header { t.label3() } else { t.label2() },
                TextAlign::Left,
                0.0,
                0,
            );
            y += m::NOTE_LINE;
        }
        self.draw_form(c, t, window, cx);

        if let Some(content) = self.content.as_mut() {
            c.save_gstate();
            // Content may reach up into the header band (About's mascot): clip at the card top, not the content top.
            let f = self.content_frame;
            let top = self.card.min_y().min(f.min_y());
            c.clip_to(CGRect::new(f.min_x(), top, f.width, f.max_y() - top));
            content.draw_cx(c, t, cx);
            c.restore_gstate();
        }
        self.draw_buttons(c, t);
        if self.close_frame.width > 0.0 {
            // The kit's close X (`Form/IconButton/Close`): a hairline X, the 28 pt frame is the pointer target.
            let state = sq_draw::close_x::CloseXState { hovered: self.close_hovered, pressed: self.close_pressed };
            c.close_x(self.close_frame, state, t);
        }
        self.menu.draw(c, t);
        // Swift `defer`: the form's open pickers draw last.
        if let Some(form) = self.form.as_mut() {
            form.draw_overlay(c, t, cx);
        }
    }

    fn draw_form(&mut self, c: &mut Canvas, t: &DrawTheme, window: CGRect, cx: &mut UiCx) {
        if let Some(form) = self.form.as_mut() {
            c.save_gstate();
            c.clip_to(self.form_viewport);
            form.set_overlay_bounds(window);
            form.draw(c, t, cx);
            c.restore_gstate();
            if let Some((_, knob)) = self.scroll_knob() {
                // The overlay scroller of the Mac scroll view: a thin knob at the right edge of the viewport.
                c.fill_rounded(knob, m::SCROLL_BAR_WIDTH / 2.0, t.label3());
            }
        }
    }

    fn draw_buttons(&self, c: &mut Canvas, t: &DrawTheme) {
        let medium = c.medium();
        if let Some(hint) = self.footer_hint.as_ref().filter(|_| self.footer_hint_width > 0.0) {
            let (y, band) = if self.kit_plain() {
                (self.card.max_y() - k::FOOT_BOTTOM - k::BUTTON_HEIGHT, k::BUTTON_HEIGHT)
            } else {
                (self.card.max_y() - self.band_height(), self.band_height())
            };
            let area = CGRect::new(self.card.min_x() + self.footer_pads().0, y, self.footer_hint_width + 2.0, band);
            c.draw_text_in(&SQL10n::string(hint), area, 11.0, t.label4(), TextAlign::Left, 0.0, 0);
        }
        for (&i, &r) in &self.button_frames {
            let b = &self.model.buttons[i];
            let destructive = matches!(b.role, SQDialogRole::Destructive | SQDialogRole::DontSave);
            let main = Some(i) == self.model.primary_index() && !destructive;
            let on = self.is_enabled(i);
            let down = self.pressed == Some(i) && on;
            let over = self.hovered == Some(i) && on;
            // Stone buttons (specs 01-buttons): primary = accent, destructive = red, ghost = quiet, secondary = raised;
            // hover, press (scale .97) and the 2 pt focus ring come from the one stone button.
            let kind = if main {
                ButtonKind::Accent
            } else if destructive {
                ButtonKind::Destructive
            } else if self.ghost_buttons.contains(&i) {
                ButtonKind::Quiet
            } else {
                ButtonKind::Raised
            };
            let touch = Touch {
                hovering: self.hovered == Some(i),
                pressed: self.pressed == Some(i),
                disabled: !on,
                focused: self.focused == Some(i),
            };
            let body = c.stone_button(r, kind, touch, t);
            let mut text = if main || destructive {
                Color::WHITE
            } else if self.ghost_buttons.contains(&i) {
                if over || down { t.label() } else { t.label2() }
            } else {
                t.label()
            };
            if !on {
                text = if main || destructive { Color::WHITE.with_alpha(0.4) } else { t.label3() };
            }
            let icon = self.button_icons.get(&i).copied();
            let lead = icon.map_or(0.0, |_| m::BUTTON_ICON + m::BUTTON_ICON_GAP);
            let title =
                c.ellipsized(&self.button_title(i), m::BUTTON_FONT, medium, r.width - 2.0 * m::BUTTON_PADDING - lead);
            let mut label = CGRect::new(body.x, body.y + 1.0, body.width, body.height);
            if let Some(icon) = icon {
                // Icon and title sit together, centered in the button.
                let text_w = c.size_of(&title, m::BUTTON_FONT, medium).width.ceil();
                let left = (body.mid_x() - (lead + text_w) / 2.0).round();
                c.draw_icon(
                    icon,
                    CGPoint::new(left, (body.mid_y() - m::BUTTON_ICON / 2.0).round()),
                    m::BUTTON_ICON,
                    text,
                    None,
                );
                label = CGRect::new(left + lead, label.y, text_w + 2.0, label.height);
            }
            c.draw_text_in(
                &title,
                label,
                m::BUTTON_FONT,
                text,
                if icon.is_some() { TextAlign::Left } else { TextAlign::Center },
                0.0,
                medium,
            );
        }
    }

    /// `NewProjectSheet` footer: preview 44 at 20, text 14 after it (12 semibold label / 11 label3), up to the buttons.
    fn draw_footer_summary(&self, c: &mut Canvas, s: &FooterSummary, band: CGRect, t: &DrawTheme) {
        let bx =
            CGRect::new(band.min_x() + m::SIDE_PAD, band.min_y() + ((band.height - 44.0) / 2.0).round(), 44.0, 44.0);
        c.fill_rounded(bx, f64::from(radius::OVERLAY), t.content());
        let side = 28.0;
        let a = s.aspect.max(0.05);
        let w = if a >= 1.0 { side } else { side * a };
        let h = if a >= 1.0 { side / a } else { side };
        let r = CGRect::new(
            bx.min_x() + ((bx.width - w) / 2.0).round(),
            bx.min_y() + ((bx.height - h) / 2.0).round(),
            w,
            h.max(2.0),
        );
        c.fill_rounded(r, f64::from(radius::SMALL), t.clip(LabelColor::Blue).with_alpha(0.85));
        // Measured against the Mac footer: the text starts 14 after the box.
        let x = bx.max_x() + 14.0;
        let right = self.button_frames.values().map(|b| b.min_x()).reduce(f64::min).unwrap_or(band.max_x()) - 16.0;
        let tw = (right - x).max(0.0);
        let semibold = c.semibold();
        c.draw_text_in(
            &s.line1,
            CGRect::new(x, band.mid_y() - 17.5, tw, 16.0),
            12.0,
            t.label(),
            TextAlign::Left,
            0.0,
            semibold,
        );
        c.draw_text_in(
            &s.line2,
            CGRect::new(x, band.mid_y() - 2.5, tw, 14.0),
            11.0,
            t.label3(),
            TextAlign::Left,
            0.0,
            0,
        );
    }
}

#[cfg(test)]
mod footer_order_tests {
    use super::*;

    /// Labels left to right, as the footer draws them.
    fn visual(d: &ShellDialog) -> Vec<String> {
        d.footer_order().into_iter().map(|i| d.model.buttons[i].title.clone()).collect()
    }

    #[test]
    fn dialog_buttons_run_left_to_right_as_in_the_design() {
        assert_eq!(
            visual(&crate::shell_host::ShellHost::ducks_twice_dialog()),
            ["Bake Again", "Cancel", "Remove Keys"]
        );
        let mut silences = ShellDialog::new("Remove Silences", "");
        crate::shell_host::ShellHost::add_silence_buttons(&mut silences);
        assert_eq!(visual(&silences), ["Mark for Review", "Cancel", "Remove"]);
        let taken = crate::shell_host::ShellHost::name_taken_dialog(
            "\u{201c}Sequence 01.mp4\u{201d} already exists in this folder",
            "",
        );
        assert_eq!(visual(&taken), ["Replace", "Cancel", "Keep Both"]);
        let replace = taken.model.buttons.iter().find(|b| b.title == "Replace").unwrap();
        assert_eq!(replace.role, SQDialogRole::Destructive);
        let space = crate::shell_host::ShellHost::export_warning_dialog("Not much disk space", "x");
        assert_eq!(visual(&space), ["Cancel", "Export Anyway"]);
        let pack = crate::shell_host::ShellHost::pack_clash_dialog(
            "Summer Pack",
            "2 presets have the same name as one you already imported from this pack.",
        );
        assert_eq!(visual(&pack), ["Cancel", "Skip Existing", "Replace", "Keep Both"]);
    }

    #[test]
    fn cancel_first_puts_cancel_before_the_answers_and_the_main_one_last() {
        let mut d = ShellDialog::new("\u{201c}Pack\u{201d} is already in the Library", "");
        d.add_button("Keep Both", SQDialogRole::Default, false);
        d.add_button("Replace", SQDialogRole::Normal, false);
        d.add_button("Skip Existing", SQDialogRole::Normal, false);
        d.add_button("Cancel", SQDialogRole::Cancel, false);
        assert_eq!(d.footer_order(), [2, 1, 3, 0]);
        d.cancel_first = true;
        assert_eq!(d.footer_order(), [3, 2, 1, 0]);
    }
}

#[cfg(test)]
mod fit_tests {
    use super::*;
    use crate::shell_new_project::ShellNewProject;
    use sq_core_project::project_template::ProjectTemplate;
    use sq_draw::GlyphAtlas;

    /// German buttons ("Abbrechen") must fit their label at every UI scale: the frame is at least the measured text plus
    /// padding, and the row stays inside the card.
    #[test]
    fn new_project_buttons_fit_german_text_at_every_scale() {
        let fonts = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
        let Some(atlas) = GlyphAtlas::inter(&fonts) else { panic!("bundled Inter loads") };
        let templates = ProjectTemplate::built_in();
        for scale in [1.0_f32, 1.5, 2.0] {
            atlas.set_point_scale(scale);
            let tm = TextMeasure::new(Some(&atlas), scale);
            let mut d = ShellNewProject::dialog(&templates, &std::env::temp_dir(), false);
            d.add_button("Abbrechen", SQDialogRole::Normal, false);
            d.layout(CGRect::new(0.0, 0.0, 1400.0, 900.0), &tm);
            for (i, f) in d.button_frames.clone() {
                let text = tm.width(&d.button_title(i), m::BUTTON_FONT, tm.medium()).ceil();
                assert!(
                    f.width + 0.5 >= text + 2.0 * m::BUTTON_PADDING,
                    "button {} is {} wide for {text} at x{scale}",
                    d.button_title(i),
                    f.width
                );
                assert!(
                    f.min_x() >= d.card.min_x() && f.max_x() <= d.card.max_x(),
                    "button {i} leaves the card at x{scale}"
                );
            }
        }
    }
}

#[cfg(test)]
mod kit_shadow_tests {
    use super::*;

    /// Kit render: alert and form `0 18px 48px #00000099`, sheet (settings) `0 24px 64px #000000A6`.
    #[test]
    fn dialog_shadows_are_the_kit_values() {
        assert_eq!((k::SHADOW_BLUR, k::SHADOW_DY, k::SHADOW_ALPHA), (48.0, 18.0, 0.6));
        assert_eq!((m::SHADOW_BLUR, m::SHADOW_DY, m::SHADOW_ALPHA), (64.0, 24.0, 0.65));
    }

    /// The Save prompt at 1100x744 (pose `dlg-save`): the kit card is 420 wide (its 1 px border sits outside the box), centered
    /// in the window, so the left edge is x = 340 and the top is the floored centering of the height. The kit PNG then lines up
    /// at offset (293, 279) for the content box, (293, 280) for its border row. The F3 acceptance run's 3 px offset came from the
    /// compare tool's search, not from the card (see PIXEL-PARITY.md, dlg-save).
    #[test]
    fn save_prompt_card_is_centered_at_1100_by_744() {
        let mut d = crate::shell_host::ShellHost::save_changes_dialog("P", true);
        d.layout(CGRect::new(0.0, 0.0, 1100.0, 744.0), &sq_draw::TextMeasure::new(None, 1.0));
        let card = d.card;
        assert_eq!((card.min_x(), card.width), (340.0, k::WIDTH));
        assert_eq!(card.min_y(), (372.0 - card.height / 2.0).floor());
        assert!((card.mid_y() - 372.0).abs() <= 1.0, "centered within 1 px: {card:?}");
    }
}

#[cfg(test)]
mod escape_tests {
    use super::*;
    use crate::shell_about::AboutPage;
    use crate::shell_form::ShellForm;
    use crate::shell_host::ShellHost;
    use crate::test_support::{session, shell};
    use sq_uikit::sqdialog_model::SQDialogRole as Role;

    /// Esc answers every dialog kind that has a way out: Cancel where there is one, else the Default button (About: Done).
    #[test]
    fn escape_closes_every_dialog_kind() {
        let (s, mut h) = (session(), shell());
        let templates = h.all_templates();
        let kinds: Vec<(&str, ShellDialog)> = vec![
            ("About", h.about_dialog(AboutPage::About)),
            ("Acknowledgments", h.about_dialog(AboutPage::Acknowledgments)),
            ("Welcome", ShellHost::welcome_dialog()),
            (
                "New Project",
                crate::shell_new_project::ShellNewProject::dialog(&templates, std::path::Path::new("/tmp"), false),
            ),
            ("Recovery", ShellHost::recovery_dialog("P", "today")),
            ("Save prompt", ShellHost::save_changes_dialog("P", true)),
            ("Save prompt, untitled", ShellHost::save_changes_dialog("P", false)),
            ("Warning", ShellHost::export_warning_dialog("t", "m")),
            ("Name taken", ShellHost::name_taken_dialog("t", "m")),
            ("Pack clash", ShellHost::pack_clash_dialog("p", "i")),
            ("Reconnect", ShellHost::reconnect_dialog(ShellForm::new(vec![]), "t", "n")),
            ("History", ShellHost::history_dialog(&s)),
        ];
        for (name, d) in kinds {
            let r = d.response(InputKey::Escape, InputModifiers::NONE);
            assert!(r.is_some(), "Esc closes {name}");
        }
    }

    /// The Save prompt's Esc is Cancel; About's Esc is Done; a lone Destructive or Normal button never answers Esc.
    #[test]
    fn escape_picks_cancel_then_default_and_never_a_destructive_button() {
        let esc = |d: &ShellDialog| d.response(InputKey::Escape, InputModifiers::NONE);
        let save = ShellHost::save_changes_dialog("P", true);
        let cancel = save.model.buttons.iter().position(|b| b.role == Role::Cancel).unwrap();
        assert_eq!(esc(&save), Some(SQDialogResponse(cancel as i64)));
        let about = shell().about_dialog(AboutPage::About);
        assert_eq!(esc(&about), Some(SQDialogResponse(0)), "Done");
        let mut d = ShellDialog::new("Delete?", "");
        d.add_button("Delete", Role::Destructive, false);
        d.add_button("Keep", Role::Normal, false);
        assert_eq!(esc(&d), None, "a choice with no way out must be answered");
    }
}
