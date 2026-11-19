import Foundation

/// A plan shared as a link (plandit.app/p/<slug>). Anyone with the link sees the plan; the link
/// follows this plan, so editing it updates the page (`PlanditStore.sharedLink`).
struct SharedLink: Codable, Equatable {
    var slug: String
    var url: URL
    /// The `DayPlan.id` this link shows.
    var planID: UUID
    var showPrices: Bool
    var note: String
}

/// What the page shows, already formatted on the phone (times in the owner's time zone), in the
/// shape `POST /api/shares/` takes. The server stores and displays it as-is.
struct SharedPlanPayload: Encodable, Equatable {
    struct Stop: Encodable, Equatable {
        var name: String
        var place: String
        var address: String
        var timeText: String
        var durationText: String
        var costText: String
        var latitude: Double
        var longitude: Double
    }

    struct Leg: Encodable, Equatable {
        var text: String
    }

    var planId: UUID
    var title: String
    var dateText: String
    var timeText: String
    var note: String
    var costText: String
    var stops: [Stop]
    var legs: [Leg]
}

extension DayPlan {
    /// The page for this plan: every stop, the trip after each, and prices only if asked.
    func sharedPayload(showPrices: Bool, note: String) -> SharedPlanPayload {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = [stops.first?.start.shortTime, stops.last?.end.shortTime].compactMap { $0 }.joined(separator: " – ")
        return SharedPlanPayload(
            planId: id,
            title: title.isEmpty ? "A Plandit day" : title,
            dateText: date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            timeText: stops.count > 0 ? timeText : "",
            note: String(trimmedNote.prefix(280)),
            costText: showPrices ? "About \(totalCost.wholeDollarsText) per person" : "",
            stops: stops.map { stop in
                SharedPlanPayload.Stop(
                    name: stop.place.name,
                    place: [stop.place.category.label, stop.place.neighborhood].filter { !$0.isEmpty }.joined(separator: " · "),
                    address: stop.place.address,
                    timeText: stop.start.shortTime,
                    durationText: stop.durationMinutes.durationText,
                    costText: showPrices ? stop.estimatedCost.dollarsText : "",
                    latitude: stop.place.latitude,
                    longitude: stop.place.longitude
                )
            },
            legs: zip(stops, stops.dropFirst()).compactMap { from, _ in
                leg(after: from).map { SharedPlanPayload.Leg(text: $0.messageText(showPrice: showPrices)) }
            }
        )
    }
}
