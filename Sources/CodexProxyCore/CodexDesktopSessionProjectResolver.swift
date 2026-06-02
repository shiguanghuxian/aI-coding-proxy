import Foundation

public struct CodexDesktopSessionProject: Sendable, Equatable {
    public var sessionID: String
    public var cwd: String

    public init(sessionID: String, cwd: String) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.cwd = CodexProjectRouteRule.normalizedProjectPath(cwd)
    }
}

public final class CodexDesktopSessionProjectResolver: @unchecked Sendable {
    private struct CacheEntry {
        var sessionID: String
        var cwd: String
        var expiresAt: Int64
    }

    private let sessionsDirectory: URL
    private let fileManager: FileManager
    private let ttlSeconds: Int64
    private let maxFilesToScan: Int
    private let maxLineBytes = 64 * 1024
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var negativeCache: [String: Int64] = [:]

    public init(
        sessionsDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true),
        fileManager: FileManager = .default,
        ttlSeconds: Int64 = 30,
        maxFilesToScan: Int = 120
    ) {
        self.sessionsDirectory = sessionsDirectory
        self.fileManager = fileManager
        self.ttlSeconds = ttlSeconds
        self.maxFilesToScan = maxFilesToScan
    }

    public func project(forSessionID rawSessionID: String?, now: Int64 = Helpers.now()) -> CodexDesktopSessionProject? {
        let sessionID = rawSessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard sessionID.isEmpty == false else { return nil }

        if let cached = self.cachedProject(sessionID: sessionID, now: now) {
            return cached
        }
        if self.hasRecentMiss(sessionID: sessionID, now: now) {
            return nil
        }
        guard let scanned = self.scanProject(sessionID: sessionID) else {
            self.storeMiss(sessionID: sessionID, now: now)
            return nil
        }
        self.store(project: scanned, now: now)
        return scanned
    }

    private func cachedProject(sessionID: String, now: Int64) -> CodexDesktopSessionProject? {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let entry = self.cache[sessionID] else { return nil }
        guard entry.expiresAt > now else {
            self.cache.removeValue(forKey: sessionID)
            return nil
        }
        return CodexDesktopSessionProject(sessionID: entry.sessionID, cwd: entry.cwd)
    }

    private func hasRecentMiss(sessionID: String, now: Int64) -> Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        guard let expiresAt = self.negativeCache[sessionID] else { return false }
        guard expiresAt > now else {
            self.negativeCache.removeValue(forKey: sessionID)
            return false
        }
        return true
    }

    private func storeMiss(sessionID: String, now: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        let negativeTTL = max(Int64(1), min(self.ttlSeconds, Int64(2)))
        self.negativeCache[sessionID] = now + negativeTTL
    }

    private func store(project: CodexDesktopSessionProject, now: Int64) {
        self.lock.lock()
        defer { self.lock.unlock() }
        self.negativeCache.removeValue(forKey: project.sessionID)
        self.cache[project.sessionID] = CacheEntry(
            sessionID: project.sessionID,
            cwd: project.cwd,
            expiresAt: now + self.ttlSeconds
        )
    }

    private func scanProject(sessionID: String) -> CodexDesktopSessionProject? {
        guard self.fileManager.fileExists(atPath: self.sessionsDirectory.path) else {
            return nil
        }

        let urls = self.recentSessionFiles()
        for url in urls {
            guard let project = self.project(in: url, matching: sessionID) else {
                continue
            }
            return project
        }
        return nil
    }

    private func recentSessionFiles() -> [URL] {
        guard let enumerator = self.fileManager.enumerator(
            at: self.sessionsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [(url: URL, modifiedAt: Date)] = []
        for case let url as URL in enumerator {
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt {
                    return lhs.modifiedAt > rhs.modifiedAt
                }
                return lhs.url.path > rhs.url.path
            }
            .prefix(self.maxFilesToScan)
            .map(\.url)
    }

    private func project(in url: URL, matching sessionID: String) -> CodexDesktopSessionProject? {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }

        var buffer = Data()
        let newline = UInt8(ascii: "\n")
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024),
                  chunk.isEmpty == false
            else {
                break
            }
            buffer.append(chunk)
            while let newlineIndex = buffer.firstIndex(of: newline) {
                let line = buffer[..<newlineIndex]
                if let project = self.project(fromLine: Data(line), matching: sessionID) {
                    return project
                }
                if self.isSessionMetadataLine(Data(line)) {
                    return nil
                }
                buffer.removeSubrange(...newlineIndex)
            }
            if buffer.count > self.maxLineBytes {
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if buffer.isEmpty == false {
            return self.project(fromLine: buffer, matching: sessionID)
        }
        return nil
    }

    private func isSessionMetadataLine(_ data: Data) -> Bool {
        guard data.count <= self.maxLineBytes,
              data.range(of: Data(#""session_meta""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else {
            return false
        }
        return type == "session_meta"
    }

    private func project(fromLine data: Data, matching sessionID: String) -> CodexDesktopSessionProject? {
        guard data.count <= self.maxLineBytes,
              data.range(of: Data(#""session_meta""#.utf8)) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              type == "session_meta",
              let payload = object["payload"] as? [String: Any],
              let id = Self.trimmedString(payload["id"]),
              id == sessionID,
              Self.isCodexDesktopSession(payload),
              let cwd = Self.trimmedString(payload["cwd"])
        else {
            return nil
        }
        return CodexDesktopSessionProject(sessionID: sessionID, cwd: cwd)
    }

    private static func isCodexDesktopSession(_ payload: [String: Any]) -> Bool {
        if let originator = self.trimmedString(payload["originator"]),
           originator.caseInsensitiveCompare("Codex Desktop") == .orderedSame
        {
            return true
        }
        if let source = self.trimmedString(payload["source"]),
           source.caseInsensitiveCompare("desktop") == .orderedSame
        {
            return true
        }
        return false
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let value else { return nil }
        let string: String
        if let raw = value as? String {
            string = raw
        } else {
            string = String(describing: value)
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
