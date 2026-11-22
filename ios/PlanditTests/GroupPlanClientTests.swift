import XCTest
@testable import Plandit

/// Canned HTTP with response headers (the ETag), recording every request.
final class HeaderTransport: HTTPTransport, @unchecked Sendable {
    typealias Reply = (status: Int, body: Data, headers: [String: String])

    private let lock = NSLock()
    private var replies: [Reply]
    private var fallback: Reply
    private var recorded: [URLRequest] = []

    init(_ replies: [Reply] = [], otherwise fallback: Reply = (200, Data("{}".utf8), [:])) {
        self.replies = replies
        self.fallback = fallback
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = lock.withLock {
            recorded.append(request)
            return replies.isEmpty ? fallback : replies.removeFirst()
        }
        if reply.status == -1 { throw URLError(.notConnectedToInternet) }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
}

/// The app's group plan client against the contract (scratchpad g3a-contract.md): exact paths and
/// slashes (CTR-1), plain JSON numbers for dates, `If-None-Match`, and what each status means.
@MainActor final class GroupPlanClientTests: XCTestCase {
    private let groupID = UUID(uuidString: "0B9E5E2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B")!
    private let memberID = UUID(uuidString: "1C9E5E2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B")!
    private let otherID = UUID(uuidString: "2D9E5E2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B")!

    private func client(_ transport: HeaderTransport) -> GroupPlanClient {
        GroupPlanClient(api: PlanditAPIClient(baseURL: URL(string: "https://api.example")!, userID: "user-1",
                                              tokenProvider: FakeTokenProvider(), transport: transport))
    }

    private var plan: DayPlan {
        var plan = SampleData.dayPlan
        plan.date = Date(timeIntervalSinceReferenceDate: 816_000_000)
        return plan
    }

    private func json(_ value: Any) -> Data { try! JSONSerialization.data(withJSONObject: value) }

