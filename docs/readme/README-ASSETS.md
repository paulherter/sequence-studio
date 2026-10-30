# README assets

Everything here is used by the front page `README.md`. The screenshots are real PNGs of the shared UI (dark theme)
rendered headless on Windows through D3D12 (`Windows/SQWinApp/Sources/SQWinApp/WinReadmeShots.swift`, flags
`--make-readme` and `--readme-shots`, on branch `readme-shots`) from the stock clips in `TestMedia/stock` (licenses in
`TestMedia/stock/SOURCES.txt`, not in the repo). Timeline and monitors are crops of the hero render. Capture at the pixel size below (a Retina capture scaled down is fine). Use your own footage
or royalty-free clips only, never third-party material.

| File | Pixels | What to capture |
|---|---|---|
| `banner.png`, `banner-1x.png` | 2560 x 1280 (1x: 1280 x 640) | Final art, approved banner scene (dark left with title and tagline, Pip as the standard app icon over the rainbow field). Rendered from `icon-work/splash/final/website-kopf-final.html#banner` with headless Chrome at device scale 2 (and 1). One image for light and dark mode. |
| `shot-hero.png` | 1600 x 900 | Whole editor window: timeline with several tracks, Source and Program monitors, Effect Controls open. |
| `shot-start.png` | 1200 x 675 | Start window with recents, 9:16 and 16:9 new-video cards and templates. |
| `shot-timeline.png` | 1200 x 675 | Timeline close-up: several tracks, markers, a trim in progress. |
| `shot-monitors.png` | 1200 x 675 | Source and Program monitors side by side with a clip loaded. |
| `shot-fastcut.png` | 1200 x 675 | A Fast Cut sequence with the V1 spacer or drop ghost visible. |
| `shot-effects.png` | 1200 x 675 | Effect Controls with keyframes and an open speed curve. |
| `shot-color.png` | 1200 x 675 | Color panel with scopes and a graded clip. |
| `shot-masks.png` | 1200 x 675 | A mask or subject mask with tracking on a clip. |
| `shot-captions.png` | 1200 x 675 | A title and caption styles on a vertical frame. |
| `shot-audio.png` | 1200 x 675 | Audio effects of a clip or track and the loudness setting. |
| `shot-export.png` | 1200 x 675 | Export dialog or queue with a social preset. |

Link placeholder in `README.md` to replace: `DISCORD_INVITE_URL`.
