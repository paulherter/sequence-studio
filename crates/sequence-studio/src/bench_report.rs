//! The machine-readable result of one `--play-bench` run (`--bench-json <file>`): one case, one run, one JSON file, the same
//! fields on every system, so `scripts/sq-bench.sh` can take medians and compare machines and versions
//! (`notes/tempo/`, the benchmark design in SQ-Zukunft/BENCHMARK-DESIGN.md §3). Pure data and maths; `headless::play_bench`
//! measures, this module only describes.

use serde_json::{Value, json};

/// Options of a bench run from the command line.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct BenchOpts {
    /// Where on the sequence the run starts, in milliseconds (`--bench-from <seconds>`).
    pub from_ms: i64,
    /// How long to play, in milliseconds (`--bench-secs <seconds>`); `None` = `SQ_BENCH_SECS` or 4 s.
    pub secs_ms: Option<i64>,
    /// Where the JSON goes (`--bench-json <file>`).
    pub json: Option<std::path::PathBuf>,
    /// Free labels written into the JSON (`--bench-tag key=value`, repeatable): case, variant, commit.
    pub tags: Vec<(String, String)>,
    /// The Program monitor's playback quality at the start (`--quality`, default Auto like a fresh install).
    pub quality: BenchQuality,
    /// `--bench-verify`: read every new picture's barcode back and compare it with the presenter's flag.
    pub verify: bool,
    /// `--page color`: the UI draws the Color page (source tiles, scopes, wheels) during the run, the same page switch as `--ui-shot`.
    pub color_page: bool,
    /// `--wait-proxies <seconds>`: keep the background proxy service in the run and let its queue finish (at most that long)
    /// before Play, so Auto's software-decode rule has proxies to play.
    pub wait_proxies_ms: Option<i64>,
}

/// `--quality auto|full|half|quarter`: what Preferences > Playback holds for the run.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BenchQuality {
    #[default]
    Auto,
    Full,
    Half,
    Quarter,
}

impl BenchQuality {
    pub fn parse(text: &str) -> Option<BenchQuality> {
        Some(match text {
            "auto" => BenchQuality::Auto,
            "full" => BenchQuality::Full,
            "half" => BenchQuality::Half,
            "quarter" => BenchQuality::Quarter,
            _ => return None,
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            BenchQuality::Auto => "auto",
            BenchQuality::Full => "full",
            BenchQuality::Half => "half",
            BenchQuality::Quarter => "quarter",
        }
    }
}

/// The decode quality the engine used during a run: the value at Play, every change and the value at the end.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct QualityTrace {
    /// The `--quality` choice ("auto", "full", ...).
    pub requested: String,
    pub start: String,
    pub changes: Vec<QualityChange>,
}

/// One change of the effective quality.
#[derive(Clone, Debug, PartialEq)]
pub struct QualityChange {
    /// Seconds since Play.
    pub at_play_s: f64,
    /// Position on the timeline when it happened (NaN when unknown).
    pub timeline_s: f64,
    pub to: String,
}

impl QualityTrace {
    pub fn new(requested: &str, start: &str) -> QualityTrace {
        QualityTrace { requested: requested.into(), start: start.into(), changes: Vec::new() }
    }

    /// The quality in effect now (the last change, or the start value).
    pub fn current(&self) -> &str {
        self.changes.last().map_or(self.start.as_str(), |c| c.to.as_str())
    }

    /// Notes `now` seen at `at_play_s` / `timeline_s`; records a change when it differs from the last value.
    pub fn observe(&mut self, now: &str, at_play_s: f64, timeline_s: f64) {
        if now != self.current() {
            self.changes.push(QualityChange { at_play_s, timeline_s, to: now.into() });
        }
    }

    pub fn to_json(&self) -> Value {
        json!({
            "requested": self.requested,
            "start": self.start,
            "changes": self.changes.iter().map(|c| json!({ "at_play_s": c.at_play_s, "timeline_s": c.timeline_s, "to": c.to })).collect::<Vec<_>>(),
            "final": self.current(),
        })
    }

    /// One text line for the run log.
    pub fn line(&self) -> String {
        let steps: Vec<String> = self
            .changes
            .iter()
            .map(|c| format!("{} at {:.1}s play / {:.1}s timeline", c.to, c.at_play_s, c.timeline_s))
            .collect();
        format!(
            "quality: requested {}, start {}, {} change(s){}{}, final {}\n",
            self.requested,
            self.start,
            self.changes.len(),
            if steps.is_empty() { "" } else { ": " },
            steps.join(", "),
            self.current()
        )
    }
}

/// The nearest-rank percentile of an ascending list (`q` 0...1); `NaN` for an empty list.
pub fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return f64::NAN;
    }
    sorted[((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)).round() as usize]
}

