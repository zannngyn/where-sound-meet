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

    func testSourceToMonitorWireIsValid() {
        var d = VirtualDevice.makeDefault()
        let m = d.addMonitor(deviceUID: "out", name: "Out")
        let direct = Wire(from: Endpoint(nodeID: d.sources[0].id, channel: 0), to: Endpoint(nodeID: m.id, channel: 1))
        XCTAssertTrue(d.isValid(direct))
        d.toggleWire(direct)
        XCTAssertTrue(d.wires.contains(direct))
        d.remove(nodeID: m.id)
        XCTAssertFalse(d.wires.contains(direct))
    }

    func testDefaultFlagsAndDelayRoundTrip() throws {
        var d = VirtualDevice.makeDefault()
        d.isDefaultOutput = true
        d.isDefaultInput = true
        d.sources[0].delayMs = 180
        let data = try JSONEncoder().encode([d])
        let back = try JSONDecoder().decode([VirtualDevice].self, from: data)
        XCTAssertEqual(back, [d])
        XCTAssertEqual(back[0].sources[0].delayMs, 180)
        // Old configs without the new keys still load.
        let old = try JSONDecoder().decode([VirtualDevice].self, from: Data("""
        [{"id":"1A4BE0F4-E8D1-4AAC-9CC6-5558CEE2BB4F","name":"X","sources":[{"id":"13D2F72F-B7AC-4ED5-BEE5-B316B0381844","kind":{"passThru":{}}}],"outputChannels":[],"monitors":[],"wires":[]}]
        """.utf8))
        XCTAssertFalse(old[0].isDefaultOutput)
        XCTAssertEqual(old[0].sources[0].delayMs, 0)
    }
}

extension VirtualDeviceTests {
    /// Muting a voice-chat app's own output while tapping it broke its playout; capture must default to non-muting.
    func testAppSourceDoesNotMuteOriginalByDefault() throws {
        let s = Source(kind: .app(bundleID: "com.hnc.Discord", name: "Discord"))
        XCTAssertFalse(s.muteOriginal)
        let json = #"{"id":"1A4BE0F4-E8D1-4AAC-9CC6-5558CEE2BB4F","kind":{"app":{"bundleID":"com.hnc.Discord","name":"Discord"}}}"#
        let decoded = try JSONDecoder().decode(Source.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.muteOriginal)
    }
}
