# NB2 — A trailing partial PCM byte after complete frames

Moved from [TODO.md](../TODO.md) on 2026-09-24 without rewording; the text below is the disposition as TODO recorded it, and its evidence is tied to the revisions it names.

**NB2 — Fixed.** Completion now treats a response as playable when it contains at least one complete 16-bit PCM frame, so a final orphaned byte no longer turns the frames the player schedules into a no-audio failure. Empty and single-byte OpenAI, Custom, and Gemini responses still fail; Gemini continues delivering only its complete frames, and the player continues scheduling only complete frames. README owns the current behavior.
