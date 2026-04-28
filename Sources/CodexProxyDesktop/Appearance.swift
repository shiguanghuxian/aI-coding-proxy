#if os(macOS)
import AppKit
import CodexProxyCore
import SwiftUI

struct AppearancePalette {
    var windowTop: Color
    var windowBottom: Color
    var sidebarTop: Color
    var sidebarBottom: Color
    var sidebarPanel: Color
    var panel: Color
    var panelRaised: Color
    var panelEmphasis: Color
    var panelMuted: Color
    var fieldBackground: Color
    var consoleBackground: Color
    var border: Color
    var divider: Color
    var textPrimary: Color
    var textSecondary: Color
    var textMuted: Color
    var accent: Color
    var accentSoft: Color
    var accentGlow: Color
    var success: Color
    var successSoft: Color
    var warning: Color
    var warningSoft: Color
    var danger: Color
    var dangerSoft: Color
    var info: Color
    var infoSoft: Color
    var infoBorder: Color
    var shadow: Color
}

enum AppearanceStore {
    static func preferredColorScheme(for mode: DesktopThemeMode) -> ColorScheme? {
        switch mode {
        case .system:
            return nil
        case .light:
            return .light
        case .dark:
            return .dark
        }
    }

    static func nsAppearanceName(for mode: DesktopThemeMode) -> NSAppearance.Name? {
        switch mode {
        case .system:
            return nil
        case .light:
            return .aqua
        case .dark:
            return .darkAqua
        }
    }

    @MainActor
    static func applyAppAppearance(for mode: DesktopThemeMode) {
        let app = NSApplication.shared
        let appearance = self.nsAppearanceName(for: mode).flatMap(NSAppearance.init(named:))
        app.appearance = appearance
        for window in app.windows {
            self.applyWindowAppearance(window, for: mode)
        }
    }

    @MainActor
    static func applyWindowAppearance(_ window: NSWindow, for mode: DesktopThemeMode) {
        window.appearance = self.nsAppearanceName(for: mode).flatMap(NSAppearance.init(named:))
    }

    static func palette(for scheme: ColorScheme) -> AppearancePalette {
        switch scheme {
        case .dark:
            return AppearancePalette(
                windowTop: Color(hex: 0x0C1521),
                windowBottom: Color(hex: 0x111C2B),
                sidebarTop: Color(hex: 0x101A28),
                sidebarBottom: Color(hex: 0x132131),
                sidebarPanel: Color(hex: 0x142131),
                panel: Color(hex: 0x162233),
                panelRaised: Color(hex: 0x1A2738),
                panelEmphasis: Color(hex: 0x1D2C40),
                panelMuted: Color(hex: 0x111B29),
                fieldBackground: Color(hex: 0x101928),
                consoleBackground: Color(hex: 0x0B1420),
                border: Color.white.opacity(0.08),
                divider: Color.white.opacity(0.07),
                textPrimary: Color(hex: 0xF5F7FB),
                textSecondary: Color(hex: 0xB9C8DC),
                textMuted: Color(hex: 0x8092A8),
                accent: Color(hex: 0x4A8CFF),
                accentSoft: Color(hex: 0x1B3257),
                accentGlow: Color(hex: 0x2A4F85),
                success: Color(hex: 0x32C782),
                successSoft: Color(hex: 0x17392D),
                warning: Color(hex: 0xF0B455),
                warningSoft: Color(hex: 0x4B3718),
                danger: Color(hex: 0xF26D66),
                dangerSoft: Color(hex: 0x472221),
                info: Color(hex: 0x72A8FF),
                infoSoft: Color(hex: 0x182D4D),
                infoBorder: Color(hex: 0x5C8FE3, alpha: 0.36),
                shadow: Color.black.opacity(0.30)
            )
        default:
            return AppearancePalette(
                windowTop: Color(hex: 0xF6F8FD),
                windowBottom: Color(hex: 0xEEF3FB),
                sidebarTop: Color(hex: 0xF3F6FC),
                sidebarBottom: Color(hex: 0xE9EEF9),
                sidebarPanel: Color(hex: 0xEEF3FB),
                panel: Color.white,
                panelRaised: Color(hex: 0xFAFCFF),
                panelEmphasis: Color(hex: 0xF4F8FF),
                panelMuted: Color(hex: 0xF2F6FC),
                fieldBackground: Color(hex: 0xF7F9FD),
                consoleBackground: Color(hex: 0xEDF2FA),
                border: Color(hex: 0x183153, alpha: 0.09),
                divider: Color(hex: 0x183153, alpha: 0.08),
                textPrimary: Color(hex: 0x172741),
                textSecondary: Color(hex: 0x62728B),
                textMuted: Color(hex: 0x7B8CA5),
                accent: Color(hex: 0x2E7BFF),
                accentSoft: Color(hex: 0xEAF2FF),
                accentGlow: Color(hex: 0xCFDEFF),
                success: Color(hex: 0x23B26B),
                successSoft: Color(hex: 0xEEFBF4),
                warning: Color(hex: 0xD2902E),
                warningSoft: Color(hex: 0xFFF6E8),
                danger: Color(hex: 0xE05D58),
                dangerSoft: Color(hex: 0xFFF0EF),
                info: Color(hex: 0x4A8CFF),
                infoSoft: Color(hex: 0xEFF5FF),
                infoBorder: Color(hex: 0xBFD6FF),
                shadow: Color(hex: 0x183153, alpha: 0.10)
            )
        }
    }
}

private extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: alpha
        )
    }
}
#endif
