// Swift: Captions+Words.swift (item level; the track and timeline verbs are in caption_items.rs)
//! Word-level caption editing (captions are corrected directly on the caption track): edit, delete and insert a word,
//! join with a neighbor, search and replace. All of it keeps the word timings the caption carries (`CaptionItem::words`,
//! relative to the caption's start); a caption without timings stays without them (its words keep spreading over the range
//! by length) until a word edge is dragged.

use crate::caption_item::char_count;
use sq_core_model::{CaptionItem, CaptionWord};
use sq_core_time::{Id, Time, TimeRange, text::graphemes, word_segmentation};
use std::ops::{Range, RangeInclusive};

/// The caption before or after one on the same track.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum CaptionNeighbor {
    /// The one before.
    Previous,
    /// The one after.
    Next,
}

/// One find result on a caption track.
#[derive(Clone, Debug, PartialEq)]
pub struct CaptionTextMatch {
    /// The track.
    pub track: Id,
    /// The caption.
    pub caption: Id,
    /// Index into `CaptionItem::lines`.
    pub line: usize,
    /// Character offsets of the match in that line.
    pub range: Range<usize>,
    /// The words (indices into `CaptionItem::tokens`) the match touches.
    pub words: RangeInclusive<usize>,
    /// Start of the caption (matches are listed in time order).
    pub time: Time,
}

/// One find result inside a caption.
#[derive(Clone, Debug, PartialEq)]
pub struct ItemMatch {
    /// Index into `lines`.
    pub line: usize,
    /// Character offsets of the match in that line.
    pub range: Range<usize>,
    /// The words the match touches.
    pub words: RangeInclusive<usize>,
}

/// The shortest a refitted word gets (one tick): a word must stay something that can be drawn, grabbed and lit.
pub const WORD_TICK: Time = Time::new(1, 1000);

/// Absolute words made relative to `range.start`, clamped into the range.
pub fn relative_words(words: &[CaptionWord], range: &TimeRange) -> Vec<CaptionWord> {
    words
        .iter()
        .map(|w| {
            let a = w.range.start.max(range.start).min(range.end());
            let b = w.range.end().max(a).min(range.end());
            CaptionWord {
                text: w.text.clone(),
                range: TimeRange::from_end(a - range.start, b - range.start),
                confidence: w.confidence,
            }
        })
        .collect()
}

/// `words` spread over `span` by their length (the same rule as `effective_words` without timings). When that would leave
/// a word shorter than a tick, they share the span evenly instead.
pub fn spread(toks: &[String], span: &TimeRange) -> Vec<CaptionWord> {
    let total: i64 = toks.iter().map(|t| char_count(t).max(1)).sum();
    let mut cum = 0_i64;
    let by_length: Vec<CaptionWord> = toks
        .iter()
        .map(|tok| {
            let a = cum;
            cum += char_count(tok).max(1);
            let at = |n: i64| {
                if n == total {
                    span.end()
                } else {
                    (span.start + Time::scaled_int(span.duration, n, total)).max(span.start).min(span.end())
                }
            };
            let s = at(a);
            CaptionWord { text: tok.clone(), range: TimeRange::from_end(s, at(cum).max(s)), confidence: None }
        })
        .collect();
    if by_length.iter().any(|w| w.range.duration < WORD_TICK) { even(toks, span) } else { by_length }
}

/// `words` sharing `span` in equal parts.
pub fn even(toks: &[String], span: &TimeRange) -> Vec<CaptionWord> {
    let n = toks.len() as i64;
    let at = |i: i64| if i == n { span.end() } else { span.start + Time::scaled_int(span.duration, i, n) };
    toks.iter()
        .enumerate()
        .map(|(i, tok)| CaptionWord {
            text: tok.clone(),
            range: TimeRange::from_end(at(i as i64), at(i as i64 + 1)),
            confidence: None,
        })
        .collect()
}

