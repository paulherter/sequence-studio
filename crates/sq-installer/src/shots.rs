//! Offscreen pictures of every screen, rendered by the same CPU path as the window: `sq-installer --shot <screen>`.
//! They are what the design renders in `design/installer/` are compared with, and what the checks look at when no window
//! may open. A picture is the window plus a ground around it, as the design renders are.

use crate::machine::{Check, Event, Facts, InstallerScreen, LocationCheck, Machine, Measure, UpdateKind};
use crate::session::{render, theme};
use crate::view::{Chrome, ErrorContext, SetupView, WINDOW_H, WINDOW_W};
use sq_draw::{GlyphAtlas, RgbaImage};
use sq_setup_engine::{ErrorCode, Job, SetupError, SpaceFacts, Step, Version};
use sq_uikit::redesign_tokens as rt;
use std::path::PathBuf;

/// The ground around the window in the design renders (points).
const GROUND: f64 = 24.0;

/// Every screen name `--shot` knows, in the order of the design folder.
pub const SCREENS: [&str; 16] = [
    "win-1-welcome",
    "win-1-welcome-nospace",
    "win-1-welcome-denied",
    "win-1-welcome-nested",
    "win-2-progress",
    "win-3-done",
    "win-4-update",
    "win-4-update-same",
    "win-4-update-newer",
    "win-5-uninstall",
    "win-6-uninstalled",
    "win-7-error",
    "win-7-error-damaged",
    "win-7-error-app",
    "linux-1-welcome",
    "linux-2-done",
];

fn facts(linux: bool) -> Facts {
    Facts {
        version: Version::new(0, 2, 0),
        app_exe_name: "SequenceStudio.exe",
        start_folder: PathBuf::from("C:\\Users\\Anna"),
        payload_bytes: 412 << 20,
        appimage_dir: linux.then(|| PathBuf::from("/home/paul/Downloads")),
        home: linux.then(|| PathBuf::from("/home/paul")),
        system_line: "Sequence Studio Setup 0.2.0 (x64) on Windows 11 26100".into(),
        data_shared_with: None,
    }
}

const WIN_PATH: &str = "C:\\Users\\Anna\\AppData\\Local\\Programs\\Sequence Studio";

fn welcome(check: LocationCheck) -> Machine {
    Machine::new(Machine::welcome(Job::Install, PathBuf::from(WIN_PATH), check), facts(false))
}

