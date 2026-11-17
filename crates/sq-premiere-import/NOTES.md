# sq-premiere-import notes (Etappe 2a, group g1)

Container reading (zip, inflate, fast XML, object table, `Node`) is `sq-prproj-reader`; `PRContainer.swift` is therefore only
`prcontainer.rs` here (`PRTicks`, `safe_int`, `NodeExt` for the `PRNode` lookups the reader's `Node` lacks, a lenient base64
decoder). `PRMapper.swift` is `prmapper.rs` plus `prmapper/{audio,effects,lumetri,shapes,text}.rs`.

## Done
All g1 files except the rows owned by `sq-prproj-reader`. Tests (105): 13 unit, 13 interchange, 15 reader, 35 mapper/checklist, 22 mapper effects, 7 presets. Ids come from an `IdSource` (`PRMapper::map(.., ids)`), never `Uuid::new_v4`.

## Waiting on
- sq-text: `Mapping::text_generator` (PRMapper.swift lines 640-700 plus `textSizeScale`, `textTrackingScale`, `shadowBlurScale`,
  `shadowSizeScale`, `weight`, `textCentreOffsetY`) needs `TextStyle`, `TextTemplate`, `TextGenerator.makeRef`, `TextLayout`;
  until they exist every Premiere text layer is skipped (marked `shortcut:` in `prmapper/text.rs`). Tests waiting for it:
  MapperTests text cases (textGraphicBecomesTextClip, twoLineText..., textBackground..., textShadow..., pointText...,
  multiText...), MogrtImportTests, MogrtShapeTests, and `FontResolver.withScopedCache` around `PRMapper::map`.
- `MogrtImporter::read` is ported (open, map, `TitleTemplate::capture` from sq-core-edit, slot names from controls). Tests with text layers
  (Swift MogrtImportTests text cases) wait for the Premiere text mapping above; tests/mogrt.rs holds the cases without text.
- sq-audiofx: VoiceChainImportTests and the voice-chain cases of PresetImportTests run the imported presets through the real clip
  chain.
- RealProjectTests need files outside the repo: skipped.

## Deviations and decisions
- XML interchange (FCP7 XML, FCPXML) uses the fast reader of `sq-prproj-reader` instead of Foundation `XMLParser`; a plain
  `<!DOCTYPE name>` is dropped first (the fast reader declines any DTD). Error text for malformed XML is "no root element" (Swift
  prints the parser's message).
- `MapperGolden` digests hash Foundation's `JSONEncoder` text (float format, key order); they cannot be compared with serde output.
  `canonical_json` / `canonical_digest` exist (sorted keys, ids renumbered by first appearance) for a Rust-side differential run.
- Swift `max(by:)` keeps the first of equal lengths for the active sequence; `max_by_key` would take the last: written by hand.
- Swift `Dictionary` iteration in `link` (mapper and interchange) is random; groups are built in first-seen order here.
- Int(Double) conversions that trap in Swift (`Int64(huge)` in OTIO rates) saturate in Rust.
- `Swift Set<UUID>` / `[UUID: Int]` use `BTreeMap<Id, ..>`.
