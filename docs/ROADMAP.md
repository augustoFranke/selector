# Selector Roadmap

Single source of truth for direction. Supersedes `docs/archive/PLAN.md` and `docs/archive/PLAN1.md` (kept for history). Terms per `CONTEXT.md`.

## Handoff notes (as of commit f99cbe1, 2026-07-17)

Two fixes landed in this commit, build cleanly, and are running — but neither has been **visually re-confirmed in the app** by a human yet. Check both before starting new work; delete this section once confirmed.

1. **Response text rendering** (`Sources/Selector/ChatPanel.swift`). The response `NSTextView` had zero width — missing the standard `NSScrollView` embedding config (`minSize`/`maxSize`/`autoresizingMask`/`textContainer.widthTracksTextView`), so streamed answers existed in the view's string (confirmed via live Accessibility inspection: the AX value had the full answer, but the view's AX frame was `size=(0,163)`) but never painted on screen. Fix adds that config. **To confirm:** open the chat panel, send a prompt, verify the streamed answer is actually visible, not just present.
2. **Option-gated triggers** (`Sources/Selector/SelectionCapture.swift`). All Capture triggers (drag, multi-click, shift-click, shift-nav, cmd-a) now require Option (⌥) held; plain selection alone no longer shows the bubble. **To confirm:** plain drag/multi-click/shift-click select text with no bubble; Option+drag, Option+multi-click, Option+Shift+Arrow, Option+Cmd+A each show the bubble. Note Option+drag triggers column-select instead of normal selection in Xcode/VS Code/Cursor/Sublime/BBEdit — expected, not a bug (see Standing decisions).

If both hold up, the capture-coverage pass in M1 below is the natural next step and doubles as broader confirmation of #2.

## Product thesis

Selector is a native macOS contextual AI assistant: select text anywhere, click the bubble, ask. The defensible differentiator is the **Selection Stack** — collecting Selections from *multiple apps* into one question (doc + email + terminal error → one prompt). Single-selection "ask AI" is commoditized (Writing Tools, PopClip, Raycast); cross-app context assembly is not. The capture layer (AX-first + gated pasteboard fallback) is the accumulated engineering moat.

## Standing decisions

- **Provider-agnostic model layer.** `ModelProvider` / `SpeechProvider` protocols; Groq is the first conformer. OpenRouter is the intended second (one API, every model, BYOK-friendly). The PLAN.md idea of switching wholesale to OpenRouter is replaced by this layered approach.
- **API keys live in the login Keychain** (`SecretsStore`), set from the menu bar; env var remains a dev fallback. `launchctl setenv` distribution of secrets is dead.
- **Native AppKit**, no web shell.
- **V1 never edits text in source apps.** Read-and-ask only.
- **Tools stay app-controlled** (link fetch, screenshot, TTS); no model-callable tools yet.
- **Triggers require Option (⌥) held.** Plain selection (drag, multi-click, shift-click, shift-nav, cmd-a) never shows the bubble; the same gesture with Option held arms it. Chosen over Control (collides with right-click) and Command (collides with editor multi-cursor); accepted tradeoff: Option+drag means column-select in Xcode/VS Code/Cursor/Sublime/BBEdit.
- Pure logic (session routing, prompt build, URL detection) is unit-tested; the AX/event-tap layer is verified manually per the capture test plan in `docs/archive/PLAN1.md`.

## Milestones

### M0 — Project foundations ✅ (2026-07-17)
Git repo, provider abstraction, Keychain key storage + menu-bar key entry, `App.swift` split into services, test target, docs consolidation.

### M1 — Reliability & first-run experience
The bar: a stranger can download, launch, and succeed without reading anything.
- Onboarding window: explain the two permissions, deep-link to System Settings, live trust status.
- Key entry prompt on first ask instead of a dead panel.
- Capture-coverage pass over the PLAN1 test matrix (Notes, browsers, terminals, PDF viewers); log-driven fixes.
- Panel/session lifecycle hardening (app switch, multi-display, full-screen apps).

### M2 — Second provider + settings
- `OpenRouterProvider` conforming to `ModelProvider` (streaming, vision).
- Minimal settings surface: provider picker, model name, key per provider.
- Provider capability errors surfaced in-panel (no vision model configured, etc.).

### M3 — Context quality (from docs/polish-followups.md)
- Send waits briefly for in-flight link fetches.
- Readability-style extraction, then model-summarized WebContext instead of raw 8 KB truncation.
- Link chip retry affordance; transient vs terminal fetch errors.
- User-drawn screenshot region (current: fixed rect around cursor).

### M4 — Sessions & memory
- Recent Chats: 7-day local JSON persistence incl. attachments, pruned on launch.
- Reopen a recent chat; continue a conversation (multi-turn messages).

### M5 — Distribution
- Developer ID signing + notarization; DMG or direct download.
- Sparkle (or equivalent) updates.
- Website/landing page; TestFlight-style beta group.

## Non-goals (for now)

- Editing/replacing text in other apps.
- Model-callable tool use.
- Windows/Linux, iOS.
- "Works in literally any app" claims — secure fields, games, remote desktops stay out of scope.
