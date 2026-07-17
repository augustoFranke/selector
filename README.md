# Selector

Selector is a native macOS contextual AI assistant. Select text in any app and a small "✨ ask" bubble appears near the selection; clicking it opens an anchored chat panel. While the panel is open, new selections from any app stack into the same conversation (the **Selection Stack**), URLs found in selections are fetched as web context, screenshots can be attached, and answers can be read aloud.

Capture is Accessibility-first (`kAXSelectedTextAttribute` + selection bounds), with a listen-only Quartz event tap as the trigger for deliberate selection gestures (drag, multi-click, shift-click, shift-navigation, Cmd-A) held with **Option (⌥)** — the same gesture without Option just selects text normally and Selector stays silent. A careful pasteboard fallback restores the clipboard afterwards. Secure fields are skipped. Answers stream from Groq through a provider-agnostic model layer.

Note: holding Option while drag-selecting switches to column/rectangular selection in some code editors (Xcode, VS Code/Cursor, Sublime, BBEdit) — a native macOS behavior, not a Selector bug. Use Option+multi-click or Option+Shift+Arrow in those apps instead.

See `CONTEXT.md` for the domain glossary and `docs/ROADMAP.md` for direction.

## Build & run

```sh
make app    # builds and codesigns build/Selector.app
make run    # builds, then launches the app
```

Requires Xcode command line tools and an "Apple Development" signing identity.

## API key

Set your Groq API key from the menu bar: **◉ Selector → Set Groq API Key…** (stored in your login Keychain).

For development, the environment variable fallback still works:

```sh
GROQ_API_KEY=gsk_… make run-api
```

Optional overrides: `SELECTOR_GROQ_MODEL`, `SELECTOR_GROQ_VISION_MODEL`, `SELECTOR_GROQ_TTS_MODEL`, `SELECTOR_GROQ_TTS_VOICE`.

## Permissions

- **Accessibility** — required for selection capture. Approve the prompt on first launch, or add `build/Selector.app` under System Settings → Privacy & Security → Accessibility.
- **Input Monitoring** — may be requested for the listen-only event tap.
- **Screen Recording** — requested only the first time you use the screenshot button.

## Tests

```sh
swift test
```

Covers the pure logic: Ask Session routing (idle → overlay, active → stack), prompt/context-block building, and dominant-URL detection. The Accessibility capture layer is verified manually (see the capture test matrix in `docs/archive/PLAN1.md`).

## Debugging

The menu bar item shows live capture debug state (source app, method, trigger, last failure). Runtime logs are written to `/tmp/selector.log`.
