//! Whisper's byte-level BPE tokenizer, read from the model's `tokenizer.json` (identical for tiny, base and small).
//! Decoding is what transcription needs; encoding (a close copy of the GPT-2 splitter) serves prompts and the round-trip test.

use std::collections::HashMap;

/// GPT-2's byte to printable-character map and its inverse.
fn byte_to_char() -> [char; 256] {
    let mut out = ['\0'; 256];
    let mut n = 0u32;
    for b in 0..=255u32 {
        let direct = (33..=126).contains(&b) || (161..=172).contains(&b) || (174..=255).contains(&b);
        let code = if direct {
            b
        } else {
            n += 1;
            255 + n
        };
        out[b as usize] = char::from_u32(code).unwrap_or('?');
    }
    out
}

/// The tokenizer plus the special token ids the decoder needs.
pub struct WhisperTokenizer {
    id_to_bytes: Vec<Option<Vec<u8>>>,
    vocab: HashMap<String, i64>,
    ranks: HashMap<(String, String), usize>,
    specials: HashMap<String, i64>,
    byte_char: [char; 256],
    /// `<|endoftext|>`.
    pub eot: i64,
    /// `<|startoftranscript|>`.
    pub sot: i64,
    /// `<|transcribe|>`.
    pub transcribe: i64,
    /// `<|notimestamps|>`.
    pub no_timestamps: i64,
    /// `<|0.00|>`: timestamp tokens run from here in 20 ms steps.
    pub timestamp_begin: i64,
}

impl WhisperTokenizer {
    /// Reads `tokenizer.json`.
    pub fn from_json(text: &str) -> Result<WhisperTokenizer, String> {
        let v: serde_json::Value = serde_json::from_str(text).map_err(|e| format!("bad tokenizer.json: {e}"))?;
        let vocab_json = v
            .pointer("/model/vocab")
            .and_then(serde_json::Value::as_object)
            .ok_or("tokenizer.json has no model.vocab")?;
        let byte_char = byte_to_char();
        let char_byte: HashMap<char, u8> =
            byte_char.iter().enumerate().filter_map(|(b, c)| u8::try_from(b).ok().map(|b| (*c, b))).collect();
        let mut vocab = HashMap::new();
        let mut size = 0usize;
        for (tok, id) in vocab_json {
            let id = id.as_i64().ok_or("a vocab id is not a number")?;
            size = size.max(usize::try_from(id).unwrap_or(0) + 1);
            vocab.insert(tok.clone(), id);
        }
        let mut specials = HashMap::new();
        for t in v.get("added_tokens").and_then(serde_json::Value::as_array).map_or(&[][..], Vec::as_slice) {
            if let (Some(c), Some(id)) =
                (t.get("content").and_then(|c| c.as_str()), t.get("id").and_then(|i| i.as_i64()))
            {
                size = size.max(usize::try_from(id).unwrap_or(0) + 1);
                specials.insert(c.to_string(), id);
            }
        }
        let mut id_to_bytes: Vec<Option<Vec<u8>>> = vec![None; size];
        for (tok, id) in &vocab {
            let bytes: Option<Vec<u8>> = tok.chars().map(|c| char_byte.get(&c).copied()).collect();
            if let (Some(b), Ok(i)) = (bytes, usize::try_from(*id)) {
                id_to_bytes[i] = Some(b);
            }
        }
        let mut ranks = HashMap::new();
        for (rank, m) in
            v.pointer("/model/merges").and_then(serde_json::Value::as_array).into_iter().flatten().enumerate()
        {
            let pair = match m {
                serde_json::Value::String(s) => s.split_once(' ').map(|(a, b)| (a.to_string(), b.to_string())),
                serde_json::Value::Array(a) => match (a.first(), a.get(1)) {
                    (Some(x), Some(y)) => {
                        Some((x.as_str().unwrap_or_default().to_string(), y.as_str().unwrap_or_default().to_string()))
                    }
                    _ => None,
                },
                _ => None,
            };
            if let Some(p) = pair {
                ranks.insert(p, rank);
            }
        }
        let special = |name: &str| specials.get(name).copied().ok_or_else(|| format!("tokenizer.json lacks {name}"));
        Ok(WhisperTokenizer {
            eot: special("<|endoftext|>")?,
            sot: special("<|startoftranscript|>")?,
            transcribe: special("<|transcribe|>")?,
            no_timestamps: special("<|notimestamps|>")?,
            timestamp_begin: special("<|0.00|>")?,
            id_to_bytes,
            vocab,
            ranks,
            specials,
            byte_char,
        })
    }

    /// Number of ids (text and special).
    pub fn len(&self) -> usize {
        self.id_to_bytes.len()
    }

    /// Whether the tokenizer holds no ids.
    pub fn is_empty(&self) -> bool {
        self.id_to_bytes.is_empty()
    }

    /// The id of a special token such as `<|de|>`.
    pub fn special(&self, name: &str) -> Option<i64> {
        self.specials.get(name).copied()
    }

    /// The id of the language token for a Whisper code ("de").
    pub fn language(&self, code: &str) -> Option<i64> {
        self.special(&format!("<|{code}|>"))
    }

    /// Whether `id` is a control token (never part of the text): everything from `<|endoftext|>` on, timestamps included.
    pub fn is_special(&self, id: i64) -> bool {
        id >= self.eot
    }

