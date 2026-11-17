// Swift: SQAppShell/Inspector (the Controls panel's section hosting)
//! The clip sections of the inspector as an app host: owns [`ClipSectionsDraw`], feeds it the selected clip, and turns
//! its [`SectionAction`]s into session calls; what needs a picker, the engine or another panel waits in
//! [`InspectorHost::take_deferred`].

use crate::analysis_links::eyedropper::Eyedropper;
use crate::analysis_links::magic_flow::{FlowRequest, MagicFlow};
use crate::analysis_links::picture_sampler::PictureSampler;
use crate::analysis_links::stabilization_store::StabilizationStore;
use crate::color_popover::{ColorPopover, PickerAids, PopoverEvent};
use ease::{EaseEvent, EasePopover};
use sq_app_shell::{A11yAction, AppEvent, AppHost, HostCx};
use sq_core_color::ColorMatchStatsExt;
use sq_core_graphics::format_variants_view::VariantProperty;
use sq_core_masks::stabilize_effect::{ClipEffectStabilizeExt, StabilizerMethod};
use sq_core_masks::stabilizer::StabilizerOptions;
use sq_core_model::{Clip, ClipEffect, ColorMatchReference, ColorMatchStats, EffectColor, Timeline, TrackKind};
use sq_core_time::{Id, IdSource, Time};
use sq_draw::{A11y, Canvas, DrawTheme, InputEvent};
use sq_draw_shell::ShellDialog;
use sq_editor_session::{
    Change, EditorSession, FrameSampler, GraphicLayerSelection, LookScope, LookStore, ProgramFrameSampling,
    TimecodeFormat,
};
use sq_inspector_ui::audio_masks::multiband_host::MultibandHost;
use sq_inspector_ui::audio_masks::track_audio_draw::TrackAudioDraw;
use sq_inspector_ui::audio_masks::transition_controls_draw::{TransitionControlsDraw, TransitionControlsRequest};
use sq_inspector_ui::audio_masks::transition_controls_model::{Row as TransitionRow, TransitionControlsActions};
use sq_inspector_ui::clip_sections::{ClipSectionMode, ClipSectionsDraw, ControlLooks, LookAction, SectionAction};
use sq_inspector_ui::ec::color_match::ColorMatchRequest;
use sq_inspector_ui::ec::effect_controls_model::core::{EffectControlsEvent, EffectControlsModel};
use sq_inspector_ui::ec::effect_controls_model::layout::{EffectRowKind, TextSlot};
use sq_inspector_ui::ec::effect_controls_model::property::{EffectProperty, StopwatchOutcome};
use sq_inspector_ui::ec_draw::ModelMenu;
use sq_inspector_ui::ec_draw::PromptRequest;
use sq_inspector_ui::ec_draw::effect_controls_draw_panel::{ColorTarget, PanelEvent, RemoveKeys, SpeedAction};
use sq_inspector_ui::ec_draw::effect_controls_draw_view::{EffectControlsDrawView, ViewEvent};
use sq_inspector_ui::graphics::template_slots_draw::TemplateEvent;
use sq_inspector_ui::keyframes::key_tools_input::KeyToolPrompt;
use sq_inspector_ui::text::block_draw::{BlockRequest, LookStatus, NameAsks, Part as TextPart, TextBlockDraw};
use sq_inspector_ui::text::inspector_model::TextInspectorModel;
use sq_inspector_ui::text::style_library::TextStyleLibrary;
use sq_uikit::controls_grid::{CGPoint, CGRect, CGSize};
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};
use sq_uikit::sqmenu_model::SQMenuItem;
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::rc::Rc;

/// Builds the audio block of a track the first time its clip is shown (it needs the preset library and id source).
pub type AudioBlockFactory = Box<dyn FnMut(Id, Option<sq_core_model::AudioTag>) -> TrackAudioDraw>;

/// A row a menu closed on, waiting for [`InspectorHost::pump`].
enum Pick {
    /// A row (index path) of an Effect Controls menu.
    Row(Rc<ModelMenu>, Vec<usize>),
    /// The Layer popup's choice (`None`: Whole graphic).
    Layer(Option<Id>),
}

/// Which color the open picker popover edits.
enum Wanted {
    /// A color parameter or mask range of Effect Controls.
    Controls(ColorTarget),
    /// The swatch of a color matte clip.
    Matte,
    /// A color slot of a template clip.
    Template,
    /// A color well of the Text block (the Text section of a text clip).
    Text(sq_inspector_ui::text::block_draw::Control),
    /// A color well of the transition controls.
    Transition(TransitionRow),
}

/// What a running monitor pick is for.
enum Armed {
    /// The Key Hue of an effect.
    KeyHue(EffectProperty),
    /// The color of a Text block layer.
    Text(sq_inspector_ui::text::block_draw::Layer),
}

/// An answered question of Effect Controls.
enum Answer {
    /// "Remove all keyframes?": true when confirmed.
    RemoveKeys(RemoveKeys, bool),
    /// A key tool dialog: the typed texts in field order, `None` when canceled.
    Prompt(PromptRequest, Option<Vec<String>>),
    /// The name for a curve saved from a value graph (`None`: canceled).
    SaveCurve(EffectProperty, usize, Option<String>),
}

mod access;
mod ease;
mod forms;

type Picks = Rc<RefCell<Vec<Pick>>>;

/// The items of `menu` with every leaf row queueing its index path into `picks`.
fn wired_items(menu: &Rc<ModelMenu>, picks: &Picks) -> Vec<SQMenuItem> {
    fn wire(items: Vec<SQMenuItem>, path: &[usize], menu: &Rc<ModelMenu>, picks: &Picks) -> Vec<SQMenuItem> {
        items
            .into_iter()
            .enumerate()
            .map(|(i, mut item)| {
                let mut at = path.to_vec();
                at.push(i);
                if let Some(sub) = item.submenu.take() {
                    item.submenu = Some(wire(sub, &at, menu, picks));
                } else {
                    let (menu, picks) = (Rc::clone(menu), Rc::clone(picks));
                    item.action =
                        Some(Rc::new(move || picks.borrow_mut().push(Pick::Row(Rc::clone(&menu), at.clone()))));
                }
                item
            })
            .collect()
    }
    wire(menu.items(), &[], menu, picks)
}

/// Mints the ids of keys the panel creates: a run from a random start, so they cannot meet the project's.
struct KeyIds(u128);

impl IdSource for KeyIds {
    fn next_id(&mut self) -> Id {
        self.0 = self.0.wrapping_add(1);
        Id::from_u128(self.0)
    }
}

/// A Set Reference or Match press waiting for its picture.
struct ColorMatchWait {
    effect: Id,
    request: ColorMatchRequest,
    clip: Option<Id>,
    label: String,
    time: Time,
}

/// The inspector in a dock slot: the clip sections (text, shape, matte, audio) above the Effect Controls rows and lanes.
pub struct InspectorHost {
    sections: ClipSectionsDraw,
    /// The Text block of a text clip (Swift `TextBlockView` in the Controls stack): the model it edits, the block that draws
    /// it, and the menu requests it raised that wait for `take_menus`.
    text_model: TextInspectorModel,
    text_block: TextBlockDraw,
    /// Names the Text block asked for (Save as New Look, Rename, Save Animation); `take_dialogs` shows them.
    name_asks: NameAsks,
    text_menus: Vec<(Vec<SQMenuItem>, CGRect)>,
    /// A color well of the Text block asked for the picker (control, current color, anchor in block coordinates).
    text_pick: Option<(sq_inspector_ui::text::block_draw::Control, EffectColor, CGRect)>,
    /// A status line the Text block's eyedropper request wants shown.
    text_status: Option<&'static str>,
    controls: EffectControlsDrawView,
    /// The controls of a selected transition: they replace the clip's controls while one is selected.
    transition: TransitionControlsDraw,
    transition_on: bool,
    /// Selected transitions the panel's "Save as Preset" asked to save (the root opens the name dialog).
    transition_saves: Vec<Id>,
    /// The session versions Effect Controls last followed: selection, project, playhead, layer selection (`None`: never).
    followed: Option<(u64, u64, u64, u64)>,
    /// Menus, dialogs, pickers and curve popovers of Effect Controls: they wait for the root.
    view_deferred: Vec<ViewEvent>,
    new_audio: AudioBlockFactory,
    frame: CGRect,
    /// How far the clip sections (Audio, Text, Shape...) are scrolled up when they are taller than the panel.
    sections_scroll: f64,
    /// The clip `sections_scroll` belongs to: an edit bumps the selection version too, so only a new clip resets it.
    scrolled_for: Option<Id>,
    scale: f32,
    /// A press started in the Arrange or Animation part of the Text block: the part and its top edge (panel points), so
    /// the drag and the release keep that part's coordinates.
    slot_pressed: Option<(TextPart, f64)>,
    /// The session version of the selection the sections last showed (`None`: never).
    shown: Option<(u64, u64)>,
    deferred: Vec<SectionAction>,
    picks: Picks,
    answers: Rc<RefCell<Vec<Answer>>>,
    popover: Option<ColorPopover<Wanted>>,
    /// The recent colors and the monitor pipette the picker offers.
    picker_aids: PickerAids,
    ease: Option<EasePopover>,
    /// The Library's saved easing curves, shown as chips in the curve popover.
    saved_curves: Vec<sq_core_time::EasingCurve>,
    /// Saves taken from the popover that the root has not filed yet.
    pub(crate) ease_saves: Vec<(sq_core_model::EaseShape, String)>,
    /// The Multiband Compressor setup, a floating panel above the window.
    multiband: Option<MultibandHost>,
    /// The model changed under the open Multiband setup: it reads the effect again on the next layout.
    multiband_stale: bool,
    /// The area popovers may use (the window, in points); the root sets it.
    window: CGRect,
    /// The monitor picture sampler and the Key Hue it was armed for.
    eyedropper: Option<(Eyedropper, Option<Armed>)>,
    /// Match Color (Set Reference / Match): the sampler over the Program picture and the buttons waiting for it.
    sampler: Option<PictureSampler>,
    color_matches: Vec<ColorMatchWait>,
    /// Lines for the status bar that came up outside a draw (blocked Match).
    status: Vec<String>,
    /// Analyses a Stabilizer re-plan reads, and the options each Stabilizer was last planned with.
    stabilization: StabilizationStore,
    planned_with: BTreeMap<Id, StabilizerOptions>,
    /// Where the Track buttons of Magic and drawn masks send their requests.
    magic: Option<MagicFlow>,
    /// The stored defaults (`sq.multiband.spectrumAtInput`); `None` = nothing is remembered.
    settings: Option<sq_draw_shell::SharedDefaults>,
    /// Clips to re-plan and the time the pause ends (Swift `scheduleStabilizerReplan`: 250 ms after the last change).
    replan_due: Option<(Vec<Id>, f64)>,
    /// Effect and transition defaults the panel changed ("Use as Default", Restore Factory): the root stores them.
    defaults_out: Vec<sq_core_model::effect_defaults::EffectDefaults>,
    /// The Gyroflow engine's side of the Stabilizer rows (None = no engine: the rows keep their defaults).
    gyroflow: Option<crate::gyroflow_host::GyroflowLink>,
    /// The track the compressor meter watches and the last meter sequence read (`MultibandMeterTap::tracks`).
    meter_watch: Option<Id>,
    meter_seen: Option<u64>,
    /// The tracker's matte store: the Magic Mask steps read the strip from it (None = no strip).
    mattes: Option<std::sync::Arc<sq_analysis::frame_matte_store::FrameMatteStore>>,
    /// The key, store revision and clip the strip was last computed for.
    magic_checked: Option<(String, i64, Id)>,
    /// The app's Look store: with one, the Text block's Look popup lists the session's Looks (without, its own styles).
    looks: Option<std::sync::Arc<sq_editor_session::LookStore>>,
}

