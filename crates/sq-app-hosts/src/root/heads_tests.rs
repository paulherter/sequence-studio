//! One table over every panel head and inner tab strip at the smallest window: no two texts overlap, no text runs out of
//! its panel, and every title is whole or ends at a word boundary (never `Captio...`), on the three systems' texts.

use super::*;
use sq_draw::GlyphAtlas;
use sq_draw::text_log::{self, TextRun};
use sq_editor_session::WorkspacePage;
use sq_os::Platform;
use sq_runtime::FakeClock;
use std::sync::Arc;

const SIZES: [(f32, f32); 2] = [(640.0, 400.0), (800.0, 600.0)];

fn fonts_root() -> std::path::PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts")
}

fn atlas() -> &'static GlyphAtlas {
    thread_local! {
        static ATLAS: &'static GlyphAtlas = {
            Box::leak(Box::new(GlyphAtlas::inter(&fonts_root()).unwrap_or_else(|| panic!("bundled Inter loads"))))
        };
    }
    ATLAS.with(|a| *a)
}

fn full_root(page: WorkspacePage) -> (AppRoot, crate::test_rig::Rig) {
    let dir = crate::test_rig::test_dir("sq-heads");
    std::fs::create_dir_all(&dir).expect("dir");
    let clock = Arc::new(FakeClock::new());
    let mut r = crate::standard_root(&dir, clock, DrawTheme::default()).expect("root");
    r.dock.set_page(page);
    let rig = crate::test_rig::Rig::new(super::dead_commands_tests::demo_session(
        super::dead_commands_tests::Scenario::Plain,
    ));
    r.sync(&rig.session);
    (r, rig)
}

/// Lays out and draws one frame at `size`; the text it drew.
fn draw_frame(r: &mut AppRoot, rig: &mut crate::test_rig::Rig, size: (f32, f32)) -> Vec<TextRun> {
    let t = DrawTheme::default();
    let mut c = Canvas::with_size(size.0, size.1, Some(atlas()), 1.0);
    let mut cx = HostCx {
        session: &mut rig.session,
        ui: &mut rig.ui,
        services: &mut rig.services,
        events: &mut rig.events,
        atlas: Some(atlas()),
        scale: 1.0,
    };
    text_log::start();
    r.layout(CGRect::new(0.0, 0.0, f64::from(size.0), f64::from(size.1)), &mut cx);
    AppHost::draw(r, &mut c, &t, &mut cx);
    let mut runs = text_log::finish();
    runs.dedup();
    runs
}

fn hit(a: Box4, b: Box4) -> bool {
    a.0 + 0.5 < b.0 + b.2 && b.0 + 0.5 < a.0 + a.2 && a.1 + 1.0 < b.1 + b.3 && b.1 + 1.0 < a.1 + a.3
}

type Box4 = (f32, f32, f32, f32);

fn cut_to(a: Box4, clip: Box4) -> Option<Box4> {
    let (l, t) = (a.0.max(clip.0), a.1.max(clip.1));
    let (r, b) = ((a.0 + a.2).min(clip.0 + clip.2), (a.1 + a.3).min(clip.1 + clip.3));
    (r > l && b > t).then_some((l, t, r - l, b - t))
}

/// What is wrong with `runs` inside `area` (left, top, width, height), as readable lines. Only text that shows counts:
/// a run wholly outside its clip is not on screen, and one that is cut by its clip is a clipped label.
fn problems(label: &str, runs: &[TextRun], area: Box4) -> Vec<String> {
    let inside: Vec<(&TextRun, Box4)> = runs
        .iter()
        .filter_map(|r| {
            let seen = cut_to(r.rect, r.clip)?;
            let c = (seen.0 + seen.2 / 2.0, seen.1 + seen.3 / 2.0);
            (c.0 >= area.0 && c.0 <= area.0 + area.2 && c.1 >= area.1 && c.1 <= area.1 + area.3).then_some((r, seen))
        })
        .collect();
    let mut out = Vec::new();
    for (i, (a, sa)) in inside.iter().enumerate() {
        if a.is_cut_inside_a_word() {
            out.push(format!(
                "{label}: cut inside a word \"{}\" -> \"{}\"",
                a.asked,
                a.drawn.clone().unwrap_or_default()
            ));
        }
        if a.rect.0 < area.0 - 0.5 || a.rect.0 + a.rect.2 > area.0 + area.2 + 0.5 {
            out.push(format!(
                "{label}: \"{}\" leaves the panel ({:.0}..{:.0}, clip {:.0?})",
                a.asked,
                a.rect.0,
                a.rect.0 + a.rect.2,
                a.clip
            ));
        }
        if sa.2 + 0.5 < a.rect.2 {
            out.push(format!("{label}: \"{}\" is clipped ({:.0} of {:.0} px show)", a.asked, sa.2, a.rect.2));
        }
        for (b, sb) in &inside[i + 1..] {
            if a.rect.2 > 0.0 && b.rect.2 > 0.0 && hit(*sa, *sb) {
                out.push(format!("{label}: \"{}\" overlaps \"{}\" at {:?}", a.asked, b.asked, sa));
            }
        }
    }
    out
}

