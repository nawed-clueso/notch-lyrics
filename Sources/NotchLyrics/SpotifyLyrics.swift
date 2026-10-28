import CryptoKit
import Foundation
import Security
import os.log

private let spotifyLogger = Logger(subsystem: "com.notchlyrics.app", category: "spotify-lyrics")

/// Opt-in lyrics from Spotify itself (Musixmatch's synced lines, timed to the
/// exact recording), for tracks playing in Spotify.
///
/// There is no public API for this. It signs in the way the Spotify web player
/// does: the user's `sp_dc` cookie plus a TOTP code whose secret ships inside
/// the web player's JavaScript. Spotify rotates that secret, so it is read
/// from the live bundle rather than hard-coded. Anything here can break when
/// Spotify changes the web player, and every failure falls back to LRCLIB.
enum SpotifyLyricsSettings {
    /// Posted after the toggle or the cookie changes.
    static let didChange = Notification.Name("SpotifyLyricsSettingsDidChange")

    private static let enabledKey = "spotifyLyricsEnabled"
    private static let keychainService = "com.notchlyrics.app.spotify"
    private static let keychainAccount = "sp_dc"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    /// The `sp_dc` cookie. It signs in as the user, so it lives in the
    /// Keychain, never in defaults.
    static var cookie: String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func saveCookie(_ value: String) {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ] as CFDictionary)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attrs as CFDictionary, nil)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    static func clearCookie() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        SecItemDelete(query as CFDictionary)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Accepts the bare value or a pasted `sp_dc=…; …` cookie string.
    static func normalise(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let range = value.range(of: "sp_dc=") {
            value = String(value[range.upperBound...])
        }
        if let end = value.firstIndex(of: ";") { value = String(value[..<end]) }
        return value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
    }
}

/// The 22-character base-62 id Spotify uses for a track, or nil for local
/// files, episodes and anything else.
func spotifyTrackID(from raw: String) -> String? {
    let id = raw
        .replacingOccurrences(of: "spotify:track:", with: "")
        .replacingOccurrences(of: "spotify:", with: "")
    guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
    return id
}

