import Foundation

/// A friend's answer on the shared plan's page (group plans, mode 1), as
/// `GET /api/shares/<slug>/answers/` returns it. Kept in memory only: never saved, synced or used
/// for anything but this plan (GS-7).
nonisolated struct ShareAnswer: Identifiable, Equatable, Sendable {
    nonisolated enum Status: String, Sendable {
        /// "I'm in"
        case `in`
        /// "Can't make it"
        case out
    }

    var id: UUID
    var name: String
    var status: Status
    /// Stop id → the saved post they picked instead (`SharedPlanPayload.Alternate.id`), or nil for
    /// "I'd swap this" without a pick.
    var swaps: [UUID: UUID?]
    var createdAt: Date
    var updatedAt: Date
}

extension ShareAnswer {
    /// The server's `{"answers": [...]}`, oldest first. An answer this build can't read is skipped
    /// rather than failing the whole list.
    nonisolated static func decodeList(_ data: Data) throws -> [ShareAnswer] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(List.self, from: data).answers.compactMap(\.answer)
    }

    private nonisolated struct List: Decodable {
        var answers: [Lossy]
    }

    private nonisolated struct Lossy: Decodable {
        var answer: ShareAnswer?

        init(from decoder: Decoder) throws {
            answer = try? Wire(from: decoder).answer
        }
    }

    /// camelCase, ids as strings in whatever case the app sent them.
    private nonisolated struct Wire: Decodable {
        var id: String
        var name: String
        var status: String
        var swaps: [String: String?]
        var createdAt: Date
        var updatedAt: Date

        var answer: ShareAnswer? {
            guard let id = UUID(uuidString: id), let status = Status(rawValue: status) else { return nil }
            var parsed: [UUID: UUID?] = [:]
            for (stop, pick) in swaps {
                guard let stopID = UUID(uuidString: stop) else { continue }
                parsed[stopID] = pick.flatMap { UUID(uuidString: $0) }
            }
            return ShareAnswer(id: id, name: name, status: status, swaps: parsed, createdAt: createdAt, updatedAt: updatedAt)
        }
    }
}

/// Who's in and who can't make it, for Today and the answers sheet.
struct ShareAnswerSummary: Equatable {
    var inNames: [String]
    var outNames: [String]

    /// "3 in · 1 can't make it".
    var text: String { ShareAnswersText.summary(inCount: inNames.count, outCount: outNames.count) ?? "" }

    /// What VoiceOver reads: "Friends' answers: 3 in, 1 can't make it".
    var accessibilityText: String {
        "Friends' answers: " + text.replacingOccurrences(of: " · ", with: ", ")
    }
}

/// One friend's "I'd swap this" on one stop.
struct SwapPick: Equatable, Identifiable {
    var answerID: UUID
    var name: String
    /// The saved post they'd go to instead; nil when they didn't pick one.
    var alternateID: UUID?

    var id: String { ShareAnswers.keepKey(answerID: answerID, alternateID: alternateID) }
}

/// Turning friends' answers into what Today shows.
enum ShareAnswers {
    static func summary(_ answers: [ShareAnswer]) -> ShareAnswerSummary? {
        guard !answers.isEmpty else { return nil }
        return ShareAnswerSummary(
            inNames: answers.filter { $0.status == .in }.map(\.name),
            outNames: answers.filter { $0.status == .out }.map(\.name)
        )
    }

    /// Swap picks per stop, for stops still ahead in `plan`. Answers about stops that are gone,
    /// done or underway don't show, and neither do picks the organizer kept the stop over.
    static func swapMarks(_ answers: [ShareAnswer], plan: DayPlan, kept: Set<String>) -> [UUID: [SwapPick]] {
        var marks: [UUID: [SwapPick]] = [:]
        for stop in plan.stops where stop.status == .upcoming {
            let picks = answers.compactMap { answer -> SwapPick? in
                guard let pick = answer.swaps[stop.id] else { return nil }
                let swap = SwapPick(answerID: answer.id, name: answer.name, alternateID: pick)
                return kept.contains(keepKey(stopID: stop.id, pick: swap)) ? nil : swap
            }
            if !picks.isEmpty { marks[stop.id] = picks }
        }
        return marks
    }

    /// What "Keep it" remembers for one pick: who, which stop and what they picked. A friend who
    /// picks something else later shows again.
    static func keepKey(stopID: UUID, pick: SwapPick) -> String {
        "\(stopID.uuidString)/\(pick.id)"
    }

    fileprivate static func keepKey(answerID: UUID, alternateID: UUID?) -> String {
        "\(answerID.uuidString)/\(alternateID?.uuidString ?? "-")"
    }
}

enum ShareAnswersText {
    /// "3 in · 1 can't make it", "2 in", "1 can't make it"; nil with no answers.
    static func summary(inCount: Int, outCount: Int) -> String? {
        var parts: [String] = []
        if inCount > 0 { parts.append("\(inCount) in") }
        if outCount > 0 { parts.append("\(outCount) can't make it") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The mark on a stop: "2 would swap".
    static func wouldSwap(_ count: Int) -> String {
        "\(count) would swap"
    }
}
