This document contains guidelines that all AI agents MUST follow.

The key words MUST, MUST NOT, REQUIRED, SHALL, SHALL NOT, SHOULD, SHOULD NOT, RECOMMENDED, NOT RECOMMENDED, MAY, and OPTIONAL in this document are to be interpreted as described in BCP 14 (IETF RFC 2119 and RFC 8174) when, and only when, they appear in all capitals, as shown here.

# Meta Guidelines

- Always read relevant code & documentation, and plan your actions before making a file change.
- State assumptions explicitly. When you notice an ambiguity that materially affects the project (e.g. scope, architecture, dataflow, correctness, or security), confirm with the user before continuing.
- Isolated subtasks (tasks that require little or no additional context from the main conversation and produce a small, well-bounded result for follow-up work) SHOULD be executed in subagents to keep the main context window clean.
- Before considering a task done, you MUST re-check that all instructions in this file are followed.

# Documentation Guidelines

- Each document SHOULD own its assigned topic, and other docs SHOULD link or summarize without becoming competing sources of truth.
- Documentation MUST be updated as soon as its content no longer reflects the latest state of the project.
- `README.md` describes project structure, architecture, dataflow, design decisions & assumptions, and build & test procedures.

# Implementation Guidelines

- Implement only what was asked with small, surgical changes. Do not add features or unrelated refactors unless explicitly asked to.
- Prefer the simplest implementation. Each function/class/module MUST have a single responsibility and a well-defined interface; other SOLID principles MAY be relaxed in favor of simplicity.
- Implementations MUST be easy to test with minimal mocking. Pure functions are preferred, and side effects SHOULD be isolated.
- Code SHOULD use up-to-date features from languages, libraries, and frameworks.

# Test Guidelines

Tests MUST encode WHY behavior matters, not just WHAT it does. A test that does not fail when business logic changes is wrong.

After any code change:

- All existing unit tests and static analysis MUST pass.
- Create new tests if necessary.
- Business logic in `Sources/Managers/` MUST meet the line-coverage threshold (enforced by `check-coverage.sh`).
- Declarative UI logic in `Sources/Views/` is exempted from coverage check.

# Review Guidelines

Always perform an adversarial review on your changes before committing:

- Does it achieve the intended purpose?
- Is it bug-free?
- Can it be simplified?
- Are there design flaws or anti-patterns?
- Are there design choices that make testing or validation unnecessarily difficult?
- Anything else a senior reviewer would push back on? (Use judgment)

The review MUST be performed in a subagent. Use Claude Fable 5 if available.

Fix trivial issues. For others, stop and confirm with the user.

# Version Control Guidelines

- Commit each functionally independent change once fully implemented, tested, documented, and reviewed.
- Commit messages MUST follow this template. Do not add "Co-Authored-By" line:

```
<Your name: Claude/Codex/Antigravity/...>: <one-line summary>

<One paragraph describing the change in detail. If more than one paragraph is necessary to explain the change, the commit SHOULD be broken down.>
```
