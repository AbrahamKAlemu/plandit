import Foundation

/// A time of day as the friends' input link writes it, "13:30", in minutes after midnight.
nonisolated struct ClockTime: Comparable, Hashable, Sendable {
    var minutes: Int

    init(minutes: Int) { self.minutes = minutes }

    init(_ hour: Int, _ minute: Int = 0) { minutes = hour * 60 + minute }

    /// "HH:MM", 00:00 to 23:59; nil otherwise.
    init?(_ text: String) {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let hour = Int(parts[0]), let minute = Int(parts[1]),
              (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        minutes = hour * 60 + minute
    }

    /// The time of day of `date` in `calendar`'s time zone.
    init(of date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// "13:30", as the server takes it.
    var text: String { String(format: "%02d:%02d", minutes / 60, minutes % 60) }

    /// This time on `day` in `calendar`'s time zone. Set from the day's own clock, not counted from
    /// midnight, so 1 PM stays 1 PM on the days the clocks change.
    func date(on day: Date, calendar: Calendar = .current) -> Date? {
        calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: day)
    }

    static func < (lhs: ClockTime, rhs: ClockTime) -> Bool { lhs.minutes < rhs.minutes }
}

/// The organizer's "Ask friends what works" link (plandit.app/g/<slug>, group plans mode 2), as
/// the app keeps it: in the snapshot, like `SharedLink`, so the answers can be read later and on
/// another phone. Friends' answers themselves are never kept (`PlanRequest`, GS-7).
struct PlanRequestLink: Codable, Equatable {
    var slug: String
    var url: URL
    /// The plan's day, "2026-11-22", in `timeZone`.
    var day: String
    var windowStart: String
    var windowEnd: String
    /// The organizer's time zone when they made it (IANA name).
    var timeZone: String
    var answersBy: Date
    /// The saved posts friends can star, in the organizer's order.
    var placeIDs: [UUID]
    /// Today's plan (`DayPlan.id`) once "Build our plan" put the answers in it.
    var builtPlanID: UUID?
    /// The stops "Build our plan" put in it, so "Try again" never puts another plan on the link.
    var builtStopIDs: [UUID]?

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone) ?? .current
        return calendar
    }

    /// Midnight at the start of the plan's day, in `timeZone`.
    var dayDate: Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    var start: ClockTime? { ClockTime(windowStart) }
    var end: ClockTime? { ClockTime(windowEnd) }

    /// The plan's day is today, so the plan can go in Today.
    func isToday(now: Date) -> Bool {
        day == DayPlan.isoDay(now, calendar: calendar)
    }

    /// The plan's day has gone by.
    func isOver(now: Date) -> Bool {
        day < DayPlan.isoDay(now, calendar: calendar)
    }
}

/// A friends' input link as `GET /api/plan-requests/<slug>/` returns it, with every answer. Kept in
/// memory only: answers are never saved, synced or used for anything but this plan (GS-7).
nonisolated struct PlanRequest: Equatable, Sendable {
    nonisolated enum Status: String, Sendable {
        /// Friends can answer.
        case open
        /// Past the deadline, or the organizer closed it.
        case closed
        /// A plan was shared with this request: the link opens it.
        case built
    }

    var slug: String
    var url: URL
    var status: Status
    var placeIDs: [UUID]
    var answersBy: Date
    /// The built plan's /p/ slug; nil until built.
    var planSlug: String?
    var answers: [GroupAnswer]
}

/// A friend's answer on a /g/ link: a first name, their budget for the day (train included), when
/// they're free and up to 3 starred places.
nonisolated struct GroupAnswer: Identifiable, Equatable, Sendable {
    var id: UUID
    var name: String
    var budget: Int
    var freeFrom: ClockTime
    var freeUntil: ClockTime
    /// The saved posts they starred (the request's place ids).
    var stars: [UUID]
    var createdAt: Date
    var updatedAt: Date
}

