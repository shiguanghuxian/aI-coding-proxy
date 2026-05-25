#if os(macOS)
import CodexProxyCore
import Foundation

enum SettingsTab: String, CaseIterable, Identifiable, Sendable, Equatable {
    case appearance
    case general
    case ocr
    case proxy
    case service
    case cleanup

    var id: String { self.rawValue }

    var symbolName: String {
        switch self {
        case .appearance:
            return "circle.lefthalf.filled"
        case .general:
            return "slider.horizontal.3"
        case .ocr:
            return "text.viewfinder"
        case .proxy:
            return "network"
        case .service:
            return "server.rack"
        case .cleanup:
            return "trash"
        }
    }

    var tabTitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .sectionAppearance
        case .general:
            return .sectionGeneral
        case .ocr:
            return .sectionOCRModel
        case .proxy:
            return .proxyTitle
        case .service:
            return .sectionService
        case .cleanup:
            return .sectionCleanup
        }
    }

    var panelTitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .sectionAppearance
        case .general:
            return .sectionGeneral
        case .ocr:
            return .sectionOCRModel
        case .proxy:
            return .sectionOutboundProxy
        case .service:
            return .sectionService
        case .cleanup:
            return .sectionCleanup
        }
    }

    var subtitleKey: LocalizedTextKey {
        switch self {
        case .appearance:
            return .helperAppearanceAppliesImmediately
        case .general:
            return .settingsSubtitle
        case .ocr:
            return .helperOCRModelSettings
        case .proxy:
            return .proxySubtitle
        case .service:
            return .helperServiceDiagnostics
        case .cleanup:
            return .helperCleanup
        }
    }
}
#endif
