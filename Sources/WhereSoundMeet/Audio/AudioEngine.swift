import CoreAudio
import Foundation
import WhereSoundMeetCore
import Observation
import os

/// Keeps the driver's device list and one DeviceGraph per running VirtualDevice in sync with the model.
@Observable
@MainActor
final class AudioEngine {
    /// device id -> node id -> per-channel level
    private(set) var levels: [UUID: [UUID: [Float]]] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var driverError: String?
    private(set) var driverReady = false

    private var graphs: [UUID: DeviceGraph] = [:]
    private let taps = TapController()
    private var timer: Timer?
    private var pendingDevices: [VirtualDevice] = []
    private var syncTask: Task<Void, Never>?
    private var lastPushed: [String] = []
    private static let log = Logger(subsystem: DriverProtocol.appBundleID, category: "engine")

    init() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollMeters() }
        }
    }

    func apply(_ devices: [VirtualDevice]) {
        pendingDevices = devices
        guard DriverClient.isInstalled else {
            driverReady = false
            driverError = "Driver not installed"
            stopAll()
            return
        }
        let list = devices.map { (uid: $0.driverUID, name: $0.name) }
        let key = list.map { "\($0.uid)=\($0.name)" }
        do {
            if key != lastPushed || !driverReady {
                try DriverClient.push(devices: list)
                lastPushed = key
            }
            driverReady = true
            driverError = nil
        } catch {
            driverReady = false
            driverError = error.localizedDescription
            stopAll()
            return
        }
        syncTask?.cancel()
        syncTask = Task { await syncGraphs() }
    }

    /// HAL device list changed (e.g. coreaudiod restarted): push again and rebuild graphs.
    func hardwareChanged() {
        lastPushed = []
        apply(pendingDevices)
    }

    /// Re-targets app taps after the process list changed.
    func processesChanged() {
        for (id, g) in graphs {
            if let d = pendingDevices.first(where: { $0.id == id }) { try? g.update(d) }
        }
    }

    private func syncGraphs() async {
        let devices = pendingDevices
        let wanted = Set(devices.filter(\.isOn).map(\.id))
        for id in graphs.keys where !wanted.contains(id) {
            graphs[id]?.stop()
            graphs[id] = nil
            levels[id] = nil
        }
        for d in devices where d.isOn {
            if Task.isCancelled { return }
            guard await waitForDevice(uid: d.driverUID) else {
                errors[d.id] = "Virtual device did not appear"
                continue
            }
            do {
                try DriverClient.setOwnerPID(deviceUID: d.driverUID, pid: ProcessInfo.processInfo.processIdentifier)
                if let g = graphs[d.id] {
                    try g.update(d)
                } else {
                    graphs[d.id] = try DeviceGraph(device: d, taps: taps)
                }
                errors[d.id] = nil
            } catch {
                Self.log.error("graph error for \(d.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                errors[d.id] = error.localizedDescription
                graphs[d.id]?.stop()
                graphs[d.id] = nil
            }
        }
    }

    private func waitForDevice(uid: String) async -> Bool {
        for _ in 0..<30 {
            if AudioSystem.deviceID(forUID: uid) != nil { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return false
    }

    private func stopAll() {
        for g in graphs.values { g.stop() }
        graphs = [:]
        levels = [:]
    }

    private func pollMeters() {
        guard !graphs.isEmpty else { return }
        var next: [UUID: [UUID: [Float]]] = [:]
        for (id, g) in graphs { next[id] = g.nodeLevels() }
        levels = next
    }
}
