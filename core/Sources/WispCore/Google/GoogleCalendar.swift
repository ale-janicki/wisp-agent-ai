import Foundation

/// The answer the user gives to an invitation, in Google's wording.
public enum GoogleRSVPChoice: String, CaseIterable, Equatable, Sendable {
    case accepted, tentative, declined

    public init?(_ status: AttendeeStatus) {
        switch status {
        case .accepted: self = .accepted
        case .tentative: self = .tentative
        case .declined: self = .declined
        case .pending: return nil
        }
    }

    public var attendeeStatus: AttendeeStatus {
        switch self {
        case .accepted: .accepted
        case .tentative: .tentative
        case .declined: .declined
        }
    }

    public var label: String {
        switch self {
        case .accepted: "Sim"
        case .tentative: "Talvez"
        case .declined: "Não"
        }
    }
}

public enum GoogleRSVPError: Error, Equatable, Sendable {
    case notConnected
    case unauthorized
    case forbidden
    case notFound
    case notInvitee
    case tooManyAttendees
    case changed
    case rateLimited
    case http(Int)
    case network
    case malformed

    public var message: String {
        switch self {
        case .notConnected: "Conecte o Google em Ajustes > Integrações para responder."
        case .unauthorized: "O Google recusou o acesso; desconecte e conecte a conta de novo em Ajustes > Integrações."
        case .forbidden: "O Google não deixou responder a este convite com esta conta."
        case .notFound: "Não achei este evento na agenda do Google desta conta."
        case .notInvitee: "Esta conta do Google não está entre os convidados do evento."
        case .tooManyAttendees: "Esse convite tem convidados demais para responder pelo Wisp; responda pelo Google Agenda."
        case .changed: "O evento mudou no Google enquanto você respondia; tente de novo."
        case .rateLimited: "O Google pediu uma pausa; tente de novo em instantes."
        case .http(let status): "O Google respondeu erro \(status); tente de novo."
        case .network: "Sem conexão com o Google; confira a internet."
        case .malformed: "Não entendi a resposta do Google."
        }
    }
}

public protocol GoogleTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionGoogleTransport: GoogleTransport {
    private let session: URLSession

    public init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct GoogleWhen: Decodable, Equatable {
    var dateTime: String?
    var date: String?
}

/// Just enough of an event to decide which one is the invitation on screen.
struct GoogleEventStub: Decodable, Equatable {
    var id: String
    var status: String?
    var recurrence: [String]?
    var recurringEventId: String?
    var start: GoogleWhen?
    var originalStartTime: GoogleWhen?
}

struct GoogleEventList: Decodable {
    var items: [GoogleEventStub]?
}

enum GoogleEventMatch: Equatable {
    case found(String)
    case needsInstances(master: String)
    case none
}

public enum GoogleCalendarAPI {
    public static let base = "https://www.googleapis.com/calendar/v3/calendars/primary/events"
    static let stubFields = "items(id,status,recurrence,recurringEventId,start,originalStartTime)"

    // MARK: Requests

    public static func listRequest(iCalUID: String, token: String) -> URLRequest {
        request(base, query: [("iCalUID", iCalUID), ("showDeleted", "false"), ("maxResults", "250"), ("fields", stubFields)], token: token)
    }

    /// Instances around the occurrence; a moved occurrence keeps its original start, so the window is a day each side.
    public static func instancesRequest(eventID: String, around start: Date, token: String) -> URLRequest {
        request(
            "\(base)/\(pathEncode(eventID))/instances",
            query: [("timeMin", rfc3339(start.addingTimeInterval(-86_400))), ("timeMax", rfc3339(start.addingTimeInterval(86_400))),
                    ("showDeleted", "false"), ("maxResults", "50"), ("fields", stubFields)],
            token: token
        )
    }

    public static func getRequest(eventID: String, token: String) -> URLRequest {
        request("\(base)/\(pathEncode(eventID))", query: [], token: token)
    }

