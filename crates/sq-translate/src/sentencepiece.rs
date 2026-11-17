//! A unigram SentencePiece tokenizer: reads the pieces and scores of a `.spm` model file (a protobuf) and segments text
//! with the best-scoring path (Viterbi). Marian models map the pieces to ids through their own `vocab.json`.

use std::collections::HashMap;

/// The word-start mark of SentencePiece.
pub const SPACE: char = '\u{2581}';

/// Piece types of the model file.
const NORMAL: u64 = 1;
const USER_DEFINED: u64 = 4;

/// The pieces of a unigram model.
#[derive(Clone, Debug, Default)]
pub struct SentencePiece {
    /// Usable pieces: text -> score.
    pieces: HashMap<String, f32>,
    max_chars: usize,
    unknown_score: f32,
}

fn varint(data: &[u8], at: &mut usize) -> Option<u64> {
    let mut out = 0u64;
    for shift in (0..64).step_by(7) {
        let b = *data.get(*at)?;
        *at += 1;
        out |= u64::from(b & 0x7f) << shift;
        if b & 0x80 == 0 {
            return Some(out);
        }
    }
    None
}

/// The fields of one protobuf message: (field number, wire type, varint value or bytes).
enum Field<'a> {
    Varint(u64),
    Bytes(&'a [u8]),
    Fixed32(u32),
    Other,
}

fn fields(data: &[u8]) -> Option<Vec<(u64, Field<'_>)>> {
    let mut at = 0;
    let mut out = Vec::new();
    while at < data.len() {
        let tag = varint(data, &mut at)?;
        let field = match tag & 7 {
            0 => Field::Varint(varint(data, &mut at)?),
            1 => {
                at = at.checked_add(8).filter(|e| *e <= data.len())?;
                Field::Other
            }
            2 => {
                let n = usize::try_from(varint(data, &mut at)?).ok()?;
                let end = at.checked_add(n).filter(|e| *e <= data.len())?;
                let f = Field::Bytes(&data[at..end]);
                at = end;
                f
            }
            5 => {
                let end = at.checked_add(4).filter(|e| *e <= data.len())?;
                let f = Field::Fixed32(u32::from_le_bytes([data[at], data[at + 1], data[at + 2], data[at + 3]]));
                at = end;
                f
            }
            _ => return None,
        };
        out.push((tag >> 3, field));
    }
    Some(out)
}

impl SentencePiece {
    /// Reads a `.spm` file's bytes. `None` when it is not a SentencePiece model with pieces.
    pub fn from_model(data: &[u8]) -> Option<SentencePiece> {
        let mut pieces = HashMap::new();
        let mut max_chars = 1;
        let mut min_score = 0f32;
        for (num, f) in fields(data)? {
            let (1, Field::Bytes(msg)) = (num, f) else { continue };
            let (mut text, mut score, mut kind) = (None, 0f32, NORMAL);
            for (n, f) in fields(msg)? {
                match (n, f) {
                    (1, Field::Bytes(b)) => text = String::from_utf8(b.to_vec()).ok(),
                    (2, Field::Fixed32(bits)) => score = f32::from_bits(bits),
                    (3, Field::Varint(k)) => kind = k,
                    _ => {}
                }
            }
            let Some(text) = text else { continue };
            if kind == NORMAL || kind == USER_DEFINED {
                max_chars = max_chars.max(text.chars().count());
                min_score = min_score.min(score);
                pieces.insert(text, score);
            }
        }
        if pieces.is_empty() {
            return None;
        }
        // SentencePiece's unk penalty: an unknown character costs 10 below the worst piece.
        Some(SentencePiece { pieces, max_chars, unknown_score: min_score - 10.0 })
    }

    /// Builds a model from `(piece, score)` pairs (tests).
    pub fn from_pieces(list: &[(&str, f32)]) -> SentencePiece {
        let mut pieces = HashMap::new();
        let mut max_chars = 1;
        let mut min_score = 0f32;
        for (p, s) in list {
            max_chars = max_chars.max(p.chars().count());
            min_score = min_score.min(*s);
            pieces.insert((*p).to_string(), *s);
        }
        SentencePiece { pieces, max_chars, unknown_score: min_score - 10.0 }
    }

