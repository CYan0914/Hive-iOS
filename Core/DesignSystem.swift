import SwiftUI

enum Theme {
    static let background = Color(red: 0.06, green: 0.06, blue: 0.08)
    static let surface = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let surfaceHigh = Color(red: 0.19, green: 0.19, blue: 0.23)
    static let accent = Color(red: 0.98, green: 0.72, blue: 0.25)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.62)
    static let danger = Color(red: 0.95, green: 0.38, blue: 0.38)
    static let success = Color(red: 0.42, green: 0.85, blue: 0.55)
    static let border = Color(white: 0.24)
}

extension View {
    func hiveCard() -> some View {
        self
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
