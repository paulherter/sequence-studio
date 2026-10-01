# Third-party code and references

Sequence Studio will be GPL-3.0. Code from GPL-3.0, MIT, BSD and Apache-2.0 projects may be reused
after reading and checking it. Every reuse gets a line below: what, from where (commit/file), license.

## References
| Project | License | Language | Use |
|---|---|---|---|
| [palmier-pro](https://github.com/palmier-io/palmier-pro) | GPL-3.0 | Swift | Main UI/architecture reference (Premiere-like). Code reuse allowed with attribution. |
| [openshot-qt](https://github.com/OpenShot/openshot-qt) | GPL-3.0 (GitHub shows NOASSERTION, repo is GPL-3) | Python/Qt (+ libopenshot C++) | Concepts only (keyframe/clip model); little direct reuse. |
| [openreel-video](https://github.com/Augani/openreel-video) | MIT | TypeScript (browser) | Concepts only (timeline interactions, caption styling). |

## Reused code
| Source | License | Form | Use |
|---|---|---|---|
| RNNoise 0.1.1 (xiph/rnnoise, tarball v0.1.1) | BSD-3-Clause (Xiph.Org, Mozilla; license kept in `Packages/SQAudioFX/Sources/CRNNoise/COPYING`) | C, vendored; one addition: `rnnoise_reset()` in denoise.c + rnnoise.h (in-place state reset for seeks, no allocation). No `rnn_reader.c`, no training code | Noise suppression in SQAudioFX. |
