// SPDX-License-Identifier: GPL-3.0-or-later
//! Coding-agent hooks as Rust, so they behave the same on macOS and Windows.
//! Contract: stdin = hook JSON, exit 0 = allow, exit 2 = block (reason on stderr).
//! Known limit: the shell guard sees quoted `-c` strings and wrappers (nice, env, sudo) but not scripts the agent writes
//! and then runs; the worktree + branch isolation is the second line of defense.

use crate::json::Json;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;

pub fn run(name: &str) -> i32 {
    let mut text = String::new();
    if std::io::stdin().read_to_string(&mut text).is_err() {
        return 0;
    }
    let Ok(input) = Json::parse(&text) else {
        eprintln!("hook {name}: input is not JSON, allowing");
        return 0;
    };
    let cwd = input.get("cwd").and_then(Json::as_str).map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    let field = |k: &str| input.at(&["tool_input", k]).and_then(Json::as_str).map(str::to_string);
    let verdict = match name {
        "pre-bash" => field("command").and_then(|c| pre_bash(&c, in_worktree(&cwd))),
        "pre-read" => field("file_path").or_else(|| field("path")).and_then(|p| pre_read(&p)),
        "pre-write" => {
            let own = std::env::var("SQ_WORKER_OWN").ok();
            field("file_path").or_else(|| field("notebook_path")).and_then(|p| pre_write(&p, &cwd, own.as_deref()))
        }
        "post-edit" => return post_edit(field("file_path"), &cwd),
        "stop" => return stop(input.get("stop_hook_active").and_then(Json::as_bool).unwrap_or(false), &cwd),
        other => {
            eprintln!("unknown hook `{other}` (pre-bash|pre-read|pre-write|post-edit|stop)");
            return 1;
        }
    };
    match verdict {
        Some(reason) => {
            eprintln!("BLOCKED: {reason}");
            2
        }
        None => 0,
    }
}

/// True when `cwd` lies in a linked git worktree (`.git` is a file there), false in the main checkout or outside git.
pub fn in_worktree(cwd: &Path) -> bool {
    cwd.ancestors().find_map(|d| std::fs::metadata(d.join(".git")).ok()).is_some_and(|m| m.is_file())
}

/// Splits a shell command into simple commands (by `; & | newline`), honoring quotes.
fn segments(cmd: &str) -> Vec<Vec<String>> {
    let (mut out, mut cur, mut tok) = (Vec::new(), Vec::new(), String::new());
    let (mut quote, mut has_tok) = (None::<char>, false);
    let mut chars = cmd.chars().peekable();
    let flush = |tok: &mut String, has: &mut bool, cur: &mut Vec<String>| {
        if *has {
            cur.push(std::mem::take(tok));
            *has = false;
        }
    };
    while let Some(c) = chars.next() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some('"'), '\\') => {
                if let Some(n) = chars.next() {
                    tok.push(n);
                }
            }
            (Some(_), c) => tok.push(c),
            (None, '\'' | '"') => {
                quote = Some(c);
                has_tok = true;
            }
            (None, '\\') => {
                if let Some(n) = chars.next() {
                    tok.push(n);
                    has_tok = true;
                }
            }
            (None, ';' | '&' | '|' | '\n' | '(' | ')') => {
                flush(&mut tok, &mut has_tok, &mut cur);
                if !cur.is_empty() {
                    out.push(std::mem::take(&mut cur));
                }
            }
            (None, c) if c.is_whitespace() => flush(&mut tok, &mut has_tok, &mut cur),
            (None, c) => {
                tok.push(c);
                has_tok = true;
            }
        }
    }
    flush(&mut tok, &mut has_tok, &mut cur);
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

fn base(tok: &str) -> &str {
    tok.rsplit(['/', '\\']).next().unwrap_or(tok)
}

