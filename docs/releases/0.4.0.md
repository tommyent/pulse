The rings now follow each provider's real limits, and Pulse is more honest when something goes wrong.

- **Rings that match your plan.** The outer arc is your shortest limit, usually the 5-hour session, and the inner arc the next, usually the week. A limit on one model, such as Fable or Argon, fills a gray disc behind the logo. A plan with no 5-hour limit shows the week outside and the model's limit inside.
- **Grok has one arc.** Grok has one limit, its credits, so that's what its ring shows. The card still lists what each product used. With **Show what's left** on, the credits turn around and the products keep showing what they used.
- **Antigravity has two rings.** Gemini is now violet and Claude and GPT is sky blue, each with its own card. Before, they shared one ring and the fuller pool took it over. A switch in **Settings → Accounts** hides the second.
- **Sign-ins you choose.** The hidden claude.ai page now runs only after you sign in with **Connect**. Connect shows on the account's card, in the menu bar popover and in Settings while the CLI isn't signed in.
- **Old numbers look old.** When a refresh fails, the ring dims and its card says when the numbers are from and why. Past a window's reset time, the old number is gone. A provider that doesn't answer can't hold up the others.
- **No more log pile-up from Antigravity.** The Antigravity CLI's log for each refresh now goes in a temporary folder and is removed with it.
- **Smaller fixes.** One reset no longer shows as two different times. Failure reasons wrap instead of getting cut off. VoiceOver reads each ring's numbers. Antigravity no longer shows one percent too few. Cards show the provider's own plan name. If Pulse can't read its settings, it keeps a copy instead of overwriting them, and a failed save when a break ends no longer crashes it.

For Apple silicon Macs on macOS 26 or later. To check the download, run `shasum -a 256 -c Pulse-0.4.0.dmg.sha256` in the folder that holds both files.
