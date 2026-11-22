import SwiftUI

/// "Plan a day", opened from the + in the tab bar. Pick saved places, set a start time and budget,
/// and see the day the planner builds before you commit to it.
struct PlanBuilderSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(SheetRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    /// Picked post ids, in the order they were picked.
    @State private var picked: [UUID] = []
    @State private var mode: PlanditStore.PlanMode = .replace
    @State private var start = PlanDefaults.start()
    @State private var budget: Double = 60
    /// "Free until": off means the day can run late.
    @State private var hasEnd = false
    @State private var end = PlanDefaults.start().addingTimeInterval(4 * 3600)
    @State private var didSetUp = false
    @State private var built = 0

    var body: some View {
        NavigationStack {
            Group {
                if store.plannablePosts.isEmpty {
                    EmptyState(
                        icon: .bookmark,
                        title: "Save a few places first",
                        message: "Share TikToks or Reels to Plandit, then come back here to plan your day."
                    ) {
                        Button {
                            router.isPlanning = false
                            router.show(.saved)
                        } label: {
                            HStack(spacing: Space.xs) {
                                Icon(.bookmark, size: 18)
                                Text("Go to Saved")
                            }
                        }
                        .buttonStyle(.secondary)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.xl)
                } else {
                    form
                }
            }
            .background(Color.surface)
            .navigationTitle("Plan a day")
            .navigationBarTitleDisplayMode(.inline)
            .solidSheetHeader()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .sensoryFeedback(.success, trigger: built)
        .onAppear(perform: setUp)
    }

    // MARK: - Form

    private var form: some View {
        let outcome = store.previewPlan(postIDs: picked, start: start, budget: budget, mode: mode, end: hasEnd ? end : nil)
        return VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    Text("Pick the saved places you want to get to. Plandit puts them in an order that makes sense, on time and on budget.")
                        .font(.bodyText)
                        .foregroundStyle(.inkMuted)

                    if store.canAskFriends { askFriendsRow }
                    if hasPlan { modePicker }
                    placesSection
                    timeAndBudget
                    PlanPreview(outcome: outcome, lockedCount: lockedCount, spent: spent(outcome), budget: budget, end: hasEnd ? end : nil)
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.3), value: picked)
                .animation(.snappy(duration: 0.3), value: mode)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Hairline()
                Button(mode == .add && hasPlan ? "Update today's plan" : "Build my plan") { build() }
                    .buttonStyle(.primary)
                    .disabled(outcome.stops.isEmpty)
                    .accessibilityIdentifier("build-plan")
                    .padding(.horizontal, Space.lg)
                    .padding(.vertical, Space.sm)
            }
            .background(Color.surface)
        }
    }

    /// Group plans, mode 2: a link friends answer, then a plan from their answers.
    private var askFriendsRow: some View {
        NavigationLink {
            AskFriendsView()
        } label: {
            ListRow(icon: .users, title: "Ask friends what works",
                    detail: store.activeRequest() == nil
                        ? "Send a link. Friends say when they're free, what they'll spend and their picks."
                        : "See their answers and build your plan.")
        }
        .buttonStyle(.plain)
        .planditCard(padding: 0)
        .accessibilityIdentifier("ask-friends")
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: Space.xs) {
                Chip(title: "Add to today", isSelected: mode == .add) { mode = .add }
                Chip(title: "Start over", isSelected: mode == .replace) { mode = .replace }
            }
            Text(mode == .add
                 ? "Keeps what you've already done and fits your picks into the rest of the day."
                 : "Clears today's plan and plans only what you pick here.")
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
    }

    private var placesSection: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Places")
                Spacer()
                Text(pickedSummary).font(.metadata).foregroundStyle(.inkMuted)
            }
            ForEach(store.plannablePosts) { post in
                let isLocked = mode == .add && store.isInToday(post)
                PickRow(post: post, isPicked: isLocked || picked.contains(post.id), isLocked: isLocked) {
                    toggle(post.id)
                }
                Hairline()
            }
        }
    }

    private var timeAndBudget: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("When and how much")
            VStack(spacing: 0) {
                HStack {
                    Label { Text("Start").font(.bodyText) } icon: { Icon(.clock, size: 18) }
                        .foregroundStyle(.ink)
                    Spacer()
                    if let anchor {
                        Text("After \(anchor.place.name), \(anchor.end.shortTime)")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .multilineTextAlignment(.trailing)
                    } else {
                        DatePicker("Start time", selection: $start, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                    }
                }
                .frame(minHeight: 48)
                Hairline()
                HStack {
                    Toggle(isOn: $hasEnd.animation(.snappy)) {
                        Label { Text("Free until").font(.bodyText) } icon: { Icon(.calendarDays, size: 18) }
                            .foregroundStyle(.ink)
                    }
                    .tint(.emerald)
                    .accessibilityIdentifier("free-until-toggle")
                    .onChange(of: hasEnd) { _, isOn in
                        if isOn { end = (anchor?.end ?? start).addingTimeInterval(3 * 3600) }
                    }
                    if hasEnd {
                        DatePicker("End time", selection: $end, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .accessibilityIdentifier("free-until-time")
                            .transition(.opacity)
                    }
                }
                .frame(minHeight: 48)
                Hairline()
                HStack {
                    Label { Text("Budget").font(.bodyText) } icon: { Icon(.wallet, size: 18) }
                        .foregroundStyle(.ink)
                    Spacer()
                    Text(budget.wholeDollarsText)
                        .font(.manrope(.bold, size: 17))
                        .foregroundStyle(.ink)
                        .contentTransition(.numericText())
                        .accessibilityIdentifier("budget-value")
                    Stepper("Budget", value: $budget.animation(.snappy), in: 0...300, step: 5)
                        .labelsHidden()
                }
                .frame(minHeight: 48)
            }
            .planditCard(padding: Space.sm)
        }
    }

    // MARK: - State

    private var hasPlan: Bool { !store.today.stops.isEmpty }
    private var lockedCount: Int { mode == .add ? store.lockedStops.count : 0 }
    private var anchor: PlanStop? { mode == .add ? store.lockedStops.last : nil }

    private var pickedSummary: String {
        let inPlan = mode == .add ? store.today.stops.count - lockedCount : 0
        return inPlan > 0 ? "\(picked.count) new · \(inPlan) in plan" : "\(picked.count) picked"
    }

    private func spent(_ outcome: DayPlanner.Outcome) -> Double {
        (mode == .add ? store.lockedCost : 0) + outcome.cost + store.today.extras.total
    }

    private func setUp() {
        guard !didSetUp else { return }
        didSetUp = true
        budget = store.today.budget
        mode = hasPlan ? .add : .replace
        // "Change it" on a suggested plan: its places in its order, at its start time and budget.
        if let draft = router.takePendingDraft() {
            let plannable = Set(store.plannablePosts.map(\.id))
            picked = draft.picks.filter(plannable.contains)
            if let draftStart = draft.start { start = draftStart }
            if let draftBudget = draft.budget { budget = draftBudget }
            mode = .replace
        }
    }

    private func toggle(_ id: UUID) {
        if let index = picked.firstIndex(of: id) {
            picked.remove(at: index)
        } else {
            picked.append(id)
        }
    }

    private func build() {
        withAnimation(.snappy(duration: 0.35)) {
            _ = store.buildPlan(postIDs: picked, start: start, budget: budget, mode: mode, end: hasEnd ? end : nil)
        }
        built += 1
        router.finishPlanning()
    }
}