    public static func patchRequest(eventID: String, body: Data, etag: String?, token: String) -> URLRequest {
        var request = request("\(base)/\(pathEncode(eventID))", query: [("sendUpdates", "all")], token: token)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-Match") }
        request.httpBody = body
        return request
    }

    // MARK: Patch body

    /// From the fetched event, a body that carries every attendee exactly as Google sent it and changes only the one that is the user.
    /// Google replaces `attendees` as a whole on patch, so the full list has to go back.
    public static func patchBody(fromEvent data: Data, choice: GoogleRSVPChoice, accountEmail: String) throws -> (body: Data, etag: String?) {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw GoogleRSVPError.malformed }
        // Google replaces `attendees` as a whole: a truncated list sent back would remove the guests it left out.
        if event["attendeesOmitted"] as? Bool == true { throw GoogleRSVPError.tooManyAttendees }
        var attendees = (event["attendees"] as? [[String: Any]]) ?? []
        guard let index = selfAttendeeIndex(attendees, accountEmail: accountEmail) else { throw GoogleRSVPError.notInvitee }
        attendees[index]["responseStatus"] = choice.rawValue
        guard let body = try? JSONSerialization.data(withJSONObject: ["attendees": attendees], options: [.sortedKeys]) else { throw GoogleRSVPError.malformed }
        return (body, event["etag"] as? String)
    }

    /// The attendee Google flags `self`, else the one whose address is the connected account.
    static func selfAttendeeIndex(_ attendees: [[String: Any]], accountEmail: String) -> Int? {
        if let flagged = attendees.firstIndex(where: { $0["self"] as? Bool == true }) { return flagged }
        let wanted = accountEmail.lowercased()
        return attendees.firstIndex { ($0["email"] as? String)?.lowercased() == wanted }
    }

    // MARK: Matching

    static func stubs(from data: Data) throws -> [GoogleEventStub] {
        guard let list = try? JSONDecoder().decode(GoogleEventList.self, from: data) else { throw GoogleRSVPError.malformed }
        return (list.items ?? []).filter { $0.status != "cancelled" }
    }

    /// Picks the Google event for an EventKit one. All occurrences of a series share one iCalUID, so a recurring event is told apart by its
    /// start: an exception matches on `originalStartTime`, a plain occurrence is found through `instances` of the series master.
    static func match(_ items: [GoogleEventStub], start: Date, allDay: Bool, calendar: Calendar, isRecurring: Bool) -> GoogleEventMatch {
        func sameStart(_ item: GoogleEventStub) -> Bool {
            matches(item.originalStartTime ?? item.start, start: start, allDay: allDay, calendar: calendar)
        }
        if !isRecurring {
            if let single = items.first(where: { $0.recurrence == nil && $0.recurringEventId == nil }) { return .found(single.id) }
            return .none
        }
        if let occurrence = items.first(where: { $0.recurringEventId != nil && sameStart($0) }) { return .found(occurrence.id) }
        if let master = items.first(where: { $0.recurrence?.isEmpty == false }) { return .needsInstances(master: master.id) }
        return .none
    }

    static func pickInstance(_ items: [GoogleEventStub], start: Date, allDay: Bool, calendar: Calendar) -> String? {
        items.first { matches($0.originalStartTime ?? $0.start, start: start, allDay: allDay, calendar: calendar) }?.id
    }

    static func matches(_ when: GoogleWhen?, start: Date, allDay: Bool, calendar: Calendar) -> Bool {
        guard let when else { return false }
        if let text = when.dateTime, let parsed = parse(text) { return abs(parsed.timeIntervalSince(start)) < 1 }
        if let day = when.date, allDay { return day == dayString(start, calendar: calendar) }
        return false
    }

    // MARK: Account

