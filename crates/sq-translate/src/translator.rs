//! The translation service: language pairs, the model download on first use, and the run over a list of captions.

use crate::detect::detect_language;
use crate::marian::{Marian, OnnxSeq2Seq, Specials};
use crate::sentencepiece::SentencePiece;
use crate::store::{Cancel, Fetcher, TranslateStore};
use std::collections::HashMap;
use std::fmt;

/// The languages the models cover: BCP-47 code and English name, sorted by name.
pub fn supported_languages() -> Vec<(&'static str, &'static str)> {
    vec![
        ("nl", "Dutch"),
        ("en", "English"),
        ("fr", "French"),
        ("de", "German"),
        ("it", "Italian"),
        ("pt", "Portuguese"),
        ("es", "Spanish"),
    ]
}

/// English name of a language code (the code itself when unknown).
pub fn language_name(code: &str) -> String {
    supported_languages().iter().find(|(c, _)| *c == code).map_or_else(|| code.to_string(), |(_, n)| (*n).to_string())
}

/// One model direction: the repo and the language token the source needs (multi-target models).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Direction {
    /// Repo suffix (`en-de`, `ROMANCE-en`).
    pub repo: &'static str,
    /// `>>pt<<`-style prefix of the source text.
    pub prefix: Option<&'static str>,
}

/// The direct model from `from` to `to`; both are base codes. Only English pairs exist.
pub fn direction(from: &str, to: &str) -> Option<Direction> {
    const DIRECT: [&str; 5] = ["de", "fr", "es", "it", "nl"];
    let dir = |repo, prefix| Some(Direction { repo, prefix });
    match (from, to) {
        ("en", "de") => dir("en-de", None),
        ("en", "fr") => dir("en-fr", None),
        ("en", "es") => dir("en-es", None),
        ("en", "it") => dir("en-it", None),
        ("en", "nl") => dir("en-nl", None),
        ("en", "pt") => dir("en-ROMANCE", Some(">>pt<<")),
        ("de", "en") => dir("de-en", None),
        ("fr", "en") => dir("fr-en", None),
        ("es", "en") => dir("es-en", None),
        ("it", "en") => dir("it-en", None),
        ("nl", "en") => dir("nl-en", None),
        ("pt", "en") => dir("ROMANCE-en", None),
        (f, t)
            if f != t
                && DIRECT.iter().chain(&["pt"]).any(|c| *c == f)
                && DIRECT.iter().chain(&["pt"]).any(|c| *c == t) =>
        {
            None
        }
        _ => None,
    }
}

/// The steps from `from` to `to`: one model with English on either side, else two through English.
pub fn plan(from: &str, to: &str) -> Result<Vec<Direction>, TranslateError> {
    if from == to {
        return Ok(Vec::new());
    }
    if let Some(d) = direction(from, to) {
        return Ok(vec![d]);
    }
    match (direction(from, "en"), direction("en", to)) {
        (Some(a), Some(b)) => Ok(vec![a, b]),
        _ => Err(TranslateError::Unsupported(format!("{} to {}", language_name(from), language_name(to)))),
    }
}

/// What a running job reports.
#[derive(Clone, Debug, PartialEq)]
pub enum Progress {
    /// Downloading the model of a direction: label and 0...1.
    Downloading(String, f64),
    /// Texts translated so far, of the total.
    Translating(usize, usize),
}

/// Why a translation did not happen.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TranslateError {
    /// No model for this pair.
    Unsupported(String),
    /// Canceled by the user.
    Canceled,
    /// The download, the runtime or a model failed.
    Failed(String),
}

impl fmt::Display for TranslateError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            TranslateError::Unsupported(p) => write!(f, "Translation {p} is not supported."),
            TranslateError::Canceled => f.write_str("Translation canceled."),
            TranslateError::Failed(why) => write!(f, "Translation failed: {why}"),
        }
    }
}

impl std::error::Error for TranslateError {}

/// Whether the ONNX runtime can be loaded here (the translation row stays dimmed without it).
pub fn runtime_available() -> bool {
    sq_onnx::onnx_model::OnnxModel::is_available() || sq_onnx::onnx_model::OnnxModel::load_runtime(None).is_ok()
}

