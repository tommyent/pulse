/// The guide Pulse writes into its Themes folder at each launch, for people and their AI to write a theme from.
/// `ThemeChecks` reads every worked example out of it and loads it, so each stays a theme Pulse accepts; the light one
/// is written from Groove White's own values here, so it can't drift from what Pulse draws.
enum ThemeGuide {
    /// The light example: Groove White with warmer colours, written as Pulse writes theme files.
    static let paper: PulseThemeFile = {
        var look = PulseSkin.grooveWhite
        look.accents.claude = "#A8430F"
        look.accents.codex = "#2F5BC9"
        return PulseThemeFile(name: "Paper", author: "Your name", description: "Groove White with warmer colours.",
                              appearance: .light, look: look)
    }()

    static let text = #"""
# Pulse themes

<!-- Written by Pulse at each launch. Edits here are overwritten. -->

This folder holds Pulse's themes, one JSON file per theme. Pulse reads every
`*.json` here and lists the good ones in Settings › Appearance, and it reads
a file again within about a second, after edits to it stop: the theme in use
redraws without a relaunch. A theme is data only: colours, sizes and shadows.
No code, no images, no network, and nothing that points outside the file, so
one file is the whole theme: send it to someone, or move it to another Mac,
and it works there.

When someone asks for a theme ("make Pulse warmer", "a green Groove"), you
write a file here. Start from the closest example and change values.

## Settings › Appearance

```
Mode         ( Auto | Light | Dark )
Light theme  [ Groove White      ▾ ]
Dark theme   [ Groove            ▾ ]
```

**Mode** Auto follows the Mac's appearance as it changes; Light and Dark keep
Pulse in one. Pulse draws the **light theme** in light and the **dark theme**
in dark. Each theme says which menu it belongs in (`appearance`, below).
**Import…** copies a theme file into this folder after the same checks as
every file here (a file dropped on Settings does the same); **Export…** saves
the light or the dark theme as one file to share.

## The files

| File | What it is |
|---|---|
| `classic-glass.json`, `classic-solid.json`, `groove.json`, `groove-white.json`, `groove-black.json` | Pulse's own themes, as examples to copy. They are built into Pulse and always there; these copies are rewritten at each launch, and edits to them never apply (an edited copy is first moved beside it as `<name>.json.replaced-<time>`; if it can't be moved, it stays as it is and its `.error` says why). Copy one under a new name to make your own. |
| `glacier.json`, `orchard.json`, `matcha-washi.json`, `linen.json`, `abyss.json`, `forest-canopy.json`, `velvet.json`, `synthwave-chrome.json`, `espresso-brass.json`, `newsprint.json` | picks from Pulse's theme collection, built in the same way: always there, rewritten at each launch, never read back. Copy one under a new name to change it. |
| `<name>.json` | a theme. `<name>` is its id: what Pulse saves as the chosen theme. Rename the file and it is a different theme. |
| `<name>.error` | written by Pulse when `<name>.json` can't be used: every problem, with the key it is in. Removed once the file is fixed or gone. **Check for it after every edit.** |
| `AGENTS.md` | this guide |

Limits: a theme is a regular file (a link, a pipe or a folder is refused) of
at most 64 KB. Pulse reads at most 50 theme files, in order of name; one past
that isn't read, draws Classic if chosen, and Settings says so once for them
all. Pulse marks each `.error` file it writes (an extended attribute) and
removes or rewrites only those: any other `.error` entry is left alone,
whatever it says. In one pass it writes `.error` files for at most 10 theme
files (Settings lists every problem), each at most 8 KB.

**A file that fails any check never draws.** Pulse keeps showing the last
good version of that theme from this run (or the person's Classic, if it had
none) and writes the reasons to `<name>.error`. Settings marks the theme with
⚠︎ and shows the first problem. A theme chosen for a menu it doesn't belong in,
or one Pulse doesn't have, draws the person's Classic (Glass or Solid) there.

## The format

One theme is one look, in one JSON object:

```
{
  "format": 1,                       required: the format this file is written in
  "name": "Shown in Settings",       required, 1 to 40 characters
  "author": "Who made it",           optional, 1 to 80 characters
  "description": "What it is",       optional, 1 to 300 characters, line breaks allowed
  "appearance": "light",             required: "light", "dark" or "any"
  ...the look's keys (below)...
}
```

