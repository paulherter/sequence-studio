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
        // One source: the app reads the same id from `Identity`, so packager and app cannot drift apart.
        sq_setup_engine::Identity::from_raw(Some(if self.nightly() { "nightly" } else { "stable" })).linux_id()
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

    /// `CFBundleVersion`: up to three period-separated integers, and every newer build of a channel compares higher.
    /// Scheme `<major*1000+minor>.<patch>.<third>`: `third` is the build date (YYYYMMDD) for Nightly and 0 for Stable, so
    /// 0.2.1 -> "2.1.0" and 0.2.1-nightly.20261121 -> "2.1.20261121". A new base version always raises the first two parts,
    /// a later nightly of the same version raises the date. Stable and Nightly have separate bundle ids, so they are never
    /// compared with each other. A base that is not `x.y.z` gives "0.0.0" (the caller's version check fails elsewhere).
    pub(crate) fn bundle_build(self, base: &str, date: &str) -> String {
        let n: Vec<u32> = base.split('.').map(|p| p.parse().unwrap_or(0)).collect();
        let [major, minor, patch] = [0, 1, 2].map(|i| n.get(i).copied().unwrap_or(0));
        let third = if self.nightly() { date.parse::<u32>().unwrap_or(0) } else { 0 };
        format!("{}.{patch}.{third}", major * 1000 + minor)
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

/// The build date as `YYYYMMDD`: `SQ_NIGHTLY_DATE` when it is set (so two builds of one day can differ, for update tests),
/// else today (UTC).
pub(crate) fn today() -> String {
    date_or_today(std::env::var("SQ_NIGHTLY_DATE").ok().as_deref())
}

/// `over` when it is a valid `YYYYMMDD` date, else today.
fn date_or_today(over: Option<&str>) -> String {
    if let Some(d) = over.map(str::trim).filter(|d| valid_date(d)) {
        return d.to_string();
    }
    utc_today()
}

fn valid_date(d: &str) -> bool {
    let b = d.as_bytes();
    if b.len() != 8 || !b.iter().all(u8::is_ascii_digit) {
        return false;
    }
    let (y, m, day): (u32, u32, u32) =
        (d[..4].parse().unwrap_or(0), d[4..6].parse().unwrap_or(0), d[6..].parse().unwrap_or(0));
    y >= 2000 && (1..=12).contains(&m) && (1..=31).contains(&day)
}

/// Today's date (UTC) as `YYYYMMDD`.
fn utc_today() -> String {
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
        assert_eq!(
            (c.mac_icon(), c.linux_icon(), c.windows_icon()),
            ("AppIcon.icns", "sequence-studio.png", "SequenceStudio.ico")
        );
        assert_eq!(c.version("0.2.0", "20261119"), "0.2.0");
        assert_eq!(c.windows_script_args("0.2.0", "20261119"), v(&["-Version", "0.2.0"]));
    }

    #[test]
    fn the_bundle_build_rises_with_every_newer_build() {
        assert_eq!(Channel::Stable.bundle_build("0.2.1", "20261121"), "2.1.0");
        assert_eq!(Channel::Nightly.bundle_build("0.2.1", "20261121"), "2.1.20261121");
        let key = |s: String| s.split('.').map(|p| p.parse::<u32>().unwrap_or(0)).collect::<Vec<_>>();
        let builds = [
            Channel::Nightly.bundle_build("0.2.1", "20261121"),
            Channel::Nightly.bundle_build("0.2.1", "20261122"),
            Channel::Nightly.bundle_build("0.2.2", "20261123"),
            Channel::Nightly.bundle_build("0.3.0", "20261124"),
            Channel::Nightly.bundle_build("1.0.0", "20270101"),
        ];
        assert!(builds.windows(2).all(|w| key(w[0].clone()) < key(w[1].clone())), "{builds:?}");
        let stable = ["0.2.0", "0.2.1", "0.3.0", "1.0.0"].map(|b| key(Channel::Stable.bundle_build(b, "20261121")));
        assert!(stable.windows(2).all(|w| w[0] < w[1]));
        assert_eq!(Channel::Stable.bundle_build("junk", "20261121"), "0.0.0");
    }

    #[test]
    fn the_linux_id_is_the_apps_own() {
        use sq_setup_engine::Identity;
        assert_eq!(Channel::Stable.linux_id(), Identity::STABLE.linux_id());
        assert_eq!(Channel::Nightly.linux_id(), Identity::NIGHTLY.linux_id());
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
        assert!(
            a.contains(&"SequenceStudioNightly".to_string()) && a.contains(&"SequenceStudio-Nightly.ico".to_string())
        );
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
    fn the_build_date_can_be_overridden_with_a_valid_date_only() {
        assert_eq!(date_or_today(Some("20261121")), "20261121");
        assert_eq!(date_or_today(Some(" 20261121 ")), "20261121");
        for bad in ["", "2026112", "202611211", "2026-11-2", "20261321", "20261100", "abcdefgh"] {
            assert_eq!(date_or_today(Some(bad)), utc_today(), "{bad}");
        }
        assert_eq!(date_or_today(None), utc_today());
    }

    #[test]
    fn days_become_dates() {
        assert_eq!(ymd(0), "19700101");
        assert_eq!(ymd(20_046), "20241119");
        assert_eq!(ymd(11_016), "20000229");
        assert_eq!(ymd(20_411), "20251119");
    }
}
