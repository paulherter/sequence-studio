---
title: Effects and motion
chapter: effects-and-grading
order: 1
code: crates/sq-core-effects, crates/sq-render/src/effects, crates/sq-render/src/gpu_effects, crates/sq-render/src/compositor, crates/sq-lottie
---

## For users

How to put effects on clips, move and animate them with keyframes, shape the motion with curves, change speed, and use transitions, Lottie animations, Quick Apply and presets.

### The basics

An effect is a small change you put on a clip: a blur, a shadow, a color tweak. Every effect on a clip has parameters (numbers, checkboxes, color wells). You see and change them in the **Controls** panel (Window > Controls).

Each clip also has a **Transform** group in Controls: Position, Scale, Rotation, Anchor and Opacity, plus a Blend Mode. Use it to move, size, turn and fade a clip.

#### How to add an effect

1. Select a clip in the timeline.
2. Open the **Effects** panel (Window > Effects). Effects live in bins such as Video, Transitions and Audio. Video effects are grouped further (for example Blur & Sharpen, Cutout, Film & Retro, Adjust, Motion, Stylize, Stabilize). Every folder shows how many effects it holds. The search also finds Premiere names, such as "Gaussian Blur".
3. Drag an effect (or a preset) onto the clip or onto the Effect Controls panel, or press **Option+Space** (Ctrl+Space on Windows and Linux) to open Quick Apply and type the name (see below).
4. Open the **Controls** panel. The effect is now listed under the clip with its parameters.

Things you can do with an effect in Controls:

- Change a value by dragging the number or typing a new one.
- Use **Disable Effect** / **Enable Effect** to switch it off without losing its settings.
- Use **Duplicate Effect**, **Delete**, **Copy** and **Paste Effect** from the effect's menu. Click an effect's header to select it (a mask works the same way).
- While the Controls panel has the focus, Delete (Backspace on Windows and Linux), **Edit > Delete**, **Cut**, **Copy** and **Paste** act on what is selected in Controls and never on the clip in the timeline. Selected keyframes come first; otherwise the selected effect or mask is used. **Paste** puts a copied effect on this clip, or copied keyframes at the playhead. With nothing selected in Controls the key does nothing. **Undo** brings a deleted effect back.
- Use **Reorder Effects** to change the order. Order matters: a blur before a shadow looks different from a shadow before a blur.
- Use **Reset** to bring a value, or a whole effect, back to its default.

To copy only some parts of a clip to another clip, use Edit > Paste Special > **Paste Settings**.

### Transform and keyframes

#### Move, size and turn a clip

1. Select the clip and open Controls.
2. Change **Position**, **Scale**, **Rotation**, **Anchor** or **Opacity**.
3. **Anchor** is the point the clip turns and scales around.
4. Scale has a **Uniform Scale** option. Turn it off to set width and height separately (**Link Width and Height** / **Unlink Width and Height**).

There is also a **Transform** effect (Effects panel) that adds a second move/scale/rotate stage on top of the clip. It has Position, Scale, Rotation, Anchor, Opacity and a **Shutter Angle** for motion blur on fast moves.

#### What is a keyframe?

A keyframe stores a value at one moment in time. Put two keyframes with different values on a parameter and the app fills in everything between them. That is how you make a clip slide, grow or fade.

#### How to animate a value

1. Park the playhead where the move should start.
2. In Controls, click the **animate diamond** at the start of the parameter's row. This turns animation on and adds a key at the playhead.
3. Move the playhead to a new time.
4. Change the value. A new keyframe is added for you.
5. Play the clip.

More things you can do:

- Use the small arrows at the end of the row to jump to the **Previous Keyframe** or **Next Keyframe**, and the center button to **Add/Remove Keyframe**.
- Click the diamond again to turn animation off. The app asks before it removes the keys.
- Right-click keyframes for **Move Keyframes**, **Duplicate Keyframes**, **Delete Keyframes**, **Copy** and **Paste Keyframes**.
- Color, checkbox and choice parameters change in steps: a new key holds its value until the next key.