- **`format`** is 1. A file with a higher number was made for a newer Pulse,
  and this Pulse says so instead of guessing at it.
- **`appearance`**: `"light"` lists the theme under Light theme, `"dark"`
  under Dark theme, and `"any"` under both, drawing the same in either mode.
  Pulse's windows take the theme's appearance (system controls, menus): light
  for a light theme, dark for a dark one, and for "any" the one its surface
  reads as (Classic: dark).
- **A flat theme** (no `groove`) uses Classic's drawing, which is dark only:
  its appearance is "dark", or "any" with a dark surface.

Every key below is required unless it says optional. Keys Pulse doesn't know
are refused, so a typo can't pass silently.

### Value types

- **colour**: a string. `"#RRGGBB"`, `"#RRGGBBAA"`, or exact components
  from 0 to 1: `"0.07,0.07,0.08"` (optionally `",alpha"`). Either may start
  with `srgb:` (the default) or `p3:` (Display P3): `"p3:1,0.40,0.16"`.
  Nothing else (no names, no `rgb()`, no 3-digit hex).
- **shadow**: a list of exactly five values, `[x, y, blur, colour, opacity]`.
  `x`, `y` is the offset (positive is right and down); `blur` is a CSS blur,
  twice SwiftUI's radius; `colour` is a hex colour, or `"accent"` for the
  ring's own colour; `opacity` 0 to 1. A shadow's unit (points, ring units
  or ems) is given with its key. **Inner** shadows shade inside a shape,
  **drop** shadows fall outside it. Light comes from the top left: lit edges
  have negative offsets on an inner shadow's highlight, shadows positive.
- **shadow list**: a list of shadows, at most 4 (at most 2 for `drop`).
- **ring units**: a ring is 100 units across and draws in a box 120 units
  across, so 60 from the centre is the edge of the space it has.

## The look

