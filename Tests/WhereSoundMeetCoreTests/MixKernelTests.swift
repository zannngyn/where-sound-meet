import XCTest
@testable import WhereSoundMeetCore

final class MixKernelTests: XCTestCase {
    /// 1 stereo input at half gain, 2 buses, outputs: virtual (2ch, gain 1) + monitor (2ch, gain 0.25).
    private func makePlan() -> MixPlan {
        MixPlan(inputs: [.init(offset: 0, channels: 2, gain: 0.5)],
                outputs: [.init(offset: 0, channels: 2, gain: 1), .init(offset: 1, channels: 2, gain: 0.25)],
                busCount: 2,
                inputToBus: [.init(0, 0, 0), .init(0, 1, 1)],
                busToOutput: [.init(0, 0, 0), .init(1, 0, 1), .init(0, 1, 0), .init(1, 1, 1)],
                masterGain: 1)
    }

    private func run(_ k: MixKernel, input: [Float], outputCount: Int, frames: Int) -> [[Float]] {
        var input = input
        var outs = [[Float]](repeating: [Float](repeating: 9, count: frames * 2), count: outputCount)
        input.withUnsafeMutableBufferPointer { i in
            var ptrs: [UnsafeMutablePointer<Float>] = []
            for n in 0..<outputCount { ptrs.append(outs[n].withUnsafeMutableBufferPointer { $0.baseAddress! }) }
            k.process(inputs: [UnsafePointer(i.baseAddress!)], outputs: ptrs, frames: frames)
        }
        return outs
    }

    func testRoutesAndAppliesGain() {
        let k = MixKernel(maxFrames: 4, maxBuses: 4)
        k.install(makePlan())
        let outs = run(k, input: [1, -1, 1, -1, 1, -1, 1, -1], outputCount: 2, frames: 4)
        XCTAssertEqual(outs[0], [0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(outs[1], [0.125, -0.125, 0.125, -0.125, 0.125, -0.125, 0.125, -0.125])
        let m = k.meters()
        XCTAssertEqual(m.inputs[0][0], 1, accuracy: 1e-5)
        XCTAssertEqual(m.buses[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(m.outputs[1][1], 0.125, accuracy: 1e-5)
    }

    func testNoWiresGivesSilence() {
        let k = MixKernel(maxFrames: 4, maxBuses: 2)
        var p = makePlan(); p.inputToBus = []
        k.install(p)
        let outs = run(k, input: [Float](repeating: 1, count: 8), outputCount: 2, frames: 4)
        XCTAssertEqual(outs[0], [Float](repeating: 0, count: 8))
        XCTAssertEqual(outs[1], [Float](repeating: 0, count: 8))
    }

    func testMasterGainZeroMutes() {
        let k = MixKernel(maxFrames: 4, maxBuses: 2)
        var p = makePlan(); p.masterGain = 0
        k.install(p)
        let outs = run(k, input: [Float](repeating: 1, count: 8), outputCount: 2, frames: 4)
        XCTAssertEqual(outs[0], [Float](repeating: 0, count: 8))
    }

    func testCrossWireLeftIntoRight() {
        let k = MixKernel(maxFrames: 2, maxBuses: 2)
        var p = makePlan(); p.inputs[0].gain = 1
        p.inputToBus = [.init(0, 0, 1)]   // L -> bus 1 (R)
        k.install(p)
        let outs = run(k, input: [1, 0, 1, 0], outputCount: 2, frames: 2)
        XCTAssertEqual(outs[0], [0, 1, 0, 1])
    }
}
