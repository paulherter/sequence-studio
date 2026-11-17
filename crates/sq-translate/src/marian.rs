//! Marian (OPUS-MT) translation of one text: tokenize, encode, decode greedily, detokenize. The network sits behind
//! [`Seq2Seq`]; [`OnnxSeq2Seq`] runs the Xenova ONNX export (encoder + merged decoder) on `sq-onnx`.

use crate::sentencepiece::{SentencePiece, join_pieces};
use crate::store::Cancel;
use sq_onnx::onnx_model::{OnnxModel, TensorData, TypedTensor};
use std::collections::HashMap;
use std::path::Path;

/// What the encoder produced for one source text.
#[derive(Clone, Debug, PartialEq)]
pub struct Encoded {
    /// `[seq, dim]` hidden states, row-major.
    pub hidden: Vec<f32>,
    /// Source length in tokens.
    pub seq: usize,
}

/// The network: an encoder and a decoder that yields the next-token scores for a prefix.
pub trait Seq2Seq {
    /// Encodes source token ids.
    fn encode(&self, ids: &[i64]) -> Result<Encoded, String>;
    /// The scores over the target vocabulary for the token after `prefix` (which starts with the decoder start token).
    fn next_logits(&self, enc: &Encoded, prefix: &[i64]) -> Result<Vec<f32>, String>;
}

/// Token ids with a special meaning.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Specials {
    /// End of sequence (also appended to the source).
    pub eos: i64,
    /// Padding; Marian also starts the decoder with it and never generates it.
    pub pad: i64,
    /// Unknown piece.
    pub unk: i64,
}

/// Longest source (tokens, end mark included) and longest output we decode.
const MAX_SOURCE: usize = 256;
const MAX_NEW: usize = 256;

/// One translation direction, ready to run.
pub struct Marian<B: Seq2Seq> {
    backend: B,
    spm: SentencePiece,
    vocab: HashMap<String, i64>,
    inverse: HashMap<i64, String>,
    specials: Specials,
}

impl<B: Seq2Seq> Marian<B> {
    /// A translator over `backend` with the source tokenizer and the `vocab.json` token table.
    pub fn new(backend: B, spm: SentencePiece, vocab: HashMap<String, i64>, specials: Specials) -> Marian<B> {
        let inverse = vocab.iter().map(|(k, v)| (*v, k.clone())).collect();
        Marian { backend, spm, vocab, inverse, specials }
    }

    /// Source token ids of `text`: `prefix` (a `>>pt<<` language token of multi-target models) first, then the pieces, then the end mark.
    pub fn tokenize(&self, text: &str, prefix: Option<&str>) -> Vec<i64> {
        let mut ids = Vec::new();
        if let Some(p) = prefix {
            ids.push(self.vocab.get(p).copied().unwrap_or(self.specials.unk));
        }
        for piece in self.spm.encode(text) {
            ids.push(piece.and_then(|p| self.vocab.get(&p).copied()).unwrap_or(self.specials.unk));
        }
        ids.truncate(MAX_SOURCE - 1);
        ids.push(self.specials.eos);
        ids
    }

    /// Text of target token ids (up to the end mark; control tokens dropped).
    pub fn detokenize(&self, ids: &[i64]) -> String {
        join_pieces(
            ids.iter()
                .take_while(|i| **i != self.specials.eos)
                .filter(|i| **i != self.specials.pad && **i != self.specials.unk)
                .filter_map(|i| self.inverse.get(i))
                .map(String::as_str),
        )
    }

