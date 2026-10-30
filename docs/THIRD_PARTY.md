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
| Apple scroll physics (UIScrollView rubber band `(1-1/(x*0.55/d+1))*d`, deceleration 0.998/ms) | published formulas | - | `ScrollBody` (SQDrawKit) implements the known formulas and a critically damped spring itself. No code borrowed. |
| [gyroflow](https://github.com/gyroflow/gyroflow) gyroflow_core 1.6.3 + gyroflow-plugins @32ae998 | GPL-3.0 (+ section-7 app-store permission) | Rust | Engine of the Stabilizer's Gyroflow method, see "Linked libraries" below. The plugin parameter names/ranges and the shim pattern (gyroflow-plugins `common/src/lib.rs`, the app's `src/rendering/mod.rs` `create_planes_proc!`) were followed. |
| [colour-science](https://github.com/colour-science/colour) | BSD-3-Clause | Python | Cross-check of the Canon Log / Canon Log 2 / Canon Log 3 constants only (`models/rgb/transfer_functions/canon.py`); the formulas come from Canon's white paper, no code copied. |

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
| CMX3600 EDL, Final Cut Pro 7 XML (xmeml), FCPXML and OpenTimelineIO (.otio JSON) file-format descriptions | Public format descriptions; OpenTimelineIO (Apache-2.0) schema names read for the field layout, no code ported | Own readers in `SQPremiereImport/Interchange/`, own writers in `SQExport` (`EDLWriter`, `FCPXMLWriter`, `XMEMLWriter`, `OTIOWriter`) | Timeline interchange. |
| [font-rs](https://github.com/raphlinus/font-rs) (Raph Levien), accumulation rasterizer (`src/raster.rs`) | Apache-2.0 or MIT | Algorithm followed, re-typed in Swift (signed-area accumulation buffer, running sum per row); no code copied | CPU glyph rasterizer of the portable UI, `Packages/SQText/Sources/SQText/GlyphRaster.swift` (Windows app atlas). |
| SMPTE ST 377-1 (MXF), ST 379/381/382 (generic container, picture and sound mappings), RP 224 labels, ITU-T H.264 | Public specifications; FFmpeg `mxfdec.c` read for understanding only, no code ported | Own KLV/partition/index/metadata reader and H.264 Annex B reader in `MXF/` | MXF import (Sony XAVC). |

## Linked libraries
Built from source by `scripts/build-gyro.sh` (Rust crate `Vendor/sqgyro`, every version pinned by `Vendor/sqgyro/Cargo.lock`) into `libsqgyro.dylib`, which the app loads at runtime from `Contents/Frameworks` (build output, never committed). README credits Gyroflow.

| Library | Pinned | License | Use |
|---|---|---|---|
| [gyroflow_core](https://github.com/gyroflow/gyroflow) (`src/core`, with the bundled `lens_profiles`) | rev 5fa0309a (bumped 2026-10-17 from d918ab3; LICENSE at the pin read: GPL-3.0; gyroflow-plugins itself pins f681124); default features off + `bundle-lens-profiles` (no OpenCL) | GPL-3.0 (LICENSE read); lens profiles: see "Lens profiles" below (CC0-1.0 per upstream repo) | Gyro parsing, smoothing, adaptive zoom, rolling shutter, horizon lock, lens undistortion (wgpu on Metal). |
| `sqgyro` C shim (own code, `Vendor/sqgyro`) | — | GPL-3.0-or-later | C API: open, set params, recompute, warp one plane, motion metric. |
| [telemetry-parser](https://github.com/AdrianEddy/telemetry-parser) | rev d45ebf2 | MIT OR Apache-2.0 (LICENSE-MIT / LICENSE-APACHE read) | Camera metadata (Sony rtmd, GoPro GPMF, DJI, Insta360, .gcsv). |
| [rs-sync](https://github.com/gyroflow/rs-sync) | rev fc5cf51 | LGPL-2.1 (LICENSE read; GPL-3 compatible) | Linked by gyroflow_core (optical-flow sync; not called by us). |
| [mp4parse-rust](https://github.com/AdrianEddy/mp4parse-rust) fork, `median` | ff910c6 / 0.3.2 | MPL-2.0 (GPL-3 compatible, file-level copyleft; sources unmodified) | MP4 parsing in telemetry-parser. |
| wgpu, naga, nalgebra, parking_lot and ~300 crates.io crates | Cargo.lock | MIT / Apache-2.0 / BSD / Zlib / ISC / Unlicense / Unicode-3.0 / CDLA-Permissive-2.0 (all 320 checked with `cargo metadata`, 2026-10-05) | GPU warp and support code. |
| app_dirs2, rust-cv (`cv`), fc-blackbox (forks pinned by Cargo.lock) | Cargo.lock | MIT / MIT OR Apache-2.0 (license files read) | Support code of gyroflow_core. |
| [GyroflowToolbox](https://github.com/latenitefilms/GyroflowToolbox) | read only | MIT | Reference for a C-ABI shim around gyroflow_core in a macOS host. |
| [FFmpeg](https://ffmpeg.org) (Windows build only, `Packages/SQMediaFFmpeg`) | BtbN `ffmpeg-master-latest-win64-lgpl-shared` on the build PC (`SQ_FFMPEG`; not in the repo) | LGPL-2.1-or-later shared build (no GPL or nonfree parts; GPL-3 compatible); dynamically linked, DLLs ship next to the exe | Windows demux, decode (D3D11VA), audio decode/resample, H.264/HEVC encode (AMF / NVENC / Quick Sync / Media Foundation, OpenH264 if present), AAC, MP4 mux. Own C++ shim `CSQFFmpeg` (GPL-3.0-or-later). |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (Windows build only, `Packages/SQOnnx`) | 1.24.4, `onnxruntime.dll` + `onnxruntime_providers_shared.dll` from the Microsoft.ML.OnnxRuntime.DirectML nuget (not in the repo; `scripts/win-onnx-setup.sh`); the C API header is vendored in `Packages/SQOnnx/Sources/CSQOnnx/include/ort` | MIT (LICENSE read; copy in `Packages/SQOnnx/ORT-LICENSE-MIT.txt`) | EdgeTAM Magic Mask on Windows, loaded at run time with LoadLibrary. The DirectML execution provider uses `DirectML.dll` from the Windows system folder (a system component, not shipped). |

## Lens profiles (Gyroflow)
With the feature `bundle-lens-profiles`, `gyroflow_core`'s `build.rs` (rev 5fa0309a, line 10) downloads
`https://github.com/gyroflow/lens_profiles/releases/latest/download/profiles.cbor.gz` at build time and
embeds it in `libsqgyro.dylib`. Finding (checked 2026-10-07 via the GitHub repository page): the
`gyroflow/lens_profiles` repository carries a `LICENSE` file and is declared CC0-1.0 (Creative Commons Zero).
Caveats: the repository has no README statement about the origin of the individual profiles, so we rely on
the repository-level CC0 declaration only. `scripts/build-gyro.sh` pre-places release `v41` (LENS_PROFILES_TAG) so the embedded
set is pinned and reproducible; bump it on purpose. Treat per-profile provenance as unverified.

## EdgeTAM (subject mask tracking model)
**EdgeTAM** (subject mask tracking model: weights converted to Core ML, model structure re-expressed for conversion).
Source: https://github.com/facebookresearch/EdgeTAM, commit 7711e012a30a2402c4eaab637bdb00a521302c91, checkpoint
`checkpoints/edgetam.pt`. Copyright (c) Meta Platforms, Inc. and affiliates. Licensed under the Apache License,
Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0). Changes by Sequence Studio: the network was split into
five fixed-shape parts (image encoder, mask decoder for a click, mask decoder for a box with a click, memory encoder,
memory attention), the rotary position encoding and
the prompt embedding were rewritten without complex numbers and boolean indexing, and the weights were converted to
16-bit Core ML models. EdgeTAM builds on SAM 2 (Apache-2.0, Meta) and uses a RepViT-M1 image trunk whose weights are
part of the checkpoint.

RepViT (https://github.com/THU-MIG/RepViT, Copyright THU-MIG): `LICENSE` checked 2026-10-09, Apache License 2.0,
compatible with GPL-3.0. The export uses timm's RepViT code (Apache-2.0).

Apache-2.0 section 4: the app that carries the models must also carry the Apache-2.0 license text and this statement
of changes (next to the models in `Contents/Resources/SubjectMask/`). The EdgeTAM repository has no `NOTICE` file of
its own (checked at the commit above). The models are not in this repository; no code of EdgeTAM is: the Swift
tracker (`Packages/SQAnalysis/Sources/SQAnalysis/EdgeTAM.swift`) is written against the converted parts' inputs and
outputs.

EdgeTAM on Windows: the same five parts are exported to FP32 ONNX files by `Tools/SubjectMaskSpike/python/export_onnx.py` (same Apache-2.0 statement of changes as above, plus: exported with torch.onnx, inputs and outputs carry the Core ML parts' names). The files stay out of the repo; `scripts/win-onnx-setup.sh` makes and pushes them.

## GPL source offer
Sequence Studio is GPL-3.0-or-later. Every binary release (DMG) must link the exact source tag it was built
from (the GitHub Release notes name the tag and commit), so the corresponding source is available to anyone
who received the binary. The Rust dependencies are fully reproducible from `Vendor/sqgyro/Cargo.lock` plus the
gyroflow rev `5fa0309a`, with the one exception of the lens-profile download above. Anyone may rebuild with
`scripts/build-gyro.sh`.

## Lucide icons (SQUIKit/Resources/Icons)

- Lucide, lucide-static 1.55.0, ISC licence, https://github.com/lucide-icons/lucide. Only the SVGs in use are bundled,
  loaded solely by `SQIcon` (SQUIKit), rendered as template images.
- Our own drawings (own work, same 24x24 stroke grid): toolSlip, toolSlide, toolRipple, toolRoll, toolRateStretch,
  keyframe, pageEdit, pageColor, markIn, markOut, markInOut, textOverline.

## Beat tracking (SQAnalysis/BeatDetector.swift)

- Own code: spectral flux, autocorrelation tempo and the dynamic-programming beat tracker after D. Ellis, "Beat Tracking by
  Dynamic Programming" (2007); no code copied.
- Model candidate, not shipped: "Beat This!" (CPJKU/beat_this, ISMIR 2024), README checked 2026-10-13: code and published
  weights MIT (compatible with GPL-3.0; some training data has other licences, which does not affect the weights' terms
  as published). Needs a PyTorch to Core ML conversion first. madmom models are CC BY-NC-SA: not usable.

- Apple lzfse (github.com/lzfse/lzfse, BSD-3-Clause, GPL-3.0 compatible): decoder sources vendored unmodified in
  `Packages/SQAnalysis/Sources/CLZFSE` (licence file beside them) so Windows reads Mac Magic Mask caches (`.sqmatte` LZFSE frames).
  Checked 2026-10-29 against Mac-written fixtures in LZFSETests.

## Speech on Windows (SQTranscribe, CSQWhisper)

- whisper.cpp (github.com/ggml-org/whisper.cpp, MIT, GPL-3.0 compatible; ggml inside it is MIT too), release b5454 (commit
  d1be6fde, 2026-10-06). Not vendored as source and not linked: `whisper.dll` and `ggml*.dll` come from the project's own
  Windows release zip (`scripts/win-whisper-setup.sh`) and are loaded at run time by `Packages/SQTranscribe/Sources/CSQWhisper`
  (same pattern as ONNX Runtime). That C file copies the struct layouts of `whisper_context_params` and `whisper_full_params`
  from the pinned `whisper.h` (needed because both are passed by value); the DLL must come from the same release.
- Models: OpenAI Whisper weights in whisper.cpp's ggml format, `ggml-small-q5_1.bin` (MIT, OpenAI), downloaded on first use from
  huggingface.co/ggerganov/whisper.cpp into `%LOCALAPPDATA%\SequenceStudio\Whisper`. Never in the repo.

## Slang (shader language and compiler)

- Slang (github.com/shader-slang/slang, Apache-2.0, GPL-3.0 compatible), release 2026.20. Used as a build tool only: `scripts/slang-compile.sh` and the shader scripts compile `Packages/SQGPU/Shaders/*.slang` to MSL and HLSL. The compiler is not in the repo and not linked; only the generated shader code and our own `.slang` sources ship.
