// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaPolicy.swift (`extension MediaManagement`: folders, outside mode, disposition)
//! Where imported media lives in a project folder and what import does with a file from outside it. One rule set for
//! every import path; the shell reads it after each import and the copying is `MediaFileOps`.

use crate::media_file_ops::MediaManagement;
use sq_core_model::{ImportMode, MediaPolicyDefaults, OutsideMediaMode, Project};
use std::path::{Path, PathBuf};

/// What import does with one file (Swift `MediaManagement.Disposition`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Disposition {
    /// Use the file where it is: it is inside the project folder, or the choice is "leave".
    Link,
    /// Outside the project folder and the project asks.
    Ask,
    /// Outside the project folder: copy or move it into `Files/Imported/` without asking.
    Apply(ImportMode),
    /// Swift's `.link` for a project file that is not in a folder of its own name (`Film/Untitled Project.sqproj`) while
    /// the setting would copy, move or ask: there is no `Files/` to copy into, so the file stays where it is. Told apart
    /// from `Link` only so the import can say why nothing was copied.
    Stay,
}

impl MediaManagement {
    /// The project folder (`<Name>/`) of a project that lives in one; `None` for a loose project file or an unsaved project.
    pub fn project_folder(project_url: Option<&Path>) -> Option<PathBuf> {
        let url = project_url?;
        let dir = url.parent()?;
        (dir.file_name()? == url.file_stem()?).then(|| dir.to_path_buf())
    }

    /// `Files/` in a project folder, otherwise `<Name> Files/` next to the project file.
    pub fn files_folder(project_url: &Path) -> PathBuf {
        let dir = project_url.parent().map(Path::to_path_buf).unwrap_or_default();
        match Self::project_folder(Some(project_url)) {
            Some(folder) => folder.join("Files"),
            None => {
                let stem = project_url.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                dir.join(format!("{stem} Files"))
            }
        }
    }

    /// `Files/Imported/`: copies of outside media (flat). Created on the first copy.
    pub fn imported_folder(project_url: &Path) -> PathBuf {
        Self::files_folder(project_url).join("Imported")
    }

    /// `Files/Library/`: Library items used in a sequence. Created on the first copy.
    pub fn library_folder(project_url: &Path) -> PathBuf {
        Self::files_folder(project_url).join("Library")
    }

    /// The effective outside-media mode of a project: its own choice, else an explicit older import mode, else the app default.
    pub fn outside_mode(project: &Project, defaults: &MediaPolicyDefaults) -> OutsideMediaMode {
        project
            .media_policy
            .as_ref()
            .and_then(|p| p.outside)
            .or(project.import_mode.map(|m| match m {
                ImportMode::Copy => OutsideMediaMode::Copy,
                ImportMode::Move => OutsideMediaMode::Move,
                ImportMode::Leave => OutsideMediaMode::Leave,
            }))
            .unwrap_or(defaults.outside)
    }

    /// Library items used by the project are copied into `Files/Library/` (only in a project folder).
    pub fn copies_library_items(project: &Project, project_url: Option<&Path>, defaults: &MediaPolicyDefaults) -> bool {
        Self::project_folder(project_url).is_some()
            && project.media_policy.as_ref().and_then(|p| p.copy_library_items).unwrap_or(defaults.copy_library_items)
    }

