import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine
import ObjCGuard

/// File-scope, nonisolated home for cross-thread audio bridge state.
/// LevelStore is `@unchecked Sendable` (internally NSLock'd), so any thread —
/// the CoreAudio I/O thread that pushes peaks, the main thread that reads
/// them for the visualizer — can touch it safely.
enum SharedAudio {
    static let levels = LevelStore()
}

/// Everything `start()` needs, captured on the main actor up front so the audio
/// queue never reaches back into `AudioEffects` (which is `@MainActor`).
struct EngineConfig: Sendable {
    var inputUID: String?
    var outputUID: String?
    var bandGains: [Float]
    var preGain: Float
    var reverbWet: Float
    var reverbPreset: Int
    var distortion: Float
    var lowPassCutoff: Float
    var highPassCutoff: Float
    var pan: Float
    var pitchSemitones: Float
    var modulationMode: Int
    var modulationIntensity: Float
    var bypass: Bool

    @MainActor
    init(_ fx: AudioEffects) {
        inputUID = fx.inputUID
        outputUID = fx.outputUID
        bandGains = fx.bandGains
        preGain = fx.preGain
        reverbWet = fx.reverbWet
        reverbPreset = fx.reverbPreset
        distortion = fx.distortion
        lowPassCutoff = fx.lowPassCutoff
        highPassCutoff = fx.highPassCutoff
        pan = fx.pan
        pitchSemitones = fx.pitchSemitones
        modulationMode = fx.modulationMode
        modulationIntensity = fx.modulationIntensity
        bypass = fx.bypass
    }
}

/// Routes a loopback input (typically BlackHole) → effects chain → output device.
///
/// AVAudioEngine.outputNode is built on `kAudioUnitSubType_DefaultOutput` which
/// can't be re-bound to a non-default device (returns -10851). So we terminate
/// the engine at an `AVAudioSinkNode`, push processed audio into a ring buffer,
/// and feed a manually-built `kAudioUnitSubType_HALOutput` whose CurrentDevice
/// IS settable. The HAL output's render callback drains the ring buffer.
///
/// **Nothing here runs on the main thread.** Starting the engine touches
/// `AVAudioEngine.inputNode`, which initialises the input audio unit, and that
/// does a TCC microphone preflight plus synchronous HAL IPC to coreaudiod
/// (`_TellServerAboutStreamUsage`). With a Bluetooth output such as AirPods,
/// opening an input also flips the headset into 24 kHz voice mode, which
/// reconfigures the output device mid-start. Run on main, that sequence froze
/// the UI for as long as CoreAudio took — which is why every mutating member is
/// confined to `queue` and the lifecycle calls are `async`.
final class AudioEngine: @unchecked Sendable {
    static let shared = AudioEngine()

    /// Serial queue owning every property below. AVAudioEngine is not
    /// thread-safe, so one queue rather than one lock per field.
    private let queue = DispatchQueue(label: "com.notchlyrics.audio", qos: .userInitiated)

    private var engine = AVAudioEngine()
    private let eq: AVAudioUnitEQ
    private let reverb = AVAudioUnitReverb()
    private let distortion = AVAudioUnitDistortion()
    private let pitchUnit = AVAudioUnitTimePitch()
    private let delayUnit = AVAudioUnitDelay()
    private let preGainMixer = AVAudioMixerNode()
    private let panMixer = AVAudioMixerNode()
    private let sourcePlayer = AVAudioPlayerNode()
    private var sinkNode: AVAudioSinkNode?
    private var lfoTimer: DispatchSourceTimer?
    private var lfoStart: Date = .init()
    private var inputTapInstalled = false
    private var inputConverter: AVAudioConverter?
    private var running = false

    /// Queue-local copy of the modulation settings, so the LFO never reads
    /// `@MainActor` state from its timer.
    private var modMode: Int = 0
    private var modIntensity: Float = 0

    // Manual HAL output side
    private var outputUnit: AudioUnit?
    private let ring = FloatRingBuffer(frames: 16_384, channels: 2)

