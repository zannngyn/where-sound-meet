import XCTest
@testable import WhereSoundMeetCore

final class DeviceStoreTests: XCTestCase {
    func testSaveThenLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lb-\(UUID()).json")
        let store = DeviceStore(url: url)
        XCTAssertEqual(try store.load(), [])
        let d = VirtualDevice.makeDefault()
        try store.save([d])
        XCTAssertEqual(try store.load(), [d])
    }
}
