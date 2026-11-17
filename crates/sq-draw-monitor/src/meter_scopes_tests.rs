//! MeterPanelTests, MeterStripTests, ScopesPanelTests, ScopesHintTests, ScopeTraceSettingsTests (card part) and
//! ScopeImageCacheTests of the Swift package.

use crate::memory_defaults::MemoryDefaults;
use crate::meter_panel::{MeterDefaults, MeterPanel, MeterPanelEvent};
use crate::scope_trace_settings::ScopeTraceSettings;
use crate::scopes_panel::{ScopeCountsSource, ScopeSource, ScopesMode, ScopesPanel};
use crate::test_support::canvas;
use sq_audiofx::channel_monitor::ChannelMonitor;
use sq_audiofx::monitor_gain::MonitorGain;
use sq_draw::monitor::audio_meter::{AudioMeter, MeterChannelLabel, MeterReading, MeterStyle};
use sq_draw::monitor::loudness_meter::{LoudnessMeter, LoudnessReading};
use sq_draw::monitor::scope_graticule::ScopeKind;
use sq_draw::monitor::scopes_drawing::ScopeBoxLayout;
use sq_draw::theme::metrics;
use sq_draw::{InputEvent, InputModifiers, Rect};
use sq_render::passes::scope_binning::{ScopeCounts, ScopeLayout, compute_nv12, compute_rgba};
use sq_uikit::appearance_palette::UiDefaults;
use sq_uikit::controls_grid::{CGPoint, CGRect};
use sq_uikit::sqmenu_model::SQMenuItemKind;

fn meter(h: f32) -> MeterPanel {
    let mut p = MeterPanel::new(Box::new(MemoryDefaults::default()));
    p.layout_px(Rect::new(0.0, 0.0, 120.0, h), 1.0);
    p
}

fn reading(seq: i64) -> Option<MeterReading> {
    Some(MeterReading { source: 7, sequence: seq, peaks: vec![0.5, 0.5] })
}

fn loud() -> LoudnessReading {
    LoudnessReading {
        momentary_lufs: Some(-20.0),
        short_term_lufs: Some(-21.0),
        integrated_lufs: Some(-22.0),
        true_peak_db: -3.0,
    }
}

#[test]
fn meter_and_loudness_columns_sit_centered_when_they_fit() {
    let mut p = meter(300.0);
    assert_eq!(p.meter_rect().width, AudioMeter::WIDTH);
    assert_eq!(p.loudness_rect().width, LoudnessMeter::COLUMNS_WIDTH);
    assert!((p.meter_rect().min_x() - (120.0 - p.loudness_rect().max_x())).abs() <= 1.0);
    p.layout_px(Rect::new(0.0, 0.0, 60.0, 300.0), 1.0);
    assert_eq!(p.loudness_rect(), CGRect::default());
}

#[test]
fn new_buffers_move_the_bars_and_a_stale_feed_silences_them() {
    let mut p = meter(300.0);
    p.reading = reading(1);
    p.loudness_reading = Some(loud());
    p.poll(10.0);
    assert!(!p.meter.is_settled());
    assert_eq!(p.loudness.reading().momentary_lufs, Some(-20.0));
    p.poll(10.5); // same buffer number: playback stopped
    assert_eq!(p.loudness.reading().momentary_lufs, None);
    assert_eq!(p.loudness.reading().integrated_lufs, Some(-22.0));
}

#[test]
fn meter_follows_the_ballistics_setting_at_each_buffer() {
    let mut d = MemoryDefaults::default();
    d.set_string(MeterStyle::DEFAULTS_KEY, MeterStyle::Fast.raw_value());
    let mut p = MeterPanel::new(Box::new(d));
    p.layout_px(Rect::new(0.0, 0.0, 120.0, 300.0), 1.0);
    p.reading = reading(1);
    p.poll(10.0);
    assert_eq!(p.meter.style(), MeterStyle::Fast);
}

#[test]
fn click_on_loudness_resets_and_right_click_opens_the_menu() {
    let mut p = meter(300.0);
    let l = p.loudness_rect();
    let at = CGPoint::new(l.mid_x(), l.mid_y());
    p.handle_event(&InputEvent::MouseDown { x: at.x as f32, y: at.y as f32, modifiers: InputModifiers::NONE });
    p.handle_event(&InputEvent::MouseDown { x: at.x as f32, y: at.y as f32, modifiers: InputModifiers::SECONDARY });
    let ev = p.take_events();
    assert_eq!(ev.iter().filter(|e| matches!(e, MeterPanelEvent::ResetLoudness)).count(), 1);
    let titles: Vec<String> = ev
        .iter()
        .filter_map(|e| {
            if let MeterPanelEvent::Menu(items, _) = e {
                Some(items.iter().map(|i| i.title.clone()).collect())
            } else {
                None
            }
        })
        .next_back()
        .unwrap_or_default();
    assert_eq!(titles.last().map(String::as_str), Some("Reset Peak and Loudness"));
    assert!(titles.contains(&"Dim Monitor".to_string()));
}

