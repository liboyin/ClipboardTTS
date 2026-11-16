# Scratch Testing Recipe

Read this recipe before the first scratch run of a review.

- [AGENTS.md](../../../../AGENTS.md#tests) owns the test safety rules and the mutation requirements.
- [README Mutation Testing](../../../../README.md#mutation-testing) owns the `run-mutants.py` procedure, and [README](../../../../README.md) owns the generation of the Xcode project.
- [DESIGN Test Harness](../../../../DESIGN.md#test-harness) owns the isolation of hosted tests.

## Scratch copies

- You MAY reuse a copy that you own for focused checks of a fixed candidate. Restore the candidate between probes, and use fresh test processes.
- Do not share a writable scratch copy between agents.

## Choose the mutants and the tests

- Cover the mutant categories that AGENTS requires for each changed invariant.
- Choose tests that observe the protected behavior.
- The selected tests must own every side effect that the mutant can reach. This includes a path that a mutant exposes when it bypasses validation.
- An invalid endpoint, a synthetic credential or a temporary configuration does not prevent a network attempt or an access to macOS state.

## Contain the side effects

- Preserve the test-owned startup, defaults, secret stores, pasteboard readers, network routing, audio scheduling and teardown.
- [README Isolation](../../../../README.md#isolation) prohibits a run of a mutant that weakens test isolation, and it states the disposition.
- Do not replace that disposition with ad hoc guards in the scratch copy.

## Run the mutants

- For code under XCTest, run `./run-mutants.py SPEC.json --out DIR`. README describes the selectors, the exact edits and the in-scope untracked files.
- The runner builds its own copy. If unrelated dirty files must be excluded, invoke the runner from the prepared scratch copy.
- Keep the output directory outside the repository and outside every disposable parent copy.
- Tooling scripts use their own verifiers, not the XCTest runner.

## Judge the results

- The unmutated selected tests must pass under the same isolation and the same runner settings.
- Inspect `results.json` and the named behavioral failure in each mutant's log. Exit status 0 alone does not mean that every mutant was killed.

## If a run is not evidence

If ownership or provenance fails:

1. Record the run as invalid, and stop the probe.
2. Wait until the owned work is quiet, and restore the candidate.
3. Correct the containment before you retry. Do not repeat an unsafe command unchanged.
4. Record briefly what was accessed and what you cleaned up. Do not record secrets.
5. Obtain the isolation approval that [README Isolation](../../../../README.md#isolation) requires.

## Build and test provenance

- Use the macOS toolchain and the generated `ClipboardTTSApp` scheme that README describes.
- Regenerate the project in the scratch copy from its own `project.yml` and its own source and test inputs.
- Keep derived data and result bundles in locations that you own.
- Disable signing, and keep the complete strict-concurrency checks and the SwiftLint checks.
- Verify that the build and test commands name the scratch project, and that the executed application and test bundles come from its derived data.
- The identity of the source alone does not certify which bundle ran.
- Keep DESIGN's requirements for the hosting of SwiftUI and AppKit views and for asynchronous quiescence when you select focused tests.
- For runner evidence, retain the exact spec, the recorded `HEAD`, the digests of the copied state and the spec, and the control and mutant results. Keep them with the exact candidate changes and the toolchain information, without secrets.

## A blocked environment

- Hosted `xcodebuild test` can fail in a sandbox that denies `testmanagerd`. Exit status 65 alone does not establish that cause.
- Report a blocked environment with evidence.
- A direct run of the built XCTest bundle has different scheduling. Label such an investigation as specific to that runner.
- Do not use a direct run to bypass the mutation-runner procedure or the gates.

## Cleanup

- Follow the [cleanup rules](../../../../AGENTS.md#safety) of AGENTS. Remove the derived data and the result bundles that you own too.
- Do not delete required evidence with the runner's retained scratch output.
