use super::*;

fn p(s: &str) -> PathBuf {
    PathBuf::from(s)
}

#[test]
fn a_finished_export_in_the_background_names_the_file_and_reveals_it() {
    let n = export_finished(&[p("/out/Film.mp4"), p("/out/B.mp4")], &[], false).unwrap();
    assert_eq!((n.title.as_str(), n.body.as_str()), ("Export finished", "Film.mp4"));
    assert_eq!(n.reveal, Some(p("/out/Film.mp4")));
}

#[test]
fn a_failure_wins_and_has_nothing_to_reveal() {
    let n = export_finished(&[p("/out/Film.mp4")], &["“A”: disk full".into()], false).unwrap();
    assert_eq!((n.title.as_str(), n.body.as_str(), n.reveal), ("Export failed", "“A”: disk full", None));
}

#[test]
fn nothing_is_posted_while_the_app_is_active_or_nothing_finished() {
    assert_eq!(export_finished(&[p("/x.mp4")], &[], true), None);
    assert_eq!(export_finished(&[], &[], false), None);
}

#[test]
fn a_click_shows_the_file_or_else_its_folder() {
    let d = std::env::temp_dir().join(format!("sq-notify-{}", std::process::id()));
    std::fs::create_dir_all(&d).unwrap();
    let f = d.join("a.mp4");
    std::fs::write(&f, b"x").unwrap();
    assert_eq!(reveal_target(&f), (f.clone(), true));
    assert_eq!(reveal_target(&d.join("gone.mp4")), (d.clone(), false));
}

#[test]
fn the_recording_notifier_keeps_what_was_posted() {
    let mut n = RecordingNotifier::default();
    let note = export_finished(&[p("/a.mp4")], &[], false).unwrap();
    n.post(&note);
    assert_eq!(n.posted, vec![note]);
}

struct Refusing(u32);
impl TryNotifier for Refusing {
    fn try_post(&mut self, _: &Notification) -> bool {
        self.0 += 1;
        false
    }
}
struct Accepting;
impl TryNotifier for Accepting {
    fn try_post(&mut self, _: &Notification) -> bool {
        true
    }
}

struct Shared(std::rc::Rc<std::cell::RefCell<Vec<Notification>>>);
impl Notifier for Shared {
    fn post(&mut self, note: &Notification) {
        self.0.borrow_mut().push(note.clone());
    }
}

#[test]
fn a_refused_toast_falls_back_to_the_balloon_and_an_accepted_one_does_not() {
    let note = Notification { title: "Export finished".into(), body: "a.mp4".into(), reveal: None };
    let seen = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let mut f = Fallback { primary: Refusing(0), fallback: Box::new(Shared(std::rc::Rc::clone(&seen))) };
    f.post(&note);
    assert_eq!((f.primary.0, seen.borrow().len()), (1, 1));
    let mut ok = Fallback { primary: Accepting, fallback: Box::new(Shared(std::rc::Rc::clone(&seen))) };
    ok.post(&note);
    assert_eq!(seen.borrow().len(), 1, "the balloon stayed quiet");
}

#[test]
fn the_toast_xml_escapes_names() {
    let note = Notification { title: "Export <done>".into(), body: "R&D \"cut\".mp4".into(), reveal: None };
    let x = toast_xml(&note);
    assert!(x.contains("<text>Export &lt;done&gt;</text>"));
    assert!(x.contains("<text>R&amp;D &quot;cut&quot;.mp4</text>"));
    assert!(x.starts_with("<toast>") && x.ends_with("</toast>"));
}
