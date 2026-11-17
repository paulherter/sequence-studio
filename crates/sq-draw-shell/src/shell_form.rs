// Swift: ShellForm.swift
//! The body of a form dialog: `SQDialogForm` and the `SQDialog.formRow` / `checkRow` / `popupRow` / `sliderRow` / `radioRow`
//! builders translated onto the canvas. Rows stack edge to edge with `Theme.Sheet.formRowGap`; a label column of 104 pt
//! (right of the 20 pt card edge, 16 pt gap) and the controls filling the rest, as on the Mac. The controls are the shared
//! toolkit ones (`TextFieldControl`, `InspectorDraw::popup` / `checkbox` / `slider`), so dialogs look like the panels.
//! Values live in `values` under each row's `id`; the caller reads them when the dialog answers.
//! A form with a `Sidebar` (Preferences: the Mac `SettingsWindow` page list) draws the page list in a left column with
//! a rule after it and the rows to its right; a click on a page answers a change `(sidebar.id, Index(page))`.
//! The sidebar is the first Tab stop (Up/Down pick the page, as the Mac list) and stays put while a long page scrolls
//! (`sidebar_shift`, set by the dialog).
//!
//! Mapping: `onChange` is the queue [`DialogForm::take_changes`]; `openPopup` is [`DialogForm::take_popup`] and a chosen
//! option comes back through a queue the form applies at its next call. The text measure borrows the atlas, so calls that
//! need it take `&TextMeasure`; what a later press needs (button and segment frames) is kept from the last layout.
//! `valueFormatter` / `valueParser` of [`ShellForm::set_format`] are boxed closures.

use crate::shell_dialog::{DialogForm, FormValue, PopupRequest};
use sq_draw::inspector::color_picker_control::Outcome as PickerOutcome;
use sq_draw::inspector::scrub_field_control::{Event as ScrubEvent, ValueFormatter, ValueParser};
use sq_draw::inspector::text_edit_state::Outcome as EditOutcome;
use sq_draw::stone::{ButtonKind, Touch};
use sq_draw::theme::{radius, type_size};
use sq_draw::{
    Alignment, Canvas, CheckState, ClickCounter, Color, ColorPickerControl, DrawTheme, InputKey, InputModifiers,
    InspectorDraw, InspectorTokens, ScrubFieldControl, TextAlign, TextEditState, TextFieldControl, TextMeasure, UiCx,
};
use sq_editor_session::ExportPreviewMath;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::localization::SQL10n;
use sq_uikit::scrub_math::ScrubMath;
use sq_uikit::sqcolor_value::SQColorValue;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::{SQMenuIcon, SQMenuItem};
use std::cell::RefCell;
use std::collections::{BTreeMap, BTreeSet};
use std::ops::RangeInclusive;
use std::rc::Rc;
use std::time::Instant;

/// A reaction to a changed value (Swift `onChange` closure that edits the form itself).
pub type ChangeReaction = Box<dyn Fn(&mut ShellForm, &str, &FormValue)>;

/// The scrub bar of a [`Row::Picture`] (`ExportScrubBar` with the play button and the timecode): the sheet sets it, the
/// form reports a click as `preview_play` (`Bool`: playing), a scrub as `preview_scrub` (`Number`: 0...1) and a
/// stepping key as `preview_step` (`Index`: -1 or 1).
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PreviewTransport {
    /// Frames of the preview source; 0 = nothing to play yet (the bar stays empty).
    pub frames: usize,
    /// Scrub position, 0...1.
    pub fraction: f64,
    /// Playing.
    pub playing: bool,
    /// "00:00:01:12" of the shown frame.
    pub timecode: String,
}

/// One row of a form.
#[derive(Clone, Debug, PartialEq)]
pub enum Row {
    /// A note line (`SQDialog.formText`), wrapped to the card.
    Text(String),
    /// "Label [field]" with a free text field (names, numbers with `unit`).
    Field {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Start value.
        value: String,
        /// Unit after the field.
        unit: String,
    },
    /// "Label [popup]".
    Popup {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Options.
        options: Vec<String>,
        /// Chosen option.
        selected: i64,
    },
    /// "Label [color well]" (`SQColorWell` in `SQDialog.formRow`): a swatch that opens the SQ color picker under it.
    Color {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Start color.
        value: SQColorValue,
    },
    /// A check box row (`SQDialog.checkRow`).
    Check {
        /// Value key.
        id: String,
        /// Title next to the box.
        title: String,
        /// Start state.
        on: bool,
    },
    /// "Label [slider] [field]" (`SQDialog.sliderRow`), value in `range`.
    Slider {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Start value.
        value: f64,
        /// Value range.
        range: RangeInclusive<f64>,
        /// Unit after the value.
        unit: String,
    },
    /// "Label [slider] [number field] unit" (the Mac `NumericSlider`): the slider spans the field's `range`, the plain field
    /// shows the value in accent from its leading edge, and the unit sits after it in a column of at least 24.
    SliderNumber {
        /// Row label.
        label: String,
        /// The number field.
        field: NumberField,
    },
    /// A radio group, one row per option (`SQDialog.radioRow` without the trailing field).
    Radio {
        /// Value key.
        id: String,
        /// Options.
        options: Vec<String>,
        /// Chosen option.
        selected: i64,
    },
    /// "Label  detail text  [Button] [Button]": a click answers `(id, Index(button))`; `enabled` holds one flag per button
    /// (missing = enabled).
    Buttons {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Text left of the buttons.
        detail: String,
        /// Button titles.
        titles: Vec<String>,
        /// Enabled flags.
        enabled: Vec<bool>,
    },
    /// "Label [number field] unit" (`SQDialog.formRow` with `SQDialog.makeNumberField`): a scrub field, the value in accent.
    Number {
        /// Row label.
        label: String,
        /// The number field.
        field: NumberField,
    },
    /// A radio group whose options each carry a number field, one form row per option.
    RadioNumbers {
        /// Value key.
        id: String,
        /// Options.
        options: Vec<String>,
        /// Chosen option.
        selected: i64,
        /// One field per option.
        fields: Vec<NumberField>,
    },
    /// A group heading (`SequenceSettingsSheet.groupCaption`).
    Caption(String),
    /// "Frame Size [w] × [h] [swap]": two 72 pt number fields and the swap button.
    Size {
        /// Row label.
        label: String,
        /// Width field.
        width: NumberField,
        /// Height field.
        height: NumberField,
    },
    /// "Label [segmented]" (`segment_width` per segment, 0 = title width plus 24).
    Segmented {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// Options.
        options: Vec<String>,
        /// Chosen option.
        selected: i64,
        /// Segment width.
        segment_width: f64,
    },
    /// Free space (pt).
    Gap(f64),
    /// "Label" over an empty control line.
    Label {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
    },
    /// A note and a bar chart in the control column (`CutCheckSheetView`).
    Chart {
        /// The summary line.
        note: String,
        /// The chart title.
        title: String,
        /// The columns.
        bars: Vec<Bar>,
    },
    /// A picture in the control column (the Export preview): the renderer image slot `slot` holds it once `ready`, shown
    /// fitted in a box of the `width` x `height` aspect.
    Picture {
        /// The renderer image slot.
        slot: usize,
        /// Aspect width of the output.
        width: i64,
        /// Aspect height of the output.
        height: i64,
        /// The slot holds the picture.
        ready: bool,
        /// The scrub bar under the picture (play button, bar, timecode).
        transport: PreviewTransport,
    },
    /// A multi-line text box over the whole form width, `height` pt high (`ProjectNotesDialog`): Return breaks the line,
    /// Esc and Tab leave it to the dialog.
    // Lines do not wrap softly (a long line is clipped at the box edge): matches Swift (`ShellForm.textBox`).
    TextBox {
        /// Value key.
        id: String,
        /// Start text.
        value: String,
        /// Box height.
        height: f64,
    },
    /// "Label [list box]" (`EffectDefaultsSettingsView`): a 440 pt `fill2` box with one 28 pt line per entry (title, a button
    /// right) or, with no entry, `empty` in `label3`. A button answers `(id, Index(line))`.
    ListBox {
        /// Value key.
        id: String,
        /// Row label.
        label: String,
        /// The entries.
        lines: Vec<String>,
        /// Button title.
        button: String,
        /// Text of the empty box.
        empty: String,
    },
}

impl Row {
    /// A `.field` row without a unit.
    pub fn field(id: &str, label: &str, value: &str) -> Row {
        Row::Field { id: id.into(), label: label.into(), value: value.into(), unit: String::new() }
    }
    /// A `.popup` row.
    pub fn popup(id: &str, label: &str, options: &[&str], selected: i64) -> Row {
        Row::Popup {
            id: id.into(),
            label: label.into(),
            options: options.iter().map(|s| (*s).into()).collect(),
            selected,
        }
    }
    /// A `.check` row.
    pub fn check(id: &str, title: &str, on: bool) -> Row {
        Row::Check { id: id.into(), title: title.into(), on }
    }
    /// A `.slider` row without a unit.
    pub fn slider(id: &str, label: &str, value: f64, range: RangeInclusive<f64>) -> Row {
        Row::Slider { id: id.into(), label: label.into(), value, range, unit: String::new() }
    }
    /// A `.radio` row.
    pub fn radio(id: &str, options: &[&str], selected: i64) -> Row {
        Row::Radio { id: id.into(), options: options.iter().map(|s| (*s).into()).collect(), selected }
    }
    /// A `.buttons` row with every button enabled.
    pub fn buttons(id: &str, label: &str, detail: &str, titles: &[&str]) -> Row {
        Row::Buttons {
            id: id.into(),
            label: label.into(),
            detail: detail.into(),
            titles: titles.iter().map(|s| (*s).into()).collect(),
            enabled: Vec::new(),
        }
    }
    /// A `.segmented` row.
    pub fn segmented(id: &str, label: &str, options: &[&str], selected: i64, segment_width: f64) -> Row {
        Row::Segmented {
            id: id.into(),
            label: label.into(),
            options: options.iter().map(|s| (*s).into()).collect(),
            selected,
            segment_width,
        }
    }

    pub(crate) fn id(&self) -> Option<&str> {
        match self {
            Row::Field { id, .. }
            | Row::Popup { id, .. }
            | Row::Check { id, .. }
            | Row::Slider { id, .. }
            | Row::Radio { id, .. }
            | Row::Buttons { id, .. }
            | Row::RadioNumbers { id, .. }
            | Row::Segmented { id, .. }
            | Row::Label { id, .. }
            | Row::TextBox { id, .. }
            | Row::Color { id, .. }
            | Row::ListBox { id, .. } => Some(id),
            Row::Number { field, .. } | Row::SliderNumber { field, .. } => Some(&field.id),
            Row::Size { width, .. } => Some(&width.id),
            Row::Text(_) | Row::Gap(_) | Row::Caption(_) | Row::Chart { .. } | Row::Picture { .. } => None,
        }
    }
}

/// One column of a `.chart` row (`ShotBucket`).
#[derive(Clone, Debug, PartialEq)]
pub struct Bar {
    /// Label under the column.
    pub label: String,
    /// Count over the column.
    pub count: i64,
}

/// One line of a number grid under a row (`SQFormRow.unitGrid`): title (11 pt `label3`) | 72 pt field | unit (`label3`).
#[derive(Clone, Debug, PartialEq)]
pub struct GridCell {
    /// Title left of the field.
    pub title: String,
    /// The field.
    pub field: NumberField,
    /// Unit after the field.
    pub unit: String,
}

/// The tone of a status line.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusTone {
    /// Gray.
    Idle,
    /// Green.
    Ok,
    /// Warning color.
    Warning,
}

/// A status line under a row (the Mac Edit API row: an 8 pt dot, the text, an optional button). A click on the button
/// answers `("<row id>.status", Index(0))`.
#[derive(Clone, Debug, PartialEq)]
pub struct Status {
    /// The text.
    pub text: String,
    /// The dot and text tone.
    pub tone: StatusTone,
    /// Button title.
    pub button: Option<String>,
    /// Icon before the button title.
    pub button_icon: Option<SQIcon>,
}

/// One `SQDialog.makeNumberField` (a `ScrubField`): drag, type, arrows, double-click resets to `default_value`. Its value
/// lives in `values[id]` as `Number`.
#[derive(Clone, Debug, PartialEq)]
pub struct NumberField {
    /// Value key.
    pub id: String,
    /// Start value.
    pub value: f64,
    /// Value range.
    pub range: RangeInclusive<f64>,
    /// Arrow step.
    pub step: f64,
    /// Decimals shown.
    pub decimals: i64,
    /// Unit after the field.
    pub unit: String,
    /// Double-click value.
    pub default_value: Option<f64>,
}

impl NumberField {
    /// A field with step 1, no decimals and no unit.
    pub fn new(id: &str, value: f64, range: RangeInclusive<f64>) -> NumberField {
        NumberField { id: id.into(), value, range, step: 1.0, decimals: 0, unit: String::new(), default_value: None }
    }
}

/// The link toggle beside two number rows (the Speed sheet's speed/duration link): the rows end `side_pad + 24` earlier,
/// the icon sits at the right edge between them; a click answers `(id, Bool)`.
#[derive(Clone, Debug, PartialEq)]
pub struct Link {
    /// Value key.
    pub id: String,
    /// The linked field ids.
    pub fields: Vec<String>,
}

/// The page list of a sidebar form: icon and title per page, the selected one under `id`.
#[derive(Clone, Debug)]
pub struct Sidebar {
    /// Value key.
    pub id: String,
    /// Title and icon of each page.
    pub items: Vec<(String, SQIcon)>,
}

/// A `.listBox` line with more than its name: an icon before the name, a gray detail after it and an optional warning word.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ListLine {
    /// Icon before the name.
    pub icon: Option<SQIcon>,
    /// Gray detail.
    pub detail: String,
    /// Warning word.
    pub warning: Option<String>,
}

/// One card of a shape row: its caption and the picture's size (`0 x 0` = a dashed "any size" frame).
#[derive(Clone, Debug, PartialEq)]
pub struct ShapeCard {
    /// "9:16", "Custom".
    pub title: String,
    /// The shape's width in the picture; 0 for Custom.
    pub width: i64,
    /// The shape's height in the picture; 0 for Custom.
    pub height: i64,
}

/// The kit's color dots (`.dots`): 16 pt dots 5 pt apart, the chosen one with a ring.
pub struct DotRow;

impl DotRow {
    /// Dot diameter.
    pub const DOT: f64 = 16.0;
    const PITCH: f64 = 21.0;

    /// Width of `n` dots.
    pub fn width(n: usize) -> f64 {
        (n as f64 * Self::PITCH - (Self::PITCH - Self::DOT)).max(0.0)
    }

    /// The dot frames inside `control`.
    pub fn frames(control: CGRect, n: usize) -> Vec<CGRect> {
        (0..n)
            .map(|k| {
                CGRect::new(
                    control.min_x() + k as f64 * Self::PITCH,
                    control.mid_y() - Self::DOT / 2.0,
                    Self::DOT,
                    Self::DOT,
                )
            })
            .collect()
    }
}

impl ShapeCard {
    /// Card height (the design's `.shape`), gap between cards, and the longest side of the little picture.
    pub const HEIGHT: f64 = 62.0;
    /// Gap between two cards.
    pub const GAP: f64 = 8.0;
    /// Space for the hint line under the cards.
    pub const HINT_ROOM: f64 = 20.0;
    const PICTURE: f64 = 26.0;

    /// The card frames inside `control` (equal widths).
    pub fn frames(control: CGRect, n: usize) -> Vec<CGRect> {
        if n == 0 {
            return Vec::new();
        }
        let w = ((control.width - Self::GAP * (n as f64 - 1.0)) / n as f64).max(0.0);
        (0..n)
            .map(|k| CGRect::new(control.min_x() + k as f64 * (w + Self::GAP), control.min_y(), w, Self::HEIGHT))
            .collect()
    }

    /// The little picture's size: the longest side is 26, Custom is a 26 x 18 dashed frame.
    pub fn picture(&self) -> (f64, f64) {
        if self.width <= 0 || self.height <= 0 {
            return (Self::PICTURE, 18.0);
        }
        let k = Self::PICTURE / self.width.max(self.height) as f64;
        (self.width as f64 * k, self.height as f64 * k)
    }
}

/// The Mac `SQMenuPopup` extras of a popup row: a key column per option, group headers and separators before options, and a
/// key drawn in the closed box left of the chevron.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PopupStyle {
    /// Key column per option.
    pub keys: Vec<String>,
    /// Group headers before options.
    pub headers: BTreeMap<usize, String>,
    /// Separators before options.
    pub separator_before: BTreeSet<usize>,
    /// Key shown in the closed box.
    pub box_key: String,
    /// A color dot (0xRRGGBB) per option.
    pub dots: Vec<u32>,
    /// Box height when taller than the 22 pt capsule.
    pub height: Option<f64>,
    /// Title size when not the 11 pt body.
    pub font_size: Option<f64>,
}

/// A `.buttons` row whose detail sits on a `fill` chip with an icon and whose buttons have a fixed width.
#[derive(Clone, Debug, PartialEq)]
pub struct Chip {
    /// Icon before the path.
    pub icon: SQIcon,
    /// Fixed button width.
    pub button_width: f64,
}

mod m {
    /// The picture row's bar under the box (`ExportDialogView`: play 24 wide, 10 below the box, field height 22, timecode 78).
    pub const BAR_GAP: f64 = 10.0;
    pub const BAR_HEIGHT: f64 = 22.0;
    pub const BAR_PLAY: f64 = 24.0;
    pub const BAR_TIMECODE: f64 = 78.0;
    pub const BAR_INSET: f64 = 8.0;
    pub const SIDE_PAD: f64 = 16.0;
    /// A settings page starts 8 pt lower than its sidebar.
    pub const PAGE_TOP: f64 = 8.0;
    pub const ROW_GAP: f64 = 12.0;
    /// art.html `.frm`: a dialog's rows are 26 pt, 4 apart, the label column 96 (measured in the crops) and 12 from the control.
    pub const DIALOG_ROW: f64 = 26.0;
    pub const DIALOG_ROW_GAP: f64 = 4.0;
    pub const DIALOG_LABEL_WIDTH: f64 = 56.0;
    pub const DIALOG_LABEL_GAP: f64 = 12.0;
    /// art.html: every dialog control sits flush on the content edges (the Mac frame bleeds are gone).
    pub const FIELD_BLEED: f64 = 0.0;
    /// art.html `--h-c`: a well, field or popup in a dialog row is 22 high, centered in its 26 pt row; a check row is 22.
    pub const DIALOG_CONTROL: f64 = 22.0;
    pub const DIALOG_CHECK_ROW: f64 = 22.0;
    pub const FIELD_ICON_SIZE: f64 = 12.0;
    pub const POPUP_BLEED: f64 = 5.0;
    pub const ROW_HEIGHT: f64 = 28.0;
    pub const CHECK_ROW_HEIGHT: f64 = 24.0;
    pub const LABEL_WIDTH: f64 = 104.0;
    /// The label column grows to its longest label up to this (the Mac form's labels never truncate).
    pub const LABEL_MAX: f64 = 160.0;
    /// Settings pages (`SQFormRow`): `Theme.Modal.labelColumnL`, help lines at most `SQFormRow.helpMaxWidth`, 4 below.
    pub const SETTINGS_LABEL_WIDTH: f64 = 154.0;
    pub const HELP_MAX_WIDTH: f64 = 440.0;
    pub const HELP_GAP: f64 = 4.0;
    pub const SETTINGS_FONT: f64 = sq_uikit::design_tokens::sq_tokens::type_size::BODY as f64;
    pub const SETTINGS_HELP_LINE: f64 = 16.0;
    pub const LABEL_GAP: f64 = 16.0;
    pub const CONTROL_GAP: f64 = 8.0;
    pub const UNIT_FIELD_WIDTH: f64 = 72.0;
    pub const SLIDER_FIELD_WIDTH: f64 = 60.0;
    pub const DIALOG_SLIDER_FIELD: f64 = 56.0;
    /// `NumericSlider.unitColumn`: the narrowest unit column after a slider's field.
    pub const UNIT_COLUMN: f64 = 24.0;
    pub const NOTE_LINE: f64 = 16.0;
    pub const STRONG_LINE: f64 = 14.0;
    pub const FONT: f64 = 12.0;
    pub const BUTTON_PADDING: f64 = 14.0;
    pub const MIN_BUTTON: f64 = 64.0;
    /// The sidebar column (`SettingsPage.sidebarWidth`, 200 in the Mac L modal).
    pub const SIDEBAR_WIDTH: f64 = 212.0;
    pub const SIDEBAR_ROW: f64 = 28.0;
    /// Redesign R4b: the settings page is a stack of cards (frame `Settings / General`).
    pub const SIDEBAR_TOP: f64 = 16.0;
    pub const PAGE_HEADER: f64 = 88.0;
    pub const CARD_PAD: f64 = 32.0;
    pub const CARD_SIDE: f64 = 16.0;
    pub const CARD_RADIUS: f64 = 8.0;
    pub const ROW_PAD_TOP: f64 = 10.0;
    pub const ROW_PAD_BOTTOM: f64 = 9.0;
    pub const CARD_TITLE_LINE: f64 = 16.0;
    pub const CARD_HELP_W: f64 = 348.0;
    /// Text and a control count as side by side when the control starts at least this far right of the text.
    pub const CARD_TEXT_MIN_BESIDE: f64 = 20.0;
    /// Space kept between a card row's text and the control beside it.
    pub const CARD_TEXT_GAP: f64 = 12.0;
    /// A card row whose text column beside the control would be narrower than this (or than its title) stacks: text on top,
    /// the control below it across the row.
    pub const CARD_STACK_COL: f64 = 160.0;
    /// Space between the text and the control below it in a stacked row.
    pub const CARD_STACK_GAP: f64 = 8.0;
    /// One line of the page subtitle.
    pub const SUBTITLE_LINE: f64 = 16.0;
    pub const CARD_MIN_ROW: f64 = 35.0;
    pub const CARD_SLOT: f64 = 180.0;
    /// The narrowest a card row's label column gets before the control slot shrinks instead, and the least the slot keeps.
    pub const CARD_TEXT_MIN_COL: f64 = 140.0;
    pub const CARD_SLOT_MIN: f64 = 110.0;
    pub const CARD_SLIDER_SLOT: f64 = 280.0;
    /// The Settings slider's track (kit `Settings/Slider`).
    pub const SETTINGS_TRACK: f64 = 200.0;
    pub const SWITCH_W: f64 = 34.0;
    pub const SWITCH_H: f64 = 20.0;
    pub const CARD_BOTTOM: f64 = 28.0;
    pub const GROUP_TITLE_TOP: f64 = 22.0;
    pub const SIDEBAR_GAP: f64 = 2.0;
    pub const SIDEBAR_INSET: f64 = 8.0;
    /// R4e: the search field above the page list: its height.
    pub const SEARCH_HEIGHT: f64 = 26.0;
    /// R4e: the space the search field takes above the first page.
    pub const SEARCH_BLOCK: f64 = 38.0;
    /// R4e: the height of a choice card's picture.
    pub const CHOICE_PICTURE: f64 = 78.0;
    /// R4e: the reset arrow's box.
    pub const RESET_BOX: f64 = 20.0;
    /// `SQDialog.radioRow`: the radio and its title take 190 pt before the field.
    pub const RADIO_COLUMN: f64 = 206.0;
    pub const LINK_WIDTH: f64 = 24.0;
    pub const SIZE_FIELD: f64 = 72.0;
    pub const TIMES_WIDTH: f64 = 7.0;
    pub const CAPTION_TOP: f64 = 8.0;
    pub const CAPTION_LINE: f64 = 14.0;
    pub const CAPTION_AFTER: f64 = 4.0;
    pub const SECTION_TOP: f64 = 18.0;
    pub const GRID_GAP: f64 = 8.0;
    pub const STATUS_DOT: f64 = 8.0;
    pub const CHART_GAP: f64 = 8.0;
    pub const CHART_TITLE_LINE: f64 = 14.0;
    pub const CHART_HEIGHT: f64 = 110.0;
    pub const CHART_BAR_MAX: f64 = 64.0;
    pub const CHART_LINE: f64 = 12.0;
    pub const CHART_INNER: f64 = 3.0;
    pub const LIST_PAD: f64 = 6.0;
    pub const INFO_INDENT: f64 = 18.0;
    pub const BOX_INSET: f64 = 6.0;
    pub const BOX_LINE: f64 = 14.0;
}

fn dim(c: Color) -> Color {
    c.with_alpha(c.a * InspectorTokens::DISABLED_ALPHA)
}

/// `Double(s.trimmingCharacters(in: .whitespaces))`.
fn parse_number(s: &str) -> Option<f64> {
    s.trim_matches(|c| c == ' ' || c == '\t').parse::<f64>().ok()
}

/// The body of a form dialog (Swift `ShellForm`).
pub struct ShellForm {
    rows: Vec<Row>,
    values: BTreeMap<String, FormValue>,
    colors: BTreeMap<String, SQColorValue>,
    picker: Option<ColorPickerControl>,
    picker_row: usize,
    picker_frame: CGRect,
    picker_dragging: bool,
    /// The area the picker may use (the window); the dialog sets it before drawing.
    pub overlay_bounds: CGRect,
    row_frames: Vec<CGRect>,
    /// Redesign R4b: the page title and subtitle drawn above the first card of a sidebar form.
    pub page_header: Option<(String, String)>,
    header_origin: CGPoint,
    /// Width of the page column the header sits in (a narrow window clips the subtitle otherwise).
    header_width: f64,
    card_rects: Vec<CGRect>,
    /// The kit dialog form: one grouped card of rows (`dialogs.html` `.card2`), set by the dialog card.
    pub kit_cards: bool,
    dividers: Vec<CGRect>,
    control_frames: Vec<CGRect>,
    note_lines: BTreeMap<usize, Vec<String>>,
    fields: BTreeMap<usize, TextFieldControl>,
    scrubs: BTreeMap<String, ScrubFieldControl>,
    scrub_frames: BTreeMap<String, CGRect>,
    pressed_scrub: Option<String>,
    clicks: ClickCounter,
    /// Rows and number fields (by id) drawn dimmed that take no input. A radio option is disabled with its field's id.
    pub disabled: BTreeSet<String>,
    /// The link toggle beside two number rows.
    pub link: Option<Link>,
    /// Fixed control widths by row id (the Mac's 120 pt rate popups); other controls fill the row.
    pub control_widths: BTreeMap<String, f64>,
    /// Side padding of the rows (20; the Mac `NewProjectSheet` uses 24).
    pub side_pad: f64,
    /// Extra space before a row by row index.
    pub extra_gap_before: BTreeMap<usize, f64>,
    /// Text field heights are centered in the 28 pt row; a labeled field bleeds like the Mac frame.
    pub labeled_field_bleed: bool,
    /// The dialog text field's font: `SQTextField` is `Typography.body` (11); New Project's own fields are 12.
    pub dialog_field_font_size: f64,
    /// A labeled popup's frame bleeds 5 pt left of the control column, as on a settings page.
    pub labeled_popup_bleed: bool,
    /// Inset of the label column and the hints from their frames.
    pub label_inset: f64,
    /// Field heights by row id.
    pub field_heights: BTreeMap<String, f64>,
    /// A gray hint after a row's control by row id.
    pub hints: BTreeMap<String, String>,
    /// `.size` rows (by their width field id) laid out as the Mac `NewProjectSheet`: W, the swap button, H, no "×".
    pub swap_between: BTreeSet<String>,
    /// `.size` rows (by their width field id) without the swap button.
    pub plain_size: BTreeSet<String>,
    /// Extra per-line data of a `.listBox` by row id.
    pub list_lines: BTreeMap<String, Vec<ListLine>>,
    /// Popup extras by row id.
    pub popup_styles: BTreeMap<String, PopupStyle>,
    grids: BTreeMap<String, Vec<GridCell>>,
    inside_units: BTreeSet<String>,
    check_fields: BTreeMap<String, (NumberField, f64)>,
    /// Number fields whose value is drawn in `label` instead of accent.
    pub label_tinted: BTreeSet<String>,
    /// Status lines under rows by row id; the host replaces them and lays out again.
    pub statuses: BTreeMap<String, Status>,
    grid_title_frames: BTreeMap<String, CGRect>,
    status_frames: BTreeMap<usize, CGRect>,
    status_button_frames: BTreeMap<usize, CGRect>,
    help_tops: BTreeMap<usize, f64>,
    /// Card rows whose control sits below the text (a narrow page), by row index.
    stacked_rows: BTreeSet<usize>,
    /// Titles that wrap to several lines in a narrow column (translated text), by row index.
    title_lines: BTreeMap<usize, Vec<String>>,
    /// The width of the help under a row whose control is not part of the card row layout (a list, a button row).
    help_cols: BTreeMap<usize, f64>,
    /// The text column of a card row where it is not the plain `card_text_width` (stacked rows, a switch with a number).
    text_widths: BTreeMap<usize, f64>,
    /// The page subtitle wrapped to the page column (one line when it fits).
    subtitle_lines: Vec<String>,
    chart_parts: BTreeMap<usize, (f64, CGRect)>,
    box_editor: Option<TextEditState>,
    box_scroll: f64,
    focused_scrub: Option<String>,
    /// `.buttons` rows (by id) whose detail sits on a `fill` chip.
    pub chips: BTreeMap<String, Chip>,
    /// Help lines under a row's control by row id.
    pub helps: BTreeMap<String, String>,
    /// The row label of a check row by id.
    pub check_labels: BTreeMap<String, String>,
    placeholders: BTreeMap<String, String>,
    /// The name a screen reader gets for a row (by id) whose label is drawn empty (Find's field and popup, a radio group).
    pub a11y_labels: BTreeMap<String, String>,
    /// Popup rows (by id) that sit at the end of the field row before them.
    pub inline_popups: BTreeSet<String>,
    /// Rows that take no room and no focus (a folded "More options" section).
    pub hidden: BTreeSet<String>,
    /// A dialog's row height when it is not the 26 pt of the other dialogs (the New Project sheet: 30).
    pub dialog_row: Option<f64>,
    /// A segmented row drawn as a row of shape cards (id -> the cards); the New Project "Start from" row.
    pub shape_cards: BTreeMap<String, Vec<ShapeCard>>,
    /// A segmented row drawn as a row of color dots (id -> RGB per option); the Marker dialog's Color row.
    pub dot_rows: BTreeMap<String, Vec<u32>>,
    /// Check rows drawn as a disclosure caret with their title ("More options").
    pub disclosures: BTreeSet<String>,
    /// Popup id -> label: the popup sits on the popup row before it, behind that label ("Audio" beside "Frame rate").
    pub beside: BTreeMap<String, String>,
    /// Hints drawn as a small raised pill (the aspect next to the size fields).
    pub pill_hints: BTreeSet<String>,
    /// A leading icon inside a field row's well by id.
    pub field_icons: BTreeMap<String, SQIcon>,
    help_lines: BTreeMap<usize, Vec<String>>,
    link_frame: CGRect,
    /// Text rows drawn in the warning color.
    pub warning_notes: BTreeSet<usize>,
    /// Text rows in `bodyStrong`.
    pub strong_notes: BTreeSet<usize>,
    /// Strong rows that are the plain `SQDialog.formText(note: false)`.
    pub plain_strong_notes: BTreeSet<usize>,
    focused: Option<usize>,
    /// The focus came from the keyboard (Tab, arrows, a dialog opening): only then the ring is drawn. A mouse press clears it.
    focus_visible: bool,
    hovered: Option<usize>,
    hovered_point: Option<CGPoint>,
    dragging: Option<usize>,
    /// A single-line field pressed for text selection: the row, and the press point while the editor opened with that press.
    selecting: Option<(usize, Option<CGPoint>)>,
    label_width: f64,
    sidebar: Option<Sidebar>,
    sidebar_frames: Vec<CGRect>,
    sidebar_rule: CGRect,
    /// How far the dialog scrolled the form.
    pub sidebar_shift: f64,
    /// The sidebar column reaches this far below the rows (the dialog's footer).
    pub sidebar_extra: f64,
    /// How tall the viewport is: the sidebar column stays at the viewport top.
    pub viewport_height: f64,
    sidebar_focused: bool,
    sidebar_hovered: Option<usize>,
    /// R4e: ids whose value differs from the default (a blue dot after the title and a reset arrow), set by the owner.
    changed: BTreeSet<String>,
    reset_frames: Vec<(String, CGRect)>,
    /// R4e: how many settings each sidebar page has changed (drawn right of the page title).
    sidebar_counts: Vec<usize>,
    /// R4e: the search field above the page list; its text is reported as `("search", Text)`.
    search: Option<TextFieldControl>,
    search_frame: CGRect,
    /// R4e: popup rows drawn as picture cards (Dark / Light / System) instead of a list.
    choice_cards: BTreeSet<String>,
    /// Label and note size of a dialog form (body, 11; the New Project sheet keeps 12).
    pub dialog_font_size: Option<f64>,
    /// Unlabeled checks stay at the left edge even in a form with labeled rows.
    pub flush_checks: bool,
    /// A radio group drawn as a numbered list in a well with a check on the current row (History, art.html 32).
    pub numbered_list: bool,
    /// The number of the first row of a `numbered_list`.
    pub list_number_base: i64,
    /// Note rows that start with a small (i) icon.
    pub info_notes: BTreeSet<usize>,
    fixed_label_column: Option<f64>,
    /// art.html dialog slider rows: a fixed track width.
    pub slider_track_width: Option<f64>,
    /// Runs right after a value changed and may change other rows (a preset popup that fills two fields). The change is
    /// queued for [`DialogForm::take_changes`] first.
    pub on_change: Option<ChangeReaction>,
    popup_request: Option<PopupRequest>,
    chosen: Rc<RefCell<Vec<(usize, usize)>>>,
    changes: Vec<(String, FormValue)>,
    button_cache: BTreeMap<usize, Vec<CGRect>>,
    list_button_cache: BTreeMap<usize, Vec<CGRect>>,
    segment_cache: BTreeMap<usize, Vec<f64>>,
    started: Instant,
}

