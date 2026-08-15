# SF1 iOS port — agent rules

These rules are mandatory for every human or LLM coding agent working in this
repository. `AGENTS.md` is canonical; tool-specific instruction files must
point here instead of creating divergent rules.

## 1. Canonical workspace and storage

- The only working checkout is `/Volumes/iPhone/PS1_Rrecomps/SF1`.
- Before reading or writing project state, verify `/Volumes/iPhone` is mounted
  and the checkout contains `.git`. Stop if either check fails.
- Start every shell with `source tools/project-env.sh`.
- Keep source, dependency checkouts, build trees, DerivedData, caches, temporary
  files, logs, screenshots, captures and test artifacts on `/Volumes/iPhone`.
- Use repository-relative `out/` for builds and `tmp/` for disposable evidence.
  Both are ignored by Git.
- Do not deliberately create project files under `/Users`, `/tmp`, Desktop,
  Documents or Xcode's default DerivedData. Installed compilers, SDKs, agent
  skills and platform-mandated agent metadata are not project artifacts.
- Simulator validation may create a system-managed app/container or crash log
  on the internal drive. Copy needed evidence to `tmp/validation/`, then
  uninstall the test app and remove only the project-specific local artifacts.
- Never copy the repository to the internal SSD to work around a build issue.
  Diagnose the external-volume issue or stop and report it.

## 2. Session startup and handoff

Before changing code:

1. Read this file and `docs/AI_HANDOFF.md`.
2. Inspect `git status --short --branch`, current remotes and recent commits.
3. Read the Brains RAG startup context when available:
   - `master/system.md`
   - `master/conventions.md`
   - the current agent's `master/sessions/<agent>-last.md`
4. Search the relevant project/reference brains before assuming architecture or
   user environment details.
5. Inspect the active coding client's skill/plugin catalog and load every skill
   relevant to the task before editing.

After a meaningful milestone, before a risky operation and before ending:

- Update `docs/AI_HANDOFF.md` with exact state, paths, commands, evidence,
  blockers and next step.
- Commit and push verified source/doc changes to the public fork so the external
  drive is not the only copy.
- Never claim unverified work is complete; explicitly list what was not tested.

## 3. RAG and primary-source requirements

- Apple platform or API question: search Apple-focused RAG and use the installed
  Apple/Xcode documentation skill or Xcode-bundled documentation.
- Metal, GPU, shader or renderer work: search `shared/metal-programming` and
  `shared/metal-build-tooling` before design or implementation.
- Recompilation, PsyCross, SDL, PS1 runtime or portability work: search
  `shared/recomp-porting` and `shared/recomp-porting/refs/sf-pc-port`; search
  `shared/recomp-porting/refs/sdl` when SDL behavior is involved.
- Use `brain_search_many` across those brains for cross-cutting questions. Read
  the cited source file, not only the vector-search snippet.
- For API signatures and current platform behavior, prefer primary sources:
  Xcode headers/docs, Apple documentation, official library docs and upstream
  source. RAG provides context, not permission to guess.
- If Brains or a required skill system is unavailable, record that fact and use
  the best available primary source. Do not silently skip the lookup.

## 4. Skill routing

At minimum, route tasks as follows when those skills exist:

- Apple API/framework or Xcode docs: Apple documentation skill.
- Metal/OpenGL migration, shaders, GPU capture: graphics/Metal skill.
- iOS app structure, lifecycle or UI: iOS design/UIKit/SwiftUI skill.
- Build, signing, toolchain or Xcode failure: Apple build skill.
- Tests, smoke tests or flaky validation: testing skill.
- Async work, render threads or data races: concurrency skill.
- Performance, memory or thermal work: performance skill.
- Simulator/device launch and UI inspection: iOS debugger/simulator skill.

Read skill instructions before writing code. Do not invoke a skill by name when
the current client does not provide it; use the equivalent documented workflow.

## 5. Architecture boundaries

- Preserve the portable targets: `sf_core`, `sf_assets`, `sf_disc`, `sf_psx`,
  `sf_platform_input` and `sf_game`.
- Keep Apple APIs in the iOS host/backend boundary. Do not leak UIKit, Metal,
  AVFoundation or GameController into portable gameplay targets.
- Preserve guest timing, deterministic state and the existing `GR_*`/
  presentation boundary unless a reviewed design requires otherwise.
- Prefer a narrow backend implementation over rewriting gameplay or guest
  behavior.
- The current UIKit target is a bootstrap, not proof that gameplay is running.

## 6. Required validation evidence

Build success alone is not proof that a change works.

For every change, run the smallest relevant matrix and save evidence under
`tmp/validation/<date-task>/`:

- Portable C++: affected build plus deterministic CTest coverage.
- iOS host/build files: iPhone arm64 build and arm64 Simulator build.
- UI or lifecycle: launch in Simulator or device, inspect the visible UI, and
  capture a screenshot plus relevant logs.
- Renderer/Metal/shader: render a known scene, inspect the image, capture logs,
  enable Metal validation, and use GPU Frame Capture when practical. Compare
  against a known-good reference when available.
- Input: verify real or simulated controller/touch events and log state changes.
- Audio/FMV: verify audible/visible output, timing and interruption/resume paths;
  record logs and media metadata.
- Device-only behavior: test on a physical device. If no device is available,
  mark it `NOT VERIFIED ON DEVICE`.

Before saying "fixed", "working", "good to go" or equivalent:

1. Reproduce the original failure when applicable.
2. Run the relevant build/test matrix.
3. Perform runtime smoke validation through visual output, logs, captures or
   direct interaction.
4. Check `git diff --check` and inspect the final diff.
5. State exact evidence and remaining untested risk.
6. Remove any project-specific Simulator/Xcode artifacts written outside the
   external workspace after their evidence has been preserved.

Do not add automated retail-game launches to CTest. Interactive game validation
must remain an explicit smoke-test step using the user's legal disc image.

## 7. Legal data and secrets

- Never commit or upload BIN/CUE files, extracted retail assets, saves, generated
  retail data, credentials, signing keys, provisioning profiles or tokens.
- Local legal disc staging is `tmp/discs/sf1/`; BIN and CUE stay together and
  the CUE filename reference must exactly match the BIN.
- Treat all GitHub content as public. Review staged files before every commit.
- Do not print secrets in logs or handoff documents.

## 8. Git and GitHub

- `origin` must be the public fork `https://github.com/negroISO/SF-pc-port.git`.
- `upstream` must be `https://github.com/Madxbio97/SF-pc-port.git`.
- Main iOS integration branch: `ios-port`. Use focused feature branches for risky
  work and merge only after validation.
- Do not force-push, rewrite shared history, or push directly to upstream.
- Stage explicit paths. Exclude unrelated files and inspect `git diff --cached`.
- Commit messages are terse and describe the verified milestone.
- Push each meaningful verified milestone; open an upstream PR only when the user
  explicitly asks.

## 9. Current baseline commands

After `source tools/project-env.sh`:

```sh
cmake --preset ios-device
cmake --build --preset ios-device-core-release
cmake --build --preset ios-device-shell-release

cmake --preset ios-simulator
cmake --build --preset ios-simulator-shell-debug
```

The authoritative current status and next task are in `docs/AI_HANDOFF.md`.
