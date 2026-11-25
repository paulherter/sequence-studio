//! Word timing from cross-attention (portable, so it is tested without an engine): the standard Whisper alignment. The
//! attention weights of the model's alignment heads over the tokens and the 20 ms encoder frames are normalized per frame,
//! median filtered along time, averaged over the heads and fed to dynamic time warping; the path says at which frame each
//! token starts. The token times then go through `whisper_words` like the interpolated ones.

/// Seconds per encoder frame is 20 ms: two centiseconds.
pub const FRAME_CS: i64 = 2;
/// Width of the median filter along time (OpenAI's reference).
pub const MEDIAN_WIDTH: usize = 7;

/// Median filter along one row, the ends reflected (`width` odd).
pub fn median_filter(row: &[f32], width: usize) -> Vec<f32> {
    let n = row.len();
    if n < 2 || width < 3 {
        return row.to_vec();
    }
    let pad = width / 2;
    let at = |i: isize| -> f32 {
        // Reflection without repeating the edge sample (torch's reflect padding).
        let mut i = i;
        let last = n as isize - 1;
        while i < 0 || i > last {
            i = if i < 0 { -i } else { 2 * last - i };
        }
        row[i as usize]
    };
    (0..n as isize)
        .map(|c| {
            let mut w: Vec<f32> = (c - pad as isize..=c + pad as isize).map(at).collect();
            w.sort_by(f32::total_cmp);
            w[w.len() / 2]
        })
        .collect()
}

/// One head's weights (`rows` tokens by `cols` frames, row-major) normalized per frame over the tokens (mean 0, standard
/// deviation 1, population variance) and median filtered along time.
fn prepared(head: &[f32], rows: usize, cols: usize) -> Vec<f32> {
    let mut m = head.to_vec();
    for c in 0..cols {
        let mean = (0..rows).map(|r| m[r * cols + c]).sum::<f32>() / rows as f32;
        let var = (0..rows).map(|r| (m[r * cols + c] - mean).powi(2)).sum::<f32>() / rows as f32;
        let std = var.sqrt().max(1e-6);
        for r in 0..rows {
            m[r * cols + c] = (m[r * cols + c] - mean) / std;
        }
    }
    let mut out = Vec::with_capacity(m.len());
    for r in 0..rows {
        out.extend(median_filter(&m[r * cols..(r + 1) * cols], MEDIAN_WIDTH));
    }
    out
}

/// Dynamic time warping over a cost matrix (`rows` by `cols`, row-major): the cheapest monotonic path from the top left to
/// the bottom right as (row, column) pairs. Ties prefer the diagonal, then a step down, then a step right (the reference).
pub fn dtw(cost: &[f32], rows: usize, cols: usize) -> Vec<(usize, usize)> {
    if rows == 0 || cols == 0 {
        return Vec::new();
    }
    let w = cols + 1;
    let mut total = vec![f32::INFINITY; (rows + 1) * w];
    let mut trace = vec![2u8; (rows + 1) * w];
    total[0] = 0.0;
    for i in 1..=rows {
        for j in 1..=cols {
            let (c0, c1, c2) = (total[(i - 1) * w + j - 1], total[(i - 1) * w + j], total[i * w + j - 1]);
            let (best, t) = if c0 < c1 && c0 < c2 {
                (c0, 0)
            } else if c1 < c0 && c1 < c2 {
                (c1, 1)
            } else {
                (c2, 2)
            };
            total[i * w + j] = cost[(i - 1) * cols + j - 1] + best;
            trace[i * w + j] = t;
        }
    }
    // The first row and column can only be left one way.
    trace[..=cols].fill(2);
    for i in 0..=rows {
        trace[i * w] = 1;
    }
    let (mut i, mut j) = (rows, cols);
    let mut path = Vec::new();
    while i > 0 || j > 0 {
        path.push((i.saturating_sub(1), j.saturating_sub(1)));
        match trace[i * w + j] {
            0 => {
                i -= 1;
                j -= 1;
            }
            1 => i -= 1,
            _ => j -= 1,
        }
    }
    path.reverse();
    path
}

/// Which 20 ms frames of `samples` (16 kHz mono) hold speech: the frame's RMS is above 8 % of the loud frames' level
/// (95th percentile) and above a floor for digital near-silence.
pub fn voiced_frames(samples: &[f32]) -> Vec<bool> {
    const FRAME: usize = 320;
    let rms: Vec<f32> =
        samples.chunks(FRAME).map(|c| (c.iter().map(|v| v * v).sum::<f32>() / c.len().max(1) as f32).sqrt()).collect();
    let mut sorted = rms.clone();
    sorted.sort_by(f32::total_cmp);
    let loud = sorted.get(sorted.len() * 95 / 100).copied().unwrap_or(0.0);
    let limit = (loud * 0.08).max(1e-3);
    let mut voiced: Vec<bool> = rms.iter().map(|r| *r > limit).collect();
    // A click or breath shorter than this is not speech: it would pull the first word of a chunk back into the silence.
    const MIN_RUN: usize = 5;
    let mut i = 0;
    while i < voiced.len() {
        if !voiced[i] {
            i += 1;
            continue;
        }
        let end = voiced[i..].iter().position(|v| !*v).map_or(voiced.len(), |n| i + n);
        if end - i < MIN_RUN {
            voiced[i..end].fill(false);
        }
        i = end;
    }
    voiced
}

