import SwiftUI

/// Edit the stops still ahead: drag to reorder, tap the trash can to remove. Times update as you go;
/// nothing changes until Save, and Save can be undone. Stops that are done or underway stay where they are.
struct EditPlanSheet: View {
    @Environment(PlanditStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var order: [UUID] = []
    @State private var didLoad = false

    var body: some View {
        let current = store.today
        let preview = store.previewReorder(order)
        let first = current.firstMovableIndex
        NavigationStack {
            List {
                if first > 0 {
                    Section {
                        ForEach(Array(current.stops[..<first].enumerated()), id: \.element.id) { index, stop in
                            row(number: index + 1, stop: stop, was: nil)
                                .moveDisabled(true)
                        }
                    } header: {
                        Text("Done or underway")
                    }
                }
                Section {
                    ForEach(order, id: \.self) { id in
                        if let index = preview.stops.firstIndex(where: { $0.id == id }) {
                            let stop = preview.stops[index]
                            HStack(spacing: Space.sm) {
                                row(number: index + 1, stop: stop, was: current.stops.first { $0.id == id }?.start)
                                    .accessibilityIdentifier("reorder-\(stop.place.name)")
                                Spacer(minLength: 0)
                                Button {
                                    withAnimation(.snappy) { order.removeAll { $0 == id } }
                                } label: {
                                    Icon(.trash, size: 18)
                                        .foregroundStyle(Color.error)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(stop.place.name)")
                                .accessibilityIdentifier("remove-\(stop.place.name)")
                            }
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } header: {
                    Text("Still ahead")
                } footer: {
                    Text(footer(removed: current.stops.count - first - order.count))
                }
                let warnings = warnings(current: current, preview: preview)
                if !warnings.isEmpty {
                    Section {
                        ForEach(warnings, id: \.self) { Text($0).font(.metadata).foregroundStyle(Color.error) }
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Color.surface)
            .navigationTitle("Edit plan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        withAnimation(.snappy) { store.reorder(order) }
                        dismiss()
                    }
                    .accessibilityIdentifier("reorder-save")
                }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.surface)
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            order = store.today.stops[store.today.firstMovableIndex...].map(\.id)
        }
    }

    private func footer(removed: Int) -> String {
        let base = "Drag to change the order, or tap the trash can to remove a stop. Times update as you go."
        guard removed > 0 else { return base }
        return base + (removed == 1 ? " 1 stop will be removed; Cancel keeps it." : " \(removed) stops will be removed; Cancel keeps them.")
    }

    private func row(number: Int, stop: PlanStop, was: Date?) -> some View {
        HStack(spacing: Space.sm) {
            StopBadge(number: number, status: stop.status, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.place.name).font(.bodyText).foregroundStyle(.ink).lineLimit(1)
                Group {
                    if let was, was != stop.start {
                        Text("\(stop.start.shortTime) · was \(was.shortTime)")
                    } else {
                        Text(stop.start.shortTime)
                    }
                }
                .font(.metadata)
                .foregroundStyle(.inkMuted)
                .contentTransition(.numericText())
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spokenLabel(number: number, stop: stop, was: was))
    }

    /// "The High Line, stop 3, 2:20 PM, was 1:15 PM". Drag handles and remove buttons read it too.
    static func spokenLabel(number: Int, stop: PlanStop, was: Date?) -> String {
        var label = "\(stop.place.name), stop \(number), \(stop.start.shortTime)"
        if let was, was != stop.start { label += ", was \(was.shortTime)" }
        return label
    }

    private func warnings(current: DayPlan, preview: DayPlan) -> [String] {
        let alreadyLate = Set(current.stopsArrivingAfterClose().map(\.id))
        return preview.stopsArrivingAfterClose()
            .filter { !alreadyLate.contains($0.id) }
            .map { "You'd get to \($0.place.name) after it closes." }
    }
}
