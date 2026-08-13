# TODO — Gap Remediation Hand-over

This document is the authoritative execution plan for the verified remediation gaps. It is written
for implementation sessions that share no conversation context: each executor must be able to
understand one task from the repository and this file alone.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md` owns
product behavior; `README.md` owns the current architecture and operating instructions. Treat
descriptions here as task boundaries, not as substitutes for re-reading the affected code.

Task 14 remains intentionally removed. Nothing in this plan reinstates the stateful menu-bar icon.

## Current status

- There are exactly eight active implementation tasks: Tasks 19–24 and Tasks 32–33.
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

| Verified gap | Classification | Task |
| --- | --- | --- |
| Custom credentials can be attached to an arbitrary plain-HTTP endpoint | Blocking | 19 |
| The deferred clipboard action can replace a stream started during its delay | Blocking | 20 |
| Gemini exposes only 5 of the 30 currently documented TTS voices | Blocking | 21 |
| Transient Gemini 500 responses have no bounded automatic retry | Non-blocking | 22 |
| Unhosted Settings tests recreate `@StateObject` state and emit lifecycle warnings | Non-blocking | 23 |
| Failed legacy-key migration tells the user to retry but offers no in-app retry | Non-blocking | 24 |
| Mock-scope delivery revocation can block teardown's main thread without a bound | Non-blocking | 32 |
| `TTSNetworkManager.swift` has 12 lines of file-length headroom for Tasks 19 and 22 | Non-blocking | 33 |

---

## Phase 1 — Restore state isolation and cancellation truth

This phase repairs ownership boundaries used by later tasks: tests must not touch developer
configuration, and a stopped request must not retain authority to call client code. Tasks 26–29 are
implemented. Its gap review ran on 2026-08-13 over `8a81b50..4d8a842` and added Tasks 30–33. Tasks
30 and 31 are complete; finish Tasks 32–33 before starting Phase 2.

Startup regressions now own their settings storage in memory, so no later task may seed a
disk-backed `UserDefaults` suite from a test. See [README.md](README.md#build--test) for the rule.

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

### 32. Bound mock-scope delivery revocation

**Classification:** Non-blocking — teardown hang risk

**Depends on:** Nothing

**Purpose.** `MockURLProtocol.endTest` calls `revokeAudioDelivery`, which invokes
`TestNetworkFactory.revokePendingDelivery` on the tearing-down thread. On main that reaches
`stopStreaming()`, which now blocks on callback authority until any in-flight client handler
returns. That call sits outside `endTest`'s `deadline`, so unlike the wait loop it replaced it has
no bound: a handler that does not return converts a single failing test into a hung suite. The
current suite is safe only because every handler barrier uses a bounded semaphore timeout — the same
class of failure Task 26 was created to eliminate after a Keychain read hung the coverage gate.

**Primary paths.**

- `Tests/MockURLProtocol.swift`
- `Tests/TestNetworkSupport.swift`
- `README.md`

**Required change.**

1. Bound the revocation step by the same deadline that bounds the rest of scope shutdown, and
   report a non-quiescent scope instead of blocking indefinitely.
2. Preserve the existing guarantee that a revoked handler cannot run after settings restoration or
   in the next test's scope.
3. Keep the off-main recovery path free of any synchronous wait on the main queue.
4. Document the bound in README's mock-test lifecycle paragraph.

**Non-goals and invariants.**

- Do not weaken the production callback-authority boundary to make teardown easier.
- Do not use a sleep, and do not silently swallow a scope that fails to quiesce.
- Preserve the undeclared-request, settings-snapshot, and no-late-work checks.

**Validation and falsification.**

- Hold a handler inside callback authority past the scope deadline and prove teardown reports a
  non-quiescent scope in bounded time rather than blocking.
- Prove a normal scope with in-flight delivery still drains and restores settings unchanged.
- Mutation-test removing the bound and confirm the new regression hangs or fails.

**Done when.** No client handler can make mock-scope teardown block the tearing-down thread without
a bound.

### 33. Restore one declaration per line in `TTSNetworkManager.swift`

**Classification:** Non-blocking — readability, and headroom for Phase 2 and Phase 3

**Depends on:** Nothing

**Purpose.** Unrelated declarations in this file are joined with semicolons to fit under SwiftLint's
400-line `file_length` limit. `465f0d9` started the practice at line 43; `1b9a65e` extended it to
lines 32, 44, 46, and 47, and to the initializer statement at line 132. `0c877ce` then had to
relocate `requestURL(for:)` out of the file for the same reason, after the limit failed the build
and, through it, `./check-coverage.sh`. The file is 388 lines, 12 short of the limit. Tasks 19 and
22 both add code to it, so the next executor meets the same pressure and the same temptation to
compress declarations instead of structuring the change.

**This task requires a user decision before implementation.** The executor MUST ask which of these
the user wants and MUST NOT choose unilaterally, because they differ in architecture: extract a
cohesive responsibility into a new extension file; raise the `file_length` limit in `.swiftlint.yml`
with a recorded rationale; or keep the limit and accept the current density.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `.swiftlint.yml` only if the user selects the limit change
- `README.md` if the file layout changes

**Required change.**

1. Restore one declaration per line for every semicolon-joined stored property.
2. Apply the user's chosen approach to create headroom.
3. Leave every declaration's type, access level, and initialization byte-identical.

**Non-goals and invariants.**

- Do not change behavior, isolation annotations, or the documented confinement rules.
- Do not disable `file_length`, and do not move a declaration into a file that does not own it.
- Do not bundle this with Task 19 or Task 22.

**Validation and falsification.**

- Confirm `swiftlint --strict` and the complete-concurrency build stay clean, and the full suite
  passes unchanged.
- Confirm `git diff` shows only formatting or relocation, with no semantic edit.

**Done when.** The manager file declares one property per line and has documented headroom for the
Phase 2 and Phase 3 changes that target it.

### Phase 1 gap review — closed

The 2026-08-13 review over `8a81b50..4d8a842` verified the gates above and opened Tasks 30–33. Do
not begin Phase 2 until Tasks 32–33 are complete.

---

## Phase 2 — Secure and serialize request initiation

This phase prevents request setup from leaking credentials or replacing work that became active
during a deferred UI action.

### 19. Reject insecure non-loopback Custom endpoints

**Classification:** Blocking — credential transport security

**Depends on:** Tasks 32–33

**Purpose.** `requestURL` accepts both HTTP and HTTPS, and Custom requests attach their saved API
key as `Authorization: Bearer`. Application Transport Security currently provides a platform layer,
but the app contract itself does not prevent future configuration or policy changes from sending
credentials and clipboard text to an arbitrary cleartext remote endpoint. `requestURL(for:)` moved
to `TTSNetworkManager+Requests.swift` in `0c877ce`. The metadata paths are weaker still: the model
and voice requests build their URL with a bare `URL(string:)`, attach `Authorization: Bearer`, and
apply no scheme check at all.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/Managers/TTSNetworkManager+Requests.swift`
- `Sources/Managers/TTSNetworkManager+Metadata.swift`
- `Sources/Views/SettingsView.swift`
- `Tests/TTSNetworkManagerAuthenticationTests.swift`
- `Tests/TTSNetworkManagerFailureTests.swift`
- `Tests/SettingsViewTests.swift`
- `README.md`