impl ShellForm {
    /// A form of `rows` (a settings form passes a `sidebar` and the `selected` page).
    pub fn new(rows: Vec<Row>) -> ShellForm {
        ShellForm::with_sidebar(rows, None, 0)
    }

    /// A settings form with a page list.
    pub fn with_sidebar(rows: Vec<Row>, sidebar: Option<Sidebar>, selected: i64) -> ShellForm {
        let mut f = ShellForm {
            rows: Vec::new(),
            values: BTreeMap::new(),
            colors: BTreeMap::new(),
            picker: None,
            picker_row: 0,
            picker_frame: CGRect::default(),
            picker_dragging: false,
            overlay_bounds: CGRect::new(0.0, 0.0, 1280.0, 800.0),
            row_frames: Vec::new(),
            control_frames: Vec::new(),
            note_lines: BTreeMap::new(),
            fields: BTreeMap::new(),
            scrubs: BTreeMap::new(),
            scrub_frames: BTreeMap::new(),
            pressed_scrub: None,
            clicks: ClickCounter::default(),
            disabled: BTreeSet::new(),
            link: None,
            control_widths: BTreeMap::new(),
            side_pad: m::SIDE_PAD,
            extra_gap_before: BTreeMap::new(),
            labeled_field_bleed: true,
            dialog_field_font_size: type_size::BODY as f64,
            labeled_popup_bleed: false,
            label_inset: 0.0,
            field_heights: BTreeMap::new(),
            hints: BTreeMap::new(),
            swap_between: BTreeSet::new(),
            plain_size: BTreeSet::new(),
            list_lines: BTreeMap::new(),
            popup_styles: BTreeMap::new(),
            grids: BTreeMap::new(),
            inside_units: BTreeSet::new(),
            check_fields: BTreeMap::new(),
            label_tinted: BTreeSet::new(),
            statuses: BTreeMap::new(),
            grid_title_frames: BTreeMap::new(),
            status_frames: BTreeMap::new(),
            status_button_frames: BTreeMap::new(),
            help_tops: BTreeMap::new(),
            stacked_rows: BTreeSet::new(),
            title_lines: BTreeMap::new(),
            help_cols: BTreeMap::new(),
            text_widths: BTreeMap::new(),
            subtitle_lines: Vec::new(),
            chart_parts: BTreeMap::new(),
            box_editor: None,
            box_scroll: 0.0,
            focused_scrub: None,
            chips: BTreeMap::new(),
            helps: BTreeMap::new(),
            check_labels: BTreeMap::new(),
            placeholders: BTreeMap::new(),
            a11y_labels: BTreeMap::new(),
            inline_popups: BTreeSet::new(),
            hidden: BTreeSet::new(),
            dialog_row: None,
            shape_cards: BTreeMap::new(),
            dot_rows: BTreeMap::new(),
            disclosures: BTreeSet::new(),
            beside: BTreeMap::new(),
            pill_hints: BTreeSet::new(),
            field_icons: BTreeMap::new(),
            help_lines: BTreeMap::new(),
            page_header: None,
            header_origin: CGPoint::ZERO,
            header_width: 0.0,
            card_rects: Vec::new(),
            kit_cards: false,
            dividers: Vec::new(),
            link_frame: CGRect::default(),
            warning_notes: BTreeSet::new(),
            strong_notes: BTreeSet::new(),
            plain_strong_notes: BTreeSet::new(),
            focused: None,
            focus_visible: false,
            hovered: None,
            hovered_point: None,
            dragging: None,
            selecting: None,
            label_width: m::LABEL_WIDTH,
            sidebar: None,
            sidebar_frames: Vec::new(),
            sidebar_rule: CGRect::default(),
            sidebar_shift: 0.0,
            sidebar_extra: 0.0,
            viewport_height: 0.0,
            sidebar_focused: false,
            sidebar_hovered: None,
            changed: BTreeSet::new(),
            reset_frames: Vec::new(),
            sidebar_counts: Vec::new(),
            search: None,
            search_frame: CGRect::default(),
            choice_cards: BTreeSet::new(),
            dialog_font_size: None,
            flush_checks: false,
            numbered_list: false,
            list_number_base: 0,
            info_notes: BTreeSet::new(),
            fixed_label_column: None,
            slider_track_width: None,
            on_change: None,
            popup_request: None,
            chosen: Rc::new(RefCell::new(Vec::new())),
            changes: Vec::new(),
            button_cache: BTreeMap::new(),
            list_button_cache: BTreeMap::new(),
            segment_cache: BTreeMap::new(),
            started: Instant::now(),
        };
        if let Some(sb) = &sidebar {
            f.values.insert(sb.id.clone(), FormValue::Index(selected));
        }
        f.sidebar = sidebar;
        for (i, r) in rows.iter().enumerate() {
            match r {
                Row::Field { id, value, .. } => {
                    f.values.insert(id.clone(), FormValue::Text(value.clone()));
                    let mut t = TextFieldControl::new(value);
                    t.alignment = Alignment::Left;
                    t.dialog_style = f.sidebar.is_none();
                    t.true_minus = f.sidebar.is_none();
                    f.fields.insert(i, t);
                }
                Row::Popup { id, selected, .. } => {
                    f.values.insert(id.clone(), FormValue::Index(*selected));
                }
                Row::Color { id, value, .. } => {
                    f.colors.insert(id.clone(), *value);
                }
                Row::Check { id, on, .. } => {
                    f.values.insert(id.clone(), FormValue::Bool(*on));
                }
                Row::Slider { id, value, .. } => {
                    f.values.insert(id.clone(), FormValue::Number(*value));
                    let mut t = TextFieldControl::new(&Self::format(*value));
                    t.alignment = Alignment::Right;
                    f.fields.insert(i, t);
                }
                Row::Radio { id, selected, .. } | Row::Segmented { id, selected, .. } => {
                    f.values.insert(id.clone(), FormValue::Index(*selected));
                }
                Row::Number { field, .. } => f.add_scrub(field),
                Row::SliderNumber { field, .. } => {
                    f.add_scrub(field);
                    // A settings page reads its value from the left edge of the well; a dialog right-aligns it.
                    if f.sidebar.is_some()
                        && let Some(s) = f.scrubs.get_mut(&field.id)
                    {
                        s.leading_text = true;
                    }
                }
                Row::Size { width, height, .. } => {
                    f.add_scrub(width);
                    f.add_scrub(height);
                }
                Row::RadioNumbers { id, selected, fields, .. } => {
                    f.values.insert(id.clone(), FormValue::Index(*selected));
                    for x in fields {
                        f.add_scrub(x);
                    }
                }
                Row::TextBox { id, value, .. } => {
                    f.values.insert(id.clone(), FormValue::Text(value.clone()));
                }
                Row::Text(_)
                | Row::Gap(_)
                | Row::Buttons { .. }
                | Row::Caption(_)
                | Row::Label { .. }
                | Row::Chart { .. }
                | Row::Picture { .. }
                | Row::ListBox { .. } => {}
            }
        }
        f.rows = rows;
        f
    }

    fn now(&self) -> f64 {
        self.started.elapsed().as_secs_f64()
    }

    pub(crate) fn notify(&mut self, id: &str, v: FormValue) {
        self.changes.push((id.to_string(), v.clone()));
        if let Some(react) = self.on_change.take() {
            react(self, id, &v);
            if self.on_change.is_none() {
                self.on_change = Some(react);
            }
        }
    }

    // MARK: Properties

    /// The rows.
    pub fn rows(&self) -> &[Row] {
        &self.rows
    }
    /// The value of every row by id.
    pub fn values(&self) -> &BTreeMap<String, FormValue> {
        &self.values
    }
    /// A picker is open.
    pub fn picker_open(&self) -> bool {
        self.picker.is_some()
    }
    /// Every row's frame (window points, set by `layout`).
    pub fn row_frames(&self) -> &[CGRect] {
        &self.row_frames
    }
    /// Every row's control frame.
    pub fn control_frames(&self) -> &[CGRect] {
        &self.control_frames
    }
    /// The number fields' boxes after layout.
    pub fn scrub_frames(&self) -> &BTreeMap<String, CGRect> {
        &self.scrub_frames
    }
    /// Number grids under rows by row id (`set_grid`).
    pub fn grids(&self) -> &BTreeMap<String, Vec<GridCell>> {
        &self.grids
    }
    /// Number fields after a check row's title by check id.
    pub fn check_fields(&self) -> &BTreeMap<String, (NumberField, f64)> {
        &self.check_fields
    }
    /// The focused row.
    pub fn focused_row(&self) -> Option<usize> {
        self.focused
    }
    /// The label column of the last layout.
    pub fn label_width(&self) -> f64 {
        self.label_width
    }
    /// The sidebar.
    pub fn sidebar(&self) -> Option<&Sidebar> {
        self.sidebar.as_ref()
    }
    /// The sidebar's page frames (window points, set by `layout`).
    pub fn sidebar_frames(&self) -> &[CGRect] {
        &self.sidebar_frames
    }
    /// The rule after the sidebar column.
    pub fn sidebar_rule_frame(&self) -> CGRect {
        self.sidebar_rule
    }
    /// The page list has the keyboard.
    pub fn sidebar_has_focus(&self) -> bool {
        self.sidebar_focused
    }
    /// The link button's frame.
    pub fn link_frame(&self) -> CGRect {
        self.link_frame
    }
    /// A number field's control.
    pub fn scrub(&self, id: &str) -> Option<&ScrubFieldControl> {
        self.scrubs.get(id)
    }
    /// Placeholder text of field rows by id.
    pub fn placeholders(&self) -> &BTreeMap<String, String> {
        &self.placeholders
    }
    /// Sets the placeholder text of field rows by id (label3 in the empty field).
    pub fn set_placeholders(&mut self, p: BTreeMap<String, String>) {
        self.placeholders = p;
        for (i, r) in self.rows.iter().enumerate() {
            if let Row::Field { id, .. } = r
                && let Some(f) = self.fields.get_mut(&i)
            {
                f.placeholder = self.placeholders.get(id).cloned().unwrap_or_default();
            }
        }
    }

    /// The Mac `NSPopUpButton` bleed exists on a settings page only; dialogs are flush (art.html).
    fn popup_bleed(&self) -> f64 {
        if self.sidebar.is_some() { m::POPUP_BLEED } else { 0.0 }
    }
    fn row_h(&self) -> f64 {
        if self.sidebar.is_none() { self.dialog_row.unwrap_or(m::DIALOG_ROW) } else { m::ROW_HEIGHT }
    }
    fn row_g(&self) -> f64 {
        if self.sidebar.is_none() { m::DIALOG_ROW_GAP } else { m::ROW_GAP }
    }
    fn label_g(&self) -> f64 {
        if self.sidebar.is_none() { m::DIALOG_LABEL_GAP } else { m::LABEL_GAP }
    }

    /// Text size: 12 in dialogs, the Mac settings `body` 11 on a settings form.
    fn font(&self) -> f64 {
        if self.sidebar.is_some() { m::SETTINGS_FONT } else { self.dialog_font_size.unwrap_or(type_size::BODY as f64) }
    }

    /// Every labeled row of a dialog puts a label column left of its control; unlabeled checks then sit in the control column.
    fn has_labeled_rows(&self) -> bool {
        self.rows.iter().any(|r| match r {
            Row::Field { label, .. }
            | Row::Popup { label, .. }
            | Row::Slider { label, .. }
            | Row::Number { label, .. }
            | Row::SliderNumber { label, .. }
            | Row::Size { label, .. }
            | Row::Segmented { label, .. }
            | Row::Color { label, .. } => !label.is_empty(),
            _ => false,
        })
    }

    /// An unlabeled check of a form with labeled rows: its box starts in the control column (art.html `.frm` checks).
    fn indented_check(&self, id: &str) -> bool {
        self.sidebar.is_none() && !self.check_labels.contains_key(id) && self.has_labeled_rows() && !self.flush_checks
    }

    fn help_line(&self) -> f64 {
        if self.sidebar.is_some() { m::SETTINGS_HELP_LINE } else { m::NOTE_LINE }
    }

    /// Segment widths: `sw` each, or (`sw` 0, the Mac `SQSegmented` default) each title at 11 pt plus 24.
    fn segment_widths(options: &[String], sw: f64, room: f64, tm: &TextMeasure) -> Vec<f64> {
        let text: Vec<f64> =
            options.iter().map(|o| tm.width(&SQL10n::string(o), type_size::BODY as f64, 0).ceil()).collect();
        let n = options.len().max(1) as f64;
        // A row wider than its column (Cover: Face, Whole Person, Skin) takes less padding per segment, 8 pt at least;
        // below that every segment shrinks in proportion and the title is clipped by its segment.
        let pad = if sw > 0.0 { 0.0 } else { ((room - 2.0 - text.iter().sum::<f64>()) / n).clamp(8.0, 24.0) };
        let widths: Vec<f64> = text.iter().map(|w| if sw > 0.0 { sw } else { w + pad }).collect();
        let total: f64 = widths.iter().sum::<f64>() + 2.0;
        if room > 0.0 && total > room {
            let k = (room - 2.0) / (total - 2.0);
            return widths.into_iter().map(|w| (w * k).floor()).collect();
        }
        widths
    }

    fn label_column(&self, tm: &TextMeasure) -> f64 {
        if self.sidebar.is_some() {
            return m::SETTINGS_LABEL_WIDTH;
        }
        if let Some(w) = self.fixed_label_column {
            return w;
        }
        let mut w = m::DIALOG_LABEL_WIDTH;
        for r in &self.rows {
            let label = match r {
                Row::Field { label, .. }
                | Row::Popup { label, .. }
                | Row::Slider { label, .. }
                | Row::Buttons { label, .. }
                | Row::Number { label, .. }
                | Row::Size { label, .. }
                | Row::Segmented { label, .. }
                | Row::ListBox { label, .. } => label,
                _ => continue,
            };
            w = w.max(tm.width(&SQL10n::string(label), self.font(), 0).ceil() + self.label_inset);
        }
        w.min(m::LABEL_MAX)
    }

    // MARK: Setup

    /// Puts a number grid under row `row_id` (`SQFormRow.row(extra: [unitGrid])`); the fields answer changes by their ids.
    pub fn set_grid(&mut self, row_id: &str, cells: Vec<GridCell>) {
        for c in &cells {
            self.add_scrub(&c.field);
        }
        self.grids.insert(row_id.to_string(), cells);
    }

    /// Puts number field `f` (`width` pt) after check `check_id`'s title, 8 apart (`SettingsWindow.checkItem` with a
    /// trailing field); it takes no input while the check is off.
    pub fn set_check_field(&mut self, check_id: &str, f: NumberField, width: f64) {
        self.add_scrub(&f);
        if self.sidebar.is_some() && !f.unit.is_empty() {
            if let Some(s) = self.scrubs.get_mut(&f.id) {
                s.unit = f.unit.clone();
            }
            self.inside_units.insert(f.id.clone());
        }
        self.check_fields.insert(check_id.to_string(), (f, width));
    }

    /// Replaces the note and bars of the `.chart` row `i` (a rerun); lay out again afterwards.
    pub fn set_chart(&mut self, i: usize, note: &str, bars: Vec<Bar>) {
        if let Some(Row::Chart { title, .. }) = self.rows.get(i) {
            let title = title.clone();
            self.rows[i] = Row::Chart { note: note.to_string(), title, bars };
        }
    }

    /// Opens the editor of text box `id` with the caret at the end (the Mac box is first responder when its dialog opens).
    pub fn begin_editing(&mut self, id: &str) {
        if let Some(i) = (0..self.rows.len()).find(|&i| self.rows[i].id() == Some(id)) {
            self.focus(i);
        }
    }

    /// The number field ids under or after row `i` (its grid, its check field).
    fn extra_scrub_ids(&self, i: usize) -> Vec<String> {
        let Some(id) = self.rows[i].id() else { return Vec::new() };
        let mut out: Vec<String> =
            self.grids.get(id).map(|g| g.iter().map(|c| c.field.id.clone()).collect()).unwrap_or_default();
        if let Some((f, _)) = self.check_fields.get(id) {
            out.push(f.id.clone());
        }
        out
    }

    /// A number field that takes no input: listed in `disabled`, or after a check that is off.
    fn scrub_off(&self, id: &str) -> bool {
        if self.disabled.contains(id) {
            return true;
        }
        if let Some(owner) = self.check_fields.iter().find(|(_, v)| v.0.id == id).map(|(k, _)| k) {
            return self.bool(owner) != Some(true);
        }
        false
    }

    /// The color of a `.color` row.
    pub fn color(&self, id: &str) -> Option<SQColorValue> {
        self.colors.get(id).copied()
    }
    /// The text under `id`.
    pub fn text(&self, id: &str) -> Option<String> {
        match self.values.get(id) {
            Some(FormValue::Text(s)) => Some(s.clone()),
            _ => None,
        }
    }
    /// The index under `id`.
    pub fn index(&self, id: &str) -> Option<i64> {
        match self.values.get(id) {
            Some(FormValue::Index(i)) => Some(*i),
            _ => None,
        }
    }
    /// The flag under `id`.
    pub fn bool(&self, id: &str) -> Option<bool> {
        match self.values.get(id) {
            Some(FormValue::Bool(b)) => Some(*b),
            _ => None,
        }
    }
    /// The number under `id` (a text value is parsed).
    pub fn number(&self, id: &str) -> Option<f64> {
        match self.values.get(id) {
            Some(FormValue::Number(d)) => Some(*d),
            Some(FormValue::Text(s)) => parse_number(s),
            _ => None,
        }
    }

    /// Sets a value from outside.
    pub fn set(&mut self, id: &str, v: FormValue) {
        self.values.insert(id.to_string(), v.clone());
        for i in 0..self.rows.len() {
            if self.rows[i].id() == Some(id) {
                if let FormValue::Text(s) = &v
                    && let Some(f) = self.fields.get_mut(&i)
                {
                    f.text = s.clone();
                }
                if let FormValue::Number(d) = &v
                    && let Some(f) = self.fields.get_mut(&i)
                {
                    f.text = Self::format(*d);
                }
            }
        }
        if let FormValue::Number(d) = v
            && let Some(s) = self.scrubs.get_mut(id)
            && !s.is_editing()
        {
            s.value = d;
        }
    }

    /// Keeps the keyboard on the page list (a settings page swapped by key).
    pub fn set_sidebar_focused(&mut self, on: bool) {
        self.sidebar_focused = on;
    }

    /// R4e: rows whose value differs from the default get the blue dot and the reset arrow.
    pub fn set_changed(&mut self, ids: BTreeSet<String>) {
        self.changed = ids;
    }

    /// R4e: the changed count per sidebar page.
    pub fn set_sidebar_counts(&mut self, counts: Vec<usize>) {
        self.sidebar_counts = counts;
    }

    /// R4e: puts the search field above the page list, holding `text`.
    pub fn enable_search(&mut self, text: &str) {
        let mut t = TextFieldControl::new(text);
        t.bare = true;
        t.alignment = sq_draw::inspector::text_field_control::Alignment::Left;
        t.font_size = m::SETTINGS_FONT;
        self.search = Some(t);
    }

    /// R4e: the search text, typed or committed.
    pub fn search_text(&self) -> String {
        self.search.as_ref().map(|s| s.editor().map_or_else(|| s.text.clone(), |e| e.string())).unwrap_or_default()
    }

    /// R4e: the search field has the keyboard.
    pub fn search_editing(&self) -> bool {
        self.search.as_ref().is_some_and(TextFieldControl::is_editing)
    }

    /// R4e: the search field's frame after layout.
    pub fn search_frame(&self) -> CGRect {
        self.search_frame
    }

    /// R4e: the reset arrows' frames by row id after layout.
    pub fn reset_frames(&self) -> &[(String, CGRect)] {
        &self.reset_frames
    }

    /// R4e: draws popup row `id` as picture cards (its options are the card titles).
    pub fn set_choice_cards(&mut self, id: &str) {
        self.choice_cards.insert(id.to_string());
    }

    /// The search field of the form this one replaces, still open with its caret and selection (`take_search_editing`).
    pub fn keep_search(&mut self, field: TextFieldControl) {
        self.search = Some(field);
    }

    /// Focus moves to the search field.
    pub fn focus_search(&mut self) {
        if let Some(s) = self.search.as_mut() {
            s.mouse_down(None, 1);
        }
    }

    /// Reports the search text when it changed.
    fn search_changed(&mut self, before: &str) {
        let now = self.search_text();
        if now != before {
            self.notify("search", FormValue::Text(now));
        }
    }

    /// Replaces the text left of a `.buttons` row's buttons (a chosen folder's path).
    pub fn set_detail(&mut self, id: &str, new_detail: &str) {
        for r in &mut self.rows {
            if let Row::Buttons { id: rid, detail, .. } = r
                && rid == id
            {
                *detail = new_detail.to_string();
            }
        }
    }

    /// Replaces the note of text row `i` (a live summary line); other rows stay as they are. Lay out again afterwards.
    pub fn set_note(&mut self, i: usize, s: &str, warning: bool, strong: bool, plain: bool) {
        if !matches!(self.rows.get(i), Some(Row::Text(_))) {
            return;
        }
        self.rows[i] = Row::Text(s.to_string());
        let flip = |set: &mut BTreeSet<usize>, on: bool| {
            if on {
                set.insert(i);
            } else {
                set.remove(&i);
            }
        };
        flip(&mut self.warning_notes, warning);
        flip(&mut self.strong_notes, strong);
        flip(&mut self.plain_strong_notes, plain);
    }

    fn format(d: f64) -> String {
        if d.round() == d && d.abs() < 9.0e18 { format!("{}", d as i64) } else { format!("{d:.2}") }
    }
}

// MARK: Layout

