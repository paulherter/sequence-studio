# Vocabulary (display words)

One term per concept, short, plain English, same word in Effect Controls, Effects panel, menus, popovers and docs.
Display-only: code names (`Easing`, `EaseArm`, `EasingPreset`, `MotionCurve`) stay as they are. Premiere names are not a goal
(DECISIONS 2026-10-02). New sections are added by the pass that touches them. Naming pass (DECISIONS 2026-10-03, below)
table rows are the work list: apply each row to display strings only. Ids, ProjectFile keys, the .prproj importer mapping
(PRMapper, importer report notes) and code identifiers stay. Menu, bin and tool names keep Title Case as today.

## Easing (KEYFRAME-EASING, DECISIONS 2026-10-03)

On branch keyframes-pre-easing the redesign is reverted (DECISIONS 2026-10-03); only the key-command names (Smooth, Smooth in, Smooth out) are in use there.

| Concept | Use | Do not use |
|---|---|---|
| How a value moves between two keys | **Ease** (noun and verb: "ease the selection") | Interpolation, Velocity curve, Temporal |
| The shape of that move | **Curve** | Bezier, Graph curve, Motion path |
| Constant speed | **Steady** | Linear |
| Slow at both keys | **Smooth** | Easy Ease, Ease in-out, Continuous Bezier |
| Slow arriving at the right key | **Smooth In** | Ease In |
| Slow leaving the left key | **Smooth Out** | Ease Out |
| Passes the end value and settles | **Overshoot** | Back out, Anticipate (that is the reverse, next row) |
| Pulls back before it starts | **Wind-Up** | Back in, Anticipate |
| Bouncy settle, computed live | **Spring** | Elastic, Bounce |
| No movement until the next key | **Hold** | Step, Freeze |
| The next key's value from right after this key (a Hold played backwards: what a reverse makes of a Hold; its own entry directly under Hold in the keyframe menus and chips, glyph = the Hold step mirrored; Toggle Hold brings back whichever of the two the key was; code `Interpolation.holdAhead`) | **Hold Ahead** | Mirrored hold, Reverse hold, helper key |
| Speed at a key relative to the segment's average | **Speed** (0 = stop, 1 = steady) | Velocity |
| How far a handle reaches along the segment | **Reach** (field label; stored as influence) | Influence |
| The speed graph / the value graph | **Speed** / **Value** (toggle) | Velocity graph, Value graph |
| A named curve shared by many keys in one project | **Linked curve** ("Soft Landing") | Shared ease, Master curve |
| Make a linked segment independent | **Unlink** | Detach, Break |
| A curve saved for all projects (a copy) | **Preset** ("Save as preset") | Favorite, Template |
| The row of one-click curves | **Chips** (UI only; never user-facing text) | Quick curves |
| Optional Library pack of the old cubic set (Sine, Quad, Cubic, Quart, Quint, Expo, Circ, Back; in, out, in-out) | **Classic** | Penner, Legacy |
| Default curve for new keys | **Default ease** (Preferences) | Default interpolation |
| Convert a live Spring into keys | **Bake to keys** | Convert, Rasterize |

Naming rules: title case as in every menu ("Smooth In", "Soft Landing"; changed 2026-10-06, was sentence case);
an empty preset name saves as "Custom curve".

One list, one order, everywhere a curve is named (keyframe right-click, transition Easing, chips, tooltips; code: SQCore
`EaseName`, `EasingCurve.displayName`; DECISIONS 2026-10-06): **Steady, Smooth, Smooth In, Smooth Out, Hold**, then the
extra presets **Fast Start, Fast End, Gentle, Smooth In 100%, Smooth Out 100%, Soft Landing**, then **Custom** ("Custom…"
opens the curve editor). Never "Ease in 33%" and the like: those are stored names only.

Motion effect Curve list (`MotionCurve.title`, order fixed by the stored raw value): **Gentle, Smooth, Auto**, the list
above, **Spring**, then the strength families, each as "<Word> Out" (slow start), "<Word> In" (slow arrival) and the bare
word (both): **Soft** (was Sine), **Light** (Quad), **Firm** (Cubic), **Strong** (Quart), **Heavy** (Quint), **Sharp**
(Expo), **Round** (Circ); **Wind-Up, Overshoot, Wind-Up Overshoot** (Back); **Spring Out, Spring In, Spring In Out**
(Elastic); **Bounce Out, Bounce In, Bounce**. "In" and "Out" always mean the same as in Smooth In / Smooth Out, which is
the reverse of the CSS names (CSS "Sine In" starts slowly: here "Soft Out").

