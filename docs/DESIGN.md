# ReGlass design system

ReGlass looks like warm paper: a neutral off-white canvas, cards a step lighter, ink for the words and one accent,
copper. In Dark Mode the same system turns into a warm near-black with lighter ink and a brighter copper. The app follows
the system's Light/Dark setting; nothing forces an appearance.

Everything here lives in code in `ReGlass/Design/Theme.swift` (tokens, surfaces, buttons, the glasses drawing) and
`ReGlass/Design/Components.swift` (status, rings, spinners, motion). The alarm Live Activity, which can't see `Theme`,
has the same values in `ReGlassAlarmLook` (`ReGlass/Connectors/Alarms/ReGlassAlarmMetadata.swift`). Change a value
here and in code together, and measure it again.

## Principles

- **Paper first.** The canvas and cards carry the page; colour is for meaning (copper = ReGlass, red = destructive,
  green/amber/red = status, category colours = categories).
- **One accent.** Copper marks what's tappable or live: links, selected tabs, the send button, toggles, rings, the glint
  on the glasses. Never use it for decoration or for status.
- **Content vs. controls.** Cards and rows are quiet content surfaces; Liquid Glass is only for controls floating over
  content (bars, pills, round buttons, chips, the toast). This is HIG › Materials.
- **Lots of motion, always with a Reduce Motion fallback.** Springs for presses and arrivals, a fade or stillness under
  Reduce Motion.
- **Inline, not wizard-like.** Flows change in place (blur cross-fades, inline confirmations), no stock modal sheets
  for main flows and no sideways slide decks.

## Colour

All tokens are dynamic colours (`UIColor { traits in … }` via `Theme.dynamic(light, dark, contrast:, alpha:)`).
Contrast is WCAG 2.x, measured with the canvas, card and raised surfaces as backgrounds. Text needs 4.5:1 (we hold
small captions to it too); large text and non-text UI need 3:1.

### Surfaces

| Token | Light | Dark | Use |
|---|---|---|---|
| `canvas` | `#F4F2EC` | `#1F1E1C` | The screen, the launch screen (`LaunchBackground`), flat covers |
| `backdropTop` / `backdropBottom` | `#F8F7F3` / `#EFECE5` | `#252421` / `#1B1A18` | `ReGlassBackdrop`'s gentle fall around the canvas; the fade under the typing bars uses `backdropBottom` |
| `card` | `#FBFAF7` | `#2A2926` | Content cards, list rows (`.listRowBackground(Theme.card)`) |
| `raised` | `#FFFFFF` | `#34322F` | Text fields (`field`), cards under Increase Contrast |
| `glow` / `glowSoft` (`halo`) | `#E3A176` / `#F0C5A8` at 35 % | `#CB7F4D` / `#D08C5E` at 30 % | The soft warm light behind the glasses and emblems, the daylight at the top of the backdrop |
| `scrim` | ink at 32 % | black at 55 % | Behind Meta's sign-in dialogs |

Card on canvas is only 1.07:1 (dark 1.15:1) by design: the hairline edge, not the fill, draws the card.

### Text, lines and accent, with measured contrast

| Token | Light | Dark | Light: canvas / card / raised | Dark: canvas / card / raised | Needs |
|---|---|---|---|---|---|
| `ink` | `#1F1E1C` | `#EDEBE4` | 14.9 / 16.0 / 16.7 | 14.0 / 12.2 / 10.7 | 4.5 |
| `textSecondary` | `#5E5B54` | `#B8B4AA` | 6.1 / 6.5 / 6.8 | 8.0 / 7.0 / 6.2 | 4.5 |
| `textTertiary` | `#6F6B63` | `#A29E94` | 4.7 / 5.1 / 5.3 | 6.2 / 5.4 / 4.8 | 4.5 |
| `accent` (copper, text and glyphs) | `#9A582D` | `#D08C5E` | 4.9 / 5.3 / 5.5 | 6.0 / 5.3 / 4.6 | 4.5 |
| `good` | `#2E7A47` | `#6FCB8D` | 4.7 / 5.0 / 5.3 | 8.4 / 7.3 / 6.5 | 4.5 |
| `warning` | `#8F5A00` | `#EBB55B` | 5.2 / 5.5 / 5.8 | 9.0 / 7.8 / 6.9 | 4.5 |
| `critical` | `#B8322A` | `#FF8A7A` | 5.3 / 5.7 / 6.0 | 7.3 / 6.4 / 5.6 | 4.5 |
| `actionRed` (destructive) | `#D70015` | `#FF6961` | 4.8 / 5.2 / 5.4 | 5.9 / 5.2 / 4.5 | 4.5 |
| `accentFill` (copper, areas) | `#AC6232` | `#CB7F4D` | 4.1 / 4.4 / 4.6 | 5.3 / 4.6 / 4.1 | 3 (non-text) |
| `control` (outlines that are the control) | `#8E8A80` | `#85817A` | 3.1 / 3.3 / 3.4 | 4.3 / 3.8 / 3.3 | 3 (non-text) |

