import Foundation

/// Source-agnostic browser media reader. Iterates tabs across Safari / Chromium browsers
/// and reads whatever metadata is exposed via `navigator.mediaSession.metadata` plus
/// raw `<video>/<audio>` state. Works for: YouTube, YouTube Music, SoundCloud,
/// Apple Music web, Spotify Web, Bandcamp, Vimeo, Twitch, any HTML5 media page that
/// populates Media Session API.
struct BrowserMediaSource: PlaybackSource {
    let name = "Browser Media"

    /// URL substrings that get JS-injected. Filtering at the tab-iteration level avoids
    /// running JS in every tab of every window on every poll.
    private static let mediaHostHints = [
        "music.youtube.com", "youtube.com", "soundcloud.com",
        "music.apple.com", "open.spotify.com", "bandcamp.com",
        "vimeo.com", "twitch.tv", "music.amazon.com", "tidal.com",
        "deezer.com", "audiomack.com"
    ]

    /// Hosts whose content is *music* (we'll try LRCLib for lyrics).
    private static let musicHosts: Set<String> = [
        "music.youtube.com", "soundcloud.com", "music.apple.com",
        "open.spotify.com", "bandcamp.com", "music.amazon.com",
        "tidal.com", "deezer.com", "audiomack.com"
    ]

