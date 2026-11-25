//! The names one release channel installs under. Stable and Nightly install side by side, so each has its own folder,
//! shortcuts, registry records and taskbar identity; the files inside the install folder (`SequenceStudio.exe`,
//! `SequenceStudio.ico`) are named the same in both.

/// Which channel a setup program installs. The packager fixes it at build time (`SQ_CHANNEL`, the same value the app is
/// built with), so a setup and the app it installs always agree.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Identity {
    nightly: bool,
}

impl Identity {
    pub const STABLE: Identity = Identity { nightly: false };
    pub const NIGHTLY: Identity = Identity { nightly: true };

    /// The channel of a build: `nightly` when `SQ_CHANNEL` said so at compile time, else Stable.
    pub fn build() -> Identity {
        Identity::from_raw(option_env!("SQ_CHANNEL"))
    }

    pub fn from_raw(raw: Option<&str>) -> Identity {
        Identity { nightly: raw.is_some_and(|c| c.trim().eq_ignore_ascii_case("nightly")) }
    }

    pub fn is_nightly(self) -> bool {
        self.nightly
    }

    /// The other channel.
    pub fn other(self) -> Identity {
        Identity { nightly: !self.nightly }
    }

    fn pick(self, stable: &'static str, nightly: &'static str) -> &'static str {
        if self.nightly { nightly } else { stable }
    }

    /// The Linux id of the channel: desktop entry (`<id>.desktop`), icon (`<id>.png`), window app id, data folder. Matches
    /// what the Linux packager writes into the AppImage.
    pub fn linux_id(self) -> &'static str {
        self.pick("sequence-studio", "sequence-studio-nightly")
    }

    /// The stable file name of the integrated AppImage in `~/Applications`.
    pub fn linux_integrated_name(self) -> &'static str {
        self.pick("SequenceStudio.AppImage", "SequenceStudioNightly.AppImage")
    }

    /// The install folder name, the shortcut file names and the Add/Remove Programs title.
    pub fn app_name(self) -> &'static str {
        self.pick("Sequence Studio", "Sequence Studio Nightly")
    }

    /// The setup program copy that removes the app.
    pub fn uninstaller_name(self) -> &'static str {
        self.pick("Uninstall Sequence Studio.exe", "Uninstall Sequence Studio Nightly.exe")
    }

    /// Taskbar and notification identity (the app sets the same).
    pub fn aumid(self) -> &'static str {
        self.pick("SequenceStudio.App", "SequenceStudio.Nightly.App")
    }

    pub fn project_class(self) -> &'static str {
        self.pick("SequenceStudio.Project", "SequenceStudio.Nightly.Project")
    }

    pub fn project_class_label(self) -> &'static str {
        self.pick("Sequence Studio project", "Sequence Studio Nightly project")
    }

    pub fn uninstall_key(self) -> &'static str {
        self.pick(
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\SequenceStudio",
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\SequenceStudioNightly",
        )
    }

    /// The key the old Inno installer of this channel wrote (its AppId plus `_is1`).
    pub fn inno_uninstall_key(self) -> &'static str {
        self.pick(
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{6C1E2A57-3B0D-4F52-9A0E-5E51A7C0D2B4}_is1",
            r"Software\Microsoft\Windows\CurrentVersion\Uninstall\{9D3B7E14-52A8-4C6F-8E21-4A0F5B7C3D68}_is1",
        )
    }

    pub fn aumid_key(self) -> &'static str {
        self.pick(
            r"Software\Classes\AppUserModelId\SequenceStudio.App",
            r"Software\Classes\AppUserModelId\SequenceStudio.Nightly.App",
        )
    }

    pub fn class_key(self) -> &'static str {
        self.pick(r"Software\Classes\SequenceStudio.Project", r"Software\Classes\SequenceStudio.Nightly.Project")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_two_channels_share_no_record() {
        let (a, b) = (Identity::STABLE, Identity::NIGHTLY);
        let pairs = [
            (a.app_name(), b.app_name()),
            (a.uninstaller_name(), b.uninstaller_name()),
            (a.aumid(), b.aumid()),
            (a.project_class(), b.project_class()),
            (a.uninstall_key(), b.uninstall_key()),
            (a.inno_uninstall_key(), b.inno_uninstall_key()),
            (a.aumid_key(), b.aumid_key()),
            (a.class_key(), b.class_key()),
        ];
        for (stable, nightly) in pairs {
            assert_ne!(stable, nightly);
        }
    }

    #[test]
    fn the_channel_is_read_from_the_build_value() {
        assert!(Identity::from_raw(Some("nightly")).is_nightly());
        assert!(!Identity::from_raw(Some("stable")).is_nightly());
        assert!(!Identity::from_raw(None).is_nightly());
    }
}
