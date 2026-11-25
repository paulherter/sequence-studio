//! One timeline for every timing in the app: `SQ_TRACE_JSON=<path>` writes Chrome/Perfetto trace-event JSON at exit
//! (open it in ui.perfetto.dev or `scripts/trace-report.py`). Without the variable every call is one relaxed atomic load.
//!
//! Each thread appends to its own buffer (a mutex only `finish` ever contends for) that is registered on first use, so
//! threads that never end are still flushed. Names and categories are `&'static str`; only `args` allocates, and only
//! when tracing is on.

use std::cell::RefCell;
use std::fmt::Write as _;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

static ON: AtomicBool = AtomicBool::new(false);
static EPOCH: OnceLock<Instant> = OnceLock::new();
static PATH: OnceLock<String> = OnceLock::new();
static THREADS: Mutex<Vec<Arc<ThreadBuf>>> = Mutex::new(Vec::new());

struct Event {
    cat: &'static str,
    name: std::borrow::Cow<'static, str>,
    /// Microseconds since the epoch.
    ts: u64,
    /// `None`: an instant event; otherwise the span length in microseconds.
    dur: Option<u64>,
    args: Option<String>,
}

struct ThreadBuf {
    tid: u64,
    name: String,
    events: Mutex<Vec<Event>>,
}

thread_local! {
    static LOCAL: RefCell<Option<Arc<ThreadBuf>>> = const { RefCell::new(None) };
}

/// Reads `SQ_TRACE_JSON` once; the first call of the program should be this one (later calls do nothing).
pub fn init_from_env() {
    let Some(path) = std::env::var("SQ_TRACE_JSON").ok().filter(|p| !p.is_empty()) else { return };
    if PATH.set(path).is_ok() {
        let _ = EPOCH.set(Instant::now());
        ON.store(true, Ordering::Relaxed);
    }
}

/// Whether the trace is on: one relaxed load.
#[inline]
pub fn enabled() -> bool {
    ON.load(Ordering::Relaxed)
}

fn us_since_epoch(t: Instant) -> u64 {
    EPOCH.get().map_or(0, |e| u64::try_from(t.saturating_duration_since(*e).as_micros()).unwrap_or(u64::MAX))
}

fn push(ev: Event) {
    let _ = LOCAL.try_with(|cell| {
        let mut slot = cell.borrow_mut();
        let buf = slot.get_or_insert_with(|| {
            let cur = std::thread::current();
            let buf = Arc::new(ThreadBuf {
                tid: THREADS.lock().map_or(0, |t| t.len() as u64 + 1),
                name: cur.name().map_or_else(|| format!("thread-{:?}", cur.id()), str::to_string),
                events: Mutex::new(Vec::with_capacity(4096)),
            });
            if let Ok(mut all) = THREADS.lock() {
                all.push(Arc::clone(&buf));
            }
            buf
        });
        if let Ok(mut e) = buf.events.lock() {
            e.push(ev);
        }
    });
}

/// A running span; ends when dropped. Inert (no clock read) when tracing is off.
#[must_use = "the span ends when this is dropped"]
pub struct Span {
    live: Option<(&'static str, &'static str, Instant, Option<String>)>,
}

impl Drop for Span {
    fn drop(&mut self) {
        if let Some((cat, name, start, args)) = self.live.take() {
            push(Event {
                cat,
                name: name.into(),
                ts: us_since_epoch(start),
                dur: Some(start.elapsed().as_micros() as u64),
                args,
            });
        }
    }
}

/// Starts a span.
#[inline]
pub fn span(cat: &'static str, name: &'static str) -> Span {
    Span { live: enabled().then(|| (cat, name, Instant::now(), None)) }
}

/// Starts a span with arguments (`k=v` text built only when tracing is on).
#[inline]
pub fn span_args(cat: &'static str, name: &'static str, args: impl FnOnce() -> String) -> Span {
    Span { live: enabled().then(|| (cat, name, Instant::now(), Some(args()))) }
}

/// A span that already happened, from `start` until now.
#[inline]
pub fn since(cat: &'static str, name: &'static str, start: Instant, args: impl FnOnce() -> String) {
    if enabled() {
        push(Event {
            cat,
            name: name.into(),
            ts: us_since_epoch(start),
            dur: Some(start.elapsed().as_micros() as u64),
            args: Some(args()),
        });
    }
}

