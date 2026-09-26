# TODO — Future Work

Read [AGENTS.md](AGENTS.md), [USER_STORIES.md](USER_STORIES.md), and [README.md](README.md) before accepting an implementation task. This file owns outstanding work, user decisions, and task boundaries. AGENTS owns working policy; README owns current architecture and operating instructions; USER_STORIES owns product behavior.

This plan replaces the former phase sequence and phase-closure fences. Dependencies below govern execution. A recorded finding is not permission to combine unrelated changes or redesign the app. Accept a bounded assignment, re-read its code, and implement one independent change per commit. Expand a compact backlog entry into a full boundary before implementing it.

## Maintaining this plan

This section owns how TODO is updated. General working principles belong in AGENTS; the review skill owns the review procedure. Keep this file focused on decisions and work that still matter.

1. Give each finding a stable ID, severity, evidence status, relevant paths, expected outcome, validation criteria, and dependencies. Keep hypotheses distinguishable from validated defects; preserve reviewer classifications and record user dispositions. Do not recycle IDs.
2. Keep unassigned work compact. Before implementation, expand the assigned task into a full boundary: intent, dependencies, implementation direction, non-goals, validation, and done criteria. Link that boundary from the finding instead of duplicating it.
3. Record accepted decisions with their rationale and affected tasks. Keep unresolved choices explicit. When a decision changes, record its supersession and update affected boundaries and dependencies before the implementation commit.
4. Use explicit dependencies and readiness to guide execution. Do not rebuild phase-closure fences or imply that every non-blocking issue must land before unrelated work can proceed.
5. In each implementation commit, remove the completed task's full active entry and execution boundary, and record its disposition — evidence, mutation results, review findings, and limitations — in a new `completed_work/<ID>.md`. Leave only a one-line summary linking to that record under dispositions. Update references, dependencies, legacy mappings, and any affected counts or indexes. Put current operations in README.
6. Record deferral or acceptance without change explicitly, with the reason and any revisit trigger. Do not silently drop inherited work or treat a documentation rewrite as an implementation fix.
7. Keep evidence tied to its revision and provenance. Remove obsolete status inventories; historical review results do not certify an executor's current gates. Check local links and ID/dependency consistency after restructuring this file.

## Evidence provenance

The findings come from the 2026-09-06 full-project review of cf39ce5a9777a9acf150bab0a4b93dade6798d4e, using Xcode 26.6 (17F113) and SwiftLint 0.65.1. Commands and bounded scratch probes are recorded in that review conversation; scratch artifacts were removed. Probe descriptions below are reproduction recipes, not checked-in tests or reusable gate certificates. Revalidate affected claims and remedies against the execution revision.

The review did not exercise live providers, physical device switching, macOS 13, or Thread Sanitizer. Device-change evidence used an owned engine and a simulated notification. The inherited Task 42 whole-suite mutant result was not rerun. [N5](completed_work/N5.md)'s record holds the relevant toolchain warnings.

A follow-up sequential review on 2026-09-18 covered the Codex commits `afccaff`–`379cd97` and produced NB26–NB29 and N6. It was read-only against `ec01095`: it inspected the ten diffs, the affected source and tests, `project.yml`, the generated scheme list, and `swiftlint --strict` (0 violations in 95 files). It did not rerun the test suite, the coverage gate, or the mutation evidence those commits' dispositions claim.

N7 comes from NB12's gate run on 2026-09-18 at `6578dac`, which used Xcode 27.0 (27A266a) and Swift 6.4 rather than the Xcode 26.6 recorded above. Toolchain claims recorded against 26.6 have not been revalidated on 27.0.

**Validated** means source inspection and/or the stated review probe supported the finding. **Not independently validated** identifies inherited evidence still needing verification. Architectural benefits are design judgments, even when the underlying structure is validated.

## Decisions and constraints

### Accepted user decisions — 2026-09-06

