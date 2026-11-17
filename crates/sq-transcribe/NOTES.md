# sq-transcribe notes

Ported: all portable Swift files. Not ported (Apple-only): `AudioExtraction.swift`, `SpeechTranscription.swift` and the Swift tests that run
them (ChannelMapped, Speech, WebMAudioExtraction, WordConfidenceFollowUp, WordToken).

## Async and engine seams (PORTING section 9)
- `TranscriptionService`, `WhisperEngine`, `ModelDownloader` are blocking traits; the caller runs them on a worker thread (this replaces
  `Task.detached`). Cancellation is a `CancelToken` argument plus `TranscriptionError::Cancelled` (Swift `CancellationError`). The token
  is a copy of the one in `sq-proxy`: both move into the shared executor crate when it exists.
- The two Swift `prepare` overloads are one `prepare(locale, progress, cancel)`; pass `&mut |_| {}` where Swift passed nothing.
- `Locale` is a small struct over the identifier text (language subtag, `bcp47()`); Foundation's full `Locale` is not needed.
- New word ids come from an `IdSource` (`transcribe`, `applying_text`, `WhisperWords::words`, the readers).
- `Caption::new` takes the word ids and indices explicitly (Swift defaulted them to fresh UUIDs and `0..<0`).
- `CaptionPreset::with` takes a `CaptionPresetOptions` struct instead of five optional labelled arguments.

## FFI
- `vendor/csqwhisper.{c,h}` is a copy of `Packages/SQTranscribe/Sources/CSQWhisper` (our own file; the whisper.h struct layouts inside are MIT,
  see docs/THIRD_PARTY.md). `whisper.dll` / `ggml*.dll` stay a run-time download (`scripts/win-whisper-setup.sh`), not vendored.
- `unsafe impl Send for Context` (whisper_runtime::ffi): a context is used by one thread at a time because `WhisperRuntime` keeps it behind a
  `Mutex`. The cancel callback is polled through a shared reference to one field of the callback struct (it may run on ggml worker
  threads, hence `Sync`), the progress callback through an exclusive reference to the other field.
- Off Windows the C layer reports "not available"; the test `off_windows_the_engine_is_unavailable` covers it. Not run against a real
  `whisper.dll` here (Swift's WhisperRealEngineTests is a manual test); run on the PC with the DLL before relying on it.

## Not ported / waiting on
- `URLSessionDownloader` (HTTP download with progress): needs an HTTP client crate, which is a workspace dependency decision. `WhisperTranscriber::new`
  takes any `ModelDownloader`; until one exists the model has to be placed by hand (or via `scripts/win-whisper-setup.sh`).
- Channel-map transcription in `TimelineTranscription` (Swift: AVFoundation on the Mac, `unavailable` elsewhere): the portable path is ported, so a media
  with a channel map fails with `Unavailable`. Needs the media crate's audio sources.
- An audio reader closure (`AudioReader`: 16 kHz mono floats) from the FFmpeg media layer.

## Swift quirks kept
- `TranscriptEditing.normalise` trims with `CharacterSet.alphanumerics.inverted`; the Rust set is `char::is_alphanumeric` plus the combining-mark blocks.
- Strings compare by bytes (Swift: canonical equivalence), so a typed "e\u{301}" does not match a recognized "\u{e9}". Fix with an NFC helper in
  `sq_core_time::text` when one exists.
- `Character.isLetter/isNumber` are decided by the first scalar (`has_letter_or_number`), as in Swift.
- `split(whereSeparator: isWhitespace)` splits on `char::is_whitespace` here; they differ only for whitespace followed by combining marks.

## ONNX Whisper engine (Windows/Linux, no DLL to place)
- `onnx_whisper.rs` (`OnnxWhisperService`, a `TranscriptionService`), `whisper_mel.rs`, `whisper_tokenizer.rs`, `onnx_whisper_store.rs`
  (+ `CurlDownloader`), `onnx_whisper_pins.rs`. Models: onnx-community/whisper-tiny|base|small_timestamped int8, `SQ_WHISPER_ONNX_SIZE` (default small).
- Timing is segment-level from the model's timestamp tokens, words interpolated by text length (shortcut in the module header; DTW needs an
  export with cross-attentions). Greedy decoding, no temperature fallback, no prompt carry-over between chunks.
- The decoder uses the merged model's key/value cache: step 0 without cache, later steps one token. Silent chunks (RMS < 1e-4) skip the model.
- Real test: `SQ_WHISPER_WAV` (16 kHz mono WAV) + ONNX Runtime on PATH; skips without them.
- The Mac keeps Apple's Speech; the app picks `OnnxWhisperService` or the whisper.cpp `WhisperTranscriber` where no Speech exists.

## ONNX Whisper decoding (w22)
- Settings follow whisper.cpp's greedy defaults, as the Swift app's `sqwh_run` uses them: temperature fallback 0, 0.2 ... 1.0 when the last 32 tokens have entropy below 2.4 or the average log-probability is below -1.0; a chunk with `<|nospeech|>` above 0.6 and an unsure result is silence; the text of the previous chunk is the prompt (`<|startofprev|>`, at most 200 tokens, dropped above temperature 0.5 and after silence). Beam search is not used (the Swift run is greedy too).
- Language: `Locale::new("auto")` detects from the first audible 30 s (language token with the highest logit after `<|startoftranscript|>`). The captions panel passes it when "Auto language" is on and the engine says `detects_language`.
- Word times: the pinned `onnx-community/whisper-*_timestamped` exports return cross-attentions; `OnnxWhisper::align` (teacher-forced pass, openai alignment) + `whisper_align.rs` (normalize, median 7, DTW) time the tokens, clamped to their segment. A model on disk under the earlier Xenova pin (`LEGACY_PINS`) keeps working with interpolated times.
- Channel maps: `transcribe_mapped` renders the item's map through `FFmpegAudioSource::open_mapped` (mixed down to mono); the whole file is transcribed once and words are cut to each clip's source range afterwards, as Swift does for a sequence.
