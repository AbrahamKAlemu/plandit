import SwiftUI

// Plandit color tokens, from the Plandit Style Guide (October 2026).
// Emerald is the action color and black (ink) is structure. Most of any screen
// should be canvas, surface and ink, with emerald covering the least area.

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension ShapeStyle where Self == Color {
    /// Logo field, active states, large graphic moments, primary buttons (always with an ink label).
    static var emerald: Color { Color(hex: 0x0FA968) }
    /// Pressed state for emerald fills, darkened toward emerald-deep.
    static var emeraldPressed: Color { Color(hex: 0x0C9159) }
    /// Accessible green for links, small controls, selected labels, and buttons with white text.
    static var emeraldDeep: Color { Color(hex: 0x087A4B) }
    /// Pale emerald for selected tab items. Derived for the guide's "pale emerald treatment"; not a named token.
    static var emeraldTint: Color { Color(hex: 0xE4F5EC) }

    /// Primary text, navigation, route structure.
    static var ink: Color { Color(hex: 0x0E0F12) }
    /// Secondary copy, metadata, timestamps, distances.
    static var inkMuted: Color { Color(hex: 0x5D626B) }

    /// The guide's `background` token, renamed so it doesn't shadow SwiftUI's `.background`.
    static var canvas: Color { Color(hex: 0xF7F8FA) }
    /// Cards, sheets, inputs.
    static var surface: Color { .white }
    /// Dividers, input borders, card outlines, inactive controls.
    static var border: Color { Color(hex: 0xDDE2E8) }
    /// Errors, destructive actions and unavailable states only. Never decorative.
    static var error: Color { Color(hex: 0xC93434) }
}
