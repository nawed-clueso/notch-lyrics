import Foundation
import AppKit
import AVFoundation
import CoreAudio

/// Live probes for everything Notch Lyrics needs from the system. Every check
/// is cheap and side-effect free unless its name says otherwise, so the
/// onboarding UI can re-run the whole set on demand.
enum OnboardingChecks {

    // MARK: - Result vocabulary

    enum Status: Equatable, Sendable {
        case satisfied
        case missing
        /// Never asked — an in-app prompt can still resolve it.
        case notDetermined
        /// Refused, or otherwise only fixable in System Settings.
        case blocked
        /// The app being probed isn't installed, so there's nothing to grant.
        case notApplicable

        var isSatisfied: Bool { self == .satisfied }
    }

    // MARK: - Automation (Apple Events)

    /// Apps whose playback state the lyrics engine reads over Apple Events.
    /// Browsers are deliberately excluded: `BrowserMediaSource` covers many of
    /// them and prompting for each would be a wall of dialogs.
    static let automationTargets: [(bundleID: String, name: String)] = [
        ("com.spotify.client", "Spotify"),
        ("com.apple.Music", "Apple Music")
    ]

    /// Whether this app may drive `bundleID` over Apple Events.
    ///
    /// `askUserIfNeeded: false` keeps this silent, so it is safe to call on
    /// every re-check. Pass `true` only from an explicit user action, and only
    /// off the main thread — the call blocks until the dialog is dismissed.
    static func automationStatus(for bundleID: String, askUserIfNeeded: Bool = false) -> Status {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil else {
            return .notApplicable
        }

        var target = AEAddressDesc()
        let created = bundleID.withCString { ptr -> OSErr in
            AECreateDesc(typeApplicationBundleID, ptr, strlen(ptr), &target)
        }
        guard created == noErr else { return .missing }
        defer { AEDisposeDesc(&target) }

        // typeWildCard for class/ID is the documented way to ask about the
        // whole target rather than one specific event.
        let status = AEDeterminePermissionToAutomateTarget(
            &target, typeWildCard, typeWildCard, askUserIfNeeded
        )

        switch status {
        case noErr:                            return .satisfied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        case OSStatus(errAEEventNotPermitted): return .blocked
        case OSStatus(procNotFound):
            // Installed but not running. Nothing has been denied; the grant
            // resolves the first time the app is actually launched.
            return .notDetermined
        default:                               return .blocked
        }
    }

    /// Worst status across every automation target that is actually installed.
    static func automationSummary() -> Status {
        let applicable = automationTargets
            .map { automationStatus(for: $0.bundleID) }
            .filter { $0 != .notApplicable }
        if applicable.isEmpty { return .notApplicable }
        if applicable.contains(.blocked) { return .blocked }
        if applicable.contains(.notDetermined) { return .notDetermined }
        return .satisfied
    }

    // MARK: - Microphone (the effects engine's capture path)

    static func microphoneStatus() -> Status {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:    .satisfied
        case .notDetermined: .notDetermined
        default:             .blocked
        }
    }

    /// Resolves microphone access before the engine opens an input.
    ///
    /// Granting it mid-start makes CoreAudio re-initialise the input audio unit
    /// underneath the engine, so every caller that starts the engine must come
    /// through here first — not just the Audio pane. Returns nil on success, or
    /// a message to show the user.
    @MainActor
    static func ensureMicrophoneAccess() async -> String? {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return nil
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            // CoreAudio re-initialises briefly as the prompt closes; let it
            // settle before anything touches an audio unit.
            try? await Task.sleep(nanoseconds: 250_000_000)
            return granted
                ? nil
                : "Microphone access was denied, so the engine can't read the loopback input. Turn Notch Lyrics on in System Settings › Privacy & Security › Microphone, then try again."
        default:
            return "Microphone access is blocked. Turn Notch Lyrics on in System Settings › Privacy & Security › Microphone, then try again."
        }
    }

    // MARK: - Loopback driver

    /// BlackHole, surfaced in the UI as "Notch Lyrics Bridge".
    static func loopbackStatus() -> Status {
        CoreAudioDevices.list().contains { $0.isBlackHole && $0.hasInput } ? .satisfied : .missing
    }

    /// System audio must be *sent* to the loopback device, otherwise the
    /// effects chain captures silence no matter how it's routed.
    static func systemOutputStatus() -> Status {
        guard let uid = CoreAudioDevices.defaultOutputUID() else { return .missing }
        guard let device = CoreAudioDevices.list().first(where: { $0.uid == uid }) else { return .missing }
        return device.isBlackHole ? .satisfied : .missing
    }

    static func currentSystemOutputName() -> String {
        guard let uid = CoreAudioDevices.defaultOutputUID(),
              let device = CoreAudioDevices.list().first(where: { $0.uid == uid })
        else { return "unknown" }
        return device.isBlackHole ? "Notch Lyrics Bridge" : device.name
    }

    // MARK: - media-control CLI (optional, powers non-scriptable apps)

    static let mediaControlPaths = [
        "/opt/homebrew/bin/media-control",
        "/usr/local/bin/media-control"
    ]

    static func mediaControlStatus() -> Status {
        mediaControlPaths.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
            ? .satisfied : .missing
    }

    // MARK: - Deep links

    enum SettingsPane: String {
        case automation  = "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        case microphone  = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case sound       = "x-apple.systempreferences:com.apple.preference.sound"
    }

    static func openSettings(_ pane: SettingsPane) {
        guard let url = URL(string: pane.rawValue) else { return }
        NSWorkspace.shared.open(url)
    }

    static func copyToClipboard(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
