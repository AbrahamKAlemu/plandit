import SwiftUI

/// The Plandit day: summary, next action, and the ordered stops.
/// Doubles as the text equivalent of the map, which the accessibility floors require.
struct TodaySheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    /// Your own plan, or the group plan picked in the switcher.
    @TodayContext private var today
    @State private var membersShown: StopRef?
    @State private var isAddingLink = false
    @State private var isShowingBudget = false
    @State private var isEditingPlan = false
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var isSendingPlan = false
    @State private var isShowingAnswers = false
    /// Goes up each time "Use this plan" makes a plan: the same success haptic as building one.
    @State private var suggestionsUsed = 0

    var body: some View {
        let plan = today.plan
        let group = today.group
        let controls = today.controls
        VStack(spacing: 0) {
            SheetHeader(title: "Today", subtitle: plan.date.longDay) {
                if let group {
                    GroupMembersButton(group: group) { membersShown = StopRef(id: group.id) }
                        .transition(.opacity)
                } else if !plan.stops.isEmpty && controls.sendPlan {
                    Button { isSendingPlan = true } label: {
                        CircleIconLabel(icon: .share)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send the plan")
                    .transition(.scale.combined(with: .opacity))
                }
            }

            let options = today.options
            if options.count > 1 || group != nil {
                VStack(alignment: .leading, spacing: Space.xs) {
                    if options.count > 1 {
                        TodaySwitcher(options: options, selection: today.choice) { choice in
                            withAnimation(.snappy(duration: 0.3)) { today.select(choice) }
                        }
                    }
                    if let group {
                        GroupStatusLine(group: group)
                    }
                }
                .padding(.horizontal, Space.lg)
                .padding(.bottom, Space.xs)
                .hiddenWhenSheetCollapsed()
            }

            if let group, plan.stops.isEmpty {
                GroupEmptyToday(group: group)
                    .hiddenWhenSheetCollapsed()
                    .frame(maxHeight: .infinity, alignment: .top)
                    .transition(.opacity)
            } else if plan.stops.isEmpty {
                Group {
                    if store.suggestions.isEmpty {
                        // Sized to the space above the tab bar rather than scrolled, so the next step is
                        // never cut off at half height: the icon goes first when the sheet is short. The
                        // screen reserves the floating bars' height (clearsFloatingBars), so this space ends
                        // where they begin.
                        ViewThatFits(in: .vertical) {
                            emptyToday(showsIcon: true)
                            emptyToday(showsIcon: false)
                            ScrollView { emptyToday(showsIcon: false) }
                                .scrollIndicators(.hidden)
                        }
                        .frame(maxHeight: .infinity, alignment: .top)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("empty-today")
                    } else {
                        suggestedPlans
                    }
                }
                .hiddenWhenSheetCollapsed()
                .transition(.opacity)
                // Suggestions follow the clock: the start time moves and places close (SP-8). Between
                // 15-minute slots this does nothing, so the cards don't reshuffle while being read.
                .task {
                    while !Task.isCancelled {
                        store.refreshSuggestions()
                        try? await Task.sleep(for: .seconds(30))
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.lg) {
                        PlanSummary(plan: plan, isGroup: group != nil, showBudget: controls.budgetAndExtras ? { isShowingBudget = true } : nil)

                        // One clock for the card and the Directions button: no directions to a stop the card says you missed.
                        TimelineView(.everyMinute) { _ in
                            let overdue = plan.overdueStops(now: AppClock.now)
                            VStack(alignment: .leading, spacing: Space.lg) {
                                if !overdue.isEmpty {
                                    CatchUpCard(plan: plan, overdue: overdue, now: AppClock.now, canEdit: controls.editing)
                                        .transition(.opacity)
                                } else if plan.isComplete {
                                    DayCompleteCard(plan: plan)
                                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                                } else if let next = plan.nextStop {
                                    Button {
                                        next.place.openDirections(by: today.travelMode(into: next.id))
                                    } label: {
                                        HStack(spacing: Space.xs) {
                                            Icon(today.travelMode(into: next.id).icon, size: 18)
                                            // One line at standard sizes; at accessibility sizes the place name wraps
                                            // instead of being cut off.
                                            Text("Directions to \(next.place.name)")
                                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                                .multilineTextAlignment(.center)
                                        }
                                        .padding(.vertical, typeSize.isAccessibilitySize ? Space.xs : 0)
                                    }
                                    .buttonStyle(.primary)
                                    .transition(.opacity)
                                }
                            }
                        }

                        if plan.stops.count > plan.firstMovableIndex && controls.editing {
                            HStack {
                                SectionTitle("Stops")
                                Spacer()
                                Button { isEditingPlan = true } label: {
                                    HStack(spacing: Space.xxs) {
                                        Icon(.arrowUpDown, size: 16)
                                        Text("Edit")
                                    }
                                    .outlinedControl()
                                }
                                .buttonStyle(.plain)
                                .accessibilityHint("Reorder or remove stops")
                                .accessibilityIdentifier("edit-plan")
                            }
                        }
                        PlanTimeline(plan: plan)

                        if controls.sendPlan {
                            Button { isSendingPlan = true } label: {
                                HStack(spacing: Space.xs) {
                                    Icon(.share, size: 18)
                                    Text("Share plan with friends")
                                }
                            }
                            .buttonStyle(.secondary)
                            .accessibilityIdentifier("send-plan")
                        }

                        if controls.startGroup {
                            StartGroupButton()
                        }

                        if controls.shareAnswers, let summary = store.answerSummary {
                            AnswerSummaryButton(summary: summary) { isShowingAnswers = true }
                                .transition(.opacity)
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
                .transition(.opacity)
                // Friends' answers on the shared plan: on appearing, and when the link changes (GV-5).
                .task(id: store.todayLink?.slug) { await store.refreshShareAnswers() }
            }
        }
        .animation(.snappy(duration: 0.35), value: plan.stops.isEmpty)
        .animation(.snappy(duration: 0.35), value: store.suggestions.map(\.id))
        .sensoryFeedback(.success, trigger: suggestionsUsed)
        .background(Color.surface)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $isShowingBudget) { BudgetSheet() }
        .sheet(isPresented: $isEditingPlan) { EditPlanSheet() }
        .sheet(isPresented: $isSendingPlan) { SendPlanSheet() }
        .sheet(isPresented: $isShowingAnswers) { ShareAnswersSheet() }
        .sheet(item: $membersShown) { GroupMembersSheet(groupID: $0.id) }
        .sheet(isPresented: $isAddingLink) {
            AddLinkSheet { id in
                // Same landing as from Saved: watch the new post get mapped.
                router.showPost(id)
            }
        }
    }

    /// Nothing planned, with plans made from the saves: the cards, then "Plan a day" for picking
    /// places yourself (SP-13).
    private var suggestedPlans: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.md) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    SectionTitle(SuggestionText.heading)
                    if let notice = store.suggestionNotice {
                        suggestionNotice(notice)
                    }
                }
                ForEach(Array(store.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    SuggestionCard(suggestion: suggestion, index: index) {
                        use(suggestion)
                    } change: {
                        // The planner opens on the card's places, start time and budget (SP-12).
                        router.startPlanning(changing: suggestion, budget: store.profile.defaultBudget)
                    }
                    .transition(.opacity)
                }
                planADayButton
            }
            .padding(.horizontal, Space.lg)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.lg)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("today-suggestions")
    }

    /// "It's later now, so these plans changed."
    private func suggestionNotice(_ text: String) -> some View {
        Text(text)
            .font(.metadata)
            .foregroundStyle(.inkMuted)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("suggestions-changed")
    }

    private func use(_ suggestion: PlanSuggestion) {
        var result = PlanditStore.UseResult.stale
        withAnimation(.snappy(duration: 0.35)) {
            result = store.useSuggestion(suggestion)
        }
        switch result {
        case .applied:
            suggestionsUsed += 1
        case .stale:
            AccessibilityNotification.Announcement(PlanditStore.suggestionsChangedMessage).post()
        }
    }

    private var planADayButton: some View {
        Button {
            router.startPlanning()
        } label: {
            HStack(spacing: Space.xs) {
                Icon(.plus, size: 18)
                Text("Plan a day")
            }
        }
        .buttonStyle(.secondary)
        .accessibilityIdentifier("today-plan-a-day")
    }

    /// Nothing planned: paste a link when nothing is saved yet (the first step is a place, not a
    /// plan), otherwise plan a day from what's saved.
    @ViewBuilder private func emptyToday(showsIcon: Bool) -> some View {
        VStack(spacing: 0) {
            // A tapped card had gone stale and nothing replaced it.
            if let notice = store.suggestionNotice {
                suggestionNotice(notice)
                    .multilineTextAlignment(.center)
                    .padding(.top, Space.xs)
            }
            emptyTodayContent(showsIcon: showsIcon)
        }
    }

    @ViewBuilder private func emptyTodayContent(showsIcon: Bool) -> some View {
        Group {
            if store.saved.isEmpty {
                EmptyState(
                    icon: .route,
                    title: "Nothing planned yet",
                    message: "Add a place first. Share a TikTok or Reel to Plandit, or paste a link.",
                    isCompact: true,
                    showsIcon: showsIcon
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
            } else {
                EmptyState(
                    icon: .route,
                    title: "Nothing planned yet",
                    message: "Tap + to turn your saved places into today's plan.",
                    isCompact: true,
                    showsIcon: showsIcon
                ) {
                    planADayButton
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.sm)
    }
}

/// "3 in · 1 can't make it" under the share button; opens who answered.
private struct AnswerSummaryButton: View {
    let summary: ShareAnswerSummary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Icon(.users, size: 18).foregroundStyle(.ink)
                Text(summary.text)
                    .font(.label)
                    .foregroundStyle(.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .planditCard(padding: Space.sm)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityText)
        .accessibilityHint("Shows who answered")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("answers-summary")
    }
}

private struct PlanSummary: View {
    let plan: DayPlan
    /// A group plan: its stops came from everyone's saves, and its budget isn't edited here.
    var isGroup = false
    /// Nil when the budget can't be changed (a group plan).
    let showBudget: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title).font(.cardHeading).foregroundStyle(.ink)
                Text(stopsLine)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .contentTransition(.numericText())
            }

            // Side by side when every value fits on one line at full size; otherwise one under the
            // other, so nothing is cut off. Always stacked from XXL text up.
            Group {
                if typeSize >= .xxLarge {
                    stacked
                } else {
                    ViewThatFits(in: .horizontal) {
                        sideBySide
                        stacked
                    }
                }
            }
            .padding(.vertical, Space.sm)
            .planditCard(padding: 0)
        }
    }

    @Environment(\.dynamicTypeSize) private var typeSize

    private var sideBySide: some View {
        HStack(alignment: .top, spacing: 0) { metrics(isStacked: false) }
            .fixedSize(horizontal: false, vertical: true)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: Space.sm) { metrics(isStacked: true) }
    }

    @ViewBuilder private func metrics(isStacked: Bool) -> some View {
        SummaryMetric(icon: .clock, value: plan.stops.first?.start.shortTime ?? "–", caption: endCaption, isStacked: isStacked)
            .accessibilityIdentifier("time-metric")
        divider(isStacked: isStacked)
        if let showBudget {
            Button(action: showBudget) {
                SummaryMetric(icon: .wallet, value: plan.totalCost.wholeDollarsText, caption: budgetCaption, showsChevron: true, isStacked: isStacked)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows where the money goes and lets you change it")
            .accessibilityIdentifier("budget-metric")
        } else {
            SummaryMetric(icon: .wallet, value: plan.totalCost.wholeDollarsText, caption: budgetCaption, isStacked: isStacked)
                .accessibilityIdentifier("budget-metric-fixed")
        }
        if let travel = TodaySummaryText.travel(plan) {
            divider(isStacked: isStacked)
            SummaryMetric(icon: travel.icon, value: travel.value, caption: travel.caption,
                          accessibilityLabel: travel.accessibilityLabel, isStacked: isStacked)
                .accessibilityIdentifier("travel-metric")
        }
    }

    private func divider(isStacked: Bool) -> some View {
        Rectangle().fill(Color.border).frame(width: isStacked ? nil : 1, height: isStacked ? 1 : nil)
    }

    private var stopsLine: String {
        let stops = plan.stops.count == 1 ? "1 stop" : "\(plan.stops.count) stops"
        return plan.savedPostCount > 0 && !isGroup ? "\(stops) · \(plan.savedPostCount) from your saved posts" : stops
    }

    private var endCaption: String {
        plan.stops.last.map { "Ends \($0.end.shortTime)" } ?? ""
    }

    private var budgetCaption: String {
        let budget = plan.budget.wholeDollarsText
        return plan.totalCost <= plan.budget ? "of \(budget) budget" : "Over \(budget) budget"
    }
}