// MeterStripTests

fn strip(h: f32) -> MeterPanel {
    let mut p = MeterPanel::new(Box::new(MemoryDefaults::default()));
    p.layout_px(Rect::new(0.0, 0.0, 104.0, h), 1.0);
    p
}

fn click(p: &mut MeterPanel, at: CGPoint, m: InputModifiers) {
    p.handle_event(&InputEvent::MouseDown { x: at.x as f32, y: at.y as f32, modifiers: m });
    p.handle_event(&InputEvent::MouseUp { x: at.x as f32, y: at.y as f32 });
}

/// The label row under the bars of bar `i`. (The Swift test probes 8 pt apart; bar 1's probe then lands on bar 0's
/// inclusive edge, so the bars' own 10 pt pitch is used here.)
fn label(p: &MeterPanel, i: usize) -> CGPoint {
    CGPoint::new(p.meter_rect().min_x() + 8.0 + i as f64 * 10.0 + 2.0, p.meter_rect().max_y() - 8.0)
}

fn contains(outer: CGRect, inner: CGRect) -> bool {
    inner.min_x() >= outer.min_x()
        && inner.max_x() <= outer.max_x()
        && inner.min_y() >= outer.min_y()
        && inner.max_y() <= outer.max_y()
}

#[test]
fn strip_shows_under_the_meter_only_when_the_card_is_tall_enough() {
    let p = strip(400.0);
    assert_eq!(p.strip_rect().height, f64::from(metrics::MONITOR_STRIP));
    assert_eq!(p.meter_rect().max_y(), p.strip_rect().min_y());
    assert!(contains(p.strip_rect(), p.slider_rect()) && contains(p.strip_rect(), p.dim_rect()));
    let small = strip(90.0);
    assert!(small.strip_rect() == CGRect::default() && small.meter_rect().height == 90.0);
}

#[test]
fn dim_button_toggles_the_stored_setting_and_reports_it() {
    let mut p = strip(400.0);
    let d = p.dim_rect();
    click(&mut p, CGPoint::new(d.mid_x(), d.mid_y()), InputModifiers::NONE);
    assert!(p.monitor_setting().dim);
    assert!(p.take_events().iter().any(|e| matches!(e, MeterPanelEvent::MonitorGainChange(s) if s.dim)));
    click(&mut p, CGPoint::new(d.mid_x(), d.mid_y()), InputModifiers::NONE);
    assert!(!p.monitor_setting().dim);
}

#[test]
fn slider_drag_sets_the_listening_level() {
    let mut p = strip(400.0);
    let r = p.slider_rect();
    p.handle_event(&InputEvent::MouseDown {
        x: (r.max_x() - 1.0) as f32,
        y: r.mid_y() as f32,
        modifiers: InputModifiers::NONE,
    });
    assert_eq!(p.monitor_setting().level_db, MonitorGain::MAX_DB);
    assert!(p.handle_event(&InputEvent::dragged(r.min_x() as f32, r.mid_y() as f32)));
    assert_eq!(p.monitor_setting().level_db, MonitorGain::MIN_DB);
    assert!(p.handle_event(&InputEvent::MouseUp { x: r.min_x() as f32, y: r.mid_y() as f32 }));
    assert!(!p.handle_event(&InputEvent::dragged(r.max_x() as f32, r.mid_y() as f32))); // the drag ended
    assert!((MeterPanel::level_db(MeterPanel::slider_fraction(-18.0)) + 18.0).abs() < 1e-9);
}

