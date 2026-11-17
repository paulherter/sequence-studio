//! A setup session as the whole program: one winit event loop around one [`SetupSession`]. The Windows installer runs it;
//! the Linux first run does not (the app has its own loop and embeds the session).

use crate::machine::{Exit, Machine};
use crate::session::{Services, SetupSession};
use crate::view::{Chrome, ErrorContext};
use sq_draw::GlyphAtlas;
use winit::application::ApplicationHandler;
use winit::event::WindowEvent;
use winit::event_loop::{ActiveEventLoop, ControlFlow, EventLoop};
use winit::window::WindowId;

struct Handler {
    title: String,
    chrome: Chrome,
    context: ErrorContext,
    start: Option<(GlyphAtlas, Machine, Box<dyn Services>)>,
    session: Option<SetupSession>,
    exit: Option<Exit>,
    failed: Option<String>,
}

impl ApplicationHandler for Handler {
    fn resumed(&mut self, el: &ActiveEventLoop) {
        let Some((atlas, machine, services)) = self.start.take() else { return };
        match SetupSession::open(el, &self.title, self.chrome, self.context.clone(), atlas, machine, services) {
            Ok(session) => self.session = Some(session),
            Err(why) => {
                self.failed = Some(why);
                el.exit();
            }
        }
    }

    fn window_event(&mut self, el: &ActiveEventLoop, id: WindowId, event: WindowEvent) {
        if let Some(session) = self.session.as_mut().filter(|s| s.id() == id)
            && let Some(exit) = session.window_event(event)
        {
            self.exit = Some(exit);
            el.exit();
        }
    }

    fn about_to_wait(&mut self, el: &ActiveEventLoop) {
        let Some(session) = self.session.as_mut() else { return };
        match session.about_to_wait() {
            (Some(exit), _) => {
                self.exit = Some(exit);
                el.exit();
            }
            (None, Some(wake)) => el.set_control_flow(ControlFlow::WaitUntil(wake)),
            (None, None) => el.set_control_flow(ControlFlow::Wait),
        }
    }
}

/// Opens the window, runs until the setup is over and says how it ended. `Err` when no window could open.
pub fn run(
    title: &str,
    chrome: Chrome,
    context: ErrorContext,
    atlas: GlyphAtlas,
    machine: Machine,
    services: Box<dyn Services>,
) -> Result<Exit, String> {
    let el = EventLoop::new().map_err(|e| format!("event loop: {e}"))?;
    let mut handler = Handler {
        title: title.to_string(),
        chrome,
        context,
        start: Some((atlas, machine, services)),
        session: None,
        exit: None,
        failed: None,
    };
    el.run_app(&mut handler).map_err(|e| format!("event loop: {e}"))?;
    match handler.failed {
        Some(why) => Err(why),
        None => Ok(handler.exit.unwrap_or(Exit::Closed)),
    }
}
