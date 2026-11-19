import XCTest

final class HistoryTests: XCTestCase {
    func testCapacityDisplaysUsedAndTotalWithMatchingUnits() throws {
        let stats: SystemStatsDetail = try fixture(#"{"m":16,"mu":4,"d":2048,"du":1024}"#)
        XCTAssertEqual(stats.memoryCapacityDisplay, "4 / 16 GiB")
        XCTAssertEqual(stats.diskCapacityDisplay, "1 / 2 TiB")

        let small: SystemStatsDetail = try fixture(#"{"m":0.5,"mu":0,"d":16,"du":0}"#)
        XCTAssertEqual(small.memoryCapacityDisplay, "0 / 512 MiB")
        XCTAssertEqual(small.diskCapacityDisplay, "0 / 16 GiB")
    }

    func testCapacitySupportsByteMemoryAndDoesNotInventMissingValues() throws {
        let stats: SystemStatsDetail = try fixture(#"{"mem":[8589934592,2147483648,0,0],"m":16,"mu":4}"#)
        XCTAssertEqual(stats.memoryCapacityDisplay, "2 / 8 GiB")
        XCTAssertNil(stats.diskCapacityDisplay)
        for payload in [#"{}"#, #"{"m":0,"mu":0,"d":0,"du":0}"#,
                        #"{"m":8,"d":16}"#, #"{"m":8,"mu":-1,"d":16,"du":-1}"#] {
            let missing: SystemStatsDetail = try fixture(payload)
            XCTAssertNil(missing.memoryCapacityDisplay)
            XCTAssertNil(missing.diskCapacityDisplay)
        }
    }

    func testHistoryPreservesZeroAndSeparatesMissingDataAndOutages() throws {
        let records: [SystemStatsRecord] = try fixture(#"""
        [
          {"id":"1","created":"2026-09-15 12:00:00.000Z","stats":{"cpu":0}},
          {"id":"2","created":"2026-09-15T12:01:00Z","stats":{"cpu":25}},
          {"id":"3","created":"2026-09-15 12:02:00.000Z","stats":{}},
          {"id":"4","created":"2026-09-15 12:03:00.000Z","stats":{"cpu":30}},
          {"id":"5","created":"2026-09-15 12:10:00.000Z","stats":{"cpu":40}}
        ]
        """#)
        let points = HistorySeries.points(from: records, metric: .cpu, range: .hour)
        XCTAssertEqual(points.map(\.value), [0, 25, 30, 40])
        XCTAssertEqual(points.map(\.segment), [0, 0, 1, 2])
    }

    func testBandwidthSupportsLegacyMegabytesAndNewByteArrays() throws {
        let current: SystemStatsDetail = try fixture(#"{"b":[1048576,2097152]}"#)
        let legacy: SystemStatsDetail = try fixture(#"{"ns":1,"nr":2}"#)
        XCTAssertEqual(HistoryMetric.upload.value(in: current), 1)
        XCTAssertEqual(HistoryMetric.download.value(in: current), 2)
        XCTAssertEqual(HistoryMetric.upload.value(in: legacy), 1)
        XCTAssertEqual(HistoryMetric.download.value(in: legacy), 2)
    }

    func testPartialRefreshRetainsDockerHistoryAndReportsFailure() async throws {
        let now = Date()
        let service = ChartHistoryService()
        let initial = try await ChartDataLoader.load(service: service, systemID: "server", range: .hour, now: now)
        XCTAssertFalse(initial.containers.isEmpty)

        await service.setContainerResponse(fails: true)
        let refreshed = try await ChartDataLoader.load(service: service, systemID: "server", range: .hour,
            now: now.addingTimeInterval(60), previous: initial)
        XCTAssertEqual(refreshed.containerRecords.map(\.id), initial.containerRecords.map(\.id))
        XCTAssertEqual(refreshed.cpu.last?.yEnd, initial.cpu.last?.yEnd)
        XCTAssertEqual(refreshed.records.last?.created, initial.records.last?.created.addingTimeInterval(60))
        let expectedNotice = String(localized: "Container history: \(URLError(.cannotConnectToHost).localizedDescription)")
        XCTAssertTrue(refreshed.notices.contains(expectedNotice))

        let withoutPrevious = try await ChartDataLoader.load(service: service, systemID: "another-server", range: .day, now: now)
        XCTAssertTrue(withoutPrevious.containers.isEmpty)
        XCTAssertFalse(withoutPrevious.notices.isEmpty)
    }

    func testSuccessfulEmptyDockerResponseClearsPreviousHistory() async throws {
        let service = ChartHistoryService()
        let initial = try await ChartDataLoader.load(service: service, systemID: "server", range: .hour, now: Date())
        await service.setContainerResponse(fails: false, empty: true)
        let refreshed = try await ChartDataLoader.load(service: service, systemID: "server", range: .hour,
            now: Date(), previous: initial)
        XCTAssertTrue(refreshed.containers.isEmpty)
        XCTAssertTrue(refreshed.cpu.isEmpty)
        XCTAssertTrue(refreshed.notices.isEmpty)
    }
}

private actor ChartHistoryService: BeszelServing {
    private var fails = false
    private var empty = false
    func setContainerResponse(fails: Bool, empty: Bool = false) { self.fails = fails; self.empty = empty }
    func fetchSystems() async throws -> [SystemRecord] { [] }
    func fetchSystemDetails() async throws -> [SystemDetailsRecord] { [] }
    func fetchContainers(filter: String?) async throws -> [ContainerRecord] { [] }
    func fetchAlerts(filter: String?) async throws -> [AlertRecord] { [] }
    func fetchHistory(systemID: String, range: HistoryRange, now: Date) async throws -> [SystemStatsRecord] { [] }
    func fetchDetailedHistory(systemID: String, range: HistoryRange, now: Date) async throws -> [DetailedSystemRecord] {
        try ChartFixtures.data(now: now).records
    }
    func fetchContainerHistory(systemID: String, range: HistoryRange, now: Date) async throws -> [DetailedContainerRecord] {
        if fails { throw URLError(.cannotConnectToHost) }
        return empty ? [] : try ChartFixtures.data(now: now).containerRecords
    }
}
