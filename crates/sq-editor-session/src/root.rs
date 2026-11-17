//! The root seam of the session's async flows (docs/rust/session-ui-design.md section 2).
//!
//! A Swift `async` session method that awaits (a dialog, a worker) becomes
//! `async fn f<R: SessionRoot + ?Sized>(h: UiRef<R>, ..)`. Each synchronous stretch runs in
//! `h.with(|r| { let s = r.session(); .. })`; nothing is borrowed across an `.await`; `None` from `with` means the
//! root is gone (Swift's `[weak self]` was nil) and the flow ends. Questions to the user are methods of a small
//! per-group trait in the group's own module (for example `FormatAsks` in ES1) that the app implements next to this
//! one; the flow bounds its root by both (`R: SessionRoot + FormatAsks + ?Sized`).

use crate::EditorSession;

/// What every async session flow needs from the app root: the session.
pub trait SessionRoot {
    fn session(&mut self) -> &mut EditorSession;
}
