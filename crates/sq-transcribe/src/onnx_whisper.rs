//! The portable speech engine: Whisper tiny/base/small as ONNX (encoder + merged decoder with key/value cache) on ONNX Runtime
//! through `sq-onnx`, features and tokenizer in Rust. It plugs in as a `TranscriptionService` exactly like the Mac's Speech
//! framework backend, so Auto Captions, status text and cancel work the same.
//!
//! Timing: the model's own timestamp tokens (20 ms steps) give segment times. With a `*_timestamped` export (its decoder returns
//! cross-attentions, `generation_config.json` lists the alignment heads) the words get real times: a second teacher-forced pass
//! over the chunk's text returns the heads' attention, `whisper_align` runs the standard normalize / median filter / DTW and the
//! token times are kept inside their segment. Without attentions (a model downloaded under the earlier Xenova pin, or a failed
//! pass) the words inside a segment get interpolated times in proportion to their text length (`timed_tokens`).

use crate::onnx_whisper_store::{CurlDownloader, OnnxWhisperStore};
use crate::transcript::Transcript;
use crate::transcription_service::{CancelToken, Locale, TranscriptionError, TranscriptionService};
use crate::whisper_align;
use crate::whisper_languages::WhisperLanguages;
use crate::whisper_mel::{CHUNK_SAMPLES, LogMel, N_FRAMES, SAMPLE_RATE};
use crate::whisper_model_store::ModelDownloader;
use crate::whisper_tokenizer::WhisperTokenizer;
use crate::whisper_transcriber::AudioReader;
use crate::whisper_words::{self, WhisperToken};
use sq_core_model::AudioChannelMap;
use sq_core_time::IdSource;
use sq_onnx::onnx_model::{OnnxModel, TensorData, TypedTensor};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{Arc, Mutex, PoisonError};

/// A chunk's length in centiseconds.
const CHUNK_CS: i64 = 3000;
/// Most text tokens of one 30 second chunk (the model's context is 448 including the prompt).
const MAX_TOKENS: usize = 224;
/// The first timestamp of a chunk may be at most 1 second in.
const MAX_INITIAL_TIMESTAMP: i64 = 50;

/// Token constraints of Whisper's timestamp decoding, applied to the logits of the next token.
pub(crate) struct Rules<'a> {
    pub eot: i64,
    pub timestamp_begin: i64,
    pub no_timestamps: i64,
    pub suppress: &'a [i64],
    pub begin_suppress: &'a [i64],
}

impl Rules<'_> {
    /// Masks `logits` (one row over the vocabulary) for the next token after `sampled` (tokens chosen so far, the prompt excluded).
    pub(crate) fn apply(&self, logits: &mut [f32], sampled: &[i64]) {
        let ts = usize::try_from(self.timestamp_begin).unwrap_or(0).min(logits.len());
        let eot = usize::try_from(self.eot).unwrap_or(0).min(logits.len());
        for id in self.suppress.iter().chain([&self.no_timestamps]) {
            if let Some(l) = usize::try_from(*id).ok().filter(|i| *i < ts) {
                mask(logits, l..l + 1);
            }
        }
        // Control tokens between the end mark and the first timestamp are never spoken.
        mask(logits, eot + 1..ts);
        if sampled.is_empty() {
            for id in self.begin_suppress {
                if let Some(l) = usize::try_from(*id).ok().filter(|i| *i < ts) {
                    mask(logits, l..l + 1);
                }
            }
        }
        let is_ts = |t: i64| t >= self.timestamp_begin;
        let last_was_ts = sampled.last().is_some_and(|t| is_ts(*t));
        let penultimate_was_ts = sampled.len() < 2 || is_ts(sampled[sampled.len() - 2]);
        if last_was_ts {
            if penultimate_was_ts {
                mask(logits, ts..logits.len()); // a pair is complete: text (or the end) comes next
            } else {
                mask(logits, 0..eot); // one timestamp open: a timestamp or the end comes next
            }
        }
        if let Some(last) = sampled.iter().rev().find(|t| is_ts(**t)) {
            // Timestamps never go backwards; a closing one may repeat, an opening one must move on.
            let floor = if last_was_ts && !penultimate_was_ts { *last } else { *last + 1 };
            mask(logits, ts..usize::try_from(floor).unwrap_or(ts).min(logits.len()).max(ts));
        }
        if sampled.is_empty() {
            mask(logits, 0..ts);
            let limit = usize::try_from(self.timestamp_begin + MAX_INITIAL_TIMESTAMP + 1).unwrap_or(logits.len());
            mask(logits, limit.min(logits.len())..logits.len());
        }
        // If timestamps together are likelier than any single text token, a timestamp it is.
        let lse = |slice: &[f32]| -> f32 {
            let m = slice.iter().copied().fold(f32::NEG_INFINITY, f32::max);
            if m == f32::NEG_INFINITY { m } else { m + slice.iter().map(|v| (v - m).exp()).sum::<f32>().ln() }
        };
        let all = lse(logits);
        let ts_mass = lse(&logits[ts..]) - all;
        let best_text = logits[..ts].iter().copied().fold(f32::NEG_INFINITY, f32::max) - all;
        if ts_mass > best_text {
            mask(logits, 0..ts);
        }
    }
}

/// Sets `logits[range]` to minus infinity.
fn mask(logits: &mut [f32], range: std::ops::Range<usize>) {
    for l in &mut logits[range] {
        *l = f32::NEG_INFINITY;
    }
}

/// Index and probability of the best token (softmax over the masked logits).
fn pick(logits: &[f32]) -> (i64, f32) {
    let (mut best, mut best_v) = (0usize, f32::NEG_INFINITY);
    for (i, v) in logits.iter().enumerate() {
        if *v > best_v {
            best = i;
            best_v = *v;
        }
    }
    let sum: f32 = logits.iter().map(|v| (v - best_v).exp()).sum();
    (best as i64, 1.0 / sum.max(1.0))
}

/// A stretch of text between two timestamps (centiseconds from the chunk start).
#[derive(Clone, Debug, PartialEq)]
pub(crate) struct Segment {
    pub start_cs: i64,
    pub end_cs: i64,
    pub tokens: Vec<(i64, f32)>,
}

/// Cuts the sampled sequence into segments at its timestamp tokens. The second value is where the next window starts
/// (centiseconds from this chunk's start), `None` for the whole chunk (OpenAI whisper's seek rule):
/// - the sequence ends on a single closing timestamp ("text <ts>"): the last segment is closed, the rest of the chunk is silent;
/// - the last segment is open (it ends in text or an opening timestamp): its tokens are dropped and the next window starts at
///   the last complete timestamp, so that speech is decoded again there, never lost and never twice.
///
/// Without a closed segment, or when that timestamp is under a second in, everything is kept and the whole chunk is used.
pub(crate) fn segments(seq: &[(i64, f32)], timestamp_begin: i64, eot: i64) -> (Vec<Segment>, Option<i64>) {
    let cs = |t: i64| (t - timestamp_begin) * 2;
    let mut out = Vec::new();
    let mut start: Option<i64> = None;
    let mut buf: Vec<(i64, f32)> = Vec::new();
    let body: Vec<(i64, f32)> = seq.iter().copied().take_while(|(t, _)| *t != eot).collect();
    for (t, p) in &body {
        if *t >= timestamp_begin {
            if buf.is_empty() {
                start = Some(cs(*t));
            } else {
                out.push(Segment { start_cs: start.unwrap_or(0), end_cs: cs(*t), tokens: std::mem::take(&mut buf) });
                start = None;
            }
        } else {
            buf.push((*t, *p));
        }
    }
    let closed = out.len();
    let open = !buf.is_empty();
    if open {
        out.push(Segment { start_cs: start.unwrap_or(0), end_cs: 3000, tokens: buf });
    }
    let n = body.len();
    let single = n >= 2 && body[n - 1].0 >= timestamp_begin && body[n - 2].0 < timestamp_begin;
    // The last timestamp that closed a segment: the next window can start there without cutting a segment in two.
    let resume = closed.checked_sub(1).map(|i| out[i].end_cs).filter(|cs| *cs >= 100);
    match resume {
        Some(cs) if !single => {
            if open {
                out.truncate(closed);
            }
            (out, Some(cs))
        }
        _ => (out, None),
    }
}

/// Where the next window starts when the model closed its last segment ("single" ending) but the chunk still holds speech
/// after it: that closing timestamp, so the speech is decoded in the next window instead of lost. `None` when the rest is quiet.
pub(crate) fn unspoken_tail(segs: &[Segment], voiced: &[bool]) -> Option<i64> {
    let end_cs = segs.last().filter(|s| s.end_cs < 3000)?.end_cs;
    let from = usize::try_from(end_cs / whisper_align::FRAME_CS).ok()? + 1;
    let loud = voiced.get(from..)?.iter().filter(|v| **v).count();
    // A frame is FRAME_CS long: compare in centiseconds.
    (end_cs >= 100 && loud * usize::try_from(whisper_align::FRAME_CS).ok()? >= MIN_LOST_SPEECH_CS).then_some(end_cs)
}

