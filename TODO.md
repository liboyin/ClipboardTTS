# TODO — Gap Remediation Hand-over

This document is the authoritative execution plan for the verified remediation gaps. It is written
for implementation sessions that share no conversation context: each executor must be able to
understand one task from the repository and this file alone.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md` owns
product behavior; `README.md` owns the current architecture and operating instructions. Treat
descriptions here as task boundaries, not as substitutes for re-reading the affected code.

Task 14 remains intentionally removed. Nothing in this plan reinstates the stateful menu-bar icon.

## Current status

- Fourteen tasks are active in Phase 5: 37–50. Task 36 was withdrawn when voice selection left the
  menu-bar drop-down. Phase 4's gap review has now run over its complete range and found no Phase 4
  gap other than Task 42; the phase closes once that finding has an explicit user disposition. Phase
  5 then addresses every outstanding review gap, and the final acceptance sweep follows its own gap
  review.
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
10. Run the adversarial-review skill on the complete dirty tree. Independently validate and fix
    every blocking finding; independently validate and fix a Nit only when its remedy is local.
    Surface every non-blocking finding, and every Nit not fixed automatically, for the user's
    fix/defer/accept decision. Repeat the gates after every edit, and re-review until no blocking
    finding remains.
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

Phase 5 contains Tasks 37–50: Tasks 37 and 38 are blocking; Tasks 39–50 are non-blocking. It begins
only after Phase 4 closes. Within Phase 5 none of the tasks depends on another, so they may be
executed in any order, one self-contained commit each. No final-sweep work may begin until every one
of them has landed or been explicitly deferred by the user.

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
file genuinely owns it. `Sources/Managers/TTSNetworkManager.swift` is 383 lines under a 400-line
limit, so a later task has 17 lines there and more in the extensions it also names;
`TTSNetworkManager+RequestLifecycle.swift` now owns starting, retrying, replacing, and stopping a
request. `Sources/Views/SettingsView.swift` reached the limit twice and was split the same way, to
367 lines: `SettingsSecretState.swift` owns the form's key storage and its migration recovery, and
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

This phase removes lifecycle warnings from Settings tests, gives failed secret migration the user
action promised by its error message, and keeps every suggestion picker valid. Tasks 23, 24, and 35
are complete. Task 36 was withdrawn without landing: menu voice selection was removed on 2026-08-20,
so the picker it would have fixed no longer exists. The rerun gap review has been performed; the
phase closes once Task 42, its one open finding, has a user disposition.

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

Every published model and voice list now names the provider its request was made for, and a form
offers only a list naming the provider it renders; a Settings picker also always tags its own current
selection. A later task that adds a suggestion source, a provider form, or another surface offering
those choices MUST carry that identity on the list rather than infer it from current settings, and
MUST NOT normalize an off-catalog model or voice to make a picker valid, because that would speak in
one the user never chose. See [README.md](README.md#design-assumptions) for the rule. Settings is now
the only surface that offers them.

### Menu voice selection removed — decision note, 2026-08-20

Voice is configured only in Settings, beside the model and API key that give it meaning. The
menu-bar drop-down is playback control alone — speak/clear, play/pause, progress, speed — and
neither offers the voice nor displays it. Task 36, which would have tagged the menu picker's own
selection, was withdrawn with the control it targeted; its commit was discarded rather than
reverted, so no history describes a picker the app never shipped.

A later task that reintroduces any voice affordance in the menu MUST bring the provider-identity and
picker-validity rules with it — a surface may offer only a list naming the provider it renders, and a
rendered picker must tag its own selection — because those guarantees were deleted with the control
they protected, not relaxed. See [README.md](README.md#design-assumptions) for the rule.

It must also re-establish the regression that pins the absence, and read the scope note in
`Tests/MenuBarViewTests.swift` first: a windowless host can prove a picker absent, but not a plain
`Text` label, which SwiftUI draws itself.

### Phase 4 gap review — run 2026-08-20, one non-blocking finding open

The 2026-08-17 review over `a9dc781^..657d396` found Task 35, whose own adversarial review added
Task 36. The rerun required over the complete phase range was performed as an independent integration
review. It ran while Task 36's commit was still present; that commit has since been
discarded, so the phase range is now `a9dc781^..2a71e72`. Nothing the review examined was affected —
Task 36 touched only the menu picker and its tests, all of which the menu voice-selection removal
deletes outright.

Result for the Phase 4 scope specifically. The invalid-picker warning the 2026-08-17 review observed
cannot recur: `Picker`'s `associated tag` / `undefined results` text and `StateObject`'s
`without being installed` text each appear zero times across the full test runs, and
`Publishing changes from within view updates` appears zero times as well. The warning is now absent
because the menu renders no picker at all, rather than because Task 36 tagged one. Isolated mutants confirmed
that the suite rejects publishing one provider's suggestion list under another provider, dropping the
legacy-value retirement on a confirmed secret write, and letting a migration outcome overwrite a
newer speech failure. Manager synchronization produced one non-blocking finding, Task 42.

The phase is not yet closed: the gate requires that every non-blocking finding carry an explicit user
disposition, and Task 42 has none. It is the first Phase 5 task because it is the outstanding
remediation work produced by this Phase 4 review. Nothing else in the Phase 4 scope — SwiftUI state
identity, host teardown, late network work, Keychain/test-double boundaries, partial migration,
retry visibility, secret precedence, error clearing, provider-scoped picker identity — produced a
finding.

---

## Phase 5 — Resolve full-project review gaps

This phase contains the outstanding gaps identified after the four original remediation phases. It
starts only after Phase 4 closes. Tasks 37 and 38 are blocking; Tasks 39–50 are non-blocking. Each
task remains a separate commit and must follow the working rules above.

### 37. Align USER_STORIES.md with the dropped stateful menu-bar icon

**Classification:** Blocking — documentation ownership

**Depends on:** nothing

**Purpose.** `USER_STORIES.md` still requires that "The menu bar icon should change to reflect the
current state (Idle, Playing, Paused)". The app renders a fixed `waveform.circle`
(`Sources/ClipboardTTSApp.swift:104`), and that requirement was deliberately dropped on 2026-08-03 in
`33b91a3`, which recorded the decision only in this file. `AGENTS.md` makes `USER_STORIES.md` the
owner of product requirements and user-visible behavior, and requires documentation to be updated as
soon as it no longer reflects the project. The owning document therefore states a requirement the
product does not meet, and the final acceptance sweep's step 7 reconciles behavior against exactly
that document.

**Primary paths.**

- `USER_STORIES.md`
- `TODO.md`

**Required change.**

1. Remove the stateful menu-bar icon from `USER_STORIES.md`, or state there that it was withdrawn and
   why, so the file describes the product as built.
2. Record the decision where it belongs. `TODO.md` may keep its one-line note that Task 14 stays
   removed; the reasoning belongs with the requirement it withdrew.
3. Re-read the rest of `USER_STORIES.md` against current behavior in the same pass. The stale Voice
   entry — "all available voices via OpenAI API" — was already replaced by the Settings-only
   requirement when menu voice selection was removed, so verify that replacement and every remaining
   line, naming the code that satisfies each.

**Non-goals and invariants.**

- Do not implement a stateful icon. Nothing in this plan reinstates it.
- Do not move product requirements into `README.md`; it owns architecture and operating instructions,
  not what the product must do.

**Validation and falsification.** Read every line of `USER_STORIES.md` against the current sources
and name the code that satisfies it. Documentation-only changes are exempt from adversarial review.

**Done when.** `USER_STORIES.md` describes only behavior the app has, and every requirement it states
can be pointed at a source path that implements it.

### 38. Settle what an odd-length provider response means

**Classification:** Blocking — user-visible failure text contradicts audible behavior, and untested

**Depends on:** nothing

**Purpose.** `Sources/Managers/TTSNetworkManager+Failures.swift:124` treats a response as playable
only when its byte count is even, but `README.md` states the contract as "at least one complete
16-bit PCM frame". A truncated response of an odd length — three bytes, say — does contain a complete
frame, and `AudioPlayerManager.scheduleAudio` schedules it, publishes `hasAudio`, and plays it. The
request then completes and publishes "The TTS service returned no playable audio. Please try again."
The user hears speech and is told there was none. Nothing distinguishes the two behaviors today:
relaxing the condition to `byteCount >= 2` passes all 189 tests, re-verified against the suite as
it stands after the menu voice-selection removal.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager+Failures.swift`
- `Tests/TTSNetworkManagerFailureTests.swift`
- `Tests/TTSNetworkManagerGeminiStreamingTests.swift`
- `README.md`

