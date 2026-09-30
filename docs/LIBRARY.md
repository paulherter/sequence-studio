# Library core (new package `SSLibrary`)

Standalone package, Foundation only (no AppKit/AVFoundation). No UI, no rendering, no project.yml changes. `scripts/test.sh SSLibrary` works via the `SS*` glob.
Preset payloads are opaque versioned JSON (`Data`) tagged by kind, so SSLibrary does not depend on SSText/SSCore while those evolve; typed wrappers come at integration.

## Slices (tests first, one commit each)
1. **File classification** (`LibraryItemKind.swift`): detect kind from extension/UTType (audio, video, image, overlay = alpha video/png, LUT, font, other), case-insensitive, ignores hidden/system files.
2. **Watched folders** (`WatchedFolder.swift`, `FolderScanner.swift`): folder entries (id, URL, display name, security-scoped bookmark `Data?`), recursive scan into `LibraryEntry` (path, kind, size, modified date), incremental rescan diff (added/removed/changed) as a pure function of two snapshots; FSEvents/DispatchSource watch behind a protocol so tests use a fake. Missing folder = offline state, not an error.
3. **Search + favorites** (`LibrarySearch.swift`, `Favorites.swift`): case/diacritic-insensitive multi-token name search with kind filter, sorting (name, date, size), favorites set keyed by stable entry id (path relative to folder + folder id), persisted as versioned JSON.
4. **Thumbnail/waveform request API** (`PreviewRequests.swift`): `PreviewRequest` (entry id, kind: thumbnail/waveform, pixel size, content hash = path+mtime+size), `PreviewCache` key/path derivation in Caches dir, protocol `PreviewProvider` (async, cancellable) with no implementation, request coalescing/de-dup and staleness when the file changes.
5. **User preset store** (`PresetStore.swift`): `PresetKind` (textTemplate, animatedTextTemplate, easing, caption, effect), `PresetItem` (id, kind, name, createdAt, payload Data, payloadVersion), store in `Application Support/Sequence Studio/Library/presets.json` (injectable base URL), `formatVersion` 1, sorted keys, atomic writes, newer version → typed error, corrupt file → backup + empty store, CRUD + rename + search by kind.

## Open questions
1. Overlay detection: classification is extension-only; `.overlay` needs an alpha hint (`hasAlpha`) from a later AVFoundation/ImageIO probe. Who runs it and caches the result (scan time vs lazily)?
2. Extension table: webm/mkv/avi/mxf listed as video even if the decoder cannot play them; ProRes alpha lives in .mov. Trim or extend the list?
3. Security-scoped bookmarks: `WatchedFolder.bookmark` is opaque here; resolve/start-access must happen in the app layer, and scanning assumes access is already started. Sandboxed or not?
4. Scanner skips hidden dirs/files and package contents, and does not follow symlinked entries outside the folder. OK?
5. `FSEventsFolderWatcher` (CoreServices) is implemented but untested (only the fake is unit tested); needs a manual check. Default latency 1 s.
6. Search matches the file name only, not folder path or metadata/tags. Add path or tag search?
7. Entry id = folder id + relative path, so a move/rename inside the folder drops its favorite. Acceptable, or track by file id?
8. Preview cache files have no size cap or eviction (only stale versions of the same entry are removed). Need an LRU limit? Preview format (png/waveform binary) is decided by the provider implementation.
9. Preset payloads are opaque; migration of old `payloadVersion`s is the owning feature's job. Should the store offer export/import of presets (file or share)?
10. Corrupt files are moved to `<name>.corrupt-<timestamp>`; backups are never pruned.
