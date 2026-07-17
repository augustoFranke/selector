# macOS Text Selection Tracking Review

## Verdict

The original document is directionally right: macOS can capture selected text in many apps through Accessibility, but there is no public API that guarantees every text selection in every app.

The viable prototype path is:

1. Read the focused accessibility element through `AXUIElementCreateSystemWide` and `kAXFocusedUIElementAttribute`.
2. Query `kAXSelectedTextAttribute` for the selected string.
3. Query `kAXSelectedTextRangeAttribute` plus `kAXBoundsForRangeParameterizedAttribute` to place UI near the selection.
4. Observe frontmost-app Accessibility notifications where available.
5. Re-query after mouse and keyboard gestures because many apps are inconsistent about selection notifications.

## Corrections And Nuance

- `kAXSelectedTextAttribute` is not a universal selection API. Apple documents it as required for accessibility objects that represent editable text elements, which leaves read-only text surfaces, custom canvases, terminal buffers, browser-rendered text, PDF renderers, and Electron/native hybrids dependent on their own Accessibility implementation quality.
- `kAXSelectedTextChangedNotification` tells you a selection changed, but it does not give you the text or geometry. You still have to query the relevant element after receiving it.
- A production selection bubble cannot rely only on `kAXSelectedTextAttribute`; it also needs geometry. The important companion APIs are `kAXSelectedTextRangeAttribute` and `kAXBoundsForRangeParameterizedAttribute`.
- The app-scoped observer limitation is real. `AXObserverCreate` takes one application PID, and Apple says an observer receives notifications only from UI elements in that application. A system-wide app must follow the active app or maintain observers for multiple apps.
- Event taps are useful as triggers, not as selected-text providers. They can tell the prototype "the user just released the mouse" or "a keyboard selection gesture happened," but Accessibility or pasteboard fallback still has to provide the selected text.
- The pasteboard fallback should be deliberate. This prototype uses it after selection gestures because it is the only practical way to cover many non-editable selections, but it preserves and restores the previous pasteboard contents.

## Prototype Scope

This prototype implements the safer high-coverage layer:

- Accessibility permission prompt.
- Frontmost-app AX observer.
- Focus and selected-text notification handling.
- Listen-only input event tap as a sampling trigger.
- `AXSelectedText` capture.
- `AXSelectedTextRange` and bounds lookup for overlay placement.
- Pasteboard-preserving Command-C fallback when AX does not expose selected text.
- Floating native AppKit `Ask ChatGPT` button that currently does nothing.
