#if os(macOS)
import AppKit
import CodexProxyCore
import Foundation
import UniformTypeIdentifiers

struct ProxyTestImageSavePanelRequest: Equatable {
    var defaultFilename: String
    var contentType: UTType
    var fileExtension: String
}

struct ProxyTestDownloadedImage: Equatable, Sendable {
    var data: Data
    var contentType: String?
}

private enum ProxyTestImageFileFormat {
    case png
    case jpeg
    case webp
    case gif

    var contentType: UTType {
        switch self {
        case .png:
            return .png
        case .jpeg:
            return .jpeg
        case .webp:
            return UTType(filenameExtension: "webp") ?? .data
        case .gif:
            return .gif
        }
    }

    var fileExtension: String {
        switch self {
        case .png:
            return "png"
        case .jpeg:
            return "jpg"
        case .webp:
            return "webp"
        case .gif:
            return "gif"
        }
    }

    static func detect(data: Data, contentType: String?) -> Self {
        let normalizedContentType = contentType?
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch normalizedContentType {
        case "image/jpeg", "image/jpg":
            return .jpeg
        case "image/webp":
            return .webp
        case "image/gif":
            return .gif
        case "image/png":
            return .png
        default:
            break
        }

        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return .png
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return .jpeg
        }
        if bytes.starts(with: [0x47, 0x49, 0x46]) {
            return .gif
        }
        if bytes.count >= 12,
           Array(bytes[0...3]) == [0x52, 0x49, 0x46, 0x46],
           Array(bytes[8...11]) == [0x57, 0x45, 0x42, 0x50]
        {
            return .webp
        }
        return .png
    }
}

extension DesktopAppModel {
    static func defaultProxyTestImageEditFileSelectionPanel() -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [
            .png,
            .jpeg,
            UTType(filenameExtension: "webp") ?? .image,
        ]
        guard panel.runModal() == .OK else { return nil }
        return panel.urls
    }

    nonisolated static func defaultProxyTestImageFilenameToken() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let timestamp = formatter.string(from: Date())
        let random = String(format: "%08X", UInt32.random(in: UInt32.min...UInt32.max))
        return "\(timestamp)-\(random)"
    }

    static func defaultProxyTestImageSavePanel(_ request: ProxyTestImageSavePanelRequest) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [request.contentType]
        panel.nameFieldStringValue = request.defaultFilename
        panel.canCreateDirectories = true
        return panel.runModal() == .OK ? panel.url : nil
    }

    nonisolated static func defaultProxyTestImageDownload(_ url: URL) async throws -> ProxyTestDownloadedImage {
        var request = URLRequest(url: url)
        request.setValue("image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode)
        {
            throw ProxyError.message("Image URL download failed with HTTP \(http.statusCode).")
        }
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type") ?? response.mimeType
        return ProxyTestDownloadedImage(data: data, contentType: contentType)
    }

    func selectProxyTestImageEditFiles() {
        guard self.proxyTestRunState != .running else { return }
        let urls: [URL]?
        if let proxyTestImageEditFileSelectionHandler {
            urls = proxyTestImageEditFileSelectionHandler()
        } else {
            urls = Self.defaultProxyTestImageEditFileSelectionPanel()
        }
        guard let urls else { return }
        self.proxyTestDraft.imageEditFileURLs = urls
    }

    func clearProxyTestImageEditFiles() {
        guard self.proxyTestRunState != .running else { return }
        self.proxyTestDraft.imageEditFileURLs.removeAll()
    }

    func saveProxyTestImage(_ output: ProxyTestImageOutput, index: Int) async {
        do {
            let imageData: Data
            let contentType: String?
            if let data = output.imageData, data.isEmpty == false {
                imageData = data
                contentType = nil
            } else {
                guard let urlString = output.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      urlString.isEmpty == false,
                      let url = URL(string: urlString)
                else {
                    throw ProxyError.message("The image result does not contain downloadable image data.")
                }
                let downloaded = try await self.proxyTestImageDownloadHandler(url)
                imageData = downloaded.data
                contentType = downloaded.contentType
            }

            guard imageData.isEmpty == false else {
                throw ProxyError.message("The image result is empty.")
            }

            let format = ProxyTestImageFileFormat.detect(data: imageData, contentType: contentType)
            let imageNumber = max(index + 1, 1)
            let filename = "proxy-test-image-\(imageNumber)-\(self.proxyTestImageFilenameTokenProvider()).\(format.fileExtension)"
            let panelRequest = ProxyTestImageSavePanelRequest(
                defaultFilename: filename,
                contentType: format.contentType,
                fileExtension: format.fileExtension
            )
            guard let url = self.proxyTestImageSavePanelHandler(panelRequest) else { return }
            try self.proxyTestImageFileWriter(imageData, url)
            self.publishProxyTestBanner(
                .success,
                title: self.text(.successProxyTestImageSaved),
                detail: url.lastPathComponent
            )
        } catch {
            let detail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            self.publishProxyTestBanner(
                .error,
                title: self.text(.errorProxyTestImageSaveFailed),
                detail: detail.isEmpty ? nil : detail
            )
        }
    }
}
#endif