    /// LevelStore lives on a nonisolated bridge so views that read the peak
    /// history don't have to go through this singleton.
    var levels: LevelStore { SharedAudio.levels }

    private var cancellables = Set<AnyCancellable>()

    private init() {
        eq = AVAudioUnitEQ(numberOfBands: 12)
        for (i, freq) in AudioEffects.bandFrequencies.enumerated() {
            let band = eq.bands[i]
            band.filterType = .parametric
            band.frequency = freq
            band.bandwidth = 0.5
            band.gain = 0
            band.bypass = false
        }
        eq.bands[10].filterType = .lowPass
        eq.bands[10].frequency = 22_000
        eq.bands[11].filterType = .highPass
        eq.bands[11].frequency = 20

        reverb.loadFactoryPreset(.mediumHall)
        reverb.wetDryMix = 0
        distortion.loadFactoryPreset(.drumsBitBrush)
        distortion.wetDryMix = 0
        pitchUnit.pitch = 0
        delayUnit.wetDryMix = 0
        delayUnit.feedback = 0
        delayUnit.delayTime = 0.005
    }

    // MARK: - Live parameter observation
    //
    // Subscriptions live on the main actor because `AudioEffects` does; each
    // one hands the new value to `queue`, which owns the audio units.

    @MainActor
    func observeEffects() {
        guard cancellables.isEmpty else { return }
        let fx = AudioEffects.shared

        fx.$bandGains.sink { [weak self] gains in self?.onQueue { $0.applyEQ(gains) } }.store(in: &cancellables)
        fx.$preGain.sink { [weak self] g in self?.onQueue { $0.preGainMixer.outputVolume = pow(10, g / 20) } }.store(in: &cancellables)
        fx.$reverbWet.sink { [weak self] w in self?.onQueue { $0.reverb.wetDryMix = w } }.store(in: &cancellables)
        fx.$reverbPreset.sink { [weak self] p in
            self?.onQueue { engine in
                if let preset = AVAudioUnitReverbPreset(rawValue: p) { engine.reverb.loadFactoryPreset(preset) }
            }
        }.store(in: &cancellables)
        fx.$distortion.sink { [weak self] d in self?.onQueue { $0.distortion.wetDryMix = d } }.store(in: &cancellables)
        fx.$lowPassCutoff.sink { [weak self] f in self?.onQueue { $0.eq.bands[10].frequency = f } }.store(in: &cancellables)
        fx.$highPassCutoff.sink { [weak self] f in self?.onQueue { $0.eq.bands[11].frequency = f } }.store(in: &cancellables)
        fx.$bypass.sink { [weak self] b in self?.onQueue { $0.eq.globalGain = b ? -120 : 0 } }.store(in: &cancellables)
        fx.$pan.sink { [weak self] p in self?.onQueue { $0.panMixer.pan = max(-1, min(1, p)) } }.store(in: &cancellables)
        fx.$pitchSemitones.sink { [weak self] s in self?.onQueue { $0.pitchUnit.pitch = s * 100 } }.store(in: &cancellables)
        fx.$modulationMode.sink { [weak self] m in
            self?.onQueue { engine in
                engine.modMode = m
                engine.applyModulation()
                // Spin the LFO up or down as the user toggles modulation rather
                // than ticking for nothing.
                if engine.running { engine.startLFOIfNeeded() }
            }
        }.store(in: &cancellables)
        fx.$modulationIntensity.sink { [weak self] i in
            self?.onQueue { engine in
                engine.modIntensity = i
                engine.applyModulation()
                if engine.running { engine.startLFOIfNeeded() }
            }
        }.store(in: &cancellables)
    }

    private func onQueue(_ work: @escaping @Sendable (AudioEngine) -> Void) {
        queue.async { work(self) }
    }

