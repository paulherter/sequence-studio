# Color

How to correct and grade your footage: the Simple grade, the Pro grade, scopes, LUTs, Match Color, and a step-by-step grading workflow.

## The basics

Color work has two goals:

1. **Correct**: make the picture look right (good exposure, neutral white, natural skin).
2. **Grade**: give it a look (warmer, moodier, faded).

Do them in that order. Correct first, then grade.

### Where to work

- The **Color** panel (Window > Color) holds all grading controls.
- The **Scopes** panel (Window > Scopes) shows measurements of the picture.
- There is also a **Color Page**. Switch between the **Edit Page** and the **Color Page** with the page switch. The Color Page shows the Color panel, the **Sources** panel (your clips and their grade state), the **Steps** panel (for the Pro grade) and the Scopes together.

Grading is stored as a **Color** effect on the clip, so it also shows up in Controls. Its **Adjust** button opens the grade on the Color Page.

## Simple grade and Pro mode

Every clip has one grade of two kinds. At the top of the Color panel you choose **Simple** or **Pro**. They are exclusive: a clip uses one or the other.

| | Simple | Pro |
|---|---|---|
| What it is | A fixed list of sections with sliders, wheels and curves | A **Color Graph**: a chain of **Steps** |
| Best for | Fast fixes and looks | Complex grades, isolated corrections |
| Start with | Just open it | Choose **Pro** in the Color panel |

### Simple: the sections

Each section has its own on/off switch and a **Reset Section** command.

| Section | What is in it |
|---|---|
| Basic | Temperature, Tint, Exposure, Contrast, Highlights, Shadows, Whites, Blacks, Vibrance, Saturation |
| Creative | **Look LUT** with Intensity; Fade, Vibrance, Saturation, Tint Balance; Shadow Tint and Highlight Tint wheels |
| Curves | Luma, Red, Green and Blue curves; Hue Saturation curves (Hue vs Hue, Hue vs Sat, Hue vs Luma, Luma vs Sat, Sat vs Sat) |
| Wheels & Match | Shadows, Midtones and Highlights wheels with luma sliders, Wheels Saturation, and **Match** |
| Zone Board | Four zones (Global, Shadows, Midtones, Highlights), each with a color puck, exposure and saturation |
| Color Range | Pick a color and limit a grade to it (Tolerance, Softness, Invert) |
| Vignette | Amount, Midpoint, Roundness, Feather |

**Auto Tone** (in the section menu) sets Exposure, Contrast, Whites and Blacks for you. It works on normal Rec. 709 footage with only Basic switched on.

### Pro: the Color Graph

The Color Graph is a chain. It begins with an **In LUT**, runs through your Steps, and ends with an **Out LUT**.

- A **Step** is one grading pass. Each Step has its own wheels, curves, a **Qualifier** (pick a color range), a **Window** (limit it to a shape) and a matte view (**Show Step matte**).
- Add steps with **Add Serial Step** (in a line), **Add Parallel Step** (a side chain mixed back in) or **Add Layer Step** (blended over the image below).
- **Tidy Up** arranges the graph.

How to start a Pro grade:

1. Select a clip and open the Color panel.
2. Choose **Pro**.
3. On the Steps panel choose **Start empty**, or **Start from Simple grade** to carry your Simple values over.
4. Add Steps as you need them.

You can go back with **Use Simple Grade**.

## Scopes

Your eyes can be fooled by your screen and the room. Scopes measure the picture.

Open **Window > Scopes** and pick a scope from its popup:

| Scope | Use it to |
|---|---|
| Waveform | Check brightness. Blacks sit near the bottom, whites near the top. Don't clip either end. |
| Parade | See red, green and blue side by side. If the three look alike for a gray area, the white balance is right. |
| Vectorscope | See color strength and hue. Skin tones land along a line (the skin tone legend). |
| Histogram | See how brightness is spread. |

The Scopes panel also works on the Edit Page: open it from **Window > Scopes** and it docks like any other panel. It measures the Program monitor. When the Source monitor is the active panel, it measures the Source picture instead and the panel header says SOURCE.

