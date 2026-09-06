import CoreAudio
import Foundation
import WhereSoundMeetCore
import os

/// One aggregate device + IOProc per running VirtualDevice. Mixes sources into the virtual output and monitors.
final class DeviceGraph: @unchecked Sendable {
    static let maxFrames = 4096
    static let log = Logger(subsystem: DriverProtocol.appBundleID, category: "graph")

    private(set) var device: VirtualDevice
    private let taps: TapController
    private let kernel = MixKernel(maxFrames: DeviceGraph.maxFrames, maxBuses: MixKernel.maxNodes)

    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var procID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?
    private var appTaps: [UUID: TapController.Tap] = [:]
    private var structureKey = ""
    private var subUIDs: [String] = []
    private var composition: [String: Any] = [:]

    /// Buffer index of the first input/output stream for each sub-device UID, and per tap UID.
    private var inputBufferForUID: [String: Int] = [:]
    private var outputBufferForUID: [String: Int] = [:]
    private var inputChannels: [Int] = []
    private var outputChannels: [Int] = []

    private var inputIndexForSource: [UUID: Int] = [:]
    private var outputIndexForMonitor: [UUID: Int] = [:]

    /// Effect chains keyed by source id; `rtChains` maps input buffer offset → chain for the IO thread.
    private var chains: [UUID: EffectChain] = [:]
    private var rtChains: [EffectChain?] = Array(repeating: nil, count: 64)
    private let chainLock = OSAllocatedUnfairLock()
    private var sampleRate: Double = DriverProtocol.sampleRate

    private var inputPtrs: [UnsafePointer<Float>] = []
    private var outputPtrs: [UnsafeMutablePointer<Float>] = []
    private let silence: UnsafeMutablePointer<Float>

    init(device: VirtualDevice, taps: TapController) throws {
        self.device = device
        self.taps = taps
        silence = .allocate(capacity: DeviceGraph.maxFrames * MixKernel.maxNodeChannels)
        silence.initialize(repeating: 0, count: DeviceGraph.maxFrames * MixKernel.maxNodeChannels)
        inputPtrs.reserveCapacity(64)
        outputPtrs.reserveCapacity(64)
        try build()
    }

    deinit {
        teardown()
        silence.deallocate()
    }

    /// Levels keyed by node id: sources and monitors get one value per channel, output channels get one value.
    func nodeLevels() -> [UUID: [Float]] {
        let m = kernel.meters()
        var out: [UUID: [Float]] = [:]
        for (id, i) in inputIndexForSource where i < m.inputs.count { out[id] = m.inputs[i] }
        for (id, i) in outputIndexForMonitor where i < m.outputs.count { out[id] = m.outputs[i] }
        for (b, ch) in device.outputChannels.enumerated() where b < m.buses.count { out[ch.id] = [m.buses[b]] }
        return out
    }

    func update(_ newDevice: VirtualDevice) throws {
        device = newDevice
        if Self.structureKey(for: newDevice) != structureKey {
            teardown()
            try build()
        } else {
            kernel.install(makePlan())
        }
    }

    func stop() { teardown() }

    // MARK: - Build

    private static func structureKey(for d: VirtualDevice) -> String {
        let s = d.sources.map { src -> String in
            switch src.kind {
            case .app(let b, _): return "app:\(b):\(src.muteOriginal)"
            case .inputDevice(let uid, _): return "in:\(uid)"
            case .passThru: return "pass"
            }
        }
        let m = d.monitors.map { "mon:\($0.deviceUID)" }
        return (s + m).joined(separator: "|")
    }