/// Layout-test view: `(row, what, rect, widest measured line)` per text block, and `(row, rect)` per control.
#[cfg(test)]
pub(crate) type PageRects = (Vec<(usize, &'static str, CGRect, f64)>, Vec<(usize, CGRect)>);

/// A list or button row without a title has nothing to put above its control: it never stacks.
fn title_less(r: &Row) -> bool {
    matches!(r, Row::ListBox { label, .. } | Row::Buttons { label, .. } if label.is_empty())
}

/// Whether a card row with a text column of `col` beside its control and a title `title_w` wide stacks.
fn stack_needed(col: f64, title_w: f64) -> bool {
    col < m::CARD_STACK_COL.max(title_w)
}

impl ShellForm {
    /// Height of the body for a card `width` wide.
    pub fn height_at(&mut self, width: f64, tm: &TextMeasure) -> f64 {
        self.layout_at(CGPoint::ZERO, width, tm)
    }

    /// Lays the rows out from `origin`; returns the height.
    pub fn layout_at(&mut self, origin: CGPoint, width: f64, tm: &TextMeasure) -> f64 {
        self.sync();
        let Some(sidebar) = self.sidebar.clone() else { return self.layout_rows(origin, width, tm) };
        let side = m::SIDEBAR_WIDTH;
        let search_h = if self.search.is_some() { m::SEARCH_BLOCK } else { 0.0 };
        self.search_frame = if self.search.is_some() {
            CGRect::new(origin.x + 12.0, origin.y + self.sidebar_shift + m::SIDEBAR_TOP, side - 24.0, m::SEARCH_HEIGHT)
        } else {
            CGRect::default()
        };
        self.sidebar_frames = (0..sidebar.items.len())
            .map(|i| {
                CGRect::new(
                    origin.x + m::SIDEBAR_INSET,
                    origin.y
                        + self.sidebar_shift
                        + m::SIDEBAR_TOP
                        + search_h
                        + i as f64 * (m::SIDEBAR_ROW + m::SIDEBAR_GAP),
                    side - 2.0 * m::SIDEBAR_INSET,
                    m::SIDEBAR_ROW,
                )
            })
            .collect();
        // The Mac page starts `PAGE_TOP` below the sidebar's first row (`SQFormRow.page` top inset 20 against the sidebar's 12).
        self.header_origin = CGPoint::new(origin.x + side + 1.0, origin.y);
        self.header_width = width - side - 1.0;
        // The subtitle wraps to the card column (a second line on a narrow page); the rows start below its last line.
        self.subtitle_lines = match &self.page_header {
            Some((_, sub)) => tm.lines(&SQL10n::string(sub), self.subtitle_width(), self.font()),
            None => Vec::new(),
        };
        let extra = self.subtitle_lines.len().saturating_sub(1) as f64 * m::SUBTITLE_LINE;
        let top = if self.page_header.is_some() { m::PAGE_HEADER + extra } else { m::PAGE_TOP };
        let rows_h = self.layout_rows(CGPoint::new(origin.x + side + 1.0, origin.y + top), width - side - 1.0, tm)
            + m::CARD_BOTTOM;
        let h = (rows_h + top)
            .max(self.sidebar_frames.last().map_or(origin.y, |f| f.max_y()) - origin.y - self.sidebar_shift);
        self.sidebar_rule = if self.sidebar_shift > 0.0 && self.viewport_height > 0.0 {
            CGRect::new(origin.x + side, origin.y + self.sidebar_shift, 1.0, self.viewport_height)
        } else {
            // art.html: the rule runs to the footer on short pages too.
            CGRect::new(origin.x + side, origin.y, 1.0, h.max(self.viewport_height))
        };
        h
    }

    #[allow(clippy::cognitive_complexity)]
    fn layout_rows(&mut self, origin: CGPoint, width: f64, tm: &TextMeasure) -> f64 {
        self.row_frames.clear();
        self.control_frames.clear();
        self.scrub_frames.clear();
        self.link_frame = CGRect::default();
        self.help_lines.clear();
        self.grid_title_frames.clear();
        self.status_frames.clear();
        self.status_button_frames.clear();
        self.help_tops.clear();
        self.stacked_rows.clear();
        self.title_lines.clear();
        self.help_cols.clear();
        self.text_widths.clear();
        self.chart_parts.clear();
        self.button_cache.clear();
        self.list_button_cache.clear();
        self.segment_cache.clear();
        let mut y = origin.y;
        let sidebar = self.sidebar.is_some();
        let cards = sidebar || self.kit_cards;
        self.card_rects.clear();
        self.dividers.clear();
        let (x0, inner) = if cards {
            let side = self.cpad() + self.cside();
            (origin.x + side, width - 2.0 * side)
        } else {
            (origin.x + self.side_pad, width - 2.0 * self.side_pad)
        };
        self.label_width = self.label_column(tm);
        let (row_h, row_g) = (self.row_h(), self.row_g());
        let (cx, cw) = if cards {
            // A narrow page keeps a text column for the labels: the control slot gives way (a 640 wide window left ~70 pt).
            let slot = self.cslot().min((inner - m::CARD_TEXT_MIN_COL - m::CARD_TEXT_GAP).max(m::CARD_SLOT_MIN));
            (x0 + inner - slot, slot)
        } else {
            let cx = x0 + self.label_width + self.label_g();
            (cx, origin.x + width - self.side_pad - cx)
        };
        let font = self.font();
        let mut group_top: Option<f64> = None;
        for i in 0..self.rows.len() {
            let r = self.rows[i].clone();
            if r.id().is_some_and(|id| self.hidden.contains(id)) {
                // A folded row: no room, no gap, no focus.
                self.row_frames.push(CGRect::new(origin.x, y, width, 0.0));
                self.control_frames.push(CGRect::new(cx, y, 0.0, 0.0));
                continue;
            }
            if let Row::Popup { id, .. } = &r
                && self.beside.contains_key(id)
                && i > 0
                && matches!(self.rows[i - 1], Row::Popup { .. })
                && i <= self.control_frames.len()
            {
                // On the popup row before it: [label] [popup], the label right of the first popup.
                let prev = self.control_frames[i - 1];
                let label_w = tm.width(&SQL10n::string(&self.beside[id]), font, 0).ceil();
                let pw = self.control_widths.get(id).copied().unwrap_or(120.0);
                let rf = self.row_frames[i - 1];
                self.row_frames.push(rf);
                self.control_frames.push(CGRect::new(
                    prev.max_x() + 16.0 + label_w + 8.0,
                    prev.min_y(),
                    pw,
                    prev.height,
                ));
                continue;
            }
            if let Some(iw) = self.inline_width(i, tm) {
                // On the field row before it: the field gives up the popup's width and the gap.
                let prev = self.control_frames[i - 1];
                // The popup ends at the card's inner edge; the field keeps its own bleed on the left only.
                let right = prev.max_x().min(x0 + inner);
                self.control_frames[i - 1].width = (right - iw - m::CONTROL_GAP - prev.min_x()).max(0.0);
                let rf = self.row_frames[i - 1];
                self.row_frames.push(rf);
                self.control_frames.push(CGRect::new(right - iw, prev.min_y(), iw, prev.height));
                continue;
            }
            // art.html settings Appearance group: a slider under a popup/slider sits 4 apart (tight group), not 12.
            let mut gap = row_g;
            if sidebar
                && i > 0
                && matches!(r, Row::Slider { .. })
                && matches!(self.rows[i - 1], Row::Popup { .. } | Row::Slider { .. })
            {
                gap = m::DIALOG_ROW_GAP;
            }
            // art.html: a check after a field row sits on a 26 pt line like it (pitch 30), not on the 22 pt check row (pitch 26).
            if !sidebar
                && i > 0
                && matches!(r, Row::Check { .. })
                && matches!(
                    self.rows[i - 1],
                    Row::Field { .. }
                        | Row::Popup { .. }
                        | Row::Number { .. }
                        | Row::SliderNumber { .. }
                        | Row::Slider { .. }
                        | Row::Segmented { .. }
                        | Row::Size { .. }
                )
            {
                gap += 2.0;
            }
            if sidebar && i > 0 && matches!(self.rows[i - 1], Row::Caption(_)) {
                gap = 0.0;
            }
            // the group's first row hangs under its heading
            if sidebar && i > 0 && matches!(r, Row::ListBox { .. }) && matches!(self.rows[i - 1], Row::ListBox { .. }) {
                gap = 8.0;
            }
            if cards {
                // Cards: rows touch, a hairline divides them (no gaps).
            } else if i > 0 {
                y += gap + self.extra_gap_before.get(&i).copied().unwrap_or(0.0);
            } else {
                y += self.extra_gap_before.get(&0).copied().unwrap_or(0.0);
            }
            let is_caption = matches!(r, Row::Caption(_));
            if cards && is_caption {
                if let Some(top) = group_top.take()
                    && y > top
                {
                    self.card_rects.push(CGRect::new(origin.x + self.cpad(), top, width - 2.0 * self.cpad(), y - top));
                }
            } else if cards && group_top.is_none() {
                group_top = Some(y);
            }
            let card_row = cards && self.is_card_row(&r);
            let row_top = y;
            if cards && !is_caption && !card_row {
                y += self.rpt();
            }
            let (cx, cw) = if card_row && matches!(r, Row::Slider { .. } | Row::SliderNumber { .. }) {
                let slot =
                    m::CARD_SLIDER_SLOT.min((inner - m::CARD_TEXT_MIN_COL - m::CARD_TEXT_GAP).max(m::CARD_SLOT_MIN));
                (x0 + inner - slot, slot)
            } else {
                (cx, cw)
            };
            // A narrow page: when the text column beside the control would be too narrow for the title, the row stacks. The
            // text takes the row's width on top and the control sits below it across the row (a switch keeps its place at
            // the right of the title; its number goes below).
            let inline_w = r
                .id()
                .and_then(|id| self.grids.get(id))
                .filter(|g| g.iter().all(|c| c.unit.is_empty()))
                .map_or(0.0, |g| {
                    g.iter()
                        .map(|c| tm.width(&SQL10n::string(&c.title), font, 0).ceil() + 8.0 + 48.0 + 14.0)
                        .sum::<f64>()
                });
            let is_check = matches!(r, Row::Check { .. });
            // Lists and button rows are not card rows (their control sits at the slot, their help below it) but stack alike.
            let stackable = card_row || (sidebar && matches!(r, Row::ListBox { .. } | Row::Buttons { .. }));
            let stack = stackable && !r.id().is_some_and(|id| self.choice_cards.contains(id)) && !title_less(&r) && {
                let title = match &r {
                    Row::Popup { label, .. }
                    | Row::Field { label, .. }
                    | Row::Slider { label, .. }
                    | Row::SliderNumber { label, .. }
                    | Row::Number { label, .. }
                    | Row::ListBox { label, .. }
                    | Row::Buttons { label, .. }
                    | Row::Label { label, .. } => label.as_str(),
                    Row::Check { title, .. } => title.as_str(),
                    _ => "",
                };
                // The title is drawn medium: a tenth wider than the regular face measured here.
                let title_w = (tm.width(&SQL10n::string(title), font, 0) * 1.1).ceil();
                let col = if inline_w > 0.0 {
                    inner - inline_w - 40.0
                } else if let Row::Check { id, .. } = &r {
                    self.check_fields.get(id).map_or(f64::INFINITY, |(_, fw)| {
                        inner - m::SWITCH_W - 12.0 - m::UNIT_COLUMN - fw - m::CARD_TEXT_GAP
                    })
                } else {
                    cx - m::CARD_TEXT_GAP - x0
                };
                if !stack_needed(col, title_w) {
                    if is_check && col.is_finite() {
                        // A switch with a number left of it: the text stops before the number.
                        self.text_widths.insert(i, col.min(m::CARD_HELP_W));
                    }
                    false
                } else {
                    true
                }
            };
            let (cx, cw) = if stack && !is_check { (x0, inner) } else { (cx, cw) };
            if stack {
                self.stacked_rows.insert(i);
                let text_w = if is_check { inner - m::SWITCH_W - m::CARD_TEXT_GAP } else { inner - m::RESET_BOX - 8.0 };
                self.text_widths.insert(i, text_w.max(1.0));
            }
            let mut stack_y = 0.0;
            // A stacked list or button row: its title takes a line above the control.
            let lift = if stack && !card_row { m::CARD_TITLE_LINE + m::CARD_STACK_GAP } else { 0.0 };
            y += lift;
            if !card_row && sidebar && r.id().is_some_and(|id| self.helps.get(id).is_some_and(|s| !s.is_empty())) {
                self.help_cols.insert(i, inner.min(m::CARD_HELP_W));
            }
            let scrubs_before = self.scrub_frames.clone();
            let mut h = row_h;
            let mut control = CGRect::new(cx, y, cw, h);
            match &r {
                Row::Text(s) => {
                    let indent = if self.info_notes.contains(&i) { m::INFO_INDENT } else { 0.0 };
                    let lines = tm.lines(&SQL10n::string(s), inner - indent, font);
                    let line_h = if self.strong_notes.contains(&i) { m::STRONG_LINE } else { m::NOTE_LINE };
                    h = lines.len() as f64 * line_h;
                    self.note_lines.insert(i, lines);
                    control = CGRect::new(x0, y, inner, h);
                }
                Row::Field { id, label, unit, .. } => {
                    // The Mac NSTextField's frame is `FIELD_BLEED` wider than its alignment rect on each side, so the naming
                    // field of an `SQDialog` accessory is drawn 18 pt from the card edge, not 20.
                    if label.is_empty() {
                        control = CGRect::new(x0 - m::FIELD_BLEED, y, inner + 2.0 * m::FIELD_BLEED, h);
                    }
                    if let Some(&w) = self.control_widths.get(id).filter(|&&w| !(label.is_empty() && w >= inner)) {
                        if label.is_empty() {
                            control.x = x0; // a narrower accessory field starts at the edge (no bleed)
                        }
                        control.width = w.min(if label.is_empty() { inner + 2.0 * m::FIELD_BLEED } else { cw });
                    } else if !unit.is_empty() {
                        control.width = m::UNIT_FIELD_WIDTH;
                    }
                    // The same frame bleed on a labeled row of a dialog (Color Matte's Name): wider than the control column.
                    if !label.is_empty() && unit.is_empty() && !sidebar && self.labeled_field_bleed {
                        control.x -= m::FIELD_BLEED;
                        control.width += 2.0 * m::FIELD_BLEED;
                    }
                    // The text keeps its place inside the alignment rect: 6 pt from it, so 8 from a bleeding frame.
                    let fh =
                        self.field_heights.get(id).copied().or(if !sidebar { Some(m::DIALOG_CONTROL) } else { None });
                    if let Some(fh) = fh.filter(|&fh| fh < h) {
                        control.y += ((h - fh) / 2.0).round();
                        control.height = fh;
                    }
                    let inset = if !sidebar && (label.is_empty() || !self.labeled_field_bleed || control.min_x() < cx) {
                        6.0 + m::FIELD_BLEED
                    } else {
                        6.0
                    };
                    let icon = if self.field_icons.contains_key(id) { m::FIELD_ICON_SIZE + 2.0 } else { 0.0 };
                    if let Some(f) = self.fields.get_mut(&i) {
                        f.text_inset = inset + icon;
                    }
                }
                Row::Check { id, .. } => {
                    h = if !sidebar && !self.check_labels.contains_key(id) {
                        m::DIALOG_CHECK_ROW
                    } else {
                        m::CHECK_ROW_HEIGHT
                    };
                    // A label (even an empty one) puts the box in the control column; an empty one is the 24 pt row under a
                    // labeled one (the Mac Punch In Cuts zoom levels), a real one the 28 pt `formRow`.
                    let labeled = self.check_labels.contains_key(id); // an empty label is a 26 pt line too (art.html 28: zoom pitch 30)
                    control = if labeled || self.indented_check(id) {
                        CGRect::new(cx, y + if labeled { (row_h - h) / 2.0 } else { 0.0 }, cw, h)
                    } else {
                        CGRect::new(x0, y, inner, h)
                    };
                    if labeled {
                        h = row_h;
                    }
                }
                Row::Radio { options, .. } => {
                    h = options.len() as f64 * m::CHECK_ROW_HEIGHT;
                    control = CGRect::new(x0, y, inner, h);
                    // art.html 32: a numbered list in an inset well, 8 above and below the rows.
                    if self.numbered_list {
                        control.y += m::LIST_PAD;
                        h += 2.0 * m::LIST_PAD;
                    }
                }
                Row::Gap(g) => {
                    h = *g;
                    control = CGRect::default();
                }
                Row::Number { field, .. } => {
                    if let Some(&w) = self.control_widths.get(&field.id) {
                        control.width = w; // art.html 23: Speed 87, Duration 118
                    } else if !field.unit.is_empty() {
                        control.width = m::UNIT_FIELD_WIDTH;
                    } else if self.link.as_ref().is_some_and(|l| l.fields.contains(&field.id)) {
                        control.width -= self.side_pad + m::LINK_WIDTH;
                    }
                    self.scrub_frames.insert(field.id.clone(), control);
                }
                Row::SliderNumber { field, .. } => {
                    let parts = self.slider_number_parts(control, &field.unit, tm);
                    self.scrub_frames.insert(field.id.clone(), parts.1);
                }
                Row::RadioNumbers { options, fields, .. } => {
                    h = options.len() as f64 * row_h + options.len().saturating_sub(1) as f64 * row_g;
                    control = CGRect::new(x0, y, inner, h);
                    for (n, f) in fields.iter().enumerate().filter(|(n, _)| *n < options.len()) {
                        self.scrub_frames.insert(
                            f.id.clone(),
                            CGRect::new(
                                x0 + m::RADIO_COLUMN,
                                y + n as f64 * (row_h + row_g),
                                if f.unit.is_empty() { inner - m::RADIO_COLUMN } else { m::UNIT_FIELD_WIDTH },
                                row_h,
                            ),
                        );
                    }
                }
                Row::Caption(_) if cards => {
                    // Group title above its card (`Group Title`: 22 above, 8 below).
                    let top = if i > 0 { m::GROUP_TITLE_TOP } else { 0.0 };
                    h = top + m::CAPTION_LINE + 8.0;
                    control =
                        CGRect::new(origin.x + self.cpad() + 2.0, y + top, width - 2.0 * self.cpad(), m::CAPTION_LINE);
                }
                Row::Caption(_) => {
                    let top = if sidebar && i > 0 { m::SECTION_TOP } else { m::CAPTION_TOP };
                    // art.html 36, 41: 31 pt from a section header to its first row
                    h = top + m::CAPTION_LINE + if sidebar { m::CAPTION_AFTER } else { 7.0 };
                    // `SQFormRow.caption`: at the control column on a settings page.
                    control = if sidebar {
                        CGRect::new(cx, y + top, cw, m::CAPTION_LINE)
                    } else {
                        CGRect::new(x0, y + m::CAPTION_TOP, inner, m::CAPTION_LINE)
                    };
                }
                Row::Size { width: w, height: hf, .. } if self.swap_between.contains(&w.id) => {
                    let fw = self.control_widths.get(&w.id).copied().unwrap_or(m::SIZE_FIELD);
                    control.width = 2.0 * fw + 2.0 * m::CONTROL_GAP + row_h;
                    let x = Self::size_pair_x(cards, cx, cw, control.width);
                    control.x = x;
                    self.scrub_frames.insert(w.id.clone(), CGRect::new(x, y, fw, h));
                    self.scrub_frames
                        .insert(hf.id.clone(), CGRect::new(x + fw + 2.0 * m::CONTROL_GAP + row_h, y, fw, h));
                }
                Row::Size { width: w, height: hf, .. } if self.plain_size.contains(&w.id) => {
                    let fw = self.control_widths.get(&w.id).copied().unwrap_or(m::SIZE_FIELD);
                    // art.html 25: two 75 pt boxes with the "×" tight between them, starting at the control column.
                    control.width = 2.0 * fw + 28.0;
                    let x = Self::size_pair_x(cards, cx, cw, control.width);
                    control.x = x;
                    self.scrub_frames.insert(w.id.clone(), CGRect::new(x, y, fw, h));
                    self.scrub_frames.insert(hf.id.clone(), CGRect::new(x + fw + 28.0, y, fw, h));
                }
                Row::Size { width: w, height: hf, .. } => {
                    control.width = 2.0 * m::SIZE_FIELD + m::TIMES_WIDTH + 3.0 * m::CONTROL_GAP + m::LINK_WIDTH;
                    let x = Self::size_pair_x(cards, cx, cw, control.width);
                    control.x = x;
                    self.scrub_frames.insert(w.id.clone(), CGRect::new(x, y, m::SIZE_FIELD, h));
                    self.scrub_frames.insert(
                        hf.id.clone(),
                        CGRect::new(x + m::SIZE_FIELD + 2.0 * m::CONTROL_GAP + m::TIMES_WIDTH, y, m::SIZE_FIELD, h),
                    );
                }
                Row::Segmented { id, .. } if self.shape_cards.contains_key(id) => {
                    control = CGRect::new(cx, y, cw, ShapeCard::HEIGHT);
                    h = ShapeCard::HEIGHT + ShapeCard::HINT_ROOM;
                }
                Row::Segmented { id, options, .. } if self.dot_rows.contains_key(id) => {
                    let w = DotRow::width(options.len());
                    control = CGRect::new(cx + cw - w, control.y, w, control.height);
                }
                Row::Segmented { options, segment_width, .. } => {
                    let widths = Self::segment_widths(options, *segment_width, cw, tm);
                    control.width = widths.iter().sum::<f64>() + 2.0;
                    self.segment_cache.insert(i, widths);
                }
                Row::Popup { id, label, .. } => {
                    // Unlabeled, like an unlabeled field: from the card's left edge (an `SQDialog` accessory popup).
                    // The Mac `SQDialog.popupRow` has no row padding: the row is the 22 pt popup, not a 28 pt row around it.
                    if label.is_empty() {
                        h = self.popup_styles.get(id).and_then(|s| s.height).unwrap_or(InspectorTokens::CAPSULE as f64);
                        control = CGRect::new(x0 - self.popup_bleed(), y, inner + self.popup_bleed(), h);
                        // art.html: the combo sits on a 26 pt line like the fields above it (pitch 30), not on a bare 22 pt row.
                        if !self.popup_styles.contains_key(id) && !sidebar {
                            control.y += ((row_h - h) / 2.0).round();
                            h = row_h;
                        }
                    }
                    if let Some(&w) = self.control_widths.get(id).filter(|&&w| !(label.is_empty() && w >= inner)) {
                        if label.is_empty() {
                            control.x = x0;
                        }
                        control.width = w.min(if label.is_empty() { inner + self.popup_bleed() } else { cw });
                    }
                    // A settings page's `NSPopUpButton` frame bleeds 5 pt left of the control column.
                    if (sidebar || self.labeled_popup_bleed) && !label.is_empty() {
                        control.x -= m::POPUP_BLEED;
                        control.width += m::POPUP_BLEED;
                    }
                }
                Row::Color { .. } => {}
                Row::Label { .. } => control = CGRect::new(cx, y, 0.0, h),
                Row::Chart { note, .. } => {
                    let size = type_size::BODY as f64;
                    let lines = if note.is_empty() { Vec::new() } else { tm.lines(&SQL10n::string(note), cw, size) };
                    let title_y =
                        y + lines.len() as f64 * m::NOTE_LINE + if lines.is_empty() { 0.0 } else { m::CHART_GAP };
                    self.note_lines.insert(i, lines);
                    let chart = CGRect::new(cx, title_y + m::CHART_TITLE_LINE + m::CHART_GAP, cw, m::CHART_HEIGHT);
                    self.chart_parts.insert(i, (title_y, chart));
                    h = chart.max_y() - y;
                    control = CGRect::new(cx, y, cw, h);
                }
                Row::Picture { width: pw, height: ph, .. } => {
                    // A portrait output keeps its aspect inside a 16:9 box instead of growing taller than the sheet.
                    h = (cw * (*ph).max(1) as f64 / (*pw).max(1) as f64).min(cw * 9.0 / 16.0).round()
                        + m::BAR_GAP
                        + m::BAR_HEIGHT;
                    control = CGRect::new(cx, y, cw, h);
                }
                Row::TextBox { height: bh, .. } => {
                    h = *bh;
                    control = CGRect::new(x0, y, inner, *bh);
                }
                Row::ListBox { lines, empty, .. } => {
                    // Empty: the wrapped hint, 28 pt line height at least, 12 inside the box.
                    // A stacked box spans the row: the hint wraps inside it.
                    let hint_w = if stack { cw.min(m::HELP_MAX_WIDTH) - 24.0 } else { m::HELP_MAX_WIDTH - 24.0 };
                    let hint = tm.lines(&SQL10n::string(empty), hint_w.max(1.0), font);
                    let line_h = self.list_line_h();
                    h = if lines.is_empty() {
                        line_h.max(hint.len() as f64 * m::NOTE_LINE + 12.0)
                    } else {
                        lines.len() as f64 * line_h
                    };
                    control = CGRect::new(cx, y, m::HELP_MAX_WIDTH.min(cw), h);
                    self.note_lines.insert(i, hint);
                }
                Row::Slider { .. } | Row::Buttons { .. } => {}
            }
            if let Row::Check { id, title, .. } = &r
                && let Some((cf, cfw)) = self.check_fields.get(id)
            {
                // `checkItem`: box 14, 6, the title, 8, the field on the row's 28 pt line.
                let tw = tm.width(&SQL10n::string(title), font, 0).ceil();
                self.scrub_frames.insert(
                    cf.id.clone(),
                    CGRect::new(control.min_x() + 14.0 + 6.0 + tw + m::GRID_GAP, y, *cfw, row_h),
                );
            }
            if !card_row
                && let Some(id) = r.id()
                && let Some(cells) = self.grids.get(id).filter(|c| !c.is_empty()).cloned()
            {
                let title_w =
                    cells.iter().map(|c| tm.width(&SQL10n::string(&c.title), font, 0).ceil()).fold(0.0, f64::max);
                let mut gy = y + h + m::HELP_GAP;
                for cell in &cells {
                    if sidebar {
                        // art.html settings: the title right-aligned in the label column, a 22 pt field at the control column, 26 pt pitch.
                        self.grid_title_frames.insert(
                            cell.field.id.clone(),
                            CGRect::new(x0, gy, self.label_width - self.label_inset, m::DIALOG_ROW - 4.0),
                        );
                        self.scrub_frames.insert(
                            cell.field.id.clone(),
                            CGRect::new(cx, gy, m::UNIT_FIELD_WIDTH, m::DIALOG_ROW - 4.0),
                        );
                        gy += m::DIALOG_ROW;
                        continue;
                    }
                    self.grid_title_frames.insert(cell.field.id.clone(), CGRect::new(cx, gy, title_w, row_h));
                    self.scrub_frames.insert(
                        cell.field.id.clone(),
                        CGRect::new(cx + title_w + m::GRID_GAP, gy, m::UNIT_FIELD_WIDTH, row_h),
                    );
                    gy += row_h + m::GRID_GAP;
                }
                h = gy - if sidebar { 4.0 } else { m::GRID_GAP } - y;
            }
            if let Some(id) = r.id()
                && let Some(st) = self.statuses.get(id).cloned()
            {
                // The Mac status stack is as tall as its tallest view: 14 for dot + text, 28 once a button joins them.
                let line =
                    CGRect::new(cx, y + h + m::HELP_GAP, cw, if st.button.is_some() { row_h } else { m::CAPTION_LINE });
                self.status_frames.insert(i, line);
                if let Some(b) = &st.button {
                    let tw = tm.width(&SQL10n::string(&st.text), font, 0).ceil();
                    let bw = tm.width(&SQL10n::string(b), font, 0).ceil()
                        + 2.0 * InspectorDraw::BUTTON_PADDING
                        + if st.button_icon.is_some() { 18.0 } else { 0.0 };
                    self.status_button_frames.insert(
                        i,
                        CGRect::new(cx + m::STATUS_DOT + m::GRID_GAP + tw + m::GRID_GAP, line.min_y(), bw, row_h),
                    );
                }
                h = line.max_y() - y;
            }
            if stack && matches!(r, Row::Popup { .. }) {
                // A stacked dropdown spans the row (its frame keeps the 5 pt bleed left of the text edge).
                control.width = inner + m::POPUP_BLEED;
            }
            if card_row {
                // `Row` of a card: title and help left (help 348 wide), the control right, centered on the row.
                let right = x0 + inner;
                let dx = if stack || matches!(r, Row::Slider { .. } | Row::SliderNumber { .. } | Row::Check { .. }) {
                    0.0
                } else if let Row::Number { field, .. } = &r
                    && !field.unit.is_empty()
                    && !self.inside_units.contains(&field.id)
                {
                    // The unit label follows the field: keep both inside the card (it ran past the edge under the scrollbar).
                    let unit_w = tm.width(&SQL10n::string(&field.unit), type_size::BODY as f64, 0).ceil();
                    right - control.max_x() - unit_w - m::CONTROL_GAP
                } else {
                    right - control.max_x()
                };
                if matches!(r, Row::Check { .. }) {
                    control = CGRect::new(right - m::SWITCH_W, row_top, m::SWITCH_W, m::SWITCH_H);
                }
                let beside = CGRect::new(control.min_x() + dx, control.min_y(), control.width, control.height);
                // A title wider than its column wraps (medium face: a tenth wider than measured here).
                let title = match &r {
                    Row::Popup { label, .. }
                    | Row::Field { label, .. }
                    | Row::Slider { label, .. }
                    | Row::SliderNumber { label, .. }
                    | Row::Number { label, .. }
                    | Row::Label { label, .. } => label.as_str(),
                    Row::Check { title, .. } => title.as_str(),
                    _ => "",
                };
                let title_col = self.text_col(i, x0, beside);
                let title = SQL10n::string(title);
                let mut title_h = m::CARD_TITLE_LINE;
                if !self.choice_cards.contains(r.id().unwrap_or_default())
                    && tm.width(&title, font, 0) * 1.1 > title_col
                    && title_col > 40.0
                {
                    let wrapped = tm.lines(&title, title_col / 1.1, font);
                    if wrapped.len() > 1 {
                        title_h = wrapped.len() as f64 * m::CARD_TITLE_LINE;
                        self.title_lines.insert(i, wrapped);
                    }
                }
                let lines = r
                    .id()
                    .and_then(|id| self.helps.get(id))
                    .filter(|s| !s.is_empty())
                    .map(|hp| {
                        if inline_w > 0.0 && !self.kit_cards && !stack {
                            // The help yields to the inline role fields at the right.
                            tm.lines(&SQL10n::string(hp), (inner - inline_w - 40.0).clamp(120.0, m::CARD_HELP_W), font)
                        } else if card_row && self.choice_cards.contains(r.id().unwrap_or_default()) {
                            // A picture-card row keeps its whole help, wrapped across the card (the kit's Choices row).
                            tm.lines(&SQL10n::string(hp), inner, font)
                        } else if self.kit_cards {
                            // The kit list item (`.d-list .li .s`): one line, cut with an ellipsis when drawn.
                            vec![SQL10n::string(hp)]
                        } else {
                            // Wrap to the column the drawing keeps (never under the control): a narrow window gave the
                            // text less than `CARD_HELP_W`, and every wrapped line then got its own ellipsis.
                            tm.lines(&SQL10n::string(hp), self.text_col(i, x0, beside).max(1.0), font)
                        }
                    })
                    .unwrap_or_default();
                // A number grid under a card row: all-ms cells are rows of their own below it (the help then sits under the
                // last one); role cells (no unit) sit inline at the right of the row.
                let grid = r.id().and_then(|id| self.grids.get(id)).filter(|g| !g.is_empty()).cloned();
                let stacked = grid.as_ref().is_some_and(|g| g.iter().any(|c| !c.unit.is_empty()));
                let (lines, grid_help) = if stacked { (Vec::new(), lines) } else { (lines, Vec::new()) };
                let left_h = title_h + if lines.is_empty() { 0.0 } else { 3.0 + lines.len() as f64 * self.help_line() };
                let below = if !stack {
                    0.0
                } else if is_check || inline_w > 0.0 {
                    m::CARD_STACK_GAP + m::DIALOG_CONTROL
                } else {
                    m::CARD_STACK_GAP + control.height
                };
                let content_h = if stack { left_h + below } else { left_h.max(control.height) };
                let (pad_t, pad_b, min_h) = if self.kit_cards && !lines.is_empty() {
                    (5.0, 5.0, 40.0)
                } else {
                    (self.rpt(), self.rpb(), m::CARD_MIN_ROW)
                };
                let rh = (pad_t + content_h + pad_b).max(min_h);
                stack_y = row_top + pad_t + left_h + m::CARD_STACK_GAP;
                let dy = if stack && is_check {
                    row_top + pad_t + ((m::CARD_TITLE_LINE - control.height) / 2.0).round() - control.min_y()
                } else if stack {
                    stack_y - control.min_y()
                } else {
                    row_top + ((rh - control.height) / 2.0).round() - control.min_y()
                };
                control = CGRect::new(control.min_x() + dx, control.min_y() + dy, control.width, control.height);
                let moved: Vec<(String, CGRect)> = self
                    .scrub_frames
                    .iter()
                    .filter(|(id, f)| scrubs_before.get(*id) != Some(*f))
                    .map(|(id, f)| (id.clone(), *f))
                    .collect();
                for (id, f) in moved {
                    self.scrub_frames.insert(id, CGRect::new(f.min_x() + dx, f.min_y() + dy, f.width, f.height));
                }
                if !lines.is_empty() {
                    self.help_tops.insert(i, row_top + pad_t + title_h + 3.0);
                    self.help_lines.insert(i, lines);
                }
                h = rh;
                if let Some(cells) = grid {
                    let field_h = m::DIALOG_CONTROL;
                    if stacked {
                        let cell_h = (self.rpt() + field_h + self.rpb()).max(m::CARD_MIN_ROW);
                        let unit_w = 40.0;
                        let n = cells.len();
                        for (k, cell) in cells.iter().enumerate() {
                            let top = row_top + rh + k as f64 * cell_h;
                            self.dividers.push(CGRect::new(
                                origin.x + self.cpad(),
                                top - 1.0,
                                width - 2.0 * self.cpad(),
                                1.0,
                            ));
                            let help_h = if k + 1 == n && !grid_help.is_empty() {
                                3.0 + grid_help.len() as f64 * self.help_line()
                            } else {
                                0.0
                            };
                            let row_h_k =
                                (self.rpt() + m::CARD_TITLE_LINE.max(field_h) + help_h + self.rpb()).max(cell_h);
                            let field = CGRect::new(
                                right - unit_w - m::GRID_GAP - m::UNIT_FIELD_WIDTH,
                                top + self.rpt(),
                                m::UNIT_FIELD_WIDTH,
                                field_h,
                            );
                            self.scrub_frames.insert(cell.field.id.clone(), field);
                            self.grid_title_frames.insert(
                                cell.field.id.clone(),
                                CGRect::new(
                                    x0,
                                    top + self.rpt() + ((field_h - m::CARD_TITLE_LINE) / 2.0).round(),
                                    (right - unit_w - m::GRID_GAP - m::UNIT_FIELD_WIDTH - m::CARD_TEXT_GAP - x0)
                                        .max(0.0),
                                    m::CARD_TITLE_LINE,
                                ),
                            );
                            if help_h > 0.0 {
                                // Stacked, the help sits below the field (full width), else right under the title.
                                let under = if stack {
                                    m::CARD_TITLE_LINE.max(field_h) + 3.0
                                } else {
                                    m::CARD_TITLE_LINE + 5.0
                                };
                                self.help_tops.insert(i, top + self.rpt() + under);
                            }
                            h += row_h_k.max(if k + 1 == n { row_h_k } else { cell_h });
                        }
                        if !grid_help.is_empty() {
                            self.help_lines.insert(i, grid_help);
                        }
                    } else {
                        let (gap, title_gap) = (14.0, 8.0);
                        let widths: Vec<f64> =
                            cells.iter().map(|c| tm.width(&SQL10n::string(&c.title), font, 0).ceil()).collect();
                        let n = cells.len() as f64;
                        let fixed = widths.iter().sum::<f64>() + n * title_gap + (n - 1.0).max(0.0) * gap;
                        // Stacked, the fields share what the row's width leaves (at most the usual 48).
                        let field_w = if stack { ((inner - fixed) / n).clamp(24.0, 48.0) } else { 48.0 };
                        let total = fixed + n * field_w;
                        let fy = if stack { stack_y } else { row_top + ((rh - field_h) / 2.0).round() };
                        let mut fx = if stack { x0 } else { right - total };
                        for (cell, tw) in cells.iter().zip(widths) {
                            self.grid_title_frames.insert(cell.field.id.clone(), CGRect::new(fx, fy, tw, field_h));
                            fx += tw + title_gap;
                            self.scrub_frames.insert(cell.field.id.clone(), CGRect::new(fx, fy, field_w, field_h));
                            fx += field_w + gap;
                        }
                    }
                }
            } else if let Some(id) = r.id()
                && let Some(help) = self.helps.get(id).filter(|s| !s.is_empty()).cloned()
            {
                let lines = tm.lines(
                    &SQL10n::string(&help),
                    if cards {
                        self.help_cols.get(&i).copied().unwrap_or(m::CARD_HELP_W)
                    } else {
                        cw.min(m::HELP_MAX_WIDTH)
                    },
                    font,
                );
                let top = y + h.max(control.max_y() - y) + m::HELP_GAP;
                h = top - y + lines.len() as f64 * self.help_line();
                self.help_tops.insert(i, top);
                self.help_lines.insert(i, lines);
            }
            if card_row
                && let Row::Check { id, .. } = &r
                && let Some((cf, cfw)) = self.check_fields.get(id)
            {
                // R4e: the number goes left of the switch, its unit between them.
                let frame = if stack {
                    CGRect::new(x0, stack_y, *cfw, m::DIALOG_CONTROL)
                } else {
                    CGRect::new(
                        control.min_x() - 12.0 - m::UNIT_COLUMN - cfw,
                        (control.mid_y() - m::DIALOG_CONTROL / 2.0).round(),
                        *cfw,
                        m::DIALOG_CONTROL,
                    )
                };
                let key = cf.id.clone();
                self.scrub_frames.insert(key, frame);
            }
            if card_row && r.id().is_some_and(|id| self.choice_cards.contains(id)) {
                // R4e: the title line, then the picture cards across the card (picture, radio and caption).
                let help_h = self.help_lines.get(&i).map_or(0.0, |l| 3.0 + l.len() as f64 * self.help_line());
                let top = row_top + self.rpt() + m::CARD_TITLE_LINE + help_h + 10.0;
                control = CGRect::new(x0, top, inner, m::CHOICE_PICTURE + 8.0 + 16.0);
                h = control.max_y() + self.rpb() + 6.0 - row_top;
            }
            if card_row
                && matches!(r, Row::Check { .. })
                && let Some(line) = self.status_frames.get(&i).copied()
            {
                // A switch row with a status line (Advanced > Edit API): the line sits under the title and help, in the card.
                let to = CGPoint::new(origin.x + self.cpad() + self.cside(), row_top + h - self.rpb());
                let (dx, dy) = (to.x - line.min_x(), to.y - line.min_y());
                self.status_frames
                    .insert(i, CGRect::new(line.min_x() + dx, line.min_y() + dy, line.width, line.height));
                if let Some(b) = self.status_button_frames.get_mut(&i) {
                    *b = CGRect::new(b.min_x() + dx, b.min_y() + dy, b.width, b.height);
                }
                h += line.height + m::HELP_GAP;
            }
            if !sidebar {
                // art.html `--h-c`: number boxes are 22 high, centered on their 26 pt line.
                let moved: Vec<(String, CGRect)> = self
                    .scrub_frames
                    .iter()
                    .filter(|(id, f)| scrubs_before.get(*id) != Some(*f) && f.height == row_h)
                    .map(|(id, f)| (id.clone(), *f))
                    .collect();
                for (id, f) in moved {
                    self.scrub_frames.insert(
                        id,
                        CGRect::new(
                            f.min_x(),
                            f.min_y() + ((row_h - m::DIALOG_CONTROL) / 2.0).round(),
                            f.width,
                            m::DIALOG_CONTROL,
                        ),
                    );
                }
            }
            // The buttons of a `.buttons` row and the list buttons keep their frames for later presses.
            let hh = if cards && !is_caption && !card_row { h + lift + self.rpt() + self.rpb() } else { h };
            self.row_frames.push(CGRect::new(origin.x, row_top, width, hh));
            self.control_frames.push(control);
            self.cache_button_frames(i, tm);
            y = row_top + hh;
            if cards && is_caption {
                group_top = Some(y);
            }
        }
        if cards {
            if let Some(top) = group_top
                && y > top
            {
                self.card_rects.push(CGRect::new(origin.x + self.cpad(), top, width - 2.0 * self.cpad(), y - top));
            }
            // A hairline under every row that has a row of the same card below it (a row that shares its frame with the
            // one before it is an inline popup).
            for i in 0..self.rows.len().saturating_sub(1) {
                let (a, b) = (self.row_frames[i], self.row_frames[i + 1]);
                let inline = i > 0 && self.row_frames[i - 1] == a;
                if !inline
                    && b != a
                    && !matches!(self.rows[i], Row::Caption(_))
                    && !matches!(self.rows[i + 1], Row::Caption(_))
                {
                    self.dividers.push(CGRect::new(
                        origin.x + self.cpad(),
                        a.max_y() - 1.0,
                        width - 2.0 * self.cpad(),
                        1.0,
                    ));
                }
            }
        }
        if let Some(link) = self.link.clone() {
            let boxes: Vec<CGRect> = link.fields.iter().filter_map(|f| self.scrub_frames.get(f).copied()).collect();
            let top = boxes.iter().map(|b| b.mid_y()).fold(None, |a: Option<f64>, v| Some(a.map_or(v, |a| a.min(v))));
            let bottom =
                boxes.iter().map(|b| b.mid_y()).fold(None, |a: Option<f64>, v| Some(a.map_or(v, |a| a.max(v))));
            if let (Some(top), Some(bottom)) = (top, bottom) {
                self.link_frame = CGRect::new(
                    origin.x + width - self.side_pad - m::LINK_WIDTH,
                    ((top + bottom) / 2.0 - row_h / 2.0).round(),
                    m::LINK_WIDTH,
                    row_h,
                );
                // art.html 23: in a dialog the link is a 24 pt bordered button right beside the last linked field, on its row.
                if !sidebar
                    && boxes.last().is_some()
                    && let Some(last_id) = link.fields.last()
                    && let Some(lb) = self.scrub_frames.get(last_id)
                {
                    self.link_frame = CGRect::new(
                        lb.max_x() + m::CONTROL_GAP,
                        lb.mid_y() - m::LINK_WIDTH / 2.0,
                        m::LINK_WIDTH,
                        m::LINK_WIDTH,
                    );
                }
            }
        }
        self.reset_frames = Vec::new();
        if cards {
            for i in 0..self.rows.len().min(self.control_frames.len()) {
                let Some(id) = self.rows[i].id().filter(|id| self.changed.contains(*id)) else { continue };
                let (row, c) = (self.row_frames[i], self.control_frames[i]);
                let right = x0 + inner;
                let (x, y) = if self.choice_cards.contains(id)
                    || (self.stacked_rows.contains(&i) && !matches!(self.rows[i], Row::Check { .. }))
                {
                    (right - m::RESET_BOX, row.min_y() + self.rpt() - 2.0)
                } else {
                    (c.min_x() - m::RESET_BOX - 8.0, c.mid_y() - m::RESET_BOX / 2.0)
                };
                self.reset_frames.push((id.to_string(), CGRect::new(x, y, m::RESET_BOX, m::RESET_BOX)));
            }
        }
        y - origin.y
    }

    /// Card margin, row inset, row padding and control slot: the settings page, or the kit dialog card.
    /// The width of a card row's title and help lines starting at `text_x`: at most `CARD_HELP_W`, and never under a control
    /// that sits beside the text (its frame starts right of the text); a control below the text leaves the full width.
    fn card_text_width(&self, text_x: f64, control: CGRect) -> f64 {
        if control.min_x() >= text_x + m::CARD_TEXT_MIN_BESIDE {
            (control.min_x() - m::CARD_TEXT_GAP - text_x).clamp(0.0, m::CARD_HELP_W)
        } else {
            m::CARD_HELP_W
        }
    }

    /// Layout-test view of a laid-out card page: every text block a row draws (title, help lines, grid titles) as
    /// `(row, what, rect, widest measured line)`, and every control rect as `(row, rect)`. The rects mirror the drawing:
    /// the title line at the row's top (or centered), the help lines from `help_tops`, each in the row's text column.
    #[cfg(test)]
    pub(crate) fn page_rects(&self, tm: &TextMeasure) -> PageRects {
        let font = self.font();
        let mut texts = Vec::new();
        let mut controls = Vec::new();
        for i in 0..self.rows.len().min(self.control_frames.len()) {
            let (row, ctl) = (self.row_frames[i], self.control_frames[i]);
            let x = row.min_x() + self.cpad() + self.cside();
            let card =
                self.is_card_row(&self.rows[i]) && self.rows[i].id().is_none_or(|id| !self.choice_cards.contains(id));
            let listed = matches!(self.rows[i], Row::ListBox { .. } | Row::Buttons { .. });
            let choice = self.rows[i].id().is_some_and(|id| self.choice_cards.contains(id));
            // A picture-card row wraps its help across the whole card.
            let col = if choice { row.width - 2.0 * (self.cpad() + self.cside()) } else { self.text_col(i, x, ctl) };
            if card || listed {
                let title = match &self.rows[i] {
                    Row::ListBox { label, .. } | Row::Buttons { label, .. } => label.clone(),
                    Row::Popup { label, .. }
                    | Row::Field { label, .. }
                    | Row::Slider { label, .. }
                    | Row::SliderNumber { label, .. }
                    | Row::Number { label, .. }
                    | Row::Label { label, .. } => label.clone(),
                    Row::Check { title, .. } => self
                        .check_labels
                        .get(self.rows[i].id().unwrap_or_default())
                        .cloned()
                        .unwrap_or_else(|| title.clone()),
                    _ => String::new(),
                };
                let title = SQL10n::string(&title);
                // The title is drawn medium: a tenth wider than the regular face measured here.
                let lines = self.title_lines.get(&i).cloned().unwrap_or_else(|| vec![title.clone()]);
                let need = lines.iter().map(|l| (tm.width(l, font, 0) * 1.1).ceil()).fold(0.0, f64::max);
                let has_help = self.help_lines.contains_key(&i);
                let y = if card && !has_help && !self.stacked_rows.contains(&i) && lines.len() == 1 {
                    row.min_y() + ((row.height - m::CARD_TITLE_LINE) / 2.0).round()
                } else {
                    row.min_y() + self.rpt()
                };
                if !title.is_empty() {
                    texts.push((i, "title", CGRect::new(x, y, col, lines.len() as f64 * m::CARD_TITLE_LINE), need));
                }
            }
            if let Some(lines) = self.help_lines.get(&i) {
                let hx = x;
                let top = self.help_tops.get(&i).copied().unwrap_or(ctl.max_y() + m::HELP_GAP);
                let width = self.help_cols.get(&i).copied().unwrap_or(col);
                let widest = lines.iter().map(|l| tm.width(l, font, 0)).fold(0.0, f64::max);
                texts.push((i, "help", CGRect::new(hx, top, width, lines.len() as f64 * self.help_line()), widest));
            }
            if ctl.width > 0.0
                && ctl.height > 0.0
                && !matches!(self.rows[i], Row::Text(_) | Row::Caption(_) | Row::Label { .. })
            {
                controls.push((i, ctl));
            }
        }
        for (id, tr) in &self.grid_title_frames {
            let Some(cell) = self.grids.values().flatten().find(|c| &c.field.id == id) else { continue };
            let title = SQL10n::string(&cell.title);
            let need = tm.width(&title, font, 0).ceil();
            texts.push((usize::MAX, "grid title", *tr, need));
        }
        controls.extend(self.scrub_frames.values().filter(|f| f.width > 0.0).map(|f| (usize::MAX, *f)));
        controls.extend(self.reset_frames.iter().map(|(_, f)| (usize::MAX, *f)));
        (texts, controls)
    }

    /// How many card rows stacked their control below the text (layout tests).
    #[cfg(test)]
    pub(crate) fn stacked_row_count(&self) -> usize {
        self.stacked_rows.len()
    }

    /// The wrapped page subtitle lines (layout tests).
    #[cfg(test)]
    pub(crate) fn subtitle_line_count(&self) -> usize {
        self.subtitle_lines.len()
    }

    /// The width a page subtitle may use: the card column, at most 560.
    fn subtitle_width(&self) -> f64 {
        (self.header_width - 2.0 * (self.cpad() + self.cside())).clamp(1.0, 560.0)
    }

    /// The text column of card row `i` whose text starts at `text_x`, `control` being its control.
    fn text_col(&self, i: usize, text_x: f64, control: CGRect) -> f64 {
        self.text_widths.get(&i).copied().unwrap_or_else(|| self.card_text_width(text_x, control))
    }

    /// The width of the widest wrapped help line of row `row` (0 without help): layout tests check it against the text column.
    pub fn widest_help_line(&self, row: usize, tm: &TextMeasure) -> f64 {
        let font = self.font();
        self.help_lines.get(&row).map_or(0.0, |l| l.iter().map(|s| tm.width(s, font, 0)).fold(0.0, f64::max))
    }

    /// Every card row's text column (title and help) as drawn, with the row's index: the rects a control must not cover.
    pub fn card_text_rects(&self) -> Vec<(usize, CGRect)> {
        let x = |row: CGRect| row.min_x() + self.cpad() + self.cside();
        (0..self.rows.len())
            .filter(|&i| i < self.control_frames.len() && self.is_card_row(&self.rows[i]))
            .filter(|&i| self.rows[i].id().is_none_or(|id| !self.choice_cards.contains(id)))
            .map(|i| {
                let (row, ctl) = (self.row_frames[i], self.control_frames[i]);
                (i, CGRect::new(x(row), row.min_y(), self.text_col(i, x(row), ctl), row.height))
            })
            .collect()
    }

    fn cpad(&self) -> f64 {
        if self.kit_cards { 20.0 } else { m::CARD_PAD }
    }
    fn cside(&self) -> f64 {
        if self.kit_cards { 12.0 } else { m::CARD_SIDE }
    }
    fn rpt(&self) -> f64 {
        if self.kit_cards { 9.0 } else { m::ROW_PAD_TOP }
    }
    fn rpb(&self) -> f64 {
        if self.kit_cards { 9.0 } else { m::ROW_PAD_BOTTOM }
    }
    fn cslot(&self) -> f64 {
        if self.kit_cards { 150.0 } else { m::CARD_SLOT }
    }

    /// A settings row that takes the card layout: title and help left, the control right.
    fn is_card_row(&self, r: &Row) -> bool {
        let plain = r.id().is_none_or(|id| {
            (self.grids.get(id).is_none_or(|g| g.is_empty())
                || (self.sidebar.is_some() && matches!(r, Row::Popup { .. } | Row::Label { .. })))
                && (!self.statuses.contains_key(id) || matches!(r, Row::Check { .. }))
                && (!self.check_fields.contains_key(id) || matches!(r, Row::Check { .. }))
        });
        plain
            && match r {
                Row::Popup { label, .. } | Row::Field { label, .. } => !label.is_empty(),
                Row::Check { .. } | Row::Slider { .. } | Row::SliderNumber { .. } | Row::Number { .. } => true,
                Row::Label { id, .. } => self.sidebar.is_some() && self.grids.get(id).is_some_and(|g| !g.is_empty()),
                _ => false,
            }
    }

    /// The width of popup row `i` when it sits on the field row before it (`inline_popups`): `control_widths` or the Mac
    /// `SQPopup.intrinsicContentSize` (title inset 10, widest option in body size, chevron gap 8 + 7 + inset 7).
    fn inline_width(&self, i: usize, tm: &TextMeasure) -> Option<f64> {
        if i == 0 || i > self.control_frames.len() {
            return None;
        }
        let Row::Popup { id, options, .. } = &self.rows[i] else { return None };
        if !self.inline_popups.contains(id) || !matches!(self.rows[i - 1], Row::Field { .. }) {
            return None;
        }
        if let Some(&w) = self.control_widths.get(id) {
            return Some(w);
        }
        let widest =
            options.iter().map(|o| tm.width(&SQL10n::string(o), type_size::BODY as f64, 0)).fold(0.0, f64::max);
        Some((10.0 + widest + 8.0 + 7.0 + 7.0).ceil())
    }

    fn slider_field(&self) -> f64 {
        if self.sidebar.is_none() { m::DIALOG_SLIDER_FIELD } else { m::SLIDER_FIELD_WIDTH }
    }

    const FIXED_SLIDER_FIELD: f64 = 64.0;

    /// `NumericSlider.layout` with `unitOutside`: the unit column (24 at least) at the right, `CONTROL_GAP`, the 72 field,
    /// 12, the slider in the rest. Returns (track, field).
    fn slider_number_parts(&self, c: CGRect, unit: &str, tm: &TextMeasure) -> (CGRect, CGRect) {
        if self.sidebar.is_none()
            && let Some(tw) = self.slider_track_width
        {
            let track = CGRect::new(c.min_x(), c.min_y(), tw, c.height);
            return (track, CGRect::new(track.max_x() + 12.0, c.min_y(), Self::FIXED_SLIDER_FIELD, c.height));
        }
        let uw = m::UNIT_COLUMN.max(tm.width(&SQL10n::string(unit), self.font(), 0).ceil());
        let field = CGRect::new(
            c.max_x() - uw - m::CONTROL_GAP - self.slider_field(),
            c.min_y(),
            self.slider_field(),
            c.height,
        );
        (CGRect::new(c.min_x(), c.min_y(), (field.min_x() - 12.0 - c.min_x()).max(0.0), c.height), field)
    }

    /// A picture row's parts: the picture box, the play button, the scrub bar and the timecode column.
    fn picture_parts(&self, i: usize) -> (CGRect, CGRect, CGRect, CGRect) {
        let f = self.control_frames[i];
        let boxed = CGRect::new(f.min_x(), f.min_y(), f.width, (f.height - m::BAR_GAP - m::BAR_HEIGHT).max(0.0));
        let y = boxed.max_y() + m::BAR_GAP;
        let play = CGRect::new(f.min_x(), y, m::BAR_PLAY, m::BAR_HEIGHT);
        let bar_x = f.min_x() + m::BAR_PLAY + 8.0;
        let tc = CGRect::new(f.max_x() - m::BAR_TIMECODE, y, m::BAR_TIMECODE, m::BAR_HEIGHT);
        let bar = CGRect::new(bar_x, y, (tc.min_x() - 8.0 - bar_x).max(0.0), m::BAR_HEIGHT);
        (boxed, play, bar, tc)
    }

    fn transport(&self, i: usize) -> Option<&PreviewTransport> {
        match self.rows.get(i) {
            Some(Row::Picture { transport, .. }) => Some(transport),
            _ => None,
        }
    }

    fn transport_mut(&mut self) -> Option<&mut PreviewTransport> {
        self.rows.iter_mut().find_map(|r| match r {
            Row::Picture { transport, .. } => Some(transport),
            _ => None,
        })
    }

    /// The bar's 0...1 position under `x` (the knob travels inside an 8 pt inset).
    fn picture_fraction(&self, i: usize, x: f64) -> f64 {
        let bar = self.picture_parts(i).2;
        ((x - bar.min_x() - m::BAR_INSET) / (bar.width - 2.0 * m::BAR_INSET).max(1.0)).clamp(0.0, 1.0)
    }

    /// Play or pause (a click on the button or the picture, Space).
    fn picture_toggle(&mut self) {
        let Some(t) = self.transport_mut().filter(|t| t.frames > 0) else { return };
        t.playing = !t.playing;
        let on = t.playing;
        self.notify("preview_play", FormValue::Bool(on));
    }

    /// A scrub to `fraction`: stops playing like the Mac bar.
    fn picture_scrub(&mut self, fraction: f64) {
        let Some(t) = self.transport_mut().filter(|t| t.frames > 0) else { return };
        (t.fraction, t.playing) = (fraction, false);
        self.notify("preview_scrub", FormValue::Number(fraction));
    }

    /// Space plays, the arrows step a frame (`ExportDialogView.keyDown`); true when the key was used.
    fn picture_key(&mut self, k: InputKey) -> bool {
        if self.transport_mut().is_none() {
            return false;
        }
        match k {
            InputKey::Space => self.picture_toggle(),
            InputKey::Left | InputKey::Right => {
                if self.transport_mut().is_some_and(|t| t.frames > 0) {
                    self.notify("preview_step", FormValue::Index(if k == InputKey::Left { -1 } else { 1 }));
                }
            }
            _ => return false,
        }
        true
    }

    fn slider_parts(&self, i: usize) -> (CGRect, CGRect) {
        let c = self.control_frames[i];
        if self.sidebar.is_none()
            && let Some(tw) = self.slider_track_width
        {
            let track = CGRect::new(c.min_x(), c.min_y(), tw, c.height);
            return (track, CGRect::new(track.max_x() + 12.0, c.min_y(), Self::FIXED_SLIDER_FIELD, c.height));
        }
        let field = CGRect::new(c.max_x() - self.slider_field(), c.min_y(), self.slider_field(), c.height);
        if self.sidebar.is_some() {
            // Kit `Settings/Slider`: a 200 wide track, 12 before the number field, flush right.
            return (
                CGRect::new(field.min_x() - 12.0 - m::SETTINGS_TRACK, c.min_y(), m::SETTINGS_TRACK, c.height),
                field,
            );
        }
        (CGRect::new(c.min_x(), c.min_y(), field.min_x() - 12.0 - c.min_x(), c.height), field)
    }

    /// The buttons of a `.buttons` row, right aligned in its control frame (`TextFieldControl.button` widths, 64 at least),
    /// and the list buttons of a `.listBox` row, kept for the presses after this layout.
    fn cache_button_frames(&mut self, i: usize, tm: &TextMeasure) {
        let font = self.font();
        let c = self.control_frames[i];
        match self.rows[i].clone() {
            Row::Buttons { id, titles, .. } => {
                let mut right = c.max_x();
                let mut out: Vec<CGRect> = Vec::new();
                for t in titles.iter().rev() {
                    let w = self.chips.get(&id).map(|c| c.button_width).unwrap_or_else(|| {
                        (tm.width(&SQL10n::string(t), font, 0).ceil() + 2.0 * m::BUTTON_PADDING).max(m::MIN_BUTTON)
                    });
                    right -= w;
                    out.insert(0, CGRect::new(right, c.min_y(), w, c.height));
                    right -= m::CONTROL_GAP;
                }
                self.button_cache.insert(i, out);
            }
            Row::ListBox { lines, button, .. } => {
                let w =
                    (tm.width(&SQL10n::string(&button), font, 0).ceil() + 2.0 * m::BUTTON_PADDING).max(m::MIN_BUTTON);
                let line_h = self.list_line_h();
                let frames = (0..lines.len())
                    .map(|n| CGRect::new(c.max_x() - 12.0 - w, c.min_y() + n as f64 * line_h, w, line_h))
                    .collect();
                self.list_button_cache.insert(i, frames);
            }
            _ => {}
        }
    }

    fn button_frames(&self, i: usize) -> &[CGRect] {
        self.button_cache.get(&i).map_or(&[], Vec::as_slice)
    }

    fn list_button_frames(&self, i: usize) -> &[CGRect] {
        self.list_button_cache.get(&i).map_or(&[], Vec::as_slice)
    }

    /// One line of a `.listBox`: art.html `.boxlist .row` is 24 on a settings page (blocks 32 apart), else the form row.
    fn list_line_h(&self) -> f64 {
        if self.sidebar.is_some() { 24.0 } else { self.row_h() }
    }

    fn button_enabled(&self, i: usize, n: usize) -> bool {
        let Row::Buttons { enabled, .. } = &self.rows[i] else { return false };
        enabled.get(n).copied().unwrap_or(true)
    }

    fn press_button(&mut self, i: usize, n: usize) {
        let Some(id) = self.rows[i].id().map(str::to_string) else { return };
        if !self.button_enabled(i, n) {
            return;
        }
        self.notify(&id, FormValue::Index(n as i64));
    }

    /// The text area of a `.textBox` row (6 pt in, scrolled so the caret line shows).
    fn box_text(&self, i: usize) -> CGRect {
        let r = self.control_frames[i].inset_by(m::BOX_INSET, m::BOX_INSET);
        CGRect::new(r.x, r.y - self.box_scroll, r.width, r.height)
    }

    fn field_box(&self, i: usize) -> CGRect {
        if let Row::Slider { .. } = self.rows[i] {
            return self.slider_parts(i).1;
        }
        self.control_frames[i]
    }

    // MARK: Focus (Tab order: fields, popups, checks, sliders, radios)

    fn focusable(&self) -> Vec<usize> {
        (0..self.rows.len())
            .filter(|&i| {
                if matches!(
                    self.rows[i],
                    Row::Text(_)
                        | Row::Gap(_)
                        | Row::Caption(_)
                        | Row::Label { .. }
                        | Row::Chart { .. }
                        | Row::Picture { .. }
                ) {
                    return false;
                }
                self.rows[i].id().is_none_or(|id| !self.disabled.contains(id) && !self.hidden.contains(id))
            })
            .collect()
    }

    /// Tab / Shift-Tab: commits an open field and moves on. False at the ends (the dialog's buttons take it).
    pub fn move_focus(&mut self, forward: bool) -> bool {
        self.commit_editing_inner();
        if self.sidebar.is_some() {
            // The page list is the stop before the first row.
            if self.sidebar_focused {
                self.sidebar_focused = false;
                if !forward {
                    return false;
                }
            } else if self.focused.is_none() && forward {
                self.sidebar_focused = true;
                return true;
            } else if !forward && self.focused.is_some() && self.focusable().first().copied() == self.focused {
                self.focused = None;
                self.sidebar_focused = true;
                return true;
            }
        }
        let order = self.focusable();
        if order.is_empty() {
            return false;
        }
        let at = self.focused.and_then(|f| order.iter().position(|&o| o == f));
        let next: i64 = match at {
            Some(a) => a as i64 + if forward { 1 } else { -1 },
            None => {
                if forward {
                    0
                } else {
                    order.len() as i64 - 1
                }
            }
        };
        if next < 0 || next as usize >= order.len() {
            self.focused = None;
            return false;
        }
        self.focus(order[next as usize]);
        true
    }

    /// A dialog opens with its first editable field focused and its text selected, so typing replaces it and Return
    /// answers (the Mac accessory field is first responder; art.html 10, 15, 17, 36). The field is a text field or a
    /// number field (Speed, Volume), whichever row comes first. False when the form has none or a settings page
    /// (sidebar) is shown.
    pub fn focus_first_text_field_row(&mut self) -> bool {
        if self.sidebar.is_some() || self.focused.is_some() {
            return false;
        }
        let Some(first) = self.focusable().into_iter().find(|&i| self.opens_with_focus(i)) else { return false };
        self.focus(first);
        if let Some(id) = self.scrub_id(first)
            && let Some(s) = self.scrubs.get_mut(&id)
        {
            s.begin_editing();
        }
        true
    }

    /// A text field or an enabled number field: what a dialog puts the keyboard in when it opens.
    fn opens_with_focus(&self, i: usize) -> bool {
        match &self.rows[i] {
            Row::Field { .. } => self.fields.contains_key(&i),
            Row::Number { field, .. } | Row::SliderNumber { field, .. } => {
                self.scrubs.contains_key(&field.id) && !self.scrub_off(&field.id)
            }
            _ => false,
        }
    }

    /// The control rect of a Settings dropdown inside its row slot `boxed`: 180 wide, flush right.
    pub(crate) fn sidebar_popup_rect(boxed: CGRect) -> CGRect {
        let wide = boxed.width.min(m::CARD_SLOT);
        CGRect::new(boxed.max_x() - wide, boxed.min_y(), wide, boxed.height)
    }

    fn focus(&mut self, i: usize) {
        self.sidebar_focused = false;
        self.focused = Some(i);
        self.focus_visible = true;
        self.focused_scrub = None;
        if let Some(f) = self.fields.get_mut(&i) {
            f.mouse_down(None, 1);
        }
        if let Row::TextBox { id, .. } = &self.rows[i]
            && self.box_editor.is_none()
        {
            self.box_editor = Some(TextEditState::with_select_all(&self.text(id).unwrap_or_default(), false));
        }
    }

    /// Whether a text field, number field or box editor is open.
    pub fn is_editing(&self) -> bool {
        self.fields.values().any(TextFieldControl::is_editing)
            || self.scrubs.values().any(ScrubFieldControl::is_editing)
            || self.box_editor.is_some()
    }

    /// Drops the focus ring and the open editors (the shot harness shows dialogs unfocused, as the offscreen Mac window is).
    pub fn blur(&mut self) {
        self.commit_editing_inner();
        self.focused = None;
        self.focused_scrub = None;
        self.sidebar_focused = false;
    }

    fn commit_editing_inner(&mut self) {
        let editing: Vec<usize> = self.fields.iter().filter(|(_, f)| f.is_editing()).map(|(i, _)| *i).collect();
        for i in editing {
            if let Some(s) = self.fields.get_mut(&i).and_then(TextFieldControl::commit) {
                self.field_committed(i, &s);
            }
        }
        let scrubbing: Vec<String> =
            self.scrubs.iter().filter(|(_, s)| s.is_editing()).map(|(k, _)| k.clone()).collect();
        for id in scrubbing {
            self.scrub_events(&id, ScrubFieldControl::commit_editing);
        }
        self.box_editor = None;
    }

    fn field_committed(&mut self, i: usize, s: &str) {
        let Some(id) = self.rows[i].id().map(str::to_string) else { return };
        if let Row::Slider { range, .. } = &self.rows[i] {
            let range = range.clone();
            let d = parse_number(s).map(|v| v.max(*range.start()).min(*range.end()));
            let v = d.or_else(|| self.number(&id)).unwrap_or(*range.start());
            self.set(&id, FormValue::Number(v));
            self.notify(&id, FormValue::Number(v));
        } else {
            self.values.insert(id.clone(), FormValue::Text(s.to_string()));
            self.notify(&id, FormValue::Text(s.to_string()));
        }
    }

    /// Picks sidebar page `n` (a click on it).
    pub fn select_page(&mut self, n: usize) {
        let Some(sb) = self.sidebar.clone() else { return };
        if n >= sb.items.len() {
            return;
        }
        self.commit_editing_inner();
        self.values.insert(sb.id.clone(), FormValue::Index(n as i64));
        self.notify(&sb.id, FormValue::Index(n as i64));
    }

    /// A popup row's option was chosen.
    pub fn choose(&mut self, row: usize, option: usize) {
        let Some(id) = self.rows[row].id().map(str::to_string) else { return };
        self.values.insert(id.clone(), FormValue::Index(option as i64));
        self.notify(&id, FormValue::Index(option as i64));
    }

    fn toggle(&mut self, i: usize) {
        let Row::Check { id, .. } = &self.rows[i] else { return };
        let id = id.clone();
        let v = FormValue::Bool(!self.bool(&id).unwrap_or(false));
        self.values.insert(id.clone(), v.clone());
        self.notify(&id, v);
    }

    /// Applies the popup options the menu picked since the last call.
    fn sync(&mut self) {
        let picked: Vec<(usize, usize)> = self.chosen.borrow_mut().drain(..).collect();
        for (row, option) in picked {
            if row < self.rows.len() {
                self.choose(row, option);
            }
        }
    }
}

// MARK: Events (window points)

impl ShellForm {
    fn canvas<'a>(tm: &TextMeasure<'a>) -> Canvas<'a> {
        Canvas::with_size(0.0, 0.0, tm.atlas, tm.scale)
    }

    /// A key while the form has focus. True when the form used it (Enter and Esc go to the dialog unless a field is open).
    pub fn key_event(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx) -> bool {
        self.sync();
        if self.search_editing() && k != InputKey::Character('\t') {
            let before = self.search_text();
            if k == InputKey::Escape {
                if let Some(s) = self.search.as_mut() {
                    s.cancel();
                    s.text.clear();
                }
            } else if k == InputKey::Enter {
                if let Some(s) = self.search.as_mut() {
                    let _ = s.commit();
                }
            } else if let Some(s) = self.search.as_mut() {
                let _ = s.key(k, m, cx);
            }
            self.search_changed(&before);
            return true;
        }
        if k == InputKey::Character('\t') {
            return self.move_focus(!m.contains(InputModifiers::SHIFT));
        }
        if self.sidebar_focused
            && let Some(sidebar) = self.sidebar.clone()
        {
            if k != InputKey::Up && k != InputKey::Down {
                return false;
            }
            let now = self.index(&sidebar.id).unwrap_or(0);
            let n = (now + if k == InputKey::Down { 1 } else { -1 }).max(0).min(sidebar.items.len() as i64 - 1);
            if n != now {
                self.select_page(n as usize);
            }
            return true;
        }
        let Some(f) = self.focused else { return self.picture_key(k) };
        if matches!(self.rows[f], Row::Picture { .. }) {
            return self.picture_key(k);
        }
        if let Row::TextBox { id, .. } = self.rows[f].clone() {
            if k == InputKey::Escape {
                return false;
            }
            if self.box_editor.is_none() {
                self.box_editor = Some(TextEditState::with_select_all(&self.text(&id).unwrap_or_default(), false));
            }
            let edited = self.box_editor.as_mut().map(|e| e.handle_lines(k, m, cx)) == Some(EditOutcome::Edited);
            if edited && let Some(s) = self.box_editor.as_ref().map(TextEditState::string) {
                self.values.insert(id.clone(), FormValue::Text(s.clone()));
                self.notify(&id, FormValue::Text(s));
            }
            return true;
        }
        if let Some(used) = self.scrub_key(f, k, m, cx) {
            return used;
        }
        if self.fields.get(&f).is_some_and(TextFieldControl::is_editing) {
            if k == InputKey::Enter {
                self.commit_editing_inner();
                return false; // Return also presses the default button (Mac field)
            }
            if k == InputKey::Escape {
                // Esc undoes a changed edit; with nothing changed it is the dialog's (Cancel), as in the Mac sheet.
                let mut undone = false;
                if let Some(t) = self.fields.get_mut(&f) {
                    undone = t.editor().is_some_and(|e| e.string() != t.text);
                    t.cancel();
                }
                return undone;
            }
            let committed = self.fields.get_mut(&f).and_then(|t| t.key(k, m, cx));
            if let Some(s) = committed {
                self.field_committed(f, &s);
            }
            return true;
        }
        match self.rows[f].clone() {
            Row::Check { .. } if k == InputKey::Space => {
                self.toggle(f);
                true
            }
            Row::Popup { options, .. } if k == InputKey::Space || k == InputKey::Down || k == InputKey::Up => {
                if k == InputKey::Space {
                    self.open(f);
                } else {
                    self.step(f, if k == InputKey::Down { 1 } else { -1 }, options.len());
                }
                true
            }
            Row::Radio { options, .. }
                if matches!(k, InputKey::Down | InputKey::Up | InputKey::Left | InputKey::Right) =>
            {
                self.step(f, if k == InputKey::Down || k == InputKey::Right { 1 } else { -1 }, options.len());
                true
            }
            Row::RadioNumbers { options, .. } if k == InputKey::Down || k == InputKey::Up => {
                self.step_radio(f, if k == InputKey::Down { 1 } else { -1 }, options.len() as i64);
                true
            }
            Row::Segmented { options, .. } if k == InputKey::Left || k == InputKey::Right => {
                self.step(f, if k == InputKey::Right { 1 } else { -1 }, options.len());
                true
            }
            Row::Buttons { titles, .. } if k == InputKey::Space || k == InputKey::Enter => {
                if let Some(n) = (0..titles.len()).find(|&n| self.button_enabled(f, n)) {
                    self.press_button(f, n);
                }
                true
            }
            Row::Slider { id, range, .. } if k == InputKey::Left || k == InputKey::Right => {
                let step_size =
                    (*range.end() - *range.start()) / if m.contains(InputModifiers::SHIFT) { 10.0 } else { 100.0 };
                let v = (self.number(&id).unwrap_or(0.0) + if k == InputKey::Right { step_size } else { -step_size })
                    .max(*range.start())
                    .min(*range.end());
                self.set(&id, FormValue::Number(v));
                self.notify(&id, FormValue::Number(v));
                true
            }
            _ => false,
        }
    }

    fn step(&mut self, i: usize, d: i64, count: usize) {
        let Some(id) = self.rows[i].id().map(str::to_string) else { return };
        if count == 0 {
            return;
        }
        let to = (self.index(&id).unwrap_or(0) + d).clamp(0, count as i64 - 1);
        self.choose(i, to as usize);
    }

    /// Up/Down in a number radio group: the next option that is not disabled.
    fn step_radio(&mut self, i: usize, d: i64, count: i64) {
        let Row::RadioNumbers { id, fields, .. } = self.rows[i].clone() else { return };
        let mut n = self.index(&id).unwrap_or(0) + d;
        while (0..count).contains(&n) && fields.get(n as usize).is_some_and(|f| self.disabled.contains(&f.id)) {
            n += d;
        }
        if !(0..count).contains(&n) {
            return;
        }
        self.values.insert(id.clone(), FormValue::Index(n));
        self.notify(&id, FormValue::Index(n));
    }

    // MARK: Color picker popover

    fn open_picker(&mut self, i: usize, id: &str) {
        let p = ColorPickerControl::new(
            self.colors.get(id).copied().unwrap_or(SQColorValue::new(0.0, 0.0, 0.0, 1.0)),
            false,
            false,
            Vec::new(),
        );
        self.picker_frame = p.frame(self.control_frames[i], self.overlay_bounds);
        self.picker = Some(p);
        self.picker_row = i;
        self.picker_dragging = false;
    }

    fn close_picker(&mut self) {
        self.picker = None;
        self.picker_dragging = false;
    }

    fn picker_changed(&mut self, p: ColorPickerControl) {
        let value = p.value;
        self.picker = Some(p);
        let Some(Row::Color { id, .. }) = self.rows.get(self.picker_row) else { return };
        let id = id.clone();
        self.colors.insert(id.clone(), value);
        self.notify(&id, FormValue::Text(value.hex()));
    }

    fn picker_local(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x - self.picker_frame.min_x(), p.y - self.picker_frame.min_y())
    }

    /// Routes a pointer press while the picker is open: inside it drives the picker, outside closes it (taken).
    pub fn picker_press(&mut self, p: CGPoint) {
        let Some(mut pk) = self.picker.take() else { return };
        let q = self.picker_local(p);
        if !CGRect::new(0.0, 0.0, self.picker_frame.width, self.picker_frame.height).contains(q) {
            self.close_picker();
            return;
        }
        self.picker_dragging = true;
        if pk.mouse_down(q) == PickerOutcome::Changed {
            self.picker_changed(pk);
        } else {
            self.picker = Some(pk);
        }
    }

    /// A drag while the picker is open.
    pub fn picker_drag(&mut self, p: CGPoint) {
        if !self.picker_dragging {
            return;
        }
        let Some(mut pk) = self.picker.take() else { return };
        if pk.mouse_dragged(self.picker_local(p)) == PickerOutcome::Changed {
            self.picker_changed(pk);
        } else {
            self.picker = Some(pk);
        }
    }

    /// A release while the picker is open.
    pub fn picker_release(&mut self) {
        if let Some(pk) = self.picker.as_mut() {
            pk.mouse_up();
        }
        self.picker_dragging = false;
    }

    /// A key while the picker is open: the hex field and Esc (closes). Always taken.
    pub fn picker_press_key(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx) {
        let Some(mut pk) = self.picker.take() else { return };
        let (taken, outcome) = pk.key(k, m, cx);
        if outcome == PickerOutcome::Changed {
            self.picker_changed(pk);
        } else {
            self.picker = Some(pk);
        }
        if !taken && (k == InputKey::Escape || k == InputKey::Enter) {
            self.close_picker();
        }
    }

    /// The popover above everything else (call outside the form's clip).
    pub fn draw_picker(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        let Some(pk) = &self.picker else { return };
        c.save_gstate();
        c.translate_by(self.picker_frame.min_x(), self.picker_frame.min_y());
        pk.draw(c, t, cx);
        c.restore_gstate();
    }

    fn open(&mut self, i: usize) {
        let Row::Popup { id, options, .. } = self.rows[i].clone() else { return };
        let style = self.popup_styles.get(&id).cloned();
        let selected = self.index(&id).unwrap_or(-1);
        let mut items: Vec<SQMenuItem> = Vec::new();
        for (n, title) in options.iter().enumerate() {
            if style.as_ref().is_some_and(|s| s.separator_before.contains(&n)) {
                items.push(SQMenuItem::separator());
            }
            if let Some(h) = style.as_ref().and_then(|s| s.headers.get(&n)) {
                items.push(SQMenuItem::header(h));
            }
            let key = style.as_ref().and_then(|s| s.keys.get(n).cloned()).unwrap_or_default();
            let dot =
                style.as_ref().and_then(|s| s.dots.get(n).map(|d| SQMenuIcon::Swatch(*d))).unwrap_or(SQMenuIcon::None);
            let mut item = SQMenuItem::new(title);
            item.icon = dot;
            item.shortcut = key;
            item.is_checked = n as i64 == selected;
            let queue = Rc::clone(&self.chosen);
            item.action = Some(Rc::new(move || queue.borrow_mut().push((i, n))));
            items.push(item);
        }
        self.popup_request = Some(PopupRequest { items, below: self.control_frames[i] });
    }

    fn row_at(&self, p: CGPoint) -> Option<usize> {
        (0..self.row_frames.len()).find(|&i| {
            if self.control_frames[i].contains(p) {
                return true;
            }
            if matches!(self.rows[i], Row::Check { .. }) {
                return self.row_frames[i].contains(p);
            }
            if self.extra_scrub_ids(i).iter().any(|id| self.scrub_frames.get(id).is_some_and(|f| f.contains(p))) {
                return true;
            }
            self.status_button_frames.get(&i).is_some_and(|f| f.contains(p))
        })
    }

    /// True when the press landed on a control.
    pub fn press_at(&mut self, p: CGPoint, modifiers: InputModifiers, tm: &TextMeasure) -> bool {
        self.sync();
        if let Some((id, _)) = self.reset_frames.iter().find(|(_, f)| f.contains(p)).cloned() {
            self.commit_editing_inner();
            self.notify(&format!("reset:{id}"), FormValue::Bool(true));
            return true;
        }
        if self.search.is_some() && self.search_frame.contains(p) {
            self.focused = None;
            self.sidebar_focused = false;
            if let Some(s) = self.search.as_mut() {
                s.mouse_down(None, 1);
            }
            return true;
        }
        if self.search_editing() {
            let before = self.search_text();
            if let Some(s) = self.search.as_mut() {
                let _ = s.commit();
            }
            self.search_changed(&before);
        }
        if let Some(n) = self.sidebar_frames.iter().position(|f| f.contains(p)) {
            self.focused = None;
            self.sidebar_focused = false;
            self.select_page(n);
            return true;
        }
        if let Some(link) = self.link.clone()
            && self.link_frame.contains(p)
        {
            self.commit_editing_inner();
            if !link.fields.iter().any(|f| self.disabled.contains(f)) {
                let v = FormValue::Bool(!self.bool(&link.id).unwrap_or(false));
                self.values.insert(link.id.clone(), v.clone());
                self.notify(&link.id, v);
            }
            return true;
        }
        self.sidebar_focused = false;
        let Some(i) = self.row_at(p) else {
            self.commit_editing_inner();
            self.focused = None;
            return false;
        };
        if self.rows[i].id().is_some_and(|id| self.disabled.contains(id)) {
            self.commit_editing_inner();
            return true;
        }
        if let Some(id) = self.scrub_frames.iter().find(|(_, f)| f.contains(p)).map(|(k, _)| k.clone()) {
            if self.scrub_off(&id) {
                self.commit_editing_inner();
                return true;
            }
            let others: Vec<String> =
                self.scrubs.iter().filter(|(k, s)| **k != id && s.is_editing()).map(|(k, _)| k.clone()).collect();
            for other in others {
                self.scrub_events(&other, ScrubFieldControl::commit_editing);
            }
            if self.focused != Some(i) {
                self.commit_editing_text_fields();
                self.box_editor = None;
            }
            self.focused = Some(i);
            self.focus_visible = false;
            self.focused_scrub = if self.extra_scrub_ids(i).contains(&id) { Some(id.clone()) } else { None };
            self.scrub_down(&id, p);
            return true;
        }
        if let Some(b) = self.status_button_frames.get(&i).copied()
            && b.contains(p)
            && let Some(id) = self.rows[i].id().map(str::to_string)
        {
            self.commit_editing_inner();
            self.notify(&format!("{id}.status"), FormValue::Index(0));
            return true;
        }
        if self.focused != Some(i) {
            self.commit_editing_inner();
        }
        self.focused = Some(i);
        self.focus_visible = false;
        self.focused_scrub = None;
        let font = self.font();
        match self.rows[i].clone() {
            Row::Field { .. } | Row::Slider { .. } => {
                if matches!(self.rows[i], Row::Slider { .. }) && !self.slider_parts(i).1.contains(p) {
                    self.dragging = Some(i);
                    self.drag(p);
                    return true;
                }
                let was_editing = self.fields.get(&i).is_some_and(TextFieldControl::is_editing);
                let boxed = self.field_box(i).inset_by(6.0, 0.0);
                let editor = self.fields.get(&i).and_then(|f| f.editor().cloned());
                if was_editing && let Some(e) = editor {
                    let right = self.fields.get(&i).is_some_and(|f| f.alignment == Alignment::Right);
                    let caret = InspectorDraw::caret_index(&Self::canvas(tm), &e, p.x, boxed, font, right);
                    let n = self.clicks.press(p.x as f32, p.y as f32, self.now());
                    if let Some(f) = self.fields.get_mut(&i) {
                        f.mouse_down(Some(caret), n);
                    }
                    self.selecting = Some((i, None));
                } else {
                    if let Some(f) = self.fields.get_mut(&i) {
                        f.mouse_down(None, 1);
                    }
                    if self.fields.get(&i).is_some_and(TextFieldControl::is_editing) {
                        self.selecting = Some((i, Some(p)));
                    }
                }
            }
            Row::Popup { id, options, .. } if self.choice_cards.contains(&id) => {
                let n = options.len().max(1) as f64;
                let area = self.control_frames[i];
                let k = (((p.x - area.min_x()) / (area.width / n)).floor().max(0.0) as usize).min(options.len() - 1);
                if self.index(&id) != Some(k as i64) {
                    let v = FormValue::Index(k as i64);
                    self.values.insert(id.clone(), v.clone());
                    self.notify(&id, v);
                }
            }
            Row::Popup { .. } => self.open(i),
            Row::Color { id, .. } => self.open_picker(i, &id),
            Row::Check { .. } => self.toggle(i),
            Row::Radio { id, options, .. } => {
                let n = ((p.y - self.control_frames[i].min_y()) / m::CHECK_ROW_HEIGHT) as i64;
                if n >= 0 && (n as usize) < options.len() {
                    self.values.insert(id.clone(), FormValue::Index(n));
                    self.notify(&id, FormValue::Index(n));
                }
            }
            Row::Buttons { .. } => {
                if let Some(n) = self.button_frames(i).iter().position(|f| f.contains(p)) {
                    self.press_button(i, n);
                }
            }
            Row::ListBox { id, .. } => {
                if let Some(n) = self.list_button_frames(i).iter().position(|f| f.contains(p)) {
                    self.notify(&id, FormValue::Index(n as i64));
                }
            }
            Row::RadioNumbers { id, options, fields, .. } => {
                let n = ((p.y - self.control_frames[i].min_y()) / (self.row_h() + self.row_g())) as i64;
                if n >= 0
                    && (n as usize) < options.len()
                    && !fields.get(n as usize).is_some_and(|f| self.disabled.contains(&f.id))
                {
                    self.values.insert(id.clone(), FormValue::Index(n));
                    self.notify(&id, FormValue::Index(n));
                }
            }
            Row::Size { width, height, .. } => {
                if !self.plain_size.contains(&width.id) && self.swap_frame(i).contains(p) {
                    self.swap_size(&width.id, &height.id);
                }
            }
            Row::Segmented { id, options, .. } if self.shape_cards.contains_key(&id) => {
                let frames = ShapeCard::frames(self.control_frames[i], options.len());
                if let Some(n) = frames.iter().position(|f| f.contains(p)) {
                    self.choose(i, n);
                }
            }
            Row::Segmented { id, options, .. } if self.dot_rows.contains_key(&id) => {
                let hit = |f: &CGRect| f.inset_by(-2.5, -3.0).contains(p);
                if let Some(n) = DotRow::frames(self.control_frames[i], options.len()).iter().position(hit) {
                    self.choose(i, n);
                }
            }
            Row::Segmented { .. } => {
                let mut x = self.control_frames[i].min_x() + 1.0;
                let widths = self.segment_cache.get(&i).cloned().unwrap_or_default();
                for (n, w) in widths.iter().enumerate() {
                    if p.x < x + w {
                        self.choose(i, n);
                        break;
                    }
                    x += w;
                }
            }
            Row::TextBox { id, .. } => {
                if self.box_editor.is_none() {
                    self.box_editor = Some(TextEditState::with_select_all(&self.text(&id).unwrap_or_default(), false));
                }
                let inner = self.box_text(i);
                if let Some(e) = self.box_editor.as_ref() {
                    let caret = InspectorDraw::caret_index_at(
                        &Self::canvas(tm),
                        e,
                        p,
                        inner,
                        m::BOX_LINE,
                        type_size::BODY as f64,
                    );
                    if let Some(e) = self.box_editor.as_mut() {
                        e.place(caret, modifiers.contains(InputModifiers::SHIFT));
                    }
                }
            }
            Row::SliderNumber { .. } => {
                self.commit_editing_text_fields();
                self.dragging = Some(i);
                self.drag_with(p, tm);
            }
            Row::Text(_)
            | Row::Gap(_)
            | Row::Number { .. }
            | Row::Caption(_)
            | Row::Label { .. }
            | Row::Chart { .. } => {}
            Row::Picture { .. } => {
                let (boxed, play, bar, _) = self.picture_parts(i);
                if bar.contains(p) {
                    if self.transport(i).is_some_and(|t| t.frames > 0) {
                        self.dragging = Some(i);
                        let f = self.picture_fraction(i, p.x);
                        self.picture_scrub(f);
                    }
                } else if play.contains(p) || boxed.contains(p) {
                    self.picture_toggle();
                }
            }
        }
        true
    }

    /// Left edge of a width × height pair. On a card the pair is wider than the control slot (the New Sequence slot is
    /// 150, the pair with its swap button 199): it ends at the slot's right edge instead of running past the card.
    fn size_pair_x(cards: bool, cx: f64, cw: f64, pair_w: f64) -> f64 {
        if cards { cx.min(cx + cw - pair_w) } else { cx }
    }

    /// The swap button of a `.size` row.
    fn swap_frame(&self, i: usize) -> CGRect {
        let c = self.control_frames[i];
        if let Row::Size { width, .. } = &self.rows[i]
            && self.swap_between.contains(&width.id)
        {
            return CGRect::new(
                c.min_x() + self.control_widths.get(&width.id).copied().unwrap_or(m::SIZE_FIELD) + m::CONTROL_GAP,
                c.min_y(),
                self.row_h(),
                c.height,
            );
        }
        CGRect::new(c.max_x() - m::LINK_WIDTH, c.min_y(), m::LINK_WIDTH, c.height)
    }

    fn swap_size(&mut self, a: &str, b: &str) {
        self.commit_editing_inner();
        let (va, vb) = (self.number(a).unwrap_or(0.0), self.number(b).unwrap_or(0.0));
        self.set(a, FormValue::Number(vb));
        self.set(b, FormValue::Number(va));
        self.notify(a, FormValue::Number(vb));
        self.notify(b, FormValue::Number(va));
    }

    /// The editor of a field row while it is open.
    pub fn text_editor_for_row(&self, i: usize) -> Option<&TextEditState> {
        self.fields.get(&i).and_then(TextFieldControl::editor)
    }

    fn field_caret(&self, i: usize, x: f64, tm: &TextMeasure) -> Option<usize> {
        let e = self.fields.get(&i)?.editor()?;
        Some(InspectorDraw::caret_index(
            &Self::canvas(tm),
            e,
            x,
            self.field_box(i).inset_by(6.0, 0.0),
            self.font(),
            self.fields.get(&i).is_some_and(|f| f.alignment == Alignment::Right),
        ))
    }

    /// A drag with the button down.
    pub fn drag_at(&mut self, p: CGPoint, tm: &TextMeasure, cx: &mut UiCx) {
        if let Some((row, start)) = self.selecting
            && let Some(caret) = self.field_caret(row, p.x, tm)
        {
            let from = start.and_then(|s| self.field_caret(row, s.x, tm));
            if let Some(f) = self.fields.get_mut(&row) {
                f.mouse_dragged(caret, from);
            }
            self.selecting = Some((row, None));
        }
        if self.dragging.is_some() {
            self.drag_with(p, tm);
        }
        if let Some(id) = self.pressed_scrub.clone() {
            let scale = tm.scale;
            self.scrub_events(&id, |s| s.mouse_dragged(p.x as f32, InputModifiers::NONE, scale, cx));
        }
    }

    /// The button went up.
    pub fn release(&mut self, cx: &mut UiCx) {
        self.dragging = None;
        self.selecting = None;
        if let Some(id) = self.pressed_scrub.take() {
            self.scrub_events(&id, |s| s.mouse_up(cx));
        }
    }

    /// The pointer moved over the form.
    pub fn hover_at(&mut self, p: CGPoint) {
        self.hovered = self.row_at(p);
        self.hovered_point = Some(p);
        for (id, s) in &mut self.scrubs {
            s.hovering = self.scrub_frames.get(id).is_some_and(|f| f.contains(p));
        }
        self.sidebar_hovered = self.sidebar_frames.iter().position(|f| f.contains(p));
    }

    fn drag_with(&mut self, p: CGPoint, tm: &TextMeasure) {
        if let Some(i) = self.dragging
            && self.transport(i).is_some()
        {
            let f = self.picture_fraction(i, p.x);
            self.picture_scrub(f);
            return;
        }
        if let Some(i) = self.dragging
            && let Row::SliderNumber { field: f, .. } = self.rows[i].clone()
        {
            let track = self.slider_number_parts(self.control_frames[i], &f.unit, tm).0;
            let t = InspectorDraw::slider_fraction(p.x, track);
            let v = ScrubMath::clamp(*f.range.start() + (*f.range.end() - *f.range.start()) * t, &f.range);
            let stepped = if f.step > 0.0 { ScrubMath::clamp((v / f.step).round() * f.step, &f.range) } else { v };
            self.set(&f.id, FormValue::Number(stepped));
            self.notify(&f.id, FormValue::Number(stepped));
            return;
        }
        self.drag(p);
    }

    fn drag(&mut self, p: CGPoint) {
        let Some(i) = self.dragging else { return };
        let Row::Slider { id, range, .. } = self.rows[i].clone() else { return };
        let f = InspectorDraw::slider_fraction(p.x, self.slider_parts(i).0);
        let v = *range.start() + (*range.end() - *range.start()) * f;
        self.set(&id, FormValue::Number(v));
        self.notify(&id, FormValue::Number(v));
    }

    // MARK: Number fields (`ScrubFieldControl`, the Mac `ScrubField`)

    fn add_scrub(&mut self, f: &NumberField) {
        let mut sc = ScrubFieldControl::new(ScrubMath::clamp(f.value, &f.range));
        sc.range = f.range.clone();
        sc.step = f.step;
        sc.decimals = f.decimals;
        sc.default_value = f.default_value;
        sc.true_minus = self.sidebar.is_none();
        self.values.insert(f.id.clone(), FormValue::Number(sc.value));
        self.scrubs.insert(f.id.clone(), sc);
    }

    /// Shows and reads field `id` through `format` / `parse` (a timecode for a frame count).
    pub fn set_format(&mut self, id: &str, format: ValueFormatter, parse: ValueParser) {
        if let Some(s) = self.scrubs.get_mut(id) {
            s.value_formatter = Some(format);
            s.value_parser = Some(parse);
        }
    }

    /// Runs `body` on field `id` and answers every value it reports.
    fn scrub_events(&mut self, id: &str, body: impl FnOnce(&mut ScrubFieldControl) -> Vec<ScrubEvent>) {
        let Some(sc) = self.scrubs.get_mut(id) else { return };
        let events = body(sc);
        for e in events {
            match e {
                ScrubEvent::Live(v) | ScrubEvent::Change(v) | ScrubEvent::End(v) | ScrubEvent::Cancel(v) => {
                    self.values.insert(id.to_string(), FormValue::Number(v));
                    self.notify(id, FormValue::Number(v));
                }
                ScrubEvent::Begin => {}
            }
        }
    }

    fn scrub_down(&mut self, id: &str, p: CGPoint) {
        let n = self.clicks.press(p.x as f32, p.y as f32, self.now());
        self.pressed_scrub = Some(id.to_string());
        self.scrub_events(id, |s| s.mouse_down(p.x as f32, n));
    }

    fn commit_editing_text_fields(&mut self) {
        let editing: Vec<usize> = self.fields.iter().filter(|(_, f)| f.is_editing()).map(|(i, _)| *i).collect();
        for i in editing {
            if let Some(s) = self.fields.get_mut(&i).and_then(TextFieldControl::commit) {
                self.field_committed(i, &s);
            }
        }
    }

    /// The field a focused row types into: a number row's, or a number radio group's selected option.
    fn scrub_id(&self, i: usize) -> Option<String> {
        if let Some(s) = &self.focused_scrub
            && self.extra_scrub_ids(i).contains(s)
        {
            return Some(s.clone());
        }
        match &self.rows[i] {
            Row::Number { field, .. } | Row::SliderNumber { field, .. } => Some(field.id.clone()),
            Row::Size { width, .. } => Some(width.id.clone()),
            Row::RadioNumbers { id, fields, .. } => {
                self.index(id).and_then(|n| fields.get(n as usize).map(|f| f.id.clone()))
            }
            _ => None,
        }
    }

    /// Keys for a focused number field: typing while it is open (Return commits and still presses the default button),
    /// arrows step it. `None` when the row has no field.
    fn scrub_key(&mut self, i: usize, k: InputKey, m: InputModifiers, cx: &mut UiCx) -> Option<bool> {
        let id = self.scrub_id(i)?;
        if !self.scrubs.contains_key(&id) || self.scrub_off(&id) {
            return None;
        }
        let now = self.now();
        if self.scrubs.get(&id).is_some_and(ScrubFieldControl::is_editing) {
            if k == InputKey::Enter {
                self.commit_editing_inner();
                return Some(false);
            }
            self.scrub_events(&id, |s| s.key(k, m, now, cx));
            return Some(true);
        }
        let arrows_step = matches!(self.rows[i], Row::Number { .. } | Row::SliderNumber { .. })
            || self.focused_scrub.as_deref() == Some(id.as_str());
        let arrow = matches!(k, InputKey::Left | InputKey::Right | InputKey::Up | InputKey::Down);
        if arrows_step && arrow {
            self.scrub_events(&id, |s| s.key(k, m, now, cx));
            return Some(true);
        }
        if matches!(self.rows[i], Row::RadioNumbers { .. }) && (k == InputKey::Left || k == InputKey::Right) {
            self.scrub_events(&id, |s| s.key(k, m, now, cx));
            return Some(true);
        }
        None
    }

    /// Number fields that show their unit inside the box ("100.0 %", art.html 23) instead of after it.
    pub fn show_unit_inside(&mut self, id: &str) {
        let unit = self.rows.iter().find_map(|r| match r {
            Row::Number { field, .. } if field.id == id => Some(field.unit.clone()),
            _ => None,
        });
        let Some(unit) = unit else { return };
        self.inside_units.insert(id.to_string());
        if let Some(s) = self.scrubs.get_mut(id) {
            s.unit = unit;
        }
    }
}

