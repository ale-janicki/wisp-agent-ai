import XCTest
@testable import WispCore

final class SpotifyPKCETests: XCTestCase {
    func testChallengeMatchesTheRFC7636Vector() {
        XCTAssertEqual(
            SpotifyPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
        )
    }

    func testVerifierIsUnreservedAndInRange() {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let verifier = SpotifyPKCE.makeVerifier()
        XCTAssertTrue((43...128).contains(verifier.count))
        XCTAssertTrue(verifier.unicodeScalars.allSatisfy(allowed.contains))
        XCTAssertNotEqual(verifier, SpotifyPKCE.makeVerifier())
    }

    func testVerifierFromBytesIsBase64URLWithoutPadding() {
        XCTAssertEqual(SpotifyPKCE.verifier(bytes: [0xFB, 0xFF, 0xBF]), "-_-_")
        XCTAssertEqual(SpotifyPKCE.verifier(bytes: [0x00]), "AA")
    }
}

final class SpotifyAuthTests: XCTestCase {
    private let redirect = URL(string: "http://127.0.0.1:43821/callback")!

    func testRedirectIsTheLoopbackLiteral() {
        XCTAssertEqual(SpotifyAuth.redirectURI.absoluteString, "http://127.0.0.1:43821/callback")
        XCTAssertEqual(SpotifyAuth.redirectPort, 43821)
    }

    func testAuthorizationURLCarriesThePKCEParameters() throws {
        let url = SpotifyAuth.authorizationURL(clientID: "abc", redirectURI: redirect, state: "st", challenge: "ch", scopes: ["a-b", "c"])
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "accounts.spotify.com")
        XCTAssertEqual(parts.path, "/authorize")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query, [
            "client_id": "abc",
            "response_type": "code",
            "redirect_uri": "http://127.0.0.1:43821/callback",
            "state": "st",
            "scope": "a-b c",
            "code_challenge_method": "S256",
            "code_challenge": "ch",
        ])
    }

    func testTokenExchangeIsAFormPostWithoutSecret() throws {
        let request = SpotifyAuth.tokenExchangeRequest(code: "c+d/e", verifier: "v", clientID: "id", redirectURI: redirect)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://accounts.spotify.com/api/token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=authorization_code&code=c%2Bd%2Fe&redirect_uri=http%3A%2F%2F127.0.0.1%3A43821%2Fcallback&client_id=id&code_verifier=v")
    }

    func testRefreshRequestSendsClientID() throws {
        let request = SpotifyAuth.refreshRequest(refreshToken: "r", clientID: "id")
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=refresh_token&refresh_token=r&client_id=id")
    }

    func testTokenResponseSetsExpiry() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let json = #"{"access_token":"A","token_type":"Bearer","scope":"x y","expires_in":3600,"refresh_token":"R"}"#
        let token = try SpotifyAuth.token(from: Data(json.utf8), now: now, previous: nil)
        XCTAssertEqual(token, SpotifyToken(accessToken: "A", refreshToken: "R", expiresAt: Date(timeIntervalSince1970: 4_600), scope: "x y"))
    }

    func testRefreshWithoutNewRefreshTokenKeepsThePreviousOne() throws {
        let previous = SpotifyToken(accessToken: "old", refreshToken: "R1", expiresAt: .distantPast, scope: "s")
        let json = #"{"access_token":"B","token_type":"Bearer","expires_in":60}"#
        let token = try SpotifyAuth.token(from: Data(json.utf8), now: Date(timeIntervalSince1970: 0), previous: previous)
        XCTAssertEqual(token.refreshToken, "R1")
        XCTAssertEqual(token.accessToken, "B")
        XCTAssertEqual(token.scope, "s")
    }

    func testFirstTokenWithoutRefreshTokenIsAnError() {
        let json = #"{"access_token":"B","token_type":"Bearer","expires_in":60}"#
        XCTAssertThrowsError(try SpotifyAuth.token(from: Data(json.utf8), now: Date(), previous: nil))
    }

    func testRejectedGrantIsReported() {
        let json = #"{"error":"invalid_grant","error_description":"Refresh token revoked"}"#
        XCTAssertThrowsError(try SpotifyAuth.token(from: Data(json.utf8), now: Date(), previous: nil)) { error in
            XCTAssertEqual(error as? SpotifyAuthError, .rejected(code: "invalid_grant", description: "Refresh token revoked"))
        }
    }

    func testNeedsRefreshUsesSkew() {
        let token = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 1_000), scope: "")
        XCTAssertFalse(token.needsRefresh(now: Date(timeIntervalSince1970: 900), skew: 60))
        XCTAssertTrue(token.needsRefresh(now: Date(timeIntervalSince1970: 941), skew: 60))
        XCTAssertTrue(token.needsRefresh(now: Date(timeIntervalSince1970: 2_000), skew: 60))
    }

    func testTokenRoundTripsThroughCodable() throws {
        let token = SpotifyToken(accessToken: "a", refreshToken: "r", expiresAt: Date(timeIntervalSince1970: 12), scope: "s")
        XCTAssertEqual(try JSONDecoder().decode(SpotifyToken.self, from: JSONEncoder().encode(token)), token)
    }
}

