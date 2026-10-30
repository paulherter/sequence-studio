import AppKit
import SQCore
import SQEditorSession
import SQEditorUI
import SQText

/// Fixed project for the panel render harness (`scripts/render-panels.sh`): the design's sample project, so renders can be
/// compared with the boards. Project "TikTok Schnitt-Tricks", sequence "Main" 1080x1920 30 fps, 00:00:22:03, a second
/// sequence "Combined 01", tracks C1 Captions (14 captions), V3 (adjustment layer "Film Grain"), V2 (Intro title, Combined 01,
/// C2156.MP4, Logo), V1 (C2140, C2147, C2152, C2156, C2160), A1 Voice, A2 SFX, A3 Music; In/Out 00:02:00..00:20:00, two
/// markers, playhead 00:00:15:00; bins Footage and Audio. Positions come from `timeline()` in docs/design-source/build.py
/// (32 px per second at 30 fps, so frames = px * 30 / 32). The media is offline on purpose (no external files): monitors
/// show their empty state. Everything here is a constant, so two runs build the same model (ids are random but never drawn).
@MainActor
enum RenderDemoProject {
    static let frame = Time(1, 30)
    static func frames(_ n: Int64) -> Time { frame * n }
    /// Board pixel (32 px per second) to frames.
    private static func px(_ v: Double) -> Int64 { Int64((v * 30 / 32).rounded()) }
    /// The clip the render selects: V1 "C2156.MP4" (Transform keyframes on Position and Scale).
    struct Built { var project: Project; var selected: Clip.ID; var playhead: Time }

    /// Frames of the five footage clips (Project panel durations) and the music bed length; the single source for the demo
    /// refs and for the real files of the "online" states.
    private static let footageFrames: [(String, Int64)] = [("C2140.MP4", 12 * 30 + 8), ("C2147.MP4", 31 * 30 + 17), ("C2152.MP4", 8 * 30 + 2),
                                                           ("C2156.MP4", 19 * 30 + 22), ("C2160.MP4", 9 * 30 + 10)]
    private static let musicName = "Music – Late Sun.mp3"

    /// Writes tiny real files for every demo media item into `dir` (idempotent). With `make(mediaDir:)` the clips are online.
    static func writeMedia(into dir: URL) async throws {
        try await RenderDemoMedia.write(into: dir, footage: footageFrames.map { ($0.0, Int($0.1)) }, music: (60, musicName))
    }

    private static func ref(_ name: String, duration: Time, video: Bool = true, dir: URL? = nil) -> MediaRef {
        let v = VideoTrackInfo(width: 1080, height: 1920, codec: "avc1", bitDepth: 8, chroma: "4:2:0",
                               nominalFrameDuration: frame, isVariableFrameRate: false)
        let a = AudioTrackInfo(sampleRate: video ? 48_000 : 44_100, channels: 2, codec: "lpcm")
        return MediaRef(name: name, path: dir?.appendingPathComponent(RenderDemoMedia.fileName(for: name)).path ?? "/Volumes/Demo/\(name)", fingerprint: MediaFingerprint(size: 1),
                        duration: duration, info: MediaInfo(duration: duration, video: video ? v : nil, audio: a))
    }

    private static let captionTexts = ["Heute zeige ich dir", "drei Tricks für schnellere", "Schnitte am Handy. Los", "geht's mit Trick eins",
                                       "Der Jump Cut spart", "dir jede Menge Zeit", "Schneide immer genau dort", "wo du Luft holst",
                                       "Dann kommt Trick Nummer", "zwei: sanfte Speed Ramps", "Beschleunige kurz vor dem Beat",
                                       "Trick drei sind Untertitel", "Die setzt du am Ende", "Folge mir für mehr"]

