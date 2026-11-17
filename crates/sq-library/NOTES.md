# sq-library notes (Etappe 2b, group g1)

Ported: all 25 portable files of `SQLibrary` (list in `docs/rust/etappe2b-groups.tsv`). Not ported (Apple-only): the FSEvents
watcher, `MediaPreviewProvider`, the AVFoundation preview player. This crate has no OS code; the seams are traits.

## Seams the app implements
- `FolderWatching` / `FolderWatchToken` (`folder_watching.rs`): the app wraps the `notify` crate behavior (coalesced "something changed").
  `FakeFolderWatcher` is the test double.
- `PreviewProvider` (`preview_requests.rs`): blocking `generate(request, destination, cancel)`; the app runs it on a worker.
- `SettingsStore` (`library_folder_store.rs`): replaces `UserDefaults` for the folder list. `MemorySettings` is the in-memory one.
- Clocks: `Timestamp` arguments (`now`) where Swift read `Date()` (`PresetStore::open`, `FavoritesStore::load`, `LUTLibrary::new`,
  `PresetFile::decode`, `import_pack`, `*::preset_item`). Ids come from `IdSource`. One exception, marked `shortcut`:
  `PreviewCache::touch` sets the file's mtime to the system time.

## Actors and @Observable (PORTING section 9)
- `LibraryIndex` (actor): plain struct. The watcher callback only pushes the folder id into a shared queue; the owner calls
  `process_changes()` and reads updates from the `Receiver` of `updates()`. `version()` counts changes.
- `PresetStore` (actor): plain struct with `&mut self`; `version()` counts successful writes.
- `PreviewCoordinator` (actor with `Task`s): a step machine. `begin` returns `Ready`, `Generate(ticket)` or `Joined(ticket)`;
  the owner runs the provider and calls `complete`; a cancelled waiter calls `leave`; joined callers read `take_outcome`.
  Supersede, staleness, coalescing and last-waiter cancel work as in Swift (cancel = an `AtomicBool` on the ticket).
  The Swift test seam `beforeMove` is gone: with no interleaving, "a supersede between check and move" is "a supersede before
  `complete`", covered by `supersede_after_generation_leaves_no_orphan`.
- `LibraryPreviewPlayer` (@Observable, portable stand-in): struct with `version()`; the app's real player replaces it.
- `PresetMetaTable`, `Favorites`, `MediaFileStampTracker`: value types as in Swift.

## Deviations and shortcuts
- `LibraryStoreError` has an extra `Io(String)` case (Swift throws the system error). `PresetFileError::Store(..)` wraps store errors
  because Swift's `PresetFile.decode` throws either kind.
- `WatchedFolder.url` is a `PathBuf` read and written as a `file://` URL string (percent-encoded; no trailing slash on write,
  one is accepted on read). `LibraryEntry`, `ContentHash`, `PresetMeta` hold `Timestamp`, so they are `PartialEq` but not `Hash`.
- `FolderScanner::scan` has no cancellation hook (`shortcut` in code). Entries are sorted by byte order of the path.
- `library_search::fold` drops accents of Latin-1 letters and combining marks only (`shortcut`); `numeric_compare` is the
  `.numeric` option on folded text. `Finder`-style order (`localizedStandardCompare`) uses `sq_core_time::text::standard_compare`.
- `TitleTemplatePreset` keeps the template as a JSON value (`shortcut`): `TitleTemplate` itself is not in `sq-core-model` yet.
  Checks kept: `content.tracks` not empty, `formatVersion` of at most 5.
- A pack without a readable `createdAt` gets the epoch (Swift: `Date()`; no clock here).
- JSON files are written with sorted keys and Swift's `"key" : value` spacing (`json_file_io::pretty_sorted`); `/` is not escaped.
- Not ported: `PreviewCache.appCache()/configureCacheRoot/defaultCachesDirectory`, `PresetStore.defaultApplicationSupport`,
  `LUTLibrary.defaultDirectory` with the OS lookup (the app passes the folders; `default_directory` takes the base).
- Test helper `folder_scanner::test_dir::TempDir` (cfg(test)) serves all modules, because `lib.rs` is not ours to extend.

## Waiting on
- Swift tests that need other crates' model code and are left out: `PresetFileTests` transition round trip (needs a
  `TransitionPreset` constructor), `transformStagePresetSurvivesFileApplyBakeAndReopen` (needs `Clip.applyPreset`,
  `convertToKeyframes`, `reopenAsEffect`), `TitleBlockTests` insert step (`Timeline.placeBlock`, `addElementTransitions`),
  `TitleTemplate*Tests` with a typed template and `TemplateSlot.graphicsLayer`, `EffectDefaultsFileTests` transitions part.
- Tests of Apple-only files: `FSEventsWatcherTests`, `MediaPreviewProviderTests`, the AVFoundation parts of `LibraryPreviewPlayerTests`,
  `PreviewCacheRootTests` (global cache root, app level).
