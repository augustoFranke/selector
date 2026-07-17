# Selector Grilled Prototype Plan

## Summary

Selector should become a native macOS contextual AI assistant: the user selects text in any app, clicks a small bubble, and opens an anchored **Chat Panel** that can collect multiple cross-app **Selections**, attach supporting context, and answer through OpenRouter.

Feasibility is solid but layered: macOS Accessibility can capture many selections and bounds, Quartz event taps can trigger re-checks, careful Cmd-C fallback expands coverage, `NSDataDetector` can detect links, ScreenCaptureKit can support user-drawn screenshots, and native speech synthesis can read answers aloud.

Primary references: [Apple AX selected text](https://developer.apple.com/documentation/applicationservices/kaxselectedtextattribute), [AX bounds for range](https://developer.apple.com/documentation/applicationservices/kaxboundsforrangeparameterizedattribute), [AXObserver](https://developer.apple.com/documentation/applicationservices/1460133-axobservercreate), [Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services), [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos), [NSDataDetector](https://developer.apple.com/documentation/foundation/nsdatadetector), [AVSpeechSynthesizer](https://developer.apple.com/documentation/avfaudio/speech-synthesis), [OpenRouter chat completions](https://openrouter.ai/docs/api/api-reference/chat/send-chat-completion-request), [OpenRouter streaming](https://openrouter.ai/docs/api/reference/streaming), [OpenRouter image inputs](https://openrouter.ai/docs/guides/overview/multimodal/image-understanding).

## Domain Language And Decisions

Create `CONTEXT.md` once implementation mode allows file writes.

- **Selection**: one captured chunk of user-selected text, with source app and capture metadata.
- **Selection Stack**: the ordered group of Selections feeding one Chat Panel session.
- **Context Attachment**: supporting non-selected context, such as fetched URL summaries or screenshots.
- **Chat Panel**: the anchored floating AI conversation surface.
- **Source Chip**: a visible UI token representing a Selection or Context Attachment in the Chat Panel.

Record ADRs only for the non-obvious tradeoffs:
- Persisting Recent Chats, including screenshots, for 7 days in plain local JSON.
- Keeping V1 tools app-controlled instead of exposing model-callable tools.
- Using careful pasteboard fallback to improve cross-app selection coverage.

## Prototype Iterations

1. **Selection Reliability**
   - Keep AX-first capture and selection bounds.
   - Restore careful Cmd-C fallback after deliberate selection gestures only; restore pasteboard afterward.
   - Add debug/status UI for trust state, source app, capture method, selected length, and last failure.
   - Verify no bubble on normal typing, scroll, single click, app switch, or secure/password fields.

2. **Chat Panel**
   - Replace inert bubble with a compact “Ask” bubble that opens a blank anchored Chat Panel.
   - Chat Panel shows Source Chips, focused input, send button, close button, and streaming response area.
   - Closing the panel resets the active Selection Stack.

3. **Automatic Cross-App Selection Stack**
   - While Chat Panel is open, valid selections from all apps auto-add to the active Selection Stack.
   - Exclude Selector’s own UI from capture.
   - Show a brief “Added to chat” toast near each new selection, then add a Source Chip.
   - Source Chips include app/source label, preview, and remove control.

4. **OpenRouter Chat**
   - Read config from `~/Library/Application Support/Selector/config.env`.
   - Require `OPENROUTER_API_KEY` and `SELECTOR_OPENROUTER_MODEL`; show in-panel errors if missing.
   - Use `https://openrouter.ai/api/v1/chat/completions` with streaming.
   - Send the Selection Stack and Context Attachments as labeled context blocks before the user instruction.

5. **URL Fetch And Summary**
   - Use `NSDataDetector` to detect all URLs inside each Selection.
   - Auto-fetch all detected URLs.
   - On send, summarize fetched page content first, then attach those summaries as Context Attachments to the main model request.
   - Do not use OpenRouter web search in V1.

6. **Screenshot Context**
   - Add manual `Add screenshot`.
   - User draws the region to capture.
   - Request Screen Recording only when screenshot is first used.
   - Attach screenshot as a Context Attachment and send to image-capable OpenRouter models.
   - Show a clear error if the chosen model does not support image input.

7. **TTS And Recent Chats**
   - Add speaker/stop controls for assistant answers using native `AVSpeechSynthesizer`.
   - Persist Recent Chats for 7 days, including Selections, messages, fetched summaries, and screenshot attachments.
   - Store V1 history as plain local JSON with pruning on app launch.

## Test Plan

- Selection: Notes, Codex, Claude, browser page text, and at least one app requiring pasteboard fallback.
- Non-selection: normal typing, clicking, scrolling, app switch, secure fields.
- Stack: collect selections from two or more apps into one Chat Panel, remove chips, close panel resets stack.
- URL: select text containing multiple URLs; all fetch; summaries are generated only on send.
- API: missing key/model errors, streaming success, network failure, invalid model, model without image support.
- Screenshot: permission denied path, user-drawn region capture, image attachment sent to compatible model.
- TTS: speak latest answer, stop, close panel stops speech, repeat playback.
- History: chats and attachments persist for 7 days and are pruned afterward.

## Assumptions

- V1 never edits or replaces text in source apps.
- “0.5ms” means a 0.5 second display delay.
- “Any app” means best-effort majority coverage, not secure fields, images, games, remote desktops, or apps that block Accessibility and copy behavior.
- OpenRouter tools remain app-controlled in V1; no model-callable web/screenshot/TTS tools yet.
- The markdown plan artifact should be written to `docs/selector-prototype-plan.md` once Plan Mode ends.
