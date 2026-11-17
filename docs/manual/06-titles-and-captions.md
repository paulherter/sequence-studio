# Titles and Captions

How to add text, style it, use title templates and motion graphics templates, and make captions from speech.

## Add text

1. Press Command-T (Windows and Linux: Ctrl+T) to add a title. It adds two title lines with a move-in and a fade, and you edit the words in the Controls panel.
2. Or choose the Text tool (T) and click in the Program monitor.
3. Select the text clip. Open the Controls panel (Shift-5) and find the Text section.

New text starts with the placeholder "Your text". Its length is set in Settings > General > New Text Length.

## Text layout and style

The Text section of the Controls panel has:

- **Font** and weight (Thin, Light, Regular, Medium, Semibold, Bold, Heavy, Black), and Size.
- **Style** toggles: Bold, Italic, All Caps, Underline, Strikethrough, Overline.
- **Alignment**: horizontal and vertical, text direction (left to right or right to left), line spacing and tracking.
- **Look**: a saved style you can apply in one click.
- **Fill** (color, footage or invert, with opacity) and **Gradient**.
- **Outline** (width, and position outside or middle).
- **Background** (opacity, padding across and down, corner radius).
- **Shadow** (opacity, angle, distance, size, blur).
- **Second Line**: its own font, size and color, for two-tier titles.
- **Shrink to Box**, **Arrange** (align to the frame), and **Intro** and **Outro** animations with their lengths.

## Fonts

Sequence Studio comes with these fonts: Inter (the default), Anton, Archivo Black, Bangers, Bebas Neue, Bowlby One, Bungee, Caveat, DM Serif Display, Fredoka, Knewave, League Spartan, Lilita One, Lobster, Montserrat, Oswald, Outfit, Pacifico, Passion One, Playfair Display, Poppins, Righteous, Rubik, Russo One, Sigmar One and Space Grotesk. They are free fonts under the SIL Open Font License.

You can also use the fonts installed on your computer, on all three systems. A font of the same name as a bundled one is taken from the bundle.

## Text looks

The text looks are grouped by use:

| Group | Looks |
|---|---|
| TikTok | Classic Outline, Yellow Caps, Highlight Box, Comic Pop |
| YouTube | Reaction Bold, Caption Bar, Red Flag, Clean Shadow |
| Professional | Lower Third, Minimal Caps, Dark Box, Editorial Serif |
| Titles | Tall Title, Poster Bold, Display Serif, Heavy Geometric |

Text motions include Pop, Bounce, Jolt and Pop Out (TikTok) and Slide Up and Slide From Left (YouTube).

## Title templates

Open the Library, switch to **Presets** and pick the **Text** chip. It holds caption styles, "Title 2-Tier" (small spaced capitals over a big heavy second line), "CTA End Card" (a 4 second end card with a bell icon), and built-in stickers and lower thirds. Double-click one to place it at the playhead, or drag it to the timeline.

## Import a motion graphics template

1. Choose File > Import Motion Graphics Template…, or drop a .mogrt file on the Library panel.
2. Open Library > Titles. The template is there as a title template.

Templates made with a video editor's own text and shape tools can be imported. Rectangles and ellipses come over as shapes; a shape shadow is dropped. Templates made in After Effects cannot be imported yet, and you will see a message saying so. You may also see "This file is not a Motion Graphics Template (.mogrt).", "contains no graphic to import", "is damaged and could not be read", or "has no text layer that can be imported".

## Make captions from speech

