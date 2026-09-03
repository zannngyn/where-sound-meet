import WhereSoundMeetCore
import SwiftUI

struct AddSourceMenu: View {
    let device: VirtualDevice
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            Section("Running Applications") {
                if store.system.processes.isEmpty { Text("No audio apps running") }
                ForEach(store.system.processes) { p in
                    Button {
                        store.mutateSelected { $0.addSource(.app(bundleID: p.bundleID, name: p.name)) }
                    } label: {
                        if let icon = AudioSystem.appIcon(bundleID: p.bundleID) {
                            Label { Text(p.name) } icon: { Image(nsImage: icon) }
                        } else {
                            Text(p.name)
                        }
                    }
                }
            }
            Section("Audio Devices") {
                ForEach(store.system.inputDevices) { d in
                    Button(d.name) { store.mutateSelected { $0.addSource(.inputDevice(uid: d.uid, name: d.name)) } }
                }
            }
            Divider()
            Button("Pass-Thru") { store.mutateSelected { $0.addSource(.passThru) } }
                .disabled(device.hasPassThru)
        } label: {
            AddLabel(caret: true)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Add source")
    }
}

struct AddChannelsButton: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button { store.mutateSelected { $0.addOutputChannelPair() } } label: { AddLabel(caret: false) }
            .buttonStyle(.plain)
            .accessibilityLabel("Add output channels")
    }
}

struct AddMonitorMenu: View {
    let device: VirtualDevice
    @Environment(AppStore.self) private var store

    var body: some View {
        Menu {
            ForEach(store.system.outputDevices) { d in
                Button(d.name) { store.mutateSelected { $0.addMonitor(deviceUID: d.uid, name: d.name) } }
                    .disabled(device.monitors.contains { $0.deviceUID == d.uid })
            }
        } label: {
            AddLabel(caret: true)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Add monitor")
    }
}

struct AddLabel: View {
    let caret: Bool
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "plus.circle.fill").font(.title2)
            if caret { Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
        }
        .foregroundStyle(.primary)
    }
}