- `onAccent` (labels on `accentFill`): white in light, 4.6:1; `#1F1E1C` in dark, 5.3:1. `onStatus` is the same pair for
  a glyph on a filled status colour: on `good` 5.3:1 / 8.4:1, on `critical` 6.0:1 / 7.3:1.
- `hairline` `#E3E0D6` / `#3A3834` (1.27 / 1.24 on a card) and `fieldEdge` `#D2CEC3` / `#4A4743` are decoration only;
  a control never depends on them alone. `track` is ink at 10 % / 14 %: ring tracks, disabled round buttons, pressed rows.
- Ink at reduced opacity for quieter body text stays readable: at 90 % 11.9 / 10.2, at 78 % 8.0 / 8.0 on a card. At
  60 % (a reminder or item ticked a moment ago, before it moves away) it is 4.3 / 5.4.
- `accentGradient` (`accent` → `accentFill`) only where depth is the point: the emblem's symbol and the countdown ring.

**Increase Contrast** firms up the quiet tokens (canvas / card): `textSecondary` `#46443F` 8.7 / 9.3 (dark `#D3CFC6`
10.7 / 9.4), `textTertiary` `#56534D` 6.8 / 7.3 (dark `#C0BCB2` 8.8 / 7.7), `control` `#6F6B63` 4.7 / 5.1 (dark
`#A29E94` 6.2 / 5.4), `hairline` `#A9A59B` (dark `#65625B`), `fieldEdge` `#8E8A80` (dark `#85817A`). Cards switch to
`raised` with a 1 pt edge, and dimmed battery rings stop dimming.

### Categories

iOS's list colours in two tones: deep in light so a caption-size name reads on the paper, softened (about 30 % less
chroma in OKLCH) in dark. Never copper or red; orange leans amber to stay clear of copper. A chosen chip's wash is the
colour at 12 % (dark 22 %), and its count is ink (a coloured count fell under 4.5:1 on the wash).

| Category | Light | Dark | Light: canvas / card | Dark: canvas / card |
|---|---|---|---|---|
| Shopping (green) | `#2F7A3C` | `#66C173` | 4.7 / 5.1 | 7.5 / 6.5 |
| To-do (blue) | `#2F68B0` | `#5E97D9` | 5.0 / 5.4 | 5.5 / 4.8 |
| Appointments (orange) | `#9E5C00` | `#E3A35C` | 4.7 / 5.0 | 7.7 / 6.7 |
| Ideas (yellow) | `#806400` | `#ECD26F` | 5.0 / 5.4 | 11.1 / 9.7 |
| Work (purple) | `#8448A8` | `#C896E1` | 5.4 / 5.8 | 7.1 / 6.2 |
| Owner's own: pink | `#B03C55` | `#E67B8B` | 5.2 / 5.6 | 6.0 / 5.2 |
| Owner's own: indigo | `#4F52B5` | `#A7A8E8` | 5.9 / 6.3 | 7.5 / 6.5 |
| Owner's own: brown | `#7A5E40` | `#AD9679` | 5.4 / 5.7 | 5.9 / 5.1 |
| Owner's own: grey | `#69686D` | `#AEAEB2` | 4.9 / 5.3 | 7.5 / 6.6 |

### System colours we keep

- **Swipe buttons** use iOS's own colours (`Theme.Swipe`), one meaning each on every page: Copy blue, Remind Me orange,
  Done green, Snooze indigo, Not Done grey, Delete red. They follow Light and Dark by themselves. Every swipe button
  sets its own tint (the app-wide copper tint would otherwise win).
- **The Reminders tab badge** is the system red with white digits, as in every iOS app.
- Calendar dots wear the calendar's own colour from Calendar.

### Asset catalog

- `AccentColor`: `#9A582D`, dark `#D08C5E` (the copper text tone; system controls that take the global tint).
- `LaunchBackground`: the canvas, `#F4F2EC`, dark `#1F1E1C`.
- `AppIcon`: ReGlass's own artwork, generic browline glasses (matte black, copper-mirror lenses) on warm charcoal with a
  copper rim light. Also bundled as `ReGlassIcon` in the widget extension.
