import WhereSoundMeetCore
import SwiftUI

/// Draws wires between port dots and handles selection / deletion.
struct WireLayer: View {
    let device: VirtualDevice
    @Environment(WireEditorState.self) private var state
    @Environment(AppStore.self) private var store

    var body: some View {
        Canvas { ctx, _ in
            for wire in device.wires {
                guard let a = state.ports[PortKey(endpoint: wire.from, side: .output)],
                      let b = state.ports[PortKey(endpoint: wire.to, side: .input)] else { continue }
                let isMonitor = device.monitors.contains { $0.id == wire.to.nodeID }
                let selected = state.selectedWire == wire
                let color = isMonitor ? Theme.wireGray : Theme.teal
                ctx.stroke(Self.path(a, b), with: .color(selected ? Theme.tealDark : color),
                           style: StrokeStyle(lineWidth: selected ? Theme.wireWidth + 1.5 : Theme.wireWidth, lineCap: .round))
            }
            if let from = state.dragFrom, let a = state.ports[from] {
                let b = state.hoverTarget.flatMap { state.ports[$0] } ?? state.dragPoint
                let path = from.side == .output ? Self.path(a, b) : Self.path(b, a)
                ctx.stroke(path, with: .color(Theme.teal.opacity(0.7)),
                           style: StrokeStyle(lineWidth: Theme.wireWidth, lineCap: .round, dash: [6, 4]))
            }
        }
        .contentShape(WireHitShape(paths: wirePaths()))
        .onTapGesture(count: 2) { p in
            if let w = hit(p) { store.mutateSelected { $0.toggleWire(w) }; state.selectedWire = nil }
        }
        .onTapGesture { p in state.selectedWire = hit(p) }
        .accessibilityHidden(true)
    }

    private func wirePaths() -> [Path] {
        device.wires.compactMap { wire in
            guard let a = state.ports[PortKey(endpoint: wire.from, side: .output)],
                  let b = state.ports[PortKey(endpoint: wire.to, side: .input)] else { return nil }
            return Self.path(a, b)
        }
    }

    private func hit(_ p: CGPoint) -> Wire? {
        var best: (Wire, CGFloat)?
        for wire in device.wires {
            guard let a = state.ports[PortKey(endpoint: wire.from, side: .output)],
                  let b = state.ports[PortKey(endpoint: wire.to, side: .input)] else { continue }
            let d = Self.distance(from: p, to: a, b)
            if d <= 7, best == nil || d < best!.1 { best = (wire, d) }
        }
        return best?.0
    }

    static func path(_ a: CGPoint, _ b: CGPoint) -> Path {
        let dx = max(60, abs(b.x - a.x) * 0.5)
        var p = Path()
        p.move(to: a)
        p.addCurve(to: b, control1: CGPoint(x: a.x + dx, y: a.y), control2: CGPoint(x: b.x - dx, y: b.y))
        return p
    }

    static func distance(from p: CGPoint, to a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = max(60, abs(b.x - a.x) * 0.5)
        let c1 = CGPoint(x: a.x + dx, y: a.y), c2 = CGPoint(x: b.x - dx, y: b.y)
        var best = CGFloat.infinity
        for i in 0...48 {
            let t = CGFloat(i) / 48, u = 1 - t
            let x = u*u*u*a.x + 3*u*u*t*c1.x + 3*u*t*t*c2.x + t*t*t*b.x
            let y = u*u*u*a.y + 3*u*u*t*c1.y + 3*u*t*t*c2.y + t*t*t*b.y
            best = min(best, hypot(x - p.x, y - p.y))
        }
        return best
    }
}

/// Hit area limited to a thick stroke around each wire so clicks elsewhere reach the cards.
struct WireHitShape: Shape {
    let paths: [Path]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for path in paths { p.addPath(path.strokedPath(StrokeStyle(lineWidth: 14, lineCap: .round))) }
        return p
    }
}
