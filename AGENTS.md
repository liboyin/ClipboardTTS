This file is intended for AI agents.

# Meta Guidelines

- State assumptions explicitly. When you notice ambiguity (e.g. two conflicting patterns, or a design choice with no stated rationale), confirm with the user before continuing.
- Prefer spawning subagents to keep the main context window clean.
- Before considering a task done, re-check that all instructions in this file are followed.

# Documentation Guidelines

- `README.md` describes project architecture, dataflow, design decisions, and assumptions for both humans and AI agents. It is the WHY document and must not be mixed with HOW content.

# Implementation Guidelines

- Prefer the simplest implementation, even if it violates SOLID principles. No feature beyond what was asked.
- Use up-to-date features from languages, libraries, and frameworks.
- Break changes into small, functionally isolated chunks; commit as you go.
- Commit messages must follow this template:

```
<Your name: Claude/Codex/Gemini/...>: <one-line summary>

<One paragraph describing the change in detail. If more than one paragraph is necessary, the change can probably be broken down.>
```

# Test Guidelines

Tests must encode WHY behavior matters, not just WHAT it does. A test that does not fail when business logic changes is wrong.

After any code change:

- All existing unit tests and static analysis must pass.
- Create new tests if necessary.

Unit test coverage must be at least 85% overall across statements, branches, functions, and lines.

# Review Guidelines

Review your own changes before committing:

- Does it achieve the intended purpose?
- Is it bug-free?
- Are there design flaws or anti-patterns?
- Can it be simplified?
- Anything else a senior reviewer would push back on? (Use judgment)

Fix trivial issues. For others, stop and confirm with the user.