| Action | Mac | Windows and Linux |
|---|---|---|
| Add Keyframe (focused property) | Ctrl+Option+K | see Window > Keyboard Shortcuts |
| Go to Previous Keyframe | Ctrl+[ | see Window > Keyboard Shortcuts |
| Go to Next Keyframe | Ctrl+] | see Window > Keyboard Shortcuts |

#### Punch In

**Clip > Video Options > Holds and Fades > Punch In** (Shift+P) adds a fixed 115 % zoom to the selected video clips. Use it again to take it off.

### Curves and easing

An **ease** is how a value moves between two keys. A **curve** is the shape of that move. Our names:

| Name | What it does |
|---|---|
| Linear | Constant speed |
| Ease In & Out | Slow at both keys |
| Ease In | Slow when arriving at the right key |
| Ease Out | Slow when leaving the left key |
| Hold | No movement until the next key |
| Spring | Overshoots and settles, computed live |

More presets are in the list: Fast Start, Fast End, Gentle, Soft Landing and others. **Custom...** opens the curve editor.

#### How to ease keyframes

1. Select one or more keyframes in Controls.
2. Pick **Clip > Ease Keyframes > Linear / Ease In & Out / Ease In / Ease Out**, or right-click a key and use **Set Keyframe Easing**.
3. To flip between a hold and a normal move, use **Toggle Hold**.

| Action | Mac | Windows and Linux |
|---|---|---|
| Ease In & Out | F9 | F9 |
| Ease In | Shift+F9 | Shift+F9 |
| Ease Out | Cmd+Shift+F9 | Ctrl+Shift+F9 |

#### The speed curve editor

Open a key's curve (the open button on the row) to see its **speed curve** in a popover.

- Drag a handle sideways to change its **Reach** (how far it reaches along the segment).
- Drag a handle up or down to change the **Speed** at that key (0 means stop, 1 means steady).
- Below the 0 line the value runs backwards. That gives a wind-up before the move or an overshoot after it.
- **Save as preset** keeps a curve for all projects.
- A **Linked curve** is a named curve shared by many keys in one project. **Unlink** makes one segment independent.

#### The Graph Editor

The foldable curve under a keyframed property in Controls is the Graph Editor. It turns the keyframe area into one speed graph. All the properties you selected are drawn in it, one color each. You can select keys of several properties and move them or change their handles together.

### Built-in effects

Names and parameters below are as they appear in Controls. Open the Effects panel or Quick Apply to see the full list.

#### Blurs and sharpening

| Effect | Parameters |
|---|---|
| Blur | Amount, Repeat Edge Pixels |
| Directional Blur | Direction, Length |
| Motion Blur | Amount, Direction (Both Sides, From Previous, Toward Next), Smoothness (Coarse, Medium, Fine) |
| Sharpen | Amount |
| Unsharp Mask | Radius, Amount, Threshold |

#### Shadows, outline and glow

| Effect | Parameters |
|---|---|
| Drop Shadow | Shadow Color, Opacity, Direction, Distance, Spread, Softness, Shadow Only |
| Long Shadow | Angle, Length, Color, Fade, Opacity |
| Outline | Width, Color, Softness, Position |
| Glow | Threshold, Radius, Intensity, Glow Colors, Glow Color |

Outline draws a line around the edge of the picture's transparent area. It works well on cutouts, stickers and keyed footage. For text and shapes use the Outline and Shadow rows in the Graphics panel instead.

#### Trails and time effects

| Effect | What it does | Parameters |
|---|---|---|
| Trails | Echoes earlier frames behind moving things | Echoes, Spacing (frames), Decay, Blend (Add, Screen, Lighten) |
| Video Denoise | Cleans noisy footage using neighbor frames | Frames Each Side, Quality, Motion Search, Luma Strength, Color Strength and more |
| Deflicker | Evens out flicker | Frames Each Side, Motion Analysis, Strength |

