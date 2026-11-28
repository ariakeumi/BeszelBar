import XCTest

final class RealtimeProtocolTests: XCTestCase {
    func testRealtimeStatsIncludeMemoryAndDiskCapacities() throws {
        let metrics: RealtimeMetrics = try fixture(#"{"info":{"mp":25,"dp":50},"stats":{"m":16,"mu":4,"d":100,"du":50,"b":[1024,2048]}}"#)
        XCTAssertEqual(metrics.stats?.memoryCapacityDisplay, "4 / 16 GiB")
        XCTAssertEqual(metrics.stats?.diskCapacityDisplay, "50 / 100 GiB")
        XCTAssertEqual(metrics.stats?.networkTraffic.compactDisplay, "1K | 2K")
    }

    func testLoadAverageSupportsCurrentAndLegacyPayloads() throws {
        let saved: SystemRecord = try fixture(#"{"id":"server","name":"Server","status":"up","info":{"l1":2,"l5":1.5,"l15":1}}"#)
        XCTAssertEqual(saved.info?.loadAverage, [2, 1.5, 1])

        let live: RealtimeMetrics = try fixture(#"{"info":{"la":[0,0.5,1]},"stats":{"la":[0,0.5,1]}}"#)
        XCTAssertEqual(live.stats?.loadAverage, [0, 0.5, 1])
        let updated = RealtimeSystemUpdate(systemID: "server", metrics: live).applying(to: saved)
        XCTAssertEqual(updated.info?.loadAverage, [0, 0.5, 1])

        let partial: RealtimeMetrics = try fixture(#"{"info":{"la":[0.25]},"stats":{"la":[0.25],"l1":1,"l5":2,"l15":3}}"#)
        XCTAssertEqual(partial.stats?.loadAverage, [1, 2, 3])
        let unchanged = RealtimeSystemUpdate(systemID: "server", metrics: partial).applying(to: updated)
        XCTAssertEqual(unchanged.info?.loadAverage, [0, 0.5, 1])
    }

    func testParserHandlesFragmentedUTF8CommentsMultilineAndLineEndings() throws {
        var parser = ServerSentEventParser()
        let text = "\u{FEFF}: keepalive\r\n\r\nid: 1\revent: metrics\rdata: {\"name\":\"主机\",\rdata: \"cpu\":12}\r\rdata: next\n\n"
        let events = try text.utf8.compactMap { try parser.append($0) }
        XCTAssertEqual(events.map(\.name), ["metrics", "message"])
        XCTAssertEqual(String(decoding: events[0].data, as: UTF8.self), "{\"name\":\"主机\",\n\"cpu\":12}")
        XCTAssertEqual(String(decoding: events[1].data, as: UTF8.self), "next")
    }

    func testParserBoundsUnterminatedFramesAndDoesNotDispatchPartialData() throws {
        var parser = ServerSentEventParser(maximumEventBytes: 12)
        XCTAssertTrue(try "data: abc\n".utf8.compactMap { try parser.append($0) }.isEmpty)
        XCTAssertThrowsError(try "data: more".utf8.forEach { _ = try parser.append($0) })
    }

    func testTopicMatchesPocketBaseJavaScript() throws {
        XCTAssertEqual(try BeszelRealtimeConnection.topic(for: "server1"),
                       "rt_metrics?options=%7B%22query%22%3A%7B%22system%22%3A%22server1%22%7D%7D")
    }

    func testLiveUpdatesOnlyChangeMenuMetricsAndPreserveMissingValues() throws {
        let original: SystemRecord = try fixture(#"{"id":"same-system","name":"Server","status":"up","info":{"cpu":1,"mp":2,"dp":3,"bb":4,"dt":5,"u":100,"v":"0.21.2","g":50}}"#)
        let update = RealtimeSystemUpdate(systemID: "same-system", metrics: try fixture(
            #"{"info":{"cpu":80,"mp":60,"dp":40,"bb":1024,"dt":70,"u":999,"g":90},"container":[{"n":"web","c":9}]}"#))
        let changed = update.applying(to: original)
        XCTAssertEqual(changed.info?.cpu, 80)
        XCTAssertEqual(changed.info?.mp, 60)
        XCTAssertEqual(changed.info?.dp, 40)
        XCTAssertEqual(changed.info?.bb, 1024)
        XCTAssertEqual(changed.info?.dt, 70)
        XCTAssertEqual(changed.info?.u, 100)
        XCTAssertEqual(changed.info?.g, 50)
        XCTAssertEqual(changed.info?.v, "0.21.2")
        let partial = RealtimeSystemUpdate(systemID: "same-system", metrics: try fixture(#"{"info":{"cpu":0}}"#))
        XCTAssertEqual(partial.applying(to: changed).info?.mp, 60)
    }

    func testDirectionalTrafficPrefersByteRatesAndPreservesUploadDownloadOrder() throws {
        let original: SystemRecord = try fixture(#"{"id":"server","name":"Server","status":"up"}"#)
        let metrics: RealtimeMetrics = try fixture(#"{"info":{"bb":202752},"stats":{"b":[24576,178176],"ns":9,"nr":8}}"#)
        let changed = RealtimeSystemUpdate(systemID: "server", metrics: metrics).applying(to: original)
        let traffic = try XCTUnwrap(changed.networkTraffic)
        XCTAssertEqual(traffic.upload, 24 * 1024)
        XCTAssertEqual(traffic.download, 174 * 1024)
        XCTAssertEqual(traffic.compactDisplay, "24K | 174K")

        let partial: RealtimeMetrics = try fixture(#"{"info":{"cpu":12}}"#)
        XCTAssertEqual(RealtimeSystemUpdate(systemID: "server", metrics: partial).applying(to: changed).networkTraffic, traffic)
        // Live-only rates must not leak into the systems collection schema.
        let encoded = try JSONEncoder().encode(changed)
        XCTAssertNil(try JSONDecoder().decode(SystemRecord.self, from: encoded).networkTraffic)
    }

    func testLegacyTrafficConvertsMegabytesAndOmittedIdleRatesResetToZero() throws {
        let legacy: RealtimeMetrics = try fixture(#"{"info":{},"stats":{"ns":0.0234375,"nr":0.169921875}}"#)
        XCTAssertEqual(legacy.stats?.networkTraffic.compactDisplay, "24K | 174K")
        let downloadOnly: RealtimeMetrics = try fixture(#"{"info":{},"stats":{"nr":1.5}}"#)
        XCTAssertEqual(downloadOnly.stats?.networkTraffic.compactDisplay, "0K | 1.5M")
        let idle: RealtimeMetrics = try fixture(#"{"info":{},"stats":{"cpu":10}}"#)
        XCTAssertEqual(idle.stats?.networkTraffic.compactDisplay, "0K | 0K")
        let shortArray: RealtimeMetrics = try fixture(#"{"info":{},"stats":{"b":[1],"ns":2}}"#)
        XCTAssertEqual(shortArray.stats?.networkTraffic.compactDisplay, "2.0M | 0K")
    }

    func testTrafficFormattingScalesAndHandlesInvalidValues() {
        XCTAssertEqual(SystemNetworkTraffic(upload: 0, download: 512).compactDisplay, "0K | 512B")
        XCTAssertEqual(SystemNetworkTraffic(upload: 1024, download: 1_048_576).compactDisplay, "1K | 1.0M")
        XCTAssertEqual(SystemNetworkTraffic(upload: 1_073_741_824, download: 1_099_511_627_776).compactDisplay, "1.0G | 1.0T")
        XCTAssertEqual(SystemNetworkTraffic(upload: -.infinity, download: .nan).compactDisplay, "0K | 0K")
        XCTAssertEqual(SystemNetworkTraffic(upload: -1024, download: .infinity).compactDisplay, "0K | 0K")
    }
}

@MainActor
final class RealtimeStateTests: XCTestCase {
    func testHubIsolationPollingThrottleAndProtectionFromOlderCollectionValues() async throws {
        let a = realtimeHub("A"), b = realtimeHub("B")
        let first = RealtimeTestService(), second = RealtimeTestService()
        let (state, defaults) = makeState([a, b]) { $0.id == a.id ? first : second }
        defer { state.stopRefreshing(); defaults.removePersistentDomain(forName: defaultsSuite) }
        state.refresh()
        await state.waitForRefresh()
        state.setRealtimeEnabled(true)
        await eventually {
            let firstCount = await first.streamCount
            let secondCount = await second.streamCount
            return firstCount == 1 && secondCount == 1
        }
        try await first.emit(cpu: 80, containerCPU: 9, upload: 24 * 1024, download: 174 * 1024)
        try await second.emit(cpu: 20, containerCPU: 3, upload: 5 * 1024, download: 6 * 1024)
        await eventually { state.hubSnapshots[a.id]?.systems.first?.cpuPercentage == 80 && state.hubSnapshots[b.id]?.systems.first?.cpuPercentage == 20 }
        state.refresh()
        await state.waitForRefresh()
        XCTAssertEqual(state.hubSnapshots[a.id]?.systems.first?.cpuPercentage, 80)
        XCTAssertEqual(state.hubSnapshots[b.id]?.systems.first?.cpuPercentage, 20)
        XCTAssertEqual(state.hubSnapshots[a.id]?.systems.first?.networkTraffic?.compactDisplay, "24K | 174K")
        XCTAssertEqual(state.hubSnapshots[b.id]?.systems.first?.networkTraffic?.compactDisplay, "5K | 6K")
        XCTAssertEqual(state.hubSnapshots[a.id]?.containers.first?.cpu, 0)
        XCTAssertEqual(state.hubSnapshots[b.id]?.containers.first?.cpu, 0)
        let calls = await first.calls
        state.poll(now: Date().addingTimeInterval(2))
        await state.waitForRefresh()
        let after = await first.calls
        XCTAssertEqual(calls, after, "Healthy streams should not poll every collection each second")
        defaults.set(10, forKey: "refreshInterval")
        state.poll(now: Date().addingTimeInterval(11))
        await state.waitForRefresh()
        let metadata = await first.calls
        XCTAssertEqual(metadata["details"], (calls["details"] ?? 0) + 1)
        XCTAssertEqual(metadata["alerts"], (calls["alerts"] ?? 0) + 1)
    }

    func testClosingCancelsStreamAndReopeningStartsNewSession() async throws {
        let service = RealtimeTestService()
        let (state, defaults) = makeState([realtimeHub("A")]) { _ in service }
        defer { state.stopRefreshing(); defaults.removePersistentDomain(forName: defaultsSuite) }
        state.refresh()
        await state.waitForRefresh()
        state.setRealtimeEnabled(true)
        await eventually { await service.streamCount == 1 }
        try await service.emit(cpu: 70)
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 70 }
        state.setRealtimeEnabled(false)
        await eventually { await service.terminated == 1 }
        try await service.emit(cpu: 99, stream: 0)
        await Task.yield()
        XCTAssertEqual(state.visibleSystems.first?.system.cpuPercentage, 70)
        state.setRealtimeEnabled(true)
        await eventually { await service.streamCount == 2 }
        try await service.emit(cpu: 85)
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 85 }
    }

    func testSwitchingEditingAndRemovingHubCancelTheirSubscriptions() async throws {
        let a = realtimeHub("A"), b = realtimeHub("B")
        let first = RealtimeTestService(), second = RealtimeTestService(), replacement = RealtimeTestService()
        let (state, defaults) = makeState([a, b], all: false) {
            if $0.url.contains("replacement") { return replacement }
            return $0.id == a.id ? first : second
        }
        defer { state.stopRefreshing(); defaults.removePersistentDomain(forName: defaultsSuite) }
        state.refresh()
        await state.waitForRefresh()
        state.setRealtimeEnabled(true)
        await eventually { await first.streamCount == 1 }
        state.selectInstance(b)
        await state.waitForRefresh()
        await eventually {
            let stopped = await first.terminated
            let count = await second.streamCount
            return stopped == 1 && count == 1
        }
        try await first.emit(cpu: 99)
        try await second.emit(cpu: 22)
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 22 }
        var edited = b
        edited.url = "https://replacement.example"
        state.updateInstance(edited)
        await state.waitForRefresh()
        await eventually {
            let stopped = await second.terminated
            let count = await replacement.streamCount
            return stopped == 1 && count == 1
        }
        try await replacement.emit(cpu: 44)
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 44 }
        state.removeInstance(edited)
        await state.waitForRefresh()
        await eventually { await replacement.terminated == 1 }
        try await replacement.emit(cpu: 100)
        await Task.yield()
        XCTAssertNil(state.hubSnapshots[b.id])
    }

    func testStaleMetricsFallBackToPollingAndDisconnectedStreamReconnects() async throws {
        let service = RealtimeTestService()
        let (state, defaults) = makeState([realtimeHub("A")]) { _ in service }
        defer { state.stopRefreshing(); defaults.removePersistentDomain(forName: defaultsSuite) }
        state.refresh()
        await state.waitForRefresh()
        state.setRealtimeEnabled(true)
        await eventually { await service.streamCount == 1 }
        try await service.emit(cpu: 80, date: Date().addingTimeInterval(-10))
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 80 }
        state.poll(now: Date().addingTimeInterval(2))
        await state.waitForRefresh()
        XCTAssertEqual(state.visibleSystems.first?.system.cpuPercentage, 0)
        let calls = await service.calls
        XCTAssertEqual(calls["systems"], 2)
        XCTAssertEqual(calls["containers"], 1)
        XCTAssertEqual(calls["details"], 1)
        XCTAssertEqual(calls["alerts"], 1)
        await service.disconnect()
        await eventually(timeout: 3) { await service.streamCount == 2 }
        try await service.emit(cpu: 91)
        await eventually { state.visibleSystems.first?.system.cpuPercentage == 91 }
    }

    private var defaultsSuite = ""

    private func makeState(_ hubs: [Instance], all: Bool = true,
                           factory: @escaping (Instance) -> any BeszelServing) -> (AppState, UserDefaults) {
        defaultsSuite = "BeszelBarTests.Realtime.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsSuite)!
        let storage = StorageManager(defaults: defaults)
        storage.saveInstances(hubs)
        storage.saveShowsAllHubs(all)
        return (AppState(storage: storage, credentials: RealtimeTestCredentials(), serviceFactory: factory), defaults)
    }

    private func eventually(timeout: TimeInterval = 1, _ condition: () async -> Bool,
                            file: StaticString = #filePath, line: UInt = #line) async {
        let until = Date().addingTimeInterval(timeout)
        while Date() < until {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        let result = await condition()
        XCTAssertTrue(result, "Expected realtime state transition", file: file, line: line)
    }
}

private actor RealtimeTestService: BeszelServing {
    private var streams: [AsyncThrowingStream<RealtimeSystemUpdate, Error>.Continuation] = []
    private(set) var terminated = 0
    private(set) var calls: [String: Int] = [:]
    var streamCount: Int { streams.count }

    func realtimeUpdates(systemIDs: [String]) -> AsyncThrowingStream<RealtimeSystemUpdate, Error>? {
        let (stream, continuation) = AsyncThrowingStream<RealtimeSystemUpdate, Error>.makeStream()
        continuation.onTermination = { [weak self] _ in Task { await self?.didTerminate() } }
        streams.append(continuation)
        return stream
    }

    private func didTerminate() { terminated += 1 }

    func emit(cpu: Double, containerCPU: Double = 0, upload: Double = 0, download: Double = 0,
              date: Date = Date(), stream: Int? = nil) throws {
        let metrics: RealtimeMetrics = try fixture(#"{"info":{"cpu":\#(cpu),"mp":40},"stats":{"b":[\#(upload),\#(download)]},"container":[{"n":"web","c":\#(containerCPU),"m":256,"b":[100,200]}]}"#)
        streams[stream ?? streams.count - 1].yield(RealtimeSystemUpdate(systemID: "same-system", metrics: metrics, receivedAt: date))
    }

    func disconnect() { streams.last?.finish(throwing: URLError(.networkConnectionLost)) }
    func fetchSystems() throws -> [SystemRecord] {
        calls["systems", default: 0] += 1
        return [try fixture(#"{"id":"same-system","name":"Server","status":"up","info":{"cpu":0}}"#)]
    }
    func fetchSystemDetails() -> [SystemDetailsRecord] { calls["details", default: 0] += 1; return [] }
    func fetchContainers(filter: String?) throws -> [ContainerRecord] {
        calls["containers", default: 0] += 1
        return [try realtimeContainer(system: "same-system")]
    }
    func fetchAlerts(filter: String?) -> [AlertRecord] { calls["alerts", default: 0] += 1; return [] }
    func fetchHistory(systemID: String, range: HistoryRange, now: Date) -> [SystemStatsRecord] { [] }
}

private final class RealtimeTestCredentials: CredentialStore {
    func saveCredential(_ credential: String, for account: String) -> Bool { true }
    func loadCredential(for account: String) -> String? { nil }
    func deleteCredential(for account: String) -> Bool { true }
}

private func realtimeHub(_ name: String) -> Instance {
    Instance(name: name, url: "https://\(name.lowercased()).example", email: "", credential: "")
}

private func realtimeContainer(system: String) throws -> ContainerRecord {
    try fixture(#"{"id":"same-container","name":"web","cpu":0,"memory":32,"net":0,"health":2,"status":"running","image":"nginx","system":"\#(system)","updated":0}"#)
}

final class RealtimeTransportTests: XCTestCase {
    func testAuthenticatedStreamUsesSubpathAndClosesWhenConsumerCancels() async throws {
        let fixture = RealtimeHTTPFixture()
        let (service, session) = makeService(fixture: fixture)
        defer { session.invalidateAndCancel(); RealtimeURLProtocol.fixture = nil }
        let optionalStream = try await service.realtimeUpdates(systemIDs: ["same-system"])
        let stream = try XCTUnwrap(optionalStream)
        let update = await consumeOneThenCancel(stream)
        XCTAssertEqual(update?.systemID, "same-system")
        XCTAssertEqual(update?.metrics.info.cpu, 81)
        await fulfillment(of: [fixture.closed], timeout: 2)
        let requests = fixture.requests
        XCTAssertTrue(requests.allSatisfy { $0.url!.path.hasPrefix("/beszel/api/") })
        let subscription = try XCTUnwrap(requests.first { $0.httpMethod == "POST" && $0.url?.path.hasSuffix("/realtime") == true })
        XCTAssertEqual(subscription.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        let body = try XCTUnwrap(fixture.subscriptionBodies.first)
        XCTAssertEqual(body["clientId"] as? String, "test-client")
        XCTAssertEqual(body["subscriptions"] as? [String], [try BeszelRealtimeConnection.topic(for: "same-system")])
    }

    func testUnauthorizedSubscriptionRefreshesAuthenticationOnReconnect() async throws {
        let fixture = RealtimeHTTPFixture(failFirstSubscription: true)
        let (service, session) = makeService(fixture: fixture)
        defer { session.invalidateAndCancel(); RealtimeURLProtocol.fixture = nil }
        let optionalFirst = try await service.realtimeUpdates(systemIDs: ["same-system"])
        let first = try XCTUnwrap(optionalFirst)
        do {
            for try await _ in first { XCTFail("Unauthorized stream must not yield metrics") }
            XCTFail("Expected an authentication error")
        } catch BeszelAPIError.httpError(let status, _) {
            XCTAssertEqual(status, 401)
        }
        let optionalSecond = try await service.realtimeUpdates(systemIDs: ["same-system"])
        let second = try XCTUnwrap(optionalSecond)
        let update = await consumeOneThenCancel(second)
        XCTAssertNotNil(update)
        let authentication = fixture.requests.filter { $0.url?.path.hasSuffix("auth-with-password") == true }
        XCTAssertEqual(authentication.count, 2)
        let subscriptions = fixture.requests.filter { $0.url?.path.hasSuffix("/realtime") == true && $0.httpMethod == "POST" }
        XCTAssertEqual(subscriptions.map { $0.value(forHTTPHeaderField: "Authorization") }, ["Bearer token-1", "Bearer token-2"])
    }

    func testFallbackPinsBothStreamAndSubscriptionToReachableEndpoint() async throws {
        let fixture = RealtimeHTTPFixture(failedHost: "lan.example")
        let (service, session) = makeService(fixture: fixture, fallback: true)
        defer { session.invalidateAndCancel(); RealtimeURLProtocol.fixture = nil }
        let optionalStream = try await service.realtimeUpdates(systemIDs: ["same-system"])
        let stream = try XCTUnwrap(optionalStream)
        let update = await consumeOneThenCancel(stream)
        XCTAssertNotNil(update)
        let realtime = fixture.requests.filter { $0.url?.path.hasSuffix("/realtime") == true }
        XCTAssertEqual(realtime.count, 2)
        XCTAssertTrue(realtime.allSatisfy { $0.url?.absoluteString == "https://remote.example/monitoring/api/realtime" })
    }

    private func makeService(fixture: RealtimeHTTPFixture, fallback: Bool = false) -> (BeszelAPIService, URLSession) {
        RealtimeURLProtocol.fixture = fixture
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RealtimeURLProtocol.self]
        let session = URLSession(configuration: config)
        let hub = Instance(name: "Hub", url: fallback ? "http://lan.example/beszel" : "https://hub.example/beszel",
                           email: "test@example.com", credential: "password",
                           fallbackURL: fallback ? "https://remote.example/monitoring" : "")
        return (BeszelAPIService(instance: hub, session: session), session)
    }

    private func consumeOneThenCancel(_ stream: AsyncThrowingStream<RealtimeSystemUpdate, Error>) async -> RealtimeSystemUpdate? {
        let received = expectation(description: "Received a realtime metric")
        let task = Task {
            var first: RealtimeSystemUpdate?
            do {
                for try await update in stream where first == nil {
                    first = update
                    received.fulfill()
                }
            } catch {}
            return first
        }
        await fulfillment(of: [received], timeout: 2)
        task.cancel()
        return await task.value
    }
}

private final class RealtimeHTTPFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var bodies: [[String: Any]] = []
    private var stream: RealtimeURLProtocol?
    private var tokenNumber = 0
    private var closedOnce = false
    private let failFirstSubscription: Bool
    private let failedHost: String?
    let closed = XCTestExpectation(description: "SSE request cancelled")
    var requests: [URLRequest] { lock.withLock { recorded } }
    var subscriptionBodies: [[String: Any]] { lock.withLock { bodies } }

    init(failFirstSubscription: Bool = false, failedHost: String? = nil) {
        self.failFirstSubscription = failFirstSubscription
        self.failedHost = failedHost
    }

    func start(_ source: RealtimeURLProtocol) {
        let request = source.request
        lock.withLock { recorded.append(request) }
        if request.url?.host == failedHost {
            source.client?.urlProtocol(source, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let path = request.url!.path
        if path.hasSuffix("auth-with-password") {
            let number = lock.withLock { tokenNumber += 1; return tokenNumber }
            source.respond(status: 200, body: "{\"token\":\"token-\(number)\"}")
        } else if path.hasSuffix("/health") {
            source.respond(status: 200, body: "{}")
        } else if request.httpMethod == "POST" {
            let body = (try? JSONSerialization.jsonObject(with: source.requestBody())) as? [String: Any] ?? [:]
            let shouldFail = lock.withLock {
                bodies.append(body)
                return failFirstSubscription && bodies.count == 1
            }
            source.respond(status: shouldFail ? 401 : 204, body: "")
            if !shouldFail, let topics = body["subscriptions"] as? [String] {
                let target = lock.withLock { stream }
                let bytes = Data("event: \(topics[0])\ndata: {\"info\":{\"cpu\":81,\"mp\":40,\"dp\":50,\"bb\":1024,\"dt\":60}}\n\n".utf8)
                target?.send(Data(bytes.prefix(11)))
                target?.send(Data(bytes.dropFirst(11)))
            }
        } else {
            source.isStream = true
            lock.withLock { stream = source }
            source.respond(status: 200, body: "event: PB_CONNECT\ndata: {\"clientId\":\"test-client\"}\n\n", streaming: true)
        }
    }

    func stopped(_ source: RealtimeURLProtocol) {
        let notify = lock.withLock {
            guard source.isStream, !closedOnce else { return false }
            closedOnce = true
            if stream === source { stream = nil }
            return true
        }
        if notify { closed.fulfill() }
    }
}

private final class RealtimeURLProtocol: URLProtocol, @unchecked Sendable {
    static var fixture: RealtimeHTTPFixture?
    var isStream = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.fixture?.start(self) }
    override func stopLoading() { Self.fixture?.stopped(self) }

    func respond(status: Int, body: String, streaming: Bool = false) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": streaming ? "text/event-stream" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { send(Data(body.utf8)) }
        if !streaming { client?.urlProtocolDidFinishLoading(self) }
    }

    func send(_ data: Data) { client?.urlProtocol(self, didLoad: data) }

    func requestBody() -> Data {
        if let body = request.httpBody { return body }
        guard let input = request.httpBodyStream else { return Data() }
        input.open()
        defer { input.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while input.hasBytesAvailable {
            let count = input.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}
