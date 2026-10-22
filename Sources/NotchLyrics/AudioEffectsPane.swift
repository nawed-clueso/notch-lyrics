import AppKit
import SwiftUI
import AVFoundation
import os.log

private let engineLogger = Logger(subsystem: "com.notchlyrics.app", category: "engine")

func friendlyName(_ d: AudioDevice) -> String {
    d.isBlackHole ? "Notch Lyrics Bridge" : d.name
}

// MARK: - Pane

/// The effects rack, hosted inside the main window. Solid accent is spent on
/// exactly one primary action here — the engine toggle — plus state indicators.
struct AudioEffectsPane: View {
    @ObservedObject private var fx = AudioEffects.shared
    @State private var devices: [AudioDevice] = CoreAudioDevices.list()
    @State private var errorText: String?
    @State private var showRouting = false
    /// True while CoreAudio is reconfiguring. Bluetooth outputs can take
    /// seconds, so the button has to show progress rather than appear dead.
    @State private var busy = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                header
                if let errorText { errorBanner(errorText) }
                meterCard
                presetsSection
                eqCard
                effectsCard
                routingCard
                footnote
            }
            .padding(.horizontal, Space.xxl)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.section)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(SP.bgColor)
        .foregroundStyle(SP.textPrimary)
        .onAppear {
            devices = CoreAudioDevices.list()
            autoSelectBridgeIfNeeded()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: Space.xs) {
                Text("Audio")
                    .font(Typo.title(28))
                Text("Run system audio through a chain of effects.")
                    .font(Typo.copy)
                    .foregroundStyle(SP.textSecondary)
            }
            Spacer(minLength: Space.lg)
            engineButton
        }
    }

    /// The one primary action in this pane, so it gets the solid accent fill.
    private var engineButton: some View {
        let on = fx.engineRunning
        return Button {
            Task { await toggleEngine() }
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: busy ? "hourglass" : (on ? "waveform.circle.fill" : "power"))
                    .font(.system(size: 12, weight: .semibold))
                Text(busy ? (on ? "Stopping…" : "Starting…") : (on ? "Turn Engine Off" : "Turn Engine On"))
            }
        }
        .buttonStyle(PrimaryButtonStyle(filled: !on))
        .disabled(busy)
        .animation(Motion.floating, value: on)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(SP.warning)
            Text(msg)
                .font(Typo.caption)
                .foregroundStyle(SP.warning)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Space.sm)
            Button {
                errorText = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(SP.textTertiary)
            .help("Dismiss")
        }
        .padding(Space.lg)
        .background(RoundedRectangle(cornerRadius: Radius.card).fill(SP.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(SP.warning.opacity(0.35)))
    }

    // MARK: Live meter

    private var meterCard: some View {
        let on = fx.engineRunning
        return VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                // State carries an icon and a word, never colour alone.
                Image(systemName: on ? "dot.radiowaves.left.and.right" : "pause.circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(on ? SP.accent : SP.textTertiary)
                Text(on ? "Live" : "Offline")
                    .font(Typo.label)
                    .foregroundStyle(on ? SP.accent : SP.textTertiary)
                Spacer()
                Text(activePresetName())
                    .font(Typo.caption)
                    .foregroundStyle(SP.textSecondary)
            }
            ThreeCanvasView(
                store: SharedAudio.levels,
                active: on,
                background: NSColor(red: 0.055, green: 0.055, blue: 0.055, alpha: 1)
            )
            .frame(height: 132)
            .clipShape(RoundedRectangle(cornerRadius: Radius.control))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control)
                    .strokeBorder(on ? SP.accent.opacity(0.20) : SP.divider)
            )
            .accessibilityLabel(on ? "Live audio meter" : "Audio meter, engine off")
        }
        .card(fill: SP.surface)
        .animation(Motion.overlay, value: on)
    }

    private func activePresetName() -> String {
        if fx.currentPresetId == "custom" { return "Custom" }
        return EffectsPreset.library.first(where: { $0.id == fx.currentPresetId })?.name ?? "—"
    }

    // MARK: Presets

    private var presetsSection: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            sectionTitle("Presets", trailing: "\(EffectsPreset.library.count) available")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.md) {
                    ForEach(EffectsPreset.library) { p in
                        PresetCard(preset: p, selected: fx.currentPresetId == p.id) {
                            fx.applyPreset(p)
                        }
                    }
                }
                .padding(.vertical, Space.xs)
            }
        }
    }

    // MARK: EQ

    private var eqCard: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                sectionTitle("10-Band EQ", trailing: nil)
                Spacer()
                Button("Flatten EQ") { fx.resetEQ() }
                    .buttonStyle(TertiaryButtonStyle())
            }
            EQCurveView(
                bands: fx.bandGains,
                preGain: fx.preGain,
                lowPass: fx.lowPassCutoff,
                highPass: fx.highPassCutoff,
                bypass: fx.bypass
            )
            .frame(height: 140)
            .padding(Space.md)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(SP.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(SP.divider))

            bandSliders
        }
        .card(fill: SP.surface)
    }

    private var bandSliders: some View {
        HStack(alignment: .bottom, spacing: Space.md) {
            ForEach(Array(AudioEffects.bandFrequencies.enumerated()), id: \.offset) { i, freq in
                VStack(spacing: Space.sm) {
                    Text(String(format: "%+.0f", fx.bandGains[i]))
                        .font(Typo.monoSmall)
                        .foregroundStyle(SP.textSecondary)
                    VerticalSlider(
                        value: Binding(get: { Double(fx.bandGains[i]) },
                                       set: { fx.bandGains[i] = Float($0) }),
                        range: -18...18
                    )
                    .frame(height: 132)
                    .accessibilityLabel("\(formatHz(freq)) hertz band")
                    .accessibilityValue(String(format: "%+.0f decibels", fx.bandGains[i]))
                    Text(formatHz(freq))
                        .font(Typo.monoSmall)
                        .foregroundStyle(SP.textTertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .well(padding: Space.lg)
    }

    // MARK: Effects

    private var effectsCard: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            HStack {
                sectionTitle("Effects", trailing: nil)
                Spacer()
                Toggle("Bypass", isOn: $fx.bypass)
                    .toggleStyle(.switch)
                    .tint(SP.accent)
                    .font(Typo.label)
                    .foregroundStyle(SP.textSecondary)
                Button("Reset Effects") { fx.resetEffects() }
                    .buttonStyle(TertiaryButtonStyle())
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.md),
                                GridItem(.flexible(), spacing: Space.md),
                                GridItem(.flexible(), spacing: Space.md)],
                      spacing: Space.md) {
                slider("Pre-Gain", $fx.preGain, -12...12, "dB", "%+.1f")
                slider("Reverb Mix", $fx.reverbWet, 0...100, "%", "%.0f")
                slider("Distortion", $fx.distortion, 0...100, "%", "%.0f")
                slider("Low-Pass", $fx.lowPassCutoff, 200...22_000, "Hz", "%.0f", log: true)
                slider("High-Pass", $fx.highPassCutoff, 20...2_000, "Hz", "%.0f", log: true)
                slider("Pan", $fx.pan, -1...1, "", "%+.2f", bipolar: true)
                slider("Pitch", $fx.pitchSemitones, -24...24, "st", "%+.1f", bipolar: true)
                reverbPresetTile
            }

            modulationRow
        }
        .card(fill: SP.surface)
    }

    private var reverbPresetTile: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("REVERB SPACE")
                .font(Typo.micro)
                .tracking(1)
                .foregroundStyle(SP.textTertiary)
            Picker("Reverb space", selection: $fx.reverbPreset) {
                ForEach(AudioEffects.reverbPresets, id: \.0) { value, name in
                    Text(name).tag(value)
                }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .well()
    }

    private var modulationRow: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text("MODULATION")
                    .font(Typo.micro)
                    .tracking(1)
                    .foregroundStyle(SP.textTertiary)
                Spacer()
                Text(String(format: "%@ · %.0f%%", modeName(fx.modulationMode), fx.modulationIntensity))
                    .font(Typo.mono)
                    .foregroundStyle(SP.textPrimary)
            }
            HStack(spacing: Space.sm) {
                ForEach([(0, "Off"), (1, "Chorus"), (2, "Flange")], id: \.0) { mode, label in
                    modeChip(label: label, mode: mode)
                }
                Spacer(minLength: Space.lg)
                HorizontalSlider(
                    value: Binding(get: { Double(fx.modulationIntensity) },
                                   set: { fx.modulationIntensity = Float($0) }),
                    range: 0...100
                )
                .frame(height: 22)
                .frame(maxWidth: 320)
                .accessibilityLabel("Modulation intensity")
            }
        }
        .well(padding: Space.lg)
    }

    private func modeChip(label: String, mode: Int) -> some View {
        let on = fx.modulationMode == mode
        return Button { fx.modulationMode = mode } label: {
            Text(label)
        }
        .buttonStyle(ChipButtonStyle(selected: on))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    private func modeName(_ mode: Int) -> String {
        switch mode { case 1: "Chorus"; case 2: "Flange"; default: "Off" }
    }

    // MARK: Routing

    private var routingCard: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Button {
                withAnimation(Motion.state) { showRouting.toggle() }
            } label: {
                HStack(spacing: Space.md) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text("Routing").font(Typo.heading)
                        Text(routingSubtitle)
                            .font(Typo.caption)
                            .foregroundStyle(SP.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(SP.textTertiary)
                        .rotationEffect(.degrees(showRouting ? 0 : -90))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if showRouting {
                HStack(alignment: .center, spacing: Space.md) {
                    devicePicker(title: "INPUT", subtitle: "Loopback source", icon: "waveform",
                                 selection: Binding(get: { fx.inputUID ?? "" },
                                                    set: { fx.inputUID = $0.isEmpty ? nil : $0 }),
                                 pool: devices.filter(\.hasInput))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(SP.textTertiary)
                    devicePicker(title: "OUTPUT", subtitle: "Your speakers", icon: "hifispeaker.fill",
                                 selection: Binding(get: { fx.outputUID ?? "" },
                                                    set: { fx.outputUID = $0.isEmpty ? nil : $0 }),
                                 pool: devices.filter(\.hasOutput))
                    Button {
                        devices = CoreAudioDevices.list()
                    } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Rescan audio devices")
                }
                if !devices.contains(where: \.isBlackHole) {
                    Text("No loopback device found. Install it with brew install blackhole-2ch, then set System Settings › Sound › Output to it.")
                        .font(Typo.caption)
                        .foregroundStyle(SP.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(fill: SP.surface)
    }

    private var routingSubtitle: String {
        let inName  = devices.first(where: { $0.uid == fx.inputUID }).map(friendlyName)  ?? "not set"
        let outName = devices.first(where: { $0.uid == fx.outputUID }).map(friendlyName) ?? "not set"
        return "\(inName) → \(outName)"
    }

    private func devicePicker(title: String, subtitle: String, icon: String,
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

    private var footnote: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(SP.textTertiary)
            Text("“Notch Lyrics Bridge” is BlackHole, renamed. The driver is still called BlackHole 2ch.")
                .font(Typo.caption)
                .foregroundStyle(SP.textTertiary)
            Spacer()
        }
    }

    // MARK: Shared bits

    private func sectionTitle(_ title: String, trailing: String?) -> some View {
        HStack(spacing: Space.sm) {
            Text(title).font(Typo.heading)
            if let trailing {
                Text(trailing).font(Typo.caption).foregroundStyle(SP.textTertiary)
            }
        }
    }

    private func slider(_ title: String, _ value: Binding<Float>,
                        _ range: ClosedRange<Float>, _ unit: String, _ format: String,
                        log: Bool = false, bipolar: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack {
                Text(title.uppercased())
                    .font(Typo.micro)
                    .tracking(1)
                    .foregroundStyle(SP.textTertiary)
                Spacer()
                Text(String(format: unit.isEmpty ? format : "\(format) \(unit)", value.wrappedValue))
                    .font(Typo.mono)
                    .foregroundStyle(SP.textPrimary)
            }
            HorizontalSlider(
                value: Binding(get: { Double(value.wrappedValue) },
                               set: { value.wrappedValue = Float($0) }),
                range: Double(range.lowerBound)...Double(range.upperBound),
                logarithmic: log,
                bipolar: bipolar
            )
            .frame(height: 22)
            .accessibilityLabel(title)
        }
        .well()
    }

    private func formatHz(_ f: Float) -> String { f >= 1_000 ? "\(Int(f / 1_000))k" : "\(Int(f))" }

    // MARK: Engine

    /// Engine start does synchronous CoreAudio HAL work, so it runs off the main
    /// thread inside `AudioEngine` and is awaited here. `busy` keeps the button
    /// honest while a slow device reconfigures.
    private func toggleEngine() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }

        if fx.engineRunning {
            await AudioEngine.shared.stop()
            errorText = nil
            return
        }

        // Permission first: granting it mid-start makes CoreAudio re-initialise
        // the input unit underneath the engine.
        if let denied = await OnboardingChecks.ensureMicrophoneAccess() {
            errorText = denied
            fx.engineRunning = false
            return
        }

        do {
            try await AudioEngine.shared.start(EngineConfig(fx))
            errorText = nil
            engineLogger.log("engine started")
        } catch {
            errorText = error.localizedDescription
            fx.engineRunning = false
            engineLogger.log("engine start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func autoSelectBridgeIfNeeded() {
        if fx.inputUID == nil, let bridge = devices.first(where: { $0.isBlackHole && $0.hasInput }) {
            fx.inputUID = bridge.uid
        }
    }
}

// MARK: - Preset card

private struct PresetCard: View {
    let preset: EffectsPreset
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: Space.md) {
                Text(preset.emoji)
                    .font(.system(size: 34))
                    .frame(width: 76, height: 76)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.control)
                            .fill(hovering ? SP.surfaceTop : SP.surfaceHi)
                    )
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.xs) {
                        Text(preset.name)
                            .font(Typo.label)
                            .foregroundStyle(SP.textPrimary)
                        // Selection is marked with a glyph as well as the border.
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(SP.accent)
                        }
                    }
                    Text(preset.tagline)
                        .font(Typo.caption)
                        .foregroundStyle(SP.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(Space.md)
            .frame(width: 132, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(selected ? SP.accent.opacity(0.10) : SP.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card).strokeBorder(
                    selected ? SP.accent : (hovering ? Color.white.opacity(0.14) : SP.divider),
                    lineWidth: selected ? 1.5 : 1
                )
            )
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(PressableButtonStyle())
        .onHover { hovering = $0 }
        .animation(Motion.state, value: selected)
        .animation(Motion.state, value: hovering)
        .accessibilityLabel("\(preset.name) preset, \(preset.tagline)")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

// MARK: - Sliders

/// Vertical fader for the EQ bands. Fill grows from 0 dB, not from the bottom,
/// so a cut reads as a cut.
struct VerticalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let frac = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let thumb = h - h * CGFloat(frac)
            let zeroY = h * CGFloat((0 - range.lowerBound) / (range.upperBound - range.lowerBound))
            ZStack {
                Capsule().fill(Color.white.opacity(0.10)).frame(width: 3)
                Capsule()
                    .fill(SP.accent)
                    .frame(width: 3, height: abs(zeroY - thumb))
                    .position(x: geo.size.width / 2, y: (zeroY + thumb) / 2)
                Circle()
                    .fill(SP.textPrimary)
                    .frame(width: 11, height: 11)
                    .position(x: geo.size.width / 2, y: thumb)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    let y = max(0, min(h, g.location.y))
                    value = range.lowerBound + Double(1 - y / h) * (range.upperBound - range.lowerBound)
                }
            )
        }
    }
}

/// Horizontal parameter slider, with optional log scaling for frequency and a
/// bipolar fill for values that centre on zero.
struct HorizontalSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var logarithmic: Bool = false
    var bipolar: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(fraction()) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10)).frame(height: 3)
                if bipolar {
                    let mid = w / 2
                    Capsule()
                        .fill(SP.accent)
                        .frame(width: abs(x - mid), height: 3)
                        .offset(x: min(mid, x))
                } else {
                    Capsule().fill(SP.accent).frame(width: x, height: 3)
                }
                Circle()
                    .fill(SP.textPrimary)
                    .frame(width: 12, height: 12)
                    .position(x: x, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { g in
                    value = valueFor(max(0, min(1, Double(g.location.x / max(w, 1)))))
                }
            )
        }
    }

    private func fraction() -> Double {
        if logarithmic {
            let lo = log(range.lowerBound), hi = log(range.upperBound)
            return (log(max(range.lowerBound, value)) - lo) / (hi - lo)
        }
        return (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func valueFor(_ f: Double) -> Double {
        if logarithmic {
            let lo = log(range.lowerBound), hi = log(range.upperBound)
            return exp(lo + (hi - lo) * f)
        }
        return range.lowerBound + (range.upperBound - range.lowerBound) * f
    }
}
