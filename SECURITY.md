# Security policy

## Supported versions

Only the latest release gets security fixes.

## Reporting a vulnerability

Please don't open a public issue. Report it privately through GitHub instead:
go to the repo's **Security** tab and click **Report a vulnerability**.

Include what you found, how to reproduce it and what an attacker could do with
it. You should get a reply within a week.

## What the app touches

So you know where to look:

- **Network:** lyrics lookups to `lrclib.net`, and cover art from the player or
  YouTube's image host. Nothing else is sent anywhere, and there is no
  analytics.
- **Automation:** it uses Apple Events to read and control Spotify, Apple
  Music, QuickTime and supported browsers.
- **Audio:** the optional effects capture audio from a loopback input device
  (BlackHole) and play it back processed. Audio is never recorded or stored.
