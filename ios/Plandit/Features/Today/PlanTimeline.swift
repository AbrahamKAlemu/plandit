import SwiftUI

/// Ordered stops joined by a rail: black for structure, emerald for the active leg.
struct PlanTimeline: View {
    let plan: DayPlan
    @Environment(PlanditStore.self) private var store
    @TodayContext private var today
    /// The trip whose walk / subway / drive options are open.
    @State private var choosingLeg: StopRef?
    /// The stop whose friends' swap picks are open.
    @State private var reviewingSwaps: StopRef?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(plan.stops.enumerated()), id: \.element.id) { index, stop in
                let leg = plan.leg(after: stop)
                NavigationLink(value: stop.id) {
                    TimelineStopRow(number: index + 1, stop: stop, railColor: leg.map { plan.state(of: $0).color })
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if today.canEdit {
                        StopActions(stop: stop)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))

                // Mode 1's swap picks are about your own shared plan, not a group plan.
                if today.controls.shareAnswers, let picks = store.swapMarks[stop.id] {
                    SwapMarkRow(count: picks.count, stopName: stop.place.name, railColor: leg.map { plan.state(of: $0).color }) {
                        reviewingSwaps = StopRef(id: stop.id)
                    }
                    .transition(.opacity)
                }

                if let leg {
                    let state = plan.state(of: leg)
                    Button {
                        choosingLeg = StopRef(id: leg.id)
                    } label: {
                        TravelLegRow(leg: leg, state: state)
                    }
                    .buttonStyle(.plain)
                    .disabled(state == .completed || !today.canEdit)
                    .accessibilityHint(state == .completed || !today.canEdit ? "" : "Choose walk, subway or drive")
                    .accessibilityIdentifier("leg-\(index + 1)")
                    .transition(.opacity)
                }
            }
        }
        .sheet(item: $choosingLeg) { TravelOptionsSheet(legID: $0.id) }
        .sheet(item: $reviewingSwaps) { StopSwapSheet(stopID: $0.id) }
    }
}

/// Progress and removal actions for a stop, shared by the timeline's context menu and the detail screen.
struct StopActions: View {
    let stop: PlanStop
    var onRemove: (() -> Void)?
    @TodayContext private var today

    var body: some View {
        switch stop.status {
        case .upcoming:
            Button {
                withAnimation(.snappy) { today.arrive(at: stop.id) }
            } label: {
                Label("I'm here", image: "Icons/map-pin")
            }
        case .now:
            Button {
                withAnimation(.snappy) { today.leave(stop.id) }
            } label: {
                Label("Not here yet", image: "Icons/undo-2")
            }
        case .done:
            Button {
                withAnimation(.snappy) { today.arrive(at: stop.id) }
            } label: {
                Label("Not done yet", image: "Icons/undo-2")
            }
        }
        if stop.status != .done {
            Button {
                withAnimation(.snappy) { today.complete(stop.id) }
            } label: {
                Label("Done here", image: "Icons/circle-check")
            }
        }
        Button(role: .destructive) {
            onRemove?()
            withAnimation(.snappy) { today.remove(stop.id) }
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

/// "2 would swap" under a stop friends would swap; opens what they picked.
private struct SwapMarkRow: View {
    let count: Int
    let stopName: String
    /// The rail carries on down to the trip after the stop; nil for the last stop.
    let railColor: Color?
    let action: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Rectangle()
                .fill(railColor ?? .clear)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .frame(width: 28)
            Button(action: action) {
                HStack(spacing: Space.xxs) {
                    Icon(.users, size: 16)
                    Text(ShareAnswersText.wouldSwap(count))
                    Icon(.chevronRight, size: 14).foregroundStyle(.inkMuted)
                }
                .outlinedControl()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(count == 1 ? "1 friend would swap \(stopName)" : "\(count) friends would swap \(stopName)")
            .accessibilityHint("Shows what they picked")
            .accessibilityIdentifier("swap-mark-\(stopName)")
            Spacer(minLength: 0)
        }
        .padding(.bottom, Space.xs)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TravelLegRow: View {
    let leg: TravelLeg
    let state: LegState
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: Space.sm) {
            RailSegment(color: state.color, dash: leg.mode.dash)
                .frame(width: 28)
            HStack(spacing: Space.xs) {
                Icon(leg.mode.icon, size: 16)
                // Two lines at standard sizes; at accessibility sizes the whole trip shows.
                Text(leg.summary).lineLimit(typeSize.isAccessibilitySize ? nil : 2)
            }
            .font(.metadata)
            .foregroundStyle(state == .active ? Color.ink : Color.inkMuted)
            .padding(.vertical, Space.sm)
            Spacer(minLength: 0)
            if state != .completed {
                // Looks like a control: the trip can be changed.
                Text("Change")
                    .font(.label)
                    .foregroundStyle(.ink)
                    .padding(.horizontal, Space.sm)
                    .frame(minHeight: 32)
                    .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Color.border))
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .fixedSize(horizontal: false, vertical: true)
        .animation(.snappy(duration: 0.3), value: state)
        .accessibilityElement(children: .combine)
    }
}

/// Solid rail for walking, dotted for transit, dashed for driving (mirrors the map's route lines).
private struct RailSegment: View {
    let color: Color
    let dash: [CGFloat]

    var body: some View {
        VerticalLine()
            .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash.map { $0 * 0.7 }))
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
