import SwiftUI

// Centralized design tokens. Replacing scattered literals with these keeps
// spacing, corner radii, and the VMS sign palette consistent across the app
// and adjustable in one place.

enum Spacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radii {
    /// Corner radius shared by cards and badges.
    static let card: CGFloat = 8
}

extension Color {
    /// Hairline stroke drawn around content cards.
    static let cardStroke = Color.primary.opacity(0.10)

    // VMS "sign" card palette — an intentionally dark, roadside-sign look.
    static let vmsCardBackground = Color(red: 0.09, green: 0.13, blue: 0.18)
    static let vmsCardBorder = Color(red: 0.28, green: 0.34, blue: 0.42)
    static let vmsCardMessage = Color(red: 1.0, green: 0.74, blue: 0.18)
}