/// The head band of the group showing `p`: the tab strip and the panel's own header row under it.
fn head_area(r: &AppRoot, p: PanelID) -> Option<(f32, f32, f32, f32)> {
    let g = r.dock.groups().iter().find(|g| g.selected == p && !g.is_floating)?;
    let f = g.frame;
    let top = f.y as f32;
    let h = (g.content.y - f.y) as f32 + 36.0;
    Some((f.x as f32, top, f.width as f32, h.min(f.height as f32)))
}

#[test]
fn every_panel_head_fits_at_the_smallest_window_on_every_system() {
    let mut failures = Vec::new();
    for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
        Platform::with_override(platform, || {
            for page in [WorkspacePage::Edit, WorkspacePage::Color] {
                for size in SIZES {
                    let (mut r, mut rig) = full_root(page);
                    for p in PanelID::ALL {
                        r.dock.show(p);
                        let runs = draw_frame(&mut r, &mut rig, size);
                        let runs = draw_frame_again(&mut r, &mut rig, size, runs);
                        let Some(area) = head_area(&r, p) else { continue };
                        // A dock layout under a panel's own minimum is the dock's to fix, not the head's.
                        let g = r.dock.groups().iter().find(|g| g.selected == p && !g.is_floating);
                        if g.is_some_and(|g| g.content.width < p.min_size().0 || g.content.height < p.min_size().1) {
                            continue;
                        }
                        failures.extend(problems(
                            &format!("{platform:?} {page:?} {size:?} {p:?} in {area:.0?}"),
                            &runs,
                            area,
                        ));
                    }
                }
            }
        });
    }
    failures.sort();
    failures.dedup();
    assert!(failures.is_empty(), "{} head problems:\n{}", failures.len(), failures.join("\n"));
}

/// A second frame: animations and lazily sized parts have settled.
fn draw_frame_again(
    r: &mut AppRoot,
    rig: &mut crate::test_rig::Rig,
    size: (f32, f32),
    _first: Vec<TextRun>,
) -> Vec<TextRun> {
    draw_frame(r, rig, size)
}

#[test]
fn the_captions_tab_strip_fits_at_the_smallest_window() {
    use sq_inspector_ui::text::panel_draw::Tab;
    let mut failures = Vec::new();
    for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
        Platform::with_override(platform, || {
            for size in SIZES {
                for tab in Tab::ALL {
                    let (mut r, mut rig) = full_root(WorkspacePage::Edit);
                    r.dock.show(PanelID::Text);
                    draw_frame(&mut r, &mut rig, size);
                    if let Some(text) = r.text.as_mut() {
                        text.panel().select(&rig.session, tab);
                    }
                    let runs = draw_frame(&mut r, &mut rig, size);
                    let area = head_area(&r, PanelID::Text).expect("the Captions panel is on screen");
                    failures.extend(problems(&format!("{platform:?} {size:?} {tab:?}"), &runs, area));
                }
            }
        });
    }
    failures.sort();
    failures.dedup();
    assert!(failures.is_empty(), "{} caption tab problems:\n{}", failures.len(), failures.join("\n"));
}

/// The text a dialog adds over the plain frame.
fn dialog_runs(with: &[TextRun], without: &[TextRun]) -> Vec<TextRun> {
    let mut rest = without.to_vec();
    with.iter()
        .filter(|r| match rest.iter().position(|o| o == *r) {
            Some(i) => {
                rest.swap_remove(i);
                false
            }
            None => true,
        })
        .cloned()
        .collect()
}

