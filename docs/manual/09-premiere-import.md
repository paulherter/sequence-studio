# Importing Premiere Projects

Open a Premiere Pro project (.prproj) or its effect presets in Sequence Studio, and see what came over.

Premiere import is experimental. It covers a subset of the features, and the import report tells you what was left out.

## Import a project

1. Choose File > Import Premiere Project….
2. Pick the .prproj file.
3. When it finishes, a report appears. Read it, then click Done.

You can open the report again later with File > Project > Import Checklist…. This menu item is only on after a Premiere import.

## What works

| Premiere | In Sequence Studio |
|---|---|
| Folders, media, sequences, tracks and cuts | Yes |
| Nested sequences | Yes |
| Speed changes (also reverse) | Yes |
| Freeze frames, time remapping | Only from XML, EDL and OTIO files, not from the .prproj |
| Position, scale, rotation and opacity, with keyframes | Partly |
| Basic color corrections (temperature, tint, exposure, contrast, saturation and more) | Partly |
| Cross dissolves and fades | Yes |
| Text and graphics clips | Partly |
| Audio gain, track volume, pan, mute | Yes |
| Noise Reduction, Multiband Compressor, Parametric EQ | Yes |
| Markers | Yes |
| Offline media | Kept, so you can reconnect it |

## What does not come over

Warp Stabilizer, 3D effects and Track Matte are not imported yet. Masks, some shapes and graphic groups are only approximated, and a Mirror that follows a scaled Transform is dropped (the import report says so). Adjustment layers, Mosaic and other Mirror effects do come over. Effects Sequence Studio does not have are left out.

## The import report

The report is a list of rows with a colored dot for each item. It tells you what came over as is, what was approximated, what was left out and what could not be found. Rows that can act have buttons:

- **Show** jumps to the affected clip. Click again for the next one.
- **Reconnect…** opens the dialog to find missing media.

Save Report… writes the list to a text file. If everything came over, the report says "Everything came over as is."

## Reconnect missing media

Premiere projects point to files by path. If the files moved, choose File > Project > Reconnect Media… and pick the folder that holds them.

## Import effect presets

1. Choose File > Import Premiere Presets….
2. Pick your Premiere presets file (Effect Presets and Custom Items.prfpset).
3. The presets appear in your preset list.

Presets that need an effect Sequence Studio does not have, and empty presets, are skipped, with the reason in the report. Some values are approximated when the preset was made for another frame size.

## Import a motion graphics template

See [Titles and Captions](06-titles-and-captions.md).

## Import keyboard shortcuts

If you also want your Premiere keys, Window > Keyboard Shortcuts > Import Shortcuts… reads Premiere .kys files. See [Shortcuts](11-shortcuts.md).

## Not sure yet

- The complete list of Premiere effects that are supported.
- Whether the import menu items are present on Windows and Linux.
- Clip label colors do not come over: neither the .prproj nor the interchange import reads them.

Related: [Editing](02-editing.md), [Titles and Captions](06-titles-and-captions.md), [Shortcuts](11-shortcuts.md), [Troubleshooting](12-troubleshooting.md)
