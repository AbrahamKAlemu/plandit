import SwiftUI

extension PastPlan {
    /// `value` rounded to whole dollars (half a dollar rounds up), or nil when it isn't a real amount:
    /// not finite, or beyond a billion either way. A corrupted synced snapshot can hold anything.
    private static func wholeDollars(_ value: Double) -> Double? {
        guard value.isFinite, abs(value) <= 1e9 else { return nil }
        return value.rounded()
    }

    /// The cost in whole dollars, rounded once; $0 when the recorded cost can't be read. The cost
    /// text, the under/over amount and the mark's color all come from this one number, so they agree.
    var wholeDollarCost: Double { Self.wholeDollars(cost) ?? 0 }

    /// Budget minus cost in whole dollars: positive is under, negative is over. Nil for plans that
    /// didn't record a budget, or whose cost or budget can't be read.
    private var wholeDollarsUnderBudget: Double? {
        guard let budget, let budget = Self.wholeDollars(budget), let cost = Self.wholeDollars(cost) else { return nil }
        return budget - cost
    }

    /// "Thu, Nov 12 · 5 stops · $31 per person", plus ", fares included" when the cost has subway or
    /// bus fares in it. Whole dollars, never "$$".
    var summaryText: String {
        let stops = stopCount == 1 ? "1 stop" : "\(stopCount) stops"
        let fareNote = (fares ?? 0) > 0 ? ", fares included" : ""
        return "\(date.shortDay) · \(stops) · \(wholeDollarCost.wholeDollarsText) per person\(fareNote)"
    }

    /// "$22 under", "$5 over" or "On budget" for plans that recorded their budget; nil for older ones.
    var budgetMark: String? {
        guard let difference = wholeDollarsUnderBudget else { return nil }
        if difference > 0 { return "\(difference.wholeDollarsText) under" }
        if difference < 0 { return "\((-difference).wholeDollarsText) over" }
        return "On budget"
    }

    /// Over the recorded budget once both are in whole dollars. The mark is green unless this is true.
    var isOverBudget: Bool { (wholeDollarsUnderBudget ?? 0) < 0 }
}

/// A finished day in Profile → Past plans. 1.0 didn't keep a plan's stops, so the row is the
/// whole record: it doesn't open anything and shows no chevron.
/// At accessibility sizes the budget mark moves under the text so the title has the whole width.
struct PastPlanRow: View {
    let plan: PastPlan
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.sm))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                    .font(.manrope(.semiBold, size: 15))
                    .foregroundStyle(.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                Text(plan.summaryText)
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 0)
            }
            if let mark = plan.budgetMark {
                Text(mark)
                    .font(.label)
                    .foregroundStyle(plan.isOverBudget ? Color.ink : Color.emeraldDeep)
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