/// Where the model skipped speech in the middle of a chunk: the first stretch between two tokens that holds at least
/// `MIN_LOST_SPEECH_CS` of voice but no token. `spans` are the (start, end) centiseconds from the chunk start of the chunk's
/// tokens in order, `voiced` its 20 ms voice frames. A speaker who says a sentence twice in one take (a retake after a short
/// pause) makes Whisper write it once, on the first copy's time, and skip the second; decoding again from the start of the
/// skipped voice gives the retake its own words and times. `None` when no such stretch exists. Never before 1 s, so the next
/// window always moves on.
pub(crate) fn lost_speech_inside(spans: &[(i64, i64)], voiced: &[bool]) -> Option<i64> {
    let frame = whisper_align::FRAME_CS;
    let mut prev_end = spans.first()?.1;
    for (start, end) in &spans[1..] {
        if *start > prev_end {
            let from = usize::try_from(prev_end / frame).ok()?;
            let to = usize::try_from(*start / frame).ok()?.min(voiced.len());
            let region = voiced.get(from..to.max(from))?;
            let loud = region.iter().filter(|v| **v).count();
            if i64::try_from(loud).ok()? * frame >= i64::try_from(MIN_LOST_SPEECH_CS).ok()? {
                // The first frame that starts real voice (8 of the next 10 frames), a little before it for the onset.
                let onset = (0..region.len()).find(|i| region[*i..region.len().min(i + 10)].iter().filter(|v| **v).count() >= 8);
                // Speech is dense from its onset to the next token; a pause with room noise or music is patchy or starts
                // late. A gap without such a run is skipped, later gaps are still checked.
                let dense = onset.is_some_and(|i| {
                    let rest = &region[i..];
                    rest.len() * frame as usize >= MIN_LOST_SPEECH_CS
                        && rest.iter().filter(|v| **v).count() * 100 >= rest.len() * MIN_VOICE_DENSITY_PERCENT
                });
                if let (true, Some(i)) = (dense, onset) {
                    let at = i64::try_from(from + i).ok()? * frame;
                    let resume = (at - 20).max(prev_end);
                    if resume >= 100 {
                        return Some(resume);
                    }
                }
            }
        }
        prev_end = prev_end.max(*end);
    }
    None
}

/// The tokens that start before `resume` (centiseconds from the chunk start, `None` = all): the next window decodes the rest
/// again. A word cut in two by `resume` (its first token before, the rest after) is dropped whole, so the next window writes it
/// once, from its beginning.
pub(crate) fn tokens_before(timed: Vec<WhisperToken>, offset_cs: i64, resume: Option<i64>) -> Vec<WhisperToken> {
    let Some(resume) = resume else { return timed };
    let cut = timed.iter().position(|t| t.start_cs - offset_cs >= resume).unwrap_or(timed.len());
    let mut kept = timed;
    let continues = kept.get(cut).is_some_and(|t| !t.bytes.first().is_some_and(|b| matches!(b, 0x20 | 0x0A | 0x09)));
    kept.truncate(cut);
    if continues {
        while let Some(last) = kept.pop() {
            if last.bytes.first().is_some_and(|b| matches!(b, 0x20 | 0x0A | 0x09)) {
                break;
            }
        }
    }
    kept
}

/// The tokens of a segment with times: the segment's span is shared out in proportion to each token's byte length.
pub(crate) fn timed_tokens(seg: &Segment, tok: &WhisperTokenizer, offset_cs: i64, limit_cs: i64) -> Vec<WhisperToken> {
    let text: Vec<(&[u8], f32)> =
        seg.tokens.iter().map(|(t, p)| (tok.token_bytes(*t), *p)).filter(|(b, _)| !b.is_empty()).collect();
    let total: usize = text.iter().map(|(b, _)| b.len()).sum();
    if total == 0 {
        return Vec::new();
    }
    let start = (offset_cs + seg.start_cs).min(limit_cs);
    let end = (offset_cs + seg.end_cs).clamp(start, limit_cs.max(start));
    let span = (end - start) as f64;
    let mut at = 0usize;
    text.iter()
        .map(|(bytes, p)| {
            let t0 = start + (span * at as f64 / total as f64).round() as i64;
            at += bytes.len();
            let t1 = start + (span * at as f64 / total as f64).round() as i64;
            WhisperToken { bytes: bytes.to_vec(), is_special: false, start_cs: t0, end_cs: t1, probability: *p }
        })
        .collect()
}

/// The tokens of a segment with times from the alignment: `times` holds one (start, end) in centiseconds from the chunk start
/// per token of the segment. Each is kept inside the segment and never goes backwards.
pub(crate) fn aligned_tokens(
    seg: &Segment,
    tok: &WhisperTokenizer,
    times: &[(i64, i64)],
    offset_cs: i64,
    limit_cs: i64,
) -> Vec<WhisperToken> {
    let start = (offset_cs + seg.start_cs).min(limit_cs);
    // A segment the model closed where it opened (start == end) says nothing about where its words are; the alignment does,
    // so such a segment only holds them to the chunk. Else the words stay inside the segment.
    let end = if seg.end_cs > seg.start_cs {
        (offset_cs + seg.end_cs).clamp(start, limit_cs.max(start))
    } else {
        limit_cs.max(start).min(offset_cs + CHUNK_CS)
    };
    let start = if seg.end_cs > seg.start_cs { start } else { offset_cs.min(limit_cs) };
    let mut last = start;
    seg.tokens
        .iter()
        .zip(times)
        .filter_map(|((t, p), (t0, t1))| {
            let bytes = tok.token_bytes(*t);
            if bytes.is_empty() {
                return None;
            }
            let s = (offset_cs + t0).clamp(last, end);
            let e = (offset_cs + t1).clamp(s, end);
            last = e;
            Some(WhisperToken { bytes: bytes.to_vec(), is_special: false, start_cs: s, end_cs: e, probability: *p })
        })
        .collect()
}

/// The timed tokens of all segments of a chunk: from the alignment `times` (one per token over all segments, in order) when
/// there are enough of them, else interpolated inside each segment.
pub(crate) fn chunk_tokens(
    segs: &[Segment],
    tok: &WhisperTokenizer,
    times: Option<&[(i64, i64)]>,
    offset_cs: i64,
    limit_cs: i64,
) -> Vec<WhisperToken> {
    let total: usize = segs.iter().map(|s| s.tokens.len()).sum();
    let times = times.filter(|t| t.len() == total);
    let mut used = 0usize;
    let mut out = Vec::new();
    for s in segs {
        let n = s.tokens.len();
        match times {
            Some(t) => out.extend(aligned_tokens(s, tok, &t[used..used + n], offset_cs, limit_cs)),
            None => out.extend(timed_tokens(s, tok, offset_cs, limit_cs)),
        }
        used += n;
    }
    // Segments are aligned one by one: a word never starts before the one before it.
    let mut prev = 0i64;
    for t in &mut out {
        t.start_cs = t.start_cs.max(prev);
        t.end_cs = t.end_cs.max(t.start_cs);
        prev = t.start_cs;
    }
    out
}

fn engine_error(e: impl std::fmt::Display) -> TranscriptionError {
    TranscriptionError::EngineMissing(e.to_string())
}

fn f32_tensor(shape: Vec<i64>, data: Vec<f32>) -> TypedTensor {
    TypedTensor::new(shape, TensorData::F32(data))
}

/// Whisper encoder and decoder sessions with the tokenizer and feature extractor.
pub struct OnnxWhisper {
    encoder: OnnxModel,
    decoder: OnnxModel,
    tok: WhisperTokenizer,
    mel: LogMel,
    heads: i64,
    head_dim: i64,
    dim: usize,
    suppress: Vec<i64>,
    begin_suppress: Vec<i64>,
    /// The `<|nospeech|>` token (named `<|nocaptions|>` in some exports).
    no_speech_id: Option<i64>,
    /// The alignment heads (decoder layer, head) of the model's generation config; empty without attentions.
    align_heads: Vec<(usize, usize)>,
}

impl OnnxWhisper {
    /// Opens the model files of an installed store.
    pub fn open(store: &OnnxWhisperStore) -> Result<OnnxWhisper, TranscriptionError> {
        let read = |n: &str| std::fs::read_to_string(store.file(n)).map_err(|e| engine_error(format!("{n}: {e}")));
        let cfg: serde_json::Value = serde_json::from_str(&read("config.json")?).map_err(engine_error)?;
        let num = |k: &str| cfg.get(k).and_then(serde_json::Value::as_i64).filter(|v| *v > 0);
        let dim = num("d_model").ok_or_else(|| engine_error("config.json has no d_model"))?;
        let heads =
            num("decoder_attention_heads").ok_or_else(|| engine_error("config.json has no decoder_attention_heads"))?;
        let list = |k: &str| -> Vec<i64> {
            cfg.get(k)
                .and_then(serde_json::Value::as_array)
                .map_or_else(Vec::new, |a| a.iter().filter_map(serde_json::Value::as_i64).collect())
        };
        let n_mels = usize::try_from(num("num_mel_bins").unwrap_or(80)).unwrap_or(80);
        let tok = WhisperTokenizer::from_json(&read("tokenizer.json")?).map_err(engine_error)?;
        let no_speech_id = tok.special("<|nospeech|>").or_else(|| tok.special("<|nocaptions|>"));
        let align_heads = if store.pin.aligned {
            alignment_heads(&read("generation_config.json").unwrap_or_default())
        } else {
            Vec::new()
        };
        let open = |n: &str| {
            let path = store.file(n);
            let path = path.to_str().ok_or_else(|| engine_error("a model path is not UTF-8"))?;
            OnnxModel::new(path, false, None, 0).map_err(engine_error)
        };
        Ok(OnnxWhisper {
            encoder: open("encoder_model_quantized.onnx")?,
            decoder: open("decoder_model_merged_quantized.onnx")?,
            tok,
            mel: LogMel::new(n_mels),
            heads,
            head_dim: dim / heads,
            dim: usize::try_from(dim).unwrap_or(0),
            suppress: list("suppress_tokens"),
            begin_suppress: list("begin_suppress_tokens"),
            no_speech_id,
            align_heads,
        })
    }

    /// The tokenizer (language ids, tests).
    pub fn tokenizer(&self) -> &WhisperTokenizer {
        &self.tok
    }

    fn encode(&self, features: Vec<f32>) -> Result<Vec<f32>, TranscriptionError> {
        let mut inputs = HashMap::new();
        inputs.insert(
            "input_features".to_string(),
            f32_tensor(vec![1, self.mel.n_mels() as i64, N_FRAMES as i64], features),
        );
        let out = self.encoder.run_typed(&inputs, &["last_hidden_state"]).map_err(engine_error)?;
        match out.into_iter().next().map(|t| t.data) {
            Some(TensorData::F32(h)) if h.len() == 1500 * self.dim => Ok(h),
            _ => Err(engine_error("the encoder returned an unexpected result")),
        }
    }

