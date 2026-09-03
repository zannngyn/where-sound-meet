import AppKit
import CoreAudio
import Foundation
import WhereSoundMeetCore
import Observation

struct AudioDeviceInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

/// One row per user-facing app. Helper processes (WebKit GPU, Chrome Helper…) are folded into their parent app.
struct AudioProcessInfo: Identifiable, Hashable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let isRunningOutput: Bool
    /// Bundle IDs of every audio process that belongs to this app (helpers included).
    let memberBundleIDs: [String]
}

/// Enumerates hardware devices and audio-producing processes; refreshes on HAL notifications.
@Observable
@MainActor
final class AudioSystem {
    private(set) var inputDevices: [AudioDeviceInfo] = []
    private(set) var outputDevices: [AudioDeviceInfo] = []
    private(set) var processes: [AudioProcessInfo] = []
    var onChange: (() -> Void)?
    var onDevicesChange: (() -> Void)?
    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private var lastDeviceUIDs: [String] = []

    init() {
        refresh()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
        listenerBlock = block
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyProcessObjectList] {
            var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main, block)
        }
    }

    func refresh() {
        let every = Self.allDevices()
        let all = every.filter {
            !$0.uid.hasPrefix(DriverProtocol.deviceUIDPrefix) && !$0.uid.hasPrefix(DriverProtocol.aggregateUIDPrefix)
        }
        let devicesChanged = Set(every.map(\.uid)) != Set(lastDeviceUIDs)
        lastDeviceUIDs = every.map(\.uid)
        inputDevices = all.filter { $0.inputChannels > 0 }
        outputDevices = all.filter { $0.outputChannels > 0 }
        if devicesChanged { onDevicesChange?() }
        let procs = Self.allProcesses()
        let changed = procs != processes
        processes = procs
        if changed { onChange?() }
    }

    // MARK: - Static helpers

    nonisolated static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var cf = uid as CFString
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &cf) { qual in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), qual, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    nonisolated static func defaultOutputDevice() -> AudioDeviceInfo? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return deviceInfo(id)
    }

    nonisolated static func allDevices() -> [AudioDeviceInfo] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices).compactMap(deviceInfo)
    }

    nonisolated static func deviceInfo(_ id: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid: String = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name: String = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioDeviceInfo(id: id, uid: uid, name: name,
                               inputChannels: channelCount(id, scope: kAudioObjectPropertyScopeInput),
                               outputChannels: channelCount(id, scope: kAudioObjectPropertyScopeOutput))
    }

    nonisolated static func channelCount(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    nonisolated static func allProcesses() -> [AudioProcessInfo] {
        let me = ProcessInfo.processInfo.processIdentifier
        struct Raw { let obj: AudioObjectID; let pid: pid_t; let bundleID: String; let running: Bool }
        var raws: [Raw] = []
        for obj in objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) {
            guard let pid: pid_t = scalarProperty(obj, kAudioProcessPropertyPID), pid != me,
                  let bundleID: String = stringProperty(obj, kAudioProcessPropertyBundleID), !bundleID.isEmpty else { continue }
            let running: UInt32 = scalarProperty(obj, kAudioProcessPropertyIsRunningOutput) ?? 0
            raws.append(Raw(obj: obj, pid: pid, bundleID: bundleID, running: running != 0))
        }
        // Group by the owning app (walk up the process tree until a regular app is found).
        var groups: [String: (app: NSRunningApplication?, name: String, members: [Raw])] = [:]
        for raw in raws {
            var owner = owningApp(of: raw.pid)
            if owner == nil, let direct = NSRunningApplication(processIdentifier: raw.pid), isUserFacing(direct) { owner = direct }
            let key = owner?.bundleIdentifier ?? raw.bundleID
            let name = owner?.localizedName ?? NSRunningApplication(processIdentifier: raw.pid)?.localizedName ?? raw.bundleID
            groups[key, default: (owner, name, [])].members.append(raw)
        }
        return groups.filter { $0.value.app != nil }.map { key, g in
            let running = g.members.contains { $0.running }
            let first = g.members.first!
            return AudioProcessInfo(id: first.obj, pid: g.app?.processIdentifier ?? first.pid, bundleID: key, name: g.name,
                                    isRunningOutput: running, memberBundleIDs: Array(Set(g.members.map(\.bundleID))).sorted())
        }
        .sorted { ($0.isRunningOutput ? 0 : 1, $0.name.lowercased()) < ($1.isRunningOutput ? 0 : 1, $1.name.lowercased()) }
    }

    /// Every audio process object that belongs to the app `bundleID`, including helper processes.
    nonisolated static func processObjectIDs(bundleID: String) -> [AudioObjectID] {
        objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList).filter { obj in
            guard let b: String = stringProperty(obj, kAudioProcessPropertyBundleID) else { return false }
            if b == bundleID { return true }
            guard let pid: pid_t = scalarProperty(obj, kAudioProcessPropertyPID) else { return false }
            return owningApp(of: pid)?.bundleIdentifier == bundleID
        }
    }

    /// The user-facing app that owns `pid`: first the process macOS holds responsible for it
    /// (covers XPC helpers such as WebKit's GPU process), then the parent-pid chain.
    nonisolated static func owningApp(of pid: pid_t) -> NSRunningApplication? {
        if let r = responsiblePID(of: pid), r != pid, r > 1,
           let app = NSRunningApplication(processIdentifier: r), isUserFacing(app) { return app }
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current), isUserFacing(app), !isHelperBundle(app) { return app }
            guard let parent = parentPID(of: current), parent > 1 else { return nil }
            current = parent
        }
        return nil
    }

    nonisolated static func isUserFacing(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier != nil && app.bundleURL != nil && app.activationPolicy != .prohibited
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    nonisolated private static let responsibleFn: ResponsibleFn? = {
        guard let h = dlopen("/usr/lib/system/libquarantine.dylib", RTLD_NOW),
              let sym = dlsym(h, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    nonisolated static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let r = fn(pid)
        return r > 0 ? r : nil
    }

    /// Resolves a helper bundle id (e.g. com.apple.WebKit.GPU) to the owning app's bundle id and name.
    nonisolated static func canonicalApp(bundleID: String) -> (bundleID: String, name: String)? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
              isHelperBundle(app), let owner = owningApp(of: app.processIdentifier),
              let id = owner.bundleIdentifier, let name = owner.localizedName else { return nil }
        return (id, name)
    }

    nonisolated static func isHelperBundle(_ app: NSRunningApplication) -> Bool {
        guard let id = app.bundleIdentifier?.lowercased() else { return true }
        return id.contains(".helper") || id.contains("webkit") || id.hasSuffix(".gpu") || id.contains(".renderer")
            || id.contains(".plugin") || id.contains("xpc")
    }

    nonisolated static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    nonisolated static func processObjectID(pid: pid_t) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pidValue = pid
        var id: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pidValue) { qual in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<pid_t>.size), qual, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    nonisolated static func appIcon(bundleID: String) -> NSImage? {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            if isHelperBundle(app), let owner = owningApp(of: app.processIdentifier), let icon = owner.icon { return icon }
            if let icon = app.icon { return icon }
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return nil
    }

    // MARK: - Property primitives

    nonisolated static func objectList(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(obj, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    nonisolated static func stringProperty(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr, let v = value else { return nil }
        return v.takeRetainedValue() as String
    }

    nonisolated static func scalarProperty<T>(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, ptr) == noErr else { return nil }
        return ptr.pointee
    }
}
