# Phase 8: Captions core (SSTranscribe only)

Scope: package `SSTranscribe` (depends on SSCore for `Time`/`TimeRange`). No UI, no timeline integration, no project-file changes.
SSTranscribe may import Speech/AVFoundation (the no-AVFoundation rule applies to SSCore only). Logic types stay pure value types and are unit-tested without Speech.

## Slices (tests first, each its own commit)
1. **Transcript model** (`Transcript.swift`): `TranscriptWord` (id, text, `TimeRange`, `isEdited`), `Transcript` (language, words, `text`). Codable, Sendable, rational time.
2. **Text-only editing** (`TranscriptEditing.swift`): `Transcript.applyingText(_:)` tokenises the new text, diffs against current words (LCS on normalised tokens). Unchanged words keep their exact timing. Changed/inserted runs are spread across the gap between the nearest unchanged neighbours (proportional to character count, frame-independent, rational). Deleted words vanish. Edited words get `isEdited = true`. Never touches media.
3. **Caption presets + segmentation** (`CaptionPreset.swift`, `CaptionSegmenter.swift`): `CaptionPreset` (maxCharsPerLine, maxLines, maxDuration, minDuration, pauseBreak, `styleRef`, `animationRef` as opaque string IDs). `CaptionSegmenter.segment(transcript, preset) -> [Caption]`; `Caption` = lines of text, `TimeRange`, word id range, `styleRef`, `animationRef`. Breaks on: char/line limit, max duration, long pause, sentence end when the caption is already reasonably full. Captions never overlap and never exceed word bounds.
4. **On-device transcription** (`SpeechTranscription.swift`): protocol `TranscriptionService` + `SpeechAnalyzerTranscriber` (SpeechAnalyzer/SpeechTranscriber, locale de-DE, `.audioTimeRange` attribute for word timing, progress callback, asset install check). Word times converted from `CMTime` to rational `Time`. Real-clip test is gated (skipped when the model or clip is missing); media stays outside the repo.

## Test media
Short clip cut from `~/Documents/Videos` into the scratchpad / `TestMedia/` (gitignored). Never committed.

## Open questions
(collected during implementation)
- Zero-length gap between two unchanged words: an inserted word gets a zero-length range at that point (no time to share without moving unchanged words). Acceptable, or steal time from neighbours?
- `minDuration` is a soft limit only (suppresses the sentence-end break for short captions); captions are never stretched beyond their words' bounds.
- Real-clip test: `TestMedia/` is gitignored only at repo root, not under Packages/SSTranscribe. The test looks at SS_TRANSCRIBE_CLIP, then the session scratchpad clip, then `Packages/SSTranscribe/TestMedia/de_speech_20s.m4a` (add a gitignore line if that path is used). de-DE model was already installed here; no authorization prompt appeared in `swift test`.
- Measurement (Arbeitszeitbetrug.mp4, first 20 s): 62 words, first "Achtung" at 0.06 s, last word ends 19.98 s, starts monotonic. Attribute runs come per word, so no run splitting was needed in practice.
