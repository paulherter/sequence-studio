//! Panics a worker catches on purpose (export queue, playback lanes, proxy and analysis threads). The app's panic hook asks
//! [`is_caught`] so a panic that is handled does not leave a crash report ("quit unexpectedly" on the next launch).

use std::cell::Cell;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::thread::Result;

thread_local! {
    static DEPTH: Cell<u32> = const { Cell::new(0) };
}

struct Depth;

impl Depth {
    fn enter() -> Depth {
        DEPTH.with(|d| d.set(d.get() + 1));
        Depth
    }
}

impl Drop for Depth {
    fn drop(&mut self) {
        DEPTH.with(|d| d.set(d.get().saturating_sub(1)));
    }
}

/// Runs `f`, catching a panic and marking it as handled for the panic hook while it unwinds.
pub fn catching<R>(f: impl FnOnce() -> R) -> Result<R> {
    let _depth = Depth::enter();
    catch_unwind(AssertUnwindSafe(f))
}

/// True while the current thread runs inside [`catching`]: a panic now is caught by its owner.
pub fn is_caught() -> bool {
    DEPTH.with(|d| d.get() > 0)
}

/// The text of a panic payload.
pub fn message(payload: &(dyn std::any::Any + Send)) -> String {
    payload
        .downcast_ref::<&str>()
        .map(|s| (*s).to_string())
        .or_else(|| payload.downcast_ref::<String>().cloned())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_panic_inside_catching_is_marked_handled_and_the_mark_ends_with_it() {
        assert!(!is_caught());
        let seen = std::cell::Cell::new(false);
        let r = catching(|| {
            seen.set(is_caught());
            panic!("boom");
        });
        assert!(seen.get() && r.as_ref().is_err_and(|p| message(p.as_ref()) == "boom"));
        assert!(!is_caught(), "a later panic is a real crash again");
        assert_eq!(catching(|| 3).ok(), Some(3));
    }
}
