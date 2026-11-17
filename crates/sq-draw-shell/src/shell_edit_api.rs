// Swift: ShellEditAPI.swift
//! The host's local Edit API (the Mac `EditAPIController`) as Preferences > Advanced shows it: the switch, the run state
//! and the address to copy. The host sets [`crate::ShellHost::flow_env`]`.edit_api`; without one the Advanced page is left
//! out.

use crate::shell_form::StatusTone;

/// `EditAPIRunState.text` / `tone` / `copyablePort`.
#[derive(Clone, Debug, PartialEq)]
pub struct EditApiState {
    /// The run state line.
    pub text: String,
    /// Its dot color.
    pub tone: StatusTone,
    /// The port the "Copy address" button copies, while the server runs.
    pub copyable_port: Option<i64>,
}

impl EditApiState {
    /// A state without a copyable port.
    pub fn new(text: &str, tone: StatusTone) -> EditApiState {
        EditApiState { text: text.to_string(), tone, copyable_port: None }
    }
}

/// The Edit API as the Advanced page sees it.
pub struct ShellEditApi {
    /// Whether the switch is on.
    pub is_enabled: Box<dyn Fn() -> bool>,
    /// Stores the switch and starts or stops the server (`EditAPIController.isEnabled` + `sync()`).
    pub set_enabled: Box<dyn Fn(bool)>,
    /// The run state.
    pub state: Box<dyn Fn() -> EditApiState>,
}

impl ShellEditApi {
    /// An Edit API from the three closures the app provides.
    pub fn new(
        is_enabled: impl Fn() -> bool + 'static,
        set_enabled: impl Fn(bool) + 'static,
        state: impl Fn() -> EditApiState + 'static,
    ) -> ShellEditApi {
        ShellEditApi { is_enabled: Box::new(is_enabled), set_enabled: Box::new(set_enabled), state: Box::new(state) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::Cell;
    use std::rc::Rc;

    #[test]
    fn the_closures_reach_the_app() {
        let on = Rc::new(Cell::new(false));
        let (a, b) = (Rc::clone(&on), Rc::clone(&on));
        let api = ShellEditApi::new(
            move || a.get(),
            move |v| b.set(v),
            || EditApiState { copyable_port: Some(8123), ..EditApiState::new("Running", StatusTone::Ok) },
        );
        (api.set_enabled)(true);
        assert!((api.is_enabled)());
        assert_eq!((api.state)().copyable_port, Some(8123));
    }
}
