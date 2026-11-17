// SPDX-License-Identifier: GPL-3.0-or-later
// Swift: RelinkScoringTests.swift

use super::*;
use sq_core_model::MediaFingerprint;
use sq_core_time::Timestamp;

fn id_of(name: &str, path: &str) -> Id {
    // Distinct ids from the path, stable between runs.
    Id::from_u128(name.bytes().chain(path.bytes()).fold(1u128, |a, b| a.wrapping_mul(131).wrapping_add(u128::from(b))))
}

fn reference(name: &str, size: i64, seconds: Option<i64>, path: &str, modified: Option<Timestamp>) -> MediaRef {
    let full = format!("{path}/{name}");
    let mut m = MediaRef::new(id_of(name, path), name, &full, MediaFingerprint { size, modified, head_hash: None });
    m.duration = seconds.map(Time::seconds);
    m
}

fn ref_(name: &str) -> MediaRef {
    reference(name, 100, Some(10), "/gone/Day1", None)
}

fn cand(path: &str, size: i64, seconds: Option<i64>, modified: Option<Timestamp>) -> RelinkCandidate {
    RelinkCandidate { path: path.into(), size, modified, duration: seconds.map(Time::seconds) }
}

fn cand10(path: &str) -> RelinkCandidate {
    cand(path, 100, Some(10), None)
}

#[test]
fn name_size_and_length_is_a_strong_checked_match() {
    let a = ref_("C0101.MP4");
    let r = RelinkScorer::propose(&[a], &[cand10("/new/c0101.mp4")]);
    assert_eq!(r.proposals.len(), 1);
    let p = &r.proposals[0];
    assert!(p.path == "/new/c0101.mp4" && p.tier() == Tier::Strong && p.is_checked());
    assert!(
        p.signals.contains(Signals::NAME) && p.signals.contains(Signals::SIZE) && p.signals.contains(Signals::DURATION)
    );
    assert!(r.unmatched.is_empty());
}

#[test]
fn equal_size_tie_is_decided_by_more_signals_not_by_order() {
    let when = Timestamp::from_unix_seconds(1_000_000.0);
    let a = reference("A.mov", 100, Some(10), "/gone/Day1", Some(when));
    let plain = cand10("/x/A.mov");
    let better = cand("/y/A.mov", 100, Some(10), Some(when));
    for order in [[plain.clone(), better.clone()], [better, plain]] {
        let r = RelinkScorer::propose(std::slice::from_ref(&a), &order);
        assert_eq!(r.proposals.first().map(|p| p.path.as_str()), Some("/y/A.mov"));
        assert!(r.proposals[0].signals.contains(Signals::MODIFIED));
    }
}

#[test]
fn full_tie_stays_deterministic_but_is_not_checked() {
    let a = ref_("A.mov");
    let (one, two) = (cand10("/q/1/A.mov"), cand10("/q/2/A.mov"));
    let r1 = RelinkScorer::propose(std::slice::from_ref(&a), &[one.clone(), two.clone()]);
    let r2 = RelinkScorer::propose(std::slice::from_ref(&a), &[two, one]);
    assert_eq!(r1.proposals[0].path, "/q/1/A.mov");
    assert_eq!(r2.proposals[0].path, "/q/1/A.mov");
    assert!(r1.proposals[0].is_ambiguous && !r1.proposals[0].is_checked());
}

#[test]
fn folder_structure_breaks_the_tie() {
    let a = reference("A.mov", 100, Some(10), "/Volumes/Old/Shoot/Day2", None);
    let r = RelinkScorer::propose(&[a], &[cand10("/n/Other/A.mov"), cand10("/n/Shoot/Day2/A.mov")]);
    assert_eq!(r.proposals[0].path, "/n/Shoot/Day2/A.mov");
    assert!(r.proposals[0].is_checked());
}

#[test]
fn renamed_copy_with_same_length_is_weak_and_unchecked() {
    let a = reference("intro.mov", 500, Some(10), "/gone/Day1", None);
    let r = RelinkScorer::propose(&[a], &[cand("/n/intro (1).mov", 777, Some(10), None)]);
    let p = &r.proposals[0];
    assert_eq!(p.path, "/n/intro (1).mov");
    assert!(p.tier() == Tier::Weak && !p.is_checked());
    assert!(!p.signals.contains(Signals::SIZE));
}