    /// The decoder inputs for `ids` (the key/value cache is empty on the first step) and the names of the cache inputs.
    fn decoder_inputs(
        &self,
        hidden: &[f32],
        ids: &[i64],
        cache: &HashMap<String, TypedTensor>,
        first: bool,
    ) -> (HashMap<String, TypedTensor>, Vec<String>) {
        let mut inputs: HashMap<String, TypedTensor> = HashMap::new();
        inputs.insert("input_ids".into(), TypedTensor::new(vec![1, ids.len() as i64], TensorData::I64(ids.to_vec())));
        inputs.insert("encoder_hidden_states".into(), f32_tensor(vec![1, 1500, self.dim as i64], hidden.to_vec()));
        inputs.insert("use_cache_branch".into(), TypedTensor::new(vec![1], TensorData::Bool(vec![!first])));
        let past: Vec<String> =
            self.decoder.input_names.iter().filter(|n| n.starts_with("past_key_values.")).cloned().collect();
        for name in &past {
            let t = match cache.get(name) {
                Some(t) if !first => t.clone(),
                // An empty cache: the no-cache branch computes everything from the prompt.
                _ => f32_tensor(vec![1, self.heads, 0, self.head_dim], Vec::new()),
            };
            inputs.insert(name.clone(), t);
        }
        (inputs, past)
    }

    /// One decoder step. `cache` holds the key/value tensors by input name (empty before the first step).
    fn step(
        &self,
        hidden: &[f32],
        ids: &[i64],
        cache: &mut HashMap<String, TypedTensor>,
        first: bool,
    ) -> Result<Vec<f32>, TranscriptionError> {
        self.step_at(hidden, ids, cache, first, None).map(|(last, _)| last)
    }

    /// Like `step`, also returning the logits of input row `row` (the first step feeds every prompt token at once).
    fn step_at(
        &self,
        hidden: &[f32],
        ids: &[i64],
        cache: &mut HashMap<String, TypedTensor>,
        first: bool,
        row: Option<usize>,
    ) -> Result<(Vec<f32>, Option<Vec<f32>>), TranscriptionError> {
        let (inputs, past) = self.decoder_inputs(hidden, ids, cache, first);
        let mut wanted: Vec<&str> = vec!["logits"];
        let presents: Vec<(String, &String)> =
            past.iter().map(|n| (n.replacen("past_key_values.", "present.", 1), n)).collect();
        wanted.extend(presents.iter().map(|(p, _)| p.as_str()));
        let mut out = self.decoder.run_typed(&inputs, &wanted).map_err(engine_error)?.into_iter();
        let Some(TypedTensor { shape, data: TensorData::F32(all) }) = out.next() else {
            return Err(engine_error("the decoder returned no logits"));
        };
        let vocab = shape.last().and_then(|v| usize::try_from(*v).ok()).filter(|v| *v > 0 && all.len() >= *v);
        let vocab = vocab.ok_or_else(|| engine_error("the decoder returned odd logits"))?;
        for ((_, name), t) in presents.iter().zip(out) {
            // The cross-attention cache is computed once (first step); the later steps only grow the self-attention one.
            if first || !name.contains(".encoder.") {
                cache.insert((*name).clone(), t);
            }
        }
        let at_row = row.and_then(|r| row_logits(&all, vocab, r)).map(<[f32]>::to_vec);
        Ok((all[all.len() - vocab..].to_vec(), at_row))
    }

    /// Word timing of one chunk: a teacher-forced pass over `<|startoftranscript|> <lang> <|transcribe|> <|notimestamps|>` and
    /// the chunk's text tokens returns the cross-attention of the alignment heads; DTW gives each token's (start, end) in
    /// centiseconds from the chunk start. `None` without attention heads or when the pass fails (the caller interpolates).
    fn align(&self, hidden: &[f32], language: i64, text: &[i64], frames: usize) -> Option<Vec<(i64, i64)>> {
        if self.align_heads.is_empty() || text.is_empty() {
            return None;
        }
        let t = &self.tok;
        let mut ids = vec![t.sot, language, t.transcribe, t.no_timestamps];
        let first_row = ids.len() - 1;
        ids.extend_from_slice(text);
        ids.push(t.eot);
        // Rows: the query before each text token (it predicts it) up to the one that predicts the end.
        let rows = text.len() + 1;
        let (inputs, _) = self.decoder_inputs(hidden, &ids, &HashMap::new(), true);
        let mut layers: Vec<usize> = self.align_heads.iter().map(|h| h.0).collect();
        layers.sort_unstable();
        layers.dedup();
        let names: Vec<String> = layers.iter().map(|l| format!("cross_attentions.{l}")).collect();
        let wanted: Vec<&str> = names.iter().map(String::as_str).collect();
        let out = self.decoder.run_typed(&inputs, &wanted).ok()?;
        let frames = frames.clamp(1, ENCODER_FRAMES);
        let mut heads = Vec::new();
        for (layer, head) in &self.align_heads {
            let TypedTensor { shape, data: TensorData::F32(all) } = out.get(layers.iter().position(|l| l == layer)?)?
            else {
                return None;
            };
            let (n_heads, n_rows) = (usize::try_from(*shape.get(1)?).ok()?, usize::try_from(*shape.get(2)?).ok()?);
            if shape.len() != 4
                || *head >= n_heads
                || n_rows != ids.len()
                || all.len() != n_heads * n_rows * ENCODER_FRAMES
            {
                return None;
            }
            let base = head * n_rows * ENCODER_FRAMES;
            let mut m = Vec::with_capacity(rows * frames);
            for r in first_row..first_row + rows {
                let at = base + r * ENCODER_FRAMES;
                m.extend_from_slice(&all[at..at + frames]);
            }
            heads.push(m);
        }
        let entry = whisper_align::entry_frames(&heads, rows, frames)?;
        Some(whisper_align::token_times(&entry, text.len(), frames))
    }

