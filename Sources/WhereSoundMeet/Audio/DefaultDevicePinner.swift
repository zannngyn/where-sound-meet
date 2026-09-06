import CoreAudio
import Foundation
import WhereSoundMeetCore
import os

/// Keeps a virtual device as the system default output / input while its flag is on, and puts the
/// previous defaults back when the flag is cleared, the device turns off, or the app quits.
/// macOS re-targets the defaults on its own (e.g. to AirPods when worn); `defaultsChanged` undoes that.
@MainActor
final class DefaultDevicePinner {
    private static let log = Logger(subsystem: DriverProtocol.appBundleID, category: "pin")
    private static let prevOutputKey = "pin.previousOutputUID"
    private static let prevSystemOutputKey = "pin.previousSystemOutputUID"
    private static let prevInputKey = "pin.previousInputUID"

    private var wantedOutput: String?
    private var wantedInput: String?
    private var retry: Task<Void, Never>?

    func apply(devices: [VirtualDevice]) {
        // Games play to the main device output (captured as Pass-Thru) and record its input (the app's mix).
        wantedOutput = devices.first { $0.isOn && $0.isDefaultOutput }?.driverUID
        wantedInput = devices.first { $0.isOn && $0.isDefaultInput }?.driverUID
        enforce()
    }

    /// The system default moved (macOS, another app, or the user); re-assert ours after a short pause.
    func defaultsChanged() {
        retry?.cancel()
        retry = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            enforce()
        }
    }

    /// Hand the defaults back before quitting so the system is never left on a device nobody drives.
    func releaseAll() {
        wantedOutput = nil
        wantedInput = nil
        enforce()
    }

    private func enforce() {
        pin(wantedOutput, kAudioHardwarePropertyDefaultOutputDevice, Self.prevOutputKey)
        pin(wantedOutput, kAudioHardwarePropertyDefaultSystemOutputDevice, Self.prevSystemOutputKey)
        pin(wantedInput, kAudioHardwarePropertyDefaultInputDevice, Self.prevInputKey)
    }

    private func pin(_ wanted: String?, _ selector: AudioObjectPropertySelector, _ prevKey: String) {
        let ud = UserDefaults.standard
        let current = AudioSystem.defaultDeviceUID(selector)
        if let wanted {
            // Device not published yet (driver still starting): the next hardware change calls apply() again.
            guard AudioSystem.deviceID(forUID: wanted) != nil, current != wanted else { return }
            if ud.string(forKey: prevKey) == nil, let current, !current.hasPrefix(DriverProtocol.deviceUIDPrefix) {
                ud.set(current, forKey: prevKey)
            }
            let ok = AudioSystem.setDefaultDevice(uid: wanted, selector)
            Self.log.info("pin \(Self.name(selector), privacy: .public) -> \(wanted, privacy: .public): \(ok)")
        } else if let prev = ud.string(forKey: prevKey) {
            ud.removeObject(forKey: prevKey)
            guard current?.hasPrefix(DriverProtocol.deviceUIDPrefix) == true else { return }   // user already moved on
            let ok = AudioSystem.setDefaultDevice(uid: prev, selector)
            Self.log.info("restore \(Self.name(selector), privacy: .public) -> \(prev, privacy: .public): \(ok)")
        }
    }

    private static func name(_ s: AudioObjectPropertySelector) -> String {
        switch s {
        case kAudioHardwarePropertyDefaultOutputDevice: return "output"
        case kAudioHardwarePropertyDefaultSystemOutputDevice: return "system output"
        default: return "input"
        }
    }
}
