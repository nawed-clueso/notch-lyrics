import Foundation
import AppKit

/// Hint for the UI: should we attempt lyric lookup and show a lyric stack,
/// or treat this as generic video/audio with no lyrics expected?
enum MediaKind: Equatable {
    case music   // Spotify, Apple Music, YT Music, SoundCloud, Bandcamp, etc.
    case video   // YouTube (regular), Vimeo, Twitch, QuickTime
}

/// Source-agnostic Now Playing snapshot.
struct NowPlayingInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double
    let elapsedAtCapture: Double
    let captureTimestamp: Date
    let isPlaying: Bool
    let artworkData: Data?
    let artworkURL: String?
    let sourceName: String
    let kind: MediaKind
    /// Spotify's own id for the track, when the source knows it. Lets the
    /// lyrics come from Spotify for exactly this recording.
    var spotifyTrackID: String? = nil

    var currentPosition: Double {
        guard isPlaying else { return elapsedAtCapture }
        return elapsedAtCapture + Date().timeIntervalSince(captureTimestamp)
    }

    /// The same track with the playhead moved to `position` as of now. Used
    /// after a seek, before the player has reported it.
    func at(position: Double) -> NowPlayingInfo {
        NowPlayingInfo(id: id, title: title, artist: artist, album: album,
                       duration: duration, elapsedAtCapture: position,
                       captureTimestamp: Date(), isPlaying: isPlaying,
                       artworkData: artworkData, artworkURL: artworkURL,
                       sourceName: sourceName, kind: kind,
                       spotifyTrackID: spotifyTrackID)
    }
}

/// A source publishes NowPlayingInfo when asked. Nil = nothing playing here.
protocol PlaybackSource {
    var name: String { get }
    func fetch() -> NowPlayingInfo?
}

/// Polls each source on a low-frequency loop. Prefers whichever source is actively
/// playing. Updates the listener only when something meaningful changed.
@MainActor
final class SourceCoordinator {
    typealias Listener = (NowPlayingInfo?) -> Void

    private let sources: [PlaybackSource]
    private var listener: Listener?
    private var pollTimer: Timer?
    private var lastEmitted: NowPlayingInfo?
    /// When nothing is currently playing, we prefer to keep showing whichever source
    /// WAS playing most recently, rather than letting a stale paused track from a
    /// higher-priority source steal the display.
    private var lastPlayingSourceName: String?

    init(sources: [PlaybackSource]) {
        self.sources = sources
    }

    func start(listener: @escaping Listener) {
        self.listener = listener
        poll()                       // fire immediately
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    /// Trigger an out-of-cycle poll, e.g. after dispatching a play/pause command so the
    /// UI reflects the new state without waiting for the next tick.
    func requestImmediatePoll() { poll() }

    /// Guards against stacking polls: if a source's AppleScript is slow (e.g. a
    /// browser tab mid-reload), we skip new ticks until the in-flight poll returns,
    /// instead of piling up blocked background threads that never recover.
    private var isPolling = false

    private func poll() {
        if isPolling { return }
        isPolling = true
        let snapshot = sources
        let lastPlayingName = lastPlayingSourceName
        DispatchQueue.global(qos: .userInitiated).async {
            var results: [NowPlayingInfo] = []
            var playingChoice: NowPlayingInfo?
            for source in snapshot {
                if let info = source.fetch() {
                    results.append(info)
                    if info.isPlaying, playingChoice == nil { playingChoice = info }
                }
            }
            let chosen: NowPlayingInfo?
            if let playing = playingChoice {
                chosen = playing
            } else if let lastName = lastPlayingName,
                      let preferred = results.first(where: { $0.sourceName == lastName }) {
                chosen = preferred           // stick with the most recent playing source while paused
            } else {
                chosen = results.first
            }
            DispatchQueue.main.async { [weak self] in
                self?.isPolling = false
                self?.emit(chosen)
            }
        }
    }

    private func emit(_ info: NowPlayingInfo?) {
        if info?.isPlaying == true { lastPlayingSourceName = info?.sourceName }
        // Avoid spam: only emit when something the UI cares about changed.
        if info?.id == lastEmitted?.id
            && info?.isPlaying == lastEmitted?.isPlaying
            && abs((info?.elapsedAtCapture ?? 0) - (lastEmitted?.elapsedAtCapture ?? 0)) < 0.3 {
            return
        }
        lastEmitted = info
        listener?(info)
    }
}
