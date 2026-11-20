---
title: Masks and tracking
chapter: masks-and-tracking
order: 1
code: crates/sq-core-masks, crates/sq-analysis, crates/sq-gyroflow, crates/sq-onnx
---

## For users

How to cut out parts of a picture with masks, pick a subject with Magic Mask and track it, steady shaky footage, reframe for other shapes, and find scene changes.

### What works where

| Feature | Mac | Windows and Linux |
|---|---|---|
| Shape masks (rectangle, ellipse, pen) | Yes | Shared app, see Not sure |
| Picture (matte) masks | Yes | Shared app, see Not sure |
| Color Range masks | Yes | Shared app, see Not sure |
| Magic Mask (click a subject, then track) | Yes | Yes |
| Mask tracking for path masks | Yes | See Not sure |
| Stabilize (Standard, picture analysis) | Yes | Yes |
| Stabilize with Gyroflow | Yes | Yes, in Controls |
| Auto Reframe | Yes | Yes, see Not sure |
| Find Scene Changes | Yes | Yes |

When a command is not available on your computer, the status line says "... is not available on this computer yet."

### Masks

A mask limits where a clip shows, or where an effect works. Everything outside the mask is cut away (or the other way round, if you invert it).

#### Kinds of mask

- **Shape masks**: Rectangle, Ellipse, or a free **Pen** path. All of them are bezier paths you can edit point by point.
- **Picture masks**: another video track's picture is the mask. Read its **Shape** (alpha) or its **Brightness**.
- **Color Range masks**: the mask follows a picked color.
- **Magic Mask**: you click a subject and the app follows it.
- **Subject Mask**: a person cut-out in one step.

#### How to add a shape mask

1. Select a video clip.
2. In **Controls**, add a mask from the Mask section, or right-click the Program monitor and choose **Add Mask**, then **Add Rectangle Mask** or **Add Ellipse Mask**.
3. Or press **P** for the **Mask Tool** and pick its mode: **Magic**, **Pen**, **Ellipse** or **Rectangle**. Drag to draw an ellipse or rectangle. In Pen mode, each click adds a corner point (Shift-click starts a new mask).
4. Drag points and handles in the Program monitor to change the shape. You can **Add Mask Vertex**, **Delete Mask Vertex** or **Convert Mask Vertex** (corner or curve) from the menu.

A path needs at least three points.

#### Mask settings

Each mask has these rows in Controls:

| Setting | What it does |
|---|---|
| Mask Feather | Softens the edge |
| Mask Opacity | How strongly it cuts |
| Mask Expansion | Grows or shrinks the shape |
| Inverted | Swaps inside and outside |
| Mask Mode | **Add**, **Subtract**, **Intersect** or **Difference**, to combine with masks above it |
| Mask Path | Stopwatch to animate the shape |

Turn on **Animate Mask Path** (the stopwatch) to add a key. Move the playhead, change the shape, and the mask follows.

Press **Mask Tint** (right-click the Program monitor, **Show**) to see the masked area tinted.

#### How to add a picture mask

1. Put the clip that should be the mask on another video track of the same sequence.
2. Select the clip to be masked.
3. Right-click the Program monitor and choose **Add Mask > Add Picture Mask**, then the track.
4. In Controls, pick the track and a channel (**Shape** or **Brightness**) on the **Picture of** row.

The **Track Mask** effect does a similar job with Alpha or Luma and an Invert option.

#### How to add a Color Range mask

1. Right-click the Program monitor and choose **Add Mask > Add Color Range Mask**.
2. Pick the color in the picture.
3. Adjust **Tolerance** (how far from the color still counts) and **Softness** (how gradually it fades out). **Invert** keeps everything except the color.

#### Use a mask inside an effect

A mask can cut the picture or only feed an effect. Choose **Use Mask in Effect** (also shown as **Use in effect...**) and pick the effect. Then the effect works only inside the mask. **Stop Using Mask in Effect** reverses it. Turn off **Mask Cuts Picture** if the mask should only be a helper.

### Magic Mask

Magic Mask finds an object you click and follows it through the clip.

#### How to use it

1. Select a video clip and put the playhead on a frame where the subject is clear.
2. Press **P** and choose **Magic**.
3. Move over the Program monitor. The object under the pointer is highlighted.
4. Click to pick it. Click more to **Add to Magic Mask**. Option-click to **Remove from Magic Mask**. Shift-click to start a new mask.
5. In Controls, press **Follow to the end** to follow the subject from here to the clip's end, or **From here back to the start**. The strip under step 3 is green where the mask holds and orange where it might slip. **Show me where →** jumps to the first orange place. The edge rows are **Soft edge**, **Grow / shrink** and **Keep outside**. The step buttons track one frame at a time. **Stop Tracking** ends a run.
6. Scrub through. Where the mask is wrong, go to that frame and click to correct it. Then track again.