#### Looks and distortion

Radial Blur, Mirror, Mosaic (Columns, Rows), Film Grain, RGB Split, Posterize, Duotone, Invert, Twirl, Spherize, Wave Warp, Corner Warp, Lens Distortion, Halftone, Tile, Kaleidoscope, Edge Feather, Glitch Displace, Gradient, Light Leak, Strobe Light, Horizontal Flip, Vertical Flip, Rounded Corners and Crop (Left, Top, Right, Bottom, Softness).

The tape and film looks are separate effects: Gate Weave, Aged Film, Scanlines, Chroma Bleed and Tracking Noise.

#### Keying and transparency

- **Color Key** removes one color (green or blue screen). Set Key Hue, Tolerance and Soften first. Then use Shrink / Grow, Matte Contrast, Spill and the Output choice (Composite, Alpha, Source) to clean it up.
- **Luma Key** removes the darks or the brights.
- **Track Mask** lets another video track's picture limit this clip.

#### Motion effects

The **Motion** bin holds ready-made animation effects. An effect acts over the whole clip: Shake shakes the picture for the clip's full length (Strength, Rotation, Speed, Seed), and Bounce, Pulse and Wiggle loop for the whole clip. Something that plays once at the start or end of a clip, such as Move, Zoom, Pop or the Shake transition, is a transition and lives under **Transitions**. A project made earlier, with a Shake set to play only at the start or the end of a clip, now shakes the whole clip too.

#### Punch up with Dynamic Zoom

**Clip > Video Options > Dynamic Zoom > Dynamic Zoom In / Dynamic Zoom Out** adds a slow zoom. **Edit Dynamic Zoom** lets you change it.

#### Motion presets

**Library > Presets** (the **Motion** chip) holds keyframe building blocks (punch in, shake, slide in and more) and the ones you save yourself. Select a video clip, then double-click a preset (or right-click it and choose **Apply to Selected Clips**). It lands on the whole clip as one undo step.

### Speed changes

#### How to change a clip's speed

1. Select the clip.
2. Choose **Clip > Speed...** (Cmd+R on a Mac, Ctrl+R on Windows and Linux).
3. Type a **Speed** percentage, or a **Duration**. The two are linked.
4. For video, pick **Frames**: **Repeat frames**, **Blend frames** or **Optical flow**.
5. Tick **Reverse** to play backwards, **Keep Pitch** to keep the voice from sounding high or low, and **Move Later Clips** to close or open the gap after the clip.
6. Confirm.

**Clip > Reverse Clip** reverses without opening the dialog.

#### Speed ramps

A speed ramp changes speed smoothly during a clip.

1. Select the clip and choose **Clip > Timing > Show Speed Ramp**.
2. Move the playhead and choose **Add Speed Point**.
3. Drag the points and handles to shape the ramp.
4. **Remove Speed Ramp** takes it away.

**Clip > Timing > Speed Ramp Presets** gives you one-click ramps: **Surge** (slow in, fast out), **Rush** (fast in, slow out), **Punch** (sharp burst, then slow motion), **Pulse** (quick swell and back) and **Crest** (smooth rise, fast plateau, smooth fall). Each also has an "on Beat" version.

You can also animate the **Speed** row in Controls with keyframes.

### Transitions

A transition blends or moves between two clips at a cut.

#### How to add a transition

1. Click the cut between two clips, or select clips.
2. Choose **Sequence > Apply Video Transition** (Cmd+D on a Mac, Ctrl+D on Windows and Linux). To use the default transition, choose **Apply Default Transitions to Selection** (Shift+D).
3. Or drag a transition from the **Transitions** bin onto the cut.
4. Select the transition to change **Duration**, **Alignment** and **Easing** in Controls.

Alignment can be **Center at Cut**, **Start at Cut** or **End at Cut**. If a clip has no extra media past the cut, the transition holds the last frame. The held part is drawn with red stripes.

