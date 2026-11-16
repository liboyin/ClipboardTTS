# Writing tests

[AGENTS.md](AGENTS.md#tests) owns the testing rules. This file owns the conventions that apply them. [DESIGN Test Harness](DESIGN.md#test-harness) owns the design of the shared test support. [README Test](README.md#test) owns how the suite and the gates run.

This file lives at the repository root. XcodeGen would copy a Markdown file under `Tests/` into the test bundle as a resource.

## Layout and naming

- XCTest cases live under `Tests/`, and they MUST use `@testable import ClipboardTTSApp`.
- A test name MUST describe the protected behavior.
- Comments explain non-obvious reasons or trade-offs.
- Tooling scripts have their own verifiers, not XCTest cases. [README Mutation Testing](README.md#verifying-the-runner) describes the verifier of the mutation runner.

## Owned state

- Use test-owned state throughout hosted startup, the managers and SwiftUI persistence. DESIGN describes the support for [hosted startup](DESIGN.md#hosted-startup) and for [settings storage](DESIGN.md#settings-storage).
- Snapshot and restore only the state that the test owns.
- Do not seed real preferences to prove that the code does not access them.
- Do not leave a seeded disk-backed suite behind.
- A scratch copy alone does not isolate macOS state.

## Network

- Automated tests MUST NOT reach an external service.
- DESIGN describes the test-owned [network routing and its lifecycle](DESIGN.md#network-routing-and-lifecycle).

## Asynchronous work

- A shared asynchronous resource or a process-global double needs five things: ownership by one test, synchronized access, cancellation, quiescence, and local accounting for late work.
- These guarantees hold after timeouts and failures too. A fulfilled expectation alone does not prove that callbacks or background work have stopped.
- DESIGN describes the [terminal-state assertions](DESIGN.md#terminal-state-assertions) and the rules for [ordering and cross-thread state](DESIGN.md#ordering-and-cross-thread-state).

## Time

- Prefer controlled inputs, schedulers and explicit completion signals.
- Do not wait for elapsed time where a completion signal exists.

## Views and audio

- DESIGN describes how tests host [views](DESIGN.md#hosted-views), and how they own [audio players and menu tests](DESIGN.md#audio-players-and-menu-tests).

## Mutants

- Mutants of code under XCTest run through the [`run-mutants.py` procedure](README.md#mutation-testing).
- A mutant that weakens the tests' own isolation MUST NOT run through the runner as it stands. [README Isolation](README.md#isolation) states the rule.

## Coverage

- An exclusion from coverage MUST have a narrow rationale of platform UI or integration, and an end-to-end smoke check. Validate the check whenever the exclusion changes.
- The location of a directory alone does not justify the exclusion of application logic.
- Record each manual check that was not performed as a limitation.
- [README Manual Smoke Checks](README.md#manual-smoke-checks) lists the smoke checks. [DESIGN Coverage Gate](DESIGN.md#coverage-gate) explains the policy.