    /// One 30 second chunk at one temperature (0 = greedy, else sampling), with the carried-over text before the prompt.
    fn decode_chunk(
        &self,
        hidden: &[f32],
        language: i64,
        past: &[i64],
        temperature: f32,
        seed: u64,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Decoded, TranscriptionError> {
        let t = &self.tok;
        let rules = Rules {
            eot: t.eot,
            timestamp_begin: t.timestamp_begin,
            no_timestamps: t.no_timestamps,
            suppress: &self.suppress,
            begin_suppress: &self.begin_suppress,
        };
        let mut ids: Vec<i64> = Vec::new();
        if !past.is_empty()
            && let Some(prev) = t.special("<|startofprev|>")
        {
            ids.push(prev);
            ids.extend_from_slice(past);
        }
        ids.extend([t.sot, language, t.transcribe]);
        let mut cache = HashMap::new();
        let mut sampled: Vec<(i64, f32)> = Vec::new();
        let mut rng = Rng::new(seed);
        let mut no_speech = 0.0f32;
        for n in 0..MAX_TOKENS {
            if cancel() {
                return Err(TranscriptionError::Cancelled);
            }
            // OpenAI's reference reads the no-speech probability at the `<|startoftranscript|>` row of the prompt, not at
            // the last one (after `<|transcribe|>` the model has already committed to speech).
            let sot_row = ids.len().checked_sub(3);
            let (mut logits, sot_logits) =
                self.step_at(hidden, &ids, &mut cache, n == 0, sot_row.filter(|_| n == 0))?;
            if let (Some(id), Some(l)) = (self.no_speech_id, sot_logits) {
                no_speech = probability_of(&l, id);
            }
            let so_far: Vec<i64> = sampled.iter().map(|s| s.0).collect();
            rules.apply(&mut logits, &so_far);
            let (token, p) = if temperature > 0.0 { sample(&logits, temperature, &mut rng) } else { pick(&logits) };
            if token == t.eot || !p.is_finite() {
                break;
            }
            sampled.push((token, p));
            // A model stuck on one token would run to the limit: stop after a long run.
            if sampled.len() > 30 && sampled[sampled.len() - 30..].iter().all(|s| s.0 == token) {
                break;
            }
            ids = vec![token];
        }
        Ok(Decoded::new(sampled, no_speech, t.timestamp_begin))
    }

    /// Whisper.cpp's temperature fallback: the chunk is decoded greedily; when the result looks failed (repetitive or
    /// unsure) it is decoded again at the next temperature of the list. The last try is kept when all fail.
    fn decode_with_fallback(
        &self,
        hidden: &[f32],
        language: i64,
        past: &mut Vec<i64>,
        seed: u64,
        cancel: &dyn Fn() -> bool,
    ) -> Result<Decoded, TranscriptionError> {
        let mut last = None;
        for (i, temperature) in TEMPERATURES.iter().enumerate() {
            // OpenAI's reference drops the carried text once the temperature is past 0.5: it may have caused the failure.
            let carried: &[i64] = if !CONDITION_ON_PREVIOUS_TEXT || *temperature > 0.5 { &[] } else { past };
            let d = self.decode_chunk(hidden, language, carried, *temperature, seed.wrapping_add(i as u64), cancel)?;
            let failed = d.needs_fallback();
            last = Some(d);
            if !failed {
                break;
            }
        }
        let d = last.unwrap_or_else(|| Decoded::new(Vec::new(), 0.0, self.tok.timestamp_begin));
        // Carry this chunk's text into the next one's prompt (whisper.cpp `prompt_past`).
        let text: Vec<i64> = d.tokens.iter().map(|(t, _)| *t).filter(|t| *t < self.tok.eot).collect();
        if d.is_silence() {
            past.clear();
        } else if CONDITION_ON_PREVIOUS_TEXT && !text.is_empty() {
            past.extend(text);
            let over = past.len().saturating_sub(MAX_PROMPT);
            past.drain(..over);
        }
        Ok(d)
    }

    /// The language of the speech: the language token the decoder puts first after `<|startoftranscript|>`, on the first
    /// chunk that is not silent (whisper.cpp detects once on the first 30 seconds). `None` for silence or a model without
    /// language tokens.
    pub fn detect_language(
        &self,
        samples: &[f32],
        cancel: &dyn Fn() -> bool,
    ) -> Result<Option<String>, TranscriptionError> {
        let mut seek = 0usize;
        while seek < samples.len() {
            if cancel() {
                return Err(TranscriptionError::Cancelled);
            }
            let chunk = &samples[seek..samples.len().min(seek + CHUNK_SAMPLES)];
            seek += CHUNK_SAMPLES;
            if !is_audible(chunk) {
                continue;
            }
            let hidden = self.encode(self.mel.compute(chunk))?;
            let logits = self.step(&hidden, &[self.tok.sot], &mut HashMap::new(), true)?;
            let candidates: Vec<(&'static str, i64)> =
                WhisperLanguages::codes().filter_map(|c| self.tok.language(c).map(|id| (c, id))).collect();
            return Ok(best_language(&logits, &candidates).map(str::to_string));
        }
        Ok(None)
    }

    /// Recognizes 16 kHz mono `samples` in `language` (a Whisper code): the words as tokens with times (centiseconds).
    /// `"auto"` detects the language first (see [`OnnxWhisper::recognize_detecting`]).
    pub fn recognize(
        &self,
        samples: &[f32],
        language: &str,
        progress: &mut dyn FnMut(f64),
        cancel: &dyn Fn() -> bool,
    ) -> Result<Vec<WhisperToken>, TranscriptionError> {
        self.recognize_detecting(samples, language, progress, cancel).map(|(tokens, _)| tokens)
    }

    /// Like `recognize`, also returning the language that was used (the detected one for `"auto"`).
    pub fn recognize_detecting(
        &self,
        samples: &[f32],
        language: &str,
        progress: &mut dyn FnMut(f64),
        cancel: &dyn Fn() -> bool,
    ) -> Result<(Vec<WhisperToken>, String), TranscriptionError> {
        let language = if language == AUTO {
            self.detect_language(samples, cancel)?.unwrap_or_else(|| "en".to_string())
        } else {
            language.to_string()
        };
        let lang =
            self.tok.language(&language).ok_or_else(|| TranscriptionError::LocaleUnsupported(language.clone()))?;
        let total_cs = i64::try_from(samples.len() * 100 / SAMPLE_RATE).unwrap_or(i64::MAX);
        let mut out = Vec::new();
        let mut past: Vec<i64> = Vec::new();
        let mut gap_resumes = 0usize;
        let mut seek = 0usize; // samples
        while seek < samples.len() {
            if cancel() {
                return Err(TranscriptionError::Cancelled);
            }
            let chunk = &samples[seek..samples.len().min(seek + CHUNK_SAMPLES)];
            let offset_cs = i64::try_from(seek * 100 / SAMPLE_RATE).unwrap_or(0);
            let mut advance = CHUNK_SAMPLES;
            // Digital silence only invites hallucinated phrases: skip the model.
            if is_audible(chunk) {
                let hidden = self.encode(self.mel.compute(chunk))?;
                let d = self.decode_with_fallback(&hidden, lang, &mut past, seek as u64 + 1, cancel)?;
                if !d.is_silence() {
                    let (segs, resume) = segments(&d.tokens, self.tok.timestamp_begin, self.tok.eot);
                    // Word times from the attentions when the model has them; else the interpolated ones.
                    let text: Vec<i64> = segs.iter().flat_map(|s| s.tokens.iter().map(|(t, _)| *t)).collect();
                    let frames = chunk.len().div_ceil(CHUNK_SAMPLES / ENCODER_FRAMES);
                    let times = self.align(&hidden, lang, &text, frames);
                    let voiced = whisper_align::voiced_frames(chunk);
                    let mut timed = Vec::new();
                    for mut t in chunk_tokens(&segs, &self.tok, times.as_deref(), offset_cs, total_cs) {
                        // Alignment gives a token's entry frame; the silence before the first word and after the last
                        // one belongs to no word.
                        let (s, e) =
                            whisper_align::trim_to_voice(t.start_cs - offset_cs, t.end_cs - offset_cs, &voiced);
                        (t.start_cs, t.end_cs) = (offset_cs + s, offset_cs + e);
                        timed.push(t);
                    }
                    let resume = resume.or_else(|| unspoken_tail(&segs, &voiced));
                    // Speech the model skipped in the middle (a retake): decode again from there, and keep only what lies before.
                    // A token's end is cut back to where its voice stops, the way a word's end is, so a stretch the alignment ran
                    // a word over (it ends where the next word starts) still shows as a gap.
                    let spans: Vec<(i64, i64)> = timed
                        .iter()
                        .map(|t| {
                            let (s, e) = (t.start_cs - offset_cs, t.end_cs - offset_cs);
                            (s, whisper_align::word_end_in_voice(s, e, &voiced))
                        })
                        .collect();
                    let gap = if gap_resume_allowed(gap_resumes, offset_cs) { lost_speech_inside(&spans, &voiced) } else { None };
                    gap_resumes += usize::from(gap.is_some());
                    let resume = match (resume, gap) {
                        (Some(a), Some(b)) => Some(a.min(b)),
                        (a, b) => a.or(b),
                    };
                    out.extend(tokens_before(timed, offset_cs, resume));
                    if let Some(cs) = resume {
                        advance = usize::try_from(cs).unwrap_or(0) * SAMPLE_RATE / 100;
                    }
                }
            }
            seek += advance.max(SAMPLE_RATE);
            progress((seek.min(samples.len()) as f64) / samples.len() as f64);
        }
        Ok((out, language))
    }
}

/// Encoder frames of one 30 second chunk (20 ms each).
const ENCODER_FRAMES: usize = 1500;

/// The (layer, head) pairs of `alignment_heads` in a generation config (empty when absent or odd).
pub(crate) fn alignment_heads(json: &str) -> Vec<(usize, usize)> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(json) else { return Vec::new() };
    let pair = |p: &serde_json::Value| {
        let a = p.as_array()?;
        Some((usize::try_from(a.first()?.as_u64()?).ok()?, usize::try_from(a.get(1)?.as_u64()?).ok()?))
    };
    v.get("alignment_heads")
        .and_then(serde_json::Value::as_array)
        .map_or_else(Vec::new, |a| a.iter().filter_map(pair).collect())
}

/// The language code that asks for detection.
pub const AUTO: &str = "auto";

/// Temperatures of the fallback ladder (whisper.cpp: start 0, step 0.2, up to 1).
const TEMPERATURES: [f32; 6] = [0.0, 0.2, 0.4, 0.6, 0.8, 1.0];
/// A chunk whose token histogram over the last 32 tokens has less entropy than this is repetitive (whisper.cpp `entropy_thold`).
const ENTROPY_THOLD: f64 = 2.4;
/// An average token log-probability below this is unsure (`logprob_thold`).
const LOGPROB_THOLD: f64 = -1.0;
/// With this much probability on "no speech" and an unsure result, the chunk is silence (`no_speech_thold`).
const NO_SPEECH_THOLD: f32 = 0.6;
/// Most carried-over tokens (1 + 200 + 3 prompt + 224 sampled stay below the context of 448).
const MAX_PROMPT: usize = 200;
/// Whether a chunk is decoded with the text of the chunks before it as its prompt. Off: with the prompt the model treats a
/// speaker's retake of an earlier sentence as a repetition and skips it (real clip, 22-28 s: the intro sentence said again was
/// dropped); it is OpenAI's `condition_on_previous_text=False`. Costs some consistency of spelling across chunks.
const CONDITION_ON_PREVIOUS_TEXT: bool = false;
/// Voiced audio after the last closed timestamp of a chunk that the model still ended early must be at least this long
/// (centiseconds) to restart the next window there: the model stopped before the speech did.
const MIN_LOST_SPEECH_CS: usize = 100;
/// How much of the stretch after its onset must be voice for a gap to count as skipped speech (percent).
const MIN_VOICE_DENSITY_PERCENT: usize = 80;
/// Decoding again from skipped speech costs a whole window: at most this many times per minute of audio passed (plus a start
/// allowance), so a music bed or room noise that looks like voice cannot make a recording many times slower.
const GAP_RESUMES_PER_MINUTE: usize = 2;
const GAP_RESUME_ALLOWANCE: usize = 2;

/// Whether another re-decode from skipped speech is allowed after `done` of them with the window now at `seek_cs`.
pub(crate) fn gap_resume_allowed(done: usize, seek_cs: i64) -> bool {
    let minutes = usize::try_from(seek_cs / 6000).unwrap_or(0);
    done < GAP_RESUME_ALLOWANCE + GAP_RESUMES_PER_MINUTE * minutes
}

/// What one decoding try of a chunk gave.
#[derive(Clone, Debug)]
pub(crate) struct Decoded {
    pub tokens: Vec<(i64, f32)>,
    pub avg_logprob: f64,
    pub no_speech: f32,
    entropy: Option<f64>,
}

impl Decoded {
    pub(crate) fn new(tokens: Vec<(i64, f32)>, no_speech: f32, timestamp_begin: i64) -> Decoded {
        let text: Vec<&(i64, f32)> = tokens.iter().filter(|(t, _)| *t < timestamp_begin).collect();
        let avg_logprob = if text.is_empty() {
            0.0
        } else {
            text.iter().map(|(_, p)| f64::from(p.max(1e-6)).ln()).sum::<f64>() / text.len() as f64
        };
        // Entropy of the last 32 tokens, only judged for a run that long (whisper.cpp).
        let entropy = (tokens.len() >= 32).then(|| {
            let mut counts: HashMap<i64, f64> = HashMap::new();
            for (t, _) in &tokens[tokens.len() - 32..] {
                *counts.entry(*t).or_default() += 1.0;
            }
            -counts.values().map(|c| (c / 32.0) * (c / 32.0).ln()).sum::<f64>()
        });
        Decoded { tokens, avg_logprob, no_speech, entropy }
    }

    /// Repetitive or unsure: decode again at a higher temperature.
    pub(crate) fn needs_fallback(&self) -> bool {
        self.entropy.is_some_and(|e| e < ENTROPY_THOLD) || self.avg_logprob < LOGPROB_THOLD
    }

