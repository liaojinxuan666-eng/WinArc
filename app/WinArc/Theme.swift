import SwiftUI

enum WinArcTheme {
    static let background = Color(red: 0.025, green: 0.035, blue: 0.055)
    static let panel = Color.white.opacity(0.075)
    static let stroke = Color.white.opacity(0.12)
    static let secondary = Color.white.opacity(0.62)
}

extension View {
    func winArcGlass(radius: CGFloat = 24) -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(WinArcTheme.stroke, lineWidth: 1)
            )
    }
}
