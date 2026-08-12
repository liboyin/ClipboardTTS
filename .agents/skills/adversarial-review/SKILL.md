---
name: adversarial-review
description: Read-only adversarial review and triage of a non-trivial code change.
---

# Adversarial Review

Return a verified report without changing the repository. The reviewer MAY propose remedies but MUST NOT implement them.

## Procedure

1. **Freeze and snapshot.** The main agent records `git status`, hashes of dirty tracked files, path metadata for untracked files, and relevant PIDs/listeners, then freezes repository edits.

2. **Dispatch one reviewer.** Tell it to read this skill but execute only step 3 and return the defined report; the main agent owns steps 1, 2, and 4. Launch the reviewer agent without inherited conversation history using the applicable supported harness:

   - **Codex:** spawn the reviewer as a native subagent with `spawn_agent`, using `fork_turns: "none"` and explicit `model: "gpt-5.6-sol"` and `reasoning_effort: "high"` overrides, and instruct it to keep the repository read-only.
   - **Claude Code with the Codex plugin:** dispatch the reviewer with `/codex:rescue --fresh --model gpt-5.6-sol --effort high <review prompt>` or a fresh underlying companion `task` command with the same model and effort. Omit `--write`; never use `--resume` or `--resume-last`. The resulting Codex task MUST use its read-only sandbox.

   Pass only:

   - Repository path and target: dirty tree, commit, or range.
   - In-scope paths and any unrelated dirty paths to ignore.
   - Purpose of the change in a few sentences.

   Add undocumented constraints, accepted findings not to re-raise, or prior mutation evidence only when nonempty. Do not inline the diff, full conversation, architecture summaries available in the repository, suspected defects, or the main agent's conclusions.

   The reviewer MAY ask for further information when missing context could affect a finding or verdict. Reply with the minimum factual context and record the exchange under **Assumptions**.

   If `gpt-5.6-sol` or the applicable dispatch mechanism is unavailable, stop and ask the user. Do not substitute or issue a verdict.

3. **Review.** The reviewer:

   - Reads `AGENTS.md`, the complete target diff, in-scope untracked files, and relevant source, tests, documentation, and configuration. Never reads ignored untracked content.
   - Takes a constructively adversarial stance: assume the change may be wrong and actively try to falsify it with counterexamples, boundary and failure cases, invariant violations, state transitions, tests that can pass for the wrong reason, and mutants. For Swift, scrutinize isolation, lifetimes, callback ordering, cancellation, shared macOS state, and AppKit/SwiftUI lifecycle assumptions where relevant. Never manufacture findings, treat taste as a defect, or inflate severity; every finding needs evidence and proportional impact.
   - Uses these questions to navigate the review:
     - Does it achieve the intended purpose?
     - Is it bug-free?
     - Can it be simplified?
     - Is it consistent with the documentation?
     - Are there design flaws or anti-patterns?
     - Are there design choices that make testing or validation unnecessarily difficult?
     - Anything else a senior reviewer would push back on? Use judgment.
   - Verifies claims with safe, bounded commands. For changed assertions, uses a scratch copy to pass the baseline suite, prove the scratch with a loud mutant, and test applicable revert and future-regression mutants.
   - Keeps the repository read-only, cleans up only its recorded scratch artifacts and processes, compares repository status and hashes at exit, and returns the report below.

4. **Verify and triage.** The main agent confirms repository integrity and treats every reviewer claim and remedy as a hypothesis to validate. Classify each verified finding once: **Blocking** for bugs, broken tests, requirements, security, misleading claims, or `AGENTS.md` MUST violations; **Non-blocking** for deferrable improvements; **Nit** for cheap style only. Record rejected hypotheses under **Dismissed**. Any unexplained repository change blocks the review.

## Report

Return this structure without rewritten code. Every finding MUST cite a path and, when possible, a line; write “None” for empty sections.

```markdown
## Adversarial Review Report
**Purpose:** ...
**Target:** ...
**Reviewer:** <model/tool; failure>
**Assumptions:** ...
**Verification:** <commands and results>

### Blocking
1. `path:line` — <defect>. Impact: ... Proposed remedy (optional): ...
### Non-blocking
...
### Nits
...
### Dismissed
<hypothesis and measured reason>
### Verdict
<No blocking findings | N blocking findings — fix and re-review | Review blocked — reviewer availability or repository integrity>
```
