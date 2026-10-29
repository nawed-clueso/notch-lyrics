import AppKit
import SwiftUI
import AVFoundation

// MARK: - Steps

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, lyrics, nowPlaying, microphone, bridge, routing, vibe, done

    var id: Int { rawValue }

    var shortTitle: String {
        switch self {
        case .welcome:    "Welcome"
        case .lyrics:     "Lyrics"
        case .nowPlaying: "Players"
        case .microphone: "Capture"
        case .bridge:     "Bridge"
        case .routing:    "Routing"
        case .vibe:       "Sound"
        case .done:       "Done"
        }
    }
}

// MARK: - Live system probe

/// Polls every system dependency while Setup is open, so flipping a switch in
/// System Settings turns the row green without the user coming back to click
/// anything.
@MainActor
final class SystemProbe: ObservableObject {

    struct Snapshot: Sendable {
        var automation: [String: OnboardingChecks.Status] = [:]
        var microphone: OnboardingChecks.Status = .notDetermined
        var loopback: OnboardingChecks.Status = .missing
        var systemOutput: OnboardingChecks.Status = .missing
        var systemOutputName: String = "unknown"
        var mediaControl: OnboardingChecks.Status = .missing
        var devices: [AudioDevice] = []
        var running: Set<String> = []
    }

    @Published private(set) var snap = Snapshot()

    private var timer: Timer?

    var automationSummary: OnboardingChecks.Status {
        let applicable = snap.automation.values.filter { $0 != .notApplicable }
        if applicable.isEmpty { return .notApplicable }
        if applicable.contains(.blocked) { return .blocked }
        if applicable.contains(.notDetermined) { return .notDetermined }
        return .satisfied
    }

    func start() {
        refresh()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Probes run off-main: the TCC round-trip behind `automationStatus` is
    /// fast but not free, and this fires on a timer.
    func refresh() {
        // NSWorkspace's running-app list is read here, on main, rather than
        // inside the detached probe task.
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        Task.detached(priority: .utility) {
            var s = Snapshot()
            s.running = running
            for target in OnboardingChecks.automationTargets {
                s.automation[target.bundleID] = OnboardingChecks.automationStatus(for: target.bundleID)
            }
            s.microphone = OnboardingChecks.microphoneStatus()
            s.loopback = OnboardingChecks.loopbackStatus()
            s.systemOutput = OnboardingChecks.systemOutputStatus()
            s.systemOutputName = OnboardingChecks.currentSystemOutputName()
            s.mediaControl = OnboardingChecks.mediaControlStatus()
            s.devices = CoreAudioDevices.list()
            await MainActor.run { self.snap = s }
        }
    }
}

// MARK: - Pane

struct OnboardingPane: View {
    let onComplete: () -> Void

