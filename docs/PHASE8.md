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
