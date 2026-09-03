import WhereSoundMeetCore
import SwiftUI

enum PortSide: Hashable { case input, output }

struct PortKey: Hashable {
    let endpoint: Endpoint
    let side: PortSide
}

/// Center points of every port dot in the "editor" coordinate space.
struct PortPositions: PreferenceKey {
    static let defaultValue: [PortKey: CGPoint] = [:]
    static func reduce(value: inout [PortKey: CGPoint], nextValue: () -> [PortKey: CGPoint]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

/// Shared drag/selection state for the wire layer and the port dots.
@Observable
@MainActor
final class WireEditorState {
    var ports: [PortKey: CGPoint] = [:]
    var dragFrom: PortKey?
    var dragPoint: CGPoint = .zero
    var hoverTarget: PortKey?
    var selectedWire: Wire?
    var selectedNode: UUID?

    func select(node: UUID?) { selectedNode = node; selectedWire = nil }
    func select(wire: Wire?) { selectedWire = wire; selectedNode = nil }

    /// Nearest port on the opposite side within `radius` points.
    func target(near p: CGPoint, from: PortKey, radius: CGFloat = 18) -> PortKey? {
        let side: PortSide = from.side == .output ? .input : .output
        var best: (PortKey, CGFloat)?
        for (k, pos) in ports where k.side == side {
            let d = hypot(pos.x - p.x, pos.y - p.y)
            if d <= radius, best == nil || d < best!.1 { best = (k, d) }
        }
        return best?.0
    }
}