actor SpotifyLyricsClient {
    static let shared = SpotifyLyricsClient()

    enum CheckResult: Equatable {
        case connected
        case noCookie
        /// Spotify answered but treated the cookie as signed out.
        case cookieRejected
        /// The web player's sign-in step couldn't be completed.
        case unavailable(String)
    }

    private struct Secret {
        let key: Data
        let version: String
    }

    private struct Token {
        let value: String
        let expires: Date
        let cookie: String
    }

    private var secret: Secret?
    private var token: Token?

    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        // The cookie is sent by hand on the one request that needs it, so
        // nothing else picks it up.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    // MARK: - Lyrics

    func lyrics(trackID: String) async -> LyricsBundle? {
        guard SpotifyLyricsSettings.isEnabled, let cookie = SpotifyLyricsSettings.cookie else { return nil }
        for attempt in 0..<2 {
            guard let access = await accessToken(cookie: cookie, forceRefresh: attempt > 0) else { return nil }
            var components = URLComponents(string: "https://spclient.wg.spotify.com/color-lyrics/v2/track/\(trackID)")!
            components.queryItems = [
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "vocalRemoval", value: "false"),
                URLQueryItem(name: "market", value: "from_token"),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            request.setValue("WebPlayer", forHTTPHeaderField: "app-platform")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

            guard let (data, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse
            else { return nil }
            switch http.statusCode {
            case 200:
                let bundle = Self.parse(data)
                spotifyLogger.log("🎤 spotify lyrics \(trackID, privacy: .public): \(bundle?.lines.count ?? 0, privacy: .public) lines synced=\(bundle?.isSynced ?? false, privacy: .public)")
                return bundle
            case 401:
                token = nil
                continue
            default:
                // 404 means Spotify has no lyrics for this track.
                spotifyLogger.log("🎤 spotify lyrics \(trackID, privacy: .public): HTTP \(http.statusCode, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// Signs in with the saved cookie, for the settings pane.
    func check() async -> CheckResult {
        guard let cookie = SpotifyLyricsSettings.cookie else { return .noCookie }
        token = nil
        do {
            let fresh = try await requestToken(cookie: cookie)
            return fresh == nil ? .cookieRejected : .connected
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) -> LyricsBundle? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let lyrics = root["lyrics"] as? [String: Any],
              let rawLines = lyrics["lines"] as? [[String: Any]],
              !rawLines.isEmpty
        else { return nil }
        let synced = (lyrics["syncType"] as? String) != "UNSYNCED"
        let lines = rawLines.enumerated().map { index, line -> LyricLine in
            let words = (line["words"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            // Spotify marks instrumental gaps with a note; an empty line is
            // what the card turns into break dots.
            let text = words == "♪" ? "" : words
            let start = (line["startTimeMs"] as? String).flatMap(Double.init) ?? 0
            // Unsynced lines all start at 0, so space them out the way the
            // LRCLIB plain-lyrics fallback does.
            return LyricLine(timestamp: synced ? start / 1000 : Double(index) * 4, text: text)
        }
        return LyricsBundle(lines: lines, isSynced: synced)
    }

    // MARK: - Access token

    private func accessToken(cookie: String, forceRefresh: Bool) async -> String? {
        if !forceRefresh, let token, token.cookie == cookie, token.expires > Date().addingTimeInterval(60) {
            return token.value
        }
        do {
            return try await requestToken(cookie: cookie)?.value
        } catch {
            spotifyLogger.log("🎤 spotify sign-in failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// A signed-in web player token, or nil when Spotify rejects the cookie
    /// or treats it as signed out. Throws when the sign-in step itself fails.
    private func requestToken(cookie: String) async throws -> Token? {
        for attempt in 0..<2 {
            let secret = try await currentSecret(refresh: attempt > 0)
            let serverTime = try await self.serverTime()
            var components = URLComponents(string: "https://open.spotify.com/api/token")!
            components.queryItems = [
                URLQueryItem(name: "reason", value: "init"),
                URLQueryItem(name: "productType", value: "web-player"),
                URLQueryItem(name: "totp", value: Self.totp(key: secret.key, at: Date().timeIntervalSince1970)),
                URLQueryItem(name: "totpServer", value: Self.totp(key: secret.key, at: serverTime)),
                URLQueryItem(name: "totpVer", value: secret.version),
            ]
            var request = URLRequest(url: components.url!)
            request.setValue("sp_dc=\(cookie)", forHTTPHeaderField: "Cookie")
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 401: the TOTP passed but the cookie is expired or wrong.
            if status == 401 || status == 403 { return nil }
            // Any other refusal (400 is a rejected TOTP) retries once with a
            // freshly read secret.
            guard status == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = obj["accessToken"] as? String
            else {
                if attempt == 0 { continue }
                throw SpotifyError("Spotify refused the sign-in (HTTP \(status)).")
            }
            if obj["isAnonymous"] as? Bool == true { return nil }
            let expiresMs = obj["accessTokenExpirationTimestampMs"] as? Double ?? 0
            let fresh = Token(value: value,
                              expires: Date(timeIntervalSince1970: expiresMs / 1000),
                              cookie: cookie)
            token = fresh
            return fresh
        }
        return nil
    }

    private func serverTime() async throws -> Double {
        var request = URLRequest(url: URL(string: "https://open.spotify.com/api/server-time")!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await session.data(for: request)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let time = obj["serverTime"] as? Double
        else { return Date().timeIntervalSince1970 }
        return time
    }

    // MARK: - TOTP secret

    private func currentSecret(refresh: Bool) async throws -> Secret {
        if !refresh, let secret { return secret }
        let fresh = try await fetchSecret()
        secret = fresh
        return fresh
    }

    /// Reads the newest `{secret, version}` pair out of the web player bundle.
    private func fetchSecret() async throws -> Secret {
        var home = URLRequest(url: URL(string: "https://open.spotify.com/")!)
        home.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        let (htmlData, _) = try await session.data(for: home)
        let html = String(decoding: htmlData, as: UTF8.self)
        guard let bundleURL = Self.firstMatch(
            #"https://open\.spotifycdn\.com/cdn/build/web-player/web-player\.[a-z0-9]+\.js"#, in: html
        ).flatMap({ URL(string: $0[0]) }) else {
            throw SpotifyError("Couldn't find the Spotify web player.")
        }
        let (jsData, _) = try await session.data(from: bundleURL)
        let js = String(decoding: jsData, as: UTF8.self)
        // The list is newest first: [{secret:'…',version:61},{…}].
        guard let match = Self.firstMatch(#"\[\{secret:(['"])((?:\\.|(?!\1).)*)\1,version:(\d+)\}"#, in: js) else {
            throw SpotifyError("Couldn't read the Spotify sign-in secret.")
        }
        let raw = Self.unescapeJS(match[2])
        // Each character is XORed with its index, and the decimal results
        // joined into one string, whose UTF-8 bytes are the HMAC key.
        let digits = raw.unicodeScalars.enumerated()
            .map { String(Int($0.element.value) ^ ($0.offset % 33 + 9)) }
            .joined()
        spotifyLogger.log("🎤 spotify secret version \(match[3], privacy: .public)")
        return Secret(key: Data(digits.utf8), version: match[3])
    }

    static func totp(key: Data, at time: Double) -> String {
        var counter = UInt64(time / 30).bigEndian
        let message = Data(bytes: &counter, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(mac[mac.count - 1] & 0x0f)
        let code = (UInt32(mac[offset] & 0x7f) << 24)
            | (UInt32(mac[offset + 1]) << 16)
            | (UInt32(mac[offset + 2]) << 8)
            | UInt32(mac[offset + 3])
        return String(format: "%06d", code % 1_000_000)
    }

    /// Capture groups of the first match, index 0 being the whole match.
    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) } ?? ""
        }
    }

    /// Undoes JavaScript string-literal escapes.
    private static func unescapeJS(_ s: String) -> String {
        var out = ""
        var chars = s.makeIterator()
        while let c = chars.next() {
            guard c == "\\", let next = chars.next() else { out.append(c); continue }
            switch next {
            case "x", "u":
                let width = next == "x" ? 2 : 4
                var hex = ""
                for _ in 0..<width { if let h = chars.next() { hex.append(h) } }
                if let value = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                }
            case "n": out.append("\n")
            case "t": out.append("\t")
            default: out.append(next)
            }
        }
        return out
    }
}

struct SpotifyError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