## Trim mode (DECISIONS 2026-10-03)

| Concept | Use | Do not use |
|---|---|---|
| The cut between two clips | **Edit** | Edit point, Cut |
| The mode and its two-up view | **Trim mode** | Trim Monitor |
| Ripple the clip ending at the edit / starting at it / roll the edit | **Before** / **After** / **Both** | Ripple out, Ripple in, Roll |
| Result lines | "Moved edit +2 frames", "Trimmed -1 frame" | "Rolled", "Rippled" |


## Naming pass (DECISIONS 2026-10-03)

Rule of thumb: keep a name when it is plain English and used the same way everywhere; rename when it is a Premiere product
word (Ultra Key, Lumetri, Razor, Lift, Nest, Bin) or when two names exist for one concept. Video/Audio stay as the side words.
Already good and kept: Presets, Library, Project, Timeline, Program, Source, Scopes, Graphics, Controls, Sequence, Marker, Keyframe,
Insert, Overwrite, Snap, Group, Link, Slip, Slide, Mark In/Out, Export, Quick Export, Export Frame, Poster Frame, Offline, Relink-free
words like Reveal in Finder, Opacity, Position, Rotation, Crop, Sharpen, Mirror, Glow, Vignette, Grain, Posterize, Mosaic, Tint,
Distort, Transform, Stylize. Render has no user-facing name (no change). Marker/export terms need no change.

### Effects panel bins

| Concept | Use | Do not use |
|---|---|---|
| Top-level bin of picture effects | **Video** | Video Effects |
| Top-level bin of picture transitions | **Transitions** | Video Transitions |
| Top-level bin of sound effects | **Audio** | Audio Effects |
| Top-level bin of sound transitions | **Crossfades** | Audio Transitions |
| Blur effects | **Blur** | Blur & Sharpen (Sharpen moves into Adjust) |
| Transparency effects | **Cutout** | Keying |
| Grain and noise | **Grain** | Noise & Grain |
| Color-tweak effects (also Invert, Black & White) | **Adjust** | Color Correction, Image Control, Channel |
| Parametric motion effects (also Bounce, Pulse, Wiggle) | **Motion** | Loop Animators |
| Drop Shadow's bin | **Stylize** | Perspective |
| Sound level effects | **Level** | Amplitude and Compression |
| Sound tone effects | **Tone** | Filter and EQ |
| Sound repair effects | **Cleanup** | Noise Reduction/Restoration |

### Effect and transition names

