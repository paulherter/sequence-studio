import Foundation

/// Premiere Pro `commandname` (a `.kys` item) -> our command (`EditorCommand.id`). Only commands we really have are mapped
/// (our own vocabulary on our side); everything else is listed by the importer as having no equivalent.
///
/// Names come from a published list of Premiere's internal command ids (not from a live copy: UNVERIFIED, docs/KEYMAP.md).
/// Judgment calls:
/// - Premiere's "Ripple Delete" is our Ripple Delete, its "Clear" is our Delete (leaves a gap), as in Premiere.
/// - Trim Previous / Next Edit to Playhead are our Ripple Trim Previous / Next Edit to Playhead.
/// - Premiere's "Add Edit" is our Add Edit; its Track Select tools are our Track Forward / Backward tools.
public enum PremiereCommandTable {
    public static let rows: [String: ForeignKeymap.Target] = {
        var t: [String: ForeignKeymap.Target] = [:]
        func c(_ name: String, _ id: String) { t["cmd." + name] = .command(id) }

        // Transport
        c("transport.toggleplay", "playPause"); c("monitor.playstoptoggle", "playPause")
        c("transport.stop", "shuttleStop"); c("transport.shuttle.stop", "shuttleStop")
        c("transport.shuttle.left", "shuttleReverse"); c("transport.shuttle.right", "shuttleForward")
        c("transport.rewind", "shuttleReverse"); c("transport.fastforward", "shuttleForward")
        c("transport.shuttle.slow.left", "shuttleSlowReverse"); c("transport.shuttle.slow.right", "shuttleSlowForward")
        c("transport.step.back", "stepBackward"); c("transport.step.forward", "stepForward")
        c("monitor.step.backward", "stepBackward"); c("monitor.step.forward", "stepForward")
        c("transport.step.back.five", "stepBackward5"); c("transport.step.forward.five", "stepForward5")
        c("transport.sequence.start", "goToStart"); c("transport.sequence.end", "goToEnd")
        c("transport.selectedclip.start", "goToSelectedClipStart"); c("transport.selectedclip.end", "goToSelectedClipEnd")
        c("transport.playintoout", "playInToOut"); c("transport.play.ctitoout", "playToOut")
        c("transport.playedit", "playAround")
        c("transport.record", "recordVoiceOver")
        c("monitor.loop", "toggleLoop"); c("toggle.audio.scrubbing", "toggleAudioScrubbing")
        c("tlnav.prev.edit", "previousEditPoint"); c("tlnav.next.edit", "nextEditPoint")
        c("tlnav.prev.edit.any.track", "previousEditPointAnyTrack"); c("tlnav.next.edit.any.track", "nextEditPointAnyTrack")
        // Range
        c("common.setin", "markIn"); c("common.setout", "markOut")
        c("goto.in", "goToIn"); c("goto.out", "goToOut")
        c("clear.in", "clearIn"); c("clear.out", "clearOut"); c("clear.inandout", "clearInOut")
        c("marker.setsequenceinoutmarkeraroundtargetclip", "markClip")
        c("marker.setsequenceinoutmarkeraroundselection.out", "markSelection")
        // Markers
        c("set.marker", "addMarker"); c("marker.edit", "editMarker")
        c("marker.clearmarker.current", "clearMarker"); c("marker.clearmarker.all", "clearAllMarkers")
        c("marker.gotomarker.next", "nextMarker"); c("marker.gotomarker.previous", "previousMarker")
        c("marker.nextrow", "nextMarker"); c("marker.previousrow", "previousMarker")
        // Tools
        c("tools.01pointer", "tool.selection"); c("tools.02trackselectforward", "tool.trackForward")
        c("tools.02_5trackselectbackward", "tool.trackBackward"); c("tools.03ripple", "tool.ripple")
        c("tools.04roll", "tool.rolling"); c("tools.05ratestretch", "tool.rateStretch"); c("tools.06razor", "tool.razor")
        c("tools.07slip", "tool.slip"); c("tools.08slide", "tool.slide"); c("tools.10hand", "tool.hand")
        c("tools.11zoom", "tool.zoom"); c("tools.12text", "tool.type")
        // Editing
        c("sequence.razorateditline", "addEdit"); c("sequence.razorateditline.all", "addEditAllTracks")
        c("clip.insert", "insert"); c("clip.overlay", "overwrite")
        c("sequence.lift", "lift"); c("sequence.extract", "extract")
        c("edit.clear", "delete"); c("clip.delete", "delete"); c("edit.rippledelete", "rippleDelete"); c("timeline.ripple.delete", "rippleDelete")
        c("sequence.extendselectededittoplayhead", "extendEdit")
        c("tlnav.trim.in.to.cti", "rippleTrimPrevious"); c("tlnav.trim.out.to.cti", "rippleTrimNext")
        c("sequence.rippletrimpreviousedittoplayhead", "rippleTrimPrevious"); c("sequence.rippletrimnextedittoplayhead", "rippleTrimNext")
        c("sequence.trimbackward", "trimBackward"); c("sequence.trimforward", "trimForward")
        c("sequence.trimbackwardmany", "trimBackward5"); c("sequence.trimforwardmany", "trimForward5")
        c("sequence.toggletrimtype", "toggleTrimType")
        c("tlnav.select.clip.at.playhead", "selectClipAtPlayhead")
        c("tlnav.select.next.clip", "selectNextClip"); c("tlnav.select.previous.clip", "selectPreviousClip")
        c("timeline.nudge.left.one", "nudgeLeft"); c("timeline.nudge.right.one", "nudgeRight")
        c("timeline.nudge.left.several", "nudgeLeft5"); c("timeline.nudge.right.several", "nudgeRight5")
        c("timeline.nudge.up", "moveSelectionUp"); c("timeline.nudge.down", "moveSelectionDown")
        c("timeline.slide.left.one", "slideLeft"); c("timeline.slide.right.one", "slideRight")
        c("timeline.slide.left.several", "slideLeft5"); c("timeline.slide.right.several", "slideRight5")
        c("timeline.slip.left.one", "slipLeft"); c("timeline.slip.right.one", "slipRight")
        c("timeline.slip.left.several", "slipLeft5"); c("timeline.slip.right.several", "slipRight5")
        c("clip.enable", "enableClip"); c("sequence.snap", "toggleSnapping"); c("edit.duplicate", "duplicate")
        c("clip.linkaudioandvideo", "link"); c("sequence.linkedselection", "toggleLinkedSelection")
        c("clip.group", "group"); c("clip.ungroup", "ungroup")
        c("sequence.matchframe", "matchFrame"); c("sequence.reversematchframe", "reverseMatchFrame")
        c("sequence.selectionfollowsplayhead", "toggleSelectionFollowsPlayhead")
        c("edit.editoriginal", "editOriginal")
        c("tlnav.toggle.all.target.video", "toggleAllTargets"); c("tlnav.toggle.all.target.audio", "toggleAllTargets")
        // Clipboard / history / selection
        c("edit.cut", "cut"); c("edit.copy", "copy"); c("edit.paste", "paste"); c("edit.pasteinsert", "pasteInsert")
        c("edit.pasteattributes", "pasteAttributes")
        c("edit.undo", "undo"); c("edit.redo", "redo"); c("edit.selectall", "selectAll"); c("edit.deselectall", "deselectAll")
        // Retiming, effects, titles, audio
        c("clip.speed", "speedDuration"); c("clip.videooptions.insertframeholdsegment", "insertFrameHold")
        c("sequence.applydefaulttransitions", "applyDefaultTransitions")
        c("sequence.applydefaultvideotransition", "applyVideoTransition"); c("sequence.applydefaultaudiotransition", "applyAudioTransition")
        c("clip.audiooptions.nudgevolumeup", "audioGainUp"); c("clip.audiooptions.nudgevolumedown", "audioGainDown")
        c("clip.audiooptions.nudgevolumeup3", "audioGainUp6"); c("clip.audiooptions.nudgevolumedown3", "audioGainDown6")
        c("clip.audiooptions.gain", "audioGain")
        c("clip.keyframe.addremovevideo", "addKeyframe"); c("clip.keyframe.addremoveaudio", "addKeyframe")
        c("clip.keyframe.selectnext", "nextKeyframe"); c("clip.keyframe.selectprevious", "previousKeyframe")
        c("timeline.interpolation.easein", "easeIn"); c("timeline.interpolation.easeout", "easeOut")
        c("timeline.interpolation.hold", "toggleHoldInterpolation")
        c("effectcontrols.interpolation.easein", "easeIn"); c("effectcontrols.interpolation.easeout", "easeOut")
        c("effectcontrols.interpolation.hold", "toggleHoldInterpolation")
        // View
        c("tlnav.zoomto.sequence", "zoomFit"); c("project.zoom.in", "zoomIn"); c("project.zoom.out", "zoomOut")
        c("timeline.expand.all.tracks", "expandAllTracks"); c("timeline.minimize.all.tracks", "minimizeAllTracks")
        c("timeline.increase.video.tracks.height", "videoTracksTaller"); c("timeline.decrease.video.tracks.height", "videoTracksShorter")
        c("timeline.increase.audio.tracks.height", "audioTracksTaller"); c("timeline.decrease.audio.tracks.height", "audioTracksShorter")
        c("toggle.maximize.frame", "maximizePanel"); c("toggle.maximize.focused.frame", "maximizeActivePanel")
        c("posterframe.clear", "clearPosterFrame")
        // Multi-camera: Cut to Camera n
        for n in 1...9 { c("multicam.choose.camera.\(n)", "switchAngle.\(n)") }
        // File / app
        c("file.import", "importMedia"); c("file.new.project", "newProject"); c("file.openproject", "openProject")
        c("file.save", "save"); c("file.saveas", "saveAs"); c("file.savecopy", "saveCopy")
        c("file.export.movie", "export"); c("export.frame", "exportFrame")
        c("file.newbinfromselection", "newBin")
        c("edit.preferences.general", "preferences"); c("edit.keyboardshortcuts", "keyboardShortcuts")
        c("sequence.sequencesettingsgeneral", "sequenceSettings")
        c("edit.find", "find")
        // macOS owns these.
        for name in ["file.quit", "file.exit", "window.minimize", "app.hide", "app.hideothers"] { t["cmd." + name] = .system }
        return t
    }()
}
