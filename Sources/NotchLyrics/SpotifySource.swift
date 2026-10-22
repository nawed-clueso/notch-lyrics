import Foundation

/// Reads playback state from the Spotify desktop app via AppleScript.
struct SpotifySource: PlaybackSource {
    let name = "Spotify"

    private static let script = """
    if application "Spotify" is not running then return ""
    tell application "Spotify"
        if player state is stopped then return ""
        set t to name of current track
        set a to artist of current track
        set al to album of current track
        set p to player position
        set d to (duration of current track) / 1000
        set i to id of current track
        set s to player state as string
        set art to artwork url of current track
        return t & "|||" & a & "|||" & al & "|||" & p & "|||" & d & "|||" & i & "|||" & s & "|||" & art
    end tell
    """

    func fetch() -> NowPlayingInfo? {
        guard let raw = AppleScriptRunner.run(Self.script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count >= 7,
              let pos = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
              let dur = Double(parts[4].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        let artURL = parts.count >= 8 ? parts[7] : ""
        return NowPlayingInfo(
            id: "spotify:" + parts[5].replacingOccurrences(of: "spotify:track:", with: ""),
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: dur,
            elapsedAtCapture: pos,
            captureTimestamp: Date(),
            isPlaying: parts[6] == "playing",
            artworkData: nil,
            artworkURL: artURL.isEmpty ? nil : artURL,
            sourceName: name,
            kind: .music
        )
    }
}

enum AppleScriptRunner {
    static func run(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let descriptor = script.executeAndReturnError(&error)
        if error != nil { return nil }
        return descriptor.stringValue
    }
}