/// The gaps between distinct pictures on the monitor, in milliseconds.
#[derive(Clone, Debug, PartialEq)]
pub struct GapStats {
    pub count: usize,
    pub p50: f64,
    pub p95: f64,
    pub p99: f64,
    pub max: f64,
    /// Gaps longer than 1.5 and 2 frame durations.
    pub over_1_5x: usize,
    pub over_2x: usize,
}

impl GapStats {
    /// Sorts `gaps` and counts against the frame duration `frame_ms` (0 counts nothing).
    pub fn of(gaps: &mut [f64], frame_ms: f64) -> GapStats {
        gaps.sort_by(f64::total_cmp);
        let over = |k: f64| if frame_ms > 0.0 { gaps.iter().filter(|g| **g > frame_ms * k).count() } else { 0 };
        GapStats {
            count: gaps.len(),
            p50: percentile(gaps, 0.5),
            p95: percentile(gaps, 0.95),
            p99: percentile(gaps, 0.99),
            max: percentile(gaps, 1.0),
            over_1_5x: over(1.5),
            over_2x: over(2.0),
        }
    }
}

/// Everything one run measured.
#[derive(Clone, Debug, Default)]
pub struct BenchReport {
    pub tags: Vec<(String, String)>,
    pub project: String,
    pub size: (u32, u32),
    pub from_s: f64,
    pub played_s: f64,
    pub length_s: f64,
    pub fps: f64,
    /// "device" (real output) or "null" (host clock, `SQ_AUDIO_NULL` or no device).
    pub audio: String,
    pub first_picture_ms: f64,
    pub play_first_ms: f64,
    pub shown: u64,
    pub expected: f64,
    pub dropped: u64,
    pub standins: u64,
    pub max_lag: i64,
    pub gaps: Option<GapStats>,
    pub underruns: u64,
    /// Master clock minus the position of the picture on screen at each new picture, in ms (positive = picture late).
    pub drift_max_abs_ms: f64,
    pub drift_mean_ms: f64,
    pub ui_frames_per_s: f64,
    pub ui_avg_ms: f64,
    pub rss_mb: (f64, f64, f64),
    pub gpu_busy: u64,
    pub machine: Machine,
    pub quality: QualityTrace,
    /// Composites per shown frame (B2; 1.0 = one composite for each frame).
    pub composites_per_shown: f64,
    pub verify: Option<crate::bench_frames::Verify>,
}

/// Which machine and how loaded it was.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Machine {
    pub host: String,
    pub os: String,
    pub arch: String,
    pub cpu: String,
    pub gpu: String,
    pub load_1m: Option<f64>,
}

impl Machine {
    /// This machine now. The GPU name comes from the caller (the adapter the engine opened).
    pub fn here(gpu: &str) -> Machine {
        let run = |cmd: &str, args: &[&str]| {
            std::process::Command::new(cmd)
                .args(args)
                .output()
                .ok()
                .and_then(|o| String::from_utf8(o.stdout).ok())
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        };
        let host = run("hostname", &[]).unwrap_or_default();
        let cpu = if cfg!(target_os = "macos") {
            run("sysctl", &["-n", "machdep.cpu.brand_string"])
        } else {
            std::fs::read_to_string("/proc/cpuinfo").ok().and_then(|t| {
                t.lines().find(|l| l.starts_with("model name"))?.split_once(':').map(|(_, v)| v.trim().to_string())
            })
        };
        let load_1m = if cfg!(target_os = "macos") {
            run("sysctl", &["-n", "vm.loadavg"])
                .and_then(|s| s.trim_matches(|c| c == '{' || c == '}' || c == ' ').split(' ').next()?.parse().ok())
        } else {
            std::fs::read_to_string("/proc/loadavg").ok().and_then(|t| t.split(' ').next()?.parse().ok())
        };
        Machine {
            host,
            os: std::env::consts::OS.to_string(),
            arch: std::env::consts::ARCH.to_string(),
            cpu: cpu.unwrap_or_default(),
            gpu: gpu.to_string(),
            load_1m,
        }
    }
}