/// The timings after the words `r` of `old` were replaced by `new`. Every other word keeps its time.
/// - same count: one to one, only the text changes;
/// - other count: the new words share the time span of the replaced ones by their length;
/// - insertion (`r` empty): the new words take the pause between the neighbors; without a pause they take the second half
///   of the word before (the first half of the word after, at the very start);
/// - no word ends up without a duration: when the span is shorter than a tick per word, the new words and their neighbors
///   (one more on each side until there is room, at last the whole caption) share their span evenly.
pub fn refit(old: &[CaptionWord], r: Range<usize>, new: &[String], duration: Time) -> Vec<CaptionWord> {
    let mut out: Vec<CaptionWord> = old[..r.start].to_vec();
    let mut tail: Vec<CaptionWord> = old[r.end..].to_vec();
    if new.is_empty() {
        out.extend(tail);
        return out;
    }
    if !r.is_empty() && new.len() == r.len() {
        out.extend(new.iter().zip(&old[r]).map(|(n, o)| CaptionWord {
            text: n.clone(),
            range: o.range,
            confidence: if *n == o.text { o.confidence } else { None },
        }));
        out.extend(tail);
        return out;
    }
    let mut span: TimeRange;
    if r.is_empty() {
        let lo = out.last().map_or(Time::ZERO, |w| w.range.end());
        let hi = tail.first().map_or(duration.max(lo), |w| w.range.start);
        if hi > lo {
            span = TimeRange::from_end(lo, hi);
        } else if let Some(p) = out.last().filter(|p| p.range.duration > Time::ZERO).cloned() {
            let mid = p.range.start + p.range.duration.halved();
            if let Some(l) = out.last_mut() {
                l.range = TimeRange::from_end(p.range.start, mid);
            }
            span = TimeRange::from_end(mid, p.range.end());
        } else if let Some(n) = tail.first().filter(|n| n.range.duration > Time::ZERO).cloned() {
            let mid = n.range.start + n.range.duration.halved();
            tail[0].range = TimeRange::from_end(mid, n.range.end());
            span = TimeRange::from_end(n.range.start, mid);
        } else {
            span = TimeRange::new(lo, Time::ZERO);
        }
    } else {
        let a = old[r.start].range.start;
        span = TimeRange::from_end(a, old[r.end - 1].range.end().max(a));
    }
    // Too short for its words: take the neighbors in and share.
    let mut pool: Vec<String> = new.to_vec();
    let mut widened = false;
    let mut pool_confidence: Vec<Option<f32>> = vec![None; new.len()]; // the new words are unconfirmed-free: None
    let too_short = |span: &TimeRange, n: usize| span.duration < WORD_TICK * n as i64;
    while too_short(&span, pool.len()) && !(out.is_empty() && tail.is_empty()) {
        widened = true;
        if let Some(p) = out.pop() {
            pool.insert(0, p.text);
            pool_confidence.insert(0, p.confidence);
            span = TimeRange::from_end(p.range.start.min(span.start), p.range.end().max(span.end()));
        }
        if !tail.is_empty() {
            let n = tail.remove(0);
            pool.push(n.text);
            pool_confidence.push(n.confidence);
            span = TimeRange::from_end(n.range.start.min(span.start), n.range.end().max(span.end()));
        }
    }
    if too_short(&span, pool.len()) && duration > Time::ZERO {
        widened = true;
        span = TimeRange::from_end(Time::ZERO, duration);
    }
    let mut fitted = if widened { even(&pool, &span) } else { spread(&pool, &span) };
    for (f, c) in fitted.iter_mut().zip(pool_confidence) {
        f.confidence = c;
    }
    out.extend(fitted);
    out.extend(tail);
    out
}

/// Character spans of the words of a line.
fn word_spans(chars: &[&str]) -> Vec<Range<usize>> {
    word_segmentation::spans(chars)
}

fn is_space(g: &str) -> bool {
    g.chars().all(char::is_whitespace)
}

/// Word editing on a caption.
pub trait CaptionWordEditExt {
    /// Replaces the words `r` (indices into `tokens`, empty = insert before `r.start`) by `new`. Line breaks are kept: the
    /// new words stand on the line of the first replaced word (an inserted word on the line of the word before it). A line
    /// left without words disappears. Timings follow by `refit`.
    fn replace_tokens(&mut self, r: Range<usize>, new: &[String]);
    /// New text with the timings following it: the words both texts share at the start and at the end keep their time, the
    /// changed middle is refitted (`refit`). Without timings the caption stays without them.
    fn set_lines_refitting_words(&mut self, new_lines: Vec<String>);
    /// Replaces the characters `r` of line `line`. The timings follow by position, not by text: a word that stands whole
    /// before or after the replaced characters keeps its time, only the words the replacement touches are refitted. A line
    /// left without words disappears; a caption left without words is for the caller to remove. Out-of-range input is
    /// ignored (false).
    fn replace_characters(&mut self, r: Range<usize>, line: usize, new: &str) -> bool;
    /// Every match of `find`, line by line, left to right, not overlapping. The case option is the only one (no diacritic
    /// folding), so what is counted is what a replace changes.
    fn text_matches(&self, find: &str, case_sensitive: bool) -> Vec<ItemMatch>;
}