    private func build() throws {
        structureKey = Self.structureKey(for: device)
        var tapList: [[String: Any]] = []
        for src in device.sources {
            switch src.kind {
            case .app(let bundleID, _):
                do {
                    let tap = try taps.makeProcessTap(bundleID: bundleID, muteOriginal: src.muteOriginal)
                    appTaps[src.id] = tap
                    tapList.append([kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 1])
                } catch {
                    Self.log.info("skipping source \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            case .passThru, .inputDevice:
                break
            }
        }

        var subUIDs: [String] = [device.passThruUID]
        for src in device.sources { if case .inputDevice(let uid, _) = src.kind, !subUIDs.contains(uid) { subUIDs.append(uid) } }
        for m in device.monitors where !subUIDs.contains(m.deviceUID) { subUIDs.append(m.deviceUID) }
        // Hidden devices (the cap device) are absent from the device list but resolve by UID.
        subUIDs = subUIDs.filter { AudioSystem.deviceID(forUID: $0) != nil }
        guard subUIDs.first == device.passThruUID else { throw DriverError.coreAudio("Virtual device \(device.name) not found", -1) }
        self.subUIDs = subUIDs

        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Where Sound Meet Graph \(device.name)",
            kAudioAggregateDeviceUIDKey: DriverProtocol.aggregateUIDPrefix + device.id.uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            kAudioAggregateDeviceMainSubDeviceKey: device.passThruUID,
            kAudioAggregateDeviceSubDeviceListKey: subUIDs.map {
                [kAudioSubDeviceUIDKey: $0,
                 kAudioSubDeviceDriftCompensationKey: ($0 == device.passThruUID) ? 0 : 1]
            },
            kAudioAggregateDeviceTapListKey: tapList,
            kAudioAggregateDeviceTapAutoStartKey: 1,
        ]
        composition = desc
        var aggID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard status == noErr, aggID != kAudioObjectUnknown else { throw DriverError.coreAudio("Create aggregate device", status) }
        aggregateID = aggID

        var frameSize: UInt32 = 512
        var fsAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyBufferFrameSize,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(aggID, &fsAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frameSize)

        mapBuffers(subUIDs: subUIDs)
        if let sr: Float64 = AudioSystem.scalarProperty(aggID, kAudioDevicePropertyNominalSampleRate), sr > 0 { sampleRate = sr }
        kernel.install(makePlan())
        installRateListener(aggID)

        var pid: AudioDeviceIOProcID?
        let block: AudioDeviceIOBlock = { [unowned self] _, inData, _, outData, _ in
            self.render(input: inData, output: outData)
        }
        let s2 = AudioDeviceCreateIOProcIDWithBlock(&pid, aggID, nil, block)
        guard s2 == noErr, let pid else { teardown(); throw DriverError.coreAudio("Create IOProc", s2) }
        procID = pid
        let s3 = AudioDeviceStart(aggID, pid)
        guard s3 == noErr else { teardown(); throw DriverError.coreAudio("Start device", s3) }
        Self.log.info("graph started for \(self.device.name, privacy: .public): inputs=\(self.inputChannels.count) outputs=\(self.outputChannels.count)")
    }

    /// Clients (e.g. iPad apps) may switch the virtual device's sample rate; rebuild effect chains to match.
    private func installRateListener(_ aggID: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.aggregateID == aggID,
                      let sr: Float64 = AudioSystem.scalarProperty(aggID, kAudioDevicePropertyNominalSampleRate), sr > 0, sr != self.sampleRate
                else { return }
                Self.log.info("sample rate changed to \(sr) for \(self.device.name, privacy: .public)")
                self.sampleRate = sr
                self.chains = [:]
                self.kernel.install(self.makePlan())
            }
        }
        rateListener = block
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(aggID, &addr, .main, block)
    }

    /// Re-targets app taps after the system process list changed, keeping the aggregate and its IOProc alive.
    /// Tearing the graph down for every process change restarted the tapped app's own IO (Discord's voice
    /// context) and left it with a stale device handle; swapping taps in the composition does not.
    func refreshTaps() {
        guard aggregateID != kAudioObjectUnknown else { return }
        var next = appTaps
        var created: [TapController.Tap] = []
        for src in device.sources {
            guard case .app(let bundleID, _) = src.kind else { continue }
            let procs = Set(AudioSystem.processObjectIDs(bundleID: bundleID))
            // An app with no audio processes keeps its old tap: an empty process list would tap the whole system.
            guard !procs.isEmpty else { continue }
            if let tap = appTaps[src.id], Set(tap.processIDs) == procs { continue }
            do {
                let tap = try taps.makeProcessTap(bundleID: bundleID, muteOriginal: src.muteOriginal)
                next[src.id] = tap
                created.append(tap)
            } catch {
                Self.log.info("tap refresh skipped \(bundleID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        guard !created.isEmpty else { return }
        var desc = composition
        desc[kAudioAggregateDeviceTapListKey] = device.sources.compactMap { src -> [String: Any]? in
            guard case .app = src.kind, let tap = next[src.id] else { return nil }
            return [kAudioSubTapUIDKey: tap.uid, kAudioSubTapDriftCompensationKey: 1]
        }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioAggregateDevicePropertyComposition,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = desc as CFDictionary
        let status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, UInt32(MemoryLayout<CFDictionary>.size), &cf)
        guard status == noErr else {
            Self.log.error("tap list update failed (\(status)), rebuilding \(self.device.name, privacy: .public)")
            for tap in created { taps.destroy(tap) }
            teardown()
            try? build()
            return
        }
        composition = desc
        let old = appTaps
        appTaps = next
        for (id, tap) in old where next[id]?.objectID != tap.objectID { taps.destroy(tap) }
        mapBuffers(subUIDs: subUIDs)
        kernel.install(makePlan())
        Self.log.info("taps refreshed for \(self.device.name, privacy: .public): \(created.count) new")
    }

    /// Aggregate buffers follow sub-device order (each sub-device's streams), then taps.
    private func mapBuffers(subUIDs: [String]) {
        inputBufferForUID = [:]; outputBufferForUID = [:]
        inputChannels = Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeInput)
        outputChannels = Self.bufferChannels(aggregateID, scope: kAudioObjectPropertyScopeOutput)
        var inIdx = 0, outIdx = 0
        for uid in subUIDs {
            guard let id = AudioSystem.deviceID(forUID: uid) else { continue }
            let inStreams = Self.streamCount(id, scope: kAudioObjectPropertyScopeInput)
            let outStreams = Self.streamCount(id, scope: kAudioObjectPropertyScopeOutput)
            if inStreams > 0 { inputBufferForUID[uid] = inIdx; inIdx += inStreams }
            if outStreams > 0 { outputBufferForUID[uid] = outIdx; outIdx += outStreams }
        }
        for src in device.sources {
            if case .app = src.kind, let tap = appTaps[src.id] { inputBufferForUID[tap.uid] = inIdx; inIdx += 1 }
        }
        if inIdx != inputChannels.count || outIdx != outputChannels.count {
            Self.log.error("buffer map mismatch: mapped in=\(inIdx) out=\(outIdx), actual in=\(self.inputChannels.count) out=\(self.outputChannels.count)")
        }
        Self.log.info("map in=\(self.inputBufferForUID.description, privacy: .public) out=\(self.outputBufferForUID.description, privacy: .public) inCh=\(self.inputChannels.description, privacy: .public) outCh=\(self.outputChannels.description, privacy: .public)")
    }

    private func makePlan() -> MixPlan {
        var inputs: [MixPlan.Input] = []
        var inputIndexForSource: [UUID: Int] = [:]
        var outputIndexForMonitor: [UUID: Int] = [:]
        var nextChains: [UUID: EffectChain] = [:]
        var nextRT: [EffectChain?] = Array(repeating: nil, count: 64)
        func syncChain(for src: Source, channels: Int, offset: Int, into next: inout [UUID: EffectChain], rt: inout [EffectChain?]) {
            guard src.effects.anyEnabled else { return }
            let chain: EffectChain
            if let existing = chains[src.id], existing.channels == channels { chain = existing }
            else { chain = EffectChain(channels: channels, sampleRate: sampleRate) }
            chain.apply(src.effects)
            next[src.id] = chain
            if offset < rt.count { rt[offset] = chain }
        }
        defer { self.inputIndexForSource = inputIndexForSource; self.outputIndexForMonitor = outputIndexForMonitor }
        for src in device.sources {
            let uid: String?
            switch src.kind {
            case .app: uid = appTaps[src.id]?.uid
            case .passThru: uid = device.passThruUID
            case .inputDevice(let u, _): uid = u
            }
            guard let uid, let buf = inputBufferForUID[uid], buf < inputChannels.count else { continue }
            inputIndexForSource[src.id] = inputs.count
            let delay = Int((Double(src.delayMs) / 1000 * sampleRate).rounded())
            inputs.append(.init(offset: buf, channels: inputChannels[buf], gain: src.isOn ? src.volume : 0,
                                delayFrames: min(max(delay, 0), MixKernel.maxDelayFrames)))
            syncChain(for: src, channels: inputChannels[buf], offset: buf, into: &nextChains, rt: &nextRT)
        }
        chains = nextChains
        let rtSnapshot = nextRT
        chainLock.withLock { rtChains = rtSnapshot }
        var outputs: [MixPlan.Output] = []
        if let buf = outputBufferForUID[device.passThruUID], buf < outputChannels.count {
            outputs.append(.init(offset: buf, channels: outputChannels[buf], gain: 1))
        }
        for m in device.monitors {
            guard let buf = outputBufferForUID[m.deviceUID], buf < outputChannels.count else { continue }
            outputIndexForMonitor[m.id] = outputs.count
            outputs.append(.init(offset: buf, channels: outputChannels[buf], gain: m.isOn ? m.volume : 0))
        }
        let busIndex = Dictionary(uniqueKeysWithValues: device.outputChannels.enumerated().map { ($1.id, $0) })
        var inputToBus: [MixPlan.InputWire] = []
        var busToOutput: [MixPlan.OutputWire] = []
        var inputToOutput: [MixPlan.DirectWire] = []
        if !outputs.isEmpty {
            for b in 0..<min(device.outputChannels.count, outputs[0].channels) { busToOutput.append(.init(b, 0, b)) }
        }
        for w in device.wires {
            if let ii = inputIndexForSource[w.from.nodeID], let bus = busIndex[w.to.nodeID] {
                inputToBus.append(.init(ii, w.from.channel, bus))
            } else if let bus = busIndex[w.from.nodeID], let oi = outputIndexForMonitor[w.to.nodeID] {
                busToOutput.append(.init(bus, oi, w.to.channel))
            } else if let ii = inputIndexForSource[w.from.nodeID], let oi = outputIndexForMonitor[w.to.nodeID] {
                inputToOutput.append(.init(ii, w.from.channel, oi, w.to.channel))
            }
        }
        return MixPlan(inputs: inputs, outputs: outputs, busCount: min(device.outputChannels.count, MixKernel.maxNodes),
                       inputToBus: inputToBus, busToOutput: busToOutput, inputToOutput: inputToOutput,
                       masterGain: device.isOn ? device.volume : 0)
    }

    // MARK: - Render (RT thread)

    private var callbackCount = 0

    private func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        callbackCount += 1
        let diag = callbackCount % 2000 == 1
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)
        inputPtrs.removeAll(keepingCapacity: true)
        outputPtrs.removeAll(keepingCapacity: true)
        var frames = 0
        for b in inList {
            let ch = max(Int(b.mNumberChannels), 1)
            frames = max(frames, Int(b.mDataByteSize) / (ch * MemoryLayout<Float>.size))
            inputPtrs.append(b.mData.map { UnsafePointer($0.assumingMemoryBound(to: Float.self)) } ?? UnsafePointer(silence))
        }
        if chainLock.lockIfAvailable() {
            for i in 0..<min(inputPtrs.count, rtChains.count) {
                if let chain = rtChains[i] { inputPtrs[i] = chain.process(inputPtrs[i], frames: frames) }
            }
            chainLock.unlock()
        }
        for b in outList {
            let ch = max(Int(b.mNumberChannels), 1)
            frames = max(frames, Int(b.mDataByteSize) / (ch * MemoryLayout<Float>.size))
            outputPtrs.append(b.mData?.assumingMemoryBound(to: Float.self) ?? silence)
        }
        kernel.process(inputs: inputPtrs, outputs: outputPtrs, frames: frames)
        if diag {
            let m = kernel.meters()
            Self.log.debug("cb#\(self.callbackCount) frames=\(frames) in=\(self.inputPtrs.count) out=\(self.outputPtrs.count) meters in=\(m.inputs.description, privacy: .public) bus=\(m.buses.description, privacy: .public) out=\(m.outputs.description, privacy: .public)")
        }
    }

    // MARK: - Teardown

    private func teardown() {
        if aggregateID != kAudioObjectUnknown {
            if let rateListener {
                var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
                AudioObjectRemovePropertyListenerBlock(aggregateID, &addr, .main, rateListener)
            }
            rateListener = nil
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = kAudioObjectUnknown
        for tap in appTaps.values { taps.destroy(tap) }
        appTaps = [:]
        chainLock.withLock { rtChains = Array(repeating: nil, count: 64) }
        chains = [:]
    }

    // MARK: - Helpers

    private static func streamCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func bufferChannels(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }
}
