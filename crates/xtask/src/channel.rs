// SPDX-License-Identifier: GPL-3.0-or-later
//! The release channel of a package: `cargo xtask package --channel nightly` (or `SQ_CHANNEL=nightly`; default stable).
//! This is the one place that maps a channel to names and ids; the Mac, Linux and Windows packagers only ask it, so
//! Nightly and Stable install side by side (own name, bundle id, file names, icon). The channel is also exported to the
//! app build as `SQ_CHANNEL` (read at compile time with `option_env!`).

use std::time::{SystemTime, UNIX_EPOCH};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub(crate) enum Channel {
    #[default]
    Stable,
    Nightly,
}

impl Channel {
    pub(crate) fn parse(s: &str) -> Result<Channel, String> {
        match s {
            "stable" => Ok(Channel::Stable),
            "nightly" => Ok(Channel::Nightly),
            other => Err(format!("unknown channel {other}; use stable or nightly")),
        }
    }

    /// Takes `--channel <x>` / `--channel=<x>` out of the arguments; without it `SQ_CHANNEL` decides.
    pub(crate) fn extract(args: &[String]) -> Result<(Channel, Vec<String>), String> {
        Self::extract_with(args, std::env::var("SQ_CHANNEL").ok().as_deref())
    }

    fn extract_with(args: &[String], env: Option<&str>) -> Result<(Channel, Vec<String>), String> {
        let mut channel = match env.filter(|e| !e.is_empty()) {
            Some(e) => Channel::parse(e)?,
            None => Channel::Stable,
        };
        let mut rest = Vec::new();
        let mut it = args.iter();
        while let Some(a) = it.next() {
            if a == "--channel" {
                channel = Channel::parse(it.next().ok_or("--channel needs stable or nightly")?)?;
            } else if let Some(v) = a.strip_prefix("--channel=") {
                channel = Channel::parse(v)?;
            } else {
                rest.push(a.clone());
            }
        }
        Ok((channel, rest))
    }

    /// The value of `SQ_CHANNEL` for the app build.
    pub(crate) fn id(self) -> &'static str {
        match self {
            Channel::Stable => "stable",
            Channel::Nightly => "nightly",
        }
    }

    fn nightly(self) -> bool {
        self == Channel::Nightly
    }

    /// Product name: the .app folder, the DMG name, the desktop entry name, the Windows product name.
    pub(crate) fn display_name(self) -> &'static str {
        if self.nightly() { "Sequence Studio Nightly" } else { "Sequence Studio" }
    }

    /// Bundle id on the Mac (CFBundleIdentifier).
    pub(crate) fn bundle_id(self) -> &'static str {
        if self.nightly() { "de.paulherter.SequenceStudio.nightly" } else { "de.paulherter.SequenceStudio" }
    }

    /// Linux desktop file id and icon name (`<id>.desktop`).
    pub(crate) fn linux_id(self) -> &'static str {
        if self.nightly() { "sequence-studio-nightly" } else { "sequence-studio" }
    }

    /// Start of the AppImage, zip and setup file names (no spaces).
    pub(crate) fn file_prefix(self) -> &'static str {
        if self.nightly() { "SequenceStudioNightly" } else { "SequenceStudio" }
    }

    pub(crate) fn mac_icon(self) -> &'static str {
        if self.nightly() { "AppIcon-Nightly.icns" } else { "AppIcon.icns" }
    }

    pub(crate) fn linux_icon(self) -> &'static str {
        if self.nightly() { "sequence-studio-nightly.png" } else { "sequence-studio.png" }
    }

    pub(crate) fn windows_icon(self) -> &'static str {
        if self.nightly() { "SequenceStudio-Nightly.ico" } else { "SequenceStudio.ico" }
    }

    /// Windows AppUserModelID.
    pub(crate) fn windows_aumid(self) -> &'static str {
        if self.nightly() { "SequenceStudio.Nightly.App" } else { "SequenceStudio.App" }
    }

    /// Inno Setup AppId (a GUID of its own, so the two installs never replace each other).
    pub(crate) fn windows_app_guid(self) -> &'static str {
        if self.nightly() { "9D3B7E14-52A8-4C6F-8E21-4A0F5B7C3D68" } else { "6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4" }
    }

    /// Version string: Nightly gets `-nightly.<YYYYMMDD>`.
    pub(crate) fn version(self, base: &str, date: &str) -> String {
        if self.nightly() { format!("{base}-nightly.{date}") } else { base.to_string() }
    }

    /// The arguments of `build-installer.ps1` that differ per channel.
    pub(crate) fn windows_script_args(self, base_version: &str, date: &str) -> Vec<String> {
        let mut a = vec!["-Version".to_string(), self.version(base_version, date)];
        if self.nightly() {
            for (k, v) in [
                ("-Name", self.display_name()),
                ("-FilePrefix", self.file_prefix()),
                ("-Aumid", self.windows_aumid()),
                ("-AppGuid", self.windows_app_guid()),
                ("-Icon", self.windows_icon()),
            ] {
                a.push(k.into());
                a.push(v.into());
            }
        }
        a
    }
}

