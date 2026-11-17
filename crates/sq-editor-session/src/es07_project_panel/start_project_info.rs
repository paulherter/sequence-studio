//! What a start card shows of a recent project, and the start screen's date wording (Swift `StartProjectInfo`).

use std::collections::BTreeMap;
use std::path::Path;

use sq_core_model::{Project, TrackKind};
use sq_core_project::media_grouping::GroupingCalendar;
use sq_core_project::project_merge::ProjectMerge;
use sq_core_project::project_template::TemplateFolder;
use sq_core_time::Timestamp;

use super::calendar::{days_from_civil, weekday_name};

/// The active sequence's frame size, rate and length of a project file (the start card), plus its poster frame.
// Swift: StartProjectInfo.swift:5
#[derive(Clone, Debug, PartialEq)]
pub struct StartProjectInfo {
    // Swift: StartProjectInfo.swift:7
    pub width: i64,
    // Swift: StartProjectInfo.swift:8
    pub height: i64,
    // Swift: StartProjectInfo.swift:9
    pub fps: f64,
    // Swift: StartProjectInfo.swift:10
    pub seconds: i64,
    /// First video or still clip on the active sequence: its file and the time of its first used frame (the poster).
    // Swift: StartProjectInfo.swift:12
    pub poster_path: Option<String>,
    // Swift: StartProjectInfo.swift:13
    pub poster_seconds: f64,
    /// The poster file is not on disk: the card says "Locate media…".
    // Swift: StartProjectInfo.swift:15
    pub media_missing: bool,
}

impl StartProjectInfo {
    // Swift: StartProjectInfo.swift:16
    pub fn new(
        width: i64,
        height: i64,
        fps: f64,
        seconds: i64,
        poster_path: Option<String>,
        poster_seconds: f64,
    ) -> Self {
        StartProjectInfo { width, height, fps, seconds, poster_path, poster_seconds, media_missing: false }
    }

    // Swift: StartProjectInfo.swift:21
    pub fn from_project(project: &Project) -> Option<StartProjectInfo> {
        let tl = project
            .timelines
            .iter()
            .find(|t| Some(t.id) == project.active_timeline)
            .or_else(|| project.timelines.first())?;
        let fd = tl.format.frame_duration;
        let d = tl.duration();
        let first = tl
            .tracks
            .iter()
            .filter(|t| t.kind == TrackKind::Video)
            .flat_map(|t| t.clips().iter())
            // A title or other generator has no file (and a nested sequence none in the bin): the poster is the first
            // clip that has picture content from a media file.
            .filter(|c| c.generator.is_none() && project.media(c.media).is_some())
            .min_by_key(|c| c.start); // min_by_key keeps the first of equal keys, like Swift's min(by:)
        let mut reference = first.and_then(|c| project.media(c.media));
        let mut at = first.map_or(0.0, |c| c.source.start.value() as f64 / c.source.start.timescale().max(1) as f64);
        if first.is_none() {
            // Nothing with picture on the timeline (a project whose clips are only in the Project panel): the first video
            // item of the bin, at its poster time. Swift shows a blank card here; this is a deliberate improvement.
            reference = project.media.iter().find(|m| m.info.as_ref().is_some_and(|i| i.video.is_some()));
            at = reference.and_then(|m| m.poster_time).map_or(0.0, |t| t.value() as f64 / t.timescale().max(1) as f64);
        }
        Some(StartProjectInfo::new(
            tl.format.width,
            tl.format.height,
            fd.timescale() as f64 / fd.value().max(1) as f64,
            d.value() / d.timescale(),
            reference.map(|m| m.path.clone()),
            at,
        ))
    }

    /// Reads each project file (call off the UI thread; unreadable ones are left out).
    // Swift: StartProjectInfo.swift:34
    pub fn read(paths: &[String]) -> BTreeMap<String, StartProjectInfo> {
        let mut out = BTreeMap::new();
        for p in paths {
            let Ok(project) = ProjectMerge::load(Path::new(p)) else { continue };
            let Some(mut info) = StartProjectInfo::from_project(&project) else { continue };
            if let Some(m) = &info.poster_path {
                info.media_missing = !Path::new(m).exists();
            }
            out.insert(p.clone(), info);
        }
        out
    }

    /// "9:16", "4:5", "1:1", "16:9" (reduced ratio), "2.39:1" when the reduced ratio is not a common one.
    // Swift: StartProjectInfo.swift:46
    pub fn aspect_of(w: i64, h: i64) -> String {
        if w <= 0 || h <= 0 {
            return String::new();
        }
        let g = gcd(w, h);
        let (a, b) = (w / g, h / g);
        if a.max(b) <= 21 {
            return format!("{a}:{b}");
        }
        format!("{:.2}:1", w as f64 / h as f64)
    }

