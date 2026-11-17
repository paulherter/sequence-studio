//! The command line of the setup program (spec §10.1, §10.2).
//!
//! `SequenceStudio-Setup.exe [--quiet] [--dir <folder>] [--desktop]` installs or updates;
//! `Uninstall Sequence Studio.exe --uninstall [--quiet] [--delete-data]` removes; the uninstaller starts a copy of itself
//! as `--uninstall --from <folder>` so its own file can go too; `--pack <stage> --out <setup.exe>` makes a setup program.

use std::path::PathBuf;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Args {
    /// No window: the same job, the exit code says how it went (0 = ok, else the error number).
    pub quiet: bool,
    pub uninstall: bool,
    /// The install folder an uninstall copy removes (set by the program itself).
    pub from: Option<PathBuf>,
    /// The install folder, for tests and scripts.
    pub dir: Option<PathBuf>,
    pub desktop: bool,
    pub delete_data: bool,
    /// `--pack <stage folder>` and `--out <file>`.
    pub pack: Option<PathBuf>,
    pub out: Option<PathBuf>,
}

impl Args {
    pub fn parse(args: &[String]) -> Result<Args, String> {
        let mut out = Args::default();
        let mut it = args.iter();
        while let Some(arg) = it.next() {
            let mut value = |name: &str| it.next().map(PathBuf::from).ok_or_else(|| format!("{name} needs a value"));
            match arg.as_str() {
                "--quiet" => out.quiet = true,
                "--uninstall" => out.uninstall = true,
                "--desktop" => out.desktop = true,
                "--delete-data" => out.delete_data = true,
                "--from" => out.from = Some(value("--from")?),
                "--dir" => out.dir = Some(value("--dir")?),
                "--pack" => out.pack = Some(value("--pack")?),
                "--out" => out.out = Some(value("--out")?),
                other => return Err(format!("unknown option {other}")),
            }
        }
        Ok(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(text: &str) -> Result<Args, String> {
        Args::parse(&text.split_whitespace().map(String::from).collect::<Vec<_>>())
    }

    #[test]
    fn the_install_and_uninstall_options_are_read() {
        let a = parse("--quiet --dir D:\\Apps --desktop").unwrap_or_default();
        assert!(a.quiet && a.desktop && !a.uninstall);
        assert_eq!(a.dir, Some(PathBuf::from("D:\\Apps")));
        let u = parse("--uninstall --from C:\\App --delete-data").unwrap_or_default();
        assert!(u.uninstall && u.delete_data && !u.quiet);
        assert_eq!(u.from, Some(PathBuf::from("C:\\App")));
        assert_eq!(parse("").unwrap_or_default(), Args::default());
    }

    #[test]
    fn pack_takes_the_stage_and_the_output() {
        let a = parse("--pack stage --out setup.exe").unwrap_or_default();
        assert_eq!((a.pack, a.out), (Some(PathBuf::from("stage")), Some(PathBuf::from("setup.exe"))));
    }

    #[test]
    fn an_unknown_option_or_a_missing_value_is_refused() {
        assert!(parse("--frobnicate").is_err());
        assert!(parse("--dir").is_err());
    }
}