Some of the transitions: Dissolve, Through Black, Through White, Through Color, Quick Fade, Push, Slide, Whip, Zoom In, Zoom Out, Zoom Pop, Soft Wipe, Glitch, Iris, Light Leak, Blur Dissolve, Flash, Spin, Cross Zoom, Clock Wipe, Radial Wipe, Barn Doors, Blinds, Checker Wipe, Mosaic Dissolve, Flip 3D, Shake, Move, Zoom and Pop.

For sound there are **Crossfades**, including Smooth Crossfade and Steady Crossfade.

### Lottie animations

Lottie is a file format for vector animations (stickers, icons, animated graphics).

1. Choose **File > Import Lottie Animation...** (it may be inside an Import submenu).
2. Pick a Lottie animation file.
3. Drag it from the Project panel onto a video track like any other clip.
4. Change Position, Scale, Opacity and effects in Controls.

### Quick Apply

Quick Apply is a search popup for effects, transitions, presets and commands.

1. Select a clip.
2. Press **Option+Space** (Ctrl+Space on Windows and Linux, or Window > Quick Apply).
3. Type a few letters. Recent items show first when the search is empty.
4. Use Up and Down to move, **Return** to apply, **Esc** to close.
5. For a transition with selected clips, Return asks where to put it: Left for start, Right for end, Down for both, then Return.

### Presets

A preset is a saved group of effects with their keyframes.

- Built-in presets cover motion (live motion effects on the clip), keying (Green Screen, Blue Screen), film looks (Film Look, VHS, Bad TV) and audio chains.
- A preset is applied as normal effects. After that you can change them freely.
- To keep your own: choose **Save Effect Stack as Preset** in Quick Apply, or **Save as Preset** for a clip. It saves Transform, Opacity and the effects with their keyframes and easing, and puts the preset in the **Library** panel.
- Saved easing curves are kept in the same Library.

### Keys at a glance

On Windows and Linux, use Ctrl where this table says Cmd, and Alt where it says Option. Open **Window > Keyboard Shortcuts** to see or change any key.

| Action | Mac |
|---|---|
| Quick Apply | Option+Space (Ctrl+Space on Windows and Linux) |
| Speed... | Cmd+R |
| Apply Video Transition | Cmd+D |
| Apply Default Transitions | Shift+D |
| Ease In & Out | F9 |
| Punch In | Shift+P |

### Not sure yet

- Which bin holds Outline, Long Shadow, Trails and Motion Blur in the Effects panel.
- Whether every effect and Lottie import work the same on Windows and Linux.
- The Windows and Linux keys for shortcuts that use the Control key on a Mac.
- Whether Ctrl+Space opens Quick Apply on every Linux desktop (an input method may own it).
- The exact submenu of the Import Lottie command in the shared window.

Related: [Editing](timeline-and-editing.md), [Color](color.md), [Masks and tracking](masks-and-tracking.md)

## For developers

Effects, transitions and motion are split into saved data, pure logic, and GPU drawing.

| Crate | Role |
|---|---|
| `sq-core-model` | The saved types (clip effects, keyframes, transitions). |
| `sq-core-effects` | Pure logic: effect evaluation at a time (`effects_evaluation`, `evaluation`), editing verbs (`effects_editing`), Dynamic Zoom, motion effects, motion presets and recipes, speed ramp presets, effect and effect stack presets, adjustment clips, transitions (`transition`, `transition_layer`, `transition_feel`, `transition_custom_curve`), sequence conform. |
| `sq-render` | Turns layer requests into GPU passes. `effects` holds the CPU references (blend modes, keys, crop mask, Gaussian blur, style and whole-picture filters), `gpu_effects` the GPU passes of the effect chain, `compositor` the layer tree and `GpuCompositor`. |
| `sq-gpu` | The shaders, written once in Slang (`crates/sq-gpu/shaders-src`, for example `Blur.slang`, `DropShadow.slang`, `Filters.slang`, `TemporalTrails.slang`, `OpticalFlow.slang`, `TransitionMix.slang`, `TransitionCover.slang`). `cargo xtask shaders` regenerates the compiled shaders. |
| `sq-lottie` | Lottie documents. |

