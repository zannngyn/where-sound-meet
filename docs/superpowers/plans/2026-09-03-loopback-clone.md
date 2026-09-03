# Loopback Clone Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** macOS app tái hiện Loopback: thiết bị audio ảo (HAL plugin C), gom audio app / micro / Pass-Thru, nối kênh bằng dây kéo chuột, monitor ra loa, lưu cấu hình.

**Architecture:** SwiftPM package (`WhereSoundMeetCore` lib thuần logic + `Loopback` executable SwiftUI, đóng gói thành `.app` bằng script) và một HAL AudioServerPlugIn viết bằng C build bằng `clang` + Makefile thành `WhereSoundMeetDriver.driver`. App tạo 1 aggregate device cho mỗi virtual device đang On, mix trong 1 IOProc, ghi ra output stream của device ảo và các monitor. Plugin loop output của app vào input của device ảo; Pass-Thru bắt bằng global tap giới hạn `deviceUID`.

**Tech Stack:** Swift 6.2 (language mode 5), SwiftUI, CoreAudio (AudioHardware, AudioServerPlugIn, CATapDescription), C11, XCTest, bash.

**Spec:** `docs/superpowers/specs/2026-09-03-loopback-clone-design.md`

## Global Constraints

- macOS 14.0+ (`LSMinimumSystemVersion` 14.0), build trên macOS 26.6 / Xcode 26.3.
- Không thêm dependency ngoài (không SwiftPM package bên thứ ba, không Homebrew).
- Code, comment, log, commit message: tiếng Anh. Không comment dài.
- Bundle ID app `com.zan.wheresoundmeet`, driver `com.zan.wheresoundmeet.driver`. Tên hiển thị "Loopback".
- Sample rate cố định 48000, Float32, 2 kênh cho mọi device ảo. Tối đa 8 device ảo (`kMaxDevices = 8`).
- Không copy code BlackHole (GPL-3). Viết mới.
- Không `pkill -f`; script chạy nền phải lưu PID. Không giết tiến trình giữ port.
- Không commit trừ khi được bảo. Thư mục chưa là git repo — không `git init` tự ý.
- Màu: teal `#3DBEB0`, đỏ `#E5484D`, nền `#ECECEC`, card trắng bo 8.

---

## Cấu trúc file

```
Package.swift
Sources/WhereSoundMeetCore/
  Model/VirtualDevice.swift       # VirtualDevice, Source, OutputChannel, Monitor, Wire, Endpoint
  Model/DeviceStore.swift         # load/save JSON, debounce
  Audio/MixKernel.swift           # RT-safe mix: MixPlan, MixState, mix(...)
  Audio/DriverProtocol.swift      # selector 'lbdv'/'lbpd', bundle IDs, dict keys
Sources/Loopback/
  App/WhereSoundMeetApp.swift           # @main, WindowGroup
  App/AppStore.swift              # @Observable, devices + selection, hooks engine
  App/Theme.swift                 # màu, kích thước
  Audio/AudioSystem.swift         # enumerate devices/processes, listeners
  Audio/DriverClient.swift        # push device list / owner pid to plugin
  Audio/TapController.swift       # create/destroy process taps
  Audio/DeviceGraph.swift         # aggregate device + IOProc cho 1 VirtualDevice
  Audio/AudioEngine.swift         # điều phối DeviceGraph theo store, meter publisher
  Audio/Permissions.swift         # mic + audio capture status, open System Settings
  UI/SidebarView.swift
  UI/DeviceEditorView.swift
  UI/Cards/SourceCard.swift  UI/Cards/ChannelCard.swift  UI/Cards/MonitorCard.swift
  UI/Cards/CardChrome.swift       # header/toggle/meter/port dùng chung
  UI/Wires/WireLayer.swift        # Canvas + drag
  UI/Wires/PortPreference.swift   # PreferenceKey vị trí port
  UI/AddMenus.swift               # menu "+" cho 3 cột
  UI/Banners.swift                # driver chưa cài / thiếu quyền
Tests/WhereSoundMeetCoreTests/
  VirtualDeviceTests.swift  DeviceStoreTests.swift  MixKernelTests.swift  DriverProtocolTests.swift
Driver/
  WhereSoundMeetDriver.c  WhereSoundMeetDriver.h  Info.plist  Makefile
Resources/
  Info.plist                      # cho app bundle
  Loopback.entitlements           # rỗng (không sandbox), giữ chỗ
Scripts/
  build-app.sh   install-driver.sh   run.sh
```

---

### Task 1: Scaffold SwiftPM + app bundle script

**Files:**
- Create: `Package.swift`, `Sources/WhereSoundMeetCore/Audio/DriverProtocol.swift`, `Sources/Loopback/App/WhereSoundMeetApp.swift`, `Sources/Loopback/App/Theme.swift`, `Resources/Info.plist`, `Scripts/build-app.sh`, `Scripts/run.sh`, `Tests/WhereSoundMeetCoreTests/DriverProtocolTests.swift`

**Interfaces:**
- Produces: `WhereSoundMeetCore.DriverProtocol` (enum với hằng số), `Theme` (màu/size), script tạo `build/WhereSoundMeet.app`.

- [ ] **Step 1: Package.swift**

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loopback",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WhereSoundMeetCore", path: "Sources/WhereSoundMeetCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "Loopback", dependencies: ["WhereSoundMeetCore"], path: "Sources/Loopback",
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AppKit")]),
        .testTarget(name: "WhereSoundMeetCoreTests", dependencies: ["WhereSoundMeetCore"], path: "Tests/WhereSoundMeetCoreTests"),
    ]
)
```

- [ ] **Step 2: DriverProtocol.swift + test**

```swift
import Foundation

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

    public static func fourCC(_ s: String) -> UInt32 {
        precondition(s.utf8.count == 4)
        return s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    public static func deviceUID(for id: UUID) -> String { deviceUIDPrefix + id.uuidString }
}
```

Test `Tests/WhereSoundMeetCoreTests/DriverProtocolTests.swift`:

```swift
import XCTest
@testable import WhereSoundMeetCore

final class DriverProtocolTests: XCTestCase {
    func testFourCCMatchesCConstant() {
        XCTAssertEqual(DriverProtocol.fourCC("lbdv"), 0x6C626476) // 'lbdv'
        XCTAssertEqual(DriverProtocol.fourCC("lbpd"), 0x6C627064)
    }
    func testDeviceUIDPrefix() {
        let id = UUID()
        XCTAssertTrue(DriverProtocol.deviceUID(for: id).hasPrefix("com.zan.wheresoundmeet.device."))
        XCTAssertTrue(DriverProtocol.deviceUID(for: id).hasSuffix(id.uuidString))
    }
}
```

- [ ] **Step 3: App entry + Theme**

`Sources/Loopback/App/WhereSoundMeetApp.swift`:

```swift
import SwiftUI

