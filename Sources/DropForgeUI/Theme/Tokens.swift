import AppKit
import SwiftUI

/// DropForge design tokens. Components use these names only, never raw colours or sizes.
public enum Tokens {
    public enum Palette {
        /// Primary accent: "forge teal". Adapts to light, dark and increased contrast.
        public static let accent = dynamic(light: (0.059, 0.486, 0.525), dark: (0.255, 0.773, 0.788),
                                           lightHC: (0.0, 0.33, 0.37), darkHC: (0.45, 0.93, 0.95))
        /// Secondary accent: "slate indigo", used for tools.
        public static let secondary = dynamic(light: (0.31, 0.36, 0.84), dark: (0.55, 0.60, 1.0),
                                              lightHC: (0.18, 0.2, 0.62), darkHC: (0.72, 0.76, 1.0))
        /// Tertiary accent for actions: "moss".
        public static let tertiary = dynamic(light: (0.18, 0.55, 0.36), dark: (0.42, 0.82, 0.58),
                                             lightHC: (0.07, 0.38, 0.2), darkHC: (0.6, 0.95, 0.7))
        public static let danger = NSColor.systemRed
        public static let success = NSColor.systemGreen
        public static let text = NSColor.labelColor
        public static let secondaryText = NSColor.secondaryLabelColor
        public static let separator = NSColor.separatorColor
        /// Text on an accent fill: white on the deep light-mode accents, near-black on the bright dark-mode ones.
        public static let onAccent = dynamic(light: (1, 1, 1), dark: (0.06, 0.07, 0.09), lightHC: (1, 1, 1), darkHC: (0, 0, 0))

        public static func category(_ c: CategoryTone) -> NSColor {
            switch c {
            case .convert: accent
            case .tools: secondary
            case .actions: tertiary
            }
        }

        static func dynamic(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat),
                            lightHC: (CGFloat, CGFloat, CGFloat), darkHC: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hc = appearance.name.rawValue.contains("HighContrast")
                    || NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                let c = isDark ? (hc ? darkHC : dark) : (hc ? lightHC : light)
                return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        }
    }

    public enum CategoryTone { case convert, tools, actions }

    public enum Wheel {
        public static let hubRadius: CGFloat = 60
        public static let ringWidth: CGFloat = 80
        public static let ringGap: CGFloat = 6
        public static let largeScale: CGFloat = 1.25
        public static let headerHeight: CGFloat = 34
        public static let footerHeight: CGFloat = 30
        public static let margin: CGFloat = 18
        public static let segmentFillAlpha: CGFloat = 0.07
        public static let segmentFillAlphaHighContrast: CGFloat = 0.16
        public static let strokeAlpha: CGFloat = 0.12
        public static let strokeAlphaHighContrast: CGFloat = 0.65
        public static let iconPointSize: CGFloat = 19
        public static let labelPointSize: CGFloat = 11
        public static let hubTitlePointSize: CGFloat = 12
        public static let hubDetailPointSize: CGFloat = 10
        public static let appearDuration: TimeInterval = 0.14
    }

    public enum Metrics {
        public static let spacingXS: CGFloat = 4
        public static let spacingS: CGFloat = 8
        public static let spacingM: CGFloat = 12
        public static let spacingL: CGFloat = 20
        public static let spacingXL: CGFloat = 28
        public static let cornerRadius: CGFloat = 10
        public static let smallCornerRadius: CGFloat = 6
        public static let editorSize = CGSize(width: 760, height: 600)
        public static let pickerSize = CGSize(width: 460, height: 520)
        public static let progressWidth: CGFloat = 420
        public static let shelfSize = CGSize(width: 260, height: 300)
        public static let previewMaxPixels = 1600
        public static let thumbnailPixels = 240
    }

    public enum Motion {
        /// Honour System Settings › Accessibility › Display › Reduce motion.
        @MainActor public static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        @MainActor public static var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }
        @MainActor public static var highContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
    }
}

extension Color {
    static let dfAccent = Color(nsColor: Tokens.Palette.accent)
    static let dfSecondary = Color(nsColor: Tokens.Palette.secondary)
    static let dfTertiary = Color(nsColor: Tokens.Palette.tertiary)
    static let dfDanger = Color(nsColor: Tokens.Palette.danger)
    static let dfOnAccent = Color(nsColor: Tokens.Palette.onAccent)
    static let dfSuccess = Color(nsColor: Tokens.Palette.success)
}
