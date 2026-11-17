// Swift: LocalizationCounts.swift
//! Plural forms and undo-step names. Both take English text as the key, like `SQL10n::string`. The key lists are the
//! exact English strings the German catalog must cover (`SQL10n::required_keys`).

use crate::localization::SQL10n;
use sq_core_time::text::graphemes;

impl SQL10n {
    /// Undo-step name patterns the inspector builds from a verb and a (separately translated) parameter name. `%@` stands for the parameter or effect name.
    pub const UNDO_PATTERNS: &[&str] = &[
        "Change %@",
        "Reset %@",
        "Remove %@",
        "Unlink %@",
        "Link %@",
        "Add %@",
        "Edit %@ Keyframes",
        "Set %@ Ease",
        "Animate %@",
        "Stop Animating %@",
        "Add %@ Keyframe",
        "Remove %@ Keyframe",
        "Change EQ %@",
        "Reset EQ %@",
        "%@ (Linked)",
        "Apply Preset “%@”",
        "Caption Look %@",
        "Add %@ Layer",
        "Apply Motion “%@”",
        "Apply %@",
        "Reset %@ to Automatic",
        "Transition Layer %@",
        "Undo %@",
        "Redo %@",
    ];

    /// Whole undo names (no parameter inside).
    pub const UNDO_NAMES: &[&str] = &[
        "Add Mask",
        "Edit Curves",
        "Add Mask Vertex",
        "Add Keyframe",
        "Uniform Scale",
        "Set Grade Range",
        "Set Grade Fade",
        "Reorder Effects",
        "Remove Keyframes",
        "Remove Keyframe",
        "Paste Effect",
        "Move Mask Vertex",
        "Move Keyframe",
        "Match Color",
        "Mask Cuts Picture",
        "Invert Mask",
        "Grade Whole Clip",
        "Duplicate Effect",
        "Delete Masks",
        "Delete Mask",
        "Delete Mask Vertex",
        "Delete Keyframes",
        "Change Transform",
        "Change Mask Track",
        "Change Mask Mode",
        "Change Mask Channel",
        "Change Blend Mode",
        "Change Motion Duration",
        "Multiband Preset",
        "Add Effect",
        "Add Text",
        "Align Layers",
        "Arrange Layers",
        "Blend Mode",
        "Delete Layers",
        "Distribute Layers",
        "Duplicate Layers",
        "Follow Edges",
        "Follow Padding",
        "Group Layers",
        "Move Layers",
        "Opacity",
        "Remove Effect",
        "Rename Group",
        "Rename Layer",
        "Resize Layer",
        "Shape Kind",
        "Ungroup Layers",
        "Mark Search Hits",
        "Color Graph",
    ];

