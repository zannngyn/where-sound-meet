import WhereSoundMeetCore
import SwiftUI

struct SourceCard: View {
    let source: Source
    let levels: [Float]
    @Environment(AppStore.self) private var store

    var body: some View {
        CardChrome(nodeID: source.id, title: source.kind.displayName,
                   isOn: Binding(get: { source.isOn }, set: { v in store.mutateSelected { $0.sources[id: source.id]?.isOn = v } }),
                   volume: Binding(get: { source.volume }, set: { v in store.mutateSelected { $0.sources[id: source.id]?.volume = v } }),
                   effects: Binding(get: { source.effects }, set: { v in store.mutateSelected { $0.sources[id: source.id]?.effects = v } })) {
            HStack(spacing: 16) {
                SourceIconView(kind: source.kind)
                VStack(spacing: 14) {
                    ForEach(0..<source.channelCount, id: \.self) { ch in
                        HStack(spacing: 10) {
                            Text("\(ch + 1) (\(ch % 2 == 0 ? "L" : "R"))").font(.callout).frame(width: 40, alignment: .trailing)
                            LevelMeter(level: levels.indices.contains(ch) ? levels[ch] : 0)
                            PortDot(key: PortKey(endpoint: Endpoint(nodeID: source.id, channel: ch), side: .output))
                        }
                    }
                }
            }
        } options: {
            VStack(alignment: .leading, spacing: 8) {
                if case .app = source.kind {
                    Toggle("Mute app's own output while capturing",
                           isOn: Binding(get: { source.muteOriginal }, set: { v in store.mutateSelected { $0.sources[id: source.id]?.muteOriginal = v } }))
                        .toggleStyle(.checkbox)
                }
                delayRow
                RemoveButton { store.mutateSelected { $0.remove(nodeID: source.id) } }
            }
        }
    }
}

extension SourceCard {
    /// Delay into the output channels only (direct wires to monitors stay live), so a singer who hears this
    /// source late through Bluetooth headphones still lines up with it in the device's output.
    private var delayRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Delay to channels").font(.callout)
                Slider(value: Binding(get: { Double(source.delayMs) },
                                      set: { v in store.mutateSelected { $0.sources[id: source.id]?.delayMs = Float(v) } }),
                       in: 0...Double(Source.maxDelayMs), step: 5)
                    .tint(Theme.teal)
                    .accessibilityLabel("Delay to channels for \(source.kind.displayName)")
                Text("\(Int(source.delayMs)) ms").font(.callout).monospacedDigit().frame(width: 56, alignment: .trailing)
            }
            let monitors = store.selected?.monitors ?? []
            let hints = monitors.compactMap { m in AudioSystem.outputLatencyMs(uid: m.deviceUID).map { (m, $0) } }
            if !hints.isEmpty {
                HStack(spacing: 6) {
                    Text("Match headphones:").font(.caption).foregroundStyle(Theme.textSecondary)
                    ForEach(hints, id: \.0.id) { m, ms in
                        Button("\(m.name) (\(Int(ms.rounded())) ms)") {
                            store.mutateSelected { $0.sources[id: source.id]?.delayMs = Float(min(ms, Double(Source.maxDelayMs))) }
                        }
                        .buttonStyle(.link).font(.caption)
                    }
                }
            }
        }
    }
}

extension Array where Element: Identifiable {
    subscript(id id: Element.ID) -> Element? {
        get { first { $0.id == id } }
        set {
            guard let i = firstIndex(where: { $0.id == id }) else { return }
            if let newValue { self[i] = newValue } else { remove(at: i) }
        }
    }
}
