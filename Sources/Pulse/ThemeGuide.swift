/// The guide Pulse writes into its Themes folder at each launch, for people and their AI to write a theme from.
/// `ThemeChecks` reads the worked example out of it and loads it, so the example stays a theme Pulse accepts.
enum ThemeGuide {
    static let text = #"""
# Pulse themes

<!-- Written by Pulse at each launch. Edits here are overwritten. -->

This folder holds Pulse's themes, one JSON file per theme. Pulse reads every
`*.json` here, lists the good ones in Settings › General › Skin, and reads a
file again within a second of it changing: the theme in use redraws without a
relaunch. A theme is data only: colours, sizes and shadows. No code, no
images, no network.

When someone asks for a theme ("make Pulse warmer", "a green Groove"), you
write a file here. Start from the closest example and change values.

## The files

| File | What it is |
|---|---|
| `classic.json`, `groove.json`, `groove-black.json` | Pulse's own themes, as examples to copy. They are built into Pulse and always there; these copies are rewritten at each launch, and edits to them never apply (an edited copy is kept beside it as `<name>.json.replaced-<time>`). Copy one under a new name to make your own. |
| `<name>.json` | a theme. `<name>` is its id: what Pulse saves as the chosen theme. Rename the file and it is a different theme. |
| `<name>.error` | written by Pulse when `<name>.json` can't be used: every problem, with the key it is in. Removed once the file is fixed or gone. **Check for it after every edit.** |
| `AGENTS.md` | this guide |

Limits: a file is at most 64 KB, and Pulse reads at most 50 theme files
(in order of name).

**A file that fails any check never draws.** Pulse keeps showing the last
good version of that theme from this run (or Classic, if it had none) and
writes the reasons to `<name>.error`. Settings marks the theme with ⚠︎ and
shows the first problem.

## The format

```
{
  "name": "Shown in Settings",       1 to 40 characters
  "dark":  { ...one half... },        required
  "light": { ...one half... }         optional
}
```

A theme without `light` keeps Pulse dark whatever the system's appearance,
as Classic does. A theme with `light` follows the system: `dark` in Dark
Mode, `light` in Light Mode.

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

## One half

| Key | Type | What it is |
|---|---|---|
| `accents.claude`, `.codex`, `.grok`, `.antigravity` | colour | each account's ring, bar and tuck tick |
| `accents.antigravity2` | colour | an account's later pool of models (Antigravity's Claude and GPT) |
| `accents.battery` | colour, optional | the battery ring at a normal charge; left out: the system's green. Low and critical stay the system's yellow and red |
| `accents.breakBar` | colour, optional | the break countdown's ring, for the default break colour |
| `surface` | colour | a flat theme's panel (Settings' Solid look); for a Groove theme, use the slab's colour |
| `track` | colour | a flat theme's empty ring track |
| `ink.primary` | colour, optional | numbers and titles; left out: the system's label colour |
| `ink.secondary` | colour | captions |
| `ink.alert` | colour, optional | text near a limit, a critical battery; left out: the system's red |
| `stale` | 0 to 1 | the opacity of a ring and number from an earlier refresh |
| `groove` | object, optional | the sculpted look (next section). Left out: the flat look, Classic's drawing with this half's colours. A `light` half needs `groove`: the flat drawing is dark only |

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
| `bubbleDrop` | shadow | ring units, offset and blur to 4 | an agent's disc's shadow |
| `bubbleInner` | shadow list | ring units | an agent's disc's inner shadows |
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
| `porthole` | object, optional | | a dark puck each ring sits in, pressed into a light slab (Groove Black's light half): `{"radius": 1 to 58 ring units, at least the outer channel's edge; "lip": shadow, offset and blur to 2; "inner": shadow list, offset and blur to 10}` |
| `bubble` | colour, optional | | the agents' discs; left out: the hub's face lifted 9% toward white |
| `bubbleInk` | colour, optional | | "+3" on a disc; left out: light grey |
| `discWell` | colour, optional | | the cap disc's well; left out: the floor lifted 16% toward white |
| `discInk` | colour, optional | | the cap disc's level; left out: white |

The rings' geometry must fit: the outer channel inside the box
(`outer.radius + outer.channel / 2` at most 60), the inner channel inside the
outer one, `hubSingle` inside the outer channel, `hubDouble` inside the inner
one, and a porthole around the outer channel.

## The contrast floor

Pulse refuses a theme that would be hard to read, with the thresholds Fable's
Groove designs were measured against (WCAG contrast ratios):

- **Text, 4.5:1**, on `groove.slab` (a flat theme: on `surface`):
  `ink.primary` (the system's white in dark or black in light when left out),
  `ink.secondary`, `ink.alert`, and `ink.primary` at the `stale` opacity.
- **A ring's or a bar's colour, 3:1**: every colour in `accents`, on
  `groove.floor` and on `groove.barFloor` (a flat theme: on `surface`).
- **Marks on a hub, 3:1**: `groove.onFace` on `groove.face`.

These colours must be opaque. Not held to the floor, as in Pulse's own
themes: the providers' logos (brand marks), an empty channel against the slab
(carried by its shadow), and a later window's half-strength bar.

Light colours on a white floor fail first: deepen a colour (same hue, darker)
until it passes, as Groove's light half does (Grok's amber becomes `#986300`).

Increase Contrast (System Settings › Accessibility › Display) makes Pulse
draw ink black or white, drop the wall's shadow, and use Classic's full
colours on a dark floor; a theme needs nothing for it.

## A worked example

A flat theme, complete. Save it as `ember.json` here, pick "Ember" in
Settings, and check that no `ember.error` appears:

```json
{
  "name": "Ember",
  "dark": {
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
}
```

For a sculpted theme, copy `groove.json` (it has every key) and change the
values: for example the accents and `floor` for other colours, or `outer`,
`inner` and the hubs for thinner rings. To try a light half on its own,
switch the system to Light Mode.

## Not yet

Images (a texture, a logo), a command that checks or previews a theme, and an
MCP server may come later. Today a theme is this JSON alone.
"""#
}
