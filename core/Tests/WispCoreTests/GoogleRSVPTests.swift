import XCTest
@testable import WispCore

private func json(_ object: Any) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

private func jwt(_ claims: [String: Any]) -> String {
    func b64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    return [b64(json(["alg": "RS256"])), b64(json(claims)), "signature"].joined(separator: ".")
}

private func query(_ request: URLRequest) -> [String: String] {
    let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
    return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
}

final class GoogleClientParsingTests: XCTestCase {
    func testReadsDesktopClient() throws {
        let data = json(["installed": ["client_id": " abc.apps.googleusercontent.com ", "client_secret": "s3cret", "project_id": "p"]])
        let client = try GoogleClient.parse(data)
        XCTAssertEqual(client, GoogleClient(clientID: "abc.apps.googleusercontent.com", clientSecret: "s3cret"))
        XCTAssertEqual(try GoogleClient.parse(client.serialized()), client)
    }

    func testRefusesWebClientAndJunk() {
        XCTAssertThrowsError(try GoogleClient.parse(json(["web": ["client_id": "a", "client_secret": "b"]]))) { XCTAssertEqual($0 as? GoogleClient.ParseError, .webClient) }
        XCTAssertThrowsError(try GoogleClient.parse(json(["installed": ["client_id": "a"]]))) { XCTAssertEqual($0 as? GoogleClient.ParseError, .missingFields) }
        XCTAssertThrowsError(try GoogleClient.parse(json(["installed": ["client_id": "", "client_secret": "b"]]))) { XCTAssertEqual($0 as? GoogleClient.ParseError, .missingFields) }
        XCTAssertThrowsError(try GoogleClient.parse(Data("nope".utf8))) { XCTAssertEqual($0 as? GoogleClient.ParseError, .notJSON) }
    }
}

final class GoogleAuthTests: XCTestCase {
    private let client = GoogleClient(clientID: "id.apps", clientSecret: "sec ret&")

    func testAuthorizationURLCarriesPKCEAndNarrowScope() {
        let redirect = GoogleAuth.redirectURI(port: 50_123)
        let url = GoogleAuth.authorizationURL(clientID: client.clientID, redirectURI: redirect, state: "st", challenge: "ch")
        let q = query(URLRequest(url: url))
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(q["redirect_uri"], "http://127.0.0.1:50123/callback")
        XCTAssertEqual(q["code_challenge_method"], "S256")
        XCTAssertEqual(q["code_challenge"], "ch")
        XCTAssertEqual(q["access_type"], "offline")
        XCTAssertEqual(q["scope"], "https://www.googleapis.com/auth/calendar.events openid email")
        XCTAssertEqual(q["state"], "st")
    }

    func testRandomPortStaysInDynamicRange() {
        for _ in 0..<200 { XCTAssertTrue((49_152...65_000).contains(GoogleAuth.randomPort())) }
    }

    func testTokenRequestsAreFormEncoded() {
        let exchange = GoogleAuth.tokenExchangeRequest(code: "c/d", verifier: "v", client: client, redirectURI: GoogleAuth.redirectURI(port: 50_000))
        XCTAssertEqual(exchange.url, GoogleAuth.tokenEndpoint)
        let body = String(decoding: exchange.httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=c%2Fd"))
        XCTAssertTrue(body.contains("client_secret=sec%20ret%26"))
        XCTAssertTrue(body.contains("code_verifier=v"))
        let refresh = String(decoding: GoogleAuth.refreshRequest(refreshToken: "rt", client: client).httpBody!, as: UTF8.self)
        XCTAssertTrue(refresh.contains("grant_type=refresh_token") && refresh.contains("refresh_token=rt"))
        let revoke = GoogleAuth.revokeRequest(token: "a+b")
        XCTAssertEqual(revoke.url, GoogleAuth.revokeEndpoint)
        XCTAssertEqual(String(decoding: revoke.httpBody!, as: UTF8.self), "token=a%2Bb")
    }

    func testTokenParsingTakesEmailFromIDTokenAndKeepsItOnRefresh() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try GoogleAuth.token(
            from: json(["access_token": "at", "expires_in": 3_600, "refresh_token": "rt", "id_token": jwt(["email": "Ana@Example.com"])]),
            now: now, previous: nil)
        XCTAssertEqual(first, GoogleToken(accessToken: "at", refreshToken: "rt", expiresAt: now.addingTimeInterval(3_600), email: "ana@example.com"))
        XCTAssertFalse(first.needsRefresh(now: now))
        XCTAssertTrue(first.needsRefresh(now: now.addingTimeInterval(3_560)))
        let refreshed = try GoogleAuth.token(from: json(["access_token": "at2", "expires_in": 100]), now: now, previous: first)
        XCTAssertEqual(refreshed.refreshToken, "rt")
        XCTAssertEqual(refreshed.email, "ana@example.com")
        XCTAssertEqual(refreshed.accessToken, "at2")
    }

