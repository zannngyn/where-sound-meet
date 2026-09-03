import WhereSoundMeetCore
import SwiftUI

struct SidebarView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "power.circle.fill").font(.title2).foregroundStyle(.secondary)
                Text("Devices").font(.title2.weight(.bold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 8)

            List(selection: $store.selectedID) {
                ForEach(store.devices) { device in
                    DeviceRow(device: device)
                        .tag(device.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        .listRowSeparator(.hidden)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button { store.addDevice() } label: {
                    Label("New Virtual Device", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New Virtual Device")
                Spacer()
                Button { store.deleteSelected() } label: {
                    Image(systemName: "minus.circle.fill").font(.title3)
                }
                .buttonStyle(.plain)
                .disabled(store.selectedID == nil)
                .accessibilityLabel("Delete selected device")
            }
            .padding(12)
        }
        .background(Theme.sidebar)
    }
}

private struct DeviceRow: View {
    @Environment(AppStore.self) private var store
    let device: VirtualDevice

    private var level: Float {
        let levels = store.engine.levels[device.id] ?? [:]
        return device.outputChannels.compactMap { levels[$0.id]?.first }.max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(device.name).font(.headline).lineLimit(1)
                Spacer()
                OnOffToggle(isOn: Binding(get: { device.isOn }, set: { store.setOn(device.id, $0) }))
            }
            HStack(alignment: .top, spacing: 8) {
                SourceIcons(sources: device.sources)
                Text(device.sources.map(\.kind.displayName).joined(separator: ", "))
                    .font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(2)
                Spacer(minLength: 4)
                LevelMeter(level: level, width: 64)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                Slider(value: Binding(get: { Double(device.volume) }, set: { store.setVolume(device.id, Float($0)) }), in: 0...1)
                    .tint(Theme.teal)
                    .accessibilityLabel("Volume for \(device.name)")
                Text("\(Int(device.volume * 100))%").font(.callout).monospacedDigit().frame(width: 44, alignment: .trailing)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius).stroke(Theme.cardBorder))
    }
}

private struct SourceIcons: View {
    let sources: [Source]

    var body: some View {
        HStack(spacing: -6) {
            ForEach(sources.prefix(3)) { s in
                SourceIconView(kind: s.kind, size: 20)
                    .overlay(Circle().stroke(Theme.card, lineWidth: 1.5))
            }
        }
    }
}
