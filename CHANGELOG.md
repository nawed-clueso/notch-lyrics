# Changelog

All notable changes to this project are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.1.0] - 2026-10-28

### Added

- Optional Spotify lyrics: for songs playing in Spotify (app or
  open.spotify.com), use Spotify's own lyrics, timed to the exact recording.
  Set it up in the new Lyrics pane (View › Lyrics, ⌘3) with your `sp_dc`
  cookie, which is kept in the Keychain. Falls back to LRCLIB.
- Displays without a notch show the line whole and centred, with the artwork
  and meter either side.

### Changed

- The notch is set in Geist: a semibold current line, and the same family as
  the timestamps.
- The current line shows solid instead of filling in. Lyrics are only timed
  per line, so the fill was a guess at where the words were.
- Lyrics run half a second ahead, so each line is up just before it's sung.

### Fixed

- Opening and closing the card no longer leaves faded copies of old lyrics
  behind it.

## [1.0.0] - 2026-10-22

First release.

- Synced lyrics in the notch for Spotify, Apple Music, QuickTime and browser
  playback, with lyrics from LRCLIB.
- Lyrics card on hover with a scrubber, playback controls and line-by-line
  scrolling.
- Optional audio effects through a loopback device: presets, a 10-band EQ and
  reverb.
- Same bar centred in the menu bar on displays without a notch.

[Unreleased]: https://github.com/nawed-clueso/notch-lyrics/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/nawed-clueso/notch-lyrics/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/nawed-clueso/notch-lyrics/releases/tag/v1.0.0