    /// Undo names the session and editor packages build themselves.
    pub const SESSION_UNDO_NAMES: &[&str] = &[
        "Add Adjustment Layer",
        "Add Caption",
        "Add Caption Track",
        "Add Clip Marker",
        "Add Color Matte",
        "Add Format",
        "Add Graphic",
        "Add Lottie Animation",
        "Add Rounded Corners",
        "Add Speed Keyframe",
        "Add Stabilizer",
        "Add Tone",
        "Apply Look",
        "Audio Follows Video",
        "Caption Look",
        "Caption Style",
        "Change Format",
        "Change Motion Length",
        "Change Label",
        "Change Media Setting",
        "Change Shape",
        "Change Stinger",
        "Change Transition",
        "Change Transition Layer",
        "Clear In",
        "Clear In and Out",
        "Clear Marker",
        "Clear Out",
        "Clear Transition",
        "Close Gap",
        "Combine",
        "Convert to Keyframes",
        "Cut Out",
        "Cut Out Start",
        "Cut at Scene Changes",
        "Delete Captions",
        "Delete Clip Marker",
        "Delete Empty Text",
        "Delete Spacer",
        "Delete Track",
        "Delete Word",
        "Duplicate as Format",
        "Dynamic Zoom",
        "Edit Caption",
        "Edit Clip Marker",
        "Edit Color Matte",
        "Edit Marker",
        "Edit Template",
        "Insert Title Block",
        "Insert Title Template",
        "Insert Voiceover",
        "Join Captions",
        "Jump Cut",
        "Link Grades",
        "Move Caption",
        "Move Clip Marker",
        "Move In and Out",
        "Move Marker",
        "Move Transition Cut",
        "Move into Sync",
        "Move to Folder",
        "New Sequence",
        "New Sequence From Clip",
        "Nudge Clips",
        "Propose Cuts",
        "Re-open as Effect",
        "Reject Proposed Cuts",
        "Remove Duck Keys",
        "Remove Format",
        "Remove Speed Keyframe",
        "Replace Caption Text",
        "Replace Clip",
        "Replace Media",
        "Reset Caption Position",
        "Resize Transition Layer",
        "Restore Autosave Version",
        "Reverse Speed",
        "Rolling Shutter",
        "Sequence Settings",
        "Set Audio Channels",
        "Set Deinterlace",
        "Set Pixel Aspect",
        "Set Zone Middle",
        "Slide",
        "Slip",
        "Slip into Sync",
        "Speed Ramp",
        "Speed Transition Curve",
        "Split Caption",
        "Switch Angle",
        "Tidy Captions",
        "Track Role",
        "Transition Layer Alignment",
        "Transition Layer Duration",
        "Unlink Grades",
        "Unnest",
        "Use Take",
        "Whoosh at Cuts",
        "Original",
        "Ripple Delete",
        "Delete Range",
    ];

