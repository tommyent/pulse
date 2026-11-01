Pulse used far more memory than it should, up to about 1.3 GB, because of how the Codex pet's animation frames were loaded: every frame it drew kept its own decoded copy of the pet's whole picture sheet. Now Pulse decodes the sheet once and every frame shares it.

- In a test that draws the pet's animation frames, memory went from 1,304 MB to 53 MB. The decoded image copies went from 1,274 MB to none.
- The pet now takes about 25 MB: one 13 MB picture sheet and 11 MB for drawing.

For Apple silicon Macs on macOS 26 or later. To check the download, run `shasum -a 256 -c Pulse-0.3.1.dmg.sha256` in the folder that holds both files.
