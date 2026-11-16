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

No Blocking finding is open, and no Nit is open. No open task is bounded for implementation.

- NB51 (silent realtime responses) waits for the user's decision on its evidence. More live trials need the user's authorization.
- S10 (verifier size) is a proposal. It waits for the user's decision on how much tooling robustness to keep.
- T2 to T8 come from the [2026-11-17 review](../project-reviews.md#full-project-review--2026-11-17). T2, T3, T4, T7 and T8 each wait for a decision of the user.
- T3 (missing key), T2 (empty clipboard) and T4 (failure messages) change what the user sees first. Do them before the others. T3 and T4 share one set of messages.
- T6 (Gemini endpoint) and T5 (stray whitespace) change the same endpoint builder. Do T6 first. Neither waits for a decision.
- T7 (one gate command) and T8 (hardened runtime) depend on no other task.

## Shared constraints

**Integration.**

- Supplement an integration change with checks across entry points: playback, cancellation, switching of provider and format, failure and recovery, and settings isolation.
- Static analysis gives additional evidence. So does Thread Sanitizer, where it is relevant and supported. Clean output is not proof of race freedom.

**Manual checks.**

- The user runs the [manual smoke checks](../README.md#manual-smoke-checks) of the symbols that the coverage gate excludes (D17). No agent has performed them.
- Physical switching of audio devices remains unverified.

## Open tasks

- [NB51](open/NB51.md) — Non-blocking, needs the user's decision. `gpt-realtime-2.1-mini` intermittently goes silent mid-response while reporting success.
- [S10](open/S10.md) — Non-blocking proposal, needs the user's decision. Review how much code verifies the tooling.
- [T2](open/T2.md) — Non-blocking, needs the user's decision. Speak Copied Text does nothing visible when the clipboard holds no text.
- [T3](open/T3.md) — Non-blocking, needs the user's acceptance. A request without a saved key still goes to OpenAI or Gemini.
- [T4](open/T4.md) — Non-blocking, needs the user's decision. Three provider failures give a message that the user cannot act on.
- [T5](open/T5.md) — Non-blocking. Stray whitespace around an endpoint, model, voice or key reaches the provider.
- [T6](open/T6.md) — Non-blocking simplification. Gemini's endpoint is fixed in DESIGN but caller-supplied in the request path.
- [T7](open/T7.md) — Non-blocking proposal, needs the user's decision. One command runs both gates from a clean state.
- [T8](open/T8.md) — Non-blocking proposal, needs the user's decision. The packaged app is signed without the hardened runtime.