| Key | Type | What it is |
|---|---|---|
| `accents.claude`, `.codex`, `.grok`, `.antigravity` | colour | each account's ring, bar and tuck tick |
| `accents.antigravity2` | colour | an account's later pool of models (Antigravity's Claude and GPT) |
| `accents.battery` | colour, optional | the battery ring at a normal charge; left out: the system's green. Low and critical stay the system's yellow and red |
| `accents.breakBar` | colour, optional | the break countdown's ring, for the default break colour |
| `surface` | colour | a flat theme's rail, cards and popover; unused by a Groove theme, whose panels draw `groove.slab` (set it to the slab's colour) |
| `glass` | true, optional | a flat theme's panels on untinted dark Liquid Glass instead of `surface` (Classic Glass); flat themes only |
| `liquid` | true, optional | prototype: a flat theme's panels are the system's clear Liquid Glass with nothing over it, light or dark (`appearance`); `ink` and `accents` alone must read on whatever is behind, and `surface` only stands for it in the contrast checks |
| `halo` | shadow list, optional | prototype, `liquid` themes only: soft shadows in points (offsets to ±8, blur to 16) behind everything on the glass, text, rings and icons, so the ink reads on either side of what shows through; e.g. `[0, 0, 3, "#000000", 0.6]` behind white text |
| `liquidMaterial` | text, optional | prototype, `liquid` themes only: `clear` (left out: the most transparent Liquid Glass, the strongest bending at its edges), `regular` (Liquid Glass frosted grey), or `ultraThin` (the older blur, which doesn't bend what's behind) |
| `wash` | colour, optional | prototype, `liquid` themes only: a colour laid on the glass under everything, its alpha the strength, e.g. `srgb:0.56,0.63,1,0.16` or `#8FA0FF29` for a light violet-blue tint |
| `backdrop` | text, optional | prototype, `liquid` themes only: a picture drawn inside the panels under the glass, so the glass bends it instead of the desktop: `desktop` (the Mac's own desktop picture, blurred) or the file name of a picture in this folder (`.png`, `.jpg`, `.heic`; no path). The picture isn't part of the theme file: Export… leaves it behind |
| `track` | colour | a flat theme's empty ring track |
| `ink.primary` | colour, optional | numbers and titles; left out: the system's label colour |
| `ink.secondary` | colour | captions |
| `ink.alert` | colour, optional | text near a limit, a critical battery; left out: the system's red |
| `stale` | 0 to 1 | the opacity of a ring and number from an earlier refresh |
| `groove` | object, optional | the sculpted look (next section). Left out: the flat look, Classic's drawing with these colours |

### `groove`: the sculpted look

A slab lit from the top left; each ring a channel pressed into it, the
colour lying on the channel's floor, part of it in the wall's shadow; a raised
hub with the logo standing on it; text embossed and icons raised.

| Key | Type | Unit, range | What it is |
|---|---|---|---|
| `slab`, `slabTop`, `slabBottom` | colour | | the slab: its colour, and its gradient's top-left and bottom-right ends (rail, cards, pill, popover, Settings) |
| `grain` | number | 0 to 1 | the slab's fine grain |
| `raise` | shadow list | points, offsets to ±20, blur to 24 | inner shadows: the slab's soft light and dark, then its lit and shaded edges |
| `drop` | shadow list | points, at most 2; offset + blur at most 12 | the slab's shadow on what's behind it; the panel leaves 12 pt around |
| `outer`, `inner` | `{radius, channel, tube}` | ring units: radius 1 to 60, channel and tube 0.5 to 30 | a ring's outer and inner channels: the circle's radius, the channel's width, and the colour's width in it (at most the channel's) |
| `hubSingle`, `hubDouble` | number | ring units, 3 to 60 | the hub's radius with one channel, and with two |
| `floor` | colour | | a channel's floor, where the colour lies |
| `face`, `faceTop`, `faceBottom` | colour | | the hub (and a porthole): its colour, and its gradient's light and dark ends |
| `pressLip` | shadow | ring units, offset and blur to 3 | the light the slab's edge catches below a channel |
| `pressInner` | shadow list | ring units | inner shadows of a channel |
| `tubeBleed` | shadow | ring units | the colour's own glow up the channel's wall; `"accent"` for the ring's colour |
| `tubeInner` | shadow | ring units | an inner shadow on the colour |
| `wall` | shadow, optional | ring units | the channel wall's shadow across the colour; left out or `null`: none |
| `dome` | shadow list | ring units | inner shadows of the hub |
| `bubbleDrop` | shadow | points, offset and blur to 4 | an agent's disc's shadow |
| `bubbleInner` | shadow list | points | an agent's disc's inner shadows |
| `logoDrop` | shadow list | ring units, offset and blur to 8 | the logo standing on the hub |
| `logoInner` | shadow list | ring units | the logo's lit and shaded edges |
| `onFace` | colour | | marks on a hub (Grok's logo, symbols, a ring's text) |
| `type` | shadow list | ems of the text's size, offset and blur to 0.5 | embossed text: a lit edge, then its shadows |
| `glyph` | shadow list | points, offset and blur to 8 | raised icons and logos on the slab |
| `barSlot`, `barFill`, `barRadius` | number | points: slot 2 to 20, fill 1 to 20 and at most the slot, radius 0 to 10 and at most half the slot | a card's bar: the slot's height, the fill's height in it, the corner radius |
| `barFloor` | colour | | the slot's floor |
| `barPress` | shadow list | points, offset and blur to 4 | the slot's inner shadows |
| `barLip` | shadow | points, offset and blur to 3 | the light caught below the slot |
| `fillInner` | shadow list | points, offset and blur to 4 | the fill's inner shadows |
| `fillDrop` | shadow | points, offset and blur to 3 | the fill's shadow in the slot |
| `secondBarGround` | colour | | a later window's bar is its colour halfway to this |
| `porthole` | object, optional | | a dark puck each ring sits in, pressed into a light slab (Groove Black): `{"radius": 1 to 58 ring units, at least the outer channel's edge; "lip": shadow, offset and blur to 2; "inner": shadow list, offset and blur to 10}` |
| `bubble` | colour, optional | | the agents' discs; left out: the hub's face lifted 9% toward white |
| `bubbleInk` | colour, optional | | "+3" on a disc; left out: light grey |
| `discWell` | colour, optional | | the cap disc's well; left out: the floor lifted 16% toward white |
| `discInk` | colour, optional | | the cap disc's level; left out: white |

The rings' geometry must fit: the outer channel inside the box
(`outer.radius + outer.channel / 2` at most 60), the inner channel inside the
outer one, `hubSingle` inside the outer channel, `hubDouble` inside the inner
one, and a porthole around the outer channel.

## Legibility: a warning, not a refusal

A theme that is hard to read still loads and draws. Pulse measures it with the
thresholds Fable's Groove designs were measured against (WCAG contrast
ratios), and Settings › Appearance marks it with ⚠︎ and says which text or
colour is under them, and where (hover the line for every one). Pulse's own
themes pass them all. If someone wants a theme readable, keep to these:

- **Text, 4.5:1**, anywhere along the slab's gradient: from
  `groove.slabTop` through `groove.slab` to `groove.slabBottom`, every colour
  in between too (a flat theme: on `surface`):
  `ink.primary` (the system's white in dark or black in light when left out),
  `ink.secondary`, `ink.alert`, and `ink.primary` at the `stale` opacity.
- **The agents' counter ("+3"), 4.5:1**: `groove.bubbleInk` on
  `groove.bubble`, or Pulse's defaults for whichever is left out.
- **A ring's or a bar's colour, 3:1**: every colour in `accents`, on
  `groove.floor` and on `groove.barFloor` (a flat theme: on `surface`).
- **Marks on a hub, 3:1**: `groove.onFace` anywhere along the hub's
  gradient, from `groove.faceTop` through `groove.face` to
  `groove.faceBottom`.

A translucent colour gets a warning too, since how well it reads depends on
what's behind it. Not measured, as in Pulse's own themes: the providers' logos
(brand marks), an empty channel against the slab (carried by its shadow), and
a later window's half-strength bar.

Light colours on a white floor fall short first: deepen a colour (same hue,
darker) until the warning goes, as Groove White does (Grok's amber becomes
`#986300`).

Increase Contrast (System Settings › Accessibility › Display) makes Pulse
draw ink black or white, drop the wall's shadow, and use Classic's full
colours on a dark floor; a theme needs nothing for it.

## Worked examples

Each is complete. Save it here under the name given, pick it in Settings ›
Appearance, and check that no `.error` file appears beside it (and no ⚠︎ in
Settings).

**A dark theme**, flat, as `ember.json` (under Dark theme):

```json
{
  "format": 1,
  "name": "Ember",
  "author": "Your name",
  "description": "Classic's drawing on a warm dark brown.",
  "appearance": "dark",
  "accents": {
    "claude": "#FF7A45",
    "codex": "#6E95FF",
    "grok": "#FFC24D",
    "antigravity": "#B08CFF",
    "antigravity2": "#5CC4FF"
  },
  "surface": "#1A1412",
  "track": "#2E2622",
  "ink": { "secondary": "#E8DDD8" },
  "stale": 0.5
}
```

**A theme for either mode**, flat on glass, as `ember-glass.json` (under
both menus, drawing the same in each):

```json
{
  "format": 1,
  "name": "Ember Glass",
  "appearance": "any",
  "glass": true,
  "accents": {
    "claude": "#FF7A45",
    "codex": "#6E95FF",
    "grok": "#FFC24D",
    "antigravity": "#B08CFF",
    "antigravity2": "#5CC4FF"
  },
  "surface": "#1A1412",
  "track": "#2E2622",
  "ink": { "secondary": "#E8DDD8" },
  "stale": 0.5
}
```

**A light theme**, sculpted, as `paper.json` (under Light theme): Groove
White with warmer Claude and Codex colours. Every `groove` key is there, as
a sculpted theme needs:

```json
\#(String(decoding: ThemeStore.file(paper), as: UTF8.self).trimmingCharacters(in: .newlines))
```

For other sculpted themes, copy `groove.json` (dark) or `groove-white.json`
(light) and change the values: the accents and `floor` for other colours, or
`outer`, `inner` and the hubs for thinner rings.

## Not yet

Images (a texture, a logo), a command that checks or previews a theme, and an
MCP server may come later. Today a theme is this JSON alone.
"""#
}
