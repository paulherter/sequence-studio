// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: ProjectOpenRouting.swift

use sq_core_file::{FILE_EXTENSION, ProjectFileError, is_project_path};
use std::path::{Path, PathBuf};

/// What to do with a file the user asked to open (Open panel, Finder, Dock drop, start window).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProjectOpenRoute {
    /// A Sequence Studio project.
    SequenceStudioProject,
    /// A Premiere project to import.
    PremiereImport,
    /// Anything else.
    Unsupported,
    /// A file that is no project (a video, sound or picture, or any other file): imported into the open project like a
    /// drop on the window; what cannot be imported is reported by the import.
    MediaImport,
}

/// The Premiere project extension.
pub const PREMIERE_EXTENSION: &str = "prproj";

fn is_premiere(path: &Path) -> bool {
    path.extension().and_then(|e| e.to_str()).is_some_and(|e| e.to_lowercase() == PREMIERE_EXTENSION)
}

/// Where a file to open goes.
pub fn route(path: &Path) -> ProjectOpenRoute {
    if is_project_path(path) {
        return ProjectOpenRoute::SequenceStudioProject;
    }
    if is_premiere(path) {
        return ProjectOpenRoute::PremiereImport;
    }
    ProjectOpenRoute::Unsupported
}

/// [`route`] for a path the OS or the command line handed to the app: a plain file that is no project is media to
/// import (Swift `application(_:open:)` sends it to `importMixed`), never a damaged project. A folder or a path that
/// does not exist keeps the `Unsupported` answer, so the open error names it.
pub fn open_route(path: &Path) -> ProjectOpenRoute {
    match route(path) {
        ProjectOpenRoute::Unsupported if path.is_file() => ProjectOpenRoute::MediaImport,
        other => other,
    }
}

/// The project a folder chosen in a folder chooser stands for: the folder itself or its nearest ancestor that is a project
/// (by extension), so a user who navigated into a `.sqproj` still opens it. A folder holding `project.json` counts too.
/// `None` when the choice is no project. `has_project_json` is injected to keep this free of file access.
pub fn project_folder(chosen: &Path, has_project_json: impl Fn(&Path) -> bool) -> Option<PathBuf> {
    let mut url = chosen.to_path_buf();
    loop {
        if is_project_path(&url) || is_premiere(&url) {
            return Some(url);
        }
        match url.parent() {
            Some(parent) if parent != url && url.components().count() > 1 => url = parent.to_path_buf(),
            _ => break,
        }
    }
    has_project_json(chosen).then(|| chosen.to_path_buf())
}

/// Plain-language dialog text for a failed open (title, detail). `None` when the error is not one of the three
/// project-file errors the dialog knows. `file_exists` tells a path that is gone (moved, renamed, deleted) from a file or
/// folder that is there but holds no project.
pub fn message(error: &ProjectFileError, file_name: &str, file_exists: bool) -> Option<(String, String)> {
    let title = format!("Could not open \u{201C}{file_name}\u{201D}");
    let detail = match error {
        ProjectFileError::Missing if !file_exists => format!(
            "\u{201C}{file_name}\u{201D} was not found. It was moved, renamed or deleted. If it moved, choose Locate… on its card in the Recent list of the start window."
        ),
        ProjectFileError::Missing => format!(
            "This file is not a Sequence Studio project. Choose a .{FILE_EXTENSION} project, or use File > Import Premiere Project for a .{PREMIERE_EXTENSION} file."
        ),
        ProjectFileError::Corrupt => format!(
            "\u{201C}{file_name}\u{201D} is damaged. If Sequence Studio saved an autosave of it, you are offered to recover it the next time the app starts."
        ),
        ProjectFileError::NewerVersion { .. } => format!(
            "\u{201C}{file_name}\u{201D} was saved by a newer version of Sequence Studio. Update the app to open it."
        ),
        ProjectFileError::Encode(_) | ProjectFileError::Io(_) => return None,
    };
    Some((title, detail))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_that_is_gone_is_called_missing_not_a_non_project() {
        let (_, gone) = message(&ProjectFileError::Missing, "Film.sqproj", false).unwrap_or_default();
        assert!(gone.contains("was not found") && gone.contains("Locate"), "{gone}");
        assert!(!gone.contains("not a Sequence Studio project"), "{gone}");
        let (_, there) = message(&ProjectFileError::Missing, "Film.sqproj", true).unwrap_or_default();
        assert!(there.contains("not a Sequence Studio project"), "{there}");
    }

    #[test]
    fn routes_by_extension() {
        assert_eq!(route(Path::new("/a/Film.sqproj")), ProjectOpenRoute::SequenceStudioProject);
        assert_eq!(route(Path::new("/a/Film.SSPROJ")), ProjectOpenRoute::SequenceStudioProject);
        assert_eq!(route(Path::new("/a/Cut.PRPROJ")), ProjectOpenRoute::PremiereImport);
        assert_eq!(route(Path::new("/a/notes.txt")), ProjectOpenRoute::Unsupported);
    }

    #[test]
    fn a_media_file_is_imported_not_opened_as_a_project() {
        let dir = std::env::temp_dir().join(format!("sq-open-route-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap_or_default();
        let movie = dir.join("clip.mp4");
        std::fs::write(&movie, b"x").unwrap_or_default();
        let project = dir.join("Film.sqproj");
        std::fs::write(&project, b"x").unwrap_or_default();
        assert_eq!(open_route(&movie), ProjectOpenRoute::MediaImport);
        assert_eq!(
            open_route(&project),
            ProjectOpenRoute::SequenceStudioProject,
            "a project is opened, never imported"
        );
        assert_eq!(open_route(&dir), ProjectOpenRoute::Unsupported, "a folder is no media file");
        assert_eq!(open_route(&dir.join("missing.mov")), ProjectOpenRoute::Unsupported);
        assert_eq!(open_route(Path::new("/a/Cut.prproj")), ProjectOpenRoute::PremiereImport);
        std::fs::remove_dir_all(&dir).unwrap_or_default();
    }

    #[test]
    fn a_folder_inside_a_project_opens_the_project() {
        let inside = Path::new("/a/Film.sqproj/media");
        assert_eq!(project_folder(inside, |_| false), Some(PathBuf::from("/a/Film.sqproj")));
        assert_eq!(project_folder(Path::new("/a/plain"), |_| true), Some(PathBuf::from("/a/plain")));
        assert_eq!(project_folder(Path::new("/a/plain"), |_| false), None);
    }

    #[test]
    fn messages_name_the_file() {
        let (title, detail) = message(&ProjectFileError::Corrupt, "Film.sqproj", true).unwrap_or_default();
        assert!(title.contains("Film.sqproj") && detail.contains("damaged"));
        assert!(message(&ProjectFileError::Io("x".into()), "f", true).is_none());
    }
}
