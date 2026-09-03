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
                RemoveButton { store.mutateSelected { $0.remove(nodeID: source.id) } }
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