/// Index of the real command: skips `VAR=x`, `nice -n 15`, `env`, `sudo`, `time`, ...
fn command_start(t: &[String]) -> usize {
    let mut i = 0;
    while i < t.len() {
        let b = base(&t[i]);
        let is_assign = b.contains('=') && !b.starts_with('=') && !b.starts_with('-');
        if is_assign {
            i += 1;
        } else if matches!(b, "nice" | "env" | "sudo" | "time" | "command" | "exec" | "nohup") {
            i += 1;
            while i < t.len()
                && (t[i].starts_with('-') || t[i].chars().all(|c| c.is_ascii_digit()) || t[i].contains('='))
            {
                i += 1;
            }
        } else {
            break;
        }
    }
    i
}

/// Reason to block a shell command, or None.
pub fn pre_bash(cmd: &str, in_worktree: bool) -> Option<String> {
    for seg in segments(cmd) {
        let s = command_start(&seg);
        let Some(prog) = seg.get(s) else { continue };
        let args = &seg[s + 1..];
        let found = match base(prog) {
            "git" => git_denied(args),
            "rm" => rm_denied(args),
            "cargo" if !in_worktree => {
                Some("cargo runs only inside a linked worktree, never in the main checkout".to_string())
            }
            "sh" | "bash" | "zsh" | "dash" => {
                args.iter().position(|a| a == "-c").and_then(|p| args.get(p + 1)).and_then(|c| pre_bash(c, in_worktree))
            }
            _ => None,
        };
        if found.is_some() {
            return found;
        }
    }
    None
}

fn git_denied(args: &[String]) -> Option<String> {
    let mut i = 0;
    while i < args.len() && args[i].starts_with('-') {
        let takes_value = matches!(args[i].as_str(), "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace");
        i += if takes_value { 2 } else { 1 };
    }
    let sub = args.get(i)?.as_str();
    let rest = &args[i + 1..];
    let bad = |why: &str| Some(format!("`git {sub}` is not allowed for agents ({why})"));
    match sub {
        "stash" | "reset" | "clean" | "rebase" => bad("it can destroy other workers' or uncommitted work"),
        "checkout" | "restore" if rest.iter().any(|a| a == ".") => bad("it discards all changes in the tree"),
        "push"
            if rest.iter().any(|a| {
                a.starts_with("--force") || (a.starts_with('-') && !a.starts_with("--") && a.contains('f'))
            }) =>
        {
            bad("no force push, the driver is the only one that publishes")
        }
        _ => None,
    }
}

fn rm_denied(args: &[String]) -> Option<String> {
    let short = |pred: fn(char) -> bool| {
        args.iter().any(|a| a.starts_with('-') && !a.starts_with("--") && a.chars().skip(1).any(pred))
    };
    let recursive = args.iter().any(|a| a == "--recursive") || short(|c| c == 'r' || c == 'R');
    let force = args.iter().any(|a| a == "--force") || short(|c| c == 'f');
    (recursive && force).then(|| "`rm -rf` is not allowed for agents; delete single files".to_string())
}

/// Reason to block reading `path`, or None. Covers the read-block list of the migration plan (section 3).
pub fn pre_read(path: &str) -> Option<String> {
    let norm = path.replace('\\', "/");
    let parts: Vec<&str> = norm.split('/').collect();
    let last = parts.last().copied().unwrap_or("");
    let is_header = [".h", ".hpp", ".hh"].iter().any(|e| last.ends_with(e));
    let hit = last == "ShaderSources.swift"
        || last == "rnn_data.c"
        || parts.iter().any(|p| p.contains("CThorVG") || *p == "Fixtures" || *p == "TestMedia")
        || (is_header && parts.iter().any(|p| p.to_ascii_lowercase().contains("onnxruntime")));
    hit.then(|| {
        format!(
            "{path} is on the read-block list (huge generated, vendored or media file); grep a narrow range elsewhere"
        )
    })
}