/// A span with a known start and length (a GPU pass, a wait measured elsewhere), ending now when `start` is `None`.
#[inline]
pub fn complete(
    cat: &'static str,
    name: &'static str,
    start: Instant,
    dur: std::time::Duration,
    args: impl FnOnce() -> String,
) {
    if enabled() {
        push(Event {
            cat,
            name: name.into(),
            ts: us_since_epoch(start),
            dur: Some(dur.as_micros() as u64),
            args: Some(args()),
        });
    }
}

/// A span of `dur` that ended just now (the caller measured only the length).
#[inline]
pub fn ended_now(cat: &'static str, name: &'static str, dur: std::time::Duration, args: impl FnOnce() -> String) {
    if enabled() {
        let now = Instant::now();
        let start = now.checked_sub(dur).unwrap_or(now);
        complete(cat, name, start, dur, args);
    }
}

/// A point in time with a name that is not a literal (an open milestone).
#[inline]
pub fn mark_dyn(cat: &'static str, name: &str) {
    if enabled() {
        push(Event { cat, name: name.to_string().into(), ts: us_since_epoch(Instant::now()), dur: None, args: None });
    }
}

/// A point in time.
#[inline]
pub fn instant(cat: &'static str, name: &'static str, args: impl FnOnce() -> String) {
    if enabled() {
        push(Event { cat, name: name.into(), ts: us_since_epoch(Instant::now()), dur: None, args: Some(args()) });
    }
}

fn escape(s: &str, out: &mut String) {
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            c if (c as u32) < 0x20 => {
                let _ = write!(out, "\\u{:04x}", c as u32);
            }
            c => out.push(c),
        }
    }
}

/// Renders every buffer as trace-event JSON (`args` is `k=v k=v` text, kept as one string under `a`).
fn render() -> String {
    let mut out = String::from("{\"traceEvents\":[\n");
    let threads = THREADS.lock().map(|t| t.clone()).unwrap_or_default();
    let mut first = true;
    let mut sep = |out: &mut String| {
        if !std::mem::take(&mut first) {
            out.push_str(",\n");
        }
    };
    for t in &threads {
        sep(&mut out);
        let _ =
            write!(out, "{{\"ph\":\"M\",\"pid\":1,\"tid\":{},\"name\":\"thread_name\",\"args\":{{\"name\":\"", t.tid);
        escape(&t.name, &mut out);
        out.push_str("\"}}");
        let events = t
            .events
            .lock()
            .map(|e| e.iter().map(|e| (e.cat, e.name.clone(), e.ts, e.dur, e.args.clone())).collect::<Vec<_>>());
        for (cat, name, ts, dur, args) in events.unwrap_or_default() {
            sep(&mut out);
            let _ = write!(
                out,
                "{{\"ph\":\"{}\",\"pid\":1,\"tid\":{},\"cat\":\"{cat}\",\"name\":\"{}\",\"ts\":{ts}",
                if dur.is_some() { 'X' } else { 'i' },
                t.tid,
                name.replace('"', "'")
            );
            if let Some(d) = dur {
                let _ = write!(out, ",\"dur\":{d}");
            } else {
                out.push_str(",\"s\":\"t\"");
            }
            if let Some(a) = args.filter(|a| !a.is_empty()) {
                out.push_str(",\"args\":{\"a\":\"");
                escape(&a, &mut out);
                out.push_str("\"}");
            }
            out.push('}');
        }
    }
    out.push_str("\n]}\n");
    out
}

/// Writes the trace file. Call at exit; safe to call more than once (the last call wins).
pub fn finish() {
    if !enabled() {
        return;
    }
    if let Some(path) = PATH.get() {
        let _ = std::fs::write(path, render());
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spans_render_as_trace_event_json_with_thread_names() {
        ON.store(true, Ordering::Relaxed);
        let _ = EPOCH.set(Instant::now());
        std::thread::Builder::new()
            .name("trace-test".into())
            .spawn(|| {
                let _s = span_args("t", "work", || "clip=\"a\"".into());
                instant("t", "mark", String::new);
            })
            .map(|h| h.join())
            .ok();
        let json = render();
        assert!(json.contains("\"name\":\"work\"") && json.contains("\"ph\":\"X\""), "{json}");
        assert!(json.contains("\"name\":\"mark\"") && json.contains("trace-test"), "{json}");
        assert!(json.contains("clip=\\\"a\\\""), "args are escaped: {json}");
    }

    #[test]
    fn off_by_default_costs_no_span() {
        if !enabled() {
            assert!(span("t", "x").live.is_none());
        }
    }
}
