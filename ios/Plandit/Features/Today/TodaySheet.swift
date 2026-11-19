import SwiftUI

/// The Plandit day: summary, next action, and the ordered stops.
/// Doubles as the text equivalent of the map, which the accessibility floors require.
struct TodaySheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    @State private var isAddingLink = false
    @State private var isShowingBudget = false
    @State private var isEditingPlan = false

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
                    if plan.stops.isEmpty, store.saved.isEmpty {
                        // Nothing to plan from yet: the first step is a place, not a plan.
                        EmptyState(
                            icon: .route,
                            title: "Nothing planned yet",
                            message: "Add a place first. Share a TikTok or Reel to Plandit, or paste a link.",
                            isCompact: true
                        ) {
                            Button {
                                isAddingLink = true
                            } label: {
                                HStack(spacing: Space.xs) {
                                    Icon(.clipboardPaste, size: 18)
                                    Text("Paste a link")
                                }
                            }
                            .buttonStyle(.secondary)
                            .accessibilityIdentifier("today-paste-link")
                        }
                        .transition(.opacity)
                    } else if plan.stops.isEmpty {
                        EmptyState(
                            icon: .route,
                            title: "Nothing planned yet",
                            message: "Tap + to turn your saved places into today's plan.",
                            isCompact: true
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
                        .transition(.opacity)
                    } else {
                        PlanSummary(plan: plan) { isShowingBudget = true }

                        // One clock for the card and the Directions button: no directions to a stop the card says you missed.
                        TimelineView(.everyMinute) { _ in
                            let overdue = plan.overdueStops(now: AppClock.now)
                            VStack(alignment: .leading, spacing: Space.lg) {
                                if !overdue.isEmpty {
                                    CatchUpCard(plan: plan, overdue: overdue, now: AppClock.now)
                                        .transition(.opacity)
                                } else if plan.isComplete {
                                    DayCompleteCard(plan: plan)
                                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                                } else if let next = plan.nextStop {
                                    Button {
                                        next.place.openDirections(by: store.travelMode(into: next.id))
                                    } label: {
                                        HStack(spacing: Space.xs) {
                                            Icon(store.travelMode(into: next.id).icon, size: 18)
                                            Text("Directions to \(next.place.name)").lineLimit(1)
                                        }
                                    }
                                    .buttonStyle(.primary)
                                    .transition(.opacity)
                                }
                            }
                        }

                        if plan.stops.count > plan.firstMovableIndex {
                            HStack {
                                SectionTitle("Stops")
                                Spacer()
                                Button { isEditingPlan = true } label: {
                                    HStack(spacing: Space.xxs) {
                                        Icon(.arrowUpDown, size: 16)
                                        Text("Edit")
                                    }
                                    .font(.label)
                                    .foregroundStyle(.ink)
                                    .frame(minHeight: 44)
                                    .contentShape(Rectangle())
                                }
                                .accessibilityHint("Reorder or remove stops")
                                .accessibilityIdentifier("edit-plan")
                            }
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
        .sheet(isPresented: $isShowingBudget) { BudgetSheet() }
        .sheet(isPresented: $isEditingPlan) { EditPlanSheet() }
        .sheet(isPresented: $isAddingLink) {
            AddLinkSheet { id in
                // Same landing as from Saved: watch the new post get mapped.
                router.showPost(id)
            }
        }
    }
}

private struct PlanSummary: View {
    let plan: DayPlan
    let showBudget: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.cardHeading).foregroundStyle(.ink)
                Text(stopsLine)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .contentTransition(.numericText())
            }

            // Side by side, or one under the other from XXL text up, so nothing is cut off.
            let layout = isStacked
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.sm))
                : AnyLayout(HStackLayout(alignment: .top, spacing: 0))
            layout {
                SummaryMetric(icon: .clock, value: plan.stops.first?.start.shortTime ?? "–", caption: endCaption, isStacked: isStacked)
                divider
                Button(action: showBudget) {
                    SummaryMetric(icon: .wallet, value: plan.totalCost.wholeDollarsText, caption: budgetCaption, showsChevron: true, isStacked: isStacked)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Shows where the money goes and lets you change it")
                .accessibilityIdentifier("budget-metric")
                divider
                let travel = TodaySummaryText.travel(plan)
                SummaryMetric(icon: travel.icon, value: travel.value, caption: travel.caption, isStacked: isStacked)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, Space.sm)
            .planditCard(padding: 0)
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var isStacked: Bool { typeSize >= .xxLarge }

    private var divider: some View {
        Rectangle().fill(Color.border).frame(width: isStacked ? nil : 1, height: isStacked ? 1 : nil)
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

/// How Today's summary describes getting around: miles walked when the day has any walking,
/// otherwise its rides by kind, so a subway day never reads "0.0 mi Walking". Like the other
/// tiles, a short value over a caption: "2" over "subway rides", "2 rides" over "1 subway, 1 bus".
enum TodaySummaryText {
    struct Travel: Equatable {
        var icon: Lucide
        var value: String
        var caption: String
    }

    static func travel(_ plan: DayPlan) -> Travel {
        guard let rides = rides(plan.legs) else {
            return Travel(icon: .footprints, value: plan.walkingMiles.milesText, caption: "Walking")
        }
        return rides
    }

    /// "All done for today" line: "2.1 mi walked", "2 subway rides" or "1 subway, 1 bus".
    static func completedTravel(_ plan: DayPlan) -> String {
        guard let rides = rides(plan.legs) else { return "\(plan.walkingMiles.milesText) walked" }
        return rides.value.hasSuffix("rides") ? rides.caption : "\(rides.value) \(rides.caption)"
    }

    /// Nil when any trip is a walk, or there are no trips.
    private static func rides(_ legs: [TravelLeg]) -> Travel? {
        guard !legs.isEmpty, !legs.contains(where: { $0.mode == .walk }) else { return nil }
        let counted = RideWording.counts(legs)
        // The icon follows the most common kind; ties go to the subway, then the bus.
        guard let most = counted.max(by: { $0.count < $1.count }) else { return nil }
        guard counted.count == 1 else {
            return Travel(icon: most.mode.icon, value: "\(legs.count) rides", caption: RideWording.kinds(legs))
        }
        return Travel(icon: most.mode.icon, value: "\(most.count)", caption: RideWording.noun(most.mode, count: most.count))
    }
}

private struct SummaryMetric: View {
    let icon: Lucide
    let value: String
    let caption: String
    var showsChevron = false
    /// One under the other, full width: nothing has to shrink or fit on one line.
    var isStacked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Icon(icon, size: 16).foregroundStyle(.ink)
                Text(value)
                    .font(.manrope(.bold, size: 17))
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .lineLimit(isStacked ? nil : 1)
                    .minimumScaleFactor(isStacked ? 1 : 0.8)
                if showsChevron {
                    Icon(.chevronRight, size: 14).foregroundStyle(.inkMuted)
                }
            }
            // A longer caption ("1 subway, 1 bus") takes a second line rather than being cut off.
            Text(caption)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .lineLimit(isStacked ? nil : 2)
        }
        .fixedSize(horizontal: false, vertical: true)
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
                Text("\(plan.stops.count) stops · \(plan.totalCost.wholeDollarsText) · \(TodaySummaryText.completedTravel(plan))")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .planditCard()
        .accessibilityElement(children: .combine)
    }
}

