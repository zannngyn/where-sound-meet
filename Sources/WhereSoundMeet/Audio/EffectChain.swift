import AudioToolbox
import Foundation
import WhereSoundMeetCore
import os

/// Fixed-order chain of Apple AudioUnit effects for one source. Built on the main thread,
/// `process` runs on the IO thread without allocating.
final class EffectChain: @unchecked Sendable {
    static let maxFrames = 4096
    private static let log = Logger(subsystem: DriverProtocol.appBundleID, category: "effects")

    enum Stage: Int, CaseIterable { case highPass, lowPass, gate, eq, compressor, echo, reverb, limiter }

    let channels: Int
    let sampleRate: Double
    private var units: [Stage: AudioUnit] = [:]
    private let enabledMask = OSAllocatedUnfairLock<UInt32>(initialState: 0)
    private var rtMask: UInt32 = 0

    // Planar scratch: stageIn is what the render callback hands to the AU, stageOut receives its output.
    private var stageIn: [UnsafeMutablePointer<Float>]
    private var stageOut: [UnsafeMutablePointer<Float>]
    private let interleavedOut: UnsafeMutablePointer<Float>
    private let bufferList: UnsafeMutablePointer<AudioBufferList>
    private var sampleTime: Float64 = 0

    init(channels: Int, sampleRate: Double) {
        self.channels = max(1, min(channels, 8))
        self.sampleRate = sampleRate
        stageIn = (0..<self.channels).map { _ in .allocate(capacity: Self.maxFrames) }
        stageOut = (0..<self.channels).map { _ in .allocate(capacity: Self.maxFrames) }
        for p in stageIn + stageOut { p.initialize(repeating: 0, count: Self.maxFrames) }
        interleavedOut = .allocate(capacity: Self.maxFrames * self.channels)
        interleavedOut.initialize(repeating: 0, count: Self.maxFrames * self.channels)
        bufferList = AudioBufferList.allocate(maximumBuffers: self.channels).unsafeMutablePointer
        for s in Stage.allCases { units[s] = makeUnit(for: s) }
    }

    deinit {
        for u in units.values { AudioUnitUninitialize(u); AudioComponentInstanceDispose(u) }
        for p in stageIn + stageOut { p.deallocate() }
        interleavedOut.deallocate()
        free(bufferList)
    }

    // MARK: - Configuration (main thread)

    func apply(_ e: EffectSettings) {
        var mask: UInt32 = 0
        func set(_ s: Stage, _ on: Bool) { if on { mask |= 1 << UInt32(s.rawValue) } }
        set(.highPass, e.highPass.enabled); set(.lowPass, e.lowPass.enabled); set(.gate, e.gate.enabled)
        set(.eq, e.eq.enabled); set(.compressor, e.compressor.enabled); set(.echo, e.echo.enabled)
        set(.reverb, e.reverb.enabled); set(.limiter, e.limiter.enabled)

        if let u = units[.highPass] { param(u, kHipassParam_CutoffFrequency, e.highPass.cutoff) }
        if let u = units[.lowPass] { param(u, kLowPassParam_CutoffFrequency, e.lowPass.cutoff) }
        if let u = units[.gate] {
            param(u, kDynamicsProcessorParam_ExpansionThreshold, e.gate.threshold)
            param(u, kDynamicsProcessorParam_ExpansionRatio, e.gate.ratio)
            param(u, kDynamicsProcessorParam_Threshold, 20)          // no compression in the gate unit
            param(u, kDynamicsProcessorParam_AttackTime, 0.002)
            param(u, kDynamicsProcessorParam_ReleaseTime, 0.08)
        }
        if let u = units[.eq] {
            for (i, g) in e.eq.gains.prefix(10).enumerated() { param(u, kAUNBandEQParam_Gain + UInt32(i), g) }
        }
        if let u = units[.compressor] {
            param(u, kDynamicsProcessorParam_Threshold, e.compressor.threshold)
            param(u, kDynamicsProcessorParam_HeadRoom, e.compressor.headRoom)
            param(u, kDynamicsProcessorParam_AttackTime, e.compressor.attack)
            param(u, kDynamicsProcessorParam_ReleaseTime, e.compressor.release)
            param(u, kDynamicsProcessorParam_OverallGain, e.compressor.makeupGain)
            param(u, kDynamicsProcessorParam_ExpansionRatio, 1)
        }
        if let u = units[.echo] {
            param(u, kDelayParam_DelayTime, e.echo.time)
            param(u, kDelayParam_Feedback, e.echo.feedback)
            param(u, kDelayParam_WetDryMix, e.echo.mix)
        }
        if let u = units[.reverb] {
            var preset = AUPreset(presetNumber: Int32(e.reverb.room.presetIndex), presetName: nil)
            AudioUnitSetProperty(u, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0, &preset, UInt32(MemoryLayout<AUPreset>.size))
            param(u, kReverbParam_DryWetMix, e.reverb.mix)
        }
        if let u = units[.limiter] { param(u, kLimiterParam_PreGain, e.limiter.preGain) }

        let finalMask = mask
        enabledMask.withLock { $0 = finalMask }
    }