**Required change.**

1. Decide which rule is the app's, and make the code, the failure text, and `README.md` agree. Either
   a trailing partial frame is tolerated because complete frames were delivered, or an odd length is
   a corrupt response whose message says so instead of claiming no audio arrived.
2. Whichever is chosen, the player and the network manager must agree about it. Audio the user can
   hear must not coexist with a message saying none arrived.
3. Add the assertion that fails when the chosen rule is reverted, and mutation-test it.

**Non-goals and invariants.**

- Do not change what an empty or single-byte response reports.
- Do not make the player drop complete frames merely to match the stricter reading.
- Keep every failure message application-owned; no provider response text.

**Validation and falsification.** Drive an odd-length response through both the OpenAI-compatible and
Gemini paths and assert the published state together with what the player buffered. Mutation-test the
even-length requirement, its relaxation, and an over-restriction that rejects a valid even-length
response.

**Done when.** An odd-length response produces one coherent outcome across player state, published
message, and documentation, and a mutant that reverses the decision fails a test.

### 39. Anchor the built-product pattern in .gitignore

**Classification:** Non-blocking — silent loss of new files from version control

**Depends on:** nothing

**Purpose.** `.gitignore:3` is `ClipboardTTSApp*`, unanchored, so it matches any path segment with
that prefix in any directory: `git check-ignore -v Tests/ClipboardTTSAppSmokeTests.swift` reports it
ignored. Such a file compiles locally, because `project.yml` globs `Sources` and `Tests` wholesale,
but never appears in `git status`, so `AGENTS.md`'s explicit-path staging rule drops it without a
signal. Tracked files including `Sources/ClipboardTTSApp.swift` are unaffected.

