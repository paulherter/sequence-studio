#![allow(clippy::expect_used)]
//! A process whose stdout and stderr pipes are closed by the reader must write through `sq_os::outln!` and
//! `sq_os::errln!` without a panic and exit 0 (the GUI app used to crash with os error 232 / EPIPE).
//! No libtest harness: the harness itself prints to stdout and would be the first to fail.

use std::process::{Command, Stdio};

fn main() {
    if std::env::var_os("SQ_STDIO_CHILD").is_some() {
        for i in 0..2000 {
            sq_os::outln!("line {i} {}", "x".repeat(200));
            sq_os::errln!("err {i}");
            sq_os::out!("partial");
            sq_os::err!("partial");
        }
        return;
    }
    let exe = std::env::current_exe().expect("test exe");
    let mut child = Command::new(exe)
        .env("SQ_STDIO_CHILD", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .expect("spawn child");
    // The reader goes away before the child writes much: its pipes are closed.
    drop(child.stdout.take());
    drop(child.stderr.take());
    let status = child.wait().expect("wait");
    assert!(status.success(), "child with closed pipes failed: {status:?}");
    println!("closed_stdout: ok");
}
