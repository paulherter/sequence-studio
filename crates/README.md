# Crates

Cargo workspace members. Names mirror the Swift packages (`SQFoo` -> `sq-foo`). Order and dependencies: `docs/rust/crate-order.tsv`. Rules: `docs/rust/PORTING.md`.

| crate | from | status |
|---|---|---|
| xtask | new | v0 (check, gate, hooks, driver) |
| sq-installer | new | Windows setup program and Linux first-run window (design/installer) |
| sq-setup-engine | new | payload, install plan, rollback, SQI error codes for the setup |
| sq-prproj-reader | SQPremiereImport (container) | container reader ported |
| sq-core-time | SQCore (split, docs/rust/sq-core-split.md) | time, ids, keyframes, text ported; T-1 remainder open |
| sq-core-model | SQCore (split) | skeleton (docs/rust/sq-core-model-tasks.md) |
| sq-edit | SQCore | planned |
| sq-color | SQCore | planned |
| sq-masks | SQCore | planned |
| sq-project-file | SQCore | planned |
| sq-gpu | SQGPU | planned |
| sq-onnx | SQOnnx | planned |
| sq-frame | SQFrame | planned |
| sq-audiofx | SQAudioFX | planned |
| sq-editapi | SQEditAPI | planned |
| sq-text | SQText | planned |
| sq-media | SQMedia | planned |
| sq-media-ffmpeg | SQMediaFFmpeg | planned |
| sq-premiereimport | SQPremiereImport | planned |
| sq-render | SQRender | planned |
| sq-analysis | SQAnalysis | planned |
| sq-library | SQLibrary | planned |
| sq-proxy | SQProxy | planned |
| sq-transcribe | SQTranscribe | planned |
| sq-lottie | SQLottie | planned |
| sq-uikit | SQUIKit | planned |
| sq-playback | SQPlayback | planned |
| sq-export | SQExport | planned |
| sq-drawkit | SQDrawKit | planned |
| sq-editor-session | SQEditorSession | planned |
| sq-draw-monitor | SQDrawMonitor | planned |
| sq-draw-shell | SQDrawShell | planned |
| sq-timeline-ui | SQTimelineUi | planned |
| sq-draw-timeline | SQDrawTimeline | planned |
| sq-inspector-ui | SQInspectorUi | planned |
| sq-draw-library | SQDrawLibrary | planned |
| sq-app-shell | SQAppShell | planned |
| sq-gpu-interop | new (unsafe allow-list) | planned |
| sq-video-hw | new (unsafe allow-list) | planned |
| sq-platform-mac | new (unsafe allow-list) | planned |
| sq-platform-win | new (unsafe allow-list) | planned |
| sqgyro | Vendor/sqgyro | planned |