**Primary paths.**

- `.gitignore`

**Required change.** Narrow the pattern to the built product it was meant to ignore, anchored to the
repository root. `*.xcodeproj` on line 8 already covers the generated project, so the new pattern
must not be the only thing keeping that out.

**Non-goals and invariants.**

- Keep `build/`, `DerivedData/`, `xcuserdata/`, the generated project, and `.DS_Store` ignored.
- Do not commit the generated project or any build output.

**Validation and falsification.** After the change, `git check-ignore -v` must report the built
`.app` and the generated `.xcodeproj` as ignored and must report a hypothetical
`Tests/ClipboardTTSAppSmokeTests.swift` and `Sources/ClipboardTTSAppExtras.swift` as not ignored.
Confirm `git status` is otherwise unchanged.

**Done when.** A new source or test file whose name begins with the app's name appears in
`git status`, and nothing that was ignored before has become visible.

### 40. Keep a provider credential from following a redirect off its origin

**Classification:** Non-blocking — credential scope, and a misleading authentication failure

**Depends on:** nothing

**Purpose.** `Sources/Managers/TTSNetworkManager.swift:368` applies the transport rule to a redirect
target but says nothing about its origin, and the Gemini key travels in a custom header. Measured on
this toolchain against loopback servers: `URLSession` strips `Authorization` from a redirected
request but replays `x-goog-api-key` verbatim, so a redirect away from
`generativelanguage.googleapis.com` hands the raw Gemini key to whatever HTTPS host the response
names. Exposure requires a redirect issued from Google's own endpoint or a TLS or DNS compromise, so
the likelihood is low and the fix is small. The same probe showed the mirror-image problem for the
Bearer providers: because `Authorization` is dropped on every redirect the session follows, including
a same-origin path change, an OpenAI-compatible or Custom endpoint that redirects reaches its target
unauthenticated, returns 401, and the app tells the user to check an API key that is correct.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Tests/TTSNetworkManagerEndpointTransportTests.swift`
- `README.md`

**Required change.**

1. Decide what a change of origin means for a redirect that carries a credential, and enforce it
   where the transport rule already is. Refusing a cross-origin redirect and dropping the provider
   credential header on one are both defensible; picking neither is not.
2. Make the failure a redirect produces describe what happened. A redirect that cost the request its
   credential must not be reported as the user's key being wrong.
3. Document the rule beside the transport rule in `README.md`, with the measured `URLSession`
   behavior it rests on, since that behavior is the reason the rule is not obvious.

**Non-goals and invariants.**

- Do not stop following safe redirects outright unless that is the decision, and say so if it is.
- Keep the existing transport refusal, its message, and its precedence over the provider's redirect
  status exactly as they are.
- Never echo an endpoint or a key in a failure message.

**Validation and falsification.** Drive a redirect through the mock protocol for both credential
shapes and assert which headers reach the target and what the manager publishes. Mutation-test the
origin check and the header removal, and include an over-restriction that would break an ordinary
permitted same-origin redirect.

**Done when.** A credential-bearing request cannot carry its key to an origin the user never
configured, and a redirect that strips the credential reports itself rather than blaming the key.

### 41. Retire or reconnect the unreachable metadata paths

**Classification:** Non-blocking — dead production code and a latent provider-identity trap

**Depends on:** nothing

**Purpose.** Several paths in `Sources/Managers/TTSNetworkManager+Metadata.swift` cannot run in
production. The HTTP voice-discovery branch and its `decodeVoices` helper execute only when the
selected provider is neither OpenAI nor Gemini, and `SettingsView.fetchMetadata` — since 2026-08-20
the only caller of `fetchAvailableVoices` — returns early for Custom, which `README.md` states as the
intent: a Custom endpoint has no discovery contract. Separately, `inferredMetadataProvider(for:)`
runs only when `updateSettings` is called without a provider, which no path in `Sources` does, and
the `"OpenAICompatible"` value it returns matches no provider identity anywhere else: that literal
appears exactly once in the whole repository. Fourteen tests reach it and so run the manager in a
state production cannot produce. Removing menu voice selection added a third: `isCurrentProvider(_:)`
on `TTSNetworkManager` now has no caller in `Sources` at all, and survives only as the accessor three
startup regressions in `Tests/AppStartupDependenciesTests.swift` use to read provider identity —
`metadataSettingsSnapshot().provider` already exposes the same value to a production caller.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager+Metadata.swift`
- `Sources/Managers/TTSNetworkManager.swift`
- `Tests/TTSNetworkManagerMetadataSourceTests.swift`
- `Tests/TTSNetworkManagerMetadataTests.swift`
- `Tests/AppStartupDependenciesTests.swift`
- `README.md`

