// Millfolio design tokens — mirrors web/src/app.css (:root). A calm, private,
// "veil + lens" palette. These will move to ../../shared once formalized.

import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

enum Theme {
    static let bg = Color(hex: 0x0E1116)
    static let surface = Color(hex: 0x161B22)
    static let surface2 = Color(hex: 0x1C232D)
    static let border = Color(hex: 0x2A323D)
    static let text = Color(hex: 0xE6EDF3)
    static let textDim = Color(hex: 0x9AA7B4)
    static let accent = Color(hex: 0x6EA8FE)       // lens blue
    static let accentDim = Color(hex: 0x334455)
    static let ok = Color(hex: 0x3FB950)
    static let warn = Color(hex: 0xD29922)
    static let err = Color(hex: 0xF85149)

    static let radius: CGFloat = 10
    static let onAccent = Color(hex: 0x06101F)
    static let onOk = Color(hex: 0x06120A)
}
