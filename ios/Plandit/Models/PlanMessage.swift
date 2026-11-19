import Foundation

/// What goes into the plan when it's sent to friends.
struct PlanMessageOptions: Equatable {
    /// A line from the sender at the top: "Who's in?"
    var note = ""
    var showPrices = true
    /// "↓ 22 min walk" between stops.
    var showTravel = true
    /// Leave out stops already done, for a plan that's underway.
    var onlyWhatsLeft = false
}

extension DayPlan {
    /// The plan as a text message, ready for a group chat.
    func message(_ options: PlanMessageOptions = PlanMessageOptions()) -> String {
        let shown = options.onlyWhatsLeft ? stops.filter { $0.status != .done } : stops
        guard let first = shown.first else { return "My Plandit day: nothing planned yet" }
        var lines: [String] = []
        let note = options.note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !note.isEmpty { lines += [note, ""] }

        let meet = [first.place.name, first.place.address].filter { !$0.isEmpty }.joined(separator: ", ")
        let isPartial = shown.count < stops.count
        lines.append("\(title) · \(date.shortDay)")
        lines.append(isPartial ? "Next: \(first.start.shortTime) at \(meet)" : "Meet \(first.start.shortTime) at \(meet)")
        lines.append("")

        for (index, stop) in shown.enumerated() {
            lines.append(options.showPrices
                ? "\(stop.start.shortTime)  \(stop.place.name) (\(stop.estimatedCost.dollarsText))"
                : "\(stop.start.shortTime)  \(stop.place.name)")
            if options.showTravel, index < shown.count - 1, let leg = leg(after: stop) {
                lines.append("   ↓ \(leg.messageText(showPrice: options.showPrices))")
            }
        }

        lines.append("")
        let ends = shown.last.map { "Done by \($0.end.shortTime)." } ?? ""
        if options.showPrices {
            lines.append(costLine(for: shown, isPartial: isPartial) + " " + ends)
        } else {
            lines.append(ends)
        }
        lines.append("Planned with Plandit")
        return lines.joined(separator: "\n")
    }

    /// "About $42 per person, including $5.80 in subway fares." For what's left: "About $22 more per person."
    private func costLine(for shown: [PlanStop], isPartial: Bool) -> String {
        let ids = Set(shown.map(\.id))
        let shownLegs = legs.filter { ids.contains($0.fromStopID) && ids.contains($0.toStopID) }
        let fares = shownLegs.filter(\.mode.isTransit).reduce(0) { $0 + $1.cost }
        let rides = shownLegs.filter { $0.mode == .drive }.reduce(0) { $0 + $1.cost }
        let total = isPartial
            ? shown.reduce(0) { $0 + $1.estimatedCost } + fares + rides
            : totalCost
        var including: [String] = []
        if fares > 0 { including.append("\(fares.dollarsText) in subway fares") }
        if rides > 0 { including.append("\(rides.wholeDollarsText) in rides") }
        let amount = isPartial ? "About \(total.wholeDollarsText) more per person" : "About \(total.wholeDollarsText) per person"
        return including.isEmpty ? amount + "." : amount + ", including \(including.joined(separator: " and "))."
    }
}

extension TravelLeg {
    /// "22 min walk", "35 min subway (4 and 7 trains, $2.90)", "18 min drive (about $14)".
    func messageText(showPrice: Bool) -> String {
        let time = minutes.durationText
        switch mode {
        case .walk:
            return "\(time) walk"
        case .subway, .bus:
            var extra = [detail].compactMap { $0 }.filter { !$0.isEmpty }
            if showPrice, cost > 0 { extra.append(cost.dollarsText) }
            let way = mode == .bus ? "bus" : "subway"
            return extra.isEmpty ? "\(time) \(way)" : "\(time) \(way) (\(extra.joined(separator: ", ")))"
        case .drive:
            return showPrice ? "\(time) drive (about \(cost.wholeDollarsText))" : "\(time) drive"
        }
    }
}
