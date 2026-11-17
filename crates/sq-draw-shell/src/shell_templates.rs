// Swift: ShellTemplates.swift
//! Rename and Delete of a saved template (the Mac `renameTemplate` / `templateStore.delete` behind the start window's
//! card menu). Built-in templates have neither.

use crate::shell_dialog::{ShellDialog, Tone};
use crate::shell_flows::ShellRoot;
use crate::shell_form::{Row, ShellForm};
use crate::shell_host::ShellHost;
use sq_core_project::project_template::{ProjectTemplate, TemplateError};
use sq_core_time::SequentialIds;
use sq_runtime::UiRef;
use sq_uikit::localization::SQL10n;
use sq_uikit::sqdialog_model::{SQDialogResponse, SQDialogRole};

/// `TemplateError` has no `Error` impl: the text is its message or the rule that failed.
pub(crate) fn template_error_text(e: TemplateError) -> String {
    match e {
        TemplateError::Io(m) => m,
        TemplateError::Invalid(i) => i.to_string(),
    }
}

impl ShellHost {
    /// The saved template with `id`.
    fn saved_template(&self, id: &str) -> Option<ProjectTemplate> {
        let folder = self.template_folder.as_ref()?;
        folder.load(&mut SequentialIds::default()).into_iter().find(|t| t.id == id)
    }

    fn reload_start(&mut self) {
        let folder = self.template_folder.as_ref();
        if let Some(s) = self.start.as_mut() {
            s.reload(self.recents.entries(), folder);
        }
    }

    /// One name field; a blank or unchanged name changes nothing.
    pub async fn rename_template<R: ShellRoot + ?Sized>(h: UiRef<R>, id: String) {
        let Some(Some((t, d))) = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let t = shell.saved_template(&id)?;
            let mut d = ShellDialog::new("Rename Template", "");
            d.form = Some(Box::new(ShellForm::new(vec![Row::field("name", "Name", &t.name)])));
            d.add_button("Rename", SQDialogRole::Default, false);
            d.add_button("Cancel", SQDialogRole::Cancel, false);
            Some((t, d))
        }) else {
            return;
        };
        if Self::ask(&h, d).await != Some(SQDialogResponse::FIRST) {
            return;
        }
        let _ = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let Some(form) = shell.take_answered_form() else { return };
            let typed = form.text("name").unwrap_or_default().trim_matches([' ', '\t']).to_string();
            if typed.is_empty() || typed == t.name {
                return;
            }
            let Some(folder) = &shell.template_folder else { return };
            match folder.rename(&t, &typed) {
                Ok(_) => shell.reload_start(),
                Err(e) => {
                    shell.present_message("Could not rename the template", &template_error_text(e), Some(Tone::Error))
                }
            }
        });
    }

    /// Deletes the template's file right away, as the Mac does (no confirmation; the projects made from it stay).
    pub async fn delete_template<R: ShellRoot + ?Sized>(h: UiRef<R>, id: String) {
        let _ = h.with(|r| {
            let shell = &mut *r.shell_parts().shell;
            let Some(t) = shell.saved_template(&id) else { return };
            let Some(folder) = &shell.template_folder else { return };
            if let Err(e) = folder.delete(&t) {
                shell.present_message("Could not delete the template", &template_error_text(e), Some(Tone::Error));
                return;
            }
            shell.reload_start();
            shell.flash(&SQL10n::format("Deleted the template “%@”.", &[&t.name]));
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::shell_dialog::FormValue;
    use crate::shell_live::test_rig::{answer_swept, type_into};
    use crate::tests::Rig;
    use sq_core_project::project_template::TemplateFolder;
    use sq_core_time::Time;

    #[test]
    fn saved_templates_rename_and_delete() {
        let rig = Rig::new();
        let dir = std::env::temp_dir().join(format!("sq-shell-tpl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let folder = TemplateFolder::new(&dir);
        let mut format = sq_core_model::SequenceFormat::new(Time::new(1, 30));
        format.width = 1080;
        format.height = 1920;
        let t = ProjectTemplate::new("user-a", "Old", "", format);
        folder.save(&t).expect("save");
        rig.with(|r| r.shell.template_folder = Some(TemplateFolder::new(&dir)));
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::RenameTemplate("user-a".into())));
        rig.run_flows();
        type_into(&rig, "name", FormValue::Text("Reels".into()));
        answer_swept(&rig, SQDialogResponse::FIRST);
        let names = || folder.load(&mut SequentialIds::default()).into_iter().map(|t| t.name).collect::<Vec<_>>();
        assert_eq!(names(), ["Reels"]);
        rig.with(|r| r.shell.start_flow(crate::ShellFlow::DeleteTemplate("user-a".into())));
        rig.run_flows();
        assert!(names().is_empty());
    }
}
