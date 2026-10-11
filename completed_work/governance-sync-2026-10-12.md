# Governance sync — 2026-10-12

## Origin and boundary

The user requested syncing project governance files and skills from a reference Python project into ClipboardTTS and explaining local deviations. The source was inspected at revision `e3ad2a62bb46d095ba192b255fa72dfee3e06bd5`; ClipboardTTS started clean at `dfe404a5a2b8987641152b88fdb73277312ab1eb`. The reference project's name and links are omitted at the user's request.

The boundary is governance prose and skill instructions: AGENTS, TODO maintenance, adversarial review and its supporting references, and grouped-task execution for Codex and Claude. Dependencies are the existing README procedures and local ownership/authorization safeguards. Application behavior, build/test configuration, executable tooling, product documentation, accepted product decisions, backlog findings and historical completion records are outside scope. Done criteria are coherent adapted instructions, valid local references and skill metadata, a reviewed diff, and an explicit deviation record. Application gates and formal adversarial review are exempt for this documentation-only change under both the original and updated AGENTS.

## Imported workflow

AGENTS now links grouped-task execution and completion-record ownership, explains document conflicts and enforced permissions, and supports bounded delegation and cohesive integration review. TODO maintenance now names compatibility surfaces, supports one authoritative boundary in a retained review record, and requires complete durable closure evidence. Existing decisions, backlog entries and historical evidence are preserved.

The adversarial-review skill now includes review scope, a persistent independent reviewer, compact evidence records, stronger integrity inventories, explicit scratch execution containment, and evidence retention. The default reviewer changes from `gpt-6-sol` to upstream's `gpt-6.1-sol`, with high reasoning effort. Upstream's continued reviewer session supersedes the old instruction to start every review in a new session: it retains independent review context and outstanding findings across follow-ups. Each task/group still starts without the main agent's conversation, and fixes or rollback still require full gates and a fresh assessment/verdict. The previously accepted Claude CLI bypass dispatch remains subject to enforced platform permissions.

The grouped-task skill is copied unchanged into `.agents/skills/grouped-task-execution/SKILL.md` and exposed to Claude through `.claude/skills/grouped-task-execution`. The existing Claude adversarial-review symlink and identical Claude model/effort settings require no change.

## Local deviations

| Area | ClipboardTTS adaptation and reason |
|---|---|
| Document ownership | Keep README for architecture/operations, USER_STORIES for product behavior and TODO for accepted decisions. Do not import DESIGN or move accepted decisions as part of this sync. |
| Execution platform | Replace mandatory Docker/devcontainer execution with macOS and the existing Xcode toolchain. Do not copy Docker, Compose, devcontainer, dependency, lint or coverage configuration from the Python service. |
| Language and contracts | Retain Swift `///` guidance, `@testable import ClipboardTTSApp`, and Swift/AppKit/SwiftUI review concerns. Adapt compatibility surfaces to menu, Settings, Services, clipboard, persistence, provider requests and audio sessions. |
| Test ownership | Retain the protections for real preferences, Keychain, pasteboard, external services, hosted startup and asynchronous quiescence. Replace Python import/pytest provenance with scratch source, generated project and executed app/test-bundle provenance. |
| Mutation requirements | Retain revert, plausible-regression and over-restriction evidence for every changed invariant where applicable, rather than adopting upstream's high-impact-only requirement. Keep README's `run-mutants.py` procedure and its user-approved-isolation requirement for mutants that weaken test isolation. |
| Validation | Keep the passing baseline at HEAD, same-revision baseline reuse, coverage gate, strict SwiftLint and strict-concurrency Debug build with signing disabled. Do not adopt Ruff/mypy, Python statement/branch thresholds, cross-revision baseline reuse, or cosmetic gate/verdict reuse after fixes. |
| Finding dispositions | Keep user disposition of all surfaced Non-blocking findings and unfixed Nits, rather than upstream's autonomous deferral option. Preserve reviewer-owned classification and the escalation after two unresolved assessments. |
| Snapshot implementation | Do not import executable `snapshot.py` or its Python tests. Specify its relevant inventory contract in the review skill: HEAD, complete index, NUL-safe status/path handling, hashes/modes, symlink targets, tracked deletions/type changes, untracked scope, owned processes and fail-closed comparisons. This extends the existing manual workflow without adding executable tooling to a governance-only change. It is an instruction contract, not a tested snapshot implementation. |
| Project procedures | Retain generated-Xcode-project handling and existing executable coverage policy. Omit Redis, YouTube/Azure, media-library/browser-profile and Whisper-specific rules and upstream product/backlog records. |
| Claude skill discovery | Use a directory symlink for the new grouped-task skill, matching the existing local adversarial-review exposure, instead of upstream's duplicated grouped-task file. Both harnesses read one canonical copy. |
| Commit attribution | Retain the existing `<Claude/Codex/Antigravity/...>` prefix choices. |

These adaptations assume “sync” means importing applicable governance while preserving ClipboardTTS's established platform and stronger safeguards. The repository's existing document owners, test rules and operating procedures support that assumption; no product behavior or accepted backlog decision changes.

## Validation and limitations

Compared the pinned upstream governance/skill inventory with the local tracked files; read local AGENTS, relevant TODO/README procedures, the mutation runner contract, and Claude discovery/settings. Checked the final diff, local Markdown destinations and heading anchors, the grouped-task and adversarial-review discovery symlinks, and preservation of TODO content from Evidence provenance onward.

The skill-creator `quick_validate.py` passed for both canonical skills and the Claude grouped-task copy. The first attempts failed because the host Python lacked PyYAML; reruns used an isolated temporary virtual environment with PyYAML, without changing project dependencies. Its pip upgrade notice was tooling advice, not a validation failure. `git diff --check` passed. A separate read-only agent compared the source policies and checked the adapted documentation; this was documentation verification, not a formal application review verdict. Its two suggestions were handled: use a shared Claude skill symlink, and remove the copied version-specific empirical claim about CLI stdin behavior while retaining the explicit closed-stdin command.

No application tests, coverage gate, app build, mutations or live-provider checks were run because no code, test or executable configuration changed. New reviewer dispatch commands and the manual snapshot procedure were inspected, not exercised as an application review. Temporary source checkout, edit script and validation environment were removed after verification; this record retains the source revision and results.
