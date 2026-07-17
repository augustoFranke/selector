# Context

Domain glossary for Selector. Use these terms exactly in code, plans, ADRs, and review.

## Terms

### Ask Session

The single live conversation draft. Owns the **Selection Stack**, any other **Context Attachments**, and one in-flight or last-completed model answer.

Two phases:
- *idle* — no attachments, no answer, **Chat Panel** hidden.
- *active* — at least one attachment, **Chat Panel** visible.

Owns the routing rule: a fresh **Capture** while idle signals the **Selection Overlay** to appear; a fresh Capture while active appends to the **Selection Stack**.

### Selection

One captured chunk of user-selected text from another macOS app. Carries: text, source app, **Capture** method (AX or pasteboard), capture timestamp.

Selections are *Context Attachments*.

### Selection Stack

The ordered list of **Selection**s on the active **Ask Session**. New captures append while the session is active. Duplicates allowed.

### Context Attachment

Anything attached to an **Ask Session** that the model sees. V1 kinds:
- **Selection**
- **Link Context** — a URL detected inside a Selection and the fetched page text.
- **Screenshot** — a cursor-region screen capture.

Future kinds (PLAN.md): URL Summary, Recent Chat.

Each attachment has a stable id and renders as a **Source Chip**.

### Chat Panel

The anchored floating UI surface for an active **Ask Session**. Renders the Source Chips, the input field, the response area, the screenshot button, and the speak button.

A pure presenter — does not own attachment, stream, or answer state. Reads everything from the Ask Session.

### Source Chip

The visible UI token for one **Context Attachment** inside the **Chat Panel**. Has a kind-specific badge, a body, an optional thumbnail, and a remove control.

### Selection Overlay

The compact "Ask…" bubble shown next to a fresh **Selection** when the **Ask Session** is *idle*. Clicking it activates the session with that selection as the seed.

### Snapshot

Capture-time payload carrying a **Selection** plus its on-screen bounds (when AX provides them) and a fallback cursor point. Used by the **Selection Overlay** and **Chat Panel** to position themselves.

### Capture

The act of reading the user's current selection.

Strategy: AX-first (`kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`, `kAXBoundsForRangeParameterizedAttribute`), with a careful pasteboard fallback gated to deliberate **Trigger** gestures and a restore-after step. Skips secure fields and Selector's own UI.

### Model Provider

A streaming chat-completion backend behind the `ModelProvider` protocol (plus `SpeechProvider` for TTS). The **Ask Session** talks only to the protocol; Groq is the first conformer. Keys resolve via `SecretsStore`: login Keychain first, environment variable fallback.

### Trigger

A user gesture that schedules a Capture sample: *drag*, *multi-click*, *shift-click*, *shift-navigation*, *cmd-a*. No capture on plain typing, scroll, app switch, or single click.
