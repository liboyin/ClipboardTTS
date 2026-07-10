# TODO — Hand-over Document

Follow-up work for ClipboardTTS, written to be executable by any agent or human without
further context. Read `AGENTS.md` (workflow rules) and `README.md` (architecture, build &
test commands) before starting.

Ground rules for every task below:

- Tasks are independent unless a dependency is stated. Execute one task per commit.
- After any code change: `xcodegen generate` (if `project.yml` changed), then
  `./check-coverage.sh` must pass (runs tests + enforces ≥85% line coverage on
  `Sources/Managers/`), and `swiftlint --strict` must be clean.
- Delete a task from this file in the same commit that completes it.
- Items marked **[needs user decision]** have an open question — ask before implementing.

---

## 3. Fix residual concurrency races (bug)

**Context.** Commit `200772d` fixed the data race on `AudioPlayerManager`'s audio buffers,
but the same pattern remains one layer up, plus one narrow window in the player:

- `TTSNetworkManager.streamTTS` (`Sources/Managers/TTSNetworkManager.swift:106-118`)
  resets `isErrorResponse` / `errorData` / `geminiBuffer` on the caller's thread while a
  just-cancelled task's delegate callbacks may still be running on the session's delegate
  queue (delegate queue is nil ⇒ URLSession's own serial background queue). A stale
  callback can append to the freshly-cleared buffers or flip `isErrorResponse` for the new
  request.
- `stopStreaming()` (`:121-127`) cancels the task but never clears `dataHandler`, so a
  late in-flight chunk can still call `scheduleAudio` and resurrect audio after a stop.
- `AudioPlayerManager.stop()` (`Sources/Managers/AudioPlayerManager.swift:110-125`) calls
  `playerNode.stop()` *before* the `bufferQueue.sync` clear; a `scheduleAudio` block
  already queued on `bufferQueue` can schedule one more buffer after the stop.

**Change.** Suggested approach (adapt if a simpler one holds up):
- Confine all of `TTSNetworkManager`'s mutable per-request state to one serial context.
  A clean option is a generation/request-ID counter: increment on every `streamTTS` /
  `stopStreaming`, capture it in the delegate callbacks, and no-op when stale. This also
  fixes the `dataHandler` leak (nil it or gate it on the generation).
- Same generation idea in `AudioPlayerManager`: `stop()` bumps a generation inside
  `bufferQueue`; queued `scheduleAudio` blocks compare and drop.

**Done when.** All existing tests pass, new tests cover "chunk arrives after stop is a
no-op" for both managers, and the test scheme runs clean under Thread Sanitizer
(`xcodebuild test -enableThreadSanitizer YES`, or toggle in the scheme).

## 4. Key security: Keychain + header + no key logging

**Context.** API keys are stored in plaintext `UserDefaults` (via `@AppStorage` in
`Sources/Views/SettingsView.swift:9-11` and read in
`Sources/Managers/TTSNetworkManager.swift:21-38`). The Gemini key is embedded in the URL
query string (`:57`), which leaks into proxies and any log line that prints the URL — and
`streamTTS` does exactly that when the URL fails to parse (`:60`).

**Change.** Three parts, in increasing size:
1. **Never log key material.** In `streamTTS`'s failure path, log a redacted URL or just
   the base URL, never the composed `urlString`.
2. **Gemini key via header.** Send `x-goog-api-key: <key>` instead of `?key=`. Update the
   URL assertion in `Tests/TTSNetworkManagerTests.swift` (`testNetworkManagerFormatsGeminiRequestCorrectly`
   and `testNetworkManagerInitReadsProviderSpecificDefaults`) to expect the header.
3. **Keychain storage.** Replace the three `@AppStorage` key fields with a small
   Keychain-backed store (a `KeychainStore` type in `Sources/Managers/` wrapping
   `SecItemAdd`/`SecItemCopyMatching`/`SecItemUpdate`, service =
   `com.clipboardtts.ClipboardTTSApp`, one account per provider). `TTSNetworkManager.init`
   reads keys from it instead of `UserDefaults`. Include a one-time migration: if a legacy
   `UserDefaults` key exists, move it into the Keychain and delete the default.
   Keep non-secret settings (provider, model, voice, base URL) in `UserDefaults`/`@AppStorage`.

**Done when.** No API key ever appears in `UserDefaults`, URLs, or log output; legacy keys
are migrated on first run; `KeychainStore` has unit tests (it lives in `Sources/Managers/`,
so it is inside the coverage gate); all existing tests updated and passing.

## 5. Surface API/network errors in the UI

**Context.** Every failure path in `TTSNetworkManager` only `print()`s (invalid URL `:60`,
JSON encode failure `:102`, non-2xx response `:169-175`, transport error `:177-178`). A
user with a bad API key clicks "Speak Copied Text" and nothing happens, with no feedback —
which also makes the USER_STORIES requirement "start streaming within 2 seconds"
unverifiable by the user.

**Change.** Add `@Published var lastError: String?` to `TTSNetworkManager`, set on the
main queue in each failure path (clear it at the start of `streamTTS`), and render it in
`MenuBarView` (e.g. a small red `Text` under the buttons, visible only when non-nil).
Prefer a short human-readable message (HTTP status + first line of the error body) over
raw JSON.

**Done when.** Pointing the app at a bad key/endpoint shows the error in the dropdown;
unit tests assert `lastError` is set for non-2xx responses and cleared on the next
successful request (extend `testNetworkManagerHandlesAPIError`).

## 6. Restore streaming for Gemini

**Context.** `README.md` names minimal time-to-first-byte as a primary design goal, and
the OpenAI path honors it via chunked PCM. The Gemini path does not: it calls
`:generateContent` and buffers the entire response, decoding audio only in
`didCompleteWithError` (`Sources/Managers/TTSNetworkManager.swift:157-167`). Long texts
wait for the full synthesis before the first sound.

**Change.** Switch the Gemini URL to `:streamGenerateContent?alt=sse` and parse the SSE
stream incrementally in `urlSession(_:dataTask:didReceive:)`: buffer bytes until a
complete `data: {...}\n\n` event, JSON-decode it, extract
`candidates[0].content.parts[0].inlineData.data`, base64-decode, and forward to
`dataHandler` per event. Verify against current Google GenAI docs (fetch them — payload
shapes change) that audio chunks are actually emitted incrementally for TTS models, and
mind base64 padding: only decode complete events, never partial buffers.

**Done when.** A `MockURLProtocol` test feeding two SSE events asserts `dataHandler` fires
once per event (not once at completion); manual test with a real Gemini key starts audio
before the response finishes.

## 7. Make the audio sample rate configurable

**Context.** `AudioPlayerManager.setupEngine` hardcodes 24 kHz / mono / 16-bit PCM
(`Sources/Managers/AudioPlayerManager.swift:40`). That matches OpenAI's `pcm` format and
Gemini's TTS output, but a *Custom* OpenAI-compatible endpoint returning 22.05/44.1 kHz
will play at the wrong speed and pitch with no error.
(Decision resolved with the user: make it configurable; do not just document it.)

**Change.**
- Add a "Sample Rate (Hz)" field to the **Custom** provider section of
  `Sources/Views/SettingsView.swift` (persisted via `@AppStorage("customSampleRate")`,
  default 24000; validate it parses to a sane positive value, e.g. 8000–48000, and fall
  back to 24000 otherwise). OpenAI and Gemini remain fixed at 24 kHz — no UI for them.
- Plumb the value into `AudioPlayerManager` (e.g. `func setSampleRate(_ hz: Double)`),
  called from `SettingsView.syncSettings()`. On change, the engine graph must be rebuilt:
  nodes are connected with a fixed `AVAudioFormat`, so stop the player, disconnect,
  reconnect with the new format, and reset buffered state (a format change mid-buffer is
  not meaningful — treat it like `stop()`).
- The frame math in `scheduleAudio`, `seek`, and the progress timer already derives from
  `format.sampleRate`, so it adapts automatically once `audioFormat` is rebuilt — verify,
  don't assume.

**Done when.** A custom endpoint at 22.05 or 44.1 kHz plays at correct speed/pitch; unit
tests cover `setSampleRate` (bufferDuration math at a non-default rate, and that a rate
change resets playback state); README "Design Assumptions" documents the default and the
Custom-provider override; `./check-coverage.sh` still passes.

## 8. Add the AGPL-3.0 license

(Decision resolved with the user: GNU Affero General Public License v3.0.)

Add a `LICENSE` file containing the verbatim AGPL-3.0 text from
<https://www.gnu.org/licenses/agpl-3.0.txt> (do not paraphrase or reformat). Add a short
"License" section to README stating the project is licensed under AGPL-3.0, copyright
Libo Yin. Optionally add the standard per-project AGPL notice block (program name,
copyright line, warranty disclaimer) to the README rather than to every source file.

## 9. Publish a GitHub Release with a notarised .dmg

**Context.** `package.sh` currently produces an ad-hoc-signed .app that requires users to
strip the quarantine attribute manually. A notarised .dmg removes that friction.
**Prerequisite:** an Apple Developer Program membership and a "Developer ID Application"
certificate in the login keychain — confirm with the user that these exist before starting.

**Change.**
- Extend `package.sh` (or add `release.sh`) to: build Release signed with the Developer ID
  identity and hardened runtime (`CODE_SIGN_IDENTITY="Developer ID Application: ..."`,
  `OTHER_CODE_SIGN_FLAGS=--options=runtime`), wrap the .app in a .dmg (`hdiutil create`),
  submit with `xcrun notarytool submit --wait` (needs an App Store Connect API key or
  app-specific password — ask the user), then `xcrun stapler staple` the .dmg.
- Create the GitHub release: `gh release create v1.0 <dmg> --title ... --notes ...`.
  Update the version in `Sources/Info.plist` / `project.yml` if it is no longer 1.0.
- Update README's distribution section (the `xattr` instructions become the fallback for
  source builds only).

