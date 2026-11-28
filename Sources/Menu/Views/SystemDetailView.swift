import SwiftUI

struct SystemDetailView: View {
    @Environment(\.menuAppearance) private var appearance
    let appState: AppState
    let entry: HubSystem
    var onAction: (() -> Void)? = nil
    var showsLoadAverage = false
    @State private var latestStats: SystemStatsDetail?

    private var realtimeStats: SystemStatsDetail? {
        appState.realtimeStats(for: entry.id)
    }

    private var system: SystemRecord {
        appState.system(for: entry.id)?.system ?? entry.system
    }

    private var details: SystemDetailsRecord? {
        appState.hubSnapshots[entry.instance.id]?.details[entry.system.id]
    }

    private var cpuModel: String? {
        details?.cpu ?? system.info?.m
    }

    private var cpuCores: Int? {
        details?.cores ?? system.info?.c
    }

    private var hostname: String? {
        details?.hostname ?? system.info?.h
    }

    private var loadAverage: [Double]? {
        realtimeStats?.loadAverage ?? system.info?.loadAverage ?? latestStats?.loadAverage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.size(8)) {
            VStack(alignment: .leading, spacing: appearance.size(2)) {
                HStack(spacing: appearance.size(8)) {
                    let displayName = hostname ?? system.name
                    Label {
                        Text(displayName)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "desktopcomputer")
                    }
                    .font(.system(size: appearance.size(12), weight: .semibold))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    if let onAction {
                        SystemDetailActions(appState: appState, entry: entry, onAction: onAction)
                    }
                }

                if cpuModel != nil || cpuCores != nil {
                    HStack(spacing: appearance.size(4)) {
                        Image(systemName: "cpu")
                            .font(.system(size: appearance.size(9)))
                        if let model = cpuModel {
                            Text(model)
                                .lineLimit(1)
                        }
                        if let cores = cpuCores {
                            if cpuModel != nil {
                                Text("•")
                            }
                            Text("\(cores) cores")
                        }
                    }
                    .font(.system(size: appearance.size(10)))
                    .foregroundColor(.secondary)
                }

                if system.info?.dt != nil || system.info?.u != nil {
                    HStack(spacing: appearance.size(12)) {
                        if let temp = system.info?.dt {
                            Text(verbatim: String(format: "%.0f°C", temp))
                                .foregroundColor(temp > 80 ? .red : (temp > 60 ? .orange : .secondary))
                        }
                        if let uptime = system.info?.u {
                            Label(formatUptime(uptime), systemImage: "clock")
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.system(size: appearance.size(10)))
                }
            }

            Divider()
                .padding(.vertical, appearance.size(2))

            VStack(alignment: .leading, spacing: appearance.size(6)) {
                Label("Usage", systemImage: "chart.bar.fill")
                    .font(.system(size: appearance.size(11), weight: .semibold))
                    .foregroundColor(.primary)

                if let cpu = system.cpuPercentage {
                    MetricBar(label: "CPU", value: cpu, color: valueColor(cpu))
                }
                if showsLoadAverage, let loadAverage {
                    loadAverageRow(loadAverage)
                }
                if let mem = system.memoryPercentage {
                    MetricBar(label: "Memory", value: mem, color: valueColor(mem),
                              capacity: realtimeStats?.memoryCapacityDisplay ?? latestStats?.memoryCapacityDisplay ?? "—")
                }
                if let disk = system.diskPercentage {
                    MetricBar(label: "Disk", value: disk, color: valueColor(disk),
                              capacity: realtimeStats?.diskCapacityDisplay ?? latestStats?.diskCapacityDisplay ?? "—")
                }
            }
        }
        .padding(.horizontal, appearance.size(8))
        .padding(.vertical, appearance.size(6))
        .frame(maxWidth: onAction == nil ? appearance.size(240) : .infinity, alignment: .leading)
        .task(id: appState.connectionRevision) {
            // Seed capacities for older hubs and refresh while streaming is unavailable.
            while !Task.isCancelled {
                if realtimeStats?.memoryCapacityDisplay == nil || realtimeStats?.diskCapacityDisplay == nil {
                    do {
                        let service = try appState.chartService(for: entry.id)
                        let records = try await service.fetchSystemStats(systemID: entry.system.id, limit: 1)
                        try Task.checkCancellation()
                        latestStats = records.first?.stats
                    } catch is CancellationError {
                        return
                    } catch {
                        // Keep percentages available when capacity data cannot be read.
                    }
                }
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
            }
        }
    }

    private func loadAverageRow(_ load: [Double]) -> some View {
        HStack(spacing: appearance.size(6)) {
            loadReading("1m", value: load[0])
            loadReading("5m", value: load[1])
            loadReading("15m", value: load[2])
        }
        .font(.system(size: appearance.size(10)))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .combine)
    }

    private func loadReading(_ period: String, value: Double) -> some View {
        HStack(spacing: appearance.size(2)) {
            Text(verbatim: period)
                .foregroundStyle(.secondary)
            Text(value, format: .number.precision(.fractionLength(0...2)))
                .monospacedDigit()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func formatUptime(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: seconds) ?? "—"
    }

    private func formatBandwidth(_ mb: Double) -> String {
        if mb >= 1024 {
            return String(format: "%.1f GB/s", mb / 1024)
        }
        return String(format: "%.1f MB/s", mb)
    }

    private func valueColor(_ value: Double) -> Color {
        if value >= 90 { return AppColors.red }
        if value >= 70 { return AppColors.orange }
        return AppColors.green
    }
}

enum AppColors {
    static let green = Color.green
    static let orange = Color.orange
    static let red = Color.red
    static let gray = Color.gray
}

struct MetricBar: View {
    @Environment(\.menuAppearance) private var appearance
    let label: LocalizedStringKey
    let value: Double
    let color: Color
    var capacity: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: appearance.size(3)) {
            HStack {
                Text(label)
                    .font(.system(size: appearance.size(10), weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(value))%")
                    .font(.system(size: appearance.size(10), weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: appearance.size(3))
                        .fill(Color.secondary.opacity(0.2))
                        .frame(height: appearance.size(6))

                    RoundedRectangle(cornerRadius: appearance.size(3))
                        .fill(color)
                        .frame(width: geometry.size.width * min(value / 100, 1.0), height: appearance.size(6))
                }
            }
            .frame(height: appearance.size(6))

            if let capacity {
                Text(verbatim: capacity)
                    .font(.system(size: appearance.size(10)))
                    .monospacedDigit()
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}
