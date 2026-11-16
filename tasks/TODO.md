# TODO — Open work

This file holds the recommended order, the constraints that several tasks share, and the index of open tasks. [README.md](README.md) owns how tasks are recorded, bounded and closed.

- Read [AGENTS.md](../AGENTS.md), [DESIGN.md](../DESIGN.md) and the relevant operating instructions in the [project README](../README.md) before you accept an implementation task.
- A recorded task is not permission to combine unrelated changes or to redesign the app.
- For a group of related tasks, use the [grouped task execution skill](../.agents/skills/grouped-task-execution/SKILL.md).

Until 2026-11-16, one plan file held all of this content. Its other parts moved as follows:

- The accepted decisions and the constraints that remain in force are in [DESIGN.md](../DESIGN.md#accepted-decisions).
- The provenance of the review findings, the history of the task IDs and the legacy task mapping are in [project-reviews.md](../project-reviews.md).
- The outcome of each closed task is the Outcome line of its record in [closed/](closed/).

## Recommended order

No Blocking finding is open, and no Nit is open. No open task is bounded for implementation. The open tasks do not depend on each other.

- NB54 (menu accessibility) and NB60 (Settings picker accessibility) may share one boundary and one manual VoiceOver session.
- NB55 (seek cost) starts with a measurement at `HEAD`. The measurement decides whether a change is needed.
- NB51 (silent realtime responses) waits for the user's decision on its evidence. More live trials need the user's authorization.
- S10 (verifier size) is a proposal. It waits for the user's decision on how much tooling robustness to keep.

## Shared constraints

**Integration.**

- Review an integrated change against the accepted decisions and the current DESIGN and README.
- Supplement an integration change with checks across entry points: playback, cancellation, switching of provider and format, failure and recovery, and settings isolation.
- Inspect the warnings and the complete gated population.
- Static analysis gives additional evidence. So does Thread Sanitizer, where it is relevant and supported. Clean output is not proof of race freedom.

**Manual checks.**

- The user runs the [manual smoke checks](../README.md#manual-smoke-checks) of the symbols that the coverage gate excludes (D17). No agent has performed them.
- Physical switching of audio devices remains unverified.
- A check against a live provider needs the user's authorization, under the [safety rules](../AGENTS.md).
- Record evidence at its actual revision.

## Open tasks

- [NB51](open/NB51.md) — Non-blocking, needs the user's decision. `gpt-realtime-2.1-mini` intermittently goes silent mid-response while reporting success.
- [NB54](open/NB54.md) — Non-blocking. Give menu controls explicit accessible purposes and values.
- [NB55](open/NB55.md) — Non-blocking. Dragging the position slider re-encodes the remaining buffer on the main thread.
- [NB60](open/NB60.md) — Non-blocking. Settings' suggestion pickers have no accessible name.
- [S10](open/S10.md) — Non-blocking proposal, needs the user's decision. Review how much code verifies the tooling.
