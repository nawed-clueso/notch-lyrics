# Notch Lyrics identity

The logo is the mirrorball emoji, 🪩. The name is set beside it in Instrument
Serif. That's the whole mark.

This replaced a hand-drawn faceted-ball logo. The emoji already carries the
disco read at every size, renders from the system font on every Mac, and needs
no asset pipeline — so the only thing left to typeset is the name.

## Type

Three roles, three real families rather than weights of one:

| Role | Face | Used for |
| --- | --- | --- |
| Title | **Instrument Serif** Regular | Pane titles, the wordmark. Formal, high contrast, holds up large. |
| UI & prose | **Work Sans** Regular / SemiBold | Everything read as interface or copy. Humanist, still legible at 11pt. |
| Data | **Geist Mono** Regular | Values, frequencies, shell commands. Monospaced digits so readouts don't jitter. |

Both new faces are SIL Open Font License, downloaded from Google Fonts as static
TTFs and bundled in `Sources/NotchLyrics/Resources/`. They're registered with
CoreText at launch by `AppFont.registerAll()`, which also verifies each family
resolves afterwards — a failed registration otherwise falls back to the system
font silently and the whole app just looks slightly wrong.

Instrument Serif ships one weight. That's deliberate: titles don't need a bold,
and having only one removes the temptation to use the serif for controls, where
its contrast turns spindly below about 15pt.

## Where it appears

- **Sidebar** — `BrandLockup` (emoji + name), 19pt cap height.
- **App icon** — `scripts/make-icon.sh` renders 🪩 at every required size via
  Apple Color Emoji. No vector artwork to maintain.
- **Tight spaces** — `Brandmark` is the emoji alone, for when the name is
  already obvious.

## Rules

- Don't recolour the emoji or place it on a busy background — it's a full-colour
  glyph and can't be knocked out.
- Keep clear space around the lockup equal to the emoji's height.
- The serif is for titles only. Never for buttons, labels, or values.
- One accent (`#1ED760`) carries state and the single primary action per view.
  `#C8FFDD` is a highlight for the meter, not a UI state colour.

## Palette

| Token | Value | Role |
| --- | --- | --- |
| Accent | `#1ED760` | State, one primary action per view |
| Glint | `#C8FFDD` | Meter highlight |
| Ground | `#121212` | Window |
| Surface | `#181818` | Cards |
| Well | `#242424` | Controls inside cards |
