import SSCore
@testable import SSTranscribe

func t(_ ms: Int64) -> Time { Time(ms, 1000) }

func w(_ text: String, _ startMs: Int64, _ endMs: Int64) -> TranscriptWord {
    TranscriptWord(text: text, range: TimeRange(start: t(startMs), end: t(endMs)))
}

func transcript(_ words: [TranscriptWord]) -> Transcript {
    Transcript(language: "de-DE", words: words)
}