| ID | Decision | Applies to |
|---|---|---|
| D1 | Introduce one speech-session coordinator incrementally before fixing underruns. It owns start/cancel, the selected audio format, and ordered completion. | NB19, B2, NB9 |
| D2 | Applying a changed live PCM format clears the buffer and cancels its paired network request. Do not defer the change until the next session. | NB9 |
| D3 | Discard a trailing partial PCM byte silently when complete frames exist. Empty and single-byte responses still fail. | NB2 |
| D4 | OpenAI-compatible endpoints may omit Content-Type or use a generic type; reject explicitly unsupported formats. Validate Gemini's native PCM declaration. | NB1 |
| D5 | Refuse cross-origin credential-bearing redirects. Preserve credentials deliberately only on permitted same-origin redirects, subject to the transport rule. | NB4 |
| D6 | Use an explicit ephemeral policy with no persistent cache, shared cookie store, or credential store. | NB5 |
| D7 | Expand the 85% aggregate coverage gate to application logic outside Managers, with narrow documented platform UI/integration exceptions. | NB16 |
| D8 | Remove the unused clipboard-presence console messages. | NB24 |
| D9 | Keep AGENTS concise and principle-based, the review skill procedural, and TODO focused on future work with its own maintenance rules. This separates stable working policy from review operations and evolving plans. | Documentation ownership |

### Accepted user decisions — 2026-09-17

| ID | Decision | Applies to |
|---|---|---|
| D10 | An audio configuration change pauses the session at its position: restart the engine on the new output, keep the buffer and the running request, and cancel any pending automatic start or underrun resume. Play resumes from that position. Speech never moves to a different output device unasked. | NB11 |
| D11 | A new speech attempt (menu, Services, Test Voice) retries starting a stopped engine instead of silently refusing. Success clears the stale failure and starts speech; failure keeps "Couldn't start audio playback. Try again." visible and starts no request. | NB11 |

### Accepted user decisions — 2026-09-18

| ID | Decision | Applies to |
|---|---|---|
| D12 | Raise `ClipboardTTSApp`'s deployment target to macOS 14, the version the gates actually exercise, rather than keep a macOS 13 claim evidenced only by manual smoke checks. macOS 13 support is dropped. | NB29 |
| D13 | Cap one Gemini SSE event at 64 MiB before it ends, and fail a stream that exceeds it on the existing no-playable-audio path. The largest documented event is about 42 MB, which leaves roughly 50% headroom. That figure comes from each Gemini TTS model's 16,384-token output limit at the 25 audio tokens per second Google bills, as 24-kHz 16-bit mono PCM, base64-encoded. | NB6 |
| D14 | A request-state publication that an observer triggers while another publication is still running takes effect as soon as the outermost one finishes, in order and in the same main-queue turn, instead of inside it or on a later main-queue turn. State is then correct when the outer call returns, and main-queue work queued earlier cannot see a stopped request still marked as streaming. | NB8 |

### Accepted user decisions — 2026-09-20

| ID | Decision | Applies to |
|---|---|---|
| D15 | Expanding the gate must not weaken the floor it already has. `Sources/Managers/` keeps its own 85% verdict beside the new 85% verdict over all gated application logic, because a single combined aggregate would let Managers fall to roughly 78% before the combined number dipped, absorbed by the high-coverage views. | NB16 |
| D16 | Exclusions name symbols, not files or directories. Moving production code so that an exclusion could cover a whole file is refused: the adapters share their files with real logic, and per-function coverage records make the narrower arithmetic exact. | NB16 |
| D17 | Each exclusion's end-to-end smoke check is written down and run by the user rather than by the agent, and TODO records until then that the agent has not performed it. | NB16 |

### Accepted user decisions — 2026-09-21

| ID | Decision | Applies to |
|---|---|---|
| D18 | NB20 lands as two independent extractions with a commit and gates each: the pure provider catalogs and the OpenAI-compatible discovery contract first, then the manager's resolved request configuration. | NB20 |
| D19 | The static catalogs keep being published through the guarded metadata token path. The provider identity each published list carries is what lets a Settings form refuse the previous provider's list on the render before `onChange` resynchronizes the manager, so moving that protection into the form is not part of NB20. | NB20 |
| D20 | NB21 is accepted without change. Both layers it names carry behavior with no cheaper owner at this baseline, and replacing the hosted control presses with command-level tests would need its own boundary. | NB21 |

### Accepted user decisions — 2026-09-24

