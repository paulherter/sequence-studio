//! Console output that never panics. `println!`/`eprintln!` panic when the stream is closed (a harness that stops reading
//! the pipe: os error 232 on Windows, EPIPE on Linux and Mac), and a panic in the GUI app means a crash report and the
//! "quit unexpectedly" dialog on the next start. Every console line of the app goes through these macros instead
//! (`sq_os::outln!`, `sq_os::errln!`, `sq_os::out!`, `sq_os::err!`): a failed write is dropped.

use std::fmt::Arguments;
use std::io::Write;

/// Writes to stdout, ignoring a closed stream. Use the macros.
pub fn write_out(args: Arguments<'_>, newline: bool) {
    write_to(&mut std::io::stdout().lock(), args, newline);
}

/// Writes to stderr, ignoring a closed stream. Use the macros.
pub fn write_err(args: Arguments<'_>, newline: bool) {
    write_to(&mut std::io::stderr().lock(), args, newline);
}

/// The shared write: a failure of the stream is not ours to report (there is nowhere to print it).
pub fn write_to(out: &mut dyn Write, args: Arguments<'_>, newline: bool) {
    let _ = out.write_fmt(args);
    if newline {
        let _ = out.write_all(b"\n");
    }
    let _ = out.flush();
}

/// Like `println!`, without the panic on a closed stdout.
#[macro_export]
macro_rules! outln {
    () => { $crate::stdio::write_out(format_args!(""), true) };
    ($($arg:tt)*) => { $crate::stdio::write_out(format_args!($($arg)*), true) };
}

/// Like `print!`, without the panic on a closed stdout.
#[macro_export]
macro_rules! out {
    ($($arg:tt)*) => { $crate::stdio::write_out(format_args!($($arg)*), false) };
}

/// Like `eprintln!`, without the panic on a closed stderr.
#[macro_export]
macro_rules! errln {
    () => { $crate::stdio::write_err(format_args!(""), true) };
    ($($arg:tt)*) => { $crate::stdio::write_err(format_args!($($arg)*), true) };
}

/// Like `eprint!`, without the panic on a closed stderr.
#[macro_export]
macro_rules! err {
    ($($arg:tt)*) => { $crate::stdio::write_err(format_args!($($arg)*), false) };
}

#[cfg(test)]
mod tests {
    use std::io::{self, Write};

    struct Closed;
    impl Write for Closed {
        fn write(&mut self, _: &[u8]) -> io::Result<usize> {
            Err(io::Error::from(io::ErrorKind::BrokenPipe))
        }
        fn flush(&mut self) -> io::Result<()> {
            Err(io::Error::from(io::ErrorKind::BrokenPipe))
        }
    }

    #[test]
    fn a_closed_stream_is_not_fatal() {
        super::write_to(&mut Closed, format_args!("x {}", 1), true);
    }

    #[test]
    fn the_text_and_newline_arrive() {
        let mut buf = Vec::new();
        super::write_to(&mut buf, format_args!("a{}", 1), true);
        assert_eq!(buf, b"a1\n");
    }
}
