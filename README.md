# Clipboard TTS App

<img src="Sources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="256" height="256" alt="Clipboard TTS app icon">

Native macOS menu bar app (Swift/SwiftUI, macOS 14+) that reads clipboard text aloud through OpenAI's Realtime API, an OpenAI-compatible TTS endpoint, or Google Gemini's own streaming speech endpoint. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

[DESIGN.md](DESIGN.md) describes the architecture, design assumptions, and test-harness rules; [USER_STORIES.md](USER_STORIES.md) describes product behavior.

## Requirements

- A Mac with Apple silicon running macOS 14 or later, and Xcode. The app is distributed for Apple silicon only and does not run on Intel Macs.
- `xcodegen` and `swiftlint` are user-managed; the app does not install or modify them. Every app build runs `swiftlint --strict` over `Sources` and `Tests` and fails if SwiftLint is not on `PATH` or in Homebrew's `/opt/homebrew/bin` or `/usr/local/bin`.

## Build

Regenerate Xcode project after editing `project.yml` or adding/removing source or test files, so Xcode discovers the current file set:
```
xcodegen generate
```

Build:
```
xcodebuild -project ClipboardTTSApp.xcodeproj -scheme ClipboardTTSApp -configuration Debug build
```

Both targets remain in Swift 5 language mode, but `project.yml` enables complete strict-concurrency checking for each of them, and the setting sits on each target rather than on a command, so anything that builds a target checks it: `./check-coverage.sh` builds the test bundle and, through the test target's declared dependency, the app target as well, while the explicit app build above remains a required gate in its own right. An incremental build reports only the file batches it recompiled, so clear the derived data before concluding that a target is warning-free.

The `ClipboardTTSApp` target builds `ClipboardTTS.app`; its target, scheme, Swift module, and bundle identifier keep the `ClipboardTTSApp` name, so saved preferences and Keychain items carry over. It and its unit-test bundle both target macOS 14, so every gate runs on the app's own minimum; macOS 14 is also the minimum of the XCTest libraries in Xcode 27.2, the version this was last checked on. The generated project has one `ClipboardTTSApp` scheme, whose test action runs that bundle, so the coverage script selects it and the current host architecture explicitly to avoid a multiple-destination warning. Xcode 27.2 invokes AppIntents metadata extraction for both targets even though neither links AppIntents; its “Metadata extraction skipped, no AppIntents.framework dependency found” warning is benign tool metadata, not a source warning. Do not suppress compiler or lint diagnostics to hide it.

## Test

Run the tests and check the app target's line coverage:
```
./check-coverage.sh
```

