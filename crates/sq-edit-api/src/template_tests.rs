//! Title templates through the router: list, save, insert (fields, duration, dry run) and the refusals.

use crate::edit_apirouter::tests::FakeHost;
use crate::edit_apirouter::{EditAPIConfig, EditAPIHost, EditAPIRouter, HostError};
use crate::edit_transaction::fixture::Fixture;
use crate::edit_transaction::{HostCommit, TransactionError};
use crate::http::HTTPRequest;
use crate::template_ops::TemplateInfo;
use serde_json::{Value, json};
use sq_core_edit::title_template::TitleTemplateExt as _;
use sq_core_model::{
    Clip, GeneratorRef, Project, SequenceFormat, SlotValue, TemplateFieldKind, Timeline, TitleTemplate, Track,
    TrackKind,
};
use sq_core_time::{Id, SequentialIds, Time, TimeRange};
use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::AtomicBool;

/// A one-layer text template ("Hello", 5 s) captured the way Save as Template does.
fn template() -> TitleTemplate {
    let payload = json!({"template": {"text": "Hello", "name": "T",
        "style": {"fontName": "Inter", "size": 80.0, "color": {"red": 1.0, "green": 1.0, "blue": 1.0, "alpha": 1.0}}}});
    let mut clip = Clip::new(
        Id::from_u128(1),
        "text",
        Id::from_u128(501),
        TrackKind::Video,
        TimeRange::new(Time::ZERO, Time::new(5, 1)),
        Time::new(10, 1),
    );
    clip.generator = Some(GeneratorRef {
        kind: "text".into(),
        payload: serde_json::to_vec(&payload).unwrap_or_default(),
        payload_version: 1,
    });
    let mut ids = SequentialIds::default();
    let mut track = Track::new(Id::from_u128(60), TrackKind::Video);
    assert!(track.overwrite(clip, &mut ids).is_ok());
    let tl = Timeline::new(Id::from_u128(50), "S", SequenceFormat::new(Time::new(1, 30)), vec![track]);
    let p = Project::new(Id::from_u128(999), "P", vec![], vec![tl]);
    TitleTemplate::capture(&[Id::from_u128(1)], Id::from_u128(50), &p, "Hello Title", &[], &mut ids)
        .unwrap_or_else(|e| panic!("capture: {e:?}"))
}

type SavedTemplate = (Vec<Id>, String, Option<String>);

/// The plain fake host plus a template library of one entry, in folder "Titles/Social".
struct TemplateHost {
    base: Arc<FakeHost>,
    template: TitleTemplate,
    saved: std::sync::Mutex<Vec<SavedTemplate>>,
}

impl EditAPIHost for TemplateHost {
    fn project(&self) -> Option<Project> {
        self.base.project()
    }
    fn active_sequence(&self) -> Option<Id> {
        self.base.active_sequence()
    }
    fn run(&self, r: &HostCommit, cancel: &AtomicBool) -> Result<(Project, Project), TransactionError> {
        self.base.run(r, cancel)
    }
    fn undo(&self, accept: &dyn Fn(&str) -> bool) -> bool {
        self.base.undo(accept)
    }
    fn templates(&self) -> Vec<TemplateInfo> {
        vec![TemplateInfo {
            id: Id::from_u128(77).to_string(),
            name: self.template.name.clone(),
            folder: Some("Titles/Social".into()),
            fields: self.template.fields(),
        }]
    }
    fn template(&self, id_or_name: &str) -> Option<TitleTemplate> {
        let known = id_or_name == Id::from_u128(77).to_string() || id_or_name.eq_ignore_ascii_case(&self.template.name);
        known.then(|| self.template.clone())
    }
    fn save_template(&self, clips: Vec<Id>, name: String, folder: Option<String>) -> Result<Id, HostError> {
        if clips.contains(&Id::from_u128(13)) {
            return Err(HostError::new(422, "Select the title layers first."));
        }
        self.saved.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push((clips, name, folder));
        Ok(Id::from_u128(78))
    }
}