    // Swift: StartProjectInfo.swift:53
    pub fn aspect(&self) -> String {
        Self::aspect_of(self.width, self.height)
    }

    // Swift: StartProjectInfo.swift:55
    pub fn size(&self) -> String {
        format!("{} \u{D7} {}", self.width, self.height)
    }

    // Swift: StartProjectInfo.swift:56
    pub fn rate(&self) -> String {
        let r = self.fps.round();
        if (self.fps - r).abs() < 0.01 { format!("{} fps", r as i64) } else { format!("{:.2} fps", self.fps) }
    }

    /// "02:14", "1:02:14".
    // Swift: StartProjectInfo.swift:61
    pub fn length(&self) -> String {
        let s = self.seconds.max(0);
        let (h, m, sec) = (s / 3600, (s % 3600) / 60, s % 60);
        if h > 0 { format!("{h}:{m:02}:{sec:02}") } else { format!("{m:02}:{sec:02}") }
    }
}

fn gcd(a: i64, b: i64) -> i64 {
    if b == 0 { a } else { gcd(b, a % b) }
}

/// The start screen's date wording (board "Start Screen B"; English UI).
// Swift: StartProjectInfo.swift:67
pub enum StartLabels {}

const DAY: f64 = 86_400.0;
const MONTHS: [&str; 12] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

fn same_day(cal: &dyn GroupingCalendar, a: Timestamp, b: Timestamp) -> bool {
    cal.year_month_day(a) == cal.year_month_day(b)
}

impl StartLabels {
    /// Group headings of the Recent grid.
    // Swift: StartProjectInfo.swift:77
    pub const GROUPS: [&'static str; 3] = ["Today", "This week", "Earlier"];

    /// "Today", "Yesterday", otherwise a short date like "28 Sep".
    // Swift: StartProjectInfo.swift:70
    pub fn day(date: Timestamp, now: Timestamp, cal: &dyn GroupingCalendar) -> String {
        if same_day(cal, date, now) {
            return "Today".into();
        }
        if same_day(cal, date, cal.previous_day(now)) {
            return "Yesterday".into();
        }
        let (_, m, d) = cal.year_month_day(date);
        format!("{d} {}", MONTHS[(m - 1).clamp(0, 11) as usize])
    }

    /// Group heading of the Recent grid: Today, This week (last 7 days), Earlier.
    // Swift: StartProjectInfo.swift:78
    pub fn group(date: Timestamp, now: Timestamp, cal: &dyn GroupingCalendar) -> &'static str {
        if same_day(cal, date, now) {
            return Self::GROUPS[0];
        }
        if date.unix_seconds() > now.unix_seconds() - 7.0 * DAY {
            return Self::GROUPS[1];
        }
        Self::GROUPS[2]
    }

    /// Card caption time: "Just now", "12 min ago", "2 h ago", then the day label.
    // Swift: StartProjectInfo.swift:85
    pub fn relative(date: Timestamp, now: Timestamp, cal: &dyn GroupingCalendar) -> String {
        let s = now.unix_seconds() - date.unix_seconds();
        if s < 60.0 {
            return "Just now".into();
        }
        if s < 3600.0 {
            return format!("{} min ago", (s / 60.0) as i64);
        }
        if s < DAY && same_day(cal, date, now) {
            return format!("{} h ago", (s / 3600.0) as i64);
        }
        if same_day(cal, date, cal.previous_day(now)) {
            return "Yesterday".into();
        }
        if s < 6.0 * DAY {
            let (y, m, d) = cal.year_month_day(date);
            return weekday_name(days_from_civil(y, m, d)).into();
        }
        Self::day(date, now, cal)
    }
}

