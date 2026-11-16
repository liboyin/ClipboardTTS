# Project Reviews and Finding Provenance

This file keeps the provenance of the review findings and the history of task IDs. It is a historical record: it is not rewritten, and it does not certify current validation. [tasks/](tasks/) owns the state of tasks, and [DESIGN.md](DESIGN.md#accepted-decisions) owns the accepted decisions. Where the text below says "TODO", it means the single plan file that held this content until 2026-11-16.

## Evidence provenance

The findings come from the 2026-09-06 full-project review of cf39ce5a9777a9acf150bab0a4b93dade6798d4e, using Xcode 26.6 (17F113) and SwiftLint 0.65.1. Commands and bounded scratch probes are recorded in that review conversation; scratch artifacts were removed. Probe descriptions below are reproduction recipes, not checked-in tests or reusable gate certificates. Revalidate affected claims and remedies against the execution revision.

The review did not exercise live providers, physical device switching, macOS 13, or Thread Sanitizer. Device-change evidence used an owned engine and a simulated notification. The inherited Task 42 whole-suite mutant result was not rerun. [N5](tasks/closed/N5.md)'s record holds the relevant toolchain warnings.

A follow-up sequential review on 2026-09-18 covered the Codex commits `afccaff`–`379cd97` and produced NB26–NB29 and N6. It was read-only against `ec01095`: it inspected the ten diffs, the affected source and tests, `project.yml`, the generated scheme list, and `swiftlint --strict` (0 violations in 95 files). It did not rerun the test suite, the coverage gate, or the mutation evidence those commits' dispositions claim.

[N7](tasks/closed/N7.md) came from NB12's gate run on 2026-09-18 at `6578dac`, which used Xcode 27.0 (27A266a) and Swift 6.4 rather than the Xcode 26.6 recorded above. Toolchain claims recorded against 26.6 have not been revalidated on 27.0.

**Validated** means source inspection and/or the stated review probe supported the finding. **Not independently validated** identifies inherited evidence still needing verification. Architectural benefits are design judgments, even when the underlying structure is validated.

### Full-project review — 2026-11-03

Reviewed clean revision `0ccae841e79f151323181465c8ddefcba9848c2e` from application/audio/Settings/accessibility, network/security/concurrency, and tooling/test-ownership/documentation angles. Independent reviewers `/root/app_review`, `/root/network_review`, and `/root/tooling_review` were each dispatched as `gpt-6.1-sol` with medium reasoning; the main agent independently inspected every recorded finding and the simplification premises. All three reported no Blocking findings. NB54 below, and the completion records of [S5](tasks/closed/S5.md), [S6](tasks/closed/S6.md), [NB52](tasks/closed/NB52.md), [NB53](tasks/closed/NB53.md), and [N11](tasks/closed/N11.md), retain the essential evidence and limitations. The user's requested disposition is to record issues for future work, not implement fixes or supersede existing decisions.

On macOS 26.7.1 with Python 3.9.6, the tooling reviewer ran `./verify-coverage-gate.py` (42/42 cases passed) and `./verify-mutation-runner.py classify/a_passing_run_survives verdicts_and_restore` (2/2 passed) in an external archive of that revision. Shell syntax passed for `check-coverage.sh`, `package.sh`, and `kokoro/start-native.sh`, checked individually with `bash -n` (the main agent checked the latter two). These checks validate tooling only; no XCTest, application build, coverage measurement, mutation of application code, live-provider trial, hardware switch, or VoiceOver session ran. Read-only assessment and documentation changes are exempt from application gates. Repository status and index remained unchanged through review; disposable tooling scratch was removed. Supporting reports remain temporarily at `/tmp/clipboardtts-review-20261103/`; no active entry depends on their retention.

### Second full-project review — 2026-11-03

Reviewed clean revision `23a88719e6fa848f212efd6d07197d912b2ce87d`, the commit recording the review above, from runtime/performance, test-ownership, distribution, accessibility, and simplification angles. At the user's request it did not use the adversarial-review skill; the main agent inspected everything directly and skipped findings already recorded above. It read every file under `Sources/`, the tooling scripts' structure, the cited tests, and the documentation, and ran `grep` inventories over `Sources/` and `Tests/`, `lipo -archs` on the local Release product, and line and word counts. Environment: Darwin 25.6.0, Xcode 27.2 (27B52), SwiftLint 0.65.1. No build, XCTest, coverage, mutation, live-provider, profiling, or VoiceOver run was performed, so performance and prompt claims below are source-derived hypotheses. NB55–NB60, N12–N13, and S7–S11 come from it; the user's disposition is to record them, not implement them.

### macOS 27 gate run — 2026-11-14

After the host was updated from macOS 26 to macOS 27.2.1 (26B131), the user asked for the build and gates to be rerun at clean `adff48a`, then for the failures to be investigated and recorded as tasks. Environment: Apple silicon arm64, Xcode 27.2 (27B52) with the unchanged MacOSX27.2 SDK, XcodeGen 2.46.0, SwiftLint 0.65.1. After deleting the project's derived data and running `xcodegen generate`, `xcodebuild -project ClipboardTTSApp.xcodeproj -scheme ClipboardTTSApp -configuration Debug CODE_SIGNING_ALLOWED=NO build` succeeded, with strict SwiftLint reporting 0 violations in 122 files and no source warnings; the only warning was README's benign AppIntents metadata warning. `./check-coverage.sh` then exited 65 from `xcodebuild test`, before any coverage verdict: 447 tests ran, with 15 assertion failures in 8 tests (B5). The last recorded pass of the same suite was [NB53](tasks/closed/NB53.md)'s final candidate at `eaf528b`: 447 tests, 0 failures, on macOS 26.7.1 (25G241) with the same Xcode. The only later commits are documentation and the marketing-version bump, so the failures come from the macOS 27 runtime, not from a code change. The logs also showed Xcode environment errors unrelated to the macOS build: "CoreSimulator is out of date", the `DVTCoreDeviceCore` plug-in failing to load, and the test host's `com.apple.linkd.autoShortcut` XPC connection being refused. These need the user's Xcode component reinstall, not a repository change.

The cause was isolated with a diagnostic XCTest added only to a `git archive` scratch copy of `adff48a` and run alone with `-only-testing` into scratch derived data. It used `makeOwnedDefaults`, `InMemorySecretStore`, `TestNetworkFactory`, and `makeOwnedAudioPlayer` under `MockURLProtocolTestCase`, so it touched no developer state. The probe printed each host's AppKit subview tree and walked `accessibilityChildren()` for three cases. (1) A bare SwiftUI view held a `Picker` with hidden labels, a `.menu`-style `Picker`, a `Slider`, a `Toggle`, and a `Button`. It was tested windowless, in a borderless offscreen `NSWindow` before ordering, and in the same window after `orderFrontRegardless()`. In every case each control produced only a `_FocusRingView` (plus a `KeyViewProxy` once ordered), with no `NSPopUpButton`, `NSSlider`, or `NSButton`, and the host reported role `AXGroup` with no accessibility children. (2) Hosted `SettingsView` for Gemini still built AppKit text fields, the secure field, the sidebar's `OutlineListRepresentable`, and `SettingsActionButton`'s `NSButton`, but each suggestion picker was only a `_FocusRingView`. (3) Hosted `MenuBarView` held only `_FocusRingView`s. The window case was diagnostic only, since DESIGN forbids window hosts in tests. The scratch copy and its derived data were deleted afterwards; this paragraph is the retained recipe and result. No live provider, VoiceOver session, or launch of the real app ran, so how macOS 27 draws these controls in the production windows was not observed.

## Task IDs

S-prefixed IDs mark user-requested streamlining work rather than review findings: S1–S2 originated on 2026-09-24, and S3–S4 were recorded on 2026-09-26 after S2's architecture discussion. Finding IDs preserve the full-project review's numbering; NB26–NB29 and N6 continue that sequence from the 2026-09-18 commit review, and N7 from NB12's gate run, both recorded under Evidence provenance. NB30 came from NB26's mutation run, NB31 from the startup inspection that followed it, NB33–NB41 from S2's review on 2026-09-25 and 2026-09-26, NB42 from NB35's review on 2026-09-26, NB43 from NB40's investigation on 2026-09-28, and NB44–NB45 from the gap review of the D22 sequence on 2026-09-29, NB46–NB47 from the gap review of the NB31/NB18 group on 2026-10-12, and NB48–NB49 and N8–N10 from the gap review of that session's changes on 2026-10-13. NB52–NB54, N11, and simplification proposals S5–S6 come from the 2026-11-03 full-project review above, and NB55–NB60, N12–N13, and S7–S11 from the second review that day, and NB61 from the gap review of NB57, N11, and N12, and B5 and NB62 from the macOS 27 gate run above, NB63 from NB62's analysis, and S12 from S8's implementation on 2026-11-15, and NB64 from S11's verification on 2026-11-16; B5, NB52, NB53, NB57, NB58, NB59, NB61, NB62, NB63, N11, N12, N13, NB56, NB64, S5, S6, S7, S8, S9, S11, and S12 are closed. Severity and readiness are separate: needing a decision does not make a defect non-blocking.

These two tasks have no record of their own. They were closed inside the record of S2 (the mutation runner):

- [NB37](tasks/closed/S2.md) — Fixed in S2 by user decision: `results.json` records how its run ended and identifies its inputs.
- [NB36](tasks/closed/S2.md) — Fixed in S2 by user decision: a run locks its `--out`, so a concurrent run is refused.

## Investigation gates

NB20's and NB21's inventories were taken on 2026-09-21, produced D18–D20, and are closed; see [NB20](tasks/closed/NB20.md) and [NB21](tasks/closed/NB21.md). An investigation can expose new decisions; it does not authorize guessing compatibility limits or removing coverage.

## Legacy tasks

- No other implementation finding has been deferred or accepted without change.
- Legacy Tasks 14 and 36 remain withdrawn; [USER_STORIES](DESIGN.md#product-requirements) governs the fixed icon and Settings-only voice selection. This plan reinstates neither feature.

### Legacy task mapping

| Old task | Current owner | Disposition |
|---|---|---|
| 38 | NB2 / D3 | Fixed; tolerate a trailing partial byte after complete PCM |
| 40 | NB4 / D5 | Fixed; see [NB4](tasks/closed/NB4.md) |
| 42 | NB25 | Fixed; see [NB25](tasks/closed/NB25.md) |
| 44 | NB1 / D4 | Fixed; see [NB1](tasks/closed/NB1.md) |
| 45 | NB5 / D6 | Fixed; see [NB5](tasks/closed/NB5.md) |
| 46 | NB24 / D8 | Fixed; see [NB24](tasks/closed/NB24.md) |
| 48 | NB22 | Missing-rationale premise corrected: both audio files explain their exceptions; cohesion policy belongs in AGENTS, not a forced split task |
| 52 | B2 / D1 | Fixed; see [B2](tasks/closed/B2.md) |
| 55 | NB7 | Fixed; canonical typed identity |