/// A time span (centiseconds from the chunk start) cut back to the speech inside it: the start moves forward to the first
/// voiced frame and the end back behind the last one, each with one frame of margin. The span is left alone when it holds no
/// voiced frame: it then has no time of its own (zero length at its start; a word takes its end from its last token, so a
/// trailing "." in the pause after the word no longer stretches it). Without any voiced frame at all nothing changes.
pub fn trim_to_voice(start_cs: i64, end_cs: i64, voiced: &[bool]) -> (i64, i64) {
    if end_cs <= start_cs || !voiced.iter().any(|v| *v) {
        return (start_cs, end_cs);
    }
    let from = usize::try_from(start_cs.max(0) / FRAME_CS).unwrap_or(0).min(voiced.len());
    let to = usize::try_from((end_cs + FRAME_CS - 1) / FRAME_CS).unwrap_or(0).min(voiced.len());
    let slice = voiced.get(from..to).unwrap_or(&[]);
    let (Some(first), Some(last)) = (slice.iter().position(|v| *v), slice.iter().rposition(|v| *v)) else {
        return (start_cs, start_cs);
    };
    let first = (from + first).saturating_sub(1) as i64 * FRAME_CS;
    let last = (from + last + 2) as i64 * FRAME_CS;
    (start_cs.max(first), end_cs.min(last).max(start_cs.max(first)))
}

/// Voiced frames of a whole recording, measured per 30 s chunk (the loudness reference of `voiced_frames` is local, so a quiet
/// passage next to a loud one keeps its own speech frames).
pub fn voiced_frames_chunked(samples: &[f32]) -> Vec<bool> {
    samples.chunks(crate::whisper_mel::CHUNK_SAMPLES).flat_map(voiced_frames).collect()
}

/// A pause inside one word that is still bridged (centiseconds): longer silence ends the word.
pub const WORD_HOLD_CS: i64 = 20;

/// The end of a word (centiseconds from the start of `voiced`) that starts at `start_cs` and was given `end_cs`: the end of
/// the voiced run that begins at the start, bridging gaps up to `WORD_HOLD_CS`, plus one frame of margin. Alignment can run a
/// word's end on to the next word's start across a pause (or even into that word's voice); this cuts it back to where the
/// voice stops. Never later than `end_cs`, never before `start_cs`; unchanged when the span holds no voiced frame.
pub fn word_end_in_voice(start_cs: i64, end_cs: i64, voiced: &[bool]) -> i64 {
    if end_cs <= start_cs {
        return end_cs;
    }
    let from = usize::try_from(start_cs.max(0) / FRAME_CS).unwrap_or(0);
    let to = usize::try_from((end_cs + FRAME_CS - 1) / FRAME_CS).unwrap_or(0).min(voiced.len());
    let hold = usize::try_from(WORD_HOLD_CS / FRAME_CS).unwrap_or(0);
    let (mut last, mut gap) = (None, 0usize);
    for (f, &v) in voiced.iter().enumerate().take(to).skip(from) {
        if v {
            (last, gap) = (Some(f), 0);
        } else if last.is_some() {
            gap += 1;
            if gap > hold {
                break;
            }
        }
    }
    let Some(last) = last else { return end_cs };
    end_cs.min((last as i64 + 2) * FRAME_CS).max(start_cs)
}

/// The frame at which the alignment path enters each row (token). `heads` are the selected heads' weights, each `rows` by
/// `cols` row-major (`cols` = the frames that hold audio). `None` for an empty or odd shape.
pub fn entry_frames(heads: &[Vec<f32>], rows: usize, cols: usize) -> Option<Vec<usize>> {
    if heads.is_empty() || rows == 0 || cols == 0 || heads.iter().any(|h| h.len() != rows * cols) {
        return None;
    }
    let prep: Vec<Vec<f32>> = heads.iter().map(|h| prepared(h, rows, cols)).collect();
    let cost: Vec<f32> =
        (0..rows * cols).map(|k| -prep.iter().map(|h| h[k]).sum::<f32>() / prep.len() as f32).collect();
    let path = dtw(&cost, rows, cols);
    let mut entry = vec![0usize; rows];
    let mut seen = 0usize;
    for (k, (r, c)) in path.iter().enumerate() {
        // Rows are visited in order: the first path point of a row is where it starts.
        if (k == 0 || *r != path[k - 1].0) && *r < rows {
            entry[*r] = *c;
            seen += 1;
        }
    }
    (seen == rows).then_some(entry)
}

