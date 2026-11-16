import SwiftUI

struct InfoMenuRowView: View {
    @Environment(\.menuAppearance) private var appearance
    let title: LocalizedStringKey
    let subtext: String?

    var body: some View {
        HStack(spacing: appearance.size(10)) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.system(size: appearance.size(13)))

            VStack(alignment: .leading, spacing: appearance.size(2)) {
                Text(title)
                    .font(.system(size: appearance.size(12), weight: .semibold))
                if let subtext = subtext {
                    Text(subtext)
                        .font(.system(size: appearance.size(11)))
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.horizontal, appearance.size(10))
        .padding(.vertical, appearance.size(6))
        .frame(maxWidth: .infinity)
    }
}
