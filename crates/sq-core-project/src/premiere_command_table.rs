// SPDX-License-Identifier: GPL-3.0-or-later
//! Premiere Pro `commandname` (a `.kys` item) -> our command (`EditorCommand.id`). Only commands we really have are mapped
//! (our own vocabulary on our side); everything else is listed by the importer as having no equivalent.
//!
//! Names come from a published list of Premiere's internal command ids (not from a live copy: UNVERIFIED, docs/KEYMAP.md).
//! Judgment calls:
//! - Premiere's "Ripple Delete" is our Ripple Delete, its "Clear" is our Delete (leaves a gap), as in Premiere.
//! - Trim Previous / Next Edit to Playhead are our Ripple Trim Previous / Next Edit to Playhead.
//! - Premiere's "Add Edit" is our Add Edit; its Track Select tools are our Track Forward / Backward tools.
// Swift: PremiereCommandTable.swift

use crate::foreign_keymap::Target;
use std::collections::BTreeMap;

/// (Premiere `commandname` without the `cmd.` prefix, our command id) in the order of the Swift table; a later row replaces
/// an earlier one with the same name.
const ROWS: &[(&str, &str)] = &[
    // Transport
    ("transport.toggleplay", "playPause"),
    ("monitor.playstoptoggle", "playPause"),
    ("transport.stop", "shuttleStop"),
    ("transport.shuttle.stop", "shuttleStop"),
    ("transport.shuttle.left", "shuttleReverse"),
    ("transport.shuttle.right", "shuttleForward"),
    ("transport.rewind", "shuttleReverse"),
    ("transport.fastforward", "shuttleForward"),
    ("transport.shuttle.slow.left", "shuttleSlowReverse"),
    ("transport.shuttle.slow.right", "shuttleSlowForward"),
    ("transport.step.back", "stepBackward"),
    ("transport.step.forward", "stepForward"),
    ("monitor.step.backward", "stepBackward"),
    ("monitor.step.forward", "stepForward"),
    ("transport.step.back.five", "stepBackward5"),
    ("transport.step.forward.five", "stepForward5"),
    ("transport.sequence.start", "goToStart"),
    ("transport.sequence.end", "goToEnd"),
    ("transport.selectedclip.start", "goToSelectedClipStart"),
    ("transport.selectedclip.end", "goToSelectedClipEnd"),
    ("transport.playintoout", "playInToOut"),
    ("transport.play.ctitoout", "playToOut"),
    ("transport.playedit", "playAround"),
    ("transport.record", "recordVoiceOver"),
    ("monitor.loop", "toggleLoop"),
    ("toggle.audio.scrubbing", "toggleAudioScrubbing"),
    ("tlnav.prev.edit", "previousEditPoint"),
    ("tlnav.next.edit", "nextEditPoint"),
    ("tlnav.prev.edit.any.track", "previousEditPointAnyTrack"),
    ("tlnav.next.edit.any.track", "nextEditPointAnyTrack"),
    // Range
    ("common.setin", "markIn"),
    ("common.setout", "markOut"),
    ("goto.in", "goToIn"),
    ("goto.out", "goToOut"),
    ("clear.in", "clearIn"),
    ("clear.out", "clearOut"),
    ("clear.inandout", "clearInOut"),
    ("marker.setsequenceinoutmarkeraroundtargetclip", "markClip"),
    ("marker.setsequenceinoutmarkeraroundselection.out", "markSelection"),
    // Markers
    ("set.marker", "addMarker"),
    ("marker.edit", "editMarker"),
    ("marker.clearmarker.current", "clearMarker"),
    ("marker.clearmarker.all", "clearAllMarkers"),
    ("marker.gotomarker.next", "nextMarker"),
    ("marker.gotomarker.previous", "previousMarker"),
    ("marker.nextrow", "nextMarker"),
    ("marker.previousrow", "previousMarker"),
    // Tools
    ("tools.01pointer", "tool.selection"),
    ("tools.02trackselectforward", "tool.trackForward"),
    ("tools.02_5trackselectbackward", "tool.trackBackward"),
    ("tools.03ripple", "tool.ripple"),
    ("tools.04roll", "tool.rolling"),
    ("tools.05ratestretch", "tool.rateStretch"),
    ("tools.06razor", "tool.razor"),
    ("tools.07slip", "tool.slip"),
    ("tools.08slide", "tool.slide"),
    ("tools.10hand", "tool.hand"),
    ("tools.11zoom", "tool.zoom"),
    ("tools.12text", "tool.type"),
    // Editing
    ("sequence.razorateditline", "addEdit"),
    ("sequence.razorateditline.all", "addEditAllTracks"),
    ("clip.insert", "insert"),
    ("clip.overlay", "overwrite"),
    ("sequence.lift", "lift"),
    ("sequence.extract", "extract"),
    ("edit.clear", "delete"),
    ("clip.delete", "delete"),
    ("edit.rippledelete", "rippleDelete"),
    ("timeline.ripple.delete", "rippleDelete"),
    ("sequence.extendselectededittoplayhead", "extendEdit"),
    ("tlnav.trim.in.to.cti", "rippleTrimPrevious"),
    ("tlnav.trim.out.to.cti", "rippleTrimNext"),
    ("sequence.rippletrimpreviousedittoplayhead", "rippleTrimPrevious"),
    ("sequence.rippletrimnextedittoplayhead", "rippleTrimNext"),
    ("sequence.trimbackward", "trimBackward"),
    ("sequence.trimforward", "trimForward"),
    ("sequence.trimbackwardmany", "trimBackward5"),
    ("sequence.trimforwardmany", "trimForward5"),
    ("sequence.toggletrimtype", "toggleTrimType"),
    ("tlnav.select.clip.at.playhead", "selectClipAtPlayhead"),
    ("tlnav.select.next.clip", "selectNextClip"),
    ("tlnav.select.previous.clip", "selectPreviousClip"),
    ("timeline.nudge.left.one", "nudgeLeft"),
    ("timeline.nudge.right.one", "nudgeRight"),
    ("timeline.nudge.left.several", "nudgeLeft5"),
    ("timeline.nudge.right.several", "nudgeRight5"),
    ("timeline.nudge.up", "moveSelectionUp"),
    ("timeline.nudge.down", "moveSelectionDown"),
    ("timeline.slide.left.one", "slideLeft"),
    ("timeline.slide.right.one", "slideRight"),
    ("timeline.slide.left.several", "slideLeft5"),
    ("timeline.slide.right.several", "slideRight5"),
    ("timeline.slip.left.one", "slipLeft"),
    ("timeline.slip.right.one", "slipRight"),
    ("timeline.slip.left.several", "slipLeft5"),
    ("timeline.slip.right.several", "slipRight5"),
    ("clip.enable", "enableClip"),
    ("sequence.snap", "toggleSnapping"),
    ("edit.duplicate", "duplicate"),
    ("clip.linkaudioandvideo", "link"),
    ("sequence.linkedselection", "toggleLinkedSelection"),
    ("clip.group", "group"),
    ("clip.ungroup", "ungroup"),
    ("sequence.matchframe", "matchFrame"),
    ("sequence.reversematchframe", "reverseMatchFrame"),
    ("sequence.selectionfollowsplayhead", "toggleSelectionFollowsPlayhead"),
    ("edit.editoriginal", "editOriginal"),
    ("tlnav.toggle.all.target.video", "toggleAllTargets"),
    ("tlnav.toggle.all.target.audio", "toggleAllTargets"),
    // Clipboard / history / selection
    ("edit.cut", "cut"),
    ("edit.copy", "copy"),
    ("edit.paste", "paste"),
    ("edit.pasteinsert", "pasteInsert"),
    ("edit.pasteattributes", "pasteAttributes"),
    ("edit.undo", "undo"),
    ("edit.redo", "redo"),
    ("edit.selectall", "selectAll"),
    ("edit.deselectall", "deselectAll"),
    // Retiming, effects, titles, audio
    ("clip.speed", "speedDuration"),
    ("clip.videooptions.insertframeholdsegment", "insertFrameHold"),
    ("sequence.applydefaulttransitions", "applyDefaultTransitions"),
    ("sequence.applydefaultvideotransition", "applyVideoTransition"),
    ("sequence.applydefaultaudiotransition", "applyAudioTransition"),
    ("clip.audiooptions.nudgevolumeup", "audioGainUp"),
    ("clip.audiooptions.nudgevolumedown", "audioGainDown"),
    ("clip.audiooptions.nudgevolumeup3", "audioGainUp6"),
    ("clip.audiooptions.nudgevolumedown3", "audioGainDown6"),
    ("clip.audiooptions.gain", "audioGain"),
    ("clip.keyframe.addremovevideo", "addKeyframe"),
    ("clip.keyframe.addremoveaudio", "addKeyframe"),
    ("clip.keyframe.selectnext", "nextKeyframe"),
    ("clip.keyframe.selectprevious", "previousKeyframe"),
    ("timeline.interpolation.easein", "easeIn"),
    ("timeline.interpolation.easeout", "easeOut"),
    ("timeline.interpolation.hold", "toggleHoldInterpolation"),
    ("effectcontrols.interpolation.easein", "easeIn"),
    ("effectcontrols.interpolation.easeout", "easeOut"),
    ("effectcontrols.interpolation.hold", "toggleHoldInterpolation"),
    // View
    ("tlnav.zoomto.sequence", "zoomFit"),
    ("project.zoom.in", "zoomIn"),
    ("project.zoom.out", "zoomOut"),
    ("timeline.expand.all.tracks", "expandAllTracks"),
    ("timeline.minimize.all.tracks", "minimizeAllTracks"),
    ("timeline.increase.video.tracks.height", "videoTracksTaller"),
    ("timeline.decrease.video.tracks.height", "videoTracksShorter"),
    ("timeline.increase.audio.tracks.height", "audioTracksTaller"),
    ("timeline.decrease.audio.tracks.height", "audioTracksShorter"),
    ("toggle.maximize.frame", "maximizePanel"),
    ("toggle.maximize.focused.frame", "maximizeActivePanel"),
    ("posterframe.clear", "clearPosterFrame"),
    // Multi-camera: Cut to Camera n
    // File / app
    ("file.import", "importMedia"),
    ("file.new.project", "newProject"),
    ("file.openproject", "openProject"),
    ("file.save", "save"),
    ("file.saveas", "saveAs"),
    ("file.savecopy", "saveCopy"),
    ("file.export.movie", "export"),
    ("export.frame", "exportFrame"),
    ("file.newbinfromselection", "newBin"),
    ("edit.preferences.general", "preferences"),
    ("edit.keyboardshortcuts", "keyboardShortcuts"),
    ("sequence.sequencesettingsgeneral", "sequenceSettings"),
    ("edit.find", "find"),
];

