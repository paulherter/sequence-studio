// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: MediaPathResolverTests.swift

use super::*;
use crate::recovery::tests::TempDir;

/// A fresh folder inside a fresh folder: the resolver also searches the parent, which must not be the shared temp dir.
fn work() -> (TempDir, PathBuf) {
    let outer = TempDir::new();
    let w = outer.path().join("w");
    fs::create_dir_all(&w).unwrap();
    let w = fs::canonicalize(w).unwrap();
    (outer, w)
}

fn file(dir: &Path, rel: &str, size: usize) -> PathBuf {
    let u = dir.join(rel);
    fs::create_dir_all(u.parent().unwrap()).unwrap();
    fs::write(&u, vec![0u8; size]).unwrap();
    u
}

/// Path text the way the resolver reports it: `/` separators on every platform.
fn s(p: &Path) -> String {
    p.to_string_lossy().replace('\\', "/")
}

fn req(stored: &str) -> Request {
    Request::new(stored)
}

fn hit(path: &Path, method: Method) -> Hit {
    Hit { path: s(path), method }
}

#[test]
fn file_name_handles_posix_and_windows_paths() {
    assert_eq!(MediaPathResolver::file_name_of("/Volumes/SSD/Clips/C2117.mp4"), "C2117.mp4");
    assert_eq!(MediaPathResolver::file_name_of("D:\\Footage\\Day 1\\C2116.MP4"), "C2116.MP4");
    assert_eq!(MediaPathResolver::file_name_of("\\\\nas\\share\\a.mov"), "a.mov");
    assert_eq!(MediaPathResolver::file_name_of("C2117.mp4"), "C2117.mp4");
}

#[test]
fn stored_path_wins_when_it_exists() {
    let (_g, dir) = work();
    let f = file(&dir, "A.mov", 10);
    let hits = MediaPathResolver::new(Some(dir), vec![]).resolve(&[req(&s(&f))]);
    assert_eq!(hits.get(&s(&f)), Some(&hit(&f, Method::StoredPath)));
}

#[test]
fn media_next_to_the_moved_project_is_found() {
    // The maintainer's "s112x2": project and both clips in one folder, stored paths from another volume.
    let (_g, w) = work();
    let dir = w.join("S112 x2");
    let (a, b) = (file(&dir, "C2117.mp4", 10), file(&dir, "C2116.mp4", 10));
    file(&dir, "S112 x2.prproj", 10);
    let r = MediaPathResolver::new(Some(dir), vec![]);
    let hits = r.resolve(&[req("/Volumes/T7/S112 x2/C2117.mp4"), req("/Volumes/T7/S112 x2/C2116.mp4")]);
    assert_eq!(hits.get("/Volumes/T7/S112 x2/C2117.mp4"), Some(&hit(&a, Method::ProjectFolder)));
    assert_eq!(hits.get("/Volumes/T7/S112 x2/C2116.mp4"), Some(&hit(&b, Method::ProjectFolder)));
}

#[test]
fn windows_paths_resolve_by_file_name() {
    let (_g, dir) = work();
    let a = file(&dir, "Footage/C0001.MP4", 10);
    let hits = MediaPathResolver::new(Some(dir), vec![]).resolve(&[req("E:\\Projekte\\Footage\\C0001.MP4")]);
    assert_eq!(hits.get("E:\\Projekte\\Footage\\C0001.MP4").map(|h| h.path.clone()), Some(s(&a)));
}

#[test]
fn relative_path_is_tried_against_the_project_folder() {
    let (_g, root) = work();
    let project = root.join("Project");
    fs::create_dir_all(&project).unwrap();
    let a = file(&root, "Media/x.mov", 10);
    let request =
        Request { stored_path: "/old/Media/x.mov".into(), relative_path: Some("..\\Media\\x.mov".into()), size: None };
    let hits = MediaPathResolver::new(Some(project), vec![]).resolve(&[request]);
    assert_eq!(hits.get("/old/Media/x.mov"), Some(&hit(&a, Method::RelativePath)));
}

#[test]
fn subfolders_and_the_parent_are_searched() {
    let (_g, root) = work();
    let project = root.join("Edit");
    let deep = file(&project, "a/b/c/deep.mov", 10);
    let sibling = file(&root, "Footage/sib.mov", 10);
    let hits = MediaPathResolver::new(Some(project), vec![]).resolve(&[req("/x/deep.mov"), req("/x/sib.mov")]);
    assert_eq!(hits.get("/x/deep.mov").map(|h| h.path.clone()), Some(s(&deep)));
    assert_eq!(hits.get("/x/sib.mov").map(|h| h.path.clone()), Some(s(&sibling)));
}

#[test]
fn locate_folders_are_searched_last() {
    let ((_g1, project), (_g2, card)) = (work(), work());
    let a = file(&card, "DCIM/100/clip.mov", 10);
    let hits = MediaPathResolver::new(Some(project), vec![card]).resolve(&[req("/gone/clip.mov")]);
    assert_eq!(hits.get("/gone/clip.mov"), Some(&hit(&a, Method::SearchFolder)));
}

#[test]
fn known_size_must_match() {
    let (_g, dir) = work();
    file(&dir, "A.mov", 10);
    let request = Request { stored_path: "/gone/A.mov".into(), relative_path: None, size: Some(99) };
    assert!(MediaPathResolver::new(Some(dir), vec![]).resolve(&[request]).is_empty());
}

#[test]
fn ambiguous_names_pick_the_matching_folder_or_nothing() {
    // Camera files repeat names across cards: never guess.
    let (_g, dir) = work();
    let card2 = file(&dir, "Card2/C0001.MP4", 10);
    file(&dir, "Card1/C0001.MP4", 10);
    let r = MediaPathResolver::new(Some(dir), vec![]);
    let p = "/Volumes/X/Card2/C0001.MP4";
    assert_eq!(r.resolve(&[req(p)]).get(p).map(|h| h.path.clone()), Some(s(&card2)));
    assert!(r.resolve(&[req("/Volumes/X/Other/C0001.MP4")]).is_empty());
}

#[test]
fn name_match_is_case_insensitive() {
    let (_g, dir) = work();
    let a = file(&dir, "c2117.MP4", 10);
    let hits = MediaPathResolver::new(Some(dir), vec![]).resolve(&[req("/gone/C2117.mp4")]);
    assert_eq!(hits.get("/gone/C2117.mp4").map(|h| h.path.clone()), Some(s(&a)));
}

#[test]
fn scan_finds_wanted_names_recursively_in_several_folders() {
    let ((_g1, a), (_g2, b)) = (work(), work());
    file(&a, "x/y/z/one.mov", 5);
    file(&b, "two.MOV", 7);
    file(&b, "other.mov", 10);
    let named = BTreeSet::from(["one.mov".to_string(), "two.mov".to_string()]);
    let found = RelinkScanner::scan(&[a, b], &named);
    let names: BTreeSet<String> = found.iter().map(|c| MediaPathResolver::file_name_of(&c.path)).collect();
    assert_eq!(names, BTreeSet::from(["one.mov".to_string(), "two.MOV".to_string()]));
    assert_eq!(found.iter().find(|c| c.path.ends_with("two.MOV")).map(|c| c.size), Some(7));
}

#[test]
fn standardized_resolves_dots_lexically() {
    assert_eq!(standardized(Path::new("/a/b/../c/./d")), "/a/c/d");
    assert_eq!(standardized(Path::new("/a/../../b")), "/b");
}
