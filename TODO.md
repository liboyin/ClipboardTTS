# TODO — Gap Remediation Hand-over

This document is the authoritative execution plan for the verified remediation gaps. It is written
for implementation sessions that share no conversation context: each executor must be able to
understand one task from the repository and this file alone.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md` owns
product behavior; `README.md` owns the current architecture and operating instructions. Treat
descriptions here as task boundaries, not as substitutes for re-reading the affected code.

Task 14 remains intentionally removed. Nothing in this plan reinstates the stateful menu-bar icon.

## Current status

- Eleven tasks are active in Phase 5: 38, 40–42, 44–46, 48, and 52–54. Task 36 was withdrawn when voice
  selection left the menu-bar drop-down. Phase 4's gap review has now run over its complete range
  and found no Phase 4 gap other than Task 42; the phase closes once that finding has an explicit
  user disposition. Phase 5 then addresses every outstanding review gap, and the final acceptance
  sweep follows its own gap review.
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

Phase 5 contains Tasks 38, 40–42, 44–46, 48, and 52–54: Task 38 is blocking; the rest are
non-blocking. It begins only after Phase 4 closes. Within Phase 5 none of the tasks depends on
another, so they may be executed in any order, one self-contained commit each. No final-sweep work
may begin until every one of them has landed or been explicitly deferred by the user.

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
starts only after Phase 4 closes. Task 38 is blocking; Tasks 40–42, 44–46, 48, and 52–54 are
non-blocking. Each task remains a separate commit and must follow the working rules above.

See [README.md](README.md#design-assumptions) for the Gemini early-stop completion rule that binds
later checks.

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
   Re-read Task 53 first: its menu-bar check needs a provider accessor that returns no credential,
   which `metadataSettingsSnapshot()` does not satisfy. If Task 53 landed first, re-check `Sources`
   — this accessor may already have the production caller whose absence this step rests on.
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

### 52. Resume playback after a streaming underrun

**Classification:** Non-blocking — playback can stop permanently while audio is still arriving; the
end-of-stream ownership design needs a user decision before implementation

**Depends on:** nothing

**Purpose.** The progress timer pauses whenever `playbackProgress` reaches `bufferDuration`, but
`bufferDuration` is only the audio received so far, not the end of the stream. An ordinary underrun —
made likelier by a playback rate above 1.0 or a slow provider — therefore calls `pause()`, which
stops the timer and clears `isPlaying`. Nothing resumes it: automatic playback is one-shot per
stream, guarded by `automaticPlaybackGeneration`, so later `scheduleAudio` calls keep appending
buffers to a paused node. Manual recovery is also poor, because `play()` seeks back to zero when
`playbackProgress >= bufferDuration`. `AudioPlayerManager` has no end-of-stream signal at all, so it
cannot currently tell an underrun from a completed read. A user-initiated `pause()` also clears
`isPlaying`, so later audio must not make an intentional pause resume. No existing test exercises the
timer's pause branch; `Tests/AudioPlayerManagerAutomaticPlaybackTests.swift` covers the prebuffer and
frame accounting only, and its scheduler does not control render-time progress.

**Primary paths.**

- `Sources/Managers/AudioPlayerManager.swift`
- `Sources/Managers/TTSNetworkManager+Failures.swift`
- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/Views/MenuBarView.swift`
- `Sources/Views/SettingsView.swift`
- `Sources/Managers/ServicesCoordinator.swift`
- `Tests/AudioPlayerManagerTests.swift`
- `Tests/AudioPlayerManagerAutomaticPlaybackTests.swift`
- `README.md`

**Required change.**

1. Before implementation, obtain user direction on the end-of-stream owner and write the selected
   interface here. The decision is between an explicit generation-tagged terminal callback from
   `TTSNetworkManager` to the stream owner, delivered through the ordered audio-delivery path, and a
   different explicitly named bridge. Do not infer end-of-stream from the published `isStreaming`
   value: its main-queue publication can race ahead of accepted audio deliveries.
