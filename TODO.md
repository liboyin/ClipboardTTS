# TODO — Remediation Hand-over

This document is the executable plan for resolving the findings from the whole-project
adversarial review. It replaces the previous hand-over, whose task list and line references
no longer matched the repository.

Read `AGENTS.md`, `USER_STORIES.md`, and `README.md` before starting. `USER_STORIES.md`
owns product behavior; `README.md` owns current architecture and operating instructions.
Keep those documents current rather than duplicating their content here.

## Working rules

- Execute tasks in the order shown unless a task explicitly says it is independent.
- There are exactly 15 numbered tasks. Each task MUST be one self-contained implementation
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
| Active requests change decoder when provider settings change | Blocking | 3 |
| Seeking to the buffered end leaves false playing state | Blocking | 10 |
| Custom requests send empty model and voice values | Blocking | 7 |
| API keys use plaintext preferences, URL queries, and unsafe logging | Blocking | 8 |
| Gemini buffers the full response instead of streaming | Blocking | 9 |
| Network and API failures are invisible in the UI | Blocking | 6 |
| Custom audio is always interpreted as 24-kHz PCM | Blocking | 11 |
| Required voice, icon, and About UI is missing | Blocking | 13–15 |
| Stale metadata responses can replace the current provider's models | Blocking | 5 |
| Settings keys have three hand-maintained definitions | Non-blocking | 2 |
| The streaming callback executes while the state lock is held | Non-blocking | 4 |
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

## Phase 1 — Establish shared configuration

### 2. Give persisted settings one source of truth

**Classification:** Non-blocking, scheduled early because Tasks 7, 8, 11, and 13 depend on it

**Depends on:** Nothing

**Problem.** The same settings-key strings are repeated in `SettingsView`,
`TTSNetworkManager`, and `Tests/UserDefaultsSnapshot`. Adding a key in only one or two places
can make tests depend on or overwrite the developer's actual configuration.

**Required change.**

1. Add a `SettingsKeys` namespace in production code containing every persisted non-secret
   key and the legacy secret-key names needed by Task 8's migration.
2. Expose an `allUserDefaultsKeys` collection used by test isolation.
3. Replace literals in `@AppStorage`, `TTSNetworkManager`, and `UserDefaultsSnapshot`.
4. When later tasks add Custom model, voice, or sample-rate settings, add them only through
   this namespace.
5. Keep Keychain account identifiers separate from `UserDefaults` keys so the storage
   boundary is explicit.

**Tests and falsification.**

- Test that `allUserDefaultsKeys` contains every declared preference key exactly once.
- Prove snapshot restore behavior for both originally present and originally absent values.
- Mutation-test omission of a newly introduced key from the isolation collection.

**Done when.** Each persisted setting string has one declaration, test isolation enumerates
that source, and no production or test file carries a second literal copy.

## Phase 2 — Repair network state and failure behavior

### 3. Bind response parsing to immutable per-request context

**Classification:** Blocking

**Depends on:** Task 2

**Problem.** `streamTTS` chooses a request format from the current provider, but URL-session
delegate callbacks later re-read mutable manager settings. Switching provider during an
active request can forward Gemini JSON as PCM or buffer OpenAI PCM as Gemini data.

**Required change.**

1. Introduce an explicit provider kind and immutable request-settings snapshot.
2. Store an active-request context under `stateQueue`. It must contain the task identifier,
   provider/decoder kind, data handler, error state, and provider-specific incremental buffer.
3. Delegate callbacks must consult only the context belonging to their task. They MUST NOT
   infer response format from the manager's current `baseURL`.
4. Preserve the current non-cancelling behavior unless the user directs otherwise:
   `updateSettings` affects the next request only, while the active task finishes with its
   captured configuration.
5. Preserve stale-task rejection and the audio stream-generation guard.

**Tests and falsification.**

- Start delayed Gemini, switch settings to OpenAI, and assert only decoded Gemini audio is
  delivered.