    func testTokenParsingFailures() {
        let now = Date()
        XCTAssertThrowsError(try GoogleAuth.token(from: json(["error": "invalid_grant", "error_description": "Bad"]), now: now, previous: nil)) {
            XCTAssertEqual($0 as? GoogleAuthError, .rejected(code: "invalid_grant", description: "Bad"))
        }
        XCTAssertThrowsError(try GoogleAuth.token(from: json(["access_token": "a", "expires_in": 1, "id_token": jwt(["email": "a@b.c"])]), now: now, previous: nil)) {
            XCTAssertEqual($0 as? GoogleAuthError, .missingRefreshToken)
        }
        XCTAssertThrowsError(try GoogleAuth.token(from: json(["access_token": "a", "expires_in": 1, "refresh_token": "r"]), now: now, previous: nil)) {
            XCTAssertEqual($0 as? GoogleAuthError, .missingEmail)
        }
        XCTAssertThrowsError(try GoogleAuth.token(from: Data("x".utf8), now: now, previous: nil)) { XCTAssertEqual($0 as? GoogleAuthError, .malformed) }
        XCTAssertNil(GoogleAuth.email(fromIDToken: "a.b"))
    }

    func testCallbackReuseRejectsWrongState() {
        XCTAssertThrowsError(try SpotifyCallback.parse(target: "/callback?code=x&state=bad", path: GoogleAuth.redirectPath, state: "good"))
        XCTAssertEqual(try SpotifyCallback.parse(target: "/callback?code=x&state=good", path: GoogleAuth.redirectPath, state: "good"), .code("x"))
    }
}

final class GoogleCalendarRequestTests: XCTestCase {
    func testListRequestQueriesICalUID() {
        let request = GoogleCalendarAPI.listRequest(iCalUID: "abc+1@google.com", token: "tok")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/calendar/v3/calendars/primary/events")
        XCTAssertEqual(query(request)["iCalUID"], "abc+1@google.com")
        XCTAssertTrue(request.url!.absoluteString.contains("iCalUID=abc%2B1@google.com") || request.url!.absoluteString.contains("iCalUID=abc%2B1%40google.com"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
    }

    func testInstancesWindowAndPath() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let request = GoogleCalendarAPI.instancesRequest(eventID: "ev/1", around: start, token: "t")
        XCTAssertTrue(request.url!.path.hasSuffix("/events/ev%2F1/instances") || request.url!.absoluteString.contains("/events/ev%2F1/instances"))
        XCTAssertEqual(query(request)["timeMin"], "2023-11-13T22:13:20Z")
        XCTAssertEqual(query(request)["timeMax"], "2023-11-15T22:13:20Z")
    }

    func testPatchRequestNotifiesEveryoneAndGuardsWithETag() {
        let request = GoogleCalendarAPI.patchRequest(eventID: "e1", body: Data("{}".utf8), etag: "\"123\"", token: "t")
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(query(request)["sendUpdates"], "all")
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"123\"")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(GoogleCalendarAPI.patchRequest(eventID: "e1", body: Data(), etag: nil, token: "t").value(forHTTPHeaderField: "If-Match"))
    }

