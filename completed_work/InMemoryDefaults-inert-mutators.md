# Accepted without change — InMemoryDefaults' inert domain mutators

Moved from [TODO.md](../TODO.md) on 2026-09-24 without rewording; the text below is the disposition as TODO recorded it, and its evidence is tied to the revisions it names.

**Accepted without change — `InMemoryDefaults`' inert domain mutators (2026-09-06).** Registration, named-domain, suite, and volatile-domain mutators succeed while doing nothing, so a future production path invoking one through an injected store would look correct under test while production mutated real state. Accepted because no production path calls them, the behavior is fail-closed for B1's isolation goal, and the lint rule refuses those calls from `Tests/`. **Revisit if** production code ever calls a domain-level `UserDefaults` member through an injected store.
