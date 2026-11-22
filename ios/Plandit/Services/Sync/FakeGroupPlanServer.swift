#if DEBUG
import Foundation

/// The group plan server in memory, for unit tests and `-fakeGroupPlans` UI tests. One account
/// ("you") calls it; other members' edits, joins, removals and the group ending are scripted.
///
/// It keeps the rules the app relies on (contract g3a): `version` and `membersVersion`, the ETag
/// `"<version>.<membersVersion>"` compared weakly, an `editId` already logged answering with its
/// version, a stale base answering 409 with the edits since it (authors looked up when read, so a
/// member who left is null), 404 for anyone not in the group, an organizer who can't leave, and
/// the 64 KB plan limit. It doesn't check dates or the plan's shape.
///
/// Scripting, for a test:
/// - `script(_:_:)` answers the next call of a kind differently: 304, 404, no answer, saved but
///   the answer lost, a status, or a body this build can't read.
/// - `holdNext(_:)` keeps the next answer of a kind (worked out when asked) until `release(_:)`.
/// - `beforeNext(_:_:)` runs something just before the next call of a kind is handled, such as
///   another member's edit landing first.
/// - `change(_:by:kind:stopIDs:plan:)` is another member's edit; `forgetEdits` prunes the log.
actor FakeGroupPlanServer: GroupPlanServing {
    enum Call: Sendable, Hashable {
        case list, create, fetch, put, end, preview, join, newInvite, removeMember
    }

    enum Scripted: Sendable, Equatable {
        /// A fetch answers 304 whatever its ETag.
        case notModified
        /// A fetch answers 200 with the plan even when its ETag matches (what the URL cache can do).
        case fullAnswer
        /// 404, or what each call makes of it.
        case gone
        /// No HTTP answer, and nothing happened on the server.
        case network
        /// The server did it, then the answer was lost.
        case lostAfterSaving
        /// An unexpected status (`APIError.status`), and nothing happened.
        case status(Int)
        /// The server did it, but this build can't read the answer (`APIError.invalidResponse`).
        case unreadable
    }

    /// One GET of a group, with the `If-None-Match` it sent (nil when none).
    struct Fetch: Sendable, Equatable {
        var id: UUID
        var etag: String?
    }

    /// What a test can read back about a group.
    struct Info: Sendable {
        var version: Int
        var membersVersion: Int
        var plan: DayPlan
        var memberNames: [String]
        var token: String
    }

    private struct Member: Sendable {
        var id: UUID
        var name: String
        var isYou: Bool
    }

    private struct Logged: Sendable {
        var version: Int
        var authorID: UUID?
        var kind: String
        var stopIDs: [UUID]
        var editID: UUID?
    }

    private struct Group: Sendable {
        var id: UUID
        var date: String
        var version = 1
        var membersVersion = 1
        var plan: DayPlan
        /// Organizer first, then in join order.
        var members: [Member]
        var token: String
        var log: [Logged] = []
        /// The organizer removed you: no preview or join with any link (MF-G).
        var removedYou = false
        var dayOver = false

        var you: Member? { members.first(where: \.isYou) }
    }

    nonisolated static let maxPlanBytes = 65_536
    nonisolated static let tooLargeDetail = "This plan is too big to save for the group. Remove a stop and try again."
    nonisolated static let organizerLeavesDetail = "Organizers can't leave their own plan. End the plan instead, which removes it for everyone."
    nonisolated static let inviteBase = "https://plandit.app/j/"

    private let yourName: String
    private var groups: [Group] = []
    private var tokens = 0
    private var scripts: [(call: Call, answer: Scripted)] = []
    private var holds: [Call: Int] = [:]
    private var held: [(call: Call, continuation: CheckedContinuation<Void, Never>)] = []
    private var triggers: [Call: [@Sendable () async -> Void]] = [:]
    /// The log keeps this many edits per group, like the server's 200.
    var editsKept = 200

    /// Every call, in order, scripted ones too.
    private(set) var calls: [Call] = []
    /// Each GET of a group.
    private(set) var fetches: [Fetch] = []
    /// ETags go out weak (`W/"4.2"`), as a proxy might make them.
    private var weakETags = false
    /// The body of each PUT, scripted ones too.
    private(set) var updates: [GroupPlanUpdate] = []

    init(yourName: String = "Sofia") {
        self.yourName = yourName
    }

    // MARK: - Scripting

    func script(_ call: Call, _ answer: Scripted) {
        scripts.append((call, answer))
    }

    /// The next `call` is answered as the server is when it's asked, but only after `release`.
    func holdNext(_ call: Call) {
        holds[call, default: 0] += 1
    }

    /// Lets held answers go, oldest first: every one, or only those of `call`.
    func release(_ call: Call? = nil) {
        let releasing = held.filter { call == nil || $0.call == call }
        held.removeAll { call == nil || $0.call == call }
        for entry in releasing { entry.continuation.resume() }
    }

    var heldCount: Int { held.count }

    func beforeNext(_ call: Call, _ action: @escaping @Sendable () async -> Void) {
        triggers[call, default: []].append(action)
    }

    func useWeakETags() {
        weakETags = true
    }

    func count(_ call: Call) -> Int {
        calls.filter { $0 == call }.count
    }

    /// A group someone else (or you, when `organizer` is nil) organizes. Returns its id.
    @discardableResult
    func seedGroup(id: UUID = UUID(), plan: DayPlan, date: String, organizer: String?, others: [String] = [], youAreMember: Bool = true) -> UUID {
        var members: [Member] = []
        if let organizer {
            members.append(Member(id: UUID(), name: organizer, isYou: false))
            if youAreMember { members.append(Member(id: UUID(), name: yourName, isYou: true)) }
        } else {
            members.append(Member(id: UUID(), name: yourName, isYou: true))
        }
        members += others.map { Member(id: UUID(), name: $0, isYou: false) }
        groups.append(Group(id: id, date: date, plan: plan, members: members, token: newToken()))
        return id
    }

    func info(_ id: UUID) -> Info? {
        guard let group = groups.first(where: { $0.id == id }) else { return nil }
        return Info(version: group.version, membersVersion: group.membersVersion, plan: group.plan,
                    memberNames: group.members.map(\.name), token: group.token)
    }

    /// Another member's edit (or, with a name that isn't a member's, one whose author has left).
    /// Returns the new version.
    @discardableResult
    func change(_ id: UUID, by name: String?, kind: String, stopIDs: [UUID], plan: DayPlan) -> Int {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return 0 }
        groups[index].version += 1
        groups[index].plan = plan
        let author = groups[index].members.first { !$0.isYou && $0.name == name }
        log(Logged(version: groups[index].version, authorID: author?.id, kind: kind, stopIDs: stopIDs, editID: nil), in: index)
        return groups[index].version
    }

    /// Drops logged edits up to `version`, so a 409's list starts later (`editsFrom` past the base).
    func forgetEdits(_ id: UUID, through version: Int) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].log.removeAll { $0.version <= version }
    }

    @discardableResult
    func addMember(_ name: String, to id: UUID) -> UUID {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return UUID() }
        let member = Member(id: UUID(), name: name, isYou: false)
        groups[index].members.append(member)
        groups[index].membersVersion += 1
        return member.id
    }

    func removeMember(named name: String, from id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].members.removeAll { !$0.isYou && $0.name == name }
        groups[index].membersVersion += 1
    }

    /// The organizer removed you.
    func removeYou(from id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].members.removeAll(where: \.isYou)
        groups[index].removedYou = true
        groups[index].membersVersion += 1
    }

    /// The organizer ended it (or the purge deleted it).
    func endGroup(_ id: UUID) {
        groups.removeAll { $0.id == id }
    }

    func setDayOver(_ id: UUID) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[index].dayOver = true
    }

    // MARK: - GroupPlanServing

    func list() async throws -> [GroupPlanSummary] {
        let scripted = await begin(.list)
        let answer = groups.filter { $0.you != nil }.map(summary)
        try await finish(.list, scripted, gone: { throw APIError.status(404) })
        return answer
    }

    func create(date: String, plan: DayPlan) async throws -> (GroupPlanDetail, etag: String?) {
        let scripted = await begin(.create)
        var answer: (GroupPlanDetail, String)?
        var refusal: GroupPlanError?
        if Self.acts(scripted) {
            if await Self.size(of: plan) > Self.maxPlanBytes {
                refusal = .tooLarge(Self.tooLargeDetail)
            } else if let existing = groups.first(where: { $0.plan.id == plan.id && $0.members.first?.isYou == true }) {
                // A double tap or a retry: that group, unchanged.
                answer = (detail(existing), etag(existing))
            } else {
                let group = Group(id: UUID(), date: date, plan: plan, members: [Member(id: UUID(), name: yourName, isYou: true)], token: newToken())
                groups.append(group)
                answer = (detail(group), etag(group))
            }
        }
        try await finish(.create, scripted, gone: { throw APIError.status(404) })
        if let refusal { throw refusal }
        guard let answer else { throw APIError.status(500) }
        return (answer.0, answer.1)
    }

    func fetch(_ id: UUID, etag: String?) async throws -> GroupPlanFetch {
        let scripted = await begin(.fetch)
        fetches.append(Fetch(id: id, etag: etag))
        var answer: GroupPlanFetch = .gone
        if let group = visible(id) {
            let matches = etag.map { Self.matches($0, self.etag(group)) } == true && scripted != .fullAnswer
            answer = matches ? .notModified : .plan(detail(group), etag: self.etag(group))
        }
        if scripted == .notModified { answer = .notModified }
        var gone = false
        try await finish(.fetch, scripted, gone: { gone = true })
        return gone ? .gone : answer
    }

    func put(_ id: UUID, _ update: GroupPlanUpdate) async throws -> GroupPlanPutResult {
        let scripted = await begin(.put)
        updates.append(update)
        var answer = GroupPlanPutResult.gone
        if Self.acts(scripted) {
            answer = store(update, in: id, size: await Self.size(of: update.plan))
        }
        var gone = false
        try await finish(.put, scripted, gone: { gone = true })
        return gone ? .gone : answer
    }

    func end(_ id: UUID) async throws -> Bool {
        let scripted = await begin(.end)
        var answer = false
        if Self.acts(scripted),
           let group = visible(id), group.members.first?.isYou == true {
            groups.removeAll { $0.id == id }
            answer = true
        }
        try await finish(.end, scripted, gone: { answer = false })
        return answer
    }

    func preview(token: String) async throws -> GroupInvitePreview? {
        let scripted = await begin(.preview)
        let answer = joinable(token).map {
            GroupInvitePreview(organizerName: $0.members.first?.name ?? "Friend", date: $0.date, memberCount: $0.members.count)
        }
        var gone = false
        try await finish(.preview, scripted, gone: { gone = true })
        return gone ? nil : answer
    }

    func join(token: String) async throws -> (GroupPlanDetail, etag: String?)? {
        let scripted = await begin(.join)
        var answer: (GroupPlanDetail, String)?
        if Self.acts(scripted),
           let group = joinable(token), let index = groups.firstIndex(where: { $0.id == group.id }) {
            if groups[index].you == nil {
                groups[index].members.append(Member(id: UUID(), name: yourName, isYou: true))
                groups[index].membersVersion += 1
            }
            answer = (detail(groups[index]), etag(groups[index]))
        }
        var gone = false
        try await finish(.join, scripted, gone: { gone = true })
        guard !gone, let answer else { return nil }
        return (answer.0, answer.1)
    }

    func newInvite(_ id: UUID) async throws -> URL? {
        let scripted = await begin(.newInvite)
        var answer: URL?
        if Self.acts(scripted),
           let index = groups.firstIndex(where: { $0.id == id }), groups[index].members.first?.isYou == true {
            groups[index].token = newToken()
            groups[index].membersVersion += 1
            answer = URL(string: Self.inviteBase + groups[index].token)
        }
        try await finish(.newInvite, scripted, gone: { answer = nil })
        return answer
    }

    func removeMember(_ memberID: UUID, from id: UUID) async throws -> Bool {
        let scripted = await begin(.removeMember)
        var answer = false
        if Self.acts(scripted),
           let index = groups.firstIndex(where: { $0.id == id }), let you = groups[index].you {
            let youOrganize = groups[index].members.first?.isYou == true
            if memberID == you.id {
                if youOrganize {
                    try await finish(.removeMember, nil, gone: {})
                    throw GroupPlanError.rejected(Self.organizerLeavesDetail)
                }
                groups[index].members.removeAll(where: \.isYou)
                groups[index].membersVersion += 1
                answer = true
            } else if youOrganize, groups[index].members.contains(where: { $0.id == memberID }) {
                groups[index].members.removeAll { $0.id == memberID }
                groups[index].membersVersion += 1
                answer = true
            }
        }
        try await finish(.removeMember, scripted, gone: { answer = false })
        return answer
    }

    // MARK: - Internals

    /// Records the call, runs its trigger and takes its script.
    private func begin(_ call: Call) async -> Scripted? {
        calls.append(call)
        if var waiting = triggers[call], !waiting.isEmpty {
            let action = waiting.removeFirst()
            triggers[call] = waiting
            await action()
        }
        guard let index = scripts.firstIndex(where: { $0.call == call }) else { return nil }
        return scripts.remove(at: index).answer
    }

    /// Holds the answer if asked to, then turns the script into what the client would see.
    private func finish(_ call: Call, _ scripted: Scripted?, gone: () throws -> Void) async throws {
        if let count = holds[call], count > 0 {
            holds[call] = count - 1
            await withCheckedContinuation { held.append((call, $0)) }
        }
        switch scripted {
        case .network, .lostAfterSaving: throw APIError.network
        case .status(let status): throw APIError.status(status)
        case .unreadable: throw APIError.invalidResponse
        case .gone: try gone()
        case .notModified, .fullAnswer, nil: break
        }
    }

    /// Whether the server does the work: not when there was no answer, a status or a 404 instead.
    private static func acts(_ scripted: Scripted?) -> Bool {
        switch scripted {
        case nil, .notModified, .fullAnswer, .lostAfterSaving, .unreadable: true
        case .network, .status, .gone: false
        }
    }

    /// The PUT's rules in the server's order.
    private func store(_ update: GroupPlanUpdate, in id: UUID, size: Int) -> GroupPlanPutResult {
        guard let index = groups.firstIndex(where: { $0.id == id }), let you = groups[index].you else { return .gone }
        guard size <= Self.maxPlanBytes else { return .tooLarge(Self.tooLargeDetail) }
        if let logged = groups[index].log.first(where: { $0.editID == update.editId }) {
            guard logged.authorID == you.id else { return .rejected("Already used by another member's edit. Send a new one.") }
            // The logged version with today's members, and an ETag to match, as the server's.
            return .saved(saved(groups[index], version: logged.version), etag: etag(groups[index], version: logged.version))
        }
        guard update.plan.id == groups[index].plan.id else { return .rejected("This isn't the group's plan.") }
        guard !groups[index].dayOver else { return .rejected("This plan's day is over, so it can't be changed.") }
        guard update.baseVersion == groups[index].version else {
            let group = groups[index]
            let edits = group.log.filter { $0.version > update.baseVersion }.map { logged(group, $0) }
            let conflict = GroupPlanConflict(version: group.version, membersVersion: group.membersVersion, plan: group.plan,
                                             members: members(group), edits: edits, editsFrom: edits.first?.version)
            return .conflict(conflict, etag: etag(group))
        }
        groups[index].version += 1
        groups[index].plan = update.plan
        log(Logged(version: groups[index].version, authorID: you.id, kind: update.edit.kind, stopIDs: update.edit.stopIds, editID: update.editId), in: index)
        return .saved(saved(groups[index], version: groups[index].version), etag: etag(groups[index]))
    }

    private func log(_ entry: Logged, in index: Int) {
        groups[index].log.append(entry)
        if groups[index].log.count > editsKept { groups[index].log.removeFirst(groups[index].log.count - editsKept) }
    }

    private func visible(_ id: UUID) -> Group? {
        groups.first { $0.id == id && $0.you != nil }
    }

    private func joinable(_ token: String) -> Group? {
        guard let group = groups.first(where: { $0.token == token }), !group.removedYou, !group.dayOver else { return nil }
        guard group.you != nil || group.members.count < 8 else { return nil }
        return group
    }

    private func newToken() -> String {
        tokens += 1
        return "fake-invite-for-tests-\(tokens)"
    }

    private func members(_ group: Group) -> [GroupPlanMember] {
        group.members.enumerated().map { GroupPlanMember(id: $1.id, name: $1.name, isOrganizer: $0 == 0) }
    }

    private func logged(_ group: Group, _ entry: Logged) -> GroupPlanLoggedEdit {
        let author = group.members.first { $0.id == entry.authorID }
        return GroupPlanLoggedEdit(version: entry.version, authorId: author?.id, authorName: author?.name, kind: entry.kind, stopIds: entry.stopIDs)
    }

    private func saved(_ group: Group, version: Int) -> GroupPlanSaved {
        GroupPlanSaved(version: version, membersVersion: group.membersVersion, members: members(group))
    }

    private func detail(_ group: Group) -> GroupPlanDetail {
        let organizes = group.members.first?.isYou == true
        return GroupPlanDetail(id: group.id, date: group.date, version: group.version, membersVersion: group.membersVersion,
                               plan: group.plan, members: members(group), memberId: group.you?.id ?? UUID(), isOrganizer: organizes,
                               inviteUrl: organizes ? URL(string: Self.inviteBase + group.token) : nil)
    }

    private func summary(_ group: Group) -> GroupPlanSummary {
        let organizes = group.members.first?.isYou == true
        return GroupPlanSummary(id: group.id, date: group.date, version: group.version, membersVersion: group.membersVersion,
                                etag: etag(group), organizerName: group.members.first?.name ?? "Friend", memberCount: group.members.count,
                                memberId: group.you?.id ?? UUID(), isOrganizer: organizes,
                                inviteUrl: organizes ? URL(string: Self.inviteBase + group.token) : nil)
    }

    private func etag(_ group: Group, version: Int? = nil) -> String {
        (weakETags ? "W/" : "") + "\"\(version ?? group.version).\(group.membersVersion)\""
    }

    /// Weak comparison, a list, or `*`, as the server's.
    private static func matches(_ ifNoneMatch: String, _ etag: String) -> Bool {
        ifNoneMatch.split(separator: ",").contains { part in
            var tag = part.trimmingCharacters(in: .whitespaces)
            if tag == "*" { return true }
            if tag.hasPrefix("W/") { tag.removeFirst(2) }
            return tag == etag.replacingOccurrences(of: "W/", with: "")
        }
    }

    /// The plan's JSON size. On the main actor, where `DayPlan`'s `Encodable` belongs.
    @MainActor private static func size(of plan: DayPlan) -> Int {
        (try? JSONEncoder().encode(plan).count) ?? 0
    }
}