    func testPatchBodyChangesOnlySelfAndKeepsEveryOtherField() throws {
        let event: [String: Any] = [
            "etag": "\"9\"",
            "summary": "Sync",
            "attendees": [
                ["email": "boss@x.com", "organizer": true, "responseStatus": "accepted", "displayName": "Boss"],
                ["email": "me@x.com", "self": true, "responseStatus": "needsAction", "optional": true, "comment": "hi"],
                ["email": "peer@x.com", "responseStatus": "tentative", "additionalGuests": 2],
            ],
        ]
        let patch = try GoogleCalendarAPI.patchBody(fromEvent: json(event), choice: .declined, accountEmail: "me@x.com")
        XCTAssertEqual(patch.etag, "\"9\"")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: patch.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["attendees"])
        let attendees = try XCTUnwrap(body["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.count, 3)
        XCTAssertEqual(attendees[0]["responseStatus"] as? String, "accepted")
        XCTAssertEqual(attendees[0]["displayName"] as? String, "Boss")
        XCTAssertEqual(attendees[1]["responseStatus"] as? String, "declined")
        XCTAssertEqual(attendees[1]["comment"] as? String, "hi")
        XCTAssertEqual(attendees[1]["optional"] as? Bool, true)
        XCTAssertEqual(attendees[2]["responseStatus"] as? String, "tentative")
        XCTAssertEqual(attendees[2]["additionalGuests"] as? Int, 2)
    }

    func testSelfSelectionFallsBackToAccountEmailAndFailsWithoutOne() throws {
        let noFlag: [String: Any] = ["attendees": [["email": "a@x.com", "responseStatus": "needsAction"], ["email": "Me@X.com", "responseStatus": "needsAction"]]]
        let patch = try GoogleCalendarAPI.patchBody(fromEvent: json(noFlag), choice: .accepted, accountEmail: "me@x.com")
        let attendees = try XCTUnwrap((JSONSerialization.jsonObject(with: patch.body) as? [String: Any])?["attendees"] as? [[String: Any]])
        XCTAssertEqual(attendees.map { $0["responseStatus"] as? String }, ["needsAction", "accepted"])
        XCTAssertThrowsError(try GoogleCalendarAPI.patchBody(fromEvent: json(noFlag), choice: .accepted, accountEmail: "other@x.com")) {
            XCTAssertEqual($0 as? GoogleRSVPError, .notInvitee)
        }
        XCTAssertThrowsError(try GoogleCalendarAPI.patchBody(fromEvent: Data("[]".utf8), choice: .accepted, accountEmail: "a")) {
            XCTAssertEqual($0 as? GoogleRSVPError, .malformed)
        }
    }

    func testTruncatedAttendeeListIsNeverPatched() {
        let event: [String: Any] = ["attendeesOmitted": true, "attendees": [["email": "me@x.com", "self": true, "responseStatus": "needsAction"]]]
        XCTAssertThrowsError(try GoogleCalendarAPI.patchBody(fromEvent: json(event), choice: .accepted, accountEmail: "me@x.com")) {
            XCTAssertEqual($0 as? GoogleRSVPError, .tooManyAttendees)
        }
        XCTAssertEqual(GoogleRSVPError.tooManyAttendees.message, "Esse convite tem convidados demais para responder pelo Wisp; responda pelo Google Agenda.")
    }

    func testAccountSelection() {
        let me = CalAttendee(name: "Me", email: "Me@X.com", status: .pending, isMe: true)
        let other = CalAttendee(name: "O", email: "o@x.com")
        XCTAssertEqual(GoogleCalendarAPI.account(for: [other, me], connected: ["me@x.com"]), "me@x.com")
        XCTAssertNil(GoogleCalendarAPI.account(for: [other, me], connected: ["o@x.com"]))
        XCTAssertNil(GoogleCalendarAPI.account(for: [other, me], connected: []))
        XCTAssertNil(GoogleCalendarAPI.account(for: [CalAttendee(name: "Me", email: "me@x.com", isOrganizer: true, isMe: true)], connected: ["me@x.com"]))
        XCTAssertNil(GoogleCalendarAPI.account(for: [CalAttendee(name: "Me", email: nil, isMe: true)], connected: ["me@x.com"]))
    }

    func testChoiceMapping() {
        XCTAssertNil(GoogleRSVPChoice(.pending))
        for choice in GoogleRSVPChoice.allCases { XCTAssertEqual(GoogleRSVPChoice(choice.attendeeStatus), choice) }
        XCTAssertEqual(GoogleRSVPChoice.allCases.map(\.label), ["Sim", "Talvez", "Não"])
    }
}

final class GoogleMatchingTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let start = ISO8601DateFormatter().date(from: "2026-11-24T13:00:00Z")!

