# Third-party code and references

Sequence Studio is GPL-3.0-or-later. Code from GPL-3.0, MIT, BSD and Apache-2.0 projects may be reused
after reading and checking it. Every reuse gets a line below: what, from where (commit/file), license.

## Rust tree: what ships in a release (2026-11-09)
- Every Rust crate in the binary, with version and license: [THIRD_PARTY-CRATES.md](THIRD_PARTY-CRATES.md), generated from `cargo metadata` by `scripts/gen-third-party-crates.py` (regenerate after any dependency change; exits non-zero on a license that is not GPL-3.0-or-later compatible).
- **FFmpeg** (shared libraries, not compiled in): an LGPL build only. The Windows build used is BtbN `ffmpeg-master-latest-win64-lgpl-shared` (configured `--enable-version3`, no `--enable-gpl`, no `--enable-nonfree`: LGPL-3.0-or-later); the Mac bundle takes the folder in `SQ_FFMPEG` (Homebrew's build is GPL and is refused). `cargo xtask package` and `build-installer.ps1` read libavcodec's configure line and stop on `--enable-gpl` / `--enable-nonfree`. Shipped with every package: `Licenses/FFMPEG-LICENSE.txt` (the build's license text) and `Licenses/FFMPEG-NOTICE.txt` (dynamic linking, how to replace the libraries, where the source is) from `packaging/licenses/`.
- **ONNX Runtime 1.24.4** (MIT, `ORT-LICENSE-MIT.txt`), loaded at run time; **EdgeTAM and OPUS-MT models** (see the sections below), downloaded or bundled as files, never in the repo; **fonts** (OFL, listed below); **whisper.cpp** (MIT) on Windows.
- Terms of the project itself: GPL-3.0-or-later (`LICENSE`) with the section 7 additional terms (`LICENSE-ADDITIONAL-TERMS.md`). Both files are copied into the Mac bundle's `Contents/Resources` and next to `SequenceStudio.exe` (also in the installer).
- The tables below started as the Swift-era list. Rows that name `Packages/` or Swift files describe the frozen Swift app; where the Rust app ships the same thing from another place, the row says so. ThorVG and its bundled libraries are in the Swift app only: the Rust app draws Lottie with `crates/sq-lottie` (tiny-skia, BSD-3-Clause; `png` and `zune-jpeg` for embedded images), all listed in `THIRD_PARTY-CRATES.md`.

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
| Inter 4.x variable fonts (rsms/inter, https://github.com/rsms/inter; files `Inter-VariableFont_opsz,wght.ttf` and `Inter-Italic-VariableFont_opsz,wght.ttf`, unmodified) | SIL Open Font License 1.1 (Copyright 2020 The Inter Project Authors; licence text kept next to the fonts in `Packages/SQText/Sources/SQText/Resources/Fonts/OFL.txt`) | Font files kept in `Packages/SQText/Sources/SQText/Resources/Fonts` and read by `crates/sq-text`; the Mac bundle, the Windows installer and the Linux AppImage copy them with their `OFL.txt`; not renamed, not sold on their own | Default font of new text and captions (`TextStyle.defaultFontName`). |
| Bundled creator fonts (25 families from google/fonts `ofl/`, unmodified TTFs: Bebas Neue, Anton, Oswald, Archivo Black, League Spartan, Passion One, Russo One, Montserrat, Poppins [Medium/Bold/ExtraBold], Rubik, Space Grotesk, Outfit, Fredoka, Lilita One, Righteous, Playfair Display, DM Serif Display, Pacifico, Lobster, Caveat, Knewave, Bangers, Bungee, Bowlby One, Sigmar One) | SIL Open Font License 1.1, each family's own copyright line and `OFL.txt` kept next to the files in `Packages/SQText/Sources/SQText/Resources/Fonts/Families/<folder>/`. Reserved Font Names (Bowlby, Lilita, Lobster, Knewave, Passion, Playfair Display, Righteous, Russo, 'Source' for DM Serif Display) are respected: files not modified, not renamed | Copied by the packagers with each family's `OFL.txt` (`crates/xtask`, `crates/sq-text/src/bundled_fonts.rs`), registered for the running process only; not sold on their own | Fonts for titles and captions in the font picker ("Included"). Checked per file by `BundledFontsTests`. |
| RNNoise 0.1.1 (xiph/rnnoise, tarball v0.1.1) | BSD-3-Clause (Xiph.Org, Mozilla; license kept in `crates/sq-audiofx/vendor/rnnoise/COPYING`) | C, vendored; one addition: `rnnoise_reset()` in denoise.c + rnnoise.h (in-place state reset for seeks, no allocation). No `rnn_reader.c`, no training code | Noise suppression (`crates/sq-audiofx`). |
| [ThorVG](https://github.com/thorvg/thorvg) v1.1.2 (tag, b004a77) | MIT (LICENSE read; copy in `Packages/SQLottie/THORVG-LICENSE`) | C++, vendored unmodified in `Packages/SQLottie/Sources/CThorVG` (src/common, src/renderer incl. cpu_engine, loaders lottie/raw/png/jpg, inc/thorvg.h) plus own `config.h` and C shim `sqlottie.cpp`. Not vendored: svg/webp/sfnt/media loaders, gpu engines, savers, jerryscript (expressions). | Lottie rendering for Lottie clips (software, single-threaded). Swift app only; the Rust app does not ship it. |
| RapidJSON (inside ThorVG `loaders/lottie/rapidjson`) | MIT (copy in `Packages/SQLottie/RAPIDJSON-LICENSE`); `msinttypes` headers BSD-3-Clause | C++ headers, vendored with ThorVG | JSON parsing in the Lottie loader. Swift app only; the Rust app does not ship it. |
| LodePNG (inside ThorVG `loaders/png`, Copyright Lode Vandevenne) | zlib | C++, vendored with ThorVG | PNG images embedded in Lottie files. Swift app only; the Rust app does not ship it. |
| jpgd (inside ThorVG `loaders/jpg`, Rich Geldreich) | Public Domain (ThorVG uses it under those terms; also offered under Apache-2.0) | C++, vendored with ThorVG | JPEG images embedded in Lottie files. Swift app only; the Rust app does not ship it. |
| Robert Penner's easing equations (via the widely published formulas) | BSD-3-Clause | Formulas re-typed in Swift, normalised so expo/elastic land exactly on 1 | Motion effect curve families in SQCore `MotionEasing.swift` (FB-T3). |
| Vorbis I specification (xiph.org, public specification text) | Freely implementable spec (BSD-style spec licence) | Own Swift decoder written from the spec in `Packages/SQMedia/Sources/SQMedia/WebM/VorbisDecoder.swift` (no libvorbis code; libvorbis was used on the dev Mac only to validate output, not shipped) | WebM audio. |
| Matroska / WebM and VP9 bitstream specs, RFC 6716 (Opus TOC) | Public specifications | Own EBML parser, VP9 key-frame header reader and Opus packet-length reader in `WebM/` | WebM import. |
| CMX3600 EDL, Final Cut Pro 7 XML (xmeml), FCPXML and OpenTimelineIO (.otio JSON) file-format descriptions | Public format descriptions; OpenTimelineIO (Apache-2.0) schema names read for the field layout, no code ported | Own readers in `SQPremiereImport/Interchange/`, own writers in `SQExport` (`EDLWriter`, `FCPXMLWriter`, `XMEMLWriter`, `OTIOWriter`) | Timeline interchange. |
| [font-rs](https://github.com/raphlinus/font-rs) (Raph Levien), accumulation rasterizer (`src/raster.rs`) | Apache-2.0 or MIT | Algorithm followed, re-typed in Swift (signed-area accumulation buffer, running sum per row); no code copied | CPU glyph rasterizer of the portable UI, `Packages/SQText/Sources/SQText/GlyphRaster.swift` (Windows app atlas). |
| SMPTE ST 377-1 (MXF), ST 379/381/382 (generic container, picture and sound mappings), RP 224 labels, ITU-T H.264 | Public specifications; FFmpeg `mxfdec.c` read for understanding only, no code ported | Own KLV/partition/index/metadata reader and H.264 Annex B reader in `MXF/` | MXF import (Sony XAVC). |

## Linked libraries
In the Rust app, `crates/sq-gyroflow` depends on `gyroflow-core` as a Cargo git dependency (rev 5fa0309a, feature `bundle-lens-profiles`, no OpenCL), pinned by `Cargo.lock` and allowed in `deny.toml`. The rows below also describe the Swift app's `libsqgyro.dylib` (`scripts/build-gyro.sh`, `Vendor/sqgyro`, frozen); the Rust app takes the same Gyroflow revision. README credits Gyroflow.

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
| [FFmpeg](https://ffmpeg.org) (Windows build, `crates/sq-media-ffmpeg`) | BtbN `ffmpeg-master-latest-win64-lgpl-shared` on the build PC (`SQ_FFMPEG`; not in the repo) | LGPL-2.1-or-later shared build (no GPL or nonfree parts; GPL-3 compatible); dynamically linked, DLLs ship next to the exe | Windows demux, decode (D3D11VA), audio decode/resample, H.264/HEVC encode (AMF / NVENC / Quick Sync / Media Foundation, OpenH264 if present), AAC, MP4 mux. Own C++ shim `CSQFFmpeg` (GPL-3.0-or-later). |
| [FFmpeg](https://ffmpeg.org) (Mac release, `scripts/build-ffmpeg-lgpl-mac.sh`) | commit ceb466cbcd (same as the Windows BtbN build), built to `SQ_FFMPEG`; not in the repo | LGPL-3.0-or-later shared build (`--enable-version3`, no GPL or nonfree); dynamically linked into `Contents/Frameworks` | Mac demux/decode (VideoToolbox), H.264/HEVC/ProRes encode (VideoToolbox), AAC (AudioToolbox). Linked codec libs: dav1d (BSD-2-Clause), Opus (BSD-3-Clause), LAME libmp3lame (LGPL-2.0-or-later), libvpx (BSD-3-Clause), SVT-AV1 (BSD-2-Clause-Patent). Not used: x264, x265, fdk-aac. |
| [FFmpeg](https://ffmpeg.org) (Linux AppImage, `crates/xtask/src/package_linux.rs`) | BtbN `ffmpeg-n9.0.2-48-gd4070a14ce-linux64-lgpl-shared-9.0` (release autobuild-2026-11-10-12-39, sha256 6c212a1b914c84dc1e201fddeb9dea7304ef0748884722d4bb13311416c36ebb), fetched by `scripts/linux-deps.sh` into `SQ_DEPS` (`SQ_FFMPEG`); not in the repo | LGPL-3.0-or-later shared build (`--enable-version3`, no GPL or nonfree; checked with `ffmpeg -L` and the configure line); the 5 libs the app links go to `usr/lib`, replaceable | Linux demux/decode, encode through the system. The build also links libopenh264 (BSD-2-Clause), libkvazaar (BSD-3-Clause; the software HEVC encoder), libopencore-amr (Apache-2.0), dav1d, libvpx, SVT-AV1, Opus, LAME (LGPL-2.1), libvorbis, libaom, libwebp, libjxl and more (static inside the libs; none GPL; x264/x265/xvid are disabled). Source: github.com/FFmpeg-Builds/FFmpeg-Builds. |
| [appimagetool](https://github.com/AppImage/appimagetool) 1.9.1 (Linux AppImage, `crates/xtask/src/package_linux.rs`) | release asset `appimagetool-x86_64.AppImage`, sha256 ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0, fetched by `scripts/linux-deps.sh` into `SQ_DEPS` (`SQ_APPIMAGETOOL`); not in the repo | MIT (LICENSE file; dependencies keep their own); it embeds the AppImage type2 runtime (MIT), which is part of every AppImage it writes | Build tool only: packs the AppDir into `SequenceStudio-<version>-x86_64.AppImage`. |
| [ONNX Runtime](https://github.com/microsoft/onnxruntime) (`crates/sq-onnx`, Rust app on Mac, Windows and Linux) | 1.24.4, pinned and sha256-checked, downloaded into a cache folder only: macOS `libonnxruntime.dylib` (arm64) from the GitHub release `onnxruntime-osx-arm64-1.24.4.tgz` by `cargo xtask package` (cache `~/Library/Caches/SequenceStudio/onnxruntime`, ad-hoc signed into `Contents/Frameworks`); Linux `libonnxruntime.so` (x86_64, `onnxruntime-linux-x64-1.24.4.tgz`, cache `~/.cache/SequenceStudio/onnxruntime`, next to the exe in the AppImage; sha256 pinned in `crates/xtask/src/onnxruntime.rs`); Windows `onnxruntime.dll` + `onnxruntime_providers_shared.dll` from the Microsoft.ML.OnnxRuntime.DirectML nuget by `packaging/windows/build-installer.ps1` (next to the exe; `scripts/win-onnx-setup.sh` for the dev box). Not in the repo; the C API header is vendored in `crates/sq-onnx/vendor/ort` | MIT (LICENSE read; copy in `crates/sq-onnx/vendor/ORT-LICENSE-MIT.txt`, shipped as `ORT-LICENSE-MIT.txt` in the package) | EdgeTAM Magic Mask and the Stabilizer's ML parts, loaded at run time (LoadLibrary / dlopen). The DirectML execution provider uses `DirectML.dll` from the Windows system folder (a system component, not shipped); on the Mac the macOS build's Core ML provider (compiled in, opt-in via `SQ_ONNX_PROVIDER=coreml`, falls back to the CPU). The Windows package is the DirectML build (same version 1.24.4, same sha256 pin in `packaging/windows/build-installer.ps1`); the provider is picked in `crates/sq-onnx` (`SQ_ONNX_PROVIDER=cpu|directml|coreml|auto`). |

## Lens profiles (Gyroflow)
With the feature `bundle-lens-profiles`, `gyroflow_core`'s `build.rs` (rev 5fa0309a, line 10) downloads
`https://github.com/gyroflow/lens_profiles/releases/latest/download/profiles.cbor.gz` at build time and
embeds it in `libsqgyro.dylib`. Finding (checked 2026-10-07 via the GitHub repository page): the
`gyroflow/lens_profiles` repository carries a `LICENSE` file and is declared CC0-1.0 (Creative Commons Zero).
Caveats: the repository has no README statement about the origin of the individual profiles, so we rely on
the repository-level CC0 declaration only. `scripts/build-gyro.sh` pre-places release `v41` (LENS_PROFILES_TAG) so the embedded
set is pinned and reproducible; bump it on purpose. Treat per-profile provenance as unverified.

## EdgeTAM (subject mask tracking model)
The Rust app runs the five parts as FP32 ONNX files (`edgetam_*.onnx`) on ONNX Runtime. The Windows installer and the Linux AppImage carry the Apache-2.0 text as `Licenses/APACHE-2.0.txt`. The Core ML description below is the frozen Swift app's.

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

EdgeTAM on Windows: the installer (`packaging/windows/build-installer.ps1`) bundles the five parts in `<install folder>\SubjectMask`, sha256-pinned in the script, with the Apache-2.0 text as `Licenses\APACHE-2.0.txt` and this file in `Licenses\`. The same five parts are exported to FP32 ONNX files by `Tools/SubjectMaskSpike/python/export_onnx.py` (same Apache-2.0 statement of changes as above, plus: exported with torch.onnx, inputs and outputs carry the Core ML parts' names). The files stay out of the repo; `scripts/win-onnx-setup.sh` makes and pushes them.

## GPL source offer
Sequence Studio is GPL-3.0-or-later. Every binary release (Mac .dmg, Windows setup, Linux AppImage) must link the exact source tag it was built
from (the GitHub Release notes name the tag and commit), so the corresponding source is available to anyone
who received the binary. The Rust dependencies are pinned by `Cargo.lock` (Gyroflow at rev `5fa0309a`), with the one exception of the lens-profile download above. Anyone may rebuild with `cargo xtask package`.

## Phosphor icons (SQUIKit/Resources/Icons; Rust app: crates/sq-uikit/resources/Icons, embedded with include_str)

- Phosphor Icons (Regular and Fill weights), MIT licence, https://github.com/phosphor-icons/core. Only the SVGs in use are
  bundled (`ph-<name>[-fill].svg`, 256 grid, filled outlines), loaded solely by `SQIcon` (SQUIKit), rendered as template
  images. The Discord and GitHub logos are the brand marks below, not Phosphor. Lucide (ISC) was used before 2026-11 and is no longer bundled.
- Brand marks (`brand-github.svg`, `brand-discord.svg`, 24 grid): the GitHub Invertocat and the Discord Clyde mark from simple-icons (https://github.com/simple-icons/simple-icons, CC0-1.0). The marks are trademarks of GitHub Inc. and Discord Inc.; they appear only as links to those services (About, Start window, Help menu).
- Also Phosphor (Regular, MIT): `magnet`, the Fast Cut card on the Start window's Learn page (`ph-magnet.svg`).
- Our own drawings (`sq-<case>.svg`, own work, 24 grid, stroke 1.5 = Phosphor's 16/256): the cases marked `own` in the design
  kit's icon-map.json (tool and mark glyphs, text overline/direction, distribute, power, page icons and more).
- `scripts/gen-icons.mjs` regenerates the files and `SQIcon+Resources.swift` from the kit's icon-map.json.

## Beat tracking (SQAnalysis/BeatDetector.swift)

- Own code: spectral flux, autocorrelation tempo and the dynamic-programming beat tracker after D. Ellis, "Beat Tracking by
  Dynamic Programming" (2007); no code copied.
- Model candidate, not shipped: "Beat This!" (CPJKU/beat_this, ISMIR 2024), README checked 2026-10-13: code and published
  weights MIT (compatible with GPL-3.0; some training data has other licences, which does not affect the weights' terms
  as published). Needs a PyTorch to Core ML conversion first. madmom models are CC BY-NC-SA: not usable.

- Apple lzfse (github.com/lzfse/lzfse, BSD-3-Clause, GPL-3.0 compatible): decoder sources vendored unmodified in
  `crates/sq-analysis/vendor/lzfse` (licence file beside them; the Swift app had them in `Packages/SQAnalysis`) so Windows reads Mac Magic Mask caches (`.sqmatte` LZFSE frames).
  Checked 2026-10-29 against Mac-written fixtures in LZFSETests.

## Speech on Windows (SQTranscribe, CSQWhisper)

- whisper.cpp (github.com/ggml-org/whisper.cpp, MIT, GPL-3.0 compatible; ggml inside it is MIT too), release b5454 (commit
  d1be6fde, 2026-10-06). Not vendored as source and not linked: `whisper.dll` and `ggml*.dll` come from the project's own
  Windows release zip (`scripts/win-whisper-setup.sh`) and are loaded at run time by `Packages/SQTranscribe/Sources/CSQWhisper`
  (same pattern as ONNX Runtime). That C file copies the struct layouts of `whisper_context_params` and `whisper_full_params`
  from the pinned `whisper.h` (needed because both are passed by value); the DLL must come from the same release.
- Models: OpenAI Whisper weights in whisper.cpp's ggml format, `ggml-small-q5_1.bin` (MIT, OpenAI), downloaded on first use from
  huggingface.co/ggerganov/whisper.cpp into `%LOCALAPPDATA%\SequenceStudio\Whisper`. Never in the repo.

## Speech without whisper.dll, Reframe and Anonymize detectors on Windows/Linux (sq-transcribe, sq-analysis)

- Whisper ONNX exports `onnx-community/whisper-tiny|base|small_timestamped` on huggingface.co (OpenAI Whisper weights, Apache-2.0 on the Hub card;
  decoder returns cross-attentions for word timing; same file names plus `generation_config.json`; folder `onnx-aligned-<size>`; pinned in
  `onnx_whisper_pins.rs` `PINS`). Earlier pin, still used when it is already on disk (`LEGACY_PINS`): `Xenova/whisper-tiny|base|small` on huggingface.co (OpenAI Whisper weights, Apache-2.0 on the Hub card, MIT upstream):
  int8 `encoder_model_quantized.onnx`, `decoder_model_merged_quantized.onnx`, `tokenizer.json`, `config.json`. Downloaded on first use by
  `sq-transcribe` into `<Whisper folder>\onnx-<size>`, pinned by commit, size and SHA-256 (`crates/sq-transcribe/src/onnx_whisper_pins.rs`).
  Mel features, the BPE tokenizer and the decoding loop are our own code. Never in the repo.
- YuNet face detector `face_detection_yunet_2023mar.onnx` (MIT, Shiqi Yu, github.com/opencv/opencv_zoo, commit f12e127, 232 589 bytes) and
  YOLOX-Tiny `yolox_tiny.onnx` (Apache-2.0, Megvii, github.com/Megvii-BaseDetection/YOLOX release 0.1.1rc0, 20 219 662 bytes, person class only).
  Downloaded on first use by `sq-analysis::person_detector` into `%LOCALAPPDATA%\SequenceStudio\People`, pinned by size and SHA-256. Decoding,
  NMS and the spectral-residual saliency (Hou and Zhang 2007, a published algorithm) are our own code.

## Caption translation (sq-translate)

- OPUS-MT translation models by the Language Technology Research Group at the University of Helsinki (Helsinki-NLP, github.com/Helsinki-NLP/Opus-MT),
  licensed CC-BY-4.0 (attribution required: shown in the About window and here), in the ONNX exports `Xenova/opus-mt-*` on
  huggingface.co (int8 quantized `encoder_model_quantized.onnx` and `decoder_model_merged_quantized.onnx`, `source.spm`, `vocab.json`,
  `config.json`). Twelve directions: English to and from German, French, Spanish, Italian, Dutch, Portuguese (`en-ROMANCE` /
  `ROMANCE-en`). Downloaded on first use by `sq-translate` into `%LOCALAPPDATA%\SequenceStudio\Translation` (Mac:
  `~/Library/Application Support/SequenceStudio/Translation`), pinned by repo commit, size and SHA-256 (`crates/sq-translate/src/pins.rs`).
  Never in the repo. They run on the ONNX Runtime the app ships (see above). The SentencePiece reader and the Marian decoding are our own code (no library).

## Text to speech (sq-platform-tts)
- Mac: Apple's `AVSpeechSynthesizer` through the `objc2-avf-audio` and `objc2-foundation` bindings (MIT OR Apache-2.0 OR Zlib, already in the lock through cpal).
- Stabilizer Vision fallback (Mac): Apple's Vision framework through `objc2-vision` 0.3.2 (MIT OR Apache-2.0 OR Zlib, same objc2 family) in `sq-platform-vision`; the homography matrix (`simd_float3x3`, not in the generated bindings) is read with a short assembly call to `objc_msgSend`.
- Windows: the WinRT `SpeechSynthesizer` through the `windows` crate (MIT OR Apache-2.0).
- Linux: the `espeak-ng` program (GPL-3.0-or-later). It is started as a separate process, not linked and not shipped; without it the voice list is empty.

## Slang (shader language and compiler)

- Slang (github.com/shader-slang/slang, Apache-2.0, GPL-3.0 compatible), release 2026.20. Used as a build tool only: `scripts/slang-compile.sh` and the shader scripts compile `Packages/SQGPU/Shaders/*.slang` to MSL, DXIL and SPIR-V (Vulkan on Linux; the .spv files are checked in). The compiler is not in the repo and not linked; only the generated shader code and our own `.slang` sources ship.
| ttf-parser 0.25 (https://github.com/harfbuzz/ttf-parser) | MIT OR Apache-2.0 | Cargo dependency of sq-text, no code copied | Reads CFF (.otf) glyph outlines for installed fonts. |
| jpeg-encoder 0.7 (https://github.com/vstroebel/jpeg-encoder) | (MIT OR Apache-2.0) AND IJG (the IJG license is BSD-style and GPL-3.0 compatible) | Cargo dependency of sq-app-hosts, no code copied | JPEG writer of Export Frame (quality 95). |
| gyroflow-core 1.6.3 (https://github.com/gyroflow/gyroflow, rev 5fa0309a) | GPL-3.0 | Cargo git dependency of sq-gyroflow (same revision as Vendor/sqgyro), no code copied; `file.rs` follows the logic of Vendor/sqgyro | Gyro data, lens profiles, smoothing and the warp of the Gyroflow stabilizer. |
| gif 0.13 (https://github.com/image-rs/image-gif) | MIT OR Apache-2.0 | Cargo dependency of sq-media-ffmpeg, no code copied | GIF frame decoder of the animated-image strip (with color_quant, weezl). |
| exr 1.74 (https://github.com/johannesvollmer/exrs) | BSD-3-Clause | Cargo dependency of sq-app-hosts, no code copied | OpenEXR writer (half float, linear) of Export Frame. |
| tiff 0.11 (https://github.com/image-rs/image-tiff) | MIT | Cargo dependency of sq-app-hosts (already in Cargo.lock through `image`), no code copied | 16-bit TIFF writer of Export Frame. |
- Mac emoji sequences: CoreText through `objc2-core-text` 0.3.2 (MIT OR Apache-2.0 OR Zlib, the objc2 family already in the lock) in `sq-platform-mac` (installed into `sq-text` by injection), macOS only.
