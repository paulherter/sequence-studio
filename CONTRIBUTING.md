# Contributing

Sequence Studio is pre-alpha. Open an issue before starting larger work.

## Rules

- Tests first for edit logic. Run `scripts/test.sh [Package]` before sending changes; `scripts/build.sh` must pass.
- Swift 6 with strict concurrency. No warnings suppressed to get around it.
- Time is rational (`value/timescale`), never `Double`.
- The model is value types; undo works on snapshots.
- SQCore must not import AVFoundation or AppKit.
- No footage or other test media in the repository. Keep it in `TestMedia/` (git-ignored) or outside the repo.
- Only GPL-3.0-compatible code (GPL, MIT, BSD, Apache-2.0). Read and check it first, then add an entry to `docs/THIRD_PARTY.md`.
- Keep commits small, in English. Do not deviate from `PLAN.md` without recording the decision in `docs/DECISIONS.md`.

By contributing you agree that your work is licensed under GPL-3.0-or-later.