#[test]
fn label_click_solos_alt_click_mutes() {
    let mut p = strip(400.0);
    let l0 = label(&p, 0);
    click(&mut p, l0, InputModifiers::NONE);
    assert!(p.channel_monitor().is_soloed(0));
    assert_eq!(p.channel_labels(), [MeterChannelLabel::Soloed, MeterChannelLabel::Silenced]);
    let l1 = label(&p, 1);
    click(&mut p, l1, InputModifiers::OPTION);
    assert!(p.channel_monitor().is_muted(1));
    assert_eq!(p.channel_labels(), [MeterChannelLabel::Soloed, MeterChannelLabel::Muted]);
    p.clear_channel_monitor();
    assert_eq!(p.channel_labels(), [MeterChannelLabel::Normal, MeterChannelLabel::Normal]);
    let changes: Vec<ChannelMonitor> = p
        .take_events()
        .into_iter()
        .filter_map(|e| if let MeterPanelEvent::ChannelMonitorChange(c) = e { Some(c) } else { None })
        .collect();
    assert!(changes.len() == 3 && changes.last().is_some_and(ChannelMonitor::is_neutral));
}

#[test]
fn menu_has_listening_channel_and_dim_rows() {
    let mut p = strip(400.0);
    let titles: Vec<String> = p.menu_items().iter().map(|i| i.title.clone()).collect();
    for t in [
        "Full (0 dB)",
        "\u{2212}12 dB",
        "Solo L",
        "Mute R",
        "Clear Solo and Mute",
        "Dim Monitor",
        "Reset Peak and Loudness",
    ] {
        assert!(titles.contains(&t.to_string()), "{t}");
    }
    if let Some(a) = p.menu_items().iter().find(|i| i.title == "\u{2212}12 dB").and_then(|i| i.action.clone()) {
        a();
    }
    p.pump();
    assert_eq!(p.monitor_setting().level_db, -12.0);
    assert!(p.menu_items().iter().any(|i| i.title == "\u{2212}12 dB" && i.is_checked));
}

#[test]
fn the_meter_card_draws_with_the_strip() {
    let mut p = strip(400.0);
    let mut c = sq_draw::canvas::Canvas::with_size(104.0, 400.0, None, 1.0);
    p.draw_card(&mut c, &p.theme.clone());
    assert!(!c.list.quads().is_empty());
}

// Scopes

fn counts() -> ScopeCounts {
    let (w, h) = (16usize, 8usize);
    let px: Vec<u8> = (0..w * h).flat_map(|i| [(i * 2 % 256) as u8, (i % 256) as u8, 200, 255]).collect();
    compute_rgba(&px, w, h, ScopeLayout::default(), 1)
}

fn scopes() -> ScopesPanel {
    let mut p = ScopesPanel::new();
    p.layout_px(Rect::new(0.0, 0.0, 320.0, 520.0), 1.0);
    p
}

#[test]
fn the_card_shows_one_big_waveform() {
    let mut p = scopes();
    assert_eq!(p.slots().len(), 1);
    assert!(p.slots()[0].box_.height > ScopeBoxLayout::FIRST_BOX);
    assert_eq!(p.kinds(), [ScopeKind::Waveform]);
    p.layout_px(Rect::new(0.0, 0.0, 320.0, 260.0), 1.0);
    assert_eq!(p.slots().len(), 1);
}

#[test]
fn a_frame_bins_into_scope_pictures_at_the_plot_size() {
    let mut p = scopes();
    let (w, h) = (64usize, 36usize);
    let mut bytes = vec![126u8; w * h];
    bytes.extend(vec![128u8; w * h / 2]);
    p.update_nv12(&bytes, w, h, false, false, 1);
    let plot = ScopeBoxLayout::plot(
        ScopeKind::Waveform,
        sq_uikit::controls_grid::CGSize::new(p.slots()[0].box_.width, p.slots()[0].box_.height),
    );
    assert_eq!(p.images()[0].as_ref().map(|i| i.width), Some(plot.width.round() as usize));
    p.select(ScopeKind::Vectorscope, 0);
    let v = p.images()[0].as_ref().unwrap_or_else(|| panic!("vectorscope"));
    assert_eq!(v.pixels[3], 0); // corner outside the vectorscope ring is transparent
}

struct Gpu {
    reads: usize,
    strides: Vec<usize>,
    counts: Option<ScopeCounts>,
}

impl ScopeCountsSource for Gpu {
    fn scope_counts(&mut self, pixel_stride: usize) -> Option<ScopeCounts> {
        self.reads += 1;
        self.strides.push(pixel_stride);
        self.counts.clone()
    }
}