struct Rig {
    f: Fixture,
    host: Arc<TemplateHost>,
    router: EditAPIRouter,
}

fn rig() -> Rig {
    let f = Fixture::new();
    let host = Arc::new(TemplateHost { base: FakeHost::new(&f), template: template(), saved: Default::default() });
    let router = EditAPIRouter::new(EditAPIConfig::new("tok".into(), 4321), Arc::<TemplateHost>::clone(&host));
    Rig { f, host, router }
}

fn call(r: &Rig, method: &str, path: &str, body: &Value) -> (u16, Value) {
    let headers: HashMap<String, String> =
        [("host".to_string(), "127.0.0.1:4321".to_string()), ("authorization".to_string(), "Bearer tok".to_string())]
            .into();
    let req = HTTPRequest {
        method: method.into(),
        path: path.into(),
        query: String::new(),
        headers,
        body: if body.is_null() { Vec::new() } else { body.to_string().into_bytes() },
    };
    let resp = r.router.handle(&req, &AtomicBool::new(false));
    (resp.status, serde_json::from_slice(&resp.body).unwrap_or(Value::Null))
}

fn insert(r: &Rig, op: Value, dry: bool) -> (u16, Value) {
    let mut op = op;
    op["op"] = json!("insertTemplate");
    let body = json!({"sequence": r.f.seq, "dryRun": dry, "operations": [op]});
    call(r, "POST", "/v1/commit", &body)
}

fn clip_count(r: &Rig) -> usize {
    let p = r.host.project().unwrap_or_else(|| panic!("project"));
    p.timelines[0].tracks.iter().map(|t| t.clips().len()).sum()
}

fn id_of(v: &Value) -> Id {
    serde_json::from_value(v.clone()).unwrap_or_else(|e| panic!("id: {e}"))
}

fn t(seconds: i64) -> Value {
    json!({"value": seconds, "timescale": 1})
}

#[test]
fn templates_are_listed_with_their_folders_and_typed_fields() {
    let r = rig();
    let (status, body) = call(&r, "GET", "/v1/templates", &Value::Null);
    assert_eq!(status, 200);
    assert_eq!(body["folders"], json!(["Titles/Social"]));
    let fields = body["templates"][0]["fields"].as_array().cloned().unwrap_or_default();
    assert!(fields.iter().any(|f| f["kind"] == "text" && f["value"] == "Hello"), "{fields:?}");
    assert!(fields.iter().any(|f| f["kind"] == "duration" && f["value"]["seconds"] == 5.0), "{fields:?}");
    assert_eq!(call(&r, "DELETE", "/v1/templates", &Value::Null).0, 405);
}

#[test]
fn saving_a_template_passes_clips_name_and_folder_to_the_host() {
    let r = rig();
    let body = json!({"clips": [r.f.a], "name": "Mine", "folder": "Titles"});
    let (status, answer) = call(&r, "POST", "/v1/templates", &body);
    assert_eq!((status, answer["id"].clone()), (200, json!(Id::from_u128(78))));
    let saved = r.host.saved.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    assert_eq!(saved, vec![(vec![r.f.a], "Mine".to_string(), Some("Titles".to_string()))]);
    assert_eq!(call(&r, "POST", "/v1/templates", &json!({"clips": [], "name": "x"})).0, 400);
    assert_eq!(call(&r, "POST", "/v1/templates", &json!({"clips": [r.f.a], "name": " "})).0, 400);
    assert_eq!(call(&r, "POST", "/v1/templates", &json!({"clips": [r.f.a], "name": "x", "bogus": 1})).0, 400);
    let (status, refused) = call(&r, "POST", "/v1/templates", &json!({"clips": [Id::from_u128(13)], "name": "x"}));
    assert_eq!(status, 422, "{refused}");
}

