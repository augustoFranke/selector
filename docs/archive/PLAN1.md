# Selector Prototype Research And Iteration Plan

## Summary

Selector is feasible as a native macOS app, but not through a single universal selection API. The product should be built as layered prototypes: first make selection capture reliable, then add the anchored mini chat, automatic multi-selection stacking, OpenRouter-backed responses, URL fetching, screenshot context, and TTS.

Save this plan as `docs/selector-prototype-plan.md` in the next implementation turn.

Research basis:
[AX selected text](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [AX bounds for range](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute), [AXObserver](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [NSDataDetector](https://developer.apple.com/documentation/foundation/nsdatadetector), [Apple speech synthesis](https://developer.apple.com/documentation/avfaudio/speech-synthesis), [Apple Writing Tools](https://support.apple.com/en-us/121582), [Groq Cloud docs](https://console.groq.com/docs/overview), [Groq chat completions](https://console.groq.com/docs/api-reference#chat-create), [Groq streaming](https://console.groq.com/docs/text-chat#streaming-a-chat-completion), [Groq supported models](https://console.groq.com/docs/models), [Groq TTS](https://console.groq.com/docs/text-to-speech), [Groq vision](https://console.groq.com/docs/vision).

## Key Design Decisions

- Interaction surface: anchored floating mini chat beside the selected text.
- Multi-selection behavior: while the mini chat is open, new selections from any app automatically append to the same input stack.
- First model API: Groq Cloud (free tier), supplied by `GROQ_API_KEY`.
- Default chat model: `llama-3.3-70b-versatile`; override via `SELECTOR_GROQ_MODEL`.
- First API run mode: launch from terminal so the app receives the env var; later replace with Keychain UI.
- Link behavior: if the selected chunk is clearly a URL, fetch it automatically and show a source chip.
- Screenshot behavior: manual `Add screenshot` button; request Screen Recording only when clicked. Send images to a Groq vision-capable model (e.g. `meta-llama/llama-4-scout-17b-16e-instruct`) instead of the default chat model when an image attachment is present.
- TTS: prefer Groq TTS (e.g. `playai-tts`) when `GROQ_API_KEY` is available; fall back to native `AVSpeechSynthesizer` otherwise.

## Prototype Iterations

### Prototype 0: Stabilize Selection Capture

- Keep current AX-first approach: focused element, `kAXSelectedTextAttribute`, `kAXSelectedTextRangeAttribute`, and `kAXBoundsForRangeParameterizedAttribute`.
- Keep event tap only as a trigger: mouse drag, double-click, Shift-navigation, Cmd-A.
- Restore a controlled pasteboard fallback only if needed for web/non-editable selections, but never on normal typing.
- Add a small internal debug overlay or menu item showing trust state, last selected text length, source app, capture method, and last failure.
- Acceptance: Notes, Codex, Claude, and at least one browser page show the bubble after selection; normal typing and normal clicking do not.

### Prototype 1: Anchored Mini Chat Shell

- Replace the inert bubble action with an anchored `NSPanel` chat.
- Initial bubble remains compact like the ChatGPT/Codex/Claude screenshots; clicking it opens the larger panel.
- Panel contains selected text chip, input field, send button, close button, and status area.
- Source text is read-only in the panel; no “replace source text” behavior yet.
- Acceptance: selecting text opens a bubble; clicking opens a stable panel near the selection without stealing focus unexpectedly.

### Prototype 2: Automatic Selection Stack

- Introduce `SelectionContext`: id, text, source app, timestamp, bounds, capture method, detected URLs.
- Introduce `SelectionStack`: ordered list of contexts for the current chat draft.
- While panel is open, every valid new selection appends automatically.
- UI shows stacked chips with app name and short preview; user can remove individual chips or clear all.
- Duplicate selections are allowed in v1 and shown as separate chips.
- Acceptance: select text in one app, open panel, select text in another app, and both appear in one input stack.

### Prototype 3: Groq Streaming Chat

- Add `GroqClient` using `URLSession` against `https://api.groq.com/openai/v1/chat/completions` (OpenAI-compatible schema).
- Read `GROQ_API_KEY`; optionally read `SELECTOR_GROQ_MODEL`, defaulting to `llama-3.3-70b-versatile`.
- Add `make run-api` that launches the binary with the current shell environment.
- Use SSE streaming (`stream: true`) and update the panel incrementally as `choices[].delta.content` chunks arrive.
- Prompt shape: system instruction, stacked selections as labeled context blocks, user instruction.
- Respect Groq free-tier rate limits: surface 429 responses with a clear in-panel retry hint.
- Acceptance: with `GROQ_API_KEY` set, user can ask a question about one or more selections and see streamed output from llama-3.3-70b-versatile.

### Prototype 4: URL Selection And Web Context

- Use `NSDataDetector` to detect URLs in selected text.
- If the selected chunk is exactly one URL or mostly one URL, auto-fetch it with `URLSession`.
- Convert HTML to readable text using system HTML-to-attributed-string parsing, cap extracted content, and attach it as a `WebContext` chip.
- If direct fetch fails, keep the URL chip and let the model answer from the URL alone. Groq does not offer a built-in web search tool, so any future fallback uses an external search API rather than a provider tool.
- Acceptance: selecting a URL appends a source chip, fetches page text, and the model can answer using that fetched content.

### Prototype 5: Manual Screenshot Context

- Add an `Add screenshot` button to the chat panel.
- On first use, request Screen Recording permission via the system flow.
- Capture a padded rectangle around the current selection bounds when available; otherwise capture a small region around the cursor.
- Attach the screenshot as an image context and send it through Groq’s vision input format (`image_url` with base64 data URL) routed to a vision-capable Groq model such as `meta-llama/llama-4-scout-17b-16e-instruct`.
- If the currently selected chat model is not vision-capable, auto-route the request with attachments to the configured vision model, or show a clear capability error if none is configured.
- Acceptance: user can add a screenshot manually and ask the model about visible UI/text in it.

### Prototype 6: TTS

- Add speaker and stop controls for assistant responses.
- Primary path: Groq TTS via `https://api.groq.com/openai/v1/audio/speech` using `playai-tts` (model id `playai-tts`), stream the returned audio into `AVAudioPlayer`/`AVPlayer`.
- Configurable voice via `SELECTOR_GROQ_TTS_VOICE`; default to a clear English voice from the Groq voice catalog.
- Fallback path: if Groq TTS fails or `GROQ_API_KEY` is missing, use `AVSpeechSynthesizer` with the system default voice.
- Speak only the latest assistant answer by default.
- Stop speech when the panel closes or the user presses stop; cancel in-flight Groq TTS request on stop.
- Acceptance: generated answers can be read aloud through Groq TTS, fall back cleanly to system TTS on failure, and can be stopped/restarted without blocking selection capture.

## Implementation Structure

- Split the current monolithic `App.swift` into services after Prototype 0:
  - `SelectionCaptureService`
  - `SelectionOverlayController`
  - `MiniChatController`
  - `SelectionStack`
  - `GroqClient` (chat + TTS)
  - `LinkContextFetcher`
  - `ScreenshotContextService`
  - `SpeechService`
- Keep the app native AppKit for now; do not introduce Electron or a web shell.
- Keep model tools app-side first. Use Groq tool calling only after the direct URL/screenshot flows are stable.
- Keep permissions explicit:
  - Accessibility and Input Monitoring for selection capture.
  - Screen Recording only for manual screenshot support.
  - Network access for Groq API and URL fetching.

## Test Plan

- Selection capture:
  - Notes editable text, browser page text, Codex/Claude chat text, PDF/text viewer where available.
  - No bubble on normal typing, normal single click, scroll, app switch, or secure/password fields.
- Anchored UI:
  - Bubble placement on single-line and multi-line selections.
  - Panel remains usable across app switches and hides on explicit close.
- Stacking:
  - Add selections from two different apps into one stack.
  - Remove one chip and clear all chips.
  - Verify no accidental stacking when panel is closed.
- Groq:
  - Missing `GROQ_API_KEY` shows a clear in-panel error.
  - Streaming response updates progressively.
  - Network failure, 429 rate limit, and model error are visible and recoverable.
- Links:
  - Plain URL selection fetches page content.
  - Non-URL text does not fetch.
  - Failed fetch preserves URL context and does not block chat.
- Screenshots:
  - Permission denied shows recovery instructions.
  - Captured image attaches and can be sent to a vision-capable model.
- TTS:
  - Speak, stop, close-panel stop, and repeated speak all work.

## Assumptions

- “0.5ms” display delay means 0.5 seconds.
- First API prototype uses `GROQ_API_KEY`, even though Finder-launched apps usually do not inherit shell env vars; `make run-api` is the supported launch path until Keychain UI lands.
- Groq free tier is rate-limited; the prototype targets interactive single-user usage and treats 429s as user-visible errors rather than auto-retrying aggressively.
- First version does not edit or replace text inside other apps.
- First version does not promise literal “any app”; secure fields, images, remote desktops, games, and custom-rendered apps may not expose selectable text.
- Screenshot support is user-triggered only to avoid surprising Screen Recording prompts.