// MARK: Drawing

/// The one look of every segmented control (Swift `SegmentDraw`, SQDrawKit): a `well` track with a 0.5 `hair` ring, the
/// chosen segment `raised` on a small 0 1 2 shadow with a `hair2` ring.
// shortcut: private copy until `sq-draw` ports SegmentDraw; the second user moves it there.
pub(crate) mod segment_draw {
    use sq_draw::stone::Touch;
    use sq_draw::{Canvas, DrawTheme};
    use sq_uikit::controls_grid::CGRect;

    pub fn track(c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        c.stone_segment_track(r, Touch::default(), t);
    }

    /// `opaqueAbove`: the shadow is only a ring outside the segment, never a dark smear under it.
    pub fn selected(c: &mut Canvas, r: CGRect, t: &DrawTheme) {
        c.stone_segment(r, true, Touch::default(), t);
    }
}

fn text(c: &mut Canvas, s: &str, r: CGRect, size: f64, color: Color, align: TextAlign) {
    c.draw_text_in(s, r, size, color, align, 0.0, 0);
}

/// A row title: the kit's Medium weight on a settings page (`sidebar`), the plain face in dialogs.
fn title_text(c: &mut Canvas, s: &str, r: CGRect, size: f64, sidebar: bool, color: Color, align: TextAlign) {
    let face = if sidebar { c.medium() } else { 0 };
    // A title wrapped to a narrow column comes as lines joined by a newline.
    for (n, line) in s.split('\n').enumerate() {
        let line_rect = CGRect::new(r.min_x(), r.min_y() + n as f64 * m::CARD_TITLE_LINE, r.width, r.height);
        c.draw_text_in(line, line_rect, size, color, align, 0.0, face);
    }
}

