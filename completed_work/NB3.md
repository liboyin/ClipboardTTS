# NB3 — Multipart Gemini audio

Moved from [TODO.md](../TODO.md) on 2026-09-24 without rewording; the text below is the disposition as TODO recorded it, and its evidence is tied to the revisions it names.

**NB3 — Fixed.** The selected Gemini candidate now validates every `inlineData` part before queuing any of its PCM, then contributes those parts in source order through the request-owned frame accumulator. A valid multipart event therefore preserves split Int16 frames, while a malformed later part still takes the established fatal revocation path instead of silently succeeding. Candidate selection and metadata-only events are unchanged. README owns the current behavior.