    /// Rule by location: inside the project folder is linked in place, never asked, never copied. Outside follows the
    /// project's mode. Loose project files and unsaved projects never ask: only an explicit older import mode applies there.
    /// This is the one decision: `Ask` and `Apply` come only with a project folder, so a question is never put whose answer
    /// has nowhere to go (a `Files/` folder beside a loose project file does not make it a project folder, as in Swift).
    pub fn disposition(
        path: &str,
        project: &Project,
        project_url: Option<&Path>,
        defaults: &MediaPolicyDefaults,
    ) -> Disposition {
        let Some(url) = project_url else { return Disposition::Link };
        let Some(folder) = Self::project_folder(Some(url)) else {
            return match project.import_mode {
                Some(ImportMode::Leave) => Disposition::Link,
                Some(mode) => Disposition::Apply(mode),
                None if Self::outside_mode(project, defaults) == OutsideMediaMode::Leave => Disposition::Link,
                None => Disposition::Stay,
            };
        };
        if Self::is_inside(path, &folder) {
            return Disposition::Link;
        }
        match Self::outside_mode(project, defaults) {
            OutsideMediaMode::Ask => Disposition::Ask,
            OutsideMediaMode::Leave => Disposition::Link,
            OutsideMediaMode::Copy => Disposition::Apply(ImportMode::Copy),
            OutsideMediaMode::Move => Disposition::Apply(ImportMode::Move),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_model::MediaPolicy;
    use sq_core_time::Id;

    fn project(outside: Option<OutsideMediaMode>) -> Project {
        let mut p = Project::new(Id::from_u128(1), "Film", Vec::new(), Vec::new());
        p.media_policy = outside.map(|o| MediaPolicy { outside: Some(o), ..MediaPolicy::default() });
        p
    }

    const URL: &str = "/tmp/sqmp-rules/Film/Film.sqproj";

    #[test]
    fn folders_follow_the_project_folder_layout() {
        let url = Path::new(URL);
        assert_eq!(MediaManagement::imported_folder(url), Path::new("/tmp/sqmp-rules/Film/Files/Imported"));
        assert_eq!(MediaManagement::library_folder(url), Path::new("/tmp/sqmp-rules/Film/Files/Library"));
        let loose = Path::new("/tmp/sqmp-rules/Film.sqproj");
        assert_eq!(MediaManagement::imported_folder(loose), Path::new("/tmp/sqmp-rules/Film Files/Imported"));
        assert_eq!(MediaManagement::project_folder(Some(loose)), None);
    }

    #[test]
    fn inside_is_linked_outside_follows_the_mode() {
        let d = MediaPolicyDefaults::default();
        let url = Some(Path::new(URL));
        let inside = "/tmp/sqmp-rules/Film/Footage/a.mov";
        let outside = "/tmp/sqmp-other/a.mov";
        for mode in [None, Some(OutsideMediaMode::Copy), Some(OutsideMediaMode::Move), Some(OutsideMediaMode::Leave)] {
            assert_eq!(MediaManagement::disposition(inside, &project(mode), url, &d), Disposition::Link);
        }
        let at = |m| MediaManagement::disposition(outside, &project(m), url, &d);
        assert_eq!(at(None), Disposition::Ask, "the app default asks");
        assert_eq!(at(Some(OutsideMediaMode::Copy)), Disposition::Apply(ImportMode::Copy));
        assert_eq!(at(Some(OutsideMediaMode::Move)), Disposition::Apply(ImportMode::Move));
        assert_eq!(at(Some(OutsideMediaMode::Leave)), Disposition::Link);
        let copy_default = MediaPolicyDefaults { outside: OutsideMediaMode::Copy, ..d };
        assert_eq!(
            MediaManagement::disposition(outside, &project(None), url, &copy_default),
            Disposition::Apply(ImportMode::Copy)
        );
    }

    #[test]
    fn unsaved_and_loose_projects_never_ask() {
        let d = MediaPolicyDefaults::default();
        let p = project(Some(OutsideMediaMode::Ask));
        assert_eq!(MediaManagement::disposition("/x/a.mov", &p, None, &d), Disposition::Link);
        let loose = Some(Path::new("/tmp/sqmp-rules/Film.sqproj"));
        assert_eq!(MediaManagement::disposition("/x/a.mov", &p, loose, &d), Disposition::Stay);
        let leave = project(Some(OutsideMediaMode::Leave));
        assert_eq!(MediaManagement::disposition("/x/a.mov", &leave, loose, &d), Disposition::Link);
        let mut old = project(None);
        old.import_mode = Some(ImportMode::Copy);
        assert_eq!(MediaManagement::disposition("/x/a.mov", &old, loose, &d), Disposition::Apply(ImportMode::Copy));
    }

    /// FINAL-LIN-5 row 1: the question must come only where its answer can be done, whatever the layout or setting.
    #[test]
    fn a_question_or_an_applied_copy_needs_a_project_folder() {
        let d = MediaPolicyDefaults::default();
        let layouts = [
            ("/tmp/sqmp-rules/Film/Film.sqproj", true),
            ("/tmp/sqmp-rules/Film/Untitled Project.sqproj", false), // a `Files` folder beside it changes nothing
            ("/tmp/sqmp-rules/Film.sqproj", false),
            ("Film.sqproj", false),
        ];
        for (url, in_folder) in layouts {
            for outside in
                [None, Some(OutsideMediaMode::Ask), Some(OutsideMediaMode::Copy), Some(OutsideMediaMode::Move)]
            {
                let got = MediaManagement::disposition("/x/a.mov", &project(outside), Some(Path::new(url)), &d);
                assert_eq!(MediaManagement::project_folder(Some(Path::new(url))).is_some(), in_folder, "{url}");
                assert_eq!(
                    matches!(got, Disposition::Ask | Disposition::Apply(_)),
                    in_folder,
                    "{url} {outside:?}: {got:?}"
                );
            }
        }
    }
}