#[test]
fn gpu_counts_skip_the_cpu_binning_once_per_generation() {
    let mut p = scopes();
    let mut src = Gpu { reads: 0, strides: Vec::new(), counts: None };
    assert!(!p.measure(&mut src, 1)); // nothing on the GPU: the host falls back to the readback
    let (w, h) = (64usize, 36usize);
    let mut nv12 = vec![126u8; w * h];
    nv12.extend(vec![128u8; w * h / 2]);
    src.counts = Some(compute_nv12(&nv12, w, h, false, ScopeLayout::default(), 1));
    assert!(p.measure(&mut src, 2));
    assert!(p.images()[0].is_some());
    let shown = p.image_generation();
    assert!(p.measure(&mut src, 2));
    assert!(src.reads == 2 && p.image_generation() == shown);
    assert_eq!(src.strides, [p.pixel_stride, p.pixel_stride]);
}

#[test]
fn the_popup_offers_every_scope_and_switches() {
    let mut p = scopes();
    let r = p.slots()[0].popup;
    p.handle_event(
        &InputEvent::MouseDown { x: (r.min_x() + 4.0) as f32, y: r.mid_y() as f32, modifiers: InputModifiers::NONE },
        None,
    );
    let items = p.menus.pop().map(|m| m.items).unwrap_or_default();
    assert_eq!(
        items.iter().map(|i| i.title.as_str()).collect::<Vec<_>>(),
        ScopeKind::ALL.iter().map(|k| ScopeBoxLayout::title(*k)).collect::<Vec<_>>()
    );
    if let Some(a) = &items[1].action {
        a();
    }
    p.pump();
    assert_eq!(p.kinds()[0], ScopeKind::Parade);
}

#[test]
fn the_mode_switches_between_one_big_scope_and_all_four() {
    let mut p = scopes();
    let (w, h) = (64usize, 36usize);
    let mut nv12 = vec![126u8; w * h];
    nv12.extend(vec![128u8; w * h / 2]);
    p.update_nv12(&nv12, w, h, false, false, 1);
    assert_eq!(p.mode(), ScopesMode::One);
    p.select(ScopeKind::Parade, 0);
    assert_eq!((p.kinds(), p.selected()), (&[ScopeKind::Parade][..], ScopeKind::Parade));
    p.toggle_all();
    assert_eq!(p.mode(), ScopesMode::All);
    assert_eq!(p.kinds(), ScopeKind::ALL);
    assert_eq!(p.slots().len(), 4);
    assert!(p.slots()[1].box_.min_x() > p.slots()[0].box_.max_x(), "2 x 2 grid");
    assert!(p.slots()[2].box_.min_y() > p.slots()[0].box_.max_y());
    let atlas = p.images()[0].as_ref().unwrap_or_else(|| panic!("the four scopes in one picture"));
    assert!(atlas.width > 0 && atlas.height > 0);
    // Picking a scope in the grid goes back to one big scope of that kind.
    p.select(ScopeKind::Histogram, 3);
    assert_eq!((p.mode(), p.kinds()), (ScopesMode::One, &[ScopeKind::Histogram][..]));
    assert_eq!(p.slots().len(), 1);
}

#[test]
fn a_double_click_on_a_scope_toggles_all_four() {
    let mut p = scopes();
    let b = p.slots()[0].box_;
    let mut cx = sq_draw::UiCx::new();
    let down = InputEvent::MouseDown { x: b.mid_x() as f32, y: b.mid_y() as f32, modifiers: InputModifiers::NONE };
    p.handle_event(&down, Some(&mut cx));
    assert_eq!(p.mode(), ScopesMode::One);
    p.handle_event(&down, Some(&mut cx));
    assert_eq!(p.mode(), ScopesMode::All);
}

#[test]
fn the_head_names_what_is_measured() {
    let mut p = scopes();
    assert_eq!(p.source.label(), "PROGRAM");
    p.source = ScopeSource::Source;
    assert_eq!(p.source.label(), "SOURCE");
    let mut c = sq_draw::canvas::Canvas::with_size(320.0, 520.0, None, 1.0);
    p.draw_card(&mut c, &sq_draw::theme::DrawTheme::default());
}

#[test]
fn the_hint_line_pushes_the_scopes_down() {
    let mut p = scopes();
    assert!(p.hint_frame().is_none());
    let top = p.slots()[0].popup.min_y();
    assert_eq!(top, ScopeBoxLayout::TOP);
    p.hint = Some("On screen: B-roll".to_string());
    p.layout_px(Rect::new(0.0, 0.0, 320.0, 520.0), 1.0);
    assert_eq!(p.hint_frame(), Some(CGRect::new(12.0, 4.0, 296.0, ScopesPanel::HINT_LINE_HEIGHT)));
    assert_eq!(p.slots()[0].popup.min_y(), top + ScopesPanel::HINT_LINE_HEIGHT + 4.0);
    assert_eq!(p.slots().len(), 1);
    p.hint = None;
    p.layout_px(Rect::new(0.0, 0.0, 320.0, 520.0), 1.0);
    assert!(p.hint_frame().is_none() && p.slots()[0].popup.min_y() == top);
}