    /// `mediaDir`: folder written by `writeMedia(into:)`; nil keeps every item offline (the default for the board comparisons).
    static func make(mediaDir: URL? = nil) throws -> Built {
        // Footage durations as in the Project panel: 12:08, 31:17, 8:02, 19:22, 9:10; music 2:41:00.
        let footage = footageFrames.map { ref($0.0, duration: frames($0.1), dir: mediaDir) }
        let music = ref(musicName, duration: Time(mediaDir == nil ? 161 : 60, 1), video: false, dir: mediaDir)
        var project = Project(name: "TikTok Schnitt-Tricks")
        for r in footage { project.add(r) }
        project.add(music)

        var v1 = Track(kind: .video), v2 = Track(kind: .video), v3 = Track(kind: .video)
        var a1 = Track(kind: .audio), a2 = Track(kind: .audio), a3 = Track(kind: .audio)
        v1.name = "Video 1"; a1.name = "Voice"; a2.name = "SFX"; a3.name = "Music"
        v1.isTargeted = true; a1.isTargeted = true

        // V1 and A1: (left px, width px) from build.py. Frames are laid out gap-free from px rounding.
        let v1px: [(Double, Double)] = [(0, 95), (96, 185), (282, 102), (385, 175), (561, 145)]
        var selected: Clip.ID?
        var cursor: Int64 = 0
        for (i, (l, w)) in v1px.enumerated() {
            let r = footage[i]
            let start = i == 0 ? 0 : cursor
            let len = i == v1px.count - 1 ? Int64(663) - start : px(l + w) - start
            cursor = start + len
            let link = UUID()
            let src = TimeRange(start: frames(20), duration: frames(len))
            var video = Clip(name: r.name, media: r.id, kind: .video, source: src, start: frames(start), link: link, mediaDuration: r.duration)
            if r.name == "C2156.MP4" {
                // Transform keyframes on Position (3 keys, the middle one eased) and Scale (2 keys), clip-local times.
                var pos = AnimatedProperty(Vec2.zero)
                pos.track.insert(Keyframe(time: frames(20), value: Vec2(0, 0)))
                pos.track.insert(Keyframe(time: frames(89), value: Vec2(0, -148), interpolation: .bezier,
                                          inHandle: EaseHandle(dx: 0.42, dy: 0), outHandle: EaseHandle(dx: 0.58, dy: 1)))
                pos.track.insert(Keyframe(time: frames(150), value: Vec2(0, 0)))
                var sc = AnimatedProperty(Vec2(1, 1))
                sc.track.insert(Keyframe(time: frames(20), value: Vec2(1, 1)))
                sc.track.insert(Keyframe(time: frames(150), value: Vec2(1.2, 1.2)))
                video.animation.position = pos
                video.animation.scale = sc
                selected = video.id
            }
            try v1.overwrite(video)
            try a1.overwrite(Clip(name: r.name, media: r.id, kind: .audio, source: src, start: frames(start), link: link, mediaDuration: r.duration))
        }
        // C2156.MP4 on V2.
        let b = footage[3]
        try v2.overwrite(Clip(name: b.name, media: b.id, kind: .video, source: TimeRange(start: .zero, duration: frames(105)),
                              start: frames(px(300)), mediaDuration: b.duration))
        // SFX on A2 and the music bed on A3.
        for (l, w) in [(86.0, 26.0), (272, 26), (418, 16), (586, 42)] {
            try a2.overwrite(Clip(name: "Whoosh", media: music.id, kind: .audio, source: TimeRange(start: frames(30), duration: frames(px(w))),
                                  start: frames(px(l)), mediaDuration: music.duration))
        }
        try a3.overwrite(Clip(name: music.name, media: music.id, kind: .audio, source: TimeRange(start: .zero, duration: frames(663)),
                              start: .zero, mediaDuration: music.duration))

        // Second sequence "Combined 01" (00:00:02:18 = 78 frames), nested into Main on V2.
        var inner = Track(kind: .video)
        inner.name = "V1"
        let c147 = footage[1]
        try inner.overwrite(Clip(name: c147.name, media: c147.id, kind: .video, source: TimeRange(start: frames(300), duration: frames(78)),
                                 start: .zero, mediaDuration: c147.duration))
        let fmt = SequenceFormat(width: 1080, height: 1920, frameDuration: frame)
        let combined = Timeline(name: "Combined 01", format: fmt, tracks: [inner])
        try v2.overwrite(Clip(name: combined.name, media: combined.id, kind: .video, source: TimeRange(start: .zero, duration: frames(78)),
                              start: frames(px(134)), mediaDuration: frames(78), sequence: combined.id))

        let main = Timeline(name: "Main", format: fmt, tracks: [v1, v2, v3, a1, a2, a3])
        project.timelines = [main, combined]
        project.activeTimeline = main.id

        // Bins: Footage and Audio folders, then the two sequences (as on the Project board).
        var root = project.rootBin
        root.children = [.bin(Bin(name: "Footage", children: footage.map { .media($0.id) })),
                         .bin(Bin(name: "Audio", children: [.media(music.id)])),
                         .sequence(main.id), .sequence(combined.id)]
        project.rootBin = root
        project.normalizeBins()

        // Title, logo and adjustment layer (generator clips go through the project so they get their payload).
        var template = TextTemplate(name: "Title", text: "Intro title", style: CaptionPresetLibrary.builtIn.style(for: "title"))
        template.animation = nil
        let titleRef = try TextGenerator.makeRef(template: template, animations: nil)
        var logoTemplate = template
        logoTemplate.text = "Logo"
        let logoRef = try TextGenerator.makeRef(template: logoTemplate, animations: nil)
        let v2ID = project.timelines[0].tracks[1].id
        let v3ID = project.timelines[0].tracks[2].id
        try project.addGeneratorClip(kind: titleRef.kind, payload: titleRef.payload, payloadVersion: titleRef.payloadVersion, name: "Intro title",
                                     in: main.id, at: frames(px(6)), track: v2ID, duration: frames(px(86)))
        try project.addGeneratorClip(kind: logoRef.kind, payload: logoRef.payload, payloadVersion: logoRef.payloadVersion, name: "Logo",
                                     in: main.id, at: frames(px(640)), track: v2ID, duration: frames(663 - px(640)))
        let adj = try project.addAdjustmentClip(in: main.id, at: frames(px(96)), track: v3ID, duration: frames(663 - px(96)))

        try project.edit(main.id) { t in
            if var c = t.tracks.flatMap(\.clips).first(where: { $0.id == adj }) { c.name = "Film Grain"; try t.replaceClip(c) }
            // Board `.mk`: orange markers.
            for (x, name) in [(160.0, "Hook"), (420, "Trick 2")] {
                let id = t.addMarker(at: frames(px(x)), name: name)
                _ = t.updateMarker(id) { $0.color = .orange }
            }
            t.inOut = TimeRange(start: frames(px(64)), end: frames(px(64 + 576)))
            let items = captionTexts.enumerated().map { i, text in
                CaptionItem(lines: [text], range: TimeRange(start: frames(Int64(i) * 48), duration: frames(46)))
            }
            let captions = try t.replaceCaptions(items)
            if let i = t.captionTracks.firstIndex(where: { $0.id == captions }) { t.captionTracks[i].name = "Captions" }   // board C1 "Captions"
        }
        guard let selected else { throw EditError.clipNotFound }
        // The Project board shows Footage open with C2156.MP4 selected. The harness loads this project right after the
        // call, so the Project panel reveals the file on the next main-queue turn (before the first capture).
        let revealed = footage[3].id
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                (NSApp.delegate as? AppController)?.panels.projectView.reveal(media: revealed)
            }
        }
        return Built(project: project, selected: selected, playhead: frames(450))
    }

    /// Loads `built` like the board shows it: tabs "Main | Combined 01" with Main active, the clip selected, the playhead set.
    @MainActor
    static func load(_ built: Built, into session: EditorSession) {
        session.newProject(built.project)
        let ids = built.project.timelines.map(\.id)
        for id in ids.reversed() { session.openSequenceTab(id) }     // Combined 01 first, then back to Main
        session.moveSequenceTab(root: ids[0], to: 0)
        session.select(clips: [built.selected])
        session.seek(to: built.playhead)
    }
}
