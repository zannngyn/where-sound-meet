import AppKit
import CoreAudio
import Foundation
import WhereSoundMeetCore

enum DriverError: LocalizedError {
    case notInstalled
    case bundleMissing
    case coreAudio(String, OSStatus)
    case install(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled: return "Where Sound Meet driver is not installed."
        case .bundleMissing: return "WhereSoundMeetDriver.driver is missing from the app bundle."
        case .coreAudio(let what, let status): return "\(what) failed (\(status))."
        case .install(let msg): return "Driver install failed: \(msg)"
        }
    }
}

/// Talks to the HAL plug-in through its custom properties.
enum DriverClient {
    static let installPath = "/Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver"

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: installPath) }

    static func pluginObjectID() -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateBundleIDToPlugIn,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var bundleID = DriverProtocol.driverBundleID as CFString
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &bundleID) { qual in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), qual, &size, &id)
        }
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func push(devices: [(uid: String, name: String)]) throws {
        guard let plugin = pluginObjectID() else { throw DriverError.notInstalled }
        var addr = AudioObjectPropertyAddress(mSelector: DriverProtocol.deviceListSelector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let list = devices.map { [DriverProtocol.keyUID: $0.uid, DriverProtocol.keyName: $0.name] } as CFArray
        var value: CFPropertyList? = list
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(plugin, &addr, 0, nil, UInt32(MemoryLayout<CFPropertyList?>.size), ptr)
        }
        guard status == noErr else { throw DriverError.coreAudio("Set device list", status) }
    }

    static func currentDeviceUIDs() -> [String] {
        guard let plugin = pluginObjectID() else { return [] }
        var addr = AudioObjectPropertyAddress(mSelector: DriverProtocol.deviceListSelector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: CFPropertyList?
        var size = UInt32(MemoryLayout<CFPropertyList?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(plugin, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let arr = value as? [[String: String]] else { return [] }
        return arr.compactMap { $0[DriverProtocol.keyUID] }
    }

    static func setOwnerPID(deviceUID: String, pid: pid_t) throws {
        guard let dev = AudioSystem.deviceID(forUID: deviceUID) else { throw DriverError.coreAudio("Find device \(deviceUID)", -1) }
        var addr = AudioObjectPropertyAddress(mSelector: DriverProtocol.ownerPIDSelector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: CFPropertyList? = NSNumber(value: Int32(pid))
        let status = withUnsafePointer(to: &value) { ptr in
            AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<CFPropertyList?>.size), ptr)
        }
        guard status == noErr else { throw DriverError.coreAudio("Set owner pid", status) }
    }

    /// Copies the bundled driver into the HAL folder with an admin prompt and restarts coreaudiod.
    static func installDriver() throws {
        guard let src = Bundle.main.resourceURL?.appendingPathComponent("WhereSoundMeetDriver.driver"),
              FileManager.default.fileExists(atPath: src.path) else { throw DriverError.bundleMissing }
        let legacy = "/Library/Audio/Plug-Ins/HAL/LoopbackDriver.driver"
        let sh = "rm -rf '\(legacy)' '\(installPath)' && cp -R '\(src.path)' '\(installPath)' && chown -R root:wheel '\(installPath)' && killall coreaudiod"
        let escaped = sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err { throw DriverError.install(err[NSAppleScript.errorMessage] as? String ?? "\(err)") }
    }
}