impl InspectorHost {
    /// A host whose audio blocks come from `new_audio`.
    pub fn new(new_audio: AudioBlockFactory) -> InspectorHost {
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(1, |d| d.as_nanos() << 64 | u128::from(std::process::id()) << 32);
        let name_asks = NameAsks::default();
        let mut text_block = TextBlockDraw::new();
        text_block.ask_name = Some(name_asks.ask());
        let mut controls = EffectControlsDrawView::new(EffectControlsModel::new(Box::new(KeyIds(seed))), 0.0);
        controls.rows_panel.asks_before_removing = true;
        InspectorHost {
            sections: ClipSectionsDraw::new(),
            text_model: TextInspectorModel::new(
                sq_text::text_style::TextStyle::default(),
                sq_core_model::anchored_animation::AnimationSet::new(None, None),
                None,
                Box::new(sq_inspector_ui::text::inspector_model::TextBoxDefaults::installed_families),
                TextStyleLibrary::default(),
                Box::new(sq_core_time::RandomIds),
            ),
            text_block,
            name_asks,
            text_menus: Vec::new(),
            slot_pressed: None,
            text_pick: None,
            text_status: None,
            meter_watch: None,
            meter_seen: None,
            mattes: None,
            magic_checked: None,
            looks: None,
            controls,
            transition: TransitionControlsDraw::new(TransitionControlsActions::new()),
            transition_on: false,
            transition_saves: Vec::new(),
            followed: None,
            view_deferred: Vec::new(),
            new_audio,
            frame: CGRect::default(),
            sections_scroll: 0.0,
            scrolled_for: None,
            scale: 1.0,
            shown: None,
            deferred: Vec::new(),
            picks: Picks::default(),
            answers: Rc::default(),
            popover: None,
            picker_aids: PickerAids::default(),
            ease: None,
            saved_curves: Vec::new(),
            ease_saves: Vec::new(),
            multiband: None,
            multiband_stale: false,
            window: CGRect::default(),
            eyedropper: None,
            sampler: None,
            color_matches: Vec::new(),
            status: Vec::new(),
            stabilization: StabilizationStore::default(),
            planned_with: BTreeMap::new(),
            magic: None,
            settings: None,
            replan_due: None,
            defaults_out: Vec::new(),
            gyroflow: None,
        }
    }

    /// The sections (text, graphics and audio blocks are fed through it).
    pub fn sections(&mut self) -> &mut ClipSectionsDraw {
        &mut self.sections
    }

    /// What waits for the app root (pickers, the engine, the Graphics panel), in the order it happened.
    pub fn take_deferred(&mut self) -> Vec<SectionAction> {
        std::mem::take(&mut self.deferred)
    }

    /// Queues `action` as if the sections had asked for it.
    #[cfg(test)]
    pub(crate) fn defer(&mut self, action: SectionAction) {
        self.deferred.push(action);
    }

    /// What Effect Controls asked for that needs a menu, dialog, picker or popover, in the order it happened.
    pub fn take_view_deferred(&mut self) -> Vec<ViewEvent> {
        std::mem::take(&mut self.view_deferred)
    }

    /// The popup menus waiting to open, with their anchors in the dock's points; the view's menu requests and the Layer
    /// popup leave `take_view_deferred` and `take_deferred`. Rows come back through [`InspectorHost::pump`].
    pub fn take_menus(&mut self) -> Vec<(Vec<SQMenuItem>, CGRect)> {
        let mut menus = Vec::new();
        let origin = CGPoint::new(self.frame.x, self.frame.y + self.controls_y());
        let place = |a: CGRect, o: CGPoint| CGRect::new(a.x + o.x, a.y + o.y, a.width, a.height);
        for event in std::mem::take(&mut self.view_deferred) {
            match event {
                ViewEvent::Menu { menu, anchor } => {
                    menus.push((wired_items(&menu, &self.picks), place(anchor, origin)));
                }
                ViewEvent::Panel(PanelEvent::Menu { menu, anchor }) => {
                    menus.push((wired_items(&Rc::new(menu), &self.picks), place(anchor, origin)));
                }
                other => self.view_deferred.push(other),
            }
        }
        let corner = CGPoint::new(self.frame.x, self.frame.y + self.sections_y());
        for action in std::mem::take(&mut self.deferred) {
            match action {
                SectionAction::LayerMenu { entries, picked, anchor } => {
                    let row = |title: &str, id: Option<Id>| {
                        let mut item = SQMenuItem::new(title);
                        item.is_checked = id == picked;
                        let picks = Rc::clone(&self.picks);
                        item.action = Some(Rc::new(move || picks.borrow_mut().push(Pick::Layer(id))));
                        item
                    };
                    let mut items = vec![row("Whole graphic", None)];
                    items.extend(entries.iter().map(|(id, name)| row(name, Some(*id))));
                    menus.push((items, place(anchor, corner)));
                }
                other => self.deferred.push(other),
            }
        }
        let corner = CGPoint::new(self.frame.x, self.frame.y + self.sections_y());
        // The Audio block's Preset and Loudness dropdowns and the template's menu (anchors in the sections' coordinates).
        menus.extend(self.sections.take_menus().into_iter().map(|r| (r.items, place(r.anchor, corner))));
        menus.extend(std::mem::take(&mut self.text_menus).into_iter().map(|(items, a)| (items, place(a, corner))));
        let at = CGPoint::new(self.frame.x, self.frame.y);
        menus.extend(std::mem::take(&mut self.transition.menus).into_iter().map(|r| (r.items, place(r.anchor, at))));
        if let Some(m) = &mut self.multiband {
            menus.extend(m.take_menus().into_iter().map(|r| (r.items, r.anchor)));
        }
        menus
    }

    /// The questions Effect Controls asks (remove keyframes, key tool dialogs, the name of a saved curve) as dialogs for
    /// the root to show; the answer comes back through [`InspectorHost::pump`].
    pub fn take_dialogs(&mut self) -> Vec<ShellDialog> {
        let ask = |p: &KeyToolPrompt, answers: &Rc<RefCell<Vec<Answer>>>, done: Box<dyn FnOnce(bool) -> Answer>| {
            let mut d = ShellDialog::new(&p.title, &p.informative);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            d.add_button(&p.confirm, SQDialogRole::Default, false);
            let answers = Rc::clone(answers);
            d.completion = Some(Box::new(move |r: SQDialogResponse| answers.borrow_mut().push(done(r.0 == 1))));
            d
        };
        let mut dialogs = Vec::new();
        for event in std::mem::take(&mut self.view_deferred) {
            match event {
                ViewEvent::Panel(PanelEvent::ConfirmRemoveKeyframes { title, what }) => {
                    let prompt = KeyToolPrompt::remove_keyframes(&title);
                    dialogs.push(ask(&prompt, &self.answers, Box::new(move |yes| Answer::RemoveKeys(what, yes))));
                }
                ViewEvent::Prompt(req) => {
                    let answers = Rc::clone(&self.answers);
                    let prompt = req.prompt.clone();
                    let done = Box::new(move |texts| answers.borrow_mut().push(Answer::Prompt(req, texts)));
                    dialogs.push(forms::ask(&prompt, done));
                }
                ViewEvent::SaveCurve { property, index } => {
                    let answers = Rc::clone(&self.answers);
                    let done = Box::new(move |texts: Option<Vec<String>>| {
                        let name = texts.and_then(|t| t.into_iter().next());
                        answers.borrow_mut().push(Answer::SaveCurve(property, index, name));
                    });
                    dialogs.push(forms::ask(&KeyToolPrompt::save_curve(), done));
                }
                other => self.view_deferred.push(other),
            }
        }
        dialogs.extend(self.name_asks.take().into_iter().map(crate::name_dialog::name_dialog));
        dialogs
    }

