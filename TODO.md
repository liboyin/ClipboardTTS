# TODO — Remediation Hand-over

This document is the executable plan for resolving the findings from the whole-project
adversarial review. It replaces the previous hand-over, whose task list and line references
no longer matched the repository.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md`
owns product behavior; `README.md` owns current architecture and operating instructions.
Keep those documents current rather than duplicating their content here.

## Working rules

- Execute tasks in the order shown unless a task explicitly says it is independent.
- There are exactly 2 remaining numbered tasks. Each task MUST be one self-contained implementation
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
  None of the 14 implementation tasks may use the documentation-only review exemption for the
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
| Required About UI is missing | Blocking | 15 |
| The Swift 5 project is not clean under complete concurrency checking | Non-blocking | 16 |

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
- API secret values belong in the Keychain, not `UserDefaults`, URLs, logs, fixtures, or
  committed files. Tests may use unmistakably fake tokens.
- Do not switch the project to Swift 6 as part of this remediation. First make the Swift 5
  build clean with complete concurrency checking; a language-mode migration is separate work.

---

## Phase 5 — Complete the required UI

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

This sweep supplements the 14 per-task reviews. It is not Task 17 and cannot replace or defer
testing, linting, or adversarial review required before any of the 14 implementation commits.
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
   replay, Custom non-24-kHz audio, the 0.1-second startup prebuffer, voice locking, and About.
   Obtain user permission and credentials before any live provider test; never record keys.
5. Run the adversarial-review loop on the complete remediation range until no blocking
   findings remain. Resolve or obtain explicit user disposition for every remaining
   non-blocking finding.
6. Reconcile `README.md` and `USER_STORIES.md` with the verified final behavior. Remove
   completed tasks from this file so it contains only genuinely outstanding work.