impl ShellForm {
    fn draw_scrub(&mut self, c: &mut Canvas, f: &NumberField, focused: bool, t: &DrawTheme, cx: &mut UiCx) {
        let off = self.scrub_off(&f.id);
        let Some(boxed) = self.scrub_frames.get(&f.id).copied() else { return };
        let Some(sc) = self.scrubs.get_mut(&f.id) else { return };
        sc.is_enabled = !off;
        sc.value_tint = Some(t.label());
        sc.draw(c, boxed, t, focused && !off, cx);
        if !f.unit.is_empty() && !self.inside_units.contains(&f.id) {
            let col = if off { dim(t.label3()) } else { t.label3() };
            text(
                c,
                &SQL10n::string(&f.unit),
                CGRect::new(boxed.max_x() + m::CONTROL_GAP, boxed.min_y(), 300.0, boxed.height),
                type_size::BODY as f64,
                col,
                TextAlign::Left,
            ); // `SQUnitLabel`
        }
    }

    /// `SQRadio`: a 14 pt dot, accent with a white center when on.
    fn draw_radio(c: &mut Canvas, on: bool, enabled: bool, o: CGPoint, t: &DrawTheme) {
        let dot = CGRect::new(o.x, o.y, 14.0, 14.0);
        c.stone_radio(dot, on, Touch { disabled: !enabled, ..Touch::default() }, t);
    }