**Required change.**

1. Centralize endpoint transport validation for every Custom request path.
2. Permit HTTPS endpoints with an otherwise valid host.
3. Permit plain HTTP only for explicit loopback hosts needed by local engines: `localhost`, IPv4
   loopback addresses, and IPv6 loopback. Do not treat private-network or DNS-resolved remote hosts
   as loopback merely because they may be local to one machine.
4. Reject every other HTTP endpoint before creating or resuming a URL-session task and before
   attaching credentials or request content.
5. Publish a short actionable application-owned configuration error that contains no key, request
   body, or full credential-bearing URL.
6. Apply the same rule to any Custom metadata request that remains reachable after re-reading the
   current UI and manager contract.
7. Document the HTTPS/loopback rule in README's Custom-provider assumptions.

**Non-goals and invariants.**

- Do not add certificate pinning, custom trust handling, an ATS exception, or a general networking
  policy framework.
- Do not block HTTP loopback engines that satisfy the existing OpenAI-compatible contract.
- Do not alter fixed OpenAI or Gemini endpoints and authentication headers.
- Do not log or render rejected URLs containing user-controlled query values.

**Validation and falsification.**

- Intercept HTTPS Custom, `http://localhost`, IPv4 loopback, and IPv6 loopback requests and prove
  they use the expected request contract.
