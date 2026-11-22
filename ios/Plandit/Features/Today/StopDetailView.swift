import SwiftUI

struct StopDetailView: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    /// Keeps editing the plan it opened on.
    @TodayContext(pinned: true) private var today
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingCost = false
    @State private var isEditingTime = false
    @State private var choosingLeg: StopRef?

    var body: some View {
        if let stop = today.stop(id: stopID), let number = today.stopNumber(id: stopID) {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.lg) {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        HStack(spacing: Space.xs) {
                            StopBadge(number: number, status: stop.status, size: 32)
                            StopStatusTag(status: stop.status)
                                .transition(.scale.combined(with: .opacity))
                        }
                        Text(stop.place.name).font(.pageHeading).foregroundStyle(.ink)
                        Text("\(stop.place.category.label) · \(stop.place.neighborhood)")
                            .font(.bodyText)
                            .foregroundStyle(.inkMuted)
                    }

                    StatusPicker(stop: stop)

                    VStack(alignment: .leading, spacing: Space.md) {
                        Button { isEditingTime = true } label: {
                            HStack {
                                FactRow(icon: .clock, title: "When", value: "\(stop.start.shortTime)–\(stop.end.shortTime) · \(stop.durationMinutes.durationText)")
                                if stop.status != .done { Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(stop.status == .done || !today.canEdit)
                        .accessibilityHint("Change when you go and how long you stay")
                        .accessibilityIdentifier("stop-time")
                        if today.controls.budgetAndExtras {
                            Button { isEditingCost = true } label: {
                                HStack {
                                    FactRow(icon: .wallet, title: stop.costIsCustom ? "Your estimate" : "Estimated cost", value: costValue(stop))
                                    Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("Change what this stop costs")
                            .accessibilityIdentifier("stop-cost")
                        } else {
                            // A group plan's costs aren't edited (G3b-2).
                            FactRow(icon: .wallet, title: "Estimated cost", value: stop.estimatedCost.dollarsText)
                                .accessibilityIdentifier("stop-cost-fixed")
                        }
                        FactRow(icon: .mapPin, title: "Address", value: stop.place.address)
                        if let hours = stop.place.hours {
                            FactRow(icon: .info, title: "Hours", value: hours)
                        }
                        if let leg = today.plan.leg(after: stop) {
                            Button { choosingLeg = StopRef(id: leg.id) } label: {
                                HStack {
                                    FactRow(icon: leg.mode.icon, title: "Next", value: leg.summary)
                                    Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(today.plan.state(of: leg) == .completed || !today.canEdit)
                            .accessibilityHint("Choose walk, subway or drive")
                        }
                    }
                    .planditCard()

                    if let note = stop.note {
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            SectionTitle("Why it's in your plan")
                            Text(note).font(.bodyText).foregroundStyle(.ink)
                        }
                    }

                    if let post = store.post(id: stop.sourcePostID) {
                        SourceCard(post: post)
                    }

                    VStack(spacing: Space.sm) {
                        Button {
                            stop.place.openDirections(by: today.travelMode(into: stop.id))
                        } label: {
                            HStack(spacing: Space.xs) {
                                Icon(.navigation, size: 18)
                                Text("Get directions")
                            }
                        }
                        .buttonStyle(.primary)


                        if today.canEdit {
                            Button(role: .destructive) {
                                dismiss()
                                withAnimation(.snappy) { today.remove(stop.id) }
                            } label: {
                                Text("Remove from plan")
                                    .font(.label)
                                    .foregroundStyle(.error)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .accessibilityIdentifier("remove-from-plan")
                        }
                    }
                }
                .padding(Space.lg)
                .animation(.snappy(duration: 0.3), value: stop.status)
            }
            .background(Color.surface)
            .navigationBarTitleDisplayMode(.inline)
            .sensoryFeedback(.impact(weight: .light), trigger: stop.status)
            .sheet(isPresented: $isEditingCost) { StopCostSheet(stopID: stop.id) }
            .sheet(isPresented: $isEditingTime) { StopTimeSheet(stopID: stop.id) }
            .sheet(item: $choosingLeg) { TravelOptionsSheet(legID: $0.id) }
        } else {
            ContentUnavailableView("Stop removed", image: "Icons/route", description: Text("This stop is no longer in today's plan."))
        }
    }

    /// "$20 · $15–30 · Typical for food in NYC" or "$7 · less than the usual $15–30".
    private func costValue(_ stop: PlanStop) -> String {
        let guide = store.priceGuide(for: stop)
        guard !stop.costIsCustom, guide.low != guide.high else { return stop.estimatedCost.dollarsText }
        return "\(stop.estimatedCost.dollarsText) · \(BudgetSheet.costSource(stop.estimatedCost, guide: guide).lowercasedFirst)"
    }
}

/// Where you are with this stop: Planned, I'm here or Done. Any choice can be changed back with one tap,
/// and the Undo bar covers what it did to the stops around it.
private struct StatusPicker: View {
    let stop: PlanStop
    /// Keeps editing the plan it opened on.
    @TodayContext(pinned: true) private var today

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            Picker("Status", selection: Binding(get: { stop.status }, set: { change(to: $0) })) {
                Text("Planned").tag(StopStatus.upcoming)
                Text("I'm here").tag(StopStatus.now)
                Text("Done").tag(StopStatus.done)
            }
            .pickerStyle(.segmented)
            .disabled(!today.canEdit)
            .accessibilityIdentifier("stop-status")
            Text(hint)
                .font(.metadata)
                .foregroundStyle(.inkMuted)
        }
    }

    private var hint: String {
        switch stop.status {
        case .upcoming: "Tap I'm here when you arrive. Stops before it are marked done."
        case .now: "Tap Done when you leave. The next stop becomes I'm here."
        case .done: "Went back or tapped by mistake? Tap Planned or I'm here."
        }
    }

    private func change(to status: StopStatus) {
        guard status != stop.status else { return }
        withAnimation(.snappy) {
            switch status {
            case .upcoming: today.leave(stop.id)
            case .now: today.arrive(at: stop.id)
            case .done: today.complete(stop.id)
            }
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