impl CaptionWordEditExt for CaptionItem {
    fn replace_tokens(&mut self, r: Range<usize>, new: &[String]) {
        let timed = self.has_word_timings();
        let old = self.words.clone();
        // Each word remembers whether whitespace stood before it, so untouched words keep their spacing (CJK has none);
        // `None` = first of its line, the seam rule decides.
        let mut per_line: Vec<Vec<(String, Option<bool>)>> = self
            .lines
            .iter()
            .map(|line| {
                let chars: Vec<&str> = graphemes(line).collect();
                word_spans(&chars)
                    .into_iter()
                    .map(|sp| {
                        let gap = (sp.start > 0).then(|| is_space(chars[sp.start - 1]));
                        (chars[sp].concat(), gap)
                    })
                    .collect()
            })
            .collect();
        let mut flat: Vec<(usize, usize)> = Vec::new();
        for (l, toks) in per_line.iter().enumerate() {
            for k in 0..toks.len() {
                flat.push((l, k));
            }
        }
        if r.end > flat.len() || r.start > r.end {
            return;
        }
        let target: (usize, usize);
        if !r.is_empty() {
            target = flat[r.start];
        } else if r.start > 0 {
            let p = flat[r.start - 1];
            target = (p.0, p.1 + 1);
        } else if let Some(f) = flat.first() {
            target = *f;
        } else {
            if per_line.is_empty() {
                per_line = vec![Vec::new()];
            }
            target = (0, 0);
        }
        // The first new word takes the spacing of the first word it replaces.
        let inherited: Option<bool> = if r.is_empty() { None } else { per_line[flat[r.start].0][flat[r.start].1].1 };
        for i in r.clone().rev() {
            per_line[flat[i].0].remove(flat[i].1);
        }
        let mut fresh: Vec<(String, Option<bool>)> = new.iter().map(|w| (w.clone(), None)).collect();
        if let Some(f) = fresh.first_mut() {
            f.1 = inherited;
        }
        let at = target.1.min(per_line[target.0].len());
        per_line[target.0].splice(at..at, fresh);
        let rebuilt: Vec<String> = per_line
            .iter()
            .filter(|l| !l.is_empty())
            .map(|line| {
                let mut s = String::new();
                for (text, gap) in line {
                    if !s.is_empty() && gap.unwrap_or_else(|| !word_segmentation::is_tight(&s, text)) {
                        s.push(' ');
                    }
                    s.push_str(text);
                }
                s
            })
            .collect();
        self.lines = if rebuilt.is_empty() { vec![String::new()] } else { rebuilt };
        self.words = if timed { refit(&old, r, new, self.range.duration) } else { Vec::new() };
    }

    fn set_lines_refitting_words(&mut self, new_lines: Vec<String>) {
        let timed = self.has_word_timings();
        let old_toks = self.tokens();
        let old = std::mem::take(&mut self.words);
        self.lines = new_lines;
        if !timed {
            return;
        }
        let new = self.tokens();
        let n = old_toks.len().min(new.len());
        let mut p = 0;
        while p < n && old_toks[p] == new[p] {
            p += 1;
        }
        let mut s = 0;
        while s + p < n && old_toks[old_toks.len() - 1 - s] == new[new.len() - 1 - s] {
            s += 1;
        }
        self.words = refit(&old, p..(old_toks.len() - s), &new[p..(new.len() - s)], self.range.duration);
    }

