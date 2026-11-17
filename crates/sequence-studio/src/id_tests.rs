//! The ids of a session the app opens: they must not meet the ids other parts mint (the timeline panel counts up from
//! small numbers, a project opened later holds the ids an earlier session handed out). Two clips with one id cannot be
//! selected (Controls says "No clip selected"), drawn or exported.

fn is_small(id: sq_core_time::Id) -> bool {
    id.as_u128() >> 64 == 0
}

#[test]
fn a_new_session_starts_with_random_ids_not_with_1_2_3() {
    let dir = std::env::temp_dir().join(format!("sq-id-tests-{}", std::process::id()));
    let (mut session, _) = crate::untitled_session(&dir);
    let project_ids: Vec<_> = session
        .project()
        .timelines
        .iter()
        .flat_map(|t| std::iter::once(t.id).chain(t.tracks.iter().map(|tr| tr.id)))
        .collect();
    assert!(!project_ids.is_empty());
    assert!(project_ids.iter().all(|id| !is_small(*id)), "untitled project ids: {project_ids:?}");
    let (a, b) = (session.ids.next_id(), session.ids.next_id());
    assert!(!is_small(a) && !is_small(b) && a != b, "next ids {a:?} {b:?}");
    let _ = std::fs::remove_dir_all(&dir);
}
