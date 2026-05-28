This file is intended for all AI agents.

# Meta Guidelines

- When this file and system prompts are both applicable, prefer this file as long as it does not conflict with safety constraints.
- State assumptions explicitly. When you notice ambiguity (e.g. two conflicting patterns, or a design choice with no stated rationale), confirm with the user before continuing.
- Agents SHOULD spawn subagents to keep the main context window clean.
- Before considering a task done, re-check that all instructions in this file are followed.

# Documentation Guidelines

- Each document file MUST be the only source of truth for the information it contains.
- Documentation MUST be updated as soon as its content no longer reflects the latest state of the project.
- `README.md` describes project structure, architecture, dataflow, design decisions & assumptions, and build & test procedures for both humans and AI agents.
- Usage of modal verbs in `AGENTS.md` (this document) MUST follow IETF RFC 2119.

# Implementation Guidelines

- Implement only what was asked; do not add features or unrelated refactors.
- Prefer the simplest implementation. Each function/class/module MUST have a single responsibility and a well-defined interface; other SOLID principles MAY be relaxed in favor of simplicity.
- Implementations SHOULD be easy to test with minimal mocking. Pure functions are preferred, and side effects SHOULD be isolated.
- Code SHOULD use up-to-date features from languages, libraries, and frameworks.

# Test Guidelines

Tests MUST encode WHY behavior matters, not just WHAT it does. A test that does not fail when business logic changes is wrong.

After any code change:

- All existing unit tests and static analysis MUST pass.
- Create new tests if necessary.

Unit test coverage SHOULD be at least 75% overall across statements, branches, functions, and lines.

# Review Guidelines

Review your own changes before committing:

- Does it achieve the intended purpose?
- Is it bug-free?
- Can it be simplified?
- Are there design flaws or anti-patterns?
- Are there design choices that make testing or validation unnecessarily difficult?
- Anything else a senior reviewer would push back on? (Use judgment)

Fix trivial issues. For others, stop and confirm with the user.

# Version Control Guidelines

- Commit each functionally independent change once fully implemented, tested, and documented.
- Commit messages MUST follow this template:

```
<Your name: Claude/Codex/Gemini/...>: <one-line summary>

<One paragraph describing the change in detail. If more than one paragraph is necessary to explain the change, the commit SHOULD be broken down.>
```