    @StateObject private var probe = SystemProbe()
    @State private var step: OnboardingStep = .welcome

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            progress
            ScrollView {
                stepBody
                    .padding(.horizontal, Space.xxl)
                    .padding(.top, Space.xl)
                    .padding(.bottom, Space.xxl)
                    .frame(maxWidth: 760, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .background(SP.bgColor)
        .onAppear { probe.start() }
        .onDisappear { probe.stop() }
    }

    // MARK: Progress

    private var progress: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.xs) {
                ForEach(OnboardingStep.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? SP.accent : Color.white.opacity(0.10))
                        .frame(height: 3)
                }
            }
            HStack {
                Text("Step \(step.rawValue + 1) of \(OnboardingStep.allCases.count)")
                    .font(Typo.caption)
                    .foregroundStyle(SP.textTertiary)
                Spacer()
                Text(step.shortTitle)
                    .font(Typo.caption)
                    .foregroundStyle(SP.textSecondary)
            }
        }
        .padding(.horizontal, Space.xxl)
        .padding(.top, Space.section)
        .animation(Motion.state, value: step)
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome:    WelcomeStep()
        case .lyrics:     LyricsStep(probe: probe)
        case .nowPlaying: NowPlayingStep(probe: probe)
        case .microphone: MicrophoneStep(probe: probe)
        case .bridge:     BridgeStep(probe: probe)
        case .routing:    RoutingStep(probe: probe)
        case .vibe:       VibeStep()
        case .done:       DoneStep(probe: probe)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: Space.md) {
            if step != .welcome {
                Button("Back") { goto(step.rawValue - 1) }
                    .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if step != .done {
                Button("Skip Setup") {
                    OnboardingState.markCompleted()
                    onComplete()
                }
                .buttonStyle(TertiaryButtonStyle(size: .medium))
            }
            Button(step == .done ? "Open Audio" : "Continue") {
                if step == .done { onComplete() } else { goto(step.rawValue + 1) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, Space.xxl)
        .padding(.vertical, Space.lg)
        .overlay(alignment: .top) { Rectangle().fill(SP.divider).frame(height: 1) }
    }

    private func goto(_ raw: Int) {
        guard let next = OnboardingStep(rawValue: raw) else { return }
        withAnimation(Motion.floating) { step = next }
        probe.refresh()
    }
}

// MARK: - Step: welcome

private struct WelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "WELCOME",
                title: "Lyrics in your notch,\neffects on everything.",
                subtitle: "Notch Lyrics parks a pill in the notch that follows along with whatever you're playing, and puts a full effects rack on your system audio. Setup takes about a minute."
            )
            VStack(alignment: .leading, spacing: Space.md) {
                FeatureRow(icon: "text.alignleft",
                           title: "Synced lyrics",
                           detail: "Spotify, Apple Music, YouTube Music, QuickTime, and anything using macOS Now Playing.")
                FeatureRow(icon: "slider.horizontal.3",
                           title: "11 presets, 10-band EQ",
                           detail: "Reverb, distortion, filters, pitch, pan, chorus and flange, live on system audio.")
                FeatureRow(icon: "macwindow.on.rectangle",
                           title: "One pill per display",
                           detail: "Windows appear and disappear as you plug monitors in and out.")
            }
            InfoNote(icon: "hand.raised",
                     text: "Each step asks macOS for one permission. Lyrics are looked up by song title and artist, and audio never leaves your Mac.")
        }
    }
}

// MARK: - Step: lyrics (Apple Events)

private struct LyricsStep: View {
    @ObservedObject var probe: SystemProbe

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "LYRICS ACCESS",
                title: "Let it read what's playing.",
                subtitle: "macOS calls this Automation. It lets Notch Lyrics ask your music apps for the current track and playback position, which is what keeps the lyrics in time.",
                status: probe.automationSummary
            )

            VStack(spacing: Space.sm) {
                ForEach(OnboardingChecks.automationTargets, id: \.bundleID) { target in
                    let status = probe.snap.automation[target.bundleID] ?? .notDetermined
                    StatusRow(
                        icon: "app.badge.checkmark",
                        title: target.name,
                        detail: detail(for: status, target: target),
                        status: status
                    ) {
                        if status == .notDetermined {
                            Button("Grant Access") { request(target.bundleID) }
                                .buttonStyle(MiniButtonStyle(filled: true))
                        } else if status == .blocked {
                            Button("Open Settings") { OnboardingChecks.openSettings(.automation) }
                                .buttonStyle(MiniButtonStyle())
                        }
                    }
                }
            }

            InfoNote(icon: "safari",
                     text: "Browsers are handled separately and need no prompt here. Arc works out of the box; in Safari and Chrome enable “Allow JavaScript from Apple Events” in the Develop menu.")

            InfoNote(icon: "arrow.clockwise",
                     text: "The prompt only appears while the app in question is running. Open Spotify or Music first if Grant Access does nothing.")
        }
    }

    private func detail(for status: OnboardingChecks.Status,
                        target: (bundleID: String, name: String)) -> String {
        switch status {
        case .satisfied:      "Allowed"
        case .notApplicable:  "Not installed, nothing to grant"
        case .blocked:        "Denied. Turn Notch Lyrics on under \(target.name) in Automation."
        case .notDetermined:  probe.snap.running.contains(target.bundleID)
                                ? "Not asked yet" : "Open \(target.name), then grant access"
        case .missing:        "Unavailable"
        }
    }

    /// `askUserIfNeeded: true` blocks until the dialog closes, so it must not
    /// run on the main thread or the whole window freezes behind the prompt.
    private func request(_ bundleID: String) {
        Task.detached(priority: .userInitiated) {
            _ = OnboardingChecks.automationStatus(for: bundleID, askUserIfNeeded: true)
            await MainActor.run { probe.refresh() }
        }
    }
}

