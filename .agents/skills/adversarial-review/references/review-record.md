# Review Record

Use this compact template for the [review procedure](../SKILL.md#procedure). Keep one record per task or cohesive group, updating it for follow-up candidates; it MAY contain the reviewer report and main-agent addendum. Reference supporting artifacts instead of duplicating their contents, and omit conditional sections when they do not apply. Record decisions and results, not a chronological transcript. Retain failure excerpts only when they establish the behavioral outcome or explain a finding; full passing logs are unnecessary.

This is the working evidence record. When closing TODO tasks, the main agent preserves its essential contents under [TODO's completion-record procedure](../../../../TODO.md#maintaining-this-plan), linking shared evidence when several tasks used one review record.

- **Boundary:** intent, dependencies, implementation direction, affected compatibility surface, non-goals, validation, acceptance and done criteria for each task; write the accepted boundary here or link its sole owning location. State shared group constraints once and give each task distinct acceptance criteria. Distinguish existing caller contracts from new runtime validation requirements.
- **Target:** starting and candidate revisions/range, in-scope paths and uncommitted inputs; full or follow-up scope and prior target when applicable.
- **Reviewer:** agent/session ID, model/effort; replacement reason and transferred findings when applicable.
- **Checks:** commands, results, relevant non-secret environment summary, and baseline selection rationale. Include the integration-coverage decision when deciding whether a further group review is needed.
- **Findings:** reviewer report and verdict, main-agent validation and dispositions, reasons/revisit triggers for deferrals, and any user decisions.
- **Integrity and cleanup:** snapshot comparison outcome, cleanup performed, retained artifact locations and lifetime limitations. Summarize a successful comparison once; detailed temporary snapshots need retention only for reuse or investigation.

## Mutation evidence, when required or performed

Name the primary evidence producer and any reviewer additions. Record shared candidate identity, bootstrap, isolation and execution settings once, with per-case differences where needed. For each protected invariant, provide or reference the tested candidate (revision plus patch or equivalent for uncommitted inputs), build/test-bundle provenance, mutant definition, relevant test, exact command and runner settings, and behavioral failure. Explain why the chosen mutation probes the risk; cover the locally required revert, plausible-regression and over-restriction categories where applicable, explaining any inapplicability. Multiple assertions may share evidence. For removed/weakened coverage, identify the retained test that still rejects the broken behavior. Report invalid runs separately from behavioral failures. Identify which evidence a candidate, test or probe change invalidates and why unchanged cases remain applicable. The reviewer records the evidence checks and any reason for rerunning or extending a case; do not duplicate the producer's evidence in the reviewer report.

## Additional provenance for evidence reuse

Record the original tested revision, commands/results and evidence location. Compare relevant implementation, tests, call-path dependencies, configuration, file modes, symlink targets and environment. Include in-scope untracked inputs; never read ignored content or secrets to construct provenance. Record tested-input fingerprints and the non-secret environment evidence establishing equivalence, including tool/dependency versions where relevant. Changed or unknown relevant inputs invalidate reuse; rerun the affected checks instead. Revision-sensitive checks also require a new run when metadata changes.

AGENTS and the skill's Review Scope limit reuse: baselines require the same unchanged revision and relevant environment, and fixes or rollback require full gates and a fresh reviewer verdict. This template supplies provenance fields, not permission to relax those requirements.

Keep referenced evidence outside disposable scratch; detailed logs may be discarded once definitions, outcomes and provenance are sufficient.