    /// Engine-made error text and session status lines (shown through lastError, the status bar and the Captions panel).
    pub const STATUS_KEYS: &[&str] = &[
        "Open a sequence first.",
        "There is no video track for the shape.",
        "Open a clip in the Source view or select media in the Project panel first.",
        "Nothing to append.",
        "Appended to the main track.",
        "Appended %@ clips to the main track.",
        "Spacer inserted.",
        "No spacer inserted.",
        "Select clips first.",
        "Nothing replaced.",
        "Replaced with a spacer.",
        "Lifted off the main track.",
        "Nothing lifted.",
        "Put on the main track.",
        "Nothing moved.",
        "Select a clip above or below the main track first.",
        "Attach point set.",
        "Attach point not set.",
        "Select two or more connected clips first.",
        "Storyline created.",
        "No storyline created.",
        "Select clips inside a storyline first.",
        "Nothing deleted.",
        "Deleted from the storyline.",
        "The project has no file yet.",
        "Another project was opened while saving.",
        "The track is locked.",
        "Another clip is in the way.",
        "That sequence format is not valid.",
        "The clip no longer exists.",
        "That clip does not belong on this track.",
        "Nothing to edit.",
        "Speed cannot be changed on that clip (titles and stills).",
        "Transitions go on a cut between two clips that touch, or on a clip edge.",
        "Not enough media beyond the cut for a transition. Trim the clips to leave handles.",
        "Select a group to ungroup.",
        "Select a nested sequence to unnest.",
        "Ungrouping would change how this group looks or sounds (its effects, speed or transitions, blend modes, dips or opacity over overlapping clips inside, track settings or markers inside).",
        "This clip cannot become a graphic without changing how it looks.",
        "This effect cannot be converted to keyframes (it must be the last enabled transform effect, with Motion on, and no format variant or open shutter).",
        "There is nothing to re-open.",
        "Only the most recent conversion can be re-opened.",
        "No spacer at the playhead.",
        "No gap at the playhead.",
        "No audio cut ahead of the playhead.",
        "No audio cut behind the playhead.",
        "Set In and Out first.",
        "Set In and Out, or select a clip, to bleep.",
        "There is no audio track to bleep.",
        "Nothing left to bleep there.",
        "Attach Backtimed needs a Fast Cut sequence.",
        "Attach Backtimed needs a clip on the main track.",
        "A sequence cannot contain itself, nor a sequence that contains it.",
        "That sequence is empty.",
        "Saved as “%@”; the old “%@” was left in place.",
        "No cut on %@ tracks to split.",
        "No cut on %@ tracks to nudge.",
        "No room to move the %@ edit.",
        "Select a cut (an edge, or clips next to each other) first.",
        "Select a video clip to match its color.",
        "Nothing to match to: put a clip on another track under the playhead, or a clip before this one on its track.",
        "Match works on Rec. 709 footage. This clip is interpreted as %@; grade it by hand.",
        "Match would measure the Vignette too. Reset or switch off Vignette first.",
        "Nothing to edit: the In and Out points leave no range.",
        "Fit to Fill needs a sequence In and Out; set both, then try again.",
        "Nothing is patched: click the source chips left of the track headers to connect them.",
        "Four marks set: used the sequence In/Out and the source In (Fit to Fill in the Source menu retimes the source into the range instead).",
        "That clip cannot become a sequence yet.",
        "Select the title layers first.",
        "This clip has no keyframes, so there is no intro or outro to keep.",
        "The %@ language pack is not installed. Add it in System Settings > General > Language & Region > Translation Languages.",
        "Translation %@ is not supported on this Mac.",
        "There are no captions to tidy.",
        "Unlock the caption track first.",
        "There are no captions to translate.",
        "Could not tell the language of the captions.",
        "The captions are already in that language.",
        "Anonymize: the clip was removed or locked meanwhile. Nothing was changed.",
        "The clip was trimmed, slipped or retimed while Anonymize was following the people, so the result does not fit the frames it shows now. Nothing was changed. Run Anonymize again.",
        "Target an audio track, or select an edit, to apply “%@”.",
        "Target a track, or select an edit, to apply “%@”.",
        "Target an audio track, or select an edit, to apply a transition.",
        "Target a track, or select an edit, to apply a transition.",
        "There is no video track for the graphic.",
        "That graphic is not available.",
        "Set an In or Out point in the Source monitor first.",
        "The In to Out range is empty.",
        "There is no caption at the playhead.",
        "Move the playhead inside the caption.",
        "Select two or more captions to merge.",
        "The %@ file has no captions.",
        "No transcript word under the playhead. Create captions first.",
        "The word under the playhead is only punctuation.",
        "The last sequence cannot be deleted.",
        "Not deleted: still used in %@.",
        "Could not be read.",
        "Variable frame rate: picture can drift against audio. Conform the clip to a constant rate before editing.",
        "Choose a folder on a disk.",
        "That is a file, not a folder.",
        "Sequence Studio cannot write to that folder.",
        "No sequence open.",
        "Already jump cut at the playhead. Move the playhead first.",
        "No clip under the playhead to jump cut.",
        "Select two or more video clips, or target a video track with several shots.",
        "Unknown error.",
        "This sequence has no clips to use as slots.",
        "An item has no known length yet.",
        "No slot could take that media.",
        "No captions: the caption track is locked.",
        "Captions need a current transcript: transcribe in the Text panel, then run Disguise Voice again.",
        "The transcript has no words in this range, so no captions were created.",
        "Disguise Voice on %@ clip, %@.",
        "Disguise Voice on %@ clips, %@.",
        "%@ caption created.",
        "%@ captions created.",
        "Makes the voice harder to recognize. Not a guarantee.",
        "An Angles clip needs at least two clips.",
        "Select the title clips first.",
        "A title block holds only text, shape and adjustment clips. Deselect clips with media.",
        "That item is not in the project.",
        "That item has no known length yet.",
        "There is no video track for the text.",
        "Could not start the microphone.",
        "The recording failed.",
        "The recording was too short.",
        "Could not import the recording.",
        "Could not place the recording.",
        "There is no video track for the animation.",
        "There is no video track for the color matte.",
        "There is no video track for the adjustment layer.",
        "Unknown preset.",
        "Select an audio clip to apply “%@”.",
        "Select a video clip to apply “%@”.",
        "The main track of a Fast Cut sequence stays at the bottom.",
        "Language %@ is not supported for on-device transcription.",
        "There is no audio to transcribe: no audible clips in this sequence.",
        "In: %@  ·  Out: %@",
        "None (built-in conversion)",
        "Memory for decoded frames of both monitors (this Mac: %@ GB). More plays back smoother, less leaves room for other apps. Auto scales with your Mac and shrinks when memory runs low.",
    ];

