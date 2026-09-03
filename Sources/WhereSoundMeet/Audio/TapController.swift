import CoreAudio
import Foundation

/// Creates and destroys Core Audio process taps (macOS 14.2+).
final class TapController {
    struct Tap {
        let objectID: AudioObjectID
        let uid: String
        let channels: Int
        let processIDs: [AudioObjectID]
    }

    enum TapError: LocalizedError {
        case appNotRunning(String)
        var errorDescription: String? {
            switch self {
            case .appNotRunning(let b): return "\(b) is not producing audio yet."
            }
        }
    }

    func makeProcessTap(bundleID: String, muteOriginal: Bool) throws -> Tap {
        let procs = AudioSystem.processObjectIDs(bundleID: bundleID)
        // An empty process list would tap the whole system (and feed our own output back).
        guard !procs.isEmpty else { throw TapError.appNotRunning(bundleID) }
        let desc = CATapDescription(__stereoMixdownOfProcesses: procs.map { NSNumber(value: $0) })
        desc.name = "Where Sound Meet \(bundleID)"
        return try create(desc, processIDs: procs, mute: muteOriginal)
    }

    func destroy(_ tap: Tap) {
        AudioHardwareDestroyProcessTap(tap.objectID)
    }

    private func create(_ desc: CATapDescription, processIDs: [AudioObjectID], mute: Bool) throws -> Tap {
        desc.isPrivate = true
        desc.muteBehavior = mute ? .mutedWhenTapped : .unmuted
        var id: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(desc, &id)
        guard status == noErr, id != kAudioObjectUnknown else { throw DriverError.coreAudio("Create tap", status) }
        guard let uid: String = AudioSystem.stringProperty(id, kAudioTapPropertyUID) else {
            AudioHardwareDestroyProcessTap(id)
            throw DriverError.coreAudio("Read tap UID", -1)
        }
        var channels = 2
        if let fmt: AudioStreamBasicDescription = AudioSystem.scalarProperty(id, kAudioTapPropertyFormat) {
            channels = Int(fmt.mChannelsPerFrame)
        }
        return Tap(objectID: id, uid: uid, channels: channels, processIDs: processIDs)
    }
}
