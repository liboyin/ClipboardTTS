# Clipboard TTS App

<img src="Sources/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="256" height="256" alt="Clipboard TTS app icon">

Native macOS menu bar app (Swift/SwiftUI, macOS 14+) that reads clipboard text aloud through OpenAI's Realtime API, an OpenAI-compatible TTS endpoint, or Google Gemini's own streaming speech endpoint. No external Swift dependencies; uses only Apple frameworks (AVAudioEngine, URLSession, NSPasteboard).

[DESIGN.md](DESIGN.md) describes the architecture, design assumptions, and test-harness rules; [USER_STORIES.md](USER_STORIES.md) describes product behavior.

## Requirements

- A Mac with Apple silicon running macOS 14 or later, and Xcode. The app is distributed for Apple silicon only and does not run on Intel Macs.
- `xcodegen` and `swiftlint` are user-managed; the app does not install or modify them. Every app build runs `swiftlint --strict` over `Sources` and `Tests` and fails if SwiftLint is not on `PATH` or in Homebrew's `/opt/homebrew/bin` or `/usr/local/bin`.

## First use

To build your own copy, install the tools in [Requirements](#requirements), then run these commands from this repository:

```sh
xcodegen generate
./package.sh
```

1. Move `build/Build/Products/Release/ClipboardTTS.app` to `/Applications`. If you received a packaged copy, move that app instead and follow the first-run instructions supplied by [package.sh](package.sh).
2. Launch ClipboardTTS from `/Applications` and open its menu-bar icon; it has no Dock icon.
3. Click the gear button to open **Settings** and select a provider in the sidebar. For OpenAI or Gemini, enter your API key and choose a model and voice. For Custom, configure your server's full speech URL, model, voice, key if required, and PCM sample rate; [Local Kokoro Server](#local-kokoro-server) gives a local setup.
4. Click **Test Voice** to check the configuration. Then copy text, open the menu-bar icon, and click **Speak Copied Text**. If the button says **Clear Buffer**, click it first to discard the previous speech, then click **Speak Copied Text**.

See [USER_STORIES](USER_STORIES.md) for playback behavior and provider-specific limits, and [Packaging](#packaging) to enable the selected-text service.

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

The `ClipboardTTSApp` target builds `ClipboardTTS.app`; its target, scheme, Swift module, and bundle identifier keep the `ClipboardTTSApp` name, so saved preferences and Keychain items carry over.

The app and its unit-test bundle both have a macOS 14 deployment target. Tests run on the host macOS version; a gate run on macOS 27.2.1 does not demonstrate runtime compatibility with macOS 14. [N12](completed_work/N12.md) records the `vtool` inspection of Xcode 27.2's XCTest libraries at revision `69e5e29` on Darwin 25.6.0: their minimum is macOS 14.

The generated project has one `ClipboardTTSApp` scheme, whose test action runs that bundle, so the coverage script selects it and the current host architecture explicitly to avoid a multiple-destination warning. Xcode 27.2 invokes AppIntents metadata extraction for both targets even though neither links AppIntents; its “Metadata extraction skipped, no AppIntents.framework dependency found” warning is benign tool metadata, not a source warning. Do not suppress compiler or lint diagnostics to hide it.

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

### Isolation

The runner adds no isolation of its own, so a mutant that weakens the tests' own [isolation](DESIGN.md#test-harness) — the hosted startup graph, the secret store, the preference domain, or network routing — must not be run through it as it stands; record that category as not applicable for that reason unless the user approves an isolation for it. For network routing, TODO's D24 approves one: every request the selected tests issue targets a loopback literal, and the spec and its selectors are inspected first.

### Run mutations

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

Replace the example paths and text with the candidate's actual inputs. Omit `tests` to run the whole test bundle and `untracked` when no untracked files belong to the candidate. `--only NAME ...` restricts execution to named mutants, and `--test-deadline SECONDS` replaces the default 30-minute deadline on each test run. [run-mutants.py](run-mutants.py)'s module docstring states the runner's contract, and its function docstrings and comments give the reasons for each rule below.

### Inputs

Names become log filenames: letters, digits, `.`, `_`, and `-`, starting with a letter or digit, unique regardless of case, and not `control`, which names the unmutated run's log. Paths must be relative, stay inside the scratch copy, and identify files in the target state. Named untracked files must be regular, unignored files, not symlinks. Every edit's nonempty old text must match exactly once where that edit applies. Malformed specs, unknown keys, and text containing NUL or invalid Unicode are refused before building, as are a spec that cannot be read and a `DIR` that cannot be created.

`DIR` must be outside the repository, must not contain it, and must be new, empty, or marked as owned by the runner. A second run on the same `DIR` is refused before anything in it is deleted, and so are symlinked output children; the previous `results.json` and logs are removed before the spec is read ([claim_output](run-mutants.py)).

### What a run tests

The scratch copy uses indexed paths as the working tree holds them, whatever `HEAD`, an export attribute, or an assume-unchanged flag says, plus the named untracked files. Paths beneath a working-tree symlink are omitted rather than followed; an indexed path the working tree holds as a directory, such as a submodule, is refused ([build_copy](run-mutants.py)).

The unmutated control must pass, and every selector must run at least one test that is not skipped. Generation must preserve all edit targets before tests launch; this also catches tracked generated files such as `Sources/Info.plist`, whose generator input should be mutated instead ([run_tests](run-mutants.py)).

After each mutant the runner restores original bytes, regenerates the project, and verifies the restored edit targets. If regeneration fails, the run stops with exit 2 and no verdict for that mutant. If writing a mutant's edits fails (a read-only file or a full disk, for example), the runner restores whatever it wrote before stopping with the same exit code and no verdict for that mutant.

### Interrupts and deadlines

Once the control begins, SIGINT and SIGTERM, including a terminal's Ctrl-C, stop the running test tool and let restoration finish before the runner exits; before then, either ends the runner before any mutant is applied. Any other signal, such as SIGHUP, ends the runner at once and can leave the copy mutated until the next run rebuilds it ([run_shielded](run-mutants.py) and [Interrupts](run-mutants.py) explain the process-group handling).

A test run, build included, still going at its deadline is presumed hung and stopped ([run_tests](run-mutants.py); [TEST_DEADLINE](run-mutants.py) records how the 30-minute default was sized). That run is `NO-VERDICT` whatever its log holds, with a detail naming the deadline, so its mutant is unjudged, a stopped control refuses the run, and otherwise the next mutant runs. Its log shows the test that was running; to tell a slow run from a hang, rerun that mutant with `--only` and a longer deadline. XcodeGen and `uname` get 60 s each: one still going then is killed with every process in its session, and the run stops with exit 2, as it does when one fails. If the error adds that not every process in its session could be confirmed stopped, check for leftovers.

`xcodebuild`'s own test timeouts stay off, because they bound a test but not a build, a launch, or `xcodebuild` itself; a scheme or test plan that enables them makes a test past its allowance read as `KILLED` by that test, which Xcode's `Failing tests:` summary names.

### Verdicts, exit codes, and results

Verdicts come from the log's last standalone terminal marker ([classify](run-mutants.py)):

- `KILLED` names every test a failed run reports failing, in an `error: -[…]` line or in the `Failing tests:` summary Xcode prints directly above the final marker, which alone names a test that crashed, exited, or exceeded an enabled execution allowance (D23).
- `SURVIVED` requires success with at least one test executed and not skipped.
- `NO-TESTS` means success without executing any test, or without executing one for every selector.
- `BUILD-FAILED` identifies a build or strict SwiftLint failure.
- `FAILED-UNNAMED` means a finished failure that names no test, such as a crash in a suite's class-level `setUp` or `tearDown`, and leaves its mutant unjudged.
- `NO-VERDICT` means no terminal marker, or a run its deadline stopped.

Test logs are read as UTF-8 with undecodable bytes replaced by U+FFFD ([read_log](run-mutants.py)). Failed-tool stderr receives the same replacement only when [describe](run-mutants.py) receives bytes. The `uname` and two `git rev-parse` calls use `text=True`, so subprocess decoding happens first, strictly in the locale's encoding; replacement is not guaranteed for those calls (the remaining investigation is [NB64](TODO.md#nb64--three-runner-tool-calls-may-not-read-their-output-as-readme-describes)).

The [runner entry point](run-mutants.py) (`__main__`) configures stdout to escape characters the locale's encoding cannot carry, so printing a verdict line does not fail for that reason. `results.json` keeps the exact test name.

| Exit | Meaning |
|---|---|
| 0 | All mutants received a verdict; this does not mean all were killed. |
| 1 | A mutant was unjudged (`NO-VERDICT` or `FAILED-UNNAMED`), ran no tests, or the runner raised an unexpected exception. |
| 2 | The runner refused the run or handled an interruption. A failed tool's own error output follows the refusal. |

An unexpected exception is surfaced with Python's traceback. In that case, `results.json` exists only if the control had begun and records an incomplete run with the error.

Once the control begins, `results.json` is written however the runner ends, except by a signal it does not handle, such as SIGHUP, which can leave none. It records what the [run-mutants.py module docstring](run-mutants.py) lists, plus any error, the selectors, and the selected mutants; its digests are SHA-256, of the spec's bytes and of the copied target state before generation, so the file alone identifies its evidence. Inspect it and the per-mutant logs in `DIR`; the scratch copy remains for inspection.

### Verifying the runner

`./verify-mutation-runner.py` verifies the runner without Xcode; run it whenever the runner changes. The [verify-mutation-runner.py module docstring](verify-mutation-runner.py) describes the cases. `--list` prints each case's stable name; with no argument it runs every case, and naming cases, as in `./verify-mutation-runner.py classify/a_passing_run_survives verdicts_and_restore`, runs only those. An unknown name refuses the run with exit 2, as does running cases under Python's optimization (`-O` or `PYTHONOPTIMIZE`); a run with a failing case exits 1. Cleanup stops every stand-in process a case started and fails the case for one not confirmed gone within 5 seconds, or names it on stderr if the run was interrupted ([owned_processes](verify-mutation-runner.py)). If cleanup cannot finish, it retains the case's pid ledger, reports its location and the original error, and marks its processes as unconfirmed: inspect that ledger and stop any remaining owned processes before removing it. A Ctrl-C during cleanup waits for it to finish. Tooling scripts are mutated against their own verifiers rather than this XCTest runner.

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

Return to your ClipboardTTS checkout before starting the server (adjust the path if you cloned it elsewhere):

```sh
cd ~/Code/ClipboardTTS
kokoro/start-native.sh         # Apple GPU; Ctrl-C stops it
kokoro/start-native.sh --cpu   # CPU only
```

It listens on `127.0.0.1:8881`, so it can run beside the Docker service. Its speech URL, `http://127.0.0.1:8881/v1/audio/speech`, is Custom's default Base URL until another is typed; the Settings values above otherwise apply unchanged. `KOKORO_FASTAPI_DIR` and `KOKORO_PORT` override the checkout location and port; the loopback host is fixed. It applies the compose file's chunk sizing and `INFO` log level, so the terminal shows copied text the same way `docker logs` does, and skips the Hugging Face update check. The first start after setup took about 54 s; later starts take about 8 s on the GPU and 7 s on the CPU. The startup banner says "warmed up on cuda" whatever the device; the `Loading Kokoro model on mps` log line is the reliable one.

Measured on 2026-10-29 on an Apple M2 with 16 GB, macOS 26.7.1, upstream commit `404d122`, with ClipboardTTS-shaped requests to each server in turn after one warm-up request, using text that server process had not spoken before (repeating a text makes the GPU look faster than it is, 0.31 s rather than about 1 s for a short sentence):

| Server | First audio, one sentence (6 runs) | First audio, 860–950 characters (3 runs) | Whole passage, about 50 s of audio |
|---|---|---|---|
| Docker, CPU | 1.07–1.10 s (3 runs of one repeated sentence) | 2.1–3.9 s | 17.6–18.3 s |
| Native, CPU | 0.54–0.87 s | 0.96–1.9 s | 8.5–10.2 s |
| Native, Apple GPU | 0.86–1.3 s | 0.72–1.2 s | 4.6–5.3 s |

Running natively removes most of Docker's latency. The GPU halves generation time and gave the steadiest first audio on long passages, but a sentence the GPU process has not seen before costs it a little more than the CPU; both stay well ahead of playback. These are a few runs on one machine, not a benchmark.

## Packaging

To distribute locally without an Apple Developer Program account (ad-hoc signed, not notarized), run `./package.sh`. The right-click service stays out of the Services menu until it is enabled once in System Settings → Keyboard → Keyboard Shortcuts… → Services → Text → "Speak Selected Text with Clipboard TTS"; an app already open when it is enabled may need relaunching before its context menu lists it. `package.sh` names no destination, so `xcodebuild` builds for the first one it matches, which on an Apple silicon Mac is `arm64` alone; package on Apple silicon, because the app is distributed for it only.
