//! Port of `ShellHost.ask / confirmDiscardChanges / saveDocument / saveDocumentAs / presentMessage / presentError`
//! (Packages/SQDrawShell/.../ShellHost.swift:499-601) with `SaveChangesPrompt` (SQUIKit/SaveChangesPrompt.swift).
use super::Log;
use super::session::{SaveError, Session};
use crate::{ModalAnswer, modal, spawn_local};
use std::cell::RefCell;
use std::rc::Rc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Response {
    First,
    Second,
    Third,
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Choice {
    Save,
    Cancel,
    DontSave,
}
impl Choice {
    pub fn from(r: Response) -> Choice {
        match r {
            Response::First => Choice::Save,
            Response::Third => Choice::DontSave,
            _ => Choice::Cancel,
        }
    }
    /// `SaveChangesPrompt.outcome(...) == .proceed`
    pub fn proceeds(self, save_succeeded: Option<bool>) -> bool {
        match self {
            Choice::DontSave => true,
            Choice::Cancel => false,
            Choice::Save => save_succeeded == Some(true),
        }
    }
}
pub struct Dialog {
    pub title: String,
    pub informative: String,
    pub buttons: Vec<String>,
    answer: ModalAnswer<Response>,
}

pub struct Host {
    pub session: Rc<Session>,
    pub log: Log,
    pub dialog: RefCell<Option<Dialog>>,
    /// Pending file-chooser (a second kind of modal wait: `files?.chooseSaveLocation`).
    panel: RefCell<Option<ModalAnswer<Option<String>>>>,
    /// Dialogs that were shown, in order (title), for assertions.
    pub shown: RefCell<Vec<String>>,
}
impl Host {
    pub fn new(session: Rc<Session>, log: Log) -> Rc<Self> {
        Rc::new(Host { session, log, dialog: RefCell::new(None), panel: RefCell::new(None), shown: RefCell::default() })
    }

    /// `ShellHost.ask`: menu dismissed, dialog shown, suspend until the user clicks.
    pub async fn ask(self: &Rc<Self>, title: &str, informative: &str, buttons: &[&str]) -> Response {
        self.log.push("menu.dismiss");
        let (ask, answer) = modal::<Response>();
        self.shown.borrow_mut().push(title.into());
        *self.dialog.borrow_mut() = Some(Dialog {
            title: title.into(),
            informative: informative.into(),
            buttons: buttons.iter().map(|s| s.to_string()).collect(),
            answer,
        });
        self.log.push(format!("dialog.show:{title}"));
        ask.await
    }
    /// UI side: the user clicked button `r` (`d.completion`: clear the dialog, resume the continuation).
    pub fn click(&self, r: Response) -> bool {
        let d = self.dialog.borrow_mut().take();
        match d {
            Some(d) => {
                self.log.push("dialog.close");
                d.answer.answer(r)
            }
            None => false,
        }
    }

    async fn choose_save_url(self: &Rc<Self>) -> Option<String> {
        let (ask, answer) = modal::<Option<String>>();
        *self.panel.borrow_mut() = Some(answer);
        self.log.push("panel.show");
        let mut url = ask.await?;
        if !url.ends_with(".sqproj") {
            url.push_str(".sqproj");
        }
        Some(url)
    }
    /// UI side: the file chooser returned `url` (None = canceled).
    pub fn panel_choose(&self, url: Option<&str>) -> bool {
        match self.panel.borrow_mut().take() {
            Some(a) => a.answer(url.map(String::from)),
            None => false,
        }
    }

    pub fn present_message(self: &Rc<Self>, title: &str, detail: &str) {
        let (me, t, d) = (self.clone(), title.to_string(), detail.to_string());
        spawn_local(async move {
            let _ = me.ask(&t, &d, &["OK"]).await;
        });
    }
    pub fn present_error(self: &Rc<Self>, title: &str, e: &SaveError) {
        self.log.push(format!("error.log:{title}"));
        self.present_message(title, &format!("{e:?}"));
    }

    pub async fn confirm_discard_changes(self: &Rc<Self>) -> bool {
        if !self.session.is_dirty() {
            return true;
        }
        let title = format!("Save changes to “{}”?", self.session.name());
        let detail = if self.session.file_url().is_some() {
            "Your changes are lost if you don’t save them."
        } else {
            "Your changes are lost if you don’t save them. This project was never saved: Save asks for a place."
        };
        let choice = Choice::from(self.ask(&title, detail, &["Save", "Cancel", "Don’t Save"]).await);
        let saved = if choice == Choice::Save { Some(self.save_document().await) } else { None };
        choice.proceeds(saved)
    }

    pub async fn save_document(self: &Rc<Self>) -> bool {
        let Some(url) = self.session.file_url() else { return self.save_document_as().await };
        self.log.push(format!("project save start: {url}"));
        match self.session.save().await {
            Ok(()) => {
                self.log.push("project save ok");
                true
            }
            Err(e) => self.report_save_error(e),
        }
    }
    pub async fn save_document_as(self: &Rc<Self>) -> bool {
        let Some(url) = self.choose_save_url().await else { return false };
        self.log.push(format!("project save as start: {url}"));
        match self.session.save_as(&url).await {
            Ok(()) => {
                self.log.push("project save as ok");
                true
            }
            Err(e) => self.report_save_error(e),
        }
    }
    fn report_save_error(self: &Rc<Self>, e: SaveError) -> bool {
        if e == SaveError::ProjectChanged {
            self.log.push("save canceled: another project was opened meanwhile");
            return false;
        }
        self.present_error("Could not save", &e);
        false
    }
}