**Done when.** `spctl --assess --type open --context context:primary-signature <dmg>`
passes, a fresh macOS user can download and open the app with no Terminal steps, and the
release is live on GitHub.

## 10. Add a demo GIF to the README

Record ~10 seconds of real usage: select text in an app → menu bar → "Speak Copied Text" →
progress bar advancing (audio is inaudible in a GIF, so make the moving progress slider and
icon state the visual proof). Save as `docs/demo.gif` (keep it under ~5 MB; `ffmpeg` +
`gifski` or a screen-recording → GIF tool), embed near the top of README. Best done after
task 9 so the recording shows the released build.

## 11. Give the settings keys a single source of truth

**Context.** The nine `UserDefaults` key strings exist in three hand-maintained copies:
`@AppStorage` literals in `Sources/Views/SettingsView.swift:7-15`, `string(forKey:)` calls
in `Sources/Managers/TTSNetworkManager.swift:22-35`, and `AppSettingsDefaults.keys` in
`Tests/UserDefaultsSnapshot.swift`. Adding a tenth `@AppStorage` and forgetting the test
list silently reintroduces task 2's bug (tests overwriting the developer's real settings),
and nothing detects the omission.

**Change.** Add a `SettingsKeys` enum in `Sources/Managers/` holding the key strings, and
reference it from all three sites (`@AppStorage(SettingsKeys.ttsProvider)` etc.). Expose an
`allKeys` collection so the test helper enumerates it instead of repeating the literals.

