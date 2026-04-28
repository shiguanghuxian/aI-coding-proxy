import Foundation

#if os(macOS)
import Security
#endif

#if canImport(CryptoKit)
import CryptoKit
#elseif canImport(Crypto)
import Crypto
#endif

#if os(macOS)
internal protocol SecretStoreKeychainAdapter: Sendable {
    func read(service: String, account: String) throws -> Data?
    func write(service: String, account: String, data: Data) throws
    func delete(service: String, account: String) throws
}

internal struct KeychainOperationError: Error, LocalizedError {
    enum Operation: String {
        case read
        case add
        case update
        case delete
    }

    var operation: Operation
    var status: OSStatus
    var account: String

    var errorDescription: String? {
        "Keychain \(self.operation.rawValue) failed (\(self.status)) for \(self.account)"
    }

    var isAccessFailure: Bool {
        switch self.status {
        case errSecAuthFailed, errSecInteractionNotAllowed, errSecNotAvailable:
            return true
        default:
            return false
        }
    }
}

private struct SystemKeychainAdapter: SecretStoreKeychainAdapter {
    func read(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainOperationError(operation: .read, status: status, account: account)
        }
        return item as? Data
    }

    func write(service: String, account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var createQuery = query
            createQuery[kSecValueData as String] = data
            let createStatus = SecItemAdd(createQuery as CFDictionary, nil)
            guard createStatus == errSecSuccess else {
                throw KeychainOperationError(operation: .add, status: createStatus, account: account)
            }
            return
        }
        guard updateStatus == errSecSuccess else {
            throw KeychainOperationError(operation: .update, status: updateStatus, account: account)
        }
    }

    func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainOperationError(operation: .delete, status: status, account: account)
        }
    }
}
#endif

public final class SecretStore: @unchecked Sendable {
    private enum TextSecretRecoveryPolicy {
        case generateWhenMissing
        case generateWhenMissingOrKeychainUnavailable
    }

