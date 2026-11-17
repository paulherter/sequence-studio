//! What the setup is doing, and the steps a job walks through.

use crate::version::Version;

/// The work a setup run does. The old version rides along where the screens name it (`Updated from 0.1.2`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Job {
    /// Windows: first install.
    Install,
    /// Windows: over an existing install (ours, or the old Inno one).
    Update {
        from: Version,
    },
    Uninstall,
    /// Linux: menu entry, `.sqproj` link and the move of the AppImage.
    LinuxAdd,
    LinuxUpdate {
        from: Version,
    },
    LinuxRemove,
}

impl Job {
    /// The title of the progress screen.
    pub fn progress_title(&self, new: &Version) -> String {
        match self {
            Job::Install => "Installing Sequence Studio".into(),
            Job::Update { .. } | Job::LinuxUpdate { .. } => format!("Updating to {new}"),
            Job::Uninstall => "Removing Sequence Studio".into(),
            Job::LinuxAdd => "Adding to your apps".into(),
            Job::LinuxRemove => "Removing from your apps".into(),
        }
    }

    /// The title of the error screen.
    pub fn failure_title(&self) -> &'static str {
        match self {
            Job::Install => "Installation failed",
            Job::Update { .. } | Job::LinuxUpdate { .. } => "Update failed",
            Job::Uninstall => "Uninstall failed",
            Job::LinuxAdd | Job::LinuxRemove => "Couldn't add to your apps",
        }
    }

    /// The closing sentence of an error: what state the computer is in.
    pub fn state_after_failure(&self) -> &'static str {
        match self {
            Job::Install => "Nothing was installed.",
            Job::Update { .. } | Job::LinuxUpdate { .. } => "Your installed version still works.",
            Job::Uninstall | Job::LinuxRemove => "Nothing was removed.",
            Job::LinuxAdd => "Nothing was added.",
        }
    }

    /// Whether the job removes instead of adds.
    pub fn removes(&self) -> bool {
        matches!(self, Job::Uninstall | Job::LinuxRemove)
    }

    pub fn is_linux(&self) -> bool {
        matches!(self, Job::LinuxAdd | Job::LinuxUpdate { .. } | Job::LinuxRemove)
    }

    /// The steps in order with the share of the bar each owns (start, end as fractions of 1). Install and update split
    /// 4 / 86 / 7 / 3 percent (`Preparing`, `Copying files`, Start menu, `Finishing`); the others are as the spec says.
    pub fn steps(&self) -> &'static [(Step, f64, f64)] {
        match self {
            Job::Install | Job::Update { .. } => &[
                (Step::Preparing, 0.0, 0.04),
                (Step::Copying, 0.04, 0.90),
                (Step::StartMenu, 0.90, 0.97),
                (Step::Finishing, 0.97, 1.0),
            ],
            Job::Uninstall => &[(Step::RemovingFiles, 0.0, 0.92), (Step::RemovingStartMenu, 0.92, 1.0)],
            Job::LinuxAdd | Job::LinuxUpdate { .. } => {
                &[(Step::MovingAppFile, 0.0, 0.85), (Step::AddingMenuEntry, 0.85, 1.0)]
            }
            Job::LinuxRemove => &[(Step::AddingMenuEntry, 0.0, 1.0)],
        }
    }

    /// From this bar value on, Cancel is disabled: the registry and shortcut step is short and not cut in half. A job
    /// that cannot be rolled back (removing) is never cancelable (0).
    pub fn cancel_until(&self) -> f64 {
        match self {
            Job::Install | Job::Update { .. } => 0.90,
            Job::LinuxAdd | Job::LinuxUpdate { .. } => 0.85,
            Job::Uninstall | Job::LinuxRemove => 0.0,
        }
    }
}

/// One step of a job; the label is the line left above the bar.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    Preparing,
    Copying,
    StartMenu,
    Finishing,
    RemovingFiles,
    RemovingStartMenu,
    MovingAppFile,
    AddingMenuEntry,
}

impl Step {
    pub fn label(self) -> &'static str {
        match self {
            Step::Preparing => "Preparing\u{2026}",
            Step::Copying => "Copying files",
            Step::StartMenu => "Adding to the Start menu",
            Step::Finishing => "Finishing",
            Step::RemovingFiles => "Removing files",
            Step::RemovingStartMenu => "Removing the Start menu entry",
            Step::MovingAppFile => "Moving the app file",
            Step::AddingMenuEntry => "Adding the menu entry",
        }
    }

    /// The sub line under the bar when the step has no byte count of its own.
    pub fn detail(self) -> &'static str {
        match self {
            Step::Preparing => "Checking the package",
            Step::Copying | Step::RemovingFiles | Step::MovingAppFile => "",
            Step::StartMenu | Step::RemovingStartMenu | Step::AddingMenuEntry => "Registering the app",
            Step::Finishing => "Cleaning up",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_job_covers_the_bar_from_start_to_end_without_a_gap() {
        let old = Version::new(0, 1, 2);
        for job in [
            Job::Install,
            Job::Update { from: old.clone() },
            Job::Uninstall,
            Job::LinuxAdd,
            Job::LinuxUpdate { from: old },
            Job::LinuxRemove,
        ] {
            let steps = job.steps();
            assert_eq!(steps.first().map(|s| s.1), Some(0.0), "{job:?}");
            assert_eq!(steps.last().map(|s| s.2), Some(1.0), "{job:?}");
            for pair in steps.windows(2) {
                assert_eq!(pair[0].2, pair[1].1, "{job:?} has a gap");
            }
        }
    }

    #[test]
    fn titles_follow_the_job_and_the_state_sentence_says_what_is_left() {
        let new = Version::new(0, 2, 0);
        assert_eq!(Job::Install.progress_title(&new), "Installing Sequence Studio");
        assert_eq!(Job::Update { from: Version::new(0, 1, 2) }.progress_title(&new), "Updating to 0.2.0");
        assert_eq!(Job::LinuxAdd.progress_title(&new), "Adding to your apps");
        assert_eq!(Job::Uninstall.failure_title(), "Uninstall failed");
        assert_eq!(Job::Install.state_after_failure(), "Nothing was installed.");
        assert_eq!(Job::Update { from: new }.state_after_failure(), "Your installed version still works.");
    }

    #[test]
    fn cancel_is_open_until_the_registry_step_starts() {
        assert_eq!(Job::Install.cancel_until(), 0.90);
        assert_eq!(Job::Uninstall.cancel_until(), 0.0, "a removal cannot be rolled back");
    }
}