#[test]
fn insert_places_one_clip_with_the_text_and_the_given_length() {
    let r = rig();
    let before = clip_count(&r);
    let fields = template().fields();
    let name = fields.iter().find(|f| f.kind == TemplateFieldKind::Text).map(|f| f.name.clone()).unwrap_or_default();
    let op = json!({"template": "Hello Title", "track": r.f.v1, "at": t(10), "duration": t(3), "fields": { name: "Welcome" }});
    let (status, body) = insert(&r, op, false);
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["applied"], true);
    assert_eq!(body["diff"]["added"].as_array().map(Vec::len), Some(1), "{body}");
    assert_eq!(body["clipsAdded"].as_array().map(Vec::len), Some(1), "{body}");
    assert_eq!(clip_count(&r), before + 1);
    let p = r.host.project().unwrap_or_else(|| panic!("project"));
    let placed = p.timelines[0].tracks.iter().find_map(|tr| tr.clip(id_of(&body["clipsAdded"][0])));
    let placed = placed.unwrap_or_else(|| panic!("clip on the track"));
    assert_eq!((placed.start, placed.timeline().duration), (Time::new(10, 1), Time::new(3, 1)));
    let texts: Vec<&SlotValue> = placed.template_slots.iter().flatten().map(|s| &s.value).collect();
    assert!(texts.contains(&&SlotValue::Text("Welcome".into())), "{texts:?}");
}

#[test]
fn insert_without_fields_uses_the_template_length_and_its_id_works_as_the_name() {
    let r = rig();
    let op = json!({"template": Id::from_u128(77).to_string(), "track": r.f.v1, "at": t(10)});
    let (status, body) = insert(&r, op, false);
    assert_eq!(status, 200, "{body}");
    let p = r.host.project().unwrap_or_else(|| panic!("project"));
    let id = id_of(&body["clipsAdded"][0]);
    let c = p.timelines[0].tracks.iter().find_map(|tr| tr.clip(id)).unwrap_or_else(|| panic!("clip"));
    assert_eq!(c.timeline().duration, template().duration().snapped(Time::new(1, 25)));
}

#[test]
fn a_dry_run_reports_the_clip_and_changes_nothing() {
    let r = rig();
    let before = clip_count(&r);
    let (status, body) = insert(&r, json!({"template": "Hello Title", "track": r.f.v1, "at": t(10)}), true);
    assert_eq!(status, 200, "{body}");
    assert_eq!(body["applied"], false);
    assert_eq!(body["diff"]["added"].as_array().map(Vec::len), Some(1));
    assert_eq!(clip_count(&r), before);
}

#[test]
fn refusals_name_the_problem() {
    let r = rig();
    let before = clip_count(&r);
    let at = |extra: Value| {
        let mut op = json!({"template": "Hello Title", "track": r.f.v1, "at": t(10)});
        extra.as_object().into_iter().flatten().for_each(|(k, v)| op[k] = v.clone());
        op
    };
    let (status, body) = insert(&r, at(json!({"template": "Nope"})), false);
    assert_eq!(status, 404, "{body}");
    assert_eq!(body["operationIndex"], 0);
    let text_field = template().fields().into_iter().find(|f| f.kind == TemplateFieldKind::Text).map(|f| f.name);
    let name = text_field.unwrap_or_default();
    let (status, body) = insert(&r, at(json!({"fields": { name.clone(): 5 }})), false);
    assert_eq!(status, 400, "{body}");
    assert!(body["error"].as_str().is_some_and(|e| e.contains("takes a string")), "{body}");
    let (status, body) = insert(&r, at(json!({"fields": {"Nope": "x"}})), false);
    assert_eq!(status, 400, "{body}");
    assert!(body["error"].as_str().is_some_and(|e| e.contains("known fields") && e.contains(&name)), "{body}");
    let (status, body) = insert(&r, at(json!({"fields": [1]})), false);
    assert_eq!(status, 400, "{body}");
    let (status, body) = insert(&r, at(json!({"track": r.f.a1})), false);
    assert_eq!(status, 422, "an audio track: {body}");
    let (status, body) = insert(&r, at(json!({"track": Id::from_u128(4242)})), false);
    assert_eq!(status, 422, "no such track: {body}");
    assert_eq!(clip_count(&r), before, "a refusal changes nothing");
}