| ID | Decision | Applies to |
|---|---|---|
| D21 | `TTSNetworkManager` always builds its session from `productionSessionConfiguration()`, and a caller may inject only a routing layer applied on top of it, in place of a whole session configuration. Tests route through that layer, so every mock-routed test runs on the production policy, and startup built for a hosted test run passes a layer that fails every request locally. This supersedes NB26's shape, the `.productionDefault` token and `.provided` mode, because no test then needs a way to reach an unrouted manager; it trades a test-only parameter in production code for one session policy under test and the fix NB31 needs. | NB31, NB26 |

These choices do not need to be asked again. Validate exact implementation details against the repository and version-appropriate APIs. Raise a newly discovered material trade-off before changing the boundary; do not reinterpret an accepted decision silently.

### Constraints that remain in force

- Preserve USER_STORIES: the fixed menu icon, Settings-only voice selection, two-click Clear Buffer/Speak behavior, and the clipboard-only OpenAI input-length refusal.
- Preserve README's immutable request snapshots, ordered generation-authorized callbacks, synchronous cancellation authority, and single bounded Gemini HTTP 500 retry. Completion cannot overtake accepted PCM; published isStreaming is not an end-of-stream signal.
- Preserve the 0.1-second initial prebuffer, 0.2-second deferred clipboard policy, exact-end seek/replay, and finite Custom sample rates from 8000 through 48000, including fractions.
- Tests state settings through storage they own (`makeOwnedDefaults`), never the developer's preferences. Do not reintroduce snapshot/clear/restore of the app's own domain, and do not seed real preferences to prove that tests avoid them; a scratch checkout alone does not isolate macOS preferences.

### Investigation gates

NB20's and NB21's inventories were taken on 2026-09-21, produced D18–D20, and are closed; see [NB20](completed_work/NB20.md) and [NB21](completed_work/NB21.md). An investigation can expose new decisions; it does not authorize guessing compatibility limits or removing coverage.

## Active backlog

S-prefixed IDs mark user-requested streamlining work rather than review findings: S1–S2 originated on 2026-09-24, and S3–S4 were recorded on 2026-09-26 after S2's architecture discussion. Finding IDs preserve the full-project review's numbering; NB26–NB29 and N6 continue that sequence from the 2026-09-18 commit review, and N7 from NB12's gate run, both recorded under Evidence provenance. NB30 came from NB26's mutation run, NB31 from the startup inspection that followed it, and NB33–NB41 from S2's review on 2026-09-25 and 2026-09-26. Severity and readiness are separate: needing a decision does not make a defect non-blocking.

### Blocking

No Blocking finding is outstanding; [B2](completed_work/B2.md) was the last one.

### Non-blocking

#### S3 — Make mutation campaign lock ownership explicit

**Design proposal; structure validated by source inspection at `8c80839`, 2026-09-26.** `claim_output` returns a raw file descriptor that `main` leaves open until process exit; the CLI's current lock lifetime is intentional, but acquisition and release are not a scoped resource that can be exercised repeatedly within one process. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py). **Direction:** give output ownership an explicit scope, such as a context manager, covering acquisition before destructive work through restoration and final report writing, with release on normal return and exceptional exits. Preserve existing CLI verdicts, diagnostics, output protection, and signal behavior; subprocess cancellation and deadlines remain NB33/NB35's work. **Acceptance:** direct tests demonstrate release after success and failure, including a refusal after acquisition, and subsequent reacquisition without exiting the test process; the live two-run case still proves exclusion throughout the campaign; applicable mutations detect early release and missing cleanup. **Dependencies:** none; builds on completed NB36, and may inform NB33/NB35 without requiring them. Recording this proposal does not authorize implementation.

#### S4 — Make mutation verifier cases independently runnable