/// How Today's summary describes getting around: miles walked when the day has any walking that
/// rounds to more than nothing, otherwise its rides by kind, so a subway day never reads
/// "0.0 mi Walking". Like the other tiles, a short value over a caption: "2" over "subway rides",
/// "2 rides" over "1 subway, 1 bus". A day with no trips (one stop) has nothing to say.
enum TodaySummaryText {
    struct Travel: Equatable {
        var icon: Lucide
        var value: String
        var caption: String
        /// What VoiceOver reads: "2 subway rides", "2.3 miles walking".
        var accessibilityLabel: String
    }

    static func travel(_ plan: DayPlan) -> Travel? {
        guard !plan.legs.isEmpty else { return nil }
        let walks = plan.legs.filter { $0.mode == .walk }
        let miles = plan.walkingMiles.milesText
        if !walks.isEmpty, miles != 0.0.milesText {
            return Travel(icon: .footprints, value: miles, caption: "Walking", accessibilityLabel: spokenMiles(plan.walkingMiles) + " walking")
        }
        if let rides = rides(plan.legs.filter { $0.mode != .walk }) { return rides }
        // Only short walks: count them rather than say "0.0 mi".
        return Travel(icon: .footprints, value: "\(walks.count)", caption: RideWording.noun(.walk, count: walks.count),
                      accessibilityLabel: RideWording.count(walks.count, .walk))
    }

