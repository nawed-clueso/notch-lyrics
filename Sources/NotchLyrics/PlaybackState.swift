import AppKit
import SwiftUI

/// Where the lyric lookup for the current track stands. Kept apart from
/// `lyrics` because a nil bundle means both "still fetching" and "LRCLIB has
/// nothing", and the pill has to say different things for each.
enum LyricsStatus: Equatable {
    case none, loading, found, notFound
}

@MainActor
final class PlaybackState: ObservableObject {
    @Published private(set) var nowPlaying: NowPlayingInfo?
    @Published private(set) var lyrics: LyricsBundle?
    @Published private(set) var lyricsStatus: LyricsStatus = .none
    @Published private(set) var currentLineIndex: Int?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var palette: [Color] = ColorExtractor.defaultPalette
    @Published private(set) var backgroundColor: Color = ColorExtractor.defaultBackground
    @Published var isHovering: Bool = false
    /// Bumped by the lyric timer to force the collapsed view to re-render when
    /// the chunk-within-a-line changes (the current line index itself doesn't
    /// change mid-line).
    @Published private(set) var lyricChunkTick: Int = 0

    private let coordinator = SourceCoordinator(sources: [
        SpotifySource(),
        AppleMusicSource(),
        QuickTimeSource(),
        BrowserMediaSource(),
        // Last: system Now Playing (MediaRemote). Catches apps AppleScript can't
        // reach — e.g. Dia, which only answers JS for its frontmost active tab.
        NowPlayingSource()
    ])
    private let fetcher = LyricsFetcher()
    private var lyricTimer: Timer?