**Done when.** No settings key string is written more than once; `AppSettingsDefaults.keys`
is gone in favor of `SettingsKeys.allKeys`; `./check-coverage.sh` still passes.

## 12. Reset `MockURLProtocol.requestHandler` between tests

**Context.** `Tests/MockURLProtocol.swift:4` is a `static var` that no test ever clears, so a
handler outlives the test class that installed it. This is not theoretical: with task 2's
settings isolation in place, a `/v1/models` request dispatched by
`SettingsViewTests.testProviderDidChangeAndTestVoice` raced the `XCTFail` handler left behind
by `ServicesCoordinatorTests.swift:48-51`, failing the settings test with the services test's
message. That test now installs its handler before issuing any request, but the hazard
remains for every future test, and `startLoading`'s `fatalError` on a nil handler makes a
naive reset unsafe.

**Change.** Give `MockURLProtocol` a `reset()` that clears the handler, call it from a shared
`setUp`/`tearDown` (an `XCTestCase` extension, or a base class), and replace the `fatalError`
in `startLoading` with an `XCTFail`-style failure attributed to the running test plus a
returned error, so a stray request names the offender instead of killing the process.

**Done when.** No test depends on a handler set by another test; a request with no handler
installed fails that test with a clear message rather than crashing the suite.

## 13. Stop tests from making real network requests

**Context.** `Tests/SettingsViewTests.swift:9` builds `TTSNetworkManager(configuration: .ephemeral)`
without `MockURLProtocol`, then `testSettingsViewMethods` calls `syncSettings()` and
`fetchMetadata()`. Those issue real outbound requests to `api.openai.com/v1/models` carrying
the fake key `test-openai-key`. The suite is therefore slow, offline-hostile, and leaks a
request to a third party on every run. `MenuBarViewTests.swift:13` and
`MenuBarViewTests.swift:72` construct the manager the same way.

**Change.** Route every `TTSNetworkManager` built in tests through `MockURLProtocol` (the
config is already a one-liner) or, where the test genuinely does not care about the network,
point it at a base URL that cannot resolve. Do not leave a code path where a unit test talks
to a real endpoint.

**Done when.** The full suite passes with the machine offline (`sudo ifconfig en0 down`, or
Network Link Conditioner set to 100% loss), and no test names a real hostname.

## 14. Stop tests from clobbering the real clipboard

**Context.** Same bug class as task 2, one layer over: `Tests/MenuBarViewTests.swift:51-52`
and `Tests/TextExtractionManagerTests.swift:11-13,21-22` call
`NSPasteboard.general.clearContents()` and write their own strings, destroying whatever the
developer had copied and never restoring it.

**Change.** Either snapshot and restore the general pasteboard around each test (mirroring
`UserDefaultsSnapshot`), or — cleaner — inject the pasteboard into `TextExtractionManager`
(`init(pasteboard: NSPasteboard = .general)`) and hand tests a scratch
`NSPasteboard(name:)` so the general one is never touched. Prefer injection: it removes the
shared-state problem instead of papering over it, and matches the "side effects isolated"
rule in `CLAUDE.md`.

**Done when.** Copying a string, running `./check-coverage.sh`, and pasting yields the
original string; no test writes to `NSPasteboard.general`.
