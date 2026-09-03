import WhereSoundMeetCore
import SwiftUI

struct DeviceEditorView: View {
    let device: VirtualDevice
    @Environment(AppStore.self) private var store
    @State private var wires = WireEditorState()
    @State private var editingName = false
    @State private var draftName = ""
    @State private var confirmDelete = false

    private var levels: [UUID: [Float]] { store.engine.levels[device.id] ?? [:] }
    private var columnCount: Int { store.showMonitors ? 3 : 2 }
    private let sidePadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                let layout = layout(for: geo.size.width)
                ScrollView(layout.scrollsHorizontally ? [.horizontal, .vertical] : .vertical) {
                    ZStack(alignment: .topLeading) {
                        columns(gap: layout.gap)
                        WireLayer(device: device)
                    }
                    .coordinateSpace(name: "editor")
                    .onPreferenceChange(PortPositions.self) { wires.ports = $0 }
                    .padding(.horizontal, sidePadding).padding(.top, 8).padding(.bottom, 24)
                    .frame(minWidth: geo.size.width, alignment: .topLeading)
                    .contentShape(Rectangle())
                    .onTapGesture { wires.select(node: nil) }
                    .environment(\.cardWidth, layout.cardWidth)
                }
                .defaultScrollAnchor(.topLeading)
            }
            .focusable()
            .focusEffectDisabled()
            .onDeleteCommand { deleteSelection() }
            Divider()
            footer
        }
        .environment(wires)
        .onChange(of: device.id) { _, _ in wires.select(node: nil) }
    }

    // MARK: - Responsive layout

    private struct Layout { var cardWidth: CGFloat; var gap: CGFloat; var scrollsHorizontally: Bool }

    /// Cards shrink toward `cardMinWidth` and gaps toward `columnMinGap` before horizontal scrolling kicks in.
    private func layout(for width: CGFloat) -> Layout {
        let n = CGFloat(columnCount)
        let available = width - sidePadding * 2
        let minTotal = n * Theme.cardMinWidth + (n - 1) * Theme.columnMinGap
        if available < minTotal {
            return Layout(cardWidth: Theme.cardMinWidth, gap: Theme.columnMinGap, scrollsHorizontally: true)
        }
        let maxTotal = n * Theme.cardMaxWidth + (n - 1) * Theme.columnMaxGap
        if available >= maxTotal {
            return Layout(cardWidth: Theme.cardMaxWidth, gap: Theme.columnMaxGap, scrollsHorizontally: false)
        }
        // Distribute the shortfall: gaps give way first, then cards.
        let gapRoom = (n - 1) * (Theme.columnMaxGap - Theme.columnMinGap)
        let shortfall = maxTotal - available
        if shortfall <= gapRoom {
            return Layout(cardWidth: Theme.cardMaxWidth, gap: Theme.columnMaxGap - shortfall / (n - 1), scrollsHorizontally: false)
        }
        let cardWidth = Theme.cardMaxWidth - (shortfall - gapRoom) / n
        return Layout(cardWidth: max(Theme.cardMinWidth, cardWidth), gap: Theme.columnMinGap, scrollsHorizontally: false)
    }

    // MARK: - Pieces

    private var header: some View {
        HStack(spacing: 8) {
            if editingName {
                TextField("Device name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .font(.title.weight(.bold))
                    .frame(maxWidth: 360)
                    .onSubmit { store.rename(device.id, to: draftName); editingName = false }
                    .onExitCommand { editingName = false }
            } else {
                Text(device.name).font(.title.weight(.bold)).lineLimit(1)
                Button { draftName = device.name; editingName = true } label: {
                    Image(systemName: "pencil").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rename device")
            }
            Spacer()
        }
        .padding(.horizontal, sidePadding).padding(.top, 16).padding(.bottom, 8)
    }

    private func columns(gap: CGFloat) -> some View {
        HStack(alignment: .top, spacing: gap) {
            column(title: "Sources", subtitle: device.sourcesSummary, trailing: { AddSourceMenu(device: device) }) {
                ForEach(device.sources) { s in
                    SourceCard(source: s, levels: levels[s.id] ?? [])
                }
            }
            column(title: "Output Channels", subtitle: "\(device.outputChannels.count) Channels", trailing: { AddChannelsButton() }) {
                ForEach(Array(stride(from: 0, to: device.outputChannels.count, by: 2)), id: \.self) { i in
                    ChannelCard(channels: Array(device.outputChannels[i..<min(i + 2, device.outputChannels.count)]), levels: levels)
                }
            }
            if store.showMonitors {
                column(title: "Monitors", subtitle: "\(device.monitors.count) Device\(device.monitors.count == 1 ? "" : "s")",
                       trailing: { AddMonitorMenu(device: device) }) {
                    ForEach(device.monitors) { m in
                        MonitorCard(monitor: m, levels: levels[m.id] ?? [])
                    }
                }
            }
        }
    }

    private func column<T: View, C: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> T, @ViewBuilder cards: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 32) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).font(.callout).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer()
                trailing()
            }
            .modifier(ColumnWidth())
            cards()
        }
    }

    private var selectedNodeName: String? {
        guard let id = wires.selectedNode else { return nil }
        if let s = device.sources.first(where: { $0.id == id }) { return s.kind.displayName }
        if let m = device.monitors.first(where: { $0.id == id }) { return m.name }
        if let c = device.outputChannels.first(where: { $0.id == id }) {
            let pair = device.outputChannels.filter { $0.index / 2 == c.index / 2 }
            return "Channels " + pair.map { "\($0.index + 1)" }.joined(separator: " & ")
        }
        return nil
    }

    private func deleteSelection() {
        if let w = wires.selectedWire {
            store.mutateSelected { $0.toggleWire(w) }
            wires.select(wire: nil)
        } else if let id = wires.selectedNode {
            store.mutateSelected { $0.remove(nodeID: id) }
            wires.select(node: nil)
        } else {
            confirmDelete = true
        }
    }

    private var footer: some View {
        HStack {
            Button(role: .destructive) { deleteSelection() } label: {
                Label(selectedNodeName.map { "Delete \($0)" } ?? (wires.selectedWire != nil ? "Delete Wire" : "Delete"), systemImage: "trash")
            }
            .confirmationDialog("Delete \"\(device.name)\"?", isPresented: $confirmDelete) {
                Button("Delete", role: .destructive) { store.deleteSelected() }
            } message: {
                Text("This removes the virtual device and all of its sources, channels and monitors.")
            }
            Spacer()
            Button { store.showMonitors.toggle() } label: {
                Label(store.showMonitors ? "Hide Monitors" : "Show Monitors", systemImage: store.showMonitors ? "eye.slash" : "eye")
            }
        }
        .padding(12)
    }
}

/// Column headers share the card width from the environment of the enclosing editor.
private struct ColumnWidth: ViewModifier {
    @Environment(\.cardWidth) private var cardWidth
    func body(content: Content) -> some View { content.frame(width: cardWidth) }
}