    func start() {
        coordinator.start { [weak self] info in
            self?.handleUpdate(info)
        }
        // Local-only timer: re-derives "current lyric" from the captured timestamp;
        // no subprocess fork, just a property read. The coordinator handles fresh fetches.
        // 0.25s ticks let mid-line chunk transitions feel responsive without
        // costing anything meaningful.
        lyricTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.recomputeCurrentLine()
                self?.lyricChunkTick &+= 1
            }
        }
    }

    private var artworkTask: Task<Void, Never>?

    private func handleUpdate(_ incoming: NowPlayingInfo?) {
        let trackChanged = incoming?.id != nowPlaying?.id
        if trackChanged { pendingSeek = nil }
        let info = incoming.map(holdingPendingSeek)
        nowPlaying = info
        if trackChanged {
            currentLineIndex = nil
            lyrics = nil
            lyricsStatus = info?.kind == .music ? .loading : .none
            artwork = nil
            artworkTask?.cancel()
            artworkTask = nil
            if let info {
                if info.kind == .music {
                    fetchLyrics(for: info)
                }
                if let data = info.artworkData, let image = NSImage(data: data) {
                    artwork = image
                    refreshPalette(from: image)
                } else if let urlStr = info.artworkURL {
                    downloadArtwork(from: urlStr, trackId: info.id)
                }
            }
        } else if artwork == nil, let info,
                  let data = info.artworkData, let image = NSImage(data: data) {
            // Now Playing payloads can deliver artwork a beat after the track
            // starts — pick it up on a later poll instead of missing it entirely.
            artwork = image
            refreshPalette(from: image)
        }
        recomputeCurrentLine()
    }

    private func downloadArtwork(from urlStr: String, trackId: String) {
        guard let url = URL(string: urlStr) else { return }
        artworkTask = Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard !Task.isCancelled, nowPlaying?.id == trackId, let img = NSImage(data: data)
                else { return }
                artwork = img
                refreshPalette(from: img)
            } catch {
                NSLog("⚠️ artwork download failed: \(error.localizedDescription)")
            }
        }
    }

    private func refreshPalette(from image: NSImage) {
        // NSImage isn't Sendable; keep palette extraction on the main actor.
        // It's already cheap (downsampled 64×64 histogram) so this stays smooth.
        let colors = ColorExtractor.palette(from: image, count: 5)
        palette = colors
        backgroundColor = ColorExtractor.backgroundColor(from: image)
    }

    /// Maximum backward jitter we'll absorb before treating a position
    /// regression as a real user seek (in seconds).
    private let backwardJitterTolerance: Double = 1.5

    /// Clamped, monotonically-forward position used for lyric selection.
    /// Between polls the source extrapolates time; when a fresh poll lands
    /// the reported position can be 50–300 ms *behind* the extrapolation
    /// (Spotify reporting lag), which previously snapped the highlighted
    /// line back to the prior one for one tick. We clamp the position
    /// forward within a jitter window so that doesn't happen, while still
    /// allowing real seeks (> 1.5 s backward) through unchanged.
    private var clampedPosition: Double = 0
    private var clampedTrackID: String?

    /// Where the lyrics are drawn from: the scrub preview while one is in
    /// progress, the playhead otherwise.
    private var displayPosition: Double { scrubPosition ?? clampedPosition }

    private func updateClampedPosition() {
        guard let info = nowPlaying else {
            clampedPosition = 0
            clampedTrackID = nil
            return
        }
        let raw = info.currentPosition
        if info.id != clampedTrackID {
            clampedTrackID = info.id
            clampedPosition = raw
        } else if !info.isPlaying {
            // Paused: the reported position is exact, not a lagging poll. The
            // last extrapolation can have run up to a poll interval past the
            // pause, so take this even when it's behind; otherwise the lyrics
            // sit ahead of the song and stall after resuming until it catches up.
            clampedPosition = raw
        } else if raw + backwardJitterTolerance < clampedPosition {
            // User seeked back — accept it.
            clampedPosition = raw
        } else {
            // Forward, or small backward jitter — never regress.
            clampedPosition = max(clampedPosition, raw)
        }
    }

    private func recomputeCurrentLine() {
        guard let nowPlaying, let lyrics, !lyrics.lines.isEmpty else {
            currentLineIndex = nil
            return
        }
        _ = nowPlaying     // referenced for the early-exit guard above
        updateClampedPosition()
        let position = displayPosition
        var lo = 0, hi = lyrics.lines.count - 1, found = -1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lyrics.lines[mid].timestamp <= position {
                found = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        let next = found >= 0 ? found : nil
        if next != currentLineIndex { currentLineIndex = next }   // avoid spurious re-renders
    }

    private func fetchLyrics(for info: NowPlayingInfo) {
        Task { @MainActor in
            let bundle = await fetcher.lyrics(
                track: info.title, artist: info.artist, album: info.album, duration: info.duration
            )
            if info.id == nowPlaying?.id {
                // An LRC that parses to zero lines is as good as no lyrics.
                let usable = bundle.flatMap { $0.lines.isEmpty ? nil : $0 }
                lyrics = usable
                lyricsStatus = usable == nil ? .notFound : .found
                recomputeCurrentLine()
            }
        }
    }

    // MARK: - View-model conveniences

    var currentLine: String? {
        guard let idx = currentLineIndex, let lyrics else { return nil }
        return lyrics.lines[idx].text
    }

    // Neighbouring lines for the open card. LRC marks instrumental breaks with
    // empty lines, so these skip blanks: the card shows the last words sung
    // and the next words coming, not an empty row.

    /// Nearest non-empty line before the current one (or before the break).
    var previousLine: String? { previousLineIndex.flatMap { lyrics?.lines[$0].text } }
    /// Nearest non-empty line after the current one. During the intro, before
    /// any line is active, this is the song's first line.
    var nextLine: String? { nextLineIndex.flatMap { lyrics?.lines[$0].text } }
    /// The non-empty line after `nextLine`.
    var lineAfterNext: String? { lineAfterNextIndex.flatMap { lyrics?.lines[$0].text } }

    // Start times of the lines on the card, for click-to-seek.
    var previousLineStart: Double? { previousLineIndex.flatMap { lyrics?.lines[$0].timestamp } }
    var currentLineStart: Double? { currentLineIndex.flatMap { lyrics?.lines[$0].timestamp } }
    var nextLineStart: Double? { nextLineIndex.flatMap { lyrics?.lines[$0].timestamp } }
    var lineAfterNextStart: Double? { lineAfterNextIndex.flatMap { lyrics?.lines[$0].timestamp } }

    private var previousLineIndex: Int? {
        guard let lyrics, let idx = currentLineIndex else { return nil }
        // In the silence after a line, that line has become the previous one.
        if !lyrics.lines[idx].text.isEmpty, breakSpan != nil { return idx }
        return lyricIndex(before: idx)
    }
    private var nextLineIndex: Int? { lyricIndex(after: currentLineIndex ?? -1) }
    private var lineAfterNextIndex: Int? { nextLineIndex.flatMap { lyricIndex(after: $0) } }

    private func lyricIndex(after idx: Int) -> Int? {
        guard let lyrics else { return nil }
        var i = idx + 1
        while i < lyrics.lines.count {
            if !lyrics.lines[i].text.isEmpty { return i }
            i += 1
        }
        return nil
    }

    private func lyricIndex(before idx: Int) -> Int? {
        guard let lyrics else { return nil }
        var i = idx - 1
        while i >= 0 {
            if !lyrics.lines[i].text.isEmpty { return i }
            i -= 1
        }
        return nil
    }

    /// Timestamp the next non-empty line becomes current, or the end of the
    /// track when there is none.
    private func nextLyricStart(after idx: Int) -> Double? {
        guard let lyrics, let nowPlaying else { return nil }
        if let next = lyricIndex(after: idx) { return lyrics.lines[next].timestamp }
        return nowPlaying.duration > 0 ? nowPlaying.duration : nil
    }

    /// When the line at `idx` stops being current: the next LRC line's
    /// timestamp, blank or not, or the end of the track after the last line.
    private func lineEnd(_ idx: Int) -> Double? {
        guard let lyrics, let nowPlaying else { return nil }
        if idx + 1 < lyrics.lines.count { return lyrics.lines[idx + 1].timestamp }
        return nowPlaying.duration > 0 ? nowPlaying.duration : nil
    }

    var lyricsAreSynced: Bool { lyrics?.isSynced ?? false }

    /// Rough time it takes to sing a line, from its length. LRC only gives
    /// each line a start time, so this is what tells a sung line apart from
    /// the instrumental after it when the file doesn't mark the gap. Generous
    /// on purpose: guessing short would put the break dots up while a slow
    /// line is still being sung; guessing long only shows them a little late.
    private func estimatedSingTime(_ text: String) -> Double {
        Double(text.count) * 0.12 + 1.5
    }

    /// How much of the current line has been sung, 0…1, for the fill that
    /// sweeps across it. LRC only times whole lines, so the fill is spread
    /// over the line's slot, capped at its estimated sung length so it
    /// doesn't crawl through a silence after the words end.
    var lineFill: Double {
        guard lyricsAreSynced, let idx = currentLineIndex, let lyrics,
              !lyrics.lines[idx].text.isEmpty,
              let end = lineEnd(idx) else { return 1 }
        let line = lyrics.lines[idx]
        let sungEnd = Swift.min(end, line.timestamp + estimatedSingTime(line.text))
        let fillEnd = Swift.max(line.timestamp + 0.5, sungEnd)
        return Swift.min(Swift.max((displayPosition - line.timestamp) / (fillEnd - line.timestamp), 0), 1)
    }

    /// Breaks shorter than this keep a blank row rather than flashing the dots.
    private let minimumBreak: Double = 2.5

    /// The instrumental stretch the playhead is in, if any, as start and end
    /// times. Three kinds: the intro before the first line; a gap the LRC
    /// marks with blank lines; and an unmarked gap, the time after a line's
    /// estimated sung length runs out before the next line (or, after the
    /// last line, before the end of the track).
    private var breakSpan: (start: Double, end: Double)? {
        guard lyricsAreSynced, let lyrics, nowPlaying != nil else { return nil }
        guard let idx = currentLineIndex else {
            guard let end = nextLyricStart(after: -1), end >= minimumBreak else { return nil }
            return (0, end)
        }
        let line = lyrics.lines[idx]
        if line.text.isEmpty {
            // Start from the first blank in a run, so consecutive blank lines
            // read as one break instead of restarting the dots at each.
            var first = idx
            while first > 0, lyrics.lines[first - 1].text.isEmpty { first -= 1 }
            let start = lyrics.lines[first].timestamp
            guard let end = nextLyricStart(after: idx), end - start >= minimumBreak else { return nil }
            return (start, end)
        }
        guard let end = lineEnd(idx) else { return nil }
        let sungEnd = line.timestamp + estimatedSingTime(line.text)
        guard end - sungEnd >= minimumBreak, displayPosition >= sungEnd else { return nil }
        return (sungEnd, end)
    }

    /// Progress 0…1 through the current instrumental break, measured to the
    /// moment the next line appears (or the track ends). Nil while a line is
    /// being sung, when the lyrics aren't synced, or when the gap is too short
    /// to bother.
    var breakProgress: Double? {
        guard let span = breakSpan else { return nil }
        return Swift.min(Swift.max((displayPosition - span.start) / (span.end - span.start), 0), 1)
    }

    /// What the closed bar reads: the line being sung, or the track title
    /// during breaks and when there are no lyrics.
    var collapsedText: String {
        guard let nowPlaying else { return "Disco's quiet" }
        if let line = currentLine, !line.isEmpty, breakSpan == nil { return line }
        return nowPlaying.title
    }

    /// The closed bar's split and wing width on a given display. A line too
    /// long for the wings is shown a page at a time, advancing with how much
    /// of it has been sung. Cached per text and display in `NotchWings`, so
    /// the 0.25s lyric tick doesn't re-measure.
    func collapsedBar(for layout: NotchLayout) -> NotchWings.Bar {
        let pages = NotchWings.pages(for: collapsedText, layout: layout)
        // Unsynced lyrics have no meaningful fill; they show the first page.
        let sung = lyricsAreSynced && currentLine?.isEmpty == false ? lineFill : 0
        let page = Swift.min(Int(sung * Double(pages.count)), pages.count - 1)
        return NotchWings.bar(for: pages[page], layout: layout)
    }

    var progress: Double {
        guard let nowPlaying, nowPlaying.duration > 0 else { return 0 }
        return min(max(nowPlaying.currentPosition / nowPlaying.duration, 0), 1)
    }
    var menuBarText: String {
        currentLine ?? nowPlaying?.title ?? "Not Playing"
    }

    var elapsedText: String { format(scrubPosition ?? nowPlaying?.currentPosition ?? 0) }
    var durationText: String { format(nowPlaying?.duration ?? 0) }
    var isMusic: Bool { nowPlaying?.kind == .music }
    var sourceSupportsTrackSkip: Bool {
        guard let src = nowPlaying?.sourceName else { return false }
        return src == "Spotify" || src == "Apple Music" || src.hasPrefix("Browser") || src.hasPrefix("Now Playing")
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Seeking

    /// The position being previewed while the user drags the scrubber or
    /// skims the lyrics. While set, the lyrics, fill and time follow it
    /// instead of the playhead; the player only moves when it's committed.
    @Published private(set) var scrubPosition: Double?

    /// What the current-line slot held when the scrub began: the line's text,
    /// or "" for the dots or a blank row. The card keeps the height that
    /// needed for the whole scrub, instead of resizing under the cursor as the
    /// preview passes one- and two-line lines. Nil when not scrubbing.
    @Published private(set) var scrubAnchorLine: String?

    /// A seek just sent, held until the player reports a position near it.
    /// Players apply a seek a beat after the command, and a poll in between
    /// would otherwise snap the lyrics back to the old spot and forward again.
    private var pendingSeek: (target: Double, sentAt: Date, playing: Bool)?
    private let seekSettleWindow: TimeInterval = 2.5

    /// Duration if known, for clamping seeks; 0 when the source didn't say.
    private var trackDuration: Double { nowPlaying?.duration ?? 0 }

    /// Moves the preview without touching the player.
    func previewScrub(to seconds: Double) {
        guard nowPlaying != nil else { return }
        if scrubPosition == nil {
            scrubAnchorLine = breakProgress == nil ? (currentLine ?? "") : ""
        }
        let upper = trackDuration > 0 ? trackDuration : seconds
        scrubPosition = Swift.min(Swift.max(seconds, 0), upper)
        skimCommit?.cancel()
        recomputeCurrentLine()
    }

    /// Ends a scrub, seeking the player to the previewed spot when `commit`.
    func endScrub(commit: Bool) {
        if commit, let target = scrubPosition { seek(to: target) }
        scrubPosition = nil
        scrubAnchorLine = nil
        recomputeCurrentLine()
    }

    /// Steps the preview by whole lyric lines (two-finger scroll over the
    /// lyrics) and seeks there once the scrolling stops.
    func skim(lines step: Int) {
        guard lyricsAreSynced, let lyrics, !lyrics.lines.isEmpty else { return }
        let sung = lyrics.lines.indices.filter { !lyrics.lines[$0].text.isEmpty }
        guard !sung.isEmpty else { return }
        let from = displayPosition
        // The sung line at or before the preview position; before the first
        // line, step from "nothing yet" so one step lands on the first.
        let currentPos = sung.lastIndex(where: { lyrics.lines[$0].timestamp <= from + 0.05 })
        let target: Int
        if let currentPos {
            target = Swift.min(Swift.max(currentPos + step, 0), sung.count - 1)
        } else {
            target = step > 0 ? 0 : -1
        }
        // A small offset past the timestamp so the line is unambiguously current.
        previewScrub(to: target < 0 ? 0 : lyrics.lines[sung[target]].timestamp + 0.05)
        skimCommit?.cancel()
        skimCommit = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 550_000_000)
            guard !Task.isCancelled else { return }
            self?.endScrub(commit: true)
        }
    }
    private var skimCommit: Task<Void, Never>?

    /// Jumps to a lyric line by its start time (clicking a line).
    func seek(toLineStartingAt seconds: Double) {
        guard lyricsAreSynced else { return }
        seek(to: seconds + 0.05)
    }

    /// Sends the seek to whichever player is playing, and moves the lyrics
    /// there straight away rather than on the next poll.
    func seek(to seconds: Double) {
        guard let info = nowPlaying else { return }
        let upper = info.duration > 0 ? info.duration - 0.5 : seconds
        let target = Swift.min(Swift.max(seconds, 0), Swift.max(upper, 0))
        let src = info.sourceName
        switch src {
        case "Spotify":
            run(#"tell application "Spotify" to set player position to "# + fixed(target))
        case "Apple Music":
            run(#"tell application "Music" to set player position to "# + fixed(target))
        case "QuickTime":
            run("""
            tell application "QuickTime Player"
                if (count of documents) > 0 then set current time of document 1 to \(fixed(target))
            end tell
            """)
        default:
            if src.hasPrefix("Now Playing") {
                NowPlayingSource.command("seek", fixed(target))
            } else if src.hasPrefix("Browser") {
                runInBrowserMediaTab(js: "var m=document.querySelector('video,audio'); if(m){m.currentTime=\(fixed(target));}")
            }
        }

        pendingSeek = (target, Date(), info.isPlaying)
        nowPlaying = info.at(position: target)
        clampedPosition = target
        recomputeCurrentLine()
        kickRefresh()
    }

    /// Fixed-point seconds for AppleScript and JS, never in scientific notation.
    private func fixed(_ value: Double) -> String { String(format: "%.2f", value) }

    /// Where a just-sent seek should have the playhead by now.
    private func expectedSeekPosition(at now: Date) -> Double? {
        guard let pending = pendingSeek else { return nil }
        let elapsed = now.timeIntervalSince(pending.sentAt)
        guard elapsed < seekSettleWindow else { pendingSeek = nil; return nil }
        return pending.target + (pending.playing ? elapsed : 0)
    }

    /// A poll taken before the player applied a seek still reports the old
    /// spot; keep the seek's position until the player agrees or the settle
    /// window runs out.
    private func holdingPendingSeek(_ info: NowPlayingInfo) -> NowPlayingInfo {
        let now = Date()
        guard let expected = expectedSeekPosition(at: now) else { return info }
        if abs(info.currentPosition - expected) <= 1.5 {
            pendingSeek = nil
            return info
        }
        return info.at(position: expected)
    }

    // MARK: - Controls

    func togglePlayPause() {
        guard let src = nowPlaying?.sourceName else { return }
        switch src {
        case "Spotify":
            run(#"tell application "Spotify" to playpause"#)
        case "Apple Music":
            run(#"tell application "Music" to playpause"#)
        case "QuickTime":
            run("""
            tell application "QuickTime Player"
                if (count of documents) > 0 then
                    tell document 1
                        if playing then
                            pause
                        else
                            play
                        end if
                    end tell
                end if
            end tell
            """)
        default:
            if src.hasPrefix("Now Playing") {
                NowPlayingSource.command("toggle-play-pause")
            } else if src.hasPrefix("Browser") {
                runInBrowserMediaTab(js: #"var m=document.querySelector('video,audio'); if(m){m.paused?m.play():m.pause();}"#)
            }
        }
        kickRefresh()
    }

    func nextTrack() {
        guard let src = nowPlaying?.sourceName else { return }
        switch src {
        case "Spotify":     run(#"tell application "Spotify" to next track"#)
        case "Apple Music": run(#"tell application "Music" to next track"#)
        default:
            if src.hasPrefix("Now Playing") {
                NowPlayingSource.command("next-track")
            } else if src.hasPrefix("Browser") {
                runInBrowserMediaTab(js: clickButtonJS(matching: [#"next track"#, #"^next$"#, #"next song"#, #"play next"#]))
            }
        }
        kickRefresh()
    }

    func previousTrack() {
        guard let src = nowPlaying?.sourceName else { return }
        switch src {
        case "Spotify":     run(#"tell application "Spotify" to previous track"#)
        case "Apple Music": run(#"tell application "Music" to previous track"#)
        default:
            if src.hasPrefix("Now Playing") {
                NowPlayingSource.command("previous-track")
            } else if src.hasPrefix("Browser") {
                runInBrowserMediaTab(js: clickButtonJS(matching: [#"previous track"#, #"^previous$"#, #"^prev$"#, #"previous song"#, #"play previous"#]))
            }
        }
        kickRefresh()
    }

    // Find any clickable element whose aria-label matches one of the regexes (case-insensitive).
    private func clickButtonJS(matching patterns: [String]) -> String {
        let regexes = patterns.map { "/\($0)/i" }.joined(separator: ",")
        return """
        (function(){var rxs=[\(regexes)];var btns=document.querySelectorAll('button,[role="button"],tp-yt-paper-icon-button');
        for(var i=0;i<btns.length;i++){var lbl=(btns[i].getAttribute('aria-label')||btns[i].title||'').toLowerCase();
        for(var j=0;j<rxs.length;j++){if(rxs[j].test(lbl)){btns[i].click();return true;}}}return false;})()
        """
    }

    private func run(_ script: String) {
        Task.detached { _ = AppleScriptRunner.run(script) }
    }

    private func runInBrowserMediaTab(js: String) {
        Task.detached { _ = BrowserControlBridge.run(js: js) }
    }

    private func kickRefresh() {
        // Give the source a moment to commit, then re-poll so UI reflects new state.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.coordinator.requestImmediatePoll()
        }
    }
}