    // MARK: - RT

    /// Returns a pointer to the processed interleaved audio (or the input itself when nothing is enabled).
    func process(_ input: UnsafePointer<Float>, frames: Int) -> UnsafePointer<Float> {
        if let m = enabledMask.withLockIfAvailable({ $0 }) { rtMask = m }
        guard rtMask != 0 else { return input }
        let n = min(frames, Self.maxFrames)
        for ch in 0..<channels {
            let dst = stageIn[ch]
            for f in 0..<n { dst[f] = input[f * channels + ch] }
        }
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        for stage in Stage.allCases where rtMask & (1 << UInt32(stage.rawValue)) != 0 {
            guard let u = units[stage] else { continue }
            let list = UnsafeMutableAudioBufferListPointer(bufferList)
            for ch in 0..<channels {
                list[ch].mNumberChannels = 1
                list[ch].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
                list[ch].mData = UnsafeMutableRawPointer(stageOut[ch])
            }
            var flags = AudioUnitRenderActionFlags()
            let status = AudioUnitRender(u, &flags, &ts, 0, UInt32(n), bufferList)
            if status == noErr { swap(&stageIn, &stageOut) }
        }
        sampleTime += Float64(n)
        for ch in 0..<channels {
            let src = stageIn[ch]
            for f in 0..<n { interleavedOut[f * channels + ch] = src[f] }
        }
        return UnsafePointer(interleavedOut)
    }

    // MARK: - Self test

    static func selfTest() {
        let frames = 512, channels = 2, sr = 48_000.0
        var input = [Float](repeating: 0, count: frames * channels)
        for f in 0..<frames { let v = sinf(Float(f) * 2 * .pi * 1000 / Float(sr)) * 0.5; input[f * 2] = v; input[f * 2 + 1] = v }
        func rms(_ p: UnsafePointer<Float>, _ n: Int) -> Float { var a: Float = 0; for i in 0..<n { a += p[i] * p[i] }; return (a / Float(n)).squareRoot() }
        func run(_ label: String, _ configure: (inout EffectSettings) -> Void) {
            let chain = EffectChain(channels: channels, sampleRate: sr)
            var e = EffectSettings(); configure(&e); chain.apply(e)
            var out: Float = 0
            input.withUnsafeBufferPointer { buf in
                for _ in 0..<20 { out = rms(chain.process(buf.baseAddress!, frames: frames), frames * channels) }
            }
            print(String(format: "%-28@ in=%.3f out=%.3f", label, rms(input, frames * channels), out))
        }
        run("none") { _ in }
        run("lowPass 200 Hz (1 kHz tone)") { $0.lowPass.enabled = true; $0.lowPass.cutoff = 200 }
        run("highPass 5 kHz (1 kHz tone)") { $0.highPass.enabled = true; $0.highPass.cutoff = 5000 }
        run("eq -12 dB @ 1 kHz") { $0.eq.enabled = true; $0.eq.gains[5] = -12 }
        run("eq +6 dB @ 1 kHz") { $0.eq.enabled = true; $0.eq.gains[5] = 6 }
        run("gate threshold 0 dB") { $0.gate.enabled = true; $0.gate.threshold = 0; $0.gate.ratio = 50 }
        run("compressor -40 dB") { $0.compressor.enabled = true; $0.compressor.threshold = -40; $0.compressor.headRoom = 1 }
        run("limiter pre-gain +20") { $0.limiter.enabled = true; $0.limiter.preGain = 20 }
        run("echo mix 50") { $0.echo.enabled = true; $0.echo.mix = 50 }
        run("reverb cathedral mix 50") { $0.reverb.enabled = true; $0.reverb.room = .cathedral; $0.reverb.mix = 50 }
    }