2. The selected signal MUST carry the stream generation, be delivered after every earlier accepted
   PCM handoff for that generation, and be invalidated by `stop()`, Clear Buffer, replacement, and
   a stale request. A terminal signal for an already-revoked generation must be a no-op. Add the
   originating and consuming paths named above only when the selected interface needs them; preserve
   their existing request-generation ownership.
3. Model three distinct states in `AudioPlayerManager`: an automatic underrun while the stream is
   open, a genuine stream end after the buffered audio plays out, and an intentional user pause.
   Later audio resumes only the first state, from the current buffer end without replaying from zero
   or reapplying the startup prebuffer. A user pause MUST remain paused until the user chooses Resume,
   even if the stream remains open and new audio arrives.
4. Extract or inject the progress-tick input needed to test the timer branch deterministically. The
   existing automatic-playback scheduler is not such a seam because the timer reads live
   `AVAudioPlayerNode` render time. Keep production timer ownership on the main queue.

**Non-goals and invariants.**

- Do not change the automatic-playback prebuffer duration or the one-shot automatic-playback contract
  without user direction.
- Preserve the `scheduleGeneration` guards, the exact-end seek behavior that suppresses pending
  automatic playback, and `stop()`'s documented bump-then-stop ordering.
- Do not let newly received audio override an intentional user pause.

**Validation and falsification.** Through the new deterministic progress seam, schedule a short
buffer for an open stream and drive rendered progress past `bufferDuration`; after later audio is
scheduled, assert rendering resumes without a manual `play()`, without restarting from zero, and
without a second startup prebuffer. Separately prove that a manual pause stays paused after more
audio, and that a terminal signal followed by buffer exhaustion stays paused at a genuine end.
Force the final PCM handoff to wait behind the ordered delivery queue and prove the terminal signal
cannot overtake it. Mutation-test the resume path, a regression restoring the unconditional pause,
the generation/order guard on the terminal signal, and an over-restriction that never pauses at a
genuine end of stream.

**Done when.** A mid-stream underrun cannot permanently stop playback, a manual pause and a genuine
end remain paused, stale terminal signals have no effect, and the selected end-of-stream contract is
documented.

### 53. Reject oversized OpenAI clipboard text at the menu-bar entry point

**Classification:** Non-blocking — user-requested validation and feedback; the dialog copy, the
Unicode counting unit, and the settings-race scope need user decisions before implementation

**Depends on:** nothing. This must not wait for Gemini work: the user selected an OpenAI-only,
local check precisely to preserve Gemini's fastest-start path. It does not depend on Task 41 either,
but the two meet at one accessor: Task 41 proposes removing `isCurrentProvider(_:)` because nothing
in `Sources` calls it, and step 1 below needs exactly such a credential-free provider accessor.
Whichever lands second MUST re-read the other's entry before changing that accessor.

