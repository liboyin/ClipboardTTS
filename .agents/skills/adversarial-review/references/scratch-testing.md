# Scratch Testing Recipe

Use this recipe when the [review procedure](../SKILL.md#procedure) requires writable execution. [AGENTS](../../../../AGENTS.md#test-guidelines) owns test safety and mutation requirements; [README](../../../../README.md#build--test) owns Xcode generation, hosted-test isolation and the `run-mutants.py` procedure.

Create a scratch copy only when writable execution is needed. Reuse an owned copy for focused checks of a fixed candidate where practical, restoring the candidate between probes and using fresh test processes. Do not share writable scratch between agents. Retain evidence outside disposable scratch. Evidence inspection alone needs no copy.

## Mutation selection and containment

Cover AGENTS' applicable revert, plausible-regression and over-restriction categories for each changed invariant. Choose tests that observe the protected behavior and own every reachable side effect, including paths exposed by a mutant bypassing validation. An invalid endpoint, synthetic credential or temporary configuration does not prevent a network attempt or access to macOS state.

Preserve test-owned startup, defaults, secret stores, pasteboard readers, network routing, audio scheduling and teardown. README explicitly prohibits running a mutant that weakens test isolation through the runner as it stands: record that category as inapplicable unless the user approves an isolation for it. Do not substitute ad hoc scratch guards for that required disposition. Never use the real Keychain, pasteboard, preferences or external providers to establish a mutation kill.

For code under XCTest, use `./run-mutants.py SPEC.json --out DIR` with the selectors, exact edits and in-scope untracked files described in README. The runner builds its own copy; invoke it from the prepared target when unrelated dirty files must be excluded. Keep the output directory outside the repository and any disposable parent copy. Tooling scripts use their own verifiers rather than the XCTest runner.

The unmutated selected tests must pass under the same isolation and runner settings. Inspect `results.json` and the named behavioral failure in each mutant log: exit 0 alone does not mean all mutants were killed, and build, lint, environment, provenance or no-test failures do not prove behavioral protection. Retain the exact spec, candidate/test identities, selectors, runner settings, control result and relevant failure excerpts.

If ownership or provenance fails, record the run as invalid, stop the probe, quiesce owned work, restore the candidate, and resolve containment before retrying. Do not repeat an unsafe command unchanged. Preserve a brief account of any verified access and cleanup without secrets; obtain any isolation approval required above.

## Build and test provenance

Use the macOS toolchain and generated `ClipboardTTSApp` scheme described in README. Regenerate the project in scratch from its own `project.yml` and source/test inputs. Keep derived data and result bundles in owned locations, disable signing, and retain complete strict-concurrency and SwiftLint checks. Verify build/test commands reference the scratch project and that the executed application/test bundles come from its derived data. Source identity alone does not certify which bundle ran.

Preserve the hosted startup branch and test-owned dependencies; a scratch checkout does not isolate macOS state. Keep SwiftUI/AppKit hosting and asynchronous quiescence requirements from README when selecting focused tests. For runner evidence, retain its recorded HEAD, copied-state/spec digests and control/mutant results alongside the exact candidate changes and non-secret toolchain information. Record additional build/bundle provenance when needed to establish the exercised candidate.

Hosted `xcodebuild test` can fail in a sandbox that denies `testmanagerd`; exit 65 alone does not establish that cause. Report a blocked environment with evidence. Running the built XCTest bundle directly has different scheduling: label any such focused investigation runner-specific, and do not use it to bypass the required mutation-runner procedure or application gates.

After transferring essential evidence to the retained record, remove owned scratch copies, derived data and disposable logs, and confirm owned processes have stopped. Do not delete required evidence with the runner's retained scratch output.
