import SwiftUI

struct MenuAppearance {
    static let fontSizeKey = "menuFontSize"
    static let defaultFontSize = 12.0
    static let fontSizeRange = 10.0...18.0

    let fontSize: Double

    init(fontSize: Double = defaultFontSize) {
        self.fontSize = fontSize.isFinite
            ? min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            : Self.defaultFontSize
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(fontSize: defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize)
    }

    func size(_ points: CGFloat) -> CGFloat {
        points * fontSize / Self.defaultFontSize
    }
}

private struct MenuAppearanceKey: EnvironmentKey {
    static let defaultValue = MenuAppearance()
}

extension EnvironmentValues {
    var menuAppearance: MenuAppearance {
        get { self[MenuAppearanceKey.self] }
        set { self[MenuAppearanceKey.self] = newValue }
    }
}