#[test]
fn the_hint_says_what_is_measured() {
    assert_eq!(ScopesPanel::hint_text("On screen: B-roll"), "Measuring B-roll, not the graded clip");
    assert_eq!(ScopesPanel::hint_text("On screen: no clip"), "Measuring no clip, not the graded clip");
}

#[test]
fn the_cards_waveform_slot_has_a_settings_button_that_opens_the_menu() {
    let mut p = scopes();
    p.toggle_all();
    assert!(p.slots().len() == 4 && p.kinds() == ScopeKind::ALL);
    let b = p.settings_button(0).unwrap_or_else(|| panic!("a waveform settings button"));
    assert!(p.settings_button(2).is_none(), "the vectorscope has no waveform settings");
    assert!(b.max_x() == p.slots()[0].popup.max_x() && b.mid_y() == p.slots()[0].popup.mid_y());
    let down = |p: &mut ScopesPanel, at: CGPoint, m: InputModifiers| {
        p.handle_event(&InputEvent::MouseDown { x: at.x as f32, y: at.y as f32, modifiers: m }, None)
    };
    assert!(down(&mut p, CGPoint::new(b.mid_x(), b.mid_y()), InputModifiers::NONE));
    let shown = p.menus.pop().map(|m| m.items).unwrap_or_default();
    assert_eq!(shown.iter().filter(|i| i.kind == SQMenuItemKind::Action).count(), ScopeTraceSettings::STEPS.len());
    // A right-click on the waveform box opens the same menu; on the vectorscope nothing opens.
    let bx = p.slots()[0].box_;
    assert!(down(&mut p, CGPoint::new(bx.mid_x(), bx.mid_y()), InputModifiers::SECONDARY));
    assert!(!p.menus.is_empty());
    p.menus.clear();
    let vec = p.slots()[2].box_;
    down(&mut p, CGPoint::new(vec.mid_x(), vec.mid_y()), InputModifiers::SECONDARY);
    assert!(p.menus.is_empty());
    // The tip names the button; switching the first scope to the vectorscope drops it.
    assert_eq!(p.help_at(CGPoint::new(b.mid_x(), b.mid_y())).as_deref(), Some(ScopeTraceSettings::BUTTON_TIP));
    p.select(ScopeKind::Vectorscope, 0);
    assert!(p.settings_button(0).is_none());
}

#[test]
fn a_second_layout_keeps_the_pictures_and_only_changes_redraw_them() {
    let mut p = ScopesPanel::new();
    let r = Rect::new(0.0, 0.0, 320.0, 520.0);
    p.layout_px(r, 1.0);
    p.update_counts(counts(), 1);
    let g = p.image_generation();
    assert!(p.images()[0].is_some());
    for _ in 0..5 {
        p.layout_px(r, 1.0);
    }
    assert_eq!(p.image_generation(), g);
    // A new size, scale, scope kind, intensity or frame draws them again.
    p.layout_px(Rect::new(0.0, 0.0, 300.0, 520.0), 1.0);
    assert_eq!(p.image_generation(), g + 1);
    p.layout_px(Rect::new(0.0, 0.0, 300.0, 520.0), 2.0);
    assert_eq!(p.image_generation(), g + 2);
    p.select(ScopeKind::Histogram, 0);
    assert_eq!(p.image_generation(), g + 3);
    p.select(ScopeKind::Waveform, 0);
    let g2 = p.image_generation();
    p.settings.set_intensity(2.0);
    p.layout_px(Rect::new(0.0, 0.0, 300.0, 520.0), 2.0);
    assert_eq!(p.image_generation(), g2 + 1);
    p.update_counts(counts(), 2);
    assert_eq!(p.image_generation(), g2 + 2);
    p.layout_px(Rect::new(0.0, 0.0, 300.0, 520.0), 2.0);
    assert_eq!(p.image_generation(), g2 + 2);
    // Clearing drops the pictures.
    p.clear();
    assert!(p.images()[0].is_none());
}

#[test]
fn the_scopes_card_draws_into_a_list() {
    let mut p = scopes();
    p.update_counts(counts(), 1);
    let mut c = canvas();
    p.draw_card(&mut c, &p.theme.clone());
    assert!(!c.list.quads().is_empty());
    let _: &dyn MeterDefaults = &MemoryDefaults::default();
}