// MARK: - Step: media-control

private struct NowPlayingStep: View {
    @ObservedObject var probe: SystemProbe

    private let command = "brew install media-control"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "EVERY PLAYER · OPTIONAL",
                title: "Cover the apps that\ndon't answer scripts.",
                subtitle: "Some players, Dia among them, can't be queried directly. A small command-line helper reads macOS's own Now Playing session instead, so those apps still get lyrics.",
                status: probe.snap.mediaControl
            )

            StatusRow(
                icon: "terminal",
                title: "media-control",
                detail: probe.snap.mediaControl.isSatisfied
                    ? "Installed and ready"
                    : "Not found in /opt/homebrew/bin or /usr/local/bin",
                status: probe.snap.mediaControl
            ) { EmptyView() }

            if !probe.snap.mediaControl.isSatisfied {
                CommandBlock(command: command)
                InfoNote(icon: "info.circle",
                         text: "Run it in Terminal, then come back. This row turns green on its own. Skipping is fine: everything except those few apps keeps working.")
            }
        }
    }
}

// MARK: - Step: microphone

private struct MicrophoneStep: View {
    @ObservedObject var probe: SystemProbe

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "CAPTURE",
                title: "The effects rack needs\nmicrophone access.",
                subtitle: "Not your actual microphone. The effects chain reads from a virtual loopback input device, and macOS files every audio input under the same permission.",
                status: probe.snap.microphone
            )

            StatusRow(
                icon: "mic",
                title: "Microphone",
                detail: {
                    switch probe.snap.microphone {
                    case .satisfied:     "Allowed"
                    case .notDetermined: "Not asked yet"
                    default:             "Denied. Turn Notch Lyrics on in Privacy & Security › Microphone."
                    }
                }(),
                status: probe.snap.microphone
            ) {
                switch probe.snap.microphone {
                case .notDetermined:
                    Button("Grant Access") { request() }
                        .buttonStyle(MiniButtonStyle(filled: true))
                case .blocked:
                    Button("Open Settings") { OnboardingChecks.openSettings(.microphone) }
                        .buttonStyle(MiniButtonStyle())
                default:
                    EmptyView()
                }
            }

            InfoNote(icon: "eye.slash",
                     text: "Audio is processed in memory and played straight back out. Nothing is recorded, saved, or uploaded.")
        }
    }

    private func request() {
        Task { @MainActor in
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            // CoreAudio briefly re-initialises after the prompt closes; give it
            // a beat before the next probe reads device state.
            try? await Task.sleep(nanoseconds: 250_000_000)
            probe.refresh()
        }
    }
}

// MARK: - Step: loopback bridge

private struct BridgeStep: View {
    @ObservedObject var probe: SystemProbe

