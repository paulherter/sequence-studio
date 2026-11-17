# sq-translate

Offline caption translation, the same on Mac and Windows (Swift uses Apple's Translation framework, Mac only). OPUS-MT
(Helsinki-NLP, CC-BY-4.0) Marian models in the ONNX exports of `Xenova/opus-mt-*`, run through `sq-onnx` (ONNX Runtime).

- `sentencepiece`: reads `source.spm` (unigram pieces and scores) and tokenizes with Viterbi; ids come from `vocab.json`.
- `marian`: encoder + merged decoder, greedy decoding without a key/value cache (captions are short), behind the small
  `Seq2Seq` trait so the pipeline is tested with a fake model.
- `store`: the pinned file list per direction (`pins.rs`: commit, size, sha256), the download into the cache folder
  (`SQ_TRANSLATE_MODELS`, else `%LOCALAPPDATA%\SequenceStudio\Translation`, else `~/Library/Application Support/SequenceStudio/Translation`)
  through the system `curl`, with progress and cancel. Models are never bundled in the repo.
- `translator`: language pairs English <-> German, French, Spanish, Italian, Portuguese, Dutch; any other pair of these goes
  through English (two models). `detect`: a small stop-word language guess for those seven languages.

Attribution: OPUS-MT models, Helsinki-NLP, CC-BY-4.0 (docs/THIRD_PARTY.md, About text).

Test: `cargo xtask check sq-translate`. The real-model test runs when `SQ_TRANSLATE_MODELS` holds the en-de files (or
`SQ_TRANSLATE_DOWNLOAD=1` lets it download them).
