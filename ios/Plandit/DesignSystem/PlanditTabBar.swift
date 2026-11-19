import SwiftUI

/// Bottom page selector, an island floating at the foot of the persistent sheet (like Find My on
/// iOS 26): the sheet's content scrolls on underneath it. Solid surface with a border and a soft
/// shadow rather than glass: the style guide rules out glassmorphism.
/// The selected pill slides between tabs instead of jumping.
/// Today, Saved, Plan, Profile (D-2). Plan looks like the tabs but opens the planner: it's an action,
/// not a tab, so it's never selected.
/// Like the system tab bar, text stops growing at the largest standard size; at accessibility
/// sizes a long press on an item shows its large version. Labels shrink rather than clip or wrap.
struct PlanditTabBar: View {
    @Binding var selection: AppTab
    var onPlan: () -> Void = {}
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
                        Text(tab.title)
                            .font(.manrope(.semiBold, size: 13))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
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
                .accessibilityShowsLargeContentViewer {
                    Label(tab.title, image: "Icons/\(tab.icon.rawValue)")
                }
            }
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.surface)
                .floatingShadow()
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.border))
        .padding(.horizontal, Space.md)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xxs)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tab-bar")
    }
}


/// The planner action, drawn like the tabs (icon over label, ink) so the bar reads as one row.
/// It's an action, not a tab, so it never shows the selected pill.
private struct PlanButton: View {
    let action: () -> Void
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(spacing: Space.xxs) {
                Icon(.plus, size: 22)
                Text("Plan")
                    .font(.manrope(.semiBold, size: 13))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundStyle(Color.ink)
            .frame(maxWidth: .infinity, minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Plan a day")
        .accessibilityIdentifier("plan-button")
        .accessibilityShowsLargeContentViewer {
            Label("Plan a day", image: "Icons/\(Lucide.plus.rawValue)")
        }
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}
