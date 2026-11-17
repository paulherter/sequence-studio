# HDR plan (W47, 2026-11-09)

## Swift behavior (read in this session)
- Working space: scene-linear Rec.709 primaries, half float, 1.0 = reference white = 203 nit (`HDRConform.swift:1-8`, `HDRDelivery.swift:61-67`).
- HLG/PQ sources are tone-mapped to SDR (extended Reinhard, peak 1000 nit) unless the clip's target is HDR or `hdrConform` is off
  (`ClipColorPipeline.swift:133`: `skipsToneMap = (!hdrConform || targetSpace.isHDR) && source.isHDR`).
- HDR export (HEVC only): `TimelineFrameSource.swift:526` sets `skipsToneMap` for every HDR source when `hdrOutput != nil`, the export shader
  (`SQ_HDR`) then does linear 709 -> Rec.2020 -> HLG/PQ OETF (`HDRDelivery.encode`), P010, BT.2020 tags, MDCV/CLLI.
- SDR sources in an HDR file: just the linear value, so SDR white lands at 203 nit (PQ code 573, HLG signal 0.75).
- Display: `DisplayView.swift:14-39` has `hdr1000` / `unToneMapped`, extended-range float on `extendedLinearDisplayP3` (EDR, CAMetalLayer).

## Rust gap before this change
- Compositor already composites in `Rgba16Float` and the clip pipeline already has `skips_tone_map` (`color/clip_pipeline.rs:157`), and the engine
  already publishes the half-float canvas (`Shown::linear`). But the export read the 8-bit Present output, and the resolver never set
  `skips_tone_map` for an HDR delivery, so `hdr_stage` only saw SDR (`shortcut:` in `hdr_stage.rs`).
- Display: `sequence-studio/src/surface.rs:90` configures `Bgra8Unorm` + `SurfaceColorSpace::Auto`: SDR only.

## Done in this slice (export)
1. `LayerColorResolver::with_hdr_output(.., true)`: HLG/PQ pipelines skip the tone map (Swift 526). Playback keeps `new` (tone-mapped).
2. `EngineFrames` (sequence-studio/export.rs), when `applied_hdr_delivery()` is set, reads `Shown::linear` and hands the encoder an
   `Rgba16f` frame (linear Rec.709, 1.0 = 203 nit). Every other export stays on the 8-bit Rec.709 frame: SDR output is untouched.
3. `hdr_stage::to_p010_f16` reads half floats (no clamp before the OETF, negative light floors at 0); `to_p010` (8-bit) shares the same packer.
4. Tests: `hdr_stage` unit tests (float white = code 573/721, 4x white above, 8-bit and float inputs agree within 3 codes) and
   `a_pq_clip_keeps_its_highlights_in_an_hdr_export` (10-bit PQ ProRes clip at Y' 700 -> HEVC Main10 file, ffprobe tags, decoded peak code > 650,
   SDR white is 573; the SDR export still yields `Rgba8`).

## Not done (next steps)
- SDR sequence with an HDR clip and an SDR file: already tone-mapped the Swift way (default path, unchanged).
- HDR-to-SDR / `HdrToSdr` conform settings and the per-clip `target_space` HLG<->PQ conversions (`HDRConform.Kind`) are not wired in the compositor.
- The 8-bit `fit` scaler for scaled exports is nearest neighbor for the float frame too (same as before for 8-bit).
- Display path. wgpu 30 has `SurfaceColorSpace::ExtendedSrgbLinear` (scRGB; Metal EDR and DX12 `RGB_FULL_G10`, Rgba16Float, `Auto` picks it for
  Rgba16Float when supported) and `Hdr10` (PQ). So both systems can show HDR with the same code: a second `Rgba16Float` surface config
  and a Present variant that writes `working * (SDR white nits / 80)` instead of the 709 OETF, plus a Program-monitor "HDR" display mode like Swift's
  `hdr1000`. Mac: needs `wantsExtendedDynamicRangeContent` (wgpu-hal sets it for this space). Windows: only when Windows HDR is on; otherwise the
  surface stays SDR. Untested here (no HDR display): build as one small slice with a runtime probe of `surface.get_capabilities().format_capabilities`.