Open a sequence first: the panel says "Open a sequence to see its scopes" otherwise.

## LUTs

A LUT is a saved color look. It maps input colors to output colors. We read `.cube` LUT files.

### How to add and use a LUT

1. In the Color panel pick **Look LUT** (Creative section), then **Choose File...** and select a `.cube` file.
2. Or use **Add LUTs to Library...** to import one or more LUT files into your LUT library and keep them for later. Mark a LUT with the star to make it a **Favorite**.
3. Use **Intensity** to blend the look in. **Clear LUT** removes it.

There is also a **Source LUT** (it converts camera footage first, with its own Source LUT Intensity). If a LUT was made for a different color space, a **LUT color space mismatch** hint warns you.

Use a Source LUT to turn flat log footage into a normal picture. Use a Look LUT for the creative look.

## Match Color

Match Color makes one clip look like another, for example when two shots of the same scene have different color.

### Match Color to Clip (one step)

1. Select the clip to change (the target).
2. Choose **Clip > Video Options > Match Color to Clip**.
3. The reference is the clip under the playhead on another video track, or the clip before the target on its own track.
4. The app measures both and sets the target's Wheels & Match.

### Set Reference and Match (two steps)

1. Park the playhead on the shot you want to look like.
2. In the **Wheels & Match** section press **Set Reference**.
3. Select the clip to change, put the playhead on it, and press **Match**.

The reference is stored with the clip, so you can delete the reference shot later.

Match needs Wheels & Match switched on, Rec. 709 footage and Vignette off. It tries to protect skin tones. Use the wheels afterwards to fine tune.

## A practical grading workflow

Start simple. Add depth only when you need it.

### Level 1: basic fix (2 minutes)

1. Open the Waveform scope.
2. In **Basic**, set **Exposure** so the main subject sits in a good brightness range.
3. Set **Contrast**, then pull **Whites** and **Blacks** until the waveform fills the range without squashing against the edges.
4. Fix the white balance with **Temperature** and **Tint**. Use the white balance picker on something that should be gray or white.
5. Check the Parade: the three channels should line up on neutral areas.

### Level 2: match your shots

1. Grade one good shot first.
2. For the other shots in the scene use **Match Color to Clip**.
3. Check cuts by playing across them.
4. To use one grade on many clips: **Copy Grade**, then **Paste Grade**, or **Link Grade to Selected Clips**. **Link All Clips of This Source** links every clip from the same media file.

### Level 3: add a look

1. In **Creative**, choose a Look LUT and set Intensity low (30 to 60 percent).
2. Use **Fade** to lift the blacks for a soft film feel.
3. Use the Shadow Tint and Highlight Tint wheels for a split tone (for example cool shadows, warm highlights).
4. Add a gentle **Vignette**.

### Level 4: fix one thing

Use **Color Range** to select just the sky, a shirt or skin. Pick the color, widen Tolerance until the selection is clean, then add Softness. Change only that area.

### Level 5: deeper control

1. Use **Curves** for fine contrast, or Hue vs Sat to calm one color.
2. Use the **Zone Board** to push shadows and highlights apart.
3. For hard jobs choose **Pro** and build Steps: one for balance, one for skin, one for the sky, one for the look. Use a Step's Qualifier or Window to limit it.

### Tips

- **Compare** shows your grade next to the original.
- **Bypass** turns a grade off to compare.
- Grade on the Color Page when you have a lot of clips. Use the Sources panel to see which clips are graded.
- Watch the scopes more than your eyes. Re-check after a break.

## Not sure yet

- Whether the section header shows "Creative" or "Look" in every build.
- Whether Auto Tone, Match and the Pro Color Graph behave exactly the same on Windows and Linux.
- How the Hue Saturation curves are named in the curve menu.
- The exact list of input color spaces and HDR options (Interpret As, Log Handling, HDR Conform).
- Whether the Color Page layout is the same on Windows and Linux.

Related: [Effects and motion](03-effects-and-motion.md), [Masks and tracking](05-masks-and-tracking.md), [Editing](02-editing.md)