- `Glasses`: the same glasses as a full pair on a transparent background, cropped to their visible bounds for setup and
  glasses screens.

### Alarm Live Activity (`ReGlassAlarmLook`)

The Lock Screen activity sits on the canvas of the current appearance at 88 % (a fixed colour per `colorScheme`, as
`activityBackgroundTint` wants), with ink titles, secondary text, copper time and glyphs, copper rings and bars on a faint
ink track, and Stop as an ink capsule on that track. The Dynamic Island is always dark, so the same dynamic tokens
resolve to their dark tones there (on black: copper 8.0, ink 17.6, secondary 10.1). Worst cases on the Lock Screen (the
88 % tint over a black or white wallpaper): light secondary 4.6, light copper time 3.7 and dark copper time 4.4, both large
text. AlarmKit's own alert and tint, and the Island's keyline, use the fixed copper `#C96442` (5.4:1 on black,
3.9:1 on white). `ReGlassMark` mirrors the app icon, with the activity badge at its corner.

## Type

- **Inter Display SemiBold** (bundled, SIL OFL) for the wordmark, screen titles and the glasses' name only:
  `.displayFont(.largeTitle | .title | .title2 | .title3)`. Sized from the text style it stands in for, so Dynamic Type
  scales it. Under Bold Text it falls back to San Francisco Bold, as Inter ships only SemiBold.
- **San Francisco** for everything else, in text styles (never fixed sizes except inside rings and badges that scale
  with their own `@ScaledMetric`). Rounded SF with monospaced digits for live numbers (battery, countdowns).
- Hierarchy is weight and colour, not size jumps: `ink` for what matters, `textSecondary` for support, `textTertiary`
  for captions and times. At accessibility sizes rows stack instead of truncating.

## Surfaces and materials

- **Backdrop** (`ReGlassBackdrop`): the canvas with a slightly lighter top and deeper bottom, and one soft patch of
  warm light in the top corner (`glow`, 30 % × `intensity`). Settings-style screens use `intensity: 0.6`.
- **Content cards and rows** (`.contentCard()`, `.contentSurface(in:)`): `card` fill with a 0.75 pt `hairline` edge,
  continuous corners (20–30 pt). Under Increase Contrast, `raised` and a 1 pt edge. Never Liquid Glass.
- **List rows** in grouped lists: `.listRowBackground(Theme.card)` with `.scrollContentBackground(.hidden)` over the
  backdrop.
- **Liquid Glass** (`.glassSurface(in:interactive:)`): untinted `.regular`, so it takes its warmth from the paper under
  it in both appearances. Text on it is `ink`.
- **Text fields** (`.fieldSurface(focused:)`): `field` fill, `fieldEdge`, turning `accentFill` while focused (eased, 0.2 s).
- **Glows** (`halo`, `glow`): blurred and translucent, behind the glasses and the emblems; brighter when the glasses are
  connected. Never behind text.

## Components

- **Primary pill** (`PrimaryButtonStyle`): `accentFill` capsule, `onAccent` label, headline weight, hugging its label
  (190–300 pt wide, 50 pt tall, long labels wrap), centred. One per screen. Disabled: `track` fill, tertiary label.
- **Secondary pill** (`SecondaryButtonStyle`): glass capsule, ink label.
- **Quiet text button** (`QuietButtonStyle`): secondary text, still a 44 pt target.
- **Compact pill** (`CompactPillStyle`) inside rows and cards: `.prominent` copper with `onAccent`, `.glass` ink on glass,
  `.destructive` `actionRed` on glass. 44 pt tall, hugging the label.
- **Round buttons**: 44 pt glass circles with ink glyphs (Settings gear, onboarding Back/Close). The send button is a
  36 pt `accentFill` disc with an `onAccent` arrow once there's something to send, a `track` disc before.
- **Rows**: title in `ink` headline, a secondary line, a tertiary time; leading SF Symbols in `accent`
  (`RowSymbol`, `InfoRow`), chevrons in `textTertiary`.
- **Chips** (`ChipButton`): glass capsules; chosen, a wash of the category colour and a thin ring in it that slides
  to the next chip (a fade under Reduce Motion).
- **Checkboxes and rings**: empty circle in `control`; ticked, an `accentFill` disc with an `onAccent` check and one
  copper ring spreading out (`TickBurst`, none under Reduce Motion).
- **Status** (`StatusPill`, `AssistantStatusLine`, `ConnectorLight`): a dot or symbol in `good` / `warning` /
  `critical` / `accent` always beside words; colour never stands alone.