## Step 2 (W51, 2026-11-09)
- Export file verified on the PC (hevc_amf, 640x360, `a_pq_clip_keeps_its_highlights_in_an_hdr_export` with `SQ_REQUIRE_HDR_FILE=1`): yuv420p10le,
  bt2020nc/smpte2084/bt2020, mastering display + content light level side data, peak Y' code 700 (source 700, SDR white 573). HLG file not run
  (same code path, OETF unit-tested). The test now exports at 640x360 (AMF limit).
- Per-clip conform: the working space is scene-linear (1.0 = 203 nit), so HLG<->PQ and SDR-in-HDR need no extra pass: a clip decodes to the same
  light the explicit `HdrConform` route encodes (`hdr_sequence_conform_matches_the_explicit_route`, known values 0.25/1/2/4 x white, SDR white = PQ 572-573).
  HLG/PQ in an SDR sequence: tone-mapped as before.
- Display: `effects/display_view.rs` ports Swift `DisplayView` (default Sdr, session-only) and `surface_mode(view, headroom)`; ExtendedLinear only for an
  HDR view on a display with headroom > 1. `Surface::new` logs the mode; it still always configures `Bgra8Unorm` (SDR shots unchanged).

## Step 3 (W53, 2026-11-09): display path
- Surface: `Surface::follow_mode` (surface.rs) reconfigures the window as `Rgba16Float` + `SurfaceColorSpace::ExtendedSrgbLinear` when `surface_mode(view, headroom)`
  says `ExtendedLinear`, back to `Bgra8Unorm` + `Auto` otherwise (macOS: the sRGB tag is skipped in float mode, wgpu-hal sets the extended tag). Checked on every `present`.
- Drawing: no new Slang (no `slangc` here). The UI draws twice through the unchanged `DrawQuads` pipeline into two `Bgra8Unorm` targets (video quad black / white,
  `WgpuRenderer::draw_with(.., VideoOverride)`), then `sq_draw::hdr_present::HdrPresent` (WGSL) writes the surface: sRGB-decoded UI * 203/80, plus the
  linear half-float Program composite (`DisplayPicture::linear` = `Shown::linear`) in the video quad, weighted by `white - black` (1 on the bare picture, 0 under an opaque
  overlay). UI white = 203 nit like the SDR path's white. Hdr1000 = hue-preserving roll-off toward 10x white (same formula as `DisplayView::encode`), UnToneMapped = raw,
  both in Rec.709 primaries (scRGB), no P3 matrix. Without a linear picture (CPU pixels) the UI is drawn once as it is.
- Probe: trait `sq_platform::display::HeadroomProbe` (`SystemProbe`, `FixedProbe`); macOS `NSScreen.maximumExtendedDynamicRangeColorComponentValue` (objc2 `msg_send`, `sq-platform-mac/display.rs`),
  Windows DXGI `IDXGIOutput6::GetDesc1` of the window's monitor: headroom = MaxLuminance / 203 only when the color space is HDR10 (advanced color on). Asked at start, on `Moved` and
  `ScaleFactorChanged`. `SQ_HDR_HEADROOM=<x>` overrides the answer. Logged: "display headroom probe: ..." and "display mode: ...".