    /// Draws the rows (and the sidebar), then the changed marks over them.
    pub fn draw_rows(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.draw_rows_inner(c, t, cx);
        self.draw_marks(c, t);
    }

    /// R4e: a blue dot after the title of a changed setting and its reset arrow.
    fn draw_marks(&self, c: &mut Canvas, t: &DrawTheme) {
        let tm = TextMeasure::new(c.atlas(), c.scale);
        for (id, r) in &self.reset_frames {
            let Some(i) = self.rows.iter().position(|row| row.id() == Some(id.as_str())) else { continue };
            let title = match &self.rows[i] {
                Row::Popup { label, .. } | Row::Field { label, .. } | Row::Slider { label, .. } => label.clone(),
                _ => self.check_labels.get(id).cloned().unwrap_or_default(),
            };
            let row = self.row_frames[i];
            let x = row.min_x() + self.cpad() + self.cside() + tm.width(&SQL10n::string(&title), self.font(), 0).ceil();
            let y = row.min_y() + self.rpt() + m::CARD_TITLE_LINE / 2.0;
            c.fill_ellipse(CGRect::new(x + 8.0, (y - 3.0).round(), 6.0, 6.0), t.accent());
            c.draw_icon(SQIcon::Reset, CGPoint::new(r.mid_x() - 6.0, r.mid_y() - 6.0), 12.0, t.label3(), None);
        }
    }

    /// R4e: the picture cards of a choice row: a small drawing of each option, the chosen one ringed in the accent.
    fn draw_choice_cards(c: &mut Canvas, area: CGRect, options: &[String], sel: i64, t: &DrawTheme, font: f64) {
        let n = options.len().max(1) as f64;
        let gap = 12.0;
        let w = ((area.width - gap * (n - 1.0)) / n).floor();
        for (k, title) in options.iter().enumerate() {
            let on = k as i64 == sel;
            let pic = CGRect::new(area.min_x() + k as f64 * (w + gap), area.min_y(), w, m::CHOICE_PICTURE);
            let (dark, light) = (title != "Light", title != "Dark");
            let timeline = title == "Normal" || title == "Fast Cut";
            if timeline {
                Self::paint_edit_mode_picture(c, pic, title == "Fast Cut", t, font);
            } else if dark && light {
                // System: the dark picture, the light one over its lower right triangle (kit `Light half`).
                // shortcut: the triangle is cut in 1 pt strips, a canvas has no path clip; upgrade with one.
                Self::paint_theme_picture(c, pic, true);
                let mut y = 0.0;
                while y < pic.height {
                    let h = 1.0f64.min(pic.height - y);
                    let x = pic.width * (1.0 - (y + h / 2.0) / pic.height);
                    c.save_gstate();
                    c.clip_to(CGRect::new(pic.min_x() + x, pic.min_y() + y, pic.width - x, h));
                    Self::paint_theme_picture(c, pic, false);
                    c.restore_gstate();
                    y += h;
                }
            } else {
                Self::paint_theme_picture(c, pic, dark);
            }
            if on {
                c.stroke_rounded(pic.inset_by(-1.0, -1.0), 7.0, 2.0, t.accent());
            } else {
                c.stroke_rounded(pic.inset_by(-0.5, -0.5), 6.5, 1.0, t.token(sq_uikit::redesign_tokens::color::LINE2));
            }
            Self::draw_radio(c, on, true, CGPoint::new(pic.min_x(), pic.max_y() + 9.0), t);
            let caption = SQL10n::string(title);
            text(
                c,
                &caption,
                CGRect::new(pic.min_x() + 22.0, pic.max_y() + 8.0, (w - 22.0).max(0.0), 16.0),
                font,
                if on { t.label() } else { t.label2() },
                TextAlign::Left,
            );
            if let Some(note) =
                timeline.then(|| if title == "Fast Cut" { "· magnetic main track" } else { "· classic tracks" })
            {
                // The note after the name (the kit's Normal / Fast Cut choices), a fixed offset past the caption.
                let off = 22.0 + caption.chars().count() as f64 * font * 0.58 + 6.0;
                let room = (w - off).max(0.0);
                // The note is extra: a narrow card leaves it out rather than cutting it mid-word.
                if c.ellipsized(note, font, 0, room) == note {
                    text(
                        c,
                        note,
                        CGRect::new(pic.min_x() + off, pic.max_y() + 8.0, room, 16.0),
                        font,
                        t.label3(),
                        TextAlign::Left,
                    );
                }
            }
        }
    }

    /// The Dark / Light picture of the kit (`Settings/Choice/Dark|Light`, 189.33 x 78 scaled to `r`): the window with two
    /// panels around the viewer and one lane with two clips.
    fn paint_theme_picture(c: &mut Canvas, r: CGRect, dark: bool) {
        let (bg, panel, lane) = if dark { (0x0E0E10, 0x1F1F22, 0x2B2B2F) } else { (0xD9D9DD, 0xF4F4F6, 0xE6E6EA) };
        let (sx, sy) = (r.width / 189.33, r.height / 78.0);
        let part = |c: &mut Canvas, x: f64, y: f64, w: f64, h: f64, rgb: u32| {
            c.fill_rounded(
                CGRect::new(r.min_x() + x * sx, r.min_y() + y * sy, w * sx, h * sy),
                2.0,
                Color::hex(rgb, 1.0),
            );
        };
        c.fill_rounded(r, 6.0, Color::hex(bg, 1.0));
        part(c, 6.0, 6.0, 55.27, 33.16, panel);
        part(c, 64.27, 6.0, 71.85, 33.16, 0x111111);
        part(c, 139.12, 6.0, 44.21, 33.16, panel);
        part(c, 6.0, 42.16, 177.33, 29.84, lane);
        part(c, 27.28, 51.11, 53.2, 6.57, 0x3474B5);
        part(c, 87.57, 51.11, 39.01, 6.57, 0x3474B5);
    }

    /// The Normal / Fast Cut picture of the kit: three clips on one lane; Normal leaves a dashed gap, Fast Cut closes it.
    fn paint_edit_mode_picture(c: &mut Canvas, r: CGRect, fast: bool, t: &DrawTheme, font: f64) {
        c.fill_rounded(r, 6.0, Color::hex(0x141416, 1.0));
        let (sx, y, h) = (r.width / 290.0, r.min_y() + r.height * 0.38, r.height * 0.26);
        let clip = |c: &mut Canvas, x: f64, w: f64, rgb: u32| {
            c.fill_rounded(CGRect::new(r.min_x() + x * sx, y, w * sx, h), 2.0, Color::hex(rgb, 1.0));
        };
        clip(c, 23.2, 75.4, 0x3474B5);
        let note = if fast {
            clip(c, 104.4, 87.0, 0x3474B5);
            clip(c, 197.2, 58.0, 0x2A5F96);
            "Gap closes by itself"
        } else {
            // The gap: a dashed outline (3 on, 2 off).
            let g = CGRect::new(r.min_x() + 104.4 * sx, y, 63.8 * sx, h);
            let dash = Color::hex(0xFFFFFF, 0.3);
            let mut x = g.min_x();
            while x < g.max_x() {
                let w = 3.0f64.min(g.max_x() - x);
                c.fill(CGRect::new(x, g.min_y(), w, 1.0), dash);
                c.fill(CGRect::new(x, g.max_y() - 1.0, w, 1.0), dash);
                x += 5.0;
            }
            let mut yy = g.min_y();
            while yy < g.max_y() {
                let hh = 3.0f64.min(g.max_y() - yy);
                c.fill(CGRect::new(g.min_x(), yy, 1.0, hh), dash);
                c.fill(CGRect::new(g.max_x() - 1.0, yy, 1.0, hh), dash);
                yy += 5.0;
            }
            clip(c, 174.0, 87.0, 0x3474B5);
            "Delete leaves a gap"
        };
        text(
            c,
            note,
            CGRect::new(r.min_x() + 10.0, r.min_y() + r.height * 0.77, r.width - 20.0, 14.0),
            font - 1.0,
            t.label3(),
            TextAlign::Left,
        );
    }