    /// "All done for today" line: "2.1 mi walked", "2 subway rides" or "1 subway, 1 bus". Nil with no trips.
    static func completedTravel(_ plan: DayPlan) -> String? {
        guard let travel = travel(plan) else { return nil }
        if travel.caption == "Walking" { return "\(travel.value) walked" }
        return travel.value.hasSuffix("rides") ? travel.caption : "\(travel.value) \(travel.caption)"
    }

    /// Nil when there are no rides.
    private static func rides(_ legs: [TravelLeg]) -> Travel? {
        let counted = RideWording.counts(legs)
        // The icon follows the most common kind; ties go to the subway, then the bus.
        guard let most = counted.max(by: { $0.count < $1.count }) else { return nil }
        guard counted.count == 1 else {
            let kinds = RideWording.kinds(legs)
            return Travel(icon: most.mode.icon, value: "\(legs.count) rides", caption: kinds,
                          accessibilityLabel: "\(legs.count) rides: \(kinds)")
        }
        return Travel(icon: most.mode.icon, value: "\(most.count)", caption: RideWording.noun(most.mode, count: most.count),
                      accessibilityLabel: RideWording.count(most.count, most.mode))
    }

    /// "2.3 miles", "1 mile": words for VoiceOver rather than "mi".
    private static func spokenMiles(_ miles: Double) -> String {
        let number = miles.formatted(.number.precision(.fractionLength(1)))
        return number == 1.0.formatted(.number.precision(.fractionLength(1))) ? "1 mile" : "\(number) miles"
    }
}