**Design proposal; structure validated by source inspection at `8c80839`, 2026-09-26.** Integration cases are nested inside `end_to_end_cases`, and the verifier's entry point runs every classification, selector, and integration case with no case-selection interface. **Paths:** [verifier](verify-mutation-runner.py), [runner's pure helpers](run-mutants.py), [verification procedure](README.md). **Direction:** expose stable case names and allow focused selection while retaining the full suite as the default; exercise pure spec validation and edit planning directly where this avoids unnecessary subprocess fixtures, retaining end-to-end coverage of wiring, copying, locks, processes, restoration, and reports. No generic mutation framework or runner redesign is needed. **Acceptance:** a named selection runs only its requested cases, unknown names fail explicitly, and the default still runs the complete suite; failures retain named attribution and nonzero exits, and scratch/process ownership survives failures. Preserve existing behavioral coverage and demonstrate equivalent mutation detection before replacing integration assertions with direct tests, following AGENTS' coverage-removal rule. **Dependencies:** none; independent of S3 and NB38. NB18 concerns Swift test dependencies and does not own this Python verifier work. Recording this proposal does not authorize implementation.

#### NB17 — Test teardown does not own every queued audio action

**Validated — ownership trace.** Fixed waits remain in Services/audio/metadata tests. Draining a network delivery queue does not drain the player buffer queue, publications, or pending automatic start. This is a missing guarantee, not a claim the baseline observed an escaping callback. **Paths:** [Services tests](Tests/ServicesCoordinatorTests.swift), [audio tests](Tests/AudioPlayerManagerTests.swift), [test factory](Tests/TestNetworkSupport.swift), [audio owner](Sources/Managers/AudioPlayerManager.swift), metadata tests. **Direction/acceptance:** test-owned audio lifecycle, explicit processing/publication completion, cancelled scheduled work, unconditional teardown, and locally counted late work. Forced delayed callbacks cannot escape even after assertion timeouts. Preserve network scope accounting.

#### NB18 — Pure tests inherit heavyweight integration dependencies

**Validated — construction trace.** Secret/state tests inherit the global network lifecycle; an About test creates audio/network managers solely to forward metadata. **Paths:** [SecretStoreTests](Tests/SecretStoreTests.swift), [SettingsSecretStateTests](Tests/SettingsSecretStateTests.swift), [SettingsAboutTests](Tests/SettingsAboutTests.swift), test support. **Direction/acceptance:** test pure units with owned memory dependencies and no audio/session resources; retain a small hosted wiring suite. Meaningful mutants must still detect protected behavior. Improved preferences ownership alone does not justify removing shared asynchronous safeguards.

#### NB24 — Clipboard-presence console messages have no release purpose

**Validated — print calls; legacy Task 46.** They disclose clipboard presence, not copied text. **Paths:** [TextExtractionManager](Sources/Managers/TextExtractionManager.swift), [text tests](Tests/TextExtractionManagerTests.swift), README if a diagnostic description changes. **Direction/acceptance:** implement D8 by removing the prints. Preserve populated/empty injected clipboard returns; introduce no new error or alternative logging; never use the shared pasteboard.

#### NB27 — A later malformed Gemini inline part discards audio already validated ahead of it

**Validated — source inspection.** `audioPayload(in:)` now reads every part before returning, so any part whose `inlineData` is unreadable or declares a non-audio media type makes the whole candidate `.invalid` and takes the fatal revocation path, dropping audio parts that passed validation earlier in the same event. Before `912bf09` the first audio part returned immediately and a later part was never read. The trade-off is deliberate and documented; the exposure is that a provider adding one non-audio inline part to an `AUDIO`-modality response would silence an utterance that previously played. **Paths:** [audioPayload](Sources/Managers/TTSNetworkManager+GeminiStreaming.swift), [Gemini streaming tests](Tests/TTSNetworkManagerGeminiStreamingTests.swift), README. **Direction:** decide from provider evidence whether an unplayable part accompanying valid audio is a corrupt stream or an ignorable extra; keep the current rule until that evidence exists. **Acceptance:** the chosen rule and its evidence are stated in README, and both a malformed-only event and a mixed valid/malformed event keep a test.

#### NB28 — Three landed invariants carry no recorded mutation evidence