- Start delayed OpenAI, switch settings to Gemini, and assert PCM is forwarded unchanged.
- Cover stale data and completion callbacks after stop and after replacement.
- Mutation-test delegate code that consults current settings instead of task context.

**Done when.** Provider changes cannot alter an active task's URL, authentication, payload,
decoder, buffers, or handler.

### 4. Invoke client callbacks outside `stateQueue`

**Classification:** Non-blocking

**Depends on:** Task 3

**Problem.** The OpenAI data handler currently runs inside `stateQueue.sync`. A handler that
calls `stopStreaming()` recursively synchronizes on the same serial queue and can deadlock or
trap.

**Required change.**

1. Under `stateQueue`, validate the task and capture the data plus handler needed for delivery.
2. Exit the queue before invoking client code.
3. Apply the same rule to completion-time Gemini delivery after Task 9: no external callback,
   UI publication, logging formatter, or decoder with unknown re-entrancy may run while the
   state queue is held.
4. Document the lock boundary and callback ordering.

**Tests and falsification.**

- Use a handler that calls `stopStreaming()` and prove it completes within a bounded timeout.
- Verify no data is delivered after the re-entrant stop.
- Mutation-test moving handler invocation back inside the queue.

**Done when.** Client callbacks can safely stop or replace a stream without queue re-entry.

### 5. Reject stale provider-metadata completions

**Classification:** Blocking

**Depends on:** Task 3

**Problem.** A delayed OpenAI model request can complete after a switch to Gemini and replace
the current provider's model list.

**Required change.**

1. Track model and voice metadata requests explicitly, using cancellation plus a provider or
   generation token checked before publication. Cancellation alone is not sufficient because
   completion can race.
2. Invalidate outstanding metadata work whenever the selected provider or endpoint changes.
3. Publish results on the main actor/queue only when the response still belongs to the current
   metadata generation.
4. Keep model and voice request state separate if they can complete independently.
5. Clear or replace lists deterministically during provider changes so the UI never presents
   entries from the previous provider.

**Tests and falsification.**

- Delay an OpenAI model response, switch to Gemini, complete the old response, and assert the
  Gemini list remains.
- Repeat with two Custom endpoints and with voice metadata.
- Cover cancellation, malformed responses, and an empty successful list.
- Mutation-test removal of the generation/provider guard.

**Done when.** Only the latest provider and endpoint may publish model or voice metadata.

### 6. Surface request failures to the user

**Classification:** Blocking

**Depends on:** Tasks 3–5

**Problem.** Invalid URLs, encoding failures, non-2xx responses, transport failures, and
provider-decoding failures only print to the console. Users receive no explanation when
speech does not start.

**Required change.**

1. Define a small user-facing error model, or a sanitized `lastError` string, published by
   `TTSNetworkManager` on the main actor/queue.
2. Clear stale error state at the start of a new request.
3. Set an error for invalid configuration, request encoding, non-2xx responses, transport
   failure, and malformed/empty provider audio.
4. Include only actionable, bounded information such as HTTP status and a short sanitized
   message. Never expose keys, authorization headers, full request URLs, or unbounded bodies.
5. Render the error in `MenuBarView` without hiding playback controls.
6. Clear the message on the next request and on explicit Clear Buffer; document this behavior.

**Tests and falsification.**

- Assert each failure class publishes an error and finishes streaming state.
- Assert the next request clears the previous error and a later success leaves it cleared.
- Test truncation/redaction of error bodies containing key-like material.
- Add a view construction/state test showing the error only when present.

**Done when.** A user can distinguish invalid configuration, authentication/API failure, and
transport failure without consulting Console, and no secret can enter the UI or logs.

## Phase 3 — Define provider contracts and secure secrets

### 7. Implement the OpenAI-compatible Custom model/voice contract

**Classification:** Blocking

**Depends on:** Tasks 2–6

**Problem.** Custom settings return empty model and voice values, while request encoding still
sends `"model": ""` and `"voice": ""`. The current test incorrectly claims those fields are
omitted.

