import XCTest
@testable import WhereSoundMeetCore

final class EffectsTests: XCTestCase {
    func testDefaultsAreAllDisabled() {
        let e = EffectSettings()
        XCTAssertFalse(e.anyEnabled)
        XCTAssertEqual(e.enabledCount, 0)
        XCTAssertEqual(e.eq.gains.count, EQSettings.frequencies.count)
    }

    func testPresetsHaveTenBands() {
        for p in EQSettings.Preset.allCases { XCTAssertEqual(p.gains.count, 10, p.rawValue) }
        XCTAssertEqual(EQSettings.Preset.flat.gains, Array(repeating: 0, count: 10))
    }

    func testOldSourceJSONWithoutEffectsStillDecodes() throws {
        let json = """
        {"id":"6F2A1B3C-0000-4000-8000-000000000001","kind":{"passThru":{}},"isOn":true,"volume":1,"channelCount":2}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(Source.self, from: json)
        XCTAssertEqual(s.effects, EffectSettings())
    }

    func testEffectsRoundTrip() throws {
        var s = Source(kind: .passThru)
        s.effects.eq.enabled = true
        s.effects.eq.gains = EQSettings.Preset.vocal.gains
        s.effects.reverb.enabled = true
        s.effects.reverb.room = .cathedral
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(Source.self, from: data)
        XCTAssertEqual(back, s)
        XCTAssertEqual(back.effects.enabledCount, 2)
    }
}
