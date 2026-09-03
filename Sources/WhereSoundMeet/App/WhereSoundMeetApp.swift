import SwiftUI

@main
struct WhereSoundMeetApp: App {
    @State private var store = AppStore()

    init() {
        // Debug aid: `WhereSoundMeet --list-processes` prints the grouped audio process list and exits.
        if CommandLine.arguments.contains("--list-processes") {
            for p in AudioSystem.allProcesses() {
                print("\(p.isRunningOutput ? "*" : " ") \(p.name) [\(p.bundleID)] pid=\(p.pid) members=\(p.memberBundleIDs)")
            }
            exit(0)
        }
        // Debug aid: `WhereSoundMeet --effects-selftest` runs a 1 kHz sine through each effect and prints RMS.
        if CommandLine.arguments.contains("--effects-selftest") {
            EffectChain.selfTest()
            exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("Where Sound Meet") {
            RootView()
                .environment(store)
                .frame(minWidth: 1000, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1500, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Device") { store.addDevice() }.keyboardShortcut("n")
            }
            CommandMenu("Driver") {
                Button(DriverClient.isInstalled ? "Reinstall Driver…" : "Install Driver…") { store.installDriver() }
                Button("Retry Driver Connection") { store.retryDriver() }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 260, ideal: 280, max: 340)
        } detail: {
            VStack(spacing: 0) {
                Banners()
                if let device = store.selected {
                    DeviceEditorView(device: device)
                } else {
                    EmptyEditorView()
                }
            }
            .background(Theme.canvas)
        }
        .navigationTitle("Where Sound Meet")
    }
}

struct EmptyEditorView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.circle").font(.system(size: 48)).foregroundStyle(Theme.textSecondary)
            Text("No virtual device").font(.title2.weight(.semibold))
            Text("Create one to start routing audio.").foregroundStyle(Theme.textSecondary)
            Button("New Virtual Device") { store.addDevice() }.keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