Data flow: the clip's effect list and keyframes are evaluated by `sq-core-effects` for the playhead time. The compositor
(`sq-render/src/compositor`) builds a layer tree, and after a layer is drawn it calls `EffectHooks::finish_layer`
(`compositor/gpu_compositor.rs`); `gpu_effects` implements those hooks (Crop, Rounded Corners, blur, shadows, filters,
keys, masks, film look). The pure plan of the chain is in `gpu_effects/effect_chain_plan.rs`, the uniform packing in
`gpu_effects/uniform_plan.rs`. Temporal effects (Deflicker, Video Denoise, Trails) are in `gpu_effects/temporal_passes.rs`,
optical flow in `gpu_effects/optical_flow_passes.rs`.

Transitions are stored anchored to clip ids and only record the user's intent. `TrackTransitions::resolve`
(`sq-core-effects/src/transition/resolve.rs`) clamps the duration to the clip handles and requires the cut to exist;
`Track::prune_transitions` drops what no longer resolves. The per-frame maths (`TransitionMix`, `TransitionRender`) are in
`transition/render.rs`; the edit verbs on `Timeline` in `transition/edit.rs`.

Lottie: `sq-lottie` keeps the document model and a renderer seam. `LottieEngine` and `LottieDrawing`
(`lottie_renderer.rs`) are the traits an engine implements; `LottieRenderer` (`lottie_document.rs`) caches frames within a
byte budget (`with_frame_budget`) and returns a `PortableFrame` for a layer request. The portable drawing path uses
`tiny-skia` (`lottie_skia.rs`); other modules cover expressions, geometry, modifiers, properties and text.

Tests: `cargo xtask check sq-core-effects`, `cargo xtask check sq-render`, `cargo xtask check sq-lottie`. The GPU effects
have golden tests (`gpu_effects/golden.rs`, `tests_effects.rs`, `tests_flow_temporal.rs`) compared with the CPU references
in `sq-render/src/effects`, which are the oracle.

Extension points: a new effect needs its saved type in `sq-core-model`, evaluation in `sq-core-effects`, a CPU reference in
`sq-render/src/effects`, a Slang kernel in `sq-gpu/shaders-src` and a pass in `gpu_effects`; a new transition kind needs its
logic in `sq-core-effects/src/transition` and a shader (`TransitionMix`, `TransitionCover`, `TransitionPreBlur`).

## For AI agents

- Inputs: a clip's effect list with keyframes, the sequence time, and the sequence format. Output: a drawn layer in the
  compositor and, for transitions, the mix of two layers.
- Invariants: saved types live in `sq-core-model`, logic in `sq-core-effects`, drawing in `sq-render` and `sq-gpu`. Time is
  rational. The CPU references in `crates/sq-render/src/effects` are the test oracle of the GPU kernels, so a kernel
  change comes with a matching reference change.
- A stored transition holds only intent (clip ids, duration); what plays comes from `TrackTransitions::resolve`
  (`crates/sq-core-effects/src/transition/resolve.rs`). Never write a resolved duration back as saved data.
- Shaders are Slang in `crates/sq-gpu/shaders-src` (shared parts in `Parts/`), one source for Metal and D3D12.
- Files: `crates/sq-core-effects/src/{effects_evaluation,effects_editing,motion_effects,motion_presets,dynamic_zoom,speed_ramp_preset,transition}.rs`,
  `crates/sq-render/src/{effects,gpu_effects,compositor}`, `crates/sq-lottie/src`.
- Commands: `cargo xtask check sq-core-effects`, `cargo xtask check sq-render`, `cargo xtask check sq-lottie`,
  `cargo xtask shaders` (after editing a `.slang` file).
- Extension hook: `EffectHooks` in `crates/sq-render/src/compositor/gpu_compositor.rs`.
