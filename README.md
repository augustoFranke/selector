# Selector

Selector is a native macOS prototype that watches the frontmost app for text selection changes and shows a floating `Ask ChatGPT` button near the start of the selected text.

It uses macOS Accessibility as the first source of selected text and selection bounds, with a listen-only Quartz event tap as a trigger to re-check after mouse and keyboard selection gestures. When Accessibility does not expose selected text, it briefly sends Command-C, reads plain text only if the pasteboard changed, restores the original pasteboard contents, and places the button near the pointer. The button appears 0.5 seconds after a selection trigger and is intentionally inert in this prototype.

## Build

```sh
make app
```

The app bundle is created at `build/Selector.app`.

## Permissions

Selector needs Accessibility permission. Input Monitoring may also be requested by macOS because the prototype uses a listen-only event tap to notice global mouse and keyboard gestures.

If the app is not trusted yet, launch it once and approve it in System Settings. If macOS does not show a prompt automatically, add `build/Selector.app` manually in System Settings > Privacy & Security > Accessibility.

## Debugging

Runtime notes are written to:

```sh
/tmp/selector.log
```