/// The language of the texts (`None` when it cannot be told or is not one of ours).
pub fn detect(texts: &[String]) -> Option<&'static str> {
    detect_language(texts)
}

/// Translates lists of texts between the supported languages.
pub struct Translator {
    store: TranslateStore,
}

impl Translator {
    /// A translator over the model folder.
    pub fn new(store: TranslateStore) -> Translator {
        Translator { store }
    }

    /// The Marian pipeline of an installed direction.
    fn load(&self, d: Direction) -> Result<Marian<OnnxSeq2Seq>, TranslateError> {
        let failed = |e: String| TranslateError::Failed(e);
        let dir = self.store.dir(d.repo);
        let read = |name: &str| std::fs::read(dir.join(name)).map_err(|e| failed(format!("{name}: {e}")));
        let spm = SentencePiece::from_model(&read("source.spm")?)
            .ok_or_else(|| failed("source.spm is not a SentencePiece model".into()))?;
        let vocab: HashMap<String, i64> =
            serde_json::from_slice(&read("vocab.json")?).map_err(|e| failed(format!("vocab.json: {e}")))?;
        let config = String::from_utf8(read("config.json")?).map_err(|e| failed(e.to_string()))?;
        let cfg: serde_json::Value = serde_json::from_str(&config).map_err(|e| failed(e.to_string()))?;
        let id = |k: &str, default: i64| cfg.get(k).and_then(serde_json::Value::as_i64).unwrap_or(default);
        let specials = Specials {
            eos: id("eos_token_id", 0),
            pad: id("pad_token_id", 0),
            unk: vocab.get("<unk>").copied().unwrap_or(1),
        };
        let net = OnnxSeq2Seq::open(
            &dir.join("encoder_model_quantized.onnx"),
            &dir.join("decoder_model_merged_quantized.onnx"),
            &config,
        )
        .map_err(failed)?;
        Ok(Marian::new(net, spm, vocab, specials))
    }