**Validated — TODO inspection.** The [NB2](completed_work/NB2.md), [NB3](completed_work/NB3.md), and [NB7](completed_work/NB7.md) dispositions describe the new behavior but record no mutants, while NB1, NB4, NB5, NB9, NB10, and B2–B4 each name the mutants that fail a named test. AGENTS requires a revert, a plausible regression, and an over-restriction where applicable for each added or changed invariant. Inspection indicates the obvious reverts do die — the parity predicate against `testOpenAICompatibleResponsesKeepACompleteFrameBeforeTrailingPartialBytes`, first-part-only Gemini delivery against `testGeminiDeliversEveryAudioPartInOrderAndJoinsPartialFrames`, and endpoint inference against `testCustomGoogleLookingHostUsesOpenAICompatibleModelDiscovery` — but that is reasoning, not a run. **Paths:** the NB2/NB3/NB7 records, [PCM completion](Sources/Managers/TTSNetworkManager+Failures.swift), [Gemini streaming](Sources/Managers/TTSNetworkManager+GeminiStreaming.swift), [provider dispatch](Sources/Managers/TTSNetworkManager.swift). **Direction/acceptance:** run the missing mutants in isolated scratch copies and record each against the named test that fails it, or record why a category does not apply. Run them through README's `run-mutants.py` procedure.

#### NB31 — Hosted startup builds managers on the unrouted production session

**Validated — source inspection, 2026-09-24, at `2f1843a`; no request was observed.** `AppStartupDependencies.make` builds its manager with no session configuration in both branches, so every graph it returns holds a session without mock routing, the exposure NB26 closed in the test factory. Two places reach it. `AppStartupDependenciesTests` builds four such graphs, and each test invalidates its session in a `defer` and sends no request. The hosted app's own graph, built by `ClipboardTTSApp.init` when XCTest launches the host, keeps its session for the whole run. Its `ServicesCoordinator` observes `NotificationCenter.default`, and `streamTTS` does not refuse an empty key, so a Services notification posted there during a run would send a request to `api.openai.com` whenever the host's audio engine can start. No test posts there today, because every Services test posts to its own `NotificationCenter()`, so only convention keeps the test process off the network. **Paths:** [startup](Sources/ClipboardTTSApp.swift), [startup tests](Tests/AppStartupDependenciesTests.swift), [manager](Sources/Managers/TTSNetworkManager.swift), [session policy](Sources/Managers/TTSNetworkManager+SessionPolicy.swift), [test factory](Tests/TestNetworkSupport.swift), [policy test](Tests/TTSNetworkManagerSessionPolicyTests.swift). **Direction (D21):** replace the manager's optional session configuration with a routing layer the manager applies to `productionSessionConfiguration()`. `TestNetworkFactory` passes its mock routing as that layer, which retires `.productionDefault`, its token, `productionDefaultSessionPolicy()`, and `.provided`; the policy test then reads the policy from a mock-routed manager's own session. `AppStartupDependencies.make` takes a routing layer as well: its hosted-test branch passes one that fails every request locally, and the startup tests pass it for the production branch too, so no test builds an unrouted session. **Acceptance:** a request issued from any manager a hosted-test graph returns fails locally without leaving the machine; production startup applies no routing and still builds the NB5 policy; NB5's revert of the default still fails the policy test; every mock-routed test passes on the production policy; the existing startup isolation tests and NB30's registration tests still hold. **Dependencies:** none; supersedes NB26's factory shape.

#### NB33 — A terminal Ctrl-C can cut the mutation runner's restore short

**Reported by S2's review, 2026-09-25; not independently validated.** A terminal Ctrl-C signals the whole foreground process group, so the `xcodegen` that `run-mutants.py` runs to regenerate the copy after a restore dies with it; `check=True` then raises, and the runner exits 2 with a generic tool error rather than "interrupted". The reviewer's stand-in probe left the copy's `project.yml` restored but its generated file mutated. The verifier's signal cases signal only the runner's PID, and README's statement that signals let restoration finish overstates this case. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py), README. **Direction/acceptance:** shield tool children from a terminal signal (for example by starting them in their own session) and add a verifier case that signals the process group, or narrow README and the diagnostic; either way a process-group SIGINT during regeneration must not leave a mutated copy reported as restored. By user decision on 2026-09-25 this also covers a post-restore regeneration that fails for any reason: nothing tests that the run then stops, since a `check=False` mutant of that call survives the verifier, so a verifier case must hold it.

