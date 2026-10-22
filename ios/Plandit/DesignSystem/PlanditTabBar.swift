import SwiftUI

/// Bottom page selector, pinned inside the persistent sheet (like Find My on iOS 26).
/// Solid surface rather than glass: the style guide rules out glassmorphism.
/// The selected pill slides between tabs instead of jumping.
/// The emerald + (like TikTok's create button) opens "Plan a day"; it's an action, not a tab.
struct PlanditTabBar: View {
    @Binding var selection: AppTab
    var onPlan: () -> Void = {}
    @Environment(\.isSheetCollapsed) private var isCollapsed
    @Namespace private var pill

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(AppTab.allCases) { tab in
                if tab == .profile {
                    PlanButton(action: onPlan)
                }
                let isSelected = tab == selection
                Button {
                    withAnimation(.snappy(duration: 0.3)) { selection = tab }
                } label: {
                    VStack(spacing: Space.xxs) {
                        Icon(tab.icon, size: 22)
                        Text(tab.title).font(.manrope(.semiBold, size: 13))
                    }
                    .foregroundStyle(isSelected ? Color.emeraldDeep : Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                                .fill(Color.emeraldTint)
                                .matchedGeometryEffect(id: "selected-tab", in: pill)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.border))
        .padding(.horizontal, Space.md)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xxs)
        .background(Color.surface)
        // Clean edge where scrolling content meets the bar; not needed when only the header shows.
        .overlay(alignment: .top) {
            if !isCollapsed { Hairline() }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}


/// The + in the tab bar: emerald fill with an ink glyph, the one primary action on every screen.
private struct PlanButton: View {
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Icon(.plus, size: 26)
                .foregroundStyle(Color.onEmerald)
                .frame(width: 60, height: 52)
                .background(Color.emerald, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(PlanButtonStyle())
        .padding(.horizontal, Space.xxs)
        .accessibilityLabel("Plan a day")
        .accessibilityIdentifier("plan-button")
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

private struct PlanButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.snappy(duration: 0.2), value: configuration.isPressed)
    }
}
