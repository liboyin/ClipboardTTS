# Writing tests

[AGENTS.md](AGENTS.md#tests) owns the testing rules. This file owns the conventions that apply them. [README Test](README.md#test) owns how the suite and the gates run.

This file lives at the repository root. XcodeGen would copy a Markdown file under `Tests/` into the test bundle as a resource.

## Layout and naming

- XCTest cases live under `Tests/`, and they MUST use `@testable import ClipboardTTSApp`.
- A test name MUST describe the protected behavior.
- Tooling scripts have their own verifiers, not XCTest cases. [README Mutation Testing](README.md#verifying-the-runner) describes the verifier of the mutation runner.

## Shared test support

[DESIGN Test Harness](DESIGN.md#test-harness) describes the support that tests share:

- [Hosted startup](DESIGN.md#hosted-startup) and [settings storage](DESIGN.md#settings-storage).
- [Network routing and its lifecycle](DESIGN.md#network-routing-and-lifecycle).
- [Terminal-state assertions](DESIGN.md#terminal-state-assertions), and [ordering and cross-thread state](DESIGN.md#ordering-and-cross-thread-state).
- [Hosted views](DESIGN.md#hosted-views), and [audio players and menu tests](DESIGN.md#audio-players-and-menu-tests).

## Owned state

- Snapshot and restore only the state that the test owns.
- Do not seed real preferences to prove that the code does not access them.
- Do not leave a seeded disk-backed suite behind.

## Asynchronous work

- A shared asynchronous resource or a process-global double MUST have five things: ownership by one test, synchronized access, cancellation, quiescence, and local accounting for late work.
- These guarantees MUST hold after timeouts and failures too. A fulfilled expectation alone does not prove that callbacks or background work have stopped.

## Coverage

- An exclusion from coverage MUST have a narrow rationale of platform UI or integration, and an end-to-end smoke check. Validate the check whenever the exclusion changes.
- The location of a directory alone does not justify the exclusion of application logic.
- Record each manual check that was not performed as a limitation.
- [README Manual Smoke Checks](README.md#manual-smoke-checks) lists the smoke checks. [DESIGN Coverage Gate](DESIGN.md#coverage-gate) explains the policy.