    fn replace_characters(&mut self, r: Range<usize>, line: usize, new: &str) -> bool {
        if line >= self.lines.len() {
            return false;
        }
        let chars: Vec<&str> = graphemes(&self.lines[line]).collect();
        if r.end > chars.len() || r.start > r.end {
            return false;
        }
        let timed = self.has_word_timings();
        let old = self.words.clone();
        let base: usize = self.lines[..line].iter().map(|l| word_segmentation::spans_of(l).len()).sum();
        let new_chars: Vec<&str> = graphemes(new).collect();
        let after: Vec<&str> = chars[..r.start].iter().chain(&new_chars).chain(&chars[r.end..]).copied().collect();
        let was = word_spans(&chars);
        let now = word_spans(&after);
        let shift = new_chars.len() as i64 - r.len() as i64;
        let shared = was.len().min(now.len());
        let mut p = 0;
        while p < shared && was[p].end <= r.start && now[p] == was[p] {
            p += 1;
        }
        let mut s = 0;
        while s + p < shared {
            let (a, b) = (&was[was.len() - 1 - s], &now[now.len() - 1 - s]);
            let moved = |x: usize| (x as i64 + shift) as usize;
            if a.start < r.end || *b != (moved(a.start)..moved(a.end)) {
                break;
            }
            s += 1;
        }
        let fresh: Vec<String> = now[p..(now.len() - s)].iter().map(|sp| after[sp.clone()].concat()).collect();
        self.lines[line] = after.concat();
        self.lines.retain(|l| !graphemes(l).all(is_space));
        if self.lines.is_empty() {
            self.lines = vec![String::new()];
        }
        self.words = if timed {
            refit(&old, (base + p)..(base + was.len() - s), &fresh, self.range.duration)
        } else {
            Vec::new()
        };
        true
    }