    /// The model thinks there is no speech and is unsure about what it wrote.
    pub(crate) fn is_silence(&self) -> bool {
        self.no_speech > NO_SPEECH_THOLD && self.avg_logprob < LOGPROB_THOLD
    }
}

fn is_audible(chunk: &[f32]) -> bool {
    !chunk.is_empty() && (chunk.iter().map(|s| s * s).sum::<f32>() / chunk.len() as f32).sqrt() > 1e-4
}

/// The logits of row `row` in a flattened `[rows, vocab]` decoder output.
pub(crate) fn row_logits(all: &[f32], vocab: usize, row: usize) -> Option<&[f32]> {
    all.get(row.checked_mul(vocab)?..)?.get(..vocab)
}

/// Probability of token `id` under the plain softmax of `logits`.
fn probability_of(logits: &[f32], id: i64) -> f32 {
    let Some(v) = usize::try_from(id).ok().and_then(|i| logits.get(i)) else { return 0.0 };
    let m = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    let sum: f32 = logits.iter().map(|l| (l - m).exp()).sum();
    (v - m).exp() / sum.max(f32::MIN_POSITIVE)
}

/// The code of the language token with the highest logit.
pub(crate) fn best_language<'a>(logits: &[f32], candidates: &[(&'a str, i64)]) -> Option<&'a str> {
    candidates
        .iter()
        .filter_map(|(code, id)| usize::try_from(*id).ok().and_then(|i| logits.get(i)).map(|l| (*code, *l)))
        .filter(|(_, l)| l.is_finite())
        .max_by(|a, b| a.1.total_cmp(&b.1))
        .map(|(code, _)| code)
}

/// Small deterministic generator for the sampled fallback tries (the same audio gives the same text).
struct Rng(u64);

impl Rng {
    /// Mixes the seed (a small seed would start with tiny draws).
    fn new(seed: u64) -> Rng {
        let mut z = seed.wrapping_add(0x9E37_79B9_7F4A_7C15);
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        Rng((z ^ (z >> 31)) | 1)
    }

    fn next_f32(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        ((self.0 >> 40) as f32) / ((1u64 << 24) as f32)
    }
}

/// Draws a token from the softmax of `logits / temperature`; the probability returned is the plain softmax one.
fn sample(logits: &[f32], temperature: f32, rng: &mut Rng) -> (i64, f32) {
    let m = logits.iter().copied().fold(f32::NEG_INFINITY, f32::max);
    if m == f32::NEG_INFINITY {
        return (0, f32::NAN);
    }
    let weights: Vec<f32> = logits.iter().map(|l| ((l - m) / temperature).exp()).collect();
    let total: f32 = weights.iter().sum();
    let mut target = rng.next_f32() * total;
    let mut chosen = logits.iter().position(|l| *l == m).unwrap_or(0);
    for (i, w) in weights.iter().enumerate() {
        if *w > 0.0 {
            chosen = i;
            if target < *w {
                break;
            }
            target -= *w;
        }
    }
    (chosen as i64, probability_of(logits, chosen as i64))
}

/// `TranscriptionService` over the ONNX Whisper engine: the model downloads once (sha256 pinned), the audio comes from `audio`.
pub struct OnnxWhisperService {
    /// Where the model lives.
    pub store: OnnxWhisperStore,
    downloader: Option<Box<dyn ModelDownloader>>,
    audio: AudioReader,
    mapped_audio: Option<MappedAudioReader>,
    engine: Mutex<Option<Arc<OnnxWhisper>>>,
}

/// Reads a file's audio as 16 kHz mono floats, hearing only the channels of the map (the item's Audio Channels).
pub type MappedAudioReader = Box<dyn Fn(&Path, &AudioChannelMap) -> Result<Vec<f32>, TranscriptionError> + Send + Sync>;

impl OnnxWhisperService {
    /// A service; without a `downloader` a missing model cannot be fetched (`CurlDownloader` is the usual one).
    pub fn new(
        store: OnnxWhisperStore,
        downloader: Option<Box<dyn ModelDownloader>>,
        audio: AudioReader,
    ) -> OnnxWhisperService {
        OnnxWhisperService { store, downloader, audio, mapped_audio: None, engine: Mutex::new(None) }
    }

    /// The standard service: store from the environment, downloads with curl.
    pub fn standard(env: impl Fn(&str) -> Option<String>, audio: AudioReader) -> OnnxWhisperService {
        Self::new(OnnxWhisperStore::standard(env), Some(Box::new(CurlDownloader)), audio)
    }

    /// Adds the reader that renders channel maps (without it a media item with a map fails with `Unavailable`).
    #[must_use]
    pub fn with_mapped_audio(mut self, reader: MappedAudioReader) -> OnnxWhisperService {
        self.mapped_audio = Some(reader);
        self
    }

    fn open(&self) -> Result<Arc<OnnxWhisper>, TranscriptionError> {
        let mut slot = self.engine.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(e) = slot.as_ref() {
            return Ok(Arc::clone(e));
        }
        let e = Arc::new(OnnxWhisper::open(&self.store)?);
        *slot = Some(Arc::clone(&e));
        Ok(e)
    }
}

impl TranscriptionService for OnnxWhisperService {
    fn supported_languages(&self) -> Vec<String> {
        WhisperLanguages::supported()
    }

    fn prepare(
        &self,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
    ) -> Result<(), TranscriptionError> {
        language_code(locale)?;
        if !OnnxModel::is_available() {
            OnnxModel::load_runtime(None).map_err(|e| TranscriptionError::EngineMissing(e.to_string()))?;
        }
        if self.store.is_installed() {
            return Ok(());
        }
        let Some(downloader) = &self.downloader else {
            return Err(TranscriptionError::ModelDownloadFailed("no connection".into()));
        };
        self.store.install(downloader.as_ref(), progress, cancel)
    }

    fn detects_language(&self) -> bool {
        true
    }

    fn download_megabytes(&self) -> Option<u64> {
        let missing = self.store.missing_bytes();
        (missing > 0).then(|| missing.div_ceil(1_000_000))
    }

    fn transcribe(
        &self,
        url: &Path,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        self.run(locale, progress, cancel, ids, || (self.audio)(url))
    }

    fn transcribe_mapped(
        &self,
        url: &Path,
        map: Option<&AudioChannelMap>,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
    ) -> Result<Transcript, TranscriptionError> {
        let Some(map) = map else { return self.transcribe(url, locale, progress, cancel, ids) };
        let Some(reader) = &self.mapped_audio else { return Err(TranscriptionError::Unavailable) };
        self.run(locale, progress, cancel, ids, || reader(url, map))
    }
}

/// The Whisper code of a locale, or `AUTO` for the identifier "auto" (language detection).
fn language_code(locale: &Locale) -> Result<String, TranscriptionError> {
    if locale.identifier().eq_ignore_ascii_case(AUTO) {
        return Ok(AUTO.to_string());
    }
    WhisperLanguages::code(locale).ok_or_else(|| TranscriptionError::LocaleUnsupported(locale.identifier().to_string()))
}