    /// Translates one text. An empty text stays empty.
    // Deliberate: greedy search. Swift translates with Apple's Translation framework (no beam setting); beam 4, the Marian
    // default, is the upgrade if quality needs it.
    pub fn translate(&self, text: &str, prefix: Option<&str>, cancel: &Cancel) -> Result<String, String> {
        let source = self.tokenize(text, prefix);
        if source.len() <= 1 + usize::from(prefix.is_some()) {
            return Ok(String::new());
        }
        let enc = self.backend.encode(&source)?;
        let limit = (source.len() * 2 + 10).min(MAX_NEW);
        let mut prefix_ids = vec![self.specials.pad];
        while prefix_ids.len() <= limit {
            if cancel.is_canceled() {
                return Err("canceled".into());
            }
            let mut logits = self.backend.next_logits(&enc, &prefix_ids)?;
            if let Some(p) = usize::try_from(self.specials.pad).ok().and_then(|p| logits.get_mut(p)) {
                *p = f32::NEG_INFINITY;
            }
            let next = logits
                .iter()
                .enumerate()
                .fold((0usize, f32::NEG_INFINITY), |b, (i, v)| if *v > b.1 { (i, *v) } else { b })
                .0 as i64;
            if next == self.specials.eos {
                break;
            }
            prefix_ids.push(next);
        }
        Ok(self.detokenize(&prefix_ids[1..]))
    }
}

/// The Xenova ONNX export: `encoder_model` and `decoder_model_merged`, run without a key/value cache (every step feeds the whole prefix).
pub struct OnnxSeq2Seq {
    encoder: OnnxModel,
    decoder: OnnxModel,
    heads: i64,
    head_dim: i64,
    dim: usize,
}

fn i64_tensor(shape: Vec<i64>, data: Vec<i64>) -> TypedTensor {
    TypedTensor::new(shape, TensorData::I64(data))
}

impl OnnxSeq2Seq {
    /// Opens both models; `config` is the model's `config.json` text (sizes).
    pub fn open(encoder: &Path, decoder: &Path, config: &str) -> Result<OnnxSeq2Seq, String> {
        let cfg: serde_json::Value = serde_json::from_str(config).map_err(|e| format!("bad config.json: {e}"))?;
        let num = |k: &str| cfg.get(k).and_then(serde_json::Value::as_i64).filter(|v| *v > 0);
        let dim = num("d_model").ok_or("config.json has no d_model")?;
        let heads = num("decoder_attention_heads").ok_or("config.json has no decoder_attention_heads")?;
        let path = |p: &Path| p.to_str().map(str::to_string).ok_or_else(|| "a model path is not UTF-8".to_string());
        let open = |p: &Path| OnnxModel::new(&path(p)?, false, None, 0).map_err(|e| e.to_string());
        Ok(OnnxSeq2Seq {
            encoder: open(encoder)?,
            decoder: open(decoder)?,
            heads,
            head_dim: dim / heads,
            dim: usize::try_from(dim).unwrap_or(0),
        })
    }
}

impl Seq2Seq for OnnxSeq2Seq {
    fn encode(&self, ids: &[i64]) -> Result<Encoded, String> {
        let n = ids.len() as i64;
        let mut inputs = HashMap::new();
        inputs.insert("input_ids".to_string(), i64_tensor(vec![1, n], ids.to_vec()));
        inputs.insert("attention_mask".to_string(), i64_tensor(vec![1, n], vec![1; ids.len()]));
        let out = self.encoder.run_typed(&inputs, &["last_hidden_state"]).map_err(|e| e.to_string())?;
        match out.into_iter().next().map(|t| t.data) {
            Some(TensorData::F32(hidden)) if hidden.len() == ids.len() * self.dim => {
                Ok(Encoded { hidden, seq: ids.len() })
            }
            _ => Err("the encoder returned an unexpected result".into()),
        }
    }