    /// Applies the rows picked in menus that [`InspectorHost::take_menus`] handed out (call after a menu closed).
    pub fn pump(&mut self, cx: &mut HostCx) {
        // A picked Preset / Loudness row reaches the Audio block, whose change goes on to the session.
        self.sections.run_menu_commands();
        self.route(cx);
        let answers: Vec<Answer> = self.answers.borrow_mut().drain(..).collect();
        for answer in answers {
            match answer {
                Answer::RemoveKeys(RemoveKeys::Speed, true) => {
                    SpeedAction::ToggleAnimation(true).run(&mut self.controls.model, cx.session);
                }
                Answer::RemoveKeys(what, true) => {
                    self.controls.rows_panel.confirm_remove_keyframes(&mut self.controls.model, &what);
                }
                Answer::Prompt(req, texts) => self.controls.answer_prompt(&req, texts),
                Answer::SaveCurve(property, index, name) => {
                    self.controls.save_curve_named(&property, index, name.as_deref());
                }
                Answer::RemoveKeys(_, false) => {}
            }
        }
        if let Some(m) = &mut self.multiband {
            m.menu_closed(&mut self.controls.model);
        }
        let picks: Vec<Pick> = self.picks.borrow_mut().drain(..).collect();
        for pick in picks {
            match pick {
                Pick::Row(menu, path) => self.controls.run_menu(&menu, &path),
                Pick::Layer(layer) => self.sections.layer_picked(layer),
            }
        }
        self.route(cx);
    }

    /// The Graphic item Controls shows: the rows' item and the Layer popup's choice (both `None` = Whole graphic).
    pub fn shown_graphic_item(&self) -> (Option<Id>, Option<Id>) {
        (self.controls.model.item_layer(), self.sections.picked_item())
    }

    /// Gives the Text block's Look popup the app's Looks: Save as New Look, Rename, Update and Delete go to `looks`.
    pub fn set_looks(&mut self, looks: std::sync::Arc<sq_editor_session::LookStore>) {
        self.sections.wire_looks(&mut self.text_block);
        self.looks = Some(looks);
        self.shown = None;
    }

    /// Turns the Key Hue eyedropper on: it samples the Program monitor picture through `eyedropper` (shared with the monitor host).
    pub fn with_eyedropper(mut self, eyedropper: Eyedropper) -> InspectorHost {
        self.controls.rows_panel.has_key_sampler = true;
        self.text_block.can_sample_screen_color = true;
        self.eyedropper = Some((eyedropper, None));
        self
    }

    /// Lets Set Reference and Match of the Color effect read the Program picture through `sampler`.
    pub fn with_frame_sampler(mut self, sampler: PictureSampler) -> InspectorHost {
        self.sampler = Some(sampler);
        self
    }

    /// A Match Color button: the frame is captured now, the model changes when the picture arrives (Swift `InspectorHooks.onColorMatch`).
    fn start_color_match(&mut self, effect: Id, request: ColorMatchRequest, session: &EditorSession) {
        if request == ColorMatchRequest::Match
            && let Some(reason) = self.controls.model.color_match_block(effect, None, None)
        {
            self.status.push(reason);
            return;
        }
        let Some(sampler) = self.sampler.clone() else {
            self.status.push("Match Color cannot read the picture on this computer yet.".to_string());
            return;
        };
        let at = session.playhead();
        let (name, frame_duration) = session.active_timeline().map_or((None, Time::new(1, 30)), |tl| {
            let shot = tl
                .tracks
                .iter()
                .rev()
                .filter(|t| t.kind == TrackKind::Video)
                .find_map(|t| t.clips().iter().find(|c| c.timeline().contains(at)));
            (shot.map(|c| (c.id, c.name.clone())), tl.frame_duration())
        });
        let timecode = TimecodeFormat::new(frame_duration, false).string_for_frame(at.frame_index(frame_duration));
        let key = request.key();
        let mut sampler = sampler;
        sampler.sample_linear(96, key);
        self.color_matches.retain(|w| w.request != request);
        self.color_matches.push(ColorMatchWait {
            effect,
            request,
            clip: name.as_ref().map(|(id, _)| *id),
            label: format!("{} {timecode}", name.map_or_else(|| "Frame".to_string(), |(_, n)| n)),
            time: at,
        });
    }

    /// Finishes the buttons whose picture arrived.
    fn poll_color_match(&mut self, cx: &mut HostCx) {
        let Some(sampler) = self.sampler.clone() else { return };
        for wait in std::mem::take(&mut self.color_matches) {
            let Some(answer) = sampler.take_ready(wait.request.key()) else {
                self.color_matches.push(wait);
                continue;
            };
            let Some(linear) = answer else { continue };
            let display = FrameSampler::display_rgb(&linear);
            match wait.request {
                ColorMatchRequest::SetReference => {
                    if let Some(stats) = ColorMatchStats::measure(&display) {
                        let reference =
                            ColorMatchReference { clip: wait.clip, time: wait.time, label: wait.label, stats };
                        self.controls.model.set_color_match_reference(wait.effect, Some(reference));
                    }
                }
                ColorMatchRequest::Match => {
                    if !self.controls.model.apply_color_match(wait.effect, &display, None) {
                        cx.events.push(AppEvent::Status("The clip already matches the reference.".to_string()));
                    }
                }
            }
        }
        for line in self.status.drain(..) {
            cx.events.push(AppEvent::Status(line));
        }
    }

    /// Feeds the Magic Mask steps' result strip from the tracker's mattes.
    pub fn with_matte_store(
        mut self,
        store: std::sync::Arc<sq_analysis::frame_matte_store::FrameMatteStore>,
    ) -> InspectorHost {
        self.mattes = Some(store);
        self
    }

    /// Fills `mask_track.magic_tracked / magic_weak / magic_first_weak` from the stored matte areas of the clip's first
    /// tracked Magic mask; recomputed only when the clip, the key or the store changed (the areas are read from every frame).
    fn feed_magic_check(&mut self, session: &EditorSession) {
        use sq_inspector_ui::ec::magic_check::MagicCheck;
        let Some(store) = self.mattes.clone() else { return };
        let model = &self.controls.model;
        let found = model.first_magic_check_key().zip(model.clip().map(|c| c.id));
        let stamp = found.as_ref().map(|((_, k), clip)| (k.clone(), store.revision(), *clip));
        if stamp == self.magic_checked {
            return;
        }
        self.magic_checked = stamp;
        let check = match (&found, model.clip()) {
            (Some(((_, key), _)), Some(clip)) => {
                let fd = session.active_timeline().map_or(Time::new(1, 30), sq_core_model::Timeline::frame_duration);
                MagicCheck::from_samples(clip, &store.health_samples(key), fd)
            }
            _ => MagicCheck::default(),
        };
        let view = &mut self.controls.rows_panel.mask_track;
        (view.magic_tracked, view.magic_weak, view.magic_first_weak) = (check.tracked, check.weak, check.first_weak);
        self.controls.relayout();
    }

    /// Routes the Track buttons of Effect Controls to the Magic Mask runner behind `flow`.
    pub fn with_magic_flow(mut self, flow: MagicFlow) -> InspectorHost {
        self.magic = Some(flow);
        self
    }

    /// Connects the Stabilizer rows of Gyroflow to the shared engine (state, Analyze, Cancel).
    pub fn with_gyroflow(mut self, engine: std::sync::Arc<sq_gyroflow::GyroEngine>) -> InspectorHost {
        self.gyroflow = Some(crate::gyroflow_host::GyroflowLink::new(engine));
        self
    }

    /// The analyses re-plans read; an analysis job puts its results in the same store.
    pub fn with_stabilization(mut self, store: StabilizationStore) -> InspectorHost {
        self.stabilization = store;
        self
    }

    /// Keeps "Spectrum at Input" of the Multiband setup in `store` (Swift: `UserDefaults`, same key).
    pub fn set_settings_store(&mut self, store: sq_draw_shell::SharedDefaults) {
        // The keyframe easing choices list ☆ My Curves from the same preferences (`sq.myCurves`).
        self.controls.model.easing_library =
            sq_editor_session::MyCurves::load(&sq_draw_shell::SharedView(std::rc::Rc::clone(&store)));
        crate::my_curves_link::load_my_curves(
            &mut self.transition,
            &sq_draw_shell::SharedView(std::rc::Rc::clone(&store)),
        );
        self.settings = Some(store);
    }

    /// The selected transitions the panel's "Save as Preset" asked to save; the root asks for the name.
    pub fn take_transition_saves(&mut self) -> Vec<Id> {
        std::mem::take(&mut self.transition_saves)
    }

    /// True while Effect Controls shows a transition (it replaces the clip's controls).
    pub fn shows_transition(&self) -> bool {
        self.transition_on
    }

