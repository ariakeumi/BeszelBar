import SwiftUI

struct AlertMenuRowView: View {
    @Environment(\.menuAppearance) private var appearance
    let alert: AlertRecord
    let systemName: String
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: appearance.size(10)) {
            Image(systemName: alertIcon)
                .font(.system(size: appearance.size(12), weight: .semibold))
                .foregroundColor(alertColor)

            VStack(alignment: .leading, spacing: appearance.size(2)) {
                Text(alert.name)
                    .font(.system(size: appearance.size(11), weight: .medium))
                    .lineLimit(1)

                HStack(spacing: appearance.size(4)) {
                    Text(systemName)
                        .font(.system(size: appearance.size(10)))
                        .foregroundColor(.secondary)

                    Text("\u{2022}")
                        .font(.system(size: appearance.size(8)))
                        .foregroundColor(.secondary)

                    Text("\(alert.displayMetric) > \(alert.displayThreshold)")
                        .font(.system(size: appearance.size(10)))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, appearance.size(10))
        .padding(.vertical, appearance.size(8))
        .background(
            RoundedRectangle(cornerRadius: appearance.size(6), style: .continuous)
                .fill(isHovered ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var alertIcon: String {
        guard let metric = alert.metric?.lowercased() else { return "exclamationmark.triangle" }
        switch metric {
        case "cpu": return "cpu"
        case "memory", "mem": return "memorychip"
        case "disk": return "internaldrive"
        case "temperature", "temp": return "thermometer.high"
        case "network": return "network"
        default: return "exclamationmark.triangle"
        }
    }

    private var alertColor: Color {
        alert.triggered == true ? .red : .yellow
    }
}
