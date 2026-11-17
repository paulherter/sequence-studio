//! ES5 tests: the pure rules and the session verbs that need no other group (ports of the Swift tests of these files).

use std::collections::BTreeSet;

use sq_core_graphics::graphics_editing::ProjectGraphicsExt;
use sq_core_model::project_media_ops::GeneratorPlacement;
use sq_core_model::{
    CaptionItem, CaptionPosition, Clip, ClipSpeed, Project, SequenceFormat, Timeline, Track, TrackKind,
};
use sq_core_time::{Id, IdSource, SequentialIds, Time, TimeRange};
use sq_text::caption_presets::CaptionPresetLibrary;
use sq_text::caption_style_looks::CaptionStyleLooks;
use sq_transcribe::caption_segmenter::Caption;

use super::common::generator_track;
use super::*;
use crate::{EditorSession, LookRef, LookScope, LookStore, LookTarget, SessionDeps};

fn s(n: i64) -> Time {
    Time::new(n, 1)
}

fn session() -> EditorSession {
    let mut ids = SequentialIds::default();
    // two video tracks and one audio track, 30 fps
    let tl = Timeline::new(
        ids.next_id(),
        "Main",
        SequenceFormat::new(Time::new(1, 30)),
        vec![
            Track::new(ids.next_id(), TrackKind::Video),
            Track::new(ids.next_id(), TrackKind::Video),
            Track::new(ids.next_id(), TrackKind::Audio),
        ],
    );
    let project = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let mut deps = SessionDeps::headless(std::env::temp_dir().join("sq-es05-tests"));
    deps.ids = Box::new(ids);
    EditorSession::new(project, deps)
}

