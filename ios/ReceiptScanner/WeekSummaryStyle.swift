import SwiftUI

/// Colors from index.html's :root and .rate-* styles.
enum WebStyle {
    static let surface = Color(hex: 0x141416)
    static let surface2 = Color(hex: 0x1C1C20)
    static let border = Color(hex: 0x2A2A30)
    static let muted = Color(hex: 0x5A5850)
    static let dim = Color(hex: 0x8A8880)
    static let accent = Color(hex: 0xC4F54A)
    static let total = Color(hex: 0xE8A050)
    static let daily = Color(hex: 0xC08040)
    static let green = Color(hex: 0x6CC070)
    static let red = Color(hex: 0xF05454)
    static let accentDim = Color(hex: 0x8AAC34)
    static let bar = Color(hex: 0xE8C840)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}
