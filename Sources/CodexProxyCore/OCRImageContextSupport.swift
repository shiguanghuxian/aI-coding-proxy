import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public struct OCRImageReference: Sendable, Equatable {
    public var index: Int
    public var imageURL: String
    public var detail: String?

    public init(index: Int, imageURL: String, detail: String? = nil) {
        self.index = index
        self.imageURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.detail = detail?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct OCRImageRecognitionResult: Sendable, Equatable {
    public var index: Int
    public var text: String?
    public var error: String?

    public init(index: Int, text: String? = nil, error: String? = nil) {
        self.index = index
        self.text = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.error = error?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var contextText: String {
        if let text, text.isEmpty == false {
            return text
        }
        let detail = self.error?.isEmpty == false ? self.error! : "OCR 未返回可用内容。"
        return "[OCR识别失败]\n错误：\(detail)"
    }
}

struct OCRResultCacheEntry: Codable, Sendable, Equatable {
    var text: String
    var mimeType: String
    var byteCount: Int
    var touchedAt: Int64
    var expiresAt: Int64
}

private struct OCRPreparedImage: Sendable, Equatable {
    var imageHash: String
    var mimeType: String
    var byteCount: Int
    var imageURL: String
}

public struct OCRRecognitionLogContext: Sendable, Equatable {
    public var endpoint: String
    public var accountKey: String
    public var accountLabel: String
    public var requestedModel: String

    public init(
        endpoint: String = "",
        accountKey: String = "",
        accountLabel: String = "",
        requestedModel: String = ""
    ) {
        self.endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountKey = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accountLabel = accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.requestedModel = requestedModel.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public actor OCRResultCache {
    private var entries: [String: OCRResultCacheEntry] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]
    private let ttlSeconds: Int64
    private let capacity: Int
    private let store: SQLiteStore?

    public init(ttlSeconds: Int64 = 30 * 24 * 60 * 60, capacity: Int = 4_096, store: SQLiteStore? = nil) {
        self.ttlSeconds = max(ttlSeconds, 60)
        self.capacity = max(capacity, 16)
        self.store = store
    }

    public func value(for key: String, now: Int64 = Helpers.now()) -> String? {
        guard var entry = self.entries[key] else {
            return self.persistentValue(for: key, now: now)
        }
        guard entry.expiresAt > now else {
            self.entries.removeValue(forKey: key)
            return nil
        }
        entry.touchedAt = now
        self.entries[key] = entry
        try? self.store?.touchOCRResultCacheEntry(imageHash: key, now: now)
        return entry.text
    }

    public func store(
        _ text: String,
        for key: String,
        mimeType: String = "",
        byteCount: Int = 0,
        now: Int64 = Helpers.now()
    ) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        let entry = OCRResultCacheEntry(
            text: trimmed,
            mimeType: mimeType,
            byteCount: max(0, byteCount),
            touchedAt: now,
            expiresAt: now + self.ttlSeconds
        )
        self.entries[key] = entry
        self.prune(now: now)
        try? self.store?.upsertOCRResultCacheEntry(imageHash: key, entry: entry, capacity: self.capacity)
    }

    func text(
        for key: String,
        mimeType: String,
        byteCount: Int,
        operation: @Sendable @escaping () async throws -> String
    ) async throws -> String {
        if let cached = self.value(for: key) {
            return cached
        }
        if let task = self.inFlight[key] {
            return try await task.value
        }

        let task = Task { try await operation() }
        self.inFlight[key] = task
        do {
            let text = try await task.value
            self.inFlight.removeValue(forKey: key)
            self.store(text, for: key, mimeType: mimeType, byteCount: byteCount)
            return text
        } catch {
            self.inFlight.removeValue(forKey: key)
            throw error
        }
    }

    func textWithStatus(
        for key: String,
        mimeType: String,
        byteCount: Int,
        operation: @Sendable @escaping () async throws -> String
    ) async throws -> (text: String, cacheHit: Bool) {
        if let cached = self.value(for: key) {
            return (cached, true)
        }
        if let task = self.inFlight[key] {
            return (try await task.value, true)
        }

        let task = Task { try await operation() }
        self.inFlight[key] = task
        do {
            let text = try await task.value
            self.inFlight.removeValue(forKey: key)
            self.store(text, for: key, mimeType: mimeType, byteCount: byteCount)
            return (text, false)
        } catch {
            self.inFlight.removeValue(forKey: key)
            throw error
        }
    }

    public func prune(now: Int64 = Helpers.now()) {
        self.entries = self.entries.filter { $0.value.expiresAt > now }
        _ = try? self.store?.pruneExpiredOCRResultCache(now: now)
        guard self.entries.count > self.capacity else { return }
        let overflow = self.entries.count - self.capacity
        let removable = self.entries
            .sorted { $0.value.touchedAt < $1.value.touchedAt }
            .prefix(overflow)
            .map(\.key)
        for key in removable {
            self.entries.removeValue(forKey: key)
        }
    }

    public func summary(now: Int64 = Helpers.now()) throws -> OCRCacheSummary {
        try self.store?.ocrResultCacheSummary(now: now) ?? OCRCacheSummary()
    }

    public func clear(_ request: ClearOCRCacheRequest, now: Int64 = Helpers.now()) throws -> ClearOCRCacheResult {
        let deleted = try self.store?.clearOCRResultCache(request, now: now) ?? 0
        if request.clearAll {
            for task in self.inFlight.values {
                task.cancel()
            }
            self.inFlight.removeAll()
            self.entries.removeAll()
        } else {
            self.entries = self.entries.filter { _, entry in
                let expiredMatches = request.expiredOnly && entry.expiresAt <= now
                let olderMatches = request.olderThanSeconds.map { entry.touchedAt < now - $0 } ?? false
                let shouldDelete = (request.expiredOnly || request.olderThanSeconds != nil)
                    && (!request.expiredOnly || expiredMatches)
                    && (request.olderThanSeconds == nil || olderMatches)
                return !shouldDelete
            }
        }
        return ClearOCRCacheResult(deletedCount: deleted, summary: try self.summary(now: now))
    }

    private func persistentValue(for key: String, now: Int64) -> String? {
        guard let persistent = try? self.store?.loadOCRResultCacheEntry(imageHash: key, now: now),
              persistent.expiresAt > now
        else {
            return nil
        }
        self.entries[key] = persistent
        return persistent.text
    }
}

public enum OCRImageContextSupport {
    public static func imageReferences(in request: [String: Any]) -> [OCRImageReference] {
        let input = request["input"] as? [[String: Any]] ?? []
        var references: [OCRImageReference] = []

        for item in input {
            guard ((item["type"] as? String) ?? "").lowercased() == "message",
                  ((item["role"] as? String) ?? "user").lowercased() == "user"
            else {
                continue
            }
            for block in self.contentBlocks(from: item["content"]) {
                guard let image = self.imageReference(from: block, index: references.count + 1) else {
                    continue
                }
                references.append(image)
            }
        }

        return references
    }

    public static func anthropicImageReferences(in request: [String: Any]) -> [OCRImageReference] {
        let messages = request["messages"] as? [[String: Any]] ?? []
        var references: [OCRImageReference] = []

        for message in messages {
            guard self.isUserAnthropicMessage(message) else {
                continue
            }
            for block in self.anthropicContentBlocks(from: message["content"]) {
                guard let image = self.anthropicImageReference(from: block, index: references.count + 1) else {
                    continue
                }
                references.append(image)
            }
        }

        return references
    }

    public static func geminiImageReferences(in request: [String: Any]) -> [OCRImageReference] {
        let contents = request["contents"] as? [[String: Any]] ?? []
        var references: [OCRImageReference] = []

        for content in contents {
            guard self.isUserGeminiContent(content) else {
                continue
            }
            for part in self.geminiParts(from: content["parts"]) {
                guard let image = self.geminiImageReference(from: part, index: references.count + 1) else {
                    continue
                }
                references.append(image)
            }
        }

        return references
    }

    public static func requestByInjectingOCRContext(
        into request: [String: Any],
        results: [OCRImageRecognitionResult]
    ) -> [String: Any] {
        let sortedResults = results.sorted { $0.index < $1.index }
        guard sortedResults.isEmpty == false,
              var input = request["input"] as? [[String: Any]]
        else {
            return request
        }

        let targetIndex = self.lastUserMessageIndexWithImage(in: input)
        guard let targetIndex else {
            return request
        }
        let originalText = self.messageText(from: input[targetIndex]["content"])
        let injectedText = self.injectedText(
            results: sortedResults,
            originalUserText: originalText
        )

        for index in input.indices {
            guard ((input[index]["type"] as? String) ?? "").lowercased() == "message" else {
                continue
            }
            let blocks = self.contentBlocks(from: input[index]["content"])
            let strippedBlocks = blocks.filter { self.imageReference(from: $0, index: 1) == nil }
            if index == targetIndex {
                input[index]["content"] = [[
                    "type": "input_text",
                    "text": injectedText,
                ]]
            } else {
                input[index]["content"] = strippedBlocks.isEmpty
                    ? [["type": "input_text", "text": self.messageText(from: input[index]["content"])]]
                    : strippedBlocks
            }
        }

        var updated = request
        updated["input"] = input
        return updated
    }

    public static func anthropicRequestByInjectingOCRContext(
        into request: [String: Any],
        results: [OCRImageRecognitionResult]
    ) -> [String: Any] {
        let sortedResults = results.sorted { $0.index < $1.index }
        guard sortedResults.isEmpty == false,
              var messages = request["messages"] as? [[String: Any]],
              let targetIndex = self.lastUserAnthropicMessageIndexWithImage(in: messages)
        else {
            return request
        }

        let originalText = self.anthropicMessageText(from: messages[targetIndex]["content"])
        let injectedText = self.injectedText(
            results: sortedResults,
            originalUserText: originalText
        )

        for index in messages.indices {
            guard self.isUserAnthropicMessage(messages[index]) else {
                continue
            }
            let blocks = self.anthropicContentBlocks(from: messages[index]["content"])
            let containsImage = blocks.contains { self.anthropicImageReference(from: $0, index: 1) != nil }
            guard containsImage else {
                continue
            }
            if index == targetIndex {
                messages[index]["content"] = [[
                    "type": "text",
                    "text": injectedText,
                ]]
            } else {
                let strippedBlocks = blocks.filter { self.anthropicImageReference(from: $0, index: 1) == nil }
                messages[index]["content"] = strippedBlocks.isEmpty
                    ? [["type": "text", "text": self.nonEmptyFallbackText(self.anthropicMessageText(from: messages[index]["content"]))]]
                    : strippedBlocks
            }
        }

        var updated = request
        updated["messages"] = messages
        return updated
    }

    public static func geminiRequestByInjectingOCRContext(
        into request: [String: Any],
        results: [OCRImageRecognitionResult]
    ) -> [String: Any] {
        let sortedResults = results.sorted { $0.index < $1.index }
        guard sortedResults.isEmpty == false,
              var contents = request["contents"] as? [[String: Any]],
              let targetIndex = self.lastUserGeminiContentIndexWithImage(in: contents)
        else {
            return request
        }

        let originalText = self.geminiContentText(from: contents[targetIndex]["parts"])
        let injectedText = self.injectedText(
            results: sortedResults,
            originalUserText: originalText
        )

        for index in contents.indices {
            guard self.isUserGeminiContent(contents[index]) else {
                continue
            }
            let parts = self.geminiParts(from: contents[index]["parts"])
            let containsImage = parts.contains { self.geminiImageReference(from: $0, index: 1) != nil }
            guard containsImage else {
                continue
            }
            if index == targetIndex {
                contents[index]["parts"] = [[
                    "text": injectedText,
                ]]
            } else {
                let strippedParts = parts.filter { self.geminiImageReference(from: $0, index: 1) == nil }
                contents[index]["parts"] = strippedParts.isEmpty
                    ? [["text": self.nonEmptyFallbackText(self.geminiContentText(from: contents[index]["parts"]))]]
                    : strippedParts
            }
        }

        var updated = request
        updated["contents"] = contents
        return updated
    }

    public static func injectedText(
        results: [OCRImageRecognitionResult],
        originalUserText: String
    ) -> String {
        let imageContext = results.sorted { $0.index < $1.index }.map { result in
            """
            [图片\(result.index) OCR识别结果]
            \(result.contextText)
            """
        }.joined(separator: "\n\n")
        let trimmedOriginal = originalUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        <image_ocr_context>
        \(imageContext)
        </image_ocr_context>

        用户原始消息：
        \(trimmedOriginal.isEmpty ? "（无文本）" : trimmedOriginal)
        """
    }

    private static func lastUserMessageIndexWithImage(in input: [[String: Any]]) -> Int? {
        for index in input.indices.reversed() {
            let item = input[index]
            guard ((item["type"] as? String) ?? "").lowercased() == "message",
                  ((item["role"] as? String) ?? "user").lowercased() == "user"
            else {
                continue
            }
            if self.contentBlocks(from: item["content"]).contains(where: { self.imageReference(from: $0, index: 1) != nil }) {
                return index
            }
        }
        return nil
    }

    private static func lastUserAnthropicMessageIndexWithImage(in messages: [[String: Any]]) -> Int? {
        for index in messages.indices.reversed() {
            let message = messages[index]
            guard self.isUserAnthropicMessage(message) else {
                continue
            }
            if self.anthropicContentBlocks(from: message["content"]).contains(where: { self.anthropicImageReference(from: $0, index: 1) != nil }) {
                return index
            }
        }
        return nil
    }

    private static func lastUserGeminiContentIndexWithImage(in contents: [[String: Any]]) -> Int? {
        for index in contents.indices.reversed() {
            let content = contents[index]
            guard self.isUserGeminiContent(content) else {
                continue
            }
            if self.geminiParts(from: content["parts"]).contains(where: { self.geminiImageReference(from: $0, index: 1) != nil }) {
                return index
            }
        }
        return nil
    }

    private static func contentBlocks(from content: Any?) -> [[String: Any]] {
        if let blocks = content as? [[String: Any]] {
            return blocks
        }
        if let text = content as? String {
            return [["type": "input_text", "text": text]]
        }
        return []
    }

    private static func messageText(from content: Any?) -> String {
        self.contentBlocks(from: content).compactMap { block -> String? in
            let type = ((block["type"] as? String) ?? "").lowercased()
            switch type {
            case "input_text", "output_text", "text":
                return block["text"] as? String
            case "refusal":
                return block["refusal"] as? String ?? block["text"] as? String
            default:
                return nil
            }
        }
        .joined(separator: "\n")
    }

    private static func imageReference(from block: [String: Any], index: Int) -> OCRImageReference? {
        let type = ((block["type"] as? String) ?? "").lowercased()
        guard type == "input_image" || type == "image_url" else {
            return nil
        }

        var url: String?
        var detail: String?
        if let imageURL = block["image_url"] as? String {
            url = imageURL
        } else if let imageURL = block["image_url"] as? [String: Any] {
            url = imageURL["url"] as? String
            detail = imageURL["detail"] as? String
        } else if let imageURL = block["image_url"] as? [String: String] {
            url = imageURL["url"]
            detail = imageURL["detail"]
        }
        if url == nil {
            url = block["url"] as? String
        }
        if detail == nil {
            detail = block["detail"] as? String
        }
        guard let trimmedURL = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmedURL.isEmpty == false
        else {
            return nil
        }
        return OCRImageReference(index: index, imageURL: trimmedURL, detail: detail)
    }

    private static func isUserAnthropicMessage(_ message: [String: Any]) -> Bool {
        ((message["role"] as? String) ?? "user").lowercased() == "user"
    }

    private static func anthropicContentBlocks(from content: Any?) -> [[String: Any]] {
        if let blocks = content as? [[String: Any]] {
            return blocks
        }
        if let text = content as? String {
            return [["type": "text", "text": text]]
        }
        return []
    }

    private static func anthropicMessageText(from content: Any?) -> String {
        self.anthropicContentBlocks(from: content).compactMap { block -> String? in
            guard ((block["type"] as? String) ?? "text").lowercased() == "text" else {
                return nil
            }
            return block["text"] as? String
        }.joined(separator: "\n")
    }

    private static func anthropicImageReference(from block: [String: Any], index: Int) -> OCRImageReference? {
        guard ((block["type"] as? String) ?? "").lowercased() == "image" else {
            return nil
        }
        guard let source = block["source"] as? [String: Any] else {
            return nil
        }
        let sourceType = ((source["type"] as? String) ?? "").lowercased()
        if sourceType == "base64" || source["data"] != nil {
            guard let data = (source["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  data.isEmpty == false
            else {
                return nil
            }
            let mediaType = self.trimmedString(source["media_type"] ?? source["mediaType"]) ?? "image/png"
            return OCRImageReference(index: index, imageURL: "data:\(mediaType);base64,\(data)")
        }
        if sourceType == "url" || source["url"] != nil {
            guard let url = (source["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  url.isEmpty == false
            else {
                return nil
            }
            return OCRImageReference(index: index, imageURL: url)
        }
        return nil
    }

    private static func isUserGeminiContent(_ content: [String: Any]) -> Bool {
        let role = ((content["role"] as? String) ?? "user").lowercased()
        return role == "user" || role == "tool"
    }

    private static func geminiParts(from raw: Any?) -> [[String: Any]] {
        raw as? [[String: Any]] ?? []
    }

    private static func geminiContentText(from raw: Any?) -> String {
        self.geminiParts(from: raw).compactMap { part -> String? in
            part["text"] as? String
        }.joined(separator: "\n")
    }

    private static func geminiImageReference(from part: [String: Any], index: Int) -> OCRImageReference? {
        if let inlineData = part["inlineData"] as? [String: Any]
            ?? part["inline_data"] as? [String: Any]
        {
            guard let data = (inlineData["data"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  data.isEmpty == false
            else {
                return nil
            }
            let mediaType = self.trimmedString(inlineData["mimeType"] ?? inlineData["mime_type"]) ?? "image/png"
            return OCRImageReference(index: index, imageURL: "data:\(mediaType);base64,\(data)")
        }

        if let fileData = part["fileData"] as? [String: Any]
            ?? part["file_data"] as? [String: Any]
        {
            guard let uri = self.trimmedString(fileData["fileUri"] ?? fileData["file_uri"]),
                  uri.isEmpty == false
            else {
                return nil
            }
            return OCRImageReference(index: index, imageURL: uri)
        }

        return nil
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonEmptyFallbackText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "（图片内容已汇总到 OCR 上下文。）" : trimmed
    }
}

public struct OCRImageProcessor: Sendable {
    private static let defaultMaxConcurrentRecognitions = 3

    private let cache: OCRResultCache
    private let store: SQLiteStore?
    private let localMLXRuntime: (any LocalMLXOCRServing)?

    public init(
        cache: OCRResultCache,
        store: SQLiteStore? = nil,
        localMLXRuntime: (any LocalMLXOCRServing)? = nil
    ) {
        self.cache = cache
        self.store = store
        self.localMLXRuntime = localMLXRuntime
    }

    public func pruneExpiredCache() async {
        await self.cache.prune()
    }

    public func cacheSummary() async throws -> OCRCacheSummary {
        try await self.cache.summary()
    }

    public func clearCache(_ request: ClearOCRCacheRequest) async throws -> ClearOCRCacheResult {
        try await self.cache.clear(request)
    }

    public func requestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        config: AppConfig,
        logContext: OCRRecognitionLogContext? = nil
    ) async -> [String: Any] {
        let ocrConfig = config.ocrModel
        let references = OCRImageContextSupport.imageReferences(in: request)
        guard references.isEmpty == false else {
            return request
        }
        guard ocrConfig.isReadyForRecognition else {
            self.recordSkippedLogs(for: references, ocrConfig: ocrConfig, logContext: logContext)
            return request
        }

        let results = await self.recognizeAll(
            references,
            ocrConfig: ocrConfig,
            networkConfig: config,
            logContext: logContext
        )
        return OCRImageContextSupport.requestByInjectingOCRContext(into: request, results: results)
    }

    public func anthropicRequestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        config: AppConfig,
        logContext: OCRRecognitionLogContext? = nil
    ) async -> [String: Any] {
        let ocrConfig = config.ocrModel
        let references = OCRImageContextSupport.anthropicImageReferences(in: request)
        guard references.isEmpty == false else {
            return request
        }
        guard ocrConfig.isReadyForRecognition else {
            self.recordSkippedLogs(for: references, ocrConfig: ocrConfig, logContext: logContext)
            return request
        }

        let results = await self.recognizeAll(
            references,
            ocrConfig: ocrConfig,
            networkConfig: config,
            logContext: logContext
        )
        return OCRImageContextSupport.anthropicRequestByInjectingOCRContext(into: request, results: results)
    }

    public func geminiRequestByApplyingOCRIfNeeded(
        _ request: [String: Any],
        config: AppConfig,
        logContext: OCRRecognitionLogContext? = nil
    ) async -> [String: Any] {
        let ocrConfig = config.ocrModel
        let references = OCRImageContextSupport.geminiImageReferences(in: request)
        guard references.isEmpty == false else {
            return request
        }
        guard ocrConfig.isReadyForRecognition else {
            self.recordSkippedLogs(for: references, ocrConfig: ocrConfig, logContext: logContext)
            return request
        }

        let results = await self.recognizeAll(
            references,
            ocrConfig: ocrConfig,
            networkConfig: config,
            logContext: logContext
        )
        return OCRImageContextSupport.geminiRequestByInjectingOCRContext(into: request, results: results)
    }

    private func recognizeAll(
        _ references: [OCRImageReference],
        ocrConfig: OCRModelConfig,
        networkConfig: AppConfig,
        logContext: OCRRecognitionLogContext?
    ) async -> [OCRImageRecognitionResult] {
        await withTaskGroup(of: OCRImageRecognitionResult.self) { group in
            var iterator = references.makeIterator()
            let maxConcurrentRecognitions = self.maxConcurrentRecognitions(for: ocrConfig)
            let workerCount = min(maxConcurrentRecognitions, references.count)
            for _ in 0..<workerCount {
                guard let reference = iterator.next() else { break }
                group.addTask {
                    await self.recognize(
                        reference,
                        ocrConfig: ocrConfig,
                        networkConfig: networkConfig,
                        logContext: logContext
                    )
                }
            }

            var results: [OCRImageRecognitionResult] = []
            for await result in group {
                results.append(result)
                if let reference = iterator.next() {
                    group.addTask {
                        await self.recognize(
                            reference,
                            ocrConfig: ocrConfig,
                            networkConfig: networkConfig,
                            logContext: logContext
                        )
                    }
                }
            }
            return results.sorted { $0.index < $1.index }
        }
    }

    private func maxConcurrentRecognitions(for ocrConfig: OCRModelConfig) -> Int {
        switch ocrConfig.provider {
        case .openAICompatible:
            return Self.defaultMaxConcurrentRecognitions
        case .localMLX:
            return ocrConfig.localMLX.maxConcurrentRecognitions
        }
    }

    private func recognize(
        _ reference: OCRImageReference,
        ocrConfig: OCRModelConfig,
        networkConfig: AppConfig,
        logContext: OCRRecognitionLogContext?
    ) async -> OCRImageRecognitionResult {
        let startedMS = Helpers.nowMilliseconds()
        do {
            let prepared = try await self.preparedImage(reference.imageURL, config: ocrConfig, networkConfig: networkConfig)
            let lookup = try await self.cache.textWithStatus(
                for: prepared.imageHash,
                mimeType: prepared.mimeType,
                byteCount: prepared.byteCount
            ) {
                try await self.performWithRetry(
                    attempts: 2,
                    debugMode: ocrConfig.debugMode
                ) {
                    try await self.performOCR(
                        reference: reference,
                        preparedImage: prepared,
                        ocrConfig: ocrConfig,
                        networkConfig: networkConfig
                    )
                }
            }
            self.recordRecognitionLog(
                reference: reference,
                prepared: prepared,
                ocrConfig: ocrConfig,
                logContext: logContext,
                status: lookup.cacheHit ? .cacheHit : .recognized,
                cacheHit: lookup.cacheHit,
                startedMS: startedMS,
                error: nil
            )
            return OCRImageRecognitionResult(index: reference.index, text: lookup.text)
        } catch {
            if ocrConfig.debugMode {
                print("[ocr] image \(reference.index) failed: \(error.localizedDescription)")
            }
            self.recordRecognitionLog(
                reference: reference,
                prepared: nil,
                ocrConfig: ocrConfig,
                logContext: logContext,
                status: .failed,
                cacheHit: false,
                startedMS: startedMS,
                error: error.localizedDescription
            )
            return OCRImageRecognitionResult(index: reference.index, error: error.localizedDescription)
        }
    }

    private func recordSkippedLogs(
        for references: [OCRImageReference],
        ocrConfig: OCRModelConfig,
        logContext: OCRRecognitionLogContext?
    ) {
        for reference in references {
            self.recordRecognitionLog(
                reference: reference,
                prepared: nil,
                ocrConfig: ocrConfig,
                logContext: logContext,
                status: .skipped,
                cacheHit: false,
                startedMS: Helpers.nowMilliseconds(),
                error: ocrConfig.enabled
                    ? "OCR 配置不完整，已跳过图片识别。"
                    : "OCR 未启用，已跳过图片识别。"
            )
        }
    }

    private func recordRecognitionLog(
        reference: OCRImageReference,
        prepared: OCRPreparedImage?,
        ocrConfig: OCRModelConfig,
        logContext: OCRRecognitionLogContext?,
        status: OCRRecognitionLogStatus,
        cacheHit: Bool,
        startedMS: Int64,
        error: String?
    ) {
        guard let store else {
            return
        }
        let context = logContext ?? OCRRecognitionLogContext()
        let entry = OCRRecognitionLogEntry(
            createdAt: Helpers.now(),
            endpoint: context.endpoint,
            accountKey: context.accountKey,
            accountLabel: context.accountLabel,
            requestedModel: context.requestedModel,
            ocrModel: ocrConfig.recognitionModelLabel,
            imageIndex: reference.index,
            imageHash: prepared?.imageHash,
            mimeType: prepared?.mimeType ?? "",
            byteCount: prepared?.byteCount ?? 0,
            status: status,
            cacheHit: cacheHit,
            latencyMS: max(0, Helpers.nowMilliseconds() - startedMS),
            errorSummary: error.map(self.safeErrorSummaryForLog)
        )
        do {
            try store.insertOCRRecognitionLog(entry)
        } catch {
            if ocrConfig.debugMode {
                print("[ocr] failed to write recognition log: \(error.localizedDescription)")
            }
        }
    }

    private func safeErrorSummaryForLog(_ error: String) -> String {
        var sanitized = error
        for (pattern, replacement) in [
            (#"data:image/[^ \n\r\t"'<>]+"#, "[redacted-image-data]"),
            (#"https?://[^ \n\r\t"'<>]+"#, "[redacted-url]"),
        ] {
            sanitized = (try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
                .map {
                    $0.stringByReplacingMatches(
                        in: sanitized,
                        range: NSRange(location: 0, length: sanitized.utf16.count),
                        withTemplate: replacement
                    )
                } ?? sanitized
        }
        return Helpers.truncate(sanitized, limit: 300)
    }

    private func performOCR(
        reference: OCRImageReference,
        preparedImage: OCRPreparedImage,
        ocrConfig: OCRModelConfig,
        networkConfig: AppConfig
    ) async throws -> String {
        switch ocrConfig.provider {
        case .openAICompatible:
            return try await self.performOpenAICompatibleOCR(
                reference: reference,
                preparedImage: preparedImage,
                ocrConfig: ocrConfig,
                networkConfig: networkConfig
            )
        case .localMLX:
            guard let localMLXRuntime else {
                throw LocalOCRModelError.unsupportedPlatform
            }
            return try await localMLXRuntime.recognize(
                LocalMLXOCRRequest(
                    prompt: ocrConfig.prompt,
                    imageURL: preparedImage.imageURL,
                    detail: reference.detail,
                    modelID: ocrConfig.localMLX.effectiveModelID(),
                    maxTokens: ocrConfig.localMLX.maxTokens,
                    timeout: ocrConfig.timeout
                ),
                config: ocrConfig,
                networkConfig: networkConfig
            )
        }
    }

    private func performOpenAICompatibleOCR(
        reference: OCRImageReference,
        preparedImage: OCRPreparedImage,
        ocrConfig: OCRModelConfig,
        networkConfig: AppConfig
    ) async throws -> String {
        let url = try OpenAICompatibleUpstream.chatCompletionsURL(
            from: ocrConfig.baseURL,
            providerPreset: .genericOpenAICompatible,
            baseURLMode: .exactAPIPrefix
        )
        var imageURLObject: [String: Any] = ["url": preparedImage.imageURL]
        if let detail = reference.detail, detail.isEmpty == false {
            imageURLObject["detail"] = detail
        }
        let body: [String: Any] = [
            "model": ocrConfig.model,
            "stream": false,
            "messages": [
                [
                    "role": "system",
                    "content": ocrConfig.prompt,
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": "请识别图片\(reference.index)的全部关键信息，并按系统要求输出。",
                        ],
                        [
                            "type": "image_url",
                            "image_url": imageURLObject,
                        ],
                    ],
                ],
            ],
            "max_tokens": 2_048,
            "temperature": 0,
        ]
        let requestBody = try JSONSerialization.data(withJSONObject: body)
        let headers = OpenAICompatibleUpstream.requestHeaders(
            apiKey: ocrConfig.apiKey,
            accept: "application/json",
            providerPreset: .genericOpenAICompatible
        )
        let response = try await self.withTimeout(seconds: ocrConfig.timeout) {
            try await HTTPClientFactory.request(
                config: networkConfig,
                url: url,
                method: .POST,
                headers: headers,
                body: requestBody
            )
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message("OCR 服务异常：\(response.statusCode) \(Helpers.truncate(response.bodyText))")
        }
        let payload = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] ?? [:]
        let text = self.extractChatCompletionText(from: payload)
        guard text.isEmpty == false else {
            throw ProxyError.message("OCR 返回为空")
        }
        return text
    }

    private func preparedImage(
        _ rawURL: String,
        config: OCRModelConfig,
        networkConfig: AppConfig
    ) async throws -> OCRPreparedImage {
        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            throw ProxyError.message("图片地址为空")
        }
        if trimmed.lowercased().hasPrefix("data:") {
            let parsed = try self.parseDataURL(trimmed)
            let imageHash = Helpers.sha256(parsed.data)
            let prepared = try self.preparedImageData(parsed.data, mimeType: parsed.mimeType, maxImageSize: config.maxImageSize)
            return OCRPreparedImage(
                imageHash: imageHash,
                mimeType: prepared.mimeType,
                byteCount: parsed.data.count,
                imageURL: "data:\(prepared.mimeType);base64,\(prepared.data.base64EncodedString())"
            )
        }
        guard trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") else {
            throw ProxyError.message("图片格式不支持：仅支持 data URL、http 或 https 图片。")
        }

        let response = try await self.withTimeout(seconds: config.timeout) {
            try await HTTPClientFactory.request(config: networkConfig, url: trimmed)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ProxyError.message("图片下载失败：HTTP \(response.statusCode)")
        }
        let mimeType = response.headers["content-type"]?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            ?? self.inferredImageMimeType(from: response.body)
        let imageHash = Helpers.sha256(response.body)
        let prepared = try self.preparedImageData(response.body, mimeType: mimeType, maxImageSize: config.maxImageSize)
        return OCRPreparedImage(
            imageHash: imageHash,
            mimeType: prepared.mimeType,
            byteCount: response.body.count,
            imageURL: "data:\(prepared.mimeType);base64,\(prepared.data.base64EncodedString())"
        )
    }

    private func preparedImageData(_ data: Data, mimeType: String, maxImageSize: Int) throws -> (mimeType: String, data: Data) {
        let normalizedMimeType = mimeType.lowercased()
        guard ["image/png", "image/jpeg", "image/webp", "image/gif"].contains(normalizedMimeType) else {
            throw ProxyError.message("图片格式不支持：\(mimeType)")
        }
        guard data.isEmpty == false else {
            throw ProxyError.message("图片内容为空")
        }
        if data.count <= maxImageSize {
            return (normalizedMimeType, data)
        }
        if let compressed = self.compressedImageData(data, maxImageSize: maxImageSize) {
            return compressed
        }
        throw ProxyError.message("图片超过 OCR 最大大小限制：\(data.count) bytes > \(maxImageSize) bytes")
    }

    private func compressedImageData(_ data: Data, maxImageSize: Int) -> (mimeType: String, data: Data)? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary) else {
            return nil
        }

        var maxPixelSize = 2_048
        while maxPixelSize >= 320 {
            let thumbnailOptions = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
                return nil
            }

            for quality in [0.82, 0.68, 0.54, 0.4] {
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
                    continue
                }
                CGImageDestinationAddImage(destination, image, [
                    kCGImageDestinationLossyCompressionQuality: quality,
                ] as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    continue
                }
                let compressed = output as Data
                if compressed.count <= maxImageSize {
                    return ("image/jpeg", compressed)
                }
            }

            maxPixelSize = Int(Double(maxPixelSize) * 0.72)
        }
        return nil
        #else
        return nil
        #endif
    }

    private func parseDataURL(_ value: String) throws -> (mimeType: String, data: Data) {
        guard let comma = value.firstIndex(of: ",") else {
            throw ProxyError.message("data URL 格式无效")
        }
        let header = String(value[..<comma]).lowercased()
        let encoded = String(value[value.index(after: comma)...])
        guard header.contains(";base64") else {
            throw ProxyError.message("data URL 必须使用 base64 图片内容")
        }
        let mimeType = header
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "application/octet-stream"
        guard let data = Data(base64Encoded: encoded) else {
            throw ProxyError.message("data URL base64 解码失败")
        }
        return (mimeType, data)
    }

    private func inferredImageMimeType(from data: Data) -> String {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return "image/png"
        }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return "image/jpeg"
        }
        if bytes.count >= 12,
           bytes[0..<4] == Array("RIFF".utf8)[0..<4],
           bytes[8..<12] == Array("WEBP".utf8)[0..<4]
        {
            return "image/webp"
        }
        if bytes.starts(with: Array("GIF".utf8)) {
            return "image/gif"
        }
        return "application/octet-stream"
    }

    private func extractChatCompletionText(from payload: [String: Any]) -> String {
        let choices = payload["choices"] as? [[String: Any]] ?? []
        let parts = choices.compactMap { choice -> String? in
            if let message = choice["message"] as? [String: Any] {
                if let text = message["content"] as? String {
                    return text
                }
                if let content = message["content"] as? [[String: Any]] {
                    return content.compactMap { $0["text"] as? String }.joined()
                }
            }
            return nil
        }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.isEmpty == false }
        return parts.joined(separator: "\n")
    }

    private func performWithRetry<T: Sendable>(
        attempts: Int,
        debugMode: Bool,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        for attempt in 1...max(attempts, 1) {
            do {
                return try await operation()
            } catch {
                lastError = error
                if debugMode {
                    print("[ocr] attempt \(attempt) failed: \(error.localizedDescription)")
                }
            }
        }
        throw lastError ?? ProxyError.message("OCR 请求失败")
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 1)) * 1_000_000_000)
                throw ProxyError.message("OCR 超时")
            }
            guard let value = try await group.next() else {
                throw ProxyError.message("OCR 超时")
            }
            group.cancelAll()
            return value
        }
    }
}
