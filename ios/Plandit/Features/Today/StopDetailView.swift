import SwiftUI

struct StopDetailView: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isEditingCost = false
    @State private var isEditingTime = false
    @State private var choosingLeg: StopRef?

    var body: some View {
        if let stop = store.stop(id: stopID), let number = store.stopNumber(id: stopID) {
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

                    VStack(alignment: .leading, spacing: Space.md) {
                        Button { isEditingTime = true } label: {
                            HStack {
                                FactRow(icon: .clock, title: "When", value: "\(stop.start.shortTime)–\(stop.end.shortTime) · \(stop.durationMinutes.durationText)")
                                if stop.status != .done { Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted) }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(stop.status == .done)
                        .accessibilityHint("Change when you go and how long you stay")
                        .accessibilityIdentifier("stop-time")
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
                        FactRow(icon: .mapPin, title: "Address", value: stop.place.address)
                        if let hours = stop.place.hours {
                            FactRow(icon: .info, title: "Hours", value: hours)
                        }
                        if let leg = store.today.leg(after: stop) {
                            Button { choosingLeg = StopRef(id: leg.id) } label: {
                                HStack {
                                    FactRow(icon: leg.mode.icon, title: "Next", value: leg.summary)
                                    Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(store.today.state(of: leg) == .completed)
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
                            stop.place.openDirections(by: store.travelMode(into: stop.id))
                        } label: {
                            HStack(spacing: Space.xs) {
                                Icon(.navigation, size: 18)
                                Text("Get directions")
                            }
                        }
                        .buttonStyle(.primary)

                        ProgressButtons(stop: stop)

                        Button(role: .destructive) {
                            dismiss()
                            withAnimation(.snappy) { store.removeStop(stop.id) }
                        } label: {
                            Text("Remove from plan")
                                .font(.label)
                                .foregroundStyle(.error)
                                .frame(maxWidth: .infinity, minHeight: 44)
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

/// "I'm here" and "Done here" move the day forward; the map and timeline follow.
private struct ProgressButtons: View {
    let stop: PlanStop
    @Environment(PlanditStore.self) private var store

    var body: some View {
        HStack(spacing: Space.sm) {
            if stop.status != .now {
                Button {
                    withAnimation(.snappy) { store.arrive(at: stop.id) }
                } label: {
                    HStack(spacing: Space.xs) {
                        Icon(.mapPin, size: 18)
                        Text("I'm here")
                    }
                }
                .buttonStyle(.secondary)
                .transition(.opacity)
            }
            if stop.status != .done {
                Button {
                    withAnimation(.snappy) { store.complete(stop.id) }
                } label: {
                    HStack(spacing: Space.xs) {
                        Icon(.circleCheck, size: 18)
                        Text("Done here")
                    }
                }
                .buttonStyle(.secondary)
                .transition(.opacity)
            }
        }
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
