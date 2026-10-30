import Foundation
import SQCore
import SQDrawShell

/// The Project panel's Windows inputs: icon grid posters from the timeline's FFmpeg thumbnail atlas (the item's poster
/// frame, `MediaRef.posterTime`, else the first frame: the Mac `ProjectThumbnails.poster`) and the start screen's card pictures.
extension AppController {
    func wireProjectPanel() {
        projectList.poster = { [weak session] id in
            winTimelineMedia?.picture(media: id, at: session?.project.media(id)?.posterTime).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        // Hover Scrub: the frame under the pointer from the same atlas (the Mac `ProjectThumbnails.scrub`).
        projectList.posterAt = { id, t in
            winTimelineMedia?.picture(media: id, at: t).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        // Start screen cards: the poster media's frame at the poster time, from the same atlas (the Mac StartPosterLoader).
        shell.startPoster = { [paths] path, seconds in
            winTimelineMedia?.picture(media: paths.id(forPath: path), at: Time(Int64(max(seconds, 0) * 1000), 1000)).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
        // Card import board tiles: the file's first frame from the same atlas (the Mac Quick Look thumbnail).
        ShellCardImport.poster = { [paths] item in
            winTimelineMedia?.picture(media: paths.id(forPath: item.url.path), at: nil).map {
                ProjectPoster(slot: $0.slot, u0: $0.source.u0, v0: $0.source.v0, u1: $0.source.u1, v1: $0.source.v1,
                              pixelSize: $0.pixelSize)
            }
        }
    }
}
