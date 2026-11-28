import Foundation

struct SystemRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let status: String?
    let host: String?
    let port: String?
    let info: SystemInfo?
    let v: String?
    let updated: String?
    // Directional rates come from rt_metrics, not the systems collection.
    var networkTraffic: SystemNetworkTraffic? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, status, host, port, info, v, updated
    }
}

struct SystemInfo: Codable, Hashable, Sendable {
    let h: String?
    let k: String?
    let c: Int?
    let t: Int?
    let m: String?
    let o: String?
    let os: Int?
    let u: Double?
    let v: String?
    var cpu: Double?
    var mp: Double?
    var dp: Double?
    var b: Double?
    var bb: Double?
    let l1: Double?
    let l5: Double?
    let l15: Double?
    var la: [Double]?
    let bat: [Double]?
    let g: Double?
    var dt: Double?
    let p: Bool?
    let ct: Int?
    let efs: [String: Double]?
    let sv: [Int]?

    var loadAverage: [Double]? {
        loadAverageValues(la, legacy: (l1, l5, l15))
    }
}

extension SystemRecord {
    var displayStatus: String {
        guard let status = status?.lowercased() else { return String(localized: "status.unknown") }
        switch status {
        case "up", "online": return String(localized: "status.operational")
        case "down", "offline": return String(localized: "status.offline")
        case "pending": return String(localized: "status.pending")
        case "paused": return String(localized: "status.paused")
        case "unknown": return String(localized: "status.unknown")
        default: return status.capitalized
        }
    }

    var isOnline: Bool {
        guard let status = status?.lowercased() else { return false }
        return status == "up" || status == "online"
    }

    var cpuPercentage: Double? {
        info?.cpu
    }

    var memoryPercentage: Double? {
        info?.mp
    }

    var diskPercentage: Double? {
        info?.dp
    }

    var temperature: Double? {
        info?.dt
    }
}

struct SystemStatsRecord: Identifiable, Codable {
    let id: String
    let created: String
    let stats: SystemStatsDetail?
    let type: String?
}

struct SystemStatsDetail: Codable, Sendable {
    let cpu: Double?
    let mp: Double?
    let dp: Double?
    let ns: Double?
    let nr: Double?
    var b: [Double]? = nil
    var m: Double? = nil
    var mu: Double? = nil
    var d: Double? = nil
    var du: Double? = nil
    var mem: [Double]? = nil
    var la: [Double]? = nil
    var l1: Double? = nil
    var l5: Double? = nil
    var l15: Double? = nil

    enum CodingKeys: String, CodingKey {
        case cpu, mp, dp, ns, nr, b, m, mu, d, du, mem, la, l1, l5, l15
    }

    var loadAverage: [Double]? {
        loadAverageValues(la, legacy: (l1, l5, l15))
    }

    var memoryCapacityDisplay: String? {
        if let mem, mem.count >= 2 {
            return Self.capacityDisplay(used: mem[1] / 1_073_741_824, total: mem[0] / 1_073_741_824)
        }
        return Self.capacityDisplay(used: mu, total: m)
    }

    var diskCapacityDisplay: String? {
        Self.capacityDisplay(used: du, total: d)
    }

    private static func capacityDisplay(used: Double?, total: Double?) -> String? {
        guard let used, let total, used.isFinite, total.isFinite, used >= 0, total > 0 else { return nil }
        let divisor = total >= 1024 ? 1024.0 : (total < 1 ? 1.0 / 1024 : 1)
        let unit = total >= 1024 ? "TiB" : (total < 1 ? "MiB" : "GiB")
        let format = FloatingPointFormatStyle<Double>.number.precision(.fractionLength(0...2))
        return "\((used / divisor).formatted(format)) / \((total / divisor).formatted(format)) \(unit)"
    }
}

private func loadAverageValues(_ values: [Double]?, legacy: (Double?, Double?, Double?)) -> [Double]? {
    if let values, values.count >= 3 {
        return Array(values.prefix(3))
    }
    if let l1 = legacy.0, let l5 = legacy.1, let l15 = legacy.2 {
        return [l1, l5, l15]
    }
    return nil
}

struct SystemDetailsRecord: Identifiable, Codable, Hashable {
    let id: String
    let system: String
    let hostname: String?
    let kernel: String?
    let cores: Int?
    let threads: Int?
    let cpu: String?
    let memory: Int64?
    let os: Int?
    let osName: String?
    let arch: String?
    let podman: Bool?
    let updated: String?

    enum CodingKeys: String, CodingKey {
        case id, system, hostname, kernel, cores, threads, cpu, memory, os
        case osName = "os_name"
        case arch, podman, updated
    }
}

enum ContainerHealth: Int, Codable, Hashable {
    case none = 0
    case starting = 1
    case healthy = 2
    case unhealthy = 3

    var displayText: String {
        switch self {
        case .none: return String(localized: "No Health Check")
        case .starting: return String(localized: "container.health.starting")
        case .healthy: return String(localized: "container.health.healthy")
        case .unhealthy: return String(localized: "container.health.unhealthy")
        }
    }

    var color: String {
        switch self {
        case .none: return "secondary"
        case .starting: return "orange"
        case .healthy: return "green"
        case .unhealthy: return "red"
        }
    }
}

struct ContainerRecord: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let cpu: Double
    let memory: Double
    let net: Double
    let health: ContainerHealth
    let status: String
    let image: String
    let system: String
    let updated: Int64

    var updatedDate: Date {
        Date(timeIntervalSince1970: Double(updated) / 1000.0)
    }

    var displayStatus: String {
        switch status.lowercased() {
        case "running": return String(localized: "container.status.running")
        case "stopped": return String(localized: "container.status.stopped")
        case "created": return String(localized: "container.status.created")
        case "restarting": return String(localized: "container.status.restarting")
        case "paused": return String(localized: "container.status.paused")
        case "exited": return String(localized: "container.status.exited")
        case "dead": return String(localized: "container.status.dead")
        case "removing": return String(localized: "container.status.removing")
        default: return status
        }
    }
}

struct ContainerStatsRecord: Identifiable, Codable {
    let id: String
    let system: String
    let name: String?
    let cpu: Double?
    let mem: Double?
    let created: String?

    var containerID: String { id }
    var containerName: String? { name }
    var memory: Double? { mem }
}

struct AlertRecord: Identifiable, Codable {
    let id: String
    let name: String
    let system: String?
    let metric: String?
    let threshold: Double?
    let enabled: Bool?
    let triggered: Bool?
    let created: String?
    let updated: String?
    var value: Double? = nil

    var displayMetric: String {
        switch metric?.lowercased() {
        case "cpu": return String(localized: "CPU")
        case "memory", "mem": return String(localized: "Memory")
        case "disk": return String(localized: "Disk")
        case "temperature", "temp": return String(localized: "chart.temperatures")
        case "network": return String(localized: "Network")
        case "bandwidth": return String(localized: "Bandwidth")
        default: return metric ?? name
        }
    }

    var displayThreshold: String {
        if let t = threshold ?? value {
            return String(format: "%.0f", t)
        }
        return "-"
    }
}

struct AlertHistoryRecord: Identifiable, Codable {
    let id: String
    let alert: String
    let system: String?
    let name: String?
    let message: String?
    let value: Double?
    let threshold: Double?
    let created: String?
}

struct PocketBaseListResponse<T: Codable>: Codable {
    let page: Int
    let perPage: Int
    let totalPages: Int
    let totalItems: Int
    let items: [T]
}

struct AuthResponse: Codable {
    let token: String
}