    private func stub(_ id: String, start: String? = nil, original: String? = nil, recurrence: [String]? = nil, series: String? = nil, status: String? = nil) -> GoogleEventStub {
        GoogleEventStub(
            id: id, status: status, recurrence: recurrence, recurringEventId: series,
            start: start.map { GoogleWhen(dateTime: $0, date: nil) }, originalStartTime: original.map { GoogleWhen(dateTime: $0, date: nil) })
    }

    func testSingleEventMatchesWithoutStart() {
        let items = [stub("one", start: "2026-11-24T10:00:00-03:00")]
        XCTAssertEqual(GoogleCalendarAPI.match(items, start: start, allDay: false, calendar: utc, isRecurring: false), .found("one"))
        XCTAssertEqual(GoogleCalendarAPI.match([], start: start, allDay: false, calendar: utc, isRecurring: false), .none)
    }

    func testRecurringExceptionMatchesOnOriginalStartTimeAcrossOffsets() {
        let items = [
            stub("master", start: "2026-11-17T10:00:00-03:00", recurrence: ["RRULE:FREQ=WEEKLY"]),
            stub("master_20261124T130000Z", start: "2026-11-24T15:00:00-03:00", original: "2026-11-24T10:00:00-03:00", series: "master"),
        ]
        XCTAssertEqual(GoogleCalendarAPI.match(items, start: start, allDay: false, calendar: utc, isRecurring: true), .found("master_20261124T130000Z"))
    }

    func testRecurringPlainOccurrenceGoesThroughInstances() {
        let items = [stub("master", start: "2026-11-17T10:00:00-03:00", recurrence: ["RRULE:FREQ=WEEKLY"]),
                     stub("master_20261201T130000Z", start: "2026-12-01T10:00:00-03:00", original: "2026-12-01T10:00:00-03:00", series: "master")]
        XCTAssertEqual(GoogleCalendarAPI.match(items, start: start, allDay: false, calendar: utc, isRecurring: true), .needsInstances(master: "master"))
        XCTAssertEqual(GoogleCalendarAPI.match([stub("x", start: "2026-11-24T13:00:00Z")], start: start, allDay: false, calendar: utc, isRecurring: true), .none)
    }

    func testInstancePickUsesOriginalStartAndFractionalSeconds() {
        let instances = [stub("a", start: "2026-11-17T13:00:00Z"), stub("b", start: "2026-11-24T13:00:00.000Z"), stub("c", start: "2026-11-24T20:00:00Z", original: "2026-11-25T13:00:00Z")]
        XCTAssertEqual(GoogleCalendarAPI.pickInstance(instances, start: start, allDay: false, calendar: utc), "b")
        XCTAssertNil(GoogleCalendarAPI.pickInstance([stub("a", start: "2026-11-17T13:00:00Z")], start: start, allDay: false, calendar: utc))
    }

    func testAllDayMatchesOnDate() {
        let day = utc.startOfDay(for: start)
        let item = GoogleEventStub(id: "d", status: nil, recurrence: nil, recurringEventId: "m", start: GoogleWhen(dateTime: nil, date: "2026-11-24"), originalStartTime: nil)
        XCTAssertEqual(GoogleCalendarAPI.pickInstance([item], start: day, allDay: true, calendar: utc), "d")
        XCTAssertNil(GoogleCalendarAPI.pickInstance([item], start: day.addingTimeInterval(86_400), allDay: true, calendar: utc))
    }

