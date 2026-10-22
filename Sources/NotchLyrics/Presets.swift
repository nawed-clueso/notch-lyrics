import Foundation
import AVFoundation

/// Curated effect snapshots. Pick one and the engine sounds like that.
struct EffectsPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let emoji: String
    let tagline: String

    let bandGains: [Float]
    let preGain: Float
    let reverbWet: Float
    let reverbPreset: Int
    let distortion: Float
    let lowPassCutoff: Float
    let highPassCutoff: Float
    let pan: Float
    let pitchSemitones: Float
    let modulationMode: Int        // 0 off, 1 chorus, 2 flange
    let modulationIntensity: Float

    static let library: [EffectsPreset] = [
        .init(id: "off", name: "Clean", emoji: "🪞", tagline: "Untouched",
              bandGains: [0,0,0,0,0,0,0,0,0,0],
              preGain: 0, reverbWet: 0, reverbPreset: AVAudioUnitReverbPreset.mediumHall.rawValue,
              distortion: 0, lowPassCutoff: 22_000, highPassCutoff: 20,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "lounge", name: "Lounge", emoji: "🛋️", tagline: "Warm & soft",
              bandGains: [3, 2, 1, 0, 0, 0, -1, -2, -2, -3],
              preGain: 0, reverbWet: 22, reverbPreset: AVAudioUnitReverbPreset.mediumRoom.rawValue,
              distortion: 0, lowPassCutoff: 14_000, highPassCutoff: 25,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "concert", name: "Concert Hall", emoji: "🎼", tagline: "Wide & roomy",
              bandGains: [0, 0, 0, 0, 0, 1, 2, 2, 1, 0],
              preGain: 0, reverbWet: 55, reverbPreset: AVAudioUnitReverbPreset.largeHall.rawValue,
              distortion: 0, lowPassCutoff: 22_000, highPassCutoff: 20,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "lofi", name: "Lo-Fi", emoji: "📻", tagline: "Tape & dust",
              bandGains: [2, 2, 1, 0, -1, -2, -3, -4, -6, -8],
              preGain: -2, reverbWet: 15, reverbPreset: AVAudioUnitReverbPreset.smallRoom.rawValue,
              distortion: 18, lowPassCutoff: 7_500, highPassCutoff: 80,
              pan: 0, pitchSemitones: -0.3,
              modulationMode: 1, modulationIntensity: 25),

        .init(id: "underwater", name: "Underwater", emoji: "🌊", tagline: "Submerged",
              bandGains: [4, 3, 2, 0, -2, -4, -6, -9, -12, -14],
              preGain: 0, reverbWet: 60, reverbPreset: AVAudioUnitReverbPreset.cathedral.rawValue,
              distortion: 0, lowPassCutoff: 1_400, highPassCutoff: 20,
              pan: 0, pitchSemitones: 0,
              modulationMode: 1, modulationIntensity: 60),

        .init(id: "8bit", name: "8-Bit", emoji: "🎮", tagline: "Gritty bytes",
              bandGains: [-4, -2, 0, 2, 3, 2, 0, -2, -4, -6],
              preGain: -2, reverbWet: 5, reverbPreset: AVAudioUnitReverbPreset.smallRoom.rawValue,
              distortion: 75, lowPassCutoff: 8_000, highPassCutoff: 250,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "karaoke", name: "Karaoke", emoji: "🎤", tagline: "Center stage",
              bandGains: [-2, -2, -2, -3, -4, -4, 0, 2, 2, 0],
              preGain: 0, reverbWet: 35, reverbPreset: AVAudioUnitReverbPreset.mediumHall.rawValue,
              distortion: 0, lowPassCutoff: 18_000, highPassCutoff: 100,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "chromatic", name: "Chromatic", emoji: "🌈", tagline: "Pitched & swirly",
              bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              preGain: 0, reverbWet: 30, reverbPreset: AVAudioUnitReverbPreset.plate.rawValue,
              distortion: 0, lowPassCutoff: 22_000, highPassCutoff: 20,
              pan: 0, pitchSemitones: 5,
              modulationMode: 2, modulationIntensity: 70),

        .init(id: "bass-boost", name: "Bass Boost", emoji: "🔊", tagline: "Subs only",
              bandGains: [10, 8, 5, 2, 0, 0, 0, 0, 0, 0],
              preGain: -2, reverbWet: 0, reverbPreset: AVAudioUnitReverbPreset.smallRoom.rawValue,
              distortion: 0, lowPassCutoff: 22_000, highPassCutoff: 20,
              pan: 0, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0),

        .init(id: "vinyl", name: "Vinyl", emoji: "💿", tagline: "Aged groove",
              bandGains: [1, 1, 0, 0, 0, 0, -1, -2, -3, -5],
              preGain: 0, reverbWet: 10, reverbPreset: AVAudioUnitReverbPreset.smallRoom.rawValue,
              distortion: 22, lowPassCutoff: 12_000, highPassCutoff: 65,
              pan: 0, pitchSemitones: 0,
              modulationMode: 1, modulationIntensity: 15),

        .init(id: "stage-left", name: "Stage Left", emoji: "↩️", tagline: "Pan ear-only",
              bandGains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
              preGain: 0, reverbWet: 12, reverbPreset: AVAudioUnitReverbPreset.mediumRoom.rawValue,
              distortion: 0, lowPassCutoff: 22_000, highPassCutoff: 20,
              pan: -0.85, pitchSemitones: 0,
              modulationMode: 0, modulationIntensity: 0)
    ]
}