**Required change.**

1. For each path, either give it a production caller or remove it. Before removing either, identify
   what it uniquely carries — the transport refusal for a metadata endpoint, the two response shapes
   `decodeVoices` accepts, the cancellation and freshness guards its tests exercise — and give each
   surviving item another home or another test.
2. If `inferredMetadataProvider` stays, make its result a provider identity the rest of the app
   recognizes, so a manager can never hold one that no surface will ever match.
3. Decide whether `isCurrentProvider(_:)` stays as a test-only observation seam or gives way to
   `metadataSettingsSnapshot().provider` in the three startup regressions that use it. A manager
   accessor kept alive only by its assertions is a claim about production that production never makes.
4. Move the tests that only reach these paths onto a configuration production can actually reach, or
   delete them with the code they cover. A test whose setup production cannot produce proves nothing
   about production.

**Non-goals and invariants.**

- Do not add voice discovery for Custom. `README.md` states it has no discovery contract.
- Keep the metadata generation, token, provider-identity, and endpoint-transport guards intact for
  every path that survives.
- Do not lower `Sources/Managers/` coverage below the gate by deleting code its tests were carrying.

**Validation and falsification.** After the change, prove by search that every remaining metadata
entry point has a caller in `Sources`, and that no manager state reachable in tests is unreachable in
production. Mutation-test the guards that survive.

**Done when.** Every metadata path in the manager is reachable from the app, and no provider identity
exists that no surface can match.

### 42. Cover or retire the provider half of the metadata scope check

**Classification:** Non-blocking — Phase 4 finding, untested manager synchronization

**Depends on:** nothing

