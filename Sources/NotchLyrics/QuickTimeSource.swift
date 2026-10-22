import Foundation

/// QuickTime Player playback via AppleScript. Title comes from the document name
/// (file name minus extension). No artist/album/artwork.
struct QuickTimeSource: PlaybackSource {
    let name = "QuickTime"

    private static let script = """
    if application "QuickTime Player" is not running then return ""
    tell application "QuickTime Player"
        try
            if (count of documents) = 0 then return ""
            set d to document 1
            set n to name of d
            set t to (current time of d) as real
            set dur to (duration of d) as real
            set p to (playing of d) as text
            return n & "|||" & t & "|||" & dur & "|||" & p
        on error
            return ""
        end try
    end tell
    """

    func fetch() -> NowPlayingInfo? {
        guard let raw = AppleScriptRunner.run(Self.script), !raw.isEmpty else { return nil }
        let parts = raw.components(separatedBy: "|||")
        guard parts.count == 4,
              let pos = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              let dur = Double(parts[2].replacingOccurrences(of: ",", with: "."))
        else { return nil }
        // Strip common video file extensions for a cleaner title.
        var title = parts[0]
        for ext in [".mp4", ".mov", ".m4v", ".mkv", ".avi", ".m4a", ".mp3"] {
            if title.lowercased().hasSuffix(ext) {
                title = String(title.dropLast(ext.count))
                break
            }
        }
        return NowPlayingInfo(
            id: "qt:\(parts[0])",
            title: title,
            artist: "",
            album: "",
            duration: dur,
            elapsedAtCapture: pos,
            captureTimestamp: Date(),
            isPlaying: parts[3] == "true",
            artworkData: nil,
            artworkURL: nil,
            sourceName: name,
            kind: .video
        )
    }
}
