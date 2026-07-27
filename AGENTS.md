All agents MUST follow this file.

CAPITALIZED requirement words have the meanings defined by BCP 14 (RFC 2119 and RFC 8174).

# Meta Guidelines

- Before editing, you MUST read the relevant code and documentation and plan your actions carefully.
- State assumptions explicitly. When you notice multiple reasonable approaches with trade-offs, or ambiguities that materially affect scope, architecture, dataflow, correctness, or security, you MUST stop and confirm with the user.
- Isolated subtasks (tasks that require little or no additional context from the main conversation and produce a small, well-bounded result for follow-up work) SHOULD be executed in subagents to keep the main context window clean.
- Clean up any background process you start. Resolve PIDs beforehand and use `kill`; NEVER use `pkill -f` as it matches your own tool execution and will terminate your agent.
- Claims that an action succeeded MUST use a check whose output would differ on failures. Treat non-zero exit codes as failures until explained. Verify absence directly instead of inferring it.
- Before considering a task done, you MUST re-check compliance with this file.

# Workflow Guidelines

- The planner defines a task's intended boundary, dependencies, non-goals, validation strategy, and done criteria in `TODO.md`. Each task MUST remain a self-contained commit.
- The executor MUST re-read the task and affected code before implementation. `TODO.md` is a contract to validate against the repository, not permission to apply it mechanically.
- When execution exposes an ambiguity or trade-off that materially affects scope, architecture, dataflow, correctness, security, or user-visible behavior, the executor MUST stop and ask the user for direction. It MUST NOT broaden or rewrite the task boundary unilaterally.
- The executor MAY make a non-material assumption only when it is supported by repository evidence and does not alter the requested outcome. Its final hand-over MUST name the assumption, supporting evidence, and effect on the change.
- If user direction changes a task's material boundary, update `TODO.md` before committing so the remaining execution plan stays authoritative.
- The adversarial reviewer independently evaluates the complete dirty tree against the task boundary; review findings re-enter the executor's test and review loop.

# Documentation Guidelines

- Each document SHOULD be the unique owner of its assigned topic. Other docs SHOULD link or summarize without becoming competing sources of truth.
- Documentation MUST be updated as soon as its content no longer reflects the latest state of the project.
- Design decisions & assumptions MUST be documented, and SHOULD record the reasoning behind them.
- Every empirical claim in a document, status block, documentation comment, or other code comment MUST be verified immediately before writing down.
- Document ownership:
    - `USER_STORIES.md` owns product requirements and user-visible behavior.
    - `TODO.md` is the phased execution plan and hand-over log. It records work still to do and decisions already made.
    - `README.md` is the project overview and operating guide. It owns the current architecture, design assumptions, and build, test, and distribution procedures.
- Completed-task handling:
    - Remove a completed task's full active entry from `TODO.md` in that task's implementation commit.
    - Record detailed implementation history in the commit and current operating behavior in `README.md`; do not duplicate either in `TODO.md`.
    - `TODO.md` MAY retain one concise hand-over or decision note when the completion materially constrains remaining work. Link to `README.md` instead of repeating implementation detail.
    - Update task counts, dependencies, and work-map references in the same commit.
- New or changed non-test types, functions, and methods MUST use Swift documentation comments (`///`) when their purpose, contract, side effects, or constraints are not obvious from the declaration. Test method names MUST describe the behavior under test; add a comment only when the reason or trade-off is not clear from the test.

# Implementation Guidelines

- Implement only what was asked with small, surgical changes. Do not add features or unrelated refactors unless explicitly asked to.
- Prefer the simplest implementation. Each function/class/module MUST have a single responsibility and a well-defined interface; other SOLID principles MAY be relaxed in favor of simplicity.
- Code MUST be testable with minimal mocking; prefer pure logic and isolated side effects.
- Code SHOULD use up-to-date features from languages, libraries, frameworks, and external services. Because these change quickly, you SHOULD verify behavior empirically or against the version-appropriate documentation before planning or building on them.
- Before deleting a seemingly redundant layer, identify everything unique it carries (copy, error shape, ordering, timing, diagnostics) and give each item another home.

# Test Guidelines

- Tests MUST encode WHY behavior matters, not just WHAT it does. A test that does not fail when business logic changes is wrong.
- Mutation-test every new assertion in an isolated scratch copy. Include at least one mutant toward a plausible future regression, not only a revert, and test the trade-off introduced by a constraint.
- `check-coverage.sh` is the source of truth for coverage measurement and thresholds. It uses XCTest coverage from `xccov` and requires at least 85% aggregate line coverage for `Sources/Managers/`.
- `Sources/Views/` is exempt from the line-coverage gate because declarative SwiftUI bodies are exercised through construction smoke tests. Other exclusions MUST have a documented rationale and an end-to-end smoke test.
- XCTest test cases MUST import the app with `@testable import ClipboardTTSApp`. Prefer injected dependencies and test doubles over modifying process-wide macOS state.
- Tests that touch persisted app settings MUST call `isolateAppSettingsDefaults()` so the hosted test bundle neither reads nor overwrites the developer's configuration.
- Generate `ClipboardTTSApp.xcodeproj` with `xcodegen generate` before building or testing when it is absent or `project.yml` changed. The generated project MUST NOT be committed.
- After every code change, all gates MUST pass:

```bash
./check-coverage.sh
swiftlint --strict
```

# Review Guidelines

Every non-trivial code, test, or configuration change MUST pass the adversarial review (`.agents/skills/adversarial-review/SKILL.md`) procedure before commit. Documentation-only changes are exempt.

The adversarial review skill owns the operational procedure: the caller context it requires, the questions it scrutinizes with, and its report format. Call it as a function on the current dirty tree and expect a verified, triaged findings report without code change.

The main agent remains accountable for the execute-review loop:

1. Run the review skill on the dirty tree or the specified revision.
2. Based on the review report, create execution plans to fix blocking findings and trivial non-blocking findings.
3. Implement the plan step-by-step.
4. Repeat step 1 - 3 until no blocking findings remain. Do not shorten the loop.
5. Ask the user whether to fix, defer, or ignore remaining non-blocking findings.

Undoing a code change re-enters the loop at step 1. Verify clean rollbacks against `HEAD` with `git diff`; do not rely on your recollection of the delta.

# Version Control Guidelines

- Commit each functionally independent change once fully implemented, tested, and documented.
- Stage explicit paths and inspect `git status` immediately before committing. NEVER use `git add -A` or `git commit -a`.
- Use the template below for commit messages. Do not add a `Co-Authored-By` line:

```text
<Claude/Codex/Antigravity/...>: <one-line summary>

<One or more paragraphs describing the change in detail.>
```
