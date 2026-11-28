import Foundation

struct RealtimeSystemUpdate: Sendable {
    let systemID: String
    let metrics: RealtimeMetrics
    let receivedAt: Date

    init(systemID: String, metrics: RealtimeMetrics, receivedAt: Date = Date()) {
        self.systemID = systemID
        self.metrics = metrics
        self.receivedAt = receivedAt
    }

    func applying(to system: SystemRecord) -> SystemRecord {
        guard system.id == systemID, system.isOnline else { return system }
        var info = system.info ?? metrics.info
        info.cpu = metrics.info.cpu ?? info.cpu
        info.mp = metrics.info.mp ?? info.mp
        info.dp = metrics.info.dp ?? info.dp
        info.b = metrics.info.b ?? info.b
        info.bb = metrics.info.bb ?? info.bb
        info.dt = metrics.info.dt ?? info.dt
        info.la = metrics.info.loadAverage ?? info.la
        return SystemRecord(id: system.id, name: system.name, status: system.status,
                            host: system.host, port: system.port, info: info,
                            v: system.v, updated: system.updated,
                            networkTraffic: metrics.stats?.networkTraffic ?? system.networkTraffic)
    }
}

struct RealtimeMetrics: Decodable, Sendable {
    let info: SystemInfo
    let stats: SystemStatsDetail?
}

extension SystemStatsDetail {
    var networkTraffic: SystemNetworkTraffic {
        // New agents send bytes/s in [upload, download] order. Older
        // agents use MB/s; zero rates may be omitted from their payload.
        if let b, b.count >= 2 {
            return SystemNetworkTraffic(upload: b[0], download: b[1])
        }
        return SystemNetworkTraffic(upload: (ns ?? 0) * 1_048_576,
                                    download: (nr ?? 0) * 1_048_576)
    }
}

struct SystemNetworkTraffic: Hashable, Sendable {
    let upload: Double
    let download: Double

    var uploadDisplay: String { Self.formatRate(upload) }
    var downloadDisplay: String { Self.formatRate(download) }
    var compactDisplay: String { "\(uploadDisplay) | \(downloadDisplay)" }

    private static func formatRate(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0K" }
        for (divisor, suffix) in [(1_099_511_627_776.0, "T"), (1_073_741_824.0, "G"), (1_048_576.0, "M")] {
            if bytesPerSecond >= divisor {
                return String(format: "%.1f%@", bytesPerSecond / divisor, suffix)
            }
        }
        if bytesPerSecond >= 1_024 {
            return String(format: "%.0fK", bytesPerSecond / 1_024)
        }
        return String(format: "%.0fB", bytesPerSecond)
    }
}
