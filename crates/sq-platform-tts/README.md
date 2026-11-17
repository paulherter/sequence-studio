# sq-platform-tts

Text to speech for Voiceover from Text (Swift `SpeechRenderer`).

- `SpeechEngine`: `voices()` and `synthesize(text, voice, rate, out.wav)`, both blocking.
- `render`: cleans the script, makes room for the file, removes the partial file on a failure.
- `SpeechJob`: one render on a worker thread; the UI polls its `JobState` (`Running`, `Done(length)`, `Failed`).
- Backends: Mac `AVSpeechSynthesizer` (`mac.rs`; needs the main run loop, which the app's window loop gives), Windows
  WinRT `SpeechSynthesizer` (`win.rs`), Linux the `espeak-ng` program (`linux.rs`; run as a process, not linked). A system
  without voices lists none and the dialog says so.
- `ToneSpeech`: a stand-in engine for tests of the flow above it.
- `tests/system_voice.rs`: speaks with the real system voices when `SQ_TTS_SYSTEM=1` is set.
