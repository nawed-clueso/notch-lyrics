import Foundation

/// Apple Music (Music.app) via AppleScript. Same shape as Spotify.
struct AppleMusicSource: PlaybackSource {
    let name = "Apple Music"

    private static let script = """
    if application "Music" is not running then return ""
    tell application "Music"
        if player state is stopped then return ""
        try
            set t to name of current track
            set a to artist of current track
            set al to album of current track
            set p to player position
            set d to duration of current track
            set i to (persistent ID of current track) as text
            set s to player state as string
            return t & "|||" & a & "|||" & al & "|||" & p & "|||" & d & "|||" & i & "|||" & s
        on error
            return ""
        end try
    end tell
    """

    func fetch() -> NowPlayingInfo? {
        guard let raw = AppleScriptRunner.run(Self.script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count == 7,
              let pos = Double(parts[3].replacingOccurrences(of: ",", with: ".")),
              let dur = Double(parts[4].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        return NowPlayingInfo(
            id: "music:" + parts[5],
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            duration: dur,
            elapsedAtCapture: pos,
            captureTimestamp: Date(),
            isPlaying: parts[6] == "playing",
            artworkData: nil,
            artworkURL: nil,
            sourceName: name,
            kind: .music
        )
    }
}
