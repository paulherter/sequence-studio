// SPDX-License-Identifier: GPL-3.0-or-later
//! `cargo xtask <check|gate|hook|driver>`: repo automation without shell scripts (macOS and Windows alike).

mod channel;
mod driver;
mod hooks;
mod json;
mod notices;
mod onnxruntime;
mod package;
mod package_linux;
mod shaders;
mod stage;

use std::path::Path;
use std::process::{Command, ExitCode};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let rest = |n: usize| args.get(n..).unwrap_or(&[]);
    let result = match args.first().map(String::as_str) {
        Some("check") => check(args.get(1).map(String::as_str)),
        Some("gate") => match args.get(1) {
            Some(c) => gate(c),
            None => Err("usage: cargo xtask gate <crate>".into()),
        },
        Some("hook") => match args.get(1) {
            Some(name) => return ExitCode::from(u8::try_from(hooks::run(name)).unwrap_or(1)),
            None => Err("usage: cargo xtask hook <pre-bash|pre-read|pre-write|post-edit|stop>".into()),
        },
        Some("driver") => driver::run(rest(1)),
        Some("shaders") => shaders::run(rest(1)),
        Some("notices") => notices::run(rest(1)),
        Some("package") => package::run_package(rest(1)),
        _ => {
            Err("usage: cargo xtask <check [crate] | gate <crate> | hook <name> | driver <cmd> | shaders [--spirv] | notices [--check] | package [--sign] [--notarize] [--dmg]>"
                .into())
        }
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("xtask: {e}");
            ExitCode::FAILURE
        }
    }
}

/// A command for `cargo`, niced when `SQ_NICE` is set (unix only), so a busy machine stays usable.
fn cargo(args: &[&str]) -> Command {
    let nice = std::env::var("SQ_NICE").ok().filter(|_| cfg!(unix));
    let mut c = match nice {
        Some(n) => {
            let mut c = Command::new("nice");
            c.args(["-n", &n, "cargo"]);
            c
        }
        None => Command::new("cargo"),
    };
    c.args(args);
    c
}

fn step(label: &str, mut cmd: Command) -> Result<(), String> {
    println!("== {label}");
    match cmd.status() {
        Ok(s) if s.success() => Ok(()),
        Ok(s) => Err(format!("{label} failed ({s})")),
        Err(e) => Err(format!("{label}: cannot start: {e}")),
    }
}

fn has(args: &[&str]) -> bool {
    Command::new("cargo").args(args).output().map(|o| o.status.success()).unwrap_or(false)
}

fn scope(krate: Option<&str>) -> Vec<String> {
    match krate {
        Some(c) => vec!["-p".into(), c.into()],
        None => vec!["--workspace".into()],
    }
}

/// fmt --check, clippy -D warnings, nextest (or cargo test when nextest is missing).
fn check(krate: Option<&str>) -> Result<(), String> {
    let sc = scope(krate);
    let with = |base: &[&str], tail: &[&str]| -> Vec<String> {
        base.iter().map(|s| s.to_string()).chain(sc.iter().cloned()).chain(tail.iter().map(|s| s.to_string())).collect()
    };
    let run = |label: &str, argv: Vec<String>| step(label, cargo(&argv.iter().map(String::as_str).collect::<Vec<_>>()));
    let fmt: Vec<String> = match krate {
        Some(c) => vec!["fmt".into(), "-p".into(), c.into(), "--".into(), "--check".into()],
        None => vec!["fmt".into(), "--all".into(), "--".into(), "--check".into()],
    };
    run("fmt", fmt)?;
    // The workspace-hack crate must match the dependency graph (fix: `cargo hakari generate && cargo hakari manage-deps`).
    if krate.is_none() && has(&["hakari", "--version"]) {
        step("hakari verify", cargo(&["hakari", "verify"]))?;
    }
    // The notices file must match Cargo.lock (fix: `cargo xtask notices`).
    if krate.is_none() {
        notices::run(&["--check".to_string()])?;
        println!("== notices ok");
    }
    run("clippy", with(&["clippy", "--all-targets"], &["--", "-D", "warnings"]))?;
    if has(&["nextest", "--version"]) {
        run("nextest", with(&["nextest", "run"], &[]))?;
    } else {
        run("test (nextest not installed)", with(&["test"], &[]))?;
    }
    println!("check ok");
    Ok(())
}

/// Crates that may contain `unsafe` (each block needs a `// SAFETY:` comment).
fn unsafe_allowed(krate: &str) -> bool {
    matches!(krate, "sq-gpu" | "sq-gpu-interop" | "sq-video-hw") || krate.starts_with("sq-platform-")
}

/// Counts `unsafe` blocks, fns, impls and traits in the code lines of every .rs file below `dir`.
pub fn count_unsafe(dir: &Path) -> usize {
    let Ok(entries) = std::fs::read_dir(dir) else { return 0 };
    entries
        .flatten()
        .map(|e| {
            let p = e.path();
            if p.is_dir() {
                count_unsafe(&p)
            } else if p.extension().is_some_and(|x| x == "rs") {
                std::fs::read_to_string(&p).map(|t| count_unsafe_text(&t)).unwrap_or(0)
            } else {
                0
            }
        })
        .sum()
}

pub fn count_unsafe_text(text: &str) -> usize {
    text.lines()
        .map(str::trim_start)
        .filter(|l| !l.starts_with("//"))
        .map(|l| {
            ["unsafe {", "unsafe fn", "unsafe impl", "unsafe trait", "unsafe extern"]
                .iter()
                .map(|k| l.matches(k).count())
                .sum::<usize>()
        })
        .sum()
}

fn gate(krate: &str) -> Result<(), String> {
    check(Some(krate))?;
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).ancestors().nth(2).unwrap_or(Path::new("."));
    let n = count_unsafe(&root.join("crates").join(krate).join("src"));
    println!("== unsafe: {n} in {krate}{}", if unsafe_allowed(krate) { " (allow-listed crate)" } else { "" });
    if n > 0 && !unsafe_allowed(krate) {
        return Err(format!("{krate} has {n} unsafe uses and is not on the allow-list"));
    }
    if has(&["deny", "--version"]) {
        step("deny", cargo(&["deny", "check", "licenses", "bans", "sources"]))?;
    } else {
        println!("== deny: cargo-deny not installed, skipped");
    }
    let (run, how) = if cfg!(windows) { ("run.ps1", Some("powershell")) } else { ("run", None) };
    let oracle = root.join("oracle").join(krate).join(run);
    if oracle.exists() {
        let mut c = match how {
            Some(sh) => {
                let mut c = Command::new(sh);
                c.args(["-NoProfile", "-File"]).arg(&oracle);
                c
            }
            None => Command::new(&oracle),
        };
        c.current_dir(root);
        step("oracle parity", c)?;
    } else {
        println!("== oracle: no oracle/{krate}/{run}, skipped");
    }
    println!("gate ok: {krate}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsafe_counter_ignores_comments() {
        assert_eq!(count_unsafe_text("// unsafe { x }\nfn a() { unsafe { b() } }\nunsafe fn c() {}\n"), 2);
        assert_eq!(count_unsafe_text("let s = 1;"), 0);
    }

    #[test]
    fn allow_list() {
        assert!(unsafe_allowed("sq-platform-win"));
        assert!(unsafe_allowed("sq-video-hw"));
        assert!(!unsafe_allowed("sq-core"));
    }
}
