# Pilot notes: Rust port of the prproj container layer

Scope: ZIP reader, gzip, raw inflate, fast XML, object table (fast path only; the XMLParser fallback is not ported, the
Rust side prints `XML nil` where Swift would fall back). Crate: `crates/sq-prproj-reader` (std only). Parity: `parity/run.sh`
(builds the Swift dumpers with plain Xcode swiftc via `parity/swift-dump/build.sh`, generates fixtures, diffs).

## Size
- Swift: PRZip 78 + PRFastXML 255 + PRInflate 10 + SQCore RawInflate 121 + PRContainer part (error, PRGzip, PRNode,
  object table) ~144 = about 608 lines.
- Rust: 766 lines without tests (container 111, fastxml ~270, inflate ~190, zip ~140); 1028 with unit tests and the 128-line
  dump CLI. Rust is about 1.25x longer (the Swift Apple Compression path is not counted, the portable one is).

## Parity (412 inputs)
- 0 unexplained diffs Rust vs Swift (portable inflate = SQCore RawInflate). Inputs: valid, gzip header flags, stored, truncated,
  corrupt (90 fuzzed gzip), gzip and zip bombs (limit, claimed sizes), UTF-16/BOM/other encodings, DOCTYPE, entity edge cases,
  Unicode whitespace, deep nesting (1000, 20000, 200000), 120 XML mutations, 60 ZIP mutations, 7 real projects (largest 10.5 MB inflated).
- Extra fuzz (`parity/fuzz.py 1500`): 0 crashes, 0 hangs, 0 Rust-vs-Swift diffs on either side.
- Known divergences (`parity/known-divergences.txt`):
  1. Swift `String ==` and `Dictionary` use Unicode canonical equivalence (e + U+0301 equals U+00E9): duplicate-attribute check,
     end-tag match and the ObjectID index differ for such names (3 fixtures). Needs a normalization table; real files do not hit it.
  2. 200000 nested elements: Swift crashes (stack overflow, SIGSEGV); Rust parses it (iterative drop). A latent crash in the original.
  3. Zip entry names over 1024 bytes: Rust rejects (the speed-test change below), Swift does not.
- Apple (Compression framework) vs portable Swift: 1 fixture (bit-flipped gzip) inflates on Apple but errors on the portable path;
  9 of 1500 fuzz cases differ. The Swift code already behaves differently on Mac and Windows; Rust matches the portable one.
- Foundation quirk found only by parity: `trimmingCharacters(.whitespacesAndNewlines)` also trims U+200B but not U+FEFF or U+180E.
  Ported as an explicit table (`fastxml.rs::is_ws`).

## Build and run numbers (M-series Mac, loaded, nice 15)
- cargo clean release build 2.9 s; debug build 1.3 s; incremental release (touch fastxml.rs) 1.1 s.
- Swift scratch dumpers (plain swiftc, 5 files, two variants) 19 s.
- Largest real file (1.39 MB gz, 10.5 MB XML, 11.6 MB dump output), mean of 8 runs incl. process start and printing:
  Rust 0.17 s, Swift portable 0.42 s, Swift Apple 0.38 s.

## Development speed, Swift vs Rust
| step | Rust | Swift (SQPremiereImport) |
|---|---|---|
| cold build + filtered test | 2.9 s release / 1.3 s debug | `scripts/test.sh` filter FastXML: 60 s (build 56, tests 4) |
| touch one file, rebuild + test | `cargo test` 0.75 s; `cargo check` 0.24 s | blank line in PRFastXML.swift: 3 s (build 2, tests 1) |
| micro change "zip name over 1024 bytes -> error" + test | 1 edit call, 1 test call, green first time, about 1.3 s | 1 edit call; 1 test call with a too broad filter that stalled 11 min (Mac loaded); 1 narrow call 7 s (build 4, tests 3) |
- The Swift incremental number is good once the module graph is built; cold is 60 s even for a small package, and the slots/stall
  rules add minutes under load. The Rust crate has no dependencies; one with dependencies has a longer cold build, same incremental.
- Where an agent loses time. Swift: build/test slots, stalls under load (twice 300 s = 11 min), filter mistakes, toolchain/SDK mismatch
  with plain swiftc (3 failed attempts). Rust: nothing measurable here (0 compile errors).

## Quality of result per effort
- First parity run: 5 diffs: 3 canonical-equivalence (language semantics), 1 Swift crash (deep nesting), 1 real port bug (U+200B).
  Caught by: compiler 0, parity run 5, review 0.
- Rust compile/borrow errors: 0 on the first `cargo build` (design decision up front: iterative `Drop` for Node). 3 failures were my own
  hand-written test vectors (ZIP header padding twice, wrong deflate bytes). Swift side: 3 build-setup errors (toolchain/SDK, missing import), 0 type errors.
- Latent issues in the Swift original: (a) stack overflow on 200000 nested elements; (b) Apple and portable inflate disagree on corrupt streams;
  (c) `Huffman.decode` reads `symbols[...]` unchecked (a trap if an oversubscribed table put it out of range; Rust returns an error instead);
  (d) canonical-equivalence duplicate keys. No hang and no other crash in about 1900 mutated inputs on either side.
- Verdict for this slice, with the agent as author: Rust gave the better result per effort. No compile iterations, the port was mechanical because the
  Swift was already byte-and-index code, bounds are checked by default, and the loop (cargo test under 1 s, no slots, no stalls) is far shorter
  than the SQ Swift package loop. Cost: about 25 percent more lines, no Foundation (whitespace table and canonical equality had to be reproduced or
  dropped), and the code lives in two languages until a C ABI bridges them. One parsing slice with no UI, concurrency or Apple frameworks: it says little about those.

## Next step (sketch only)
C ABI `cdylib`/`staticlib` with a handle API: `sqpr_open(bytes, len, limit, *out_handle) -> status` (ok / corruptArchive / notPremiere / xmlNil),
`sqpr_node_count`, `sqpr_node(handle, index, *name, *text, *attr_count, *first_child, *next_sibling)` returning UTF-8 slices valid until `sqpr_free`.
A flat index-based node array avoids per-node allocation across the boundary. Swift keeps `PRObjectTable`'s API, builds `PRNode` lazily from the
flat array, and keeps the `XMLParser` fallback for `xmlNil`. Windows uses the same library. Build via a script step like Vendor/sqgyro.

## Effort
About 20 min on the clock file plus an 11 min stalled Swift test run; about 35 tool calls.
