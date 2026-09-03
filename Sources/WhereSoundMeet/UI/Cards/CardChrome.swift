import WhereSoundMeetCore
import SwiftUI

private struct CardWidthKey: EnvironmentKey { static let defaultValue: CGFloat = Theme.cardMaxWidth }
extension EnvironmentValues {
    var cardWidth: CGFloat { get { self[CardWidthKey.self] } set { self[CardWidthKey.self] = newValue } }
}

/// Card frame: header with title + optional toggle, body, collapsible "Options" footer.
/// Click selects the node; right-click offers Remove; the footer Delete button / Delete key remove the selection.
struct CardChrome<Body: View, Options: View>: View {
    let nodeID: UUID
    let title: String
    var isOn: Binding<Bool>? = nil
    var volume: Binding<Float>? = nil
    var effects: Binding<EffectSettings>? = nil
    var offTint: Color = Color(white: 0.75)
    @ViewBuilder let content: () -> Body
    @ViewBuilder let options: () -> Options
    @State private var showOptions = false
    @Environment(\.cardWidth) private var cardWidth
    @Environment(WireEditorState.self) private var wires
    @Environment(AppStore.self) private var store

    private var selected: Bool { wires.selectedNode == nodeID }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                Spacer()
                if let effects { EffectsButton(effects: effects, sourceName: title) }
                if let isOn { OnOffToggle(isOn: isOn, offTint: offTint) }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Theme.cardHeader)
            Divider()
            content()
                .padding(12)
            if let volume {
                VolumeRow(volume: volume)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            DisclosureGroup(isExpanded: $showOptions) {
                options().padding(.top, 6)
            } label: {
                Text("Options").font(.callout)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .frame(width: cardWidth)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius)
            .stroke(selected ? Theme.teal : Theme.cardBorder, lineWidth: selected ? 2 : 1))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .opacity((isOn?.wrappedValue ?? true) ? 1 : 0.75)
        .contentShape(RoundedRectangle(cornerRadius: Theme.cardRadius))
        .onTapGesture { wires.select(node: selected ? nil : nodeID) }
        .contextMenu {
            if let isOn { Button(isOn.wrappedValue ? "Turn Off" : "Turn On") { isOn.wrappedValue.toggle() } }
            Button("Remove \(title)", role: .destructive) { remove() }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func remove() {
        if wires.selectedNode == nodeID { wires.select(node: nil) }
        store.mutateSelected { $0.remove(nodeID: nodeID) }
    }
}

/// Capsule toggle showing "On"/"Off" like the original Loopback app.
struct OnOffToggle: View {
    @Binding var isOn: Bool
    var offTint: Color = Color(white: 0.75)

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Theme.card : offTint)
                Capsule().stroke(isOn ? Theme.teal : offTint, lineWidth: 1.5)
                Text(isOn ? "On" : "Off")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isOn ? Theme.teal : .white)
                    .frame(maxWidth: .infinity, alignment: isOn ? .leading : .trailing)
                    .padding(.horizontal, 7)
                Circle().fill(.white).shadow(radius: 1)
                    .padding(2)
                    .frame(width: 22, height: 22)
            }
            .frame(width: 58, height: 22)
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .accessibilityLabel(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }
}

struct LevelMeter: View {
    let level: Float
    /// nil = fill the available width
    var width: CGFloat? = nil
    var height: CGFloat = 10

    var body: some View {
        let v = CGFloat(min(1, max(0, level)).squareRoot())
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.meterTrack)
                RoundedRectangle(cornerRadius: 2).fill(Theme.teal).frame(width: max(0, geo.size.width * v))
                HStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Spacer()
                        Rectangle().fill(Theme.card).frame(width: 1.5)
                    }
                }
            }
        }
        .frame(width: width, height: height)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .accessibilityHidden(true)
    }
}

/// Connection dot. Dragging from an output port starts a wire.
struct PortDot: View {
    let key: PortKey
    @Environment(WireEditorState.self) private var wires
    @Environment(AppStore.self) private var store

    var body: some View {
        let active = wires.hoverTarget == key || wires.dragFrom == key
        Circle()
            .fill(active ? Theme.teal : Color(white: 0.85))
            .overlay(Circle().stroke(Color(white: 0.5), lineWidth: 1))
            .frame(width: Theme.portDiameter, height: Theme.portDiameter)
            .contentShape(Circle().scale(2))
            .background(GeometryReader { geo in
                Color.clear.preference(key: PortPositions.self,
                                       value: [key: CGPoint(x: geo.frame(in: .named("editor")).midX,
                                                            y: geo.frame(in: .named("editor")).midY)])
            })
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named("editor"))
                    .onChanged { g in
                        wires.dragFrom = key
                        wires.dragPoint = g.location
                        wires.hoverTarget = wires.target(near: g.location, from: key)
                    }
                    .onEnded { g in
                        defer { wires.dragFrom = nil; wires.hoverTarget = nil }
                        guard let target = wires.target(near: g.location, from: key) else { return }
                        let (from, to) = key.side == .output ? (key, target) : (target, key)
                        let wire = Wire(from: from.endpoint, to: to.endpoint)
                        store.mutateSelected { $0.toggleWire(wire) }
                    }
            )
            .accessibilityLabel(key.side == .output ? "Output port" : "Input port")
    }
}

struct SourceIconView: View {
    let kind: SourceKind
    var size: CGFloat = 64

    var body: some View {
        switch kind {
        case .app(let bundleID, _):
            if let icon = AudioSystem.appIcon(bundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: size, height: size)
            } else {
                Image(systemName: "app.fill").resizable().frame(width: size, height: size).foregroundStyle(.secondary)
            }
        case .inputDevice:
            ZStack {
                Circle().fill(Color(white: 0.55))
                Image(systemName: "mic.fill").font(.system(size: size * 0.5)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        case .passThru:
            ZStack {
                Circle().fill(Theme.red)
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(.white)
            }
            .frame(width: size, height: size)
        }
    }
}

struct RemoveButton: View {
    let action: () -> Void
    var body: some View {
        Button(role: .destructive, action: action) { Label("Remove", systemImage: "trash") }
            .buttonStyle(.bordered)
    }
}

struct VolumeRow: View {
    @Binding var volume: Float
    var body: some View {
        HStack {
            Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
            Slider(value: Binding(get: { Double(volume) }, set: { volume = Float($0) }), in: 0...1).tint(Theme.teal)
                .accessibilityLabel("Volume")
            Text("\(Int(volume * 100))%").font(.callout).monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }
}
