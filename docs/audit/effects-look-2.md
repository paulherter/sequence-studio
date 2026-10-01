# Audit round 2: effects-look (stream 5, project file v22)

Adobe checks are grep results in `docs/reference/adobe/*.txt` (no text copied). "verified" = confirmed there, "corrected" = the plan row was wrong, "not in guide" = could not be verified.

| Feature | Premiere | Sequence Studio now | Gap | Done |
|---|---|---|---|---|
| [1] Fade In/Out | no single command; keyframes or transitions | Clip > Video Options > Fade In / Fade Out: opacity keys, 1 s, clamped to half the clip, undo one step. Audio fade is stream 3 | audio part | yes (video) |
| [2] Frame hold | Add Frame Hold (Cmd+Shift+K), Insert Frame Hold Segment (2 s) (verified, freeze-frame.txt) | both in Clip > Video Options. Held clip = `Clip.holdFrame`, grows freely, keys frozen. Add = rest of clip frozen, no ripple; Insert = split + 2 s, ripple | no key binding (Cmd+Shift+K left out: not bound by other streams yet), no Hold On dialog / Hold Filters | yes |
| [3] Second instance, reorder | apply again adds an instance; drag to reorder | any effect can be applied repeatedly (instances by id), drag a header to reorder, one undo step, list order = evaluation order | none | yes |
| [15] Gaussian Blur | Blurriness | Blurriness (px sigma), animatable, 0 = identity, CPU + Metal, large sigma runs reduced | no Blur Dimensions / Repeat Edge Pixels | yes |
| [16] Crop | separate effect | Crop effect, Left/Top/Right/Bottom %, animatable, 100 % total = layer skipped, CPU + Metal | no Zoom / Edge Feather | yes (separate effect, as decided) |
| [17] Blend modes | list: Normal, Dissolve, Darken group (Multiply...), Lighten group (Screen, Linear Dodge (Add)...), Overlay group (verified, blending-modes.txt) | Normal, Multiply, Screen, Linear Dodge (Add), Overlay in that order; math in linear light, so Overlay differs from Premiere near mid grey | other 20 modes, Dissolve; nested-clip blend | yes |
| [22] Paste Attributes | Motion, Opacity, Time Remapping, Volume replace; other effects are added; keys land at the same clip-local position (verified, applying-removing-finding-organizing-effects.txt) | Cmd+Opt+V: motion, opacity, blend, volume, colour replace; effects added with new ids | the guide mentions no dialog: none built. No Remove Attributes. Time Remapping n/a | yes |
| [27] fx badge | corrected: guide describes only dim (no effects, "disabled") and bright white (effect applied), underlined for source effects, top right of the clip; no purple/yellow (fx-badges.txt) | bright badge drawn when something is applied (effects, changed Motion/Opacity, blend, colour, hold). Dim state not drawn (quiet timeline) | click opens Effect Controls, right-click list not built | yes |
| [25] fx toggle Motion/Opacity | fx button on fixed effects | fx button on Motion and Opacity (`Clip.motionEnabled/opacityEnabled`, renders at defaults) | Volume has none | yes |
| [26] Cut/Clear | effect header menu | header menu: Disable, Cut, Copy, Paste, Clear, Reset, Duplicate Effect | none | yes |
| [24] Ultra Key | many controls | compact: Key Hue, Tolerance, Soften, Spill Suppression; 2 keys per clip; CPU + Metal | no matte cleanup, choke, pedestal | yes |
| Opacity band | rubber band, Cmd-click key | line on video clips (selected, keyed or not 100 %), drag, Cmd-click adds one key with the shown value | | yes |
| Existing (regression tests only) | keyframe copy/paste, key menu, uniform scale, effect copy/paste, effects search, speed rescales keys | already built; tests added for speed/split/trim key rescale of effect keys | | tests |
| Sharpen | | not built | | no |

Not verified: Cmd+Shift+K availability in our map, exact Ultra Key defaults.
