# Polish Follow-Ups

Tracks prototype-grade behaviors that should be revisited before the tool is considered polished. Items here are deliberately out of scope for the current iteration of PLAN1.md but should not be lost.

## Prototype 4 — URL Fetch / Web Context

### 1. Send should wait for pending fetches
- **Current**: Clicking Send while a `LINK · FETCHING…` chip is in flight sends the prompt with a "still fetching" note in the WebContext block.
- **Polished**: Send should briefly block on any pending fetch — show "Waiting for page…" in the response area, then auto-start the stream once the fetch resolves (or times out, suggested 5s). User should never need to think about fetch timing.
- **Files**: `ChatPanel.swift` (`sendTapped`, `buildMessages`), `LinkContext.swift`.

### 2. Summarize fetched pages instead of raw truncation
- **Current**: 8 KB body cap with hard truncation mid-sentence; raw page text (incl. nav, cookie banners, footer noise after `NSAttributedString` HTML parsing) is sent to the chat model.
- **Polished**: Per PLAN.md, run a first Groq call to summarize each fetched page, then attach those summaries as `WebContext` blocks to the main chat request. Avoids mid-sentence cuts and reduces token bloat.
- **Files**: `LinkContext.swift` (cap + storage), `GroqClient.swift` (one-shot non-streaming call helper), `ChatPanel.swift` (orchestration).

### 3. Readability extraction
- **Current**: `NSAttributedString` HTML→text keeps boilerplate (cookie banners, nav, sidebars).
- **Polished**: Apply a Readability-style content selector (main article / `<article>` / largest text block) before summarization so the summarizer isn't fed cookie banners.
- **Files**: `LinkContext.swift` (`extractReadableText`).

### 4. UX for fetch failure
- **Current**: Chip shows `LINK · FAILED` with reason in the chip label; prompt still goes through with a note.
- **Polished**: Inline retry affordance on the chip; differentiate transient (network) vs. terminal (404/410) errors.
- **Files**: `LinkContext.swift`, `ChatPanel.swift` (`makeLinkChipView`).
