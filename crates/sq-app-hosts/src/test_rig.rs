//! What a host borrows for one call, owned by a test.

use sq_app_shell::{AppEvent, AppServices, HostCx};
use sq_draw::UiCx;
use sq_editor_session::EditorSession;

/// Owns the parts of a [`HostCx`] without a glyph atlas.
pub(crate) struct Rig {
    pub session: EditorSession,
    pub ui: UiCx,
    pub services: AppServices,
    pub events: Vec<AppEvent>,
    /// Device pixels per point (events arrive in pixels, frames are in points).
    pub scale: f32,
}

impl Rig {
    pub(crate) fn new(session: EditorSession) -> Rig {
        Rig { session, ui: UiCx::new(), services: AppServices::headless(), events: Vec::new(), scale: 1.0 }
    }

    /// The same rig on a display of `scale` pixels per point.
    pub(crate) fn at_scale(mut self, scale: f32) -> Rig {
        self.scale = scale;
        self
    }

    pub(crate) fn cx(&mut self) -> HostCx<'_> {
        HostCx {
            session: &mut self.session,
            ui: &mut self.ui,
            services: &mut self.services,
            events: &mut self.events,
            atlas: None,
            scale: self.scale,
        }
    }
}

/// A fresh, unique folder name under the temp dir for one test: process id, a counter and the clock, so a reused pid or
/// a leftover of an earlier run (Windows keeps them) never hands a test old presets or prefs. Not created; tests that need
/// it create it. Tests never use the user's real support, caches or presets folders.
pub(crate) fn unique_dir(tag: &str) -> std::path::PathBuf {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_nanos());
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    std::env::temp_dir().join(format!("{tag}-{}-{nanos}-{n}", std::process::id()))
}

/// Guard: no test file of this crate may resolve the user's real support, caches or presets folders; they build their
/// folders with [`unique_dir`] (or inject a folder, as `mark_welcome_seen(support)` does).
#[test]
fn no_test_code_resolves_the_real_user_folders() {
    fn walk(dir: &std::path::Path, hits: &mut Vec<String>) {
        let Ok(entries) = std::fs::read_dir(dir) else { return };
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(&p, hits);
            } else if p
                .file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n == "tests.rs" || n.ends_with("_tests.rs"))
            {
                let text = std::fs::read_to_string(&p).unwrap_or_default();
                for needle in [
                    "app_support_dir",
                    "Application Support",
                    "\"APPDATA\"",
                    "\"LOCALAPPDATA\"",
                    "home_dir",
                    "default_folder(",
                ] {
                    if text.contains(needle) {
                        hits.push(format!("{}: {needle}", p.display()));
                    }
                }
            }
        }
    }
    let mut hits = Vec::new();
    walk(&std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src"), &mut hits);
    assert!(hits.is_empty(), "tests must not touch the real user folders: {hits:?}");
}
