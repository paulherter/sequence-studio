# Contributing with AI coding tools

You may use AI coding tools (assistants, agents, autocomplete) on this repository. You stay responsible for every line you submit. The rules in [CONTRIBUTING.md](CONTRIBUTING.md) apply unchanged; this guide adds habits that keep tool-written changes reviewable.

## Give the tool the right context

- Point it at [DEVELOPING.md](DEVELOPING.md), [ARCHITECTURE.md](ARCHITECTURE.md), the README of the crate you work on, and [docs/rust/PORTING.md](docs/rust/PORTING.md) for ports from Swift. Do not let it read the whole repository.
- Say which crate it may change. One task, one crate. Do not let it edit the root `Cargo.toml`, other crates or generated files (for example `crates/sq-gpu/shaders/`) unless that is the task.
- Tell it to stay out of test media and fixture folders.

## Verify, do not trust

- Every claim about the code ("this crate does X", "macOS and Windows share Y") must cite `file:line` that was read in the same session. Docs can be stale; the code wins, then fix the doc.
- Check that every function, flag and command a tool mentions exists (`grep` it). Tools invent APIs and options.
- Run the proof yourself and read the output: `cargo xtask check <crate>` must pass (`fmt`, `clippy -D warnings`, tests). Do not accept "should work".
- Reference data (goldens) must come from the oracle, not from the code under test.

## Habits that came from real mistakes

These cost the project hours before they became rules. Put them in your tool's instructions.

- **Builds are heavy; run one at a time.** A Rust build and test run of this workspace uses all cores and many gigabytes. Never start a second `cargo` while one runs, give agents at most two parallel builds, and run `nice` (`SQ_NICE=10`) or `-j 4` on a shared or small machine. Five parallel builds froze a laptop.
- **Use the machine that has the resources.** If your laptop is small, build and test on a second machine (for example a Windows PC) and sync only the files; Windows also catches path and platform mistakes the Mac does not. Keep that machine's `target` folder separate.
- **Disk hygiene.** Every worktree has its own `target` folder of several gigabytes. Delete it when the task is merged (`rm -rf target`), keep at most a few worktrees, and look at free disk space before a big build. A full disk fails builds in confusing ways.
- **Test first for edit logic.** Write the failing test, then the code. Do not ask a tool to "fix the tests" until you know which side is wrong.
- **Verify with numbers against the reference.** Where a Swift reference exists, behavior is judged by recorded outputs (the oracle, see `docs/rust/ORACLE.md`) and measurements (milliseconds, 1/255 pixel difference, frame counts), not by "looks the same". A claim without a number or a `file:line` is not a result.
- **No freestyling.** Do not redesign, rename or "improve" while porting: port what the reference does, keep its operation order, and write down a deliberate difference. Questions that need the maintainer go into an issue, not into a guess.
- **One task, one branch, small commits.** Short imperative messages, explicit paths in `git add`. Merge the base branch before you start; stale branches produce conflicts in `Cargo.lock` (keep the base's file, then run `cargo check` to regenerate it).
- **Stop when stuck.** After two failed attempts at the same fix, stop and report what you measured instead of trying a third guess.
- **Report with proof.** End a task with the last lines of `cargo xtask check <crate>` and the names of the tests that cover the change. "It compiled" is not proof.

## Keep changes small

- Small diffs, one logical change per commit, explicit paths in `git add`. Reject drive-by refactors, renamed items and reformatting you did not ask for.
- No new dependencies, no `#[allow(...)]`, no `unwrap`/`expect`, no `unsafe` outside the allow-listed crates. If the tool says it needs one, stop and open an issue.
- Prefer less code. Remove dead code and speculative abstractions the tool added.
- Commit messages describe the change in plain imperative English. Leave out chat text and tool-generated boilerplate.

## Never commit

- Footage, test media, screenshots of private projects, or anything under `TestMedia/`.
- Secrets: API keys, signing identities, certificates, tokens, `.env` files. Signing and notarization use environment variables only.
- Personal data: user names, home-directory paths, machine names, emails of other people.
- Code you cannot license under GPL-3.0-or-later. Do not paste code from other projects; if a tool reproduces something recognizable, discard it.

## Before you open the pull request

1. Read the whole diff as if someone else wrote it.
2. Run `cargo xtask check <crate>` for each touched crate, plus dependents for shared crates.
3. For UI changes, check a `--ui-shot` render (see DEVELOPING.md) and that only `DrawTheme` tokens are used.
4. Say in the pull request that a tool helped, and what you verified yourself.

## Not sure yet

- Whether a tool-use disclosure line should become mandatory in the pull request template.
