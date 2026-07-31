# TODO — Remediation Hand-over

This document is the executable plan for resolving the findings from the whole-project
adversarial review. It replaces the previous hand-over, whose task list and line references
no longer matched the repository.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md`
owns product behavior; `README.md` owns current architecture and operating instructions.
Keep those documents current rather than duplicating their content here.

## Working rules

- Execute tasks in the order shown unless a task explicitly says it is independent.
- There are exactly 5 remaining numbered tasks. Each task MUST be one self-contained implementation
  commit: do not combine tasks in one commit, split a task across commits, or include code
  belonging to a later task.
- Every task must leave the repository coherent and independently pass all required tests,
  coverage, lint, and review gates. If that is impossible within the stated boundary, stop
  and ask the user to revise the task instead of borrowing changes from another task.
- When execution exposes a material ambiguity or trade-off, follow the escalation rules in
  `AGENTS.md`; do not broaden or rewrite the task boundary without the user's direction.
- Before implementation, re-read every path named by the task because line numbers and
  surrounding code may have moved.
- Add tests that encode the user or system consequence of the behavior. Mutation-test every
  new assertion in an isolated scratch copy as required by `AGENTS.md`.
- Unit tests MUST NOT contact external services, write to `NSPasteboard.general`, use the
  developer's Keychain, or leave changes in the app's real `UserDefaults` domain.
- Documentation and tests required to explain and verify a task belong in that task's commit.
  None of the 15 implementation tasks may use the documentation-only review exemption for the
  task as a whole.
- Remove a completed task from this file in its implementation commit. Move durable decisions
  or architectural facts into `README.md` rather than leaving completed history here. A concise
  hand-over note is permitted only when it materially constrains remaining work, as defined in
  `AGENTS.md`.

## Per-task commit checklist

Complete this checklist separately for each numbered task:

1. Start from the commits for its declared dependencies and confirm the worktree state.
2. Implement only that task, its focused tests, required documentation, and removal of its
   completed entry from this file.
3. Mutation-test every new assertion in an isolated scratch copy, including a plausible future
   regression and the trade-off introduced by the constraint.
4. Generate the project when `project.yml` changed or the generated project is absent:

   ```bash
   xcodegen generate
   ```

5. Run the task-specific tests plus both complete repository gates:

   ```bash
   ./check-coverage.sh
   swiftlint --strict
   ```

   Inspect the per-file coverage output rather than relying only on the aggregate result.
6. Before staging or committing, run the adversarial-review skill on the task's complete dirty
   tree. Give the reviewer that task's purpose and treat still-numbered tasks in this document
   as known, unchanged, out-of-scope work; this must never hide a defect introduced, exposed,
   or worsened by the current task.
7. Fix every blocking finding and trivial non-blocking finding, rerun the tests and lint, and
   repeat review. Any edit made in response to review invalidates the earlier gate results.
   Continue until no blocking finding remains; ask the user to fix, defer, or ignore any other
   non-blocking finding.
8. Only after the final gates and review succeed, stage explicit paths, inspect the staged diff
   and `git status`, and create that task's single commit using the `AGENTS.md` message format.
   Never commit with a failed gate, an unexplained repository change, or a pending review
   disposition.

## Work map

| Issue or requested change | Classification | Remediation task |
| --- | --- | --- |
| Required voice, icon, and About UI is missing | Blocking | 13–15 |
| The Swift 5 project is not clean under complete concurrency checking | Non-blocking | 16 |
| Playback starts immediately on the first playable packet | Requested implementation change | 12 |

## Decisions already made

- Phase 0 is complete. Tests create network managers and sessions through the hermetic mock
  factory, and test teardown invalidates registered sessions and drains protocol work before
  releasing the next test. See `README.md` for the operating contract.
- The Custom provider's PCM sample rate will be configurable. OpenAI and Gemini remain fixed
  at 24 kHz unless their documented response formats change.
- The Custom provider follows the OpenAI-compatible request contract: model and voice are
  configurable, required values and are included in every Custom speech request.
- Changing audio format invalidates buffered audio. Rebuilding the graph therefore stops
  playback and clears the buffer.
- The progress slider remains a product requirement, but elapsed and remaining time labels do
  not. Do not add time-label UI unless `USER_STORIES.md` changes again.
- Automatic playback will wait 0.1 seconds after the first playable audio packet arrives.
  This is an implementation constraint intended to accumulate a small startup buffer, not a
  user story.
- API secret values belong in the Keychain, not `UserDefaults`, URLs, logs, fixtures, or
  committed files. Tests may use unmistakably fake tokens.
- Do not switch the project to Swift 6 as part of this remediation. First make the Swift 5
  build clean with complete concurrency checking; a language-mode migration is separate work.

---

## Phase 2 — Repair network state and failure behavior

## Phase 4 — Repair audio boundaries and Custom format

### 12. Add a 0.1-second automatic-playback prebuffer

**Classification:** Requested implementation change

**Depends on:** Task 11 (complete)

**Problem.** `AudioPlayerManager.scheduleAudio` currently schedules the first playable PCM
buffer and calls `play()` immediately. A small or slowly followed first packet can be consumed
before enough subsequent audio is buffered, causing startup underrun.

**Required change.**

1. Start a one-shot 0.1-second delay when the first packet containing at least one complete PCM
   frame is accepted for the current stream generation.
2. Continue appending and scheduling packets during the delay so playback begins with the
   accumulated startup buffer.
3. Associate the pending start with `scheduleGeneration`. `stop()`, Clear Buffer, a new stream,
   or any format-reset operation must cancel or invalidate it so an old delayed action cannot
   restart playback.
4. Start at most one automatic-playback delay per stream. Later packets must not postpone the
   original deadline or schedule additional starts.
5. Keep `hasAudio` and `bufferDuration` truthful during prebuffering, but leave `isPlaying`
   false until `playerNode.play()` actually runs.
6. Make delayed-start scheduling directly testable with an injected clock/scheduler or an
   equivalently isolated component. Automated correctness tests must not depend only on
   imprecise wall-clock sleeps.
7. Do not add this delay to `USER_STORIES.md`. After implementation, update README's Audio or
   Network architecture description so it no longer claims playback starts on the first bytes
   and instead records the 0.1-second prebuffer.

**Tests and falsification.**

- After the first playable packet, assert audio is buffered but playback has not started
  before the 0.1-second deadline.
- Assert playback starts once after the deadline and includes packets received during the
  prebuffer window.
- Stop before the deadline and prove the delayed action cannot start playback.
- Start a new generation before the deadline and prove the old generation cannot start it.
- Cover a sub-frame packet followed by enough bytes for the first complete frame; the delay
  begins only when playable audio exists.
- Mutation-test immediate playback, rescheduling the deadline on every packet, and failure to
  invalidate the pending start.

**Done when.** Automatic playback begins once, 0.1 seconds after the first playable packet for
the still-active stream, with no delayed restart after cancellation, replacement, or format
change.

## Phase 5 — Complete the required UI

### 13. Add provider-aware voice selection to the menu

**Classification:** Blocking

**Depends on:** Phase 1 (complete)

**Problem.** Voice selection exists only in Settings, although `USER_STORIES.md` requires it
in the menu and restricts changes to idle state.

**Required change.**

1. Add a menu voice control bound to the selected provider's persisted voice.
2. Populate it from provider-authoritative metadata that passed Task 5's freshness guard.
   Verify at execution time whether OpenAI exposes voice discovery; if it does not, use and
   document a version-appropriate list from official documentation rather than inventing an
   endpoint. Define Custom behavior from the contract recorded in README Design Assumptions.
3. Disable voice changes whenever streaming is active or audio remains buffered; "idle" means
   neither condition is true.
4. When changed at idle, update the network manager's next-request settings without duplicating
   setting-key literals or reconstructing unrelated state.
5. Keep Settings and menu selection synchronized through the shared persisted value.

**Tests and falsification.**

- Verify the binding selects the correct provider-specific voice.
- Verify the control is enabled only when idle.
- Switch provider and assert stale voices cannot be selected.
- Verify a menu change is used by the next intercepted TTS request.
- Mutation-test allowing a change while paused with buffered audio.

**Done when.** The menu offers only current-provider voices, stays synchronized with Settings,
and cannot alter an active or buffered read.

### 14. Make the menu-bar icon reflect playback state

**Classification:** Blocking

**Depends on:** Tasks 6, 9, and 12

**Problem.** `ClipboardTTSApp` always uses `waveform.circle`, so idle, playing/streaming, and
paused states are indistinguishable.

**Required change.**

1. Use a state-driven `MenuBarExtra` label rather than a constant `systemImage` initializer.
2. Define one symbol and accessibility label for:
   - idle: no stream and no buffered audio;
   - active: network streaming or audio playing;
   - paused: buffered audio exists but neither streaming nor playing.
3. Make state precedence explicit so startup, prebuffer delay, completion, pause, clear, and
   error transitions cannot select contradictory icons.

**Tests and falsification.**

- Put state-to-symbol selection in a pure helper and test every meaningful boolean combination.
- Test transition sequences: idle → streaming → playing → paused → playing → cleared.
- Mutation-test precedence that labels buffered-and-playing audio as paused.

**Done when.** The status item and accessibility label truthfully reflect idle, active, and
paused state through the complete lifecycle.

### 15. Add an About action

**Classification:** Blocking

**Depends on:** Nothing

**Problem.** Settings lacks the About entry required by `USER_STORIES.md`.

**Required change.**

1. Add a conventional About action in Settings or its standard macOS command location.
2. Prefer the system About panel and bundle metadata over a custom window unless product
   requirements demand more.
3. Show application name and version from bundle metadata. Reference the existing license
   without duplicating its full text in source.
4. Keep this task separate from release, notarization, or marketing work.

**Tests and falsification.**

- Add a construction or action-routing test that does not display an interactive panel during
  the automated suite.
- Verify version text comes from bundle metadata rather than a second hard-coded value.

**Done when.** A user can open standard About information from the application UI.

## Phase 6 — Concurrency hardening

### 16. Eliminate complete-concurrency warnings in Swift 5 mode

**Classification:** Non-blocking

**Depends on:** All earlier manager and UI state changes

**Problem.** A build with `SWIFT_STRICT_CONCURRENCY=complete` reports mutable state on the
URL-session delegate, non-Sendable manager captures, and a concurrently captured mutable
voice-list local. These become errors in Swift 6.

**Required change.**

1. Run a clean strict-concurrency build and inventory every warning before choosing isolation.
2. Put observable UI state on `@MainActor` where practical.
3. Keep queue-owned network/audio buffers behind their existing explicit synchronization, and
   make cross-isolation handoffs visible.
4. Replace mutable captured locals with immutable values before dispatch.
5. Treat URL-session and notification callbacks as concurrent entry points. Hop to the correct
   actor/queue before touching isolated state.
6. Avoid `@unchecked Sendable` as a warning silencer. If it is genuinely required for an
   Apple delegate type, document the protected fields and invariant and test concurrent entry.
7. Add `SWIFT_STRICT_CONCURRENCY: complete` to `project.yml` once the build is clean so future
   warnings are visible. Do not change `SWIFT_VERSION` in this task.

**Tests and falsification.**

- Run the full test/coverage gate under Thread Sanitizer when feasible for the manager tests;
  record and resolve any failures rather than treating a clean run as proof of absence.
- Exercise provider switching, stop/replacement, metadata races, seek during streaming, and
  Services notifications after the isolation changes.
- Mutation-test removal of an actor hop or immutable capture where a deterministic test can
  expose the regression.

**Done when.**

```bash
xcodebuild \
  -project ClipboardTTSApp.xcodeproj \
  -scheme ClipboardTTSApp \
  -configuration Debug \
  SWIFT_STRICT_CONCURRENCY=complete \
  CODE_SIGNING_ALLOWED=NO \
  build
