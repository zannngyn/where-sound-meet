import Foundation

public struct Endpoint: Codable, Hashable {
    public var nodeID: UUID
    public var channel: Int
    public init(nodeID: UUID, channel: Int) { self.nodeID = nodeID; self.channel = channel }
}

public struct Wire: Codable, Hashable {
    public var from: Endpoint
    public var to: Endpoint
    public init(from: Endpoint, to: Endpoint) { self.from = from; self.to = to }
}

public enum SourceKind: Codable, Hashable {
    case app(bundleID: String, name: String)
    case inputDevice(uid: String, name: String)
    case passThru

    public var displayName: String {
        switch self {
        case .app(_, let n), .inputDevice(_, let n): return n
        case .passThru: return "Pass-Thru"
        }
    }
}

public struct Source: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var kind: SourceKind
    public var isOn = true
    public var volume: Float = 1
    public var channelCount = 2
    public var effects = EffectSettings()
    /// App sources only: silence the app's normal output while it is captured, so it is heard only via monitors.
    /// Off by default: muting a voice-chat app (Discord) while tapping it starved its playout IO context.
    public var muteOriginal = false
    /// Extra delay (ms) on the path into the output channels only; direct wires to monitors stay undelayed.
    /// Lets a singer's mic line up with music they hear late through Bluetooth headphones.
    public var delayMs: Float = 0
    public static let maxDelayMs: Float = 500
    public init(kind: SourceKind) { self.kind = kind }

    enum CodingKeys: String, CodingKey { case id, kind, isOn, volume, channelCount, effects, muteOriginal, delayMs }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        channelCount = try c.decodeIfPresent(Int.self, forKey: .channelCount) ?? 2
        effects = try c.decodeIfPresent(EffectSettings.self, forKey: .effects) ?? EffectSettings()
        muteOriginal = try c.decodeIfPresent(Bool.self, forKey: .muteOriginal) ?? false
        delayMs = try c.decodeIfPresent(Float.self, forKey: .delayMs) ?? 0
    }
}

public struct OutputChannel: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var index: Int
    public init(index: Int) { self.index = index }
    public var label: String { "Channel \(index + 1) (\(index % 2 == 0 ? "L" : "R"))" }
}

public struct Monitor: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var deviceUID: String
    public var name: String
    public var isOn = true
    public var volume: Float = 1
    public init(deviceUID: String, name: String) { self.deviceUID = deviceUID; self.name = name }
}

public struct VirtualDevice: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name: String
    public var isOn = true
    public var volume: Float = 1
    public var sources: [Source] = []
    public var outputChannels: [OutputChannel] = []
    public var monitors: [Monitor] = []
    public var wires: Set<Wire> = []
    /// Keep this device as the system default output / input while it is on (apps that cannot pick a device follow it).
    public var isDefaultOutput = false
    public var isDefaultInput = false

    public init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey { case id, name, isOn, volume, sources, outputChannels, monitors, wires, isDefaultOutput, isDefaultInput }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? true
        volume = try c.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        sources = try c.decodeIfPresent([Source].self, forKey: .sources) ?? []
        outputChannels = try c.decodeIfPresent([OutputChannel].self, forKey: .outputChannels) ?? []
        monitors = try c.decodeIfPresent([Monitor].self, forKey: .monitors) ?? []
        wires = try c.decodeIfPresent(Set<Wire>.self, forKey: .wires) ?? []
        isDefaultOutput = try c.decodeIfPresent(Bool.self, forKey: .isDefaultOutput) ?? false
        isDefaultInput = try c.decodeIfPresent(Bool.self, forKey: .isDefaultInput) ?? false
    }

    public static func makeDefault(name: String = "Where Sound Meet Audio") -> VirtualDevice {
        var d = VirtualDevice(name: name)
        d.addOutputChannelPair()
        d.addSource(.passThru)
        return d
    }

    public var driverUID: String { DriverProtocol.deviceUID(for: id) }
    public var passThruUID: String { DriverProtocol.passThruUID(for: id) }

    public var sourcesSummary: String {
        var apps = 0, devices = 0, pass = false
        for s in sources {
            switch s.kind {
            case .app: apps += 1
            case .inputDevice: devices += 1
            case .passThru: pass = true
            }
        }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) App\(apps == 1 ? "" : "s")") }
        if devices > 0 { parts.append("\(devices) Device\(devices == 1 ? "" : "s")") }
        if pass { parts.append("Pass-Thru") }
        return parts.isEmpty ? "No sources" : parts.joined(separator: ", ")
    }

    public var hasPassThru: Bool { sources.contains { $0.kind == .passThru } }

    @discardableResult
    public mutating func addSource(_ kind: SourceKind) -> Source {
        let s = Source(kind: kind)
        sources.append(s)
        for ch in 0..<min(s.channelCount, outputChannels.count) {
            wires.insert(Wire(from: Endpoint(nodeID: s.id, channel: ch),
                              to: Endpoint(nodeID: outputChannels[ch].id, channel: 0)))
        }
        return s
    }

    public mutating func addOutputChannelPair() {
        let base = outputChannels.count
        outputChannels.append(OutputChannel(index: base))
        outputChannels.append(OutputChannel(index: base + 1))
    }

    @discardableResult
    public mutating func addMonitor(deviceUID: String, name: String) -> Monitor {
        let m = Monitor(deviceUID: deviceUID, name: name)
        monitors.append(m)
        for ch in 0..<min(2, outputChannels.count) {
            wires.insert(Wire(from: Endpoint(nodeID: outputChannels[ch].id, channel: 0),
                              to: Endpoint(nodeID: m.id, channel: ch)))
        }
        return m
    }

    public mutating func remove(nodeID: UUID) {
        sources.removeAll { $0.id == nodeID }
        monitors.removeAll { $0.id == nodeID }
        if let i = outputChannels.firstIndex(where: { $0.id == nodeID }) {
            let start = i - (i % 2)
            let end = min(start + 2, outputChannels.count)
            let removed = Set(outputChannels[start..<end].map(\.id))
            outputChannels.removeSubrange(start..<end)
            for n in outputChannels.indices { outputChannels[n].index = n }
            wires = wires.filter { !removed.contains($0.from.nodeID) && !removed.contains($0.to.nodeID) }
        }
        wires = wires.filter { $0.from.nodeID != nodeID && $0.to.nodeID != nodeID }
    }

    public mutating func toggleWire(_ w: Wire) {
        guard isValid(w) else { return }
        if wires.contains(w) { wires.remove(w) } else { wires.insert(w) }
    }

    public func isValid(_ w: Wire) -> Bool {
        let fromIsSource = sources.contains { $0.id == w.from.nodeID }
        let fromIsChannel = outputChannels.contains { $0.id == w.from.nodeID }
        let toIsChannel = outputChannels.contains { $0.id == w.to.nodeID }
        let toIsMonitor = monitors.contains { $0.id == w.to.nodeID }
        return (fromIsSource && toIsChannel) || (fromIsChannel && toIsMonitor) || (fromIsSource && toIsMonitor)
    }
}
