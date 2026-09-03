import XCTest
@testable import WhereSoundMeetCore

final class DriverProtocolTests: XCTestCase {
    func testFourCCMatchesCConstant() {
        XCTAssertEqual(DriverProtocol.fourCC("lbdv"), 0x6C62_6476)
        XCTAssertEqual(DriverProtocol.fourCC("lbpd"), 0x6C62_7064)
    }

    func testDeviceUIDPrefix() {
        let id = UUID()
        XCTAssertTrue(DriverProtocol.deviceUID(for: id).hasPrefix("com.zan.wheresoundmeet.device."))
        XCTAssertTrue(DriverProtocol.deviceUID(for: id).hasSuffix(id.uuidString))
    }
}