    private let dataDirectory: URL
    private let serviceName = "io.shiguanghuxian.codex-proxy"
    #if os(macOS)
    private let keychainAdapter: any SecretStoreKeychainAdapter
    private let keychainEnabledOverride: Bool?
    #endif

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        #if os(macOS)
        self.keychainAdapter = SystemKeychainAdapter()
        self.keychainEnabledOverride = nil
        #endif
    }

    #if os(macOS)
    init(
        dataDirectory: URL,
        keychainAdapter: any SecretStoreKeychainAdapter,
        keychainEnabledOverride: Bool? = nil
    ) {
        self.dataDirectory = dataDirectory
        self.keychainAdapter = keychainAdapter
        self.keychainEnabledOverride = keychainEnabledOverride
    }
    #endif

    private var keychainEnabled: Bool {
        #if os(macOS)
        if let keychainEnabledOverride = self.keychainEnabledOverride {
            return keychainEnabledOverride
        }
        let raw = ProcessInfo.processInfo.environment["CODEX_PROXY_DISABLE_KEYCHAIN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case "1", "true", "yes", "on":
            return false
        default:
            return true
        }
        #else
        return false
        #endif
    }

    public func masterKey() throws -> SymmetricKey {
        #if os(macOS)
        let url = Paths.keyFileURL(in: self.dataDirectory)
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            return SymmetricKey(data: existing)
        }
        if self.keychainEnabled, let existing = try self.readKeychainItem(account: "master-key") {
            try Helpers.writeFile(url, data: existing)
            return SymmetricKey(data: existing)
        }
        let data = Helpers.secureRandomData(length: 32)
        try Helpers.writeFile(url, data: data)
        if self.keychainEnabled {
            try self.writeKeychainItem(account: "master-key", data: data)
        }
        return SymmetricKey(data: data)
        #else
        let url = Paths.keyFileURL(in: self.dataDirectory)
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            return SymmetricKey(data: existing)
        }
        let data = Helpers.secureRandomData(length: 32)
        try Helpers.writeFile(url, data: data)
        return SymmetricKey(data: data)
        #endif
    }

    public func proxyAPIKey() throws -> String {
        try self.readOrCreateTextSecret(
            account: "proxy-api-key",
            fallbackURL: Paths.proxyAPIKeyURL(in: self.dataDirectory),
            recoveryPolicy: .generateWhenMissing,
            generatedValue: { "sk-local-" + Helpers.randomToken(length: 36) }
        )
    }

    public func adminToken() throws -> String {
        try self.readOrCreateTextSecret(
            account: "admin-token",
            fallbackURL: Paths.adminTokenURL(in: self.dataDirectory),
            recoveryPolicy: .generateWhenMissing,
            generatedValue: { "adm-local-" + Helpers.randomToken(length: 36) }
        )
    }

    public func mihomoSubscriptionURL() throws -> String? {
        try self.readOptionalFileTextSecret(
            fallbackURL: Paths.mihomoSubscriptionURLURL(in: self.dataDirectory)
        )
    }

    public func setMihomoSubscriptionURL(_ value: String?) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            try self.clearFileTextSecret(
                fallbackURL: Paths.mihomoSubscriptionURLURL(in: self.dataDirectory)
            )
            return
        }
        try self.persistFileTextSecret(
            value: trimmed,
            fallbackURL: Paths.mihomoSubscriptionURLURL(in: self.dataDirectory)
        )
    }

    public func mihomoControllerSecret() throws -> String {
        try self.readOrCreateTextSecret(
            account: "mihomo-controller-secret",
            fallbackURL: Paths.mihomoControllerSecretURL(in: self.dataDirectory),
            recoveryPolicy: .generateWhenMissingOrKeychainUnavailable,
            generatedValue: { Helpers.randomToken(length: 48) }
        )
    }

    public func rotateProxyAPIKey() throws -> String {
        let value = "sk-local-" + Helpers.randomToken(length: 36)
        try self.persistTextSecret(account: "proxy-api-key", value: value, fallbackURL: Paths.proxyAPIKeyURL(in: self.dataDirectory))
        return value
    }

    public func rotateAdminToken() throws -> String {
        let value = "adm-local-" + Helpers.randomToken(length: 36)
        try self.persistTextSecret(account: "admin-token", value: value, fallbackURL: Paths.adminTokenURL(in: self.dataDirectory))
        return value
    }

    func persistMirroredProxyAPIKey(_ value: String) throws {
        try self.persistTextSecret(
            account: "proxy-api-key",
            value: value,
            fallbackURL: Paths.proxyAPIKeyURL(in: self.dataDirectory)
        )
    }

    func persistMirroredAdminToken(_ value: String) throws {
        try self.persistTextSecret(
            account: "admin-token",
            value: value,
            fallbackURL: Paths.adminTokenURL(in: self.dataDirectory)
        )
    }

    public func saveAnthropicOAuthSecret(_ secret: AnthropicOAuthSecretBundle, ref: String = UUID().uuidString) throws -> String {
        let data = try Helpers.encodeJSON(secret, pretty: false)
        let fallbackURL = Paths.anthropicOAuthSecretURL(ref: ref, in: self.dataDirectory)
        try self.persistMirroredSecretData(
            account: self.anthropicOAuthAccountName(ref: ref),
            data: data,
            fallbackURL: fallbackURL
        )
        return ref
    }

    public func loadAnthropicOAuthSecret(ref: String) throws -> AnthropicOAuthSecretBundle {
        let fallbackURL = Paths.anthropicOAuthSecretURL(ref: ref, in: self.dataDirectory)
        let data = try self.loadMirroredSecretData(
            account: self.anthropicOAuthAccountName(ref: ref),
            fallbackURL: fallbackURL
        )
        return try Helpers.readJSON(AnthropicOAuthSecretBundle.self, from: data)
    }

    public func loadAnthropicOAuthSecretIfPresent(ref: String) -> AnthropicOAuthSecretBundle? {
        try? self.loadAnthropicOAuthSecret(ref: ref)
    }

    public func deleteAnthropicOAuthSecret(ref: String) throws {
        try self.deleteMirroredSecretData(
            account: self.anthropicOAuthAccountName(ref: ref),
            fallbackURL: Paths.anthropicOAuthSecretURL(ref: ref, in: self.dataDirectory)
        )
    }

    public func saveGeminiOAuthSecret(_ secret: GeminiOAuthSecretBundle, ref: String = UUID().uuidString) throws -> String {
        let data = try Helpers.encodeJSON(secret, pretty: false)
        let fallbackURL = Paths.geminiOAuthSecretURL(ref: ref, in: self.dataDirectory)
        try self.persistMirroredSecretData(
            account: self.geminiOAuthAccountName(ref: ref),
            data: data,
            fallbackURL: fallbackURL
        )
        return ref
    }

    public func loadGeminiOAuthSecret(ref: String) throws -> GeminiOAuthSecretBundle {
        let fallbackURL = Paths.geminiOAuthSecretURL(ref: ref, in: self.dataDirectory)
        let data = try self.loadMirroredSecretData(
            account: self.geminiOAuthAccountName(ref: ref),
            fallbackURL: fallbackURL
        )
        return try Helpers.readJSON(GeminiOAuthSecretBundle.self, from: data)
    }

    public func loadGeminiOAuthSecretIfPresent(ref: String) -> GeminiOAuthSecretBundle? {
        try? self.loadGeminiOAuthSecret(ref: ref)
    }

    public func deleteGeminiOAuthSecret(ref: String) throws {
        try self.deleteMirroredSecretData(
            account: self.geminiOAuthAccountName(ref: ref),
            fallbackURL: Paths.geminiOAuthSecretURL(ref: ref, in: self.dataDirectory)
        )
    }

    private func readOptionalTextSecret(account: String, fallbackURL: URL) throws -> String? {
        if let existing = try? String(contentsOf: fallbackURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty
        {
            #if os(macOS)
            self.bestEffortWriteKeychainItem(account: account, data: Data(existing.utf8))
            #endif
            return existing
        }
        #if os(macOS)
        if self.keychainEnabled,
           let existing = try self.readKeychainItem(account: account),
           let text = String(data: existing, encoding: .utf8),
           !text.isEmpty
        {
            try Helpers.writeFile(fallbackURL, data: Data(text.utf8))
            return text
        }
        #endif
        return nil
    }

    private func readOrCreateTextSecret(
        account: String,
        fallbackURL: URL,
        recoveryPolicy: TextSecretRecoveryPolicy,
        generatedValue: () -> String
    ) throws -> String {
        do {
            if let existing = try self.readOptionalTextSecret(account: account, fallbackURL: fallbackURL) {
                return existing
            }
        } catch {
            #if os(macOS)
            if recoveryPolicy == .generateWhenMissingOrKeychainUnavailable,
               self.isRecoverableKeychainAccessFailure(error)
            {
                let generated = generatedValue()
                try self.persistTextSecret(account: account, value: generated, fallbackURL: fallbackURL)
                return generated
            }
            #endif
            throw error
        }
        let generated = generatedValue()
        try self.persistTextSecret(account: account, value: generated, fallbackURL: fallbackURL)
        return generated
    }

    private func loadMirroredSecretData(account: String, fallbackURL: URL) throws -> Data {
        if let existing = self.readOptionalFileData(fallbackURL: fallbackURL) {
            #if os(macOS)
            self.bestEffortWriteKeychainItem(account: account, data: existing)
            #endif
            return existing
        }
        #if os(macOS)
        if self.keychainEnabled,
           let existing = try self.readKeychainItem(account: account)
        {
            try Helpers.ensureDirectory(fallbackURL.deletingLastPathComponent())
            try Helpers.writeFile(fallbackURL, data: existing)
            return existing
        }
        #endif
        return try Data(contentsOf: fallbackURL)
    }

    private func persistTextSecret(account: String, value: String, fallbackURL: URL) throws {
        try self.persistMirroredSecretData(
            account: account,
            data: Data(value.utf8),
            fallbackURL: fallbackURL
        )
    }

    private func clearTextSecret(account: String, fallbackURL: URL) throws {
        try self.deleteMirroredSecretData(account: account, fallbackURL: fallbackURL)
    }

    private func readOptionalFileTextSecret(fallbackURL: URL) throws -> String? {
        if let existing = try? String(contentsOf: fallbackURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           !existing.isEmpty
        {
            return existing
        }
        return nil
    }

    private func persistFileTextSecret(value: String, fallbackURL: URL) throws {
        try Helpers.writeFile(fallbackURL, data: Data(value.utf8))
    }

    private func clearFileTextSecret(fallbackURL: URL) throws {
        try? FileManager.default.removeItem(at: fallbackURL)
    }

    private func anthropicOAuthAccountName(ref: String) -> String {
        "anthropic-oauth-\(ref)"
    }

    private func geminiOAuthAccountName(ref: String) -> String {
        "gemini-oauth-\(ref)"
    }

    private func readOptionalFileData(fallbackURL: URL) -> Data? {
        guard let existing = try? Data(contentsOf: fallbackURL), existing.isEmpty == false else {
            return nil
        }
        return existing
    }

    private func persistMirroredSecretData(account: String, data: Data, fallbackURL: URL) throws {
        try Helpers.ensureDirectory(fallbackURL.deletingLastPathComponent())
        try Helpers.writeFile(fallbackURL, data: data)
        #if os(macOS)
        self.bestEffortWriteKeychainItem(account: account, data: data)
        #endif
    }

    private func deleteMirroredSecretData(account: String, fallbackURL: URL) throws {
        try? FileManager.default.removeItem(at: fallbackURL)
        #if os(macOS)
        self.bestEffortDeleteKeychainItem(account: account)
        #endif
    }

    #if os(macOS)
    private func readKeychainItem(account: String) throws -> Data? {
        try self.keychainAdapter.read(service: self.serviceName, account: account)
    }

    private func writeKeychainItem(account: String, data: Data) throws {
        try self.keychainAdapter.write(service: self.serviceName, account: account, data: data)
    }

    private func deleteKeychainItem(account: String) throws {
        try self.keychainAdapter.delete(service: self.serviceName, account: account)
    }

    private func bestEffortWriteKeychainItem(account: String, data: Data) {
        guard self.keychainEnabled else { return }
        try? self.writeKeychainItem(account: account, data: data)
    }

    private func bestEffortDeleteKeychainItem(account: String) {
        guard self.keychainEnabled else { return }
        try? self.deleteKeychainItem(account: account)
    }

    private func isRecoverableKeychainAccessFailure(_ error: Error) -> Bool {
        guard let keychainError = error as? KeychainOperationError else {
            return false
        }
        return keychainError.isAccessFailure
    }
    #endif
}

public enum CryptoBox {
    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw ProxyError.message("Unable to combine encrypted payload.")
        }
        return combined
    }

    public static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(box, using: key)
    }
}