extension PlanRequest {
    /// The server's JSON. An answer this build can't read is skipped rather than failing the whole
    /// request, and so is a place id that isn't one.
    nonisolated static func decode(_ data: Data) throws -> PlanRequest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let wire = try decoder.decode(Wire.self, from: data)
        guard let status = Status(rawValue: wire.status) else { throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "status")) }
        return PlanRequest(
            slug: wire.slug,
            url: wire.url,
            status: status,
            placeIDs: wire.places.compactMap { UUID(uuidString: $0.id) },
            answersBy: wire.answersBy,
            planSlug: wire.planSlug,
            answers: wire.answers.compactMap(\.answer)
        )
    }

    private nonisolated struct Wire: Decodable {
        struct Place: Decodable { var id: String }
        var slug: String
        var url: URL
        var status: String
        var places: [Place]
        var answersBy: Date
        var planSlug: String?
        var answers: [LossyAnswer]
    }

    private nonisolated struct LossyAnswer: Decodable {
        var answer: GroupAnswer?

        init(from decoder: Decoder) throws {
            answer = try? AnswerWire(from: decoder).answer
        }
    }

    private nonisolated struct AnswerWire: Decodable {
        var id: String
        var name: String
        var budget: Int
        var freeFrom: String
        var freeUntil: String
        var stars: [String]
        var createdAt: Date
        var updatedAt: Date

        var answer: GroupAnswer? {
            guard let id = UUID(uuidString: id), let from = ClockTime(freeFrom), let until = ClockTime(freeUntil) else { return nil }
            return GroupAnswer(id: id, name: name, budget: budget, freeFrom: from, freeUntil: until,
                               stars: stars.compactMap { UUID(uuidString: $0) }, createdAt: createdAt, updatedAt: updatedAt)
        }
    }
}

/// What `POST /api/plan-requests/` takes: 2 to 10 saved places, the day, the time range and the
/// deadline for answers (GI-1).
nonisolated struct PlanRequestDraft: Encodable, Equatable, Sendable {
    /// One saved place, as friends see it: name, neighborhood, kind and the cost in dollars.
    nonisolated struct Place: Encodable, Equatable, Sendable {
        var id: UUID
        var name: String
        var neighborhood: String
        var kind: String
        var costText: String
    }

    var places: [Place]
    /// "2026-11-22"
    var day: String
    /// "12:00"
    var windowStart: String
    var windowEnd: String
    var timeZone: String
    /// ISO 8601 with Z, as the server needs a moment, not a local time.
    var answersBy: String

    static let minPlaces = 2
    static let maxPlaces = 10
    static let maxDaysAhead = 14
    static let minWindowMinutes = 60
}

extension PlanRequestDraft {
    /// The request for these saved posts (in this order) on `day`, from `start` to `end`, with
    /// answers by `answersBy`. Posts without a place are left out. Texts are cut to the server's
    /// limits, as the shared plan's are.
    @MainActor init(posts: [SavedPost], day: Date, start: ClockTime, end: ClockTime, answersBy: Date, calendar: Calendar = .current) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        self.init(
            places: posts.compactMap { SharedPlanPayload.Alternate(post: $0, showPrice: true) }.map {
                Place(id: $0.id, name: $0.name, neighborhood: $0.neighborhood, kind: $0.kind, costText: $0.costText)
            },
            day: DayPlan.isoDay(day, calendar: calendar),
            windowStart: start.text,
            windowEnd: end.text,
            timeZone: calendar.timeZone.identifier,
            answersBy: formatter.string(from: answersBy)
        )
    }
}

extension PlanRequestLink {
    /// What the app keeps once the server made the link for `draft`.
    init(request: PlanRequest, draft: PlanRequestDraft, answersBy: Date) {
        self.init(slug: request.slug, url: request.url, day: draft.day, windowStart: draft.windowStart, windowEnd: draft.windowEnd,
                  timeZone: draft.timeZone, answersBy: answersBy, placeIDs: draft.places.map(\.id), builtPlanID: nil)
    }
}
