import SwiftUI

/// The Plandit day: summary, next action, and the ordered stops.
/// Doubles as the text equivalent of the map, which the accessibility floors require.
struct TodaySheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router

    var body: some View {
        let plan = store.today
        VStack(spacing: 0) {
            SheetHeader(title: "Today", subtitle: plan.date.longDay) {
                if !plan.stops.isEmpty {
                    ShareLink(item: plan.shareText) {
                        CircleIconLabel(icon: .share)
                    }
                    .accessibilityLabel("Share the plan")
                    .transition(.scale.combined(with: .opacity))
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    if plan.stops.isEmpty {
                        EmptyState(
                            icon: .route,
                            title: "Nothing planned yet",
                            message: "Tap + to turn your saved places into today's plan."
                        ) {
                            Button {
                                router.startPlanning()
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Icon(.plus, size: 18)
                                    Text("Plan a day")
                                }
                            }
                            .buttonStyle(.secondary)
                        }
                        .padding(.top, Space.md)
                        .transition(.opacity)
                    } else {
                        PlanSummary(plan: plan)

                        if plan.isComplete {
                            DayCompleteCard(plan: plan)
                                .transition(.scale(scale: 0.96).combined(with: .opacity))
                        } else if let next = plan.nextStop {
                            Button {
                                next.place.openDirections()
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Icon(.navigation, size: 18)
                                    Text("Directions to \(next.place.name)").lineLimit(1)
                                }
                            }
                            .buttonStyle(.primary)
                            .transition(.opacity)
                        }

                        PlanTimeline(plan: plan)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.top, Space.xs)
                .padding(.bottom, Space.lg)
                .animation(.snappy(duration: 0.35), value: plan.stops.map(\.id))
                .animation(.snappy(duration: 0.35), value: plan.stops.map(\.status))
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
                Text(stopsLine)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .contentTransition(.numericText())
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

    private var stopsLine: String {
        let stops = plan.stops.count == 1 ? "1 stop" : "\(plan.stops.count) stops"
        return plan.savedPostCount > 0 ? "\(stops) · \(plan.savedPostCount) from your saved posts" : stops
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
                    .contentTransition(.numericText())
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

/// Shown once every stop is done.
private struct DayCompleteCard: View {
    let plan: DayPlan

    var body: some View {
        HStack(spacing: Space.sm) {
            Icon(.circleCheck, size: 22)
                .foregroundStyle(.onEmerald)
                .frame(width: 40, height: 40)
                .background(Color.emerald, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("All done for today").font(.cardHeading).foregroundStyle(.ink)
                Text("\(plan.stops.count) stops · \(plan.totalCost.wholeDollarsText) · \(plan.walkingMiles.milesText) walked")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .planditCard()
        .accessibilityElement(children: .combine)
    }
}
