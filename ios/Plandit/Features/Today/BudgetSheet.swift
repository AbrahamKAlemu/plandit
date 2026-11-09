import SwiftUI

/// Where today's money goes: each stop, getting around, and anything else the user adds.
/// Every line can be changed, and the budget itself too.
struct BudgetSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var extras: [CostItem] = []
    @State private var didLoad = false
    @State private var editingStop: StopRef?

    var body: some View {
        let plan = store.today
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    header(plan)
                    stops(plan)
                    travel(plan)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        SectionTitle("Other costs")
                        Text("Anything that isn't one stop, like snacks or the subway home.")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                        CostItemsEditor(items: $extras, addTitle: "Add a cost", placeholder: "Snacks, subway home…")
                    }
                    Text("Prices are per person and are estimates. Change any of them to match what you'll spend.")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
                .padding(Space.lg)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                // The total stays in sight while editing further down.
                VStack(spacing: 0) {
                    Hairline()
                    BudgetLine(plan: plan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Space.lg)
                        .padding(.vertical, Space.sm)
                }
                .background(Color.surface)
            }
            .background(Color.surface)
            .navigationTitle("Budget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .keyboardDoneButton()
        }
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            extras = store.today.extras
        }
        .onChange(of: extras) { _, new in
            let counted = new.filter { $0.amount > 0 }
            if counted != store.today.extras { store.setExtras(counted) }
        }
        .sheet(item: $editingStop) { StopCostSheet(stopID: $0.id) }
    }

    private func header(_ plan: DayPlan) -> some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(plan.totalCost.wholeDollarsText) of \(plan.budget.wholeDollarsText)")
                    .font(.pageHeading)
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("budget-total")
                Text(plan.remainingText)
                    .font(.label)
                    .foregroundStyle(plan.remaining < 0 ? Color.error : Color.emeraldDeep)
            }
            BudgetBar(spent: plan.totalCost, budget: plan.budget)
            HStack {
                Label { Text("Budget").font(.bodyText) } icon: { Icon(.wallet, size: 18) }
                    .foregroundStyle(.ink)
                Spacer()
                Text(plan.budget.wholeDollarsText)
                    .font(.manrope(.bold, size: 17))
                    .foregroundStyle(.ink)
                    .contentTransition(.numericText())
                    .accessibilityIdentifier("day-budget-value")
                Stepper("Budget", value: Binding(get: { plan.budget }, set: { store.setBudget($0) }), in: 0...500, step: 5)
                    .labelsHidden()
            }
            .frame(minHeight: 48)
            .planditCard(padding: Space.sm)
        }
    }

    private func stops(_ plan: DayPlan) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                SectionTitle("Stops")
                Spacer()
                Text(plan.stopsCost.dollarsText).font(.label).foregroundStyle(.ink)
            }
            VStack(spacing: 0) {
                ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
                    Button {
                        editingStop = StopRef(id: stop.id)
                    } label: {
                        HStack(spacing: Space.sm) {
                            StopBadge(number: index + 1, status: stop.status, size: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.place.name).font(.bodyText).foregroundStyle(.ink).lineLimit(1)
                                Text(costSource(stop)).font(.metadata).foregroundStyle(.inkMuted).lineLimit(1)
                            }
                            Spacer(minLength: Space.xs)
                            Text(stop.estimatedCost.dollarsText).font(.manrope(.bold, size: 16)).foregroundStyle(.ink)
                            Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityHint("Change this stop's cost")
                    .accessibilityIdentifier("budget-stop-\(index + 1)")
                    if index < plan.stops.count - 1 { Hairline() }
                }
            }
            .planditCard(padding: Space.sm)
        }
    }

    @ViewBuilder private func travel(_ plan: DayPlan) -> some View {
        let transit = plan.legs.filter(\.mode.isTransit)
        let drives = plan.legs.filter { $0.mode == .drive }
        let walks = plan.legs.filter { $0.mode == .walk }
        if !plan.legs.isEmpty {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle("Getting around")
                    Spacer()
                    Text(plan.travelCost.dollarsText).font(.label).foregroundStyle(.ink)
                }
                VStack(alignment: .leading, spacing: Space.sm) {
                    if !walks.isEmpty {
                        travelRow(.footprints, "\(count(walks.count, "walk", "walks")) · \(plan.walkingMiles.milesText)", "Free")
                    }
                    if !transit.isEmpty {
                        travelRow(.trainFront, Self.transitText(transit), plan.faresCost.dollarsText)
                    }
                    if !drives.isEmpty {
                        travelRow(.car, count(drives.count, "drive", "drives"), "about \(plan.ridesCost.wholeDollarsText)")
                    }
                    Text("Change how you get between stops by tapping a trip on Today.")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }
                .planditCard()
            }
        }
    }

    private func travelRow(_ icon: Lucide, _ title: String, _ cost: String) -> some View {
        HStack(spacing: Space.sm) {
            Icon(icon, size: 18).foregroundStyle(.ink)
            Text(title).font(.bodyText).foregroundStyle(.ink)
            Spacer()
            Text(cost).font(.manrope(.bold, size: 16)).foregroundStyle(.ink)
        }
        .accessibilityElement(children: .combine)
    }

    private func count(_ n: Int, _ one: String, _ many: String) -> String {
        n == 1 ? "1 \(one)" : "\(n) \(many)"
    }

    private func costSource(_ stop: PlanStop) -> String {
        if !stop.costItems.isEmpty {
            return stop.costItems.count == 1 ? "1 item you added" : "\(stop.costItems.count) items you added"
        }
        if stop.costIsCustom || store.post(id: stop.sourcePostID)?.userCost != nil { return "Your estimate" }
        return Self.costSource(stop.estimatedCost, guide: store.priceGuide(for: stop))
    }

    /// Never a range that disagrees with the number next to it: "$15–30 · Typical for food in NYC"
    /// only when the stop's cost is inside it, otherwise "Less than the usual $15–30".
    static func costSource(_ cost: Double, guide: PriceGuide) -> String {
        // The post's price is already on the right.
        if guide.low == guide.high { return guide.sourceText }
        if cost < guide.low { return "Less than the usual \(guide.rangeText)" }
        if cost > guide.high { return "More than the usual \(guide.rangeText)" }
        return "\(guide.rangeText) · \(guide.sourceText)"
    }

    /// "2 subway rides", "1 bus ride", "2 rides: 1 subway, 1 bus".
    static func transitText(_ legs: [TravelLeg]) -> String {
        let subway = legs.filter { $0.mode == .subway }.count
        let bus = legs.filter { $0.mode == .bus }.count
        switch (subway, bus) {
        case (_, 0): return subway == 1 ? "1 subway ride" : "\(subway) subway rides"
        case (0, _): return bus == 1 ? "1 bus ride" : "\(bus) bus rides"
        default: return "\(subway + bus) rides: \(subway) subway, \(bus) bus"
        }
    }
}

struct StopRef: Identifiable, Hashable {
    let id: UUID
}

/// Spent against budget. Emerald under, error red over; the text above says the same thing.
private struct BudgetBar: View {
    let spent: Double
    let budget: Double

    var body: some View {
        GeometryReader { geometry in
            let fraction = budget > 0 ? min(spent / budget, 1) : (spent > 0 ? 1 : 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.border)
                Capsule()
                    .fill(spent > budget ? Color.error : Color.emerald)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 8)
        .animation(.snappy(duration: 0.3), value: spent)
        .accessibilityHidden(true)
    }
}
