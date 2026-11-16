---
name: grouped-task-execution
description: Select and implement a small group of related open tasks, delegating implementation and reviewing the integrated group. Use for grouped backlog execution in this repository.
---

# Grouped Task Execution

Use this workflow for a group of related backlog tasks.

- [AGENTS.md](../../../AGENTS.md) owns the standards and the commit requirements. The [task rules](../../../tasks/README.md) own boundaries and closure.
- The main agent owns the integration, the final validation and the commit boundaries.
- This skill does not turn a documentation audit or unrelated fixes into a task group.

## 1. Select and bound

1. Choose a small, high-value group of tasks that share a behavior, an invariant or a dependency.
2. Revalidate each task against the current code.
3. Bound each task under the [task rules](../../../tasks/README.md#bound-a-task). Keep one authoritative boundary for each task in `tasks/open/<ID>.md`.
4. Record the intended commit boundaries and their order before implementation.

Grouping does not expand authorization, and it does not settle an unresolved material decision.

## 2. Delegate by ownership

- Use one implementation agent for coupled tasks that edit the same code.
- Separate independent work only if the edit boundaries are compatible.
- Start each implementation agent through the harness's own subagent mechanism, without the main agent's conversation, unless the user selects otherwise.
- The fixed reviewer model and the Codex CLI dispatch belong only to the [reviewer](../adversarial-review/SKILL.md#reviewer-session).
- Supply the repository path, the path of the boundary, the edit ownership, the relevant documentation and the unrelated work to preserve.
- State who is responsible for the validation and for the evidence.
- Do not repeat the contracts that the boundary states.
- Implement foundations before the behavior that depends on them. Run focused checks between stages.

## 3. Integrate and freeze

1. The implementation agents report that their repository edits are complete, and they name the remaining evidence work that needs only scratch copies.
2. Resolve the integration issues.
3. Compare the work with the plan from step 1, and record each deviation.
4. Confirm the commit boundaries. [Review Scope](../adversarial-review/SKILL.md#review-scope) says when tasks may share one review.
5. Freeze the candidate and run the final gates. Isolated evidence work MAY run at the same time.

These rules also apply:

- Freeze, validate and review each independent candidate in the order from step 1.
- An intermediate state needs full gates and its own review only if it is committed independently.

## 4. Review and resolve

- Apply the [review procedure](../adversarial-review/SKILL.md#procedure) to every accepted boundary, acceptance criterion, retained behavior and integration path.
- [Review Scope](../adversarial-review/SKILL.md#review-scope) says what the review covers, and when tasks that were already reviewed need a further review.

## 5. Close

1. Verify the done criteria of each task.
2. Close the tasks under the [task rules](../../../tasks/README.md#close-a-task) before the commit.

## 6. Gap review

After the group's commits, the main agent reviews the committed range itself. This step does not use the adversarial review skill.

1. Check the range against the accepted boundaries, contracts, decisions, completion records, documentation and conventions.
2. Look especially for risks that only the combined changes create.
3. Report each gap with its location, evidence and impact. Separate defects from hypotheses and from nits.
4. Report the gaps before you fix them, unless the user asked for fixes. A gap does not expand authorization.
5. Fix each gap under the normal rules for boundaries, gates, review and completion records.
6. Repeat until no gap remains, or until each gap has a recorded disposition.

## 7. Report and reflect

- Report the changes, checks, verdicts, gap-review outcome, deferrals and limitations. Link the completion records.
- End the handoff with the governance friction that you observed and concrete improvements. Separate friction from your own execution mistakes.
- If no friction arose, say so briefly.
- Treat this feedback as a proposal. [Governance Files](../../../AGENTS.md#governance-files) says where a lesson goes and who approves a governance edit.