    func testCancelledItemsAreDropped() throws {
        let data = json(["items": [["id": "a", "status": "cancelled"], ["id": "b", "status": "confirmed"]]])
        XCTAssertEqual(try GoogleCalendarAPI.stubs(from: data).map(\.id), ["b"])
        XCTAssertEqual(try GoogleCalendarAPI.stubs(from: json([String: Any]())).count, 0)
        XCTAssertThrowsError(try GoogleCalendarAPI.stubs(from: Data("x".utf8)))
    }
}

private actor FakeTransport: GoogleTransport {
    private var replies: [(Int, Data)]
    private(set) var requests: [URLRequest] = []

    init(_ replies: [(Int, Data)]) { self.replies = replies }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        requests.append(request)
        guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
        let reply = replies.removeFirst()
        return (reply.1, reply.0)
    }
}

final class GoogleRSVPServiceTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let start = ISO8601DateFormatter().date(from: "2026-11-24T13:00:00Z")!
    private let event: [String: Any] = ["etag": "\"e\"", "attendees": [["email": "o@x.com", "organizer": true, "responseStatus": "accepted"], ["email": "me@x.com", "self": true, "responseStatus": "needsAction"]]]

    private func service(_ transport: FakeTransport, refreshes: Counter = Counter()) -> GoogleRSVPService {
        GoogleRSVPService(transport: transport) { force in
            if force { await refreshes.bump() }
            return force ? "fresh" : "old"
        }
    }

    actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
    }

    func testSingleEventListGetPatch() async throws {
        let transport = FakeTransport([(200, json(["items": [["id": "e1"]]])), (200, json(event)), (200, json([String: Any]()))])
        try await service(transport).respond(iCalUID: "u@g", start: start, allDay: false, isRecurring: false, calendar: utc, choice: .tentative, accountEmail: "me@x.com")
        let requests = await transport.requests
        XCTAssertEqual(requests.map { $0.httpMethod ?? "GET" }, ["GET", "GET", "PATCH"])
        XCTAssertTrue(requests[1].url!.path.hasSuffix("/events/e1"))
        XCTAssertEqual(query(requests[2])["sendUpdates"], "all")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        XCTAssertEqual((sent["attendees"] as? [[String: Any]])?.map { $0["responseStatus"] as? String }, ["accepted", "tentative"])
    }

    func testRecurringPlainOccurrenceUsesInstances() async throws {
        let list = json(["items": [["id": "m", "recurrence": ["RRULE:FREQ=WEEKLY"], "start": ["dateTime": "2026-11-17T13:00:00Z"]]]])
        let instances = json(["items": [["id": "m_20261124T130000Z", "start": ["dateTime": "2026-11-24T13:00:00Z"]]]])
        let transport = FakeTransport([(200, list), (200, instances), (200, json(event)), (200, json([String: Any]()))])
        try await service(transport).respond(iCalUID: "u", start: start, allDay: false, isRecurring: true, calendar: utc, choice: .accepted, accountEmail: "me@x.com")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 4)
        XCTAssertTrue(requests[1].url!.path.hasSuffix("/events/m/instances"))
        XCTAssertTrue(requests[3].url!.path.hasSuffix("/events/m_20261124T130000Z"))
    }

    func testRetriesOnceOnUnauthorizedWithFreshToken() async throws {
        let transport = FakeTransport([(401, Data()), (200, json(["items": [["id": "e1"]]])), (200, json(event)), (200, Data("{}".utf8))])
        let refreshes = Counter()
        try await service(transport, refreshes: refreshes).respond(iCalUID: "u", start: start, allDay: false, isRecurring: false, calendar: utc, choice: .accepted, accountEmail: "me@x.com")
        let requests = await transport.requests
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer old")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer fresh")
        let count = await refreshes.value
        XCTAssertEqual(count, 1)
    }

    private func failure(_ replies: [(Int, Data)]) async -> GoogleRSVPError? {
        do {
            try await service(FakeTransport(replies)).respond(iCalUID: "u", start: start, allDay: false, isRecurring: false, calendar: utc, choice: .accepted, accountEmail: "me@x.com")
            return nil
        } catch {
            return error as? GoogleRSVPError
        }
    }

    func testFailuresMapToPortugueseErrors() async {
        let listed = (200, json(["items": [["id": "e1"]]]))
        let fetched = (200, json(event))
        var failure = await self.failure([(200, json(["items": [Any]()]))])
        XCTAssertEqual(failure, .notFound)
        failure = await self.failure([(401, Data()), (401, Data())])
        XCTAssertEqual(failure, .unauthorized)
        failure = await self.failure([(403, Data())])
        XCTAssertEqual(failure, .forbidden)
        failure = await self.failure([listed, fetched, (412, Data())])
        XCTAssertEqual(failure, .changed)
        failure = await self.failure([(429, Data())])
        XCTAssertEqual(failure, .rateLimited)
        failure = await self.failure([(503, Data())])
        XCTAssertEqual(failure, .http(503))
        failure = await self.failure([])
        XCTAssertEqual(failure, .network)
        failure = await self.failure([listed, (200, json(["attendees": [["email": "z@x.com"]]]))])
        XCTAssertEqual(failure, .notInvitee)
        XCTAssertEqual(GoogleRSVPError.http(503).message, "O Google respondeu erro 503; tente de novo.")
    }
}

