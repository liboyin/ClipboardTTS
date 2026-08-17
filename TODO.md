# TODO — Gap Remediation Hand-over

This document is the authoritative execution plan for the verified remediation gaps. It is written
for implementation sessions that share no conversation context: each executor must be able to
understand one task from the repository and this file alone.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md` owns
product behavior; `README.md` owns the current architecture and operating instructions. Treat
descriptions here as task boundaries, not as substitutes for re-reading the affected code.

Task 14 remains intentionally removed. Nothing in this plan reinstates the stateful menu-bar icon.

## Current status

- No implementation task is active. The remaining work is the Phase 4 gap review, then the final
  acceptance sweep.
- Each numbered task MUST be implemented in its own session and committed as one self-contained
  change after its tests, documentation, gates, and adversarial-review loop pass.
- Execute the phases in order. Tasks within a phase may be reordered only when their declared
  dependencies still hold and the reordering does not cross the phase review gate.
- Every phase MUST end with a gap review before work begins on the next phase. A phase review is a
  separate read-only review session, not a substitute for any task's dirty-tree review.

## Working rules for isolated sessions

1. Re-read this document, `AGENTS.md`, the named production paths, their tests, and the current
   documentation. Verify that the stated evidence still matches the repository before editing.
2. Confirm that every dependency is present in history and that the worktree contains no
   unexplained changes. A task's boundary does not authorize implementing another active task.
3. If repository evidence invalidates the task, or a material choice would change architecture,
   dataflow, security, correctness, or user-visible behavior, stop and ask the user. Update this
   plan before implementation when the agreed boundary changes.
4. Implement the smallest change that satisfies the task's contract. Preserve all behavior named
   under **Non-goals and invariants**.
5. Add tests that encode the user or system consequence. Mutation-test every new assertion in an
   isolated scratch copy, including a plausible future regression and the trade-off introduced by
   the constraint.
6. Tests MUST NOT contact external services, write to `NSPasteboard.general`, use the developer's
   Keychain, or leave changes in the app's real `UserDefaults` domain.
7. Update `README.md` in the same commit whenever its architecture, assumptions, or operating
   instructions change. Update `USER_STORIES.md` only when the user changes product behavior.
8. Generate `ClipboardTTSApp.xcodeproj` when it is absent or `project.yml` changed; never commit
   the generated project.
9. Run the focused tests and all repository gates after the final edit:

   ```bash
   ./check-coverage.sh
   swiftlint --strict
   xcodebuild \
     -project ClipboardTTSApp.xcodeproj \
     -scheme ClipboardTTSApp \
     -configuration Debug \
     SWIFT_STRICT_CONCURRENCY=complete \
     CODE_SIGNING_ALLOWED=NO \
     build
   ```

   Inspect the per-file manager coverage report and the build output; a successful exit code alone
   does not establish the absence of warnings.
10. Run the adversarial-review skill on the complete dirty tree. Fix every blocking finding and
    trivial non-blocking finding, repeat the gates after every edit, and re-review until no blocking
    finding remains. Ask the user to fix, defer, or ignore any other non-blocking finding.
11. Remove the completed task's full active entry from this file in its implementation commit.
    Update active-task counts, phase dependencies, and references in that same commit. Retain only
    concise decisions that materially constrain remaining work.
12. Stage explicit paths, inspect the staged diff and `git status`, then commit with the message
    format required by `AGENTS.md`. Never combine two numbered tasks in one commit.

## Phase review gate

At the end of each phase, run a read-only gap review over the phase's complete commit range against
this plan and the phase purpose. Start it in a fresh session so it does not inherit an implementation
session's conclusions. The reviewing agent performs the review itself and reports its own findings;
per `AGENTS.md`, a read-only assessment does not dispatch the adversarial reviewer. The review must
evaluate the integrated result, not merely repeat individual commit reviews, and must include:

- the complete phase diff plus relevant current source, tests, documentation, and configuration;
- counterexamples for ordering, cancellation, failure, security, and lifecycle boundaries affected
  by that phase;
- `./check-coverage.sh`, `swiftlint --strict`, and the complete-concurrency build;
- focused scratch tests or mutants for any plausible defect that the existing suite does not
  distinguish; and
- a final repository-integrity check proving that the review changed no tracked or untracked
  source files.

A phase is complete only when its gap review reports no blocking findings and every non-blocking
finding has an explicit user disposition. If the review discovers work, add new self-contained
tasks to this file and complete them before starting the next phase. Do not hide a phase finding
inside a later task.

## Work map

Every verified gap has been remediated. A phase review or the final sweep that discovers new work
adds its own self-contained task here.

---

## Phase 1 — Restore state isolation and cancellation truth

This phase repairs ownership boundaries used by later tasks: tests must not touch developer
configuration, and a stopped request must not retain authority to call client code. Tasks 26–29 are
implemented. Its gap review ran on 2026-08-13 over `8a81b50..4d8a842` and added Tasks 30–34, all of
which are complete. This phase is closed; Phase 2 may begin.

Startup regressions now own their settings storage in memory, so no later task may seed a
disk-backed `UserDefaults` suite from a test. See [README.md](README.md#build--test) for the rule.

A file that reaches SwiftLint's `file_length` limit is split along cohesion, never compressed with
semicolons and never relieved by raising the limit: a group of declarations that serves a clearly
different purpose moves to its own file, and may widen from `private` to internal only where that
file genuinely owns it. `Sources/Managers/TTSNetworkManager.swift` is 389 lines under a 400-line
limit, so a later task has 11 lines there and more in the extensions it also names;
`TTSNetworkManager+RequestLifecycle.swift` now owns starting, retrying, replacing, and stopping a
request. `Sources/Views/SettingsView.swift` reached the limit twice and was split the same way, to
361 lines: `SettingsSecretState.swift` owns the form's key storage and its migration recovery, and
`ModelVoiceConfigurationView.swift` owns the model and voice fields every provider form shares.
`Tests/SettingsMigrationRecoveryTests.swift` was split along the same seam, into the hosted-form
recovery tests, `SettingsSecretStateTests.swift`, and the shared `ScriptedSecretStore.swift` double.
Note that `lastError` has a file-private setter, which keeps the state-publication group in the
declaring file.

Mock-scope revocation now runs in two halves, and the half that can block runs off the tearing-down
thread under the scope deadline. Every later task that revokes or retries a request through the mock
lifecycle MUST keep the blocking half off that thread, MUST NOT move owner state reads that require
the main queue into it, and MUST NOT make the off-main recovery path publish request state: it
revokes through the manager's non-publishing `revokeActiveRequest()`, and recovery is bounded, so a
scope it cannot revoke ends the run instead of releasing the gate. See
[README.md](README.md#build--test) for the contract.

Terminal-state test assertions now require a publication caused after the assertion's own action,
so no later task may reintroduce an assertion that reads state published before its action. They
must also be invoked from the main thread: `awaitTerminalState` fails and returns `false` for an
off-main call site, because it shares observation state with a sink Combine delivers on main. See
[README.md](README.md#build--test) for the observation contract.

Callback authority is now a lock ordered *before* `stateQueue`, and a client handler runs while
holding it. Every later task that revokes, replaces, or retries a request MUST preserve that order
and MUST NOT acquire callback authority while holding `stateQueue`. See
[README.md](README.md#architecture) for the boundary.

The gap review confirmed at `4d8a842` that all three gates pass: `./check-coverage.sh` (132 tests,
0 failures, `Sources/Managers/` at 96.99%), `swiftlint --strict` (0 violations across 43 files), and
the complete-concurrency build (no source warnings).

### Phase 1 gap review — closed

The 2026-08-13 review over `8a81b50..4d8a842` verified the gates above and opened Tasks 30–33; Task
33's execution split off Task 34. Every one of them has landed, so Phase 2 may begin.

---

## Phase 2 — Secure and serialize request initiation

This phase prevents request setup from leaking credentials or replacing work that became active
during a deferred UI action.

Endpoint transport is now one app-owned rule: every credential-bearing endpoint, speech and
metadata alike, resolves through `EndpointTransportPolicy`, and so does every redirect target the
session offers to follow. A refused speech endpoint publishes its own message instead of returning
no URL, and a refused redirect records itself on the active request so completion reports that
message rather than the provider's redirect status. A later task that adds, replaces, or retries a
request MUST resolve its endpoint through that path rather than build a URL beside it. See
[README.md](README.md#design-assumptions) for the rule.

The menu's deferred clipboard read now revalidates the complete idle condition at execution time,
drops itself when the manager's request generation changed after it was scheduled, and schedules
through `DeferredClipboardAction`, which owns which attempt may run. A later task that adds, defers,
or retries a menu-initiated request MUST revalidate inside the deferred action rather than trust a
pre-delay check, MUST treat a changed request generation as staleness because published request and
audio state cannot describe a finished request whose accepted audio is still in flight, and MUST
schedule through that owner so a superseded attempt is dropped; injecting its scheduler is how a
test owns that timing. See [README.md](README.md#architecture) for the rule.

### Phase 2 gap review — closed

The 2026-08-16 review over `b871b09..c5db8fa` rechecked URL parsing and host confusion,
credential/header construction, loopback exceptions, redirect transport, delayed-action ownership,
Services/clipboard interleavings, and cancellation generations. Focused host-parsing probes covered
trailing-dot and percent-encoded names, backslash authority confusion, mapped IPv6, expanded IPv6,
leading-zero IPv4, and Unicode-dot normalization; every accepted cleartext form still resolved to
the loopback interface under Foundation's parsed host. The review found no blocking or non-blocking
Phase 2 gap and added no task, so Phase 3 may begin.

All three gates passed at `c5db8fa`: `./check-coverage.sh` (157 tests, 0 failures,
`Sources/Managers/` at 97.50%), `swiftlint --strict` (0 violations across 51 files), and the
complete-concurrency build (no source warnings).

The same review revalidated Tasks 21–24 against current code, test output, and official provider
documentation. Google still documents exactly 30 Gemini TTS voices and the rare Gemini 3.1 TTS
HTTP 500 with automated retry guidance; the full suite still emitted the unhosted `StateObject`
warnings; and failed legacy-key migration had no in-app retry. Phase 4 closed both of those last
two findings. Google now recommends its
Interactions API for new development, but explicitly says the app's existing `generateContent`
API remains fully supported. No migration task is justified by the current remediation boundary, and
the Phase 3 Gemini work stayed on the existing endpoint and response contract.

---

## Phase 3 — Complete and harden the Gemini provider contract

This phase brings user-visible Gemini metadata in line with current official documentation and
adds the bounded recovery Google recommends for the model's documented transient failure mode. Both
implementation tasks and the phase gap review are complete, so Phase 4 may begin.

The complete documented Gemini voice catalog is now one production constant published through the
existing freshness-guarded metadata path, so the menu and Settings cannot offer different subsets.
Gemini still documents no discovery endpoint: a later task that touches Gemini voice metadata must
keep that single source of truth and re-verify it against Google's guide instead of adding a second
list or a discovery request. See [README.md](README.md#design-assumptions) for the rule.

A Gemini speech request that fails with exactly the transient error Google documents — HTTP 500
with no transport error — is now retried once, silently, as a continuation of the same logical
request rather than as a new one. A later task that adds, replaces, or retries a request MUST NOT
add a second automatic attempt, MUST NOT rebuild a retry's inputs from mutable current Settings,
and MUST keep the retry on its original cancellation generation so a stop, Clear Buffer, or
replacement in that window prevents it from starting. See
[README.md](README.md#design-assumptions) for the rule and its provider rationale.

### Phase 3 gap review — closed

The 2026-08-17 review over `48234e4^..30409d7` rechecked current official Google documentation,
exact voice coverage and ordering, provider/list isolation, retry bounds, immutable captured inputs,
cancellation generations, error publication, duplicate-audio prevention, and incremental SSE
delivery. It found no blocking or non-blocking Phase 3 gap and added no task, so Phase 4 may begin.

The complete documented list remains 30 voices in the same order as the production constant, and
Google's Generate Content guide still documents the Gemini 3.1 TTS HTTP 500 failure and automated
retry guidance. Three isolated mutants proved that the focused tests reject an omitted documented
voice, retrying the wrong provider, and accepting a retry after its generation was revoked.

All three gates passed at `30409d7`: `./check-coverage.sh` (168 tests, 0 failures,
`Sources/Managers/` at 97.55%), `swiftlint --strict` (0 violations across 55 files), and the
complete-concurrency build (no source warnings).

---

## Phase 4 — Make recovery and test evidence trustworthy

This phase removes lifecycle warnings from Settings tests and gives failed secret migration the
user action promised by its error message. Both implementation tasks are complete, so only the
phase gap review remains.

Settings tests now drive an installed view through `Tests/HostedSettings.swift` instead of calling
methods on a constructed `SettingsView` value, and every Settings action renders through
`SettingsActionButton` because a hosted SwiftUI `Button` backs no AppKit control a test could press.
A later task that adds a Settings *action* MUST render it through that button and reach it by
clicking the hosted control; a text field is already AppKit-backed, and is addressed by its position
together with the text it expects to find there. See [README.md](README.md#build--test) for the rule.

Failed legacy-key migration is now recoverable without relaunching: `SettingsSecretState` owns both
the pending-provider set and the retry, and the manager withdraws or renames the startup warning it
published instead of clearing request state blindly. A later task that adds a Settings action
touching secrets MUST keep the injected `UserDefaults` explicit — `SettingsView.init` deliberately
has no default for it — MUST derive pending state from the retained legacy values rather than a
rendered message, MUST NOT let a migration outcome overwrite a newer speech failure, and MUST retire
a provider's legacy value on any confirmed write to it, because a plaintext copy that outlives the
user's own edit restores a credential they replaced or withdrew. See
[README.md](README.md#architecture) for the rule.

### Phase 4 mandatory gap review

Run the **Phase review gate** on the Phase 4 commit range. Scrutinize SwiftUI state identity, host
teardown, late network work, Keychain/test-double boundaries, partial migration, retry visibility,
secret precedence, manager synchronization, and error clearing. The remediation is not complete
until this review is closed with no blocking findings.

---

## Final acceptance sweep

Run this only after all four phase reviews are closed. It supplements, and does not replace, the
per-task adversarial reviews or the four phase reviews. If it discovers new work, add self-contained
tasks to this file and complete them before declaring the remediation finished.

1. Run `./check-coverage.sh`, inspect every manager's per-file coverage, and confirm aggregate
   manager line coverage remains at least 85%.
2. Run `swiftlint --strict`, the complete-concurrency build from the working rules, and the static
   analyzer; inspect output for warnings rather than checking only exit status:

   ```bash
   xcodebuild \
     -project ClipboardTTSApp.xcodeproj \
     -scheme ClipboardTTSApp \
     -configuration Debug \
     analyze
   ```

3. Run the manager tests with Thread Sanitizer when the host toolchain supports it. Record and
   investigate every sanitizer report; a clean run is supporting evidence, not proof that no race
   exists. Task 16 (`2476718`) and Task 28 (`1b9a65e`) are the isolation work this exercises.
4. Confirm with repository searches that:
   - network tests automatically isolate app settings before manager construction and restore only
     after asynchronous quiescence;
   - tests do not write to `NSPasteboard.general`, use the developer's Keychain, or construct a
     live-network `TTSNetworkManager`;
   - production API-key values do not use `@AppStorage`/`UserDefaults`, URL queries, logs,
     committed fixtures, or non-loopback cleartext transport;
   - every queued audio delivery is generation-authorized at callback time;
   - no response decoder or retry derives provider identity or request inputs from mutable current
     settings;
   - persisted settings keys have one declaration; and
   - Settings tests emit no uninstalled-state lifecycle warnings.
5. Perform manual smoke tests for clipboard and Services input, rapid repeated Speak actions,
   intervening Services work during the clipboard delay, Clear Buffer, provider switching during a
   request, bad credentials, Custom HTTPS and loopback HTTP, rejected remote HTTP, Gemini voice
   selection, Gemini 500 retry, Gemini first-audio latency, seek-to-end and replay, Custom
   non-24-kHz audio, the 0.1-second startup prebuffer, voice locking, migration retry, and About.
   Obtain user permission and credentials before live-provider tests; never record keys or provider
   response audio.
6. Run a final adversarial review on the complete remediation range — Tasks 17–34, currently
   `2476718..HEAD` — plus any phase-review follow-up tasks added later. Resolve every blocking
   finding and obtain explicit disposition for every non-blocking finding.
7. Reconcile `README.md`, `USER_STORIES.md`, and verified behavior. Remove completed active tasks
   from this file so it contains only genuinely outstanding work and concise decisions that still
   constrain future work.