#### NB34 — A test that crashes, exits, or times out reads as `FAILED-UNNAMED`

**Reported by S2's review, 2026-09-25, from real Xcode 27.0 runs; not independently validated.** `fatalError` or `exit` inside a test, and a test exceeding its execution allowance, each ended in `** TEST FAILED **` with no `error: -[…]` line, so `classify` returned `FAILED-UNNAMED` and the run exited 0, although Xcode printed `Failing tests:` naming the test. README and `classify`'s docstring describe `FAILED-UNNAMED` as a failure naming no test, such as a crash between tests. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py), README. **Direction/acceptance:** read the named failures a failed run reports for crashes and timeouts, or treat `FAILED-UNNAMED` as unjudged and document how to resolve it; README and the docstring then match real logs, and a verifier case holds the chosen reading.

#### NB35 — Nothing bounds a hanging mutant

**Reported by S2's review, 2026-09-25, with a real hang run; not independently validated.** `run-mutants.py` starts `xcodebuild test` without test timeouts, so a mutant that deadlocks blocks the runner until it is interrupted, which ends the campaign with exit 2 and no verdict for that mutant. **Paths:** [runner](run-mutants.py), README. **Direction/acceptance:** bound each mutant's test run (for example `-test-timeouts-enabled YES` with a documented allowance, which NB34's reading then names) or document the hang and its recovery.

#### NB38 — The runner's copy could be built by one walk of the index

**Design proposal from S2's review, 2026-09-25; not independently validated.** `build_copy` composes `git archive HEAD`, the changed paths filtered through the index, and removal-first ordering; four earlier S2 review rounds found Blocking defects in that composition. Mirroring every `git ls-files --cached` path from the working tree with the same file and symlink checks would reach the same state for this repository without ordering hazards or `git archive` attributes. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py). **Direction/acceptance:** if adopted, every existing copy-building verifier case passes unchanged and each removed step's behavior has an owner.

#### NB39 — A mutant write that fails partway can leave the copy mutated

**Reported by S2's review, 2026-09-25; not independently validated.** `run-mutants.py` writes a mutant's planned texts inside the `try` whose `finally` restores them, but moving `apply_plan` in front of that `try` survives the verifier, so no case holds it. Should a write fail partway through a multi-file mutant (permissions, a full disk), files already written would stay mutated in the copy that README says remains for inspection; the run still exits 2 with no verdict, and the next run rebuilds the copy. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py). **Direction/acceptance:** a verifier case whose later edit target cannot be written asserts that the earlier target is restored, and the moved-`apply_plan` mutant fails it.

#### NB40 — Nothing holds the runner's lenient decoding of tool output

**Reported by S2's review, 2026-09-26; not independently validated.** `run-mutants.py` reads test logs and a failed tool's stderr with `errors="replace"`, but no verifier case holds either: reading a log strictly, or decoding stderr strictly or not at all, survives. The reviewer's stand-in probe showed that one invalid byte in test output then ends the run with a traceback and exit 1, which README reserves for an unjudged mutant; the copy is still restored and no false verdict results, and real `xcodebuild` output is almost always valid UTF-8. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py). **Direction/acceptance:** cases in which the stand-in test tool and generator emit a non-UTF-8 byte assert the verdicts, the exit codes, and a decoded diagnostic, and the strict-decoding mutants fail them.

#### NB41 — Nothing holds the runner's refusal of an OS error before the control

**Reported by S2's review, 2026-09-26; not independently validated.** `run-mutants.py` refuses an `OSError` raised before the control, such as a mistyped spec path or an `--out` that cannot be created, with `error:` and exit 2, but removing `OSError` from that `except` survives the verifier. The reviewer showed that a nonexistent spec path then ends with a traceback and exit 1, which README reserves for an unjudged mutant; no verdict or copy state is affected. **Paths:** [runner](run-mutants.py), [verifier](verify-mutation-runner.py). **Direction/acceptance:** a case passing a nonexistent spec path asserts exit 2, an `error:` diagnostic, no traceback, and no test run, and the mutant fails it.

### Nits

#### N7 — The automatic-playback prebuffer closure draws an implicit-strong-capture warning

