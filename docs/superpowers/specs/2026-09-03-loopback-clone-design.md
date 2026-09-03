# Loopback clone — thiết kế

Ngày: 2026-09-03. Mục tiêu: app macOS tái hiện Loopback (Rogue Amoeba) — tạo thiết bị audio ảo,
gom audio từ app / micro / Pass-Thru, nối kênh bằng dây, monitor ra loa. Giao diện bám ảnh chụp
Loopback (sidebar Devices, 3 cột Sources / Output Channels / Monitors, dây Bézier màu teal).

Môi trường: macOS 14+ (máy dev macOS 26.6), Xcode 26.3, Swift 6.2. Không thêm dependency ngoài.

## 1. Kiến trúc

Một Xcode project `Loopback.xcodeproj`, 2 target:

| Target | Ngôn ngữ | Vai trò |
|---|---|---|
| `WhereSoundMeet.app` | Swift / SwiftUI | UI, model, audio engine, quản lý plugin |
| `WhereSoundMeetDriver.driver` | C | HAL AudioServerPlugIn, tạo thiết bị ảo trong `coreaudiod` |

Plugin cài vào `/Library/Audio/Plug-Ins/HAL/WhereSoundMeetDriver.driver` (cần `sudo`), sau đó
`sudo killall coreaudiod` một lần. Bundle ID: `com.zan.wheresoundmeet` (app), `com.zan.wheresoundmeet.driver`.

Luồng audio cho một virtual device đang On:

```
[App tap: Safari]  ─┐
[Mic input]        ─┤  aggregate device (1 IOProc trong app)
[Pass-Thru tap]    ─┘        │ mix theo ma trận dây, nhân volume, đo RMS
                              ├─▶ output stream của WhereSoundMeetDriver device  ─▶ plugin loop ─▶ input stream (app khác đọc)
                              └─▶ monitor output device(s)
```

Pass-Thru = audio các app khác phát **vào** virtual device. Plugin KHÔNG loop phần này; app bắt nó
bằng global tap giới hạn `deviceUID` = UID virtual device, loại trừ chính PID app. Plugin chỉ loop
output của client là app Loopback (chép riêng buffer của client đó trong `ProcessOutput`, nhận diện
qua `mProcessID`) và bỏ qua mix chung ở `WriteMix`. Không được xoá buffer của client khác: tap
của macOS bắt audio sau bước `ProcessOutput`, xoá là tap im lặng (đã kiểm chứng 2026-09-03).
Device không có owner (app không chạy) thì loop toàn bộ mix như BlackHole.

## 2. Plugin `WhereSoundMeetDriver` (C)

- Implement `AudioServerPlugInDriverInterface` đầy đủ: Initialize, CreateDevice/DestroyDevice,
  AddDeviceClient/RemoveDeviceClient, property get/set, StartIO/StopIO, GetZeroTimeStamp,
  BeginIOOperation/DoIOOperation/EndIOOperation.
- Mỗi device: 2 kênh (L/R), Float32 44.1k/48k (lấy sample rate theo yêu cầu, mặc định 48000),
  1 input stream + 1 output stream, ring buffer 1 s trong plugin, timestamp giả lập từ
  `mach_absolute_time` giống mô hình BlackHole/NullAudio.
- Device động: plugin object có custom property `'lbdv'` (kAudioObjectPropertyCustomPropertyInfoList)
  kiểu CFPropertyList: mảng `{ uid: String, name: String }`. App set → plugin diff, gọi
  `host->AddDevice`/`RemoveDevice`. Custom property `'lbon'` theo device: PID owner (UInt32).
- Trạng thái device lưu trong plugin theo phiên coreaudiod; app đẩy lại toàn bộ danh sách khi
  khởi động (idempotent).
- Không copy code BlackHole (GPL). Viết mới, tham chiếu sample `NullAudio` của Apple.
- Cấu hình: NSHumanReadableCopyright, `CFPlugInFactories` UUID riêng, `LSMinimumSystemVersion` 14.0.
  Universal (arm64 + x86_64), Hardened Runtime, ký ad-hoc khi dev.

## 3. Audio engine (app)

Thư mục `Loopback/Audio/`:

- `AudioSystem` — liệt kê input/output device (AudioObjectPropertyListener cho thay đổi),
  liệt kê process có audio (`kAudioHardwarePropertyProcessObjectList` + pid/bundleID/icon).
- `TapController` — tạo/huỷ `CATapDescription` + `AudioHardwareCreateProcessTap`.
- `DeviceGraph` — mỗi VirtualDevice On ↔ 1 aggregate device
  (`AudioHardwareCreateAggregateDevice`, `kAudioAggregateDeviceIsPrivateKey`,
  sub-device list = input devices + virtual output + monitor outputs, `taps` = tap UIDs,
  drift compensation bật cho mọi sub-device trừ master). Rebuild aggregate khi source/monitor
  thay đổi; đổi dây/volume/on-off chỉ swap struct atomic, không rebuild.
- `MixKernel` — code chạy trong IOProc: đọc buffer input theo offset stream, nhân
  `gain[src][ch] × sourceVolume × deviceVolume`, cộng vào output channel, ghi ra virtual output và
  monitor. Không cấp phát, không lock, không Swift ARC trong callback (dùng `UnsafeMutablePointer`,
  struct preallocated, swap bằng `Atomic`/`os_unfair_lock_trylock` phía non-RT).
