import XCTest
@testable import WhereSoundMeetCore

final class VirtualDeviceTests: XCTestCase {
    func testDefaultDeviceHasPassThruWiredToTwoChannels() {
        let d = VirtualDevice.makeDefault()
        XCTAssertEqual(d.name, "Where Sound Meet Audio")
        XCTAssertEqual(d.sources.count, 1)
        XCTAssertEqual(d.sources[0].kind, .passThru)
        XCTAssertEqual(d.outputChannels.map(\.index), [0, 1])
        let s = d.sources[0].id, c = d.outputChannels
        XCTAssertEqual(d.wires, [
            Wire(from: Endpoint(nodeID: s, channel: 0), to: Endpoint(nodeID: c[0].id, channel: 0)),
            Wire(from: Endpoint(nodeID: s, channel: 1), to: Endpoint(nodeID: c[1].id, channel: 0)),
        ])
    }

    func testAddSourceAutoWires() {
        var d = VirtualDevice.makeDefault()
        let s = d.addSource(.app(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertTrue(d.wires.contains(Wire(from: Endpoint(nodeID: s.id, channel: 0),
                                            to: Endpoint(nodeID: d.outputChannels[0].id, channel: 0))))
        XCTAssertEqual(d.sourcesSummary, "1 App, Pass-Thru")
    }

    func testAddMonitorAutoWiresFromOutputChannels() {
        var d = VirtualDevice.makeDefault()
        let m = d.addMonitor(deviceUID: "BuiltInSpeakerDevice", name: "MacBook Air Speakers")
        XCTAssertTrue(d.wires.contains(Wire(from: Endpoint(nodeID: d.outputChannels[1].id, channel: 0),
                                            to: Endpoint(nodeID: m.id, channel: 1))))
    }

    func testRemoveNodeDropsWires() {
        var d = VirtualDevice.makeDefault()
        d.remove(nodeID: d.sources[0].id)
        XCTAssertTrue(d.sources.isEmpty)
        XCTAssertTrue(d.wires.isEmpty)
    }

    func testRemoveChannelPairReindexes() {
        var d = VirtualDevice.makeDefault()
        d.addOutputChannelPair()
        d.remove(nodeID: d.outputChannels[0].id)
        XCTAssertEqual(d.outputChannels.map(\.index), [0, 1])
        XCTAssertTrue(d.wires.isEmpty)
    }

    func testToggleWireAndValidation() {
        var d = VirtualDevice.makeDefault()
        let w = d.wires.first!
        d.toggleWire(w); XCTAssertFalse(d.wires.contains(w))
        d.toggleWire(w); XCTAssertTrue(d.wires.contains(w))
        let bad = Wire(from: Endpoint(nodeID: d.outputChannels[0].id, channel: 0),
                       to: Endpoint(nodeID: d.sources[0].id, channel: 0))
        XCTAssertFalse(d.isValid(bad))
        d.toggleWire(bad)
        XCTAssertFalse(d.wires.contains(bad))
    }

    func testCodableRoundTrip() throws {
        var d = VirtualDevice.makeDefault()
        d.addSource(.inputDevice(uid: "mic", name: "Mic"))
        let data = try JSONEncoder().encode([d])
        XCTAssertEqual(try JSONDecoder().decode([VirtualDevice].self, from: data), [d])
    }

    func testSummaryCounts() {
        var d = VirtualDevice.makeDefault()
        d.addSource(.app(bundleID: "a", name: "A"))
        d.addSource(.app(bundleID: "b", name: "B"))
        d.addSource(.inputDevice(uid: "m", name: "M"))
        XCTAssertEqual(d.sourcesSummary, "2 Apps, 1 Device, Pass-Thru")
    }
}
