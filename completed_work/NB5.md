# NB5 — The ephemeral production session policy

Moved from [TODO.md](../TODO.md) on 2026-09-24 without rewording; the text below is the disposition as TODO recorded it, and its evidence is tied to the revisions it names.

**NB5 — Fixed.** Production sessions now start from one explicit ephemeral policy with no URL cache, cookie storage, or credential storage, and use `.reloadIgnoringLocalCacheData`; test routing layers its protocol onto that policy without changing its scope teardown. The focused regression inspects the effective default session and sends a request through that mock-routed policy. Reverting the default, restoring the cache or stores, selecting `.reloadIgnoringLocalAndRemoteCacheData`, or dropping the policy supplied to test routing each fail in an isolated scratch checkout. README owns the current policy.