- Meter: RMS mỗi kênh cho từng source, output channel, monitor; đẩy về UI 30 fps qua timer đọc
  giá trị atomic.
- Quyền: micro (`NSMicrophoneUsageDescription`), tap app (`NSAudioCaptureUsageDescription`,
  System Settings → Screen & System Audio Recording). Thiếu quyền → card hiện trạng thái lỗi.

## 4. Model + lưu trữ

`Loopback/Model/`:

```swift
struct VirtualDevice: Codable, Identifiable { id: UUID; name; isOn; volume: Float;
  sources: [Source]; outputChannels: [OutputChannel]; monitors: [Monitor]; wires: [Wire] }
enum SourceKind: Codable { case app(bundleID: String, name: String)
                           case inputDevice(uid: String, name: String)
                           case passThru }
struct Source: Codable, Identifiable { id; kind; isOn; volume; channelCount }
struct OutputChannel: Codable, Identifiable { id; index: Int }          // 1-based, nhóm 2 = "Channels 1 & 2"
struct Monitor: Codable, Identifiable { id; deviceUID; name; isOn; volume }
struct Wire: Codable, Hashable { from: Endpoint; to: Endpoint }         // Endpoint = (nodeID, channelIndex)
```

Lưu JSON tại `~/Library/Application Support/Loopback/devices.json`, ghi debounce 300 ms sau mỗi
thay đổi. Device mới mặc định: 1 source Pass-Thru, 2 output channel, dây Pass-Thru L→1, R→2,
đúng như Loopback tạo "Loopback Audio".

State: `AppStore` (`@Observable`, MainActor) giữ `[VirtualDevice]` + selection; engine subscribe
qua diff. Engine là nguồn cho meter và danh sách device/process; store là nguồn cho cấu hình.

## 5. UI (SwiftUI)

Bám ảnh chụp, không có Trial Mode.

- `SidebarView`: tiêu đề "Devices", danh sách device card (tên, toggle On, icon các source, meter
  tổng, slider volume + %), nút "New Virtual Device" / "−" ở đáy.
- `DeviceEditorView`: tiêu đề tên device + nút sửa tên; 3 cột. Header mỗi cột: tiêu đề, phụ đề
  đếm ("1 App, 1 Device, Pass-Thru"), nút "+" (menu: Sources → Running app / Input device /
  Pass-Thru; Output Channels → thêm cặp kênh; Monitors → output device).
- `SourceCard`, `ChannelCard`, `MonitorCard`: header có toggle On/Off (teal On, đỏ Off cho
  monitor như ảnh), thân có icon + hàng kênh (nhãn "1 (L)", meter, chấm port), footer
  "Options" collapsible (volume slider, xoá).
- `WireLayer`: `Canvas` phủ toàn vùng, vẽ cubic Bézier teal từ port ra → port vào. Vị trí port
  báo lên qua `PreferenceKey`. Kéo từ port: dây tạm theo chuột; thả lên port hợp lệ → thêm wire;
  kéo dây có sẵn ra chỗ trống → xoá. Click dây chọn, Delete xoá.
- Đáy: nút "Delete" (xoá device đang chọn, confirm), nút "Hide/Show Monitors".
- Trạng thái: chưa có device → empty state; thiếu quyền → banner + nút mở System Settings;
  plugin chưa cài → banner "Install driver" chạy script cài qua `osascript` với admin prompt.
- Token: teal `#3DBEB0` (dây, meter, On), đỏ `#E5484D` (Off), nền `#ECECEC`, card trắng bo 8,
  font hệ thống. Đặt trong `Theme.swift`.
- Skill FE áp dụng (bản core, không có delta desktop): component-reuse, accessibility (label cho
  port/toggle, keyboard xoá dây), feedback-states, design-tokens, state-architecture,
  drag-drop-reorder.

## 6. Cài đặt & kiểm chứng

- Script `Scripts/install-driver.sh`: copy bundle vào `/Library/Audio/Plug-Ins/HAL/`, chown root,
  `killall coreaudiod`. App gọi qua `osascript ... with administrator privileges`.
- Test:
  - Plugin: `xcodebuild` target driver; cài; `system_profiler SPAudioDataType` thấy device;
    `sudo log stream --predicate 'process == "coreaudiod"'` không lỗi.
  - Unit test (XCTest): `MixKernel` với buffer giả (ma trận dây, volume, RMS); Codable round-trip
    model; diff danh sách device → lệnh Add/Remove.
  - Luồng thật: Safari phát nhạc → source Safari → QuickTime chọn "Loopback Audio" làm micro,
    ghi 5 s có tiếng. Micro → monitor loa nghe được. Pass-Thru: `afplay -d "Loopback Audio"`
    (hoặc chọn output hệ thống) → QuickTime nghe được. Tắt device → im lặng. Xoá device → biến
    mất khỏi Audio MIDI Setup.

## 7. Ngoài phạm vi

Trial/licence, Options nâng cao (mute when capturing, nudge), hơn 2 kênh/source, hiệu ứng,
auto-update, ký/notarize phát hành.