- Assert public-host HTTP, private-LAN HTTP, deceptive hostnames, user-info tricks, missing hosts,
  and unsupported schemes fail without starting a request.
- Inject a conspicuous fake key and prove it appears nowhere in the rejection error, URL, logs,
  preferences, or an emitted request.
- Mutation-test allowing arbitrary HTTP and over-restricting valid loopback HTTP.

**Done when.** The app cannot send Custom credentials or clipboard text over cleartext transport
except to an explicitly recognized loopback endpoint.

### 20. Revalidate the deferred clipboard action at execution time

**Classification:** Blocking — explicit two-click playback behavior

**Depends on:** Tasks 32–33

**Purpose.** `MenuBarView.speakCopiedText()` checks stream/audio readiness before scheduling its
0.2-second delayed clipboard read. The closure does not check again. A Services request or another
invocation can become active during that window, after which the stale closure starts a new audio
generation and replaces it without the required Clear Buffer action.

**Primary paths.**

- `Sources/Views/MenuBarView.swift`
- `Sources/Managers/AudioPlayerManager.swift`
- `Sources/Managers/ServicesCoordinator.swift`
- `Tests/MenuBarViewTests.swift`
- `Tests/ServicesCoordinatorTests.swift`
- `README.md`
- `USER_STORIES.md` for the existing two-click requirement only

**Required change.**

1. Revalidate the complete idle/readiness condition inside the delayed action immediately before
   reading the clipboard or changing the audio/network generation.
2. If another stream, retained buffer, invalid audio configuration, or superseding clipboard
   attempt exists, drop the stale action without reading the pasteboard, stopping current work, or
   changing any generation.
3. Ensure rapid repeated Speak invocations can start at most one request.
4. Preserve the 0.2-second deactivation delay and the existing first-click Clear Buffer behavior.
5. Make delayed-action ownership deterministic in tests through an injected scheduler/token or an
   equivalently isolated seam; correctness tests must not rely only on wall-clock sleeps.

**Non-goals and invariants.**

- Do not change the Services payload or move its observer back into `MenuBarView`.
- Do not add interrupt-and-replace behavior or remove the two-click contract.
- Do not read or write `NSPasteboard.general` in tests.
- Do not change the independent 0.1-second audio prebuffer.

**Validation and falsification.**

- Queue a clipboard action, start a Services request before releasing it, and prove the clipboard
  action performs no read, generation change, cancellation, or network request.
- Queue two clipboard actions and prove exactly one request can start.
- Clear an already active stream and prove a later, explicit Speak action still works.
- Cover invalid sample-rate readiness at delayed execution time.
- Mutation-test keeping only the pre-delay guard and allowing both rapid actions to run.

**Done when.** A deferred clipboard action starts speech only if it still owns an idle, playable
pipeline at execution time and can never replace intervening work.

### Phase 2 mandatory gap review

Run the **Phase review gate** on the Phase 2 commit range. Scrutinize URL parsing and host confusion,
credential/header construction, loopback exceptions, ATS assumptions, delayed-action ownership,
Services/clipboard interleavings, and cancellation generations. Do not begin Phase 3 until the
review is closed with no blocking findings.

---

## Phase 3 — Complete and harden the Gemini provider contract

This phase brings user-visible Gemini metadata in line with current official documentation and
adds the bounded recovery Google recommends for the model's documented transient failure mode.

