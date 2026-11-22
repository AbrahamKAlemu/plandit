import Foundation
import Observation

/// What the app shows for one group plan.
struct GroupPlanState: Identifiable, Equatable {
    var id: UUID
    /// The plan's day, `YYYY-MM-DD`.
    var date: String
    /// The server's plan with this phone's unsent edits on top; nil until first fetched.
    var plan: DayPlan?
    /// The server's version this phone holds.
    var version: Int
    var members: [GroupPlanMember]
    /// This person's member id in the group.
    var memberId: UUID?
    var isOrganizer: Bool
    var organizerName: String
    var memberCount: Int
    /// The organizer's link to share; nil for everyone else.
    var inviteUrl: URL?
    /// Edits made on this phone the server hasn't taken yet.
    var pendingEdits: Int
    /// The server answered in a way this build can't read: no edits until the app is updated.
    var isReadOnly: Bool
    /// Past 4 AM New York time the morning after the plan's day: filed under recent plans.
    var isDayOver: Bool
}

/// Something the person should hear about a group plan, through `GroupPlanStore.onMessage`.
struct GroupPlanMessage: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Edits dropped because the plan changed under them. `author` is who made the change that
        /// got in the way, when the server's list of edits says so for certain; nil otherwise.
        case editsNotMade(count: Int, author: String?, reason: PlanEdit.Reason)
        /// Three conflicts in a row: the latest plan is shown without the edit (N-3).
        case keptChanging
        /// 404: the group ended, or this person was removed.
        case groupGone
        /// 400 or 403 on an edit, with the server's words when it gave some.
        case editRefused(String?)
        /// 413 on an edit.
        case planTooLarge(String?)
        /// An answer this build can't read; the group is read-only until the app is updated.
        case readOnly
    }

    var id = UUID()
    var groupID: UUID
    var kind: Kind
    var text: String
}

enum GroupEditResult: Equatable {
    /// Shown now and on its way to the server.
    case queued
    /// The plan already shows it; nothing to send.
    case alreadyApplied
    case noLongerApplies(PlanEdit.Reason)
    /// No plan yet, read-only, the day is over, or the group is gone.
    case unavailable
}

enum GroupPlanFailure: Error, Equatable {
    /// No answer from the server.
    case offline
    /// The link or the group doesn't work any more (404).
    case gone
    /// 400 or 403, with the server's words when it gave some.
    case refused(String?)
    case tooLarge(String?)
    /// An answer this build can't read.
    case unreadable
    case failed
}

/// Group plans this account is in (mode 3, "edit together"): one shared plan per group, edited by
/// every member and polled for everyone else's changes. Never touches the personal plan, its
/// snapshot or its `/p/` page (SW-1, SW-2); a group's finished day is filed under recent plans once.
///
/// Edits (`PlanEdit`) wait in a queue per group, one PUT at a time, in order. What's shown is the
/// server's plan with the queue on top. A 409 brings the server's newer plan: each queued edit is
/// made again on it, and one that no longer applies is dropped with a message naming who got in
/// the way when the server's list of edits is complete. A lost answer is retried with the same
/// `editId`, so the server never takes an edit twice (MF-B). Groups and queued edits are cached
/// in `group-plans-<user id>.json`, never in the personal snapshot.
@Observable @MainActor
final class GroupPlanStore {
    private(set) var groups: [GroupPlanState] = []
    /// Messages for the person (the screens decide how to show them). Ones from before it's set
    /// (queued edits sent at launch) wait for it, the latest few, and are delivered in order then.
    @ObservationIgnored var onMessage: ((GroupPlanMessage) -> Void)? {
        didSet { deliverWaitingMessages() }
    }
    /// Where finished group days are filed.
    @ObservationIgnored weak var history: PlanditStore?

    /// An edit this phone made that the server hasn't taken yet.
    private struct PendingEdit: Codable, Equatable {
        var editId: UUID
        var edit: PlanEdit
        /// The version it was made on.
        var madeOn: Int
        /// 409s in a row.
        var conflicts = 0
        /// An earlier PUT got no answer, so the server may already have it: a 200 then says
        /// nothing about which plan it holds.
        var mayHaveLanded = false
        /// A PUT is out. Still set at launch means the app quit before the answer (OFF-3).
        var sending = false
    }

