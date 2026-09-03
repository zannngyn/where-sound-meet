import WhereSoundMeetCore
import SwiftUI

/// One card per pair of output channels ("Channels 1 & 2").
struct ChannelCard: View {
    let channels: [OutputChannel]
    let levels: [UUID: [Float]]
    @Environment(AppStore.self) private var store

    private var title: String {
        "Channels " + channels.map { "\($0.index + 1)" }.joined(separator: " & ")
    }

    var body: some View {
        CardChrome(nodeID: channels[0].id, title: title) {
            VStack(spacing: 14) {
                ForEach(channels) { ch in
                    HStack(spacing: 10) {
                        PortDot(key: PortKey(endpoint: Endpoint(nodeID: ch.id, channel: 0), side: .input))
                        Text(ch.label).font(.callout).lineLimit(1).fixedSize()
                        LevelMeter(level: levels[ch.id]?.first ?? 0, width: 80)
                        Spacer(minLength: 0)
                        PortDot(key: PortKey(endpoint: Endpoint(nodeID: ch.id, channel: 0), side: .output))
                    }
                }
            }
        } options: {
            RemoveButton { store.mutateSelected { $0.remove(nodeID: channels[0].id) } }
        }
    }
}
