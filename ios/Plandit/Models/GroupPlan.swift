import Foundation

// What the server says about a group plan (mode 3, "edit together"): `/api/group-plans/`.
// Plans go both ways with a plain `JSONEncoder`/`JSONDecoder`, so dates are numbers, as the server
// requires; never the snapshot's ISO 8601 coder.

/// One person in a group plan, in join order (the organizer first). Named apart from
/// `GroupMember`, the friends' answers in mode 2.
struct GroupPlanMember: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var isOrganizer: Bool
}

/// A group as create, join and GET answer it.
struct GroupPlanDetail: Codable, Equatable {
    var id: UUID
    /// The plan's day, `YYYY-MM-DD`.
    var date: String
    var version: Int
    /// Goes up when someone joins, leaves or is removed, or the link is replaced.
    var membersVersion: Int
    var plan: DayPlan
    var members: [GroupPlanMember]
    /// This person's member id in the group.
    var memberId: UUID
    var isOrganizer: Bool
    /// The organizer's link to share; nil for everyone else.
    var inviteUrl: URL?
}

/// One row of `GET /api/group-plans/`.
struct GroupPlanSummary: Codable, Equatable {
    var id: UUID
    var date: String
    var version: Int
    var membersVersion: Int
    var etag: String
    var organizerName: String
    var memberCount: Int
    var memberId: UUID
    var isOrganizer: Bool
    var inviteUrl: URL?
}

/// What the join sheet shows before joining.
struct GroupInvitePreview: Codable, Equatable {
    var organizerName: String
    var date: String
    var memberCount: Int
}

/// An edit someone made, from a 409: who (nil once they've left) and which stops.
struct GroupPlanLoggedEdit: Codable, Equatable {
    var version: Int
    var authorId: UUID?
    var authorName: String?
    var kind: String
    var stopIds: [UUID]
}

/// A 409: the plan moved on from the version the edit was made on.
struct GroupPlanConflict: Codable, Equatable {
    var version: Int
    var membersVersion: Int
    var plan: DayPlan
    var members: [GroupPlanMember]
    /// Every edit after the edit's base version, oldest first, when `editsFrom` is the version
    /// right after it; otherwise some are missing.
    var edits: [GroupPlanLoggedEdit]
    var editsFrom: Int?
}

/// A PUT the server stored (or had already stored, for a retried `editId`).
struct GroupPlanSaved: Codable, Equatable {
    var version: Int
    var membersVersion: Int
    var members: [GroupPlanMember]
}

/// The body of a PUT.
struct GroupPlanUpdate: Codable, Equatable {
    struct Edit: Codable, Equatable {
        var kind: String
        var stopIds: [UUID]
    }

    var baseVersion: Int
    var editId: UUID
    var edit: Edit
    var plan: DayPlan
}

enum GroupPlanFetch: Equatable {
    /// 304: the ETag sent still matches.
    case notModified
    case plan(GroupPlanDetail, etag: String?)
    /// 404: the group ended, or this person isn't in it any more.
    case gone
}

enum GroupPlanPutResult: Equatable {
    case saved(GroupPlanSaved, etag: String?)
    case conflict(GroupPlanConflict, etag: String?)
    case gone
    /// 400 or 403, with the server's words when it gave some.
    case rejected(String?)
    /// 413.
    case tooLarge(String?)
}

nonisolated enum GroupPlanError: Error, Equatable {
    /// 400 or 403 on create, join, leave or remove, with the server's words when it gave some.
    case rejected(String?)
    case tooLarge(String?)
}