impl BenchReport {
    /// The JSON file's content (schema 1).
    pub fn to_json(&self) -> Value {
        let tags: serde_json::Map<String, Value> =
            self.tags.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect();
        let g = self.gaps.clone().unwrap_or(GapStats {
            count: 0,
            p50: f64::NAN,
            p95: f64::NAN,
            p99: f64::NAN,
            max: f64::NAN,
            over_1_5x: 0,
            over_2x: 0,
        });
        let per_min = if self.played_s > 0.0 { self.underruns as f64 * 60.0 / self.played_s } else { 0.0 };
        json!({
            "schema": 1,
            "tags": tags,
            "machine": {
                "host": self.machine.host, "os": self.machine.os, "arch": self.machine.arch,
                "cpu": self.machine.cpu, "gpu": self.machine.gpu, "load_1m": self.machine.load_1m,
            },
            "run": {
                "project": self.project, "size": [self.size.0, self.size.1], "from_s": self.from_s,
                "played_s": self.played_s, "length_s": self.length_s, "fps": self.fps, "audio": self.audio,
            },
            "picture": {
                "first_ms": self.first_picture_ms, "play_first_ms": self.play_first_ms, "shown": self.shown,
                "expected": self.expected, "dropped": self.dropped, "late_standins": self.standins,
                "max_lag_frames": self.max_lag, "gpu_busy_drops": self.gpu_busy,
            },
            "gap_ms": {
                "count": g.count, "p50": g.p50, "p95": g.p95, "p99": g.p99, "max": g.max,
                "over_1_5x": g.over_1_5x, "over_2x": g.over_2x,
            },
            "audio": {
                "underruns": self.underruns, "underruns_per_min": per_min,
                "av_drift_max_abs_ms": self.drift_max_abs_ms, "av_drift_mean_ms": self.drift_mean_ms,
            },
            "quality": self.quality.to_json(),
            "composites_per_shown": self.composites_per_shown,
            "verify": self.verify.as_ref().map(|v| json!({
                "checked": v.checked, "barcode_correct": v.barcode_correct, "presenter_correct": v.presenter_correct,
                "disagree": v.disagree, "unreadable": v.unreadable,
            })),
            "ui": { "frames_per_s": self.ui_frames_per_s, "avg_ms": self.ui_avg_ms },
            "rss_mb": { "start": self.rss_mb.0, "max": self.rss_mb.1, "end": self.rss_mb.2 },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percentiles_are_nearest_rank_and_empty_is_nan() {
        let v: Vec<f64> = (1..=100).map(f64::from).collect();
        assert_eq!(percentile(&v, 0.5), 51.0);
        assert_eq!(percentile(&v, 0.95), 95.0);
        assert_eq!(percentile(&v, 0.99), 99.0);
        assert_eq!(percentile(&v, 1.0), 100.0);
        assert!(percentile(&[], 0.5).is_nan());
    }

    #[test]
    fn gap_stats_sort_and_count_against_the_frame_duration() {
        let mut g = vec![33.0, 34.0, 50.0, 33.0, 70.0, 33.0];
        let s = GapStats::of(&mut g, 33.3);
        assert_eq!((s.count, s.max, s.over_1_5x, s.over_2x), (6, 70.0, 2, 1));
        assert_eq!(s.p50, 34.0);
        assert_eq!(GapStats::of(&mut [], 33.3).over_2x, 0);
    }

    #[test]
    fn the_json_has_the_fixed_fields_and_nan_becomes_null() {
        let mut gaps = vec![33.0, 33.0, 40.0];
        let r = BenchReport {
            tags: vec![("case".into(), "P1".into())],
            played_s: 30.0,
            underruns: 3,
            audio: "device".into(),
            gaps: Some(GapStats::of(&mut gaps, 33.3)),
            play_first_ms: f64::NAN,
            ..BenchReport::default()
        };
        let j = r.to_json();
        assert_eq!(j["schema"], 1);
        assert_eq!(j["tags"]["case"], "P1");
        assert_eq!(j["gap_ms"]["p95"], 40.0);
        assert_eq!(j["audio"]["underruns_per_min"], 6.0);
        assert!(j["picture"]["play_first_ms"].is_null());
        for key in ["machine", "run", "picture", "gap_ms", "audio", "ui", "rss_mb", "quality", "composites_per_shown"] {
            assert!(j.get(key).is_some(), "{key}");
        }
    }

    #[test]
    fn the_quality_trace_records_start_every_change_and_the_final_value() {
        let mut t = QualityTrace::new("auto", "half");
        t.observe("half", 0.1, 10.1);
        t.observe("quarter", 3.5, 13.5);
        t.observe("quarter", 4.0, 14.0);
        assert_eq!(t.changes.len(), 1);
        assert_eq!(t.current(), "quarter");
        let r = BenchReport { quality: t, ..BenchReport::default() };
        let q = &r.to_json()["quality"];
        assert_eq!(
            (q["requested"].as_str(), q["start"].as_str(), q["final"].as_str()),
            (Some("auto"), Some("half"), Some("quarter"))
        );
        assert_eq!(q["changes"][0]["to"], "quarter");
        assert_eq!(q["changes"][0]["timeline_s"], 13.5);
        assert!(QualityTrace::new("full", "full").to_json()["changes"].as_array().is_some_and(Vec::is_empty));
    }

    #[test]
    fn the_quality_names_round_trip() {
        for q in [BenchQuality::Auto, BenchQuality::Full, BenchQuality::Half, BenchQuality::Quarter] {
            assert_eq!(BenchQuality::parse(q.name()), Some(q));
        }
        assert_eq!(BenchQuality::parse("best"), None);
        assert_eq!(BenchQuality::default(), BenchQuality::Auto);
    }
}