**Purpose.** `Sources/Managers/TTSNetworkManager.swift:172` invalidates the metadata scope when
either the base URL or the selected provider changes. Removing the provider half passes all 189
tests, re-verified against the suite as it stands after the menu voice-selection removal. The condition is
reachable: OpenAI's fixed endpoint and Custom's default `apiBaseURL` are the same string, so
switching OpenAI to Custom without editing the Base URL changes the provider alone.
After Phase 4 tagged every published list with its provider, the user-visible consequence disappeared
— a list tagged OpenAI is refused by a Custom form regardless — and what still depends on this half
is the cancellation of an in-flight metadata request and the prompt clearing of the published lists.
`README.md` states metadata source identity as including both, so the code and the documentation
currently claim a property nothing can break.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Tests/TTSNetworkManagerMetadataSourceTests.swift`
- `README.md`

**Required change.** Decide whether the provider half still earns its place. If it does, add the
assertion that fails without it — the natural one is that switching OpenAI to Custom at the shared
default base URL cancels the pending metadata task and returns the lists to unpublished. If provider
tagging superseded it, remove it and say so in `README.md`, keeping the endpoint half.

**Non-goals and invariants.**

- Do not weaken provider tagging on published lists; it is what makes a stale list refusable.
- Keep the endpoint half: multiple Custom endpoints share the OpenAI-compatible transport.
- Keep metadata invalidation off the request-state publication path.

**Validation and falsification.** Mutation-test both halves of the condition independently, plus an
over-restriction that invalidates the scope when neither changed and so re-fetches on every keystroke.

**Done when.** Every half of `metadataScopeChanged` is either killed by a mutant or documented as
superseded, and `README.md` describes the rule the code actually enforces.

### 43. Protect the expected local harness override from staging

**Classification:** Non-blocking — secret hygiene, no runtime effect

**Depends on:** nothing

**Purpose.** The repository has a tracked shared `.claude/settings.json`, but no repository-owned
ignore rule for the conventional personal override `.claude/settings.local.json`. A contributor who
uses that override in a clone without a matching global ignore can stage it accidentally. This is a
repository-policy task only: private configuration and any credentials in a working copy are outside
the task boundary and must be handled by their owner before staging.

**Primary paths.**

- `.gitignore`

**Required change.**

1. Ignore `.claude/settings.local.json` in the repository's `.gitignore`, so the protection belongs
   to every clone rather than one developer's global configuration.
2. Keep `.claude/settings.json` as shared tracked configuration. Do not copy, move, inspect, or
   restore any user-local replacement as part of this task.

**Non-goals and invariants.**

- Do not commit any credential, and do not copy one into this plan, a commit message, or a test.
- Do not touch `.claude/skills/adversarial-review`; it is the tracked symlink that points the
  harness at the repository's review skill.
- Do not decide the tracking policy for `.antigravity.json`; that is a separate, user-directed scope.

**Validation and falsification.** `git check-ignore -v .claude/settings.local.json` names the
repository's `.gitignore`; the tracked `.claude/settings.json` is unchanged; and a clean-clone check
shows that the policy needs no user-local file to be present.

**Done when.** The repository ignores the conventional local harness override without relying on a
developer's global Git configuration, and the task has not touched user-local configuration.

### 44. Reject successful responses that do not declare supported audio

**Classification:** Non-blocking — provider or proxy failures can become audible noise

**Depends on:** nothing

**Purpose.** The speech delegate records only the HTTP status before forwarding every 2xx
OpenAI-compatible or Custom response to the PCM handler; no production path reads the response media
type. Gemini's SSE parser likewise base64-decodes every `inlineData` part without checking its
declared MIME type. A 200 JSON or HTML error body with an even byte count therefore appears to be
playable PCM, while a non-audio Gemini payload can enter the same path. Existing tests cover status,
empty bodies, malformed SSE, and PCM frame length, but no declared media type.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/Managers/TTSNetworkManager+GeminiStreaming.swift`
- `Tests/TTSNetworkManagerFailureTests.swift`
- `Tests/TTSNetworkManagerGeminiStreamingTests.swift`
- `README.md`

**Required change.**

1. Decide and document the accepted response types, including the compatibility rule for a missing
   or generic type, before changing the delegate state machine.