private struct SummaryMetric: View {
    let icon: Lucide
    let value: String
    let caption: String
    var showsChevron = false
    /// What VoiceOver reads instead of the value and caption run together.
    var accessibilityLabel: String?
    /// One under the other, full width. Side by side, the value keeps its full size on one line
    /// (the summary stacks the tiles when that doesn't fit) and the caption wraps under it.
    var isStacked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Icon(icon, size: 16).foregroundStyle(.ink)
                Text(value)
                    .font(.manrope(.bold, size: 17))
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .fixedSize(horizontal: !isStacked, vertical: false)
                if showsChevron {
                    Icon(.chevronRight, size: 14).foregroundStyle(.inkMuted)
                }
            }
            // A longer caption ("1 subway, 1 bus") wraps rather than being cut off. Its ideal width
            // is zero so only the values decide whether the tiles fit side by side.
            Text(caption)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .frame(minWidth: 0, idealWidth: isStacked ? nil : 0, maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.sm)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabel ?? "\(value), \(caption)"))
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
                Text(summary)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .planditCard()
        .accessibilityElement(children: .combine)
    }

    /// "6 stops · $42 · 2.3 mi walked", or "1 stop · $9" when there were no trips.
    private var summary: String {
        let stops = plan.stops.count == 1 ? "1 stop" : "\(plan.stops.count) stops"
        return [stops, plan.totalCost.wholeDollarsText, TodaySummaryText.completedTravel(plan)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }
}

/// Asks when the clock has passed stops that aren't marked done: did you go, or are you running behind?
/// Without it, a day nobody updated shows afternoon stops as still ahead at night.
private struct CatchUpCard: View {
    let plan: DayPlan
    let overdue: [PlanStop]
    let now: Date
    /// False for a group plan that can't be changed: the card only says what happened.
    var canEdit = true
    @TodayContext private var today

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
            if canEdit {
                HStack(spacing: Space.sm) {
                    Button(onlyUnderway ? "Done here" : (overdue.count == 1 ? "Mark it done" : "Mark them done")) {
                        withAnimation(.snappy) { today.markOverdueDone() }
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("catchup-done")
                    if isToday {
                        Button(onlyUnderway ? "Still here" : "Start from now") {
                            withAnimation(.snappy) { today.startRestFromNow() }
                        }
                        .buttonStyle(.secondary)
                        .accessibilityIdentifier("catchup-later")
                    }
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