/// Premiere commands the system owns.
const SYSTEM: [&str; 5] = ["file.quit", "file.exit", "window.minimize", "app.hide", "app.hideothers"];

/// The Premiere command table.
pub struct PremiereCommandTable;

impl PremiereCommandTable {
    /// `cmd.<name>` -> target.
    pub fn rows() -> BTreeMap<String, Target> {
        let mut t: BTreeMap<String, Target> = BTreeMap::new();
        for (name, id) in ROWS {
            t.insert(format!("cmd.{name}"), Target::Command((*id).to_string()));
        }
        // Multi-camera: Cut to Camera n
        for n in 1..=9 {
            t.insert(format!("cmd.multicam.choose.camera.{n}"), Target::Command(format!("switchAngle.{n}")));
        }
        for name in SYSTEM {
            t.insert(format!("cmd.{name}"), Target::System);
        }
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_known_names_and_the_system_ones() {
        let t = PremiereCommandTable::rows();
        assert_eq!(t.get("cmd.tools.06razor"), Some(&Target::Command("tool.razor".into())));
        assert_eq!(t.get("cmd.multicam.choose.camera.9"), Some(&Target::Command("switchAngle.9".into())));
        assert_eq!(t.get("cmd.file.quit"), Some(&Target::System));
        assert_eq!(t.get("cmd.not.in.our.table"), None);
        assert_eq!(t.get("cmd.edit.clear"), Some(&Target::Command("delete".into())));
    }

    #[test]
    fn row_count_matches_the_swift_table() {
        // 163 distinct `c(...)` names in Swift + 9 camera rows + 5 system rows.
        assert_eq!(ROWS.len(), 163);
        assert_eq!(PremiereCommandTable::rows().len(), 163 + 9 + 5);
    }
}