fn item(sess: &mut EditorSession, text: &str, a: i64, b: i64) -> CaptionItem {
    CaptionItem {
        id: sess.ids.next_id(),
        lines: vec![text.to_string()],
        range: TimeRange::from_end(s(a), s(b)),
        style_ref: "default".to_string(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    }
}

fn tracks(sess: &EditorSession) -> Vec<sq_core_model::CaptionTrack> {
    sess.active_timeline().map(|t| t.caption_tracks.clone()).unwrap_or_default()
}

// MARK: CaptionLanguageGuess (CaptionLanguageGuessTests)

fn fake_detect(text: &str) -> Option<(String, f64)> {
    let code = if text.starts_with("Heute") { "de" } else { "en" };
    Some((code.to_string(), 0.99))
}

fn supported() -> Vec<String> {
    ["de-DE", "en-US", "en-GB", "fr-FR"].iter().map(|s| s.to_string()).collect()
}

const GERMAN: &str = "Heute zeigen wir euch, wie man einen Film schneidet und dabei viel Zeit spart.";
const ENGLISH: &str = "Today we show you how to cut a film and save a lot of time while doing it.";

#[test]
fn german_text_after_english_run_picks_german() {
    let got = CaptionLanguageGuess::retry_language(GERMAN, "en-US", &supported(), &[], &fake_detect);
    assert_eq!(got.as_deref(), Some("de-DE"));
}

#[test]
fn same_language_needs_no_retry() {
    assert_eq!(CaptionLanguageGuess::retry_language(ENGLISH, "en-GB", &supported(), &[], &fake_detect), None);
}

#[test]
fn region_follows_system_language() {
    let preferred = vec!["en-GB".to_string()];
    let got = CaptionLanguageGuess::retry_language(ENGLISH, "de-DE", &supported(), &preferred, &fake_detect);
    assert_eq!(got.as_deref(), Some("en-GB"));
}

#[test]
fn short_text_is_not_trusted() {
    assert_eq!(CaptionLanguageGuess::retry_language("Hallo Welt", "en-US", &supported(), &[], &fake_detect), None);
}

#[test]
fn unsupported_language_is_skipped() {
    let only = vec!["en-US".to_string(), "fr-FR".to_string()];
    assert_eq!(CaptionLanguageGuess::retry_language(GERMAN, "en-US", &only, &[], &fake_detect), None);
}

// MARK: CaptionMapping (SpeedCaptionMappingTests)

fn one_caption(ids: &mut SequentialIds) -> Caption {
    let w = ids.next_id();
    Caption::new(vec!["hello".into()], TimeRange::new(s(11), Time::new(1, 2)), w, w, 0..1, "default", "none")
}

fn video_clip(ids: &mut SequentialIds) -> Clip {
    let id = ids.next_id();
    Clip::new(id, "c", id, TrackKind::Video, TimeRange::new(s(10), s(8)), s(100))
}

#[test]
fn sped_up_clip_maps_captions_through_the_speed() {
    let mut ids = SequentialIds::default();
    let mut clip = video_clip(&mut ids);
    clip.speed = ClipSpeed::from_percent(200.0);
    let caps = [one_caption(&mut ids)];
    let items = CaptionMapping::items(&caps, &clip, None, &mut ids);
    let src = caps[0].range;
    let it = &items[0];
    let d = src.start - s(10);
    assert_eq!(it.range.start, s(100) + Time::new(d.value(), d.timescale() * 2));
    assert_eq!(it.range.duration, Time::new(src.duration.value(), src.duration.timescale() * 2));
    assert_eq!(clip.timeline().intersection(&it.range), Some(it.range));
}

#[test]
fn reversed_clip_mirrors_the_caption_span() {
    let mut ids = SequentialIds::default();
    let mut clip = video_clip(&mut ids);
    clip.reversed = true;
    let caps = [one_caption(&mut ids)];
    let items = CaptionMapping::items(&caps, &clip, None, &mut ids);
    assert_eq!(items[0].range.end(), s(100) + (s(18) - caps[0].range.start));
    assert_eq!(items[0].range.duration, caps[0].range.duration);
}

#[test]
fn snapping_puts_ranges_on_the_frame_grid_and_drops_collapsed_ones() {
    let mut ids = SequentialIds::default();
    let fd = Time::new(1, 30);
    let mk = |a: Time, b: Time, ids: &mut SequentialIds| CaptionItem {
        id: ids.next_id(),
        lines: vec!["x".into()],
        range: TimeRange::from_end(a, b),
        style_ref: String::new(),
        animation_ref: String::new(),
        style_overridden: false,
        words: Vec::new(),
        position: None,
    };
    let items =
        [mk(Time::new(1, 100), Time::new(2, 100), &mut ids), mk(Time::new(5, 100), Time::new(50, 100), &mut ids)];
    let out = CaptionMapping::snapped(&items, fd);
    // The first collapses to one frame (the next one leaves room); both are on the grid and do not overlap.
    assert_eq!(out.len(), 2);
    assert_eq!(out[0].range.duration, fd);
    assert!(out[0].range.end() <= out[1].range.start);
    assert_eq!(out[1].range.start, out[1].range.start.snapped(fd));
}

// MARK: generator_track (GeneratorTrackPlacementTests)

struct Case {
    name: &'static str,
    busy: &'static [usize],
    locked: &'static [usize],
    expected: Option<usize>,
}

fn six_video_timeline(busy: &[usize], locked: &[usize]) -> Timeline {
    let mut ids = SequentialIds::default();
    let mut tracks: Vec<Track> = (0..6).map(|_| Track::new(ids.next_id(), TrackKind::Video)).collect();
    tracks.push(Track::new(ids.next_id(), TrackKind::Audio));
    let tl = Timeline::new(ids.next_id(), "T", SequenceFormat::new(Time::new(1, 30)), tracks);
    let tid = tl.id;
    let mut p = Project::new(ids.next_id(), "P", Vec::new(), vec![tl]);
    let ids_of: Vec<Id> = p.timelines[0].tracks.iter().map(|t| t.id).collect();
    let place = |p: &mut Project, ids: &mut SequentialIds, track: Id, at: i64, dur: i64| {
        let placement = GeneratorPlacement { timeline: tid, track, start: s(at), duration: s(dur) };
        assert!(p.add_graphics_clip(placement, Vec::new(), ids).is_ok());
    };
    for i in busy {
        place(&mut p, &mut ids, ids_of[*i], 0, 5);
    }
    place(&mut p, &mut ids, ids_of[4], 20, 2);
    for i in locked {
        p.timelines[0].tracks[*i].is_locked = true;
    }
    p.timelines.remove(0)
}

fn video_ids(t: &Timeline) -> Vec<Id> {
    t.tracks.iter().filter(|t| t.kind == TrackKind::Video).map(|t| t.id).collect()
}

#[test]
fn lowest_free_track_above_the_footage() {
    let cases = [
        Case { name: "V1 and V2 busy, V3 free", busy: &[0, 1], locked: &[], expected: Some(2) },
        Case { name: "empty sequence: V1", busy: &[], locked: &[], expected: Some(0) },
        Case { name: "only V1 busy", busy: &[0], locked: &[], expected: Some(1) },
        Case { name: "gap below footage is skipped", busy: &[2], locked: &[], expected: Some(3) },
        Case { name: "V3 locked: next free above", busy: &[0, 1], locked: &[2], expected: Some(3) },
        Case { name: "all but V6 busy: V6", busy: &[0, 1, 2, 3, 4], locked: &[], expected: Some(5) },
        Case { name: "everything busy: none qualifies", busy: &[0, 1, 2, 3, 4, 5], locked: &[], expected: None },
        Case { name: "V6 busy: nothing above it", busy: &[5], locked: &[], expected: None },
        Case { name: "locked tracks above footage", busy: &[0], locked: &[1, 2, 3, 4, 5], expected: None },
    ];
    for c in cases {
        let t = six_video_timeline(c.busy, c.locked);
        let video = video_ids(&t);
        let got = generator_track(&t, TimeRange::new(s(1), s(3)), None, false);
        assert_eq!(got, c.expected.map(|i| video[i]), "{}", c.name);
    }
}

#[test]
fn overwrite_fallback_is_the_topmost_unlocked_track() {
    let t = six_video_timeline(&[0, 1, 2, 3, 4, 5], &[5]);
    assert_eq!(generator_track(&t, TimeRange::new(s(1), s(3)), None, true), Some(video_ids(&t)[4]));
}

#[test]
fn a_preferred_video_track_wins() {
    let t = six_video_timeline(&[0], &[]);
    let video = video_ids(&t);
    assert_eq!(generator_track(&t, TimeRange::new(s(1), s(3)), Some(video[0]), true), Some(video[0]));
}

#[test]
fn a_clip_elsewhere_in_time_does_not_raise_the_track() {
    let t = six_video_timeline(&[], &[]); // only the V5 clip at 20 s exists
    let video = video_ids(&t);
    assert_eq!(generator_track(&t, TimeRange::new(s(1), s(3)), None, true), Some(video[0]));
    assert_eq!(generator_track(&t, TimeRange::new(s(20), s(1)), None, true), Some(video[5]));
}

#[test]
fn a_new_graphic_is_selected_and_undoes_in_one_step() {
    let mut sess = session();
    let depth = sess.undo_depth();
    let id = sess.add_graphics_clip(None, None, s(4), Vec::new(), true);
    let id = id.unwrap_or_else(|| panic!("no graphic"));
    assert_eq!(sess.selection(), &BTreeSet::from([id]));
    assert!(sess.undo());
    assert_eq!(sess.undo_depth(), depth);
}

#[test]
fn a_new_graphic_lands_on_the_first_free_track_above_the_footage() {
    let mut sess = session();
    let tracks: Vec<Id> = sess.active_timeline().map(|t| t.tracks.iter().map(|t| t.id).collect()).unwrap_or_default();
    let first = sess.add_graphics_clip(None, Some(tracks[0]), s(5), Vec::new(), false);
    assert!(first.is_some());
    let id = sess.add_graphics_clip(None, None, s(2), Vec::new(), false).unwrap_or_else(|| panic!("no graphic"));
    let on_second = sess.active_timeline().is_some_and(|t| t.tracks[1].clips().iter().any(|c| c.id == id));
    assert!(on_second);
}

// MARK: caption tracks (CaptionTrackLookSessionTests, SessionCaptionTidyTests)

#[test]
fn creating_captions_makes_a_track_named_captions_1() {
    let mut sess = session();
    let a = item(&mut sess, "a", 0, 2);
    assert!(sess.add_captions(vec![a]));
    assert_eq!(tracks(&sess).iter().map(|t| t.name.clone()).collect::<Vec<_>>(), ["Captions 1"]);
    assert_eq!(sess.current_caption_track().map(|t| t.name.clone()).as_deref(), Some("Captions 1"));
}

#[test]
fn track_look_edit_changes_every_caption_of_the_track() {
    let mut sess = session();
    let items = vec![item(&mut sess, "a", 0, 2), item(&mut sess, "b", 2, 4)];
    assert!(sess.replace_captions(items));
    assert!(sess.edit_caption_style(CaptionStyleField::Size(88.0), CaptionStyleScope::All, false));
    let refs: BTreeSet<String> = tracks(&sess)[0].items().iter().map(|i| i.style_ref.clone()).collect();
    assert_eq!(refs.len(), 1);
    assert_eq!(sess.caption_style_state(CaptionStyleScope::All).map(|s| s.style.size), Some(88.0));
}

#[test]
fn selected_edit_overrides_only_that_caption_and_reset_hands_it_back() {
    let mut sess = session();
    let items = vec![item(&mut sess, "a", 0, 2), item(&mut sess, "b", 2, 4)];
    assert!(sess.replace_captions(items));
    let (a, b) = (tracks(&sess)[0].items()[0].id, tracks(&sess)[0].items()[1].id);
    sess.select(BTreeSet::new(), BTreeSet::from([b]));
    assert!(sess.edit_caption_style(CaptionStyleField::Size(120.0), CaptionStyleScope::Selected, false));
    let overridden =
        |sess: &EditorSession, id: Id| tracks(sess)[0].items().iter().find(|i| i.id == id).map(|i| i.style_overridden);
    assert_eq!(overridden(&sess, b), Some(true));
    assert_eq!(overridden(&sess, a), Some(false));
    assert!(sess.selected_captions_have_overrides());
    assert!(sess.reset_selected_captions_to_track_look());
    let after = tracks(&sess)[0].items().to_vec();
    assert!(after.iter().all(|i| !i.style_overridden));
    assert_eq!(
        after.iter().find(|i| i.id == b).map(|i| i.style_ref.clone()),
        after.iter().find(|i| i.id == a).map(|i| i.style_ref.clone())
    );
    assert!(!sess.selected_captions_have_overrides());
    assert!(sess.undo());
    assert_eq!(overridden(&sess, b), Some(true));
}

#[test]
fn a_second_track_has_its_own_look_and_leaves_the_first_alone() {
    let mut sess = session();
    let first_item = item(&mut sess, "a", 0, 2);
    assert!(sess.replace_captions(vec![first_item]));
    let second = sess.add_caption_track().unwrap_or_else(|| panic!("no second track"));
    assert_eq!(tracks(&sess).iter().map(|t| t.name.clone()).collect::<Vec<_>>(), ["Captions 1", "Captions 2"]);
    assert_eq!(sess.current_caption_track().map(|t| t.id), Some(second));
    let c = sess.add_caption_at_playhead().unwrap_or_else(|| panic!("no caption"));
    assert_eq!(tracks(&sess)[1].items().iter().map(|i| i.id).collect::<Vec<_>>(), [c]); // went to the focused track
    sess.select(BTreeSet::new(), BTreeSet::new());
    let before: Vec<String> = tracks(&sess)[0].items().iter().map(|i| i.style_ref.clone()).collect();
    assert!(sess.edit_caption_style(CaptionStyleField::Size(99.0), CaptionStyleScope::All, false));
    let after: Vec<String> = tracks(&sess)[0].items().iter().map(|i| i.style_ref.clone()).collect();
    assert_eq!(after, before);
    let t2 = tracks(&sess)[1].clone();
    assert!(t2.style_ref.contains("own-trk-"));
    assert!(t2.items().iter().all(|i| i.style_ref == t2.style_ref));
    let first_id = tracks(&sess)[0].id;
    sess.focus_caption_track(Some(first_id));
    assert_eq!(sess.current_caption_track().map(|t| t.name.clone()).as_deref(), Some("Captions 1"));
    assert_ne!(sess.caption_style_state(CaptionStyleScope::All).map(|s| s.style.size), Some(99.0));
}

#[test]
fn selecting_a_caption_switches_the_look_to_its_track() {
    let mut sess = session();
    let a = item(&mut sess, "a", 0, 2);
    assert!(sess.replace_captions(vec![a]));
    sess.add_caption_track();
    sess.add_caption_at_playhead();
    let first = tracks(&sess)[0].items()[0].id;
    sess.select(BTreeSet::new(), BTreeSet::from([first]));
    assert_eq!(sess.current_caption_track().map(|t| t.name.clone()).as_deref(), Some("Captions 1"));
}

#[test]
fn tidy_is_one_undo_step_and_undo_restores() {
    let mut sess = session();
    let mut it = item(&mut sess, "one two three four five six", 0, 3);
    it.style_ref = "default".into();
    assert!(sess.add_captions(vec![it]));
    let depth = sess.undo_depth();
    assert_eq!(sess.tidy_captions(&sq_core_audio::CaptionTidyOptions::tik_tok()), Some(2));
    let texts = |s: &EditorSession| s.caption_items().iter().map(|c| c.lines.join(" ")).collect::<Vec<_>>();
    assert_eq!(texts(&sess), ["one two three", "four five six"]);
    assert_eq!(sess.undo_depth(), depth + 1);
    assert!(sess.undo());
    assert_eq!(texts(&sess), ["one two three four five six"]);
}

#[test]
fn tidy_without_captions_explains_why() {
    let mut sess = session();
    assert_eq!(sess.tidy_captions(&sq_core_audio::CaptionTidyOptions::tik_tok()), None);
    assert!(sess.last_error().is_some());
}

#[test]
fn split_merge_and_delete_keep_the_track_valid() {
    let mut sess = session();
    let a = item(&mut sess, "hello world", 0, 4);
    assert!(sess.add_captions(vec![a]));
    assert!(sess.split_caption(Some(s(2))));
    assert_eq!(sess.caption_items().len(), 2);
    let ids: BTreeSet<Id> = sess.caption_items().iter().map(|c| c.id).collect();
    sess.select(BTreeSet::new(), ids);
    assert!(sess.merge_selected_captions());
    assert_eq!(sess.caption_items().len(), 1);
    assert!(sess.delete_selected_captions());
    assert!(sess.caption_items().is_empty());
}

#[test]
fn text_replace_counts_and_position_overrides_reset() {
    let mut sess = session();
    let a = item(&mut sess, "cat cat", 0, 2);
    let id = a.id;
    assert!(sess.add_captions(vec![a]));
    assert_eq!(sess.replace_caption_text("cat", "dog", true), Some(2));
    assert_eq!(sess.caption_item(id).map(|c| c.lines.join("")).as_deref(), Some("dog dog"));
    let p = CaptionPosition { offset_y: 0.1, ..sess.caption_position() };
    assert!(sess.set_caption_item_position(&BTreeSet::from([id]), p, false));
    assert_eq!(sess.caption_item(id).and_then(|c| c.position), Some(p));
    assert!(sess.reset_caption_positions(&sess.all_caption_ids()));
    assert_eq!(sess.caption_item(id).and_then(|c| c.position), None);
}

// MARK: style looks, style tab rules

#[test]
fn a_tile_pick_changes_the_look_and_keeps_the_animation() {
    let mut sess = session();
    let spark = CaptionStyleLooks::look("spark").cloned().unwrap_or_else(|| panic!("no spark look"));
    let wave = CaptionStyleLooks::look("wave").cloned().unwrap_or_else(|| panic!("no wave look"));
    let items = vec![item(&mut sess, "a", 0, 1), item(&mut sess, "b", 2, 3)];
    assert!(sess.replace_captions(items));
    assert!(sess.apply_caption_style_look(&spark, None));
    let animation = sess.caption_items()[0].animation_ref.clone();
    assert_eq!(animation, spark.animation_ref);
    let depth = sess.undo_depth();
    assert!(sess.apply_caption_style_look_only(&wave, None));
    assert_eq!(sess.undo_depth(), depth + 1);
    assert_eq!(
        sess.caption_items().iter().map(|c| c.style_ref.clone()).collect::<Vec<_>>(),
        vec![wave.style_ref.clone(); 2]
    );
    assert_eq!(sess.caption_items().iter().map(|c| c.animation_ref.clone()).collect::<Vec<_>>(), vec![animation; 2]);
    assert_eq!(sess.caption_karaoke(), wave.karaoke);
    assert!(sess.undo());
    assert_eq!(sess.current_caption_style_look(), Some(spark));
}

#[test]
fn a_gallery_look_sets_style_animation_and_highlight_in_one_step() {
    let mut sess = session();
    let spark = CaptionStyleLooks::look("spark").cloned().unwrap_or_else(|| panic!("no spark look"));
    assert!(!sess.apply_caption_style_look(&spark, None)); // no caption track yet
    let items = vec![item(&mut sess, "a", 0, 1), item(&mut sess, "b", 2, 3)];
    assert!(sess.replace_captions(items));
    let depth = sess.undo_depth();
    assert!(sess.apply_caption_style_look(&spark, None));
    assert_eq!(sess.undo_depth(), depth + 1);
    assert_eq!(sess.caption_items().iter().map(|c| c.style_ref.clone()).collect::<Vec<_>>(), ["tiktok", "tiktok"]);
    assert_eq!(sess.caption_items().iter().map(|c| c.animation_ref.clone()).collect::<Vec<_>>(), ["pop", "pop"]);
    assert_eq!(sess.caption_karaoke(), spark.karaoke);
    assert_eq!(sess.current_caption_style_look(), Some(spark.clone()));
    let wave = CaptionStyleLooks::look("wave").cloned().unwrap_or_else(|| panic!("no wave look"));
    assert!(sess.apply_caption_style_look(&wave, None));
    assert!(sess.caption_karaoke().is_none());
    assert_eq!(sess.current_caption_style_look().map(|l| l.id), Some("wave".to_string()));
    assert!(sess.undo());
    assert_eq!(sess.current_caption_style_look(), Some(spark));
}

#[test]
fn a_look_only_changes_its_own_track() {
    let mut sess = session();
    let a = item(&mut sess, "a", 0, 1);
    assert!(sess.replace_captions(vec![a]));
    let spark = CaptionStyleLooks::look("spark").cloned().unwrap_or_else(|| panic!("no spark look"));
    assert!(sess.apply_caption_style_look(&spark, None));
    let second = sess.add_caption_track().unwrap_or_else(|| panic!("no second track"));
    let b = item(&mut sess, "b", 2, 3);
    assert!(sess.add_captions(vec![b]));
    let pop = CaptionStyleLooks::look("pop").cloned().unwrap_or_else(|| panic!("no pop look"));
    assert!(sess.apply_caption_style_look(&pop, None)); // focused track = the new one
    let t = tracks(&sess);
    assert_eq!(t.len(), 2);
    assert!(t[1].id == second && t[1].style_ref == pop.style_ref && t[1].karaoke.is_none());
    assert!(t[0].style_ref == "tiktok" && t[0].karaoke.is_some()); // the first track kept its look
}

#[test]
fn style_fields_round_trip_through_the_text_style() {
    let lib = CaptionPresetLibrary::built_in();
    let base = CaptionStyleEdit::display_style(&lib.style(Some("default")));
    let edited = CaptionStyleEdit::apply_fields_to_style(
        &[
            CaptionStyleField::Size(77.0),
            CaptionStyleField::AllCaps(true),
            CaptionStyleField::Outline(Some(sq_text::text_style::RGBAColor::new(1.0, 0.0, 0.0, 1.0))),
            CaptionStyleField::Pill(Some(sq_text::text_style::RGBAColor::new(0.0, 0.0, 0.0, 0.5))),
        ],
        &base,
        &lib,
    );
    assert_eq!(edited.size, 77.0);
    assert!(edited.all_caps && edited.stroke.is_some() && edited.background.is_some());
    // The fields that turn base into edited, applied again, give edited back.
    let fields = CaptionStyleEdit::fields(&base, &CaptionStyleEdit::display_style(&edited));
    let again = CaptionStyleEdit::apply_fields_to_style(&fields, &base, &lib);
    assert_eq!(CaptionStyleEdit::display_style(&again), CaptionStyleEdit::display_style(&edited));
    // Turning the outline off is a field of its own.
    let off = CaptionStyleEdit::fields(&edited, &CaptionStyleEdit::display_style(&base));
    assert!(off.contains(&CaptionStyleField::Outline(None)) && off.contains(&CaptionStyleField::Pill(None)));
}

#[test]
fn kit_edits_keep_tokens_and_start_from_the_base_look() {
    let kit = CaptionStyleEdit::apply_fields_to_kit(
        &[CaptionStyleField::Look("pill".into()), CaptionStyleField::PillSize(0.5), CaptionStyleField::Size(60.0)],
        &sq_core_model::StyleKit::default(),
    );
    let spec = kit.caption.unwrap_or_else(|| panic!("no caption spec"));
    assert_eq!(spec.base_style, "pill");
    assert!(spec.uses_pill);
    assert_eq!(spec.size, Some(60.0));
    let pill = kit.pill.unwrap_or_else(|| panic!("no pill"));
    assert_eq!(pill.horizontal_em, 0.5);
}

// MARK: graphic presets, CTA card, title builder

#[test]
fn every_preset_builds_on_landscape_and_portrait_canvases() {
    let mut ids = SequentialIds::default();
    let all = GraphicPresetCatalog::all();
    assert_eq!(all.len(), 7 + 6 + 6); // stickers, lower thirds, callouts
    let unique: BTreeSet<&str> = all.iter().map(|e| e.id.as_str()).collect();
    assert_eq!(unique.len(), all.len());
    for e in &all {
        for (w, h) in [(1920, 1080), (1080, 1920)] {
            let layers = e.layers(w, h, &mut ids);
            assert!(layers.as_ref().is_ok_and(|l| !l.is_empty()), "{} {w}x{h}: {layers:?}", e.id);
        }
    }
}

#[test]
fn presets_are_found_by_every_word_of_the_query() {
    assert_eq!(GraphicPresetCatalog::matching("").len(), GraphicPresetCatalog::all().len());
    let found: Vec<String> = GraphicPresetCatalog::matching("pop FIRE").into_iter().map(|e| e.id).collect();
    assert_eq!(found, ["sticker-pop-fire"]);
    assert!(
        GraphicPresetCatalog::entry("lower-third-bar").is_some_and(|e| e.category == GraphicPresetCategory::LowerThird)
    );
    assert!(GraphicPresetCatalog::entry("nope").is_none());
}

#[test]
fn the_cta_card_pops_in_dips_when_pressed_and_comes_back() {
    assert_eq!(CTAEndCard::card_scale_at_local(Time::ZERO), 0.0);
    assert_eq!(CTAEndCard::card_scale_at_local(CTAEndCard::POP_UP), 1.1);
    assert_eq!(CTAEndCard::card_scale_at_local(CTAEndCard::POP_SETTLE), 1.0);
    assert!((CTAEndCard::card_scale_at_local(Time::new(17, 10)) - 0.9).abs() < 1e-9);
    assert_eq!(CTAEndCard::card_scale_at_local(s(10)), 1.0);
    let mut ids = SequentialIds::default();
    let layers = CTAEndCard::layers(1080, 1920, &mut ids).unwrap_or_default();
    assert_eq!(
        layers.iter().map(|l| l.name.as_str()).collect::<Vec<_>>(),
        ["Pill", "Pill Done", "Icon", "Label", "Label Done"]
    );
}

#[test]
fn the_title_has_two_lines_sized_by_the_short_side_and_no_emoji() {
    let format = SequenceFormat::new(Time::new(1, 30));
    let short = format.display_width().min(format.height) as f64;
    let parts = TitleBuilder::parts(&format);
    assert_eq!(parts.len(), 2);
    assert_eq!(parts[0].template.style.size, (short * 0.08).round());
    assert_eq!(parts.iter().map(|p| p.direction).collect::<Vec<_>>(), [Some(270.0), Some(90.0)]);
    assert!(parts[0].position.y < parts[1].position.y);
    assert!(parts.iter().all(|p| !p.template.text.contains('\u{1F525}')), "no emoji in the default title");
}

#[test]
fn a_style_kit_edit_is_one_undo_step_and_the_position_default_is_stored_as_none() {
    let mut sess = session();
    let depth = sess.undo_depth();
    let p = CaptionPosition { offset_y: 0.2, ..sess.caption_position() };
    sess.set_caption_position(p, false);
    assert_eq!(sess.caption_position(), p);
    assert_eq!(sess.undo_depth(), depth + 1);
    let default = CaptionPosition { offset_y: 0.0, ..p };
    sess.set_caption_position(default, false);
    assert_eq!(sess.project().style_kit.as_ref().and_then(|k| k.caption_position), None);
}

// MARK: Looks on the selection (EditorSession+Looks, Title)

fn text_session() -> (EditorSession, Id) {
    use sq_text::text_style::TextStyle;
    use sq_text::text_template::TextTemplate;
    let mut sess = session();
    let template = TextTemplate::new("T", "Hello", TextStyle::default());
    let Some(id) = sess.add_text_clip(&template, Some(s(0)), None, s(3), None, false) else { panic!("no text clip") };
    (sess, id)
}

#[test]
fn a_built_in_look_is_given_to_the_selected_text_and_counts_as_applied() {
    use sq_text::look::{LookLibrary, LookState};
    let (mut sess, id) = text_session();
    let store = LookStore::new(None, None, None, None);
    assert_eq!(sess.look_target(), Some(LookTarget::TextClip(id)));
    assert_eq!(sess.look_state(&store), LookState::None);
    let Some(built_in) = LookLibrary::built_ins().first().cloned() else { panic!("no built-in look") };
    let r = LookRef::new(LookScope::BuiltIn, &built_in.id);
    let depth = sess.undo_depth();
    assert!(sess.apply_look(&r, &store, None));
    assert_eq!(sess.undo_depth(), depth + 1);
    assert_eq!(sess.applied_look(&store), Some(r.clone()));
    assert_eq!(sess.look_state(&store), LookState::Applied(r.token()));
}

#[test]
fn saving_the_text_as_a_new_look_folds_into_one_step_and_the_text_carries_it() {
    let (mut sess, _) = text_session();
    let store = LookStore::new(None, None, None, None);
    let depth = sess.undo_depth();
    assert_eq!(sess.save_look_as_new("  ", LookScope::User, &store), Ok(None));
    let saved = sess.save_look_as_new("Mine", LookScope::User, &store);
    let Ok(Some(r)) = saved else { panic!("not saved") };
    assert_eq!(r.scope, LookScope::User);
    assert!(sess.undo_depth() <= depth + 1);
    assert_eq!(sess.applied_look(&store), Some(r.clone()));
    assert!(sess.looks(&store).iter().any(|e| e.ref_ == r));
}

#[test]
fn a_project_look_is_deleted_unless_captions_carry_it() {
    let (mut sess, _) = text_session();
    let store = LookStore::new(None, None, None, None);
    let Ok(Some(r)) = sess.save_look_as_new("Kit", LookScope::Project, &store) else { panic!("not saved") };
    assert_eq!(sess.delete_look(&r, &store), Ok(true));
    assert!(sess.look(&r, &store).is_none());
}

#[test]
fn add_title_makes_one_graphic_clip_and_selects_its_first_line() {
    let mut sess = session();
    let store = LookStore::new(None, None, None, None);
    let defaults = sq_library::library_folder_store::MemorySettings::default();
    let made = sess.add_title(Some(s(0)), TitleBuilder::DEFAULT_DURATION, &defaults, &store);
    assert_eq!(made.len(), 1);
    assert_eq!(sess.selection(), &made.iter().copied().collect::<BTreeSet<Id>>());
    assert_eq!(sess.graphic_layer_selection().map(|g| g.layers.len()), Some(1));
    assert!(sess.undo());
    assert!(sess.active_timeline().is_some_and(|t| t.tracks.iter().all(|tr| tr.clips().is_empty())));
}

#[test]
fn the_last_used_text_look_round_trips_through_the_settings() {
    use sq_text::look::LookLibrary;
    let (sess, _) = text_session();
    let store = LookStore::new(None, None, None, None);
    let mut defaults = sq_library::library_folder_store::MemorySettings::default();
    assert_eq!(sess.last_used_text_look(&defaults, &store), None);
    let Some(l) = LookLibrary::built_ins().first() else { panic!("no built-in look") };
    let r = LookRef::new(LookScope::BuiltIn, &l.id);
    EditorSession::remember_text_look(&mut defaults, &r);
    assert_eq!(sess.last_used_text_look(&defaults, &store), Some(r));
    EditorSession::remember_text_look(&mut defaults, &LookRef::new(LookScope::User, "gone"));
    assert_eq!(sess.last_used_text_look(&defaults, &store), None);
}

#[test]
fn a_look_given_to_captions_is_remembered_by_the_track_and_counts_as_applied() {
    use sq_text::look::{LookLibrary, LookState};
    let mut sess = session();
    let a = item(&mut sess, "one", 0, 2);
    assert!(sess.replace_captions(vec![a]));
    let store = LookStore::new(None, None, None, None);
    assert_eq!(sess.look_target(), Some(LookTarget::Captions));
    let Some(l) = LookLibrary::built_ins().first().cloned() else { panic!("no built-in look") };
    let r = LookRef::new(LookScope::BuiltIn, &l.id);
    assert!(sess.apply_look(&r, &store, None));
    assert_eq!(sess.applied_look(&store), Some(r.clone()));
    assert_eq!(sess.look_state(&store), LookState::Applied(r.token()));
    // A built-in Look reaches the captions as a project Look copy; undo takes both away.
    assert!(sess.project().style_kit.as_ref().is_some_and(|k| !k.looks.is_empty()));
    assert!(sess.undo());
    assert_eq!(sess.applied_look(&store), None);
}

// MARK: Title templates (EditorSession+TitleTemplate)

fn template_session() -> (EditorSession, Vec<Id>) {
    use sq_text::text_style::TextStyle;
    use sq_text::text_template::TextTemplate;
    let mut sess = session();
    let a = TextTemplate::new("A", "Title", TextStyle::default());
    let b = TextTemplate::new("B", "Sub", TextStyle::default());
    let Some(first) = sess.add_text_clip(&a, Some(s(10)), None, s(5), None, false) else { panic!("no text clip") };
    let Some(second) = sess.add_text_clip(&b, Some(s(10)), None, s(5), None, false) else { panic!("no text clip") };
    (sess, vec![first, second])
}

#[test]
fn a_template_from_the_selection_gets_text_and_style_slots_and_inserts_as_one_clip() {
    use sq_core_model::TemplateSlotKind;
    let (mut sess, ids) = template_session();
    sess.set_selection_follows_playhead(false);
    sess.select(ids.iter().copied().collect(), BTreeSet::new());
    assert!(sess.can_save_selection_as_template());
    let Some(template) = sess.title_template_from_selection("Intro") else { panic!("no template") };
    let kinds: Vec<TemplateSlotKind> = template.slots.iter().map(|x| x.kind).collect();
    assert_eq!(
        kinds,
        vec![
            TemplateSlotKind::Text,
            TemplateSlotKind::Text,
            TemplateSlotKind::Color,
            TemplateSlotKind::Font,
            TemplateSlotKind::Number
        ]
    );
    assert_eq!(template.duration(), s(5));
    let depth = sess.undo_depth();
    let Some(placed) = sess.insert_title_template(&template, Some(s(30))) else { panic!("not placed") };
    assert_eq!(sess.undo_depth(), depth + 1);
    assert_eq!(sess.undo_name(), Some("Insert Title Template"));
    assert!(sess.selection().contains(&placed));
    let Some(clip) = sess.es5_clip(placed).cloned() else { panic!("no clip") };
    assert!(clip.start == s(30) && clip.sequence.is_some() && clip.template_slots.is_some());
    // Slot edits are undo steps that merge while one gesture continues.
    let slot = template.slots[1].id;
    let depth = sess.undo_depth();
    sess.set_template_slot(slot, sq_core_model::SlotValue::Text("One".into()), placed, false);
    sess.set_template_slot(slot, sq_core_model::SlotValue::Text("Two".into()), placed, true);
    assert_eq!(sess.undo_depth(), depth + 1);
    assert_eq!(sess.undo_name(), Some("Edit Template"));
}

#[test]
fn zones_on_without_keyframes_say_why_and_off_works() {
    let (mut sess, ids) = template_session();
    assert!(!sess.set_zones_enabled(true, ids[0]));
    assert_eq!(sess.last_error(), Some("This clip has no keyframes, so there is no intro or outro to keep."));
    // Off on a clip without zones is a no-op that still succeeds.
    assert!(sess.set_zones_enabled(false, ids[0]));
}

#[test]
fn hovering_a_look_previews_it_on_the_engine_without_an_undo_step() {
    use sq_playback::engine::LookPreview;
    use sq_text::look::LookLibrary;
    let (mut sess, id) = text_session();
    let store = LookStore::new(None, None, None, None);
    let Some(built_in) = LookLibrary::built_ins().first().cloned() else { panic!("no built-in look") };
    let r = LookRef::new(LookScope::BuiltIn, &built_in.id);
    let depth = sess.undo_depth();
    assert!(sess.preview_look(Some(&r), &store));
    assert_eq!(sess.undo_depth(), depth);
    let seen = sess.engine().as_any().downcast_ref::<crate::StubProgramEngine>().and_then(|e| e.look_preview.clone());
    let Some(LookPreview::Text { container, layer, from, to }) = seen else { panic!("no text preview") };
    assert_eq!((container, layer), (id, id));
    assert_ne!(from, to);
    sess.clear_look_preview();
    let cleared = sess.engine().as_any().downcast_ref::<crate::StubProgramEngine>().map(|e| e.look_preview.is_none());
    assert_eq!(cleared, Some(true));
    assert!(!sess.preview_look(None, &store));
}

#[test]
fn playing_clears_the_look_preview() {
    use sq_text::look::LookLibrary;
    let (mut sess, _) = text_session();
    let store = LookStore::new(None, None, None, None);
    let Some(built_in) = LookLibrary::built_ins().first().cloned() else { panic!("no built-in look") };
    assert!(sess.preview_look(Some(&LookRef::new(LookScope::BuiltIn, &built_in.id)), &store));
    sess.play_pause();
    let cleared = sess.engine().as_any().downcast_ref::<crate::StubProgramEngine>().map(|e| e.look_preview.is_none());
    assert_eq!(cleared, Some(true));
}

// MARK: Style marks (Edited, default star)

#[test]
fn a_saved_look_is_edited_once_the_current_look_differs_and_clean_again_after_an_update() {
    use sq_library::library_folder_store::MemorySettings;
    use sq_text::caption_presets::CaptionLook;
    let store = LookStore::new(None, None, None, None);
    let mut settings = MemorySettings::default();
    let mut lib = CaptionLookLibrary::empty();
    let id = Id::fixed(901);
    let look = CaptionLook::default_look();
    let new = NewCaptionLook {
        id,
        name: "My Shorts",
        look: &look,
        segmentation: &sq_transcribe::caption_preset::CaptionPreset::standard(),
        make_default: false,
    };
    assert!(lib.save(&mut LookStoreCaptions(&store), &mut settings, new).is_ok());
    let m = lib.mark(&settings, id, &look);
    assert_eq!(m, Some(CaptionStyleMark { id, name: "My Shorts".into(), edited: false, is_default: false }));
    let mut changed = look.clone();
    changed.style.size += 4.0;
    assert_eq!(lib.mark(&settings, id, &changed).map(|m| m.edited), Some(true));
    lib.update(&mut LookStoreCaptions(&store), &mut settings, id, &changed, None);
    assert_eq!(lib.mark(&settings, id, &changed).map(|m| m.edited), Some(false));
    assert_eq!(lib.mark(&settings, Id::fixed(902), &changed), None);
}

#[test]
fn the_default_star_persists_moves_clears_and_ignores_unknown_looks() {
    use sq_library::library_folder_store::MemorySettings;
    use sq_text::caption_presets::CaptionLook;
    let store = LookStore::new(None, None, None, None);
    let mut settings = MemorySettings::default();
    let mut lib = CaptionLookLibrary::empty();
    let (a, b) = (Id::fixed(903), Id::fixed(904));
    let look = CaptionLook::default_look();
    for (id, name) in [(a, "A"), (b, "B")] {
        let new = NewCaptionLook {
            id,
            name,
            look: &look,
            segmentation: &sq_transcribe::caption_preset::CaptionPreset::standard(),
            make_default: false,
        };
        assert!(lib.save(&mut LookStoreCaptions(&store), &mut settings, new).is_ok());
    }
    assert_eq!(lib.default_look_id(&settings), None);
    assert!(lib.set_default_look(&mut settings, Some(a)));
    assert_eq!(lib.mark(&settings, a, &look).map(|m| m.is_default), Some(true));
    // A new library over the same store and settings (a restart) still shows the star on A.
    let again = CaptionLookLibrary::new(&LookStoreCaptions(&store));
    assert_eq!(again.default_look_id(&settings), Some(a));
    assert!(lib.set_default_look(&mut settings, Some(b)));
    assert_eq!(lib.mark(&settings, a, &look).map(|m| m.is_default), Some(false));
    assert!(!lib.set_default_look(&mut settings, Some(Id::fixed(905))));
    assert_eq!(lib.default_look_id(&settings), Some(b));
    assert!(lib.set_default_look(&mut settings, None));
    assert_eq!(lib.default_look_id(&settings), None);
}

#[test]
fn the_current_look_follows_a_pushed_look_and_a_style_edit() {
    use sq_text::caption_presets::CaptionLook;
    let mut sess = session();
    let a = item(&mut sess, "one", 0, 2);
    assert!(sess.replace_captions(vec![a]));
    let mut look = CaptionLook::default_look();
    look.style.size += 7.0;
    assert!(sess.push_caption_look(&look, "00000000-0000-0000-0000-000000000042", None));
    assert_eq!(sess.current_caption_look(), Some(look.clone()));
    assert!(sess.edit_caption_style(CaptionStyleField::Size(look.style.size + 5.0), CaptionStyleScope::All, false));
    assert_ne!(sess.current_caption_look(), Some(look));
}
