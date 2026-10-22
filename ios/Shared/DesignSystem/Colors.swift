import SwiftUI
import UIKit

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

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension ShapeStyle where Self == Color {
    /// Logo field, active states, large graphic moments, primary buttons (always with an ink label).
    static var emerald: Color { Color(hex: 0x0FA968) }
    /// Pressed state for emerald fills, darkened toward emerald-deep.
    static var emeraldPressed: Color { Color(hex: 0x0C9159) }
    /// Accessible green for links, small controls, selected labels, and buttons with white text.
    static var emeraldDeep: Color { Color(light: 0x087A4B, dark: 0x0FA968) }
    /// Pale emerald for selected tab items. Derived for the guide's "pale emerald treatment"; not a named token.
    static var emeraldTint: Color { Color(light: 0xE4F5EC, dark: 0x0B2B1D) }

    /// Primary text, navigation, route structure.
    static var ink: Color { Color(light: 0x0E0F12, dark: 0xF7F8FA) }
    /// Secondary copy, metadata, timestamps, distances.
    static var inkMuted: Color { Color(light: 0x5D626B, dark: 0xAEB4BE) }

    /// The guide's `background` token, renamed so it doesn't shadow SwiftUI's `.background`.
    static var canvas: Color { Color(light: 0xF7F8FA, dark: 0x0E0F12) }
    /// Cards, sheets, inputs.
    static var surface: Color { Color(light: 0xFFFFFF, dark: 0x17191D) }
    /// Dividers, input borders, card outlines, inactive controls.
    static var border: Color { Color(light: 0xDDE2E8, dark: 0x34383F) }
    /// Errors, destructive actions and unavailable states only. Never decorative.
    static var error: Color { Color(light: 0xC93434, dark: 0xFF7474) }

    /// Fixed label color for emerald fills.
    static var onEmerald: Color { Color(hex: 0x0E0F12) }
    /// Foreground paired with adaptive `ink` fills.
    static var onInk: Color { Color(light: 0xFFFFFF, dark: 0x0E0F12) }
    /// Fixed black structure for map pins, where a white halo supplies contrast.
    static var mapPinInk: Color { Color(hex: 0x0E0F12) }
}
