// Swift: EffectControlsDrawRows.swift
//! The smaller Effect Controls rows (masks, color groups, grade range, stabilizer, disclosures), translated from their Mac
//! views (`SubjectMaskRow`, `MaskControlsRow`, `MaskTrackRow`, `PictureMaskRow`, `MaskUseRow`, `ColorRangeMaskRow`,
//! `ColorRangeAmountRow`, `TrackMaskTrackRow`, `ColorGroupHeaderRow`, `ColorMatchRow`, `GradeRangeRow`, `GradeFadeRow`,
//! `ColorGraphSummaryRow`, `StabilizeAnalyzeRow`, `EQCurveHeaderRow`, `MultibandEditorRow`, `MultibandParamsRow`).
//! Each row is a list of widgets on the Mac frames; the panel draws, hit-tests and fires them in one place.
//!
//! The widget closures of the Swift rows capture the model and the panel; here they are `Rc<dyn Fn(&mut PanelCx)>` run
//! against the model at click time, and panel hooks are pushed as [`PanelEvent`]s.

use std::rc::Rc;

use sq_core_model::{ClipEffect, EffectCatalog, EffectColor, MaskMode};
use sq_core_time::{Id, Time};
use sq_draw::draw_list::Color;
use sq_draw::theme::type_size;
use sq_draw::{Alignment, Canvas, CheckState, InspectorDraw, InspectorTokens, ScrubFieldControl, UiCx};
use sq_editor_session::MarkersPanelModel;
use sq_uikit::controls_grid::{CGPoint, CGRect, ControlsGrid};
use sq_uikit::keyframe_control_state::KeyframeControlState;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqicon::SQIcon;
use sq_uikit::sqmenu_model::SQMenuItem;

use super::effect_controls_draw_input::stopwatch_in;
use super::effect_controls_draw_panel::{ColorTarget, EffectControlsDrawPanel, FieldId, PanelEvent, RowRef, Target};
use super::effect_controls_draw_surfaces::SurfaceKind;
use super::{MenuEntry, ModelMenu};
use crate::ec::controls_metrics::Portable;
use crate::ec::effect_controls_model::core::EffectControlsModel;
use crate::ec::effect_controls_model::layout::{EffectRow, EffectRowKind};
use crate::ec::effect_controls_model::property::EffectProperty;
use crate::ec::prelude::*;
use crate::ec::stabilize::StabilizeRowStatus;

/// What a widget action works on: the model, the events for the host, and where the widget sits.
pub struct PanelCx<'a> {
    /// The model.
    pub model: &'a mut EffectControlsModel,
    /// Hooks for the host.
    pub events: &'a mut Vec<PanelEvent>,
    /// The widget's frame in panel points (the anchor of a picker).
    pub anchor: CGRect,
    /// Whether the host answers "remove all keyframes?" questions.
    pub asks: bool,
}

/// A widget press released inside.
pub type WidgetAction = Rc<dyn Fn(&mut PanelCx)>;
/// A popup's rows.
pub type WidgetMenu = Rc<dyn Fn() -> ModelMenu>;
/// What a timecode field does with its typed text.
pub type TextCommit = Rc<dyn Fn(&mut EffectControlsModel, &str)>;

/// A new value of a scrub field.
pub type FieldChange = Rc<dyn Fn(&mut EffectControlsModel, f64)>;

/// A scrub field of a translated row (ScrubField's configuration and callbacks on the Mac row).
#[derive(Clone)]
pub struct FieldSpec {
    /// Sets range, step, unit ...
    pub configure: Rc<dyn Fn(&mut ScrubFieldControl)>,
    /// The value now.
    pub value: f64,
    /// A drag begins.
    pub begin: Rc<dyn Fn(&mut EffectControlsModel)>,
    /// A new value.
    pub change: FieldChange,
    /// The drag ends.
    pub end: Rc<dyn Fn(&mut EffectControlsModel)>,
}

/// What one control of a translated row is.
#[derive(Clone)]
pub enum WidgetKind {
    /// A label (`makeLabel`): text, color, size, alignment.
    Text(String, Option<Color>, Option<f64>, Alignment),
    /// SQCheckbox with its title right of the box.
    Check(String, CheckState),
    /// A popup with its current title.
    Popup(String),
    /// IconButton.
    Icon(SQIcon, Option<Color>),
    /// SQButton.
    Button(String),
    /// A progress bar.
    Progress(f64),
    /// A color well.
    Well(Color),
    /// A scrub field; `FieldSpec` configures it and takes its values.
    Field(FieldSpec),
    /// A text field (timecodes); the commit gets the typed text.
    TextField(String, TextCommit),
    /// InspectorSectionHeader: chevron, bold title, optional enable box (whole row toggles).
    Disclosure { title: String, open: bool, enabled: Option<bool> },
    /// The ring of a keyframe row.
    Ring(KeyframeControlState),
    /// Previous / key / next of a keyframe row (the whole navigation, hit slots are `Hit` widgets).
    Navigation(KeyframeControlState),
    /// Hit area only.
    Hit,
    /// A drawn editor with its own pointer handling (curves, EQ), cached per key.
    Surface(SurfaceKind),
    /// Magic Mask's three steps (the buttons are widgets of the same row).
    MagicSteps(crate::audio_masks::magic_steps::View),
    /// The experimental notice box of an effect (the X is a `Hit` widget of the same row).
    Notice(sq_draw::experimental::Feature),
}

/// One control of a translated row, in row coordinates.
#[derive(Clone)]
pub struct Widget {
    /// Unique among the rows.
    pub key: String,
    /// Where it sits in the row.
    pub frame: CGRect,
    /// What it is.
    pub kind: WidgetKind,
    /// False dims it and ignores presses.
    pub enabled: bool,
    /// Its tooltip.
    pub help: Option<String>,
    /// A press released inside (buttons, checkboxes, icons, disclosures).
    pub action: Option<WidgetAction>,
    /// A popup: the items, shown through `Menu`.
    pub menu: Option<WidgetMenu>,
    /// The enable box of a disclosure.
    pub toggle: Option<WidgetAction>,
    /// Where the enable box sits.
    pub toggle_frame: Option<CGRect>,
}

impl Widget {
    fn new(key: String, frame: CGRect, kind: WidgetKind) -> Widget {
        Widget {
            key,
            frame,
            kind,
            enabled: true,
            help: None,
            action: None,
            menu: None,
            toggle: None,
            toggle_frame: None,
        }
    }
    fn with_help(mut self, h: &str) -> Widget {
        self.help = Some(h.to_string());
        self
    }
    fn when(mut self, enabled: bool) -> Widget {
        self.enabled = enabled;
        self
    }
    fn on(mut self, a: impl Fn(&mut PanelCx) + 'static) -> Widget {
        self.action = Some(Rc::new(a));
        self
    }
    fn popup_menu(mut self, m: impl Fn() -> ModelMenu + 'static) -> Widget {
        self.menu = Some(Rc::new(m));
        self
    }
}

