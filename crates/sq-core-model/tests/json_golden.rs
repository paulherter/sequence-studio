//! Serialized JSON of a real project must not change when the list types change.
use sq_core_model::Project;

const FIXTURE: &str = include_str!("../../../Packages/SQCore/Tests/Fixtures/project-v71.json");

#[test]
fn fixture_json_matches_golden() {
    let envelope: serde_json::Value = serde_json::from_str(FIXTURE).expect("fixture parses");
    let project: Project = serde_json::from_value(envelope["project"].clone()).expect("project decodes");
    let json = serde_json::to_string(&project).expect("encodes");
    if let Ok(path) = std::env::var("SQ_WRITE_GOLDEN") {
        std::fs::write(path, &json).expect("write golden");
    }
    assert_eq!(json, include_str!("golden/project-v71.json"));
}
