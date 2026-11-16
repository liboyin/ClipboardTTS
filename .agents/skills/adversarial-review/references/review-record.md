# Review Record

Use this template for the working record of a [review](../SKILL.md#procedure). [Evidence Retention](../SKILL.md#evidence-retention) says where the record lives and what it keeps.

- Update the record for each follow-up candidate.
- Record decisions and results, not a transcript.
- Refer to supporting artifacts. Do not copy their contents.
- Omit a section that does not apply.
- Keep a failure excerpt only if it establishes the behavioral outcome or explains a finding.
- At closure, the main agent preserves the essential contents in the completion record, under the [task rules](../../../../tasks/README.md#close-a-task).

## Fields

- **Boundary:** a link to the accepted boundary, as the [task rules](../../../../tasks/README.md#two-kinds-of-work) describe. Distinguish the existing contracts of callers from new requirements for runtime validation.
- **Target:** the starting revision and the candidate revision or range, the in-scope paths and the uncommitted inputs. For a follow-up, add the earlier target.
- **Reviewer:** the session ID, the model and the effort. If the reviewer was replaced, add the reason and the transferred findings.
- **Checks:** the commands, the results, a summary of the relevant environment without secrets, and the reason for the choice of baseline.
- **Coverage decision:** for a group, whether a further group review is needed, and why.
- **Findings:** the reviewer's report and verdict, the main agent's validation and dispositions, and the user's decisions. For each deferral, add the reason and the revisit trigger.
- **Integrity and cleanup:** the result of the snapshot comparison, the cleanup performed, and the location and lifetime of each retained artifact.

## Mutation evidence

Fill this section if mutation evidence was required or performed.

- Name the primary producer, and list what the reviewer added.
- Record once the shared identity of the candidate, the bootstrap, the isolation and the execution settings. Add the differences of single cases where needed.
- For each protected invariant, give or link these items:
  - The tested candidate, and the provenance of the build and the test bundle.
  - The mutant and the relevant test.
  - The exact command with the runner settings, and the behavioral failure.
- For uncommitted inputs, the tested candidate is the revision plus a patch.
- Explain why the mutant probes the risk. Cover the categories that [AGENTS.md](../../../../AGENTS.md#tests) requires, and explain each category that does not apply.
- For removed or weakened coverage, name the retained test that still rejects the broken behavior.
- Report invalid runs separately from behavioral failures.
- If the candidate, a test or a probe changed, state which evidence the change invalidates and why the other cases still apply.
- The reviewer records the evidence checks and the reason for each rerun or added case. The reviewer's report does not repeat the producer's evidence.

## Evidence reuse

Fill this section only if results were reused. [Evidence reuse](evidence-reuse.md#what-to-record) lists what to record.