    private struct Record: Codable, Equatable {
        var id: UUID
        var date: String
        /// The version of `plan`; 0 before the first fetch.
        var version: Int
        var membersVersion: Int
        /// The `membersVersion` of the last whole group fetched: what `inviteUrl`, `memberId` and
        /// `isOrganizer` are from. A PUT's answer or a 409 brings newer members without them; until a
        /// GET brings the rest, no ETag is kept, so the next refresh fetches the whole group.
        var detailMembersVersion: Int
        /// Exactly as the server sent it, for `If-None-Match`; nil when it doesn't name what's held.
        var etag: String?
        /// The server's plan, without this phone's queued edits.
        var plan: DayPlan?
        var members: [GroupPlanMember]
        var memberId: UUID?
        var isOrganizer: Bool
        var organizerName: String
        var memberCount: Int
        var inviteUrl: URL?
        var pending: [PendingEdit] = []

        init(detail: GroupPlanDetail, etag: String?) {
            id = detail.id
            date = detail.date
            version = detail.version
            membersVersion = detail.membersVersion
            detailMembersVersion = detail.membersVersion
            self.etag = etag
            plan = detail.plan
            members = detail.members
            memberId = detail.memberId
            isOrganizer = detail.isOrganizer
            organizerName = detail.members.first(where: \.isOrganizer)?.name ?? ""
            memberCount = detail.members.count
            inviteUrl = detail.inviteUrl
        }

        /// A row of the list, before its plan is fetched.
        init(summary: GroupPlanSummary) {
            id = summary.id
            date = summary.date
            version = 0
            membersVersion = 0
            detailMembersVersion = 0
            plan = nil
            members = []
            memberId = summary.memberId
            isOrganizer = summary.isOrganizer
            organizerName = summary.organizerName
            memberCount = summary.memberCount
            inviteUrl = summary.inviteUrl
        }

        /// Takes what's newer: the plan by `version`, the members by `membersVersion`; an older
        /// answer (a poll that crossed a PUT) changes nothing (RB-7). The ETag is kept only while
        /// it names exactly the plan and members held, and the whole group was fetched at those
        /// members (a 304 would otherwise keep a link replaced on another phone).
        mutating func absorb(version: Int, membersVersion: Int, plan: DayPlan?, members: [GroupPlanMember], etag: String?) {
            let planNewer = plan != nil && (self.plan == nil || version > self.version)
            let membersNewer = membersVersion > self.membersVersion
            if planNewer, let plan {
                self.plan = plan
                self.version = version
            }
            if membersNewer {
                self.members = members
                self.membersVersion = membersVersion
                memberCount = members.count
                if let organizer = members.first(where: \.isOrganizer) { organizerName = organizer.name }
                if let me = members.first(where: { $0.id == memberId }) { isOrganizer = me.isOrganizer }
            }
            if self.version == version, self.membersVersion == membersVersion, detailMembersVersion == membersVersion {
                self.etag = etag
            } else if planNewer || membersNewer {
                self.etag = nil
            }
        }

        /// A whole group (a GET, create or join): also the link and this person's place in it, when
        /// newer than the ones held, even if a PUT's answer already brought these members.
        mutating func absorb(_ detail: GroupPlanDetail, etag: String?) {
            if detail.membersVersion > detailMembersVersion {
                detailMembersVersion = detail.membersVersion
                memberId = detail.memberId
                isOrganizer = detail.isOrganizer
                inviteUrl = detail.inviteUrl
            }
            absorb(version: detail.version, membersVersion: detail.membersVersion, plan: detail.plan, members: detail.members, etag: etag)
        }
    }

    private struct Cache: Codable {
        var groups: [Record]
    }

    /// The last 409: the edits after the PUT's base, to say who got in the way.
    private struct Conflict {
        var base: Int
        var version: Int
        var edits: [GroupPlanLoggedEdit]
        var editsFrom: Int?
    }