final class SpotifyCallbackTests: XCTestCase {
    func testParsesTheRequestTarget() {
        XCTAssertEqual(SpotifyCallback.requestTarget(fromHead: "GET /callback?code=x&state=y HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"), "/callback?code=x&state=y")
        XCTAssertNil(SpotifyCallback.requestTarget(fromHead: "garbage"))
        XCTAssertNil(SpotifyCallback.requestTarget(fromHead: "POST /callback HTTP/1.1\r\n\r\n"))
    }

    func testCodeWithMatchingState() throws {
        XCTAssertEqual(try SpotifyCallback.parse(target: "/callback?code=AQ%2Bx&state=s1", path: "/callback", state: "s1"), .code("AQ+x"))
    }

    func testStateMismatchIsRejected() {
        XCTAssertThrowsError(try SpotifyCallback.parse(target: "/callback?code=x&state=evil", path: "/callback", state: "s1")) {
            XCTAssertEqual($0 as? SpotifyCallbackError, .stateMismatch)
        }
        XCTAssertThrowsError(try SpotifyCallback.parse(target: "/callback?code=x", path: "/callback", state: "s1")) {
            XCTAssertEqual($0 as? SpotifyCallbackError, .stateMismatch)
        }
    }

    func testDeniedAndOtherPaths() throws {
        XCTAssertEqual(try SpotifyCallback.parse(target: "/callback?error=access_denied&state=s1", path: "/callback", state: "s1"), .denied("access_denied"))
        XCTAssertThrowsError(try SpotifyCallback.parse(target: "/favicon.ico", path: "/callback", state: "s1")) {
            XCTAssertEqual($0 as? SpotifyCallbackError, .notCallback)
        }
        XCTAssertThrowsError(try SpotifyCallback.parse(target: "/callback?state=s1", path: "/callback", state: "s1")) {
            XCTAssertEqual($0 as? SpotifyCallbackError, .missingCode)
        }
    }
}

