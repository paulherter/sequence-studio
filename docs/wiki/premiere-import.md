---
title: Importing Premiere Projects
chapter: media
order: 2
code: crates/sq-premiere-import, crates/sq-prproj-reader, crates/sq-draw-shell/src/shell_import.rs, crates/sq-draw-shell/src/shell_interchange.rs, crates/sq-draw-shell/src/library_imports.rs, crates/sq-draw-shell/src/shell_import_report_content.rs
---

## For users

Open a Premiere Pro project (.prproj) or its effect presets in Sequence Studio, and see what came over.

Premiere import is experimental. It covers a subset of the features, and the import report tells you what was left out.

### Import a project

1. Choose File > Import Premiere Project….
2. Pick the .prproj file.
3. When it finishes, a report appears. Read it, then click Done.

You can open the report again later with File > Project > Import Checklist…. This menu item is only on after a Premiere import.

### What works

| Premiere | In Sequence Studio |
|---|---|
| Folders, media, sequences, tracks and cuts | Yes |
| Nested sequences | Yes |
| Speed changes (also reverse) | Yes |
| Freeze frames, time remapping | Only from XML, EDL and OTIO files, not from the .prproj |
| Position, scale, rotation and opacity, with keyframes | Partly |
| Basic color corrections (temperature, tint, exposure, contrast, saturation and more) | Partly |
| Cross dissolves and fades | Yes |
| Text and graphics clips | Partly |
| Audio gain, track volume, pan, mute | Yes |
| Noise Reduction, Multiband Compressor, Parametric EQ | Yes |
| Markers | Yes |
| Offline media | Kept, so you can reconnect it |

### What does not come over

Warp Stabilizer, 3D effects and Track Matte are not imported yet. Masks, some shapes and graphic groups are only approximated, and a Mirror that follows a scaled Transform is dropped (the import report says so). Adjustment layers, Mosaic and other Mirror effects do come over. Effects Sequence Studio does not have are left out.

### The import report

The report is a list of rows with a colored dot for each item. It tells you what came over as is, what was approximated, what was left out and what could not be found. Rows that can act have buttons:

- **Show** jumps to the affected clip. Click again for the next one.
- **Reconnect…** opens the dialog to find missing media.

Save Report… writes the list to a text file. If everything came over, the report says "Everything came over as is."

### Reconnect missing media

Premiere projects point to files by path. If the files moved, choose File > Project > Reconnect Media… and pick the folder that holds them.

### Import effect presets

1. Choose File > Import Premiere Presets….
2. Pick your Premiere presets file (Effect Presets and Custom Items.prfpset).
3. The presets appear in your preset list.

Presets that need an effect Sequence Studio does not have, and empty presets, are skipped, with the reason in the report. Some values are approximated when the preset was made for another frame size.

### Import a motion graphics template

See [Titles and Captions](text-and-subtitles.md).

### Import keyboard shortcuts

If you also want your Premiere keys, Window > Keyboard Shortcuts > Import Shortcuts… reads Premiere .kys files. See [Shortcuts](shortcuts.md).

### Not sure yet

- The complete list of Premiere effects that are supported.
- Whether the import menu items are present on Windows and Linux.
- Clip label colors do not come over: neither the .prproj nor the interchange import reads them.

Related: [Editing](timeline-and-editing.md), [Titles and Captions](text-and-subtitles.md), [Shortcuts](shortcuts.md), [Troubleshooting](troubleshooting.md)

## For developers

Two crates and a shell layer:

- `crates/sq-prproj-reader` is the container layer: `zip.rs`, `inflate.rs` (raw deflate and gzip, `MAX_PROJECT_SIZE` = 4 GiB output limit), `fastxml.rs` and `container.rs` (`Node`, `ObjectTable`, `ImportError` with `NotPremiereProject`, `CorruptArchive`, `Xml`). It has a `dump` binary (`src/bin/dump.rs`) that prints a deterministic text dump of what the container layer makes of a file.
- `crates/sq-premiere-import` turns the reader's tree into the project model. It depends on the model, effects, color, audio, text and project crates.
- `crates/sq-draw-shell` calls both: `shell_import.rs` (File > Import Premiere Project), `library_imports.rs` (presets and motion graphics templates), `shell_interchange.rs` (File > Import Timeline), `shell_import_report_content.rs` and `shell_relink.rs` (the report card and Reconnect Media).

Data flow of a .prproj import (`run_import_premiere_project` in `shell_import.rs`):

