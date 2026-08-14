---
name: adversarial-review
description: Adversarial review and reviewer-owned triage of non-trivial code, test, or configuration changes. Use before commit when AGENTS.md requires independent review; return findings without changing the repository.
---

# Adversarial Review

Return a reviewer-triaged report without changing the repository. The reviewer MAY propose remedies but MUST NOT implement them. The main agent investigates Blocking findings, handles Nits when practical, and surfaces Non-blocking findings to the user as defined in step 4.

## Procedure

1. **Gate, freeze, and snapshot.** Before dispatching the reviewer, the main agent MUST run every gate required by `AGENTS.md` against the exact target state and confirm that each passes. If any gate fails, do not dispatch the reviewer; resolve the failure first. After the gates pass, freeze repository edits and record `git status`, content hashes for dirty tracked files and in-scope untracked files, the paths of out-of-scope untracked files, and relevant PIDs/listeners. Do not inspect or hash ignored untracked content.

2. **Dispatch one reviewer.** Tell it to read this skill but execute only step 3 and return the defined report; the main agent owns steps 1, 2, and 4. Launch the reviewer agent without inherited conversation history using the applicable supported harness:

   - **Codex:** spawn the reviewer as a native subagent with `spawn_agent`, using `fork_turns: "none"` and explicit `model: "gpt-5.6-sol"` and `reasoning_effort: "high"` overrides. Native subagents inherit the current Full Access environment; no sandbox configuration is required.
   - **Claude Code with the Codex plugin:** dispatch the reviewer with `/codex:rescue --fresh --write --model gpt-5.6-sol --effort high <review prompt>` or a fresh underlying companion `task` command with the same model and effort. Never use `--resume` or `--resume-last`.

   (The reviewer needs filesystem write access only to create and test a scratch copy outside the repository. Native Codex receives that access from the inherited environment; Claude Code receives it through `--write`. Regardless of harness, the dispatch MUST tell the reviewer to treat the repository as strictly read-only, to build and test only in its scratch copy, and to remove that copy at exit. Construct the scratch copy from the tracked target state, apply only the in-scope staged and unstaged changes, and copy only explicitly identified in-scope untracked files. Never recursively copy ignored or out-of-scope content. If the reviewer cannot create the scratch copy, it returns a `Review blocked` verdict. The reviewer is trusted to follow this read-only contract. Step 1's snapshot and step 4's comparison detect accidental repository mutations; they are not a security boundary.)

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
   - Classifies each finding using judgment based on its evidence, impact, likelihood, task requirements, and risk of deferral. **Blocking** findings must be resolved before commit; **Non-blocking** findings are genuine issues that may reasonably be deferred; **Nits** are low-impact style or readability issues with an obvious local remedy. These are judgment categories, not mechanical issue-type rules.
   - Verifies claims with safe, bounded commands. The reviewer MUST assume that every gate required by `AGENTS.md` passed on the frozen target before dispatch. It SHOULD NOT rerun the complete gate suite, but MAY run focused tests or other bounded commands needed to investigate a specific finding. For every added, removed, or changed assertion, applies all applicable mutation requirements from `AGENTS.md` under **Test Guidelines**. Verifies supplied mutation evidence, produces any missing evidence only in the scratch copy, and records the commands and results under **Verification**.
   - In a sandboxed harness, hosted `xcodebuild test` can fail because the sandbox denies `testmanagerd`, even with write access; exit 65 alone does not prove that, since a genuinely failing test reports the same code. Running the built XCTest bundle directly is a valid fallback whose scheduling differs, so label scheduling-dependent results runner-specific.
   - Keeps the repository read-only, cleans up only its recorded scratch artifacts and processes, reports that cleanup, and returns the report below.

4. **Validate and disposition findings.** The reviewer owns the triage and verdict. The main agent first compares repository status, recorded hashes, and the out-of-scope untracked path list against the step 1 snapshot; any unexplained repository change blocks the review. It then handles each finding according to its reviewer-assigned classification:

   - **Blocking:** The main agent MUST independently investigate and validate the claim and the premise and expected effect of any proposed remedy before accepting or implementing it. It MUST fix each validated Blocking finding. If a materially equivalent Blocking finding appears in two consecutive fresh reviews and the main agent still cannot validate it, stop and ask the user for direction.
   - **Nits:** The main agent SHOULD independently validate and fix each Nit. It MAY instead leave a Nit unfixed when the remedy is non-trivial, in which case it MUST surface the Nit to the user. Before implementing any Nit remedy, it MUST validate the claim and the remedy's premise and expected effect.
   - **Non-blocking:** The main agent MUST surface each finding directly to the user and NEED NOT independently investigate or validate it first.

   The main agent MUST NOT silently discard or reclassify a reviewer finding. For every finding, record **Validated**, **Could not validate**, or **Not independently validated**, with supporting evidence when validation was attempted. The user decides whether to fix, defer, or accept without change any surfaced Non-blocking finding or Nit. Before implementing a user-selected remedy, the main agent MUST independently validate the finding and the remedy's premise and expected effect.

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
<No blocking findings | N blocking findings — fix and re-review | Review blocked — scratch environment or repository integrity>
```

After handling the report, the main agent appends a **Main-agent validation** section that records each finding as **Validated**, **Could not validate**, or **Not independently validated**, with supporting evidence when validation was attempted. This addendum does not alter the reviewer's triage or verdict.
