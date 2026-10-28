# Contributing to Notch Lyrics

Thanks for wanting to help. Bug reports, fixes and small features are all
welcome.

## Before you start

- **Bugs:** open an issue with the bug report template. Say which player you
  were using (Spotify, Apple Music, QuickTime or a browser), your macOS version
  and your Mac model.
- **Features:** open an issue first so we can agree on the shape before you
  write the code. Small, focused changes are much easier to review.
- **Security problems:** don't open a public issue. See [SECURITY.md](SECURITY.md).

## Building

You need macOS 15 or later on Apple Silicon and Xcode 16 (Swift 6).

```bash
swift build                 # debug build
swift run NotchLyrics       # run it
./scripts/build-dmg.sh      # release .app and .dmg in build/
```

The app is ad-hoc signed, so macOS asks for permissions again after each
rebuild. If that gets in the way, sign the app with a stable identity of your
own.

## Pull requests

1. Fork the repo and branch from `main`.
2. Keep each pull request to one change, and match the style of the code
   around it.
3. Make sure `swift build -c release` passes. CI runs the same build.
4. Describe what changed and how you checked it. For anything visual, a
   screenshot or short recording helps a lot.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
