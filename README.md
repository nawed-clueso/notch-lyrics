# Notch Lyrics 🪩

[![Build](https://github.com/nawed-clueso/notch-lyrics/actions/workflows/build.yml/badge.svg)](https://github.com/nawed-clueso/notch-lyrics/actions/workflows/build.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Synced lyrics in your MacBook's notch. The notch grows a little on both sides
to show the line being sung; rest the cursor on it and it opens into a lyrics
card with the lines around it, a scrubber and playback controls.

Works with Spotify, Apple Music, QuickTime, and music playing in a browser
(YouTube Music, Spotify Web and others). Lyrics come from
[LRCLIB](https://lrclib.net), or optionally from Spotify itself for songs
playing in Spotify.

## Features

- **The line being sung, in the notch.** The closed bar is the notch widened
  evenly on both sides, with the line split across the camera. Long lines show
  in parts as they're sung.
- **Lyrics card on hover.** The current line, with the lines before and after
  it. Instrumental breaks show three dots that count in
  to the next line.
- **Scrub and skim.** Drag the scrubber and the lyrics follow; click any line
  to jump to it; two-finger scroll over the card to step line by line.
- **Audio effects.** Optional presets, a 10-band EQ, reverb and more, applied to
  system audio through a loopback device (BlackHole).
- **Displays without a notch** get the same bar centred in the menu bar.

## Install

1. Download **Notch Lyrics.dmg** from the
   [latest release](https://github.com/nawed-clueso/notch-lyrics/releases/latest)
   and drag the app into Applications.
2. The app isn't signed with an Apple Developer ID, so macOS blocks the first
   launch. Open it once, then go to **System Settings › Privacy & Security** and
   click **Open Anyway**. Or run:

   ```bash
   xattr -dr com.apple.quarantine "/Applications/Notch Lyrics.app"
   ```

3. Allow it to control your music app when macOS asks. The Setup pane in the
   app walks through the rest.

**Requires** macOS 15 or later on Apple Silicon.

### Browser playback

- **Arc:** works as is.
- **Safari and Chrome:** turn on **Allow JavaScript from Apple Events** in the
  Develop menu (Safari) or View › Developer (Chrome).
- **Dia and other apps:** install `media-control`, which reads the system's Now
  Playing information:

  ```bash
  brew install media-control
  ```

### Spotify lyrics (optional)

For songs playing in the Spotify app or on open.spotify.com, Notch Lyrics can
use Spotify's own lyrics, timed to the exact recording. It signs in the way the
Spotify web player does, so it needs your `sp_dc` cookie:

1. In a browser signed in to [open.spotify.com](https://open.spotify.com), open
   Developer Tools, go to **Application** (**Storage** in Safari) › **Cookies** ›
   `open.spotify.com`, and copy the value of `sp_dc`.
2. In Notch Lyrics, open **View › Lyrics** (⌘3), paste it and click **Save**.

The cookie signs in as you: it's kept in your Keychain and only sent to
Spotify. This isn't a public API, so it can stop working when Spotify changes
the web player; songs then fall back to LRCLIB.

## Build from source

```bash
./scripts/build-dmg.sh
```

This builds a release binary with Swift Package Manager and writes
`build/Notch Lyrics.app` and `build/Notch Lyrics.dmg`. The app is ad-hoc
signed, so macOS treats each rebuild as a new app and asks for permissions
again; sign it with a stable identity of your own to keep them.

## Privacy

Notch Lyrics has no analytics and no account. The only network requests are
lyrics lookups to [LRCLIB](https://lrclib.net) (track title, artist, album and
duration) and cover art. With Spotify lyrics turned on, it also signs in to
Spotify with your cookie and asks for lyrics by track id. The optional audio effects process system audio live
and never record or store it.

## Contributing

Bug reports and pull requests are welcome. See
[CONTRIBUTING.md](CONTRIBUTING.md) for how to build and what to include, and
[SECURITY.md](SECURITY.md) for reporting security problems privately.

## Licence

The app is released under the [MIT License](LICENSE). Bundled third-party
files keep their own licences, listed below.

## Credits

Fonts: [Work Sans](https://github.com/weiweihuanghuang/Work-Sans),
[Instrument Serif](https://github.com/Instrument/instrument-serif) and
[Geist and Geist Mono](https://github.com/vercel/geist-font), under the SIL Open Font
License. 3D visualizer: [three.js](https://threejs.org) (MIT). Licence texts
are in [`LICENSES/`](LICENSES).

Lyrics belong to their respective rights holders and are fetched from LRCLIB
at runtime, never bundled. Notch Lyrics is not affiliated with or endorsed by
Spotify, Apple or Google.