    static let pollInterval: Duration = .seconds(15)
    /// After this many 409s in a row an edit is dropped with a message (N-3).
    static let conflictsAllowed = 3
    /// Messages kept while nothing listens; older ones are dropped.
    private static let messagesKept = 3

    @ObservationIgnored private var records: [Record]
    @ObservationIgnored private let server: any GroupPlanServing
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let newID: () -> UUID
    @ObservationIgnored private var isClosed = false
    /// One sender per group: its queue goes out one PUT at a time.
    @ObservationIgnored private var senders: [UUID: Task<Void, Never>] = [:]
    /// The GET out for each group; a second refresh waits for it (POL-6).
    @ObservationIgnored private var fetching: [UUID: Task<Bool, Never>] = [:]
    @ObservationIgnored private var listing: Task<Void, Never>?
    @ObservationIgnored private var pollLoop: Task<Void, Never>?
    @ObservationIgnored private var onScreen: UUID?
    @ObservationIgnored private var isActive = true
    /// Groups this build can't read an answer for, until the app is updated (RB-11).
    @ObservationIgnored private var readOnly: Set<UUID> = []
    /// Left, ended or dropped in this session: a list that crossed it doesn't bring it back.
    @ObservationIgnored private var forgotten: Set<UUID> = []
    @ObservationIgnored private var conflicts: [UUID: Conflict] = [:]
    /// Said before `onMessage` was set, oldest first.
    @ObservationIgnored private var waitingMessages: [GroupPlanMessage] = []

    init(userID: String, server: any GroupPlanServing, directory: URL = SnapshotStore.directory, calendar: Calendar = .current,
         now: @escaping () -> Date = { Date() }, sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         newID: @escaping () -> UUID = { UUID() }, onMessage: ((GroupPlanMessage) -> Void)? = nil) {
        self.server = server
        fileURL = Self.cacheURL(for: userID, in: directory)
        self.calendar = calendar
        self.now = now
        self.sleep = sleep
        self.newID = newID
        self.onMessage = onMessage
        var records = Self.load(fileURL)
        for group in records.indices {
            for edit in records[group].pending.indices where records[group].pending[edit].sending {
                records[group].pending[edit].sending = false
                records[group].pending[edit].mayHaveLanded = true
            }
        }
        self.records = records
        publish()
        for record in records where !record.pending.isEmpty { kick(record.id) }
    }