    private let command = "brew install blackhole-2ch"

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "AUDIO BRIDGE",
                title: "Install the bridge, then\npoint macOS at it.",
                subtitle: "macOS won't hand an app its own output, so system audio takes a detour through a free virtual device. Notch Lyrics shows it as “Notch Lyrics Bridge”.",
                status: probe.snap.loopback.isSatisfied && probe.snap.systemOutput.isSatisfied
                    ? .satisfied : .missing
            )

            StatusRow(
                icon: "arrow.triangle.branch",
                title: "Bridge driver installed",
                detail: probe.snap.loopback.isSatisfied
                    ? "Notch Lyrics Bridge is available as an input"
                    : "BlackHole 2ch not found",
                status: probe.snap.loopback
            ) { EmptyView() }

            if !probe.snap.loopback.isSatisfied {
                CommandBlock(command: command)
                InfoNote(icon: "lock",
                         text: "Homebrew will ask for your password: this one installs a system audio driver. Restarting is not needed.")
            }

            StatusRow(
                icon: "speaker.wave.2",
                title: "System output set to the bridge",
                detail: probe.snap.systemOutput.isSatisfied
                    ? "All system audio is flowing into the bridge"
                    : "Currently “\(probe.snap.systemOutputName)”",
                status: probe.snap.systemOutput
            ) {
                if !probe.snap.systemOutput.isSatisfied && probe.snap.loopback.isSatisfied {
                    Button("Open Sound") { OnboardingChecks.openSettings(.sound) }
                        .buttonStyle(MiniButtonStyle(filled: true))
                }
            }

            InfoNote(icon: "exclamationmark.triangle",
                     tint: SP.warning,
                     text: "Once output is set to the bridge you hear nothing until the engine is on, because the bridge is where the effects chain picks the audio up. Turn the engine on in the next step and sound comes back.")
        }
    }
}

// MARK: - Step: routing

private struct RoutingStep: View {
    @ObservedObject var probe: SystemProbe
    @ObservedObject private var fx = AudioEffects.shared
    @State private var errorText: String?
    @State private var busy = false

    init(probe: SystemProbe) { self.probe = probe }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "ROUTING",
                title: "Bridge in, speakers out.",
                subtitle: "The chain reads from the bridge and writes to whatever you actually listen on. Turn the engine on and the scene in the sidebar starts moving with your audio.",
                status: fx.engineRunning ? .satisfied : .notDetermined
            )

            HStack(alignment: .center, spacing: Space.md) {
                picker(title: "INPUT", subtitle: "The bridge", icon: "waveform",
                       selection: Binding(get: { fx.inputUID ?? "" },
                                          set: { fx.inputUID = $0.isEmpty ? nil : $0 }),
                       pool: probe.snap.devices.filter(\.hasInput))
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SP.textTertiary)
                picker(title: "OUTPUT", subtitle: "Your speakers", icon: "hifispeaker.fill",
                       selection: Binding(get: { fx.outputUID ?? "" },
                                          set: { fx.outputUID = $0.isEmpty ? nil : $0 }),
                       pool: probe.snap.devices.filter(\.hasOutput))
            }

            if let errorText {
                InfoNote(icon: "exclamationmark.triangle", tint: SP.warning, text: errorText)
            }

            HStack(spacing: Space.md) {
                Button(busy ? (fx.engineRunning ? "Stopping…" : "Starting…")
                            : (fx.engineRunning ? "Turn Engine Off" : "Turn Engine On")) {
                    Task { await toggleEngine() }
                }
                .buttonStyle(PrimaryButtonStyle(filled: !fx.engineRunning))
                .disabled(busy)
                Text(fx.engineRunning
                     ? "Playing something? The sidebar is reacting to it."
                     : "Start playback first so there's something to hear.")
                    .font(Typo.caption)
                    .foregroundStyle(SP.textTertiary)
            }
        }
        .onAppear(perform: autoSelect)
    }

    private func picker(title: String, subtitle: String, icon: String,
                        selection: Binding<String>, pool: [AudioDevice]) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(SP.textSecondary)
                Text(title)
                    .font(Typo.micro)
                    .tracking(1)
                    .foregroundStyle(SP.textTertiary)
            }
            Picker(title, selection: selection) {
                Text("Pick a device").tag("")
                ForEach(pool, id: \.uid) { d in
                    Text(friendlyName(d)).tag(d.uid)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(subtitle).font(Typo.caption).foregroundStyle(SP.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .well()
    }

    private func autoSelect() {
        if fx.inputUID == nil,
           let bridge = probe.snap.devices.first(where: { $0.isBlackHole && $0.hasInput }) {
            fx.inputUID = bridge.uid
        }
        // Default output: the first real (non-bridge) output, which is almost
        // always the built-in speakers or connected headphones.
        if fx.outputUID == nil,
           let real = probe.snap.devices.first(where: { $0.hasOutput && !$0.isBlackHole }) {
            fx.outputUID = real.uid
        }
    }

    /// Mirrors the Audio pane: permission first, then an awaited start, so a
    /// slow CoreAudio reconfiguration never blocks the main thread. This path
    /// previously called `start()` with no permission preflight at all.
    private func toggleEngine() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        if fx.engineRunning {
            await AudioEngine.shared.stop()
            errorText = nil
            return
        }
        if let denied = await OnboardingChecks.ensureMicrophoneAccess() {
            errorText = denied
            return
        }
        do {
            try await AudioEngine.shared.start(EngineConfig(fx))
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        probe.refresh()
    }
}

// MARK: - Step: vibe

private struct VibeStep: View {
    @ObservedObject private var fx = AudioEffects.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "YOUR SOUND · OPTIONAL",
                title: "Pick a vibe.",
                subtitle: "Presets apply instantly. If the engine is on you'll hear the change as you click, and every slider stays open to you afterwards in the Audio pane."
            )

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.md), count: 4),
                      spacing: Space.md) {
                ForEach(EffectsPreset.library) { p in
                    Button { fx.applyPreset(p) } label: {
                        VStack(spacing: Space.sm) {
                            Text(p.emoji).font(.system(size: 26))
                            HStack(spacing: Space.xs) {
                                Text(p.name)
                                    .font(Typo.label)
                                    .foregroundStyle(SP.textPrimary)
                                if fx.currentPresetId == p.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(SP.accent)
                                }
                            }
                            Text(p.tagline)
                                .font(Typo.caption)
                                .foregroundStyle(SP.textTertiary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Space.md)
                        .background(
                            RoundedRectangle(cornerRadius: Radius.card)
                                .fill(fx.currentPresetId == p.id ? SP.accent.opacity(0.10) : SP.surfaceHi)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Radius.card).strokeBorder(
                                fx.currentPresetId == p.id ? SP.accent : SP.divider,
                                lineWidth: fx.currentPresetId == p.id ? 1.5 : 1
                            )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: Radius.card))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityAddTraits(fx.currentPresetId == p.id ? [.isSelected] : [])
                }
            }
            .animation(Motion.state, value: fx.currentPresetId)
        }
    }
}