    /// Runs the rows picked in the transition menus, files saved curves and passes on the panel's other requests.
    fn serve_transition(&mut self, cx: &mut HostCx) {
        self.transition.run_menu_commands(cx.session);
        let rest = match &self.settings {
            Some(store) => {
                let mut view = sq_draw_shell::SharedView(std::rc::Rc::clone(store));
                let mut ids = KeyIds(
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map_or(1, |d| d.as_nanos() << 64),
                );
                let rest = crate::my_curves_link::serve_my_curves(&mut self.transition, &mut view, &mut ids);
                self.controls.model.easing_library = sq_editor_session::MyCurves::load(&view);
                rest
            }
            None => std::mem::take(&mut self.transition.requests),
        };
        for request in rest {
            match request {
                TransitionControlsRequest::PickColor { row, current, anchor } => {
                    let at = CGRect::new(anchor.x + self.frame.x, anchor.y + self.frame.y, anchor.width, anchor.height);
                    let visible = if self.window.width > 0.0 { self.window } else { self.frame };
                    self.close_popover(cx);
                    self.popover =
                        Some(ColorPopover::open_with(Wanted::Transition(row), current, at, visible, &self.picker_aids));
                }
                TransitionControlsRequest::SavePreset => {
                    if let Some(id) = cx.session.selected_transition() {
                        self.transition_saves.push(id);
                    }
                }
                TransitionControlsRequest::SaveToMyCurves(_) => {
                    cx.events.push(AppEvent::Status("My Curves are not saved here.".to_string()));
                }
            }
        }
        for line in self.transition.actions.take_status() {
            cx.events.push(AppEvent::Status(line));
        }
    }

    /// Keeps the keyframe easing library (☆ My Curves) in the preferences so every project sees it.
    fn store_my_curves(&self, library: &sq_core_time::EasingLibrary) {
        if let Some(store) = &self.settings {
            sq_editor_session::MyCurves::store(&mut sq_draw_shell::SharedView(std::rc::Rc::clone(store)), library);
        }
    }

    fn spectrum_at_input(&self) -> bool {
        let key = sq_inspector_ui::audio_masks::multiband_editor_draw::MultibandEditorDraw::SPECTRUM_INPUT_DEFAULTS_KEY;
        self.settings.as_ref().and_then(|s| s.borrow().integer(key)).is_some_and(|n| n != 0)
    }

    /// Tells the host how big the window is, so popovers stay inside it.
    pub fn set_window(&mut self, window: CGRect) {
        self.window = window;
    }

    /// Opens the curve of a speed transition at `anchor` (window points), as the timeline's context menu asks.
    pub fn open_speed_curve(&mut self, cx: &mut HostCx, clip: Id, segment: usize, anchor: CGRect) {
        let visible = if self.window.width > 0.0 { self.window } else { self.frame };
        self.ease = Some(EasePopover::open_speed(clip, segment, anchor, visible, &mut self.controls.model, cx.session));
        self.seed_ease();
    }

    /// Opens the curve popover on a source of its own (Edit Curve of a keystone) at `anchor` (window points).
    pub fn open_ease(
        &mut self,
        _cx: &mut HostCx,
        source: Box<dyn sq_uikit::ease_curve_source::EaseCurveSource>,
        anchor: CGRect,
    ) {
        let visible = if self.window.width > 0.0 { self.window } else { self.frame };
        self.ease = Some(EasePopover::open_source(source, anchor, visible));
        self.seed_ease();
    }

    fn seed_ease(&mut self) {
        let saved = self.saved_curves.clone();
        if let Some(e) = &mut self.ease {
            e.set_saved(saved);
        }
    }

    /// The Library's saved easing curves (`EasingPresets.load`); an open popover lists them at once.
    pub fn set_saved_curves(&mut self, curves: Vec<sq_core_time::EasingCurve>) {
        if self.saved_curves != curves {
            self.saved_curves = curves;
            self.seed_ease();
        }
    }

    /// The curves saved from the popover since the last call (shape and typed name).
    /// The facts the Controls rules read (Swift `InspectorHost` fact provider).
    pub fn fill_facts(&self, f: &mut sq_draw_shell::ShellPanelFacts) {
        let m = &self.controls.model;
        f.effect_controls_clip = m.clip().is_some();
        f.effect_selection_empty = m.selection().is_empty();
        f.effect_can_copy = Some(m.can_copy_focused());
        f.effect_can_cut = Some(m.can_cut_focused());
        f.effect_can_paste = Some(m.can_paste_focused());
        f.effect_can_delete = Some(m.can_delete_focused());
    }

    pub fn take_ease_saves(&mut self) -> Vec<(sq_core_model::EaseShape, String)> {
        let fresh = self.ease.as_mut().map(EasePopover::take_saves).unwrap_or_default();
        self.ease_saves.extend(fresh);
        std::mem::take(&mut self.ease_saves)
    }

    /// How far the panel's content is scrolled (sections plus Controls rows), for the whole-app wheel test.
    #[cfg(test)]
    pub(crate) fn scrolled_by(&self) -> f64 {
        self.sections_scroll + self.controls.rows_panel.scroll_y
    }

    /// True while a picker popover is open.
    pub fn has_popover(&self) -> bool {
        self.popover.is_some() || self.ease.is_some() || self.multiband.is_some()
    }

    /// Opens the color picker the sections or Effect Controls asked for (the eyedropper request stays a gap).
    fn open_pickers(&mut self, cx: &mut HostCx) {
        let sections = CGPoint::new(self.frame.x, self.frame.y + self.sections_y());
        let controls = CGPoint::new(self.frame.x, self.frame.y + self.controls_y());
        let place = |a: CGRect, o: CGPoint| CGRect::new(a.x + o.x, a.y + o.y, a.width, a.height);
        let visible = if self.window.width > 0.0 { self.window } else { self.frame };
        let mut open = None;
        if let Some(text) = self.text_status.take() {
            cx.events.push(AppEvent::Status(text.to_string()));
        }
        if let Some((control, current, anchor)) = self.text_pick.take() {
            open = Some((Wanted::Text(control), current, place(anchor, sections)));
        }
        for action in std::mem::take(&mut self.deferred) {
            match action {
                SectionAction::PickMatteColor { current, anchor } => {
                    open = Some((Wanted::Matte, current, place(anchor, sections)));
                }
                SectionAction::PickTemplateColor { current, anchor } => {
                    open = Some((Wanted::Template, current, place(anchor, sections)));
                }
                other => self.deferred.push(other),
            }
        }
        for event in std::mem::take(&mut self.view_deferred) {
            match event {
                ViewEvent::Panel(PanelEvent::PickColor { current, anchor, target }) => {
                    open = Some((Wanted::Controls(target), current, place(anchor, controls)));
                }
                ViewEvent::Panel(PanelEvent::EaseCurve { target, anchor }) => {
                    let at = place(anchor, controls);
                    match EasePopover::open(target, at, visible, &mut self.controls.model, cx.session) {
                        Some(pop) => {
                            self.ease = Some(pop);
                            self.seed_ease();
                        }
                        None => {
                            cx.events.push(AppEvent::Status("There is no speed transition at the playhead.".into()))
                        }
                    }
                }
                ViewEvent::Panel(PanelEvent::MultibandEditor(effect)) => match &mut self.multiband {
                    Some(m) if m.effect() == effect => m.reactivate(),
                    _ => {
                        self.close_multiband(cx);
                        let size = CGSize::new(visible.width, visible.height);
                        let at_input = self.spectrum_at_input();
                        self.multiband = Some(MultibandHost::open(effect, &self.controls.model, size, at_input));
                    }
                },
                ViewEvent::Panel(PanelEvent::PickKeyColor(prop)) => match &mut self.eyedropper {
                    Some((dropper, target)) => {
                        dropper.arm();
                        *target = Some(Armed::KeyHue(prop));
                        cx.events.push(AppEvent::Status("Click a color in the Program monitor picture.".to_string()));
                    }
                    None => cx.events.push(AppEvent::Status("The eyedropper is not available here.".to_string())),
                },
                ViewEvent::Panel(PanelEvent::TrackMagic { mask, step }) if self.magic.is_some() => {
                    self.magic.iter().for_each(|f| f.request(FlowRequest::TrackMagic { mask, step }));
                }
                ViewEvent::Panel(PanelEvent::TrackMask { mask, forward }) if self.magic.is_some() => {
                    self.magic.iter().for_each(|f| {
                        f.request(FlowRequest::TrackMask { mask, forward, mode: self.controls.model.mask_track_mode })
                    });
                }
                ViewEvent::Panel(PanelEvent::ShowWeak(t)) => cx.session.seek(t),
                other => self.view_deferred.push(other),
            }
        }
        if let Some((target, current, anchor)) = open {
            self.close_popover(cx);
            self.popover = Some(ColorPopover::open_with(target, current, anchor, visible, &self.picker_aids));
        }
    }

    /// Learn Noise: hands the shown clip's audio at the playhead to the block that asked to listen.
    // shortcut: reads one second on the UI thread (a seek plus 16000 frames); move it to a worker if a slow disk shows.
    fn feed_learn_noise(&mut self, session: &EditorSession) {
        let Some(clip) = self.controls.model.clip() else { return };
        let (media, at) = (clip.media, clip.start + self.controls.model.local_playhead());
        let frame = session.active_timeline().map_or(Time::new(1, 30), |t| t.frame_duration());
        let source = clip.source_time(at, frame);
        let path = session.media().file_path(media);
        self.sections.serve_learn_noise(|| crate::noise_capture::capture(&path?, source));
    }

