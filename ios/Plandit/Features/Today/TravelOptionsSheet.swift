import SwiftUI

/// How to get from one stop to the next: walk, subway or drive, each with its time, cost and
/// when you'd arrive. Picking one moves the rest of the day to match.
struct TravelOptionsSheet: View {
    let legID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if let leg = store.today.legs.first(where: { $0.id == legID }),
                   let from = store.stop(id: leg.fromStopID), let to = store.stop(id: leg.toStopID) {
                    content(leg: leg, from: from, to: to)
                } else {
                    ContentUnavailableView("Trip removed", image: "Icons/route", description: Text("These stops aren't next to each other anymore."))
                }
            }
            .background(Color.surface)
            .navigationTitle("Getting there")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .task {
            await store.loadTravelOptions(forLeg: legID)
            isLoading = false
        }
    }

    private func content(leg: TravelLeg, from: PlanStop, to: PlanStop) -> some View {
        let options = store.travelOptions(forLeg: leg.id)
        let upcomingTrips = store.today.legs.filter { store.today.state(of: $0) != .completed }.count
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(from.place.name) to \(to.place.name)")
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    Text(sourceLine(options))
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .accessibilityIdentifier("travel-source")
                }

                VStack(spacing: 0) {
                    ForEach(options) { option in
                        OptionRow(
                            option: option,
                            isSelected: option.leg.mode == leg.mode,
                            preview: store.previewTravel(option),
                            alreadyLate: Set(store.today.stopsArrivingAfterClose().map(\.id)),
                            destination: to
                        ) {
                            withAnimation(.snappy) { store.chooseTravel(option) }
                        }
                        if option.id != options.last?.id { Hairline() }
                    }
                }
                .planditCard(padding: Space.sm)

                if leg.mode == .drive {
                    Text("Drive means a taxi or rideshare. The fare is an estimate; check the app you book with.")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                }

                VStack(spacing: Space.sm) {
                    Button {
                        to.place.openDirections(by: leg.mode, from: from.place)
                    } label: {
                        HStack(spacing: Space.xs) {
                            Icon(.navigation, size: 18)
                            Text(leg.mode.isTransit ? "Subway directions in Maps" : "Directions in Maps")
                        }
                    }
                    .buttonStyle(.secondary)
                    .accessibilityIdentifier("travel-open-maps")

                    if upcomingTrips > 1 {
                        Button {
                            withAnimation(.snappy) { store.chooseTravelForRestOfDay(leg.mode) }
                        } label: {
                            Text(restOfDayTitle(leg.mode))
                                .font(.label)
                                .foregroundStyle(.ink)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .accessibilityIdentifier("travel-rest-of-day")
                    }
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
    }

    private func sourceLine(_ options: [PlanditStore.TravelOption]) -> String {
        if options.contains(where: \.isLive) { return "Times from Apple Maps" }
        return isLoading ? "Getting times from Apple Maps…" : "Estimated times"
    }

    private func restOfDayTitle(_ mode: TravelMode) -> String {
        switch mode {
        case .walk: "Walk the rest of the day"
        case .subway, .bus: "Take the subway the rest of the day"
        case .drive: "Drive the rest of the day"
        }
    }
}

private struct OptionRow: View {
    let option: PlanditStore.TravelOption
    let isSelected: Bool
    /// The day if this option were picked.
    let preview: DayPlan
    /// Stops that are late whatever you pick; only new problems get a warning.
    let alreadyLate: Set<UUID>
    let destination: PlanStop
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Space.sm) {
                Icon(option.leg.mode.icon, size: 22)
                    .foregroundStyle(.ink)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.leg.mode.label).font(.manrope(.bold, size: 16)).foregroundStyle(.ink)
                    Text(detail).font(.metadata).foregroundStyle(.inkMuted)
                    if let warning {
                        HStack(spacing: Space.xxs) {
                            Icon(.circleAlert, size: 14)
                            Text(warning)
                        }
                        .font(.metadata)
                        .foregroundStyle(.error)
                    }
                }
                Spacer(minLength: Space.xs)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(option.leg.minutes) min").font(.manrope(.bold, size: 16)).foregroundStyle(.ink)
                    Text(costText).font(.metadata).foregroundStyle(.inkMuted)
                }
                SelectionMark(isOn: isSelected)
            }
            .padding(.vertical, Space.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("travel-\(option.leg.mode.rawValue)")
    }

    private var costText: String {
        switch option.leg.mode {
        case .walk: "Free"
        case .subway, .bus: option.leg.cost.dollarsText
        case .drive: "about \(option.leg.cost.wholeDollarsText)"
        }
    }

    private var detail: String {
        let arrive = preview.stop(id: destination.id).map { "Arrive \($0.start.shortTime)" }
        return [option.leg.miles.milesText, arrive].compactMap { $0 }.joined(separator: " · ")
    }

    /// Only for stops this choice would newly make you miss.
    private var warning: String? {
        let late = preview.stopsArrivingAfterClose().filter { !alreadyLate.contains($0.id) }
        guard let first = late.first else { return nil }
        return late.count == 1 ? "You'd get to \(first.place.name) after it closes" : "You'd miss \(late.count) stops' closing times"
    }
}

/// Ink circle with a check when selected, like the planner's checkboxes.
struct SelectionMark: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(isOn ? Color.ink : Color.surface)
            Circle().strokeBorder(isOn ? Color.ink : Color.border, lineWidth: 1.5)
            if isOn {
                Icon(.check, size: 14).foregroundStyle(Color.onInk)
            }
        }
        .frame(width: 24, height: 24)
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}
