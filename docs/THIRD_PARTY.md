# Third-party code and references

Sequence Studio will be GPL-3.0. Code from GPL-3.0, MIT, BSD and Apache-2.0 projects may be reused
after reading and checking it. Every reuse gets a line below: what, from where (commit/file), license.

## References
| Project | License | Language | Use |
|---|---|---|---|
| [palmier-pro](https://github.com/palmier-io/palmier-pro) | GPL-3.0 | Swift | Main UI/architecture reference (Premiere-like). Code reuse allowed with attribution. |
| [openshot-qt](https://github.com/OpenShot/openshot-qt) | GPL-3.0 (GitHub shows NOASSERTION, repo is GPL-3) | Python/Qt (+ libopenshot C++) | Concepts only (keyframe/clip model); little direct reuse. |
| [openreel-video](https://github.com/Augani/openreel-video) | MIT | TypeScript (browser) | Concepts only (timeline interactions, caption styling). |
| [nexrender-action-mogrt-template](https://github.com/vonstring/nexrender-action-mogrt-template) | ISC | JavaScript | Format reference only: its two test templates (.mogrt) were inspected to verify the package layout (docs/ENGINE-NOTES.md "Motion Graphics Templates"). No code copied, the files are not in the repo. |
| [gyroflow](https://github.com/gyroflow/gyroflow) gyroflow_core 1.6.3 + gyroflow-plugins @32ae998 | GPL-3.0 (+ section-7 app-store permission) | Rust | Engine of the Stabilizer's Gyroflow method, see "Linked libraries" below. The plugin parameter names/ranges and the shim pattern (gyroflow-plugins `common/src/lib.rs`, the app's `src/rendering/mod.rs` `create_planes_proc!`) were followed. |

## Reused code
| Source | License | Form | Use |
|---|---|---|---|
| Inter 4.x variable fonts (rsms/inter, https://github.com/rsms/inter; files `Inter-VariableFont_opsz,wght.ttf` and `Inter-Italic-VariableFont_opsz,wght.ttf`, unmodified) | SIL Open Font License 1.1 (Copyright 2020 The Inter Project Authors; licence text kept next to the fonts in `Packages/SQText/Sources/SQText/Resources/Fonts/OFL.txt`) | Font files bundled as SPM resources of SQText, registered for the running process only (`InterFont.register()`, CTFontManagerRegisterFontsForURL `.process`); not renamed, not sold on their own | Default font of new text and captions (`TextStyle.defaultFontName`). |
| Bundled creator fonts (25 families from google/fonts `ofl/`, unmodified TTFs: Bebas Neue, Anton, Oswald, Archivo Black, League Spartan, Passion One, Russo One, Montserrat, Poppins [Medium/Bold/ExtraBold], Rubik, Space Grotesk, Outfit, Fredoka, Lilita One, Righteous, Playfair Display, DM Serif Display, Pacifico, Lobster, Caveat, Knewave, Bangers, Bungee, Bowlby One, Sigmar One) | SIL Open Font License 1.1, each family's own copyright line and `OFL.txt` kept next to the files in `Packages/SQText/Sources/SQText/Resources/Fonts/Families/<folder>/`. Reserved Font Names (Bowlby, Lilita, Lobster, Knewave, Passion, Playfair Display, Righteous, Russo, 'Source' for DM Serif Display) are respected: files not modified, not renamed | SPM resources of SQText, registered for the process only (`BundledFonts.register()`); not sold on their own | Fonts for titles and captions in the font picker ("Included"). Checked per file by `BundledFontsTests`. |
| RNNoise 0.1.1 (xiph/rnnoise, tarball v0.1.1) | BSD-3-Clause (Xiph.Org, Mozilla; license kept in `Packages/SQAudioFX/Sources/CRNNoise/COPYING`) | C, vendored; one addition: `rnnoise_reset()` in denoise.c + rnnoise.h (in-place state reset for seeks, no allocation). No `rnn_reader.c`, no training code | Noise suppression in SQAudioFX. |
| [ThorVG](https://github.com/thorvg/thorvg) v1.1.2 (tag, b004a77) | MIT (LICENSE read; copy in `Packages/SQLottie/THORVG-LICENSE`) | C++, vendored unmodified in `Packages/SQLottie/Sources/CThorVG` (src/common, src/renderer incl. cpu_engine, loaders lottie/raw/png/jpg, inc/thorvg.h) plus own `config.h` and C shim `sqlottie.cpp`. Not vendored: svg/webp/sfnt/media loaders, gpu engines, savers, jerryscript (expressions). | Lottie rendering for Lottie clips (software, single-threaded). |
| RapidJSON (inside ThorVG `loaders/lottie/rapidjson`) | MIT (copy in `Packages/SQLottie/RAPIDJSON-LICENSE`); `msinttypes` headers BSD-3-Clause | C++ headers, vendored with ThorVG | JSON parsing in the Lottie loader. |
| LodePNG (inside ThorVG `loaders/png`, Copyright Lode Vandevenne) | zlib | C++, vendored with ThorVG | PNG images embedded in Lottie files. |
| jpgd (inside ThorVG `loaders/jpg`, Rich Geldreich) | Public Domain (ThorVG uses it under those terms; also offered under Apache-2.0) | C++, vendored with ThorVG | JPEG images embedded in Lottie files. |
| Robert Penner's easing equations (via the widely published formulas) | BSD-3-Clause | Formulas re-typed in Swift, normalised so expo/elastic land exactly on 1 | Motion effect curve families in SQCore `MotionEasing.swift` (FB-T3). |
| Vorbis I specification (xiph.org, public specification text) | Freely implementable spec (BSD-style spec licence) | Own Swift decoder written from the spec in `Packages/SQMedia/Sources/SQMedia/WebM/VorbisDecoder.swift` (no libvorbis code; libvorbis was used on the dev Mac only to validate output, not shipped) | WebM audio. |
| Matroska / WebM and VP9 bitstream specs, RFC 6716 (Opus TOC) | Public specifications | Own EBML parser, VP9 key-frame header reader and Opus packet-length reader in `WebM/` | WebM import. |

## Linked libraries
Built from source by `scripts/build-gyro.sh` (Rust crate `Vendor/sqgyro`, every version pinned by `Vendor/sqgyro/Cargo.lock`) into `libsqgyro.dylib`, which the app loads at runtime from `Contents/Frameworks` (build output, never committed). README credits Gyroflow.

| Library | Pinned | License | Use |
|---|---|---|---|
| [gyroflow_core](https://github.com/gyroflow/gyroflow) (`src/core`, with the bundled `lens_profiles`) | rev d918ab3 (the rev gyroflow-plugins @32ae998 uses); default features off + `bundle-lens-profiles` (no OpenCL) | GPL-3.0 (LICENSE read); lens profiles: see "Lens profiles" below (CC0-1.0 per upstream repo) | Gyro parsing, smoothing, adaptive zoom, rolling shutter, horizon lock, lens undistortion (wgpu on Metal). |
| `sqgyro` C shim (own code, `Vendor/sqgyro`) | — | GPL-3.0-or-later | C API: open, set params, recompute, warp one plane, motion metric. |
| [telemetry-parser](https://github.com/AdrianEddy/telemetry-parser) | rev d45ebf2 | MIT OR Apache-2.0 (LICENSE-MIT / LICENSE-APACHE read) | Camera metadata (Sony rtmd, GoPro GPMF, DJI, Insta360, .gcsv). |
| [rs-sync](https://github.com/gyroflow/rs-sync) | rev fc5cf51 | LGPL-2.1 (LICENSE read; GPL-3 compatible) | Linked by gyroflow_core (optical-flow sync; not called by us). |
| [mp4parse-rust](https://github.com/AdrianEddy/mp4parse-rust) fork, `median` | ff910c6 / 0.3.2 | MPL-2.0 (GPL-3 compatible, file-level copyleft; sources unmodified) | MP4 parsing in telemetry-parser. |
| wgpu, naga, nalgebra, parking_lot and ~300 crates.io crates | Cargo.lock | MIT / Apache-2.0 / BSD / Zlib / ISC / Unlicense / Unicode-3.0 / CDLA-Permissive-2.0 (all 320 checked with `cargo metadata`, 2026-10-05) | GPU warp and support code. |
| app_dirs2, rust-cv (`cv`), fc-blackbox (forks pinned by Cargo.lock) | Cargo.lock | MIT / MIT OR Apache-2.0 (license files read) | Support code of gyroflow_core. |
| [GyroflowToolbox](https://github.com/latenitefilms/GyroflowToolbox) | read only | MIT | Reference for a C-ABI shim around gyroflow_core in a macOS host. |

## Lens profiles (Gyroflow)
With the feature `bundle-lens-profiles`, `gyroflow_core`'s `build.rs` (rev d918ab3, line 10) downloads
`https://github.com/gyroflow/lens_profiles/releases/latest/download/profiles.cbor.gz` at build time and
embeds it in `libsqgyro.dylib`. Finding (checked 2026-10-07 via the GitHub repository page): the
`gyroflow/lens_profiles` repository carries a `LICENSE` file and is declared CC0-1.0 (Creative Commons Zero).
Caveats: the repository has no README statement about the origin of the individual profiles, so we rely on
the repository-level CC0 declaration only. The download is "latest", not pinned, so the embedded profile set
differs between builds. Treat per-profile provenance as unverified.

## GPL source offer
Sequence Studio is GPL-3.0-or-later. Every binary release (DMG) must link the exact source tag it was built
from (the GitHub Release notes name the tag and commit), so the corresponding source is available to anyone
who received the binary. The Rust dependencies are fully reproducible from `Vendor/sqgyro/Cargo.lock` plus the
gyroflow rev `d918ab3`, with the one exception of the lens-profile download above. Anyone may rebuild with
`scripts/build-gyro.sh`.