**Required change.**

1. Add persisted Custom model and voice fields using `SettingsKeys`.
2. Require non-empty, non-whitespace model and voice values before issuing a Custom request.
   Invalid configuration must use Task 6's user-visible error path without contacting the
   endpoint.
3. Include both values in every Custom `/v1/audio/speech` payload. Do not preserve the current
   empty-string behavior and do not conditionally omit the fields.
4. Make request-body construction explicit and typed enough that required key inclusion is
   testable without relying on dictionary accident.
5. Correct `SettingsViewTests` so it inspects the emitted request rather than only computed
   properties.
6. Ensure Test Voice and normal clipboard/Services speech use the same validated contract.
7. Record the OpenAI-compatible Custom contract in README Design Assumptions when implemented.

**Tests and falsification.**

- Decode an intercepted Custom request and assert exact model/voice key presence and values.
- Cover missing, whitespace-only, and valid configuration.
- Assert invalid configuration produces Task 6's user-visible error without issuing a request.
- Mutation-test empty-string acceptance and omission of either required field.

**Done when.** The Custom payload, settings UI, tests, and README describe one consistent
model/voice contract.

### 8. Move API keys to Keychain and remove key-bearing URLs/logs

**Classification:** Blocking

**Depends on:** Tasks 2, 6, and 7

**Problem.** OpenAI, Gemini, and Custom keys are stored in plaintext `UserDefaults`. Gemini
puts its key in the query string, and the invalid-URL path can print the composed URL.

**Required change.**

1. Introduce a narrow secret-store protocol and a production Keychain implementation. Use a
   stable service identifier and one account per provider.
2. Inject an in-memory implementation into tests; unit tests MUST NOT access the developer's
   real Keychain.
3. Replace secret `@AppStorage` fields with view state backed by the secret store. Keep
   provider, endpoint, model, voice, and sample rate in `UserDefaults`.
4. Migrate each legacy preference key once. Delete the legacy value only after a confirmed
   Keychain write; preserve it and surface an actionable error if migration fails.
5. Send the Gemini key using the currently documented authentication header rather than a URL
   query. Verify the header name against current official Google documentation at execution
   time.
6. Redact or remove request logging. No error path may interpolate a composed URL that can
   contain credentials.
7. Do not place real keys in tests, fixtures, command output, or commits.

**Tests and falsification.**

- Test secret create/read/update/delete and error mapping against the in-memory store.
- Test successful legacy migration, failed write without deletion, and idempotent subsequent
  launch.
- Intercept all provider requests and assert keys appear only in the correct header.
- Assert URLs, logs, error state, and `UserDefaults` contain none of the injected secret
  values.
- Mutation-test deleting a legacy key before a failed store write.

**Done when.** No production secret value appears in `UserDefaults`, URLs, logs, errors, or
committed fixtures; legacy installs migrate without data loss.

### 9. Stream Gemini audio incrementally

**Classification:** Blocking

**Depends on:** Tasks 3, 4, 6, and 8

**Problem.** Gemini currently calls the non-streaming endpoint, buffers the complete JSON
response, and delivers audio only after task completion. This violates the project's
time-to-first-audio goal.

**Required change.**

1. Verify the current Gemini TTS streaming endpoint, authentication, event format, audio
   encoding, and whether chunks are actually emitted incrementally using official Google
   documentation. Provider formats are not stable enough to implement from memory.
2. Put streaming parser state in Task 3's active-request context.
3. Implement a small incremental event parser that accepts arbitrary byte boundaries, retains
   incomplete events, handles the documented line-ending form, and emits only complete events.
4. Decode and forward each complete audio chunk outside the state queue. Do not attempt base64
   decoding on partial events.
5. Convert malformed events, missing audio, and provider error events into Task 6's error
   model without corrupting already delivered audio.
6. Update README's Network section so it accurately distinguishes verified streaming behavior
   for each provider.

**Tests and falsification.**

