import SwiftUI

/// Change when a stop starts and how long you stay, after the plan is made.
/// Shows what moves before saving, and warns when a place would be closed.
struct StopTimeSheet: View {
    let stopID: UUID
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var start = Date()
    @State private var minutes = 60
    @State private var moveLaterStops = true
    @State private var didLoad = false

    var body: some View {
        NavigationStack {
            Group {
                if let stop = store.stop(id: stopID), stop.status != .done {
                    content(stop)
                } else {
                    ContentUnavailableView("Can't change this stop", image: "Icons/route", description: Text("It's done or no longer in today's plan."))
                }
            }
            .background(Color.surface)
            .navigationTitle("Time")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        withAnimation(.snappy) {
                            store.setTime(ofStop: stopID, start: start, durationMinutes: minutes, moveLaterStops: moveLaterStops)
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier("time-save")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.surface)
        .onAppear {
            guard !didLoad, let stop = store.stop(id: stopID) else { return }
            didLoad = true
            start = stop.start
            minutes = stop.durationMinutes
        }
    }

    private func content(_ stop: PlanStop) -> some View {
        let preview = store.previewTime(ofStop: stop.id, start: start, durationMinutes: minutes, moveLaterStops: moveLaterStops)
        let edited = preview.stops.first { $0.id == stop.id } ?? stop
        let laterStops = store.today.stops.drop { $0.id != stop.id }.dropFirst().filter { $0.status == .upcoming }
        return ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                Text(stop.place.name).font(.cardHeading).foregroundStyle(.ink)

                VStack(spacing: 0) {
                    HStack {
                        Label { Text(stop.status == .now ? "Started" : "Starts").font(.bodyText) } icon: { Icon(.clock, size: 18) }
                            .foregroundStyle(.ink)
                        Spacer()
                        if stop.status == .now {
                            Text(stop.start.shortTime).font(.manrope(.bold, size: 17)).foregroundStyle(.ink)
                        } else {
                            DatePicker("Starts", selection: $start, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .accessibilityIdentifier("time-start")
                        }
                    }
                    .frame(minHeight: 48)
                    Hairline()
                    HStack {
                        Label { Text("Stay for").font(.bodyText) } icon: { Icon(.clock, size: 18) }
                            .foregroundStyle(.ink)
                        Spacer()
                        Text(minutes.durationText)
                            .font(.manrope(.bold, size: 17))
                            .foregroundStyle(.ink)
                            .contentTransition(.numericText())
                            .accessibilityIdentifier("time-duration-value")
                        Stepper("Stay for", value: $minutes, in: DayPlan.shortestStay...360, step: 15)
                            .labelsHidden()
                            .accessibilityIdentifier("time-duration")
                    }
                    .frame(minHeight: 48)
                    Hairline()
                    HStack {
                        Text("You'd be there").font(.bodyText).foregroundStyle(.inkMuted)
                        Spacer()
                        Text("\(edited.start.shortTime)–\(edited.end.shortTime)")
                            .font(.label)
                            .foregroundStyle(.ink)
                            .accessibilityIdentifier("time-range")
                    }
                    .frame(minHeight: 44)
                }
                .planditCard(padding: Space.sm)

                ForEach(warnings(stop: stop, edited: edited, preview: preview), id: \.self) { warning in
                    Text(warning)
                        .font(.metadata)
                        .foregroundStyle(warning.hasPrefix("Earliest") ? Color.inkMuted : Color.error)
                }

                if !laterStops.isEmpty {
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Toggle(isOn: $moveLaterStops.animation(.snappy)) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Move later stops with it").font(.bodyText).foregroundStyle(.ink)
                                Text(moveLaterStops ? "They keep the same gaps between them." : "They only move if they'd overlap.")
                                    .font(.metadata)
                                    .foregroundStyle(.inkMuted)
                            }
                        }
                        .tint(.emerald)
                        .accessibilityIdentifier("time-move-later")
                        changes(laterStops: Array(laterStops), preview: preview)
                    }
                    .planditCard(padding: Space.sm)
                }
            }
            .padding(Space.lg)
        }
        .scrollIndicators(.hidden)
    }

    /// "Los Tacos  1:30 PM → 2:00 PM" for each later stop that moves.
    @ViewBuilder private func changes(laterStops: [PlanStop], preview: DayPlan) -> some View {
        let moved = laterStops.compactMap { old -> (PlanStop, Date)? in
            guard let new = preview.stops.first(where: { $0.id == old.id }), new.start != old.start else { return nil }
            return (old, new.start)
        }
        if !moved.isEmpty {
            Hairline()
            ForEach(moved, id: \.0.id) { old, newStart in
                HStack {
                    Text(old.place.name).font(.metadata).foregroundStyle(.ink).lineLimit(1)
                    Spacer()
                    Text("\(old.start.shortTime) → \(newStart.shortTime)").font(.metadata).foregroundStyle(.inkMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func warnings(stop: PlanStop, edited: PlanStop, preview: DayPlan) -> [String] {
        var lines: [String] = []
        if stop.status == .upcoming, edited.start > start, let earliest = store.today.earliestStart(ofStop: stop.id) {
            lines.append("Earliest is \(earliest.shortTime), after the stop before it and the trip here.")
        }
        if let close = stop.place.closingTime(on: preview.date), edited.end > close {
            lines.append("\(stop.place.name) closes at \(close.shortTime).")
        }
        let alreadyLate = Set(store.today.stopsArrivingAfterClose().map(\.id))
        for late in preview.stopsArrivingAfterClose() where late.id != stop.id && !alreadyLate.contains(late.id) {
            lines.append("You'd get to \(late.place.name) after it closes.")
        }
        return lines
    }
}
