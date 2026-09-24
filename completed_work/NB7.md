# NB7 — Typed provider identity

Moved from [TODO.md](../TODO.md) on 2026-09-24 without rewording; the text below is the disposition as TODO recorded it, and its evidence is tied to the revisions it names.

**NB7 — Fixed.** `APIKeyProvider` now normalizes persisted and direct strings before network state stores them, then request snapshots, active requests, metadata tokens, and suggestion ownership carry that typed identity. Only `.gemini` selects native Gemini request and catalog behavior; a Custom endpoint containing Google's hostname remains OpenAI-compatible for speech and model discovery. Provider-and-endpoint metadata freshness guards are unchanged. README owns the current behavior.
