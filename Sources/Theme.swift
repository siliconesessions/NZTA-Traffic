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
    /// Corner radius of panels floating over the map (see floatingPanel).
    static let floatingPanel: CGFloat = 14
}

extension Color {
    /// Hairline stroke drawn around content cards.
    static let cardStroke = Color.primary.opacity(0.10)
    /// The card stroke with Increase Contrast on (see CardBorder).
    static let cardStrokeIncreased = Color.primary.opacity(0.4)
    /// Badge tint for information with no status, such as a region.
    static let badgeNeutral = Color.gray

    // VMS "sign" card palette — an intentionally dark, roadside-sign look.
    static let vmsCardBackground = Color(red: 0.09, green: 0.13, blue: 0.18)
    static let vmsCardBorder = Color(red: 0.28, green: 0.34, blue: 0.42)
    static let vmsCardMessage = Color(red: 1.0, green: 0.74, blue: 0.18)

    // Road-event lifecycle tints. Impact colours (red closures, orange delays,
    // yellow caution) are kept for events in force now, so red always means
    // "closed now"; upcoming (Scheduled) and resolved events use these.
    static let eventUpcoming = Color.purple
    static let eventResolved = Color.gray
}

extension View {
    /// Liquid Glass behind a small panel floating over content — the map's
    /// layer controls, legend and status — so it matches the system map
    /// controls and the toolbar beside it. Group neighbouring panels in a
    /// GlassEffectContainer so their glass renders together.
    func floatingPanel(cornerRadius: CGFloat = Radii.floatingPanel) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
