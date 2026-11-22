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
    /// "Let friends suggest swaps": the page offers up to two of your saved places per stop.
    var suggestsSwaps = true
    /// Friends' swap picks the organizer answered with "Keep it" (`ShareAnswers.keepKey`), so their
    /// marks stay hidden until someone picks something else.
    var keptSwaps: [String] = []

    private enum CodingKeys: String, CodingKey { case slug, url, planID, showPrices, note, suggestsSwaps, keptSwaps }
}

extension SharedLink {
    /// Links saved before friends could answer still load, with swaps on.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        url = try c.decode(URL.self, forKey: .url)
        planID = try c.decode(UUID.self, forKey: .planID)
        showPrices = try c.decode(Bool.self, forKey: .showPrices)
        note = try c.decode(String.self, forKey: .note)
        suggestsSwaps = try c.decodeIfPresent(Bool.self, forKey: .suggestsSwaps) ?? true
        keptSwaps = try c.decodeIfPresent([String].self, forKey: .keptSwaps) ?? []
    }
}

/// What the page shows, already formatted on the phone (times in the owner's time zone), in the
/// shape `POST /api/shares/` takes. The server stores and displays it as-is.
///
/// Friends' answers (group plans, mode 1): `answers` turns on the "I'm in" form, `date` is the
/// plan's day (the server deletes answers 30 days after it), each stop carries its id for "I'd swap
/// this", and `alternates` are the saved places friends may pick instead. Today's production API
/// ignores these fields.
struct SharedPlanPayload: Encodable, Equatable {
    struct Stop: Encodable, Equatable {
        var id: UUID
        var name: String
        var place: String
        var address: String
        var timeText: String
        var durationText: String
        var costText: String
        var latitude: Double
        var longitude: Double
        /// At most 2; nil (left out of the JSON) when there are none.
        var alternates: [Alternate]?
    }

    /// One of the organizer's saves, offered as "<name> instead". `id` is the saved post's id.
    struct Alternate: Encodable, Equatable {
        var id: UUID
        var name: String
        var neighborhood: String
        var kind: String
        var costText: String
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
    var answers: Bool
    /// YYYY-MM-DD in the owner's time zone.
    var date: String
    var stops: [Stop]
    var legs: [Leg]
}

extension DayPlan {
    /// The page for this plan: every stop, the trip after each, and prices only if asked.
    /// `alternates` are the saves friends may pick instead of each stop (`SwapOptions.all`).
    func sharedPayload(showPrices: Bool, note: String, alternates: [UUID: [SavedPost]] = [:]) -> SharedPlanPayload {
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeText = [stops.first?.start.shortTime, stops.last?.end.shortTime].compactMap { $0 }.joined(separator: " – ")
        return SharedPlanPayload(
            planId: id,
            title: title.isEmpty ? "A Plandit day" : title,
            dateText: date.formatted(.dateTime.weekday(.wide).month(.wide).day()),
            timeText: stops.count > 0 ? timeText : "",
            note: String(trimmedNote.prefix(280)),
            costText: showPrices ? "About \(totalCost.wholeDollarsText) per person" : "",
            answers: true,
            date: Self.isoDay(date),
            stops: stops.map { stop in
                let offered = (alternates[stop.id] ?? []).prefix(SwapOptions.maxPerStop).compactMap {
                    SharedPlanPayload.Alternate(post: $0, showPrice: showPrices)
                }
                return SharedPlanPayload.Stop(
                    id: stop.id,
                    name: stop.place.name,
                    place: [stop.place.category.label, stop.place.neighborhood].filter { !$0.isEmpty }.joined(separator: " · "),
                    address: stop.place.address,
                    timeText: stop.start.shortTime,
                    durationText: stop.durationMinutes.durationText,
                    costText: showPrices ? stop.estimatedCost.dollarsText : "",
                    latitude: stop.place.latitude,
                    longitude: stop.place.longitude,
                    alternates: offered.isEmpty ? nil : offered
                )
            },
            legs: zip(stops, stops.dropFirst()).compactMap { from, _ in
                leg(after: from).map { SharedPlanPayload.Leg(text: $0.messageText(showPrice: showPrices)) }
            }
        )
    }

    /// "2026-11-22": the day in this phone's time zone, as the server's `date` takes it.
    static func isoDay(_ date: Date, calendar: Calendar = .current) -> String {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
    }
}

extension SharedPlanPayload.Alternate {
    /// Nil for a save without a place or a name (the server refuses a blank one). Texts are cut to
    /// the server's limits.
    init?(post: SavedPost, showPrice: Bool) {
        guard let place = post.place, !place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        self.init(
            id: post.id,
            name: String(place.name.prefix(120)),
            neighborhood: String(place.neighborhood.prefix(80)),
            kind: place.category.label,
            costText: showPrice ? (post.plannedCost?.dollarsText ?? "") : ""
        )
    }
}