    // MARK: - Setup helpers

    private func param(_ u: AudioUnit, _ id: AudioUnitParameterID, _ value: Float) {
        AudioUnitSetParameter(u, id, kAudioUnitScope_Global, 0, value, 0)
    }

    private func makeUnit(for stage: Stage) -> AudioUnit? {
        let subtype: OSType
        switch stage {
        case .highPass: subtype = kAudioUnitSubType_HighPassFilter
        case .lowPass: subtype = kAudioUnitSubType_LowPassFilter
        case .gate, .compressor: subtype = kAudioUnitSubType_DynamicsProcessor
        case .eq: subtype = kAudioUnitSubType_NBandEQ
        case .echo: subtype = kAudioUnitSubType_Delay
        case .reverb: subtype = kAudioUnitSubType_MatrixReverb
        case .limiter: subtype = kAudioUnitSubType_PeakLimiter
        }
        var desc = AudioComponentDescription(componentType: kAudioUnitType_Effect, componentSubType: subtype,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let comp = AudioComponentFindNext(nil, &desc) else { Self.log.error("no component for \(String(describing: stage))"); return nil }
        var unit: AudioUnit?
        guard AudioComponentInstanceNew(comp, &unit) == noErr, let u = unit else { return nil }

        var format = AudioStreamBasicDescription(mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                                                 mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                                 mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        let fsize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if stage == .eq {
            var bands: UInt32 = 10
            AudioUnitSetProperty(u, kAUNBandEQProperty_NumberOfBands, kAudioUnitScope_Global, 0, &bands, UInt32(MemoryLayout<UInt32>.size))
        }
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, fsize)
        AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &format, fsize)
        var maxFrames = UInt32(Self.maxFrames)
        AudioUnitSetProperty(u, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, UInt32(MemoryLayout<UInt32>.size))
        var callback = AURenderCallbackStruct(inputProc: EffectChain.renderInput,
                                              inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        AudioUnitSetProperty(u, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size))
        let status = AudioUnitInitialize(u)
        guard status == noErr else { Self.log.error("init failed \(status) for \(String(describing: stage))"); AudioComponentInstanceDispose(u); return nil }
        if stage == .eq {
            for (i, f) in EQSettings.frequencies.enumerated() {
                param(u, kAUNBandEQParam_FilterType + UInt32(i), Float(kAUNBandEQFilterType_Parametric))
                param(u, kAUNBandEQParam_Frequency + UInt32(i), f)
                param(u, kAUNBandEQParam_Bandwidth + UInt32(i), 1.0)
                param(u, kAUNBandEQParam_BypassBand + UInt32(i), 0)
            }
        }
        return u
    }

    /// Feeds the current stage input to the AU being rendered.
    private static let renderInput: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let chain = Unmanaged<EffectChain>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData else { return noErr }
        let list = UnsafeMutableAudioBufferListPointer(ioData)
        let n = Int(frames)
        for ch in 0..<min(list.count, chain.channels) {
            guard let dst = list[ch].mData?.assumingMemoryBound(to: Float.self) else { continue }
            dst.update(from: chain.stageIn[ch], count: n)
        }
        return noErr
    }
}