The gate requires at least 85% line coverage both for `Sources/Managers/` and for every gated source together. It exits 1 when measured coverage falls short and 2 when the report cannot support a verdict; [DESIGN](DESIGN.md#coverage-gate) describes the measured population, the excluded symbols, and why.

Passing a path ending in `.json` checks an already-extracted xccov report instead of a result bundle, which is the seam `./verify-coverage-gate.py` uses to drive this policy end to end over forty-two synthetic reports with no build, no bundle, and no network. Run that verification whenever the policy changes.

For focused XCTest runs, use the generated `ClipboardTTSApp` scheme with `-destination "platform=macOS,arch=$(uname -m)"`; its test action runs `ClipboardTTSAppTests`.

### Manual Smoke Checks

Each symbol the coverage gate excludes carries an end-to-end check to run by hand when its exclusion changes:

- **Menu alert** (`AppKitMenuAlertPresenter`): With OpenAI selected, copy more than 4,096 characters and speak them from the menu, which is the only path that presents that alert, and confirm it reads as `MenuBarView` built it, naming the limit and how far past it the text is.
- **About panel** (`StandardAboutPanelPresenter`): Open Settings and click **About Clipboard TTS** in the sidebar footer, and confirm the panel shows the application's name and version.
- **Keychain** (`KeychainSecretStore`): Save an API key in Settings, quit, relaunch and confirm the key is still there, then clear that field, quit, relaunch and confirm it is gone — clearing a key is what reaches `deleteSecret`, which is excluded alongside the read and the write.

Those checks have not been run by the agent that introduced the exclusions; they are recorded as outstanding in TODO.

## Mutation Testing

Mutation evidence for code under XCTest runs through `./run-mutants.py SPEC.json --out DIR`. The spec supplies exact text replacements in order; optional `tests` selects suites or cases, and optional `untracked` names in-scope untracked files. For example:

```json
{
  "tests": ["ClipboardTTSAppTests/SomeSuite"],
  "untracked": ["Tests/NewFile.swift"],
  "mutants": [
    {"name": "revert-guard", "edits": [
      {"path": "Sources/X.swift", "old": "exact text", "new": "replacement"}
    ]}
  ]
}
```

Replace the example paths and text with the candidate's actual inputs. Omit `tests` to run the whole test bundle and `untracked` when no untracked files belong to the candidate. `--only NAME ...` restricts execution to named mutants. Names become log filenames: letters, digits, `.`, `_`, and `-`, starting with a letter or digit, unique regardless of case, and not `control`, which names the unmutated run's log. Paths must be relative, stay inside the scratch copy, and identify files in the target state. Named untracked files must be regular, unignored files, not symlinks. Every edit's nonempty old text must match exactly once where that edit applies. Malformed specs, unknown keys, and text containing NUL or invalid Unicode are refused before building, as are a spec that cannot be read and a `DIR` that cannot be created.

`DIR` must be outside the repository, must not contain it, and must be new, empty, or marked as owned by the runner. A run holds an exclusive lock on that marker from before it deletes anything in `DIR` until it has written `results.json` or refused, and releases it however it ends, so a second run on the same `DIR` is refused before anything in it is deleted. The runner removes the previous `results.json` first, refuses symlinked output children, and clears old logs before reading the spec. It builds one scratch copy from every path in the index as the working tree holds it, whatever `HEAD`, an export attribute, or an assume-unchanged flag says, and from named untracked files; a path beneath a working-tree symlink is left out, and an indexed path the working tree holds as a directory, such as a submodule, is refused. The unmutated control must pass, and every selector must run at least one test that is not skipped. Generation must preserve all edit targets before tests launch; this also catches tracked generated files such as `Sources/Info.plist`, whose generator input should be mutated instead. Edits preserve UTF-8 text and exact line endings. After each mutant, the runner restores original bytes, regenerates the project, and verifies the restored edit targets; a regeneration that fails there, for any reason, stops the run with exit 2 and no verdict for that mutant, as does a write of its edits that fails, such as to a read-only file or a full disk, once the files it had written, even partly, are restored. Once the control begins, SIGINT and SIGTERM stop the running test tool and let restoration finish before the runner exits. That includes a terminal's Ctrl-C, which signals the whole foreground process group: the runner starts XcodeGen and `uname` in sessions of their own, so the signal cannot cut them short, and leaves the test tool in its process group, so a terminal's signals, a hangup included, still end it directly. Either signal before the control begins ends the runner by that signal, before any mutant is applied. Any other signal, such as SIGHUP, ends the runner at once and can leave the copy mutated until the next run rebuilds it. Each test run, build included, has a deadline of 30 minutes unless `--test-deadline SECONDS` sets another: a full-bundle run took about 50 s from fresh derived data on Xcode 27.0, but a mutant can make the tests' explicit waits expire, about 577 s if every one did, and still end in a named kill. A run still going at its deadline is presumed hung and stopped as a signal stops it, and killed if `xcodebuild` has not exited a minute later; `xcodebuild` ends the test host, which launchd starts outside the runner's process tree. That run is `NO-VERDICT` whatever its log holds, with a detail naming the deadline, so its mutant is unjudged, a stopped control refuses the run, and otherwise the next mutant runs. Its log shows the test that was running; to tell a slow run from a hang, rerun that mutant with `--only` and a longer deadline. XcodeGen and `uname`, which a terminal's signals do not reach, get 60 s each: one still going then is killed with every process still in its session, whatever its process group, and the run stops with exit 2, as it does when one fails. Finding those processes takes `ps` and shares the same 60 s; if it cannot finish, the tool itself is still killed and reaped, and the error adds that not every process in its session could be confirmed stopped, so check for leftovers. `xcodebuild`'s own test timeouts stay off, because they bound a test but not a build, a launch, or `xcodebuild` itself; a scheme or test plan that enables them makes a test past its allowance read as `KILLED` by that test, which Xcode's `Failing tests:` summary names.

Verdicts come from the log's last standalone terminal marker. `KILLED` names every test a failed run reports failing, in an `error: -[…]` line or in the `Failing tests:` summary Xcode prints directly above the final marker, which alone names a test that crashed, exited, or exceeded an enabled execution allowance, taking each test's module from its own start line; `SURVIVED` requires success with at least one test executed and not skipped; `NO-TESTS` means success without executing any test, or without executing one for every selector; `BUILD-FAILED` identifies a build or strict SwiftLint failure; `FAILED-UNNAMED` means a finished failure that names no test, such as a crash in a suite's class-level `setUp` or `tearDown`, and leaves its mutant unjudged; and `NO-VERDICT` means no terminal marker, or a run its deadline stopped. Failures are extracted only from a failed run, and only the summary that ends it counts, since test output can print the same text. Logs are read as UTF-8 whatever the locale, and a byte that cannot be decoded in one, or in a failed tool's error output, is read as U+FFFD rather than ending the run; a verdict line escapes what the locale's encoding cannot carry, as Python does on stderr, rather than failing, and `results.json` keeps the exact name. Exit 0 means all mutants received a verdict, not that all were killed; exit 1 means a mutant was unjudged, `NO-VERDICT` or `FAILED-UNNAMED`, or ran no tests, or that the runner raised an exception it does not expect, a bug it surfaces with Python's traceback rather than refusing, after which `results.json` exists only if the control had begun and then records an incomplete run with that error; exit 2 means the runner refused or interrupted the run, and a failed tool's own error output follows the refusal. Once the control begins, `results.json` is written however the runner ends, except by a signal it does not handle, such as SIGHUP, which can leave none: it records whether the run completed, its exit code and any error, `HEAD`, SHA-256 digests of the spec's bytes and of the copied target state before generation, the selectors, the selected mutants, the deadlines, the control's verdict, and each finished mutant's result, an unjudged one included, so the file alone identifies its evidence. Inspect it and the per-mutant logs in `DIR`; the scratch copy remains for inspection. `./verify-mutation-runner.py` verifies the runner without Xcode; run it whenever the runner changes. Each of its cases has a stable name, which `--list` prints and a failure is reported under. With no argument it runs every case; naming cases, as in `./verify-mutation-runner.py classify/a_passing_run_survives verdicts_and_restore`, runs only those; an unknown name refuses the run with exit 2, as does running cases under Python's optimization (`-O` or `PYTHONOPTIMIZE`), which removes the assertions they check with; a run with a failing case exits 1. Every stand-in process a case starts, directly or through the runner, notes its pid in that case's own ledger, and however the case ends, cleanup kills those still running and confirms them gone before removing the case's directory; one not confirmed gone within 5 seconds fails the case as well, or, if the run was interrupted, is named on stderr before the interrupt ends it. If an unexpected error prevents closing, reading, or stopping from the ledger, cleanup retains the ledger, reports its location and the original error, and explicitly marks its processes as unconfirmed; inspect that ledger and stop any remaining owned processes before removing it. A stand-in that starts only after its case's cleanup has begun, or that cannot note its pid, exits at its first instruction instead of running, and a Ctrl-C during that cleanup waits for it to finish. Tooling scripts are mutated against their own verifiers rather than this XCTest runner. The runner adds no isolation of its own, so a mutant that weakens the tests' own [isolation](DESIGN.md#test-harness) — the hosted startup graph, the secret store, the preference domain, or network routing — must not be run through it as it stands; record that category as not applicable for that reason unless the user approves an isolation for it. For network routing, TODO's D24 approves one: every request the selected tests issue targets a loopback literal, and the spec and its selectors are inspected first.

## Local Kokoro Server

`kokoro/compose.yaml` runs [Kokoro-FastAPI](https://github.com/remsky/Kokoro-FastAPI) v0.9.0, an OpenAI-compatible server for the Kokoro-82M v1.0 model, as a Custom provider on this Mac. The image is pinned by digest and already contains the model weights and voices, so after the first pull (about 3 GB) it needs no network. Docker on macOS cannot use the Apple GPU, so the model runs on the CPU. The port is published on `127.0.0.1` only, because the server has no authentication. Its log level is `INFO`, so `docker logs` shows each text chunk's token count and first 50 characters, which is copied text, kept until the 1 MB log cap rotates it out; `API_LOG_LEVEL: WARNING` keeps copied text out of the logs.

```
docker compose -f kokoro/compose.yaml up -d   # start; it restarts with Docker until brought down
docker compose -f kokoro/compose.yaml down    # stop and remove the container
```

Then select Custom in Settings:

| Field | Value |
|---|---|
| Base URL | `http://127.0.0.1:8880/v1/audio/speech` (the full speech URL, which the app posts to as written) |
| Model | `kokoro` |
| Voice | a voice ID such as `af_heart`; the first letter selects the language (`a` American English, `b` British English). `curl http://127.0.0.1:8880/v1/audio/voices` lists all of them. |
| API Key | anything, including empty; the server ignores it |
| PCM Sample Rate (Hz) | 24000 |

The server streams by default and labels its PCM `audio/pcm`, which the declared-format rule accepts. It streams one text chunk at a time, and the compose file lowers `TARGET_MAX_TOKENS` from 250 to 100 (with `TARGET_MIN_TOKENS` at 75), so a chunk is about one or two sentences and the first audio of a long passage arrives in about 3 s rather than 6 s on CPU. An unknown voice is answered with HTTP 400, which the app reports as an HTTP failure.

### Native on macOS

`kokoro/start-native.sh` runs the same Kokoro-FastAPI v0.9.0 directly on macOS, where PyTorch can use the Apple GPU (MPS). It needs a one-time checkout beside this repository, built with [uv](https://docs.astral.sh/uv/) from upstream's own lock file, which installs into the checkout's `.venv` with a uv-managed Python 3.12 — the version the Docker image uses — and leaves any other Python environment alone. The download script verifies the weights against upstream's pinned SHA-256 values.

```
git clone --branch v0.9.0 --depth 1 https://github.com/remsky/Kokoro-FastAPI.git ~/Code/Kokoro-FastAPI
cd ~/Code/Kokoro-FastAPI
uv sync --frozen --extra cpu --python 3.12   # macOS PyTorch builds include MPS despite the extra's name
.venv/bin/python docker/scripts/download_model.py --output api/src/models/v1_0
```

```
kokoro/start-native.sh         # Apple GPU; Ctrl-C stops it
kokoro/start-native.sh --cpu   # CPU only
```

It listens on `127.0.0.1:8881`, so it can run beside the Docker service; use `http://127.0.0.1:8881/v1/audio/speech` as the Base URL, with the Settings values above otherwise unchanged. `KOKORO_FASTAPI_DIR` and `KOKORO_PORT` override the checkout location and port; the loopback host is fixed. It applies the compose file's chunk sizing and `INFO` log level, so the terminal shows copied text the same way `docker logs` does, and skips the Hugging Face update check. The first start after setup took about 54 s; later starts take about 8 s on the GPU and 7 s on the CPU. The startup banner says "warmed up on cuda" whatever the device; the `Loading Kokoro model on mps` log line is the reliable one.

Measured on 2026-10-29 on an Apple M2 with 16 GB, macOS 26.7.1, upstream commit `404d122`, with ClipboardTTS-shaped requests to each server in turn after one warm-up request, using text that server process had not spoken before (repeating a text makes the GPU look faster than it is, 0.31 s rather than about 1 s for a short sentence):

| Server | First audio, one sentence (6 runs) | First audio, 860–950 characters (3 runs) | Whole passage, about 50 s of audio |
|---|---|---|---|
| Docker, CPU | 1.07–1.10 s (3 runs of one repeated sentence) | 2.1–3.9 s | 17.6–18.3 s |
| Native, CPU | 0.54–0.87 s | 0.96–1.9 s | 8.5–10.2 s |
| Native, Apple GPU | 0.86–1.3 s | 0.72–1.2 s | 4.6–5.3 s |

Running natively removes most of Docker's latency. The GPU halves generation time and gave the steadiest first audio on long passages, but a sentence the GPU process has not seen before costs it a little more than the CPU; both stay well ahead of playback. These are a few runs on one machine, not a benchmark.

## Packaging

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`. The right-click service stays out of the Services menu until it is enabled once in System Settings → Keyboard → Keyboard Shortcuts… → Services → Text → "Speak Selected Text with Clipboard TTS"; an app already open when it is enabled may need relaunching before its context menu lists it. `package.sh` names no destination, so `xcodebuild` builds for the first one it matches, which on an Apple silicon Mac is `arm64` alone; package on Apple silicon, because the app is distributed for it only.
