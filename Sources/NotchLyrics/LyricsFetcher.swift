import Foundation
import os.log

private let lyricsLogger = Logger(subsystem: "com.notchlyrics.app", category: "lyrics")

struct LyricLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Double      // seconds
    let text: String
}

struct LyricsBundle: Equatable {
    let lines: [LyricLine]
    let isSynced: Bool
}

actor LyricsFetcher {
    private var cache: [String: LyricsBundle] = [:]

    func lyrics(track: String, artist: String, album: String, duration: Double) async -> LyricsBundle? {
        let key = "\(track)|\(artist)|\(Int(duration))"
        if let cached = cache[key] { return cached }
        let result = await fetchFromLRCLib(track: track, artist: artist, album: album, duration: duration)
        if let result { cache[key] = result }
        return result
    }

    // MARK: - LRCLib

    private func fetchFromLRCLib(track: String, artist: String, album: String, duration: Double) async -> LyricsBundle? {
        // Strip "(feat. …)" / "[Remastered]" / "- Live" markers — they tank LRCLib hit rate.
        // Local files often arrive titled as their filename ("Essex_Honey.mp3"), so
        // also drop a trailing audio extension and turn underscores into spaces.
        let cleanTrack = track
            .replacingOccurrences(of: #"\.(mp3|m4a|aac|flac|wav|aiff?|ogg|opus|wma)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+-\s+(Remastered|Live|Acoustic).*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let cleanArtist = artist
            .components(separatedBy: ",")
            .first?
            .trimmingCharacters(in: .whitespaces) ?? artist

        lyricsLogger.log("🎤 lookup: '\(cleanTrack, privacy: .public)' by '\(cleanArtist, privacy: .public)' dur=\(Int(duration), privacy: .public)")

        guard var components = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "track_name", value: cleanTrack),
            URLQueryItem(name: "artist_name", value: cleanArtist),
            URLQueryItem(name: "album_name", value: album),
            URLQueryItem(name: "duration", value: String(Int(duration)))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        // lrclib.net can be slow to reach on some networks (VPN / poor IPv6 path),
        // taking 10s+ for the round-trip. A short timeout silently drops every
        // lookup, so allow generous headroom.
        request.timeoutInterval = 20
        request.setValue("NotchLyrics/1.0 (personal use)", forHTTPHeaderField: "User-Agent")

        let bundle: LyricsBundle? = await {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    lyricsLogger.log("🎤 /api/get returned 200")
                    return parseResponse(data: data)
                }
            } catch {}
            return nil
        }()

        // Prefer synced lyrics above all. If /api/get already gave us a synced
        // bundle, use it. If it only returned plain (unsynced) lyrics, still try the
        // search endpoint — a synced version often exists under a slightly different
        // release — and only fall back to the unsynced bundle if the search can't
        // find a synced match either.
        if let bundle, bundle.isSynced { return bundle }

        if bundle == nil {
            lyricsLogger.log("🎤 /api/get missed; falling back to search")
        } else {
            lyricsLogger.log("🎤 /api/get returned unsynced; searching for a synced version")
        }
        // Fallback: search endpoint, then score results to avoid grabbing the
        // first random cover / karaoke version when the title alone matches.
        let searched = await searchFallback(track: cleanTrack, artist: cleanArtist, duration: duration)
        if let searched, searched.isSynced { return searched }
        // Neither source produced synced lyrics — use whatever we have, if anything.
        return bundle ?? searched
    }

    private func searchFallback(track: String, artist: String, duration: Double) async -> LyricsBundle? {
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "track_name", value: track),
            URLQueryItem(name: "artist_name", value: artist)
        ]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("NotchLyrics/1.0 (personal use)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  !arr.isEmpty else {
                lyricsLogger.log("🎤 search: no results")
                return nil
            }
            lyricsLogger.log("🎤 search: \(arr.count, privacy: .public) candidates, scoring…")

            // Score each candidate: closer artist match + closer duration wins.
            // Reject anything below a minimum threshold so we don't surface a
            // completely unrelated track just because the title shares words.
            let scored = arr.map { entry -> (score: Double, entry: [String: Any]) in
                let candTrack = (entry["trackName"] as? String ?? "").lowercased()
                let candArtist = (entry["artistName"] as? String ?? "").lowercased()
                let candDur = (entry["duration"] as? Double)
                    ?? Double(entry["duration"] as? Int ?? 0)

                let qTrack = track.lowercased()
                let qArtist = artist.lowercased()

                let titleScore = stringSimilarity(qTrack, candTrack)
                let artistScore = stringSimilarity(qArtist, candArtist)
                // Duration: full credit within 2s, decays to 0 by 15s difference.
                let durDelta = abs(candDur - duration)
                let durScore = max(0, 1 - max(0, durDelta - 2) / 13)

                // Weight artist heaviest (covers usually share title, not artist).
                let total = 0.55 * artistScore + 0.30 * titleScore + 0.15 * durScore
                return (total, entry)
            }
            .sorted { $0.score > $1.score }

            // Keep only candidates we're confident actually match the track (below
            // the threshold it's too dubious to trust — better no lyrics than a
            // different song's). Then PREFER a synced candidate among them: LRCLib
            // search often ranks an unsynced entry above a synced one, but synced is
            // always the better experience. Falls back to the top relevance match
            // when none of the acceptable candidates are synced.
            let acceptable = scored.filter { $0.score >= 0.55 }
            guard !acceptable.isEmpty else {
                lyricsLogger.log("🎤 best score below threshold — refusing to use")
                return nil
            }
            let chosen = acceptable.first(where: { self.entryHasSynced($0.entry) }) ?? acceptable[0]

            let chosenTitle = (chosen.entry["trackName"] as? String) ?? "?"
            let chosenArtist = (chosen.entry["artistName"] as? String) ?? "?"
            let chosenSynced = entryHasSynced(chosen.entry)
            lyricsLogger.log("🎤 search chose: '\(chosenTitle, privacy: .public)' by '\(chosenArtist, privacy: .public)' score=\(String(format: "%.2f", chosen.score), privacy: .public) synced=\(chosenSynced, privacy: .public)")

            let json = try JSONSerialization.data(withJSONObject: chosen.entry)
            return parseResponse(data: json)
        } catch {
            lyricsLogger.log("🎤 search error: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// True when a search candidate carries non-empty synced (timestamped) lyrics.
    private func entryHasSynced(_ entry: [String: Any]) -> Bool {
        (entry["syncedLyrics"] as? String).map { !$0.isEmpty } ?? false
    }

    /// 0…1 similarity: 1.0 if equal, decays with edit-distance-ish substring
    /// overlap. Cheap to compute and good enough for picking between LRCLib
    /// candidates.
    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1.0 }
        if a.isEmpty || b.isEmpty { return 0 }
        if a.contains(b) || b.contains(a) {
            return Double(min(a.count, b.count)) / Double(max(a.count, b.count))
        }
        // Token-overlap heuristic for "mike myers vs mike myers feat ...".
        let aTokens = Set(a.split(separator: " ").map(String.init))
        let bTokens = Set(b.split(separator: " ").map(String.init))
        let inter = aTokens.intersection(bTokens).count
        let union = aTokens.union(bTokens).count
        return union == 0 ? 0 : Double(inter) / Double(union)
    }

    private func parseResponse(data: Data) -> LyricsBundle? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let synced = obj["syncedLyrics"] as? String, !synced.isEmpty {
            return LyricsBundle(lines: parseLRC(synced), isSynced: true)
        }
        if let plain = obj["plainLyrics"] as? String, !plain.isEmpty {
            // No timestamps — manufacture even spacing across the duration so we at least
            // advance through lines instead of showing the whole song at once.
            let parts = plain.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let spacing = 4.0
            let lines = parts.enumerated().map { idx, text in
                LyricLine(timestamp: Double(idx) * spacing, text: text)
            }
            return LyricsBundle(lines: lines, isSynced: false)
        }
        return nil
    }

    /// Parses `[mm:ss.xx]Line text` repeated.
    private func parseLRC(_ text: String) -> [LyricLine] {
        let pattern = #"\[(\d+):(\d+(?:\.\d+)?)\]([^\r\n]*)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        var out: [LyricLine] = []
        for m in matches where m.numberOfRanges == 4 {
            let minutes = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let seconds = Double(ns.substring(with: m.range(at: 2))) ?? 0
            let line = ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces)
            out.append(LyricLine(timestamp: minutes * 60 + seconds, text: line))
        }
        return out.sorted { $0.timestamp < $1.timestamp }
    }
}
