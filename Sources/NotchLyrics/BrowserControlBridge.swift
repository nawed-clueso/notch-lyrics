import Foundation

/// Sends a JS payload to the first browser tab that's playing media, mirroring the tab
/// discovery in BrowserMediaSource. Used for play/pause/next/prev control.
enum BrowserControlBridge {
    private static let hostHints = [
        "music.youtube.com", "youtube.com", "soundcloud.com",
        "music.apple.com", "open.spotify.com", "bandcamp.com",
        "vimeo.com", "twitch.tv", "music.amazon.com", "tidal.com",
        "deezer.com", "audiomack.com"
    ]
    private static let browserDialects: [(appName: String, isSafari: Bool)] = [
        ("Safari", true),
        ("Google Chrome", false), ("Arc", false),
        ("Brave Browser", false), ("Microsoft Edge", false)
    ]

    @discardableResult
    static func run(js: String) -> String? {
        let escapedJS = js
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let hostsList = hostHints.map { "\"\($0)\"" }.joined(separator: ", ")

        for (appName, isSafari) in browserDialects {
            guard AppleScriptRunner.run("application \"\(appName)\" is running") == "true" else { continue }
            let body: String
            if isSafari {
                body = """
                tell application "\(appName)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                set u to URL of t as string
                                repeat with h in hosts
                                    if u contains h then
                                        do JavaScript js in t
                                        return "ok"
                                    end if
                                end repeat
                            end try
                        end repeat
                    end repeat
                end tell
                """
            } else {
                body = """
                tell application "\(appName)"
                    repeat with w in windows
                        repeat with t in tabs of w
                            try
                                set u to URL of t as string
                                repeat with h in hosts
                                    if u contains h then
                                        execute t javascript js
                                        return "ok"
                                    end if
                                end repeat
                            end try
                        end repeat
                    end repeat
                end tell
                """
            }
            let script = """
            set js to "\(escapedJS)"
            set hosts to {\(hostsList)}
            try
                \(body)
            end try
            return ""
            """
            if AppleScriptRunner.run(script) == "ok" {
                return "ok"
            }
        }
        return nil
    }
}