/// One icon button of the Magic mask track row.
struct TrackButton {
    name: &'static str,
    icon: SQIcon,
    tint: Option<Color>,
    enabled: bool,
    help: &'static str,
    action: WidgetAction,
}

/// What a disclosure row needs besides its geometry.
struct Disclosure {
    title: String,
    open: bool,
    enabled: Option<bool>,
    toggle: Option<WidgetAction>,
    action: WidgetAction,
}

/// What the Magic and picture mask tracking shows on the mask track row (`MaskTrackActivity`); the host fills it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct MaskTrackView {
    /// A Magic mask is being tracked.
    pub magic_is_tracking: bool,
    /// The Magic track's state line.
    pub magic_status: String,
    /// The running picture-mask track: the mask, its direction and percent (-1 = unknown).
    pub run: Option<MaskTrackRun>,
    /// The followed stretch of the Magic mask's clip, as fractions 0..1.
    pub magic_tracked: Option<(f64, f64)>,
    /// Stretches where the Magic mask might slip, as fractions 0..1 (the host fills them from the track health).
    pub magic_weak: Vec<(f64, f64)>,
    /// Where the first weak stretch begins on the timeline ("Show me where").
    pub magic_first_weak: Option<Time>,
}

/// One running mask track.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct MaskTrackRun {
    /// The mask.
    pub mask: Id,
    /// Forward in time.
    pub forward: bool,
    /// Percent done; negative = not known yet.
    pub percent: i64,
}

fn menu_of(entries: Vec<MenuEntry>) -> ModelMenu {
    ModelMenu { entries }
}

impl EffectControlsDrawPanel {
    /// The key of a row kind (Swift `String(describing:)`).
    pub fn row_key(k: &EffectRowKind) -> String {
        format!("{k:?}")
    }

