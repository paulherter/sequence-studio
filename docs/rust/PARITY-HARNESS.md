# Cross-platform parity harness

Renders fixed inputs through the real program render path (`ProgramCompositor::render`, then the Present pass) on the
machine's GPU, without a window, and writes RGBA8 PNGs. Compare two machines' folders with `scripts/parity-compare`.

Inputs (`crates/sq-render/src/program/tests_parity.rs`, test `parity_dump`):
- `card.png`: 640x360 synthetic card as an NV12 frame tagged Rec.709, limited range: 17-step gray ramp (0, 16 ... 240, 255),
  red/green/blue/cyan/magenta/yellow patches, two skin tones, white and black bitmap text on gray (96). Patch rects:
  `card-patches.tsv`. The card is authored as display RGB, so the expected output is the same RGB back (QuickTime style).
- `clip.png` (optional): one real frame as raw 640x360 NV12 (`SQ_PARITY_NV12=<file>`), e.g.
  `ffmpeg -ss 3 -i TestMedia/stock/city-traffic.mp4 -frames:v 1 -vf "scale=640:360:out_color_matrix=bt709:out_range=tv,format=nv12" -f rawvideo clip.nv12`.

Run (same on every OS):

    SQ_PARITY_OUT=<dir> [SQ_PARITY_NV12=<file>] cargo test -p sq-render parity_dump -- --nocapture
    scripts/parity-compare <dirMac> <dirWin> [threshold=2]

`adapter.txt` in each folder names the GPU. The comparator prints max and mean abs difference per channel per image, the card
patches over the threshold, and exits 1 when any RGB max exceeds it.

On the Windows PC: copy the stage folder to a work folder `sqrust` (crates, Cargo.*, rust-toolchain.toml, clip.nv12), then
run `'<env vars above>; cargo test ...'` there, then copy the output folder back.

Result 2026-11-09 (M1 Max Metal vs RX 9070 XT D3D12): max 1/255 on both images, mean 0.016 (card) and 0.027 (clip) per
channel; no patch over 2/255. Not covered: CPU-drawn text rasters (sq-text runs on the CPU), HDR, effects.

Linux: WSL2 on the Windows PC has the lavapipe ICD (`/usr/share/vulkan/icd.d/lvp_icd.json`) and cargo 1.99, but the test stops with
"no shader backend for this platform (Metal and D3D12 only)" (`sq-gpu/src/pipelines/passthrough.rs:42`): a Vulkan path needs the
SPIR-V outputs of `cargo xtask shaders --spirv` wired into sq-gpu. Until then Linux cannot be compared.