final class SpotifyModelTests: XCTestCase {
    func testPlaylistPageReadsItemsTotalAndSkipsNulls() throws {
        let json = #"""
        {"href":"h","limit":2,"next":"https://api.spotify.com/v1/me/playlists?offset=2&limit=2","offset":0,"previous":null,"total":3,
         "items":[
          {"collaborative":false,"id":"p1","name":"Foco","uri":"spotify:playlist:p1","images":[{"url":"https://i.scdn.co/a","height":640,"width":640},{"url":"https://i.scdn.co/b","height":60,"width":60}],
           "owner":{"id":"u1","display_name":"Dono"},"items":{"href":"x","total":42},"tracks":{"href":"x","total":42},"type":"playlist"},
          null,
          {"collaborative":true,"id":"p2","name":"Velha","uri":"spotify:playlist:p2","images":null,"owner":{"id":"u2","display_name":null},"tracks":{"href":"x","total":7},"type":"playlist"}
         ]}
        """#
        let page = try JSONDecoder().decode(SpotifyPage<SpotifyPlaylist>.self, from: Data(json.utf8))
        XCTAssertEqual(page.total, 3)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.items.map(\.id), ["p1", "p2"])
        XCTAssertEqual(page.items[0].trackCount, 42)
        XCTAssertEqual(page.items[0].ownerName, "Dono")
        XCTAssertEqual(page.items[1].trackCount, 7)
        XCTAssertEqual(page.items[1].images, [])
        XCTAssertTrue(page.items[1].collaborative)
        XCTAssertEqual(page.items[0].images.best(forPixels: 100)?.absoluteString, "https://i.scdn.co/a")
        XCTAssertEqual(page.items[0].images.best(forPixels: 48)?.absoluteString, "https://i.scdn.co/b")
        XCTAssertEqual(page.items[0].images.best(forPixels: 2000)?.absoluteString, "https://i.scdn.co/a")
    }

    func testPlaylistItemsReadTheNewItemField() throws {
        let json = #"""
        {"href":"h","limit":50,"next":null,"offset":0,"previous":null,"total":3,"items":[
          {"added_at":"2026-01-01T00:00:00Z","is_local":false,"item":{"id":"t1","name":"Música","uri":"spotify:track:t1","duration_ms":201000,"type":"track",
            "artists":[{"id":"a1","name":"Um","uri":"spotify:artist:a1"},{"id":"a2","name":"Dois","uri":"spotify:artist:a2"}],
            "album":{"id":"al","name":"Disco","uri":"spotify:album:al","images":[{"url":"https://i.scdn.co/c","width":64,"height":64}],"artists":[]}}},
          {"added_at":null,"is_local":false,"item":null},
          {"is_local":false,"track":{"id":"t2","name":"Antiga","uri":"spotify:track:t2","duration_ms":1000,"type":"track","artists":[],"album":null}}
        ]}
        """#
        let page = try JSONDecoder().decode(SpotifyPage<SpotifyPlaylistEntry>.self, from: Data(json.utf8))
        let tracks = page.items.compactMap(\.track)
        XCTAssertEqual(tracks.map(\.uri), ["spotify:track:t1", "spotify:track:t2"])
        XCTAssertEqual(tracks[0].artistLine, "Um, Dois")
        XCTAssertEqual(tracks[0].durationMs, 201000)
        XCTAssertEqual(tracks[0].artwork.best(forPixels: 40)?.absoluteString, "https://i.scdn.co/c")
        XCTAssertFalse(page.hasMore)
    }

    func testSearchResultsGroupEachType() throws {
        let json = #"""
        {"tracks":{"href":"h","limit":2,"next":null,"offset":0,"previous":null,"total":1,"items":[
            {"id":"t","name":"T","uri":"spotify:track:t","duration_ms":1,"artists":[{"name":"A"}],"album":{"id":"al","name":"Al","uri":"spotify:album:al","images":[]}}]},
         "albums":{"href":"h","limit":2,"next":null,"offset":0,"previous":null,"total":1,"items":[
            {"id":"al","name":"Al","uri":"spotify:album:al","images":[],"artists":[{"name":"A"}],"total_tracks":9,"album_type":"album"}]},
         "playlists":{"href":"h","limit":2,"next":null,"offset":0,"previous":null,"total":2,"items":[null,
            {"id":"p","name":"P","uri":"spotify:playlist:p","images":[],"owner":{"display_name":"X"},"items":{"total":3}}]},
         "artists":{"href":"h","limit":2,"next":null,"offset":0,"previous":null,"total":1,"items":[
            {"id":"ar","name":"Ar","uri":"spotify:artist:ar","images":[{"url":"https://i.scdn.co/d","width":160,"height":160}]}]}}
        """#
        let results = try JSONDecoder().decode(SpotifySearchResults.self, from: Data(json.utf8))
        XCTAssertEqual(results.tracks.map(\.name), ["T"])
        XCTAssertEqual(results.albums.map(\.totalTracks), [9])
        XCTAssertEqual(results.playlists.map(\.id), ["p"])
        XCTAssertEqual(results.artists.map(\.name), ["Ar"])
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(try JSONDecoder().decode(SpotifySearchResults.self, from: Data("{}".utf8)).isEmpty)
    }

    func testDevicesAndPick() throws {
        let json = #"""
        {"devices":[
          {"id":"phone","is_active":false,"is_private_session":false,"is_restricted":false,"name":"iPhone","type":"Smartphone","volume_percent":50,"supports_volume":true},
          {"id":"tv","is_active":false,"is_restricted":true,"name":"TV","type":"TV","volume_percent":null},
          {"id":"mac","is_active":false,"is_restricted":false,"name":"Mac","type":"Computer"},
          {"id":null,"is_active":false,"is_restricted":false,"name":"Sem id","type":"Speaker"}
        ]}
        """#
        let devices = try SpotifyDevice.parseList(Data(json.utf8))
        XCTAssertEqual(devices.count, 4)
        XCTAssertEqual(SpotifyDevice.pick(devices)?.id, "mac")
        var active = devices
        active[0].isActive = true
        XCTAssertEqual(SpotifyDevice.pick(active)?.id, "phone")
        XCTAssertNil(SpotifyDevice.pick([devices[1], devices[3]]))
        XCTAssertNil(SpotifyDevice.pick([]))
    }
}

final class SpotifyRequestTests: XCTestCase {
    func testPlaylistsAndItemsRequests() {
        let playlists = SpotifyEndpoint.myPlaylists(limit: 50, offset: 100).urlRequest(accessToken: "tok")
        XCTAssertEqual(playlists.url?.absoluteString, "https://api.spotify.com/v1/me/playlists?limit=50&offset=100")
        XCTAssertEqual(playlists.httpMethod, "GET")
        XCTAssertEqual(playlists.value(forHTTPHeaderField: "Authorization"), "Bearer tok")

        let items = SpotifyEndpoint.playlistItems(id: "p/1", limit: 50, offset: 0).urlRequest(accessToken: "t")
        XCTAssertEqual(items.url?.absoluteString, "https://api.spotify.com/v1/playlists/p%2F1/items?limit=50&offset=0")
    }

    func testSearchClampsLimitToTheDocumentedMaximum() throws {
        let request = SpotifyEndpoint.search(query: "a&b c", limit: 50).urlRequest(accessToken: "t")
        let parts = try XCTUnwrap(request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(parts.path, "/v1/search")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["q"], "a&b c")
        XCTAssertEqual(query["type"], "track,album,playlist,artist")
        XCTAssertEqual(query["limit"], "10")
        XCTAssertFalse(request.url?.absoluteString.contains("a&b") ?? true)
    }

    func testPlayBodies() throws {
        let context = SpotifyEndpoint.play(.context("spotify:playlist:p", startAt: "spotify:track:t"), deviceID: "d 1").urlRequest(accessToken: "t")
        XCTAssertEqual(context.httpMethod, "PUT")
        XCTAssertEqual(context.url?.absoluteString, "https://api.spotify.com/v1/me/player/play?device_id=d%201")
        XCTAssertEqual(context.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(context.httpBody)) as? NSDictionary
        XCTAssertEqual(body, ["context_uri": "spotify:playlist:p", "offset": ["uri": "spotify:track:t"]])

        let tracks = SpotifyEndpoint.play(.tracks(["spotify:track:t"]), deviceID: nil).urlRequest(accessToken: "t")
        XCTAssertEqual(tracks.url?.absoluteString, "https://api.spotify.com/v1/me/player/play")
        let tracksBody = try JSONSerialization.jsonObject(with: XCTUnwrap(tracks.httpBody)) as? NSDictionary
        XCTAssertEqual(tracksBody, ["uris": ["spotify:track:t"]])
    }

    func testQueueAndDevices() {
        let queue = SpotifyEndpoint.queue(uri: "spotify:track:4iV5", deviceID: nil).urlRequest(accessToken: "t")
        XCTAssertEqual(queue.httpMethod, "POST")
        XCTAssertEqual(queue.url?.absoluteString, "https://api.spotify.com/v1/me/player/queue?uri=spotify%3Atrack%3A4iV5")
        XCTAssertTrue(SpotifyEndpoint.queue(uri: "x", deviceID: nil).isPlayer)
        XCTAssertFalse(SpotifyEndpoint.devices.isPlayer)
        XCTAssertEqual(SpotifyEndpoint.devices.urlRequest(accessToken: "t").url?.absoluteString, "https://api.spotify.com/v1/me/player/devices")
    }
}

final class SpotifyFailureTests: XCTestCase {
    private func body(_ status: Int, _ message: String, reason: String? = nil) -> Data {
        let reasonField = reason.map { #","reason":"\#($0)""# } ?? ""
        return Data(#"{"error":{"status":\#(status),"message":"\#(message)"\#(reasonField)}}"#.utf8)
    }

    func testSuccessIsNotAFailure() {
        XCTAssertNil(SpotifyFailure.classify(status: 200, body: Data(), retryAfter: nil, player: false))
        XCTAssertNil(SpotifyFailure.classify(status: 204, body: Data(), retryAfter: nil, player: true))
    }

    func testUnauthorized() {
        XCTAssertEqual(SpotifyFailure.classify(status: 401, body: body(401, "The access token expired"), retryAfter: nil, player: false), .unauthorized)
    }

    func testPlayerFailures() {
        XCTAssertEqual(SpotifyFailure.classify(status: 403, body: body(403, "Player command failed: Premium required", reason: "PREMIUM_REQUIRED"), retryAfter: nil, player: true), .premiumRequired)
        XCTAssertEqual(SpotifyFailure.classify(status: 404, body: body(404, "Player command failed: No active device found", reason: "NO_ACTIVE_DEVICE"), retryAfter: nil, player: true), .noActiveDevice)
        XCTAssertEqual(SpotifyFailure.classify(status: 404, body: Data(), retryAfter: nil, player: true), .noActiveDevice)
        XCTAssertEqual(SpotifyFailure.classify(status: 403, body: body(403, "Restriction violated", reason: "UNKNOWN"), retryAfter: nil, player: true), .forbidden("Restriction violated"))
    }

    func testNonPlayerForbiddenAndNotFound() {
        XCTAssertEqual(SpotifyFailure.classify(status: 403, body: body(403, "Forbidden"), retryAfter: nil, player: false), .forbidden("Forbidden"))
        XCTAssertEqual(SpotifyFailure.classify(status: 404, body: body(404, "Not found."), retryAfter: nil, player: false), .notFound("Not found."))
    }

    func testRateLimitReadsRetryAfter() {
        XCTAssertEqual(SpotifyFailure.classify(status: 429, body: Data(), retryAfter: "7", player: false), .rateLimited(retryAfter: 7, quota: false))
        XCTAssertEqual(SpotifyFailure.classify(status: 429, body: Data(), retryAfter: nil, player: false), .rateLimited(retryAfter: 1, quota: false))
        XCTAssertEqual(SpotifyFailure.classify(status: 429, body: body(429, "Too many requests", reason: "QUOTA_EXCEEDED"), retryAfter: "x", player: false), .rateLimited(retryAfter: 1, quota: true))
    }

    func testServerErrorKeepsTheMessage() {
        XCTAssertEqual(SpotifyFailure.classify(status: 502, body: Data("<html>".utf8), retryAfter: nil, player: false), .server(status: 502, message: ""))
    }
}

final class SpotifySettingsTests: XCTestCase {
    func testClientIDDefaultsToEmptyAndRoundTrips() throws {
        XCTAssertEqual(try JSONDecoder().decode(WispSettings.self, from: Data(#"{"theme":"lime"}"#.utf8)).spotifyClientID, "")
        var settings = WispSettings.default
        settings.spotifyClientID = "0123abcd"
        XCTAssertEqual(try JSONDecoder().decode(WispSettings.self, from: JSONEncoder().encode(settings)).spotifyClientID, "0123abcd")
    }
}