    /// Splits `text` into pieces; a character no piece covers comes back as `None`.
    // shortcut: plain NFKC stands in for the model's `nmt_nfkc` charsmap (which also drops control characters and maps odd
    // spaces); upgrade by reading the precompiled charsmap of the `.spm` when a caption translates differently.
    pub fn encode(&self, text: &str) -> Vec<Option<String>> {
        use unicode_normalization::UnicodeNormalization;
        let text: String = text.nfkc().collect();
        let words: Vec<&str> = text.split_whitespace().collect();
        if words.is_empty() {
            return Vec::new();
        }
        let normalized: Vec<char> = std::iter::once(SPACE).chain(words.join(&SPACE.to_string()).chars()).collect();
        let n = normalized.len();
        // best[i]: score of the best segmentation of the first i characters; back[i]: where its last piece starts.
        let mut best = vec![f32::NEG_INFINITY; n + 1];
        let mut back = vec![0usize; n + 1];
        best[0] = 0.0;
        for end in 1..=n {
            for start in end.saturating_sub(self.max_chars)..end {
                if best[start] == f32::NEG_INFINITY {
                    continue;
                }
                let piece: String = normalized[start..end].iter().collect();
                let score = match self.pieces.get(&piece) {
                    Some(s) => *s,
                    None if end - start == 1 => self.unknown_score,
                    None => continue,
                };
                if best[start] + score > best[end] {
                    best[end] = best[start] + score;
                    back[end] = start;
                }
            }
        }
        let mut out = Vec::new();
        let mut end = n;
        while end > 0 {
            let start = back[end];
            let piece: String = normalized[start..end].iter().collect();
            out.push(self.pieces.contains_key(&piece).then_some(piece));
            end = start;
        }
        out.reverse();
        // Adjacent unknown characters become one unknown, as in SentencePiece.
        out.dedup_by(|a, b| a.is_none() && b.is_none());
        out
    }
}

/// The words of decoded pieces: pieces joined, the word mark turned into a space.
pub fn join_pieces<'a>(pieces: impl Iterator<Item = &'a str>) -> String {
    let joined: String = pieces.collect();
    joined.replace(SPACE, " ").trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ligatures_and_full_width_forms_are_normalized_before_segmenting() {
        let sp = SentencePiece::from_pieces(&[("\u{2581}office", -1.0), ("\u{2581}ABC", -1.0), ("\u{2581}A", -5.0)]);
        // "o\u{FB03}ce" (ffi ligature) is "office" in NFKC; full-width "ＡＢＣ" is "ABC".
        assert_eq!(sp.encode("o\u{FB03}ce"), vec![Some("\u{2581}office".to_string())]);
        assert_eq!(sp.encode("\u{FF21}\u{FF22}\u{FF23}"), vec![Some("\u{2581}ABC".to_string())]);
    }

    fn pb_len(field: u8, body: &[u8]) -> Vec<u8> {
        let mut v = vec![(field << 3) | 2, body.len() as u8];
        v.extend_from_slice(body);
        v
    }

    fn piece_message(text: &str, score: f32, kind: u8) -> Vec<u8> {
        let mut body = pb_len(1, text.as_bytes());
        body.push((2 << 3) | 5);
        body.extend_from_slice(&score.to_le_bytes());
        body.extend_from_slice(&[3 << 3, kind]);
        pb_len(1, &body)
    }

    #[test]
    fn reads_a_model_file_and_skips_control_pieces() {
        let mut data = piece_message("<unk>", 0.0, 2);
        data.extend(piece_message("\u{2581}Hello", -3.0, 1));
        data.extend(piece_message("</s>", 0.0, 3));
        let sp = SentencePiece::from_model(&data).unwrap();
        assert_eq!(sp.encode("Hello"), vec![Some("\u{2581}Hello".to_string())]);
        assert!(SentencePiece::from_model(&[]).is_none());
    }

    #[test]
    fn viterbi_prefers_the_higher_total_score() {
        let sp = SentencePiece::from_pieces(&[
            ("\u{2581}un", -3.0),
            ("\u{2581}u", -4.0),
            ("n", -4.0),
            ("known", -2.0),
            ("\u{2581}unknown", -4.0),
            ("\u{2581}", -1.0),
        ]);
        // "▁unknown" as one piece (-4) beats "▁un"+"known" (-5).
        assert_eq!(sp.encode("unknown"), vec![Some("\u{2581}unknown".to_string())]);
        assert_eq!(
            sp.encode("  un   known "),
            vec![Some("\u{2581}un".to_string()), Some("\u{2581}".to_string()), Some("known".to_string())]
        );
    }

    #[test]
    fn an_uncovered_character_is_one_unknown() {
        let sp = SentencePiece::from_pieces(&[("\u{2581}a", -1.0), ("b", -1.0)]);
        assert_eq!(sp.encode("a\u{1F600}\u{1F600}b"), vec![Some("\u{2581}a".to_string()), None, Some("b".to_string())]);
    }

    #[test]
    fn pieces_join_into_words() {
        assert_eq!(join_pieces(["\u{2581}Hal", "lo", "\u{2581}Welt", "."].into_iter()), "Hallo Welt.");
    }
}
