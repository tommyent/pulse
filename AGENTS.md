## Lessons

- Inspect ring icons and colors in both appearances, collapsed and expanded, including with a usage card selected. Verifying the Settings appearance switch alone does not validate the overlay.
- For pop-out dismissal, test transparent areas inside its window and clicks in other apps separately. Verify inside-card clicks and reopening too; window bounds differ from visible content.
- The pet card makes Pulse active and the panel key (typing). Test its dismissal three ways: click inside, click in another app, and mouse leaving the card (which must NOT close a chat). `scripts/codex-chat-check.sh` covers the Codex path without the UI.
- WKWebView: call async page functions as `void fn()`; a returned Promise makes evaluateJavaScript fail with "unsupported type".
- Use canonical Codex realtime item IDs for voice bubbles and keep delegated agent text separate. Verify interleaved speaker deltas, full-text completions, repeated events, and late completions after voice ends.