// MARK: - Rows

/// A saved place to pick, here and in "Ask friends what works".
struct PickRow: View {
    let post: SavedPost
    let isPicked: Bool
    let isLocked: Bool
    /// The rows' accessibility identifiers start with this, then the post's title.
    var idPrefix = "pick"
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Space.sm) {
                SavedThumbnail(post: post, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.title)
                        .font(.manrope(.bold, size: 16))
                        .foregroundStyle(.ink)
                        .lineLimit(1)
                    if let place = post.place {
                        Text([place.category.label, place.neighborhood, priceText].compactMap { $0 }.joined(separator: " · "))
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .lineLimit(1)
                    }
                    Text(post.savedWhenText())
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .lineLimit(1)
                }
                Spacer(minLength: Space.xs)
                if isLocked {
                    Text("In plan").font(.label).foregroundStyle(.emeraldDeep)
                } else {
                    Checkbox(isOn: isPicked)
                }
            }
            .padding(.vertical, Space.xxs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("\(idPrefix)-\(post.title)")
    }
}

extension PickRow {
    /// The user's price, the post's, or the usual range: "$8", "Free", "$15–30".
    var priceText: String? {
        if let userCost = post.userCost { return userCost.dollarsText }
        return post.postedPrice?.rangeText
    }
}

