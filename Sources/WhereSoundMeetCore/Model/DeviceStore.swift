import Foundation

public final class DeviceStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Where Sound Meet/devices.json")
    }

    /// Config written by builds that were still named "Loopback".
    public static var legacyURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loopback/devices.json")
    }

    public func load() throws -> [VirtualDevice] {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path), url == Self.defaultURL, fm.fileExists(atPath: Self.legacyURL.path) {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: Self.legacyURL, to: url)
        }
        guard fm.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VirtualDevice].self, from: Data(contentsOf: url))
    }

    public func save(_ devices: [VirtualDevice]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(devices).write(to: url, options: .atomic)
    }
}