**Validated — clean build output.** The clean `check-coverage.sh` build for NB12 (`6578dac`) reported `'weak' ownership of capture 'self' differs from implicitly-captured strong reference in outer scope [#ImplicitStrongCapture]` at [AudioPlayerManager.swift:275](Sources/Managers/AudioPlayerManager.swift). The inner `[weak self]` scheduler closure sits inside `scheduleAudio`'s `bufferQueue.async` closure, which captures `self` strongly without saying so. The line dates from `503ab88b`, and NB12 did not touch the file. It was not previously recorded, and whether Xcode 26.6 emitted it is unverified. **Paths:** [AudioPlayerManager](Sources/Managers/AudioPlayerManager.swift), [audio tests](Tests/AudioPlayerManagerTests.swift). **Direction:** make the capture intent explicit so the warning resolves without suppression. Keep the prebuffer closure from retaining the manager across its delay. **Acceptance:** a clean build reports no source warning at that site; automatic playback, its generation guard, and B3's pause revocation behave as before; no diagnostic is disabled.

## Ready for implementation

No task is currently expanded into a full boundary. Expand every assigned task into a boundary here before implementing it, and give every change its assigned scope.

## Deferred, accepted, and completed dispositions

Each finding closed or accepted without change has its own record in [completed_work/](completed_work/), holding its full disposition, evidence, and limitations. This list is the index.

- [NB37](completed_work/S2.md) — Fixed in S2 by user decision: `results.json` records how its run ended and identifies its inputs.
- [NB36](completed_work/S2.md) — Fixed in S2 by user decision: a run locks its `--out`, so a concurrent run is refused.
- [S2](completed_work/S2.md) — Done: `run-mutants.py` runs mutation evidence in a scratch copy and reads verdicts from named failing tests; `verify-mutation-runner.py` checks it.
- [S1](completed_work/S1.md) — Done: every build runs strict SwiftLint and fails without it, replacing the standalone lint gate.
- [NB30](completed_work/NB30.md) — Fixed: tests prove each factory session is registered, so teardown invalidates it.
- [NB26](completed_work/NB26.md) — Fixed: no test can obtain a manager whose session reaches the real network.
- [NB25](completed_work/NB25.md) — Fixed: a provider-only switch's metadata invalidation fails a test when it breaks.
- [NB20](completed_work/NB20.md) — Fixed (D18, D19): pure provider catalogs and model discovery, then one resolved request configuration.
- [NB16](completed_work/NB16.md) — Fixed (D7, D15–D17): every compiled source is gated, exclusions name symbols, and Managers keeps its own floor. **Outstanding (D17):** the three exclusions' smoke checks have not been run.
- [NB15](completed_work/NB15.md) — Fixed: the gate refuses any report that does not measure exactly the gated sources on disk.
- [NB8](completed_work/NB8.md) — Fixed (D14): a publication an observer triggers applies in order when the outermost one finishes.
- [NB6](completed_work/NB6.md) — Fixed (D13): each received byte is searched once, and one event is capped at 64 MiB.
- [NB29](completed_work/NB29.md) — Fixed (D12): the app targets macOS 14, and macOS 13 support is dropped.
- [NB13](completed_work/NB13.md) — Fixed: Settings offers a retry for saved keys that could not be read.
- [NB14](completed_work/NB14.md) — Fixed: each model and voice edit applies once and refreshes only the lists it can change.
- [N6](completed_work/N6.md) — Fixed: `displayedCustomSampleRate` is separated from its neighbours again.
- [NB12](completed_work/NB12.md) — Fixed: startup takes the migrated key rather than reading it back from the store.
- [NB11](completed_work/NB11.md) — Fixed (D10, D11): new speech retries a stopped engine, and a configuration change pauses and recovers the session.
- [NB10](completed_work/NB10.md) — Fixed: a fractional Custom rate survives mount and reopen unchanged.
- [N1](completed_work/N1.md) — Fixed: the source comment's count matches its four listed rules.
- [N2](completed_work/N2.md) — Fixed: `.swiftlint.yml`'s function-length rationale describes `streamTTS` as it is.
- [NB2](completed_work/NB2.md) — Fixed (D3): a trailing partial byte no longer fails a response that has complete frames.
- [NB3](completed_work/NB3.md) — Fixed: a Gemini candidate's inline parts are validated first, then delivered in order with split frames joined.
- [N3](completed_work/N3.md) — Fixed: the sidebar provider binding synchronizes settings directly.
- [N4](completed_work/N4.md) — Fixed: the three metadata-provider tests are named for the behavior they protect.
- [N5](completed_work/N5.md) — Fixed: the test bundle targets macOS 14, XCTest's minimum.
- [NB5](completed_work/NB5.md) — Fixed (D6): production sessions keep no cache, cookie, or credential storage.
- [B1](completed_work/B1.md) — Fixed: tests use owned settings storage, and `SettingsView` binds the domain it is handed.
- [B2](completed_work/B2.md) — Fixed (D1): a stream that ran dry resumes when PCM arrives, and a finished stream stays stopped.
- [B3](completed_work/B3.md) — Fixed: pausing revokes the paused stream's pending automatic start.
- [B4](completed_work/B4.md) — Fixed: the tick reads and publishes a position in one main-queue turn.
- [NB19](completed_work/NB19.md) — Fixed (D1): `SpeechSessionCoordinator` owns speech sessions for the menu, Services, and Test Voice.
- [NB7](completed_work/NB7.md) — Fixed: provider identity is normalized once, and only `.gemini` selects Gemini behavior.
- [NB4](completed_work/NB4.md) — Fixed (D5): cleartext redirects and credential-bearing cross-origin redirects are refused.
- [NB9](completed_work/NB9.md) — Fixed (D2): applying a changed PCM format cancels the request paired with the discarded audio.
- [NB1](completed_work/NB1.md) — Fixed (D4): a success response must declare a supported format before any of it plays.
- [NB21](completed_work/NB21.md) — Accepted without change (D20): both layers carry behavior with no cheaper owner.
- [`InMemoryDefaults` mutators](completed_work/InMemoryDefaults-inert-mutators.md) — Accepted without change: `InMemoryDefaults`' domain mutators stay inert.
- [NB22](completed_work/NB22.md) — Completed by the TODO rewrite that replaced the phase handoff.
- No other implementation finding has been deferred or accepted without change.
- Legacy Tasks 14 and 36 remain withdrawn; [USER_STORIES](USER_STORIES.md) governs the fixed icon and Settings-only voice selection. This plan reinstates neither feature.