    fn text_matches(&self, find: &str, case_sensitive: bool) -> Vec<ItemMatch> {
        if find.is_empty() {
            return Vec::new();
        }
        let fold = |g: &str| if case_sensitive { g.to_string() } else { g.to_lowercase() };
        let needle: Vec<String> = graphemes(find).map(fold).collect();
        let mut out = Vec::new();
        let mut base = 0;
        for (li, line) in self.lines.iter().enumerate() {
            let chars: Vec<&str> = graphemes(line).collect();
            let spans = word_segmentation::spans(&chars);
            let hay: Vec<String> = chars.iter().map(|g| fold(g)).collect();
            let mut i = 0;
            while i + needle.len() <= hay.len() {
                if hay[i..i + needle.len()] != needle[..] {
                    i += 1;
                    continue;
                }
                let (a, b) = (i, i + needle.len());
                let touched: Vec<usize> =
                    (0..spans.len()).filter(|k| spans[*k].end > a && spans[*k].start < b).collect();
                let last = spans.len().saturating_sub(1);
                let lo = touched
                    .first()
                    .copied()
                    .unwrap_or_else(|| spans.iter().position(|s| s.start >= a).unwrap_or(last).min(last));
                let hi = touched.last().copied().unwrap_or(lo);
                out.push(ItemMatch { line: li, range: a..b, words: (base + lo)..=(base + hi) });
                i = b;
            }
            base += spans.len();
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::caption_item::tests::{item, range, word};

    fn strs(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }
    fn timed(text: &str, words: &[(&str, i64, i64)]) -> CaptionItem {
        let mut c = item(&[text], range(0, 3000));
        c.words = words.iter().map(|(s, a, b)| word(s, *a, *b)).collect();
        c
    }
    fn texts(c: &CaptionItem) -> Vec<&str> {
        c.words.iter().map(|w| w.text.as_str()).collect()
    }

    #[test]
    fn replacing_a_word_keeps_every_other_time() {
        let mut c = timed("one two three", &[("one", 0, 1000), ("two", 1000, 2000), ("three", 2000, 3000)]);
        c.replace_tokens(1..2, &strs(&["deux"]));
        assert_eq!(c.lines, vec!["one deux three"]);
        assert_eq!(texts(&c), vec!["one", "deux", "three"]);
        assert_eq!(c.words[1].range, range(1000, 2000));
        assert_eq!((c.words[0].range, c.words[2].range), (range(0, 1000), range(2000, 3000)));
    }

    #[test]
    fn deleting_a_word_turns_its_time_into_a_pause() {
        let mut c = timed("one two three", &[("one", 0, 1000), ("two", 1000, 2000), ("three", 2000, 3000)]);
        c.replace_tokens(1..2, &[]);
        assert_eq!(c.lines, vec!["one three"]);
        assert_eq!(texts(&c), vec!["one", "three"]);
        assert_eq!((c.words[0].range, c.words[1].range), (range(0, 1000), range(2000, 3000)));
    }

    #[test]
    fn a_split_word_shares_its_time_by_length() {
        let mut c = timed("one twothree", &[("one", 0, 1000), ("twothree", 1000, 3000)]);
        c.replace_tokens(1..2, &strs(&["two", "three"]));
        assert_eq!(texts(&c), vec!["one", "two", "three"]);
        assert_eq!(c.words[1].range, range(1000, 1750)); // 3 of 8 characters
        assert_eq!(c.words[2].range, range(1750, 3000));
    }

    #[test]
    fn an_inserted_word_takes_the_pause_or_half_of_the_word_before() {
        let mut c = timed("one three", &[("one", 0, 1000), ("three", 2000, 3000)]);
        c.replace_tokens(1..1, &strs(&["two"]));
        assert_eq!(c.words[1], word("two", 1000, 2000)); // the pause between the neighbors
        let mut d = timed("one three", &[("one", 0, 1000), ("three", 1000, 3000)]);
        d.replace_tokens(1..1, &strs(&["two"]));
        assert_eq!((d.words[0].range, d.words[1].range), (range(0, 500), range(500, 1000)));
    }

    #[test]
    fn an_untimed_caption_stays_untimed() {
        let mut c = item(&["one two"], range(0, 2000));
        c.replace_tokens(0..1, &strs(&["uno"]));
        assert!(c.words.is_empty());
        assert_eq!(c.lines, vec!["uno two"]);
    }

    #[test]
    fn line_breaks_are_kept_and_an_emptied_line_disappears() {
        let mut c = item(&["one two", "three"], range(0, 3000));
        c.replace_tokens(2..3, &[]);
        assert_eq!(c.lines, vec!["one two"]);
        let mut d = item(&["one two", "three"], range(0, 3000));
        d.replace_tokens(1..2, &strs(&["a", "b"]));
        assert_eq!(d.lines, vec!["one a b", "three"]);
        let mut e = item(&["only"], range(0, 1000));
        e.replace_tokens(0..1, &[]);
        assert_eq!(e.lines, vec![""]);
    }

    #[test]
    fn a_word_squeezed_below_a_tick_widens_to_its_neighbors() {
        let mut c = timed("a b", &[("a", 0, 1000), ("b", 1000, 1000)]);
        c.replace_tokens(1..2, &strs(&["x", "y"]));
        assert!(c.words.iter().all(|w| w.range.duration >= WORD_TICK));
        assert_eq!(texts(&c), vec!["a", "x", "y"]);
    }

    #[test]
    fn editing_the_text_keeps_shared_ends_and_confidence_only_of_unchanged_words() {
        let mut c = timed("so um yes", &[("so", 0, 500), ("um", 1000, 1400), ("yes", 2000, 2300)]);
        c.words[0].confidence = Some(0.2);
        c.words[1].confidence = Some(0.1);
        c.set_lines_refitting_words(strs(&["so uh yes"]));
        assert_eq!(texts(&c), vec!["so", "uh", "yes"]);
        assert_eq!((c.words[0].confidence, c.words[1].confidence), (Some(0.2), None));
        assert_eq!((c.words[1].range, c.words[2].range), (range(1000, 1400), range(2000, 2300)));
        let mut u = item(&["a b"], range(0, 1000));
        u.set_lines_refitting_words(strs(&["a b c"]));
        assert!(u.words.is_empty());
    }

    #[test]
    fn replacing_characters_refits_only_the_words_it_touches() {
        // "the the cat" with the first "the " removed: the second "the" keeps its own time.
        let mut c = timed("the the cat", &[("the", 0, 500), ("the", 500, 1000), ("cat", 1000, 1500)]);
        assert!(c.replace_characters(0..4, 0, ""));
        assert_eq!(c.lines, vec!["the cat"]);
        assert_eq!(texts(&c), vec!["the", "cat"]);
        assert_eq!((c.words[0].range, c.words[1].range), (range(500, 1000), range(1000, 1500)));
        assert!(!c.replace_characters(0..99, 0, "x"));
        assert!(!c.replace_characters(0..1, 5, "x"));
    }

    #[test]
    fn matches_are_found_per_line_with_their_words() {
        let c = item(&["Cat and cat", "a CAT"], range(0, 1000));
        let m = c.text_matches("cat", false);
        assert_eq!(
            m,
            vec![
                ItemMatch { line: 0, range: 0..3, words: 0..=0 },
                ItemMatch { line: 0, range: 8..11, words: 2..=2 },
                ItemMatch { line: 1, range: 2..5, words: 4..=4 },
            ]
        );
        assert_eq!(c.text_matches("cat", true).len(), 1);
        assert!(c.text_matches("", false).is_empty());
    }

    #[test]
    fn relative_words_are_clamped_into_the_range() {
        let w = [word("a", 500, 900), word("b", 1900, 2600)];
        let r = relative_words(&w, &range(1000, 2000));
        assert_eq!((r[0].range, r[1].range), (range(0, 0), range(900, 1000)));
    }
}