/// Lexical normalization: absolute, `.` and `..` resolved, separators unified.
fn normalize(path: &str, cwd: &Path) -> Vec<String> {
    let joined = path.replace('\\', "/");
    let full = if joined.starts_with('/') || Path::new(&joined).is_absolute() || joined.chars().nth(1) == Some(':') {
        joined
    } else {
        format!("{}/{}", cwd.to_string_lossy().replace('\\', "/"), joined)
    };
    let mut out: Vec<String> = Vec::new();
    for p in full.split('/') {
        match p {
            "" | "." => {}
            ".." => {
                out.pop();
            }
            p => out.push(if cfg!(windows) { p.to_lowercase() } else { p.to_string() }),
        }
    }
    out
}

/// Reason to block a write, or None. `own` is `SQ_WORKER_OWN`: path prefixes separated by `;`.
pub fn pre_write(path: &str, cwd: &Path, own: Option<&str>) -> Option<String> {
    let own = own.filter(|o| !o.trim().is_empty())?;
    let target = normalize(path, cwd);
    let allowed =
        own.split(';').filter(|p| !p.trim().is_empty()).any(|p| target.starts_with(&normalize(p.trim(), cwd)));
    (!allowed).then(|| format!("{path} is outside this worker's paths ({own})"))
}

/// Name of the package that owns `file`, found by walking up to the nearest manifest.
fn crate_of(file: &Path) -> Option<String> {
    file.ancestors().skip(1).find_map(|d| package_name(&std::fs::read_to_string(d.join("Cargo.toml")).ok()?))
}

/// `name = "..."` inside the `[package]` table.
pub fn package_name(manifest: &str) -> Option<String> {
    let mut in_pkg = false;
    for line in manifest.lines().map(str::trim) {
        if line.starts_with('[') {
            in_pkg = line == "[package]";
        } else if in_pkg && let Some(v) = line.strip_prefix("name") {
            let v = v.trim_start().strip_prefix('=')?.trim();
            return Some(v.trim_matches('"').to_string());
        }
    }
    None
}

fn post_edit(file: Option<String>, cwd: &Path) -> i32 {
    let Some(file) = file else { return 0 };
    let p = if Path::new(&file).is_absolute() { PathBuf::from(&file) } else { cwd.join(&file) };
    if !(file.ends_with(".rs") || file.ends_with("Cargo.toml")) {
        return 0;
    }
    let Some(krate) = crate_of(&p) else { return 0 };
    match Command::new("cargo")
        .args(["check", "-p", &krate, "--all-targets", "--message-format", "short", "--color", "never"])
        .current_dir(cwd)
        .output()
    {
        Ok(o) if !o.status.success() => {
            let text = String::from_utf8_lossy(&o.stderr);
            let lines: Vec<&str> = text
                .lines()
                .filter(|l| !l.trim_start().starts_with("Compiling") && !l.trim().is_empty())
                .take(40)
                .collect();
            eprintln!("cargo check -p {krate} failed:\n{}", lines.join("\n"));
            2
        }
        _ => 0,
    }
}

