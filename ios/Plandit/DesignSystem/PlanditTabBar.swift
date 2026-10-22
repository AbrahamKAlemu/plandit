import SwiftUI

/// Bottom page selector, pinned inside the persistent sheet (like Find My on iOS 26).
/// Solid surface rather than glass: the style guide rules out glassmorphism.
struct PlanditTabBar: View {
    @Binding var selection: AppTab
    @Environment(\.isSheetCollapsed) private var isCollapsed

    var body: some View {
        HStack(spacing: Space.xxs) {
            ForEach(AppTab.allCases) { tab in
                let isSelected = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: Space.xxs) {
                        Icon(tab.icon, size: 22)
                        Text(tab.title).font(.manrope(.semiBold, size: 13))
                    }
                    .foregroundStyle(isSelected ? Color.emeraldDeep : Color.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(isSelected ? Color.emeraldTint : .clear, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
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
    }
}