```

completes with no Swift concurrency warnings, while the project remains in Swift 5 mode and
all normal gates pass.

---

## Final acceptance sweep

After the numbered tasks are complete:

This sweep supplements the 15 per-task reviews. It is not Task 17 and cannot replace or defer
testing, linting, or adversarial review required before any of the 15 implementation commits.
If it discovers new work, record and execute that work as a new self-contained task rather
than folding it retroactively into a completed commit.

1. Run `./check-coverage.sh` and manually inspect the per-file manager coverage report; the
   aggregate must remain at least 85%.
2. Run `swiftlint --strict` and the strict-concurrency build from Task 16.
3. Confirm with repository searches that:
   - tests do not write to `NSPasteboard.general`;
   - tests cannot construct a live-network `TTSNetworkManager`;
   - production API-key values do not use `@AppStorage`/`UserDefaults`, URL queries, committed
     fixtures, or logs;
   - no response decoder derives provider identity from current mutable settings;
   - persisted settings keys have one declaration.
4. Perform manual smoke tests for clipboard and Services input, Clear Buffer, provider
   switching during a request, bad credentials, Gemini first-audio latency, seek-to-end and
   replay, Custom non-24-kHz audio, the 0.1-second startup prebuffer, voice locking, status
   icons, and About.
   Obtain user permission and credentials before any live provider test; never record keys.
5. Run the adversarial-review loop on the complete remediation range until no blocking
   findings remain. Resolve or obtain explicit user disposition for every remaining
   non-blocking finding.
6. Reconcile `README.md` and `USER_STORIES.md` with the verified final behavior. Remove
   completed tasks from this file so it contains only genuinely outstanding work.