/// Selected is an ink fill, the same as a selected chip.
struct Checkbox: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(isOn ? Color.ink : Color.surface)
            Circle().strokeBorder(isOn ? Color.ink : Color.border, lineWidth: 1.5)
            if isOn {
                Icon(.check, size: 16).foregroundStyle(Color.onInk)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 28, height: 28)
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}

// MARK: - Preview

/// The day the planner would build, so nothing about it is a surprise.
struct PlanPreview: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let outcome: DayPlanner.Outcome
    let lockedCount: Int
    let spent: Double
    let budget: Double
    let end: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            SectionTitle("Your day")
            if outcome.stops.isEmpty && outcome.skipped.isEmpty {
                Text("Pick at least one place to see your day.")
                    .font(.bodyText)
                    .foregroundStyle(.inkMuted)
            } else {
                VStack(alignment: .leading, spacing: Space.sm) {
                    if let first = outcome.stops.first, let end = outcome.end {
                        Text("\(first.start.shortTime) to \(end.shortTime)")
                            .font(.cardHeading)
                            .foregroundStyle(.ink)
                        // One row when it fits, two on narrow phones.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Space.md) { summaryLabels }
                            VStack(alignment: .leading, spacing: Space.xxs) { summaryLabels }
                        }
                        .accessibilityIdentifier("preview-summary")
                    }
                    if lockedCount > 0 {
                        Text(lockedCount == 1 ? "Keeps the stop you're already at." : "Keeps the \(lockedCount) stops you've already done.")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                    }
                    ForEach(Array(outcome.stops.enumerated()), id: \.element.id) { index, stop in
                        HStack(spacing: Space.sm) {
                            StopBadge(number: lockedCount + index + 1, status: .upcoming, size: 24)
                            // One line at standard sizes; at accessibility sizes the whole name shows.
                            Text(stop.place.name).font(.bodyText).foregroundStyle(.ink)
                                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                                .fixedSize(horizontal: false, vertical: typeSize.isAccessibilitySize)
                            Spacer(minLength: Space.xs)
                            Text(stop.start.shortTime).font(.metadata).foregroundStyle(.inkMuted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("preview-stop-\(index + 1)")
                    }
                    ForEach(outcome.skipped, id: \.candidate.id) { skip in
                        HStack(alignment: .top, spacing: Space.xs) {
                            Icon(.circleAlert, size: 16).padding(.top, 2)
                            Text(message(for: skip)).font(.metadata)
                        }
                        .foregroundStyle(.ink)
                        .accessibilityElement(children: .combine)
                    }
                }
                .planditCard()
            }
        }
    }

    @ViewBuilder private var summaryLabels: some View {
        MetaLabel(.wallet, "\(spent.wholeDollarsText) of \(budget.wholeDollarsText)")
        if outcome.walkingMiles > 0.05 {
            MetaLabel(.footprints, "\(outcome.walkingMiles.milesText) walking")
        }
        if let rides = Self.subwayRidesText(outcome.legs) {
            MetaLabel(.trainFront, rides)
        }
    }

    /// "1 subway ride", "2 subway rides", or nil for an all-walking day.
    static func subwayRidesText(_ legs: [TravelLeg]) -> String? {
        let rides = legs.filter(\.mode.isTransit).count
        return rides == 0 ? nil : (rides == 1 ? "1 subway ride" : "\(rides) subway rides")
    }

    private func message(for skip: DayPlanner.Skip) -> String {
        let name = skip.candidate.place.name
        switch skip.reason {
        case .closed:
            if let close = skip.candidate.place.closingTime(on: outcome.stops.first?.start ?? .now) {
                return "Left out \(name): it closes at \(close.shortTime)."
            }
            return "Left out \(name): it's closed by then."
        case .overBudget:
            return "Left out \(name) to stay under \(budget.wholeDollarsText)."
        case .outOfTime:
            if let end { return "Left out \(name): it doesn't fit before \(end.shortTime)." }
            return "Left out \(name): it doesn't fit before the day ends."
        case .eveningOnly:
            return "Left out \(name): it's an evening spot, and your day ends before then."
        }
    }
}