extension FakeGroupPlanServer {
    nonisolated static let launchArgument = "-fakeGroupPlans"
    /// The seeded group's link, already joined (joining again changes nothing).
    nonisolated static let seededGroupID = UUID(uuidString: "9C1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
    /// A group Jordan organizes that you're not in yet, to join by link.
    nonisolated static let joinableGroupID = UUID(uuidString: "AD1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!

    /// `-fakeGroupPlans [scenario]`, for UI tests: a server where you're in Maya's group plan for
    /// today (with Jordan; every stop planned), and Jordan's group is open to join by link.
    /// Scenarios:
    /// - `empty`: no groups at all.
    /// - `mayaRemovesStop2`: just before your first change reaches the server, Maya removes the
    ///   plan's second stop, so a change to that stop isn't made and the message names her; a
    ///   change to another stop lands after it.
    /// nil without the argument.
    @MainActor
    static func launch(_ arguments: [String] = CommandLine.arguments, now: Date = .now, calendar: Calendar = .current) async -> FakeGroupPlanServer? {
        guard let index = arguments.firstIndex(of: launchArgument) else { return nil }
        let scenario = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
        let server = FakeGroupPlanServer()
        guard scenario != "empty" else { return server }
        var plan = SampleData.dayPlan
        plan.id = UUID(uuidString: "BE1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
        plan.date = now
        for stop in plan.stops.indices { plan.stops[stop].status = .upcoming }
        let date = GroupPlanDay.string(for: now, calendar: calendar)
        await server.seedGroup(id: seededGroupID, plan: plan, date: date, organizer: "Maya", others: ["Jordan"])
        var other = plan
        other.id = UUID(uuidString: "CF1C2A4E-1B2C-4D3E-8F90-A1B2C3D4E5F6")!
        other.title = "Jordan's day"
        await server.seedGroup(id: joinableGroupID, plan: other, date: date, organizer: "Jordan", youAreMember: false)
        if scenario == "mayaRemovesStop2" {
            await server.beforeNext(.put) { [weak server] in
                guard let server, let info = await server.info(seededGroupID), info.plan.stops.count > 1 else { return }
                let removed = await MainActor.run { () -> (DayPlan, UUID)? in
                    let stop = info.plan.stops[1]
                    guard let edit = PlanEdit.removing(stop.id, in: info.plan, travel: .walkAndTransit),
                          case .applied(let result) = PlanEdit.apply(edit, to: info.plan, now: now, calendar: calendar) else { return nil }
                    return (result, stop.id)
                }
                guard let removed else { return }
                await server.change(seededGroupID, by: "Maya", kind: "remove", stopIDs: [removed.1], plan: removed.0)
            }
        }
        return server
    }
}
#endif
