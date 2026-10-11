import CoreGraphics

/// Spacing scale from the style guide: 4, 8, 12, 16, 24, 32, 48, 64, 80.
enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
    static let xxxl: CGFloat = 64
}

enum Radius {
    /// Buttons and inputs.
    static let control: CGFloat = 12
    /// Cards and panels.
    static let card: CGFloat = 16
    /// Large sheets only.
    static let sheet: CGFloat = 24
}