A pick only stores the mask on the frame you clicked. Nothing follows until you press a track button.

**Go to Next Weak Tracking** (Markers menu, Option+Shift+M on a Mac) jumps to the next stretch where the track is not sure.

#### Edge quality

Right-click the Program monitor and open **Show > Subject Mask Edges**:

- **Quality**: finer hair and soft edges, tracks slower.
- **Speed**: tracks faster, simpler edges.

Track the mask again to change frames that are already tracked.

#### Subject Mask

**Clip > Video Options > Add Subject Mask** (also in the Program monitor menu) makes a mask of the people in the picture in one step.

### Tracking a path mask

A shape mask can follow moving things.

1. Draw the mask around the object on one frame.
2. In the mask's row choose what tracking follows: **Position**, **+ Scale**, **+ Rotation** or **Perspective**. Start with Position and add more only when needed.
3. Press **Track Mask Forward** or **Track Mask Backward**. Click again to stop.

Tracking stops where the object is lost. Check the result, and fix the mask by hand on the frames it missed.

### Stabilization

Stabilization smooths out camera shake.

#### How to stabilize

1. Select the clip.
2. Choose **Clip > Video Options > Stabilize**, or drag the **Stabilizer** effect (Effects panel, Video > Stabilize) onto the clip.
3. The picture is analyzed. Controls shows progress and a Cancel option. Choosing Stabilize again while it runs cancels it.
4. Adjust the settings in Controls.

The Stabilizer has a **Method**: **Standard** or **Gyroflow**.

#### Standard method

It measures the shake in the picture and corrects it.

| Setting | What it does |
|---|---|
| Result | **Smooth Motion** keeps the move but removes bumps. **No Motion** locks the view. **Auto** decides. |
| Strength | How much correction |
| Smoothness | How long (in seconds) the camera path is smoothed |
| Crop Limit | Most the picture may be zoomed to hide edges |
| Edge Fill | **Zoom**, **Mirror Edge** or **Blur Edge** for the borders |
| Rolling Shutter, Rolling Shutter Strength | Reduces jelly wobble |

If a clip is trimmed longer after analysis, analyze again.

#### Gyroflow

Gyroflow uses the camera's own motion sensor data, so it is steadier than analyzing the picture. It needs:

- A clip that has gyro data (many action cameras record it), or a gyro data file placed next to the clip.
- The Gyroflow engine is built into the app. If the clip has no gyro data, the Gyroflow method is grayed out and shows the reason, for example "No gyro data in this file." Gyroflow is chosen in the Stabilizer rows of Controls; the Stabilize window does not offer it.

How to use it: set **Method** to **Gyroflow**. If all selected clips have gyro data, Stabilize may also offer **Use Gyroflow** or **Analyze Picture**.

| Setting | What it does |
|---|---|
| Smoothness | How smooth, in percent |
| Zoom Limit | Most the picture may be scaled up |
| Field of View | Above 100 shows more picture, below 100 zooms in |
| Lens Correction | How much lens distortion is removed |
| Rolling Shutter | On by default |
| Horizon Lock | Keeps the horizon level |
| Sync Offset | Shifts the gyro data against the picture, in milliseconds |

### Auto Reframe

Auto Reframe moves and scales a clip so the main subject stays in frame. Use it to turn 16:9 footage into 9:16.

1. Set the sequence to the new shape.
2. Select the clips.
3. Choose **Clip > Video Options > Fit Frame > Auto Reframe**.
4. Pick **Motion**: **Quick**, **Steady** or **Smooth**. Pick **Framing**: **Fill Frame**, **Closer** or **Tight**.
5. The app adds an **Auto Reframe** effect with Position keys. You can edit the keys in Controls.

If no subject is found the message tells you how many clips were skipped.

### Find Scene Changes

This finds the cuts inside a long clip, for example a recording that is already edited.

1. Select one or more video clips.
2. Choose **Clip > Video Options > Find Scene Changes**.
3. The app reads the clips and shows progress. Choose it again to cancel.
4. The scene changes are marked as proposed cuts. Review them, then use **Clip > Audio Options > Clean Up > Proposed Cuts > Accept All Proposed Cuts** to cut there, or reject them.

### Not sure yet

- Whether shape masks, picture masks, Color Range masks and mask tracking work on Windows and Linux today.
- Whether "point tracking" exists as a separate tool. Tracking in the app follows masks.
- Where the Mask section's Add command sits in Controls on the shared window.
- Whether the Gyroflow choice dialog appears in the shared window. The Method row is there.
- Whether Subject Mask works on Windows and Linux.
- Whether Auto Reframe is offered on every Windows and Linux install: it needs the subject-detection runtime that comes with the package, and without it the command answers "Auto Reframe is not available on this computer yet."
- Whether Stabilize results are kept when you quit before saving.
- Which gyro file types are accepted next to a clip.