### 21. Expose the complete documented Gemini TTS voice catalog

**Classification:** Blocking — incomplete provider-authoritative menu metadata

**Depends on:** Phase 2 mandatory gap review

**Purpose.** The app currently publishes only `Aoede`, `Charon`, `Fenrir`, `Kore`, and `Puck` for
Gemini. At review time Google's official Gemini TTS guide documented 30 supported voices. Task 13
required provider-authoritative metadata, so the current menu and Settings suggestions omit most
valid choices.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager+Metadata.swift`
- `Sources/Views/MenuBarView.swift`
- `Sources/Views/SettingsView.swift`
- `Tests/TTSNetworkManagerMetadataProviderTests.swift`
- `Tests/MenuBarViewTests.swift`
- `Tests/SettingsViewTests.swift`
- `README.md`

**Required change.**

1. Re-verify the supported Gemini TTS voices against the current official Google documentation at
   execution time, starting from the
   [Gemini TTS guide](https://ai.google.dev/gemini-api/docs/speech-generation). Do not copy the
   2026-08-10 count mechanically if the provider contract changed.
2. Keep one production source of truth for the documented Gemini voice catalog.
3. Publish the complete current list through the existing freshness-guarded metadata path so both
   menu and Settings suggestions use the same provider-authoritative values.
4. Preserve the saved voice when it remains valid. Do not silently replace a user selection merely
   because list ordering changes.
5. Update README with the verified source and maintenance assumption without duplicating a long
   list unless that list is itself the architectural source of truth.

**Non-goals and invariants.**

- Do not invent a Gemini discovery endpoint when none is documented.
- Do not mix OpenAI, Gemini, or Custom voice lists.
- Preserve Task 5 freshness tokens and Task 13's idle-only menu selection rule.
- Do not make a live provider request in unit tests.

**Validation and falsification.**

- Assert exact agreement between the verified production catalog and the current documented set,
  including voices outside the previous five.
- Mount the menu lifecycle and prove a newly added Gemini voice is selectable only for the current
  Gemini provider while idle and is used by the next intercepted request.
- Switch providers and prove Gemini voices cannot leak into OpenAI or Custom selection.
- Mutation-test omission of one documented voice and accidental reuse of another provider's list.

**Done when.** Menu and Settings expose every currently documented Gemini TTS voice through one
freshness-guarded source without weakening provider or idle-state boundaries.

### 22. Retry the documented transient Gemini 500 failure once

**Classification:** Non-blocking — provider reliability

**Depends on:** Task 21

**Purpose.** Google documents that Gemini 3.1 TTS can rarely return HTTP 500 when it emits text
tokens instead of audio and recommends automated retry handling. The app currently turns every 500
into an immediate terminal error.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/Managers/TTSNetworkManager+Failures.swift`
- `Sources/Managers/TTSNetworkManager+Requests.swift`
- `Sources/Managers/TTSNetworkManager+GeminiStreaming.swift`
- `Tests/TTSNetworkManagerFailureTests.swift`
- `Tests/TTSNetworkManagerRequestLifecycleTests.swift`
- `Tests/TTSNetworkManagerGeminiStreamingTests.swift`
- `README.md`

**Required change.**

