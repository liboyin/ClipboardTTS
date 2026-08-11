# Clipboard TTS App

Native macOS menu bar app (Swift/SwiftUI, macOS 13+) that reads clipboard text aloud via OpenAI-compatible TTS APIs. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

```
Sources/
  ClipboardTTSApp.swift       # app entry point, menu bar setup
  Managers/
    AudioPlayerManager.swift
    TextExtractionManager.swift
    TTSNetworkManager.swift
    TTSNetworkManager+Metadata.swift # guarded model/voice metadata requests
    ServicesCoordinator.swift   # bridges the macOS Services flow into the audio pipeline
  Views/
    MenuBarView.swift
    SettingsView.swift
Tests/                        # XCTest, including focused metadata state/race suites, shared
                              # MockURLProtocol, and UserDefaultsSnapshot (settings isolation)
project.yml                   # XcodeGen source of truth (*.xcodeproj is gitignored)
```

## Architecture

- **UI**: SwiftUI `MenuBarExtra` for playback controls; a separate `Window` hosts settings to keep the dropdown focused on play/pause/progress/speed. The settings window includes an endpoint test action and an About control that opens macOS's standard panel with the app bundle's name and marketing version; its credits point to the bundled `LICENSE` (AGPL-3.0).
- **Audio**: `AVAudioEngine` + `AVAudioPlayerNode` (not `AVPlayer`) so playback speed can be adjusted via `AVAudioUnitTimePitch` without altering pitch. The serialized count of complete 16-bit PCM frames is the source of truth for both buffered duration and seek boundaries—never a sum of per-chunk floating-point durations. The first playable frame of each stream starts one 0.1-second automatic-playback prebuffer window; later packets continue scheduling during that window without moving its deadline. The delayed action is generation-bound, so stopping, replacing a stream, or rebuilding the format cannot restart old audio. Seek-related node operations and buffered-data reads share the audio-buffer queue. Seeking to the exact end stops playback while retaining audio for replay from zero.
- **Text**: `TextExtractionManager` reads through an injected, read-only pasteboard adapter; the production adapter uses `NSPasteboard.general`. The menu-bar flow deactivates the app and defers the read by 0.2 seconds before starting TTS.
- **Network**: `URLSession` streams OpenAI-compatible and Custom raw PCM chunks directly. Gemini uses the documented [Generate Content streaming endpoint](https://ai.google.dev/api/generate-content), `:streamGenerateContent?alt=sse`, with `x-goog-api-key` authentication; its request-owned parser accepts LF and CRLF Server-Sent Events, waits for a complete base64 `inlineData` event, and forwards playable 16-bit PCM frames before task completion. Each task captures its provider, endpoint, credentials, request inputs, decoder, and incremental parsing state at creation; later settings changes apply only to the next request. Model and voice metadata maintain independent cancellable request state and generation tokens; only metadata for the still-selected provider and endpoint may update the UI. Cancellation limits unnecessary work but is not a freshness guarantee: a completion must still match its active request token. Metadata source identity includes both the selected provider and endpoint, because multiple Custom endpoints use the same OpenAI-compatible transport. A delegate callback validates and records task state under a private serial queue, then enqueues its audio handoff on a second serial queue while the state lock is still held; PCM therefore reaches handlers in accepted callback order. Immediately before calling the handler, the delivery queue rechecks its request generation under the state queue: this revokes handoffs still waiting for that check, while normal completion leaves already accepted audio authorized. Handlers still run outside the state lock and may synchronously stop or replace a stream. A stop can currently race after the recheck and before callback invocation; Task 28 in `TODO.md` owns that remaining authority boundary. Because `@Published` notifies observers before storing a value, request-state publications track nested updates and defer observer-triggered replacement requests until the outermost update finishes. Invalid configuration, encoding, HTTP, transport, and empty or malformed provider-audio failures publish a short, application-owned message in the menu bar; provider response bodies are never rendered, and a new request or Clear Buffer clears the message. Minimizing Time-To-First-Byte is a primary design goal.
- **Settings**: API keys are generic-password Keychain items under the stable `com.clipboardtts.api-keys` service, one account per provider. `SettingsKeys` owns only persisted preferences plus the three temporary plaintext names used to migrate existing installs. Migration removes a legacy value only after Keychain accepts the write; a failure preserves it and presents Keychain-access guidance. If both stores contain a key, the existing Keychain value wins, preventing stale plaintext from overwriting a newer saved credential.
- **Services**: The macOS right-click "Speak Selected Text with Clipboard TTS" service posts a notification handled by `ServicesCoordinator`, which lives for the whole app lifetime (created in `ClipboardTTSApp.init`). The observer explicitly hands the whole playback-start action to the main actor because notifications can be posted from any thread. This is deliberately *not* in `MenuBarView`: `MenuBarExtra(.window)` builds its body only when the dropdown is first opened, so a view-hosted observer would drop the service until then.

## Design Assumptions

- **OpenAI-compatible endpoints**: Local TTS engines must expose `/v1/audio/speech`. Cloud APIs that differ (e.g. Google Gemini) get dedicated payload formatters.
- **Custom provider contract**: Custom endpoints use the OpenAI-compatible speech payload. Users must configure a non-whitespace model and voice; every Custom request includes both values with `input` and PCM `response_format`. As with OpenAI, a successful response must contain at least one complete 16-bit PCM frame; otherwise the app reports a no-playable-audio failure.
- **PCM sample rate**: OpenAI and Gemini audio always uses the fixed 24,000 Hz mono Int16 format. Custom endpoints default to 24,000 Hz and may select any finite rate from 8,000 through 48,000 Hz in Settings; applying a changed rate discards the prior buffer before rebuilding the audio graph. The visible Custom draft is the authoritative requested rate for validation and retry, while persistence changes only after a successful graph update. Invalid draft edits do not replace the saved last-known-good rate, and a corrupt legacy value blocks new speech until it is corrected rather than silently decoding at 24 kHz.
- **Provider authentication**: OpenAI and Custom requests carry their saved key in `Authorization: Bearer`; native Gemini requests use the raw saved key in `x-goog-api-key`. Keys are never appended to URLs or included in app-owned errors.
- **Gemini audio**: The supported Gemini 3.1 TTS preview model streams base64-encoded `inlineData` through Server-Sent Events. The app treats malformed/provider-error events and streams that finish without playable audio as a sanitized no-playable-audio failure; valid non-audio metadata events are ignored, and valid Gemini output is 24-kHz mono, 16-bit PCM.
- **Provider normalization**: An unknown persisted provider value is normalized to OpenAI and its fixed endpoint before any request is built. This fails safely instead of pairing a key with an arbitrary Custom endpoint.
- **Voice metadata**: OpenAI does not expose a built-in voice-discovery endpoint for speech. Its menu metadata therefore uses the provider-authoritative list in the official [Text-to-Speech guide](https://developers.openai.com/api/docs/guides/text-to-speech#voice-options): `tts-1` and `tts-1-hd` offer alloy, ash, coral, echo, fable, onyx, nova, sage, and shimmer; other configured OpenAI TTS models offer those nine plus ballad, verse, marin, and cedar. The menu initiates this existing freshness-guarded lookup when it first appears, so it does not depend on Settings having opened. Gemini uses its provider-specific metadata list. A Custom endpoint has no discovery contract; its menu shows only the non-empty Custom voice configured in Settings. The menu accepts a choice only while its provider is synchronized with the manager and no stream or buffered audio exists.
- **External toolchain**: `xcodegen` and `swiftlint` are user-managed; the app does not install or modify them.

## Build & Test

Regenerate Xcode project after editing `project.yml` or adding/removing source or test files, so Xcode discovers the current file set:
```
xcodegen generate
```

Build:
```
xcodebuild -project ClipboardTTSApp.xcodeproj -scheme ClipboardTTSApp -configuration Debug build
```

The app target remains in Swift 5 language mode, but `project.yml` enables complete
strict-concurrency checking for it. Keep queue-owned request/audio buffers behind their explicit
serial queues, and hand UI, AppKit, and Services work to the main actor; `@unchecked Sendable`
is reserved for the URL-session delegate bridge and documented confinement invariants.

For streaming requests, accept, parse, and account for provider data while holding request-state
ownership; defer only the user audio handler to the ordered delivery queue. Completion must never
be able to clear request state ahead of an accepted final Gemini event. Handlers must not run under
the request-state queue, because they are allowed to synchronously stop or replace their stream.

Run tests and check the line coverage of `Sources/Managers/`:
```
./check-coverage.sh
```

Because XCTest launches the hosted macOS app before XCTest `setUp()`, `ClipboardTTSApp.init` detects that host and builds a separate dependency graph: a fresh process-private defaults suite and an `InMemorySecretStore`. Its startup manager reads and migrates only that owned state, so it cannot read, migrate, delete, or block on the installed app's settings or Keychain. Production startup continues to use `UserDefaults.standard` and `KeychainSecretStore`; `AppStartupDependencies.make` is the supported injection seam for regression coverage.

Every initializer reached from that startup graph must receive the selected defaults explicitly; a default parameter on a downstream migration or manager is not sufficient isolation. Startup regressions must exercise the automatic hosted branch as well as injected branches: after `isolateAppSettingsDefaults()`, seed conspicuous standard-domain values, then prove the automatic graph uses distinct defaults and an `InMemorySecretStore` while leaving those values unchanged. Do not test a Keychain regression by running a Keychain-backed hosted startup—the expected failure can block on macOS; the baseline must prove it selects the in-memory store instead.

The unit-test bundle is hosted inside the app, so `UserDefaults.standard` in a test is the real app's defaults domain. After `MockURLProtocolTestCase.setUp()` begins, it isolates every mock-network test, clears every declared settings key, and restores the developer's exact configuration only after its sessions, protocol loads, manager initialization, and factory-owned audio-delivery queues are quiescent. Scope shutdown first revokes each factory manager's pending delivery generation, then drains every registered serial delivery queue before restoring settings or releasing the next mock test. Timeout recovery runs off-main, so revocation must not synchronously wait for the main queue: settings-isolation verification can be waiting on that recovery. XCTest runs teardown blocks before `tearDown()`, so this lifecycle owns its snapshot directly; do not move restoration to `addTeardownBlock`. Non-network tests that touch settings must call `isolateAppSettingsDefaults()` themselves (`Tests/UserDefaultsSnapshot.swift`).

Network tests must create managers and sessions through `TestNetworkFactory`, which routes all requests through `MockURLProtocol` with an immutable per-test identifier. The factory atomically claims manager construction before initialization can read settings, so teardown cannot restore values during legacy-key migration. `MockURLProtocolTestCase` serializes those tests, invalidates their sessions and drains active protocol loads before releasing the next test, clears the installed response handler in setup and teardown, and fails a test that has an undeclared request without a handler; an explicitly declared unhandled request fails locally with a URL-loading error. Clipboard tests inject `FakePasteboardReader` and never modify the user's shared pasteboard.

Network-state tests wait for the relevant published terminal state (`lastError` and `isStreaming`) or an explicit mock-protocol event; install that observation before releasing any action that can complete the request, so a successful terminal publication cannot race ahead of the test. Successful terminal-state assertions must also observe an active request. Failure assertions still need a post-action publication boundary to reject a matching pre-existing error; Task 29 in `TODO.md` owns that remaining helper gap. Do not use elapsed-time polling to infer that an asynchronous request completed.

Concurrency tests use a controllable serial delivery queue and semaphores to force completion,
handler, and callback ordering deterministically. Use distinct PCM chunks when asserting order;
byte totals alone cannot reveal reordering. A Services test that posts from a background queue must
exercise the production main-action executor and observe the action on main, rather than supplying
an executor that itself performs the hop.

For focused XCTest runs, use the `ClipboardTTSAppTests` scheme (the generated project has no separate app-test scheme). A test that verifies a SwiftUI `.onAppear` action or an `NSViewRepresentable` control must host the view in `NSHostingView` and lay it out; constructing the view value alone does not run its lifecycle action. Do not wrap that test host in an `NSWindow`: AppKit window teardown can outlive the test and crash the hosted process. Release the hosting view and drain one main-queue turn before `MockURLProtocolTestCase` invalidates its session, so deferred Settings observers cannot create work after their test scope closes.

Audio-manager tests that exercise the 0.1-second automatic-playback prebuffer inject a controllable scheduler and wait for the manager's explicit audio-queue processing or state-publication hook. They must assert the queued callback before running it; do not use a sleep or a real deadline as a synchronization boundary. This keeps packet ordering, cancellation, and delayed-start tests deterministic.

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`.
