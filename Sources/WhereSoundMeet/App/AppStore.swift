import AppKit
import Foundation
import WhereSoundMeetCore
import Observation

@Observable
@MainActor
final class AppStore {
    private(set) var devices: [VirtualDevice] = []
    var selectedID: UUID?
    var showMonitors = true

    let engine: AudioEngine
    let system: AudioSystem
    private let pinner = DefaultDevicePinner()
    private let store: DeviceStore
    private var saveTask: Task<Void, Never>?
    private var quitObserver: NSObjectProtocol?

    init(store: DeviceStore = DeviceStore(url: DeviceStore.defaultURL)) {
        self.store = store
        self.engine = AudioEngine()
        self.system = AudioSystem()
        devices = Self.canonicalizeAppSources((try? store.load()) ?? [])
        selectedID = devices.first?.id
        system.onChange = { [weak self] in self?.engine.processesChanged() }
        system.onDevicesChange = { [weak self] in
            guard let self else { return }
            engine.hardwareChanged()
            pinner.apply(devices: devices)
        }
        system.onDefaultsChange = { [weak self] in self?.pinner.defaultsChanged() }
        engine.apply(devices)
        pinner.apply(devices: devices)
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pinner.releaseAll() }
        }
    }

    var selected: VirtualDevice? { devices.first { $0.id == selectedID } }

    func binding(for id: UUID) -> VirtualDevice? { devices.first { $0.id == id } }

    func mutate(_ id: UUID, _ f: (inout VirtualDevice) -> Void) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        f(&devices[i])
        commit()
    }

    func mutateSelected(_ f: (inout VirtualDevice) -> Void) {
        guard let id = selectedID else { return }
        mutate(id, f)
    }

    func addDevice() {
        let n = devices.count
        let d = VirtualDevice.makeDefault(name: n == 0 ? "Where Sound Meet Audio" : "Where Sound Meet Audio \(n + 1)")
        devices.append(d)
        selectedID = d.id
        commit()
    }

    func deleteSelected() {
        guard let id = selectedID, let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices.remove(at: i)
        selectedID = devices.indices.contains(i) ? devices[i].id : devices.last?.id
        commit()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        mutate(id) { $0.name = trimmed }
    }

    func setOn(_ id: UUID, _ on: Bool) { mutate(id) { $0.isOn = on } }

    /// Only one device can hold each default; turning it on for one clears it on the others.
    func setDefaultOutput(_ id: UUID, _ on: Bool) {
        for i in devices.indices { devices[i].isDefaultOutput = on && devices[i].id == id }
        commit()
    }

    func setDefaultInput(_ id: UUID, _ on: Bool) {
        for i in devices.indices { devices[i].isDefaultInput = on && devices[i].id == id }
        commit()
    }

    /// Display name for a device UID, including our own virtual devices (hidden from the system lists).
    func deviceName(uid: String?) -> String {
        guard let uid else { return "none" }
        if let d = devices.first(where: { $0.driverUID == uid }) { return d.name }
        if let d = (system.outputDevices + system.inputDevices).first(where: { $0.uid == uid }) { return d.name }
        return AudioSystem.allDevices().first { $0.uid == uid }?.name ?? uid
    }
    func setVolume(_ id: UUID, _ v: Float) { mutate(id) { $0.volume = v } }

    func retryDriver() { engine.apply(devices) }

    var installMessage: String?

    func installDriver() {
        do {
            try DriverClient.installDriver()
            installMessage = "Driver installed. Reconnecting…"
            Task {
                try? await Task.sleep(for: .seconds(2))
                engine.hardwareChanged()
                installMessage = nil
            }
        } catch {
            installMessage = error.localizedDescription
        }
    }

    /// Sources saved with a helper process id (WebKit GPU, Chrome Helper) are renamed to their owning app.
    private static func canonicalizeAppSources(_ devices: [VirtualDevice]) -> [VirtualDevice] {
        devices.map { d in
            var d = d
            for i in d.sources.indices {
                if case .app(let b, _) = d.sources[i].kind, let c = AudioSystem.canonicalApp(bundleID: b) {
                    d.sources[i].kind = .app(bundleID: c.bundleID, name: c.name)
                }
            }
            return d
        }
    }

    private func commit() {
        engine.apply(devices)
        pinner.apply(devices: devices)
        saveTask?.cancel()
        let snapshot = devices
        saveTask = Task { [store] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            try? store.save(snapshot)
        }
    }
}
