//! How timeline time became the source time of one evaluated layer.
// Swift: LayerTimePath.swift

use sq_core_effects::evaluation::{ClipPosterize, LayerRequest, SequenceResolver};
use sq_core_effects::transition::TrackTransitions;
use sq_core_effects::transition_layer::TrackTransitionLayer;
use sq_core_model::{Clip, Timeline, Track, TrackKind};
use sq_core_time::{Id, Time};

use crate::angles_proxy::AnglesClipExt;

#[derive(Clone, Debug)]
struct Step {
    clip: Clip,
    /// Frame duration of the sequence the clip is on.
    frame: Time,
    /// A nested clip: its sequence's frame duration. None: the layer's own clip.
    inner_frame: Option<Time>,
    /// The shown video tracks above the clip's track: a transition layer on one of them holds the clip.
    above: Vec<Track>,
}

/// How timeline time became the source time of one evaluated layer: the nested clips around it (outermost first) and
/// the clip itself, found once in the timeline. `source_time` then answers for a nearby timeline time with the
/// clips' own time mappings only, without evaluating the timeline again (the Magic matte look-ahead asks for the next
/// four ticks on every tick).
///
/// It answers only where the full evaluation gives the same time, and None everywhere else: a time outside one of the
/// clips (a clip edge was crossed, a transition half held beyond it) or under a transition layer. The caller evaluates
/// the timeline for such a time.
#[derive(Clone, Debug)]
pub struct LayerTimePath {
    steps: Vec<Step>,
}

impl LayerTimePath {
    /// None when the layer is not a file or nested clip found on its track at `t` (a graphics item, a transition half
    /// outside its clip, a side of a transition layer), or when the path does not give the layer's own source time.
    pub fn new(
        layer: &LayerRequest,
        t: Time,
        timeline: &Timeline,
        sequences: SequenceResolver,
    ) -> Option<LayerTimePath> {
        if !layer.stack_transitions.is_empty() {
            return None;
        }
        let mut tl = timeline.clone();
        let mut u = t;
        let step = |tl: &Timeline, u: Time, clip: Id, track: Id, inner_frame: Option<Time>| -> Option<Step> {
            let i = tl.tracks.iter().position(|x| x.id == track)?;
            let k = tl.tracks[i].clip_index_ending_after(u);
            let c = tl.tracks[i].clips().get(k).filter(|c| c.id == clip)?;
            let above =
                tl.tracks[i + 1..].iter().filter(|x| x.kind == TrackKind::Video && x.is_visible).cloned().collect();
            Some(Step { clip: c.clone(), frame: tl.format.frame_duration, inner_frame, above })
        };
        let mut path = LayerTimePath { steps: Vec::new() };
        for g in &layer.groups {
            if g.sequence == g.clip {
                return None;
            }
            let inner = sequences(g.sequence)?;
            let s = step(&tl, u, g.clip, g.track, Some(inner.format.frame_duration))?;
            if s.clip.sequence != Some(g.sequence) {
                return None;
            }
            let next = Self::inner(&s, u)?;
            tl = s.clip.angle_view(inner);
            path.steps.push(s);
            u = next;
        }
        let s = step(&tl, u, layer.clip, layer.track, None)?;
        if s.clip.sequence.is_some() || s.clip.is_graphics() {
            return None;
        }
        path.steps.push(s);
        (path.source_time(t) == Some(layer.source_time)).then_some(path)
    }

    /// The source time the layer reads at timeline time `t`; None when the evaluation has to say (see the type).
    pub fn source_time(&self, t: Time) -> Option<Time> {
        let mut u = t;
        for s in &self.steps {
            u = Self::inner(s, u)?;
        }
        Some(u)
    }