- Menu: View > Display (four views, Swift titles, default SDR, session-only, checkmark), `EditorCommand::DisplayView`, wired in `timeline_commands.rs`. Swift has no menu for it (only `DisplayView.current`).
- Tests: `hdr_present` (golden values on the CPU twin; WGSL vs CPU twin on the PC's DX12 adapter), `the_float_surface_encoding_matches_display_view`, `tests/sdr_hash.rs`
  (SDR scene hash 0x7ec16e01663d0a44 equal with the renderer before and after), `display_view_is_session_only_checked_and_defaults_to_sdr`, `sq-platform` probe mapping.
- NOT SEEN: no HDR display here. The float surface itself (wgpu `configure` with `Rgba16Float`/`ExtendedSrgbLinear`, EDR on macOS, Windows HDR on) and the probe values on real HDR hardware are untested;
  (capability check: see Step 4).
- Open: `DisplayP3` still draws on the 8-bit surface; Windows SDR-white-level slider is not read (203 nit assumed); the Source monitor picture is SDR white-scaled only.

## Step 4 (W104, 2026-11-10)
- Capability check: `Gpu` keeps its adapter (`Gpu::adapter`); `Surface::new` asks `surface.get_capabilities(adapter)` once and `float_surface_supported` needs
  `Rgba16Float` with `EXTENDED_SRGB_LINEAR`. `follow_mode` passes the wanted mode through `usable_mode`: without support it stays on `Bgra8Unorm` + `Auto` and logs
  "view ... needs a float surface ... staying on the SDR surface" once per view; startup logs "float display surface supported: <bool>". Test
  `a_surface_without_extended_linear_falls_back_to_sdr` (constructed capabilities).
- View Gamma in float modes: Swift ignores it too. `Present.slang:38` applies `exponent` only inside the `mode < 1.5` branch (SDR / Display P3); the HDR branch
  (`mode` 2 / 3, lines 39-46) writes linear light untouched. Rust matches (the gamma table only sits on the 8-bit path). Nothing to port.
- Transparent composite: the Swift present shader adds the 16 px checkerboard (0.20 / 0.32) for alpha < 1 in every mode (`Present.slang:50-56`); the float pass now does the same
  (`hdr_present.rs`, values in working units, scaled by 203/80). Tests `a_transparent_picture_shows_the_checkerboard_like_the_swift_present_shader` (CPU) and
  `the_shader_matches_the_cpu_twin` (picture alpha 0.5, GPU vs CPU).
- Still open (needs a display or a decision): `DisplayP3` on a P3 surface, Windows SDR-white-level slider, HDR Source monitor.

## Step 5 (2026-11-12): checked on the built-in XDR screen (M1 Max)
- Real run (`SQ_DISPLAY_VIEW=raw|p3|sdr`, project with a PQ HEVC clip, window open 14 s, log `~/Library/Logs/Sequence Studio/sq.log`):
  `float display surface supported: true`; `screen EDR component value: current 1.2, potential 5`; `display headroom probe: Some(5.0)`;
  `display mode: ExtendedLinear for view Not Tone-Mapped`; `surface ExtendedLinear: layer pixel format 115 (rgba16Float), colorspace
  kCGColorSpaceExtendedLinearSRGB, wantsExtendedDynamicRangeContent true`. wgpu 30 already sets the EDR flag and the colorspace on the
  CAMetalLayer, so no raw-layer fix was needed (a layer report line now proves it on every mode change).
- Headroom: the probe now takes the screen's *potential* value (5 = 1000 nit / 203). The current value is 1.0 to 2.5 and follows brightness and
  the EDR content on screen, so using it could never switch the float surface on from an idle SDR screen.
- Display P3: `SurfaceMode::DisplayP3` = `Bgra8Unorm` surface, layer tagged `kCGColorSpaceDisplayP3` (log: pixel format 80, colorspace
  kCGColorSpaceDisplayP3, EDR false), drawn through the same present pass (`Encoding::DisplayP3`): UI and picture in linear light, Rec.709 to P3
  matrix, clip, sRGB transfer. Swift tags P3 primaries with the 709 transfer and encodes the 709 OETF; the light is the same (tested), only the
  curve of the codes differs. Windows and Linux stay on the SDR surface for this view (no layer tag there).
- Source monitor: the Source engine's linear picture goes through the same pass (`Surface::set_source_picture`, `VideoQuad::of_image`,
  `WgpuRenderer::draw_with_image` forces image slot 5 to black / white); Program and Source are two pictures in one pass.
- Numbers: a 1000-nit patch (4.926 whites) is written as scRGB 12.49 (12.5 = 1000 nit) in half floats; UI white stays 203 nit (2.54 scRGB).
  The Mac SDR scene hash is 0xcc664f7fb75d1f8e before and after (the 0x7ec1... golden is the DX12 adapter's).
- Tests: `two_pictures_and_the_p3_target_match_the_cpu_twin` (GPU vs CPU twin, both targets), `display_p3_writes_p3_codes_with_the_srgb_transfer`,
  `the_display_p3_encoding_matches_display_view`, `an_image_slot_can_be_forced_to_black_and_white`, `surface_mode` tests.
- Not seen: a screenshot cannot show HDR; the Source monitor in a window was not opened by hand (tests only). Windows HDR still untested.
