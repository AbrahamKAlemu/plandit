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
            .solidSheetHeader()
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
        let rows = Self.rows(store.travelOptions(forLeg: leg.id), planned: leg)
        let upcomingTrips = store.today.legs.filter { store.today.state(of: $0) != .completed }.count
        let alreadyLate = Set(store.today.stopsArrivingAfterClose().map(\.id))
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text("\(from.place.name) to \(to.place.name)")
                        .font(.cardHeading)
                        .foregroundStyle(.ink)
                    if isLoading {
                        Text("Getting times from Apple Maps…")
                            .font(.metadata)
                            .foregroundStyle(.inkMuted)
                            .accessibilityIdentifier("travel-source")
                    }
                }

                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        OptionRow(
                            row: row,
                            preview: store.previewTravel(row.option),
                            alreadyLate: alreadyLate,
                            destination: to
                        ) {
                            withAnimation(.snappy) { store.chooseTravel(row.option) }
                        }
                        if let update = row.update, let minutes = row.liveMinutes {
                            LiveTimeButton(minutes: minutes, preview: store.previewTravel(update), destination: to) {
                                withAnimation(.snappy) { store.chooseTravel(update) }
                            }
                        }
                        if row.id != rows.last?.id { Hairline() }
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
                            Text(Self.restOfDayTitle(leg.mode))
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

    /// One way of making the trip, as the sheet shows it.
    struct Row: Identifiable, Equatable {
        /// The time, cost and arrival shown, and what picking the row does.
        var option: PlanditStore.TravelOption
        /// The way the trip is planned now.
        var isPlanned: Bool
        /// The planned way only: Apple Maps' time when it differs from the plan's. Picking it is the
        /// only way that time reaches the day.
        var update: PlanditStore.TravelOption?
        var id: TravelMode { option.id }
        /// The time "Apple Maps now says": Apple Maps' own, so a drive leaves out the wait for
        /// pickup that the day still counts.
        var liveMinutes: Int? {
            guard let update else { return nil }
            return update.leg.minutes - (update.leg.mode == .drive ? TravelLeg.pickupMinutes : 0)
        }

        /// Where the row's time comes from.
        var source: String {
            if isPlanned { return "In your plan" }
            return option.isLive ? "From Apple Maps" : "Estimate"
        }
    }

    /// The way the trip is planned shows the plan's own time, so it matches the timeline and the
    /// stop times, with Apple Maps' newer time offered under it; the other ways show Apple Maps
    /// times when they've loaded. Opening this sheet never moves the day. Picking the planned row
    /// again keeps its time and marks it as the user's pick. Apple Maps' newer time changes only
    /// the minutes: the line, distance and fare stay the plan's.
    static func rows(_ options: [PlanditStore.TravelOption], planned: TravelLeg) -> [Row] {
        options.map { option in
            guard option.leg.mode == planned.mode else { return Row(option: option, isPlanned: false) }
            var kept = planned
            kept.isChosen = true
            var update: PlanditStore.TravelOption?
            if option.isLive, option.leg.minutes != planned.minutes {
                var newer = kept
                newer.minutes = option.leg.minutes
                update = PlanditStore.TravelOption(leg: newer, isLive: true)
            }
            return Row(option: PlanditStore.TravelOption(leg: kept, isLive: false), isPlanned: true, update: update)
        }
    }

    static func restOfDayTitle(_ mode: TravelMode) -> String {
        switch mode {
        case .walk: "Walk the rest of the day"
        case .subway, .bus: "Take the \(mode.label.lowercased()) the rest of the day"
        case .drive: "Drive the rest of the day"
        }
    }
}

private struct OptionRow: View {
    let row: TravelOptionsSheet.Row
    /// The day if this option were picked.
    let preview: DayPlan
    /// Stops that are late whatever you pick; only new problems get a warning.
    let alreadyLate: Set<UUID>
    let destination: PlanStop
    let choose: () -> Void

    private var option: PlanditStore.TravelOption { row.option }
    private var isSelected: Bool { row.isPlanned }

    var body: some View {
        Button(action: choose) {
            HStack(spacing: Space.sm) {
                Icon(option.leg.mode.icon, size: 22)
                    .foregroundStyle(.ink)
                    .frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.leg.mode.label).font(.manrope(.bold, size: 16)).foregroundStyle(.ink)
                    Text(detail).font(.metadata).foregroundStyle(.inkMuted)
                    Text(row.source)
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .accessibilityIdentifier("travel-source-\(option.leg.mode.rawValue)")
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

/// Under the planned way, when Apple Maps' time for it has changed: "Apple Maps now says 24 min".
/// Tapping it uses that time and moves the stops after the trip.
private struct LiveTimeButton: View {
    /// Apple Maps' own time for the trip.
    let minutes: Int
    /// The day with Apple Maps' time.
    let preview: DayPlan
    let destination: PlanStop
    let apply: () -> Void

    var body: some View {
        Button(action: apply) {
            HStack(spacing: Space.xxs) {
                Icon(.clock, size: 14)
                Text("Apple Maps now says \(minutes) min")
                Spacer(minLength: 0)
            }
            .font(.label)
            .foregroundStyle(.ink)
            .padding(.leading, 32 + Space.sm)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(hint)
        .accessibilityIdentifier("travel-live-time")
    }

    private var hint: String {
        guard let arrive = preview.stop(id: destination.id)?.start.shortTime else { return "Uses this time for the trip" }
        return "Uses this time for the trip, so you'd arrive at \(arrive)"
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