    /// Translates `texts` (same order) from `from` to `to` (base codes). Downloads missing models first.
    pub fn translate(
        &self,
        texts: &[String],
        from: &str,
        to: &str,
        fetcher: &dyn Fetcher,
        progress: &mut dyn FnMut(Progress),
        cancel: &Cancel,
    ) -> Result<Vec<String>, TranslateError> {
        let steps = plan(from, to)?;
        let mut current = texts.to_vec();
        for (i, d) in steps.iter().enumerate() {
            if !self.store.is_installed(d.repo) {
                let label = format!("{} model", d.repo);
                progress(Progress::Downloading(label.clone(), 0.0));
                self.store
                    .install(d.repo, fetcher, &mut |f| progress(Progress::Downloading(label.clone(), f)), cancel)
                    .map_err(
                        |e| if cancel.is_canceled() { TranslateError::Canceled } else { TranslateError::Failed(e) },
                    )?;
            }
            let model = self.load(*d)?;
            let mut out = Vec::with_capacity(current.len());
            for (n, text) in current.iter().enumerate() {
                if cancel.is_canceled() {
                    return Err(TranslateError::Canceled);
                }
                // The first step of a pivot is half of the work.
                let step_done = if steps.len() == 2 { (i * current.len() + n) / 2 } else { n };
                progress(Progress::Translating(step_done, texts.len()));
                out.push(model.translate(text, d.prefix, cancel).map_err(|e| {
                    if cancel.is_canceled() { TranslateError::Canceled } else { TranslateError::Failed(e) }
                })?);
            }
            current = out;
        }
        progress(Progress::Translating(texts.len(), texts.len()));
        Ok(current)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::CurlFetcher;

    #[test]
    fn every_direction_between_english_and_the_six_languages_exists() {
        for l in ["de", "fr", "es", "it", "pt", "nl"] {
            assert!(direction("en", l).is_some(), "en->{l}");
            assert!(direction(l, "en").is_some(), "{l}->en");
        }
        assert_eq!(direction("en", "pt").map(|d| (d.repo, d.prefix)), Some(("en-ROMANCE", Some(">>pt<<"))));
        assert_eq!(direction("de", "fr"), None);
    }

    #[test]
    fn other_pairs_go_through_english() {
        let steps = plan("de", "pt").unwrap();
        assert_eq!(steps.iter().map(|d| d.repo).collect::<Vec<_>>(), ["de-en", "en-ROMANCE"]);
        assert_eq!(plan("en", "fr").unwrap().len(), 1);
        assert!(plan("de", "de").unwrap().is_empty());
        assert!(matches!(plan("de", "xx"), Err(TranslateError::Unsupported(_))));
    }

    /// The CPU and the platform accelerator (DirectML / Core ML) must translate the sample sentences to the same text; times
    /// per sentence go to stdout. Same switches as the test below. OPUS-MT stays on the CPU in the app: the quantized int8 parts
    /// crash DirectML on the PC (access violation, measured 2026-11-09), so the accelerator pass needs `SQ_TRANSLATE_ACCEL=1`.
    #[test]
    fn the_accelerator_and_the_cpu_translate_the_same_text() {
        use sq_onnx::onnx_model::Provider;
        let Some(folder) = std::env::var("SQ_TRANSLATE_MODELS").ok() else { return };
        if !runtime_available() {
            println!("no ONNX runtime here: skipped");
            return;
        }
        let src: Vec<String> =
            ["Hello, how are you today?", "The weather is nice.", "We will meet at the station tomorrow morning."]
                .iter()
                .map(|s| s.to_string())
                .collect();
        let mut results = Vec::new();
        let accelerated =
            if std::env::var_os("SQ_TRANSLATE_ACCEL").is_some() { Provider::platform_default() } else { Provider::Cpu };
        for provider in [Provider::Cpu, accelerated] {
            Provider::force(Some(provider));
            let t = Translator::new(TranslateStore::new(folder.clone().into()));
            let warm = t.translate(&src[..1], "en", "de", &CurlFetcher, &mut |_| {}, &Cancel::default());
            let start = std::time::Instant::now();
            let de = t.translate(&src, "en", "de", &CurlFetcher, &mut |_| {}, &Cancel::default());
            let per = start.elapsed().as_secs_f64() / src.len() as f64;
            println!("opus-mt {provider:?}: {per:.3} s per sentence (first run ok: {}): {de:?}", warm.is_ok());
            results.push(de.unwrap_or_default());
        }
        Provider::force(None);
        assert_eq!(results[0], results[1], "the providers disagree");
        assert_eq!(results[0].len(), 3);
    }

    /// The real en->de model. Needs the files in `SQ_TRANSLATE_MODELS` (or `SQ_TRANSLATE_DOWNLOAD=1` to fetch them) and a runtime.
    #[test]
    fn real_model_translates_a_sentence_en_to_de_and_back() {
        let folder = std::env::var("SQ_TRANSLATE_MODELS").ok();
        let download = std::env::var("SQ_TRANSLATE_DOWNLOAD").is_ok();
        let Some(folder) = folder.filter(|_| download || std::env::var("SQ_TRANSLATE_MODELS").is_ok()) else { return };
        if !runtime_available() {
            println!("no ONNX runtime here: skipped");
            return;
        }
        let t = Translator::new(TranslateStore::new(folder.into()));
        let src = vec!["Hello, how are you today?".to_string(), "The weather is nice.".to_string()];
        let mut log = Vec::new();
        let de = t.translate(&src, "en", "de", &CurlFetcher, &mut |p| log.push(p), &Cancel::default()).unwrap();
        println!("en->de: {de:?}");
        assert_eq!(de.len(), 2);
        assert!(de.iter().zip(&src).all(|(d, s)| !d.is_empty() && d != s));
        assert_eq!(detect(&de), Some("de"));
        if t.store.is_installed("de-en") || download {
            let back = t.translate(&de, "de", "en", &CurlFetcher, &mut |_| {}, &Cancel::default()).unwrap();
            println!("de->en: {back:?}");
            assert!(back.iter().all(|b| !b.is_empty()));
        }
    }
}
