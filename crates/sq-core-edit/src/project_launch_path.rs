//! Port of `ProjectLaunchPath.swift`: the project path among the command-line arguments of a launch.

use sq_core_file::{FILE_EXTENSION, LEGACY_FILE_EXTENSIONS};
use sq_core_model::trim_spaces;

/// Cleans one command-line argument into a project path: trims spaces and a pair of quotes (Explorer's "Open with" may
/// pass them through), drops trailing slashes or backslashes. `None` when it is not a `.sqproj` / legacy `.ssproj`
/// (case-insensitive).
pub fn launch_project_path(argument: &str) -> Option<String> {
    let mut s = trim_spaces(argument, true);
    while s.chars().count() >= 2 {
        let (Some(f), Some(l)) = (s.chars().next(), s.chars().last()) else { break };
        if f != l || (f != '"' && f != '\'') {
            break;
        }
        s = trim_spaces(&s[f.len_utf8()..s.len() - l.len_utf8()], true);
    }
    let s = s.replace('"', "");
    let s = s.trim_end_matches(['/', '\\']);
    if s.is_empty() {
        return None;
    }
    let name = s.rsplit(['/', '\\']).next().unwrap_or(s);
    let dot = name.rfind('.').filter(|d| *d != 0)?;
    let ext = name[dot + 1..].to_lowercase();
    (ext == FILE_EXTENSION || LEGACY_FILE_EXTENSIONS.contains(&ext.as_str())).then(|| s.to_string())
}

/// The first project path among the process arguments (the program name excluded by the caller).
pub fn launch_project_path_in(arguments: &[String]) -> Option<String> {
    arguments.iter().find_map(|a| launch_project_path(a))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_spaces_and_trailing_separators_are_cleaned() {
        assert_eq!(
            launch_project_path("  \"C:\\Cuts\\My Film.sqproj\"  ").as_deref(),
            Some("C:\\Cuts\\My Film.sqproj")
        );
        assert_eq!(launch_project_path("'/a/b.SQPROJ/'").as_deref(), Some("/a/b.SQPROJ"));
        assert_eq!(launch_project_path("/old/film.ssproj").as_deref(), Some("/old/film.ssproj"));
    }

    #[test]
    fn other_files_and_empty_names_are_refused() {
        assert_eq!(launch_project_path("/a/film.mov"), None);
        assert_eq!(launch_project_path("/a/.sqproj"), None);
        assert_eq!(launch_project_path("\"\""), None);
        assert_eq!(launch_project_path("noext"), None);
    }

    #[test]
    fn the_first_project_argument_wins() {
        let args = ["--flag".to_string(), "x.mov".to_string(), "a.sqproj".to_string(), "b.sqproj".to_string()];
        assert_eq!(launch_project_path_in(&args).as_deref(), Some("a.sqproj"));
    }
}