- **Destructive actions** (Delete, Delete All, Clear, Sign Out, Forget): `actionRed` text or `role: .destructive`,
  alone and last in their group. Swipe Delete stays `Theme.Swipe.delete`.
- **Toasts** (`LibraryToastView`): a glass capsule over the bar with a copper symbol, ink words and a copper Undo.
- **Experimental mark** (`ExperimentalMark`): "Experimental" in caption-2 semibold copper text (4.8:1 on the canvas,
  5.2:1 on a card; dark 6.4 / 5.6) inside a 1 pt `accentFill` outline, never a fill.
- **Blockers with a way out** (the interpreter's missing-key notice, Keys locked): a `warning` status line in ink
  words, and right under it a glass compact pill to the fix (Open Keys, Open iPhone Settings).
- **Choice rows** (Voice and Speech providers, Claude models): ink name, secondary line, and a copper `checkmark.circle.fill` for the
  chosen one beside tertiary `circle`s.
- **Emblem** (`ReGlassEmblem`, `StillEmblem`): a copper SF Symbol in a warm halo inside a hairline orbit; while working
  the halo breathes, ripples spread and a point of light circles.

### The glasses picture

`ArtImage(art:)` uses the transparent `Glasses` picture, scaled to fit with a margin for each placement. It keeps
its own colours in both appearances. Disconnected glasses desaturate; the welcome and done steps float it and pass a
glint across it (`GlintBand`, not under Reduce Motion). The app icon and Live Activity mark show the same glasses up
close on their dark background. The artwork is ReGlass's own and shows no real product or brand; see
[THIRD_PARTY.md](../THIRD_PARTY.md).

## Motion

All springs live in `Theme.Motion`, each with a Reduce Motion partner:

| Name | Spring | For | Reduce Motion |
|---|---|---|---|
| `press` / `release` | 0.18 s, 0.8 / 0.4 s, 0.52 | A finger down, then back with a little bounce (`pressFeedback`, `PressableStyle`, `CardPressStyle`) | Dims to 75 % instead of scaling |
| `inline` | 0.42 s, 0.86 | Something changing in place | 0.2 s fade |
| `arrive` | 0.45 s, 0.85 | Something new in a list or conversation | 0.2 s fade |
| `reading` | 0.6 s, 0.85 | A number and its ring moving together | 0.2 s fade |

- **Entrances** (`.entrance(index)`): pieces of a new screen rise 14 pt and fade in, 60 ms apart. Fade only under
  Reduce Motion.
- **Working**: the arc spinner (system spinner under Reduce Motion), the breathing emblem, the search pulse (still faint
  rings under Reduce Motion).
- **Moments**: burst rings on success, the handover flow of light with a key, the glint on the glasses; all off under
  Reduce Motion.
- **Live numbers** roll (`.numericText`); symbols morph (`.symbolEffect(.replace)`), cross-fading under Reduce Motion.
- Haptics are few and meaningful: a light tap on Send/Start and primary pills, success/warning on outcomes.

## Do

- Use the tokens (`Theme.ink`, `Theme.card`, `Theme.accent`, …), never `.white`, `.black` or `Color(red:…)` in a view.
- Put labels on copper in `onAccent`, and glyphs on filled status colours in `onStatus`.
- Use `accent` for text and glyphs, `accentFill` for areas and strokes.
- Keep pills compact and centred; one primary per screen.
- Give every animation a Reduce Motion path.
- Measure new colours (4.5:1 for text, 3:1 for non-text) in both appearances and add them here.

## Don't

- Don't force an appearance (`preferredColorScheme`, `UIUserInterfaceStyle`).
- Don't put Liquid Glass on cards or rows, or tint it.
- Don't use copper for status, decoration or destructive actions; don't use red for anything but deleting and errors.
- Don't use sparkle icons (or any "magic" glyph) for AI; ReGlass's symbols are plain (waveform, bubble, eyeglasses).
- Don't use full-width buttons, stock modal sheets for main flows, or step-by-step wizard slides.
- Use the supplied `Glasses` picture for glasses artwork, and don't add pictures of real branded products.

## Fixed colours on purpose

A few colours are fixed rather than tokens, each for a reason:

- The glasses artwork's own colours, and AlarmKit's fixed copper (see above).
- The Paste button on Keys: iOS draws its label white, so its fill is a warm grey that holds white in both
  appearances (`#5E5B54`, 6.8:1; dark `#625F58`, 6.4:1), quieter than the copper Save beside it.
- Calendar dots: each calendar's own colour.
- Chip-row edge fades: black and clear in a mask, which only means "shown" and "hidden".