/// The machine of one named screen with the example values of the spec (0.2.0 new, 0.1.2 installed, 412 MB).
pub fn machine(name: &str) -> Option<Machine> {
    let ok = LocationCheck::Ok { free: 50 << 30 };
    let old = Version::new(0, 1, 2);
    let update = |installed: Version, kind| {
        let screen = InstallerScreen::Update {
            job: Job::Update { from: installed.clone() },
            installed,
            location: PathBuf::from(WIN_PATH),
            app_running: kind == UpdateKind::Newer,
            kind,
        };
        Machine::new(screen, facts(false))
    };
    let after_install = |job: Job, desktop: bool| {
        let mut m = welcome(ok);
        if desktop {
            m.handle(Event::Toggle(Check::DesktopShortcut), 0.0);
        }
        m.handle(Event::Enter, 0.0);
        m.handle(Event::JobEnded(Ok(true)), 1.0);
        m.handle(Event::Tick, 2.0);
        m.screen = InstallerScreen::Done { job, opening: false };
        m
    };
    Some(match name {
        "win-1-welcome" => welcome(ok),
        "win-1-welcome-nospace" => welcome(LocationCheck::NoSpace { need: 412 << 20, free: 120 << 20 }),
        "win-1-welcome-denied" => welcome(LocationCheck::NotWritable),
        "win-1-welcome-nested" => {
            let mut m = welcome(ok);
            m.handle(Event::LocationPicked(PathBuf::from("D:\\Apps")), 0.0);
            m.handle(
                Event::LocationChecked { location: PathBuf::from("D:\\Apps").join("Sequence Studio"), check: ok },
                0.1,
            );
            m
        }
        "win-2-progress" => {
            let mut m = welcome(ok);
            m.handle(Event::Enter, 0.0);
            m.handle(Event::JobProgress { step: Step::Copying, value: 0.48, detail: String::new() }, 0.1);
            m
        }
        "win-3-done" => after_install(Job::Install, false),
        "win-4-update" => update(old, UpdateKind::Newer),
        "win-4-update-same" => update(Version::new(0, 2, 0), UpdateKind::Same),
        "win-4-update-newer" => update(Version::new(0, 3, 0), UpdateKind::Older),
        "win-5-uninstall" => Machine::new(
            InstallerScreen::UninstallConfirm {
                job: Job::Uninstall,
                location: PathBuf::from(WIN_PATH),
                delete_data: false,
                data_size: Measure::Bytes(2254857830),
            },
            facts(false),
        ),
        "win-6-uninstalled" => {
            Machine::new(InstallerScreen::Uninstalled { job: Job::Uninstall, deleted_data: false }, facts(false))
        }
        "win-7-error" | "win-7-error-damaged" => {
            let mut m = welcome(ok);
            m.handle(Event::Enter, 0.0);
            m.handle(
                Event::LogAt(PathBuf::from(
                    "C:\\Users\\Anna\\AppData\\Local\\Temp\\Sequence Studio Setup 20261116-145200.log",
                )),
                0.0,
            );
            let error = if name == "win-7-error" {
                SetupError::new(
                    ErrorCode::NoSpace,
                    "Copying files (198 of 412 MB)",
                    "os error 112 \u{b7} There is not enough space on the disk.",
                )
                .with_path(&PathBuf::from(WIN_PATH).join("sq_media.dll"))
                .with_space(SpaceFacts { drive: "C:".into(), free: 120 << 20, need: 412 << 20 })
            } else {
                SetupError::new(ErrorCode::PayloadDamaged, "Checking the package", "sha256 mismatch")
            };
            m.handle(Event::JobEnded(Err(error)), 1.0);
            m
        }
        "win-7-error-app" => {
            let mut m = welcome(ok);
            m.handle(Event::Enter, 0.0);
            m.handle(
                Event::LogAt(PathBuf::from(
                    "C:\\Users\\Anna\\AppData\\Local\\Temp\\Sequence Studio Setup 20261116-145200.log",
                )),
                0.0,
            );
            m.handle(Event::JobEnded(Ok(true)), 0.5);
            m.handle(Event::Tick, 2.0);
            m.handle(Event::Enter, 3.0);
            m.handle(Event::AppNotStarted("os error 193 \u{b7} %1 is not a valid Win32 application.".into()), 3.1);
            m
        }
        "linux-1-welcome" => {
            Machine::new(Machine::welcome(Job::LinuxAdd, PathBuf::from("/home/paul/Applications"), ok), facts(true))
        }
        "linux-2-done" => {
            let mut m = Machine::new(
                Machine::welcome(Job::LinuxAdd, PathBuf::from("/home/paul/Applications"), ok),
                facts(true),
            );
            m.handle(Event::Enter, 0.0);
            m.handle(Event::JobEnded(Ok(true)), 0.1);
            m.request = m.request.take().map(|mut r| {
                r.location = PathBuf::from("/home/paul/Applications/SequenceStudio.AppImage");
                r
            });
            m
        }
        _ => return None,
    })
}

