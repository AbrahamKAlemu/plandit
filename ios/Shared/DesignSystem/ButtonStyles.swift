import SwiftUI

/// Emerald fill with an ink label. Reserve it for the one action that matters most in a view.
struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(.semiBold, size: 16))
            .foregroundStyle(isEnabled ? Color.ink : Color.inkMuted)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, Space.md)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func fill(isPressed: Bool) -> Color {
        if !isEnabled { return .border }
        return isPressed ? .emeraldPressed : .emerald
    }
}

/// Transparent with a 1px ink border.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.manrope(.semiBold, size: 16))
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, Space.md)
            .background(configuration.isPressed ? Color.canvas : Color.surface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.ink, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var primary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}
