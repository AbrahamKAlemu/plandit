import SwiftUI

/// One suggested plan in the empty Today: where it is, the stops in order, one line of facts, then
/// "Use this plan" and "Change it". Built from the existing card, badge and button styles only (SP-14).
struct SuggestionCard: View {
    let suggestion: PlanSuggestion
    let index: Int
    let use: () -> Void
    /// Opens the planner with this plan's places picked.
    let change: () -> Void
    @Environment(\.accessibilityVoiceOverEnabled) private var isVoiceOverOn
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Stops listed by name; the rest are "+1 more".
    static let shownStops = 3

    var body: some View {
        let card = content.planditCard()
        // VoiceOver reads the card as one element, with the buttons as its actions (SP-15). Without
        // it (Voice Control, Full Keyboard Access, UI tests) the buttons stay separate controls.
        if isVoiceOverOn {
            card
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(SuggestionText.spoken(suggestion))
                .accessibilityAction(named: "Use this plan", use)
                .accessibilityAction(named: "Change it", change)
                .accessibilityIdentifier("suggestion-card-\(index)")
        } else {
            card
                .accessibilityElement(children: .contain)
                .accessibilityLabel(SuggestionText.spoken(suggestion))
                .accessibilityIdentifier("suggestion-card-\(index)")
        }
    }

    private var content: some View {
        let stops = suggestion.outcome.stops
        let more = stops.count - Self.shownStops
        return VStack(alignment: .leading, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(suggestion.title)
                    .font(.cardHeading)
                    .foregroundStyle(.ink)
                Text(SuggestionText.facts(suggestion.outcome))
                    .font(.metadata)
                    .foregroundStyle(.inkMuted)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(Array(stops.prefix(Self.shownStops).enumerated()), id: \.element.id) { number, stop in
                    HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                        StopBadge(number: number + 1, status: .upcoming, size: 24)
                            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 5 }
                        stopName(stop)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if more > 0 {
                    Text("+\(more) more")
                        .font(.metadata)
                        .foregroundStyle(.inkMuted)
                        .padding(.leading, 24 + Space.sm)
                }
            }

            buttons
        }
    }

    /// Side by side, or stacked at accessibility text sizes so neither label is cut off (SP-16).
    private var buttons: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Space.xs))
            : AnyLayout(HStackLayout(spacing: Space.xs))
        return layout {
            Button("Use this plan", action: use)
                .buttonStyle(.primary)
                .accessibilityIdentifier("suggestion-use-\(index)")
            Button("Change it", action: change)
                .buttonStyle(.secondary)
                .accessibilityIdentifier("suggestion-change-\(index)")
        }
    }

    /// "Joe's Pizza", or "Joe's Pizza · check hours" when the app can't read its hours.
    private func stopName(_ stop: PlanStop) -> Text {
        let name = Text(stop.place.name).font(.bodyText).foregroundStyle(Color.ink)
        guard SuggestionText.needsHoursCheck(stop) else { return name }
        return name + Text(" · \(SuggestionText.checkHours)").font(.metadata).foregroundStyle(Color.inkMuted)
    }
}

/// The words on a suggested plan (SP-18).
enum SuggestionText {
    static let heading = "Plans from your saves"
    static let checkHours = "check hours"

    /// "3 stops · 2:30–6:15 PM · $24 each with subway".
    static func facts(_ outcome: DayPlanner.Outcome) -> String {
        [stopCount(outcome), times(outcome, separator: "–"), cost(outcome)].compactMap { $0 }.joined(separator: " · ")
    }

    /// What VoiceOver reads: "Chelsea. 3 stops, 2:30 to 6:15 PM, $24 each with subway. Joe's Pizza,
    /// The High Line, Chelsea Market." A stop whose hours the app can't read says so after its name.
    static func spoken(_ suggestion: PlanSuggestion) -> String {
        let outcome = suggestion.outcome
        let facts = [stopCount(outcome), times(outcome, separator: " to "), cost(outcome)].compactMap { $0 }.joined(separator: ", ")
        let names = outcome.stops.map { needsHoursCheck($0) ? "\($0.place.name) (\(checkHours))" : $0.place.name }
        return "\(suggestion.title). \(facts). \(names.joined(separator: ", "))."
    }

    /// "$24 each with subway", or "$24 each, all walking". Per person, fares included.
    static func cost(_ outcome: DayPlanner.Outcome) -> String {
        let amount = outcome.cost.wholeDollarsText
        return outcome.legs.contains { $0.mode.isTransit } ? "\(amount) each with subway" : "\(amount) each, all walking"
    }

    /// "2:30–6:15 PM", or "11:30 AM–1:15 PM" across noon.
    static func times(_ outcome: DayPlanner.Outcome, separator: String) -> String? {
        guard let start = outcome.stops.first?.start, let end = outcome.end else { return nil }
        return timeRange(start, end, separator: separator)
    }

    static func timeRange(_ start: Date, _ end: Date, separator: String) -> String {
        var from = start.shortTime
        let to = end.shortTime
        // The same AM or PM at the end of both: say it once.
        let period = trailingPeriod(to)
        if !period.trimmingCharacters(in: .whitespaces).isEmpty, trailingPeriod(from) == period {
            from = String(from.dropLast(period.count))
        }
        return from + separator + to
    }

    /// Whatever follows a time's last digit: " PM", or nothing in a 24-hour locale.
    private static func trailingPeriod(_ time: String) -> String {
        guard let last = time.lastIndex(where: \.isNumber) else { return "" }
        return String(time[time.index(after: last)...])
    }

    private static func stopCount(_ outcome: DayPlanner.Outcome) -> String {
        outcome.stops.count == 1 ? "1 stop" : "\(outcome.stops.count) stops"
    }

    /// The planner can only keep a visit inside hours it can read ("Open until 9 PM").
    static func needsHoursCheck(_ stop: PlanStop) -> Bool {
        stop.place.closingTime(on: stop.start) == nil
    }
}
