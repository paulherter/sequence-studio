# Contributing

Sequence Studio is GPL-3.0-or-later alpha software. Open an issue before larger work. Issues and pull requests are in English; by taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md). Setup and commands: [DEVELOPING.md](DEVELOPING.md). Design: [ARCHITECTURE.md](ARCHITECTURE.md). Using an AI coding tool: also read [CONTRIBUTING-AI.md](CONTRIBUTING-AI.md).

## Before you start

- Work in your crate. Read that crate's `README.md`, and `docs/rust/PORTING.md` if you port Swift code. Do not read the whole repo.
- Edit logic: write the test first.
- A change that users can see updates the matching chapter in `docs/wiki/` in the same change, if that folder exists in your checkout.

## Rules

- **Tests first** for edit logic; tests live beside the code. Reference data (goldens) comes from the oracle (`docs/rust/ORACLE.md`), never recorded from the Rust code under test.
- **Done means** `cargo xtask check <crate>` is green: `fmt`, `clippy -D warnings`, tests. Before a merge also run it for crates that depend on yours.
- **Small commits**, English, imperative messages, explicit paths (`git add <paths>`, not `git add -A`). One logical change per commit.
- **Lints are deny:** no `unwrap`, `expect`, `todo!`, `unimplemented!`, `dbg!` in non-test code; write `Rc::clone(&x)` instead of `x.clone()` on `Rc`/`Arc`; no `unsafe` outside `sq-gpu`, `sq-video-hw`, `sq-platform-*`. Fix the code instead of adding `#[allow]`.
- **No new dependencies without discussion.** Dependencies are pinned in the root `[workspace.dependencies]`; propose the crate and its license in an issue first. Only GPL-3.0-or-later compatible licenses (see `deny.toml`). Borrowed code is read, checked and listed in `docs/THIRD_PARTY.md`.
- **Time is rational**, never `f64`. Keep floating-point operation order when porting.
- **American English** in code, comments, UI text and docs (color, gray, center, canceled, behavior).
- **UI:** use `DrawTheme` tokens and the draw-kit components only; no hard-coded colors, fonts or radii. One icon set (`SQIconPathData`, Phosphor); no system icons. Popups, menus, sheets and alerts use the Sequence Studio design, not system UI. A UI change is made once in the shared code and has to look the same on macOS and Windows.
- **Comments say why, not what.** A deliberate shortcut gets `// shortcut: <limit>, <when to upgrade>`. Public items get `///` docs. Less code is better: no dead code, no speculative abstractions, no duplicate helpers.
- **Names:** use the project vocabulary (`docs/VOCABULARY.md`). Abbreviate Sequence Studio only as SQ/sq (crates `sq-*`, env `SQ_*`, files `.sqproj`).
- **No footage or other media** in the repository, and no secrets, certificates or personal paths.

## Pull requests

Describe what changed and how you checked it (paste the last lines of `cargo xtask check <crate>`). Keep the diff focused; unrelated cleanups go in a separate pull request.

## License and your contribution

Sequence Studio is GPL-3.0-or-later with the additional terms in [LICENSE-ADDITIONAL-TERMS.md](LICENSE-ADDITIONAL-TERMS.md); the name, logo and the mascot Pip are reserved (see [BRAND.md](BRAND.md)). By contributing you agree that your work is licensed under GPL-3.0-or-later, and you grant Paul Herter a permanent, worldwide, free right to use, change and license your contribution under other terms as well (for example for app store builds or a future license). You keep the copyright of your contribution.

## Where things are

- Set up, build, run, test, package: [DEVELOPING.md](DEVELOPING.md). Crate map and data flow: [ARCHITECTURE.md](ARCHITECTURE.md). Using AI tools: [CONTRIBUTING-AI.md](CONTRIBUTING-AI.md).
- The earlier Swift app is not part of this repository; do not send Swift changes.

## Not sure yet

- Whether the pull request template (`.github/PULL_REQUEST_TEMPLATE.md`) should ask for the last `cargo xtask check` lines.