/// Start and end (centiseconds from the chunk start) of each of `n_tokens` text tokens. `entry` holds the entry frame of
/// the `n_tokens + 1` rows (one before the first token, whose row predicts it, up to the row that predicts the end); with
/// one row fewer the last token ends at `end_frame`.
pub fn token_times(entry: &[usize], n_tokens: usize, end_frame: usize) -> Vec<(i64, i64)> {
    (0..n_tokens)
        .map(|k| {
            let s = entry.get(k).copied().unwrap_or(end_frame);
            let e = entry.get(k + 1).copied().unwrap_or(end_frame).max(s);
            (s as i64 * FRAME_CS, e as i64 * FRAME_CS)
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::word_end_in_voice;

    #[test]
    fn word_end_stops_at_the_voice_and_ignores_voice_after_a_long_pause() {
        let mut v = vec![false; 600];
        v[0..30].fill(true); // 0-0.6 s
        v[300..320].fill(true); // the next word, after a pause
        assert_eq!(word_end_in_voice(0, 600, &v), 62);
        assert_eq!(word_end_in_voice(0, 40, &v), 40, "never later than the given end");
        assert_eq!(word_end_in_voice(100, 200, &v), 200, "no voice in the span: unchanged");
        v[34..40].fill(true); // a 0.08 s gap is bridged
        assert_eq!(word_end_in_voice(0, 600, &v), 82);
    }

    #[test]
    fn a_short_click_is_not_voiced_but_a_word_is() {
        let mut samples = vec![0.0f32; 320 * 100];
        samples[320 * 10..320 * 12].fill(0.5); // 2 frames: a click
        samples[320 * 50..320 * 70].fill(0.5); // 20 frames: speech
        let v = voiced_frames(&samples);
        assert!(!v[10] && !v[11]);
        assert!(v[50] && v[69]);
    }

    use super::*;

    #[test]
    fn the_median_filter_removes_spikes_and_reflects_the_ends() {
        let r = [0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 0.0];
        assert_eq!(median_filter(&r, 3), vec![0.0; 7]);
        // A ramp stays a ramp; the ends reflect (1,2,3 around 0 -> 3,2,1,0,1,2,3).
        let ramp: Vec<f32> = (0..7).map(|i| i as f32).collect();
        assert_eq!(median_filter(&ramp, 7), vec![2.0, 2.0, 2.0, 3.0, 4.0, 4.0, 4.0]);
        assert_eq!(median_filter(&[5.0], 7), vec![5.0]);
    }

    #[test]
    fn dtw_follows_the_diagonal_band_of_a_cheap_path() {
        // 3 tokens x 6 frames, cheap (0) cells: token 0 frames 0-1, token 1 frames 2-3, token 2 frames 4-5.
        let mut cost = vec![1.0f32; 18];
        for (r, c) in [(0, 0), (0, 1), (1, 2), (1, 3), (2, 4), (2, 5)] {
            cost[r * 6 + c] = 0.0;
        }
        let path = dtw(&cost, 3, 6);
        assert_eq!(path, vec![(0, 0), (0, 1), (1, 2), (1, 3), (2, 4), (2, 5)]);
        assert!(dtw(&[], 0, 0).is_empty());
    }

    /// Weights with one peak per row: row k (the query that predicts token k) looks at the frames of token k (0-7, 8-15,
    /// 16-27 of 30; the median filter would erase a narrower peak); the last row (it predicts the end) looks at the end.
    fn peaked() -> Vec<f32> {
        let spans = [(0usize, 8usize), (8, 16), (16, 28), (28, 30)];
        let mut m = vec![0.1f32; 4 * 30];
        for (r, (a, b)) in spans.iter().enumerate() {
            for c in *a..*b {
                m[r * 30 + c] = 1.0;
            }
        }
        m
    }

    #[test]
    fn entry_frames_find_where_each_token_starts() {
        let heads = vec![peaked(), peaked()];
        let e = entry_frames(&heads, 4, 30).unwrap();
        assert_eq!(e.len(), 4);
        assert_eq!(e[0], 0);
        assert!(e.windows(2).all(|w| w[0] <= w[1]), "{e:?}");
        // Token 1 starts at frame 8, token 2 at frame 16 (the median filter may move an edge by a frame).
        assert!(e[1].abs_diff(8) <= 1 && e[2].abs_diff(16) <= 1 && e[3] >= 27, "{e:?}");
        assert!(entry_frames(&[], 4, 30).is_none());
        assert!(entry_frames(&[vec![0.0; 5]], 4, 30).is_none());
    }

    #[test]
    fn token_times_are_twenty_milliseconds_per_frame() {
        let t = token_times(&[0, 2, 5, 9], 3, 10);
        assert_eq!(t, vec![(0, 4), (4, 10), (10, 18)]);
        // One row fewer: the last token ends at the end frame.
        assert_eq!(token_times(&[0, 2, 5], 3, 10), vec![(0, 4), (4, 10), (10, 20)]);
    }
}