private actor SlowTransport: GoogleTransport {
    private(set) var started = 0
    let fails: Bool

    init(fails: Bool) { self.fails = fails }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        started += 1
        if fails { throw URLError(.notConnectedToInternet) }
        try await Task.sleep(for: .seconds(30))
        return (Data(), 200)
    }
}

private final class LocalToken: @unchecked Sendable {
    private let lock = NSLock()
    private var present = true
    private var order: [String] = []
    var isPresent: Bool { lock.withLock { present } }
    var events: [String] { lock.withLock { order } }
    func delete() { lock.withLock { present = false; order.append("deleted") } }
}

final class GoogleSignOutTests: XCTestCase {
    func testSlowRevokeStillLeavesNoTokenAndReturnsAtTheTimeout() async {
        let local = LocalToken()
        let transport = SlowTransport(fails: false)
        let began = Date()
        await GoogleSignOut.run(refreshToken: "rt", deleteLocal: { local.delete() }, transport: transport, timeout: .milliseconds(200))
        XCTAssertFalse(local.isPresent)
        XCTAssertLessThan(Date().timeIntervalSince(began), 5)
        let started = await transport.started
        XCTAssertEqual(started, 1)
    }

    func testFailedRevokeStillLeavesNoToken() async {
        let local = LocalToken()
        await GoogleSignOut.run(refreshToken: "rt", deleteLocal: { local.delete() }, transport: SlowTransport(fails: true), timeout: .seconds(1))
        XCTAssertFalse(local.isPresent)
    }

    func testTokenIsDeletedBeforeTheRevokeIsSent() async {
        let local = LocalToken()
        let probe = ProbeTransport(local: local)
        await GoogleSignOut.run(refreshToken: "rt", deleteLocal: { local.delete() }, transport: probe, timeout: .seconds(1))
        let seen = await probe.presentWhenSent
        XCTAssertEqual(seen, [false])
    }

    func testNoRefreshTokenSkipsTheRevoke() async {
        let local = LocalToken()
        let transport = SlowTransport(fails: false)
        await GoogleSignOut.run(refreshToken: nil, deleteLocal: { local.delete() }, transport: transport, timeout: .seconds(1))
        XCTAssertFalse(local.isPresent)
        let started = await transport.started
        XCTAssertEqual(started, 0)
    }
}

private actor ProbeTransport: GoogleTransport {
    private let local: LocalToken
    private(set) var presentWhenSent: [Bool] = []

    init(local: LocalToken) { self.local = local }

    func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        presentWhenSent.append(local.isPresent)
        return (Data(), 200)
    }
}
