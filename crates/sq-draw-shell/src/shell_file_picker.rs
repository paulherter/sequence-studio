// Swift: ShellHost.swift (`ShellFilePicker`) and its default methods in ShellShortcuts, ShellMenuActions, ShellRelink,
// ShellLocate, ShellInterchange.swift
//! The platform's file choosers (the Mac `NSOpenPanel` / `NSSavePanel`, Windows `IFileOpenDialog` / `IFileSaveDialog`).
//! Swift's `async` methods return a [`ModalAsk`] here: the platform opens its dialog and answers the ask when it
//! closes, the flow awaits it outside the root borrow. `None` (or an empty list) = the user canceled.

use sq_runtime::{ModalAsk, modal};
use std::path::{Path, PathBuf};

/// An ask that is already answered: what a chooser the platform does not offer returns.
pub fn answered<T>(value: T) -> ModalAsk<T> {
    let (ask, answer) = modal();
    answer.answer(value);
    ask
}

/// The platform's file choosers.
pub trait ShellFilePicker {
    /// File > Open: a project file.
    fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>>;
    /// Save As and Save a Copy: where the project goes.
    fn choose_save_location(&mut self, suggested_name: &str, prompt: &str) -> ModalAsk<Option<PathBuf>>;
    /// File > Import: media files.
    fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>>;
    /// Keyboard Shortcuts > Import Shortcuts: a .kys, .commandset, Resolve layout or .sqkeys file. Default: not
    /// offered.
    fn choose_shortcut_file(&mut self) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    /// Keyboard Shortcuts > Export Current Set: where the .sqkeys file goes. Default: not offered.
    fn choose_shortcut_export_location(&mut self, _suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    /// File > Project > Style Kit import (`save` false) and export (`.sqstyle`). Default: not offered.
    fn choose_style_kit(&mut self, _save: bool, _suggested_name: &str) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    /// Reconnect Media's folder to search. Default: no folder chooser.
    fn choose_folder(&mut self, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    /// Project panel Locate… and Replace Media…: one file, opening in `directory`. Default: no file chooser.
    fn choose_file(&mut self, _prompt: &str, _directory: Option<&Path>) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
    /// File > Export EDL / XML / FCPXML / OpenTimelineIO: where the file goes. Default: not offered.
    /// An HTTPS GET for the update check (`UpdateCheck.check`'s fetch); `None` = it failed or the platform has none.
    fn fetch(&mut self, _url: &str) -> ModalAsk<Option<Vec<u8>>> {
        answered(None)
    }
    fn choose_export_location(
        &mut self,
        _suggested_name: &str,
        _file_extension: &str,
        _prompt: &str,
    ) -> ModalAsk<Option<PathBuf>> {
        answered(None)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_runtime::testing::Rt;
    use std::cell::RefCell;
    use std::rc::Rc;

    /// Opens a "dialog" per ask and keeps its answer end, like a platform picker.
    #[derive(Default)]
    struct Pending(Vec<sq_runtime::ModalAnswer<Option<PathBuf>>>);
    impl ShellFilePicker for Pending {
        fn choose_project(&mut self) -> ModalAsk<Option<PathBuf>> {
            let (ask, answer) = modal();
            self.0.push(answer);
            ask
        }
        fn choose_save_location(&mut self, _suggested_name: &str, _prompt: &str) -> ModalAsk<Option<PathBuf>> {
            answered(None)
        }
        fn choose_media(&mut self) -> ModalAsk<Vec<PathBuf>> {
            answered(Vec::new())
        }
    }

    #[test]
    fn a_flow_awaits_the_platform_dialog() {
        let rt = Rt::manual();
        let mut picker = Pending::default();
        let ask = picker.choose_project();
        let got = Rc::new(RefCell::new(None));
        let g = Rc::clone(&got);
        sq_runtime::spawn_local(async move {
            *g.borrow_mut() = Some(ask.await);
        });
        rt.run_until_stalled();
        assert!(got.borrow().is_none());
        assert!(picker.0[0].answer(Some(PathBuf::from("/a.sqproj"))));
        rt.run_until_stalled();
        assert_eq!(*got.borrow(), Some(Some(PathBuf::from("/a.sqproj"))));
    }

    #[test]
    fn choosers_the_platform_does_not_offer_answer_none_at_once() {
        let rt = Rt::manual();
        let mut picker = Pending::default();
        let asks = vec![
            picker.choose_shortcut_file(),
            picker.choose_shortcut_export_location("Keys"),
            picker.choose_style_kit(true, "Kit"),
            picker.choose_folder("Search"),
            picker.choose_file("Locate", None),
            picker.choose_export_location("Cut", "edl", "Export"),
        ];
        let got = Rc::new(RefCell::new(Vec::new()));
        let g = Rc::clone(&got);
        sq_runtime::spawn_local(async move {
            for a in asks {
                let v = a.await;
                g.borrow_mut().push(v);
            }
        });
        rt.run_until_stalled();
        assert_eq!(*got.borrow(), vec![None; 6]);
    }
}