- Feed one event split across several URL-session callbacks.
- Feed multiple events in one callback and across awkward boundaries, including base64 padding.
- Assert the first audio handler invocation occurs before task completion.
- Cover malformed JSON, missing audio, an HTTP error stream, and cancellation mid-event.
- Mutation-test parsing each callback as a complete event and buffering until completion.
- If the user supplies a Gemini key, perform a manual timing smoke test without recording the
  key or response content.

**Done when.** Valid Gemini audio is delivered incrementally before response completion, and
the two-second product target can be meaningfully measured.

## Phase 4 — Repair audio boundaries and Custom format

### 10. Correct exact-end seek state

**Classification:** Blocking

**Depends on:** Nothing

**Problem.** Seeking to `bufferDuration` stops `AVAudioPlayerNode` but leaves `isPlaying`
true because no remaining buffer is scheduled and no paused/stopped state is published.

**Required change.**

1. Clamp requested progress to the valid buffered range.
2. Define exact-end behavior explicitly: stop/pause the node, set progress to the buffer end,
   set `isPlaying` false, and stop the progress timer while retaining the buffer for replay.
3. Preserve current behavior for a middle seek and replay from zero after completion.
4. Keep `playerNode` operations and buffered-data reads consistently ordered. While working in
   this area, add evidence for any claimed scheduling race rather than assuming
   `AVAudioPlayerNode` semantics.

**Tests and falsification.**

- Seek to zero, middle, exact end, just below end, and beyond end.
- Cover both playing and paused preconditions.
- Assert exact end is silent, not playing, and still has buffered audio available for replay.
- Mutation-test the existing early return that leaves `isPlaying` true.

**Done when.** Slider boundary values produce truthful playback state and replay remains
possible without re-fetching audio.

### 11. Make the Custom PCM sample rate configurable

**Classification:** Blocking

**Depends on:** Tasks 2, 7, and 10

**Problem.** `AudioPlayerManager` always interprets PCM as 24-kHz mono 16-bit audio. A Custom
endpoint returning 22.05 or 44.1/48 kHz therefore has wrong duration, speed, pitch, and seek
math.

**Required change.**

1. Add a persisted Custom sample-rate field using `SettingsKeys`, defaulting to 24000 Hz.
2. Validate a finite numeric value within the supported range selected by the implementation
   (the existing decision suggested 8000–48000 Hz). Invalid input must produce clear inline or
   Task 6 error feedback and must not partially rebuild the graph.
3. Add a focused `AudioPlayerManager` API for changing sample rate.
4. On actual change, stop playback, clear buffered data and progress, disconnect/reconnect the
   fixed-format audio graph, and restart the engine safely.
5. OpenAI and Gemini must select 24 kHz automatically; only Custom uses the override.
6. Document the default and Custom override in README Design Assumptions.

**Tests and falsification.**

- At 48 kHz, 48,000 mono Int16 frames must report one second, not two.
- Cover the default rate, a non-default valid rate, unchanged rate, invalid values, and engine
  rebuild failure.
- Assert a format change clears playing/buffer/progress state.
- Verify schedule, seek, and timer math all derive from the rebuilt format.
- Mutation-test retaining the hard-coded 24-kHz divisor in any one path.

**Done when.** Supported Custom sample rates play and seek with correct timing, and changing
format cannot leave mixed-format buffered audio.

### 12. Add a 0.1-second automatic-playback prebuffer

**Classification:** Requested implementation change

**Depends on:** Tasks 10 and 11

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

**Depends on:** Tasks 2, 5, and 7

**Problem.** Voice selection exists only in Settings, although `USER_STORIES.md` requires it
in the menu and restricts changes to idle state.

**Required change.**

1. Add a menu voice control bound to the selected provider's persisted voice.
2. Populate it from provider-authoritative metadata that passed Task 5's freshness guard.
   Verify at execution time whether OpenAI exposes voice discovery; if it does not, use and
   document a version-appropriate list from official documentation rather than inventing an
   endpoint. Define Custom behavior from Task 7's chosen contract.
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