/// Reasons the worker may not stop yet. `crate_name` comes from `SQ_WORKER_CRATE`.
fn stop(active: bool, cwd: &Path) -> i32 {
    if active {
        return 0;
    }
    let mut problems = Vec::new();
    if let Ok(krate) = std::env::var("SQ_WORKER_CRATE") {
        let ok = |args: &[&str]| {
            Command::new("cargo").args(args).current_dir(cwd).output().map(|o| o.status.success()).unwrap_or(false)
        };
        if !ok(&["clippy", "-p", &krate, "--all-targets", "--", "-D", "warnings"]) {
            problems.push(format!("clippy is not clean for {krate} (run `cargo xtask check {krate}`)"));
        }
        if !ok(&["test", "-p", &krate]) {
            problems.push(format!("tests of {krate} are not green"));
        }
    }
    match Command::new("git").args(["status", "--porcelain"]).current_dir(cwd).output() {
        Ok(o) if !o.stdout.is_empty() => {
            problems.push("the working tree has uncommitted changes: commit your own paths".to_string())
        }
        _ => {}
    }
    if problems.is_empty() {
        0
    } else {
        eprintln!("Not done yet:\n- {}", problems.join("\n- "));
        2
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn denied(c: &str) -> bool {
        pre_bash(c, true).is_some()
    }

    #[test]
    fn git_destructive_commands_are_denied() {
        for c in [
            "git stash",
            "git stash pop",
            "git reset --hard",
            "git -C /x reset HEAD~1",
            "git checkout .",
            "git checkout -- .",
            "git restore .",
            "git clean -fd",
            "git rebase main",
            "git push --force",
            "git push -f origin x",
            "git push origin x --force-with-lease",
            "cd a && git stash",
            "echo hi; nice -n 15 git reset",
            "GIT_X=1 git clean -n",
            "bash -c 'git stash'",
            "/usr/bin/git reset",
        ] {
            assert!(denied(c), "{c}");
        }
    }

    #[test]
    fn harmless_git_is_allowed() {
        for c in [
            "git status",
            "git add a b",
            "git commit -m 'no git stash here'",
            "git checkout -b rs/x",
            "git push origin rs/x",
            "git push -u origin rs/x",
            "git log --oneline",
            "git restore src/a.rs",
        ] {
            assert!(!denied(c), "{c}");
        }
    }

    #[test]
    fn rm_rf_variants() {
        for c in ["rm -rf x", "rm -fr x", "rm -Rf x", "rm -r -f x", "rm --recursive --force x", "sudo rm -rf /"] {
            assert!(denied(c), "{c}");
        }
        for c in ["rm x", "rm -f x", "rm -r x", "echo rm -rf"] {
            assert!(!denied(c), "{c}");
        }
    }

    #[test]
    fn cargo_needs_a_worktree() {
        assert!(pre_bash("nice -n 15 cargo test", false).is_some());
        assert!(pre_bash("CARGO_TARGET_DIR=x cargo check", false).is_some());
        assert!(pre_bash("cargo test", true).is_none());
        assert!(pre_bash("ls", false).is_none());
    }

    #[test]
    fn read_block_list() {
        for p in [
            "/r/Packages/SQGPU/Sources/ShaderSources.swift",
            "Vendor/CThorVG/src/a.cpp",
            "x/rnn_data.c",
            "/v/onnxruntime/include/onnxruntime_c_api.h",
            "Packages/SQPremiereImport/Tests/X/Fixtures/a.prproj",
            "C:\\r\\TestMedia\\a.mov",
            "TestMedia/b.mp4",
        ] {
            assert!(pre_read(p).is_some(), "{p}");
        }
        for p in [
            "crates/sq-core/src/lib.rs",
            "docs/rust/PORTING.md",
            "Packages/SQGPU/Sources/Shaders/a.slang",
            "onnxruntime-notes.md",
        ] {
            assert!(pre_read(p).is_none(), "{p}");
        }
    }

    #[test]
    fn write_scope() {
        let cwd = Path::new("/w/wt");
        assert!(pre_write("/etc/x", cwd, None).is_none());
        assert!(pre_write("/etc/x", cwd, Some("")).is_none());
        assert!(pre_write("crates/sq-core/src/a.rs", cwd, Some("crates/sq-core")).is_none());
        assert!(pre_write("/w/wt/crates/sq-core/a.rs", cwd, Some("crates/sq-core;docs/rust")).is_none());
        assert!(pre_write("docs/rust/X.md", cwd, Some("crates/sq-core;docs/rust")).is_none());
        assert!(pre_write("crates/sq-core2/a.rs", cwd, Some("crates/sq-core")).is_some());
        assert!(pre_write("crates/sq-core/../sq-render/a.rs", cwd, Some("crates/sq-core")).is_some());
        assert!(pre_write("Cargo.toml", cwd, Some("crates/sq-core")).is_some());
    }

    #[test]
    fn manifest_package_name() {
        let m = "[workspace]\nname = \"no\"\n[package]\nname = \"sq-core\"\nversion = \"1\"\n";
        assert_eq!(package_name(m).as_deref(), Some("sq-core"));
        assert_eq!(package_name("[lib]\nname = \"x\""), None);
    }

    #[test]
    fn stop_hook_active_never_loops() {
        assert_eq!(stop(true, Path::new(".")), 0);
    }
}
