import SwiftUI

/// The Plandit day: summary, next action, and the ordered stops.
/// Doubles as the text equivalent of the map, which the accessibility floors require.
struct TodaySheet: View {
    @Environment(PlanditStore.self) private var store

    var body: some View {
        let plan = store.today
        VStack(spacing: 0) {
            SheetHeader(title: "Today", subtitle: plan.date.longDay) {
                ShareLink(item: plan.shareText) {
                    CircleIconLabel(icon: .share)
                }
                .accessibilityLabel("Share the plan")
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    PlanSummary(plan: plan)

                    if let next = plan.nextStop {
                        Button {
                            next.place.openDirections()
                        } label: {
                            HStack(spacing: Space.xs) {
                                Icon(.navigation, size: 18)
                                Text("Directions to \(next.place.name)").lineLimit(1)
                            }
                        }
                        .buttonStyle(.primary)
                    }

                    PlanTimeline(plan: plan)
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
            }
            .scrollIndicators(.hidden)
            .hiddenWhenSheetCollapsed()
        }
        .background(Color.surface)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct PlanSummary: View {
    let plan: DayPlan

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.cardHeading).foregroundStyle(.ink)
                Text("\(plan.stops.count) stops · \(plan.savedPostCount) from your saved posts")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }

            HStack(spacing: 0) {
                SummaryMetric(icon: .clock, value: plan.stops.first?.start.shortTime ?? "–", caption: endCaption)
                Rectangle().fill(Color.border).frame(width: 1)
                SummaryMetric(icon: .wallet, value: plan.totalCost.wholeDollarsText, caption: budgetCaption)
                Rectangle().fill(Color.border).frame(width: 1)
                SummaryMetric(icon: .footprints, value: plan.walkingMiles.milesText, caption: "Walking")
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.sm)
            .planditCard(padding: 0)
        }
    }

    private var endCaption: String {
        plan.stops.last.map { "Ends \($0.end.shortTime)" } ?? ""
    }

    private var budgetCaption: String {
        let budget = plan.budget.wholeDollarsText
        return plan.totalCost <= plan.budget ? "of \(budget) budget" : "Over \(budget) budget"
    }
}

private struct SummaryMetric: View {
    let icon: Lucide
    let value: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Icon(icon, size: 16).foregroundStyle(.ink)
                Text(value)
                    .font(.manrope(.bold, size: 17))
                    .foregroundStyle(.ink)
            }
            Text(caption)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sm)
        .accessibilityElement(children: .combine)
    }
}
