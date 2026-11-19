import SwiftUI

struct SystemMenuRowView: View {
    @Environment(\.menuAppearance) private var appearance
    let appState: AppState
    let entry: HubSystem
    @AppStorage("showStatsInMenu") private var showStatsInMenu = true

    private var system: SystemRecord {
        appState.system(for: entry.id)?.system ?? entry.system
    }

    var body: some View {
        HStack(spacing: appearance.size(8)) {
            VStack(alignment: .leading, spacing: appearance.size(6)) {
                HStack(alignment: .firstTextBaseline, spacing: appearance.size(8)) {
                    StatusDot(color: statusColor)

                    Text(system.name.isEmpty ? system.id : system.name)
                        .font(.system(size: appearance.size(12), weight: .medium))
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)

                    if let temperature = system.temperature, temperature.isFinite {
                        Text(verbatim: String(format: "%.0f°C", temperature))
                            .font(.system(size: appearance.size(10), weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(temperature > 80 ? Color.red : (temperature > 60 ? Color.orange : Color.secondary))
                            .fixedSize()
                    }
                }

                if showsStatsRow {
                    HStack(spacing: appearance.size(4)) {
                        if let cpu = system.cpuPercentage {
                            StatPill(value: cpu, icon: "cpu", showsLessThanOnePercent: false)
                        }
                        if let mem = system.memoryPercentage {
                            StatPill(value: mem, icon: "memorychip")
                        }
                        if let disk = system.diskPercentage {
                            StatPill(value: disk, icon: "internaldrive")
                        }

                        if system.isOnline {
                            let upload = system.networkTraffic?.uploadDisplay
                            let download = system.networkTraffic?.downloadDisplay
                            let uploadLabel = String(localized: "Upload")
                            let downloadLabel = String(localized: "Download")
                            let description = if let upload, let download {
                                "\(uploadLabel): \(upload)/s | \(downloadLabel): \(download)/s"
                            } else {
                                "\(uploadLabel) | \(downloadLabel)"
                            }

                            HStack(spacing: appearance.size(6)) {
                                trafficIndicator("arrow.up", rate: upload)
                                trafficIndicator("arrow.down", rate: download)
                            }
                            .font(.system(size: appearance.size(10), weight: .semibold))
                            .foregroundStyle(.secondary)
                            .fixedSize()
                            .padding(.leading, appearance.size(4))
                            .help(Text(verbatim: description))
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(Text(verbatim: description))
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, appearance.size(10))
        .padding(.vertical, appearance.size(4))
    }

    private func trafficIndicator(_ icon: String, rate: String?) -> some View {
        HStack(spacing: appearance.size(2)) {
            Image(systemName: icon)
                .frame(width: appearance.size(9))
            Text(verbatim: "000K")
                .hidden()
                .overlay(alignment: .trailing) {
                    if let rate {
                        Text(verbatim: rate)
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)
                    }
                }
                .font(.system(size: appearance.size(10), weight: .semibold, design: .monospaced))
        }
    }

    private var showsStatsRow: Bool {
        showStatsInMenu && (system.isOnline || system.cpuPercentage != nil
            || system.memoryPercentage != nil || system.diskPercentage != nil)
    }

    private var statusColor: Color {
        guard let status = system.status?.lowercased() else { return .gray }
        switch status {
        case "up", "online": return .green
        case "down", "offline": return .red
        case "pending": return .orange
        default: return .gray
        }
    }
}

struct StatusDot: View {
    @Environment(\.menuAppearance) private var appearance
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.2))
                .frame(width: appearance.size(12), height: appearance.size(12))
            Circle()
                .fill(color)
                .frame(width: appearance.size(6), height: appearance.size(6))
        }
    }
}

struct StatPill: View {
    @Environment(\.menuAppearance) private var appearance
    let value: Double
    let icon: String
    var showsLessThanOnePercent = true
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private var percentage: Double {
        min(max(value.isFinite ? value : 0, 0), 100)
    }

    private var displayValue: String {
        showsLessThanOnePercent && percentage > 0 && percentage < 1 ? "<1%" : "\(Int(percentage))%"
    }

    var body: some View {
        HStack(spacing: appearance.size(4)) {
            Image(systemName: icon)
                .font(.system(size: appearance.size(10), weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: appearance.size(12))

            Text(displayValue)
                .font(.system(size: appearance.size(10), weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(colorScheme == .light ? Color.secondary : Color.primary)
                .padding(.horizontal, appearance.size(3))
                .frame(width: appearance.size(38), height: appearance.size(18), alignment: .leading)
                .background { usageFill }
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: appearance.size(5), style: .continuous))
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }

    private var usageFill: some View {
        GeometryReader { geometry in
            if percentage > 0 {
                let fillWidth = min(geometry.size.width, max(1 / max(displayScale, 1), geometry.size.width * percentage / 100))

                // Reveal a stable rounded shape instead of squeezing its corners
                // into a tall sliver when the fill is narrower than its diameter.
                RoundedRectangle(cornerRadius: appearance.size(5), style: .continuous)
                    .fill(.green)
                    .frame(width: max(appearance.size(10), fillWidth))
                    .frame(width: fillWidth, alignment: .leading)
                    .clipped()
            }
        }
    }
}