/// Encodes nothing: the sheets are only opened here, never run.
struct NoEncoder;

impl sq_export::core::traits::ExportEncoding for NoEncoder {
    fn export(
        &self,
        _: &mut dyn sq_export::core::traits::FrameSource,
        _: Option<&mut dyn sq_export::core::traits::AudioSource>,
        _: &sq_export::core::settings::ExportSettings,
        _: &std::path::Path,
        _: &sq_export::core::error::CancelToken,
        _: &mut dyn FnMut(f64),
    ) -> Result<Option<sq_export::core::loudness::LoudnessReport>, sq_export::core::error::ExportError> {
        Err(sq_export::core::error::ExportError::Other("not run in this test".into()))
    }
}

/// The whole app (`Headless` over the standard root with File > Export on, as `sequence-studio/src/main.rs` sets it up) at
/// `size`, with the bundled Inter so the text log measures real widths. Cmd+M and Cmd+, start async flows
/// (`AppEvent::Flow`) that only this loop runs; a bare `AppRoot` never opens a sheet.
fn app_window(size: (f32, f32), clock: &Arc<FakeClock>) -> sq_app_shell::Headless {
    let dir = crate::test_rig::test_dir("sq-heads-window");
    std::fs::create_dir_all(&dir).expect("dir");
    let mut deps = sq_app_shell::AppDeps::headless(Arc::clone(clock) as _);
    deps.atlas = GlyphAtlas::inter(&fonts_root());
    let session = super::dead_commands_tests::demo_session(super::dead_commands_tests::Scenario::Plain);
    let h = sq_app_shell::Headless::new(session, deps, size.0 as i64, size.1 as i64);
    let mut root = crate::standard_root(&dir, Arc::clone(clock) as _, DrawTheme::default()).expect("root");
    root.shell.enable_export(crate::export_host::ExportSetup {
        queue: Arc::new(sq_export::core::queue::ExportQueue::new(Arc::new(NoEncoder))),
        make_sources: Arc::new(|_, _, _| Err(sq_export::core::error::ExportError::Other("no renderer".into()))),
        frame_pixels: None,
        make_stem_audio: None,
        stem_encoder: None,
    });
    h.with(|a| {
        a.add_host(Box::new(root));
        a.launch();
    });
    h
}

/// Turns of the loop with the clock moving, so the flows run and the sheet's opening animation is over.
fn settle_window(h: &sq_app_shell::Headless, clock: &FakeClock) {
    for _ in 0..12 {
        clock.advance(std::time::Duration::from_millis(100));
        h.turn();
    }
}

/// The title of the dialog that is up (`ShellDialog::message_text`; the Export sheet and Settings are headerless cards that
/// keep their name there).
fn open_dialog(h: &sq_app_shell::Headless) -> Option<String> {
    use sq_draw_shell::ShellRoot;
    h.with(|a| a.shell_parts().shell.dialog().map(|d| d.message_text.clone())).flatten()
}

/// The text of one frame of the app window at `size`.
fn window_text(h: &sq_app_shell::Headless, size: (f32, f32)) -> Vec<TextRun> {
    text_log::start();
    h.with(|a| a.frame(size.0 as i64, size.1 as i64));
    let mut runs = text_log::finish();
    runs.dedup();
    runs
}

