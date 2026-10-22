import Foundation
import SwiftUI
import AVFoundation

/// Parameter store for the effects chain. Single source of truth, observed by both
/// the SwiftUI panel and AudioEngine. Persists to UserDefaults so settings stick.
@MainActor
final class AudioEffects: ObservableObject {
    static let shared = AudioEffects()

    // EQ — 10 bands (Hz), ±18 dB each
    nonisolated static let bandFrequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]

    @Published var bandGains: [Float] = Array(repeating: 0, count: 10) { didSet { drift(); save() } }
    @Published var preGain: Float = 0              { didSet { drift(); save() } }   // dB, -12…+12
    @Published var reverbWet: Float = 0            { didSet { drift(); save() } }   // 0…100 %
    @Published var reverbPreset: Int = AVAudioUnitReverbPreset.mediumHall.rawValue { didSet { drift(); save() } }
    @Published var distortion: Float = 0           { didSet { drift(); save() } }   // 0…100 %
    @Published var lowPassCutoff: Float = 22_000   { didSet { drift(); save() } }   // 10 … 22 000 Hz
    @Published var highPassCutoff: Float = 20      { didSet { drift(); save() } }   // 20 … 2 000 Hz
    @Published var pan: Float = 0                  { didSet { drift(); save() } }   // -1…+1
    @Published var pitchSemitones: Float = 0       { didSet { drift(); save() } }   // -24…+24
    @Published var modulationMode: Int = 0         { didSet { drift(); save() } }   // 0 off, 1 chorus, 2 flange
    @Published var modulationIntensity: Float = 0  { didSet { drift(); save() } }   // 0…100 %
    @Published var bypass: Bool = false            { didSet { save() } }

    @Published var inputUID: String?               { didSet { save() } }
    @Published var outputUID: String?              { didSet { save() } }
    @Published var engineRunning: Bool = false     { didSet { save() } }

    /// Identifier of the last applied preset (or "custom" if user has nudged sliders).
    @Published var currentPresetId: String = "off" { didSet { save() } }
    private var applyingPreset: Bool = false       // suppresses drift marking during preset apply

    /// Marks parameters as drifted from the active preset.
    private func drift() {
        if applyingPreset { return }
        if currentPresetId != "custom" { currentPresetId = "custom" }
    }

    func applyPreset(_ p: EffectsPreset) {
        applyingPreset = true
        bandGains = p.bandGains
        preGain = p.preGain
        reverbWet = p.reverbWet
        reverbPreset = p.reverbPreset
        distortion = p.distortion
        lowPassCutoff = p.lowPassCutoff
        highPassCutoff = p.highPassCutoff
        pan = p.pan
        pitchSemitones = p.pitchSemitones
        modulationMode = p.modulationMode
        modulationIntensity = p.modulationIntensity
        applyingPreset = false
        currentPresetId = p.id
    }

    private let defaults = UserDefaults.standard

    private init() { load() }

    static let reverbPresets: [(Int, String)] = [
        (AVAudioUnitReverbPreset.smallRoom.rawValue,   "Small Room"),
        (AVAudioUnitReverbPreset.mediumRoom.rawValue,  "Medium Room"),
        (AVAudioUnitReverbPreset.largeRoom.rawValue,   "Large Room"),
        (AVAudioUnitReverbPreset.mediumHall.rawValue,  "Medium Hall"),
        (AVAudioUnitReverbPreset.largeHall.rawValue,   "Large Hall"),
        (AVAudioUnitReverbPreset.plate.rawValue,       "Plate"),
        (AVAudioUnitReverbPreset.cathedral.rawValue,   "Cathedral")
    ]

    private func save() {
        defaults.set(bandGains.map(Double.init), forKey: "fx.eq")
        defaults.set(Double(preGain), forKey: "fx.preGain")
        defaults.set(Double(reverbWet), forKey: "fx.reverbWet")
        defaults.set(reverbPreset, forKey: "fx.reverbPreset")
        defaults.set(Double(distortion), forKey: "fx.distortion")
        defaults.set(Double(lowPassCutoff), forKey: "fx.lowPass")
        defaults.set(Double(highPassCutoff), forKey: "fx.highPass")
        defaults.set(Double(pan), forKey: "fx.pan")
        defaults.set(Double(pitchSemitones), forKey: "fx.pitch")
        defaults.set(modulationMode, forKey: "fx.modMode")
        defaults.set(Double(modulationIntensity), forKey: "fx.modIntensity")
        defaults.set(currentPresetId, forKey: "fx.presetId")
        defaults.set(bypass, forKey: "fx.bypass")
        defaults.set(inputUID, forKey: "fx.inputUID")
        defaults.set(outputUID, forKey: "fx.outputUID")
        defaults.set(engineRunning, forKey: "fx.engineRunning")
    }

    private func load() {
        applyingPreset = true
        defer { applyingPreset = false }
        if let arr = defaults.array(forKey: "fx.eq") as? [Double], arr.count == 10 {
            bandGains = arr.map(Float.init)
        }
        if defaults.object(forKey: "fx.preGain") != nil   { preGain   = Float(defaults.double(forKey: "fx.preGain")) }
        if defaults.object(forKey: "fx.reverbWet") != nil { reverbWet = Float(defaults.double(forKey: "fx.reverbWet")) }
        if defaults.object(forKey: "fx.reverbPreset") != nil { reverbPreset = defaults.integer(forKey: "fx.reverbPreset") }
        if defaults.object(forKey: "fx.distortion") != nil { distortion = Float(defaults.double(forKey: "fx.distortion")) }
        if defaults.object(forKey: "fx.lowPass") != nil    { lowPassCutoff = Float(defaults.double(forKey: "fx.lowPass")) }
        if defaults.object(forKey: "fx.highPass") != nil   { highPassCutoff = Float(defaults.double(forKey: "fx.highPass")) }
        if defaults.object(forKey: "fx.pan") != nil        { pan = Float(defaults.double(forKey: "fx.pan")) }
        if defaults.object(forKey: "fx.pitch") != nil      { pitchSemitones = Float(defaults.double(forKey: "fx.pitch")) }
        if defaults.object(forKey: "fx.modMode") != nil    { modulationMode = defaults.integer(forKey: "fx.modMode") }
        if defaults.object(forKey: "fx.modIntensity") != nil { modulationIntensity = Float(defaults.double(forKey: "fx.modIntensity")) }
        currentPresetId = defaults.string(forKey: "fx.presetId") ?? "off"
        bypass = defaults.bool(forKey: "fx.bypass")
        inputUID = defaults.string(forKey: "fx.inputUID")
        outputUID = defaults.string(forKey: "fx.outputUID")
        engineRunning = false
    }

    func resetEQ() {
        bandGains = Array(repeating: 0, count: 10)
        preGain = 0
    }

    func resetEffects() {
        reverbWet = 0
        distortion = 0
        lowPassCutoff = 22_000
        highPassCutoff = 20
        pan = 0
        pitchSemitones = 0
        modulationMode = 0
        modulationIntensity = 0
    }
}
