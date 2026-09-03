import WhereSoundMeetCore
import SwiftUI

struct MonitorCard: View {
    let monitor: Monitor
    let levels: [Float]
    @Environment(AppStore.self) private var store

    var body: some View {
        CardChrome(nodeID: monitor.id, title: monitor.name,
                   isOn: Binding(get: { monitor.isOn }, set: { v in store.mutateSelected { $0.monitors[id: monitor.id]?.isOn = v } }),
                   volume: Binding(get: { monitor.volume }, set: { v in store.mutateSelected { $0.monitors[id: monitor.id]?.volume = v } }),
                   offTint: Theme.red) {
            VStack(spacing: 14) {
                ForEach(0..<2, id: \.self) { ch in
                    HStack(spacing: 10) {
                        PortDot(key: PortKey(endpoint: Endpoint(nodeID: monitor.id, channel: ch), side: .input))
                        LevelMeter(level: levels.indices.contains(ch) ? levels[ch] : 0)
                        Text("Channel \(ch + 1) (\(ch == 0 ? "L" : "R"))").font(.callout).foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        } options: {
            RemoveButton { store.mutateSelected { $0.remove(nodeID: monitor.id) } }
        }
    }
}