#[test]
fn the_export_sheet_and_settings_fit_at_the_smallest_window_on_every_system() {
    let mut failures = Vec::new();
    for platform in [Platform::Mac, Platform::Windows, Platform::Linux] {
        Platform::with_override(platform, || {
            for size in SIZES {
                // The dialog title and two texts only that sheet draws (Settings has its page title, not a "Settings" row).
                for (name, key, mods, marks) in [
                    ("Export", InputKey::Character('m'), InputModifiers::COMMAND, ["Export", "Preset"]),
                    ("Settings", InputKey::Character(','), InputModifiers::COMMAND, ["Search settings", "General"]),
                ] {
                    let clock = Arc::new(FakeClock::new());
                    let h = app_window(size, &clock);
                    settle_window(&h, &clock);
                    // `launch` arms the first-run Welcome Tour; a user closes it before anything else.
                    if open_dialog(&h).as_deref() == Some("Welcome to Sequence Studio") {
                        h.input(&InputEvent::KeyDown { key: InputKey::Escape, modifiers: InputModifiers::NONE });
                        settle_window(&h, &clock);
                    }
                    assert_eq!(
                        open_dialog(&h),
                        None,
                        "no dialog is up before {name} opens at {size:?} on {platform:?}"
                    );
                    let plain = window_text(&h, size);
                    h.input(&InputEvent::KeyDown { key, modifiers: mods });
                    settle_window(&h, &clock);
                    // Prove the right sheet is up first: a test that never opened it would pass without checking anything.
                    assert_eq!(
                        open_dialog(&h).as_deref(),
                        Some(name),
                        "the {name} sheet is open at {size:?} on {platform:?}"
                    );
                    let with = window_text(&h, size);
                    let added = dialog_runs(&with, &plain);
                    // The headless Windows rig has no Videos folder, so the sheet shows the temp dir as export folder; a runner's
                    // TMPDIR is longer than a card line and a path has no word break, so that one run is not a layout finding.
                    // (The sheet shows it home-relative, so match on its last folder name.)
                    let temp = std::env::temp_dir();
                    let leaf = temp.file_name().map_or_else(String::new, |n| n.to_string_lossy().into_owned());
                    let added: Vec<_> = added
                        .into_iter()
                        .filter(|r| leaf.is_empty() || !r.asked.ends_with(&format!("/{leaf}")))
                        .collect();
                    for mark in marks {
                        assert!(
                            added.iter().any(|r| r.asked == mark),
                            "the {name} sheet draws \"{mark}\" at {size:?} on {platform:?}: {:?}",
                            added.iter().map(|r| r.asked.as_str()).collect::<Vec<_>>()
                        );
                    }
                    // The card keeps its buttons on screen: a text under the window's edge is not counted by `problems`.
                    let buttons = h
                        .with(|a| {
                            use sq_draw_shell::ShellRoot;
                            a.shell_parts()
                                .shell
                                .dialog()
                                .map(|d| d.button_frames().values().copied().collect::<Vec<_>>())
                        })
                        .flatten()
                        .unwrap_or_default();
                    assert!(!buttons.is_empty(), "the {name} sheet has buttons at {size:?} on {platform:?}");
                    for b in buttons {
                        if b.x < -0.5
                            || b.y < -0.5
                            || b.x + b.width > f64::from(size.0) + 0.5
                            || b.y + b.height > f64::from(size.1) + 0.5
                        {
                            failures
                                .push(format!("{platform:?} {name} {size:?}: a button at {b:?} is outside the window"));
                        }
                    }
                    failures.extend(problems(
                        &format!("{platform:?} {name} {size:?}"),
                        &added,
                        (0.0, 0.0, size.0, size.1),
                    ));
                }
            }
        });
    }
    failures.sort();
    failures.dedup();
    assert!(failures.is_empty(), "{} sheet problems:\n{}", failures.len(), failures.join("\n"));
}

/// The Captions panel itself, at its own minimum width (240) and a little under it: the strip never cuts a title.
#[test]
fn the_captions_tab_strip_fits_at_and_under_the_panel_minimum() {
    use sq_inspector_ui::text::panel_draw::Tab;
    let mut failures = Vec::new();
    for width in [240.0, 220.0, 200.0] {
        for tab in Tab::ALL {
            let (mut r, mut rig) = full_root(WorkspacePage::Edit);
            let t = DrawTheme::default();
            let mut c = Canvas::with_size(400.0, 300.0, Some(atlas()), 1.0);
            let mut cx = HostCx {
                session: &mut rig.session,
                ui: &mut rig.ui,
                services: &mut rig.services,
                events: &mut rig.events,
                atlas: Some(atlas()),
                scale: 1.0,
            };
            let text = r.text.as_mut().expect("text host");
            text.panel().select(cx.session, tab);
            AppHost::layout(text, CGRect::new(0.0, 0.0, width, 300.0), &mut cx);
            text_log::start();
            AppHost::draw(text, &mut c, &t, &mut cx);
            let runs = text_log::finish();
            failures.extend(problems(&format!("{width} {tab:?}"), &runs, (0.0, 0.0, width as f32, 36.0)));
        }
    }
    failures.sort();
    failures.dedup();
    assert!(failures.is_empty(), "{} caption strip problems:\n{}", failures.len(), failures.join("\n"));
}
