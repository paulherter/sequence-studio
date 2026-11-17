//! The Linux first run: before the Start window opens, an AppImage that is not in the app menu asks to be added (and moves
//! itself to `~/Applications`), and one that finds an older integrated copy asks to update it. The window is the setup
//! program's (`sq_installer`), opened in this same event loop; its answer comes back as an [`Exit`].

use crate::applog;
use sq_app_hosts::desktop_entry;
use sq_draw::GlyphAtlas;
use sq_installer::linux::{LinuxServices, error_context, first_run};
use sq_installer::machine::Exit;
use sq_installer::session::SetupSession;
use sq_installer::view::Chrome;
use sq_platform::desktop_integration::{self as di, DesktopEnv};
use std::path::Path;
use std::time::Instant;
use winit::event::WindowEvent;
use winit::event_loop::ActiveEventLoop;
use winit::window::WindowId;

/// The open question and the AppImage it is about.
pub struct FirstRun {
    session: SetupSession,
    env: DesktopEnv,
}

impl FirstRun {
    /// Opens the window when there is something to ask; `None` when the app should just start (not an AppImage, already
    /// answered, a headless run, or the window could not open).
    pub fn open(el: &ActiveEventLoop, fonts: &Path) -> Option<FirstRun> {
        let env = DesktopEnv::current()?;
        let state = desktop_entry::startup_state(Some(&env));
        let machine = first_run(&env, &state, desktop_entry::offers_allowed())?;
        let atlas = GlyphAtlas::inter(fonts)?;
        let services = Box::new(LinuxServices::new(env.clone()));
        match SetupSession::open(el, "Sequence Studio", Chrome::System, error_context(&env), atlas, machine, services) {
            Ok(session) => Some(FirstRun { session, env }),
            Err(why) => {
                applog::error(&format!("first run: the window could not open: {why}"));
                None
            }
        }
    }

    pub fn id(&self) -> WindowId {
        self.session.id()
    }

    pub fn event(&mut self, event: WindowEvent) -> Option<Exit> {
        self.session.window_event(event)
    }

    /// Between events: the job's messages and the next frame.
    pub fn wait(&mut self) -> (Option<Exit>, Option<Instant>) {
        self.session.about_to_wait()
    }

    /// The user answered: `Not Now`, Esc and the close button are remembered, so the question never comes again.
    pub fn finish(self, exit: Exit) {
        if exit == Exit::Declined
            && let Err(failure) = di::decline(&self.env)
        {
            applog::error(&format!("first run: the answer could not be remembered: {failure}"));
        }
    }
}
