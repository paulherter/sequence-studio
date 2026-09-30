# Review 2: SSProxy, SSLibrary, SSTranscribe, SSText, SSExport

Date: 2026-09-30. Read-only review of committed code (HEAD after 276167e), traced by reading, no harness run.
Status column: open until a fix commit names the finding.

## SSExport (owner: export session, uncommitted work there)
- **X1 Med-high** `ExportWriter.swift:129-146`: audio shorter than video stalls the export. Audio input is only `markAsFinished()` after the video loop; interleaving writer stops accepting video → loop sleeps forever. Fix: finish the audio input as soon as the source ends; add a test with audio shorter than video.
- **X2 High** `ExportQueue.swift:48,163-172`: unique names are case-sensitive. "Cut" and "cut" map to the same APFS file; job 2 deletes job 1's output. Fix: reserve by lowercased name.
- **X3 High** `ExportQueue.swift:121-136`: sidecar `.srt` not in the unique-name check (stale `Name.srt` overwritten); a sidecar failure/cancel after the video deletes the finished `.mp4`. Fix: reserve `.srt` too; keep the video when only the sidecar fails.
- **X4 Low** `SRTWriter.swift:52-55`: fully negative cue passes the drop check and prints `00:00:00,000 --> 00:00:00,000`. Fix: clamp before the `end > start` check.

## SSText
- **T1 Med** `TextLayout.swift:137-139`: leading whitespace counts in width but `Measured.text` is trimmed both sides → centre/right alignment off by the space width. Fix: trim trailing only, or subtract leading width. — fixed
- **T2 Test** `AnchorTests.swift` `combinedInOutDoNotCross`: claims monotonic, only checks 0...1. Fix: assert non-increasing after the in-animation. — fixed
- **T3 Low** `AnchoredPlayback.swift:114`, `KeyframeTemplate.swift:129`: Int64 overflow traps on extreme retime/migration. Fix: checked arithmetic, throw in migration. — fixed

## SSProxy
- **P1 Med (latent)** `ProxyQueue.swift:80-100`, `ProxyCache.swift:45`: cache key ignores `timeRange`; a 5 s partial proxy is served for the whole file. Fix: key includes range, or drop `timeRange` from public `enqueue`. — fixed
- **P2 Med** `ProxyCache.swift:61-87`: concurrent `lookup` can drop a record `commit` just replaced (orphaned file). Fix: `replaceItemAt`; drop only if `records[key] == r`. — fixed
- **P3 Low** `ProxyCache.swift:41-42`: `updateSettings` writes outside the lock (stale on disk). — fixed
- **P4 Low** `ProxyQueue.swift:87,122-125`: enqueue dedupes to a job that is being cancelled. — fixed
- **P5 Low** `ProxyQueue.swift:71`: partial purge skipped if a job runs before `start()`. — fixed
- **P6 Low** `ProxyTranscoder.swift:30-31,129`: traps on timescale > Int32.max or indefinite duration. Guard and throw. — fixed

## SSLibrary
- **L1 Med** `PreviewRequests.swift:174,213-266`: superseded flight can leave an orphan file (supersede between check and move); a late request for older content supersedes the newer flight and deletes its files. Fix: re-check after move; monotonic content version (mtime), ignore older. — fixed
- **L2 Med** `FolderScanner.swift:26-29`: symlink and target in the same folder get the same entry id (relative path from resolved path). Fix: use the unresolved path. — fixed
- **L3 Med** `FolderWatching.swift:60-82`: `FSEventsBox` unretained in the FSEvents context → use after free on a late callback. Fix: retain/release callbacks or drain the queue after invalidate. — fixed

## Checked and correct
SRT rounding/hours/CRLF; export colour tags 1-1-1 and pts math; writer cancel paths; queue state machine; anchored playback and template v1–v3; TextLayout metrics; proxy partial commit by rename, transcoder cancel, eviction; PresetStore write order; corrupt-backup pruning; transcript/caption timing (rational throughout).