    /// The widgets of a row the panel draws generically, nil for the rows with their own code (sections, properties, speed).
    pub(crate) fn widgets(&self, model: &EffectControlsModel, r: &EffectRow) -> Option<Vec<Widget>> {
        let h = r.height;
        let g = ControlsGrid::new(self.size.width);
        let key = Self::row_key(&r.kind);
        let k = |s: &str| format!("{key}.{s}");
        let t = self.theme;
        let trash = |label: &str, id: Id| -> Widget {
            Widget::new(
                k("remove"),
                g.control_frame(g.reset_x(), ControlsGrid::RESET_WIDTH, h, ControlsGrid::CONTROL_HEIGHT),
                WidgetKind::Icon(SQIcon::Trash, None),
            )
            .with_help(label)
            .on(move |cx| cx.model.remove_mask(id))
        };
        let mask_mode_menu = |id: Id, current: Option<MaskMode>| {
            move || {
                menu_of(
                    super::MASK_MODES
                        .iter()
                        .map(|&m| {
                            let mut item = SQMenuItem::new(super::mask_mode_title(m));
                            item.is_checked = Some(m) == current;
                            MenuEntry::action(item, move |mdl, _| mdl.set_mask_mode(id, m))
                        })
                        .collect(),
                )
            }
        };
        let label_frame = g.label_frame(h, None);
        let label = |s: &str, color: Option<Color>| {
            Widget::new(k("label"), label_frame, WidgetKind::Text(SQL10n::string(s), color, None, Alignment::Left))
        };
        let ctl = |x: f64, width: f64| g.control_frame(x, width, h, ControlsGrid::CONTROL_HEIGHT);
        match &r.kind {
            EffectRowKind::SubjectMask(id) => {
                let id = *id;
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let on = model.is_blend_group_enabled();
                let remove = trash("Delete Subject Mask", id);
                let inverted = m.inverted;
                Some(vec![
                    Widget::new(
                        k("invert"),
                        ctl(ControlsGrid::LABEL_X, ControlsGrid::LABEL_WIDTH),
                        WidgetKind::Check(
                            "Keep outside".to_string(),
                            if inverted { CheckState::On } else { CheckState::Off },
                        ),
                    )
                    .when(on)
                    .with_help("Invert Subject Mask")
                    .on(move |cx| cx.model.set_mask_inverted(id, !inverted)),
                    Widget::new(
                        k("mode"),
                        g.fill_frame(h, Some(remove.frame.min_x() - ControlsGrid::GAP), Portable::POPUP_WIDTH),
                        WidgetKind::Popup(SQL10n::string(super::mask_mode_title(m.mode))),
                    )
                    .when(on)
                    .with_help("Mask Mode")
                    .popup_menu(mask_mode_menu(id, Some(m.mode))),
                    remove,
                ])
            }
            EffectRowKind::MaskControls(id) => {
                let id = *id;
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let on = m.enabled;
                let state = model.mask_row_keyframe_state(id);
                let inverted = m.inverted;
                let mut out = vec![
                    Widget::new(
                        k("invert"),
                        ctl(ControlsGrid::LABEL_X, ControlsGrid::LABEL_WIDTH),
                        WidgetKind::Check(
                            "Inverted".to_string(),
                            if inverted { CheckState::On } else { CheckState::Off },
                        ),
                    )
                    .when(on)
                    .with_help("Invert Mask")
                    .on(move |cx| cx.model.set_mask_inverted(id, !inverted)),
                    Widget::new(
                        k("mode"),
                        g.fill_frame(h, Some(g.value_max_x()), Portable::POPUP_WIDTH),
                        WidgetKind::Popup(SQL10n::string(super::mask_mode_title(m.mode))),
                    )
                    .when(on)
                    .with_help("Mask Mode")
                    .popup_menu(mask_mode_menu(id, Some(m.mode))),
                ];
                // A Magic mask has no path: its shape comes from the pick and Track. It keeps previous / next (its tracked frames).
                use sq_core_model::MaskSource;
                let src = m.source();
                if !(src == MaskSource::Magic || src == MaskSource::Picture) {
                    out.push(
                        Widget::new(k("ring"), g.toggle_frame(h), WidgetKind::Ring(state)).with_help("Mask Path").on(
                            move |cx| {
                                let asks = cx.asks;
                                stopwatch_in(cx.model, cx.events, asks, &EffectProperty::MaskPath(id));
                            },
                        ),
                    );
                }
                if !(src == MaskSource::Picture || (src == MaskSource::Magic && model.magic_keys(id).is_empty()))
                    && state.shows_navigation
                {
                    out.extend(self.key_navigation(
                        &k,
                        h,
                        &state,
                        Rc::new(move |cx| cx.model.go_to_previous_mask_row_key(id)),
                        Rc::new(move |cx| cx.model.toggle_mask_path_key_at_playhead(id)),
                        Rc::new(move |cx| cx.model.go_to_next_mask_row_key(id)),
                    ));
                }
                Some(out)
            }
            EffectRowKind::MaskTrack(id) => {
                model.clip().and_then(|c| c.mask(*id))?;
                Some(self.mask_track_widgets(model, *id, h, &key, trash("Delete Mask", *id)))
            }
            EffectRowKind::ExperimentalNotice(f) => {
                let f = *f;
                let (_, x) = crate::audio_masks::magic_steps::notice_box(self.size.width);
                let mut close =
                    Widget::new(format!("{key}.close"), x, WidgetKind::Hit).with_help("Close this note for good");
                close.action = Some(Rc::new(move |cx| {
                    let _ = cx;
                    sq_draw::experimental::close_notice(f);
                }));
                Some(vec![
                    Widget::new(key.clone(), CGRect::new(0.0, 0.0, self.size.width, h), WidgetKind::Notice(f)),
                    close,
                ])
            }
            EffectRowKind::MagicSteps(id) => {
                model.clip().and_then(|c| c.mask(*id))?;
                Some(self.magic_steps_widgets(model, *id, h, &key))
            }
            EffectRowKind::PictureMask(id) => {
                let id = *id;
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let remove = trash("Delete Mask", id);
                let cw = 84.0; // Theme.Inspector.channelWidth
                let channel = ctl(remove.frame.min_x() - ControlsGrid::GAP - cw, cw);
                let choices = model.picture_track_choices();
                let sel = model.picture_track_selection(id, &choices);
                let title =
                    choices.get(sel).map(|c| c.lane.clone().unwrap_or_else(|| c.title.clone())).unwrap_or_default();
                let enabled = m.enabled;
                let current_channel = m.picture_channel();
                let tracks = choices.clone();
                Some(vec![
                    label("Picture of", None),
                    Widget::new(
                        k("track"),
                        g.fill_frame(h, Some(channel.min_x() - ControlsGrid::GAP), Portable::POPUP_WIDTH),
                        WidgetKind::Popup(title),
                    )
                    .when(enabled)
                    .with_help("The track whose picture is the mask")
                    .popup_menu(move || {
                        menu_of(
                            tracks
                                .iter()
                                .enumerate()
                                .map(|(i, c)| {
                                    let mut item = SQMenuItem::new(c.lane.as_deref().unwrap_or(&c.title));
                                    item.is_checked = i == sel;
                                    if !(c.lane.is_none() || c.lane.as_deref() == Some(c.title.as_str())) {
                                        item.help = Some(c.title.clone());
                                    }
                                    let track = c.track;
                                    MenuEntry::action(item, move |mdl, _| mdl.set_mask_picture_track(id, track))
                                })
                                .collect(),
                        )
                    }),
                    Widget::new(
                        k("channel"),
                        channel,
                        WidgetKind::Popup(SQL10n::string(super::matte_channel_title(current_channel))),
                    )
                    .when(enabled)
                    .with_help("Shape: where the picture is. Brightness: how bright it is")
                    .popup_menu(move || {
                        menu_of(
                            super::MATTE_CHANNELS
                                .iter()
                                .map(|&c| {
                                    let mut item = SQMenuItem::new(super::matte_channel_title(c));
                                    item.is_checked = c == current_channel;
                                    MenuEntry::action(item, move |mdl, _| mdl.set_mask_picture_channel(id, c))
                                })
                                .collect(),
                        )
                    }),
                    remove,
                ])
            }
            EffectRowKind::MaskUse(id) => {
                let id = *id;
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let list = model.mask_input_choices(id);
                let used = list.iter().filter(|c| c.on).count();
                let title = if list.is_empty() {
                    "No effect to use it in".to_string()
                } else if used == 0 {
                    "Use in effect\u{2026}".to_string()
                } else if used == 1 {
                    "Used in 1 effect".to_string()
                } else {
                    format!("Used in {used} effects")
                };
                let cuts = m.used_by_opacity();
                let enabled = m.enabled;
                let listed = !list.is_empty();
                Some(vec![
                    Widget::new(
                        k("cuts"),
                        g.toggle_box(ControlsGrid::TOGGLE_WIDTH, h),
                        WidgetKind::Check(String::new(), if cuts { CheckState::On } else { CheckState::Off }),
                    )
                    .when(enabled)
                    .with_help("The mask cuts out the clip's picture (off: it only limits the effects that use it)")
                    .on(move |cx| cx.model.set_mask_used_by_opacity(id, !cuts)),
                    label("Cuts picture", None),
                    Widget::new(
                        k("useIn"),
                        g.fill_frame(h, None, Portable::POPUP_WIDTH),
                        WidgetKind::Popup(SQL10n::string(&title)),
                    )
                    .when(enabled && listed)
                    .with_help("Effects that only work inside this mask")
                    .popup_menu(move || {
                        menu_of(
                            list.iter()
                                .map(|c| {
                                    let mut item = SQMenuItem::new(&c.title);
                                    item.is_checked = c.on;
                                    let (on, effect) = (c.on, c.effect);
                                    MenuEntry::action(item, move |mdl, _| mdl.set_mask_input(id, !on, effect))
                                })
                                .collect(),
                        )
                    }),
                ])
            }
            EffectRowKind::ColorRangeMask(id) => {
                let id = *id;
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let on = model.is_blend_group_enabled() && m.enabled;
                let remove = trash("Delete Mask", id);
                let well = ctl(ControlsGrid::VALUE_X, 44.0);
                let x = well.max_x() + ControlsGrid::GAP;
                let key_color = m.color_range();
                let inverted = m.inverted;
                let well_key = k("well");
                Some(vec![
                    label("Color", None),
                    Widget::new(
                        well_key,
                        well,
                        WidgetKind::Well(Color::new(
                            key_color.red as f32,
                            key_color.green as f32,
                            key_color.blue as f32,
                            1.0,
                        )),
                    )
                    .when(on)
                    .with_help("The color the mask keeps")
                    .on(move |cx| {
                        let Some(key) = cx.model.color_range_of(id) else { return };
                        cx.events.push(PanelEvent::PickColor {
                            current: EffectColor { red: key.red, green: key.green, blue: key.blue, alpha: 1.0 },
                            anchor: cx.anchor,
                            target: ColorTarget::MaskRange(id),
                        });
                    }),
                    Widget::new(
                        k("invert"),
                        ctl(x, (remove.frame.min_x() - ControlsGrid::GAP - x).max(0.0)),
                        WidgetKind::Check(
                            "Inverted".to_string(),
                            if inverted { CheckState::On } else { CheckState::Off },
                        ),
                    )
                    .when(on)
                    .with_help("Keep everything except this color")
                    .on(move |cx| cx.model.set_mask_inverted(id, !inverted)),
                    remove,
                ])
            }
            EffectRowKind::ColorRangeAmount { mask, soft } => {
                let (id, soft) = (*mask, *soft);
                let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Some(Vec::new()) };
                let title = if soft { "Softness" } else { "Tolerance" };
                let dflt = sq_core_model::ColorRangeKey::DEFAULT;
                let default_value = (if soft { dflt.softness } else { dflt.tolerance }) * 100.0;
                let cur = m.color_range();
                let spec = FieldSpec {
                    configure: Rc::new(move |f| {
                        f.range = 0.0..=100.0;
                        f.step = 1.0;
                        f.decimals = 0;
                        f.unit = "%".to_string();
                        f.default_value = Some(default_value);
                    }),
                    value: (if soft { cur.softness } else { cur.tolerance }) * 100.0,
                    begin: Rc::new(|mdl| mdl.begin_gesture()),
                    change: Rc::new(move |mdl, percent| {
                        let Some(k) = mdl.color_range_of(id) else { return };
                        let v = percent.clamp(0.0, 100.0) / 100.0;
                        mdl.set_mask_color_range(
                            id,
                            sq_core_model::ColorRangeKey {
                                red: k.red,
                                green: k.green,
                                blue: k.blue,
                                tolerance: if soft { k.tolerance } else { v },
                                softness: if soft { v } else { k.softness },
                            },
                        );
                    }),
                    end: Rc::new(|mdl| mdl.end_gesture()),
                };
                Some(vec![
                    label(title, None),
                    Widget::new(k("field"), g.value_frame(0, h), WidgetKind::Field(spec))
                        .when(model.is_blend_group_enabled() && m.enabled)
                        .with_help(if soft {
                            "How gradually the mask fades out beyond the tolerance"
                        } else {
                            "How far from the picked color still counts as the color"
                        }),
                ])
            }
            EffectRowKind::TrackMaskTrack(effect) => {
                let effect = *effect;
                let choices = model.picture_track_choices();
                let sel = model.track_mask_selection(effect, &choices);
                let title =
                    choices.get(sel).map(|c| c.lane.clone().unwrap_or_else(|| c.title.clone())).unwrap_or_default();
                Some(vec![
                    label("Track", None),
                    Widget::new(k("track"), g.fill_frame(h, None, Portable::POPUP_WIDTH), WidgetKind::Popup(title))
                        .with_help("The video track whose picture limits this clip")
                        .popup_menu(move || {
                            menu_of(
                                choices
                                    .iter()
                                    .enumerate()
                                    .map(|(i, c)| {
                                        let mut item = SQMenuItem::new(c.lane.as_deref().unwrap_or(&c.title));
                                        item.is_checked = i == sel;
                                        if !(c.lane.is_none() || c.lane.as_deref() == Some(c.title.as_str())) {
                                            item.help = Some(c.title.clone());
                                        }
                                        let track = c.track;
                                        MenuEntry::action(item, move |mdl, _| mdl.set_track_mask_track(effect, track))
                                    })
                                    .collect(),
                            )
                        }),
                ])
            }
            EffectRowKind::ColorGroup { effect, key: group_key } => {
                let (effect, group_key) = (*effect, group_key.clone());
                let p =
                    EffectProperty::Fx { id: effect, kind: ClipEffect::COLOR_KIND.to_string(), key: group_key.clone() };
                let name = EffectCatalog::param(ClipEffect::COLOR_KIND, &group_key)
                    .map_or(group_key.clone(), |p| p.title.clone());
                let open = model.open_color_groups.contains(&EffectControlsModel::color_group_id(effect, &group_key));
                let on = model.scalar_value(&p) >= 0.5;
                let gk = group_key.clone();
                let pp = p.clone();
                Some(vec![self.disclosure(
                    &k,
                    h,
                    Disclosure {
                        title: name,
                        open,
                        enabled: Some(on),
                        toggle: Some(Rc::new(move |cx| {
                            let _ = cx.model.set_value(
                                &pp,
                                crate::ec::effect_controls_model::property::EffectComponent::All,
                                if on { 0.0 } else { 1.0 },
                            );
                        })),
                        action: Rc::new(move |cx| cx.model.toggle_color_group(effect, &gk)),
                    },
                )])
            }
            EffectRowKind::EqCurveHeader(effect) => {
                let effect = *effect;
                Some(vec![self.disclosure(
                    &k,
                    h,
                    Disclosure {
                        title: "Curve".to_string(),
                        open: model.is_eq_curve_open(effect),
                        enabled: None,
                        toggle: None,
                        action: Rc::new(move |cx| cx.model.toggle_eq_curve(effect)),
                    },
                )])
            }
            EffectRowKind::MultibandParams(effect) => {
                let effect = *effect;
                Some(vec![self.disclosure(
                    &k,
                    h,
                    Disclosure {
                        title: "All Parameters".to_string(),
                        open: model.is_multiband_parameters_open(effect),
                        enabled: None,
                        toggle: None,
                        action: Rc::new(move |cx| cx.model.toggle_multiband_parameters(effect)),
                    },
                )])
            }
            EffectRowKind::Multiband(effect) => {
                let effect = *effect;
                let w = self.estimated_button_width("Edit Custom Setup").max(120.0);
                Some(vec![
                    Widget::new(
                        k("open"),
                        CGRect::new(
                            ControlsGrid::LABEL_X,
                            ((h - InspectorTokens::CAPSULE as f64) / 2.0).round(),
                            w,
                            InspectorTokens::CAPSULE as f64,
                        ),
                        WidgetKind::Button("Edit Custom Setup".to_string()),
                    )
                    .on(move |cx| cx.events.push(PanelEvent::MultibandEditor(effect))),
                ])
            }
            EffectRowKind::ColorMatch(effect) => {
                let effect = *effect;
                let block = model.color_match_block(effect, None, None);
                let reference = model.color_match_reference(effect);
                let set = ctl(ControlsGrid::VALUE_X, self.estimated_button_width("Set Reference"));
                let matched = ctl(set.max_x() + ControlsGrid::GAP, self.estimated_button_width("Match"));
                let x = matched.max_x() + ControlsGrid::GAP;
                let status = reference
                    .as_ref()
                    .map_or_else(|| SQL10n::string("No reference"), |r| SQL10n::format("Ref: %@", &[&r.label]));
                let status_help = block.clone().or_else(|| reference.as_ref().map(|r| r.label.clone()));
                let mut st = Widget::new(
                    k("status"),
                    CGRect::new(x, 0.0, (g.tail_max_x() - x).max(0.0), h),
                    WidgetKind::Text(status, Some(t.label3()), Some(type_size::CAPTION as f64), Alignment::Left),
                );
                st.help = status_help;
                Some(vec![
                    Widget::new(k("set"), set, WidgetKind::Button("Set Reference".to_string()))
                        .with_help("Set Reference")
                        .on(move |cx| {
                            cx.model
                                .request_color_match(effect, crate::ec::color_match::ColorMatchRequest::SetReference)
                        }),
                    {
                        let mut w = Widget::new(k("match"), matched, WidgetKind::Button("Match".to_string()))
                            .when(block.is_none())
                            .on(move |cx| {
                                cx.model.request_color_match(effect, crate::ec::color_match::ColorMatchRequest::Match)
                            });
                        w.help = Some(block.clone().unwrap_or_else(|| "Match".to_string()));
                        w
                    },
                    st,
                ])
            }
            EffectRowKind::GradeRange(effect) => {
                let effect = *effect;
                let range = model.grade_range(effect)?;
                let fd = model.frame_duration;
                let fw = 78.0; // Theme.Inspector.timecodeWidth
                let start = ctl(ControlsGrid::VALUE_X, fw);
                let end = ctl(start.max_x() + ControlsGrid::GAP, fw);
                let bx = end.max_x() + ControlsGrid::GAP;
                let whole_w = self.estimated_button_width("Whole Clip").min((g.tail_max_x() - bx).max(0.0));
                Some(vec![
                    label("Range", Some(t.label2())),
                    Self::timecode_field(k("start"), start, range.start, fd, "Range Start", move |mdl, tm| {
                        mdl.set_grade_range(effect, Some(tm), None)
                    }),
                    Self::timecode_field(
                        k("end"),
                        end,
                        range.start + range.duration,
                        fd,
                        "Range End",
                        move |mdl, tm| mdl.set_grade_range(effect, None, Some(tm)),
                    ),
                    Widget::new(k("whole"), ctl(bx, whole_w), WidgetKind::Button("Whole Clip".to_string()))
                        .with_help("Whole Clip")
                        .on(move |cx| cx.model.set_grade_whole_clip(effect)),
                ])
            }
            EffectRowKind::GradeFade(effect) => {
                let effect = *effect;
                let fd = model.frame_duration;
                let v = model.grade_fades(effect);
                let fw = 78.0;
                let fin = ctl(ControlsGrid::VALUE_X, fw);
                let fout = ctl(fin.max_x() + ControlsGrid::GAP, fw);
                Some(vec![
                    label("Fade", Some(t.label2())),
                    Self::timecode_field(k("in"), fin, v.fade_in, fd, "Fade In Length", move |mdl, tm| {
                        mdl.set_grade_fades(effect, Some(tm), None)
                    }),
                    Self::timecode_field(k("out"), fout, v.fade_out, fd, "Fade Out Length", move |mdl, tm| {
                        mdl.set_grade_fades(effect, None, Some(tm))
                    }),
                ])
            }
            EffectRowKind::ColorGraph(effect) => {
                let effect = *effect;
                let n = model.color_graph_step_count(effect);
                let bw = self.estimated_button_width("Adjust").min((g.tail_max_x() - ControlsGrid::VALUE_X).max(0.0));
                let text = SQL10n::format(if n == 1 { "%@ Step" } else { "%@ Steps" }, &[&n.to_string()]);
                let _ = effect;
                Some(vec![
                    label(&text, Some(t.label2())),
                    Widget::new(k("adjust"), ctl(ControlsGrid::VALUE_X, bw), WidgetKind::Button("Adjust".to_string()))
                        .with_help("Adjust in the Color page")
                        .on(|cx| {
                            cx.model
                                .events
                                .push(crate::ec::effect_controls_model::core::EffectControlsEvent::OpenColorPro)
                        }),
                ])
            }
            EffectRowKind::StabilizeAnalyze(effect) => Some(self.stabilize_widgets(model, *effect, h, &k)),
            EffectRowKind::Curves(effect) => Some(vec![Widget::new(
                k("curves"),
                CGRect::new(0.0, 0.0, self.size.width, h),
                WidgetKind::Surface(SurfaceKind::Curves(*effect)),
            )]),
            EffectRowKind::EqCurve(effect) => {
                // EQCurveRow.layout: label column to the trailing inset, 4 pt above and below.
                let f = CGRect::new(
                    ControlsGrid::LABEL_X,
                    4.0,
                    (self.size.width - ControlsGrid::LABEL_X - ControlsGrid::TRAILING).max(40.0),
                    (h - 8.0).max(40.0),
                );
                Some(vec![Widget::new(k("curve"), f, WidgetKind::Surface(SurfaceKind::EqCurve(*effect))).with_help(
                    "Drag a point: frequency and gain. Scroll or Option-drag: Q. Double-click: reset the band.",
                )])
            }
            _ => None,
        }
    }

    /// SQButton.intrinsicContentSize: text width (caption face metrics are not known here) plus the 11 pt padding.
    // shortcut: estimates 6 pt per character until the title was drawn once (the draw pass measures it); upgrade with a
    // canvas-free text measure.
    pub(crate) fn estimated_button_width(&self, title: &str) -> f64 {
        let s = SQL10n::string(title);
        let padding = 11.0; // InspectorDraw.buttonPadding
        if let Some(w) = self.widths.borrow().get(&s) {
            return w.ceil() + 2.0 * padding;
        }
        let w = s.chars().count() as f64 * 6.0 + 2.0 * padding;
        self.wanted_widths.borrow_mut().insert(s);
        w
    }

    fn key_navigation(
        &self,
        k: &dyn Fn(&str) -> String,
        h: f64,
        state: &KeyframeControlState,
        previous: WidgetAction,
        key: WidgetAction,
        next: WidgetAction,
    ) -> Vec<Widget> {
        let n = super::effect_controls_draw_panel::union(self.navigation_slot(0, h), self.navigation_slot(2, h));
        let hit = |name: &str, i: usize, enabled: bool, help: &str, a: WidgetAction| {
            let mut w = Widget::new(k(name), self.navigation_slot(i, h), WidgetKind::Hit).when(enabled).with_help(help);
            w.action = Some(a);
            w
        };
        vec![
            Widget::new(k("nav"), n, WidgetKind::Navigation(*state)),
            hit("previous", 0, state.can_go_previous, "Go to Previous Keyframe", previous),
            hit("key", 1, state.can_toggle_key, "Add or Remove Keyframe", key),
            hit("next", 2, state.can_go_next, "Go to Next Keyframe", next),
        ]
    }

    fn disclosure(&self, k: &dyn Fn(&str) -> String, h: f64, d: Disclosure) -> Widget {
        let Disclosure { title, open, enabled, toggle, action } = d;
        let title = title.as_str();
        let x = ControlsGrid::LEVEL_INDENT;
        let shown = SQL10n::string(title);
        let mut w = Widget::new(
            k("disclosure"),
            CGRect::new(x, 0.0, (self.size.width - x).max(0.0), h),
            WidgetKind::Disclosure { title: shown.clone(), open, enabled },
        );
        w.help = Some(SQL10n::format(if open { "Collapse %@" } else { "Expand %@" }, &[&shown]));
        w.action = Some(action);
        if enabled.is_some() {
            let b = InspectorTokens::CHECKBOX;
            w.toggle = toggle;
            w.toggle_frame =
                Some(CGRect::new(self.size.width - ControlsGrid::TRAILING - b, ((h - b) / 2.0).round(), b, b));
        }
        w
    }

    fn timecode_field(
        key: String,
        frame: CGRect,
        t: Time,
        fd: Time,
        help: &str,
        set: impl Fn(&mut EffectControlsModel, Time) + 'static,
    ) -> Widget {
        let commit: TextCommit = Rc::new(move |mdl, text| {
            if let Some(tm) = MarkersPanelModel::parse_timecode(text, fd) {
                set(mdl, tm);
            }
        });
        Widget::new(key, frame, WidgetKind::TextField(MarkersPanelModel::timecode(t, fd), commit)).with_help(help)
    }

    /// The widgets of a Magic mask's steps row: the drawn block, the notice's X and the follow buttons.
    fn magic_steps_widgets(&self, model: &EffectControlsModel, id: Id, h: f64, key: &str) -> Vec<Widget> {
        use crate::audio_masks::magic_steps::{Geometry, Progress, View};
        let c = &self.mask_track;
        let on = model.clip().and_then(|c| c.mask(id)).is_some_and(|m| m.enabled);
        let notice = sq_draw::experimental::prefs().shows_notice(sq_draw::experimental::Feature::MagicMask);
        let g = Geometry::new(self.size.width, notice);
        let progress = Progress {
            picked: !model.magic_keys(id).is_empty(),
            tracking: c.magic_is_tracking,
            tracked: c.magic_tracked,
            weak: c.magic_weak.clone(),
        };
        let ready = on && progress.picked && model.playhead_in_clip() && !c.magic_is_tracking;
        let k = |s: &str| format!("{key}.{s}");
        let mut out = vec![Widget::new(
            k("steps"),
            CGRect::new(0.0, 0.0, self.size.width, h),
            WidgetKind::MagicSteps(View { progress, status: c.magic_status.clone() }),
        )];
        if let Some(close) = g.close.filter(|_| notice) {
            let mut w = Widget::new(k("closeNotice"), close, WidgetKind::Hit).with_help("Close this note for good");
            w.action = Some(Rc::new(move |cx| {
                let _ = cx;
                sq_draw::experimental::close_notice(sq_draw::experimental::Feature::MagicMask);
            }));
            out.push(w);
        }
        let mut follow = Widget::new(k("follow"), g.follow, WidgetKind::Button("Follow to the end".to_string()))
            .when(ready)
            .with_help("Follow to the end");
        follow.action = Some(Rc::new(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: true })));
        let mut back = Widget::new(k("back"), g.back, WidgetKind::Button("From here back to the start".to_string()))
            .when(ready)
            .with_help("From here back to the start");
        back.action = Some(Rc::new(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: false })));
        if let Some(t) = c.magic_first_weak.filter(|_| !c.magic_weak.is_empty() && !c.magic_is_tracking) {
            let mut show =
                Widget::new(k("showWeak"), g.show, WidgetKind::Hit).with_help("Go to the first place it might slip");
            show.action = Some(Rc::new(move |cx| cx.events.push(PanelEvent::ShowWeak(t))));
            out.push(show);
        }
        if c.magic_is_tracking {
            let mut stop =
                Widget::new(k("stop"), g.follow, WidgetKind::Button("Stop".to_string())).with_help("Stop Tracking");
            stop.action = Some(Rc::new(move |cx| cx.events.push(PanelEvent::TrackMagic { mask: id, step: None })));
            out.push(stop);
        } else {
            out.push(follow);
            out.push(back);
        }
        out
    }

    fn mask_track_widgets(
        &self,
        model: &EffectControlsModel,
        id: Id,
        h: f64,
        key: &str,
        remove: Widget,
    ) -> Vec<Widget> {
        let Some(m) = model.clip().and_then(|c| c.mask(id)) else { return Vec::new() };
        let (on, source) = (m.enabled, m.source());
        let g = &ControlsGrid::new(self.size.width);
        let k = |s: &str| format!("{key}.{s}");
        let k = &k;
        let t = self.theme;
        let ch = ControlsGrid::CONTROL_HEIGHT;
        let ctl = |x: f64, width: f64| g.control_frame(x, width, h, ch);
        if source == sq_core_model::MaskSource::Magic {
            // One frame back, back to the start, Stop, on to the end, one frame forward, then the state line.
            let c = &self.mask_track;
            let ready = on && model.playhead_in_clip() && !c.magic_is_tracking;
            let mut x = ControlsGrid::VALUE_X;
            let mut out = vec![Widget::new(
                k("label"),
                g.label_frame(h, None),
                WidgetKind::Text(SQL10n::string("Track"), None, None, Alignment::Left),
            )];
            let button =
                |name: &'static str,
                 icon: SQIcon,
                 tint: Option<Color>,
                 enabled: bool,
                 help: &'static str,
                 action: WidgetAction| TrackButton { name, icon, tint, enabled, help, action };
            let buttons = [
                button(
                    "stepBack",
                    SQIcon::ChevronLeft,
                    None,
                    ready,
                    "Track One Frame Back",
                    Rc::new(move |cx| cx.events.push(PanelEvent::TrackMagic { mask: id, step: Some(false) })),
                ),
                button(
                    "back",
                    SQIcon::GoToStart,
                    None,
                    ready,
                    "From here back to the start",
                    Rc::new(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: false })),
                ),
                button(
                    "stop",
                    SQIcon::Stop,
                    if c.magic_is_tracking { Some(t.accent()) } else { None },
                    c.magic_is_tracking,
                    "Stop Tracking",
                    Rc::new(move |cx| cx.events.push(PanelEvent::TrackMagic { mask: id, step: None })),
                ),
                button(
                    "forward",
                    SQIcon::GoToEnd,
                    None,
                    ready,
                    "Follow to the end",
                    Rc::new(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: true })),
                ),
                button(
                    "stepForward",
                    SQIcon::ChevronRight,
                    None,
                    ready,
                    "Track One Frame Forward",
                    Rc::new(move |cx| cx.events.push(PanelEvent::TrackMagic { mask: id, step: Some(true) })),
                ),
            ];
            for TrackButton { name, icon, tint, enabled, help, action } in buttons {
                let f = ctl(x, ch);
                let mut w = Widget::new(k(name), f, WidgetKind::Icon(icon, tint)).when(enabled).with_help(help);
                w.action = Some(action);
                out.push(w);
                x = f.max_x() + ControlsGrid::GAP;
            }
            out.push(Widget::new(
                k("status"),
                CGRect::new(x, 0.0, (remove.frame.min_x() - ControlsGrid::GAP - x).max(0.0), h),
                WidgetKind::Text(
                    c.magic_status.clone(),
                    Some(t.label2()),
                    Some(type_size::CAPTION as f64),
                    Alignment::Left,
                ),
            ));
            out.push(remove);
            return out;
        }
        // While a track runs (even from another playhead position) its button is a Stop button with the progress.
        let run = self.mask_track.run;
        let mine = run.filter(|r| r.mask == id);
        let ready = on && model.playhead_in_clip() && run.is_none();
        let back = ctl(ControlsGrid::VALUE_X, ch);
        let forward = ctl(back.max_x() + ControlsGrid::GAP, ch);
        let tx = forward.max_x() + ControlsGrid::GAP;
        let title = mine.map_or_else(
            || SQL10n::string("Track"),
            |r| if r.percent >= 0 { format!("{}%", r.percent) } else { "\u{2026}".to_string() },
        );
        let back_stops = mine.is_some_and(|r| !r.forward);
        let forward_stops = mine.is_some_and(|r| r.forward);
        let current = model.mask_track_mode;
        let mut mode_w = Widget::new(
            k("mode"),
            ctl(tx, (remove.frame.min_x() - ControlsGrid::GAP - tx).min(Portable::POPUP_WIDTH)),
            WidgetKind::Popup(SQL10n::string(current.title())),
        )
        .when(on)
        .with_help("What tracking follows");
        mode_w.menu = Some(Rc::new(move || {
            menu_of(
                sq_core_masks::mask_motion::MaskTrackMode::ALL
                    .iter()
                    .map(|&md| {
                        let mut item = SQMenuItem::new(md.title());
                        item.is_checked = md == current;
                        MenuEntry::action(item, move |mdl, _| mdl.mask_track_mode = md)
                    })
                    .collect(),
            )
        }));
        vec![
            Widget::new(k("label"), g.label_frame(h, None), WidgetKind::Text(title, None, None, Alignment::Left)),
            Widget::new(
                k("back"),
                back,
                WidgetKind::Icon(
                    if back_stops { SQIcon::Stop } else { SQIcon::ChevronLeft },
                    if back_stops { Some(t.accent()) } else { None },
                ),
            )
            .when(mine.map_or(ready, |r| !r.forward))
            .with_help("Track Mask Backward (click again to stop)")
            .on(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: false })),
            Widget::new(
                k("forward"),
                forward,
                WidgetKind::Icon(
                    if forward_stops { SQIcon::Stop } else { SQIcon::ChevronRight },
                    if forward_stops { Some(t.accent()) } else { None },
                ),
            )
            .when(mine.map_or(ready, |r| r.forward))
            .with_help("Track Mask Forward (click again to stop)")
            .on(move |cx| cx.events.push(PanelEvent::TrackMask { mask: id, forward: true })),
            mode_w,
            remove,
        ]
    }

    fn stabilize_widgets(
        &self,
        model: &EffectControlsModel,
        effect: Id,
        h: f64,
        k: &dyn Fn(&str) -> String,
    ) -> Vec<Widget> {
        let t = self.theme;
        let state = model.stabilize_status(effect);
        let (title, enabled, tip, status): (&str, bool, Option<String>, String);
        let mut fraction: Option<f64> = None;
        match &state {
            StabilizeRowStatus::Analysing(p) => {
                title = "Stop";
                enabled = true;
                tip = Some("Stop the analysis".to_string());
                fraction = Some(*p);
                status = format!("{} %", (p * 100.0).floor() as i64);
            }
            StabilizeRowStatus::Working(step) => {
                title = "Stop";
                enabled = true;
                tip = Some("Stop the analysis".to_string());
                status = step.clone();
            }
            StabilizeRowStatus::Failed(why) => {
                title = "Analyze Again";
                enabled = true;
                tip = Some("Try the analysis again".to_string());
                status = why.clone();
            }
            StabilizeRowStatus::NotAnalysed | StabilizeRowStatus::Analysed | StabilizeRowStatus::NeedsAnalysis => {
                title = if state == StabilizeRowStatus::NotAnalysed { "Analyze" } else { "Analyze Again" };
                enabled = true;
                tip = Some("Measure the camera shake of this clip".to_string());
                status = match state {
                    StabilizeRowStatus::Analysed => "Analyzed",
                    StabilizeRowStatus::NeedsAnalysis => "New frames need analyzing",
                    _ => "Not analyzed",
                }
                .to_string();
            }
            StabilizeRowStatus::Blocked(why) => {
                title = "Analyze";
                enabled = false;
                tip = Some(why.clone());
                status = why.clone();
            }
        }
        let bh = InspectorTokens::CAPSULE as f64;
        let lh = ControlsGrid::LABEL_HEIGHT;
        let button = CGRect::new(
            ControlsGrid::VALUE_X,
            ((h - bh) / 2.0).round(),
            self.estimated_button_width(title).max(72.0),
            bh,
        );
        let x = button.max_x() + ControlsGrid::GAP;
        let w = (self.size.width - x - ControlsGrid::TRAILING).max(0.0);
        let mut b = Widget::new(k("button"), button, WidgetKind::Button(title.to_string()))
            .when(enabled)
            .on(move |cx| cx.model.analyze_or_cancel_stabilizer(effect));
        b.help = tip;
        let mut out = vec![b];
        let caption = type_size::CAPTION as f64;
        if let Some(fr) = fraction {
            let pct = 36.0;
            let bar = CGRect::new(x, (h - 4.0) / 2.0, (w - pct - ControlsGrid::GAP).max(0.0), 4.0);
            out.push(Widget::new(k("progress"), bar, WidgetKind::Progress(fr)));
            out.push(Widget::new(
                k("status"),
                CGRect::new(bar.max_x() + ControlsGrid::GAP, (h - lh) / 2.0, pct, lh),
                WidgetKind::Text(status, Some(t.label3()), Some(caption), Alignment::Left),
            ));
        } else {
            let mut s = Widget::new(
                k("status"),
                CGRect::new(x, (h - lh) / 2.0, w, lh),
                WidgetKind::Text(SQL10n::string(&status), Some(t.label3()), Some(caption), Alignment::Left),
            );
            s.help = Some(status);
            out.push(s);
        }
        out
    }

    // MARK: Drawing

    pub(crate) fn draw_widgets(
        &mut self,
        model: &EffectControlsModel,
        r: &EffectRow,
        ws: &[Widget],
        c: &mut Canvas,
        hover: &Target,
        cx: &mut UiCx,
    ) {
        let t = self.theme;
        let h = r.height;
        let fill = match &r.kind {
            EffectRowKind::ColorGroup { .. }
            | EffectRowKind::EqCurveHeader(_)
            | EffectRowKind::MultibandParams(_)
            | EffectRowKind::TrackMaskTrack(_) => t.panel(),
            EffectRowKind::Multiband(_)
            | EffectRowKind::ColorMatch(_)
            | EffectRowKind::GradeRange(_)
            | EffectRowKind::GradeFade(_)
            | EffectRowKind::ColorGraph(_)
            | EffectRowKind::Curves(_)
            | EffectRowKind::EqCurve(_) => t.content(),
            _ => t.panel(),
        };
        c.fill(CGRect::new(0.0, 0.0, self.size.width, h), fill);
        c.fill(CGRect::new(0.0, h - 1.0, self.size.width, 1.0), t.row_line());
        let body = type_size::BODY as f64;
        for w in ws {
            let hovered = *hover == Target::Widget(w.key.clone());
            let pressed = self.press_target == Target::Widget(w.key.clone());
            let a = if w.enabled { 1.0 } else { InspectorTokens::DISABLED_ALPHA };
            match &w.kind {
                WidgetKind::Text(s, color, fs, align) => {
                    let size = fs.unwrap_or(body);
                    let col = color.unwrap_or_else(|| t.label2());
                    let text = Self::label_cut(s, w.frame.width, |x| c.size_of(x, size, 0).width);
                    c.draw_text_in(&text, w.frame, size, col.with_alpha(col.a * a), align.list_align(), 0.0, 0);
                }
                WidgetKind::Check(title, state) => {
                    let s = InspectorTokens::CHECKBOX;
                    let boxed = CGRect::new(w.frame.min_x(), (w.frame.mid_y() - s / 2.0).round(), s, s);
                    InspectorDraw::checkbox(c, *state, boxed, hovered, pressed, w.enabled, false, &t);
                    if !title.is_empty() {
                        c.draw_text_in(
                            &SQL10n::string(title),
                            CGRect::new(
                                boxed.max_x() + 5.0,
                                w.frame.min_y(),
                                (w.frame.width - s - 5.0).max(0.0),
                                w.frame.height,
                            ),
                            body,
                            t.label().with_alpha(t.label().a * a),
                            sq_draw::TextAlign::Left,
                            0.0,
                            0,
                        );
                    }
                }
                WidgetKind::Popup(title) => super::popup(c, title, w.frame, hovered, false, w.enabled, &t),
                WidgetKind::Icon(i, tint) => {
                    let col = self.button_tint(*tint, hovered, w.enabled, 1.0);
                    self.icon(c, *i, w.frame, 12.0, col);
                }
                WidgetKind::Button(title) => {
                    super::button(c, &SQL10n::string(title), w.frame, hovered, pressed, w.enabled, &t)
                }
                WidgetKind::Notice(f) => {
                    let (r, _) = crate::audio_masks::magic_steps::notice_box(w.frame.width);
                    c.experimental_notice(*f, r, &t);
                }
                WidgetKind::MagicSteps(view) => {
                    crate::audio_masks::magic_steps::draw(c, w.frame.width, view, &t);
                }
                WidgetKind::Progress(f) => sq_draw::InspectorDraw::progress(c, *f, w.frame, &t),
                WidgetKind::Well(col) => InspectorDraw::color_well(
                    c,
                    if w.enabled { *col } else { col.with_alpha(InspectorTokens::DISABLED_ALPHA) },
                    w.frame,
                    hovered,
                    &t,
                ),
                WidgetKind::Field(_) => {
                    let id = FieldId {
                        row: RowRef::Custom(w.key.clone()),
                        component: crate::ec::effect_controls_model::property::EffectComponent::All,
                    };
                    if let Some(f) = self.fields.get(&id) {
                        f.draw(c, w.frame, &t, self.focused_field.as_ref() == Some(&id), cx);
                    }
                }
                WidgetKind::TextField(..) => {
                    let mut f =
                        self.text_fields.get(&w.key).cloned().unwrap_or_else(|| sq_draw::TextFieldControl::new(""));
                    f.hovering = hovered;
                    f.draw(c, w.frame, &t, self.focused_text.as_deref() == Some(w.key.as_str()), cx);
                }
                WidgetKind::Disclosure { title, open, enabled } => {
                    if hovered {
                        c.fill(w.frame, t.fill_hover());
                    }
                    c.fill(CGRect::new(0.0, 0.0, self.size.width, 1.0), t.separator());
                    let slot = CGRect::new(ControlsGrid::TOGGLE_X, 0.0, ControlsGrid::TOGGLE_WIDTH, h);
                    InspectorDraw::chevron(
                        c,
                        slot,
                        if *open { sq_draw::Direction::Down } else { sq_draw::Direction::Right },
                        t.label3(),
                        10.0,
                    );
                    let mut max_x = w.frame.max_x() - ControlsGrid::TRAILING;
                    if let (Some(on), Some(boxr)) = (enabled, w.toggle_frame) {
                        InspectorDraw::checkbox(
                            c,
                            if *on { CheckState::On } else { CheckState::Off },
                            boxr,
                            *hover == Target::WidgetToggle(w.key.clone()),
                            self.press_target == Target::WidgetToggle(w.key.clone()),
                            true,
                            false,
                            &t,
                        );
                        max_x = boxr.min_x() - ControlsGrid::GAP;
                    }
                    // known limit: bodyStrong draws in the regular face (one atlas face); upgrade with a bold atlas face.
                    c.draw_text_in(
                        title,
                        CGRect::new(ControlsGrid::LABEL_X, 0.0, (max_x - ControlsGrid::LABEL_X).max(0.0), h),
                        body,
                        if *enabled == Some(false) { t.label3() } else { t.label() },
                        sq_draw::TextAlign::Left,
                        0.0,
                        0,
                    );
                }
                WidgetKind::Ring(state) => {
                    InspectorDraw::ring(
                        c,
                        if state.shows_navigation {
                            sq_uikit::keyframe_control_state::ScrubKeyframeState::OnKey
                        } else {
                            sq_uikit::keyframe_control_state::ScrubKeyframeState::None
                        },
                        hovered,
                        CGPoint::new(w.frame.mid_x(), w.frame.mid_y()),
                        &t,
                    );
                }
                WidgetKind::Navigation(state) => InspectorDraw::navigation(c, state, w.frame, true, None, &t),
                WidgetKind::Hit => {}
                WidgetKind::Surface(kind) => {
                    let kind = kind.clone();
                    let key = w.key.clone();
                    self.surface(&key, &kind).draw(model, c, w.frame, &t);
                }
            }
        }
    }

    pub(crate) fn surface(
        &mut self,
        key: &str,
        kind: &SurfaceKind,
    ) -> &mut dyn super::effect_controls_draw_surfaces::DrawSurface {
        self.surfaces.entry(key.to_string()).or_insert_with(|| kind.make()).as_mut()
    }
}
