import Foundation

public struct ChatCompletionsReasoningContentCacheEntry: Codable, Sendable, Equatable {
    public var sessionKeyHash: String
    public var accountKey: String
    public var model: String
    public var assistantFingerprint: String
    public var reasoningContent: String
    public var updatedAt: Int64

    public init(
        sessionKeyHash: String,
        accountKey: String,
        model: String,
        assistantFingerprint: String,
        reasoningContent: String,
        updatedAt: Int64
    ) {
        self.sessionKeyHash = sessionKeyHash
        self.accountKey = accountKey
        self.model = model
        self.assistantFingerprint = assistantFingerprint
        self.reasoningContent = reasoningContent
        self.updatedAt = updatedAt
    }
}

public actor ChatCompletionsReasoningContentCache {
    private struct StoreFile: Codable {
        var entries: [ChatCompletionsReasoningContentCacheEntry]
    }

    public static let defaultRetentionSeconds: Int64 = 30 * 24 * 60 * 60

    private let url: URL
    private let retentionSeconds: Int64
    private var entries: [String: ChatCompletionsReasoningContentCacheEntry]

    public init(
        dataDirectory: URL,
        retentionSeconds: Int64 = ChatCompletionsReasoningContentCache.defaultRetentionSeconds,
        now: Int64 = Helpers.now()
    ) {
        self.url = Paths.chatCompletionsReasoningContentCacheURL(in: dataDirectory)
        self.retentionSeconds = retentionSeconds
        self.entries = Self.loadEntries(from: self.url, now: now, retentionSeconds: retentionSeconds)
        Self.persist(Array(self.entries.values), to: self.url)
    }

    public func reasoningContent(
        sessionKeyHash: String,
        accountKey: String,
        model: String,
        assistantFingerprint: String,
        now: Int64 = Helpers.now()
    ) -> String? {
        self.prune(now: now)
        let key = Self.key(
            sessionKeyHash: sessionKeyHash,
            accountKey: accountKey,
            model: model,
            assistantFingerprint: assistantFingerprint
        )
        guard let entry = self.entries[key], now - entry.updatedAt <= self.retentionSeconds else {
            self.entries.removeValue(forKey: key)
            return nil
        }
        return entry.reasoningContent
    }

    public func store(
        reasoningContent: String,
        sessionKeyHash: String,
        accountKey: String,
        model: String,
        assistantFingerprint: String,
        now: Int64 = Helpers.now()
    ) {
        let trimmed = reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.prune(now: now)
        let key = Self.key(
            sessionKeyHash: sessionKeyHash,
            accountKey: accountKey,
            model: model,
            assistantFingerprint: assistantFingerprint
        )
        self.entries[key] = .init(
            sessionKeyHash: sessionKeyHash,
            accountKey: accountKey,
            model: model,
            assistantFingerprint: assistantFingerprint,
            reasoningContent: trimmed,
            updatedAt: now
        )
        self.persist()
    }

    public func entriesForTesting(now: Int64 = Helpers.now()) -> [ChatCompletionsReasoningContentCacheEntry] {
        self.prune(now: now)
        return self.entries.values.sorted {
            ($0.sessionKeyHash, $0.accountKey, $0.model, $0.assistantFingerprint)
                < ($1.sessionKeyHash, $1.accountKey, $1.model, $1.assistantFingerprint)
        }
    }

    private func prune(now: Int64) {
        let before = self.entries.count
        self.entries = self.entries.filter { _, entry in
            now - entry.updatedAt <= self.retentionSeconds
        }
        if self.entries.count != before {
            self.persist()
        }
    }

    private func persist() {
        Self.persist(Array(self.entries.values), to: self.url)
    }

    private static func persist(
        _ entries: [ChatCompletionsReasoningContentCacheEntry],
        to url: URL
    ) {
        let store = StoreFile(entries: entries)
        guard let data = try? Helpers.encodeJSON(store, pretty: true) else {
            return
        }
        try? Helpers.writeFile(url, data: data, posixMode: 0o600)
    }

    private static func loadEntries(
        from url: URL,
        now: Int64,
        retentionSeconds: Int64
    ) -> [String: ChatCompletionsReasoningContentCacheEntry] {
        guard let data = try? Data(contentsOf: url),
              let store = try? Helpers.readJSON(StoreFile.self, from: data)
        else {
            return [:]
        }

        return store.entries.reduce(into: [:]) { result, entry in
            guard now - entry.updatedAt <= retentionSeconds else { return }
            let key = self.key(
                sessionKeyHash: entry.sessionKeyHash,
                accountKey: entry.accountKey,
                model: entry.model,
                assistantFingerprint: entry.assistantFingerprint
            )
            result[key] = entry
        }
    }

    private static func key(
        sessionKeyHash: String,
        accountKey: String,
        model: String,
        assistantFingerprint: String
    ) -> String {
        [
            sessionKeyHash,
            accountKey,
            model,
            assistantFingerprint,
        ].joined(separator: "\u{1f}")
    }
}