    /// The Compressor's GR meter: watch the shown track on the playback tap and show the picked band's live reduction.
    fn feed_gain_reduction(&mut self) {
        use sq_audiofx::multiband_meters::MultibandMeterTap;
        let tap = MultibandMeterTap::tracks();
        let track = self.sections.audio_track_id();
        if self.meter_watch != track {
            tap.watch(track);
            self.meter_watch = track;
            self.meter_seen = None;
        }
        let Some(track) = track else { return };
        let reading = tap.reading(track);
        let seen = self.meter_seen;
        let mut next = seen;
        self.sections.set_audio_gain_reduction(|band| match reading {
            Some(r) => {
                let (s, db) = sq_inspector_ui::audio_masks::compressor_curve::live_reduction(
                    seen,
                    r.sequence,
                    r.gain_reduction_db,
                    band,
                );
                next = s;
                db
            }
            None => 0.0,
        });
        self.meter_seen = next;
        self.sections.set_audio_gate_open(tap.gate_open(track));
    }

    /// Hands a finished monitor pick to the Key Hue it was armed for.
    fn finish_eyedropper(&mut self, cx: &mut HostCx) {
        let Some((dropper, target)) = &mut self.eyedropper else { return };
        // Another host's pick is not ours: only an armed Key Hue pick takes the answer.
        if target.is_none() || !dropper.has_answer() {
            return;
        }
        let (Some(answer), Some(armed)) = (dropper.take_answer(), target.take()) else { return };
        match (answer, armed) {
            (Some(rgb), Armed::KeyHue(prop)) => {
                self.controls.rows_panel.key_color_picked(&mut self.controls.model, &prop, rgb);
                self.route(cx);
            }
            (Some((r, g, b)), Armed::Text(layer)) => {
                let picked = sq_uikit::sqcolor_value::SQColorValue::from_rgb(r, g, b, 1.0);
                self.text_block.color_sampled(&mut self.text_model, layer, Some(picked));
                self.route(cx);
            }
            (None, _) => cx.events.push(AppEvent::Status("No color picked.".to_string())),
        }
    }

    fn report_color(&mut self, color: Option<EffectColor>, cx: &mut HostCx) {
        let Some(pop) = &self.popover else { return };
        match &pop.target {
            Wanted::Controls(t) => self.controls.rows_panel.color_picked(&mut self.controls.model, t, color),
            Wanted::Matte => self.sections.matte_picked(color),
            Wanted::Template => self.sections.template_color_picked(color),
            Wanted::Text(control) => self.text_block.color_changed(&mut self.text_model, control, color),
            Wanted::Transition(row) => self.transition.color_picked(cx.session, row, color),
        }
        self.route(cx);
    }

    fn close_popover(&mut self, cx: &mut HostCx) {
        self.report_color(None, cx);
        self.popover = None;
    }

    /// Gives the open picker popover an event first; true when it took it.
    pub fn handle_popover(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let scale = cx.scale;
        if let Some(pop) = &mut self.ease {
            let event = pop.handle(e, scale, &mut self.controls.model, cx.session, cx.ui);
            if matches!(event, EaseEvent::Closed | EaseEvent::Dismissed) {
                self.ease = None;
            }
            self.route(cx);
            // A press elsewhere closed it and is not taken: it goes on to the panel under the pointer.
            return !matches!(event, EaseEvent::Ignored | EaseEvent::Dismissed);
        }
        let Some(pop) = &mut self.popover else { return self.handle_multiband(e, cx) };
        match pop.handle(e, scale, cx.ui) {
            PopoverEvent::Ignored => false,
            PopoverEvent::Taken => true,
            PopoverEvent::Changed(c) => {
                self.report_color(Some(c), cx);
                true
            }
            PopoverEvent::Closed => {
                self.close_popover(cx);
                true
            }
            PopoverEvent::Dismissed => {
                self.close_popover(cx);
                false
            }
        }
    }

    /// Gives the Multiband setup an event; closes it when it asked to be. Presses outside it go on to the panels.
    fn handle_multiband(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        let Some(m) = &mut self.multiband else { return false };
        let taken = m.handle(&mut self.controls.model, cx.ui, e, cx.scale, &mut |_| {});
        if let (Some(on), Some(store)) = (m.take_spectrum_at_input(), &self.settings) {
            let key =
                sq_inspector_ui::audio_masks::multiband_editor_draw::MultibandEditorDraw::SPECTRUM_INPUT_DEFAULTS_KEY;
            store.borrow_mut().set_integer(key, i64::from(on));
        }
        if m.take_close_request() {
            self.close_multiband(cx);
        }
        self.route(cx);
        taken
    }

    fn close_multiband(&mut self, cx: &mut HostCx) {
        self.close_multiband_in(cx.ui);
    }

    fn close_multiband_in(&mut self, ui: &mut sq_draw::UiCx) {
        if let Some(mut m) = self.multiband.take() {
            m.close(&mut self.controls.model, ui);
        }
    }

    /// Draws the open picker popover over everything else.
    pub fn draw_popover(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        if let Some(pop) = &self.popover {
            pop.draw(c, t, cx.ui);
        }
        if let Some(m) = &self.multiband {
            m.draw(c, cx.ui);
        }
        if let Some(pop) = &mut self.ease {
            pop.draw(c, t, &mut self.controls.model, cx.session, cx.ui);
        }
    }

    /// The Effect Controls panel (model, rows, lanes).
    /// The defaults the panel changed since the last call (Swift `model.onEffectDefaultsChange`): the root stores them.
    pub fn take_effect_defaults_changes(&mut self) -> Vec<sq_core_model::effect_defaults::EffectDefaults> {
        std::mem::take(&mut self.defaults_out)
    }

    /// The stored defaults the panel shows (Swift `EffectControlsModel.effectDefaults`).
    pub fn set_effect_defaults(&mut self, d: sq_core_model::effect_defaults::EffectDefaults) {
        if self.controls.model.effect_defaults != d {
            self.controls.model.effect_defaults = d;
        }
    }

    /// The transition controls, for the design frames (`--pose transition-options`, `transition-custom`).
    pub fn transition_panel(&mut self) -> &mut TransitionControlsDraw {
        &mut self.transition
    }

    pub fn controls(&mut self) -> &mut EffectControlsDrawView {
        &mut self.controls
    }

    /// Gives the picker popovers their recent colors and monitor pipette.
    pub fn with_picker_aids(mut self, aids: PickerAids) -> InspectorHost {
        self.picker_aids = aids;
        self
    }

    /// A pick the pipette of the open picker finished reaches the color it edits.
    fn poll_popover_pick(&mut self, cx: &mut HostCx) {
        if let Some(PopoverEvent::Changed(c)) = self.popover.as_mut().and_then(ColorPopover::poll_pick) {
            self.report_color(Some(c), cx);
        }
    }

    /// Applies what the model queued since the last call (the monitor's handles edit it from outside).
    pub fn route_model(&mut self, cx: &mut HostCx) {
        self.route(cx);
    }

    /// Whether a field in the panel has the keyboard (a value is being typed or a field waits for the next key).
    pub fn has_keyboard_focus(&self) -> bool {
        self.controls.rows_panel.has_keyboard_focus()
    }

    /// The keyboard left the panel (a press elsewhere, another panel's focus, a dialog or menu): typed values commit and no
    /// field keeps the focus, so it neither stays in edit mode on screen nor takes the next Enter.
    pub fn blur(&mut self, cx: &mut HostCx) {
        self.sections.resign_focus(cx.ui);
        self.text_block.resign_focus(&mut self.text_model, cx.ui);
        self.controls.blur(cx.ui);
        self.route(cx);
    }

    /// Whether the Text block is the leading section (a single text clip is selected).
    fn text_shown(&self) -> bool {
        self.sections.mode() == ClipSectionMode::Text
    }

    /// The Text block's edits become section actions, its menus wait for `take_menus`, and its height (it changes with the
    /// width, the open sections and the text length) goes to the sections, which size the stack from it.
    fn pump_text(&mut self) {
        if !self.text_shown() {
            return;
        }
        self.text_block.run_menu_commands(&mut self.text_model);
        let mut requests = self.text_block.take_requests();
        self.sections.pump_text(&mut self.text_model, &mut self.text_block, &mut requests);
        for r in requests {
            match r {
                BlockRequest::Menu { items, anchor, .. } => self.text_menus.push((items, anchor)),
                BlockRequest::PickColor { control, current, anchor, .. } => {
                    self.text_pick = Some((control, current, anchor));
                }
                BlockRequest::SampleColor(layer) => match &mut self.eyedropper {
                    Some((dropper, armed)) => {
                        dropper.arm();
                        *armed = Some(Armed::Text(layer));
                        self.text_status = Some("Click a color in the Program monitor picture.");
                    }
                    None => self.text_status = Some("The eyedropper is not available here."),
                },
                _ => {}
            }
        }
    }

    fn route(&mut self, cx: &mut HostCx) {
        self.pump_text();
        let actions = self.sections.take_actions();
        if !actions.is_empty() {
            for action in route_sections(cx.session, actions) {
                match action {
                    SectionAction::AlignToFrame(a) => self.controls.model.align_text(a, cx.session),
                    SectionAction::GraphicItem { clip, layer } => {
                        let selection = layer.map(|l| GraphicLayerSelection { clip, layers: [l].into() });
                        cx.session.set_graphic_layer_selection(selection);
                    }
                    SectionAction::Look(a) => self.run_look(a, cx.session),
                    other => self.deferred.push(other),
                }
            }
        }
        self.route_controls(cx);
        self.open_pickers(cx);
    }