/// The window of `machine` plus the ground, as an image `scale` device pixels per point. The view is drawn twice, so the
/// fade of a screen's first appearance and Pip's delay are over (`at` seconds after the first draw).
pub fn picture(machine: &Machine, atlas: &GlyphAtlas, light: bool, scale: f32, at: f64) -> RgbaImage {
    let chrome = if machine.facts.home.is_some() { Chrome::System } else { Chrome::OwnClose };
    let context = ErrorContext { homes: vec!["C:\\Users\\Anna".into()], token: "%USERPROFILE%".into() };
    let mut view = SetupView::new(chrome, context);
    let px = |points: f64| (points * f64::from(scale)).round() as usize;
    let size = (px(WINDOW_W), px(WINDOW_H));
    atlas.set_point_scale(scale);
    let mut machine = machine.clone();
    machine.handle(Event::Tick, 0.0);
    let _ = render(&mut view, &machine, Some(atlas), light, size, scale, 0.0);
    let window = render(&mut view, &machine, Some(atlas), light, size, scale, at);
    let t = theme(light, scale);
    let ground = t.token(rt::color::SEAM);
    let pad = px(GROUND);
    let (w, h) = (size.0 + 2 * pad, size.1 + 2 * pad);
    let mut out = RgbaImage { width: w, height: h, pixels: vec![0; w * h * 4] };
    let bytes =
        |c: sq_draw::Color| [(c.r * 255.0).round() as u8, (c.g * 255.0).round() as u8, (c.b * 255.0).round() as u8];
    let g = bytes(ground);
    let (cells, _) = out.pixels.as_chunks_mut::<4>();
    for p in cells {
        p[..3].copy_from_slice(&g);
        p[3] = 255;
    }
    let radius = f64::from(rt::radius::WINDOW) * f64::from(scale);
    for y in 0..size.1 {
        for x in 0..size.0 {
            let coverage = corner_coverage(x as f64 + 0.5, y as f64 + 0.5, size.0 as f64, size.1 as f64, radius);
            let src = &window.pixels[(y * size.0 + x) * 4..][..3];
            let dst = &mut out.pixels[((y + pad) * w + x + pad) * 4..][..3];
            for i in 0..3 {
                dst[i] = (f64::from(src[i]) * coverage + f64::from(dst[i]) * (1.0 - coverage)).round() as u8;
            }
        }
    }
    out
}

/// How much of the pixel centered at (x, y) lies inside a `w` x `h` rectangle with corners of `radius`.
fn corner_coverage(x: f64, y: f64, w: f64, h: f64, radius: f64) -> f64 {
    let dx = (radius - x).max(x - (w - radius)).max(0.0);
    let dy = (radius - y).max(y - (h - radius)).max(0.0);
    (radius + 0.5 - dx.hypot(dy)).clamp(0.0, 1.0)
}

/// Writes `image` as a PNG.
pub fn write_png(image: &RgbaImage, path: &std::path::Path) -> Result<(), String> {
    let file = std::fs::File::create(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut encoder = png::Encoder::new(std::io::BufWriter::new(file), image.width as u32, image.height as u32);
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
    writer.write_image_data(&image.pixels).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_named_screen_has_a_machine() {
        for name in SCREENS {
            assert!(machine(name).is_some(), "{name}");
        }
        assert!(machine("nope").is_none());
    }

    #[test]
    fn the_corners_are_cut_and_the_middle_is_whole() {
        assert_eq!(corner_coverage(0.5, 0.5, 100.0, 50.0, 10.0), 0.0);
        assert_eq!(corner_coverage(50.0, 25.0, 100.0, 50.0, 10.0), 1.0);
        assert_eq!(corner_coverage(50.0, 0.5, 100.0, 50.0, 10.0), 1.0, "the straight edge is not cut");
    }

    #[test]
    fn the_error_shot_is_the_error_screen_with_the_scrubbed_user_folder() {
        let m = machine("win-7-error").map(|m| m.screen);
        let Some(InstallerScreen::Error { error, .. }) = m else { panic!("not an error screen") };
        assert_eq!(error.code, ErrorCode::NoSpace);
    }

    #[test]
    fn the_failed_start_shot_is_the_error_card_with_its_own_title() {
        let m = machine("win-7-error-app").map(|m| m.screen);
        let Some(InstallerScreen::Error { job, error, log }) = m else { panic!("not an error screen") };
        assert_eq!(error.code, ErrorCode::AppNotStarted);
        assert_eq!(error.title(&job), "Sequence Studio could not start");
        assert!(log.is_some(), "Open log has a log to open");
    }
}