    /// The time one step maps `u` to (a nested clip: time in its sequence; the layer's clip: source time), as
    /// `Timeline::video_layers` does it.
    fn inner(s: &Step, u: Time) -> Option<Time> {
        if !s.clip.timeline().contains(u) {
            return None;
        }
        if s.above.iter().any(|track| track.active_transition_layer(u).is_some()) {
            return None;
        }
        let tq = s.clip.posterized_time(u, Some(s.frame));
        let Some(inner_frame) = s.inner_frame else { return Some(s.clip.source_time(tq, s.frame)) };
        Some(
            s.clip
                .hold_frame
                .unwrap_or_else(|| s.clip.inner_time(s.clip.held_read_time(tq, s.frame) - s.clip.start, inner_frame)),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_effects::evaluation::{LayerHooks, TimelineEvaluation};
    use sq_core_model::{ClipSpeed, SequenceFormat};
    use sq_core_time::{IdSource, SequentialIds, TimeRange};

    fn fd() -> Time {
        Time::new(1, 30)
    }

    fn file(ids: &mut SequentialIds, at: i64, frames: i64, speed: ClipSpeed, reversed: bool) -> Clip {
        let length = fd() * frames;
        let source =
            TimeRange::new(Time::new(1, 1), Time::new(length.value() * speed.num(), length.timescale() * speed.den()));
        let mut c = Clip::new(ids.next_id(), "f", ids.next_id(), TrackKind::Video, source, fd() * at);
        c.speed = speed;
        c.reversed = reversed;
        c
    }
    fn nested(ids: &mut SequentialIds, inner: &Timeline, at: i64, frames: i64, from: i64) -> Clip {
        let source = TimeRange::new(inner.frame_duration() * from, fd() * frames);
        let mut c = Clip::new(ids.next_id(), &inner.name, inner.id, TrackKind::Video, source, fd() * at);
        c.sequence = Some(inner.id);
        c
    }
    fn track(ids: &mut SequentialIds, clips: Vec<Clip>) -> Track {
        let mut t = Track::new(ids.next_id(), TrackKind::Video);
        for c in clips {
            t.overwrite(c, ids).unwrap();
        }
        t
    }

    /// `top` holds a nested `inner` (plain, fast, slow and reversed file clips, gaps) and a second track.
    fn fixture(ids: &mut SequentialIds) -> (Timeline, Timeline) {
        let normal = ClipSpeed::new(1, 1);
        let clips = vec![
            file(ids, 0, 20, normal, false),
            file(ids, 20, 20, normal, true),
            file(ids, 40, 20, ClipSpeed::new(2, 1), false),
            file(ids, 80, 40, ClipSpeed::new(1, 2), false),
        ];
        let inner = Timeline::new(ids.next_id(), "inner", SequenceFormat::new(fd()), vec![track(ids, clips)]);
        let top_clips = vec![nested(ids, &inner, 0, 60, 3), file(ids, 70, 30, normal, true)];
        let u_clips = vec![file(ids, 10, 33, ClipSpeed::new(3, 1), false), file(ids, 100, 45, normal, false)];
        let tracks = vec![track(ids, top_clips), track(ids, u_clips)];
        let top = Timeline::new(ids.next_id(), "top", SequenceFormat::new(fd()), tracks);
        (top, inner)
    }

    #[test]
    fn the_path_gives_the_evaluated_source_time_or_nothing() {
        let mut ids = SequentialIds::default();
        let (top, inner) = fixture(&mut ids);
        let resolver = |id: Id| if id == inner.id { Some(&inner) } else { None };
        let hooks = LayerHooks::plain();
        let (mut layers, mut paths, mut asked, mut answered) = (0, 0, 0, 0);
        for f in 0..160i64 {
            let t = fd() * f;
            for r in top.video_layers(t, &resolver, &hooks, None).iter().filter(|r| r.generator.is_none()) {
                layers += 1;
                let Some(path) = LayerTimePath::new(r, t, &top, &resolver) else { continue };
                paths += 1;
                assert_eq!(path.source_time(t), Some(r.source_time));
                for k in (-4..=4).filter(|k| *k != 0 && f + k >= 0) {
                    let at = fd() * (f + k);
                    asked += 1;
                    let Some(derived) = path.source_time(at) else { continue };
                    answered += 1;
                    let chain = |l: &LayerRequest| l.groups.iter().map(|g| g.clip).chain([l.clip]).collect::<Vec<_>>();
                    let same: Vec<_> = top
                        .video_layers(at, &resolver, &hooks, None)
                        .into_iter()
                        .filter(|l| chain(l) == chain(r))
                        .collect();
                    assert!(
                        !same.is_empty(),
                        "frame {f} + {k}: the path answers for a layer the evaluation does not show"
                    );
                    assert!(
                        same.iter().all(|l| l.source_time == derived),
                        "frame {f} + {k}: {derived:?} is not the evaluated time"
                    );
                }
            }
        }
        assert!(paths * 10 >= layers * 7, "{paths} of {layers} layers have a path");
        assert!(answered * 10 >= asked * 7, "{answered} of {asked} times answered");
    }

    #[test]
    fn a_time_outside_the_clip_is_left_to_the_evaluation() {
        let mut ids = SequentialIds::default();
        let (top, inner) = fixture(&mut ids);
        let resolver = |id: Id| if id == inner.id { Some(&inner) } else { None };
        let t = fd() * 141;
        let layers = top.video_layers(t, &resolver, &LayerHooks::plain(), None);
        let u3 = layers
            .iter()
            .find(|r| top.tracks[1].clip(r.clip).is_some())
            .and_then(|r| LayerTimePath::new(r, t, &top, &resolver))
            .unwrap();
        // The clip runs from frame 100 to 145.
        assert_eq!(u3.source_time(fd() * 144), Some(Time::new(1, 1) + fd() * 44));
        assert_eq!(u3.source_time(fd() * 145), None);
        assert_eq!(u3.source_time(fd() * 99), None);
    }
}