    /// What the Text block's Look popup asked (Swift `ClipSectionsDraw.wireLooks`); the Looks list is read again.
    fn run_look(&mut self, action: LookAction, session: &mut EditorSession) {
        let Some(store) = self.looks.clone() else { return };
        let carried = session.applied_look(&store);
        // A failed store write is dropped like Swift's `try?`; the list below shows what is really saved.
        match action {
            LookAction::Apply(token) => {
                if let Some(e) = session.looks(&store).into_iter().find(|e| e.id() == token) {
                    session.apply_look(&e.ref_, &store, None);
                }
            }
            LookAction::Update => {
                if let Some(r) = carried {
                    session.update_look(&r, &store).ok();
                }
            }
            LookAction::SaveAsNew(name) => {
                session.save_look_as_new(&name, LookScope::User, &store).ok();
            }
            LookAction::Rename(name) => {
                if let Some(r) = carried {
                    session.rename_look(&r, &name, &store).ok();
                }
            }
            LookAction::Delete => {
                if let Some(r) = carried {
                    session.delete_look(&r, &store).ok();
                }
            }
        }
        self.shown = None;
    }

    /// Seconds the Stabilizer waits after the last settings change before it re-plans (a slider drag changes it often).
    const REPLAN_DELAY: f64 = 0.25;

    /// Runs the re-plan once its pause is over; it joins the edit's undo step (same coalescing key as Swift).
    fn run_due_replan(&mut self, cx: &mut HostCx) {
        if !self.replan_due.as_ref().is_some_and(|(_, due)| cx.ui.now >= *due) {
            return;
        }
        if let Some((clips, _)) = self.replan_due.take()
            && cx.session.replan_stabilizers(&clips, &self.stabilization.lookup()).is_empty()
        {
            cx.events.push(AppEvent::Status("Stabilizer: analyze the clip to apply the new settings.".to_string()));
        }
    }

    /// Applies what the model and the view queued to the session (Swift `EffectControlsBinding.connect`).
    fn route_controls(&mut self, cx: &mut HostCx) {
        let session = &mut *cx.session;
        let mut replan = Vec::new();
        let paths = crate::gyroflow_host::path_of(session.media());
        if let Some(g) = &mut self.gyroflow {
            g.sync(&mut self.controls.model, &paths);
        }
        for event in self.controls.model.take_events() {
            match event {
                EffectControlsEvent::Edit { clip, name, coalescing, base } => {
                    if stabilizer_changed(&mut self.planned_with, &clip) {
                        replan.push(clip.id);
                    }
                    match base {
                        Some(base) => session.replace_displayed_clip_rebased(&base, clip, &name, coalescing),
                        None => session.replace_displayed_clip(clip, &name, coalescing),
                    }
                }
                EffectControlsEvent::EditMany { clips, name, coalescing, bases } => {
                    session.replace_displayed_clips_rebased(&bases, clips, &name, coalescing);
                }
                EffectControlsEvent::AudioEdit { clip, name, coalescing, base } => match base {
                    Some(base) => session.replace_clip_rebased(&base, &clip, &name, coalescing),
                    None => session.replace_clip(&clip, &name, coalescing),
                },
                EffectControlsEvent::GestureEnded => session.end_gesture(),
                EffectControlsEvent::EffectDefaultsChange(d) => self.defaults_out.push(d),
                EffectControlsEvent::LibraryChange(library) => self.store_my_curves(&library),
                EffectControlsEvent::EffectCopied(e) => session.set_effect_clipboard(Some(e)),
                EffectControlsEvent::BuiltInCopied { section, clip } => {
                    session.copy_built_in(section, &clip);
                }
                EffectControlsEvent::Seek(t) => session.seek(t),
                EffectControlsEvent::PointerDown => session.stop_playback(),
                EffectControlsEvent::ScrubBegan => session.begin_scrub(),
                EffectControlsEvent::Scrub(t) => session.scrub(t),
                EffectControlsEvent::ScrubEnded => session.end_scrub(),
                EffectControlsEvent::Notice(text) => cx.events.push(AppEvent::Status(text)),
                EffectControlsEvent::ResetSpeed => self.controls.model.reset_speed_with(session),
                EffectControlsEvent::StabilizeAnalyze(id) => {
                    let standard = self.controls.model.clip().is_some_and(|c| {
                        c.effect_of_kind(ClipEffect::STABILIZE_KIND)
                            .is_some_and(|e| e.stabilize_method() == StabilizerMethod::Standard)
                    });
                    if standard {
                        self.magic.iter().for_each(|f| f.request(FlowRequest::StabilizeStart(id)));
                    } else if let (Some(g), Some(clip)) = (&self.gyroflow, self.controls.model.clip()) {
                        g.analyze(clip, &paths);
                    }
                }
                EffectControlsEvent::StabilizeCancel => {
                    self.magic.iter().for_each(|f| f.request(FlowRequest::StabilizeStop));
                }
                EffectControlsEvent::GyroflowCancel { clip, options } => {
                    if let Some(g) = &self.gyroflow {
                        g.cancel(&clip, &options, &paths);
                    }
                }
                EffectControlsEvent::ColorMatch { effect, request } => self.start_color_match(effect, request, session),
                _ => {}
            }
        }
        if !replan.is_empty() {
            // a newer change replaces the pending list, like Swift cancels the waiting task
            self.replan_due = Some((replan, cx.ui.now + Self::REPLAN_DELAY));
        }
        for event in self.controls.take_events() {
            match event {
                ViewEvent::Panel(PanelEvent::Speed(action)) => {
                    if let Some(StopwatchOutcome::NeedsConfirmation) = action.run(&mut self.controls.model, session) {
                        self.view_deferred.push(ViewEvent::Panel(PanelEvent::ConfirmRemoveKeyframes {
                            title: "Speed".to_string(),
                            what: RemoveKeys::Speed,
                        }));
                    }
                }
                ViewEvent::ResetToAutomatic(property) => {
                    let clip = self.controls.model.clip().map(|c| c.id);
                    if let (Some(vp), Some(clip)) = (variant_property(&property), clip) {
                        session.reset_variant_override(vp, clip);
                    }
                }
                // The divider position is not stored yet.
                ViewEvent::PersistLabelWidth(_) => {}
                other => self.view_deferred.push(other),
            }
        }
    }

    /// A section that closes the column (the audio block, like Swift's non-leading sections) comes after the Controls
    /// rows, so the clip line and header stay on top; the whole stack then scrolls as one.
    fn closing(&self) -> bool {
        self.sections.height() > 0.0 && !self.sections.mode().leads()
    }

    /// A leading section (Text, Shape, Matte, Graphic, Template) sits between the clip header and the rows.
    fn leading(&self) -> bool {
        self.sections.height() > 0.0 && self.sections.mode().leads()
    }

    /// Any section makes the Controls view natural height and the whole stack scroll as one.
    fn stacked(&self) -> bool {
        self.sections.height() > 0.0
    }

    /// Height of the Controls view: the panel when no section is shown, else its own natural height (including the
    /// gap a leading section fills).
    fn controls_height(&self) -> f64 {
        if self.stacked() { self.controls.content_height() } else { self.frame.height.max(0.0) }
    }

    /// Panel y of the Controls view's top edge (points).
    fn controls_y(&self) -> f64 {
        -self.sections_scroll
    }

    /// Panel y of the sections' top edge (points): below the header when leading, below the rows when closing.
    fn sections_y(&self) -> f64 {
        if self.closing() {
            self.controls_height() - self.sections_scroll
        } else if self.leading() {
            self.controls.lead_top() - self.sections_scroll
        } else {
            -self.sections_scroll
        }
    }

    /// The part of the panel the sections cover (panel points, scrolled).
    fn sections_rect(&self) -> CGRect {
        CGRect::new(0.0, self.sections_y(), self.frame.width, self.sections.height())
    }

    /// The largest `sections_scroll`: what the stack is taller than the panel.
    fn sections_scroll_max(&self) -> f64 {
        let stack =
            if self.closing() { self.controls_height() + self.sections.height() } else { self.controls_height() };
        (stack - self.frame.height).max(0.0)
    }

    /// A point of the panel (points) in the sections' own coordinates.
    /// The Arrange and Animation parts of a text clip's Text block, between the Controls rows: part and frame in panel
    /// points (Swift `arrangeFrame`, `animationFrame`).
    fn slot_frames(&self) -> Vec<(TextPart, CGRect)> {
        if !self.text_shown() {
            return Vec::new();
        }
        let base = self.controls_y() + self.controls.top();
        let scroll = self.controls.rows_panel.scroll_y;
        self.controls
            .rows_panel
            .rows()
            .iter()
            .filter_map(|r| match r.kind {
                EffectRowKind::TextSlot(slot) => {
                    let part = match slot {
                        TextSlot::Arrange => TextPart::Arrange,
                        TextSlot::Animation => TextPart::Animation,
                    };
                    Some((part, CGRect::new(0.0, base + r.y - scroll, self.frame.width, r.height)))
                }
                _ => None,
            })
            .collect()
    }