2. Reject a declared non-audio OpenAI-compatible or Custom 2xx response and a Gemini `inlineData`
   part whose declared type is not the PCM format the player accepts. Publish the existing sanitized
   no-playable-audio outcome rather than provider content.
3. Preserve valid streamed PCM, the request-generation guards, and provider metadata handling.

**Non-goals and invariants.**

- Do not infer a response type from its bytes or expose a response body in an error.
- Do not reject a documented valid provider response merely because a proxy omitted a header unless
  the decided compatibility rule says to do so.
- Keep the empty and partial-frame outcomes owned by Task 38.

**Validation and falsification.** Through the mock protocol, deliver a declared JSON or HTML 2xx
response of even length and a Gemini `inlineData` payload with a non-audio MIME type; each must fail
without audio reaching the player. Prove the selected valid and compatibility types still stream.
Mutation-test the type checks, a missing-header over-restriction, and the accepted-type boundary.

**Done when.** An explicitly non-audio success payload cannot be buffered or reported as successful,
and the documentation states the response-type contract.

### 45. Make URL-session persistence an explicit privacy policy

**Classification:** Non-blocking — untested persistent URL-loading state for clipboard and credential requests

**Depends on:** nothing

**Purpose.** Production constructs `TTSNetworkManager` with `URLSessionConfiguration.default`, while
the test network factory uses `.ephemeral`. The default configuration carries cache, cookie, and
credential stores, but the app has no documented need to persist any of those provider interactions.
This makes production behavior both privacy-sensitive and untested.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`
- `Tests/TestNetworkSupport.swift`
- `Tests/TTSNetworkManagerTests.swift`
- `README.md`

**Required change.** Decide whether this app needs URL-loading persistence. If it does not, use and
test an explicit ephemeral/no-cache/no-cookie policy for production requests. If it does, document
the purpose and test the chosen configuration boundary instead of assuming the platform default.

**Non-goals and invariants.**

- Do not change the mock protocol's per-test identity or teardown ownership.
- Do not silently remove a provider behavior that needs persistence; obtain user direction if that
  decision changes compatibility.
- Keep request authentication and the transport policy independent of URL-session storage policy.

**Validation and falsification.** Inspect the production session configuration through an injected
session seam and assert the decided cache, cookie, and credential-storage behavior. Mutation-test a
reversion to the platform default and an over-restriction that breaks a documented required flow.

**Done when.** Production and tests enforce the same documented URL-loading persistence policy.

### 46. Make clipboard-read diagnostics intentional

**Classification:** Non-blocking — Release-only diagnostic policy

**Depends on:** nothing

**Purpose.** `TextExtractionManager` is the app's only production code that calls `print`, emitting
whether the shared clipboard contained text in every build. The rest of the app reports actionable
user-visible failures through published state and has no documented stdout diagnostic policy.

**Primary paths.**

- `Sources/Managers/TextExtractionManager.swift`
- `Tests/TextExtractionManagerTests.swift`
- `README.md`

**Required change.** Decide whether clipboard-presence diagnostics are an intentional shipped
behavior. Remove them if they are not; otherwise route them through a documented, privacy-conscious
diagnostic mechanism that never exposes copied text and can be tested without process-global output.

**Non-goals and invariants.**

- Do not log copied text or any credential.
- Do not turn an empty clipboard into a user-visible request error without user direction.

**Validation and falsification.** Assert the selected behavior for populated and empty injected
pasteboards. If diagnostics remain, prove a plausible regression that reintroduces copied text into
them fails.

**Done when.** Clipboard-read diagnostics have an explicit, tested release policy.

### 47. Document the network manager's pre-sharing publication state

**Classification:** Non-blocking — misleading concurrency documentation

**Depends on:** nothing

**Purpose.** The `TTSNetworkManager` confinement comment says `@Published` state and
`migrationFailureMessage` are written only on the main queue, but its initializer assigns
`lastError` and `migrationFailureMessage` before the instance is shared. The neighboring session
comment already describes that same construction-time exception.

**Primary paths.**

- `Sources/Managers/TTSNetworkManager.swift`

**Required change.** Amend the confinement documentation so it names both construction-time writes
and their pre-sharing constraint, without weakening the main-queue rule after initialization.

**Non-goals and invariants.**

- Do not change request-state ownership or add synchronization solely for initialization.
- Do not make a claim about a constructor call site that is not verified from the source.

**Validation and falsification.** Read every assignment to `lastError` and
`migrationFailureMessage` against the revised comment; the comment must account for the initializer
and every post-construction write.

**Done when.** The concurrency documentation precisely describes the actual publication boundary.

### 48. Resolve the AudioPlayerManager file-length exception

**Classification:** Non-blocking — planning rule and lint configuration disagree

**Depends on:** nothing

**Purpose.** `AudioPlayerManager.swift` is 417 lines and disables SwiftLint's `file_length` rule,
while Phase 1 says files that reach the 400-line limit are split along cohesion rather than relieved
by an exception. The existing exception predates that rule, leaving the plan and the checked-in lint
configuration inconsistent.

**Primary paths.**

- `Sources/Managers/AudioPlayerManager.swift`
- `TODO.md`

**Required change.** Obtain user direction on whether the file must be split along cohesion or the
Phase 1 rule should explicitly allow this documented exception. Implement only the selected policy
and update the owning documentation in the same commit.

**Non-goals and invariants.**

- Do not suppress another lint rule or raise its global threshold.
- If splitting, preserve audio-queue ownership, scheduling order, and the existing test seams.

**Validation and falsification.** Run the full gates. If splitting, mutation-test any changed
assertion and prove the extracted boundary preserves the previous behavior; if retaining the
exception, prove the plan states its limited rationale accurately.

**Done when.** The plan and the checked-in lint treatment of `AudioPlayerManager` agree.

### 49. Correct the endpoint-policy grammar

**Classification:** Non-blocking — documentation clarity

**Depends on:** nothing

**Purpose.** `EndpointTransportPolicy`'s IPv4 comment omits the relative pronoun in the phrase
"the app asks for an address it and the network stack must read the same way," obscuring a security
rationale that the two parsers must agree.

**Primary paths.**

- `Sources/Managers/EndpointTransportPolicy.swift`

**Required change.** Correct the sentence without changing its security claim or implementation.

**Validation and falsification.** Re-read the surrounding policy documentation and confirm it still
states that ambiguous IPv4 spellings are refused rather than normalized.

**Done when.** The comment is grammatical and preserves its original transport-policy rationale.

### 50. Name Gemini in the project overview

**Classification:** Non-blocking — project overview omits a supported provider

**Depends on:** nothing

**Purpose.** `README.md` describes the app as reading through OpenAI-compatible APIs, but the app
also has a dedicated Gemini streaming transport described throughout its architecture section. The
opening overview should not imply that Gemini is merely OpenAI-compatible.

**Primary paths.**

- `README.md`

**Required change.** Update the overview to name both OpenAI-compatible providers and native Gemini,
without duplicating the provider-contract detail owned by the Design Assumptions section.

**Validation and falsification.** Compare the revised overview against the architecture inventory
and the provider behavior documented later in `README.md`.

**Done when.** The first-paragraph product description names every provider transport the app
supports.

### Phase 5 mandatory gap review

Run the **Phase review gate** on the complete Phase 5 commit range after every task above has landed
or has an explicit user disposition. The final acceptance sweep may begin only after that review
reports no blocking findings and every non-blocking finding has a disposition.

---

## Final acceptance sweep

Run this only after all five phase reviews are closed. It supplements, and does not replace, the
per-task adversarial reviews or the five phase reviews. If it discovers new work, add self-contained
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
   non-24-kHz audio, the 0.1-second startup prebuffer, a Settings voice change reaching only the
   next request, migration retry, and About.
   Obtain user permission and credentials before live-provider tests; never record keys or provider
   response audio.
6. Run a final adversarial review on the complete remediation range — Tasks 17–50, currently
   `2476718..HEAD` — plus any phase-review follow-up tasks added later. Resolve every blocking
   finding and obtain explicit disposition for every non-blocking finding.
7. Reconcile `README.md`, `USER_STORIES.md`, and verified behavior. Remove completed active tasks
   from this file so it contains only genuinely outstanding work and concise decisions that still
   constrain future work.