/// Today's date (UTC) as `YYYYMMDD`.
pub(crate) fn today() -> String {
    let secs = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    ymd(i64::try_from(secs / 86_400).unwrap_or(0))
}

/// `YYYYMMDD` of a day count since 1970-01-01 (civil-from-days).
fn ymd(days: i64) -> String {
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}{m:02}{d:02}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(a: &[&str]) -> Vec<String> {
        a.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn stable_keeps_the_names_of_today() {
        let c = Channel::Stable;
        assert_eq!(c.display_name(), "Sequence Studio");
        assert_eq!(c.bundle_id(), "de.paulherter.SequenceStudio");
        assert_eq!(c.linux_id(), "sequence-studio");
        assert_eq!(c.file_prefix(), "SequenceStudio");
        assert_eq!(c.windows_aumid(), "SequenceStudio.App");
        assert_eq!(c.windows_app_guid(), "6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4");
        assert_eq!((c.mac_icon(), c.linux_icon(), c.windows_icon()), ("AppIcon.icns", "sequence-studio.png", "SequenceStudio.ico"));
        assert_eq!(c.version("0.2.0", "20261119"), "0.2.0");
        assert_eq!(c.windows_script_args("0.2.0", "20261119"), v(&["-Version", "0.2.0"]));
    }

    #[test]
    fn nightly_has_its_own_name_id_icon_and_version() {
        let c = Channel::Nightly;
        assert_eq!(c.display_name(), "Sequence Studio Nightly");
        assert_eq!(c.bundle_id(), "de.paulherter.SequenceStudio.nightly");
        assert_eq!(c.linux_id(), "sequence-studio-nightly");
        assert!(c.file_prefix().contains("Nightly"));
        assert_eq!(c.windows_aumid(), "SequenceStudio.Nightly.App");
        assert_ne!(c.windows_app_guid(), Channel::Stable.windows_app_guid());
        assert_eq!(c.version("0.2.0", "20261119"), "0.2.0-nightly.20261119");
        let a = c.windows_script_args("0.2.0", "20261119");
        assert_eq!(a[..2], v(&["-Version", "0.2.0-nightly.20261119"])[..]);
        assert!(a.contains(&"SequenceStudioNightly".to_string()) && a.contains(&"SequenceStudio-Nightly.ico".to_string()));
    }

    #[test]
    fn the_channel_comes_from_the_flag_else_the_environment_else_stable() {
        let ok = |args: &[&str], env: Option<&str>| Channel::extract_with(&v(args), env);
        assert_eq!(ok(&["--dmg"], None), Ok((Channel::Stable, v(&["--dmg"]))));
        assert_eq!(ok(&["--dmg", "--channel", "nightly"], None), Ok((Channel::Nightly, v(&["--dmg"]))));
        assert_eq!(ok(&["--channel=nightly", "--sign"], None), Ok((Channel::Nightly, v(&["--sign"]))));
        assert_eq!(ok(&[], Some("nightly")), Ok((Channel::Nightly, vec![])));
        assert_eq!(ok(&["--channel", "stable"], Some("nightly")), Ok((Channel::Stable, vec![])));
        assert!(ok(&["--channel"], None).is_err());
        assert!(ok(&["--channel", "beta"], None).is_err());
        assert!(ok(&[], Some("beta")).is_err());
    }

    #[test]
    fn days_become_dates() {
        assert_eq!(ymd(0), "19700101");
        assert_eq!(ymd(20_046), "20241119");
        assert_eq!(ymd(11_016), "20000229");
        assert_eq!(ymd(20_411), "20251119");
    }
}