| Current | New | Do not use |
|---|---|---|
| Ultra Key | **Color Key** | Ultra Key, Chroma Key, Color Key |
| Alpha Adjust | **Transparency** | Alpha Adjust |
| Track Matte Key | **Track Mask** | Track Matte, Track Matte Key |
| Gaussian Blur | **Blur** | Gaussian |
| Strobe (effect) | **Strobe Light** (matches its kind; the Strobe Cut transition and Flash stay separate) | Strobe |
| Tint (effect: two-color map) | **Duotone** (the grade's Tint slider keeps its name) | Tint |
| Hard Limiter | **Limiter** | Hard Limiter |
| Parametric EQ / Parametric EQ (5 Band) | **EQ** (one EQ in the catalog; the 3-band is hidden) | Parametric, EQ (5 band) |
| Cross Dissolve | **Dissolve** | Cross Dissolve |
| Dip to Black / Dip to White | **Through Black** / **Through White** | Dip |
| Constant Power | **Smooth Crossfade** | Constant Power |
| Constant Gain | **Steady Crossfade** | Constant Gain |

### Effect parameter labels (Effect Controls)

| Current | New | Do not use |
|---|---|---|
| Blurriness / Amount of Noise / Sharpen Amount | **Amount** | Blurriness, Amount of Noise |
| Blur Length | **Length** | Blur Length |
| Spill Suppression | **Spill** | Spill Suppression |
| Choke | **Shrink** | Choke |
| Pedestal | **Black level** | Pedestal |
| Reflection Angle | **Angle** | Reflection |
| Horizontal Blocks / Vertical Blocks | **Columns** / **Rows** | Blocks |
| Anchor Point | **Anchor** | Anchor Point |

### Color panel sections (Lumetri words)

| Current | New | Do not use |
|---|---|---|
| Basic Correction | **Basic** | Basic Correction, Lumetri |
| Creative | **Look** (DECISIONS 2026-10-10 supersedes the 2026-10-09 "Creative") | Creative (as the section name) |
| Look (LUT row inside it) | **Look LUT** | Look (twice) |
| Color Wheels & Match | **Wheels & Match** | Color Wheels |
| HSL Secondary | **Color Range** | HSL Secondary |
| Faded Film (already shown as Fade) | **Fade** (kept) | Faded Film |

### Color Pro mode (DECISIONS 2026-10-09)

| Concept | Use | Do not use |
|---|---|---|
| The two exclusive grades of a clip | **Simple** / **Pro** (header switch) | Basic/Advanced, Lumetri/Nodes |
| The Pro grade: In LUT, a chain of steps, Out LUT | **Color Graph** | Node graph, Node tree, Node editor |
| One grading pass in it | **Step** | Node, Serial node, Corrector |
| A side chain mixed back in (phase 2) | **Branch** | Parallel node, Splitter/Combiner |
| How a Step or Branch blends over the image below (phase 2) | **Layer mix** | Layer mixer, Layer node |
| Saved stills and grades to compare or reuse (phase 2) | **Gallery** | Stills gallery, PowerGrade |
| Effect Controls button on the Color effect row that opens its grade on the Color page | **Adjust** (button; the Effects bin keeps its name) | Open in Lumetri, Edit grade |

### Effect Controls, clips and speed

| Concept | Use | Do not use |
|---|---|---|
| Position/scale/rotation group (Paste Attributes group, Graphics header) | **Transform** | Motion |
| Paste only chosen parts of a clip | **Paste Settings** (replaces Paste Attributes) | Attributes |
| Speed ramp lane | **Speed Ramp** (Show Speed Ramp / Remove Speed Ramp) | Time Remapping |
| Speed dialog | **Speed...** | Speed/Duration |
| Frame handling popup in it | **Frames**: "Repeat frames" / "Blend frames" | Time Interpolation, Frame Sampling, Frame Blending |
| Scale a picture to the frame | **Fit to Frame** | Set to Frame Size, Scale to Frame Size |
| Replace the file behind a clip | **Replace Media...** | Replace Footage |
| Point a clip at its file again | **Reconnect Media...** (undo name "Reconnect Media") | Link Media, Relink Media |

### Graphics panel (audit GRAPHICS-PANEL-2026-10)

| Concept | Use | Do not use |
|---|---|---|
| The panel | **Graphics** | Essential Graphics |
| Layer list | **Layers** | |
| Align and distribute section | **Arrange** (Align To: Frame / Selection) | Align |
| Position, anchor, scale, rotation, opacity | **Transform** | Motion |
| Pivot point | **Anchor** | Anchor Point |
| Fill, outline and shadow of a shape | **Appearance** | |
| Line around a shape | **Outline** (stored key stays `shapeStroke`) | Stroke |
| Drop shadow row | **Shadow** | |
| Kept first and last part of a graphic when trimmed | **Intro and Outro** | Responsive Design - Time |
| Layer pinned to another layer or the frame | **Follow** (Follows, Edges, Padding) | Responsive Design - Position, Pin To |
| Open a graphic clip from Controls | **Edit in Graphics** | |
| Open a caption in the Text panel (caption menu) | **Edit in Text** | Return on a selected caption word edits it on the track |

### Timeline words, tools, commands

| Concept | Use | Do not use |
|---|---|---|
| Select tool and the track-select pair | **Select Tool** / **Select Forward Tool** / **Select Backward Tool** | Selection Tool, Track Select Forward |
| Ripple tool | **Ripple Tool** | Ripple Edit Tool |
| Roll tool (and its undo step) | **Roll Tool** / "Move Edit" | Rolling Edit Tool, Roll Edit |
| Cut tool | **Blade Tool** ("Blade", "Blade All Tracks") | Razor, Razor All Tracks |
| Stretch-to-speed tool | **Stretch Tool** ("Stretch") | Rate Stretch |
| Text tool | **Text Tool** | Type Tool |
| Tool slot that makes text and shapes on the picture | **Create** (modes: Text, Rectangle, Ellipse, Line, Draw) | Shape Tools, Pen Tool |
| Shape modes as commands | **Rectangle Tool** / **Ellipse Tool** / **Line Tool** / **Draw Tool** | Pen Tool, Pencil, Brush |
| One text, shape or drawing inside a Graphic clip (new UI words) | **Item** (the Graphics panel list stays "Layers") | Object, Element |
| The rows under a Graphic clip in the timeline, one per item, with the item's time inside the clip | **Item lanes** (the clip is an **opened Graphic**; the part of the clip an item shows in is its **range**, undo "Item Range") | Sub-tracks, Layer tracks, Nested timeline, Compound clip |
| Remove a range, leave a gap | **Clear Range** | Lift |
| Remove a range, close the gap | **Delete Range** | Extract |
| Cut Out command | **Cut Out (Mark Start, then Delete Range)** | ...then Extract |
| Cut between clips in command names | **Edit** (see Trim mode table) | Edit Point |
| Show the clip's source frame | **Show in Source** | Match Frame |
| Show the source frame's timeline clip | **Show in Timeline** | Reverse Match Frame |
| Keyframe ease commands | **Smooth**, **Smooth In**, **Smooth Out**, **Toggle Hold** (Easing table) | Easy Ease, Ease In, Ease Out, Toggle Hold Interpolation |
| Panel scopes in the Keyboard Shortcuts window | **Program** / **Source** / **Project** | Program Monitor, Source Monitor, Project Panel |
| Open a clip in the source view | **Open in Source** | Open in Source Monitor |
| Show captions in the program view | **Show Captions in Program** | ...Program Monitor |
| How the edge of a tracked subject mask is made (Program menu, per Mac) | **Subject Mask Edges**: **Quality** / **Speed** | Matting, Refine Edge, Hair Detail, Fine / Fast |

### Sequences, folders

| Concept | Use | Do not use |
|---|---|---|
| Replace clips by one clip holding them | **Combine...** (undo "Combine"; default name "Combined 01"; clip drawn as "combined") | Nest, Nested Sequence NN |
| Several recordings of one event cut like one clip (F7.16) | **Angles clip** ("Create Angles Clip…", default name "Angles 01"; one recording = an **Angle**, "Switch to Angle 3", undo "Switch Angle") | Multicam, Multi-Camera Source Sequence, Multicam Clip, Camera 1 |
| The sound of an Angles clip takes the angle of its picture | **Audio Follows Video** | Switch Audio, AFV |
| A flat color layer for when there is no video (solid generator; Project panel and timeline menus "New Color Matte…", Controls section "Color Matte" with one Color row; ordinary clip) | **Color Matte** (undo "Add Color Matte", "Edit Color Matte"; default name "Color Matte") | Solid, Solid Color, Color Layer, Matte (a matte is a mask elsewhere) |
| Folder in the Project panel and SFX | **Folder** ("New Folder", "Untitled Folder", "SFX folder") | Bin, New Bin |
| Saved filter of the Project panel | **Smart Folder** ("Save Filter as Smart Folder") | Smart Bin |
| Project panel grouping by day, camera or kind | **Sorted by** (Folders, Day, Camera, Kind) | Group by |

Not renamed on purpose: Sequence (also the product name), Insert/Overwrite, Ripple Delete, Slip/Slide, Marker, Safe Margins,
Poster Frame. Combine is display only: the model (`Nesting`, `nest`, ProjectFile keys) and the importer ("Nested sequence" report notes) keep their names.

## File map (apply each group in one agent; no file is in two groups)

Each agent: change only the display strings of the table rows named for its group, in the files listed, then grep those
files' tests (`Packages/*/Tests`) for the old strings and update the assertions. Where a term sits in a file owned by another
group, that group's agent changes it. Run `scripts/test.sh` per touched package. Do not touch PRMapper or other importer files.

### Group A: Effects panel, effect names, parameters, color sections, transitions
Rows: Effects panel bins, Effect and transition names, parameter labels, Color panel sections.
- Packages/SQCore/Sources/SQCore: EffectsCatalog.swift, StyleEffects.swift, AudioEffects.swift, AudioEffectsVoiceChain.swift, Transition.swift, ClipColor.swift, ColorGradeEffect.swift, ColorMatch.swift, Grouping.swift (Anchor Point label), MotionEffects.swift
- Packages/SQEditorUI/Sources/SQEditorUI: EffectFolderModel.swift, TemplateListPanelView.swift, EffectControlsModel.swift (Anchor Point), Color/ColorInspectorView.swift, Color/ColorInspectorModel.swift
- Tests: SQCore MotionEffectsTests, ClipColorTests; SQEditorUI EffectFolderTests, EffectControlsPremiereViewTests, EffectControlsAudioFXTests, EffectControlsFXTests, EffectsLookSessionTests, PresetBakeUITests, QuickApplyModelTests, TransitionViewTests, ColorInspectorModelTests, ColorPanelEditTests

### Group B: commands, menus, tools, timeline words, monitors
Rows: Timeline words/tools/commands (all of them, including Nest, Set to Frame Size, Speed/Duration, Paste Attributes and Bin titles that appear inside these shared files), Panel scopes.
- Packages/SQEditorUI/Sources/SQEditorUI: EditorCommand.swift, SQMenuModel.swift, MenuSpec.swift, TimelineContextMenu.swift, TimelineView.swift, TimelineInteraction.swift, TimelineCursors.swift, KeyboardLayoutView.swift, AppSettings.swift, MonitorPanelView.swift, MonitorPanelModel.swift, TextInspectorView.swift, Session/EditorSession.swift, Session/EditorSession+TimelineOps.swift, Session/EditorSession+Trim.swift
- Packages/SQCore/Sources/SQCore: KeyframesPremiere.swift, MotionEasing.swift, Timeline+EditTargets.swift
- App/Sources: MenuBuilder.swift, AppController+Commands.swift, AppController+Captions.swift
- Tests: SQEditorUI KeymapStoreTests, TimelineInteractionTests, TrimModeModelTests, TimelineEdgeGapTests, EditTargetRulesSessionTests, SQMenuTests, CommandParityTests, TimelineCaptionMenuTests, SequenceTabsTests; SQCore KeyframePremiereTests, KeyframeEaseSelectionTests, IdStabilityTests

### Group C: speed, paste settings, media, combine, folders, Transform
Rows: Effect Controls clips and speed, Sequences/folders (the files below only; the shared command and menu files belong to B).
- Packages/SQCore/Sources/SQCore: Nesting.swift, Bin.swift, Project+MediaOps.swift, FrameScale.swift, Timeline+MatchFrame.swift, Timeline+SourceEdit.swift, Timeline+Speed.swift, SpeedKeys.swift, SpeedKeysEditing.swift, EffectsEditing.swift
- Packages/SQMedia/Sources/SQMedia: Relink.swift
- Packages/SQEditorUI/Sources/SQEditorUI: ProjectPanelView.swift, ProjectPanelModel.swift, Library/LibraryPanelView.swift, Library/LibraryPanelModel.swift, Library/LibraryPanelModel+SFX.swift, SpeedDurationSheet.swift, SpeedDialogModel.swift, SpeedBand.swift, SpeedRampEaseSource.swift, PlainEasingEditorSource.swift, TimelineView+SpeedBand.swift, ToolState.swift, PasteAttributesDialog.swift, PasteAttributesSelection.swift, ClipDrawing.swift, Graphics/GraphicsPanelView.swift, Session/EditorSession+Speed.swift, Session/EditorSession+SpeedBand.swift, Session/EditorSession+Effects.swift, Session/EditorSession+SourceEdit.swift, Session/EditorSession+Shell.swift
- App/Sources: EditorPanels.swift, EditorPanels+SpeedBand.swift, AppController+Speed.swift, AppController+Relink.swift, AppController+EffectsLook.swift, AppController.swift
- Tests: SQCore NestingTests, NestedEffectsTests, FrameScaleTests, MasksTests; SQEditorUI ClipSpeedUITests, TimeRemapSessionTests, RelinkSessionTests, EditorSessionTests, PendingScaleSessionTests; SQLibrary PresetStoreTests

### Redundancy audit vocabulary pass (DECISIONS 2026-10-07)
One spelling for our own color words: **Color** (Color effect, Color Key, Color Range, Color Strength, Color Page,
Use Color Noise). Kept as technical terms: Color Space, Color Burn/Dodge, the `color` blend mode. Live Ducking (setting, track
flag) and **Bake Live Duck to Keys** (command, undo name) are the one duck label set; Auto Duck is the baked-key run only.

### Fast Cut (DECISIONS 2026-10-07 Fast Cut)
Own words, no Premiere or Final Cut names: **Normal** and **Fast Cut** (sequence edit mode; Shift+G toggles it, replaces
Glue), **main track** (V1 in Fast Cut), **attached clip** (a clip on another track that follows a main-track clip),
**attach thread** (the thin line from an attached clip to its host), **attach point** (where on the host it hangs),
**Spacer** (a deliberate hole on the main track). Commands: Append to Main Track, Insert Spacer, Lift off Main Track,
Put on Main Track, Set Attach Point, Move Clip Left/Right, Delete Selection Only. Preference: "New Sequences Start in" Normal | Fast Cut.

- Zero point (Position, Anchor): the frame center, Y up; Rotation counterclockwise positive (display only; the design notes 2026-10-12 Value display).
- Several takes of one performance on stacked tracks, one picked for a range: **Take** ("Use Take for In to Out": the other takes are off in the range). Not Comp, Comping lane, Playlist.
