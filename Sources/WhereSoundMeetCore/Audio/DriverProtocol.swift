import Foundation

/// Constants shared with the C HAL plug-in (Driver/WhereSoundMeetDriver.h). Keep both in sync.
public enum DriverProtocol {
    public static let driverBundleID = "com.zan.wheresoundmeet.driver"
    public static let appBundleID = "com.zan.wheresoundmeet"
    public static let maxDevices = 8
    public static let sampleRate = 48_000.0
    public static let channelCount = 2
    /// Plug-in object custom property: CFArray of {uid, name} dictionaries.
    public static let deviceListSelector = fourCC("lbdv")
    /// Device custom property: CFNumber pid of the owning app (0 = loop every client).
    public static let ownerPIDSelector = fourCC("lbpd")
    public static let keyUID = "uid"
    public static let keyName = "name"
    public static let deviceUIDPrefix = "com.zan.wheresoundmeet.device."
    public static let aggregateUIDPrefix = "com.zan.wheresoundmeet.agg."

    public static func fourCC(_ s: String) -> UInt32 {
        precondition(s.utf8.count == 4)
        return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Hidden capture device carrying what other apps send to the virtual device.
    public static let passThruSuffix = ".passthru"

    public static func deviceUID(for id: UUID) -> String { deviceUIDPrefix + id.uuidString }
    public static func passThruUID(for id: UUID) -> String { deviceUID(for: id) + passThruSuffix }
}