/// Asks when the clock has passed stops that aren't marked done: did you go, or are you running behind?
/// Without it, a day nobody updated shows afternoon stops as still ahead at night.
private struct CatchUpCard: View {
    let plan: DayPlan
    let overdue: [PlanStop]
    let now: Date
    @Environment(PlanditStore.self) private var store

    var body: some View {
        card(overdue, now: now)
    }

    private func card(_ overdue: [PlanStop], now: Date) -> some View {
        let onlyUnderway = overdue.count == 1 && overdue[0].status == .now
        let isToday = Calendar.current.isDate(plan.date, inSameDayAs: now)
        return VStack(alignment: .leading, spacing: Space.sm) {
            HStack(alignment: .top, spacing: Space.sm) {
                Icon(.clock, size: 20).foregroundStyle(.ink)
                VStack(alignment: .leading, spacing: 2) {
                    Text(onlyUnderway ? "Still at \(overdue[0].place.name)?" : "Running behind?")
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    Text(Self.message(overdue, now: now, onlyUnderway: onlyUnderway, isToday: isToday))
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    if isToday {
                        ForEach(Self.laterLines(plan, now: now), id: \.self) { line in
                            Text(line.text)
                                .font(.metadata)
                                .foregroundStyle(line.isWarning ? Color.error : Color.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: Space.sm) {
                Button(onlyUnderway ? "Done here" : (overdue.count == 1 ? "Mark it done" : "Mark them done")) {
                    withAnimation(.snappy) { store.markOverdueDone() }
                }
                .buttonStyle(.secondary)
                .accessibilityIdentifier("catchup-done")
                if isToday {
                    Button(onlyUnderway ? "Still here" : "Start from now") {
                        withAnimation(.snappy) { store.startRestFromNow() }
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("catchup-later")
                }
            }
        }
        .planditCard()
    }

    struct Line: Hashable {
        var text: String
        var isWarning = false
    }

    /// What "Start from now" / "Still here" would do: where the day ends, and any place you'd reach after it closes.
    static func laterLines(_ plan: DayPlan, now: Date) -> [Line] {
        var moved = plan
        moved.startRestFromNow(now: now)
        guard let end = moved.stops.last?.end, end != plan.stops.last?.end else { return [] }
        var lines = [Line(text: "Moving the rest later ends your day at \(end.shortTime).")]
        let alreadyLate = Set(plan.stopsArrivingAfterClose().map(\.id))
        let late = moved.stopsArrivingAfterClose().filter { !alreadyLate.contains($0.id) }.map(\.place.name)
        if !late.isEmpty {
            lines.append(Line(text: "You'd get to \(late.formatted(.list(type: .and))) after closing.", isWarning: true))
        }
        return lines
    }

    /// "It's 7:48 PM, past the times planned for The High Line, Los Tacos No. 1 and 2 more."
    static func message(_ overdue: [PlanStop], now: Date, onlyUnderway: Bool, isToday: Bool) -> String {
        if onlyUnderway {
            return "It's \(now.shortTime). It was planned until \(overdue[0].end.shortTime). \"Still here\" moves the rest of the day later."
        }
        let names = overdue.map(\.place.name)
        let listed = names.count <= 3 ? names : Array(names.prefix(2)) + ["\(names.count - 2) more"]
        let past = "past the times planned for \(listed.formatted(.list(type: .and)))"
        guard isToday else { return "This day is over, \(past)." }
        let them = overdue.count == 1 ? "it" : "them"
        return "It's \(now.shortTime), \(past). Mark \(them) done if you went, or start \(them) from now."
    }
}