    /// The text part under panel point `p` and `p` in that part's coordinates.
    fn slot_at(&self, p: CGPoint) -> Option<(TextPart, CGPoint)> {
        let in_frame = CGRect::new(0.0, 0.0, self.frame.width, self.frame.height).contains(p);
        self.slot_frames()
            .into_iter()
            .find(|(_, f)| in_frame && f.contains(p))
            .map(|(part, f)| (part, CGPoint::new(p.x, p.y - f.y)))
    }

    /// A drag or release point in the coordinates of the text part the press started in.
    fn text_space(&self, p: CGPoint) -> (TextPart, CGPoint) {
        match self.slot_pressed {
            Some((part, top)) => (part, CGPoint::new(p.x, p.y - top)),
            None => (TextPart::Text, self.in_sections_space(p)),
        }
    }

    fn in_sections_space(&self, p: CGPoint) -> CGPoint {
        CGPoint::new(p.x, p.y - self.sections_y())
    }

    fn local(&self, x: f32, y: f32) -> CGPoint {
        let k = f64::from(self.scale);
        CGPoint::new(f64::from(x) / k - self.frame.x, f64::from(y) / k - self.frame.y)
    }
}

/// The variant property a Motion row overrides (Tilt covers both axes).
fn variant_property(p: &EffectProperty) -> Option<VariantProperty> {
    match p {
        EffectProperty::Position => Some(VariantProperty::Position),
        EffectProperty::Scale => Some(VariantProperty::Scale),
        EffectProperty::Rotation => Some(VariantProperty::Rotation),
        EffectProperty::Anchor => Some(VariantProperty::Anchor),
        EffectProperty::TiltX | EffectProperty::TiltY => Some(VariantProperty::Tilt),
        _ => None,
    }
}

/// The audio clip (and its track) whose Audio sections a linked picture clip shows: only a plain video or image clip
/// (no section of its own) with an audio partner in the sequence has one.
fn linked_audio_partner(clip: &Clip, timeline: &Timeline) -> Option<(Clip, Id)> {
    if clip.kind == TrackKind::Audio || ClipSectionMode::resolve(Some(clip)) != ClipSectionMode::None {
        return None;
    }
    let link = clip.link?;
    timeline
        .tracks
        .iter()
        .filter(|tr| tr.kind == TrackKind::Audio)
        .find_map(|tr| tr.clips().iter().find(|x| x.link == Some(link) && x.id != clip.id).map(|x| (x.clone(), tr.id)))
}

/// The Looks list and the Look the selected text carries, as the Look popup shows them.
fn control_looks(session: &EditorSession, store: &LookStore) -> ControlLooks {
    let entries = session.looks(store);
    let state = session.look_state(store);
    let edited = state.is_edited();
    let carried = state.look_id().and_then(|token| entries.iter().find(|e| e.id() == token)).map(|e| LookStatus {
        name: e.look.name.clone(),
        edited,
        can_update: e.ref_.scope != LookScope::BuiltIn,
    });
    ControlLooks {
        entries: entries.iter().map(|e| (e.id(), e.look.name.clone())).collect(),
        selected: session.applied_look(store).map(|r| r.token()),
        carried,
    }
}

/// Runs the actions that need only the session and returns the rest, in order (Swift `ControlsHost.run`).
pub fn route_sections(session: &mut EditorSession, actions: Vec<SectionAction>) -> Vec<SectionAction> {
    let mut rest = Vec::new();
    for action in actions {
        match action {
            SectionAction::SetShapeKind { clip, kind } => session.set_shape_kind(kind, clip),
            SectionAction::SetColorMatte { clip, color, continues } => session.set_color_matte(clip, color, continues),
            SectionAction::AudioRole { track, role } => {
                session.set_track_audio_role(track, role);
            }
            SectionAction::AudioPreset { track, preset, continues } => {
                session.set_track_audio_preset(track, preset.as_deref(), continues);
            }
            SectionAction::AudioLoudness { track, lufs } => {
                session.set_track_loudness_target(track, lufs);
            }
            SectionAction::UpdateText { clip, from, to, animations, old_animations, forcing, continues } => {
                if session.selected_text_clips().is_empty() {
                    session.update_text_clip(clip, &to, Some(&animations), continues);
                } else {
                    session.update_text_clips(
                        clip,
                        &from,
                        &to,
                        Some(&animations),
                        old_animations.as_deref(),
                        continues,
                        &forcing,
                    );
                }
            }
            SectionAction::Template { clip, event } => match event {
                TemplateEvent::Slot { slot, value, continues } => {
                    session.set_template_slot(slot, value, clip, continues)
                }
                TemplateEvent::Zones(on) => {
                    session.set_zones_enabled(on, clip);
                }
                TemplateEvent::Middle(middle) => session.set_zone_middle(middle, clip),
            },
            // The height only matters to the layout, which reads it from the sections every frame.
            SectionAction::HeightChanged => {}
            other => rest.push(other),
        }
    }
    rest
}

impl AppHost for InspectorHost {
    fn sync(&mut self, session: &EditorSession) {
        let follow = (
            session.version(Change::SELECTION),
            session.version(Change::PROJECT),
            session.version(Change::PLAYHEAD),
            session.graphic_layer_selection_version(),
        );
        if self.followed != Some(follow) {
            self.followed = Some(follow);
            self.controls.model.sync(session, Change::SELECTION | Change::PROJECT | Change::PLAYHEAD);
            // The rows are built from the model: a new selection needs them rebuilt before the next draw.
            self.controls.relayout();
            self.multiband_stale = self.multiband.is_some();
            // The Motion rows a variant overrides offer "Reset to Automatic".
            let clip = self.controls.model.clip().map(|c| c.id);
            let rows = [
                EffectProperty::Position,
                EffectProperty::Scale,
                EffectProperty::Rotation,
                EffectProperty::Anchor,
                EffectProperty::TiltX,
                EffectProperty::TiltY,
            ];
            self.controls.rows_panel.automatic_resettable = rows
                .into_iter()
                .filter(|p| {
                    variant_property(p).zip(clip).is_some_and(|(vp, clip)| session.has_variant_override(vp, clip))
                })
                .collect();
        }
        let key = (session.version(Change::SELECTION), session.version(Change::PROJECT));
        if self.shown == Some(key) {
            self.sections.set_layer_selection(session.graphic_layer_selection());
            return;
        }
        self.shown = Some(key);
        self.transition.actions.selected_transition = session.selected_transition();
        let shown = self.transition.actions.shown(session);
        self.transition_on = shown.is_some();
        self.transition.show(shown);
        let mut selected = session.selected_edit_clips();
        let clip: Option<Clip> = (selected.len() == 1).then(|| selected.remove(0));
        let timeline = session.active_timeline();
        let tracks: Vec<_> =
            timeline.map(|t| t.tracks.iter().map(|tr| (tr.id, tr.audio_role)).collect()).unwrap_or_default();
        let clip_track = clip.as_ref().and_then(|c| {
            timeline.and_then(|t| t.tracks.iter().find(|tr| tr.clips().iter().any(|x| x.id == c.id)).map(|tr| tr.id))
        });
        // A linked picture clip has no sections of its own: its audio partner's track controls show beside it.
        let partner = clip.as_ref().and_then(|c| timeline.and_then(|t| linked_audio_partner(c, t)));
        let (section_clip, section_track) = match &partner {
            Some((a, track)) => (Some(a), Some(*track)),
            None => (clip.as_ref(), clip_track),
        };
        self.sections.sync(section_clip, &tracks, section_track, &mut *self.new_audio);
        let loudness: Vec<_> =
            timeline.map(|t| t.tracks.iter().map(|tr| (tr.id, tr.loudness_target_lufs)).collect()).unwrap_or_default();
        self.sections.sync_loudness(&loudness);
        let stored: Vec<_> = timeline
            .map(|t| {
                t.tracks.iter().map(|tr| (tr.id, sq_audiofx::track_preset::TrackPresetExt::audio_preset(tr))).collect()
            })
            .unwrap_or_default();
        self.sections.sync_presets(&stored);
        if let (true, Some(c)) = (self.text_shown(), clip.as_ref()) {
            let frame = sq_inspector_ui::ec::animation::AnimationChoices::frame_size(session.display_format().as_ref());
            let kit = session.project().style_kit.clone();
            let mixed = std::collections::BTreeSet::new();
            if let Some(store) = &self.looks {
                self.sections.set_looks(control_looks(session, store));
            }
            self.sections.load_text(c, &mut self.text_model, &mut self.text_block, kit, frame, mixed);
        }
        let shown_id = clip.as_ref().map(|c| c.id);
        if self.scrolled_for != shown_id {
            self.scrolled_for = shown_id;
            self.sections_scroll = 0.0; // another selection: the sections start at the top again
        }
        self.sections.set_layer_selection(session.graphic_layer_selection());
    }

