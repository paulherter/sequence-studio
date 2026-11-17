//! The marker for session members that have their Rust signature but not their body yet.
//!
//! `pending!("ES4")` panics with "not implemented" naming the owner group and the module. It is the only place in the
//! crate where an `unimplemented!`-style panic is allowed (the workspace denies `todo!` and `unimplemented!`), so
//! every unfinished member is findable and countable: `scripts/session-tasks.py --stats` counts the markers per group.
//! The owner must be one of `ES1`..`ES10` (checked at compile time). A group is done when none of its markers is left.

/// Owner groups a [`pending!`] marker may name (docs/rust/session-ui-design.md section 4).
pub const OWNERS: [&str; 10] = ["ES1", "ES2", "ES3", "ES4", "ES5", "ES6", "ES7", "ES8", "ES9", "ES10"];

/// Whether `owner` is one of [`OWNERS`] (const, for the compile-time check in [`pending!`]).
pub const fn is_owner(owner: &str) -> bool {
    let mut i = 0;
    while i < OWNERS.len() {
        if eq(OWNERS[i].as_bytes(), owner.as_bytes()) {
            return true;
        }
        i += 1;
    }
    false
}

const fn eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// The panic behind [`pending!`]; call the macro, not this.
#[cold]
#[track_caller]
#[allow(clippy::unimplemented)] // the one sanctioned exception, see the module docs
pub fn fail(owner: &str, module: &str) -> ! {
    unimplemented!("{owner}: {module}")
}

/// Marks a member whose body the named ES group still has to port: `pending!("ES4")`. Evaluates to `!`.
#[macro_export]
macro_rules! pending {
    ($owner:literal) => {{
        const _: () = assert!($crate::pending::is_owner($owner), "pending! owner must be ES1..ES10");
        $crate::pending::fail($owner, module_path!())
    }};
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn owners_are_the_ten_groups() {
        assert!(is_owner("ES1") && is_owner("ES10"));
        assert!(!is_owner("ES11") && !is_owner("K2") && !is_owner("es1"));
    }

    #[test]
    #[should_panic(expected = "not implemented: ES4: sq_editor_session::pending::tests")]
    fn pending_panics_with_owner_and_module() {
        fn stub() -> bool {
            pending!("ES4")
        }
        stub();
    }
}
