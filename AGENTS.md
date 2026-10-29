## Lessons

- Inspect ring icons and colors in both appearances, collapsed and expanded, with a usage card selected, key and inactive, over white, dark and busy backgrounds. A Settings switch or screenshot alone does not validate live display rendering.
- For pop-out dismissal, test transparent areas inside its window and clicks in other apps separately. Verify inside-card clicks and reopening too; window bounds differ from visible content.
- Anything beside the rail that takes clicks must count as inside for `OverlayController.mouseDown` (as the card, the hover hint and the break countdown do). Otherwise mouse-down collapses the rail, the control moves before mouse-up and its button never fires. Test with a real pointer (hover, then click), not an accessibility press.
- The pet card makes Pulse active and the panel key (typing). Test its dismissal three ways: click inside, click in another app, and mouse leaving the card (which must NOT close a chat). `scripts/codex-chat-check.sh` covers the Codex path without the UI.
- WKWebView: call async page functions as `void fn()`; a returned Promise makes evaluateJavaScript fail with "unsupported type".
- Use canonical Codex realtime item IDs for voice bubbles and keep delegated agent text separate. Verify interleaved speaker deltas, full-text completions, repeated events, and late completions after voice ends.
- For live voice, keep connecting, listening and a paused microphone visibly distinct in the ring, card and accessibility values; a connected call with a muted mic must not look as if it is starting.
- Grouped Settings forms can separate captions from native controls. Give checkboxes and steppers explicit accessibility names, distinguish repeated controls by purpose, and verify the live accessibility tree and activation instead of relying on visible labels.