Related: [Effects and motion](effects-and-motion.md), [Color](color.md), [Editing](timeline-and-editing.md)

## For developers

Masks and tracking are spread over five crates.

| Crate | Role |
|---|---|
| `sq-core-model` | Saved types (`ClipMask`, `MaskPath`, `MagicSelection`, `MaskSource`). |
| `sq-core-masks` | Logic: masks and their editing (`masks`, `mask_path_editing`, `mask_motion`, `mask_inputs`), Picture mask, Magic Mask (`magic_mask`, `magic_follow`, `magic_correction`, `magic_track_health`), Subject mask rules, Anonymize, and the Stabilizer (`stabilizer`, `_solve`, `_quadratic`, `_l1`, `_perspective`, `stabilization_cuts`, `rolling_shutter`, `stabilize_effect`). |
| `sq-analysis` | The portable engines: EdgeTAM subject tracking (`edge_tamonnx.rs`), point tracking (`mask_point_tracker.rs`), feature tracking and homography fit for stabilization, scene cut detection (`scene_cut_detector.rs`), Auto Reframe (`reframe.rs`), person detection, saliency, beat detection. |
| `sq-onnx` | The ONNX Runtime wrapper. The runtime library is loaded at run time, so the app starts without it and reports `OnnxError::Unavailable` when it is missing. |
| `sq-gyroflow` | Gyroflow stabilization: `GyroFile` opens a clip and smooths it, `GyroAnalyses` keeps one analysis per (file, options). `gyroflow-core` is a cargo dependency, so the engine is always present. |

Data flow for Magic Mask: `sq-analysis` runs EdgeTAM through `sq-onnx`, matte results are stored by the frame matte store
(`frame_matte_store.rs`), and `sq-render` draws them (`gpu_effects/mask_data.rs`, `Parts/Mask.slang`, `MaskScope.slang`).
Gyroflow: `GyroFile::warp_map` captures a coarse warp map from gyroflow-core, and the `GyroWarp` Slang pass
(`sq-render/src/program/gyro_warp.rs`, `sq-gpu/shaders-src/GyroWarp.slang`) resamples the frame with Lanczos-4. The map is
normalized, so playback and export at any decode size show the same pixels. `warp_plane_cpu` is the CPU reference.

Execution providers: `Provider::choose` in `sq-onnx/src/onnx_model.rs` is the one place that picks. The environment
variable `SQ_ONNX_PROVIDER` takes `cpu`, `directml`, `coreml` or `auto`; `auto` gives the platform accelerator (DirectML on
Windows, Core ML on the Mac) to models that ask for it, and the CPU to the rest. A provider that refuses a model falls back
to the CPU. Unsafe code is limited to the `ffi` module of `onnx_model.rs`; `sq-onnx/vendor/csqonnx.c` holds the C loader.

Tests: `cargo xtask check sq-core-masks`, `sq-analysis`, `sq-onnx`, `sq-gyroflow`. The real-model test
`edge_tamonnx::tests::a_disc_follows_the_click_and_moves` runs EdgeTAM only when `SQ_SUBJECT_MASK_MODELS` points at the
`edgetam_*.onnx` files and a runtime can be loaded; otherwise it prints why and passes.

## For AI agents

- Inputs: clip masks, a Magic Mask click or box, decoded frames, gyro data or a `.gcsv` sidecar. Output: mattes per frame,
  mask paths over time, stabilization transforms, scene cut indices, reframe boxes.
- Invariants: logic is in `sq-core-masks` (no I/O), engines in `sq-analysis`, model sessions only through `sq-onnx`.
  A missing ONNX runtime is an error value (`OnnxError::Unavailable`), never a crash at start.
- `sq-onnx` allows unsafe code only in the `ffi` module of `crates/sq-onnx/src/onnx_model.rs`; `sq-analysis` only in the `ffi` module of `src/lzfse.rs`.
- Env: `SQ_ONNX_PROVIDER=cpu|directml|coreml|auto`, `SQ_SUBJECT_MASK_MODELS` (EdgeTAM model folder for the real-model test), `SQ_ONNXRUNTIME` (runtime folder on the Mac).
- Files: `crates/sq-core-masks/src`, `crates/sq-analysis/src`, `crates/sq-onnx/src/onnx_model.rs`, `crates/sq-gyroflow/src`,
  `crates/sq-render/src/program/gyro_warp.rs`.
- Commands: `cargo xtask check sq-core-masks`, `cargo xtask check sq-analysis`, `cargo xtask check sq-onnx`, `cargo xtask check sq-gyroflow`.
