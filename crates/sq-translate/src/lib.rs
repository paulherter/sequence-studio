//! Offline caption translation on OPUS-MT models (see README.md).

pub mod detect;
pub mod marian;
pub mod sentencepiece;
pub mod store;
pub mod translator;

mod pins;

pub use store::{Cancel, CurlFetcher, Fetcher, TranslateStore};
pub use translator::{Progress, TranslateError, Translator, language_name, supported_languages};
