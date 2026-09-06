This file owns the working principles for this repository. All agents MUST follow it and explicit user instructions. CAPITALIZED requirement words have the meanings defined by BCP 14 (RFC 2119 and RFC 8174).

# Document Boundaries

- **AGENTS.md:** concise working principles and required standards.
- **[Adversarial review skill](.agents/skills/adversarial-review/SKILL.md):** how to conduct review, including dispatch, snapshots, investigation, triage, and reporting.
- **[TODO.md](TODO.md):** future work, accepted decisions, dependencies, execution boundaries, and its own maintenance rules.
- **[README.md](README.md):** current architecture, design assumptions, and operating procedures.
- **[USER_STORIES.md](USER_STORIES.md):** product requirements and user-visible behavior.

Link to the owning document instead of duplicating its procedure. Operational instructions do not override the safety and ownership principles here.

# Scope and Decisions

- Read relevant code and documentation and inspect repository status before editing. Preserve unrelated work.
- Each change MUST have a boundary: intent, dependencies, non-goals, validation strategy, and done criteria. Revalidate written tasks against the affected code; do not implement them mechanically or broaden their material scope unilaterally.
- State assumptions. Confirm unresolved choices that materially affect scope, architecture, dataflow, correctness, security, or user-visible behavior before dependent work; continue independent work where possible.
- Accepted decisions and user authorization persist. Do not ask again about settled choices. Document superseding decisions and their reasoning before committing the affected change.
- Non-material assumptions MAY be made when repository evidence supports them and they preserve the requested outcome. Name the assumption, evidence, and effect in the handoff.
- Isolated subtasks with small, bounded results SHOULD use subagents. The main agent remains accountable for integration and verification.

# Design and Documentation

- Prefer the simplest cohesive implementation within the assigned scope. Give each function, type, and module a clear responsibility; prefer pure logic, isolated side effects, and minimal mocking over unnecessary abstractions.
- Respect lint limits without splitting cohesive code solely for length. A narrow exception MUST explain the responsibility or invariant it preserves; avoid blanket disables.
- Before removing a layer, identify all unique behavior it carries, including copy, errors, ordering, timing, diagnostics, and UI/accessibility behavior. Give retained behavior an explicit owner and preserve its verification.
- Verify changing language, framework, library, and service assumptions empirically or against version-appropriate documentation.
- Update documentation when the change makes it stale. Distinguish current behavior, accepted future decisions, proposals, and unverified hypotheses.
- Verify current empirical claims before recording them. Historical evidence MUST identify its revision, relevant environment, provenance, and limitations; it does not certify current validation.
- Use Swift documentation comments (`///`) for non-obvious purposes, contracts, side effects, or constraints of new or changed non-test declarations. Test names MUST describe the protected behavior; comments should explain non-obvious reasons or trade-offs.

# Test Guidelines

- Tests MUST protect behavior or an invariant and fail when it breaks. Prefer controlled inputs, schedulers, and explicit completion over elapsed-time waits.
- For each added or changed invariant, mutation evidence MUST cover a revert, a plausible regression, and an over-restriction where applicable. Each applicable mutant MUST fail a relevant test in an isolated scratch copy. Explain inapplicable categories; evidence belongs to the invariant and MAY be shared across assertions.
- Before removing or weakening coverage, demonstrate that a mutant breaking the protected property still fails another test. A surviving mutant requires investigation, not automatic removal of coverage.
- XCTest cases MUST use `@testable import ClipboardTTSApp`. Automated tests MUST NOT access external services, `NSPasteboard.general`, the developer's Keychain, or real developer preferences, even temporarily.
- Use test-owned state throughout hosted startup, managers, and SwiftUI persistence. Snapshot/restore is permitted only for owned state. Do not seed real preferences to prove non-access or leave seeded disk-backed suites behind. A scratch checkout alone does not isolate macOS state.
- Shared asynchronous resources and process-global doubles MUST have per-test ownership, synchronized access, cancellation/invalidation, quiescence, and local accounting for late work. These guarantees MUST hold after timeouts and failures; fulfilment alone is not quiescence.
- `check-coverage.sh` owns the executable coverage policy; planned changes belong in TODO. Exclusions MUST have a narrow platform UI/integration rationale and an end-to-end smoke check validated when the exclusion changes. Directory location alone does not justify excluding application logic; record unperformed manual checks as limitations.

# Validation and Review

- Establish a passing baseline at HEAD before implementation. Reuse baseline evidence only for the same unchanged revision and relevant environment, with provenance. Run tests only in an environment satisfying the ownership rules above. A failing baseline SHOULD be fixed in a separate, authorized change first.
- Use focused checks during development. The final code, test, or configuration candidate MUST pass the coverage gate (`./check-coverage.sh`), strict SwiftLint, and a Debug app build with complete strict concurrency and signing disabled. Inspect per-file coverage and warnings; resolve new source warnings and explain accepted tooling warnings.
- Every non-trivial code, test, or configuration change MUST pass the review skill's complete procedure before commit. A change is non-trivial if it could affect runtime behavior, test guarantees, build/configuration output, security, concurrency, state/data flow, or user-visible behavior. When uncertain, run the review.
- The reviewer owns classification and verdict; the main agent owns independent investigation, implementation, and required user dispositions. After fixes or rollback, repeat full gates and obtain a fresh review. Finish only when no Blocking finding remains and every surfaced finding has its required disposition. Never silently discard or reclassify a finding.
- Documentation-only changes and read-only assessments are exempt from application gates and formal adversarial review. Verify their claims, references, completeness, and diff instead. Report what was actually checked.
- Verify success with checks that distinguish failure. Explain non-zero exits, verify absence directly, and verify rollback against the recorded pre-change state.
- Keep the generated Xcode project consistent with its configuration and source/test inputs, following README's regeneration procedure. Do not commit generated project files.
- Clean up processes and artifacts you create. Identify owned PIDs before using `kill`; NEVER use `pkill -f`. Re-check this file and the task boundary before finishing.

# Version Control

- Keep functionally independent changes in separate, self-contained commits once implemented, validated, and documented. Honor requests to leave drafts uncommitted.
- Stage explicit paths, inspect the staged diff and repository status immediately before committing, and exclude unrelated work. NEVER use `git add -A` or `git commit -a`.
- Commit messages MUST start with `<Claude/Codex/Antigravity/...>: <one-line summary>`, followed by a blank line and explanatory paragraphs. Do not add a `Co-Authored-By` line.