1. `PRReader::read(&bytes)` (`prdocument.rs`) inflates the gzip (or takes plain XML), builds an `ObjectTable` and returns a `PRDocument` with a `PRSequence` per Sequence object: tracks, items (`PRSource::Media`, `Sequence`, and others), transitions, markers and components with `PRParamValue` keyframes.
2. `PRMapper::media_paths` lists the media files, `PRMapper::resolve_media` finds them on this machine through `MediaPathResolver` (as stored, relative path, same name in the project folder tree and its parent, then earlier search folders). File I/O: call it off the main thread.
3. The shell probes the media; paths without a probed `MediaRef` get a placeholder (offline until reconnected).
4. `PRMapper::map(doc, name, media, shapes, ids)` returns a `PRImportResult { project, report }`. It maps only to features the model has; everything else is a row in the `PRImportReport` with a `Status` (`Mapped`, `Approximated`, `Dropped`). Submodules: `prmapper/audio.rs`, `effects.rs`, `lumetri.rs`, `shapes.rs`, `text.rs`. The active sequence is the longest one that no other sequence nests.
5. `PRImportChecklist::new(&report, &project)` (`primport_checklist.rs`) builds the rows the card shows (`Kind`: `CameOver`, `Approximated`, `LeftOut`, `MissingFiles`); rows with locations let Show jump to clips.

Other importers in the same crate:

- Interchange files: `interchange_model.rs` (`IXSequence`, `InterchangeFormat::detect` by content first, then extension, `read`, `read_all`, `map`) with `edlreader.rs`, `xmemlreader.rs` (Final Cut Pro 7 XML), `fcpxmlreader.rs` and `otioreader.rs`. They produce the same `PRImportResult`.
- Presets: `prpreset.rs` (`PRPresetReader::read`, `PRPresetMapper::map`).
- Motion graphics templates: `mogrt.rs` (`MogrtImporter::open`, `read`), text blobs in `prtext_blob.rs`.
- `primport_result_canonical.rs` writes a result as sorted-key JSON with ids replaced by first-appearance numbers, for differential tests.

Tests: `cargo test -p sq-premiere-import` (integration tests in `crates/sq-premiere-import/tests/`: `reader`, `mapper`, `mapper_effects`, `mapper_text`, `mogrt`, `presets`, `interchange`, `voice_chain`; `common/mod.rs` builds synthetic project XML, never a real project) and `cargo test -p sq-prproj-reader`. Extension points: a new Premiere feature is a mapping in `prmapper/` plus a report row (`report.note(feature, status, note)`); a new interchange format is a reader that returns `IXSequence` plus a case in `InterchangeFormat::detect`.

## For AI agents

- Entry points: `sq_premiere_import::prdocument::PRReader::read(&[u8]) -> Result<PRDocument, ImportError>`, `prmapper::PRMapper::map(&PRDocument, name, &BTreeMap<String, MediaRef>, shapes: bool, &mut dyn IdSource) -> PRImportResult`, `prpreset::PRPresetReader::read` then `PRPresetMapper::map`, `mogrt::MogrtImporter::read(data, file_name, ids)`, `interchange_model::InterchangeFormat::detect(data, extension)`.
- Output: `PRImportResult { project, report }`. Every feature that is not mapped as is must appear in the report with `Status::Approximated` or `Status::Dropped`; nothing is dropped silently.
- Ids are drawn from the `IdSource` passed in, so two maps of the same document differ in ids. Compare with `primport_result_canonical.rs`.
- Errors (`ImportError` display text): "This is not a Premiere Pro project file.", "The project file is damaged.", "The project file could not be read: ...".
- The source file is never modified; the result opens as a new untitled project.
- Unpack limit: 4 GiB inflated (`MAX_PROJECT_SIZE`, `crates/sq-prproj-reader/src/inflate.rs`).
- Do not read real .prproj files into the repository. Tests use `crates/sq-premiere-import/tests/common/mod.rs` and `tests/fixtures/presets.prfpset.gz`.
- Commands: `cargo test -p sq-premiere-import`, `cargo test -p sq-prproj-reader`, `cargo run -p sq-prproj-reader --bin dump -- <file>`.
- UI entry points: `choose_and_import_premiere_project` and `import_premiere_project` in `crates/sq-draw-shell/src/shell_import.rs`; presets and templates in `crates/sq-draw-shell/src/library_imports.rs` (`import_premiere_presets`, `import_mogrts`).