**Purpose.** OpenAI's Speech API documents a maximum `input` length of 4,096 characters for every
model it accepts, including `tts-1` and `tts-1-hd`
(<https://platform.openai.com/docs/api-reference/audio/createSpeech>). The OpenAI model field is
user-editable, so re-verify that limit against the current reference for the configured model before
implementing it. The current menu-bar path in `Sources/Views/MenuBarView.swift` deactivates the app,
waits 0.2 seconds, reads the clipboard, then immediately starts a stream and calls
`TTSNetworkManager.streamTTS`. An oversize OpenAI request thus costs a speech request and reports
only its eventual generic HTTP failure. `lastError` currently renders inline in the menu; it is not
the user-requested pop-up.

The user's selected boundary is deliberately narrow: validate only after **Speak Copied Text** was
clicked and its deferred clipboard read has produced text. Do not put this rule in
`TTSNetworkManager.streamTTS`, because that would also change Services and Settings' Test Voice,
which are outside the agreed scope.

OpenAI's documentation says only “characters”; it does not define the Unicode counting unit. It is
therefore not yet sound to silently choose Swift extended grapheme clusters, Unicode scalars,
UTF-16 code units, or UTF-8 bytes. An executor MUST obtain user direction on that contract under
step 6 before implementing the local limit.

**Primary paths.**

- `Sources/Views/MenuBarView.swift`
- `Sources/Managers/TTSNetworkManager.swift`
- `Sources/ClipboardTTSApp.swift`
- `Tests/MenuBarViewTests.swift`
- `Tests/MenuBarDeferredClipboardActionTests.swift`
- `USER_STORIES.md`
- `README.md`

**Required change.**

1. At the existing deferred action's post-delay idle/generation revalidation, after the clipboard
   returns text and before `AudioPlayerManager.startNewStream()` or `streamTTS`, ask the manager
   whether the selected provider is the built-in OpenAI provider. Do not duplicate endpoint or
   provider inference in the view. No existing accessor fits, so choose one deliberately:
   `requestSettingsSnapshot()` and `metadataSettingsSnapshot()` both return `apiKey`, so a view must
   not read either to learn a provider, and `TTSNetworkManager.ProviderKind.openAICompatible` means
   "not Custom, and not a `generativelanguage` base URL" rather than "the built-in OpenAI provider" —
   the two coincide only because Settings pins each built-in provider's base URL to a constant.
   `isCurrentProvider("OpenAI")` asks the persisted-identity question directly and returns no
   credential, but Task 41 proposes deleting it. Keep it, or add an equally credential-free provider
   accessor, and record the choice in Task 41's entry in the same commit.
2. For an OpenAI clipboard value over the selected 4,096-character measure, make no speech request,
   schedule no audio, and leave the idle audio pipeline intact. Reactivate the app and present a
   native macOS pop-up (`NSAlert` or an equivalently accessible AppKit dialog) carrying the app-owned
   copy recorded under step 6 and naming the 4,096-character maximum. Reactivation belongs to the
   presenter seam of step 4, not to the view: a hosted test must not activate the real test host. Do
   not also publish this click-only outcome through `lastError`, whose inline rendering would
   duplicate the pop-up.
3. Keep valid OpenAI requests, Gemini requests, and Custom requests on their current one-request,
   fastest-start path. The check must perform no provider call and must not delay a valid request
   beyond the existing local clipboard-read flow.
4. Introduce an injected alert-presenter seam that owns both the reactivation and the dialog, so a
   hosted test can observe the exact contract without activating the test host or displaying a real
   modal panel. The production presenter must be main-queue confined; the delayed action already
   returns to the menu flow after the app was deactivated. `Sources/ClipboardTTSApp.swift` builds the
   only production `MenuBarView`, and `makeMenu` in `Tests/MenuBarViewTests.swift` the only test one,
   so both construction sites change with the seam.
5. Update `USER_STORIES.md` with the resulting click-time OpenAI behavior and `README.md` with the
   provider scope, popup ownership, chosen Unicode unit, and no-network preflight rationale.
6. Before implementation, obtain user direction on three points, record each here and in `README.md`,
   and carry the user-visible part into `USER_STORIES.md`:
   - the Unicode counting unit named under **Purpose**;
   - the exact dialog wording. An executor MUST NOT choose it, for the same reason the Gemini
     early-stop copy was a user decision: the wording is the whole user-visible outcome; and
   - whether a provider switch between this check and the request is in scope. `streamTTS` takes its
     own `requestSettingsSnapshot()` when the request starts, and `deferRequestStartIfPublishingState`
     can defer that start to a later main-queue turn, so a Settings edit inside that window can
     produce an alert for a request that would have gone to Gemini, or an oversize OpenAI request
     with no alert. The request-generation revalidation does not cover it, because a settings edit
     advances no generation.

**Non-goals and invariants.**

- Do not add Gemini token counting, a Gemini character limit, request chunking, or a second network
  call before any speech request.
- Do not apply this UI-only limit to Services, Settings' Test Voice, or Custom endpoints.
- Do not expose clipboard contents, a credential, a configured endpoint, or provider response text
  in the dialog.
- Preserve `DeferredClipboardAction` ownership, the request-generation revalidation, and the
  two-click Clear Buffer contract. A stale delayed action must not surface an alert or begin speech.

**Validation and falsification.** Use an injected pasteboard and alert presenter to prove that a
4,096-unit OpenAI value begins exactly one speech request, while a 4,097-unit value presents the
fixed dialog and begins neither a request nor an audio stream. Prove that Gemini and Custom values
over the same local size still reach their existing request paths, and that an oversize OpenAI value
still starts exactly one request through `ServicesCoordinator` and through Settings' Test Voice,
neither of which consults this view-owned guard. Add boundary cases for combining marks, emoji, and
non-Latin text after the user selects the Unicode unit. Mutation-test a removed/relocated guard, an
off-by-one limit, a provider check that accidentally blocks Custom or Gemini, and a stale-action
regression that presents after the request generation changed.

**Done when.** The button-click flow rejects only oversized OpenAI clipboard text with one accessible
app-owned pop-up carrying the recorded copy, valid requests retain their fastest-start path, unrelated
entry points are unchanged, and the selected Unicode-counting contract is documented and
mutant-protected.

### 54. Compile the test target under complete strict concurrency

**Classification:** Non-blocking — the required gate set never compiles the test bundle under the
setting the app target is held to

**Depends on:** nothing. It touches no production behavior, so it may run beside any other task, but
it edits the shared hosted-Settings and mock-network test infrastructure.

**Purpose.** `project.yml` sets `SWIFT_STRICT_CONCURRENCY: complete` on the `ClipboardTTSApp` target
alone; `ClipboardTTSAppTests` declares no such setting and so inherits the default. The gate in
`AGENTS.md` builds only the app scheme with that flag, so no checked-in command has ever compiled the
test bundle under complete concurrency, and `README.md` correctly scopes its claim to the app target.

Building the test target with the flag fails. Verified on 2026-09-03 at `b728235`:

```bash
xcodebuild -project ClipboardTTSApp.xcodeproj -scheme ClipboardTTSAppTests \
  -destination 'platform=macOS' SWIFT_STRICT_CONCURRENCY=complete \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

It reports exactly one error, `Tests/HostedSettings.swift:198:41: call to main actor-isolated
function in a synchronous nonisolated context`: `edit(_:to:file:line:)` calls the delegate's
`controlTextDidChange?`, which the macOS SDK isolates to the main actor, from a nonisolated method of
a `HostedSettings` that is not itself annotated. The compiler proposes `@MainActor` on that method.

The remedy is not that one annotation, and an executor must not assume it is. Both obvious fixes were
measured in an isolated scratch copy on 2026-09-03 and both cascade, because the compiler reports one
file batch at a time and each fix exposes the next:

- Annotating `edit(_:to:file:line:)` moves the failure to its callers at `HostedSettings.swift:133`
  and `:147`.
- Annotating `final class HostedSettings` instead moves it into the XCTest methods themselves, as
  three errors in `Tests/SettingsAboutTests.swift` at lines 43, 54 and 58 — the initializer, `click`,
  and `release` — plus main-actor warnings at lines 69 and 80 of that same file.

The baseline command also emits strict-concurrency warnings before it stops. They include AppKit and
SwiftUI accesses throughout `HostedSettings`, its separate `HostedModelVoiceFields` helper, and the
two condition-guarded static variables in `MockURLProtocolScope.swift`. Those diagnostics are in
scope: `AGENTS.md` requires inspecting warnings, and they would become errors in Swift 6 language
mode. The first error prevents the compiler from revealing every later diagnostic, so the executor
must continue until the complete test target has no project-source strict-concurrency warnings or
errors.

**Primary paths.**

- `Tests/HostedSettings.swift`
- `Tests/SettingsAboutTests.swift`
- `Tests/SettingsMigrationRecoveryTests.swift`
- `Tests/SettingsViewTests.swift`
- `Tests/SettingsVoiceMetadataTests.swift`
- `Tests/TTSNetworkManagerAuthenticationTests.swift`
- `Tests/MockURLProtocolScope.swift`
- `project.yml`
- `README.md`

**Required change.**

1. Hold the test target to the same setting as a required gate. The user decided on 2026-09-03
   that the gates cover both targets, so give `ClipboardTTSAppTests` `SWIFT_STRICT_CONCURRENCY:
   complete` in `project.yml`. That is what makes `./check-coverage.sh` compile the bundle under the
   setting on every run, rather than leaving the check to a command an agent has to remember; a fix
   without it would rot exactly as this one did.
2. Give both UI-host helpers — `HostedSettings` and `HostedModelVoiceFields`, plus their shared
   hosting helpers — explicit main-actor isolation. They drive `NSHostingView`, `NSTextField`, and
   SwiftUI coordinators, all of which the SDK confines to the main actor. Propagate that isolation to
   every XCTest method using either helper, including the primary paths above and any compiler-found
   user, rather than adding escapes at individual AppKit call sites.
3. Resolve the strict-concurrency diagnostics in `MockURLProtocolScope.swift` without weakening its
   existing `NSCondition`-guarded ownership, its off-main bounded revocation, or its teardown
   quiescence contract. Do not use `@unchecked Sendable`, `nonisolated(unsafe)`, or a production-code
   isolation change to silence test diagnostics; give the test infrastructure a compiler-verifiable
   ownership boundary instead.
4. Re-run the command above after every fix and inspect the output. A zero error count in one run
   does not establish that the next batch compiles, because the build stops at the first failing
   batch. Continue until it reports no project-source strict-concurrency warnings or errors.
5. Update `README.md`'s strict-concurrency scope in the implementation commit: both targets will be
   checked, with the test target compiled by `./check-coverage.sh` and the app target by the explicit
   app build. Do not alter `AGENTS.md` merely because its app-build command remains app-only, and do
   not try to update this task's entry: the working rules require removing it when the task completes.

**Non-goals and invariants.**

- Do not change any production isolation in `Sources/` to satisfy a test, and do not relax the app
  target's existing complete-concurrency setting.
- Do not reach for `@unchecked Sendable` or `nonisolated(unsafe)` where main-actor confinement is the
  honest answer. `README.md` reserves the former for the URL-session delegate bridge.
- Preserve every hosted-view lifecycle contract `README.md` states: the windowless host, the release
  and main-queue drain before the mock scope closes, addressing a field by position and expected
  text, and reaching an action by clicking its `SettingsActionButton`.
- Do not change what any test asserts, its quiescence and teardown ownership, or the suite's coverage.

**Validation and falsification.** The command above must report no project-source
strict-concurrency warnings or errors. The required gate set must pass in its updated form:
`./check-coverage.sh` at 198 tests with `Sources/Managers/` above its threshold, now compiling the
test bundle under complete strict concurrency; `swiftlint --strict`; and the app's
complete-concurrency build. The coverage test and app build together cover both targets; neither means
that every individual gate compiles both. Prove the hosted Settings tests still exercise real AppKit
controls rather than passing because an annotation made them skip: a mutant that breaks a hosted
field edit, and one that breaks a hosted button click, must each still fail their test. Re-run the
mock-network lifecycle tests after the ownership change and prove a mutant that removes condition
protection from a scope-state access fails; the replacement isolation must not conceal an unlocked
shared-state regression.

**Done when.** The required gate set collectively compiles both targets under complete strict
concurrency with no project-source strict-concurrency warnings or errors, the hosted Settings and
mock-network lifecycles are unchanged, and `README.md` describes the scope the build enforces.

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