    /// The plan as the server stores and returns it: plain encoder, so numbers for dates.
    private func planJSON(_ plan: DayPlan) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(plan))
    }

    private func members() -> [[String: Any]] {
        [["id": memberID.uuidString.lowercased(), "name": "Sofia", "isOrganizer": true],
         ["id": otherID.uuidString.lowercased(), "name": "Maya", "isOrganizer": false]]
    }

    private func detail(version: Int = 1, plan: DayPlan) -> Data {
        json(["id": groupID.uuidString.lowercased(), "date": "2026-11-20", "version": version, "membersVersion": 1,
              "plan": planJSON(plan), "members": members(), "memberId": memberID.uuidString.lowercased(),
              "isOrganizer": true, "inviteUrl": "https://plandit.app/j/fakeInviteToken0000000"])
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
    }

    private func update(base: Int = 3) -> GroupPlanUpdate {
        GroupPlanUpdate(baseVersion: base, editId: UUID(uuidString: "3E9E5E2A-1C3D-4E5F-8A9B-0C1D2E3F4A5B")!,
                        edit: .init(kind: "remove", stopIds: [plan.stops[2].id]), plan: plan)
    }

    // MARK: - Paths (CTR-1)

    func testEveryCallUsesTheContractsExactPathAndMethod() async throws {
        let transport = HeaderTransport([
            (200, json(["groups": []]), [:]),
            (201, detail(plan: plan), ["ETag": "\"1.1\""]),
            (200, detail(plan: plan), ["ETag": "\"1.1\""]),
            (200, json(["version": 4, "membersVersion": 1, "members": members()]), ["ETag": "\"4.1\""]),
            (204, Data(), [:]),
            (200, json(["organizerName": "Sofia", "date": "2026-11-20", "memberCount": 2]), [:]),
            (200, detail(plan: plan), ["ETag": "\"1.2\""]),
            (200, json(["inviteUrl": "https://plandit.app/j/fakeInviteToken1111111"]), [:]),
            (204, Data(), [:]),
        ])
        let client = client(transport)
        let id = groupID.uuidString
        _ = try await client.list()
        _ = try await client.create(date: "2026-11-20", plan: plan)
        _ = try await client.fetch(groupID, etag: nil)
        _ = try await client.put(groupID, update())
        _ = try await client.end(groupID)
        _ = try await client.preview(token: "fakeInviteToken0000000")
        _ = try await client.join(token: "fakeInviteToken0000000")
        _ = try await client.newInvite(groupID)
        _ = try await client.removeMember(otherID, from: groupID)

        let calls = transport.requests.map { "\($0.httpMethod ?? "") \($0.url!.absoluteString)" }
        XCTAssertEqual(calls, [
            "GET https://api.example/api/group-plans/",
            "POST https://api.example/api/group-plans/",
            "GET https://api.example/api/group-plans/\(id)/",
            "PUT https://api.example/api/group-plans/\(id)/",
            "DELETE https://api.example/api/group-plans/\(id)/",
            "GET https://api.example/api/group-plans/invites/fakeInviteToken0000000/",
            "POST https://api.example/api/group-plans/invites/fakeInviteToken0000000/join",
            "POST https://api.example/api/group-plans/\(id)/invite",
            "DELETE https://api.example/api/group-plans/\(id)/members/\(otherID.uuidString)/",
        ])
        XCTAssertTrue(transport.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
    }

    // MARK: - Bodies

    /// The server rejects a date sent as a string: plain `JSONEncoder`, not the snapshot's.
    func testCreateSendsTheDayAndThePlanWithNumberDates() async throws {
        let transport = HeaderTransport([(201, detail(plan: plan), ["ETag": "\"1.1\""])])

        let (created, etag) = try await client(transport).create(date: "2026-11-20", plan: plan)

        let sent = body(transport.requests[0])
        XCTAssertEqual(sent["date"] as? String, "2026-11-20")
        let sentPlan = sent["plan"] as? [String: Any]
        XCTAssertTrue(sentPlan?["date"] is NSNumber, "plan.date must be a JSON number")
        XCTAssertEqual(sentPlan?["id"] as? String, plan.id.uuidString)
        let stops = sentPlan?["stops"] as? [[String: Any]]
        XCTAssertTrue(stops?.allSatisfy { $0["start"] is NSNumber } ?? false)
        XCTAssertEqual(created.plan, plan)
        XCTAssertEqual(created.id, groupID)
        XCTAssertEqual(created.memberId, memberID)
        XCTAssertEqual(created.inviteUrl?.absoluteString, "https://plandit.app/j/fakeInviteToken0000000")
        XCTAssertEqual(etag, "\"1.1\"")
    }

    func testPutSendsBaseEditIDKindStopIDsAndPlan() async throws {
        let transport = HeaderTransport([(200, json(["version": 4, "membersVersion": 2, "members": members()]), ["ETag": "\"4.2\""])])
        let update = update()

        let result = try await client(transport).put(groupID, update)

        let sent = body(transport.requests[0])
        XCTAssertEqual(sent["baseVersion"] as? Int, 3)
        XCTAssertEqual(sent["editId"] as? String, update.editId.uuidString)
        XCTAssertEqual((sent["edit"] as? [String: Any])?["kind"] as? String, "remove")
        XCTAssertEqual((sent["edit"] as? [String: Any])?["stopIds"] as? [String], [plan.stops[2].id.uuidString])
        XCTAssertTrue((sent["plan"] as? [String: Any])?["date"] is NSNumber)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let saved = GroupPlanSaved(version: 4, membersVersion: 2, members: [
            GroupPlanMember(id: memberID, name: "Sofia", isOrganizer: true), GroupPlanMember(id: otherID, name: "Maya", isOrganizer: false),
        ])
        XCTAssertEqual(result, .saved(saved, etag: "\"4.2\""))
    }

    // MARK: - Polling (POL-3, POL-4)

    func testFetchSendsTheETagExactlyAsReceivedAndSkipsTheURLCache() async throws {
        let transport = HeaderTransport([(304, Data(), ["ETag": "W/\"3.1\""])])

        let result = try await client(transport).fetch(groupID, etag: "W/\"3.1\"")

        XCTAssertEqual(result, .notModified)
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "If-None-Match"), "W/\"3.1\"")
        XCTAssertEqual(transport.requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }

    /// Plans, members' names and invite links never go into the shared URL cache (`Cache.db`),
    /// which would keep them after sign-out: the app's `URLSession` is swapped for one with no
    /// cache. The account's other calls keep theirs, and a test's transport is used as given.
    func testGroupCallsGoThroughASessionWithNoURLCache() throws {
        let api = PlanditAPIClient(baseURL: URL(string: "https://api.example")!, userID: "user-1", tokenProvider: FakeTokenProvider())

        let session = try XCTUnwrap(GroupPlanClient(api: api).api.transport as? URLSession)

        XCTAssertFalse(session === URLSession.shared)
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertTrue(api.transport as? URLSession === URLSession.shared, "the other calls are as they were")
        let fake = HeaderTransport()
        XCTAssertTrue(client(fake).api.transport as? HeaderTransport === fake)
    }

    /// For a group whose plan isn't held, no `If-None-Match`: a 304 would leave no plan.
    func testFetchWithoutAHeldPlanSendsNoETag() async throws {
        let transport = HeaderTransport([(200, detail(version: 3, plan: plan), ["ETag": "\"3.1\""])])

        let result = try await client(transport).fetch(groupID, etag: nil)

        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "If-None-Match"))
        guard case .plan(let detail, let etag) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(detail.version, 3)
        XCTAssertEqual(detail.plan, plan)
        XCTAssertEqual(detail.members.map(\.name), ["Sofia", "Maya"])
        XCTAssertEqual(etag, "\"3.1\"")
    }

    func testFetchOfAGroupThatsGoneIsGone() async throws {
        let transport = HeaderTransport([(404, Data(), [:])])

        let result = try await client(transport).fetch(groupID, etag: "\"3.1\"")

        XCTAssertEqual(result, .gone)
    }

    // MARK: - PUT answers (RB-*)

    /// RB-3, MF-C: the 409 is decoded with the app's own types, authors included.
    func testAStalePutDecodesTheConflictWithItsEditsAndAuthors() async throws {
        var newer = plan
        newer.stops.remove(at: 2)
        let removed = plan.stops[2].id
        let conflict = json([
            "version": 5, "membersVersion": 1, "plan": planJSON(newer), "members": members(),
            "edits": [
                ["version": 4, "authorId": otherID.uuidString.lowercased(), "authorName": "Maya", "kind": "remove", "stopIds": [removed.uuidString]],
                ["version": 5, "authorId": NSNull(), "authorName": NSNull(), "kind": "move", "stopIds": []],
            ],
            "editsFrom": 4,
        ])
        let transport = HeaderTransport([(409, conflict, ["ETag": "\"5.1\""])])

        let result = try await client(transport).put(groupID, update())

        guard case .conflict(let decoded, let etag) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(decoded.version, 5)
        XCTAssertEqual(decoded.plan, newer)
        XCTAssertEqual(decoded.editsFrom, 4)
        XCTAssertEqual(decoded.edits[0], GroupPlanLoggedEdit(version: 4, authorId: otherID, authorName: "Maya", kind: "remove", stopIds: [removed]))
        XCTAssertNil(decoded.edits[1].authorName)
        XCTAssertEqual(etag, "\"5.1\"")
    }

    func testPutAnswersBecomeGoneRejectedOrTooLarge() async throws {
        let transport = HeaderTransport([
            (404, Data(), [:]),
            (400, json(["detail": "This plan's day has passed, so it can't be changed."]), [:]),
            (400, json(["plan": ["This isn't the group's plan."]]), [:]),
            (413, json(["detail": "This plan is too big to save for the group. Remove a stop and try again.", "limitBytes": 65536]), [:]),
        ])
        let client = client(transport)

        let gone = try await client.put(groupID, update())
        let dayOver = try await client.put(groupID, update())
        let wrongPlan = try await client.put(groupID, update())
        let tooLarge = try await client.put(groupID, update())

        XCTAssertEqual(gone, .gone)
        XCTAssertEqual(dayOver, .rejected("This plan's day has passed, so it can't be changed."))
        XCTAssertEqual(wrongPlan, .rejected("This isn't the group's plan."))
        XCTAssertEqual(tooLarge, .tooLarge("This plan is too big to save for the group. Remove a stop and try again."))
    }

    /// RB-8: a lost connection is `.network`; a busy server (503) and other 5xx are errors to retry.
    func testNetworkErrorsAndServerErrorsThrow() async {
        let transport = HeaderTransport([(-1, Data(), [:]), (503, json(["detail": "Try again in a moment."]), ["Retry-After": "1"])])
        let client = client(transport)

        do {
            _ = try await client.put(groupID, update())
            XCTFail("expected a network error")
        } catch {
            XCTAssertEqual(error as? APIError, .network)
        }
        do {
            _ = try await client.put(groupID, update())
            XCTFail("expected a 503")
        } catch {
            XCTAssertEqual(error as? APIError, .status(503))
        }
    }

    /// RB-11: a body this build can't read is never taken as an answer.
    func testAnUnreadableBodyThrowsInvalidResponse() async {
        let transport = HeaderTransport([(200, json(["version": "four"]), [:]), (409, json(["plan": 7]), [:]), (200, json(["plan": []]), [:])])
        let client = client(transport)

        for _ in 0..<2 {
            do {
                _ = try await client.put(groupID, update())
                XCTFail("expected invalidResponse")
            } catch {
                XCTAssertEqual(error as? APIError, .invalidResponse)
            }
        }
        do {
            _ = try await client.fetch(groupID, etag: nil)
            XCTFail("expected invalidResponse")
        } catch {
            XCTAssertEqual(error as? APIError, .invalidResponse)
        }
    }

    /// A 401 refreshes the token once and tries again (PlanditAPIClient).
    func testA401RefreshesAndRetries() async throws {
        let transport = HeaderTransport([(401, json(["detail": "Token expired."]), [:]), (304, Data(), ["ETag": "\"3.1\""])])

        let result = try await client(transport).fetch(groupID, etag: "\"3.1\"")

        XCTAssertEqual(result, .notModified)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "If-None-Match"), "\"3.1\"")
    }

    // MARK: - Joining, leaving, ending

    func testInvitesThatDontWorkAreNil() async throws {
        let transport = HeaderTransport([(404, Data(), [:]), (404, Data(), [:]), (404, Data(), [:])])
        let client = client(transport)

        let preview = try await client.preview(token: "fakeInviteToken0000000")
        let joined = try await client.join(token: "fakeInviteToken0000000")
        let invite = try await client.newInvite(groupID)

        XCTAssertNil(preview)
        XCTAssertNil(joined)
        XCTAssertNil(invite)
    }

    func testPreviewJoinAndNewLinkDecode() async throws {
        let transport = HeaderTransport([
            (200, json(["organizerName": "Sofia", "date": "2026-11-20", "memberCount": 2]), [:]),
            (200, detail(version: 2, plan: plan), ["ETag": "\"2.3\""]),
            (200, json(["inviteUrl": "https://plandit.app/j/fakeInviteToken1111111"]), [:]),
        ])
        let client = client(transport)

        let preview = try await client.preview(token: "fakeInviteToken0000000")
        let joined = try await client.join(token: "fakeInviteToken0000000")
        let invite = try await client.newInvite(groupID)

        XCTAssertEqual(preview, GroupInvitePreview(organizerName: "Sofia", date: "2026-11-20", memberCount: 2))
        XCTAssertEqual(joined?.0.version, 2)
        XCTAssertEqual(joined?.etag, "\"2.3\"")
        XCTAssertEqual(invite?.absoluteString, "https://plandit.app/j/fakeInviteToken1111111")
    }

    /// Leaving or ending a group that's already gone is done; the organizer leaving is refused.
    func testLeavingAndEnding() async throws {
        let transport = HeaderTransport([
            (204, Data(), [:]), (404, Data(), [:]),
            (400, json(["detail": "Organizers can't leave their own plan. End the plan instead, which removes it for everyone."]), [:]),
            (204, Data(), [:]), (404, Data(), [:]),
        ])
        let client = client(transport)

        let removed = try await client.removeMember(otherID, from: groupID)
        let alreadyGone = try await client.removeMember(otherID, from: groupID)
        do {
            _ = try await client.removeMember(memberID, from: groupID)
            XCTFail("expected the organizer to be refused")
        } catch {
            XCTAssertEqual(error as? GroupPlanError, .rejected("Organizers can't leave their own plan. End the plan instead, which removes it for everyone."))
        }
        let ended = try await client.end(groupID)
        let endedAlready = try await client.end(groupID)

        XCTAssertTrue(removed)
        XCTAssertFalse(alreadyGone)
        XCTAssertTrue(ended)
        XCTAssertFalse(endedAlready)
    }

    func testCreateRefusedOrTooLargeThrows() async {
        let transport = HeaderTransport([
            (400, json(["date": ["Pick a day from today on."]]), [:]),
            (413, json(["detail": "This plan is too big to save for the group. Remove a stop and try again.", "limitBytes": 65536]), [:]),
        ])
        let client = client(transport)

        do {
            _ = try await client.create(date: "2026-11-01", plan: plan)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? GroupPlanError, .rejected("Pick a day from today on."))
        }
        do {
            _ = try await client.create(date: "2026-11-20", plan: plan)
            XCTFail("expected too large")
        } catch {
            XCTAssertEqual(error as? GroupPlanError, .tooLarge("This plan is too big to save for the group. Remove a stop and try again."))
        }
    }

    func testListDecodesEveryGroup() async throws {
        let row: [String: Any] = [
            "id": groupID.uuidString.lowercased(), "date": "2026-11-20", "version": 3, "membersVersion": 2, "etag": "\"3.2\"",
            "organizerName": "Sofia", "memberCount": 2, "memberId": memberID.uuidString.lowercased(), "isOrganizer": false, "inviteUrl": NSNull(),
        ]
        let transport = HeaderTransport([(200, json(["groups": [row]]), [:])])

        let groups = try await client(transport).list()

        XCTAssertEqual(groups, [GroupPlanSummary(id: groupID, date: "2026-11-20", version: 3, membersVersion: 2, etag: "\"3.2\"",
                                                 organizerName: "Sofia", memberCount: 2, memberId: memberID, isOrganizer: false, inviteUrl: nil)])
        XCTAssertEqual(transport.requests[0].cachePolicy, .reloadIgnoringLocalCacheData)
    }
}
