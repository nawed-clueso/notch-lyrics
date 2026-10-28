import SwiftUI

/// Where lyrics come from. LRCLIB always; Spotify's own lines on top when the
/// user opts in and signs in with their web player cookie.
struct LyricsPane: View {
    @State private var enabled = SpotifyLyricsSettings.isEnabled
    @State private var hasCookie = SpotifyLyricsSettings.cookie != nil
    @State private var draft = ""
    @State private var check: SpotifyLyricsClient.CheckResult?
    @State private var checking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header
                spotifyCard
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.section)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(SP.bgColor)
        .foregroundStyle(SP.textPrimary)
        .task { if hasCookie { await runCheck() } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Text("Lyrics")
                .font(Typo.title(28))
            Text("Synced lyrics come from LRCLIB. Songs playing in Spotify can use Spotify's own lyrics instead.")
                .font(Typo.copy)
                .foregroundStyle(SP.textSecondary)
        }
    }

    private var spotifyCard: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack(alignment: .top, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Spotify Lyrics").font(Typo.heading)
                    Text("For songs playing in the Spotify app or open.spotify.com. Lines are timed to the exact recording. If Spotify has none, LRCLIB is used.")
                        .font(Typo.caption)
                        .foregroundStyle(SP.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Space.lg)
                Toggle("Spotify Lyrics", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(SP.accent)
                    .onChange(of: enabled) { _, on in SpotifyLyricsSettings.isEnabled = on }
            }

            if hasCookie {
                StatusRow(icon: "person.crop.circle", title: "Spotify Sign-In",
                          detail: statusDetail, status: status) {
                    HStack(spacing: Space.sm) {
                        Button(checking ? "Checking…" : "Check Again") { Task { await runCheck() } }
                            .buttonStyle(MiniButtonStyle(filled: false))
                            .disabled(checking)
                        Button("Remove") {
                            SpotifyLyricsSettings.clearCookie()
                            hasCookie = false
                            check = nil
                        }
                        .buttonStyle(MiniButtonStyle(filled: false))
                    }
                }
            } else {
                cookieEntry
            }

            InfoNote(icon: "exclamationmark.triangle", tint: SP.warning,
                     text: "This signs in the way Spotify's web player does. It isn't a public API, so it can stop working when Spotify changes the web player. Songs then fall back to LRCLIB.")
        }
        .card(fill: SP.surface)
    }

    private var cookieEntry: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                SecureField("sp_dc cookie", text: $draft)
                    .textFieldStyle(.plain)
                    .font(Typo.mono)
                    .padding(.horizontal, Space.md)
                    .frame(height: 30)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(SP.surfaceHi))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(SP.divider))
                    .onSubmit(save)
                Button("Save") { save() }
                    .buttonStyle(PrimaryButtonStyle(filled: true))
                    .disabled(SpotifyLyricsSettings.normalise(draft).isEmpty)
            }
            InfoNote(icon: "info.circle",
                     text: "In a browser signed in to open.spotify.com, open Developer Tools, go to Application (Storage in Safari) › Cookies › open.spotify.com, and copy the value of sp_dc. It signs in as you, so it's kept in your Keychain and only sent to Spotify.")
        }
    }

    private var status: OnboardingChecks.Status {
        if checking { return .notDetermined }
        switch check {
        case .connected: return .satisfied
        case .cookieRejected, .unavailable: return .blocked
        case .noCookie: return .missing
        case nil: return .notDetermined
        }
    }

    private var statusDetail: String {
        if checking { return "Signing in to Spotify…" }
        switch check {
        case .connected: return "Signed in. Spotify lyrics are ready."
        case .cookieRejected: return "Spotify didn't accept this cookie. It may have expired: copy a fresh sp_dc and save it again."
        case .unavailable(let reason): return reason
        case .noCookie: return "No cookie saved."
        case nil: return "Not checked yet."
        }
    }

    private func save() {
        let value = SpotifyLyricsSettings.normalise(draft)
        guard !value.isEmpty else { return }
        SpotifyLyricsSettings.saveCookie(value)
        draft = ""
        hasCookie = true
        // Saving a cookie means they want it used.
        enabled = true
        Task { await runCheck() }
    }

    private func runCheck() async {
        checking = true
        check = await SpotifyLyricsClient.shared.check()
        checking = false
    }
}
