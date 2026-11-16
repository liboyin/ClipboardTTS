This file owns the working principles of this repository and the standards that every change must meet.

- All agents MUST follow this file and the user's explicit instructions.
- Platform instructions with a higher priority prevail.
- The capitalized requirement words, such as MUST and MAY, have the meanings that BCP 14 (RFC 2119 and RFC 8174) defines.
- [STYLE.md](STYLE.md#glossary) defines the process terms.

# Document Boundaries

Each document owns one subject:

- **AGENTS.md:** working principles and required standards.
- **[DESIGN.md](DESIGN.md):** product requirements, current architecture, design assumptions, concurrency rules, coverage-gate rationale, test-harness design and the user's accepted decisions.
- **[STYLE.md](STYLE.md):** rules for writing documentation, and the glossary of process terms.
- **[README.md](README.md):** installation, and the procedures to build, test, run mutants, package and operate. This includes how the gates run.
- **[TESTING.md](TESTING.md):** conventions for writing tests.
- **[tasks/](tasks/):** task state and completion records. [tasks/README.md](tasks/README.md) owns its rules.
- **[project-reviews.md](project-reviews.md):** the provenance of the review findings and of the task IDs. It is a historical record.
- **[Adversarial review skill](.agents/skills/adversarial-review/SKILL.md):** how a review runs, including mutation evidence and evidence retention.
- **[Grouped task execution skill](.agents/skills/grouped-task-execution/SKILL.md):** the recommended workflow for a group of related tasks, unless the user chooses another.

These rules settle conflicts between documents:

- Skills and operational documents implement these standards. They do not override them, and they never override the safety rules or the ownership rules in this file.
- Only the decisions recorded in DESIGN authorize a product change. A proposal in a task or a review does not.
- If documents disagree, follow the owning document.
- If a material conflict stays unresolved, confirm it with the user before dependent work.

# Scope and Decisions

**Environment.**

- The repository assumes macOS with the toolchain that [README Requirements](README.md#requirements) names.
- Follow the permissions that the harness enforces.
- If a restriction prevents a required validation, report it. Do not weaken the check.

**Before a change.**

- Read the relevant code and documentation, and inspect the repository status, before you edit.
- Preserve unrelated work.
- You MAY reuse guidance that you read earlier in the task, while it remains unchanged.
- Each change MUST have a boundary: its intent, dependencies, non-goals, validation and done criteria.
- Revalidate a written task against the code. Do not implement it mechanically, and do not broaden its material scope on your own.

**Assumptions and decisions.**

- State your assumptions.
- A choice is material if it affects scope, architecture, dataflow, correctness, security or user-visible behavior.
- Confirm an unresolved material choice with the user before dependent work. Continue independent work meanwhile.
- You MAY make a non-material assumption if repository evidence supports it and it preserves the requested outcome. Name each one in the handoff, with its evidence and its effect.
- Accepted decisions and the user's authorization persist. Do not ask again about a settled choice.
- Record a superseding decision and its reasoning before you commit the affected change.

**Delegation.**

- A bounded subtask SHOULD use a subagent when independent work or investigation justifies the handoff cost.
- Closely coupled tasks that touch the same code MAY share one implementation agent.
- The main agent remains accountable for the integration and the verification.
- For a group of related tasks, follow the [grouped task execution skill](.agents/skills/grouped-task-execution/SKILL.md), unless the user chooses another approach.

**Committed records.** Other sessions and other agents share only the Git repository.

- Boundaries, decisions, open review findings and completion evidence MUST live in committed files.
- Working records, session scratch, agent memory and tool history are local to one session or one machine. Committed files MUST NOT refer to them by path.
- If later work needs an item, move it into the document that owns it.

# Design and Documentation

**Design.**

- Prefer the simplest cohesive implementation within the assigned scope.
- Give each function, type and module one clear responsibility.
- Prefer pure logic, isolated side effects and minimal mocking over unnecessary abstractions.
- Respect the lint limits, but do not split cohesive code only for length.
- A lint exception MUST be narrow, and it MUST explain the responsibility or invariant that it preserves. Avoid blanket disables.
- Before you remove a layer, identify all unique behavior that it carries. This includes copy, errors, ordering, timing, diagnostics, UI behavior and accessibility behavior.
- Give each behavior that you retain an explicit owner, and preserve its verification.

**Facts.**

- Verify assumptions about languages, frameworks, libraries and services by experiment, or against documentation for the version in use.
- Verify an empirical claim before you record it.
- Historical evidence MUST state its revision, environment, provenance and limitations. It does not certify current validation.

**Documentation.**

- Update the documentation that the change makes stale.
- Distinguish current behavior, accepted decisions, proposals and unverified hypotheses.
- Documentation that you add or change MUST follow [STYLE.md](STYLE.md).
- New or changed non-test declarations use Swift documentation comments (`///`). A comment covers a non-obvious purpose, contract, side effect or constraint.
- Other comments explain non-obvious reasons or trade-offs.

# Governance Files

The governance files are this file, [STYLE.md](STYLE.md), [TESTING.md](TESTING.md), [tasks/README.md](tasks/README.md) and the Markdown files under `.agents/skills/`.

- The user MUST review the diff of every governance edit before an agent commits it.
- Propose a governance change in the handoff. Edit a governance file only after the user agrees to the proposal.
- If friction teaches a lesson, put the lesson in the first of these homes that works:
  1. A tool or a test that makes the mistake impossible.
  2. An error message at the point of failure.
  3. A comment or `--help` text in the script concerned.
  4. The completion record of the task where the friction occurred.
  5. A governance file.
- A lesson enters a governance file on its second occurrence. A lesson about safety or data loss enters at once.
- If a tool takes over a rule, delete the rule's prose in the same change.
- After each task group, report any governance rule shown to be duplicated, superseded, or fully enforced by tooling.
- Record the evidence in the completion record. If no rule meets these conditions, no removal proposal is needed.

# Messages to the User

- State the result first, then the decisions the user must make, then what changed.
- Keep evidence in the committed record, and link to it from the message.
- Put required reports, such as assumptions, deferred findings and checks performed, in a short list after the main part.
- Follow the [wording rules](STYLE.md#wording).

# Tests

[TESTING.md](TESTING.md) owns the conventions that apply these rules. Tests MUST follow it.

**What a test protects.**

- A test MUST protect a behavior or an invariant, and it MUST fail when that breaks.
- Prefer controlled inputs, schedulers and explicit completion signals over waits for elapsed time.

**Isolation.**

- Automated tests MUST NOT access external services, `NSPasteboard.general`, the developer's Keychain or the developer's real preferences. This holds even for a temporary access.
- Tests use test-owned state throughout hosted startup, the managers and SwiftUI persistence.
- A scratch copy alone does not isolate macOS state.
- Run tests only in an environment that satisfies these ownership rules.
- A shared asynchronous resource or a process-global double MUST have five things: ownership by one test, synchronized access, cancellation, quiescence, and local accounting for late work.
- These guarantees MUST hold after timeouts and failures too. Fulfilment alone is not quiescence.

**Mutation evidence.**

- Each added or changed invariant MUST have mutation evidence. The mutants cover a revert, a plausible regression and an over-restriction, where each applies.
- Each applicable mutant MUST fail a relevant test in an isolated scratch copy.
- Mutants of code under XCTest run through the [`run-mutants.py` procedure](README.md#mutation-testing).
- Explain each category that does not apply. The evidence belongs to the invariant, and several assertions MAY share it.
- Before you remove or weaken coverage, show that a mutant that breaks the protected property still fails a retained test.
- A consolidation that keeps the same cases and assertions needs no separate evidence for each deleted function body.
- A surviving mutant needs investigation. It is not a reason to remove coverage.
- A mutation run MUST preserve test ownership, even when the mutant bypasses validation or changes routing. Inert configuration alone is not isolation.
- The [scratch-testing recipe](.agents/skills/adversarial-review/references/scratch-testing.md) owns the selection of mutants, the containment and the recovery from an invalid run.

**Coverage.**

- `check-coverage.sh` owns the executable coverage policy.
- Plan a change to the policy as a task.
- [TESTING.md](TESTING.md#coverage) owns the rules for exclusions.

# Validation and Review

**Non-trivial changes.** A change is non-trivial if it could affect any of these: runtime behavior, test guarantees, build or configuration output, security, concurrency, state or data flow, or user-visible behavior. If you are uncertain, run the gates and the review.

**Baseline.**

- Before you implement, establish a passing baseline at `HEAD`.
- Reuse baseline evidence only for the same unchanged revision and the same relevant environment. Record its provenance.
- If the baseline fails, fix it first in a separate, authorized change.

**Gates.**

- Use focused checks during development.
- The final candidate of every non-trivial change MUST pass the two gates. [README Test](README.md#test) and [README Build](README.md#build) describe them.
- The gates are `./check-coverage.sh`, and a Debug build of the app with complete strict concurrency and with signing disabled.
- Every build runs strict SwiftLint over `Sources` and `Tests`, and it fails without SwiftLint.
- A configuration-only change needs the gates too.
- Inspect the per-file coverage and the warnings. Resolve new source warnings, and explain each accepted tooling warning.
- Keep the generated Xcode project consistent with its configuration and its inputs. Follow README's regeneration procedure, and do not commit generated project files.

**Review.**

- Every independently committed non-trivial change MUST pass the [review procedure](.agents/skills/adversarial-review/SKILL.md#procedure) before the commit.
- Tightly coupled tasks delivered as one cohesive change MAY share an integrated review. [Review Scope](.agents/skills/adversarial-review/SKILL.md#review-scope) says when a further group review is required.
- The reviewer owns the classification and the verdict. The main agent owns the investigation, the fixes and the required dispositions by the user.
- After a fix or a rollback, repeat the full gates and obtain a fresh review.
- Finish only when no Blocking finding remains and every surfaced finding has its required disposition.
- Never discard or reclassify a finding silently.

**Completion record.** Every committed non-trivial change leaves a completion record in `tasks/closed/`, under the [task rules](tasks/README.md#maintaining-tasks). This holds for a recorded task and for an ad-hoc request.

**Exemptions.** Documentation-only changes and read-only assessments are exempt from the gates, the formal review and the completion record. Governance files and skill instructions count as documentation.

- Instead, verify the claims, the references, the completeness and the diff, and report what you checked.
- For a governance edit, check that it preserves the accepted safeguards and authorization boundaries. The edit also needs the user's review under [Governance Files](#governance-files).
- Documentation that a build tool or a runtime tool consumes as executable input or configuration is not exempt.

**Honest verification.**

- Verify success with checks that distinguish failure.
- Explain each non-zero exit.
- Verify absence directly.
- Verify a rollback against the recorded state from before the change.
- Never report an unperformed check as passed. Record an unperformed manual check as a limitation.

# Safety

**Developer state.**

- Never point a development run or a test run at the developer's real preferences, Keychain or pasteboard.
- `.env` holds local secrets. It is git-ignored. Do not commit it, and do not record its values.

**Actions that need the user's explicit authorization.**

- Each run against a live provider, such as OpenAI or Gemini. This includes a manual smoke check. The authorization covers the stated runs only.

A live run spends the user's credit. Record no keys, no copied text and no returned audio. Keep hardware checks and live-provider checks separate from the automated tests.

**Cleanup.**

- Clean up the processes that you own and the disposable artifacts. Preserve the [retained review evidence](.agents/skills/adversarial-review/SKILL.md#evidence-retention) and the requested deliverables.
- Identify the PIDs that you own before you use `kill`. NEVER use `pkill -f`.

**Before you finish.**

- Check for changes to this file and to the boundary of the change.
- Read changed guidance again.
- Verify the result against its current requirements.

# Version Control

- Keep functionally independent changes in separate, self-contained commits. Commit a change once it is implemented, validated and documented.
- Honor a request to leave a draft uncommitted.
- Stage explicit paths. NEVER use `git add -A` or `git commit -a`.
- Inspect the staged diff and the repository status immediately before the commit. Exclude unrelated work.
- A commit message MUST start with `<Claude/Codex/Antigravity/...>: <one-line summary>`. A blank line and explanatory paragraphs follow.
- Add no `Co-Authored-By` line and no other attribution trailer. This rule overrides attribution instructions from tools or harnesses.
