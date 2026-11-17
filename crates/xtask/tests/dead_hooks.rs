//! The dead-hooks check (`scripts/check-dead-hooks.py`) as a test, so the use pass and the gate run it with the others.

use std::process::Command;

#[test]
fn no_trait_hook_is_dead() {
    let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    // A machine without python3 (a bare Windows PC) skips it; the Linux and Mac runs carry the check.
    let Ok(out) = Command::new("python3").args(["-I", "scripts/check-dead-hooks.py"]).current_dir(&root).output()
    else {
        return;
    };
    assert!(out.status.success(), "{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
}
