import Foundation
import Testing
@testable import CodexBarCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Coverage for the only file in the feature that knows HTTP exists: which
/// route each surface addresses, what the bodies say, and how every status the
/// gateway can answer becomes an error with a remedy attached.
struct NotifyGatewayClientTests {
    private static let host = URL(string: "https://gateway.test")!

    private static func link(_ deviceId: String = "ABC12345") -> NotifyDeviceLink {
        NotifyDeviceLink(deviceId: deviceId, token: "tok en/+")!
    }

    private static func tile() -> NotifyTile {
        NotifyTile(
            title: "CodexBar",
            body: "Codex 5h, 42% left",
            symbolName: NotifySymbol.quota,
            tintHex: "#34C759",
            progress: 42,
            trailing: "2h 14m",
            metrics: [NotifyMetric(label: "5h", value: "42", unit: "%", tintHex: "#34C759")!])!
    }

    private static func gauge() -> NotifyGauge {
        NotifyGauge(title: "CodexBar", value: "42", unit: "%", detail: "Codex 5h", progress: 42)!
    }

    /// Records the request it was handed and answers with a canned response.
    private final class Recorder: @unchecked Sendable {
        var requests: [URLRequest] = []

        func transport(status: Int, json: String) -> ProviderHTTPTransportHandler {
            ProviderHTTPTransportHandler { request in
                self.requests.append(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil)!
                return (Data(json.utf8), response)
            }
        }