    // Single JS payload that returns whatever it can find. Pipe-delimited:
    //   title|artist|album|currentTime|duration|isPlaying(0/1)|artworkURL|hostname|kindHint
    // Returns "" if no media is on the page.
    //
    // kindHint = "music" | "podcast" | "video" | "" (empty = caller decides).
    // Spotify Web uses Web Audio API so <audio>.duration is NaN/0 — we scrape
    // the player-bar timestamps instead.
    private static let injectionJS = #"""
    (function() {
        try {
            var media = document.querySelector('video, audio');
            var ms = (window.navigator && navigator.mediaSession) ? navigator.mediaSession : null;
            var meta = ms ? ms.metadata : null;
            if (!media && !meta) return '';

            // Title: MediaSession first, then a cleaned-up document title.
            var rawTitle = (meta && meta.title) ? meta.title : (document.title || '');
            var title = rawTitle
                .replace(/ - YouTube$/, '')
                .replace(/ ‎- YouTube$/, '')
                .replace(/^▶︎? */, '')
                .replace(/^\(\d+\)\s*/, '')   // "(3) Title - YouTube" → "Title"
                .trim();
            if (!title) return '';

            var artist = (meta && meta.artist) ? meta.artist : '';
            var album  = (meta && meta.album)  ? meta.album  : '';

            var art = '';
            if (meta && meta.artwork && meta.artwork.length) {
                art = meta.artwork[meta.artwork.length - 1].src || '';
            }
            if (!art) {
                var og = document.querySelector('meta[property="og:image"]');
                if (og) art = og.getAttribute('content') || '';
            }
            if (!art && (location.hostname === 'www.youtube.com' || location.hostname === 'youtube.com')) {
                var m = location.search.match(/[?&]v=([^&]+)/);
                if (m) art = 'https://i.ytimg.com/vi/' + m[1] + '/maxresdefault.jpg';
            }
            if (!art && location.hostname.includes('music.youtube.com')) {
                var pb = document.querySelector('ytmusic-player-bar img.image, .image.ytmusic-player-bar img');
                if (pb && pb.src) art = pb.src;
            }
            if (art) {
                art = art.replace(/=w\d+-h\d+/, '=w300-h300');
            }

            var ct  = media ? (media.currentTime || 0) : 0;
            var dur = media ? (media.duration || 0)    : 0;
            var paused = media ? media.paused : true;
            var kindHint = '';

            // Parse "M:SS" / "H:MM:SS" → seconds.
            function tsToSec(s) {
                if (!s) return 0;
                var p = s.split(':').map(function(x){ return parseInt(x, 10) || 0; });
                if (p.length === 2) return p[0] * 60 + p[1];
                if (p.length === 3) return p[0] * 3600 + p[1] * 60 + p[2];
                return 0;
            }

            // ----- Spotify Web -------------------------------------------
            if (location.hostname === 'open.spotify.com') {
                // The Web Audio API graph means <audio>.duration is NaN/0.
                // Scrape the player-bar timestamp labels instead.
                var posEl = document.querySelector('[data-testid="playback-position"]');
                var durEl = document.querySelector('[data-testid="playback-duration"]');
                if (posEl) ct  = tsToSec(posEl.textContent || posEl.innerText);
                if (durEl) dur = tsToSec(durEl.textContent || durEl.innerText);

                // Better paused signal — the play/pause button labels itself.
                var playBtn = document.querySelector('[data-testid="control-button-playpause"]');
                if (playBtn) {
                    var label = (playBtn.getAttribute('aria-label') || '').toLowerCase();
                    // "Pause" label means it's currently playing; "Play" means paused.
                    paused = label.indexOf('play') === 0 && label.indexOf('playing') === -1;
                }

                // Is this a podcast episode? URL routes go /episode/<id> vs /track/<id>.
                // Even without that, MediaSession's `meta.album` is the show name
                // and the player has a "Skip back 15s" button on podcasts only.
                var isEpisode = location.pathname.indexOf('/episode/') !== -1
                    || !!document.querySelector('[aria-label*="Skip back 15"], [aria-label*="Skip forward 15"]');
                kindHint = isEpisode ? 'podcast' : 'music';
            }

            return [title, artist, album, ct, dur, paused ? '0' : '1', art, location.hostname, kindHint].join('|||');
        } catch (e) { return ''; }
    })()
    """#

    func fetch() -> NowPlayingInfo? {
        // Dia is deliberately absent: it only answers AppleScript JS while
        // frontmost, so reading it here works exactly until the user switches
        // Space/app, then the winning source (and track id) flip-flops against
        // NowPlayingSource, resetting lyrics each time. NowPlayingSource owns
        // Dia outright — it reads the system session regardless of focus.
        let browsers: [BrowserKind] = [
            .safari,
            .chrome("Google Chrome"), .chrome("Arc"),
            .chrome("Brave Browser"), .chrome("Microsoft Edge")
        ]
        // Prefer a PLAYING tab across all browsers; only fall back to a paused tab
        // when nothing is playing. Otherwise a paused YouTube tab shadows a playing
        // Spotify Web tab that happens to sit later in tab order.
        var fallback: NowPlayingInfo?
        for browser in browsers {
            guard browser.isRunning else { continue }
            if let raw = browser.findMediaTab(hostHints: Self.mediaHostHints, js: Self.injectionJS),
               let info = parse(raw, sourceLabel: browser.appName) {
                if info.isPlaying { return info }
                if fallback == nil { fallback = info }
            }
        }
        return fallback
    }

    private func parse(_ raw: String, sourceLabel: String) -> NowPlayingInfo? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            trimmed = String(trimmed.dropFirst().dropLast())
        }
        let parts = trimmed.components(separatedBy: "|||")
        guard parts.count >= 6,
              let pos = Double(parts[3]),
              let dur = Double(parts[4])
        else { return nil }
        let title = parts[0]
        guard !title.isEmpty else { return nil }
        let artist = parts[1]
        let album = parts[2]
        let art = parts.count >= 7 ? parts[6] : ""
        let host = parts.count >= 8 ? parts[7] : ""
        let kindHint = parts.count >= 9 ? parts[8] : ""

        // Kind: explicit hint from JS wins (Spotify Web tells us podcast vs music).
        // Otherwise host-based heuristic.
        let onMusicHost = Self.musicHosts.contains(where: { host.contains($0) })
        let onYouTubeMain = host.contains("youtube.com") && !host.contains("music.youtube.com")
        let isYouTubeMusicLikely = onYouTubeMain && !artist.isEmpty
        let kind: MediaKind
        switch kindHint {
        case "podcast":             kind = .video   // never look up lyrics for episodes
        case "music":               kind = .music
        case "video":               kind = .video
        default:                    kind = (onMusicHost || isYouTubeMusicLikely) ? .music : .video
        }

        // Stable ID: title+artist only. Duration arrives late on some sites
        // (Spotify Web's DOM scrape can be 0 for the first poll), and using
        // it in the ID would force a redundant lyric re-fetch when it lands.
        let stableID = "web:\(title.lowercased())|\(artist.lowercased())"

        return NowPlayingInfo(
            id: stableID,
            title: title,
            artist: artist,
            album: album,
            duration: dur,
            elapsedAtCapture: pos,
            captureTimestamp: Date(),
            isPlaying: parts[5] == "1",
            artworkData: nil,
            artworkURL: art.isEmpty ? nil : art,
            sourceName: "Browser (\(sourceLabel))",
            kind: kind
        )
    }
}

// MARK: - Browser dialect

private enum BrowserKind {
    case safari
    case chrome(String)

    var appName: String {
        switch self {
        case .safari: return "Safari"
        case .chrome(let n): return n
        }
    }

    var isRunning: Bool {
        AppleScriptRunner.run("application \"\(appName)\" is running") == "true"
    }

    /// Iterates every tab in every window, runs JS only in tabs whose URL contains
    /// a known media-host hint. Returns the first non-empty result, preferring
    /// playing tabs by simple ordering (first-match wins — playing tabs typically
    /// fronted by the user).
    func findMediaTab(hostHints: [String], js: String) -> String? {
        let escapedJS = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let hostsList = hostHints
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        // For each media tab we run the JS and inspect the isPlaying flag (field 6
        // of the "|||"-joined payload). Return immediately on the first PLAYING tab;
        // otherwise remember the first result and return it as a paused fallback —
        // so a playing Spotify tab wins over a paused YouTube tab in the same window.
        let runJS: String
        switch self {
        case .safari:            runJS = "do JavaScript js in t"
        case .chrome:            runJS = "execute t javascript js"
        }
        let body = """
        tell application "\(appName)"
            set bestResult to ""
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        set u to URL of t as string
                        repeat with h in hosts
                            if u contains h then
                                set r to (\(runJS))
                                if r is not "" then
                                    set AppleScript's text item delimiters to "|||"
                                    set flds to text items of r
                                    set AppleScript's text item delimiters to ""
                                    if (count of flds) is greater than or equal to 6 and (item 6 of flds) is "1" then return r
                                    if bestResult is "" then set bestResult to r
                                end if
                                exit repeat
                            end if
                        end repeat
                    end try
                end repeat
            end repeat
            return bestResult
        end tell
        """

        // Bound the whole browser query: a tab mid-reload (or an otherwise
        // unresponsive browser) can block an Apple Event for the default ~2min
        // timeout, which stalls polling. `with timeout` makes it bail in 3s so the
        // source recovers on the next tick.
        let script = """
        set js to "\(escapedJS)"
        set hosts to {\(hostsList)}
        try
            with timeout of 3 seconds
                \(body)
            end timeout
        end try
        return ""
        """
        return AppleScriptRunner.run(script)
    }
}