/// Where the user's templates live: `<Application Support>/Sequence Studio/Templates`, never inside a project file. The
/// Mac template store and the portable start screen read the same folder. `support` is the app's own folder (the
/// `Sequence Studio` one); `TemplateFolder::save` makes the folder on the first save.
// Swift: StartProjectInfo.swift:99
pub fn standard_template_folder(support: &Path) -> TemplateFolder {
    TemplateFolder::new(&support.join("Templates"))
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::es07_project_panel::UtcCalendar;

    /// 2026-11-05 12:00 UTC (a Thursday).
    fn now() -> Timestamp {
        Timestamp::from_unix_seconds(1_793_880_000.0)
    }
    fn ago(s: f64) -> Timestamp {
        Timestamp::from_unix_seconds(now().unix_seconds() - s)
    }

    /// "Untitled Project 4": a title first on V1, then talk.mp4 and landscape.mp4 (the card showed the grey placeholder).
    #[test]
    fn a_title_in_front_does_not_take_the_poster_from_the_first_media_clip() {
        use sq_core_model::{Clip, GeneratorRef, MediaFingerprint, MediaRef, SequenceFormat, Timeline, Track};
        use sq_core_time::{Id, Time, TimeRange};
        let sec = Time::seconds;
        let clip = |n: u128, media: u128, start: i64, src: i64| {
            Clip::new(
                Id::from_u128(n),
                "c",
                Id::from_u128(media),
                TrackKind::Video,
                TimeRange::new(sec(src), sec(3)),
                sec(start),
            )
        };
        let mut title = clip(1, 1, 0, 0);
        title.generator = Some(GeneratorRef { kind: "text".into(), payload: vec![], payload_version: 1 });
        let mut v1 = Track::new(Id::from_u128(50), TrackKind::Video);
        v1.set_clips(vec![title, clip(2, 10, 3, 2), clip(3, 11, 6, 0)]);
        let media = |n: u128, path: &str| MediaRef::new(Id::from_u128(n), path, path, MediaFingerprint::new(1));
        let tl = Timeline::new(Id::from_u128(9), "S", SequenceFormat::new(Time::new(1, 30)), vec![v1]);
        let p = Project::new(
            Id::from_u128(8),
            "P",
            vec![media(10, "/m/talk.mp4"), media(11, "/m/landscape.mp4")],
            vec![tl],
        );
        let info = StartProjectInfo::from_project(&p).expect("info");
        assert_eq!((info.poster_path.as_deref(), info.poster_seconds), (Some("/m/talk.mp4"), 2.0));
    }

    /// A project whose clips are only in the Project panel (the timeline is empty): the card takes the first video item.
    #[test]
    fn an_empty_timeline_takes_the_poster_from_the_first_video_item_of_the_bin() {
        use crate::es08_media::testing::{info, video};
        use sq_core_model::{MediaFingerprint, MediaRef, SequenceFormat, Timeline};
        use sq_core_time::{Id, Time};
        let mut sound = MediaRef::new(Id::from_u128(10), "song", "/m/song.wav", MediaFingerprint::new(1));
        sound.info = Some(info(Time::seconds(5), None));
        let mut talk = MediaRef::new(Id::from_u128(11), "talk", "/m/talk.mp4", MediaFingerprint::new(2));
        talk.info = Some(info(Time::seconds(11), Some(video(1920, 1080))));
        talk.poster_time = Some(Time::seconds(2));
        let tl = Timeline::new(Id::from_u128(9), "S", SequenceFormat::new(Time::new(1, 30)), vec![]);
        let p = Project::new(Id::from_u128(8), "P", vec![sound, talk], vec![tl]);
        let info = StartProjectInfo::from_project(&p).expect("info");
        assert_eq!((info.poster_path.as_deref(), info.poster_seconds), (Some("/m/talk.mp4"), 2.0));
        assert_eq!(info.seconds, 0);
        let empty = Project::new(
            Id::from_u128(8),
            "P",
            vec![],
            vec![Timeline::new(Id::from_u128(9), "S", SequenceFormat::new(Time::new(1, 30)), vec![])],
        );
        assert_eq!(StartProjectInfo::from_project(&empty).expect("info").poster_path, None, "no media: no poster");
    }

    #[test]
    fn aspect_rate_length_and_size() {
        assert_eq!(StartProjectInfo::aspect_of(1080, 1920), "9:16");
        assert_eq!(StartProjectInfo::aspect_of(1920, 1080), "16:9");
        assert_eq!(StartProjectInfo::aspect_of(2390, 1000), "2.39:1");
        assert_eq!(StartProjectInfo::aspect_of(0, 5), "");
        let mut i = StartProjectInfo::new(3840, 2160, 29.97, 134, None, 0.0);
        assert_eq!(
            (i.size().as_str(), i.rate().as_str(), i.length().as_str()),
            ("3840 \u{D7} 2160", "29.97 fps", "02:14")
        );
        i.fps = 25.0;
        i.seconds = 3734;
        assert_eq!((i.rate().as_str(), i.length().as_str()), ("25 fps", "1:02:14"));
    }

    #[test]
    fn labels_follow_the_board() {
        let c = &UtcCalendar;
        assert_eq!(StartLabels::day(ago(60.0), now(), c), "Today");
        assert_eq!(StartLabels::day(ago(86_400.0), now(), c), "Yesterday");
        assert_eq!(StartLabels::day(ago(10.0 * 86_400.0), now(), c), "26 Oct");
        assert_eq!(StartLabels::group(ago(3.0 * 86_400.0), now(), c), "This week");
        assert_eq!(StartLabels::group(ago(9.0 * 86_400.0), now(), c), "Earlier");
        assert_eq!(StartLabels::relative(ago(10.0), now(), c), "Just now");
        assert_eq!(StartLabels::relative(ago(720.0), now(), c), "12 min ago");
        assert_eq!(StartLabels::relative(ago(7200.0), now(), c), "2 h ago");
        assert_eq!(StartLabels::relative(ago(3.0 * 86_400.0), now(), c), "Mon");
    }
}