#[test]
fn same_name_other_size_never_strong() {
    let a = ref_("A.mov");
    let r = RelinkScorer::propose(&[a], &[cand("/n/A.mov", 999, Some(10), None)]);
    assert_eq!(r.proposals[0].tier(), Tier::Weak);
}

#[test]
fn unrelated_file_is_not_proposed() {
    let a = ref_("A.mov");
    let r = RelinkScorer::propose(std::slice::from_ref(&a), &[cand("/n/Z.mov", 5, Some(99), None)]);
    assert!(r.proposals.is_empty());
    assert_eq!(r.unmatched, [a.id]);
}

#[test]
fn one_file_serves_one_media_item() {
    let a = reference("A.mov", 100, Some(10), "/gone/Day1", None);
    let b = reference("A.mov", 100, Some(10), "/gone/Day2", None);
    let r = RelinkScorer::propose(&[a, b.clone()], &[cand10("/n/Day2/A.mov")]);
    assert!(r.proposals.len() == 1 && r.unmatched.len() == 1);
    assert_eq!(r.proposals[0].media_id, b.id);
}

#[test]
fn unknown_recorded_size_name_only_is_weak_but_name_and_length_is_strong() {
    let a = reference("A.mov", 0, Some(10), "/gone/Day1", None);
    let name_only = RelinkScorer::propose(std::slice::from_ref(&a), &[cand("/n/A.mov", 100, None, None)]);
    assert_eq!(name_only.proposals[0].tier(), Tier::Weak);
    let with_length = RelinkScorer::propose(&[a], &[cand10("/n/A.mov")]);
    assert_eq!(with_length.proposals[0].tier(), Tier::Strong);
}

#[test]
fn worth_probing_only_for_name_or_size_hits() {
    let a = ref_("A.mov");
    assert!(RelinkScorer::worth_probing(&cand("/n/A.mov", 5, Some(10), None), std::slice::from_ref(&a)));
    assert!(RelinkScorer::worth_probing(&cand("/n/zzz.mov", 100, Some(10), None), std::slice::from_ref(&a)));
    assert!(!RelinkScorer::worth_probing(&cand("/n/zzz.mov", 5, Some(10), None), &[a]));
}

#[test]
fn health_counts_folder_outside_and_missing() {
    let inside = reference("a.mov", 100, Some(10), "/P/Show/Files", None);
    let outside = reference("b.mov", 100, Some(10), "/Users/x", None);
    let gone = reference("c.mov", 100, Some(10), "/Users/y", None);
    let in_show = |p: &str| p.starts_with("/P/Show/");
    let offline = BTreeSet::from([gone.id]);
    let h = ProjectHealth::make(&[inside.clone(), outside.clone(), outside.clone(), gone], &offline, Some(&in_show));
    assert!(h.in_folder == 1 && h.outside == 1 && h.missing == 1 && !h.is_healthy());
    assert!(ProjectHealth::make(&[inside], &BTreeSet::new(), Some(&in_show)).is_healthy());
    let loose = ProjectHealth::make(&[outside], &BTreeSet::new(), None);
    assert!(loose.outside == 0 && loose.is_healthy());
}

#[test]
fn stem_removes_copy_suffixes() {
    assert_eq!(RelinkScorer::stem_of("/a/Intro (1).mov"), "intro");
    assert_eq!(RelinkScorer::stem_of("/a/intro copy.mov"), "intro");
    assert_eq!(RelinkScorer::stem_of("C:\\a\\x_copy.mov"), "x");
    assert_eq!(RelinkScorer::stem_of("/a/.hidden"), ".hidden");
    assert_eq!(RelinkScorer::stem_of("/a/clip (x).mov"), "clip (x)");
}

#[test]
fn found_text_pluralizes() {
    let r = RelinkScorerResult::default();
    assert_eq!(r.found_text(1), "Found 0 of 1 missing file");
    assert_eq!(r.found_text(12), "Found 0 of 12 missing files");
}