    /// App menu items built in `App/Sources` and their notices. `AppMenuLiteralTests` fails for a menu literal there that is not wrapped in `SQL10n.string`.
    pub const APP_MENU_KEYS: &[&str] = &[
        "Autosave Versions",
        "Save Checkpoint…",
        "Bring All to Front",
        "Change Format…",
        "Clear Menu",
        "Close Project",
        "Collect Files into Project Folder",
        "Copy Library Items Into Project",
        "Custom Ratio…",
        "Duplicate as Format…",
        "Media Management",
        "New Adjustment Layer",
        "New Color Matte…",
        "New Graphics Clip",
        "New Sequence from Template…",
        "New Shape",
        "No Versions Yet",
        "None (as tagged)",
        "Open Recent",
        "Pixel Aspect",
        "Project Input Color Space",
        "Reconnect Media…",
        "Save Sequence as Template…",
        "Watch Project Folder",
        "Workspace",
        "Style Kit",
        "Import Style Kit…",
        "Export Style Kit…",
        "Use Brand Caption Style",
        "Rectangle",
        "Ellipse",
        "Line",
        "Arrow",
        "No preview image could be made.",
        "Nothing new in this style kit",
        "Style kit imported",
        "This project's style kit has no caption style. Import a style kit that has one.",
        "Could not export the style kit: %@",
        "Could not import “%@”: %@",
    ];

    /// Strings of the count, status and accessibility sites (required in every language).
    pub const COUNT_KEYS: &[&str] = &[
        "%@ Step",
        "%@ Steps",
        "%@ caption",
        "%@ captions",
        "%@ of %@ match",
        "%@ of %@",
        " on %@ tracks",
        "No match",
        "No match.",
        "Replaced %@ time.",
        "Replaced %@ times.",
        "Tidied: %@ caption.",
        "Tidied: %@ captions.",
        "Find and Replace are the same: nothing to change.",
        " Locked caption tracks were skipped.",
        "Translating…",
        "Added %@.",
        "There are no captions to create.",
        "Created %@ captions.",
        "Every match already has a marker.",
        "Marked %@ match.",
        "Marked %@ matches.",
        "Nothing audible in this sequence.",
        "Transcribing %@ %%",
        "The timeline changed since this transcript. Transcribe again.",
        "%@ words, %@ edited",
        "%@ words",
        "Transcription failed.",
        "Preparing the %@ language model",
        "Downloading the %@ language model: %@",
        "Editing text. Return or Esc keeps it; Cmd+Z undoes the edit.",
    ];

    /// `one` (n == 1) or `other` as a `%@` format with the count substituted, translated per language.
    pub fn plural(n: i64, one: &str, other: &str) -> String {
        Self::format(if n == 1 { one } else { other }, &[&n.to_string()])
    }

    /// `plural` with more arguments after the count (`%@` 2, 3, ...): "Collected %@ files into %@.".
    pub fn plural_with(n: i64, one: &str, other: &str, rest: &[&str]) -> String {
        let n = n.to_string();
        let mut args: Vec<&str> = vec![&n];
        args.extend_from_slice(rest);
        Self::format(if n == "1" { one } else { other }, &args)
    }

    /// `plural` for a given language.
    pub fn plural_in(n: i64, one: &str, other: &str, language: &str) -> String {
        Self::format_in(if n == 1 { one } else { other }, &[&n.to_string()], language)
    }