    fn draw_rows_inner(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.sync();
        if let Some(sidebar) = self.sidebar.clone() {
            self.draw_sidebar(c, &sidebar, t, cx);
        }
        let tm = TextMeasure::new(c.atlas(), c.scale);
        let strong = self.sidebar.is_some();
        let sidebar = strong || self.kit_cards;
        // `SQDialog.labelText` and `SQFormRow.row`: form labels are right aligned against the controls; a settings card
        // row has its title at the left.
        let label_align = if sidebar { TextAlign::Left } else { TextAlign::Right };
        let body = type_size::BODY as f64;
        let font = self.font();
        if sidebar {
            self.draw_cards(c, t);
        }
        let row_h = self.row_h();
        let row_g = self.row_g();
        for i in 0..self.rows.len() {
            if i >= self.row_frames.len() {
                continue;
            }
            let mut r = self.rows[i].clone();
            // A wrapped title (a narrow column) is drawn as its lines; `title_text` splits them again.
            if let Some(lines) = self.title_lines.get(&i) {
                match &mut r {
                    Row::Popup { label, .. }
                    | Row::Field { label, .. }
                    | Row::Slider { label, .. }
                    | Row::SliderNumber { label, .. }
                    | Row::Number { label, .. }
                    | Row::Label { label, .. } => *label = lines.join("\n"),
                    Row::Check { title, .. } => *title = lines.join("\n"),
                    _ => {}
                }
            }
            if r.id().is_some_and(|id| self.hidden.contains(id)) {
                continue;
            }
            let row = self.row_frames[i];
            let mut boxed = self.control_frames[i];
            if let Row::Popup { id, label, options, .. } = &r
                && self.choice_cards.contains(id)
            {
                let label_rect = CGRect::new(
                    row.min_x() + self.cpad() + self.cside(),
                    row.min_y() + self.rpt(),
                    m::CARD_HELP_W,
                    m::CARD_TITLE_LINE,
                );
                title_text(c, &SQL10n::string(label), label_rect, font, sidebar, t.label(), TextAlign::Left);
                let sel = self.index(id).unwrap_or(0);
                if let Some(lines) = self.help_lines.get(&i) {
                    let mut y = self.help_tops.get(&i).copied().unwrap_or(label_rect.max_y() + 3.0);
                    for l in lines {
                        let line = CGRect::new(label_rect.min_x(), y, boxed.width, self.help_line());
                        text(c, l, line, font, t.label3(), TextAlign::Left);
                        y += self.help_line();
                    }
                }
                Self::draw_choice_cards(c, boxed, options, sel, t, font);
                continue;
            }
            // A card row without help centers its title on the row, like the control (the kit's Content row).
            let centered = sidebar
                && !self.kit_cards
                && !self.help_lines.contains_key(&i)
                && !self.stacked_rows.contains(&i)
                && !self.title_lines.contains_key(&i)
                && self.is_card_row(&r)
                && r.id().is_none_or(|id| self.grids.get(id).is_none_or(|g| g.is_empty()));
            let label_rect = if sidebar {
                CGRect::new(
                    row.min_x() + self.cpad() + self.cside(),
                    if centered {
                        row.min_y() + ((row.height - m::CARD_TITLE_LINE) / 2.0).round()
                    } else {
                        row.min_y()
                            + if self.kit_cards && self.help_lines.contains_key(&i) { 5.0 } else { self.rpt() }
                            + if self.kit_cards && !self.help_lines.contains_key(&i) { 3.0 } else { 0.0 }
                    },
                    self.text_col(i, row.min_x() + self.cpad() + self.cside(), boxed),
                    m::CARD_TITLE_LINE,
                )
            } else {
                CGRect::new(row.min_x() + self.side_pad, row.min_y(), self.label_width - self.label_inset, row_h)
            };
            let hover = self.hovered == Some(i);
            let focused = self.focused == Some(i);
            // The 2 pt focus ring is for keyboard focus only, never after a mouse click (HAUPTFENSTER 12).
            let ring = focused && self.focus_visible;
            let hp = self.hovered_point;
            match &r {
                Row::Text(_) => {
                    let mut y = boxed.min_y();
                    let strong = self.strong_notes.contains(&i);
                    let color = if self.warning_notes.contains(&i) {
                        t.yellow()
                    } else if strong {
                        t.label()
                    } else {
                        t.label2()
                    };
                    let line = if strong { m::STRONG_LINE } else { m::NOTE_LINE };
                    if self.info_notes.contains(&i) {
                        let ic = CGRect::new(boxed.min_x(), boxed.min_y() + 2.0, 12.0, 12.0);
                        c.stroke_ellipse(ic.inset_by(0.5, 0.5), 1.0, t.label3());
                        text(
                            c,
                            "i",
                            CGRect::new(ic.x, ic.y + 0.5, ic.width, ic.height),
                            type_size::CAPTION as f64,
                            t.label3(),
                            TextAlign::Center,
                        );
                        boxed.x += m::INFO_INDENT;
                        boxed.width -= m::INFO_INDENT;
                    }
                    for l in self.note_lines.get(&i).cloned().unwrap_or_default() {
                        let rect = CGRect::new(boxed.min_x(), y, boxed.width, line);
                        // A strong note is medium weight, unless it is the plain `SQDialog.formText(note: false)`.
                        if strong && !self.plain_strong_notes.contains(&i) {
                            let face = c.medium();
                            c.draw_text_in(&l, rect, font, color, TextAlign::Left, 0.0, face);
                        } else {
                            text(c, &l, rect, font, color, TextAlign::Left);
                        }
                        y += line;
                    }
                }
                Row::Field { id: fid, label, unit, .. } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    let fsize = if sidebar { m::FONT } else { self.dialog_field_font_size };
                    if let Some(f) = self.fields.get_mut(&i) {
                        f.font_size = fsize;
                        f.draw(c, boxed, t, focused, cx);
                    }
                    if let Some(icon) = self.field_icons.get(fid) {
                        c.draw_icon(
                            *icon,
                            CGPoint::new(
                                boxed.min_x() + m::FIELD_BLEED + 6.0,
                                boxed.mid_y() - m::FIELD_ICON_SIZE / 2.0,
                            ),
                            m::FIELD_ICON_SIZE,
                            t.label2(),
                            None,
                        );
                    }
                    if !unit.is_empty() {
                        text(
                            c,
                            unit,
                            CGRect::new(boxed.max_x() + m::CONTROL_GAP, boxed.min_y(), 60.0, boxed.height),
                            font,
                            t.label3(),
                            TextAlign::Left,
                        );
                    }
                }
                Row::Color { id, label, .. } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    // `SQColorWell` in a form row: a capsule filling the control column, 20 high, the color under a hairline.
                    let well = CGRect::new(boxed.min_x(), boxed.mid_y() - 10.0, boxed.width, 20.0);
                    let v = self.colors.get(id).copied().unwrap_or(SQColorValue::new(0.0, 0.0, 0.0, 1.0));
                    if !sidebar {
                        // art.html 19: a field-height box with a small swatch and the color's name, like the Name field above it.
                        let field = CGRect::new(
                            boxed.min_x(),
                            boxed.mid_y() - m::DIALOG_CONTROL / 2.0,
                            boxed.width,
                            m::DIALOG_CONTROL,
                        );
                        let rad = radius::CONTROL as f64;
                        let touch = Touch { hovering: hover, ..Touch::default() };
                        c.stone_field(field, rad, self.picker.is_some(), touch, t);
                        let sw = CGRect::new(field.min_x() + 8.0, field.mid_y() - 4.0, 8.0, 8.0);
                        c.fill_rounded(sw, 2.0, ColorPickerControl::draw_color(&v));
                        c.stroke_rounded(sw.inset_by(0.25, 0.25), 2.0, 0.5, t.hair2());
                        let hex = v.hex().to_uppercase();
                        let name = if hex == "000000" { "Black".to_string() } else { format!("#{hex}") };
                        text(
                            c,
                            &name,
                            CGRect::new(
                                field.min_x() + 22.0,
                                field.min_y(),
                                (field.width - 30.0).max(0.0),
                                field.height,
                            ),
                            body,
                            t.label(),
                            TextAlign::Left,
                        );
                        if ring {
                            InspectorDraw::focus_line(c, field, rad, t);
                        }
                    } else {
                        let menu = radius::MENU as f64;
                        if v.a < 1.0 {
                            c.fill_rounded(well, menu, t.fill());
                        }
                        c.fill_rounded(well, menu, ColorPickerControl::draw_color(&v));
                        c.stroke_rounded(
                            well.inset_by(0.25, 0.25),
                            menu,
                            0.5,
                            t.ink_fill(if hover || self.picker.is_some() { 0.30 } else { 0.14 }),
                        );
                        if ring {
                            InspectorDraw::focus_line(c, boxed.inset_by(0.0, 3.0), radius::CONTROL as f64, t);
                        }
                    }
                }
                Row::Popup { id, label, options, .. } => {
                    if let Some(b) = self.beside.get(id) {
                        let w = tm.width(&SQL10n::string(b), font, 0).ceil();
                        text(
                            c,
                            &SQL10n::string(b),
                            CGRect::new(boxed.min_x() - 8.0 - w, boxed.min_y(), w, boxed.height),
                            font,
                            t.label2(),
                            TextAlign::Right,
                        );
                    }
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    let sel = self.index(id).unwrap_or(0);
                    let title =
                        if sel >= 0 { options.get(sel as usize).cloned().unwrap_or_default() } else { String::new() };
                    let style = self.popup_styles.get(id).cloned();
                    let cap = InspectorTokens::CAPSULE as f64;
                    let dot =
                        style.as_ref().and_then(|s| s.dots.get(sel.max(0) as usize).copied()).filter(|_| sel >= 0);
                    if let Some(d) = dot {
                        InspectorDraw::popup(c, "", boxed, hover, false, true, false, cap, None, t);
                        c.fill_ellipse(
                            CGRect::new(
                                boxed.min_x() + 10.0,
                                (boxed.mid_y() - m::STATUS_DOT / 2.0).round(),
                                m::STATUS_DOT,
                                m::STATUS_DOT,
                            ),
                            Color::hex(d, 1.0),
                        );
                        text(
                            c,
                            &title,
                            CGRect::new(
                                boxed.min_x() + 22.0,
                                boxed.min_y(),
                                (boxed.width - 22.0 - 18.0).max(0.0),
                                boxed.height,
                            ),
                            body,
                            t.label(),
                            TextAlign::Left,
                        );
                    } else if sidebar {
                        // Kit `Field/Dropdown/Default`: a raised button without a ring, the label at 10, a 9 pt caret at 8.
                        let touch = Touch {
                            hovering: hover,
                            pressed: false,
                            disabled: self.disabled.contains(id),
                            focused: ring,
                        };
                        // The kit's dropdown is 180 wide, flush right in its slot; the focus ring wraps this rect.
                        let field = if self.stacked_rows.contains(&i) {
                            CGRect::new(
                                boxed.min_x() + m::POPUP_BLEED,
                                boxed.min_y(),
                                boxed.width - m::POPUP_BLEED,
                                boxed.height,
                            )
                        } else {
                            Self::sidebar_popup_rect(boxed)
                        };
                        let b = c.stone_button(field, sq_draw::stone::ButtonKind::Raised, touch, t);
                        text(
                            c,
                            &title,
                            CGRect::new(
                                b.min_x() + 10.0,
                                b.min_y(),
                                (b.width - 10.0 - 8.0 - 9.0 - 12.0).max(0.0),
                                b.height,
                            ),
                            body,
                            t.label(),
                            TextAlign::Left,
                        );
                        c.draw_icon(
                            SQIcon::ChevronDown,
                            CGPoint::new(b.max_x() - 8.0 - 9.0, b.mid_y() - 4.5),
                            9.0,
                            t.label4(),
                            None,
                        );
                    } else {
                        InspectorDraw::popup(
                            c,
                            &title,
                            boxed,
                            hover,
                            false,
                            true,
                            false,
                            style.as_ref().and_then(|s| s.height).unwrap_or(cap),
                            style.as_ref().and_then(|s| s.font_size),
                            t,
                        );
                    }
                    if let Some(key) = style.as_ref().map(|s| s.box_key.clone()).filter(|k| !k.is_empty()) {
                        // `NewProjectSheet.KeyLabel`: 56 wide, right aligned, 28 left of the box's right edge, 11 pt label3.
                        text(
                            c,
                            &key,
                            CGRect::new(boxed.max_x() - 28.0 - 56.0, boxed.min_y(), 56.0, boxed.height),
                            11.0,
                            t.label3(),
                            TextAlign::Right,
                        );
                    }
                    // A Settings dropdown's ring is the stone button's own (around its control rect), not the row slot's.
                    if ring && !sidebar {
                        InspectorDraw::focus_line(c, boxed.inset_by(0.0, 3.0), radius::CONTROL as f64, t);
                    }
                }
                Row::Check { id, title, .. } if self.disclosures.contains(id) => {
                    // A caret that turns down when open, then the title in the quiet text color.
                    let open = self.bool(id) == Some(true);
                    let o = CGPoint::new(boxed.min_x() + 2.0, boxed.mid_y() - 5.0);
                    c.draw_icon(
                        if open { SQIcon::ChevronDown } else { SQIcon::ChevronRight },
                        o,
                        10.0,
                        t.label3(),
                        None,
                    );
                    let col = if hover { t.label() } else { t.label3() };
                    text(
                        c,
                        &SQL10n::string(title),
                        CGRect::new(boxed.min_x() + 16.0, boxed.min_y(), boxed.width - 16.0, boxed.height),
                        body,
                        col,
                        TextAlign::Left,
                    );
                    if ring {
                        InspectorDraw::focus_line(c, boxed, radius::CONTROL as f64, t);
                    }
                }
                Row::Check { id, title, .. } if sidebar => {
                    // `Switch/On|Off`: the title (the row title) left, the switch right.
                    let on = !self.disabled.contains(id);
                    title_text(
                        c,
                        &SQL10n::string(title),
                        label_rect,
                        font,
                        sidebar,
                        if on { t.label() } else { dim(t.label()) },
                        TextAlign::Left,
                    );
                    let touch = Touch { hovering: hover && on, pressed: false, disabled: !on, focused: ring };
                    c.stone_switch(boxed, self.bool(id) == Some(true), touch, t);
                    // R4e: a number that belongs to the switch (Live Ducking amount) sits left of it, inside the row.
                    if let Some((cf, _)) = self.check_fields.get(id).cloned() {
                        let fs = focused && self.focused_scrub.as_deref() == Some(cf.id.as_str());
                        self.draw_scrub(c, &cf, fs, t, cx);
                    }
                }
                Row::Check { id, title, .. } => {
                    let on = !self.disabled.contains(id);
                    if let Some(label) = self.check_labels.get(id) {
                        title_text(
                            c,
                            &SQL10n::string(label),
                            label_rect,
                            font,
                            sidebar,
                            if strong { t.label() } else { t.label2() },
                            label_align,
                        );
                    }
                    let b = CGRect::new(boxed.min_x(), boxed.mid_y() - 7.0, 14.0, 14.0);
                    InspectorDraw::checkbox(
                        c,
                        if self.bool(id) == Some(true) { CheckState::On } else { CheckState::Off },
                        b,
                        hover && on,
                        false,
                        on,
                        ring,
                        t,
                    );
                    // `SQCheckbox` is body (11 pt) in every dialog form; the Settings sidebar keeps its own size.
                    text(
                        c,
                        &SQL10n::string(title),
                        CGRect::new(b.max_x() + 6.0, boxed.min_y(), boxed.width - 20.0, boxed.height),
                        if sidebar { font } else { body },
                        if on { t.label() } else { dim(t.label()) },
                        TextAlign::Left,
                    );
                    if let Some((cf, _)) = self.check_fields.get(id).cloned() {
                        let fs = focused && self.focused_scrub.as_deref() == Some(cf.id.as_str());
                        self.draw_scrub(c, &cf, fs, t, cx);
                    }
                }
                Row::Number { label, field } => {
                    let col = if self.disabled.contains(&field.id) { dim(t.label2()) } else { t.label2() };
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if sidebar { t.label() } else { col },
                        label_align,
                    );
                    self.draw_scrub(c, field, focused, t, cx);
                }
                Row::RadioNumbers { id, options, fields, .. } => {
                    for (n, o) in options.iter().enumerate() {
                        let ry = boxed.min_y() + n as f64 * (row_h + row_g);
                        let off = fields.get(n).is_some_and(|f| self.disabled.contains(&f.id));
                        Self::draw_radio(
                            c,
                            self.index(id) == Some(n as i64),
                            !off,
                            CGPoint::new(boxed.min_x(), ry + row_h / 2.0 - 7.0),
                            t,
                        );
                        text(
                            c,
                            &SQL10n::string(o),
                            CGRect::new(boxed.min_x() + 20.0, ry, m::RADIO_COLUMN - 24.0, row_h),
                            body,
                            if off { dim(t.label()) } else { t.label() },
                            TextAlign::Left,
                        );
                        if let Some(f) = fields.get(n) {
                            self.draw_scrub(c, f, false, t, cx);
                        }
                    }
                    if focused
                        && let Some(n) = self.index(id)
                        && let Some(f) = fields.get(n as usize)
                        && self.scrubs.get(&f.id).is_none_or(|s| !s.is_editing())
                    {
                        let ry = boxed.min_y() + n as f64 * (row_h + row_g);
                        InspectorDraw::focus_line(
                            c,
                            CGRect::new(boxed.min_x() - 3.0, ry + 4.0, m::RADIO_COLUMN - 8.0, row_h - 8.0),
                            radius::SMALL as f64,
                            t,
                        );
                    }
                }
                Row::SliderNumber { label, field } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    let span = *field.range.end() - *field.range.start();
                    let origin = if !sidebar && *field.range.start() == -*field.range.end() { 0.5 } else { 0.0 };
                    let track = self.slider_number_parts(boxed, &field.unit, &tm).0;
                    InspectorDraw::slider(
                        c,
                        if span > 0.0 {
                            (self.number(&field.id).unwrap_or(0.0) - *field.range.start()) / span
                        } else {
                            0.0
                        },
                        origin,
                        track,
                        !self.scrub_off(&field.id),
                        t,
                    );
                    self.draw_scrub(c, field, focused, t, cx);
                }
                Row::Slider { id, label, range, unit, .. } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    let parts = self.slider_parts(i);
                    if self.slider_track_width.is_some() && !sidebar && !unit.is_empty() {
                        text(
                            c,
                            &SQL10n::string(unit),
                            CGRect::new(parts.1.max_x() + m::CONTROL_GAP, parts.1.min_y(), 40.0, parts.1.height),
                            font,
                            t.label3(),
                            TextAlign::Left,
                        );
                    }
                    let span = *range.end() - *range.start();
                    let fraction =
                        if span > 0.0 { (self.number(id).unwrap_or(0.0) - *range.start()) / span } else { 0.0 };
                    if sidebar {
                        // Kit `Settings/Slider`: the sunken track and the 8 x 16 pill knob, no fill.
                        let touch = Touch::default();
                        c.stone_slider_track(parts.0, None, touch, t);
                        let (x0, x1) = (parts.0.min_x() + 4.0, parts.0.max_x() - 4.0);
                        c.stone_slider_knob(x0 + (x1 - x0) * fraction.clamp(0.0, 1.0), parts.0.mid_y(), true, touch, t);
                    } else {
                        InspectorDraw::slider(c, fraction, 0.0, parts.0, true, t);
                    }
                    let shown = Self::format(self.number(id).unwrap_or(0.0));
                    if let Some(f) = self.fields.get_mut(&i) {
                        if !f.is_editing() {
                            f.text = shown;
                        }
                        f.font_size = font;
                        f.draw(c, parts.1, t, focused, cx);
                    }
                }
                Row::Radio { id, options, .. } if self.numbered_list => {
                    c.fill_rounded(boxed.inset_by(0.0, -m::LIST_PAD), radius::CONTROL as f64, t.well());
                    for (n, o) in options.iter().enumerate() {
                        let rr = CGRect::new(
                            boxed.min_x() + 4.0,
                            boxed.min_y() + n as f64 * m::CHECK_ROW_HEIGHT,
                            boxed.width - 8.0,
                            m::CHECK_ROW_HEIGHT,
                        );
                        let current = self.index(id) == Some(n as i64);
                        if current {
                            // art.html 11: the current row is `current`
                            c.fill_rounded(rr, radius::SMALL as f64, t.current());
                        }
                        text(
                            c,
                            &format!("{}", n as i64 + self.list_number_base),
                            CGRect::new(rr.min_x() + 8.0, rr.min_y(), 14.0, rr.height),
                            body,
                            t.label3(),
                            TextAlign::Right,
                        );
                        text(
                            c,
                            &SQL10n::string(o),
                            CGRect::new(rr.min_x() + 32.0, rr.min_y(), rr.width - 56.0, rr.height),
                            body,
                            t.label(),
                            TextAlign::Left,
                        );
                        if current {
                            c.draw_icon(
                                SQIcon::Check,
                                CGPoint::new(rr.max_x() - 22.0, rr.mid_y() - 7.0),
                                14.0,
                                t.label(),
                                None,
                            );
                        }
                    }
                    if ring {
                        InspectorDraw::focus_line(c, boxed, radius::SMALL as f64, t);
                    }
                }
                Row::Radio { id, options, .. } => {
                    for (n, o) in options.iter().enumerate() {
                        let ry = boxed.min_y() + n as f64 * m::CHECK_ROW_HEIGHT;
                        Self::draw_radio(
                            c,
                            self.index(id) == Some(n as i64),
                            true,
                            CGPoint::new(boxed.min_x(), ry + m::CHECK_ROW_HEIGHT / 2.0 - 7.0),
                            t,
                        );
                        // `SQRadio` title: Typography.body
                        text(
                            c,
                            &SQL10n::string(o),
                            CGRect::new(boxed.min_x() + 20.0, ry, boxed.width - 20.0, m::CHECK_ROW_HEIGHT),
                            body,
                            t.label(),
                            TextAlign::Left,
                        );
                    }
                    if ring {
                        InspectorDraw::focus_line(c, boxed, radius::SMALL as f64, t);
                    }
                }
                Row::Buttons { id, label, detail, titles, .. } => {
                    if !label.is_empty() {
                        title_text(
                            c,
                            &SQL10n::string(label),
                            label_rect,
                            font,
                            sidebar,
                            if strong { t.label() } else { t.label2() },
                            label_align,
                        );
                    }
                    let frames = self.button_frames(i).to_vec();
                    let text_right = frames.first().map_or(boxed.max_x(), |f| f.min_x()) - m::CONTROL_GAP;
                    if let Some(chip) = self.chips.get(id) {
                        let rr = CGRect::new(
                            boxed.min_x(),
                            boxed.min_y(),
                            (text_right - boxed.min_x()).max(0.0),
                            boxed.height,
                        );
                        c.fill_rounded(rr, radius::OVERLAY as f64, t.fill());
                        c.draw_icon(
                            chip.icon,
                            CGPoint::new(rr.min_x() + 12.0, (rr.mid_y() - 8.0).round()),
                            16.0,
                            t.label2(),
                            None,
                        );
                        let tx = rr.min_x() + 12.0 + 16.0 + 8.0 + self.label_inset;
                        let tw = (rr.max_x() - 12.0 - tx).max(0.0);
                        text(
                            c,
                            &tm.truncated_middle(detail, tw, font),
                            CGRect::new(tx, rr.min_y(), tw, rr.height),
                            font,
                            t.label2(),
                            TextAlign::Left,
                        );
                    } else {
                        text(
                            c,
                            detail,
                            CGRect::new(
                                boxed.min_x(),
                                boxed.min_y(),
                                (text_right - boxed.min_x()).max(0.0),
                                boxed.height,
                            ),
                            font,
                            t.label(),
                            TextAlign::Left,
                        );
                    }
                    for (n, rr) in frames.iter().enumerate() {
                        InspectorDraw::button(
                            c,
                            &SQL10n::string(&titles[n]),
                            *rr,
                            hover && hp.is_some_and(|p| rr.contains(p)),
                            false,
                            self.button_enabled(i, n),
                            false,
                            if self.chips.contains_key(id) { row_h } else { InspectorTokens::CAPSULE as f64 }, // the Mac's Choose... is 28 pt
                            t,
                        );
                    }
                    if ring && let Some(first) = frames.first() {
                        InspectorDraw::focus_line(c, *first, radius::CONTROL as f64, t);
                    }
                }
                Row::ListBox { id, label, lines, button, .. } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    c.stone_field(boxed, radius::CONTROL as f64, false, Touch::default(), t);
                    if lines.is_empty() {
                        let mut y = boxed.min_y() + 6.0;
                        for l in self.note_lines.get(&i).cloned().unwrap_or_default() {
                            text(
                                c,
                                &l,
                                CGRect::new(boxed.min_x() + 12.0, y, boxed.width - 24.0, m::NOTE_LINE),
                                font,
                                t.label3(),
                                TextAlign::Left,
                            );
                            y += m::NOTE_LINE;
                        }
                    }
                    for (n, rr) in self.list_button_frames(i).to_vec().into_iter().enumerate() {
                        if let Some(extra) = self.list_lines.get(id).and_then(|e| e.get(n)).cloned() {
                            self.draw_list_line(c, &lines[n], &extra, boxed, rr, t, &tm);
                        } else {
                            text(
                                c,
                                &lines[n],
                                CGRect::new(
                                    boxed.min_x() + 12.0,
                                    rr.min_y(),
                                    (rr.min_x() - boxed.min_x() - 20.0).max(0.0),
                                    rr.height,
                                ),
                                font,
                                t.label(),
                                TextAlign::Left,
                            );
                        }
                        InspectorDraw::button(
                            c,
                            &SQL10n::string(button),
                            rr,
                            hover && hp.is_some_and(|p| rr.contains(p)),
                            false,
                            true,
                            false,
                            InspectorTokens::CAPSULE as f64,
                            t,
                        );
                    }
                }
                Row::Caption(s) if sidebar => {
                    let face = c.semibold();
                    c.draw_text_in(&SQL10n::string(s), boxed, body, t.label2(), TextAlign::Left, 0.0, face);
                }
                Row::Caption(s) => {
                    let face = if sidebar { c.semibold() } else { c.medium() };
                    // art.html settings pages: the section heading is semibold in the label color (.sechead).
                    c.draw_text_in(&SQL10n::string(s), boxed, body, t.label(), TextAlign::Left, 0.0, face);
                }
                Row::Size { label, width: w, height: hf } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    self.draw_scrub(c, w, focused, t, cx);
                    self.draw_scrub(c, hf, false, t, cx);
                    if self.plain_size.contains(&w.id) {
                        let a = self.scrub_frames.get(&w.id).copied().unwrap_or(boxed);
                        let b = self.scrub_frames.get(&hf.id).copied().unwrap_or(boxed);
                        text(
                            c,
                            "\u{00D7}",
                            CGRect::new(a.max_x(), boxed.min_y(), b.min_x() - a.max_x(), boxed.height),
                            body,
                            t.label3(),
                            TextAlign::Center,
                        );
                    } else {
                        if !self.swap_between.contains(&w.id) {
                            text(
                                c,
                                "\u{00D7}",
                                CGRect::new(
                                    boxed.min_x() + m::SIZE_FIELD + m::CONTROL_GAP,
                                    boxed.min_y(),
                                    m::TIMES_WIDTH + 2.0,
                                    boxed.height,
                                ),
                                body,
                                t.label3(),
                                TextAlign::Left,
                            );
                        }
                        let sw = self.swap_frame(i);
                        let sw_hot = hover && hp.is_some_and(|p| sw.contains(p));
                        c.stone_button(
                            sw.inset_by(0.0, 2.0),
                            ButtonKind::Quiet,
                            Touch { hovering: sw_hot, ..Touch::default() },
                            t,
                        );
                        c.draw_icon(
                            SQIcon::Swap,
                            CGPoint::new(sw.mid_x() - 7.0, (sw.mid_y() - 7.0).round()),
                            14.0,
                            t.label2(),
                            None,
                        );
                    }
                }
                Row::Segmented { id, label, options, .. } if self.shape_cards.contains_key(id) => {
                    let mid = CGRect::new(label_rect.min_x(), boxed.mid_y() - row_h / 2.0, label_rect.width, row_h);
                    text(c, &SQL10n::string(label), mid, font, t.label2(), label_align);
                    let cards = self.shape_cards.get(id).cloned().unwrap_or_default();
                    let frames = ShapeCard::frames(boxed, options.len().min(cards.len()));
                    let chosen = self.index(id).unwrap_or(-1);
                    for (n, (card, f)) in cards.iter().zip(frames.iter()).enumerate() {
                        let on = chosen == n as i64;
                        let over = hover && hp.is_some_and(|p| f.contains(p));
                        let fill = if over { t.fill_hover() } else { t.fill() };
                        c.fill_rounded(*f, radius::SMALL as f64 + 2.0, fill);
                        if on {
                            c.stroke_rounded(f.inset_by(1.0, 1.0), radius::SMALL as f64 + 1.0, 2.0, t.accent());
                        }
                        let (pw, ph) = card.picture();
                        let pic = CGRect::new(
                            (f.mid_x() - pw / 2.0).round(),
                            f.min_y() + 10.0 + ((ShapeCard::PICTURE - ph) / 2.0).round().min(0.0),
                            pw,
                            ph,
                        );
                        let edge = if on { t.label() } else { t.label3() };
                        if on {
                            c.fill_rounded(pic, 3.0, t.accent().with_alpha(0.18));
                        }
                        c.stroke_rounded(pic.inset_by(0.75, 0.75), 3.0, 1.5, edge);
                        text(
                            c,
                            &SQL10n::string(&card.title),
                            CGRect::new(f.min_x(), f.max_y() - 22.0, f.width, 14.0),
                            11.0,
                            t.label(),
                            TextAlign::Center,
                        );
                    }
                    if let Some(hint) = self.hints.get(id).filter(|h| !h.is_empty()) {
                        text(
                            c,
                            &SQL10n::string(hint),
                            CGRect::new(boxed.min_x(), boxed.max_y() + 6.0, boxed.width, 14.0),
                            11.0,
                            t.label3(),
                            TextAlign::Left,
                        );
                    }
                    if ring {
                        InspectorDraw::focus_line(c, boxed, radius::CONTROL as f64, t);
                    }
                }
                Row::Segmented { id, label, options, .. } => {
                    title_text(
                        c,
                        &SQL10n::string(label),
                        label_rect,
                        font,
                        sidebar,
                        if strong { t.label() } else { t.label2() },
                        label_align,
                    );
                    if let Some(colors) = self.dot_rows.get(id) {
                        let chosen = self.index(id);
                        for (n, f) in DotRow::frames(boxed, options.len()).into_iter().enumerate() {
                            let rgb = colors.get(n).copied().unwrap_or(0x808080);
                            c.fill_rounded(f, DotRow::DOT / 2.0, Color::hex(rgb, 1.0));
                            if chosen == Some(n as i64) {
                                c.stroke_rounded(f.inset_by(-3.0, -3.0), DotRow::DOT / 2.0 + 3.0, 1.5, t.label());
                            }
                        }
                        if ring {
                            InspectorDraw::focus_line(c, boxed, radius::CONTROL as f64, t);
                        }
                    } else {
                        let track = CGRect::new(boxed.min_x(), boxed.mid_y() - 11.0, boxed.width, 22.0);
                        segment_draw::track(c, track, t);
                        let widths = self.segment_cache.get(&i).cloned().unwrap_or_default();
                        for (n, o) in options.iter().enumerate() {
                            let before: f64 = widths.iter().take(n).sum();
                            let seg = CGRect::new(
                                track.min_x() + 1.0 + before,
                                track.min_y() + 1.0,
                                widths.get(n).copied().unwrap_or(0.0),
                                track.height - 2.0,
                            );
                            let hot = hover && hp.is_some_and(|p| seg.contains(p));
                            c.stone_segment(
                                seg,
                                self.index(id) == Some(n as i64),
                                Touch { hovering: hot, ..Touch::default() },
                                t,
                            );
                            text(c, &SQL10n::string(o), seg, body, t.label(), TextAlign::Center);
                        }
                        if ring {
                            InspectorDraw::focus_line(c, track, radius::CONTROL as f64, t);
                        }
                    }
                }
                Row::Label { label, .. } => title_text(
                    c,
                    &SQL10n::string(label),
                    label_rect,
                    font,
                    sidebar,
                    if strong { t.label() } else { t.label2() },
                    label_align,
                ),
                Row::Chart { title, bars, .. } => self.draw_chart(c, i, title, bars, t),
                Row::Picture { slot, width: pw, height: ph, ready, transport } => {
                    let (boxed, play, bar, tc) = self.picture_parts(i);
                    c.fill_rounded(boxed, radius::SMALL as f64, t.fill());
                    if *ready {
                        let r = ExportPreviewMath::picture_rect(
                            sq_uikit::keyframe_graph_geometry::Rect {
                                x: boxed.min_x(),
                                y: boxed.min_y(),
                                width: boxed.width,
                                height: boxed.height,
                            },
                            *pw,
                            *ph,
                        );
                        c.draw_image_slot(
                            *slot,
                            CGRect::new(r.x, r.y, r.width, r.height),
                            [0.0, 0.0, 1.0, 1.0],
                            Color::WHITE,
                        );
                    }
                    let can = transport.frames > 0;
                    let play_hot = can && hover && hp.is_some_and(|p| play.contains(p));
                    c.stone_button(play, ButtonKind::Quiet, Touch { hovering: play_hot, ..Touch::default() }, t);
                    let ink = if can { t.label2() } else { dim(t.label2()) };
                    let icon = if transport.playing { SQIcon::Pause } else { SQIcon::Play };
                    c.draw_icon(icon, CGPoint::new(play.mid_x() - 5.5, play.mid_y() - 5.5), 11.0, ink, None);
                    let track =
                        CGRect::new(bar.min_x() + m::BAR_INSET, bar.mid_y() - 2.0, bar.width - 2.0 * m::BAR_INSET, 4.0);
                    let kx = track.min_x() + track.width * transport.fraction.clamp(0.0, 1.0);
                    c.stone_slider_track(track, can.then_some((track.min_x(), kx)), Touch::default(), t);
                    if can {
                        c.stone_slider_knob(kx, bar.mid_y(), false, Touch::default(), t);
                        text(c, &transport.timecode, tc, font, t.label2(), TextAlign::Right);
                    }
                }
                Row::TextBox { id, .. } => self.draw_text_box(c, i, id, t, cx),
                Row::Gap(_) => {}
            }
            if let Some(id) = r.id()
                && let Some(cells) = self.grids.get(id).cloned()
            {
                for cell in &cells {
                    if let Some(tr) = self.grid_title_frames.get(&cell.field.id).copied() {
                        let card = sidebar && self.is_card_row(&r);
                        let base = if card && !cell.unit.is_empty() { t.label() } else { t.label3() };
                        let col = if self.scrub_off(&cell.field.id) { dim(base) } else { base };
                        text(
                            c,
                            &SQL10n::string(&cell.title),
                            tr,
                            font,
                            col,
                            if sidebar && !card { TextAlign::Right } else { TextAlign::Left },
                        );
                    }
                    let fs = focused && self.focused_scrub.as_deref() == Some(cell.field.id.as_str());
                    self.draw_scrub(c, &cell.field, fs, t, cx);
                    if !cell.unit.is_empty()
                        && !self.inside_units.contains(&cell.field.id)
                        && let Some(fb) = self.scrub_frames.get(&cell.field.id)
                    {
                        text(
                            c,
                            &SQL10n::string(&cell.unit),
                            CGRect::new(fb.max_x() + m::GRID_GAP, fb.min_y(), 60.0, fb.height),
                            font,
                            t.label3(),
                            TextAlign::Left,
                        );
                    }
                }
            }
            if let Some(id) = r.id()
                && let Some(st) = self.statuses.get(id).cloned()
                && let Some(line) = self.status_frames.get(&i).copied()
            {
                self.draw_status(c, i, &st, line, t);
            }
            if let Some(lines) = self.help_lines.get(&i) {
                let mut y = self.help_tops.get(&i).copied().unwrap_or(boxed.max_y() + m::HELP_GAP);
                let x = if sidebar { row.min_x() + self.cpad() + self.cside() } else { boxed.min_x() };
                let beside = self.help_cols.get(&i).copied().unwrap_or_else(|| self.text_col(i, x, boxed));
                for l in lines {
                    let cut;
                    let l = if self.kit_cards {
                        cut = c.ellipsized(
                            l,
                            font,
                            0,
                            (row.width - 2.0 * (self.cpad() + self.cside()) - m::SWITCH_W - 16.0).min(beside),
                        );
                        &cut
                    } else {
                        l
                    };
                    text(
                        c,
                        l,
                        CGRect::new(x, y, if sidebar { beside } else { m::HELP_MAX_WIDTH }, self.help_line()),
                        font,
                        t.label3(),
                        TextAlign::Left,
                    );
                    y += self.help_line();
                }
            }
            if let Some(id) = r.id()
                && self.pill_hints.contains(id)
                && let Some(hint) = self.hints.get(id).filter(|h| !h.is_empty())
            {
                // The aspect as a small raised pill right of the fields (design `.ar`: 20 high, radius 3, semibold).
                let x = boxed.max_x() + m::CONTROL_GAP + 4.0;
                let w = (tm.width(&SQL10n::string(hint), 11.0, 0).ceil() + 12.0).max(44.0);
                let pill = CGRect::new(x, boxed.mid_y() - 10.0, w, 20.0);
                c.fill_rounded(pill, 3.0, t.raised());
                text(c, &SQL10n::string(hint), pill, 11.0, t.label(), TextAlign::Center);
                // The unit of the two size fields, after the pill (kit `Unit`).
                let unit = CGRect::new(pill.max_x() + 10.0, pill.min_y(), 24.0, pill.height);
                text(c, "px", unit, 11.0, t.label3(), TextAlign::Left);
            } else if let Some(id) = r.id()
                && !self.shape_cards.contains_key(id)
                && let Some(hint) = self.hints.get(id).filter(|h| !h.is_empty())
            {
                let x = boxed.max_x() + m::CONTROL_GAP + self.label_inset;
                text(
                    c,
                    &SQL10n::string(hint),
                    CGRect::new(x, boxed.min_y(), (row.max_x() - self.side_pad - x).max(0.0), row_h),
                    body,
                    t.label3(),
                    TextAlign::Left,
                );
            }
        }
        if let Some(link) = &self.link
            && self.link_frame.width > 0.0
        {
            let on = self.bool(&link.id) == Some(true);
            let off = link.fields.iter().any(|f| self.disabled.contains(f));
            // art.html 23: a dialog's link glyph stays neutral
            let tint = if on && sidebar { t.accent() } else { t.label2() };
            if !sidebar {
                let lf = self.link_frame;
                c.stone_button(lf, ButtonKind::Raised, Touch { disabled: off, ..Touch::default() }, t);
            }
            let lf = self.link_frame;
            c.draw_icon(
                if on { SQIcon::Link } else { SQIcon::Unlink },
                CGPoint::new(lf.mid_x() - 6.0, (lf.mid_y() - 6.0).round()),
                12.0,
                if off { dim(tint) } else { tint },
                None,
            );
        }
    }

    /// One list line with an icon, the name, the gray detail (cut at the end) and the warning word, 12 inside the box,
    /// `Theme.Spacing.sm` between the parts (the Mac `listLine`).
    #[allow(clippy::too_many_arguments)]
    fn draw_list_line(
        &self,
        c: &mut Canvas,
        name: &str,
        x: &ListLine,
        boxed: CGRect,
        r: CGRect,
        t: &DrawTheme,
        tm: &TextMeasure,
    ) {
        let font = self.font();
        let gap = sq_draw::theme::spacing::SM as f64;
        let mut cursor = boxed.min_x() + 12.0;
        let limit = r.min_x() - gap;
        if let Some(icon) = x.icon {
            c.draw_icon(icon, CGPoint::new(cursor, (r.mid_y() - 6.5).round()), 13.0, t.label3(), None);
            cursor += 13.0 + gap;
        }
        let name_w = tm.width(name, font, 0).ceil();
        text(
            c,
            name,
            CGRect::new(cursor, r.min_y(), name_w.min((limit - cursor).max(0.0)), r.height),
            font,
            t.label(),
            TextAlign::Left,
        );
        cursor += name_w + gap;
        let mut end = limit;
        if let Some(w) = &x.warning {
            let ww = tm.width(&SQL10n::string(w), font, 0).ceil();
            end -= ww + gap;
            if end > cursor {
                text(
                    c,
                    &SQL10n::string(w),
                    CGRect::new(end + gap, r.min_y(), ww, r.height),
                    font,
                    t.warning(),
                    TextAlign::Left,
                );
            }
        }
        if end > cursor && !x.detail.is_empty() {
            // A long path keeps both ends and loses the middle (`lineBreakMode = .byTruncatingMiddle`).
            let detail = tm.truncated_middle(&x.detail, end - cursor, font);
            text(c, &detail, CGRect::new(cursor, r.min_y(), end - cursor, r.height), font, t.label3(), TextAlign::Left);
        }
    }

    /// The Mac Edit API status line: dot (idle `label3`, ok green, warning), text (`label3` idle, else `label2`), button.
    fn draw_status(&self, c: &mut Canvas, i: usize, st: &Status, line: CGRect, t: &DrawTheme) {
        let font = self.font();
        let dot = match st.tone {
            StatusTone::Idle => t.label3(),
            StatusTone::Ok => t.green(),
            StatusTone::Warning => t.warning(),
        };
        // art.html: a 4 pt dot, centered in the 8 pt slot before the text.
        c.fill_ellipse(
            CGRect::new(
                line.min_x() + m::STATUS_DOT / 4.0,
                line.mid_y() - m::STATUS_DOT / 4.0,
                m::STATUS_DOT / 2.0,
                m::STATUS_DOT / 2.0,
            ),
            dot,
        );
        let tx = line.min_x() + m::STATUS_DOT + m::GRID_GAP;
        let right = self.status_button_frames.get(&i).map_or(line.max_x(), |b| b.min_x());
        text(
            c,
            &SQL10n::string(&st.text),
            CGRect::new(tx, line.min_y(), (right - tx).max(0.0), line.height),
            font,
            if st.tone == StatusTone::Idle { t.label3() } else { t.label2() },
            TextAlign::Left,
        );
        let (Some(b), Some(title)) = (self.status_button_frames.get(&i).copied(), st.button.as_ref()) else { return };
        let hover = self.hovered == Some(i) && self.hovered_point.is_some_and(|p| b.contains(p));
        InspectorDraw::button(c, "", b, hover, false, true, false, InspectorTokens::CAPSULE as f64, t);
        let mut x = b.min_x() + InspectorDraw::BUTTON_PADDING;
        if let Some(icon) = st.button_icon {
            c.draw_icon(icon, CGPoint::new(x, (b.mid_y() - 6.0).round()), 12.0, t.label(), None);
            x += 18.0;
        }
        text(
            c,
            &SQL10n::string(title),
            CGRect::new(x, b.min_y(), (b.max_x() - x).max(0.0), b.height),
            font,
            t.label(),
            TextAlign::Left,
        );
    }

    /// `CutCheckSheetView` + `ShotHistogramView`: the note, the chart title, a column per bar (count over a bar with 3 pt top
    /// corners, label under it).
    fn draw_chart(&self, c: &mut Canvas, i: usize, title: &str, bars: &[Bar], t: &DrawTheme) {
        let Some(parts) = self.chart_parts.get(&i).copied() else { return };
        let boxed = self.control_frames[i];
        let size = type_size::BODY as f64;
        let mut y = boxed.min_y();
        for l in self.note_lines.get(&i).cloned().unwrap_or_default() {
            text(c, &l, CGRect::new(boxed.min_x(), y, boxed.width, m::NOTE_LINE), size, t.label2(), TextAlign::Left);
            y += m::NOTE_LINE;
        }
        let medium = c.medium();
        c.draw_text_in(
            &SQL10n::string(title),
            CGRect::new(boxed.min_x(), parts.0, boxed.width, m::CHART_TITLE_LINE),
            size,
            t.label2(),
            TextAlign::Left,
            0.0,
            medium,
        );
        if bars.is_empty() {
            return;
        }
        let chart = parts.1;
        let cap = type_size::CAPTION as f64;
        let top = bars.iter().map(|b| b.count).max().unwrap_or(1).max(1);
        let col_w = (chart.width - m::GRID_GAP * (bars.len() as f64 - 1.0)) / bars.len() as f64;
        let baseline = chart.max_y() - m::CHART_LINE - m::CHART_INNER;
        c.fill(CGRect::new(chart.min_x(), baseline, chart.width, 1.0), t.hair2()); // one shared baseline
        for (n, b) in bars.iter().enumerate() {
            let x = chart.min_x() + n as f64 * (col_w + m::GRID_GAP);
            let h =
                if b.count == 0 { 0.0 } else { 3.0_f64.max((m::CHART_BAR_MAX * b.count as f64 / top as f64).round()) };
            let bar = CGRect::new(x, baseline - h, col_w, h);
            if h > 0.0 {
                // art.html 33: one flat gray, rounded top corners
                let tint = t.label4();
                c.fill_rounded(bar, 3.0, tint);
                c.fill(
                    CGRect::new(bar.min_x(), bar.max_y() - 3.0_f64.min(h / 2.0), bar.width, 3.0_f64.min(h / 2.0)),
                    tint,
                );
            }
            text(
                c,
                &format!("{}", b.count),
                CGRect::new(x, bar.min_y() - m::CHART_INNER - m::CHART_LINE, col_w, m::CHART_LINE),
                cap,
                t.label2(),
                TextAlign::Center,
            );
            text(
                c,
                &b.label,
                CGRect::new(x, baseline + m::CHART_INNER, col_w, m::CHART_LINE),
                cap,
                t.label3(),
                TextAlign::Center,
            );
        }
    }

    /// `ProjectNotesDialog.NotesBox`: field fill, radius 8, a 1 pt `fieldEdge` (`accentRing` while it edits), body text 6 in.
    fn draw_text_box(&mut self, c: &mut Canvas, i: usize, id: &str, t: &DrawTheme, cx: &mut UiCx) {
        let boxed = self.control_frames[i];
        let size = type_size::BODY as f64;
        let rad = 8.0;
        let editing = self.box_editor.is_some() && self.focused == Some(i);
        c.stone_field(boxed, rad, editing, Touch::default(), t);
        let visible = boxed.inset_by(m::BOX_INSET, m::BOX_INSET);
        // art.html notes: the placeholder (label4) shows while the box is empty, with or without the caret.
        let empty = self.text(id).unwrap_or_default().is_empty()
            || (editing && self.box_editor.as_ref().is_some_and(|e| e.text().is_empty()));
        if empty && let Some(ph) = self.placeholders.get(id).filter(|p| !p.is_empty()) {
            text(
                c,
                &SQL10n::string(ph),
                CGRect::new(visible.min_x(), visible.min_y(), visible.width, m::BOX_LINE),
                size,
                t.label4(),
                TextAlign::Left,
            );
        }
        if editing && let Some(e) = &self.box_editor {
            let line = e.position(e.caret()).0 as f64;
            if (line + 1.0) * m::BOX_LINE - self.box_scroll > visible.height {
                self.box_scroll = (line + 1.0) * m::BOX_LINE - visible.height;
            }
            if line * m::BOX_LINE < self.box_scroll {
                self.box_scroll = line * m::BOX_LINE;
            }
            c.save_gstate();
            c.clip_to(visible);
            InspectorDraw::edit_lines(
                c,
                e,
                CGRect::new(
                    visible.min_x(),
                    visible.min_y() - self.box_scroll,
                    visible.width,
                    visible.height + self.box_scroll,
                ),
                m::BOX_LINE,
                size,
                t.label(),
                t,
                cx,
            );
            c.restore_gstate();
            return;
        }
        c.save_gstate();
        c.clip_to(visible);
        let mut y = visible.min_y() - self.box_scroll;
        for l in self.text(id).unwrap_or_default().split('\n') {
            text(c, l, CGRect::new(visible.min_x(), y, visible.width, m::BOX_LINE), size, t.label(), TextAlign::Left);
            y += m::BOX_LINE;
        }
        c.restore_gstate();
    }

    /// The Mac `SettingsSidebarRow`: icon 14 and title, the selected page on `fill`, the rule after the column.
    /// The page title, its subtitle, the card backgrounds and the hairlines between rows (frame `Settings / General`).
    fn draw_cards(&self, c: &mut Canvas, t: &DrawTheme) {
        if let Some((title, _)) = &self.page_header {
            let o = self.header_origin;
            let x = o.x + self.cpad() + 2.0;
            let face = c.semibold();
            let w = 500.0;
            c.draw_text_in(
                &SQL10n::string(title),
                CGRect::new(x, o.y + 26.0, w, 24.0),
                type_size::DISPLAY as f64,
                t.label(),
                TextAlign::Left,
                0.0,
                face,
            );
            // Wrapped to the card column in `layout_at`: a narrow page gets a second line, never a cut.
            let sub_w = self.subtitle_width();
            for (n, l) in self.subtitle_lines.iter().enumerate() {
                let r = CGRect::new(x, o.y + 54.0 + n as f64 * m::SUBTITLE_LINE, sub_w, m::SUBTITLE_LINE);
                text(c, l, r, self.font(), t.label3(), TextAlign::Left);
            }
        }
        for r in &self.card_rects {
            c.fill_rounded(*r, m::CARD_RADIUS, t.token(sq_uikit::redesign_tokens::color::GROUP));
        }
        for d in &self.dividers {
            c.fill(*d, t.row_line());
        }
    }

    /// The color of a page's icon tile (`TILE` in the kit's prefs-body.html).
    pub(crate) fn tile_color(title: &str) -> Color {
        Color::hex(
            match title {
                "General" => 0x5A5A60,
                "Playback" => 0x2F6FB0,
                "Editing" => 0x7350C0,
                "Audio" => 0x1E8449,
                "Media" => 0xA8741C,
                "Shortcuts" => 0x9C3F79,
                _ => 0x4F78A3,
            },
            1.0,
        )
    }

    fn draw_sidebar(&self, c: &mut Canvas, sidebar: &Sidebar, t: &DrawTheme, ui: &mut UiCx) {
        // `Sidebar` of the Settings frame: the chrome color, rounded at the window's top-left corner only.
        let rule = self.sidebar_rule;
        let col = CGRect::new(
            rule.min_x() - m::SIDEBAR_WIDTH,
            rule.min_y(),
            m::SIDEBAR_WIDTH,
            rule.height + self.sidebar_extra,
        );
        let chrome = t.token(sq_uikit::redesign_tokens::color::CHROME);
        c.fill_rounded(CGRect::new(col.min_x(), col.min_y(), col.width, 48.0_f64.min(col.height)), 12.0, chrome);
        c.fill(CGRect::new(col.min_x() + 12.0, col.min_y(), col.width - 12.0, col.height), chrome);
        if self.sidebar_extra > 0.0 {
            // The column reaches the window's bottom: its bottom-left corner follows the window's.
            c.fill_rounded(CGRect::new(col.min_x(), col.max_y() - 48.0, col.width, 48.0), 12.0, chrome);
            c.fill(CGRect::new(col.min_x(), col.min_y() + 24.0, col.width, (col.height - 48.0).max(0.0)), chrome);
        } else {
            c.fill(CGRect::new(col.min_x(), col.min_y() + 24.0, col.width, (col.height - 24.0).max(0.0)), chrome);
        }
        if let Some(search) = &self.search {
            let f = self.search_frame;
            c.fill_rounded(f, radius::CONTROL as f64, t.well());
            c.stroke_rounded(f.inset_by(0.25, 0.25), radius::CONTROL as f64, 0.5, t.hair2());
            c.draw_icon(SQIcon::Search, CGPoint::new(f.min_x() + 8.0, f.mid_y() - 6.0), 12.0, t.label3(), None);
            let tr = CGRect::new(f.min_x() + 26.0, f.min_y(), (f.width - 26.0 - 8.0).max(0.0), f.height);
            let query = self.search_text();
            search.draw(c, tr, t, search.is_editing(), ui);
            if query.is_empty() {
                text(c, "Search settings", tr, self.font(), t.label3(), TextAlign::Left);
            }
            if search.is_editing() {
                c.stroke_rounded(f.inset_by(0.5, 0.5), radius::CONTROL as f64, 1.0, t.accent());
            }
        }
        let sel = self.index(&sidebar.id).unwrap_or(0);
        for (n, r) in self.sidebar_frames.iter().enumerate().filter(|(n, _)| *n < sidebar.items.len()) {
            let on = n as i64 == sel;
            c.stone_pill(*r, on, self.sidebar_hovered == Some(n), t);
            if on && self.sidebar_focused {
                InspectorDraw::focus_line(c, *r, radius::SMALL as f64, t);
            }
            let (title, icon) = &sidebar.items[n];
            if let Some(&k) = self.sidebar_counts.get(n).filter(|k| **k > 0) {
                text(
                    c,
                    &k.to_string(),
                    CGRect::new(r.max_x() - 30.0, r.min_y(), 22.0, r.height),
                    11.0,
                    t.accent(),
                    TextAlign::Right,
                );
            }
            let tile = CGRect::new(r.min_x() + 6.0, (r.mid_y() - 9.0).round(), 18.0, 18.0);
            c.fill_rounded(tile, 5.0, Self::tile_color(title));
            c.draw_icon(*icon, CGPoint::new(tile.min_x() + 3.5, tile.min_y() + 3.5), 11.0, Color::WHITE, None);
            text(
                c,
                &SQL10n::string(title),
                CGRect::new(r.min_x() + 6.0 + 18.0 + 8.0, r.min_y(), (r.width - 42.0).max(0.0), r.height),
                self.font(),
                if on { t.label() } else { t.label2() },
                TextAlign::Left,
            );
        }
        c.fill(self.sidebar_rule, t.hair());
    }
}

