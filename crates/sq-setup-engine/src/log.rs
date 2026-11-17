//! The setup log: `%TEMP%\Sequence Studio Setup <yyyyMMdd-HHmmss>.log`, one line per action and OS error.

use sq_core_time::local_time::Civil;
use std::fs::File;
use std::io::Write;
use std::path::{Path, PathBuf};

/// Appends lines to the log file. Writing never fails the job: the file is created at the first line, and a file that
/// cannot be written is dropped silently.
#[derive(Debug)]
pub struct Log {
    path: PathBuf,
    file: Option<File>,
    broken: bool,
}

/// `20261116-093005` for the file name.
pub fn stamp(c: &Civil) -> String {
    format!("{:04}{:02}{:02}-{:02}{:02}{:02}", c.year, c.month, c.day, c.hour, c.minute, c.second)
}

impl Log {
    /// The log in `temp`, named after the clock text (see [`stamp`]); the caller supplies it so tests are stable.
    pub fn new(temp: &Path, stamp: &str) -> Log {
        Log { path: temp.join(format!("Sequence Studio Setup {stamp}.log")), file: None, broken: false }
    }

    /// Where the file is (or will be): the Open-log button opens this.
    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn line(&mut self, text: &str) {
        if self.broken {
            return;
        }
        if self.file.is_none() {
            if let Some(parent) = self.path.parent() {
                let _ = std::fs::create_dir_all(parent);
            }
            match File::create(&self.path) {
                Ok(f) => self.file = Some(f),
                Err(_) => {
                    self.broken = true;
                    return;
                }
            }
        }
        if let Some(f) = self.file.as_mut()
            && writeln!(f, "{text}").is_err()
        {
            self.broken = true;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_name_follows_the_clock_and_lines_are_appended() {
        let dir = std::env::temp_dir().join(format!("sq-log-{}", std::process::id()));
        let civil = Civil { year: 2026, month: 11, day: 6, hour: 9, minute: 5, second: 3 };
        assert_eq!(stamp(&civil), "20261106-090503");
        let mut log = Log::new(&dir, &stamp(&civil));
        assert_eq!(log.path().file_name().and_then(|n| n.to_str()), Some("Sequence Studio Setup 20261106-090503.log"));
        assert!(!log.path().exists(), "nothing is written before the first line");
        log.line("one");
        log.line("two");
        assert_eq!(std::fs::read_to_string(log.path()).ok().as_deref(), Some("one\ntwo\n"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