    /// Translates an undo-step name: an exact name, or a verb pattern around a name that is translated on its own.
    /// Unknown text stays English. English is returned untouched.
    pub fn undo_name(name: &str) -> String {
        Self::undo_name_in(name, &Self::current_language())
    }

    /// `undo_name` for a given language.
    pub fn undo_name_in(name: &str, language: &str) -> String {
        let lang = language.to_string();
        if lang == Self::SOURCE_LANGUAGE {
            return name.to_string();
        }
        let t = Self::table(&lang);
        if let Some(exact) = t.get(name) {
            return exact.clone();
        }
        let mut patterns: Vec<&str> = Self::UNDO_PATTERNS.to_vec();
        patterns.sort_by_key(|p| std::cmp::Reverse(graphemes(p).count()));
        for pattern in patterns {
            let parts: Vec<&str> = pattern.split("%@").collect();
            if parts.len() != 2 || !name.starts_with(parts[0]) || !name.ends_with(parts[1]) {
                continue;
            }
            if name.len() < parts[0].len() + parts[1].len() {
                continue;
            }
            let Some(translated) = t.get(pattern) else { continue };
            let inner = &name[parts[0].len()..name.len() - parts[1].len()];
            return translated.replacen("%@", &Self::string_in(inner, &lang), 1);
        }
        name.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lists_keep_their_swift_sizes() {
        assert_eq!(SQL10n::UNDO_PATTERNS.len(), 24);
        assert_eq!(SQL10n::UNDO_NAMES.len(), 50);
        assert_eq!(SQL10n::SESSION_UNDO_NAMES.len(), 101);
        assert_eq!(SQL10n::STATUS_KEYS.len(), 139);
        assert_eq!(SQL10n::APP_MENU_KEYS.len(), 39);
        assert_eq!(SQL10n::COUNT_KEYS.len(), 31);
    }

    #[test]
    fn plural_with_keeps_the_other_arguments() {
        assert_eq!(
            SQL10n::plural_with(1, "Collected %@ file into %@.", "Collected %@ files into %@.", &["Media"]),
            "Collected 1 file into Media."
        );
        assert_eq!(
            SQL10n::plural_with(2, "Collected %@ file into %@.", "Collected %@ files into %@.", &["Media"]),
            "Collected 2 files into Media."
        );
    }

    #[test]
    fn plural_picks_form_and_translates() {
        assert_eq!(SQL10n::plural_in(1, "%@ Step", "%@ Steps", "en"), "1 Step");
        assert_eq!(SQL10n::plural_in(3, "%@ Step", "%@ Steps", "en"), "3 Steps");
        assert_eq!(SQL10n::plural_in(3, "%@ Step", "%@ Steps", "de"), "3 Schritte");
        assert_eq!(
            SQL10n::plural_in(2, "Reconnected %@ media file.", "Reconnected %@ media files.", "de"),
            "2 Mediendateien neu verbunden."
        );
    }

    #[test]
    fn undo_names_translate_exact_and_patterned() {
        let de = "de";
        assert_eq!(SQL10n::undo_name_in("Close Gap", de), "Lücke schließen");
        assert_eq!(SQL10n::undo_name_in("Reset Opacity to Automatic", de), "Deckkraft auf Automatisch zurücksetzen");
        assert_eq!(
            SQL10n::format_in("Undo %@", &[&SQL10n::undo_name_in("Close Gap", de)], de),
            "Lücke schließen widerrufen"
        );
        assert_eq!(SQL10n::undo_name_in("Animate Opacity", "en"), "Animate Opacity");
        assert_eq!(SQL10n::undo_name_in("Add Mask", de), "Maske hinzufügen");
        assert_eq!(SQL10n::undo_name_in("Animate Opacity", de), "Deckkraft animieren");
        // The longer pattern wins over "Add %@".
        assert_eq!(SQL10n::undo_name_in("Add Opacity Keyframe", de), "Deckkraft-Keyframe hinzufügen");
        assert_eq!(SQL10n::undo_name_in("Something Unknown", de), "Something Unknown");
    }
}