    /// The bytes of a text token (empty for control tokens).
    pub fn token_bytes(&self, id: i64) -> &[u8] {
        usize::try_from(id).ok().and_then(|i| self.id_to_bytes.get(i)).and_then(|b| b.as_deref()).unwrap_or(&[])
    }

    /// The text of `ids`; control tokens are skipped, bytes are joined before UTF-8 decoding.
    pub fn decode(&self, ids: &[i64]) -> String {
        let mut bytes = Vec::new();
        for id in ids {
            if !self.is_special(*id) {
                bytes.extend_from_slice(self.token_bytes(*id));
            }
        }
        String::from_utf8_lossy(&bytes).into_owned()
    }

    /// The ids of `text` (GPT-2 splitting, then BPE merges by rank).
    pub fn encode(&self, text: &str) -> Vec<i64> {
        let mut out = Vec::new();
        for piece in pretokenize(text) {
            let mut symbols: Vec<String> = piece.bytes().map(|b| self.byte_char[b as usize].to_string()).collect();
            loop {
                let best = (0..symbols.len().saturating_sub(1))
                    .filter_map(|i| self.ranks.get(&(symbols[i].clone(), symbols[i + 1].clone())).map(|r| (*r, i)))
                    .min();
                let Some((_, i)) = best else { break };
                let merged = format!("{}{}", symbols[i], symbols[i + 1]);
                symbols.splice(i..=i + 1, [merged]);
            }
            out.extend(symbols.iter().filter_map(|s| self.vocab.get(s).copied()));
        }
        out
    }
}

/// GPT-2's pattern `'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+` without a regex engine.
fn pretokenize(text: &str) -> Vec<String> {
    let c: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut i = 0;
    let class = |ch: char| -> u8 {
        if ch.is_alphabetic() {
            1
        } else if ch.is_numeric() {
            2
        } else {
            3
        }
    };
    while i < c.len() {
        if c[i] == '\'' {
            let rest: String = c[i + 1..c.len().min(i + 3)].iter().collect();
            if let Some(n) = ["re", "ve", "ll", "s", "t", "m", "d"].iter().find(|s| rest.starts_with(**s)) {
                out.push(c[i..i + 1 + n.len()].iter().collect());
                i += 1 + n.len();
                continue;
            }
        }
        let j = if c[i] == ' ' && i + 1 < c.len() && !c[i + 1].is_whitespace() { i + 1 } else { i };
        if c[j].is_whitespace() {
            let mut k = i;
            while k < c.len() && c[k].is_whitespace() {
                k += 1;
            }
            if k < c.len() && k - i > 1 {
                k -= 1;
            }
            out.push(c[i..k].iter().collect());
            i = k;
        } else {
            let cl = class(c[j]);
            let mut k = j;
            while k < c.len() && !c[k].is_whitespace() && class(c[k]) == cl {
                k += 1;
            }
            out.push(c[i..k].iter().collect());
            i = k;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A tiny vocabulary in the real file's shape: GPT-2 byte characters (space is "Ġ"), merges, specials.
    fn tiny() -> WhisperTokenizer {
        let json = r#"{"added_tokens":[
            {"id":10,"content":"<|endoftext|>"},{"id":11,"content":"<|startoftranscript|>"},{"id":12,"content":"<|de|>"},
            {"id":13,"content":"<|transcribe|>"},{"id":14,"content":"<|notimestamps|>"},{"id":15,"content":"<|0.00|>"}],
          "model":{"vocab":{"h":0,"i":1,"hi":2,"Ġ":3,"Ġt":4,"t":5,"!":6,"Ã":7,"¼":8,"Ġhi":9},
                   "merges":["h i","Ġ t","Ġ hi"]}}"#;
        WhisperTokenizer::from_json(json).unwrap()
    }

    #[test]
    fn byte_map_matches_gpt2() {
        let m = byte_to_char();
        assert_eq!(m[b'a' as usize], 'a');
        assert_eq!(m[b' ' as usize], 'Ġ');
        assert_eq!(m[b'\n' as usize], 'Ċ');
        assert_eq!(m[0xC3], 'Ã');
    }

    #[test]
    fn special_ids_and_language_tokens() {
        let t = tiny();
        assert_eq!((t.eot, t.sot, t.transcribe, t.no_timestamps, t.timestamp_begin), (10, 11, 13, 14, 15));
        assert_eq!(t.language("de"), Some(12));
        assert_eq!(t.language("fr"), None);
        assert!(t.is_special(15) && !t.is_special(9));
    }

    #[test]
    fn encode_merges_by_rank_and_decode_returns_the_text() {
        let t = tiny();
        // "hi hi!": "hi", then " hi" (Ġ + hi merged), then "!".
        let ids = t.encode("hi hi!");
        assert_eq!(ids, vec![2, 9, 6]);
        assert_eq!(t.decode(&ids), "hi hi!");
        // Control tokens are dropped from the text.
        assert_eq!(t.decode(&[11, 12, 2, 15, 10]), "hi");
    }

    #[test]
    fn a_character_split_across_tokens_decodes_whole() {
        // "ü" is the two bytes C3 BC, held by two tokens "Ã" and "¼".
        assert_eq!(tiny().decode(&[7, 8]), "ü");
    }

    #[test]
    fn the_splitter_follows_gpt2() {
        assert_eq!(pretokenize("Hello world, it's 2024!"), ["Hello", " world", ",", " it", "'s", " 2024", "!"]);
        assert_eq!(pretokenize("a  b"), ["a", " ", " b"]);
        assert_eq!(pretokenize("x\ny"), ["x", "\n", "y"]);
    }
}