    private func applyModulation() {
        // Map "mode + intensity 0..100" onto the delay AU's wetDryMix and
        // feedback. The LFO keeps modulating delayTime for real sweeps.
        let intensity = max(0, min(1, modIntensity / 100))
        if modMode == 0 || intensity < 0.001 {
            delayUnit.wetDryMix = 0
            delayUnit.feedback = 0
            return
        }
        switch modMode {
        case 1: // chorus — wider, slower, less feedback
            delayUnit.wetDryMix = 50 * intensity
            delayUnit.feedback  = 15 * intensity
        case 2: // flange — short delay, more feedback for resonance
            delayUnit.wetDryMix = 60 * intensity
            delayUnit.feedback  = 55 * intensity
        default:
            delayUnit.wetDryMix = 0
            delayUnit.feedback  = 0
        }
    }

    private func applyEQ(_ gains: [Float]) {
        for (i, gain) in gains.enumerated() where i < 10 { eq.bands[i].gain = gain }
    }

    // MARK: - Lifecycle
    //
    // `async` so a slow CoreAudio reconfiguration shows as a pending button,
    // not a frozen window.

    func start(_ config: EngineConfig) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try self.startOnQueue(config)
                    cont.resume()
                } catch {
                    self.teardownOnQueue()
                    cont.resume(throwing: error)
                }
            }
        }
        await MainActor.run { AudioEffects.shared.engineRunning = true }
    }

    func stop() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.teardownOnQueue()
                cont.resume()
            }
        }
        await MainActor.run { AudioEffects.shared.engineRunning = false }
    }

    /// Fire-and-forget stop for teardown paths that can't await.
    func stopDetached() {
        queue.async { self.teardownOnQueue() }
    }

    private func startOnQueue(_ config: EngineConfig) throws {
        NSLog("🎛 start: input=\(config.inputUID ?? "nil") output=\(config.outputUID ?? "nil")")
        teardownOnQueue()

        modMode = config.modulationMode
        modIntensity = config.modulationIntensity

        guard let inputID = Self.deviceID(forUID: config.inputUID, mustHaveInput: true) else {
            throw EngineError.message("Pick an input device (typically BlackHole 2ch) in the Audio pane.")
        }
        guard let outputID = Self.deviceID(forUID: config.outputUID, mustHaveOutput: true) else {
            throw EngineError.message("Pick an output device (your real speakers or headphones) in the Audio pane.")
        }

        ring.reset()
        engine = AVAudioEngine()

        do {
            try engine.inputNode.auAudioUnit.setDeviceID(inputID)
        } catch {
            throw EngineError.message("Couldn't open the input device: \(error.localizedDescription)")
        }

        // Query the input node's actual format AFTER setDeviceID. The
        // inputNode→mixer connection MUST use this exact format, otherwise
        // AVAudioEngine inserts a converter and the "isInputConnToConverter"
        // assertion trips during prepare(). The mixer can then re-emit a
        // standard non-interleaved float32 format that downstream nodes
        // (EQ, pitch, distortion, etc.) accept.
        let nativeFormat = engine.inputNode.outputFormat(forBus: 0)
        NSLog("🎛 input native format = \(nativeFormat)")
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw EngineError.message("The input device reported no format. Toggle the engine off and re-pick the input.")
        }

        // Deliberately no pre-emptive format check here. A degraded reading such
        // as 1 ch / 24 kHz can mean the device really is in that state, but it is
        // also exactly what CoreAudio reports to a process that lacks microphone
        // permission — so refusing up front would block setups that work. The
        // graph is attempted, and failure is caught below and reported with the
        // observed format attached.
        //
        // The chain runs at the input's rate: AVAudioSinkNode follows the
        // engine's input format, so anything else fails to connect.
        let sampleRate = nativeFormat.sampleRate
        guard let chainFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            throw EngineError.message("Couldn't build the effects chain at \(Int(sampleRate)) Hz.")
        }
        NSLog("🎛 chain format = \(chainFormat)")

        // Sink callback runs on CoreAudio's IO thread. Built via a static
        // factory so it carries no actor isolation.
        let sink = AVAudioSinkNode(receiverBlock: Self.makeSinkReceiver(ring: ring, levels: levels))
        sinkNode = sink

        engine.attach(sourcePlayer)
        engine.attach(preGainMixer)
        engine.attach(eq)
        engine.attach(pitchUnit)
        engine.attach(distortion)
        engine.attach(delayUnit)
        engine.attach(reverb)
        engine.attach(panMixer)
        engine.attach(sink)

        // The input node is NOT connected to the chain — AVAudioEngine
        // refuses to put any converter between inputNode and its
        // downstream, and our chain needs a standard format. Instead we
        // tap raw buffers from inputNode, convert them via AVAudioConverter,
        // and feed them into the chain through an AVAudioPlayerNode.
        engine.connect(sourcePlayer, to: preGainMixer, format: chainFormat)
        engine.connect(preGainMixer, to: eq, format: chainFormat)
        engine.connect(eq, to: pitchUnit, format: chainFormat)
        engine.connect(pitchUnit, to: distortion, format: chainFormat)
        engine.connect(distortion, to: delayUnit, format: chainFormat)
        engine.connect(delayUnit, to: reverb, format: chainFormat)
        engine.connect(reverb, to: panMixer, format: chainFormat)
        engine.connect(panMixer, to: sink, format: chainFormat)

        guard let converter = AVAudioConverter(from: nativeFormat, to: chainFormat) else {
            throw EngineError.message("Couldn't create the input converter.")
        }
        inputConverter = converter
        let tapBlock = Self.makeInputTap(
            player: sourcePlayer,
            converter: converter,
            inputFormat: nativeFormat,
            chainFormat: chainFormat
        )
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: nativeFormat, block: tapBlock)
        inputTapInstalled = true

        // Push the captured parameter values.
        applyEQ(config.bandGains)
        preGainMixer.outputVolume = pow(10, config.preGain / 20)
        reverb.wetDryMix = config.reverbWet
        if let preset = AVAudioUnitReverbPreset(rawValue: config.reverbPreset) {
            reverb.loadFactoryPreset(preset)
        }
        distortion.wetDryMix = config.distortion
        eq.bands[10].frequency = config.lowPassCutoff
        eq.bands[11].frequency = config.highPassCutoff
        eq.globalGain = config.bypass ? -120 : 0
        panMixer.pan = max(-1, min(1, config.pan))
        pitchUnit.pitch = config.pitchSemitones * 100
        applyModulation()

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw EngineError.message("The engine couldn't start: \(error.localizedDescription)")
        }

        // Check the graph actually formed before touching the player.
        // `AVAudioPlayerNode.play()` raises an ObjC exception on a disconnected
        // node, and an ObjC exception cannot be caught in Swift — it terminates
        // the process. A Swift error here is recoverable; that call is not.
        // `play()` behind the guard: it raises an ObjC exception when the graph
        // silently failed to form, and every public property still reports the
        // node as attached and connected in that state — attached, one output
        // connection, correct rate, engine running — so there is nothing to test
        // beforehand. Catching it is the only reliable option, and without this
        // the process died with no crash report at all.
        if let reason = NLGuardRun({ self.sourcePlayer.play() }) {
            throw EngineError.message(Self.startFailureAdvice(reason: reason, input: nativeFormat))
        }

        try buildOutputUnit(deviceID: outputID, sampleRate: sampleRate)

        running = true
        startLFOIfNeeded()
        NSLog("🎛 start: running at \(sampleRate) Hz")
    }

    /// Start the modulation timer only when chorus/flange is actually engaged.
    private func startLFOIfNeeded() {
        lfoTimer?.cancel()
        lfoTimer = nil
        guard modMode != 0, modIntensity > 0.1 else { return }
        lfoStart = Date()
        // A dispatch timer on the audio queue, not a main RunLoop timer: the
        // delay unit it drives is owned by this queue.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(4))
        t.setEventHandler { [weak self] in self?.tickLFO() }
        t.resume()
        lfoTimer = t
    }

    private func tickLFO() {
        let intensity = Double(max(0, min(1, modIntensity / 100)))
        guard modMode != 0, intensity > 0.001 else {
            delayUnit.delayTime = 0.005
            return
        }
        let baseSec:  Double = (modMode == 2) ? 0.005 : 0.022    // flange ~5ms, chorus ~22ms
        let depthSec: Double = (modMode == 2) ? 0.003 : 0.010
        let rateHz:   Double = (modMode == 2) ? 0.45  : 0.85
        let elapsed = Date().timeIntervalSince(lfoStart)
        let mod = sin(2 * .pi * rateHz * elapsed) * depthSec * intensity
        delayUnit.delayTime = max(0.0005, baseSec + mod)
    }

    private func teardownOnQueue() {
        lfoTimer?.cancel()
        lfoTimer = nil
        if let unit = outputUnit {
            AudioOutputUnitStop(unit)
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            outputUnit = nil
        }
        if inputTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            inputTapInstalled = false
        }
        inputConverter = nil
        if sourcePlayer.engine === engine, sourcePlayer.isPlaying { sourcePlayer.stop() }
        if engine.isRunning { engine.stop() }
        engine.reset()
        let attached: [AVAudioNode] =
            ([sourcePlayer, preGainMixer, eq, pitchUnit, distortion, delayUnit, reverb, panMixer] as [AVAudioNode])
            + (sinkNode.map { [$0] } ?? [])
        for node in attached where node.engine === engine {
            engine.disconnectNodeInput(node)
            engine.detach(node)
        }
        sinkNode = nil
        ring.reset()
        levels.reset()
        running = false
    }

    enum EngineError: Error, LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let s) = self { return s }; return nil }
    }

    // MARK: - Manual HAL output

    private func buildOutputUnit(deviceID id: AudioDeviceID, sampleRate: Double) throws {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0
        )
        guard let comp = AudioComponentFindNext(nil, &desc) else {
            throw EngineError.message("HAL output component not found.")
        }
        var unit: AudioUnit?
        var st = AudioComponentInstanceNew(comp, &unit)
        guard st == noErr, let unit else {
            throw EngineError.message("AudioComponentInstanceNew failed (\(st)).")
        }

        var dev = id
        st = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &dev, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw EngineError.message("Couldn't bind the output device (\(st)).")
        }

        var fmt = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
            mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
        )
        st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &fmt, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            // Bluetooth outputs land here when opening the input has just
            // dragged them into 24 kHz voice mode and they refuse the rate.
            throw EngineError.message(
                "The output device wouldn't accept \(Int(sampleRate)) Hz (error \(st)). "
                + "Bluetooth headphones often drop to 24 kHz when an input opens — "
                + "pick a wired or built-in output, or set the bridge and output to the same rate in Audio MIDI Setup."
            )
        }

        let refcon = Unmanaged.passUnretained(ring).toOpaque()
        var cb = AURenderCallbackStruct(inputProc: renderOutputCallback, inputProcRefCon: refcon)
        st = AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw EngineError.message("Couldn't install the render callback (\(st)).")
        }

        st = AudioUnitInitialize(unit)
        guard st == noErr else {
            AudioComponentInstanceDispose(unit)
            throw EngineError.message("Couldn't initialise the output unit (\(st)).")
        }
        st = AudioOutputUnitStart(unit)
        guard st == noErr else {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw EngineError.message("Couldn't start the output unit (\(st)).")
        }
        outputUnit = unit
    }

    // Static factory keeps the sink block free of any inherited actor
    // isolation — required because CoreAudio invokes it on its own IO thread.
    private static func makeSinkReceiver(ring: FloatRingBuffer, levels: LevelStore) -> AVAudioSinkNodeReceiverBlock {
        return { _, frameCount, ablPtr -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
            let frames = Int(frameCount)
            var peak: Float = 0
            if abl.count == 1 {
                let buf = abl[0]
                let chans = Int(buf.mNumberChannels)
                guard let raw = buf.mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if chans == 2 {
                    ring.write(raw, count: frames * 2)
                    for i in 0..<(frames * 2) { let a = abs(raw[i]); if a > peak { peak = a } }
                } else if chans == 1 {
                    let tmp = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
                    defer { tmp.deallocate() }
                    for i in 0..<frames { tmp[i*2] = raw[i]; tmp[i*2+1] = raw[i] }
                    ring.write(tmp, count: frames * 2)
                    for i in 0..<frames { let a = abs(raw[i]); if a > peak { peak = a } }
                }
            } else if abl.count >= 2 {
                guard
                    let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                    let r = abl[1].mData?.assumingMemoryBound(to: Float.self)
                else { return noErr }
                let tmp = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
                defer { tmp.deallocate() }
                for i in 0..<frames {
                    tmp[i*2] = l[i]; tmp[i*2+1] = r[i]
                    let al = abs(l[i]); if al > peak { peak = al }
                    let ar = abs(r[i]); if ar > peak { peak = ar }
                }
                ring.write(tmp, count: frames * 2)
            }
            levels.push(min(peak, 1.0))
            return noErr
        }
    }

    // Same pattern as makeSinkReceiver: the tap callback runs on
    // CoreAudio's `RealtimeMessenger.mServiceQueue`.
    private static func makeInputTap(
        player: AVAudioPlayerNode,
        converter: AVAudioConverter,
        inputFormat: AVAudioFormat,
        chainFormat: AVAudioFormat
    ) -> AVAudioNodeTapBlock {
        let ratio = chainFormat.sampleRate / inputFormat.sampleRate
        return { [weak player, weak converter] buffer, _ in
            guard let player, let converter else { return }
            let outFrames = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 8)
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: chainFormat, frameCapacity: outFrames) else { return }
            var consumed = false
            var err: NSError?
            let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
                if consumed { outStatus.pointee = .endOfStream; return nil }
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            if status == .haveData || status == .inputRanDry, outBuf.frameLength > 0 {
                player.scheduleBuffer(outBuf, completionHandler: nil)
            }
        }
    }

    // MARK: - CoreAudio helpers

    /// Explains a graph failure in terms of what was actually observed, rather
    /// than guessing at one cause. A mono or low-rate input reading is the
    /// strongest signal, and it has two very different explanations worth
    /// listing: a genuinely reconfigured device, or missing microphone access.
    private static func startFailureAdvice(reason: String, input: AVAudioFormat) -> String {
        let channels = input.channelCount == 1 ? "mono" : "\(input.channelCount) ch"
        var advice = "The effects chain couldn't start. "
        if input.channelCount < 2 || input.sampleRate < 44_100 {
            advice += "The input is reporting \(Int(input.sampleRate)) Hz \(channels), which the chain "
                + "can't use. That happens when Notch Lyrics doesn't have microphone access "
                + "(check System Settings › Privacy & Security › Microphone), or when the bridge "
                + "has been reconfigured — set BlackHole 2ch to 48000 Hz with 2 channels in "
                + "Audio MIDI Setup. "
        } else {
            advice += "The input is \(Int(input.sampleRate)) Hz \(channels). Set the bridge and your "
                + "output to the same sample rate in Audio MIDI Setup, then try again. "
        }
        return advice + "(\(reason))"
    }

    /// The rate a device is actually running at, or 0 if it won't say. The
    /// effects chain follows the *output* device, since that's the one whose
    /// format the HAL output unit has to match.
    private static func nominalSampleRate(deviceID id: AudioDeviceID) -> Double {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Double = 0
        var size = UInt32(MemoryLayout<Double>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    /// Static, so it can run on the audio queue without touching instance state.
    private static func deviceID(forUID uid: String?, mustHaveInput: Bool = false,
                                 mustHaveOutput: Bool = false) -> AudioDeviceID? {
        guard let uid else { return nil }
        return CoreAudioDevices.list().first { d in
            d.uid == uid && (!mustHaveInput || d.hasInput) && (!mustHaveOutput || d.hasOutput)
        }?.id
    }
}

// MARK: - C render callback (file-scope, @convention(c))

private let renderOutputCallback: AURenderCallback = { refcon, _, _, _, frames, ioData in
    guard let ioData else { return noErr }
    let ring = Unmanaged<FloatRingBuffer>.fromOpaque(refcon).takeUnretainedValue()
    let abl = UnsafeMutableAudioBufferListPointer(ioData)
    guard let raw = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
    let needed = Int(frames) * 2
    let got = ring.read(into: raw, count: needed)
    if got < needed {
        for i in got..<needed { raw[i] = 0 }
    }
    return noErr
}