    /// The connected account that is the user's own row in the invitation, or nil when RSVP does not apply
    /// (no matching account, the user organises the event, or nobody invited anybody).
    public static func account(for attendees: [CalAttendee], connected: [String]) -> String? {
        let known = Set(connected.map { $0.lowercased() })
        let mine = attendees.first { $0.isMe && $0.email.map { known.contains($0.lowercased()) } == true }
        guard let mine, !mine.isOrganizer, let email = mine.email else { return nil }
        return email.lowercased()
    }

    // MARK: Helpers

    private static func request(_ url: String, query: [(String, String)], token: String) -> URLRequest {
        var parts = URLComponents(string: url)!
        if !query.isEmpty { parts.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) } }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        var request = URLRequest(url: parts.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private static let pathAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    private static func pathEncode(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: pathAllowed) ?? id
    }

    private static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    private static func parse(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: text) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    private static func dayString(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// Answers an invitation through the Google Calendar API: find the event, fetch it, change only the user's row, patch.
public struct GoogleRSVPService: Sendable {
    public typealias TokenProvider = @Sendable (_ forceRefresh: Bool) async throws -> String

    private let transport: any GoogleTransport
    private let accessToken: TokenProvider

    public init(transport: any GoogleTransport, accessToken: @escaping TokenProvider) {
        self.transport = transport
        self.accessToken = accessToken
    }

    public func respond(
        iCalUID: String, start: Date, allDay: Bool, isRecurring: Bool, calendar: Calendar,
        choice: GoogleRSVPChoice, accountEmail: String
    ) async throws {
        let listed = try GoogleCalendarAPI.stubs(from: try await call { GoogleCalendarAPI.listRequest(iCalUID: iCalUID, token: $0) })
        let eventID: String
        switch GoogleCalendarAPI.match(listed, start: start, allDay: allDay, calendar: calendar, isRecurring: isRecurring) {
        case .found(let id):
            eventID = id
        case .needsInstances(let master):
            let instances = try GoogleCalendarAPI.stubs(from: try await call { GoogleCalendarAPI.instancesRequest(eventID: master, around: start, token: $0) })
            guard let id = GoogleCalendarAPI.pickInstance(instances, start: start, allDay: allDay, calendar: calendar) else { throw GoogleRSVPError.notFound }
            eventID = id
        case .none:
            throw GoogleRSVPError.notFound
        }
        let fetched = try await call { GoogleCalendarAPI.getRequest(eventID: eventID, token: $0) }
        let patch = try GoogleCalendarAPI.patchBody(fromEvent: fetched, choice: choice, accountEmail: accountEmail)
        _ = try await call { GoogleCalendarAPI.patchRequest(eventID: eventID, body: patch.body, etag: patch.etag, token: $0) }
    }

    /// One request with the current token; a 401 gets one retry with a freshly refreshed token.
    private func call(_ build: (String) -> URLRequest) async throws -> Data {
        var forceRefresh = false
        while true {
            let token = try await accessToken(forceRefresh)
            let result: (data: Data, status: Int)
            do {
                result = try await transport.send(build(token))
            } catch {
                throw GoogleRSVPError.network
            }
            switch result.status {
            case 200..<300: return result.data
            case 401 where !forceRefresh: forceRefresh = true
            case 401: throw GoogleRSVPError.unauthorized
            case 403: throw GoogleRSVPError.forbidden
            case 404: throw GoogleRSVPError.notFound
            case 412: throw GoogleRSVPError.changed
            case 429: throw GoogleRSVPError.rateLimited
            default: throw GoogleRSVPError.http(result.status)
            }
        }
    }
}

/// Disconnecting an account: the local token goes first, so a slow or failed revoke can never leave one behind.
public enum GoogleSignOut {
    public static let revokeTimeout: Duration = .seconds(5)

    public static func run(
        refreshToken: String?, deleteLocal: @Sendable () -> Void, transport: any GoogleTransport, timeout: Duration = revokeTimeout
    ) async {
        deleteLocal()
        guard let refreshToken else { return }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await transport.send(GoogleAuth.revokeRequest(token: refreshToken)) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