1. Re-verify Google's current retry guidance in the
   [Gemini TTS limitations](https://ai.google.dev/gemini-api/docs/speech-generation#limitations)
   before implementation.
2. Treat the retry as part of one logical user request with the same immutable settings, text,
   credentials, decoder, handler, and cancellation generation.
3. Retry Gemini HTTP 500 at most once and only when the request is still current. Keep
   `isStreaming` truthful across the handoff and do not publish a terminal error before the retry
   outcome is known.
4. A stop, Clear Buffer, replacement request, or invalidated generation must prevent the retry from
   starting and revoke its queued deliveries under the [README's queued-delivery ownership
   contract](README.md#architecture). That contract now includes the callback-authority lock added
   by Task 28: acquire callback authority before `stateQueue`, never the reverse, and do not start
   a retry from inside a client handler that already holds callback authority.
5. If the retry also fails, publish the existing sanitized HTTP failure exactly once and finish the
   request normally.
6. Do not retry authentication, configuration, transport, cancellation, malformed SSE, empty
   audio, OpenAI-compatible, or Custom failures.
7. Record the bounded retry behavior and provider rationale in README.

**Non-goals and invariants.**

- Do not add exponential backoff, a general retry framework, or more than one automatic attempt.
- Do not rebuild retry input from mutable current Settings.
- Do not expose response bodies, keys, or provider-controlled error text.
- Preserve incremental delivery, ordering, final-event accounting, and the 0.1-second audio
  prebuffer. A retry must not duplicate already authorized audio.

**Validation and falsification.**

- Return Gemini 500 then valid SSE audio; assert two requests, one logical lifecycle, one audio
  stream, and no terminal error.
- Return 500 twice; assert exactly two attempts and one sanitized terminal failure.
- Stop or replace between attempts and prove no retry or stale callback escapes.
- Assert 401, 403, other HTTP statuses, transport errors, OpenAI, and Custom each make one attempt.
- Verify the retry uses the original captured URL, body, headers, model, voice, and handler after a
  Settings change.
- Mutation-test an unbounded retry, retrying the wrong provider/status, and rebuilding from mutable
  settings.

**Done when.** A current Gemini request transparently receives one safe retry for the documented
500 failure and every other lifecycle, cancellation, and error contract remains unchanged.

### Phase 3 mandatory gap review

Run the **Phase review gate** on the Phase 3 commit range. Re-check current official Google
documentation, exact voice coverage, provider/list isolation, retry bounds, captured settings,
cancellation between attempts, error publication, duplicate-audio prevention, and incremental SSE
delivery. Do not begin Phase 4 until the review is closed with no blocking findings.

---

## Phase 4 — Make recovery and test evidence trustworthy

This phase removes lifecycle warnings from Settings tests and gives failed secret migration the
user action promised by its error message.

### 23. Exercise Settings state through a valid SwiftUI lifecycle

**Classification:** Non-blocking — test validity and maintainability

**Depends on:** Task 21

**Purpose.** Several Settings tests construct `SettingsView` as a value and call methods that read
its `@StateObject`. SwiftUI reports that the object is not installed on a view and creates a new
instance for each access. Those tests can pass while exercising different state identity from the
hosted production view.

**Primary paths.**

- `Sources/Views/SettingsView.swift`
- `Tests/SettingsViewTests.swift`
- `Tests/TTSNetworkManagerAuthenticationTests.swift`
- `Tests/TestNetworkSupport.swift`
- `Tests/TerminalStateAssertion.swift`, which owns the terminal-state helper since `dc08bc2`
- `README.md`

**Required change.**

1. Inventory every Settings test that accesses lifecycle-managed `@State` or `@StateObject`
   outside an installed view.
2. Host lifecycle-dependent behavior in `NSHostingView`, lay it out, drive the rendered control or
   a lifecycle-valid binding, then release it and drain the main queue before mock teardown.
3. Test extracted non-view collaborators such as `SettingsSecretState` directly where the test owns
   that object; do not create a SwiftUI host when no view lifecycle is involved.
4. If a very small production extraction is necessary for deterministic action testing, keep it
   behavior-preserving and narrowly scoped. Do not redesign Settings architecture merely to avoid
   hosting tests.
5. Remove the `Accessing StateObject ... without being installed on a View` warnings from focused
   and full-suite output.
6. Replace lifecycle sleeps with explicit control, publication, request, or main-queue-drain
   boundaries where the affected tests permit it.

**Non-goals and invariants.**

- Do not present real windows, About panels, Keychain prompts, or live network requests.
- Preserve the documented rule against wrapping test hosts in `NSWindow`.
- Preserve Settings autosave, provider synchronization, secret-store failure visibility, sample
  rate validation, Test Voice, and About behavior.
- Do not suppress or filter the SwiftUI warnings instead of fixing their cause.

**Validation and falsification.**

- Run the focused Settings and authentication suites and inspect their logs for lifecycle warnings.
- Prove hosted controls route to the same retained secret state across multiple edits/actions.
- Release each host, drain the main queue, and verify mock teardown quiesces with no late request.
- Mutation-test reverting one lifecycle-dependent test to direct unhosted state access or replacing
  the retained state with a fresh instance.

**Done when.** Settings tests exercise production-equivalent state identity, emit no uninstalled
`StateObject` warnings, and remain hermetic and teardown-safe.

### 24. Add an explicit in-app retry for failed legacy-key migration

**Classification:** Non-blocking — recovery UX

**Depends on:** Task 23

**Purpose.** Failed migration preserves the plaintext value and tells the user to check Keychain
access and try again, but migration currently reruns only when a new `TTSNetworkManager` is created.
Opening Settings reads Keychain state without offering a retry, so recovery normally requires an
undocumented relaunch.

**Primary paths.**

- `Sources/SecretStore.swift`
- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/Views/SettingsView.swift`
- `Tests/SecretStoreTests.swift`
- `Tests/SettingsViewTests.swift`
- `Tests/TTSNetworkManagerAuthenticationTests.swift`
- `README.md`

**Required change.**

1. Retain structured migration-failure state long enough for Settings to identify that one or more
   legacy provider keys still need migration. Do not infer retry eligibility by parsing a rendered
   error string.
2. When migration has failed, show an explicit user-initiated Settings action such as
   **Retry Securing Saved Keys** alongside actionable, secret-free guidance.
3. The action must rerun migration for every still-pending provider using the same injected secret
   store *and* the same injected `UserDefaults`. Task 26 threaded `defaults` explicitly through
   `APIKeyStartupState.load` and `APIKeyMigrationService.migrateLegacyAPIKeys`; a retry that relies
   on either default parameter would read the developer's domain from the hosted test app. Remove
   each legacy value only after its Keychain write is confirmed.
4. On success, refresh Settings' retained secret state and the network manager's future-request
   credentials, clear the migration-specific warning, and leave unrelated request/audio state
   unchanged.
5. On failure, preserve the legacy value, retain the previous usable Keychain value when one
   exists, and keep retry available with safe guidance.
6. Preserve the existing rule that an already saved Keychain value wins over stale plaintext.
7. Document the recovery path in README without exposing storage values or security-system details.

**Non-goals and invariants.**

- Do not display, log, copy, or return the retained plaintext secret to the user.
- Do not automatically retry in a loop or trigger repeated Keychain prompts without user action.
- Do not replace the Keychain store, change its service/accounts, or add credential export.
- Do not clear unrelated speech-request failures when migration remains unresolved.

**Validation and falsification.**

- With an in-memory store and isolated defaults, fail migration, mount Settings, and prove the
  retry action is visible while the legacy value remains intact.
- Retry successfully and assert the secret reaches the store, plaintext is removed, the retained
  Settings/network value updates, and the warning/action disappear.
- Fail the retry and assert plaintext and any newer Keychain value remain unchanged.
- Cover multiple pending providers and partial success without losing the still-failing values.
- Prove a normal launch with no migration failure shows no retry action and does no extra writes.
- Mutation-test deleting plaintext before a failed write and overwriting an existing newer secret.

**Done when.** A user can recover from transient Keychain migration failure inside Settings without
relaunching and without risking secret loss, disclosure, or stale network credentials.

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
   exists. Task 17 (`2476718`) and Task 28 (`1b9a65e`) are the isolation work this exercises.
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
6. Run a final adversarial review on the complete remediation range — Tasks 17–33, currently
   `2476718..HEAD` — plus any phase-review follow-up tasks added later. Resolve every blocking
   finding and obtain explicit disposition for every non-blocking finding.
7. Reconcile `README.md`, `USER_STORIES.md`, and verified behavior. Remove completed active tasks
   from this file so it contains only genuinely outstanding work and concise decisions that still
   constrain future work.