1. Open the Captions panel (Shift-8) and choose the Transcript tab (Step 1 of 2: Transcribe writes down what is said). Step 2 is Create Captions…, which makes the captions from the transcript.
2. Pick the language. The menu shows full language names in the language of the interface, some with a region, for example "English (United States)". The most common languages come first (English, German, Spanish, French, Italian, Portuguese, Dutch, Polish, Turkish, Russian, Japanese, Chinese, Korean, Arabic, Hindi), then a line, then every other language the speech model knows, in alphabetical order. Every language of the speech model has a name there, not a code.
3. Click Transcribe. The button reads "Transcribing…" while it works. If it fails, it reads "Try Again". Afterwards it reads "Transcribe Again".
4. Read the transcript. Words the engine is unsure about are marked. Click a word to edit it. Return or Esc keeps the edit; Undo reverts it.
5. Click Create Captions…. Choose a Style, the number of Characters (8 to 100), Lines (One or Two), Min. Duration and Caption Gap. Click Create.

The whole sequence is transcribed. Transcribing again replaces the transcript, including your edits. Your media does not change. If the timeline changed after transcribing, the panel tells you to transcribe again. You can also use Option-Command-C (Windows and Linux: Ctrl+Alt+C) for Transcribe and Create Captions.

You can search the transcript with Find in transcript, step with Prev and Next, and use Mark All to put a marker at every match.

### Which engine

Transcription runs on your own computer, on Mac, Windows and Linux alike, using the Whisper small model (multilingual). The model is about 249 MB. It is downloaded the first time you transcribe. If a language is not supported, you see "Speech recognition does not support the language X."

Every word gets its own start and end time from the audio, so word highlight and word-by-word captions follow the speech. A model that was downloaded by an earlier version keeps working, with estimated word times, and is not downloaded again on its own. If the download fails you see "The language model could not be downloaded". If the speech engine is missing you see "The speech engine is not available".

Your audio is not sent anywhere.

## Caption styles

Two caption styles come with the Create Captions dialog:

| Style | What it does |
|---|---|
| Standard | Up to 42 characters and 2 lines per caption, up to 6 seconds, at least 1 second. |
| Short Video | 11 characters, one line, one word per caption, with a pill highlight. |

The Style tab changes how captions look. A style is only a start: a tile sets the look (it keeps your animation), and every control stays open below in three sections you can fold: Look, Layout and Motion. You can apply it to All Captions or only the Selected ones. Looks include Title, Classic, Bold Box, Outline, TikTok, Pill, Yellow, Lower Third and Minimal. Look has the text style (font, fill, outline, background, shadow) and Word Highlight, Layout has the position, and Motion has the Animation. Save as New Style… keeps your style for later. Your saved styles show first as MINE, above the BUILT IN ones. Click a saved style to use it on every caption; the star on it makes it the default for Create Captions (click it again to clear it). When you change something under a picked style, an amber "● Edited" appears and the button reads Update “Name”, which writes the change into that style.

## Edit captions

The Captions tab shows all captions. Double-click a caption's timecode to type a new start time, for example 00:00:02:00: the caption moves there and keeps its length, and its neighbors and the start of the sequence stop it. Double-click the text to edit the words. Use Find, Replace With, Replace All and Match Case to fix words. Right-click a caption, or the empty space of the list, for: Edit in Text, Split Caption at Playhead, Merge Captions, Look, Reset to Track Look, Tidy for Short Video, Add Caption at Playhead, New Caption Track, Import Subtitles…, Export SRT… and Delete.

## Import subtitles

In the Captions tab right-click the list and choose Import Subtitles…, or use **File > Import** (or drag the file into the window). Sequence Studio reads .srt, .vtt, .ass and .ssa files. Choose Export SRT… to save the captions as an .srt file. To save an .srt next to a video when you export, see [Export](08-export.md).

Use View > Show Captions in Program to turn captions on or off in the Program monitor.

## Not sure yet

- Whether the speech engine is complete in every package (Windows installer, Linux AppImage). If it is missing you see "The speech engine is not available".
- Whether the offline translation models (Translate Captions downloads about 105 MB per language direction on first use) ship in every package (Windows installer, Linux AppImage).
- How well text in right-to-left and complex scripts, and ligatures, draw. Text is laid out letter by letter for now.

Related: [Editing](02-editing.md), [Export](08-export.md), [Audio](07-audio.md), [Shortcuts](11-shortcuts.md)