    fn layout(&mut self, frame: CGRect, cx: &mut HostCx) {
        self.frame = frame;
        // Events are pixels: a display scale change must reach the hit tests before the next draw.
        self.scale = cx.scale;
        self.finish_eyedropper(cx);
        self.poll_popover_pick(cx);
        if self.transition_on {
            self.transition.size = CGSize::new(frame.width, frame.height);
            self.transition.tick(cx.session, cx.ui.now);
            self.serve_transition(cx);
            return;
        }
        self.sections.set_width(frame.width);
        self.text_block.width = frame.width;
        self.text_block.tick(&mut self.text_model, cx.ui.now);
        self.pump_text();
        self.sections_scroll = self.sections_scroll.clamp(0.0, self.sections_scroll_max());
        let size = |h: f64| sq_uikit::controls_grid::CGSize::new(frame.width, h.max(0.0));
        let slots = if self.text_shown() {
            (
                self.text_block.height(&self.text_model, TextPart::Arrange),
                self.text_block.height(&self.text_model, TextPart::Animation),
            )
        } else {
            (0.0, 0.0)
        };
        self.controls.set_text_slots(slots.0, slots.1);
        self.controls.set_lead(if self.leading() { self.sections.height() } else { 0.0 });
        self.controls.set_size(size(if self.stacked() { self.controls.content_height() } else { frame.height }));
        self.sections_scroll = self.sections_scroll.clamp(0.0, self.sections_scroll_max());
        self.controls.tick(cx.ui.now);
        self.run_due_replan(cx);
        self.poll_color_match(cx);
        if std::mem::take(&mut self.multiband_stale)
            && self.multiband.as_mut().is_some_and(|m| !m.draw.sync(&self.controls.model))
        {
            self.close_multiband_in(cx.ui);
        }
        if let Some(m) = &mut self.multiband {
            m.tick(&mut self.controls.model, cx.ui.now);
        }
    }

    fn draw(&mut self, c: &mut Canvas, t: &DrawTheme, cx: &mut HostCx) {
        self.feed_gain_reduction();
        self.feed_learn_noise(cx.session);
        self.feed_magic_check(cx.session);
        self.scale = c.scale;
        if self.transition_on {
            self.transition.theme = *t;
            c.save_gstate();
            c.translate_by(self.frame.x, self.frame.y);
            c.clip_to(CGRect::new(0.0, 0.0, self.frame.width, self.frame.height));
            self.transition.draw(c, cx.ui);
            c.restore_gstate();
            return;
        }
        self.sections.theme = *t;
        c.save_gstate();
        c.translate_by(self.frame.x, self.frame.y);
        // Nothing of this panel draws outside its dock frame: the sections and the rows are cut at its edges.
        c.clip_to(CGRect::new(0.0, 0.0, self.frame.width, self.frame.height));
        // The Controls view first: it fills its whole bounds, the lead gap included, so the sections come on top of it.
        c.translate_by(0.0, self.controls_y());
        self.controls.set_theme(*t);
        self.controls.draw(c, cx.ui);
        c.translate_by(0.0, -self.controls_y());
        c.save_gstate();
        c.translate_by(0.0, self.sections_y());
        self.sections.draw(c, cx.ui);
        if self.text_shown() {
            self.text_block.theme = *t;
            self.text_block.draw(&self.text_model, c, TextPart::Text, cx.ui, cx.ui.now);
        }
        c.restore_gstate();
        for (part, f) in self.slot_frames() {
            c.save_gstate();
            c.clip_to(f);
            c.translate_by(0.0, f.y);
            c.fill(CGRect::new(0.0, 0.0, f.width, f.height), t.panel());
            self.text_block.draw(&self.text_model, c, part, cx.ui, cx.ui.now);
            c.restore_gstate();
        }
        c.restore_gstate();
    }

    fn handle(&mut self, e: &InputEvent, cx: &mut HostCx) -> bool {
        self.scale = cx.scale;
        // A press here (not on the monitor picture) ends a running color pick.
        if let (InputEvent::MouseDown { .. }, Some((dropper, _))) = (e, &self.eyedropper) {
            dropper.cancel();
            self.finish_eyedropper(cx);
        }
        if self.transition_on {
            let inside = |x: f32, y: f32| {
                let p = self.local(x, y);
                CGRect::new(0.0, 0.0, self.frame.width, self.frame.height).contains(p)
            };
            let over = match *e {
                InputEvent::MouseDown { x, y, .. }
                | InputEvent::MouseMoved { x, y }
                | InputEvent::Scroll { x, y, .. } => inside(x, y),
                _ => true,
            };
            if !over {
                return false;
            }
            let origin = CGPoint::new(self.frame.x, self.frame.y);
            let taken = self.transition.handle(cx.session, cx.ui, e, self.scale, origin);
            self.serve_transition(cx);
            return taken;
        }
        let w = self.frame.width;
        let sections_rect = self.sections_rect();
        let in_frame = |p: CGPoint| CGRect::new(0.0, 0.0, w, self.frame.height).contains(p);
        // The panel cuts the stack: a section row scrolled past the frame edge takes no click.
        let in_sections = |p: CGPoint| sections_rect.contains(p) && in_frame(p);
        let origin = CGPoint::new(self.frame.x, self.frame.y + self.controls_y());
        let taken = match *e {
            InputEvent::MouseDown { x, y, .. } => {
                let p = self.local(x, y);
                if in_sections(p) {
                    let q = self.in_sections_space(p);
                    if self.text_shown() {
                        self.text_block.mouse_down(&mut self.text_model, q, TextPart::Text, Some(1), None, cx.ui);
                    } else {
                        self.sections.mouse_down(cx.ui, q, 1);
                    }
                    true
                } else if let Some((part, q)) = self.slot_at(p) {
                    self.slot_pressed = Some((part, p.y - q.y));
                    self.text_block.mouse_down(&mut self.text_model, q, part, Some(1), None, cx.ui);
                    true
                } else if in_frame(p) {
                    if self.text_shown() {
                        self.text_block.resign_focus(&mut self.text_model, cx.ui);
                    }
                    self.controls.handle(cx.ui, e, self.scale, origin)
                } else {
                    return false;
                }
            }
            InputEvent::MouseDragged { x, y, .. } => {
                let (_, p) = self.text_space(self.local(x, y));
                self.sections.mouse_dragged(cx.ui, p, sq_draw::InputModifiers::NONE);
                if self.text_shown() {
                    let m = sq_draw::InputModifiers::NONE;
                    self.text_block.mouse_dragged(&mut self.text_model, p, m, None, cx.ui);
                }
                self.controls.handle(cx.ui, e, self.scale, origin);
                false
            }
            InputEvent::MouseUp { x, y } => {
                let (part, p) = self.text_space(self.local(x, y));
                self.slot_pressed = None;
                self.sections.mouse_up(cx.ui, p);
                if self.text_shown() {
                    self.text_block.mouse_up(&mut self.text_model, p, part, cx.ui);
                }
                self.controls.handle(cx.ui, e, self.scale, origin);
                false
            }
            InputEvent::MouseMoved { x, y } => {
                let p = self.local(x, y);
                self.sections.mouse_moved(in_sections(p).then(|| self.in_sections_space(p)));
                if self.text_shown() {
                    let q = in_sections(p).then(|| self.in_sections_space(p));
                    self.text_block.mouse_moved(&self.text_model, q, TextPart::Text, cx.ui.now);
                    if q.is_none() {
                        let slot = self.slot_at(p);
                        let part = slot.map_or(TextPart::Arrange, |(part, _)| part);
                        self.text_block.mouse_moved(&self.text_model, slot.map(|(_, q)| q), part, cx.ui.now);
                    }
                }
                if !in_sections(p) {
                    self.controls.handle(cx.ui, e, self.scale, origin);
                }
                false
            }
            InputEvent::Scroll { x, y, dy, .. } => {
                let p = self.local(x, y);
                // The controls take the wheel first when they scroll or zoom; a closing section's stack scrolls with what
                // they leave.
                let over_controls = in_frame(p) && !in_sections(p);
                let mut taken = over_controls && self.controls.handle(cx.ui, e, self.scale, origin);
                if !taken && (in_sections(p) || (over_controls && self.stacked())) {
                    // Sections taller than the panel scroll under the wheel; otherwise the wheel goes on.
                    let to = (self.sections_scroll - f64::from(dy / self.scale)).clamp(0.0, self.sections_scroll_max());
                    taken = to != self.sections_scroll;
                    self.sections_scroll = to;
                }
                taken
            }
            // A menu chord (Export, Save ...) is not for a field: the typed value commits as when the keyboard leaves the
            // panel, and the key goes on to the app.
            InputEvent::KeyDown { key, modifiers } if key.is_menu_chord(modifiers) => {
                self.blur(cx);
                false
            }
            InputEvent::KeyDown { key, modifiers } => {
                (self.text_shown() && self.text_block.key(&mut self.text_model, key, modifiers, cx.ui))
                    || self.sections.key(cx.ui, key, modifiers)
                    || self.controls.key(cx.ui, key, modifiers)
            }
        };
        self.route(cx);
        taken
    }

    fn a11y(&self, a: &mut A11y) {
        self.push_nodes(a);
    }

    fn a11y_action(&mut self, id: accesskit::NodeId, action: A11yAction, cx: &mut HostCx) -> bool {
        self.run_action(id, action, cx)
    }

    fn on_change(&mut self, _changes: Change, cx: &mut HostCx) {
        self.route(cx);
    }
}

#[cfg(test)]
mod tests;

/// True when this clip's Standard Stabilizer was planned with other settings than the ones it now stores (the first look
/// counts as changed, so the first edit of a clip never misses a re-plan).
fn stabilizer_changed(seen: &mut BTreeMap<Id, StabilizerOptions>, clip: &Clip) -> bool {
    let Some(effect) = clip.effect_of_kind(ClipEffect::STABILIZE_KIND) else {
        seen.remove(&clip.id);
        return false;
    };
    if effect.stabilize_method() != StabilizerMethod::Standard {
        return false;
    }
    let now = StabilizerOptions::from_effect(effect);
    seen.insert(clip.id, now).is_none_or(|before| !before.same_plan_as(&now))
}