        var body: [String: Any] {
            guard let data = self.requests.last?.httpBody,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return [:]
            }
            return object
        }
    }

    // MARK: - Endpoints

    @Test
    func `escapes a token that a query string would otherwise mangle`() throws {
        let url = try NotifyGatewayClient.endpoint(
            host: Self.host,
            path: "/live-activity/ABC12345",
            queryItems: [URLQueryItem(name: "token", value: "tok en/+")])
        #expect(url.absoluteString.contains("token=tok%20en/+"))
        #expect(url.path == "/live-activity/ABC12345")
    }

    @Test
    func `never doubles the separator when the host carries a trailing slash`() throws {
        let url = try NotifyGatewayClient.endpoint(
            host: #require(URL(string: "https://gateway.test/")),
            path: "/widgets/ABC12345",
            queryItems: [])
        #expect(url.path == "/widgets/ABC12345")
    }

    // MARK: - Live Activity

    @Test
    func `a start addresses the device and asks for a tile of its own`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: #"{"activityId":"LA123456"}"#),
            host: Self.host)

        let identifier = try await client.publishTile(Self.tile(), link: Self.link(), activityId: nil)

        #expect(identifier == "LA123456")
        #expect(recorder.requests.last?.url?.path == "/live-activity/ABC12345")
        #expect(recorder.body["new"] as? Bool == true)
    }

    @Test
    func `an update addresses the handle and never carries the new flag`() async throws {
        // `new` on an update would leave the device with two tiles.
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: #"{"activityId":"LA123456","pushed":true}"#),
            host: Self.host)

        let identifier = try await client.publishTile(Self.tile(), link: Self.link(), activityId: "LA123456")

        #expect(identifier == "LA123456")
        #expect(recorder.requests.last?.url?.path == "/live-activity/LA123456")
        #expect(recorder.body["new"] == nil)
    }

    @Test
    func `pushed false is a success because the content is stored`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: #"{"activityId":"LA123456","pushed":false}"#),
            host: Self.host)

        let identifier = try await client.publishTile(Self.tile(), link: Self.link(), activityId: "LA123456")
        #expect(identifier == "LA123456")
    }

    @Test
    func `refuses a tile for a mac before spending a request`() async {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: "{}"),
            host: Self.host)

        await #expect(throws: NotifyPublishError.self) {
            try await client.publishTile(Self.tile(), link: Self.link("MC12345678901234"), activityId: nil)
        }
        #expect(recorder.requests.isEmpty)
    }

    @Test
    func `ends a tile and treats an already gone tile as success`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 410, json: "{}"),
            host: Self.host)

        try await client.endTile(link: Self.link(), activityId: "LA123456", keepFor: 60)

        #expect(recorder.requests.last?.httpMethod == "DELETE")
        #expect(recorder.requests.last?.url?.query?.contains("keepFor=60") == true)
    }

    @Test
    func `clamps keepFor into the range the gateway accepts`() {
        #expect(NotifyGatewayClient.clampedKeepFor(-5) == 0)
        #expect(NotifyGatewayClient.clampedKeepFor(99999) == 14400)
        #expect(NotifyGatewayClient.clampedKeepFor(.nan) == 0)
        #expect(NotifyGatewayClient.clampedKeepFor(60) == 60)
    }

    // MARK: - Widgets

    @Test
    func `a widget create answers 201 and stores the handle`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 201, json: #"{"widgetId":"WG123456"}"#),
            host: Self.host)

        let identifier = try await client.publishGauge(Self.gauge(), link: Self.link(), widgetId: nil)

        #expect(identifier == "WG123456")
        #expect(recorder.requests.last?.url?.path == "/widgets/ABC12345")
        #expect(recorder.body["new"] as? Bool == true)
    }

    @Test
    func `a screen widget create uses the same body as a tile`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 201, json: #"{"screenWidgetId":"SW123456"}"#),
            host: Self.host)

        let identifier = try await client.publishScreenTile(Self.tile(), link: Self.link(), screenWidgetId: nil)

        #expect(identifier == "SW123456")
        #expect(recorder.requests.last?.url?.path == "/screenwidgets/ABC12345")
        #expect(recorder.body["metrics"] != nil)
    }

    @Test
    func `a screen widget kill switch reads as switched off rather than as a failure`() async {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 503, json: #"{"error":"unavailable"}"#),
            host: Self.host)

        await #expect(throws: NotifyPublishError.surfaceSwitchedOff("")) {
            try await client.publishScreenTile(Self.tile(), link: Self.link(), screenWidgetId: nil)
        }
    }

    @Test
    func `a screen widget 409 is not a live activity problem`() async {
        // The shared mapping reads 409 as a Live Activity problem because that is what it means on
        // the route it was written for. Sending somebody to open the Notify! app about their Live
        // Activities would be a wrong answer to a question about a Home Screen widget.
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 409, json: #"{"message":"several widgets"}"#),
            host: Self.host)

        await #expect(throws: NotifyPublishError.invalidPayload("several widgets")) {
            try await client.publishScreenTile(Self.tile(), link: Self.link(), screenWidgetId: nil)
        }
    }

    @Test
    func `refuses either widget for a group but not for a mac`() async {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 201, json: #"{"widgetId":"WG123456"}"#),
            host: Self.host)

        await #expect(throws: NotifyPublishError.self) {
            try await client.publishGauge(Self.gauge(), link: Self.link("GRP12345"), widgetId: nil)
        }
        #expect(recorder.requests.isEmpty)

        // A Mac cannot show a Live Activity but can perfectly well own a widget.
        let identifier = try? await client.publishGauge(
            Self.gauge(),
            link: Self.link("MC12345678901234"),
            widgetId: nil)
        #expect(identifier == "WG123456")
    }

    // MARK: - Bodies

    @Test
    func `every field CodexBar drives is stated on every write`() throws {
        // The gateway merges rather than replaces, so a field left unstated freezes its old value
        // instead of clearing it. A gauge that became a credit balance would otherwise keep the
        // previous ring on screen forever.
        let bare = try #require(NotifyTile(title: "CodexBar"))
        let body = NotifyGatewayClient.tileBody(bare)

        #expect(body["title"] as? String == "CodexBar")
        for key in ["body", "symbol", "tint", "progress", "trailing", "metrics"] {
            #expect(body[key] is NSNull, "\(key) must be an explicit null")
        }
    }

    @Test
    func `never mentions a field CodexBar does not drive`() {
        // Staying silent is what lets a CodexBar update share a tile with whatever else the user
        // configured, because the gateway leaves an absent field alone.
        let body = NotifyGatewayClient.tileBody(Self.tile())
        for key in ["status", "endsIn", "steps", "step", "button", "new"] {
            #expect(body[key] == nil, "\(key) must not be sent")
        }
    }

    @Test
    func `a gauge title is a value and never a null`() throws {
        // The gateway treats a widget title as its identity and refuses to clear it.
        let body = try NotifyGatewayClient.gaugeBody(#require(NotifyGauge(title: "CodexBar")))
        #expect(body["title"] as? String == "CodexBar")
        for key in ["value", "unit", "detail", "symbol", "tint", "progress"] {
            #expect(body[key] is NSNull, "\(key) must be an explicit null")
        }
    }

    @Test
    func `a metric carries its unit and color only when it has them`() throws {
        let plain = try #require(NotifyMetric(label: "5h", value: "42"))
        let tile = try #require(NotifyTile(title: "CodexBar", metrics: [plain]))
        let metrics = NotifyGatewayClient.tileBody(tile)["metrics"] as? [[String: Any]]
        #expect(metrics?.first?["label"] as? String == "5h")
        #expect(metrics?.first?["unit"] == nil)
        #expect(metrics?.first?["color"] == nil)
    }

    @Test
    func `a notification body nulls nothing because there is no stored state to freeze`() throws {
        let notification = try #require(NotifyNotification(text: "42% left", title: "Codex"))
        let body = NotifyGatewayClient.notificationBody(notification)
        #expect(body["text"] as? String == "42% left")
        #expect(body["title"] as? String == "Codex")
        #expect(body["groupType"] == nil)
        #expect(body["timeSensitive"] == nil)
    }

    @Test
    func `a time sensitive notification says so`() throws {
        let notification = try #require(NotifyNotification(
            text: "Out of quota",
            title: "Codex",
            groupType: "codexbar-codex",
            timeSensitive: true))
        let body = NotifyGatewayClient.notificationBody(notification)
        #expect(body["timeSensitive"] as? Bool == true)
        #expect(body["groupType"] as? String == "codexbar-codex")
    }

    // MARK: - Notification route

    @Test
    func `a notification posts json to the device route`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: #"{"success":true,"type":"device"}"#),
            host: Self.host)

        try await client.sendNotification(
            #require(NotifyNotification(text: "42% left", title: "Codex")),
            link: Self.link())

        #expect(recorder.requests.last?.url?.path == "/notify-json/ABC12345")
        #expect(recorder.requests.last?.value(forHTTPHeaderField: "Content-Type") == "application/json")
    }

    @Test
    func `an empty group reads as something the user can act on`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 404, json: "{}"),
            host: Self.host)

        await #expect(throws: NotifyPublishError.self) {
            try await client.sendNotification(
                #require(NotifyNotification(text: "42% left", title: "Codex")),
                link: Self.link("GRP12345"))
        }
    }

    // MARK: - Link check

    @Test
    func `a link check describes the device and refuses the cache`() async throws {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(
                status: 200,
                json: #"{"type":"device","id":"ABC12345","name":"Apollo","platform":"iOS"}"#),
            host: Self.host)

        let info = try await client.deviceInfo(link: Self.link())

        #expect(info.displayDescription == "Apollo (iOS)")
        #expect(recorder.requests.last?.httpMethod == "GET")
        // The only GET in the feature, and its URL carries the device token, so a cacheable answer
        // would write the secret to a file in ~/Library/Caches.
        #expect(recorder.requests.last?.cachePolicy == .reloadIgnoringLocalAndRemoteCacheData)
    }

    @Test
    func `a link check rejects a group before it can fail later with a puzzling 400`() async {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: #"{"type":"group","id":"GRP12345"}"#),
            host: Self.host)

        await #expect(throws: NotifyPublishError.self) {
            _ = try await client.deviceInfo(link: Self.link())
        }
    }

    @Test
    func `a link check 404 reads as rejected credentials`() async {
        // This route answers 404 rather than 403, and gives that same answer for a wrong token and
        // for an id that does not exist, so it cannot be used to enumerate ids.
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 404, json: "{}"),
            host: Self.host)

        await #expect(throws: NotifyPublishError.rejectedCredentials) {
            _ = try await client.deviceInfo(link: Self.link())
        }
    }

    // MARK: - Error mapping

    @Test
    func `maps each status to the remedy it implies`() {
        func mapped(_ status: Int, _ json: String = "{}", retryAfter: String? = nil) -> NotifyPublishError {
            NotifyGatewayClient.failure(status: status, data: Data(json.utf8), retryAfterHeader: retryAfter)
        }

        #expect(mapped(400, #"{"message":"bad title"}"#) == .invalidPayload("bad title"))
        #expect(mapped(403) == .rejectedCredentials)
        #expect(mapped(409, #"{"message":"open the app"}"#) == .liveActivityUnavailable("open the app"))
        #expect(mapped(410) == .tileGone)
        #expect(mapped(415) == .invalidPayload("CodexBar sent this update in the wrong format."))
        #expect(mapped(418) == .unexpectedStatus(418))
    }

    @Test
    func `keeps the activity id when Apple never answered a start`() {
        // A tile may exist, so starting again could leave two.
        let json = #"{"deliveryState":"unknown","activityId":"LA123456"}"#
        let error = NotifyGatewayClient.failure(status: 502, data: Data(json.utf8), retryAfterHeader: nil)
        #expect(error == .deliveryUnconfirmed(activityId: "LA123456"))
    }

    @Test
    func `treats a refused start as a wait rather than something to retry`() {
        let json = #"{"deliveryState":"not-delivered","retryAfterSeconds":120}"#
        let error = NotifyGatewayClient.failure(status: 502, data: Data(json.utf8), retryAfterHeader: nil)
        #expect(error == .backoff(retryAfter: 120, openingTheAppMayHelp: false))
    }

    @Test
    func `an unexplained 502 stays an unexpected status`() {
        let error = NotifyGatewayClient.failure(status: 502, data: Data("{}".utf8), retryAfterHeader: nil)
        #expect(error == .unexpectedStatus(502))
    }

    @Test
    func `prefers the gateway's own wait over the header and then over the ladder`() {
        #expect(NotifyGatewayClient.retryAfter(bodySeconds: 90, header: "30") == 90)
        #expect(NotifyGatewayClient.retryAfter(bodySeconds: nil, header: "30") == 30)
        #expect(NotifyGatewayClient.retryAfter(bodySeconds: nil, header: nil) == 1800)
        // The HTTP date form needs a clock CodexBar cannot trust to agree with the server's.
        #expect(NotifyGatewayClient.retryAfter(bodySeconds: nil, header: "Wed, 21 Oct 2026 07:28:00 GMT") == 1800)
        #expect(NotifyGatewayClient.retryAfter(bodySeconds: -5, header: nil) == 1800)
    }

    @Test
    func `says which failures are worth retrying`() {
        #expect(NotifyPublishError.transportFailed("offline").isRetryable)
        #expect(NotifyPublishError.surfaceSwitchedOff("").isRetryable)
        #expect(NotifyPublishError.backoff(retryAfter: 60, openingTheAppMayHelp: false).isRetryable)
        #expect(NotifyPublishError.rejectedCredentials.isRetryable == false)
        #expect(NotifyPublishError.tileGone.isRetryable == false)
        #expect(NotifyPublishError.notLinked.isRetryable == false)
    }

    @Test
    func `a transport failure never reaches the caller as a URLError`() async {
        let client = NotifyGatewayClient(
            transport: ProviderHTTPTransportHandler { _ in throw URLError(.notConnectedToInternet) },
            host: Self.host)

        await #expect(throws: NotifyPublishError.self) {
            try await client.publishTile(Self.tile(), link: Self.link(), activityId: nil)
        }
    }

    @Test
    func `a body it cannot read is a malformed response rather than a crash`() async {
        let recorder = Recorder()
        let client = NotifyGatewayClient(
            transport: recorder.transport(status: 200, json: "not json at all"),
            host: Self.host)

        await #expect(throws: NotifyPublishError.malformedResponse) {
            try await client.publishTile(Self.tile(), link: Self.link(), activityId: nil)
        }
    }
}