impl OnnxWhisperService {
    fn run(
        &self,
        locale: &Locale,
        progress: &mut dyn FnMut(f64),
        cancel: &CancelToken,
        ids: &mut dyn IdSource,
        audio: impl FnOnce() -> Result<Vec<f32>, TranscriptionError>,
    ) -> Result<Transcript, TranscriptionError> {
        let code = language_code(locale)?;
        cancel.check()?;
        self.prepare(locale, &mut |_| {}, cancel)?;
        let samples = audio()?;
        if samples.is_empty() {
            return Err(TranscriptionError::NoAudio);
        }
        let engine = self.open()?;
        let (tokens, used) =
            engine.recognize_detecting(&samples, &code, &mut |p| progress(p.clamp(0.0, 1.0)), &|| {
                cancel.is_cancelled()
            })?;
        progress(1.0);
        let language = if code == AUTO { used } else { locale.bcp47() };
        let voiced = whisper_align::voiced_frames_chunked(&samples);
        Ok(Transcript::new(&language, whisper_words::words_in_voice(&tokens, Some(&voiced), ids)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const TS: i64 = 1000;
    const EOT: i64 = 900;

    fn rules<'a>(suppress: &'a [i64]) -> Rules<'a> {
        Rules { eot: EOT, timestamp_begin: TS, no_timestamps: 899, suppress, begin_suppress: &[5] }
    }

    fn logits() -> Vec<f32> {
        vec![0.0; 1100]
    }

    fn allowed(l: &[f32]) -> Vec<usize> {
        l.iter().enumerate().filter(|(_, v)| **v > f32::NEG_INFINITY).map(|(i, _)| i).collect()
    }

    #[test]
    fn the_first_token_is_an_early_timestamp() {
        let mut l = logits();
        rules(&[]).apply(&mut l, &[]);
        let a = allowed(&l);
        assert_eq!((a[0], a[a.len() - 1], a.len()), (1000, 1050, 51));
    }

    #[test]
    fn an_open_timestamp_is_followed_by_text_and_a_closing_one_by_a_later_timestamp() {
        let mut l = logits();
        l[3] = 20.0; // text is clearly likelier than the timestamp mass
        rules(&[]).apply(&mut l, &[1010]);
        let a = allowed(&l);
        assert!(a.contains(&3) && a.iter().all(|i| *i <= 900), "text and end only");
        // After "ts text" a timestamp or the end must come, at or after the opening one.
        let mut l = logits();
        rules(&[]).apply(&mut l, &[1010, 3, 1012]);
        // closing timestamp 1012 is single (previous token is text): next is a timestamp or the end.
        let a = allowed(&l);
        assert!(a.iter().all(|i| *i == 900 || *i >= 1012), "{a:?}");
        let mut l = logits();
        rules(&[]).apply(&mut l, &[1010, 3]);
        assert!(allowed(&l).iter().all(|i| *i == 900 || *i >= 1010));
    }

    #[test]
    fn suppressed_and_control_tokens_never_come_out() {
        let mut l = logits();
        l[3] = 20.0;
        rules(&[3]).apply(&mut l, &[1010, 4]);
        assert_eq!(l[3], f32::NEG_INFINITY);
        assert_eq!(l[899], f32::NEG_INFINITY);
        assert_eq!(l[950], f32::NEG_INFINITY);
    }

    #[test]
    fn many_timestamps_outweigh_a_flat_text_distribution() {
        let mut l = logits();
        l[3] = 1.0;
        for v in &mut l[1000..1100] {
            *v = 1.0;
        }
        rules(&[]).apply(&mut l, &[1010, 3, 1020, 1020, 4]);
        assert!(allowed(&l).iter().all(|i| *i >= 1020), "timestamps only");
    }

    fn seq(ids: &[i64]) -> Vec<(i64, f32)> {
        ids.iter().map(|i| (*i, 0.9)).collect()
    }

    #[test]
    fn segments_split_at_timestamps_and_the_seek_follows_the_last_closed_segment() {
        // Ends on a single closing timestamp: the whole chunk is used.
        let (s, resume) = segments(&seq(&[1000, 5, 6, 1100, 1100, 7, 1150, EOT]), TS, EOT);
        assert_eq!(s.len(), 2);
        assert_eq!((s[0].start_cs, s[0].end_cs), (0, 200));
        assert_eq!((s[1].start_cs, s[1].end_cs), (200, 300));
        assert_eq!(resume, None);
        // Ends on a closed pair "ts ts": nothing is open, the next window starts at that timestamp.
        let (s, resume) = segments(&seq(&[1000, 5, 1100, 1100, 6, 1200, 1200, EOT]), TS, EOT);
        assert_eq!(s.len(), 2);
        assert_eq!(resume, Some(400));
        // Ends in text of an open segment: its tokens are dropped and the window restarts at the open timestamp.
        let (s, resume) = segments(&seq(&[1000, 5, 1100, 1100, 6, 7, EOT]), TS, EOT);
        assert_eq!(s.len(), 1);
        assert_eq!(s[0].tokens, seq(&[5]));
        assert_eq!(resume, Some(200));
        // Open segment right after the closing timestamp, no text yet.
        let (s, resume) = segments(&seq(&[1000, 5, 1100, 1100, EOT]), TS, EOT);
        assert_eq!((s.len(), resume), (1, Some(200)));
        // Only an open segment (no closed one) or a resume point under a second: everything is kept.
        let (s, resume) = segments(&seq(&[1000, 5, 6, EOT]), TS, EOT);
        assert_eq!((s.len(), resume), (1, None));
        let (s, resume) = segments(&seq(&[1000, 5, 1020, 1020, 6, EOT]), TS, EOT);
        assert_eq!((s.len(), resume), (2, None));
    }

    #[test]
    fn speech_after_a_closed_last_segment_restarts_the_window_there() {
        let (s, resume) = segments(&seq(&[1000, 5, 6, 1400, EOT]), TS, EOT); // closed at 8 s
        assert_eq!(resume, None);
        let frames = |speech: std::ops::Range<usize>| (0..1500).map(|i| speech.contains(&i)).collect::<Vec<bool>>();
        // Speech from 10 s to 14 s (frames of 20 ms) after the closing timestamp at 8 s: decode it again from 8 s.
        assert_eq!(unspoken_tail(&s, &frames(500..700)), Some(800));
        // Only the speech before the timestamp, or a short blip after it: nothing is lost.
        assert_eq!(unspoken_tail(&s, &frames(100..380)), None);
        assert_eq!(unspoken_tail(&s, &frames(600..610)), None);
        // An open last segment has no closing timestamp to go back to.
        let (s, _) = segments(&seq(&[1000, 5, 6, EOT]), TS, EOT);
        assert_eq!(unspoken_tail(&s, &frames(0..1500)), None);
    }

    #[test]
    fn words_in_a_segment_share_its_span_by_length() {
        // Tokens " ab" (3 bytes) and " c" (2) over 100..200 cs split 60/40.
        let json = r#"{"added_tokens":[{"id":10,"content":"<|endoftext|>"},{"id":11,"content":"<|startoftranscript|>"},
            {"id":13,"content":"<|transcribe|>"},{"id":14,"content":"<|notimestamps|>"},{"id":15,"content":"<|0.00|>"}],
            "model":{"vocab":{"Ġab":0,"Ġc":1},"merges":[]}}"#;
        let tok = WhisperTokenizer::from_json(json).unwrap();
        let seg = Segment { start_cs: 0, end_cs: 100, tokens: vec![(0, 0.9), (1, 0.8)] };
        let t = timed_tokens(&seg, &tok, 100, 10_000);
        assert_eq!((t[0].start_cs, t[0].end_cs, t[1].start_cs, t[1].end_cs), (100, 160, 160, 200));
        let w = whisper_words::words(&t, &mut sq_core_time::SequentialIds::default());
        assert_eq!(w.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["ab", "c"]);
        // Limited by the audio length.
        assert_eq!(timed_tokens(&seg, &tok, 100, 150)[1].end_cs, 150);
    }

    fn two_token_tokenizer() -> WhisperTokenizer {
        let json = r#"{"added_tokens":[{"id":10,"content":"<|endoftext|>"},{"id":11,"content":"<|startoftranscript|>"},
            {"id":13,"content":"<|transcribe|>"},{"id":14,"content":"<|notimestamps|>"},{"id":15,"content":"<|0.00|>"}],
            "model":{"vocab":{"Ġab":0,"Ġc":1,"Ġd":2},"merges":[]}}"#;
        WhisperTokenizer::from_json(json).unwrap()
    }

    #[test]
    fn aligned_times_stay_inside_their_segment_and_never_go_backwards() {
        let tok = two_token_tokenizer();
        let segs = [
            Segment { start_cs: 0, end_cs: 100, tokens: vec![(0, 0.9), (1, 0.8)] },
            Segment { start_cs: 100, end_cs: 200, tokens: vec![(2, 0.7)] },
        ];
        // The alignment starts the first token before its segment and runs the second past the segment's end.
        let times = [(0, 40), (30, 150), (90, 400)];
        let t = chunk_tokens(&segs, &tok, Some(&times), 1000, 10_000);
        let spans: Vec<(i64, i64)> = t.iter().map(|t| (t.start_cs, t.end_cs)).collect();
        assert_eq!(spans, vec![(1000, 1040), (1040, 1100), (1100, 1200)]);
        let w = whisper_words::words(&t, &mut sq_core_time::SequentialIds::default());
        assert_eq!(w.iter().map(|w| w.text.as_str()).collect::<Vec<_>>(), ["ab", "c", "d"]);
    }

    fn de_tokenizer() -> WhisperTokenizer {
        let json = r#"{"added_tokens":[{"id":10,"content":"<|endoftext|>"},{"id":11,"content":"<|startoftranscript|>"},
            {"id":13,"content":"<|transcribe|>"},{"id":14,"content":"<|notimestamps|>"},{"id":15,"content":"<|0.00|>"}],
            "model":{"vocab":{"Ġab":0,"Ġc":1,"Ġd":2,"Ġef":3},"merges":[]}}"#;
        WhisperTokenizer::from_json(json).unwrap()
    }

    fn word_spans(t: &[WhisperToken]) -> Vec<(i64, i64)> {
        let w = whisper_words::words(t, &mut sq_core_time::SequentialIds::default());
        w.iter()
            .map(|w| {
                (
                    w.range.start.value() * 100 / w.range.start.timescale(),
                    w.range.end().value() * 100 / w.range.end().timescale(),
                )
            })
            .collect()
    }

    #[test]
    fn a_segment_closed_where_it_opened_keeps_the_alignment_times() {
        // <|27.00|> ab c <|27.00|>: the segment span is empty, the alignment still knows where the words are.
        let tok = de_tokenizer();
        let segs = [Segment { start_cs: 2700, end_cs: 2700, tokens: vec![(0, 0.9), (1, 0.8)] }];
        let t = chunk_tokens(&segs, &tok, Some(&[(2200, 2400), (2400, 2800)]), 0, 10_000);
        assert_eq!(word_spans(&t), vec![(2200, 2400), (2400, 2800)]);
    }

    #[test]
    fn degenerate_segments_without_attentions_still_give_every_word_its_own_time() {
        // Two segments with start == end, as the Mac run produced; the second one starts later.
        let tok = de_tokenizer();
        let segs = [
            Segment { start_cs: 2700, end_cs: 2700, tokens: vec![(0, 0.9), (1, 0.8), (2, 0.8)] },
            Segment { start_cs: 3200, end_cs: 3200, tokens: vec![(3, 0.9)] },
        ];
        let spans = word_spans(&chunk_tokens(&segs, &tok, None, 0, 10_000));
        assert!(spans.iter().all(|(a, b)| b > a), "{spans:?}");
        assert!(spans.windows(2).all(|p| p[0].1 <= p[1].0), "{spans:?}");
        assert_eq!(spans[0].0, 2700);
        assert_eq!(spans[3].0, 3200);
    }

    #[test]
    fn times_are_cut_back_to_the_speech() {
        // 20 ms frames: speech in frames 10..20 (0.20 s to 0.40 s).
        let voiced: Vec<bool> = (0..50).map(|i| (10..20).contains(&i)).collect();
        assert_eq!(whisper_align::trim_to_voice(0, 100, &voiced), (18, 42));
        assert_eq!(whisper_align::trim_to_voice(30, 36, &voiced), (30, 36)); // inside the speech: unchanged
        assert_eq!(whisper_align::trim_to_voice(60, 90, &voiced), (60, 60)); // silence only: no time of its own
        assert_eq!(whisper_align::trim_to_voice(60, 90, &[false; 50]), (60, 90)); // no speech anywhere: left alone
        let mut samples = vec![0.0f32; 16_000];
        samples[3200..6400].iter_mut().enumerate().for_each(|(i, v)| *v = if i % 2 == 0 { 0.3 } else { -0.3 });
        let v = whisper_align::voiced_frames(&samples);
        assert!(v[10..20].iter().all(|x| *x) && !v[0..9].iter().any(|x| *x) && !v[22..].iter().any(|x| *x));
    }

    #[test]
    fn without_attentions_the_words_get_the_interpolated_times_as_before() {
        let tok = two_token_tokenizer();
        let segs = [
            Segment { start_cs: 0, end_cs: 100, tokens: vec![(0, 0.9), (1, 0.8)] },
            Segment { start_cs: 100, end_cs: 200, tokens: vec![(2, 0.7)] },
        ];
        let expected: Vec<WhisperToken> = segs.iter().flat_map(|s| timed_tokens(s, &tok, 100, 10_000)).collect();
        assert_eq!(chunk_tokens(&segs, &tok, None, 100, 10_000), expected);
        // A result of the wrong length is not trusted either.
        assert_eq!(chunk_tokens(&segs, &tok, Some(&[(0, 1)]), 100, 10_000), expected);
        assert_eq!(expected[0].end_cs, 160);
    }

    #[test]
    fn the_alignment_heads_come_out_of_the_generation_config() {
        let json = r#"{"alignment_heads":[[2,2],[3,0]],"bos_token_id":1}"#;
        assert_eq!(alignment_heads(json), vec![(2, 2), (3, 0)]);
        assert!(alignment_heads("{}").is_empty() && alignment_heads("nonsense").is_empty());
    }

    /// Reads a 16 kHz mono 16-bit PCM WAV (the test clip).
    fn read_wav(path: &str) -> Result<Vec<f32>, TranscriptionError> {
        let b = std::fs::read(path).map_err(|e| TranscriptionError::EngineMissing(e.to_string()))?;
        let mut at = 12;
        while at + 8 <= b.len() {
            let len = u32::from_le_bytes([b[at + 4], b[at + 5], b[at + 6], b[at + 7]]) as usize;
            if &b[at..at + 4] == b"data" {
                let end = (at + 8 + len).min(b.len());
                return Ok(b[at + 8..end]
                    .as_chunks::<2>()
                    .0
                    .iter()
                    .map(|c| f32::from(i16::from_le_bytes(*c)) / 32768.0)
                    .collect());
            }
            at += 8 + len + (len & 1);
        }
        Err(TranscriptionError::NoAudio)
    }

    /// The same clip on the CPU and on the platform accelerator (DirectML / Core ML): identical words, times to stderr.
    /// Needs `SQ_WHISPER_WAV` like the test below; `SQ_WHISPER_ONNX_SIZE` picks the size (default base). Whisper stays on the CPU
    /// in the app: the quantized int8 parts crash DirectML on the PC (access violation, measured 2026-11-09), so the accelerator
    /// pass only runs with `SQ_WHISPER_ACCEL=1`; without it both passes are the CPU (timing only).
    #[test]
    fn the_accelerator_and_the_cpu_write_the_same_words() {
        use sq_onnx::onnx_model::Provider;
        let Ok(wav) = std::env::var("SQ_WHISPER_WAV") else {
            eprintln!("skipped: SQ_WHISPER_WAV is not set");
            return;
        };
        let env = |k: &str| match k {
            "SQ_WHISPER_ONNX_SIZE" => Some(std::env::var(k).unwrap_or_else(|_| "base".into())),
            "SQ_WHISPER_MODELS" => Some(std::env::var(k).unwrap_or_else(|_| {
                std::env::temp_dir().join("sq-whisper-onnx-test-models").to_string_lossy().into_owned()
            })),
            _ => None,
        };
        let seconds: f64 = read_wav(&wav).map_or(0.0, |a| a.len() as f64 / 16000.0);
        let mut texts = Vec::new();
        let accelerated =
            if std::env::var_os("SQ_WHISPER_ACCEL").is_some() { Provider::platform_default() } else { Provider::Cpu };
        for provider in [Provider::Cpu, accelerated] {
            Provider::force(Some(provider));
            let service = OnnxWhisperService::standard(env, Box::new(|p| read_wav(&p.to_string_lossy())));
            let locale = Locale::new("en-US");
            if let Err(e) = service.prepare(&locale, &mut |_| {}, &CancelToken::new()) {
                Provider::force(None);
                eprintln!("skipped: {e}");
                return;
            }
            let start = std::time::Instant::now();
            let t = service
                .transcribe(
                    Path::new(&wav),
                    &locale,
                    &mut |_| {},
                    &CancelToken::new(),
                    &mut sq_core_time::SequentialIds::default(),
                )
                .unwrap_or_else(|e| panic!("transcribe failed: {e}"));
            let took = start.elapsed().as_secs_f64();
            eprintln!(
                "whisper {} {provider:?}: {took:.2} s for {seconds:.1} s of audio ({:.3} s per audio second): {}",
                service.store.pin.size,
                took / seconds.max(0.001),
                t.text()
            );
            texts.push(t.text());
        }
        Provider::force(None);
        assert_eq!(texts[0], texts[1], "the providers disagree");
    }

    /// Real model, real speech: `SQ_WHISPER_WAV` is a 16 kHz mono WAV with English speech, `SQ_ONNXRUNTIME_LIB` or PATH finds the
    /// runtime; the model downloads (sha256 checked) into `SQ_WHISPER_MODELS` or a temp folder; `SQ_WHISPER_ONNX_SIZE` picks the size.
    #[test]
    fn a_real_english_clip_comes_out_as_words_through_the_service() {
        let Ok(wav) = std::env::var("SQ_WHISPER_WAV") else {
            eprintln!("skipped: SQ_WHISPER_WAV (16 kHz mono WAV with English speech) is not set");
            return;
        };
        let env = |k: &str| match k {
            "SQ_WHISPER_ONNX_SIZE" => Some(std::env::var(k).unwrap_or_else(|_| "base".into())),
            "SQ_WHISPER_MODELS" => Some(std::env::var(k).unwrap_or_else(|_| {
                std::env::temp_dir().join("sq-whisper-onnx-test-models").to_string_lossy().into_owned()
            })),
            _ => None,
        };
        let service = OnnxWhisperService::standard(env, Box::new(|p| read_wav(&p.to_string_lossy())));
        let locale = Locale::new("en-US");
        let mut download = Vec::new();
        if let Err(e) = service.prepare(&locale, &mut |f| download.push(f), &CancelToken::new()) {
            if matches!(e, TranscriptionError::EngineMissing(_)) {
                eprintln!("skipped: {e}");
                return;
            }
            panic!("prepare failed: {e}");
        }
        assert!(service.store.is_installed());
        eprintln!("download progress steps: {}", download.len());

        // A canceled job reports it and makes no words.
        let c = CancelToken::new();
        c.cancel();
        let r = service.transcribe(
            Path::new("clip.wav"),
            &locale,
            &mut |_| {},
            &c,
            &mut sq_core_time::SequentialIds::default(),
        );
        assert_eq!(r, Err(TranscriptionError::Cancelled));

        let mut seen = Vec::new();
        let start = std::time::Instant::now();
        let t = service
            .transcribe(
                Path::new(&wav),
                &locale,
                &mut |p| seen.push(p),
                &CancelToken::new(),
                &mut sq_core_time::SequentialIds::default(),
            )
            .unwrap_or_else(|e| panic!("transcribe failed: {e}"));
        eprintln!("TRANSCRIPT ({}, {:.1}s): {}", service.store.pin.size, start.elapsed().as_secs_f64(), t.text());
        for w in &t.words {
            eprintln!(
                "  {:>6.2}-{:>6.2}  {}",
                w.range.start.value() as f64 / w.range.start.timescale() as f64,
                w.range.end().value() as f64 / w.range.end().timescale() as f64,
                w.text
            );
        }
        let lower = t.text().to_lowercase();
        assert!(!t.words.is_empty());
        assert!(lower.contains("country") && lower.contains("ask"), "{lower}");
        assert_eq!(t.language, "en-US");
        assert!(seen.windows(2).all(|w| w[0] <= w[1]) && seen.last() == Some(&1.0), "{seen:?}");
        assert!(t.words.windows(2).all(|w| w[0].range.start <= w[1].range.start));
        // Word times are monotonic and inside the clip; with an aligned model the words are not spread by length.
        let secs = |t: sq_core_time::Time| t.value() as f64 / t.timescale() as f64;
        assert!(t.words.iter().all(|w| secs(w.range.start) <= secs(w.range.end())));
        assert!(t.words.last().is_some_and(
            |w| secs(w.range.end()) <= read_wav(&wav).map_or(f64::MAX, |a| a.len() as f64 / 16000.0) + 0.05
        ));
        eprintln!("aligned model: {}", service.store.pin.aligned);
        assert!(t.words.iter().all(|w| w.confidence.is_some_and(|c| (0.0..=1.0).contains(&c))));
    }

    /// Voice frames (20 ms) from (start, end) centisecond stretches of speech.
    fn voice(total_cs: i64, speech: &[(i64, i64)]) -> Vec<bool> {
        (0..total_cs / 2).map(|f| speech.iter().any(|(a, b)| f * 2 >= *a && f * 2 < *b)).collect()
    }

    #[test]
    fn a_retake_the_model_skipped_is_found_where_its_voice_starts() {
        // Take 1 at 0.5-3 s has words; the retake's voice runs 3.8-9 s, the model only wrote its end (from 6.2 s).
        let voiced = voice(1000, &[(50, 300), (380, 900)]);
        let spans = [(50, 120), (120, 300), (620, 700), (700, 900)];
        let at = lost_speech_inside(&spans, &voiced).expect("the skipped voice is found");
        assert!((340..=380).contains(&at), "resume at {at}");
    }

    #[test]
    fn a_gap_with_voice_but_no_dense_run_is_skipped_and_a_later_retake_is_still_found() {
        // Gap 1 (300-620): patchy noise, 1.2 s of voice in scattered 2-frame bits, no 8-of-10 run. Gap 2 (700-1000): a retake.
        let mut voiced = voice(1200, &[(50, 300), (700, 760)]);
        for f in (150..310).filter(|f| f % 4 < 2) {
            voiced[f] = true;
        }
        voiced[350..500].fill(true);
        let spans = [(50, 300), (620, 700), (1000, 1100)];
        let at = lost_speech_inside(&spans, &voiced).expect("the later gap is checked");
        assert!((700..=720).contains(&at), "resume at {at}");
    }

    #[test]
    fn a_noise_bed_cannot_cause_more_re_decodes_than_the_cap() {
        // Every window of a 10 minute recording over a music bed looks like it skipped speech: the cap holds.
        let (mut done, mut seek_cs) = (0usize, 0i64);
        while seek_cs < 10 * 6000 {
            if gap_resume_allowed(done, seek_cs) {
                done += 1;
            }
            seek_cs += 1500; // each window moves on half a chunk
        }
        assert!(done <= GAP_RESUME_ALLOWANCE + GAP_RESUMES_PER_MINUTE * 10, "{done}");
        assert!(!gap_resume_allowed(100, 600), "an exhausted budget stays closed early in the file");
    }

    #[test]
    fn real_pauses_and_the_same_text_at_the_same_time_are_not_lost_speech() {
        // A 0.8 s pause, a short breath of 0.3 s between words, and a chunk without any gap: nothing to decode again.
        let voiced = voice(1000, &[(50, 300), (380, 400), (430, 900)]);
        assert_eq!(lost_speech_inside(&[(50, 300), (430, 600), (600, 900)], &voiced), None);
        assert_eq!(lost_speech_inside(&[(50, 900)], &voiced), None);
        assert_eq!(lost_speech_inside(&[], &voiced), None);
        // The same words twice on one time span (a hallucinated copy) leave no gap either.
        assert_eq!(lost_speech_inside(&[(50, 300), (50, 300), (300, 900)], &voiced), None);
    }

    fn token_at(text: &str, start_cs: i64) -> WhisperToken {
        WhisperToken { bytes: text.as_bytes().to_vec(), is_special: false, start_cs, end_cs: start_cs + 10, probability: 0.9 }
    }

    #[test]
    fn a_window_keeps_the_tokens_before_the_resume_point_and_never_half_a_word() {
        let t = || vec![token_at(" Hallo", 1000), token_at(" L", 1100), token_at("ohnt", 1200), token_at(" sich", 1300)];
        let words = |v: Vec<WhisperToken>| v.iter().map(|t| String::from_utf8_lossy(&t.bytes).into_owned()).collect::<Vec<_>>();
        // Offset 1000: " L" at 100, "ohnt" at 200; a resume at 150 splits the word.
        assert_eq!(words(tokens_before(t(), 1000, Some(150))), [" Hallo"]);
        assert_eq!(words(tokens_before(t(), 1000, Some(250))), [" Hallo", " L", "ohnt"]);
        assert_eq!(words(tokens_before(t(), 1000, None)).len(), 4);
    }

    /// Real model, real German speech (env-gated): `SQ_WHISPER_DE_WAV` is a 16 kHz mono WAV, `SQ_WHISPER_MODELS` holds the aligned
    /// model, `SQ_WHISPER_ONNX_SIZE` picks the size. Words must have a duration, never collide and never go backwards.
    #[test]
    fn real_german_speech_gets_distinct_word_times() {
        let Ok(wav) = std::env::var("SQ_WHISPER_DE_WAV") else {
            eprintln!("skipped: SQ_WHISPER_DE_WAV is not set");
            return;
        };
        let env = |k: &str| match k {
            "SQ_WHISPER_ONNX_SIZE" => Some(std::env::var(k).unwrap_or_else(|_| "small".into())),
            "SQ_WHISPER_MODELS" => std::env::var(k).ok(),
            _ => None,
        };
        let service = OnnxWhisperService::standard(env, Box::new(|p| read_wav(&p.to_string_lossy())));
        let locale = Locale::new("de-DE");
        if let Err(e) = service.prepare(&locale, &mut |_| {}, &CancelToken::new()) {
            eprintln!("skipped: {e}");
            return;
        }
        let t = service
            .transcribe(
                Path::new(&wav),
                &locale,
                &mut |_| {},
                &CancelToken::new(),
                &mut sq_core_time::SequentialIds::default(),
            )
            .unwrap_or_else(|e| panic!("transcribe failed: {e}"));
        let secs = |t: sq_core_time::Time| t.value() as f64 / t.timescale() as f64;
        for w in &t.words {
            eprintln!("  {:>7.2}-{:>7.2}  {}", secs(w.range.start), secs(w.range.end()), w.text);
        }
        assert!(t.words.len() > 20, "{}", t.text());
        // The 30 s chunk boundary must not swallow speech: words inside 22-28 s, none repeated across the boundary.
        let near_edge: Vec<&str> =
            t.words.iter().filter(|w| (22.0..28.0).contains(&secs(w.range.start))).map(|w| w.text.as_str()).collect();
        assert!(!near_edge.is_empty(), "no word starts within 22-28 s: speech was dropped");
        let dup: Vec<String> = t
            .words
            .iter()
            .filter(|w| (25.0..40.0).contains(&secs(w.range.start)))
            .collect::<Vec<_>>()
            .windows(3)
            .filter(|w| w[0].text == w[1].text && w[1].text == w[2].text)
            .map(|w| w[0].text.clone())
            .collect();
        assert!(dup.is_empty(), "words repeated around the boundary: {dup:?}");
        let zero: Vec<&str> =
            t.words.iter().filter(|w| secs(w.range.end()) <= secs(w.range.start)).map(|w| w.text.as_str()).collect();
        assert!(zero.is_empty(), "words without a duration: {zero:?}");
        assert!(t.words.windows(2).all(|w| secs(w[0].range.start) <= secs(w[1].range.start)), "words go backwards");
        // Every word starts and ends within 0.3 s of speech (the envelope of the clip itself).
        let samples = read_wav(&wav).unwrap_or_default();
        let voiced = whisper_align::voiced_frames(&samples);
        let near = |t: f64| {
            let f = (t / 0.02) as isize;
            (f - 15..=f + 15).any(|i| usize::try_from(i).ok().and_then(|i| voiced.get(i)).copied().unwrap_or(false))
        };
        // A word ends with its voice: no word spans a silent stretch longer than 0.5 s, none is shorter than 8 cs.
        let silent_span: Vec<String> = t
            .words
            .iter()
            .filter(|w| {
                let (a, b) = ((secs(w.range.start) / 0.02) as usize, (secs(w.range.end()) / 0.02) as usize);
                let (mut run, mut worst) = (0usize, 0usize);
                for &v in voiced.iter().take(b).skip(a) {
                    run = if v { 0 } else { run + 1 };
                    worst = worst.max(run);
                }
                worst > 25
            })
            .map(|w| format!("{} {:.2}-{:.2}", w.text, secs(w.range.start), secs(w.range.end())))
            .collect();
        assert!(silent_span.is_empty(), "words spanning a pause: {silent_span:?}");
        let short = t.words.iter().filter(|w| secs(w.range.end()) - secs(w.range.start) < 0.0799).count();
        assert_eq!(short, 0, "words shorter than 8 cs");
        let off: Vec<String> = t
            .words
            .iter()
            .filter(|w| !near(secs(w.range.start)) || !near(secs(w.range.end())))
            .map(|w| format!("{} {:.2}-{:.2}", w.text, secs(w.range.start), secs(w.range.end())))
            .collect();
        assert!(off.is_empty(), "words away from the speech: {off:?}");
    }

    #[test]
    fn repetitive_or_unsure_chunks_fall_back_and_unsure_silence_is_dropped() {
        let repeated: Vec<(i64, f32)> = (0..40).map(|_| (7, 0.9)).collect();
        assert!(Decoded::new(repeated, 0.0, TS).needs_fallback());
        let varied: Vec<(i64, f32)> = (0..40).map(|i| (i, 0.9)).collect();
        assert!(!Decoded::new(varied, 0.0, TS).needs_fallback());
        let unsure = vec![(1, 0.1), (2, 0.2)];
        assert!(Decoded::new(unsure.clone(), 0.0, TS).needs_fallback());
        assert!(Decoded::new(unsure, 0.9, TS).is_silence());
        assert!(!Decoded::new(vec![(1, 0.9)], 0.9, TS).is_silence());
    }

    #[test]
    fn the_no_speech_probability_comes_from_the_start_row_not_the_last() {
        // Two rows of a 4-token vocab: row 0 (start token) puts its mass on token 3 (no speech), row 1 does not.
        let all = [0.0, 0.0, 0.0, 9.0, 9.0, 0.0, 0.0, 0.0];
        assert_eq!(row_logits(&all, 4, 0), Some(&all[..4]));
        assert_eq!(row_logits(&all, 4, 2), None);
        assert!(probability_of(row_logits(&all, 4, 0).unwrap(), 3) > NO_SPEECH_THOLD);
        assert!(probability_of(row_logits(&all, 4, 1).unwrap(), 3) < 0.01);
        // A silent window with unsure text yields nothing; confident speech with a high no-speech value stays.
        let hallucination = vec![(1, 0.2), (2, 0.1)];
        assert!(Decoded::new(hallucination, probability_of(&all[..4], 3), TS).is_silence());
    }

    #[test]
    fn the_language_is_the_language_token_with_the_highest_logit() {
        let mut logits = vec![0.0f32; 20];
        logits[3] = 2.0;
        logits[5] = 1.0;
        logits[9] = 50.0; // not a language token
        let languages = [("de", 3), ("en", 5)];
        assert_eq!(best_language(&logits, &languages), Some("de"));
        logits[5] = 3.0;
        assert_eq!(best_language(&logits, &languages), Some("en"));
        assert_eq!(best_language(&logits, &[]), None);
    }

    #[test]
    fn locales_map_to_whisper_codes_and_auto_asks_for_detection() {
        assert_eq!(language_code(&Locale::new("de-DE")).as_deref(), Ok("de"));
        assert_eq!(language_code(&Locale::new("auto")).as_deref(), Ok(AUTO));
        assert!(matches!(language_code(&Locale::new("tlh")), Err(TranscriptionError::LocaleUnsupported(_))));
    }

    #[test]
    fn sampling_is_repeatable_and_a_low_temperature_is_nearly_greedy() {
        let mut logits = vec![0.0f32; 50];
        logits[11] = 8.0;
        logits[12] = 7.0;
        let a = sample(&logits, 0.2, &mut Rng::new(5));
        let b = sample(&logits, 0.2, &mut Rng::new(5));
        assert_eq!(a.0, b.0);
        assert_eq!(a.0, 11);
        // A hot draw moves around: not every seed gives the best token.
        let hot: std::collections::BTreeSet<i64> =
            (1..40).map(|s| sample(&logits, 3.0, &mut Rng::new(s * 977)).0).collect();
        assert!(hot.len() > 3);
    }
}
