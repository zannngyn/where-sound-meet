import SwiftUI

enum Theme {
    static let teal = Color(red: 0x3D / 255, green: 0xBE / 255, blue: 0xB0 / 255)
    static let tealDark = Color(red: 0x2A / 255, green: 0x9D / 255, blue: 0x91 / 255)
    static let red = Color(red: 0xE5 / 255, green: 0x48 / 255, blue: 0x4D / 255)
    static let canvas = Color(red: 0xEC / 255, green: 0xEC / 255, blue: 0xEC / 255)
    static let sidebar = Color(red: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF5 / 255)
    static let card = Color.white
    static let cardHeader = Color(white: 0.97)
    static let cardBorder = Color(white: 0.82)
    static let cardRadius: CGFloat = 8
    static let meterTrack = Color(white: 0.85)
    static let wireGray = Color(white: 0.6)
    static let wireWidth: CGFloat = 2.5
    static let portDiameter: CGFloat = 10
    static let cardMaxWidth: CGFloat = 340
    static let cardMinWidth: CGFloat = 250
    static let columnMinGap: CGFloat = 70
    static let columnMaxGap: CGFloat = 220
    static let textSecondary = Color(white: 0.45)
}
