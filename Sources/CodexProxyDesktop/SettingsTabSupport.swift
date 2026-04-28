#if os(macOS)
import CodexProxyCore
import Foundation

enum SettingsTab: String, CaseIterable, Identifiable, Sendable, Equatable {
    case appearance
    case general
    case proxy
    case service

    var id: String { self.rawValue }

    var symbolName: String {
        switch self {
        case .appearance:
            return "circle.lefthalf.filled"
        case .general:
            return "slider.horizontal.3"
        case .proxy:
            return "network"
        case .service:
            return "server.rack"
        }
    }

    var tabTitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .sectionAppearance
        case .general:
            return .sectionGeneral
        case .proxy:
            return .proxyTitle
        case .service:
            return .sectionService
        }
    }

    var panelTitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .sectionAppearance
        case .general:
            return .sectionGeneral
        case .proxy:
            return .sectionOutboundProxy
        case .service:
            return .sectionService
        }
    }

    var subtitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .helperAppearanceAppliesImmediately
        case .general:
            return .settingsSubtitle
        case .proxy:
            return .proxySubtitle
        case .service:
            return .helperServiceDiagnostics
        }
    }
}
#endif
