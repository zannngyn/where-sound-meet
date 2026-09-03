// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WhereSoundMeet",
    platforms: [.macOS("14.2")],
    targets: [
        .target(name: "WhereSoundMeetCore", path: "Sources/WhereSoundMeetCore",
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "WhereSoundMeet", dependencies: ["WhereSoundMeetCore"], path: "Sources/WhereSoundMeet",
                          swiftSettings: [.swiftLanguageMode(.v5)],
                          linkerSettings: [.linkedFramework("CoreAudio"), .linkedFramework("AppKit"),
                                           .linkedFramework("AVFoundation")]),
        .testTarget(name: "WhereSoundMeetCoreTests", dependencies: ["WhereSoundMeetCore"], path: "Tests/WhereSoundMeetCoreTests"),
    ]
)
