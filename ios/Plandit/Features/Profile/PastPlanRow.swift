import SwiftUI

extension PastPlan {
    /// "Thu, Nov 12 · 5 stops · $31 per person", plus ", fares included" when the cost has subway or
    /// bus fares in it. Whole dollars, never "$$".
    var summaryText: String {
        let stops = stopCount == 1 ? "1 stop" : "\(stopCount) stops"
        let fareNote = (fares ?? 0) > 0 ? ", fares included" : ""
        return "\(date.shortDay) · \(stops) · \(cost.wholeDollarsText) per person\(fareNote)"
    }

    /// "$22 under", "$5 over" or "On budget" for plans that recorded their budget; nil for older ones.
    var budgetMark: String? {
        guard let budget else { return nil }
        let difference = (budget - cost).rounded()
        if difference > 0 { return "\(difference.wholeDollarsText) under" }
        if difference < 0 { return "\((-difference).wholeDollarsText) over" }
        return "On budget"
    }
}

/// A finished day in Profile → Past plans. 1.0 didn't keep a plan's stops, so the row is the
/// whole record: it doesn't open anything and shows no chevron.
struct PastPlanRow: View {
    let plan: PastPlan

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(.ink)
                    .lineLimit(2)
                Text(plan.summaryText)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let mark = plan.budgetMark {
                Text(mark)
                    .font(.label)
                    .foregroundStyle(plan.cost <= (plan.budget ?? 0) + 0.5 ? Color.emeraldDeep : Color.ink)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 56)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityIdentifier("past-plan")
    }

    private var accessibilityText: String {
        let parts = [plan.title, plan.summaryText] + (plan.budgetMark.map { [$0 == "On budget" ? $0 : "\($0) budget"] } ?? [])
        return parts.joined(separator: ", ")
    }
}