### Legacy task mapping

| Old task | Current owner | Disposition |
|---|---|---|
| 38 | NB2 / D3 | Fixed; tolerate a trailing partial byte after complete PCM |
| 40 | NB4 / D5 | Fixed; see [NB4](completed_work/NB4.md) |
| 42 | NB25 | Fixed; see [NB25](completed_work/NB25.md) |
| 44 | NB1 / D4 | Fixed; see [NB1](completed_work/NB1.md) |
| 45 | NB5 / D6 | Fixed; see [NB5](completed_work/NB5.md) |
| 46 | NB24 / D8 | Retained; remove prints |
| 48 | NB22 | Missing-rationale premise corrected: both audio files explain their exceptions; cohesion policy belongs in AGENTS, not a forced split task |
| 52 | B2 / D1 | Fixed; see [B2](completed_work/B2.md) |
| 55 | NB7 | Fixed; canonical typed identity |

## Integration acceptance

Review integrated changes against accepted decisions and current USER_STORIES/README. Do not require every non-blocking task to land first: record explicit defer/accept dispositions and reasons.

Use AGENTS for required gates/review. Supplement integration changes with cross-entry playback, cancellation, provider/format switching, failure/recovery, and settings-isolation checks. Inspect warnings and the complete gated population. Static analysis and, when relevant and supported, Thread Sanitizer provide additional evidence; clean output is not proof of race freedom.

Keep hardware and live-provider smoke tests separate from automated test dependencies. Physical switching remains unverified by this baseline; D12 retired the macOS 13 claim instead of evidencing it. Live-provider tests need explicit authorization and credentials; record no keys, copied text, or returned audio. Record evidence at its actual revision. Remove completed full entries in their implementation commits, retaining only concise dispositions/links needed by remaining work.