// MARK: The dialog's view of the form

impl DialogForm for ShellForm {
    fn status_text(&self, id: &str) -> Option<String> {
        self.statuses.get(id).map(|s| s.text.clone())
    }

    fn replace_status(&mut self, id: &str, status: Status) -> bool {
        let known = self.statuses.contains_key(id);
        if known {
            self.statuses.insert(id.to_string(), status);
        }
        known
    }

    fn focus_first_text_field(&mut self) -> bool {
        self.focus_first_text_field_row()
    }
    fn focused(&self) -> Option<usize> {
        self.focused
    }
    fn set_kit_cards(&mut self, on: bool) {
        self.kit_cards = on;
    }
    fn set_fixed_label_column(&mut self, width: Option<f64>) {
        self.fixed_label_column = width;
    }
    fn has_sidebar(&self) -> bool {
        self.sidebar.is_some()
    }
    fn sidebar_focused(&self) -> bool {
        self.sidebar_focused
    }
    fn take_search_editing(&mut self) -> Option<TextFieldControl> {
        if self.search_editing() { self.search.take() } else { None }
    }
    fn search_field(&self) -> Option<(CGRect, bool, String)> {
        self.search.is_some().then(|| (self.search_frame, self.search_editing(), self.search_text()))
    }
    fn height(&mut self, width: f64, m: &TextMeasure) -> f64 {
        self.height_at(width, m)
    }
    fn first_row_gap(&self) -> f64 {
        self.extra_gap_before.get(&0).copied().unwrap_or(0.0)
    }
    fn set_sidebar_shift(&mut self, shift: f64) {
        self.sidebar_shift = shift;
    }
    fn set_sidebar_extra(&mut self, h: f64) {
        self.sidebar_extra = h;
    }
    fn set_viewport_height(&mut self, h: f64) {
        self.viewport_height = h;
    }
    fn layout(&mut self, origin: CGPoint, width: f64, m: &TextMeasure) {
        self.layout_at(origin, width, m);
    }
    fn row_frames(&self) -> &[CGRect] {
        &self.row_frames
    }
    fn picker_open(&self) -> bool {
        self.picker.is_some()
    }
    fn picker_key(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx) {
        self.picker_press_key(k, m, cx);
    }
    fn picker_mouse_down(&mut self, p: CGPoint) {
        self.picker_press(p);
    }
    fn picker_mouse_dragged(&mut self, p: CGPoint) {
        self.picker_drag(p);
    }
    fn picker_mouse_up(&mut self) {
        self.picker_release();
    }
    fn key(&mut self, k: InputKey, m: InputModifiers, cx: &mut UiCx) -> bool {
        self.key_event(k, m, cx)
    }
    fn commit_editing(&mut self) {
        self.commit_editing_inner();
    }
    fn set_value(&mut self, id: &str, v: FormValue) {
        self.set(id, v);
    }
    fn row_ids(&self) -> Vec<String> {
        self.rows.iter().filter_map(|r| r.id().map(str::to_string)).collect()
    }
    fn set_marks(&mut self, changed: BTreeSet<String>, counts: Vec<usize>) {
        self.changed = changed;
        self.sidebar_counts = counts;
    }
    fn set_row_detail(&mut self, id: &str, detail: &str) {
        self.set_detail(id, detail);
    }
    fn set_preview_transport(&mut self, t: PreviewTransport) {
        if let Some(now) = self.transport_mut() {
            *now = t;
        }
    }
    fn set_picture(&mut self, width: i64, height: i64, ready: bool) {
        for r in &mut self.rows {
            if let Row::Picture { width: w, height: h, ready: on, .. } = r {
                (*w, *h, *on) = (width, height, ready);
            }
        }
    }
    fn a11y_fields(&self) -> Vec<crate::shell_dialog::FormField> {
        let mut out = Vec::new();
        let mut add = |id: &str, label: &str, options: Vec<String>, default: FormValue| {
            let value = self.values.get(id).cloned().unwrap_or(default);
            let label = self.a11y_labels.get(id).map_or(label, String::as_str);
            out.push(crate::shell_dialog::FormField {
                id: id.to_string(),
                label: SQL10n::string(label),
                value,
                options: options.iter().map(|o| SQL10n::string(o)).collect(),
            });
        };
        for r in &self.rows {
            match r {
                Row::Field { id, label, value, .. } => add(id, label, vec![], FormValue::Text(value.clone())),
                Row::TextBox { id, value, .. } => add(id, id, vec![], FormValue::Text(value.clone())),
                Row::Check { id, title, on } => add(id, title, vec![], FormValue::Bool(*on)),
                Row::Radio { id, options, selected } if self.a11y_labels.contains_key(id) => {
                    add(id, "", options.clone(), FormValue::Index(*selected));
                }
                Row::Popup { id, label, options, selected } | Row::Segmented { id, label, options, selected, .. } => {
                    add(id, label, options.clone(), FormValue::Index(*selected));
                }
                Row::Slider { id, label, value, .. } => add(id, label, vec![], FormValue::Number(*value)),
                Row::Number { label, field } | Row::SliderNumber { label, field } => {
                    add(&field.id, label, vec![], FormValue::Number(field.value));
                }
                Row::Size { label, width, height } => {
                    add(&width.id, &format!("{label} width"), vec![], FormValue::Number(width.value));
                    add(&height.id, &format!("{label} height"), vec![], FormValue::Number(height.value));
                }
                _ => {}
            }
        }
        out
    }
    fn a11y_edit(&mut self, id: &str, v: FormValue) -> bool {
        let Some(field) = DialogForm::a11y_fields(self).into_iter().find(|f| f.id == id) else { return false };
        let v = match (&field.value, v) {
            (FormValue::Index(_), FormValue::Index(i)) if usize::try_from(i).is_ok_and(|i| i < field.options.len()) => {
                FormValue::Index(i)
            }
            (FormValue::Text(_), FormValue::Number(n)) => FormValue::Text(Self::format(n)),
            (FormValue::Number(_), FormValue::Text(t)) => match t.trim().parse() {
                Ok(n) => FormValue::Number(n),
                Err(_) => return false,
            },
            (FormValue::Index(_), _) => return false,
            (FormValue::Text(_), v @ FormValue::Text(_))
            | (FormValue::Bool(_), v @ FormValue::Bool(_))
            | (FormValue::Number(_), v @ FormValue::Number(_)) => v,
            _ => return false,
        };
        self.set(id, v.clone());
        self.notify(id, v);
        true
    }
    fn mouse_down(&mut self, p: CGPoint, tm: &TextMeasure) -> bool {
        self.press_at(p, InputModifiers::NONE, tm)
    }
    fn mouse_dragged(&mut self, p: CGPoint, tm: &TextMeasure, cx: &mut UiCx) {
        self.drag_at(p, tm, cx);
    }
    fn mouse_up(&mut self, cx: &mut UiCx) {
        self.release(cx);
    }
    fn mouse_moved(&mut self, p: CGPoint) {
        self.hover_at(p);
    }
    fn set_overlay_bounds(&mut self, window: CGRect) {
        self.overlay_bounds = window;
    }
    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.draw_rows(c, t, cx);
    }
    fn draw_overlay(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut UiCx) {
        self.draw_picker(c, t, cx);
    }
    fn push_change(&mut self, id: &str, v: FormValue) {
        self.notify(id, v);
    }
    fn take_changes(&mut self) -> Vec<(String, FormValue)> {
        self.sync();
        std::mem::take(&mut self.changes)
    }
    fn take_popup(&mut self) -> Option<PopupRequest> {
        self.popup_request.take()
    }
    fn text(&self, id: &str) -> Option<String> {
        ShellForm::text(self, id)
    }
    fn index(&self, id: &str) -> Option<i64> {
        ShellForm::index(self, id)
    }
    fn bool(&self, id: &str) -> Option<bool> {
        ShellForm::bool(self, id)
    }
    fn number(&self, id: &str) -> Option<f64> {
        ShellForm::number(self, id)
    }
    fn color(&self, id: &str) -> Option<SQColorValue> {
        ShellForm::color(self, id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn tm() -> TextMeasure<'static> {
        TextMeasure::new(None, 1.0)
    }

    /// A form laid out at the width of a 600 pt card at x 100.
    fn form(rows: Vec<Row>) -> ShellForm {
        let mut f = ShellForm::new(rows);
        f.layout_at(CGPoint::new(100.0, 100.0), 600.0, &tm());
        f
    }

    fn click(f: &mut ShellForm, p: CGPoint) -> bool {
        let took = f.press_at(p, InputModifiers::NONE, &tm());
        f.release(&mut UiCx::default());
        took
    }

    fn type_text(f: &mut ShellForm, s: &str) {
        let mut ui = UiCx::default();
        for ch in s.chars() {
            f.key_event(InputKey::Character(ch), InputModifiers::NONE, &mut ui);
        }
    }

    fn center(r: CGRect) -> CGPoint {
        CGPoint::new(r.mid_x(), r.mid_y())
    }

    /// The label column fits its longest label (no "Interface Langu..."), within 56...160 pt.
    #[test]
    fn the_label_column_grows_to_its_longest_label() {
        assert_eq!(form(vec![Row::field("name", "Name", "")]).label_width(), 56.0);
        assert_eq!(form(vec![Row::popup("l", "Interface Language", &["English"], 0)]).label_width(), 109.0); // 18 chars at the atlas-free 0.55 em, 11 pt
        assert_eq!(form(vec![Row::field("x", &"W".repeat(40), "")]).label_width(), 160.0);
    }

    /// The Mac `SQDialog.popupRow` (Save as Preset): an unlabeled popup row is the 22 pt popup, on a 26 pt line.
    #[test]
    fn an_unlabeled_popup_row_is_the_22pt_popup() {
        let f = form(vec![Row::field("name", "", "My Look"), Row::popup("a", "", &["Anchor to In Point"], 0)]);
        assert!(f.row_frames()[0].height == 26.0 && f.control_frames()[1].height == 22.0);
        // 22 pt wells on 26 pt lines, 4 apart (pitch 30)
        assert_eq!(f.control_frames()[1].min_y() - f.control_frames()[0].max_y(), 8.0);
    }

    #[test]
    fn rows_stack_with_the_mac_form_metrics() {
        let f = form(vec![
            Row::field("name", "Name", "Untitled"),
            Row::popup("t", "Template", &["Empty", "Vlog"], 0),
            Row::check("c", "Open after", true),
        ]);
        assert_eq!(f.row_frames().len(), 3);
        assert_eq!(f.row_frames()[1].min_y() - f.row_frames()[0].max_y(), 4.0);
        assert!(f.row_frames()[0].height == 26.0 && f.row_frames()[2].height == 22.0);
        // flush with the control column (art.html, no Mac frame bleed)
        assert_eq!(f.control_frames()[0].min_x(), 100.0 + 16.0 + 56.0 + 12.0);
        assert_eq!(f.control_frames()[0].max_x(), 100.0 + 600.0 - 16.0);
    }

    #[test]
    fn typing_in_a_field_and_commit_answers_with_the_new_value() {
        let mut f = form(vec![Row::field("name", "Name", "")]);
        let c0 = center(f.control_frames()[0]);
        click(&mut f, c0);
        assert!(f.is_editing());
        type_text(&mut f, "Trip");
        f.commit_editing_inner();
        assert_eq!(f.text("name").as_deref(), Some("Trip"));
        assert_eq!(f.take_changes().last(), Some(&("name".to_string(), FormValue::Text("Trip".to_string()))));
    }

    #[test]
    fn escape_in_an_open_field_cancels_the_edit() {
        let mut f = form(vec![Row::field("name", "Name", "A")]);
        let c0 = center(f.control_frames()[0]);
        click(&mut f, c0);
        type_text(&mut f, "BC");
        assert!(f.key_event(InputKey::Escape, InputModifiers::NONE, &mut UiCx::default()));
        assert_eq!(f.text("name").as_deref(), Some("A"));
        assert!(!f.is_editing());
        // a second Escape is the dialog's
        assert!(!f.key_event(InputKey::Escape, InputModifiers::NONE, &mut UiCx::default()));
    }

    /// Audit P1: the first Esc in the Name field of New project used to do nothing; with no change to undo it closes the sheet.
    #[test]
    fn escape_in_an_unchanged_field_is_the_dialogs() {
        let mut f = form(vec![Row::field("name", "Name", "A")]);
        let c0 = center(f.control_frames()[0]);
        click(&mut f, c0);
        assert!(f.is_editing());
        assert!(!f.key_event(InputKey::Escape, InputModifiers::NONE, &mut UiCx::default()));
        assert!(!f.is_editing());
        assert_eq!(f.text("name").as_deref(), Some("A"));
    }

    #[test]
    fn tab_walks_the_rows_and_space_toggles_the_check() {
        let mut f = form(vec![Row::field("name", "Name", "X"), Row::check("c", "Open after", false)]);
        assert!(f.focus_first_text_field_row());
        assert_eq!(f.focused_row(), Some(0));
        let mut ui = UiCx::default();
        assert!(f.key_event(InputKey::Character('\t'), InputModifiers::NONE, &mut ui));
        assert_eq!(f.focused_row(), Some(1));
        f.key_event(InputKey::Space, InputModifiers::NONE, &mut ui);
        assert_eq!(f.bool("c"), Some(true));
        // past the last row the dialog's buttons take Tab
        assert!(!f.key_event(InputKey::Character('\t'), InputModifiers::NONE, &mut ui));
        assert_eq!(f.focused_row(), None);
    }

    #[test]
    fn a_popup_opens_its_list_and_the_choice_lands() {
        let mut f = form(vec![Row::popup("t", "Template", &["Empty", "Vlog", "Short"], 0)]);
        let c0 = center(f.control_frames()[0]);
        click(&mut f, c0);
        let req = f.take_popup().expect("the list");
        assert_eq!(req.items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(), ["Empty", "Vlog", "Short"]);
        assert!(req.items[0].is_checked);
        if let Some(a) = &req.items[2].action {
            a();
        }
        assert_eq!(f.take_changes(), vec![("t".to_string(), FormValue::Index(2))]);
        assert_eq!(f.index("t"), Some(2));
    }

    #[test]
    fn slider_drag_clamps_to_the_range() {
        let mut f = form(vec![Row::slider("q", "Quality", 50.0, 0.0..=100.0)]);
        let c = f.control_frames()[0];
        click(&mut f, CGPoint::new(c.min_x(), c.mid_y()));
        assert_eq!(f.number("q"), Some(0.0));
        f.press_at(CGPoint::new(c.min_x() + 1.0, c.mid_y()), InputModifiers::NONE, &tm());
        f.drag_at(CGPoint::new(c.max_x() + 500.0, c.mid_y()), &tm(), &mut UiCx::default());
        assert_eq!(f.number("q"), Some(100.0));
    }

    #[test]
    fn radio_rows_pick_by_position_and_arrows_step() {
        let mut f = form(vec![Row::radio("r", &["A", "B", "C"], 0)]);
        let c = f.control_frames()[0];
        click(&mut f, CGPoint::new(c.min_x() + 5.0, c.min_y() + 24.0 * 2.0 + 5.0));
        assert_eq!(f.index("r"), Some(2));
        f.key_event(InputKey::Up, InputModifiers::NONE, &mut UiCx::default());
        assert_eq!(f.index("r"), Some(1));
    }

    #[test]
    fn segmented_rows_pick_the_segment_under_the_press() {
        let mut f = form(vec![Row::segmented("s", "Mode", &["One", "Two"], 0, 60.0)]);
        let c = f.control_frames()[0];
        click(&mut f, CGPoint::new(c.min_x() + 1.0 + 60.0 + 10.0, c.mid_y()));
        assert_eq!(f.index("s"), Some(1));
    }

    #[test]
    fn the_focus_ring_shows_for_keyboard_focus_only_and_wraps_the_dropdown_itself() {
        let mut f = form(vec![Row::popup("l", "Language", &["English", "German"], 0)]);
        assert!(f.move_focus(true));
        assert!(f.focus_visible, "Tab focus shows the ring");
        let c = f.control_frames()[0];
        f.focus_visible = false;
        click(&mut f, CGPoint::new(c.mid_x(), c.mid_y()));
        assert_eq!(f.focused_row(), Some(0));
        assert!(!f.focus_visible, "a mouse press never shows the ring");
        // The ring wraps the 180 wide control flush right in its slot, not the whole row slot.
        let slot = CGRect::new(100.0, 10.0, 400.0, 28.0);
        let control = ShellForm::sidebar_popup_rect(slot);
        assert_eq!((control.width, control.max_x(), control.min_y(), control.height), (180.0, 500.0, 10.0, 28.0));
        let narrow = ShellForm::sidebar_popup_rect(CGRect::new(0.0, 0.0, 120.0, 28.0));
        assert_eq!(narrow, CGRect::new(0.0, 0.0, 120.0, 28.0));
    }

    /// Audit P10: the "More options" disclosure kept its keyboard ring after a mouse click.
    #[test]
    fn a_disclosure_has_no_ring_after_a_click() {
        let mut f = form(vec![Row::field("name", "Name", "A"), Row::check("more", "More options", false)]);
        f.disclosures.insert("more".to_string());
        assert!(f.move_focus(true));
        assert!(f.move_focus(true));
        assert!(f.focus_visible);
        let c = f.control_frames()[1];
        click(&mut f, CGPoint::new(c.min_x() + 20.0, c.mid_y()));
        assert_eq!(f.focused_row(), Some(1));
        assert!(!f.focus_visible, "a mouse press never shows the ring");
        assert_eq!(f.bool("more"), Some(true));
    }

    #[test]
    fn a_number_field_takes_arrows_and_reports_the_value() {
        let field = NumberField::new("n", 5.0, 0.0..=10.0);
        let mut f = form(vec![Row::Number { label: "Amount".into(), field }]);
        assert!(f.move_focus(true));
        f.key_event(InputKey::Up, InputModifiers::NONE, &mut UiCx::default());
        assert!(f.number("n").is_some_and(|v| v != 5.0));
        assert!(!f.take_changes().is_empty());
    }

    #[test]
    fn set_note_replaces_a_text_row_only() {
        let mut f = form(vec![Row::Text("a".into()), Row::check("c", "x", false)]);
        f.set_note(0, "b", true, false, false);
        f.set_note(1, "never", false, false, false);
        assert_eq!(f.rows()[0], Row::Text("b".into()));
        assert!(matches!(f.rows()[1], Row::Check { .. }));
        assert!(f.warning_notes.contains(&0));
    }

    fn settings_form(rows: Vec<Row>) -> ShellForm {
        let sb = Sidebar { id: "page".into(), items: vec![("General".into(), SQIcon::Check)] };
        let mut f = ShellForm::with_sidebar(rows, Some(sb), 0);
        f.enable_search("");
        f.layout_at(CGPoint::ZERO, 900.0, &tm());
        f
    }

    /// P26: a Settings page (the sidebar form) shows no keyboard ring after a mouse click on any of its rows, whichever
    /// row kind was clicked and whether the keyboard held the ring before.
    #[test]
    fn a_click_on_any_settings_row_clears_the_keyboard_ring() {
        let mut f = settings_form(vec![
            Row::field("name", "Name", "A"),
            Row::check("a", "Option", true),
            Row::check("more", "More options", false),
            Row::check("b", "Other", false),
        ]);
        f.disclosures.insert("more".to_string());
        for i in 0..f.control_frames().len() {
            f.move_focus(true);
            let c = f.control_frames()[i];
            if c.width == 0.0 {
                continue;
            }
            click(&mut f, CGPoint::new(c.min_x() + 20.0, c.mid_y()));
            assert!(!f.focus_visible, "row {i}: a mouse press never shows the ring");
        }
    }

    #[test]
    fn a_changed_row_gets_a_reset_arrow_that_asks_for_its_factory_value() {
        let mut f = settings_form(vec![Row::check("a", "Option", true), Row::check("b", "Other", false)]);
        f.set_changed(["a".to_string()].into_iter().collect());
        f.layout_at(CGPoint::ZERO, 900.0, &tm());
        let ids: Vec<&str> = f.reset_frames().iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, ["a"]);
        let at = center(f.reset_frames()[0].1);
        assert!(click(&mut f, at));
        assert_eq!(f.take_changes(), vec![("reset:a".to_string(), FormValue::Bool(true))]);
    }

    #[test]
    fn counters_and_marks_do_not_move_the_rows() {
        let mut f = settings_form(vec![Row::check("a", "Option", true)]);
        let before = f.row_frames().to_vec();
        f.set_changed(["a".to_string()].into_iter().collect());
        f.set_sidebar_counts(vec![3]);
        f.layout_at(CGPoint::ZERO, 900.0, &tm());
        assert_eq!(before, f.row_frames());
    }

    #[test]
    fn the_sidebar_search_takes_clicks_and_typing_and_reports_the_text() {
        let mut f = settings_form(vec![Row::check("a", "Option", true)]);
        let first = f.sidebar_frames()[0];
        assert!(f.search_frame().max_y() <= first.min_y(), "the search sits above the first page");
        let at = center(f.search_frame());
        assert!(click(&mut f, at));
        assert!(f.search_editing());
        type_text(&mut f, "pro");
        assert_eq!(f.search_text(), "pro");
        let changes = f.take_changes();
        assert_eq!(changes.last(), Some(&("search".to_string(), FormValue::Text("pro".to_string()))));
        // Escape clears the text and tells the owner
        f.key_event(InputKey::Escape, InputModifiers::NONE, &mut UiCx::default());
        assert_eq!(f.search_text(), "");
        assert_eq!(f.take_changes().last(), Some(&("search".to_string(), FormValue::Text(String::new()))));
    }

    #[test]
    fn a_choice_row_shows_picture_cards_and_a_click_picks_the_card_under_it() {
        let mut f = settings_form(vec![Row::popup("look", "Appearance", &["Dark", "Light"], 0)]);
        f.set_choice_cards("look");
        f.layout_at(CGPoint::ZERO, 900.0, &tm());
        let area = f.control_frames()[0];
        assert!(area.height >= 78.0 + 16.0, "a picture and its caption");
        assert!(click(&mut f, CGPoint::new(area.max_x() - 10.0, area.min_y() + 30.0)));
        assert_eq!(f.index("look"), Some(1));
        assert_eq!(f.take_changes(), vec![("look".to_string(), FormValue::Index(1))]);
        // the same card again changes nothing
        click(&mut f, CGPoint::new(area.max_x() - 10.0, area.min_y() + 30.0));
        assert!(f.take_changes().is_empty());
    }

    #[test]
    fn a_sidebar_form_lists_pages_and_up_down_pick_them() {
        let sb = Sidebar {
            id: "page".into(),
            items: vec![("General".into(), SQIcon::Check), ("Media".into(), SQIcon::Check)],
        };
        let mut f = ShellForm::with_sidebar(vec![Row::check("c", "Option", false)], Some(sb), 0);
        f.layout_at(CGPoint::ZERO, 700.0, &tm());
        assert_eq!(f.sidebar_frames().len(), 2);
        assert!(f.press_at(center(f.sidebar_frames()[1]), InputModifiers::NONE, &tm()));
        assert_eq!(f.index("page"), Some(1));
        assert_eq!(f.take_changes(), vec![("page".to_string(), FormValue::Index(1))]);
    }

    #[test]
    fn on_change_can_edit_other_rows() {
        let mut f = ShellForm::new(vec![Row::popup("p", "P", &["A", "B"], 0), Row::field("name", "N", "")]);
        f.on_change = Some(Box::new(|form, id, _| {
            if id == "p" {
                form.set("name", FormValue::Text("picked".to_string()));
            }
        }));
        f.choose(0, 1);
        assert_eq!(f.text("name").as_deref(), Some("picked"));
    }

    #[test]
    fn the_picture_bar_plays_scrubs_and_steps() {
        let transport = PreviewTransport { frames: 100, fraction: 0.0, playing: false, timecode: "00:00:00:00".into() };
        let mut f = form(vec![Row::Picture { slot: 1, width: 1920, height: 1080, ready: true, transport }]);
        let (boxed, play, bar, _) = f.picture_parts(0);
        assert_eq!((play.min_y() - boxed.max_y(), play.height, play.width), (10.0, 22.0, 24.0));
        let mid = CGPoint::new(bar.mid_x(), bar.mid_y());
        assert!(click(&mut f, mid));
        match f.take_changes().last() {
            Some((id, FormValue::Number(n))) => assert!(id == "preview_scrub" && (n - 0.5).abs() < 0.02, "{id} {n}"),
            other => panic!("{other:?}"),
        }
        assert!(click(&mut f, CGPoint::new(play.mid_x(), play.mid_y())));
        assert_eq!(f.take_changes().last(), Some(&("preview_play".to_string(), FormValue::Bool(true))));
        assert!(f.picture_key(InputKey::Right));
        assert_eq!(f.take_changes().last(), Some(&("preview_step".to_string(), FormValue::Index(1))));
        assert!(!f.picture_key(InputKey::Up));
        // Without frames the bar and the keys do nothing.
        f.set_preview_transport(PreviewTransport::default());
        assert!(f.take_changes().is_empty());
        assert!(f.picture_key(InputKey::Space));
        assert!(f.take_changes().is_empty());
    }

    #[test]
    fn a_dot_row_picks_the_dot_under_the_click() {
        let mut f = ShellForm::new(vec![Row::segmented("c", "Color", &["A", "B", "C", "D"], 0, 0.0)]);
        f.dot_rows.insert("c".into(), vec![0xFF0000, 0x00FF00, 0x0000FF, 0xFFFF00]);
        f.layout_at(CGPoint::new(100.0, 100.0), 420.0, &tm());
        let dots = DotRow::frames(f.control_frames[0], 4);
        // right-aligned to the control column, 16 pt dots, 5 pt apart
        assert_eq!(dots[1].min_x() - dots[0].min_x(), 21.0);
        assert!((f.control_frames[0].width - DotRow::width(4)).abs() < 0.01);
        click(&mut f, CGPoint::new(dots[2].mid_x(), dots[2].mid_y()));
        assert_eq!(f.index("c"), Some(2));
    }

    #[test]
    fn a_segmented_row_wider_than_its_column_shrinks_to_fit() {
        let opts = ["Face".to_string(), "Whole Person".to_string(), "Skin".to_string()];
        let w = ShellForm::segment_widths(&opts, 0.0, 150.0, &tm());
        assert!(w.iter().sum::<f64>() + 2.0 <= 150.0, "{w:?}");
        // room to spare keeps the 24 pt padding
        let roomy = ShellForm::segment_widths(&opts, 0.0, 400.0, &tm());
        assert!(roomy.iter().sum::<f64>() > w.iter().sum::<f64>());
    }
}