// MARK: - Step: done

private struct DoneStep: View {
    @ObservedObject var probe: SystemProbe

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            StepHeading(
                eyebrow: "ALL SET",
                title: "You're done.",
                subtitle: "Here's where everything lives from now on."
            )

            VStack(alignment: .leading, spacing: Space.md) {
                FeatureRow(icon: "cursorarrow.rays",
                           title: "Hover the notch",
                           detail: "The pill expands into lyrics and transport controls.")
                FeatureRow(icon: "slider.horizontal.3",
                           title: "The Audio pane",
                           detail: "Presets, routing, the 10-band EQ, and the live meter, all in this window.")
                FeatureRow(icon: "dock.rectangle",
                           title: "Reopen any time",
                           detail: "Click the Dock icon, or use Window › Notch Lyrics.")
            }

            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("SETUP SUMMARY")
                .font(Typo.micro)
                .tracking(1.2)
                .foregroundStyle(SP.textTertiary)
            row("Lyrics access", probe.automationSummary)
            row("media-control (optional)", probe.snap.mediaControl)
            row("Microphone", probe.snap.microphone)
            row("Bridge driver", probe.snap.loopback)
            row("System output", probe.snap.systemOutput)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: Space.lg)
    }

    private func row(_ label: String, _ status: OnboardingChecks.Status) -> some View {
        HStack(spacing: Space.sm) {
            StatusDot(status: status)
            Text(label).font(Typo.copy).foregroundStyle(SP.textSecondary)
            Spacer()
            Text(status.label)
                .font(Typo.caption)
                .foregroundStyle(status.tint)
        }
    }
}
