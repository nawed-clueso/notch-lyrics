import Foundation

/// Reads the macOS system Now Playing session via the `media-control` CLI
/// (a MediaRemote adapter, `brew install media-control`). This sees whatever
/// any app publishes to the system media center — regardless of app focus —
/// so it catches players the AppleScript sources can't reach. Notably Dia,
/// which only answers AppleScript JavaScript for its frontmost active tab.
///
/// Ordered AFTER the dedicated sources: they provide richer data (track ids,
/// host-aware music/video kinds), and this source skips their bundle ids so a
/// paused native player doesn't show up twice under a different source name.
struct NowPlayingSource: PlaybackSource {
    let name = "Now Playing"

    /// Homebrew locations (Apple Silicon, then Intel). Nil = tool not installed;
    /// the source just stays silent in that case.
    static let binaryPath: String? = [
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control"
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    /// Apps already covered by dedicated sources.
    private static let nativeBundles: Set<String> = [
        "com.spotify.client", "com.apple.Music", "com.apple.QuickTimePlayerX"
    ]

    /// Pretty names for known browser bundle ids (shown in the pill's subtitle).
    private static let appNames: [String: String] = [
        "company.thebrowser.dia": "Dia",
        "company.thebrowser.Browser": "Arc",
        "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari",
        "com.brave.Browser": "Brave",
        "com.microsoft.edgemac": "Edge"
    ]

    func fetch() -> NowPlayingInfo? {
        guard let bin = Self.binaryPath else { return nil }
        guard let obj = Self.runGet(bin) else { return nil }

        guard let title = obj["title"] as? String, !title.isEmpty else { return nil }
        let bundle = obj["bundleIdentifier"] as? String ?? ""
        if Self.nativeBundles.contains(bundle) { return nil }

        let artist = obj["artist"] as? String ?? ""
        let album = obj["album"] as? String ?? ""
        let duration = obj["duration"] as? Double ?? 0
        let elapsed = obj["elapsedTime"] as? Double ?? 0
        let playing = obj["playing"] as? Bool ?? false

        // The payload's elapsedTime is valid at `timestamp`, not at read time;
        // NowPlayingInfo.currentPosition extrapolates from captureTimestamp.
        var captured = Date()
        if let s = obj["timestamp"] as? String,
           let parsed = ISO8601DateFormatter().date(from: s) {
            captured = parsed
        }

        var artworkData: Data?
        if let b64 = obj["artworkData"] as? String {
            artworkData = Data(base64Encoded: b64)
        }

        let appName = Self.appNames[bundle] ?? bundle.components(separatedBy: ".").last?.capitalized ?? "Media"

        return NowPlayingInfo(
            id: "np:\(bundle):\(title.lowercased())|\(artist.lowercased())",
            title: title,
            artist: artist,
            album: album,
            duration: duration,
            elapsedAtCapture: elapsed,
            captureTimestamp: captured,
            isPlaying: playing,
            artworkData: artworkData,
            artworkURL: nil,
            sourceName: "Now Playing (\(appName))",
            // Same heuristic as the browser source's YouTube fallback: media
            // with a declared artist is (probably) music worth a lyric lookup.
            kind: artist.isEmpty ? .video : .music
        )
    }

    /// Runs `media-control get` with a hard 3s bound so a wedged helper can
    /// never stall the poll loop.
    ///
    /// The pipe MUST be drained concurrently: the payload embeds the artwork
    /// JPEG as base64 and can exceed the 64KB pipe buffer, in which case the
    /// child blocks on write and never exits — waiting for exit before reading
    /// would deadlock into the timeout and drop every update.
    private static func runGet(_ bin: String) -> [String: Any]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["get"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }

        var data = Data()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }
        if drained.wait(timeout: .now() + 3) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Fire-and-forget playback command (`toggle-play-pause`, `next-track`, …).
    static func command(_ args: String...) {
        guard let bin = binaryPath else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
    }
}