    fn next_logits(&self, enc: &Encoded, prefix: &[i64]) -> Result<Vec<f32>, String> {
        let mut inputs = HashMap::new();
        inputs.insert("input_ids".to_string(), i64_tensor(vec![1, prefix.len() as i64], prefix.to_vec()));
        inputs.insert("encoder_attention_mask".to_string(), i64_tensor(vec![1, enc.seq as i64], vec![1; enc.seq]));
        inputs.insert(
            "encoder_hidden_states".to_string(),
            TypedTensor::new(vec![1, enc.seq as i64, self.dim as i64], TensorData::F32(enc.hidden.clone())),
        );
        inputs.insert("use_cache_branch".to_string(), TypedTensor::new(vec![1], TensorData::Bool(vec![false])));
        for name in self.decoder.input_names.iter().filter(|n| n.starts_with("past_key_values.")) {
            // An empty cache: the merged model's no-cache branch computes everything from the prefix.
            inputs.insert(
                name.clone(),
                TypedTensor::new(vec![1, self.heads, 0, self.head_dim], TensorData::F32(Vec::new())),
            );
        }
        let out = self.decoder.run_typed(&inputs, &["logits"]).map_err(|e| e.to_string())?;
        let Some(TypedTensor { shape, data: TensorData::F32(all) }) = out.into_iter().next() else {
            return Err("the decoder returned no logits".into());
        };
        let vocab = shape.last().copied().and_then(|v| usize::try_from(v).ok()).filter(|v| *v > 0 && all.len() >= *v);
        let vocab = vocab.ok_or("the decoder returned odd logits")?;
        Ok(all[all.len() - vocab..].to_vec())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A fake network that "translates" by emitting a fixed target sequence, one token per step.
    struct Fake {
        target: Vec<i64>,
        vocab: usize,
    }

    impl Seq2Seq for Fake {
        fn encode(&self, ids: &[i64]) -> Result<Encoded, String> {
            Ok(Encoded { hidden: vec![0.0; ids.len()], seq: ids.len() })
        }
        fn next_logits(&self, _enc: &Encoded, prefix: &[i64]) -> Result<Vec<f32>, String> {
            let mut l = vec![0.0; self.vocab];
            // The pad token (the start) scores highest: the pipeline must ignore it.
            l[0] = -5.0;
            l[9] = 100.0;
            let step = prefix.len() - 1;
            let next = self.target.get(step).copied().unwrap_or(0);
            l[next as usize] = 50.0;
            Ok(l)
        }
    }

    fn model(target: Vec<i64>) -> Marian<Fake> {
        let vocab: HashMap<String, i64> = [
            ("</s>", 0),
            ("<unk>", 1),
            ("\u{2581}Hello", 2),
            ("\u{2581}world", 3),
            ("\u{2581}Hallo", 4),
            ("\u{2581}Welt", 5),
            ("!", 6),
            (">>pt<<", 7),
            ("<pad>", 9),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        let spm = SentencePiece::from_pieces(&[("\u{2581}Hello", -1.0), ("\u{2581}world", -1.0), ("!", -1.0)]);
        Marian::new(Fake { target, vocab: 10 }, spm, vocab, Specials { eos: 0, pad: 9, unk: 1 })
    }

    #[test]
    fn tokenizes_to_known_ids_with_the_end_mark_and_a_language_prefix() {
        let m = model(vec![]);
        assert_eq!(m.tokenize("Hello world!", None), vec![2, 3, 6, 0]);
        assert_eq!(m.tokenize("Hello \u{1F600}", Some(">>pt<<")), vec![7, 2, 1, 0]);
    }

    #[test]
    fn detokenizes_up_to_the_end_mark() {
        let m = model(vec![]);
        assert_eq!(m.detokenize(&[4, 5, 6, 0, 2]), "Hallo Welt!");
        assert_eq!(m.detokenize(&[9, 1, 4]), "Hallo");
    }

    #[test]
    fn the_pipeline_decodes_greedily_until_the_end_mark() {
        let m = model(vec![4, 5, 6, 0]);
        let out = m.translate("Hello world!", None, &Cancel::default()).unwrap();
        assert_eq!(out, "Hallo Welt!");
        assert_eq!(m.translate("   ", None, &Cancel::default()).unwrap(), "");
    }

    #[test]
    fn a_canceled_run_stops() {
        let m = model(vec![4, 5, 6, 0]);
        let c = Cancel::default();
        c.cancel();
        assert!(m.translate("Hello", None, &c).is_err());
    }
}