    /// `group-plans-<user id>.json`, one per account (REM-5), named as the account's store file.
    static func cacheURL(for userID: String, in directory: URL) -> URL {
        let safe = userID.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "_" }
        return directory.appending(path: "group-plans-\(String(safe)).json")
    }

    func group(_ id: UUID) -> GroupPlanState? {
        groups.first { $0.id == id }
    }

    // MARK: - Making, joining and leaving

    /// Makes a group plan from one of this person's plans; they organize it. The same plan twice
    /// (a double tap, a retry) is the same group.
    func create(from plan: DayPlan) async -> Result<UUID, GroupPlanFailure> {
        guard !isClosed else { return .failure(.failed) }
        do {
            let (detail, etag) = try await server.create(date: GroupPlanDay.string(for: plan.date, calendar: calendar), plan: plan)
            guard !isClosed else { return .failure(.failed) }
            take(detail, etag: etag)
            return .success(detail.id)
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// The join sheet's "Maya's plan for Saturday, 3 going". `.gone` when the link doesn't work.
    func preview(token: String) async -> Result<GroupInvitePreview, GroupPlanFailure> {
        do {
            guard let preview = try await server.preview(token: token) else { return .failure(.gone) }
            return .success(preview)
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// Joins by link; joining a group this person is already in changes nothing.
    func join(token: String) async -> Result<UUID, GroupPlanFailure> {
        guard !isClosed else { return .failure(.failed) }
        do {
            guard let (detail, etag) = try await server.join(token: token) else { return .failure(.gone) }
            guard !isClosed else { return .failure(.failed) }
            take(detail, etag: etag)
            return .success(detail.id)
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// Leaves a group (not the organizer: they end it). Gone from this phone either way.
    func leave(_ id: UUID) async -> Result<Void, GroupPlanFailure> {
        guard !isClosed, let me = record(id)?.memberId else { return .failure(.gone) }
        do {
            _ = try await server.removeMember(me, from: id)
            forget(id)
            return .success(())
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// The organizer removes someone.
    func remove(member: UUID, from id: UUID) async -> Result<Void, GroupPlanFailure> {
        guard !isClosed, record(id) != nil else { return .failure(.gone) }
        do {
            _ = try await server.removeMember(member, from: id)
            await refresh(id)
            return .success(())
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// The organizer ends the group for everyone.
    func end(_ id: UUID) async -> Result<Void, GroupPlanFailure> {
        guard !isClosed, record(id) != nil else { return .failure(.gone) }
        do {
            _ = try await server.end(id)
            forget(id)
            return .success(())
        } catch {
            return .failure(Self.failure(error))
        }
    }

    /// The organizer's new link; the old one stops working.
    func newInviteLink(_ id: UUID) async -> Result<URL, GroupPlanFailure> {
        guard !isClosed, record(id) != nil else { return .failure(.gone) }
        do {
            guard let url = try await server.newInvite(id) else { return .failure(.gone) }
            guard !isClosed else { return .failure(.failed) }
            update(id) { $0.inviteUrl = url }
            await refresh(id)
            return .success(url)
        } catch {
            return .failure(Self.failure(error))
        }
    }

    // MARK: - Editing

    /// Makes an edit on the plan shown and queues it for the server.
    @discardableResult
    func apply(_ edit: PlanEdit, to id: UUID) -> GroupEditResult {
        guard !isClosed, !readOnly.contains(id), let index = index(id), !isDayOver(records[index].date),
              let shown = shownPlan(records[index]) else { return .unavailable }
        switch PlanEdit.apply(edit, to: shown, now: now(), calendar: calendar) {
        case .alreadyApplied:
            return .alreadyApplied
        case .noLongerApplies(let reason):
            return .noLongerApplies(reason)
        case .applied:
            records[index].pending.append(PendingEdit(editId: newID(), edit: edit, madeOn: records[index].version))
            save()
            publish()
            kick(id)
            return .queued
        }
    }

    private func kick(_ id: UUID) {
        guard !isClosed, senders[id] == nil, !readOnly.contains(id), let index = index(id), !records[index].pending.isEmpty else { return }
        senders[id] = Task { [weak self] in
            await self?.send(id)
            // Cancelled means whoever cancelled it already let it go.
            if !Task.isCancelled { self?.senders[id] = nil }
        }
    }

    /// Sends the group's queue, oldest first, one PUT at a time.
    private func send(_ id: UUID) async {
        var failures = 0
        while !Task.isCancelled, !isClosed, !readOnly.contains(id) {
            dropEditsThatNoLongerApply(id)
            guard let held = record(id), let head = held.pending.first, let serverPlan = held.plan else { return }
            let base: Int
            let sent: DayPlan?
            switch PlanEdit.apply(head.edit, to: serverPlan, now: now(), calendar: calendar) {
            case .applied(let plan):
                base = held.version
                sent = plan
            case .noLongerApplies where head.mayHaveLanded:
                // Its answer was lost and the plan has moved on since, maybe with it. The server
                // looks up a known editId before the base, so the same editId on the version it was
                // made on (one the server has passed) is 200 if it was stored and 409 if not.
                base = head.madeOn
                sent = nil
            default:
                continue
            }
            let body = GroupPlanUpdate(baseVersion: base, editId: head.editId,
                                         edit: .init(kind: head.edit.kind, stopIds: head.edit.stopIDs(before: serverPlan, after: sent ?? serverPlan)),
                                         plan: sent ?? serverPlan)
            updatePending(id, head.editId) { $0.sending = true }
            save()

            let answer: GroupPlanPutResult
            do {
                answer = try await server.put(id, body)
            } catch APIError.invalidResponse {
                guard !isClosed, index(id) != nil else { return }
                // It may have been stored; never PUT over a plan this build can't read (RB-11).
                updatePending(id, head.editId) { $0.sending = false; $0.mayHaveLanded = true }
                makeReadOnly(id)
                return
            } catch {
                guard !isClosed, index(id) != nil else { return }
                // No answer: the server may have it. Same editId next time (RB-8).
                updatePending(id, head.editId) { $0.sending = false; $0.mayHaveLanded = true }
                save()
                failures += 1
                do { try await sleep(Self.retryDelay(failures: failures)) } catch { return }
                continue
            }
            guard !isClosed, index(id) != nil else { return }
            failures = 0

            switch answer {
            case let .saved(saved, etag):
                // Stored just now on `base`: the server's plan is exactly the one sent.
                let fresh = sent != nil && !head.mayHaveLanded && saved.version == base + 1
                if !fresh {
                    // Stored earlier (MF-B): fetch the server's plan before letting the edit go, so it
                    // doesn't flicker away, and never add it twice.
                    update(id) { $0.absorb(version: saved.version, membersVersion: saved.membersVersion, plan: nil, members: saved.members, etag: etag) }
                    updatePending(id, head.editId) { $0.sending = false }
                    for _ in 0..<2 where (record(id)?.version ?? .max) < saved.version {
                        await refresh(id)
                    }
                    guard !isClosed, index(id) != nil else { return }
                }
                conflicts[id] = nil
                update(id) {
                    if fresh {
                        $0.absorb(version: saved.version, membersVersion: saved.membersVersion, plan: sent, members: saved.members, etag: etag)
                    }
                    $0.pending.removeAll { $0.editId == head.editId }
                }
            case let .conflict(conflict, etag):
                update(id) {
                    $0.absorb(version: conflict.version, membersVersion: conflict.membersVersion, plan: conflict.plan, members: conflict.members, etag: etag)
                }
                conflicts[id] = Conflict(base: base, version: conflict.version, edits: conflict.edits, editsFrom: conflict.editsFrom)
                // The server checks a known editId first, so a 409 also says it never took this one.
                updatePending(id, head.editId) { $0.sending = false; $0.mayHaveLanded = false; $0.conflicts += 1 }
                giveUpIfItKeepsChanging(id, head.editId)
            case .gone:
                removeGroup(id, announce: !isDayOver(held.date))
                return
            case .rejected(let detail):
                removePending(id, head.editId)
                emit(id, .editRefused(detail))
            case .tooLarge(let detail):
                removePending(id, head.editId)
                emit(id, .planTooLarge(detail))
            }
        }
    }

    /// Makes the queue again on the server's plan, in order: an edit the plan already shows goes
    /// quietly; edits that no longer apply go with one message. One the server may already have
    /// (its answer was lost) stays until the server says whether it was stored.
    private func dropEditsThatNoLongerApply(_ id: UUID) {
        guard let index = index(id), var plan = records[index].plan else { return }
        var kept: [PendingEdit] = []
        var dropped: [(edit: PlanEdit, reason: PlanEdit.Reason)] = []
        for pending in records[index].pending {
            switch PlanEdit.apply(pending.edit, to: plan, now: now(), calendar: calendar) {
            case .applied(let next):
                plan = next
                kept.append(pending)
            case .alreadyApplied:
                continue
            case .noLongerApplies where pending.mayHaveLanded:
                kept.append(pending)
            case .noLongerApplies(let reason):
                dropped.append((pending.edit, reason))
            }
        }
        guard kept.count != records[index].pending.count else { return }
        records[index].pending = kept
        save()
        publish()
        if let first = dropped.first {
            emit(id, .editsNotMade(count: dropped.count, author: author(of: first.edit, first.reason, in: records[index]), reason: first.reason))
        }
    }

    /// Who made the change that got in the way, from the last 409's edits: only when that list is
    /// complete (`editsFrom` right after the base) and is about the plan held now. Never guessed.
    private func author(of edit: PlanEdit, _ reason: PlanEdit.Reason, in record: Record) -> String? {
        guard let conflict = conflicts[record.id], conflict.version == record.version,
              let from = conflict.editsFrom, from == conflict.base + 1, let plan = record.plan else { return nil }
        let matches: (GroupPlanLoggedEdit) -> Bool
        switch reason {
        case .stopGone(let stop), .stopChanged(let stop), .alreadyInPlan(let stop):
            matches = { $0.stopIds.contains(stop) }
        case .notNextToEachOther:
            let stops = Set(edit.stopIDs(before: plan, after: plan))
            matches = { !stops.isDisjoint(with: $0.stopIds) }
        case .planFull:
            matches = { $0.kind == "add" }
        }
        guard let logged = conflict.edits.last(where: matches), logged.authorId != record.memberId else { return nil }
        return logged.authorName
    }

    /// Three 409s in a row: the latest plan, without the edit, and a message (N-3).
    private func giveUpIfItKeepsChanging(_ id: UUID, _ editID: UUID) {
        guard let index = index(id), let pending = records[index].pending.first(where: { $0.editId == editID }),
              pending.conflicts >= Self.conflictsAllowed else {
            save()
            publish()
            return
        }
        if let plan = records[index].plan, case .applied = PlanEdit.apply(pending.edit, to: plan, now: now(), calendar: calendar) {
            removePending(id, editID)
            emit(id, .keptChanging)
        } else {
            // It no longer applies or is already there: the next pass says which.
            save()
            publish()
        }
    }

    private static func retryDelay(failures: Int) -> Duration {
        .seconds(min(60, 1 << min(failures - 1, 6)))
    }

    // MARK: - Polling

    /// Asks the server for the group's plan, with its ETag when a plan is held. Never two at once:
    /// a second call waits for the first. True when the app now holds the server's plan.
    @discardableResult
    func refresh(_ id: UUID) async -> Bool {
        if let running = fetching[id] { return await running.value }
        guard !isClosed, index(id) != nil else { return false }
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let current = await self.fetch(id)
            self.fetching[id] = nil
            return current
        }
        fetching[id] = task
        return await task.value
    }

    private func fetch(_ id: UUID) async -> Bool {
        guard let held = record(id) else { return false }
        do {
            let answer = try await server.fetch(id, etag: held.plan == nil ? nil : held.etag)
            guard !isClosed, index(id) != nil else { return false }
            switch answer {
            case .notModified:
                return true
            case .gone:
                removeGroup(id, announce: !isDayOver(held.date))
                return false
            case let .plan(detail, etag):
                update(id) { $0.absorb(detail, etag: etag) }
                kick(id)
                return true
            }
        } catch APIError.invalidResponse {
            guard !isClosed, index(id) != nil else { return false }
            makeReadOnly(id)
            return false
        } catch {
            return false
        }
    }

    /// Every group this account is in: new ones are added (joined on another phone, POL-8), and
    /// ones missing from the list are dropped (REM-3). Never two at once.
    func refreshList() async {
        if let running = listing { return await running.value }
        guard !isClosed else { return }
        let task = Task { [weak self] in
            await self?.loadList()
            self?.listing = nil
        }
        listing = task
        await task.value
    }

    private func loadList() async {
        let known = Set(records.map(\.id))
        let rows: [GroupPlanSummary]
        do {
            rows = try await server.list()
        } catch {
            return
        }
        guard !isClosed else { return }
        let listed = Set(rows.map(\.id))
        for id in known.subtracting(listed) {
            guard let record = record(id) else { continue }
            removeGroup(id, announce: !isDayOver(record.date))
        }
        var stale: [UUID] = []
        for row in rows where !forgotten.contains(row.id) {
            if let index = index(row.id) {
                if records[index].plan == nil || !Self.sameETag(records[index].etag, row.etag) { stale.append(row.id) }
            } else {
                records.append(Record(summary: row))
                stale.append(row.id)
            }
        }
        save()
        publish()
        for id in stale { await refresh(id) }
        rollOverIfNeeded()
    }

    /// Compared weakly, as the server does: a proxy may have added `W/`.
    private static func sameETag(_ held: String?, _ listed: String) -> Bool {
        guard let held else { return false }
        func opaque(_ tag: String) -> Substring { tag.hasPrefix("W/") ? tag.dropFirst(2) : Substring(tag) }
        return opaque(held) == opaque(listed)
    }

    /// The group on screen is polled every 15 s while the app is active.
    func show(_ id: UUID) {
        onScreen = id
        startPolling()
    }

    func hide(_ id: UUID) {
        guard onScreen == id else { return }
        onScreen = nil
        stopPolling()
    }

    /// Back in the foreground: the group on screen at once, queued edits, the list, and rollover.
    func appBecameActive() {
        guard !isClosed else { return }
        isActive = true
        startPolling()
        for record in records where !record.pending.isEmpty { kick(record.id) }
        rollOverIfNeeded()
        Task { [weak self] in await self?.refreshList() }
    }

    func appWillResign() {
        isActive = false
        stopPolling()
    }

    private func startPolling() {
        stopPolling()
        guard !isClosed, isActive, let id = onScreen, index(id) != nil else { return }
        pollLoop = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let current = await self?.refresh(id), !Task.isCancelled,
                      let self, !self.isClosed, self.index(id) != nil else { return }
                failures = current ? 0 : failures + 1
                do { try await self.sleep(Self.pollDelay(failures: failures)) } catch { return }
            }
        }
    }

    private func stopPolling() {
        pollLoop?.cancel()
        pollLoop = nil
    }

    /// 15 s; after failures 30, 60, then 120 s (POL-7).
    private static func pollDelay(failures: Int) -> Duration {
        failures == 0 ? pollInterval : .seconds(min(120, 15 << min(failures, 3)))
    }

    // MARK: - Rollover

    /// Files each group day that's over under recent plans, with the group's id, at most once
    /// (RO-1 to RO-4). Queued edits are in the filed plan (RO-5). Today's own plan is untouched.
    func rollOverIfNeeded() {
        guard !isClosed else { return }
        if let history {
            for record in records.sorted(by: Self.byDate) where isDayOver(record.date) {
                guard let plan = shownPlan(record), !plan.stops.isEmpty else { continue }
                history.recordGroupDay(plan, groupID: record.id)
            }
        }
        publish()
    }

    // MARK: - Closing

    /// Detaches the store from its account (sign-out, deletion): nothing more is sent, written or said.
    func close() {
        isClosed = true
        senders.values.forEach { $0.cancel() }
        senders = [:]
        fetching.values.forEach { $0.cancel() }
        fetching = [:]
        listing?.cancel()
        listing = nil
        stopPolling()
        waitingMessages = []
        onMessage = nil
        history = nil
    }

    /// Removes this account's cache file (sign-out, account deletion).
    func deleteCache() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - Internals

    private func index(_ id: UUID) -> Int? {
        records.firstIndex { $0.id == id }
    }

    private func record(_ id: UUID) -> Record? {
        index(id).map { records[$0] }
    }

    /// Changes one record, then saves and redraws only if something changed (POL-2, POL-4).
    private func update(_ id: UUID, _ change: (inout Record) -> Void) {
        guard let index = index(id) else { return }
        let before = records[index]
        change(&records[index])
        guard records[index] != before else { return }
        save()
        publish()
    }

    private func updatePending(_ id: UUID, _ editID: UUID, _ change: (inout PendingEdit) -> Void) {
        guard let index = index(id), let at = records[index].pending.firstIndex(where: { $0.editId == editID }) else { return }
        change(&records[index].pending[at])
    }

    private func removePending(_ id: UUID, _ editID: UUID) {
        guard let index = index(id) else { return }
        records[index].pending.removeAll { $0.editId == editID }
        save()
        publish()
    }

    /// A group from create or join: added, or brought up to date if already here.
    private func take(_ detail: GroupPlanDetail, etag: String?) {
        forgotten.remove(detail.id)
        if index(detail.id) != nil {
            update(detail.id) { $0.absorb(detail, etag: etag) }
        } else {
            records.append(Record(detail: detail, etag: etag))
            save()
            publish()
        }
    }

    /// Left or ended here: gone from this phone without a message.
    private func forget(_ id: UUID) {
        removeGroup(id, announce: false)
    }

    /// The group, its queued edits and its cache entry go (REM-1, RB-9).
    private func removeGroup(_ id: UUID, announce: Bool) {
        forgotten.insert(id)
        guard let index = index(id) else { return }
        records.remove(at: index)
        senders.removeValue(forKey: id)?.cancel()
        conflicts[id] = nil
        readOnly.remove(id)
        if onScreen == id { stopPolling() }
        save()
        publish()
        if announce { emit(id, .groupGone) }
    }

    private func makeReadOnly(_ id: UUID) {
        guard !readOnly.contains(id) else { return }
        readOnly.insert(id)
        senders.removeValue(forKey: id)?.cancel()
        save()
        publish()
        emit(id, .readOnly)
    }

    private func isDayOver(_ date: String) -> Bool {
        guard let end = GroupPlanDay.end(of: date) else { return false }
        return now() >= end
    }

    /// The server's plan with the queue on top; an edit that no longer applies is left out until
    /// the sender drops it with a message.
    private func shownPlan(_ record: Record) -> DayPlan? {
        guard var plan = record.plan else { return nil }
        for pending in record.pending {
            if case .applied(let next) = PlanEdit.apply(pending.edit, to: plan, now: now(), calendar: calendar) { plan = next }
        }
        return plan
    }

    private func state(_ record: Record) -> GroupPlanState {
        GroupPlanState(id: record.id, date: record.date, plan: shownPlan(record), version: record.version, members: record.members,
                       memberId: record.memberId, isOrganizer: record.isOrganizer, organizerName: record.organizerName,
                       memberCount: record.memberCount, inviteUrl: record.inviteUrl, pendingEdits: record.pending.count,
                       isReadOnly: readOnly.contains(record.id), isDayOver: isDayOver(record.date))
    }

    private static func byDate(_ a: Record, _ b: Record) -> Bool {
        a.date < b.date
    }

    /// Redraws only when what's shown changed.
    private func publish() {
        let states = records.enumerated()
            .sorted { $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date < $1.element.date }
            .map { state($0.element) }
        if states != groups { groups = states }
    }

    private func save() {
        guard !isClosed else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Cache(groups: records)).write(to: fileURL, options: .atomic)
        } catch {
            print("Plandit: could not save group plans: \(error)")
        }
    }

    private static func load(_ url: URL) -> [Record] {
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode(Cache.self, from: data) else { return [] }
        return cache.groups
    }

    private func emit(_ id: UUID, _ kind: GroupPlanMessage.Kind) {
        guard !isClosed else { return }
        let message = GroupPlanMessage(groupID: id, kind: kind, text: Self.text(for: kind))
        guard let onMessage else {
            waitingMessages.append(message)
            waitingMessages.removeFirst(max(0, waitingMessages.count - Self.messagesKept))
            return
        }
        onMessage(message)
    }

    private func deliverWaitingMessages() {
        while !isClosed, let onMessage, !waitingMessages.isEmpty {
            onMessage(waitingMessages.removeFirst())
        }
    }

    private static func failure(_ error: Error) -> GroupPlanFailure {
        switch error {
        case GroupPlanError.rejected(let detail): .refused(detail)
        case GroupPlanError.tooLarge(let detail): .tooLarge(detail)
        case APIError.network: .offline
        case APIError.invalidResponse: .unreadable
        default: .failed
        }
    }

    /// The words for each message. Provisional until G3b-2's persona review.
    static func text(for kind: GroupPlanMessage.Kind) -> String {
        switch kind {
        case let .editsNotMade(count, author, reason):
            let who = author ?? "Someone"
            if count > 1 { return "\(who) changed the plan first, so \(count) of your changes weren't made." }
            switch reason {
            case .stopGone: return "\(who) removed that stop, so your change wasn't made."
            case .stopChanged: return "\(who) changed that stop first, so your change wasn't made."
            case .notNextToEachOther: return "\(who) moved those stops, so your trip change wasn't made."
            case .planFull: return "The plan already has \(PlanEdit.maxStops) stops, so yours wasn't added."
            case .alreadyInPlan: return "\(who) already added that place."
            }
        case .keptChanging:
            return "The plan kept changing, so your change wasn't made. This is the latest plan."
        case .groupGone:
            return "This group plan ended, or you're no longer in it."
        case .editRefused(let detail):
            return detail ?? "Your change couldn't be saved."
        case .planTooLarge(let detail):
            return detail ?? "This plan is too big to save for the group. Remove a stop and try again."
        case .readOnly:
            return "This version of Plandit can't update this plan. Update the app to keep editing."
        }
    }
}
