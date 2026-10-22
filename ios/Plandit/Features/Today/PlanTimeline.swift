import SwiftUI

/// Ordered stops joined by a rail: black for structure, emerald for the active leg.
struct PlanTimeline: View {
    let plan: DayPlan
    @Environment(PlanditStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
                let leg = plan.leg(after: stop)
                NavigationLink(value: stop.id) {
                    TimelineStopRow(number: index + 1, stop: stop, railColor: leg.map { plan.state(of: $0).color })
                }
                .buttonStyle(.plain)
                .contextMenu {
                    StopActions(stop: stop)
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))

                if let leg {
                    TravelLegRow(leg: leg, state: plan.state(of: leg))
                        .transition(.opacity)
                }
            }
        }
    }
}

/// Progress and removal actions for a stop, shared by the timeline's context menu and the detail screen.
struct StopActions: View {
    let stop: PlanStop
    var onRemove: (() -> Void)?
    @Environment(PlanditStore.self) private var store

    var body: some View {
        if stop.status != .now {
            Button {
                withAnimation(.snappy) { store.arrive(at: stop.id) }
            } label: {
                Label("I'm here", image: "Icons/map-pin")
            }
        }
        if stop.status != .done {
            Button {
                withAnimation(.snappy) { store.complete(stop.id) }
            } label: {
                Label("Done here", image: "Icons/circle-check")
            }
        }
        Button(role: .destructive) {
            onRemove?()
            withAnimation(.snappy) { store.removeStop(stop.id) }
        } label: {
            Label("Remove from plan", image: "Icons/trash-2")
        }
    }
}

private struct TimelineStopRow: View {
    let number: Int
    let stop: PlanStop
    /// Color of the rail below the badge; nil for the last stop.
    let railColor: Color?

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            VStack(spacing: 0) {
                StopBadge(number: number, status: stop.status)
                if let railColor {
                    Rectangle().fill(railColor).frame(width: 2).frame(maxHeight: .infinity)
                }
            }
            .frame(width: 28)

            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Text(stop.start.shortTime).font(.label).foregroundStyle(.ink)
                    StopStatusTag(status: stop.status)
                        .transition(.scale.combined(with: .opacity))
                    Spacer(minLength: 0)
                    Icon(.chevronRight, size: 16).foregroundStyle(.inkMuted)
                }
                Text(stop.place.name)
                    .font(.cardHeading)
                    .foregroundStyle(stop.status == .done ? Color.inkMuted : Color.ink)
                    .multilineTextAlignment(.leading)
                Text("\(stop.place.category.label) · \(stop.place.neighborhood)")
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                HStack(spacing: Space.sm) {
                    MetaLabel(.wallet, stop.estimatedCost.dollarsText)
                    MetaLabel(.clock, stop.durationMinutes.durationText)
                }
                .padding(.top, 2)
            }
            .padding(.bottom, Space.md)
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .animation(.snappy(duration: 0.3), value: stop.status)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows stop details")
    }
}

private struct TravelLegRow: View {
    let leg: TravelLeg
    let state: LegState

    var body: some View {
        HStack(spacing: Space.sm) {
            RailSegment(color: state.color, isDotted: leg.mode != .walk)
                .frame(width: 28)
            HStack(spacing: Space.xs) {
                Icon(leg.mode.icon, size: 16)
                Text(leg.summary).lineLimit(2)
            }
            .font(.metadata)
            .foregroundStyle(state == .active ? Color.ink : Color.inkMuted)
            .padding(.vertical, Space.sm)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
    }
}

/// Solid rail for walking, dotted for transit (mirrors the map's route lines).
private struct RailSegment: View {
    let color: Color
    let isDotted: Bool

    var body: some View {
        VerticalLine()
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: isDotted ? [1, 6] : []))
            .frame(width: 2)
            .frame(maxHeight: .infinity)
    }
}

private nonisolated struct VerticalLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        }
    }
}
