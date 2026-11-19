import SwiftUI

struct MenuAppearance {
    static let fontSizeKey = "menuFontSize"
    static let defaultFontSize = 12.0
    static let fontSizeRange = 10.0...18.0
    static let backgroundOpacityKey = "menuBackgroundOpacity"
    static let defaultBackgroundOpacity = 0.95
    static let backgroundOpacityRange = 0.2...1.0

    let fontSize: Double
    let backgroundOpacity: Double

    init(fontSize: Double = defaultFontSize, backgroundOpacity: Double = defaultBackgroundOpacity) {
        self.fontSize = fontSize.isFinite
            ? min(max(fontSize, Self.fontSizeRange.lowerBound), Self.fontSizeRange.upperBound)
            : Self.defaultFontSize
        self.backgroundOpacity = backgroundOpacity.isFinite
            ? min(max(backgroundOpacity, Self.backgroundOpacityRange.lowerBound), Self.backgroundOpacityRange.upperBound)
            : Self.defaultBackgroundOpacity
    }

    static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(fontSize: defaults.object(forKey: fontSizeKey) as? Double ?? defaultFontSize,
             backgroundOpacity: defaults.object(forKey: backgroundOpacityKey) as? Double ?? defaultBackgroundOpacity)
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
