import Foundation
import os

/// Immutable routing plan, built on the main thread from a VirtualDevice.
public struct MixPlan {
    public struct Input {
        public var offset: Int
        public var channels: Int
        public var gain: Float
        public init(offset: Int, channels: Int, gain: Float) { self.offset = offset; self.channels = channels; self.gain = gain }
    }
    public struct Output {
        public var offset: Int
        public var channels: Int
        public var gain: Float
        public init(offset: Int, channels: Int, gain: Float) { self.offset = offset; self.channels = channels; self.gain = gain }
    }
    public struct InputWire { public var input: Int; public var inCh: Int; public var bus: Int
        public init(_ input: Int, _ inCh: Int, _ bus: Int) { self.input = input; self.inCh = inCh; self.bus = bus } }
    public struct OutputWire { public var bus: Int; public var output: Int; public var outCh: Int
        public init(_ bus: Int, _ output: Int, _ outCh: Int) { self.bus = bus; self.output = output; self.outCh = outCh } }

    public var inputs: [Input]
    public var outputs: [Output]
    public var busCount: Int
    public var inputToBus: [InputWire]
    public var busToOutput: [OutputWire]
    public var masterGain: Float

    public init(inputs: [Input], outputs: [Output], busCount: Int,
                inputToBus: [InputWire], busToOutput: [OutputWire], masterGain: Float) {
        self.inputs = inputs; self.outputs = outputs; self.busCount = busCount
        self.inputToBus = inputToBus; self.busToOutput = busToOutput; self.masterGain = masterGain
    }

    public static let empty = MixPlan(inputs: [], outputs: [], busCount: 0, inputToBus: [], busToOutput: [], masterGain: 1)
}

/// RMS levels per channel, indexed like the plan.
public struct Meters: Equatable {
    public var inputs: [[Float]] = []
    public var buses: [Float] = []
    public var outputs: [[Float]] = []
    public init() {}
}

/// Real-time safe mixer. `process` allocates nothing and never blocks.
public final class MixKernel {
    public static let maxNodes = 16
    public static let maxNodeChannels = 8

    private var plan = MixPlan.empty
    private var pending: MixPlan?
    private let planLock = OSAllocatedUnfairLock()

    private let maxFrames: Int
    private let maxBuses: Int
    private let bus: UnsafeMutablePointer<Float>
    private let inMeter: UnsafeMutablePointer<Float>
    private let busMeter: UnsafeMutablePointer<Float>
    private let outMeter: UnsafeMutablePointer<Float>

    public init(maxFrames: Int, maxBuses: Int) {
        self.maxFrames = maxFrames
        self.maxBuses = maxBuses
        bus = .allocate(capacity: maxFrames * maxBuses)
        bus.initialize(repeating: 0, count: maxFrames * maxBuses)
        let nodeSlots = Self.maxNodes * Self.maxNodeChannels
        inMeter = .allocate(capacity: nodeSlots); inMeter.initialize(repeating: 0, count: nodeSlots)
        outMeter = .allocate(capacity: nodeSlots); outMeter.initialize(repeating: 0, count: nodeSlots)
        busMeter = .allocate(capacity: maxBuses); busMeter.initialize(repeating: 0, count: maxBuses)
    }

    deinit {
        bus.deallocate(); inMeter.deallocate(); outMeter.deallocate(); busMeter.deallocate()
    }

    public func install(_ p: MixPlan) {
        precondition(p.busCount <= maxBuses && p.inputs.count <= Self.maxNodes && p.outputs.count <= Self.maxNodes)
        planLock.withLock { pending = p }
    }

    /// Non-RT: snapshot of the latest levels laid out like the installed plan.
    public func meters() -> Meters {
        let p = planLock.withLock { pending ?? plan }
        var m = Meters()
        m.inputs = p.inputs.enumerated().map { i, inp in
            (0..<min(inp.channels, Self.maxNodeChannels)).map { inMeter[i * Self.maxNodeChannels + $0] }
        }
        m.buses = (0..<p.busCount).map { busMeter[$0] }
        m.outputs = p.outputs.enumerated().map { i, o in
            (0..<min(o.channels, Self.maxNodeChannels)).map { outMeter[i * Self.maxNodeChannels + $0] }
        }
        return m
    }

    /// RT: `inputs` / `outputs` hold every interleaved buffer of the device; plan entries select them by `offset`.
    public func process(inputs: [UnsafePointer<Float>], outputs: [UnsafeMutablePointer<Float>], frames: Int) {
        if planLock.lockIfAvailable() {
            if let p = pending { plan = p; pending = nil }
            planLock.unlock()
        }
        let p = plan
        let n = min(frames, maxFrames)
        let inv = 1 / Float(max(n, 1))

        bus.update(repeating: 0, count: n * p.busCount)

        for ii in 0..<p.inputs.count where p.inputs[ii].offset < inputs.count {
            let inp = p.inputs[ii], src = inputs[inp.offset]
            for ch in 0..<min(inp.channels, Self.maxNodeChannels) {
                var acc: Float = 0
                for f in 0..<n { let v = src[f * inp.channels + ch]; acc += v * v }
                inMeter[ii * Self.maxNodeChannels + ch] = (acc * inv).squareRoot()
            }
        }

        for w in p.inputToBus where w.input < p.inputs.count && w.bus < p.busCount {
            let inp = p.inputs[w.input]
            guard w.inCh < inp.channels, inp.offset < inputs.count else { continue }
            let src = inputs[inp.offset], g = inp.gain, dst = bus + w.bus * n
            for f in 0..<n { dst[f] += src[f * inp.channels + w.inCh] * g }
        }

        for b in 0..<p.busCount {
            var acc: Float = 0
            let s = bus + b * n
            for f in 0..<n { s[f] *= p.masterGain; acc += s[f] * s[f] }
            busMeter[b] = (acc * inv).squareRoot()
        }

        for oi in 0..<p.outputs.count where p.outputs[oi].offset < outputs.count {
            outputs[p.outputs[oi].offset].update(repeating: 0, count: n * p.outputs[oi].channels)
        }

        for w in p.busToOutput where w.output < p.outputs.count && w.bus < p.busCount {
            let o = p.outputs[w.output]
            guard w.outCh < o.channels, o.offset < outputs.count else { continue }
            let dst = outputs[o.offset], s = bus + w.bus * n
            for f in 0..<n { dst[f * o.channels + w.outCh] += s[f] * o.gain }
        }

        for oi in 0..<p.outputs.count where p.outputs[oi].offset < outputs.count {
            let o = p.outputs[oi], dst = outputs[o.offset]
            for ch in 0..<min(o.channels, Self.maxNodeChannels) {
                var acc: Float = 0
                for f in 0..<n { let v = dst[f * o.channels + ch]; acc += v * v }
                outMeter[oi * Self.maxNodeChannels + ch] = (acc * inv).squareRoot()
            }
        }
    }
}