@main
struct WhereSoundMeetApp: App {
    var body: some Scene {
        WindowGroup("Loopback") {
            Text("Loopback").frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
```

`Sources/Loopback/App/Theme.swift`:

```swift
import SwiftUI

enum Theme {
    static let teal = Color(red: 0x3D/255, green: 0xBE/255, blue: 0xB0/255)
    static let red = Color(red: 0xE5/255, green: 0x48/255, blue: 0x4D/255)
    static let canvas = Color(red: 0xEC/255, green: 0xEC/255, blue: 0xEC/255)
    static let sidebar = Color(red: 0xF5/255, green: 0xF5/255, blue: 0xF5/255)
    static let card = Color.white
    static let cardRadius: CGFloat = 8
    static let meterTrack = Color(white: 0.85)
    static let wireWidth: CGFloat = 2.5
    static let portDiameter: CGFloat = 10
    static let cardWidth: CGFloat = 340
    static let columnGap: CGFloat = 240
}
```

- [ ] **Step 4: Resources/Info.plist**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Loopback</string>
  <key>CFBundleDisplayName</key><string>Loopback</string>
  <key>CFBundleIdentifier</key><string>com.zan.wheresoundmeet</string>
  <key>CFBundleExecutable</key><string>Loopback</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Loopback captures audio from input devices you add as sources.</string>
  <key>NSAudioCaptureUsageDescription</key><string>Loopback captures audio from apps you add as sources.</string>
</dict></plist>
```

- [ ] **Step 5: Scripts/build-app.sh + run.sh**

```bash
#!/bin/bash
# Build the SwiftPM executable and wrap it into build/WhereSoundMeet.app
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/Loopback"
APP="$ROOT/build/WhereSoundMeet.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Loopback"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
codesign --force --sign - --identifier com.zan.wheresoundmeet "$APP"
echo "Built $APP"
```

`Scripts/run.sh`:

```bash
#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/Scripts/build-app.sh" debug
open "$ROOT/build/WhereSoundMeet.app"
```

- [ ] **Step 6: Verify**

Run: `chmod +x Scripts/*.sh && swift test && ./Scripts/build-app.sh && ls build/WhereSoundMeet.app/Contents/MacOS/Loopback`
Expected: tests pass (2), file tồn tại. `open build/WhereSoundMeet.app` hiện cửa sổ "Loopback".

---

### Task 2: Model + DeviceStore

**Files:**
- Create: `Sources/WhereSoundMeetCore/Model/VirtualDevice.swift`, `Sources/WhereSoundMeetCore/Model/DeviceStore.swift`
- Test: `Tests/WhereSoundMeetCoreTests/VirtualDeviceTests.swift`, `Tests/WhereSoundMeetCoreTests/DeviceStoreTests.swift`

**Interfaces:**
- Produces:

```swift
public struct Endpoint: Codable, Hashable { public var nodeID: UUID; public var channel: Int }  // channel 0-based
public struct Wire: Codable, Hashable { public var from: Endpoint; public var to: Endpoint }
public enum SourceKind: Codable, Hashable {
    case app(bundleID: String, name: String)
    case inputDevice(uid: String, name: String)
    case passThru
}
public struct Source: Codable, Identifiable, Hashable { id, kind, isOn, volume: Float, channelCount: Int }
public struct OutputChannel: Codable, Identifiable, Hashable { id, index: Int }  // 0-based
public struct Monitor: Codable, Identifiable, Hashable { id, deviceUID, name, isOn, volume: Float }
public struct VirtualDevice: Codable, Identifiable, Hashable {
    id, name, isOn, volume: Float, sources, outputChannels, monitors, wires
    public static func makeDefault(name: String = "Loopback Audio") -> VirtualDevice
    public var driverUID: String   // DriverProtocol.deviceUID(for: id)
    public var sourcesSummary: String  // "1 App, 1 Device, Pass-Thru"
    public mutating func addSource(_ kind: SourceKind) -> Source   // tự nối L→1, R→2 nếu rảnh
    public mutating func addOutputChannelPair()
    public mutating func addMonitor(deviceUID:name:) -> Monitor  // tự nối out ch → monitor ch
    public mutating func remove(nodeID: UUID)          // xoá node + wire liên quan
    public mutating func toggleWire(_ w: Wire)          // có thì xoá, chưa có thì thêm
    public func isValid(_ w: Wire) -> Bool  // from là source port / output channel, to là output channel / monitor
}
public final class DeviceStore { init(url: URL); func load() throws -> [VirtualDevice]; func save(_:) throws }
```

- [ ] **Step 1: Test VirtualDevice**

```swift
import XCTest
@testable import WhereSoundMeetCore

final class VirtualDeviceTests: XCTestCase {
    func testDefaultDeviceHasPassThruWiredToTwoChannels() {
        let d = VirtualDevice.makeDefault()
        XCTAssertEqual(d.name, "Loopback Audio")
        XCTAssertEqual(d.sources.count, 1)
        XCTAssertEqual(d.sources[0].kind, .passThru)
        XCTAssertEqual(d.outputChannels.map(\.index), [0, 1])
        let s = d.sources[0].id, c = d.outputChannels
        XCTAssertEqual(Set(d.wires), [
            Wire(from: Endpoint(nodeID: s, channel: 0), to: Endpoint(nodeID: c[0].id, channel: 0)),
            Wire(from: Endpoint(nodeID: s, channel: 1), to: Endpoint(nodeID: c[1].id, channel: 0)),
        ])
    }
    func testAddSourceAutoWires() {
        var d = VirtualDevice.makeDefault()
        let s = d.addSource(.app(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertTrue(d.wires.contains(Wire(from: Endpoint(nodeID: s.id, channel: 0),
                                            to: Endpoint(nodeID: d.outputChannels[0].id, channel: 0))))
        XCTAssertEqual(d.sourcesSummary, "1 App, Pass-Thru")
    }
    func testAddMonitorAutoWiresFromOutputChannels() {
        var d = VirtualDevice.makeDefault()
        let m = d.addMonitor(deviceUID: "BuiltInSpeakerDevice", name: "MacBook Air Speakers")
        XCTAssertTrue(d.wires.contains(Wire(from: Endpoint(nodeID: d.outputChannels[1].id, channel: 0),
                                            to: Endpoint(nodeID: m.id, channel: 1))))
    }
    func testRemoveNodeDropsWires() {
        var d = VirtualDevice.makeDefault()
        d.remove(nodeID: d.sources[0].id)
        XCTAssertTrue(d.sources.isEmpty); XCTAssertTrue(d.wires.isEmpty)
    }
    func testToggleWireAndValidation() {
        var d = VirtualDevice.makeDefault()
        let w = d.wires.first!
        d.toggleWire(w); XCTAssertFalse(d.wires.contains(w))
        d.toggleWire(w); XCTAssertTrue(d.wires.contains(w))
        let bad = Wire(from: Endpoint(nodeID: d.outputChannels[0].id, channel: 0),
                       to: Endpoint(nodeID: d.sources[0].id, channel: 0))
        XCTAssertFalse(d.isValid(bad))
    }
    func testCodableRoundTrip() throws {
        var d = VirtualDevice.makeDefault()
        _ = d.addSource(.inputDevice(uid: "mic", name: "Mic"))
        let data = try JSONEncoder().encode([d])
        XCTAssertEqual(try JSONDecoder().decode([VirtualDevice].self, from: data), [d])
    }
    func testSummaryCounts() {
        var d = VirtualDevice.makeDefault()
        _ = d.addSource(.app(bundleID: "a", name: "A")); _ = d.addSource(.app(bundleID: "b", name: "B"))
        _ = d.addSource(.inputDevice(uid: "m", name: "M"))
        XCTAssertEqual(d.sourcesSummary, "2 Apps, 1 Device, Pass-Thru")
    }
}
```

- [ ] **Step 2: Run test, expect compile failure.** `swift test --filter VirtualDeviceTests`

- [ ] **Step 3: Implement VirtualDevice.swift**

```swift
import Foundation

public struct Endpoint: Codable, Hashable { public var nodeID: UUID; public var channel: Int
    public init(nodeID: UUID, channel: Int) { self.nodeID = nodeID; self.channel = channel } }
public struct Wire: Codable, Hashable { public var from: Endpoint; public var to: Endpoint
    public init(from: Endpoint, to: Endpoint) { self.from = from; self.to = to } }

public enum SourceKind: Codable, Hashable {
    case app(bundleID: String, name: String)
    case inputDevice(uid: String, name: String)
    case passThru
    public var displayName: String {
        switch self { case .app(_, let n), .inputDevice(_, let n): return n; case .passThru: return "Pass-Thru" }
    }
}

public struct Source: Codable, Identifiable, Hashable {
    public var id = UUID(); public var kind: SourceKind; public var isOn = true
    public var volume: Float = 1; public var channelCount = 2
    public init(kind: SourceKind) { self.kind = kind }
}
public struct OutputChannel: Codable, Identifiable, Hashable {
    public var id = UUID(); public var index: Int
    public init(index: Int) { self.index = index }
    public var label: String { "Channel \(index + 1) (\(index % 2 == 0 ? "L" : "R"))" }
}
public struct Monitor: Codable, Identifiable, Hashable {
    public var id = UUID(); public var deviceUID: String; public var name: String
    public var isOn = true; public var volume: Float = 1
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

    public init(name: String) { self.name = name }

    public static func makeDefault(name: String = "Loopback Audio") -> VirtualDevice {
        var d = VirtualDevice(name: name)
        d.addOutputChannelPair()
        _ = d.addSource(.passThru)
        return d
    }

    public var driverUID: String { DriverProtocol.deviceUID(for: id) }

    public var sourcesSummary: String {
        var apps = 0, devices = 0, pass = false
        for s in sources { switch s.kind { case .app: apps += 1; case .inputDevice: devices += 1; case .passThru: pass = true } }
        var parts: [String] = []
        if apps > 0 { parts.append("\(apps) App\(apps == 1 ? "" : "s")") }
        if devices > 0 { parts.append("\(devices) Device\(devices == 1 ? "" : "s")") }
        if pass { parts.append("Pass-Thru") }
        return parts.isEmpty ? "No sources" : parts.joined(separator: ", ")
    }

    @discardableResult
    public mutating func addSource(_ kind: SourceKind) -> Source {
        let s = Source(kind: kind); sources.append(s)
        for ch in 0..<min(s.channelCount, outputChannels.count) {
            wires.insert(Wire(from: Endpoint(nodeID: s.id, channel: ch),
                              to: Endpoint(nodeID: outputChannels[ch].id, channel: 0)))
        }
        return s
    }
    public mutating func addOutputChannelPair() {
        let base = outputChannels.count
        outputChannels.append(OutputChannel(index: base)); outputChannels.append(OutputChannel(index: base + 1))
    }
    @discardableResult
    public mutating func addMonitor(deviceUID: String, name: String) -> Monitor {
        let m = Monitor(deviceUID: deviceUID, name: name); monitors.append(m)
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
            // channels come in pairs; drop the pair
            let pairStart = i - (i % 2)
            let removed = outputChannels[pairStart..<min(pairStart + 2, outputChannels.count)].map(\.id)
            outputChannels.removeSubrange(pairStart..<min(pairStart + 2, outputChannels.count))
            for (n, c) in outputChannels.enumerated() { outputChannels[n].index = n; _ = c }
            wires = wires.filter { !removed.contains($0.from.nodeID) && !removed.contains($0.to.nodeID) }
        }
        wires = wires.filter { $0.from.nodeID != nodeID && $0.to.nodeID != nodeID }
    }
    public mutating func toggleWire(_ w: Wire) {
        guard isValid(w) else { return }
        if wires.contains(w) { wires.remove(w) } else { wires.insert(w) }
    }
    public func isValid(_ w: Wire) -> Bool {
        let isSource = sources.contains { $0.id == w.from.nodeID }
        let fromIsChannel = outputChannels.contains { $0.id == w.from.nodeID }
        let toIsChannel = outputChannels.contains { $0.id == w.to.nodeID }
        let toIsMonitor = monitors.contains { $0.id == w.to.nodeID }
        return (isSource && toIsChannel) || (fromIsChannel && toIsMonitor)
    }
}
```

- [ ] **Step 4: Run test, expect pass.** `swift test --filter VirtualDeviceTests`

- [ ] **Step 5: DeviceStore test + implement**

Test:

```swift
import XCTest
@testable import WhereSoundMeetCore

final class DeviceStoreTests: XCTestCase {
    func testSaveThenLoad() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lb-\(UUID()).json")
        let store = DeviceStore(url: url)
        XCTAssertEqual(try store.load(), [])            // missing file → empty
        let d = VirtualDevice.makeDefault()
        try store.save([d])
        XCTAssertEqual(try store.load(), [d])
    }
}
```

Implement:

```swift
import Foundation

public final class DeviceStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Loopback/devices.json")
    }
    public func load() throws -> [VirtualDevice] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([VirtualDevice].self, from: Data(contentsOf: url))
    }
    public func save(_ devices: [VirtualDevice]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(devices).write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 6: Verify.** `swift test` → tất cả pass.

---

### Task 3: MixKernel (RT-safe)

**Files:**
- Create: `Sources/WhereSoundMeetCore/Audio/MixKernel.swift`
- Test: `Tests/WhereSoundMeetCoreTests/MixKernelTests.swift`

**Interfaces:**
- Produces:

```swift
/// Immutable routing plan built on the main thread from a VirtualDevice.
public struct MixPlan {
    public struct Input { public var offset: Int; public var channels: Int; public var gain: Float }  // vị trí trong input buffer aggregate (interleaved frame offset của stream), gain = sourceVolume * isOn
    public struct Output { public var offset: Int; public var channels: Int; public var gain: Float }
    public var inputs: [Input]; public var outputs: [Output]
    public var busCount: Int                          // số output channel của virtual device
    public var inputToBus: [(input: Int, inCh: Int, bus: Int)]   // dây source→channel
    public var busToOutput: [(bus: Int, output: Int, outCh: Int)] // dây channel→monitor + virtual out (bus i → virtual out ch i)
    public var masterGain: Float
}
public final class MixKernel {
    public init(maxFrames: Int, maxBuses: Int)
    public func install(_ plan: MixPlan)          // main thread, atomic swap
    /// RT: in = interleaved per-stream slices packed như AudioBufferList của aggregate; ghi out.
    public func process(inputs: [UnsafePointer<Float>], outputs: [UnsafeMutablePointer<Float>], frames: Int)
    public func meters() -> Meters  // copy atomic
}
public struct Meters { public var inputs: [[Float]]; public var buses: [Float]; public var outputs: [[Float]] }  // RMS per channel
```

Ghi chú: `process` nhận mảng pointer — mảng được cấp phát sẵn ở caller (DeviceGraph giữ buffer cố định), không cấp phát trong callback. Hoán đổi plan bằng `os_unfair_lock_trylock` phía RT (nếu lock đang bận, dùng plan cũ).

- [ ] **Step 1: Test**

```swift
import XCTest
@testable import WhereSoundMeetCore

final class MixKernelTests: XCTestCase {
    func makePlan() -> MixPlan {
        // 1 stereo input, 2 buses, outputs: virtual (2ch) + monitor (2ch)
        MixPlan(inputs: [.init(offset: 0, channels: 2, gain: 0.5)],
                outputs: [.init(offset: 0, channels: 2, gain: 1), .init(offset: 1, channels: 2, gain: 0.25)],
                busCount: 2,
                inputToBus: [(0, 0, 0), (0, 1, 1)],
                busToOutput: [(0, 0, 0), (1, 0, 1), (0, 1, 0), (1, 1, 1)],
                masterGain: 1)
    }
    func testRoutesAndAppliesGain() {
        let k = MixKernel(maxFrames: 4, maxBuses: 4)
        k.install(makePlan())
        var input: [Float] = [1, -1, 1, -1, 1, -1, 1, -1]   // L=1, R=-1 x4 frames
        var out0 = [Float](repeating: 9, count: 8), out1 = [Float](repeating: 9, count: 8)
        input.withUnsafeMutableBufferPointer { i in
            out0.withUnsafeMutableBufferPointer { o0 in out1.withUnsafeMutableBufferPointer { o1 in
                k.process(inputs: [UnsafePointer(i.baseAddress!)], outputs: [o0.baseAddress!, o1.baseAddress!], frames: 4)
            } }
        }
        XCTAssertEqual(out0, [0.5, -0.5, 0.5, -0.5, 0.5, -0.5, 0.5, -0.5])
        XCTAssertEqual(out1, [0.125, -0.125, 0.125, -0.125, 0.125, -0.125, 0.125, -0.125])
        let m = k.meters()
        XCTAssertEqual(m.inputs[0][0], 1, accuracy: 1e-5)      // meter đo trước gain
        XCTAssertEqual(m.buses[0], 0.5, accuracy: 1e-5)
        XCTAssertEqual(m.outputs[1][1], 0.125, accuracy: 1e-5)
    }
    func testNoWiresGivesSilence() {
        let k = MixKernel(maxFrames: 4, maxBuses: 2)
        var p = makePlan(); p.inputToBus = []; k.install(p)
        var input = [Float](repeating: 1, count: 8), out = [Float](repeating: 9, count: 8)
        input.withUnsafeMutableBufferPointer { i in out.withUnsafeMutableBufferPointer { o in
            k.process(inputs: [UnsafePointer(i.baseAddress!)], outputs: [o.baseAddress!, o.baseAddress!], frames: 4) } }
        XCTAssertEqual(out, [Float](repeating: 0, count: 8))
    }
}
```

- [ ] **Step 2: Run, expect fail.** `swift test --filter MixKernelTests`

- [ ] **Step 3: Implement**

```swift
import Foundation
import os

public struct MixPlan {
    public struct Input { public var offset: Int; public var channels: Int; public var gain: Float
        public init(offset: Int, channels: Int, gain: Float) { self.offset = offset; self.channels = channels; self.gain = gain } }
    public struct Output { public var offset: Int; public var channels: Int; public var gain: Float
        public init(offset: Int, channels: Int, gain: Float) { self.offset = offset; self.channels = channels; self.gain = gain } }
    public var inputs: [Input]
    public var outputs: [Output]
    public var busCount: Int
    public var inputToBus: [(input: Int, inCh: Int, bus: Int)]
    public var busToOutput: [(bus: Int, output: Int, outCh: Int)]
    public var masterGain: Float
    public init(inputs: [Input], outputs: [Output], busCount: Int,
                inputToBus: [(input: Int, inCh: Int, bus: Int)], busToOutput: [(bus: Int, output: Int, outCh: Int)],
                masterGain: Float) { self.inputs = inputs; self.outputs = outputs; self.busCount = busCount
        self.inputToBus = inputToBus; self.busToOutput = busToOutput; self.masterGain = masterGain }
    public static let empty = MixPlan(inputs: [], outputs: [], busCount: 0, inputToBus: [], busToOutput: [], masterGain: 1)
}

public struct Meters { public var inputs: [[Float]] = []; public var buses: [Float] = []; public var outputs: [[Float]] = [] }

public final class MixKernel {
    private var plan = MixPlan.empty
    private var pending: MixPlan?
    private let lock = OSAllocatedUnfairLock()
    private let bus: UnsafeMutablePointer<Float>     // busCount * maxFrames, planar
    private let maxFrames: Int, maxBuses: Int
    private var meterStore = Meters()
    private let meterLock = OSAllocatedUnfairLock()

    public init(maxFrames: Int, maxBuses: Int) {
        self.maxFrames = maxFrames; self.maxBuses = maxBuses
        bus = .allocate(capacity: maxFrames * maxBuses); bus.initialize(repeating: 0, count: maxFrames * maxBuses)
    }
    deinit { bus.deallocate() }

    public func install(_ p: MixPlan) {
        precondition(p.busCount <= maxBuses)
        lock.withLock { pending = p }
    }
    public func meters() -> Meters { meterLock.withLock { meterStore } }

    public func process(inputs: [UnsafePointer<Float>], outputs: [UnsafeMutablePointer<Float>], frames: Int) {
        if lock.lockIfAvailable() { if let p = pending { plan = p; pending = nil }; lock.unlock() }
        let p = plan
        let n = min(frames, maxFrames)
        var m = Meters(inputs: p.inputs.map { [Float](repeating: 0, count: $0.channels) },
                       buses: [Float](repeating: 0, count: p.busCount),
                       outputs: p.outputs.map { [Float](repeating: 0, count: $0.channels) })
        // NOTE: meter arrays above allocate; acceptable for v1 (small), tracked as follow-up.
        bus.update(repeating: 0, count: n * p.busCount)
        for (ii, inp) in p.inputs.enumerated() where ii < inputs.count {
            let src = inputs[ii]
            for ch in 0..<inp.channels { var acc: Float = 0
                for f in 0..<n { let v = src[f * inp.channels + ch]; acc += v * v }
                m.inputs[ii][ch] = (acc / Float(max(n, 1))).squareRoot() }
        }
        for w in p.inputToBus where w.input < inputs.count && w.bus < p.busCount {
            let inp = p.inputs[w.input]; let src = inputs[w.input]; let g = inp.gain
            let dst = bus + w.bus * n
            for f in 0..<n { dst[f] += src[f * inp.channels + w.inCh] * g }
        }
        for b in 0..<p.busCount { var acc: Float = 0; let s = bus + b * n
            for f in 0..<n { s[f] *= p.masterGain; acc += s[f] * s[f] }
            m.buses[b] = (acc / Float(max(n, 1))).squareRoot() }
        for (oi, o) in p.outputs.enumerated() where oi < outputs.count {
            outputs[oi].update(repeating: 0, count: n * o.channels)
        }
        for w in p.busToOutput where w.output < outputs.count && w.bus < p.busCount {
            let o = p.outputs[w.output]; let dst = outputs[w.output]; let s = bus + w.bus * n
            for f in 0..<n { dst[f * o.channels + w.outCh] += s[f] * o.gain }
        }
        for (oi, o) in p.outputs.enumerated() where oi < outputs.count {
            for ch in 0..<o.channels { var acc: Float = 0
                for f in 0..<n { let v = outputs[oi][f * o.channels + ch]; acc += v * v }
                m.outputs[oi][ch] = (acc / Float(max(n, 1))).squareRoot() }
        }
        if meterLock.lockIfAvailable() { meterStore = m; meterLock.unlock() }
    }
}
```

- [ ] **Step 4: Run tests, expect pass.** `swift test`

---

### Task 4: HAL plugin `WhereSoundMeetDriver.driver` (C)

**Files:**
- Create: `Driver/WhereSoundMeetDriver.c`, `Driver/WhereSoundMeetDriver.h`, `Driver/Info.plist`, `Driver/Makefile`, `Scripts/install-driver.sh`

**Interfaces:**
- Consumes: hằng số trong `DriverProtocol.swift` (phải khớp byte: `'lbdv'`, `'lbpd'`, key `uid`/`name`, prefix UID).
- Produces: bundle `build/WhereSoundMeetDriver.driver`; sau khi cài, plugin object (bundle `com.zan.wheresoundmeet.driver`) nhận:
  - `SetPropertyData(plugin, 'lbdv', CFArray<CFDictionary{uid,name}>)` → cập nhật danh sách device (tối đa 8), thông báo `kAudioPlugInPropertyDeviceList`, lưu vào host storage key `"devices"`.
  - `GetPropertyData(plugin, 'lbdv')` → CFArray hiện tại.
  - `SetPropertyData(device, 'lbpd', CFNumber pid)` → owner pid; 0 = loop mọi client.

- [ ] **Step 1: Header + Info.plist + Makefile**

`Driver/WhereSoundMeetDriver.h`:

```c
#pragma once
#include <CoreAudio/AudioServerPlugIn.h>

#define kLB_MaxDevices        8
#define kLB_Channels          2
#define kLB_SampleRate        48000.0
#define kLB_RingFrames        16384          /* 341 ms at 48 kHz, power of two */
#define kLB_ZeroTSPeriod      4096
#define kLB_SafetyOffset      96
#define kLB_Latency           0
#define kLB_BundleID          "com.zan.wheresoundmeet.driver"
#define kLB_Manufacturer      "Zan"
#define kLB_UIDPrefix         "com.zan.wheresoundmeet.device."
#define kLB_StorageKey        CFSTR("devices")

#define kLB_Selector_DeviceList   'lbdv'
#define kLB_Selector_OwnerPID     'lbpd'
#define kLB_Key_UID   CFSTR("uid")
#define kLB_Key_Name  CFSTR("name")

/* Object ID layout: plug-in = kAudioObjectPlugInObject (1); slot i uses 4 IDs from 2 + 4*i */
enum { kLB_FirstDeviceID = 2, kLB_IDsPerSlot = 4 };
#define LB_DeviceID(slot)    (kLB_FirstDeviceID + (slot) * kLB_IDsPerSlot)
#define LB_InStreamID(slot)  (LB_DeviceID(slot) + 1)
#define LB_OutStreamID(slot) (LB_DeviceID(slot) + 2)
#define LB_SlotForID(id)     (((id) - kLB_FirstDeviceID) / kLB_IDsPerSlot)
#define LB_IsDeviceID(id)    ((id) >= kLB_FirstDeviceID && (id) < kLB_FirstDeviceID + kLB_MaxDevices * kLB_IDsPerSlot && (((id) - kLB_FirstDeviceID) % kLB_IDsPerSlot) == 0)
#define LB_IsInStream(id)    ((id) >= kLB_FirstDeviceID && (id) < kLB_FirstDeviceID + kLB_MaxDevices * kLB_IDsPerSlot && (((id) - kLB_FirstDeviceID) % kLB_IDsPerSlot) == 1)
#define LB_IsOutStream(id)   ((id) >= kLB_FirstDeviceID && (id) < kLB_FirstDeviceID + kLB_MaxDevices * kLB_IDsPerSlot && (((id) - kLB_FirstDeviceID) % kLB_IDsPerSlot) == 2)

typedef struct {
    bool        active;
    CFStringRef uid;
    CFStringRef name;
    pid_t       ownerPID;
    UInt32      ioCount;             /* StartIO refcount */
    UInt64      anchorHostTime;
    UInt64      periodCounter;
    Float64     hostTicksPerFrame;
    Float32    *ring;                /* kLB_RingFrames * kLB_Channels, interleaved */
    pthread_mutex_t ioMutex;
} LBDevice;
```

`Driver/Info.plist` (UUID factory tự sinh bằng `uuidgen`, ghi cố định vào file):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>WhereSoundMeetDriver</string>
  <key>CFBundleIdentifier</key><string>com.zan.wheresoundmeet.driver</string>
  <key>CFBundleExecutable</key><string>WhereSoundMeetDriver</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>CFPlugInFactories</key><dict>
    <key>FACTORY-UUID</key><string>WhereSoundMeetDriver_Create</string>
  </dict>
  <key>CFPlugInTypes</key><dict>
    <key>443ABAB8-E7B3-491A-B985-BEB9187030DB</key><array><string>FACTORY-UUID</string></array>
  </dict>
</dict></plist>
```

`Driver/Makefile`:

```make
SDK := $(shell xcrun --show-sdk-path)
OUT := ../build/WhereSoundMeetDriver.driver
CFLAGS := -std=c11 -O2 -Wall -Wextra -fPIC -mmacosx-version-min=14.0 -isysroot $(SDK) -arch arm64 -arch x86_64
LDFLAGS := -bundle -framework CoreAudio -framework CoreFoundation -lpthread

all: $(OUT)/Contents/MacOS/WhereSoundMeetDriver

$(OUT)/Contents/MacOS/WhereSoundMeetDriver: WhereSoundMeetDriver.c WhereSoundMeetDriver.h Info.plist
	mkdir -p $(OUT)/Contents/MacOS
	clang $(CFLAGS) $(LDFLAGS) -o $@ WhereSoundMeetDriver.c
	cp Info.plist $(OUT)/Contents/Info.plist
	codesign --force --sign - --identifier com.zan.wheresoundmeet.driver $(OUT)

clean:
	rm -rf $(OUT)
```

- [ ] **Step 2: `WhereSoundMeetDriver.c` — khung CFPlugIn + Initialize/Storage**

Cấu trúc file, theo thứ tự:

```c
#include "WhereSoundMeetDriver.h"
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <string.h>
#include <os/log.h>

static AudioServerPlugInHostRef gHost = NULL;
static LBDevice gDevices[kLB_MaxDevices];
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static ULONG gRefCount = 0;
static os_log_t gLog;

/* forward decls of every interface method */
static HRESULT LB_QueryInterface(void*, REFIID, LPVOID*);
static ULONG   LB_AddRef(void*);   static ULONG LB_Release(void*);
static OSStatus LB_Initialize(AudioServerPlugInDriverRef, AudioServerPlugInHostRef);
static OSStatus LB_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus LB_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus LB_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LB_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus LB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus LB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean  LB_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus LB_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus LB_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus LB_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus LB_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus LB_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LB_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus LB_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus LB_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus LB_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus LB_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus LB_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, LB_QueryInterface, LB_AddRef, LB_Release, LB_Initialize, LB_CreateDevice, LB_DestroyDevice,
    LB_AddDeviceClient, LB_RemoveDeviceClient, LB_PerformDeviceConfigurationChange, LB_AbortDeviceConfigurationChange,
    LB_HasProperty, LB_IsPropertySettable, LB_GetPropertyDataSize, LB_GetPropertyData, LB_SetPropertyData,
    LB_StartIO, LB_StopIO, LB_GetZeroTimeStamp, LB_WillDoIOOperation, LB_BeginIOOperation, LB_DoIOOperation, LB_EndIOOperation
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

void* WhereSoundMeetDriver_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    (void)allocator;
    if (CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}
static HRESULT LB_QueryInterface(void* driver, REFIID iid, LPVOID* out) {
    (void)driver;
    CFUUIDRef uuid = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean ok = CFEqual(uuid, IUnknownUUID) || CFEqual(uuid, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(uuid);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    ++gRefCount; *out = gDriverRef; return S_OK;
}
static ULONG LB_AddRef(void* d) { (void)d; return ++gRefCount; }
static ULONG LB_Release(void* d) { (void)d; return gRefCount > 0 ? --gRefCount : 0; }
```

Initialize: tạo `gLog = os_log_create(kLB_BundleID, "driver")`, init mỗi slot (`ring` calloc, mutex, `hostTicksPerFrame` từ `mach_timebase_info`), gọi `LB_LoadFromStorage()` (host->CopyFromStorage key `"devices"` → CFArray → `LB_ApplyDeviceList(array, /*persist*/false)`), trả `0`.

`LB_ApplyDeviceList(CFArrayRef list, bool persist)`:
1. Lock `gStateMutex`.
2. Với mỗi slot active mà UID không có trong `list` → giải phóng uid/name, `active=false`.
3. Với mỗi phần tử trong list (tối đa 8) chưa có slot → chọn slot trống thấp nhất, gán uid/name (CFRetain), `active=true`, `ownerPID=0`.
4. Slot đã có mà name khác → cập nhật name, ghi nhận để báo `kAudioObjectPropertyName` của device đó.
5. Unlock. Nếu `persist`: `gHost->WriteToStorage(gHost, kLB_StorageKey, list)`.
6. Gọi `gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 1, &{kAudioPlugInPropertyDeviceList, Global, Main})` và cho từng device đổi tên `PropertiesChanged(deviceID, kAudioObjectPropertyName)`.

`LB_CopyDeviceList()` → CFArray mới của dict `{uid, name}` cho slot active (caller release).

CreateDevice/DestroyDevice → trả `kAudioHardwareUnsupportedOperationError`. AddDeviceClient/RemoveDeviceClient → `0`. Perform/AbortDeviceConfigurationChange → `0`.

- [ ] **Step 3: Property handling**

Bảng property phải trả lời (mọi thứ khác → `kAudioHardwareUnknownPropertyError`):

| Object | Selector | Giá trị |
|---|---|---|
| plug-in | `kAudioObjectPropertyBaseClass` | `kAudioObjectClassID` |
| plug-in | `kAudioObjectPropertyClass` | `kAudioPlugInClassID` |
| plug-in | `kAudioObjectPropertyOwner` | `kAudioObjectUnknown` |
| plug-in | `kAudioObjectPropertyManufacturer` | CFSTR("Zan") |
| plug-in | `kAudioObjectPropertyOwnedObjects` / `kAudioPlugInPropertyDeviceList` | CFArray/AudioObjectID[] của device active |
| plug-in | `kAudioPlugInPropertyTranslateUIDToDevice` | qualifier CFString UID → device ID hoặc `kAudioObjectUnknown` |
| plug-in | `kAudioPlugInPropertyResourceBundle` | CFSTR("") |
| plug-in | `kAudioObjectPropertyCustomPropertyInfoList` | 1 phần tử `{ 'lbdv', plst, None }` |
| plug-in | `'lbdv'` | get: CFArray; **settable**; set: `LB_ApplyDeviceList(value, true)` |
| device | Base/Class/Owner | `kAudioObjectClassID` / `kAudioDeviceClassID` / `kAudioObjectPlugInObject` |
| device | `kAudioObjectPropertyName` | slot.name |
| device | `kAudioObjectPropertyManufacturer` | "Zan" |
| device | `kAudioObjectPropertyOwnedObjects`, `kAudioDevicePropertyStreams` | in stream + out stream (lọc theo scope) |
| device | `kAudioDevicePropertyDeviceUID` | slot.uid |
| device | `kAudioDevicePropertyModelUID` | CFSTR("com.zan.wheresoundmeet.model") |
| device | `kAudioDevicePropertyTransportType` | `kAudioDeviceTransportTypeVirtual` |
| device | `kAudioDevicePropertyRelatedDevices` | chính nó |
| device | `kAudioDevicePropertyClockDomain` | 0 |
| device | `kAudioDevicePropertyDeviceIsAlive` | 1 |
| device | `kAudioDevicePropertyDeviceIsRunning` | ioCount > 0 |
| device | `kAudioDevicePropertyDeviceCanBeDefaultDevice` / `DeviceCanBeDefaultSystemDevice` | 1 / 1 |
| device | `kAudioDevicePropertyLatency` | 0 |
| device | `kAudioDevicePropertySafetyOffset` | 96 |
| device | `kAudioDevicePropertyNominalSampleRate` | 48000 (settable nhưng chỉ chấp nhận 48000) |
| device | `kAudioDevicePropertyAvailableNominalSampleRates` | 1 range 48000..48000 |
| device | `kAudioDevicePropertyIsHidden` | 0 |
| device | `kAudioDevicePropertyPreferredChannelsForStereo` | {1, 2} |
| device | `kAudioDevicePropertyPreferredChannelLayout` | AudioChannelLayout tag `kAudioChannelLayoutTag_Stereo` |
| device | `kAudioDevicePropertyZeroTimeStampPeriod` | 4096 |
| device | `kAudioDevicePropertyIcon` | không cung cấp (bỏ) |
| device | `kAudioObjectPropertyCustomPropertyInfoList` | 1 phần tử `{ 'lbpd', plst, None }` |
| device | `'lbpd'` | get: CFNumber ownerPID; settable; set: đọc CFNumber → `ownerPID` |
| stream | Base/Class/Owner | `kAudioObjectClassID` / `kAudioStreamClassID` / device ID |
| stream | `kAudioStreamPropertyIsActive` | 1 |
| stream | `kAudioStreamPropertyDirection` | in stream = 1, out stream = 0 |
| stream | `kAudioStreamPropertyTerminalType` | in: `kAudioStreamTerminalTypeMicrophone`; out: `kAudioStreamTerminalTypeSpeaker` |
| stream | `kAudioStreamPropertyStartingChannel` | 1 |
| stream | `kAudioStreamPropertyLatency` | 0 |
| stream | `kAudioStreamPropertyVirtualFormat` / `PhysicalFormat` | 48000, `kAudioFormatLinearPCM`, flags `kAudioFormatFlagsNativeFloatPacked`, 8 bytes/frame, 2 ch, 32 bit |
| stream | `kAudioStreamPropertyAvailableVirtualFormats` / `AvailablePhysicalFormats` | 1 AudioStreamRangedDescription của format trên |

`HasProperty` = selector có trong bảng theo object. `IsPropertySettable` = true chỉ cho `'lbdv'`, `'lbpd'`, `NominalSampleRate`, `VirtualFormat`, `PhysicalFormat` (set format chỉ chấp nhận đúng format). `GetPropertyDataSize` trả kích thước đúng; `GetPropertyData` kiểm `inDataSize` đủ rồi ghi.

- [ ] **Step 4: IO**

```c
static OSStatus LB_StartIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    if (s->ioCount == 0) {
        s->anchorHostTime = mach_absolute_time(); s->periodCounter = 0;
        memset(s->ring, 0, sizeof(Float32) * kLB_RingFrames * kLB_Channels);
    }
    s->ioCount++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus LB_StopIO(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&gStateMutex);
    if (s->ioCount > 0) s->ioCount--;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}
static OSStatus LB_GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)d; (void)client;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    pthread_mutex_lock(&s->ioMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = s->hostTicksPerFrame * kLB_ZeroTSPeriod;
    UInt64 nextHost = s->anchorHostTime + (UInt64)((s->periodCounter + 1) * ticksPerPeriod);
    if (now >= nextHost) s->periodCounter++;
    *outSampleTime = (Float64)(s->periodCounter * kLB_ZeroTSPeriod);
    *outHostTime = s->anchorHostTime + (UInt64)(s->periodCounter * ticksPerPeriod);
    *outSeed = 1;
    pthread_mutex_unlock(&s->ioMutex);
    return 0;
}
static OSStatus LB_WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, UInt32 client, UInt32 op,
                                     Boolean* willDo, Boolean* inPlace) {
    (void)d; (void)dev; (void)client;
    *willDo = (op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationProcessOutput ||
               op == kAudioServerPlugInIOOperationWriteMix);
    *inPlace = true;
    return 0;
}
static OSStatus LB_DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID dev, AudioObjectID stream, UInt32 client,
                                 UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle,
                                 void* mainBuf, void* secBuf) {
    (void)d; (void)stream; (void)secBuf;
    if (!LB_IsDeviceID(dev)) return kAudioHardwareBadObjectError;
    LBDevice* s = &gDevices[LB_SlotForID(dev)];
    Float32* buf = (Float32*)mainBuf;
    const UInt32 ringMask = kLB_RingFrames - 1;
    if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt64 start = (UInt64)cycle->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            Float32* src = s->ring + ((start + f) & ringMask) * kLB_Channels;
            buf[f * 2] = src[0]; buf[f * 2 + 1] = src[1];
            src[0] = 0; src[1] = 0;                 /* consume: prevents replay when writer stops */
        }
    } else if (op == kAudioServerPlugInIOOperationProcessOutput) {
        /* per-client hook: silence clients that are not the owner so the app can tap them via Pass-Thru */
        pid_t owner = s->ownerPID;
        if (owner != 0 && LB_ClientPID(s, client) != owner) memset(buf, 0, frames * kLB_Channels * sizeof(Float32));
    } else if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 start = (UInt64)cycle->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < frames; f++) {
            Float32* dst = s->ring + ((start + f) & ringMask) * kLB_Channels;
            dst[0] += buf[f * 2]; dst[1] += buf[f * 2 + 1];   /* add: many writers per cycle are already mixed, add keeps late writes */
        }
    }
    return 0;
}
```

`LB_ClientPID(slot, clientID)`: bảng nhỏ `{clientID, pid}` tối đa 64 entry/slot, điền trong `AddDeviceClient` (từ `inClientInfo->mClientID/mProcessID`), xoá trong `RemoveDeviceClient`. Thêm vào `LBDevice`: `struct { UInt32 id; pid_t pid; } clients[64]; UInt32 clientCount;`. Đọc trong IO không khoá (mảng nhỏ, ghi hiếm; chấp nhận race nhẹ).

Begin/EndIOOperation → `0`.

- [ ] **Step 5: `Scripts/install-driver.sh`**

```bash
#!/bin/bash
# Installs build/WhereSoundMeetDriver.driver into the system HAL folder. Requires sudo.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/WhereSoundMeetDriver.driver"
DST="/Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver"
[ -d "$SRC" ] || { echo "missing $SRC, run make -C Driver first" >&2; exit 1; }
sudo rm -rf "$DST"
sudo cp -R "$SRC" "$DST"
sudo chown -R root:wheel "$DST"
sudo killall coreaudiod
echo "Installed $DST"
```

- [ ] **Step 6: Verify (không cần app)**

Run: `make -C Driver && ls build/WhereSoundMeetDriver.driver/Contents/MacOS/WhereSoundMeetDriver`
Run: `./Scripts/install-driver.sh` (hỏi user trước vì cần sudo), rồi
`log show --last 1m --predicate 'process == "coreaudiod"' | grep -i "loopback\|crash" ` → không có lỗi.
Kiểm plugin load: `swift Scripts/probe.swift` (script tạm trong scratchpad) gọi `kAudioHardwarePropertyTranslateBundleIDToPlugIn` với `com.zan.wheresoundmeet.driver` → ID ≠ 0; set `'lbdv'` = `[{uid:"com.zan.wheresoundmeet.device.TEST", name:"LB Test"}]`; `system_profiler SPAudioDataType | grep "LB Test"` thấy device. Phát `afplay` vào device (`SwitchAudioSource` không có → dùng Audio MIDI Setup chọn output) rồi ghi bằng `sox`? Không có sox → dùng QuickTime New Audio Recording chọn "LB Test": meter QuickTime nhảy. Set list rỗng → device biến mất.

---

### Task 5: DriverClient + AudioSystem (app)

**Files:**
- Create: `Sources/Loopback/Audio/DriverClient.swift`, `Sources/Loopback/Audio/AudioSystem.swift`, `Sources/Loopback/Audio/Permissions.swift`

**Interfaces:**
- Produces:

```swift
enum DriverClient {
    static var isInstalled: Bool          // FileManager exists /Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver
    static func pluginObjectID() -> AudioObjectID?   // translate bundle id
    static func push(devices: [(uid: String, name: String)]) throws
    static func setOwnerPID(deviceUID: String, pid: pid_t) throws
    static func installDriver() throws           // osascript "do shell script ... with administrator privileges" chạy Scripts/install-driver.sh nội dung tương đương, bundle lấy từ Bundle.main.resourceURL/WhereSoundMeetDriver.driver
}
struct AudioDeviceInfo: Identifiable, Hashable { id: AudioObjectID; uid: String; name: String; inputChannels: Int; outputChannels: Int }
struct AudioProcessInfo: Identifiable, Hashable { id: AudioObjectID; pid: pid_t; bundleID: String; name: String; icon: NSImage?; isRunningOutput: Bool }
@Observable final class AudioSystem {
    var inputDevices: [AudioDeviceInfo]; var outputDevices: [AudioDeviceInfo]; var processes: [AudioProcessInfo]
    func refresh(); init() // cài listener kAudioHardwarePropertyDevices + ProcessObjectList
    static func deviceID(forUID: String) -> AudioObjectID?
    static func defaultOutputDevice() -> AudioDeviceInfo?
}
enum Permissions {
    static func microphoneStatus() -> AVAuthorizationStatus   // AVCaptureDevice.authorizationStatus(for: .audio)
    static func requestMicrophone() async -> Bool
    static func openAudioCaptureSettings()  // x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture
}
```

Ghi chú kỹ thuật:
- Custom property set: `AudioObjectSetPropertyData(pluginID, &addr('lbdv', Global, Main), 0, nil, UInt32(MemoryLayout<CFArray?>.size), &cfArray)` — dữ liệu là **con trỏ tới CFTypeRef** (host marshal plist).
- Process list: `kAudioHardwarePropertyProcessObjectList` → `[AudioObjectID]`; mỗi cái đọc `kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID` (CFString), `kAudioProcessPropertyIsRunningOutput`; tên + icon từ `NSRunningApplication(processIdentifier:)`. Lọc bỏ pid của chính app và process không có bundleID. Sắp xếp: đang phát trước, rồi theo tên.
- Device list: `kAudioHardwarePropertyDevices`; channel count qua `kAudioDevicePropertyStreamConfiguration` theo scope Input/Output. Lọc bỏ device có UID prefix `com.zan.wheresoundmeet.device.` khỏi cả 2 danh sách (không cho tự trỏ vào mình), lọc bỏ aggregate private của app.

- [ ] **Step 1: Viết 3 file theo interface trên.**
- [ ] **Step 2: Verify bằng `swift build` và một lệnh probe tạm:** thêm vào `WhereSoundMeetApp` (tạm) `Task { print(AudioSystem().outputDevices.map(\.name)); try DriverClient.push(devices: [(uid: "com.zan.wheresoundmeet.device.T1", name: "Loopback Audio")]) }`, chạy app, `system_profiler SPAudioDataType | grep "Loopback Audio"` thấy device. Gỡ code tạm sau khi xác nhận.

---

### Task 6: TapController + DeviceGraph + AudioEngine

**Files:**
- Create: `Sources/Loopback/Audio/TapController.swift`, `Sources/Loopback/Audio/DeviceGraph.swift`, `Sources/Loopback/Audio/AudioEngine.swift`

**Interfaces:**
- Consumes: `MixKernel`, `MixPlan`, `VirtualDevice`, `AudioSystem`, `DriverClient`.
- Produces:

```swift
final class TapController {
    struct Tap { let objectID: AudioObjectID; let uid: String; let channels: Int }
    func makeProcessTap(bundleID: String) throws -> Tap     // CATapDescription(stereoMixdownOfProcesses: [processObjectID]) , privateTap = true, muteBehavior = .unmuted
    func makePassThruTap(deviceUID: String) throws -> Tap   // CATapDescription(stereoGlobalTapButExcludingProcesses: [ownProcessObjectID]); deviceUID = ...; privateTap = true
    func destroy(_ t: Tap)
}
final class DeviceGraph {
    init(device: VirtualDevice, system: AudioSystem, taps: TapController) throws  // tạo taps, aggregate, IOProc, start
    func update(_ device: VirtualDevice)   // nếu tập input/monitor đổi → rebuild; else chỉ install MixPlan mới
    func meters() -> Meters
    func stop()
}
@Observable @MainActor final class AudioEngine {
    var meters: [UUID: Meters]        // theo VirtualDevice.id, cập nhật 30 Hz
    var errors: [UUID: String]
    func apply(_ devices: [VirtualDevice])  // sync: push list xuống driver, set owner pid, tạo/huỷ/cập nhật DeviceGraph cho device On
}
```

Aggregate description (`AudioHardwareCreateAggregateDevice`):

```swift
[
  kAudioAggregateDeviceNameKey: "Loopback Graph \(device.name)",
  kAudioAggregateDeviceUIDKey: "com.zan.wheresoundmeet.agg.\(device.id)",
  kAudioAggregateDeviceIsPrivateKey: 1,
  kAudioAggregateDeviceIsStackedKey: 0,
  kAudioAggregateDeviceMainSubDeviceKey: device.driverUID,
  kAudioAggregateDeviceSubDeviceListKey: ([device.driverUID] + inputDeviceUIDs + monitorUIDs).map {
      [kAudioSubDeviceUIDKey: $0, kAudioSubDeviceDriftCompensationKey: $0 == device.driverUID ? 0 : 1] },
  kAudioAggregateDeviceTapListKey: taps.map { [kAudioSubTapUIDKey: $0.uid, kAudioSubTapDriftCompensationKey: 1] },
  kAudioAggregateDeviceTapAutoStartKey: 1,
]
```

Thứ tự stream trong AudioBufferList của aggregate: input = [input streams của mỗi sub-device theo thứ tự list] rồi [taps]; output = [output streams theo thứ tự list]. Sau khi tạo, đọc `kAudioDevicePropertyStreamConfiguration` (Input/Output) để lấy số buffer + channel mỗi buffer thật, rồi map: buffer i của input ↔ sub-device/tap thứ i; buffer j output ↔ virtual (j=0) và monitor theo thứ tự. Lưu map thành `MixPlan.inputs/outputs` (`offset` = chỉ số buffer).

IOProc (`AudioDeviceCreateIOProcIDWithBlock`, queue `nil` → RT thread): với mỗi buffer input lấy `mData` thành `UnsafePointer<Float>`, output tương tự, gọi `kernel.process(inputs:outputs:frames:)` với mảng pointer đã cấp phát sẵn (`ContiguousArray` reserve trước, gán phần tử trong callback không cấp phát). Nếu input channel count ≠ 2 cho device, MixPlan.Input.channels dùng số thật.

Build `MixPlan` từ `VirtualDevice`: 
- inputs theo thứ tự `device.sources` (chỉ source có tap/device tồn tại), gain = `isOn ? volume : 0`.
- busCount = `outputChannels.count`; inputToBus từ wires source→channel (bus = `outputChannels.firstIndex(id)`).
- outputs[0] = virtual out (channels 2, gain 1), outputs[1...] = monitors (gain = `isOn ? volume : 0`); busToOutput = `[(b, 0, b) for b < 2]` + wires channel→monitor.
- masterGain = `device.isOn ? device.volume : 0`.

AudioEngine.apply: diff theo `id`; device mới On → tạo graph; Off → stop + xoá; đổi cấu trúc → `graph.update`. Timer 1/30 s đọc `graph.meters()` vào `meters`. Lỗi (tap fail, aggregate fail) → `errors[id] = message`, không crash.

- [ ] **Step 1: Viết 3 file.**
- [ ] **Step 2: Verify luồng thật (tạm gọi từ WhereSoundMeetApp):** device mặc định + source Safari đang phát YouTube + monitor "MacBook Air Speakers": nghe thấy tiếng từ loa; QuickTime chọn "Loopback Audio" làm mic thấy meter nhảy. Dừng Safari → im. Ghi lại output `log stream --predicate 'subsystem == "com.zan.wheresoundmeet"'` không lỗi.

---

### Task 7: AppStore + khung cửa sổ + Sidebar

**Files:**
- Create: `Sources/Loopback/App/AppStore.swift`, `Sources/Loopback/UI/SidebarView.swift`, `Sources/Loopback/UI/Banners.swift`
- Modify: `Sources/Loopback/App/WhereSoundMeetApp.swift`

**Interfaces:**
- Produces:

```swift
@Observable @MainActor final class AppStore {
    var devices: [VirtualDevice]; var selectedID: UUID?; var showMonitors = true
    let engine: AudioEngine; let system: AudioSystem
    var selected: VirtualDevice? { get }
    func mutateSelected(_ f: (inout VirtualDevice) -> Void)   // sửa → save debounce 300ms → engine.apply
    func addDevice(); func deleteSelected(); func rename(_ id: UUID, to: String)
    func setOn(_ id: UUID, _ on: Bool); func setVolume(_ id: UUID, _ v: Float)
    init(store: DeviceStore = .init(url: DeviceStore.defaultURL), ...)  // load, chọn device đầu, engine.apply
}
```

Layout tổng (bám ảnh): `NavigationSplitView` với sidebar 300pt (`Theme.sidebar`), detail nền `Theme.canvas`. Sidebar: tiêu đề "Devices" (icon `power` + bold 17), list card device: hàng 1 tên bold + Toggle "On" kiểu capsule (`ToggleStyle` custom: chữ On/Off trong capsule, teal khi on); hàng 2 icon mic/app 20pt + tên các source gộp (`sources.map(\.kind.displayName).joined(", ")`) + meter nhỏ 60×8; hàng 3 icon `speaker.wave.2` + Slider volume + "100%". Đáy: `Button("New Virtual Device", systemImage: "plus.circle.fill")` trái, nút `minus.circle.fill` phải (disabled khi không chọn).

Banners (trên cùng detail): `DriverClient.isInstalled == false` → "Driver chưa cài" + nút Install (gọi `installDriver`, hiện lỗi nếu fail); `errors` từ engine → banner đỏ; mic bị denied → banner + nút Open Settings.

- [ ] **Step 1: Viết AppStore + SidebarView + Banners; WhereSoundMeetApp dùng `NavigationSplitView { SidebarView } detail: { Text(selected?.name ?? "") }`.**
- [ ] **Step 2: Verify:** `./Scripts/run.sh`; tạo 2 device, đổi tên, tắt/bật, thoát, mở lại → còn nguyên (`cat ~/Library/Application\ Support/Loopback/devices.json`). `system_profiler SPAudioDataType` thấy đủ device theo tên.

---

### Task 8: DeviceEditorView + cards + menu "+"

**Files:**
- Create: `Sources/Loopback/UI/DeviceEditorView.swift`, `Sources/Loopback/UI/Cards/CardChrome.swift`, `Sources/Loopback/UI/Cards/SourceCard.swift`, `Sources/Loopback/UI/Cards/ChannelCard.swift`, `Sources/Loopback/UI/Cards/MonitorCard.swift`, `Sources/Loopback/UI/AddMenus.swift`, `Sources/Loopback/UI/Wires/PortPreference.swift`

**Interfaces:**
- Produces:

```swift
struct PortKey: Hashable { let endpoint: Endpoint; let side: PortSide }   // side: .output (chấm phải) / .input (chấm trái)
enum PortSide { case input, output }
struct PortPositions: PreferenceKey { static var defaultValue: [PortKey: CGPoint] }  // toạ độ tâm chấm trong coordinateSpace "editor"
struct PortDot: View { let key: PortKey; let onDragStart/onDragEnd... }  // Task 9 gắn gesture
struct CardChrome<Body: View>: View { title, isOn: Binding<Bool>, offTint: Color, options: ()->View, body }  // header + footer "Options"
struct LevelMeter: View { let level: Float; var width: CGFloat = 120 }  // thanh teal trên track xám
```

Bố cục detail (`DeviceEditorView`): `ScrollView([.horizontal, .vertical])` → `ZStack { columns; WireLayer }` `.coordinateSpace(name: "editor")`. Columns = `HStack(alignment: .top, spacing: Theme.columnGap)` 3 `VStack`: header (title 20 semibold + subtitle xám + nút `plus.circle.fill` menu), rồi cards spacing 32, width `Theme.cardWidth`. Tiêu đề device trên cùng (28 bold + `pencil` mở TextField inline). Đáy: HStack `Button("Delete", systemImage: "trash")` + Spacer + `Button(showMonitors ? "Hide Monitors" : "Show Monitors", systemImage: "eye.slash")`.

- SourceCard: icon 64pt (mic → `mic.fill` trong hình tròn xám; app → icon từ `AudioSystem.processes` hoặc `NSWorkspace.shared.icon(forFile:)` theo bundle path; passThru → `arrow.triangle.2.circlepath` teal/đỏ), bên phải 2 hàng: label "1 (L)"/"2 (R)", `LevelMeter`, `PortDot(side: .output)`. Options: Slider volume + nút Remove.
- ChannelCard: title "Channels \(a) & \(b)"; mỗi hàng: `PortDot(.input)`, label "Channel 1 (L)", meter, `PortDot(.output)`. Options: Remove pair.
- MonitorCard: header toggle với `offTint: Theme.red` (đỏ khi Off như ảnh); hàng: `PortDot(.input)`, meter, label "Channel 1 (L)" phải. Options: volume + Remove.
- AddMenus: Sources → submenu "Running Applications" (từ `system.processes`, icon + tên), "Audio Devices" (input devices), "Pass-Thru" (disabled nếu đã có). Output Channels → "Add Channels 3 & 4". Monitors → output devices (disabled nếu đã có).
- Meter: `store.engine.meters[device.id]` map sang node: inputs theo thứ tự sources, buses theo channel index, outputs[1...] theo monitors.
- A11y: mọi toggle/port có `accessibilityLabel`; card focusable; Delete có confirm dialog.

- [ ] **Step 1: Viết các file, WireLayer tạm là `EmptyView`.**
- [ ] **Step 2: Verify:** chạy app, thêm Safari + mic + monitor, meter nhảy khi có tiếng; đối chiếu bố cục với ảnh gốc (chụp màn hình bằng `screencapture -x` và xem).

---

### Task 9: WireLayer — vẽ và kéo dây

**Files:**
- Create: `Sources/Loopback/UI/Wires/WireLayer.swift`
- Modify: `Sources/Loopback/UI/Cards/CardChrome.swift` (PortDot gesture), `Sources/Loopback/UI/DeviceEditorView.swift`

**Interfaces:**
- Consumes: `PortPositions`, `VirtualDevice.wires/toggleWire/isValid`.
- Produces:

```swift
@Observable final class WireDrag { var from: PortKey?; var current: CGPoint; var hoverTarget: PortKey? }
struct WireLayer: View { let wires: Set<Wire>; let ports: [PortKey: CGPoint]; let drag: WireDrag; let selected: Wire?; onSelect: (Wire?)->Void }
```

Vẽ: `Canvas` full size; mỗi wire lấy `ports[PortKey(from, .output)]` và `ports[PortKey(to, .input)]`; path cubic Bézier với control points `(x1 + dx*0.5, y1)` và `(x2 - dx*0.5, y2)`, `dx = max(60, abs(x2-x1)*0.5)`; stroke teal `Theme.wireWidth`, wire được chọn stroke dày 4 + màu đậm hơn. Dây monitor (channel→monitor) vẽ xám `Color(white: 0.6)` như ảnh. Dây đang kéo: từ `drag.from` tới `drag.current`, nét đứt.

Kéo: `PortDot` có `DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))`: onChanged → `drag.from = key` (chỉ khi side == .output, hoặc side == .input để kéo ngược), `drag.current = location`, `drag.hoverTarget` = port gần nhất trong 14pt ở phía đối diện; onEnded → nếu có target và wire hợp lệ → `store.mutateSelected { $0.toggleWire(wire) }`; reset drag. Click lên dây (hit-test khoảng cách điểm-đường ≤ 6pt, lấy mẫu 32 điểm trên Bézier) → chọn; phím Delete (`.onDeleteCommand`) xoá dây chọn. Kéo từ port đã có dây ra vùng trống → không làm gì (đơn giản hoá: xoá bằng chọn + Delete, hoặc kéo lại lên chính port đích để toggle).

- [ ] **Step 1: Viết WireLayer + gesture.**
- [ ] **Step 2: Verify:** kéo Safari L → Channel 2, dây xuất hiện, audio Safari L đi vào kênh R (nghe qua monitor/ghi QuickTime). Chọn dây, Delete → mất, audio kênh đó im. Đóng mở app dây còn nguyên.

---

### Task 10: Đóng gói driver vào app + cài từ app + kiểm chứng toàn luồng

**Files:**
- Modify: `Scripts/build-app.sh` (make driver, copy vào `Contents/Resources/WhereSoundMeetDriver.driver`), `Sources/Loopback/Audio/DriverClient.swift` (`installDriver` dùng bundle trong Resources)

- [ ] **Step 1: build-app.sh gọi `make -C "$ROOT/Driver"` rồi `cp -R build/WhereSoundMeetDriver.driver "$APP/Contents/Resources/"` trước khi codesign.**
- [ ] **Step 2: `installDriver()`:**

```swift
static func installDriver() throws {
    guard let src = Bundle.main.resourceURL?.appendingPathComponent("WhereSoundMeetDriver.driver") else { throw DriverError.bundleMissing }
    let dst = "/Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver"
    let sh = "rm -rf '\(dst)' && cp -R '\(src.path)' '\(dst)' && chown -R root:wheel '\(dst)' && killall coreaudiod"
    let script = "do shell script \"\(sh.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { throw DriverError.install(err.description) }
}
```

- [ ] **Step 3: Kiểm chứng toàn luồng (ghi kết quả thật vào báo cáo):**
  1. `swift test` pass.
  2. `./Scripts/build-app.sh` → `ls build/WhereSoundMeet.app/Contents/Resources/WhereSoundMeetDriver.driver`.
  3. Gỡ driver cũ (`sudo rm -rf /Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver && sudo killall coreaudiod`), mở app → banner Install → cài từ app → banner biến mất, device xuất hiện.
  4. Safari phát nhạc → source Safari → QuickTime (mic = Loopback Audio) ghi 5 s → nghe lại có nhạc.
  5. Micro → monitor loa: nói, nghe được (bật/tắt monitor hoạt động, Off đỏ).
  6. Pass-Thru: Audio MIDI Setup đặt "Loopback Audio" làm output mặc định, `afplay /System/Library/Sounds/Glass.aiff` → QuickTime ghi được; tắt Pass-Thru → im.
  7. Xoá device → biến mất trong Audio MIDI Setup; tạo lại → xuất hiện.
  8. Thoát app: device vẫn còn trong hệ thống (ownerPID reset về 0 khi app thoát để device hoạt động như loopback thường).

---

## Self-review

- Spec §1–§7 đều có task: plugin (T4), engine (T5–T6), model/lưu (T2), UI (T7–T9), cài đặt & kiểm chứng (T4/T10). Ngoài phạm vi giữ nguyên.
- Tên nhất quán: `MixKernel.process(inputs:outputs:frames:)`, `MixPlan.Input.offset`, `VirtualDevice.toggleWire`, `DriverProtocol.deviceListSelector` ↔ `'lbdv'`.
- Điểm chưa chắc, ghi để xử lý khi gặp: (a) tap `deviceUID` có bắt được audio gửi vào device HAL ảo hay không — nếu không, fallback: plugin loop mọi client và Pass-Thru thành nút cố định (báo user); (b) thứ tự buffer trong aggregate có tap — xác minh bằng `StreamConfiguration` lúc chạy; (c) `ProcessOutput` per-client có được gọi với `inClientID` đúng — kiểm bằng log lần đầu.
