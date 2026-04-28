import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

protocol ManagedProxyRuntimeControlling: Sendable {
    func snapshot(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot
    func applyConfiguration(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot
    func effectiveProxySettings(config: AppConfig, subscriptionURL: String?) async throws -> OutboundProxySettings
    func effectiveProxySettingsForAccountNode(
        name: String,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> OutboundProxySettings
    func updateSubscription(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot
    func selectNode(
        name: String,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> ManagedProxySnapshot
    func healthcheck(
        nodeName: String?,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> ManagedProxySnapshot
    func reconcileAccountNodeListeners(
        nodeNames: [String],
        config: AppConfig,
        subscriptionURL: String?
    ) async throws
    func stop() async
}

enum ManagedProxyAccountNodeResolutionError: Error, Sendable {
    case nodeUnavailable(String)
    case listenerUnavailable(String)
}

public actor ManagedProxyRuntime {
    public static let providerName = ManagedProxyConfigSummary.defaultProviderName
    public static let selectGroupName = "CodexProxySelect"
    public static let defaultMixedPort = 8890
    public static let defaultControllerPort = 9090
    public static let defaultHealthcheckURL = ManagedProxyConfigSummary.defaultHealthcheckURL
    public static let defaultHealthcheckTimeoutMS = 8_000
    internal static let defaultBatchHealthcheckConcurrency = 10
    internal static let fallbackHealthcheckURLs = [
        "http://cp.cloudflare.com/generate_204",
        "http://www.gstatic.com/generate_204",
        "https://www.gstatic.com/generate_204",
    ]

    private struct RuntimeStateRecord: Codable, Sendable {
        var pid: Int32?
        var mixedPort: Int
        var controllerPort: Int
        var startedAt: Int64
    }

    private struct NodeListenerPortMappingRecord: Codable, Sendable {
        var portsByNodeName: [String: Int]
    }

    private struct ManagedProxyNodeListenerDefinition: Codable, Equatable, Sendable {
        var nodeName: String
        var groupName: String
        var listenerName: String
        var port: Int
    }

    private struct RuntimeConfigFingerprint: Equatable, Sendable {
        var subscriptionURL: String
        var mixedPort: Int
        var controllerPort: Int
        var updateIntervalHours: Int
        var healthcheckURL: String
        var accountNodeListeners: [ManagedProxyNodeListenerDefinition]
    }

    private struct ControllerSnapshot {
        var provider: [String: Any]
        var group: [String: Any]
    }

    private struct NodeHealthcheckResult: Sendable {
        let index: Int
        let nodeName: String
        let status: ManagedProxyNodeHealthcheckStatus
        let delayMS: Int64?
        let checkedAt: Int64
        let failureSummary: String?
    }

    private struct ControllerNodeDelayResponse: Decodable, Sendable {
        let delay: Int64
    }

    public struct NodeHealthcheckProbeResponse: Sendable, Equatable {
        public let statusCode: Int
        public let latencyMS: Int64

        public init(statusCode: Int, latencyMS: Int64) {
            self.statusCode = statusCode
            self.latencyMS = max(latencyMS, 1)
        }
    }

    private let dataDirectory: URL
    private let secretStore: SecretStore
    private let session: URLSession
    private let nodeHealthcheckProbeHandler: (@Sendable (String, String, OutboundProxySettings, Int) async throws -> NodeHealthcheckProbeResponse)?
    private let healthcheckTimestampProvider: @Sendable () -> Int64
    private let batchHealthcheckConcurrencyLimit: Int
    private var process: Process?
    private var desiredAccountNodeListenerNames: [String] = []
    private var appliedAccountNodeListeners: [ManagedProxyNodeListenerDefinition] = []
    private var lastAppliedConfigFingerprint: RuntimeConfigFingerprint?

    public init(dataDirectory: URL, secretStore: SecretStore) {
        self.dataDirectory = dataDirectory
        self.secretStore = secretStore
        self.session = Self.makeSession()
        self.nodeHealthcheckProbeHandler = nil
        self.healthcheckTimestampProvider = Helpers.now
        self.batchHealthcheckConcurrencyLimit = Self.defaultBatchHealthcheckConcurrency
    }

    init(
        dataDirectory: URL,
        secretStore: SecretStore,
        session: URLSession,
        nodeHealthcheckProbeHandler: (@Sendable (String, String, OutboundProxySettings, Int) async throws -> NodeHealthcheckProbeResponse)? = nil,
        healthcheckTimestampProvider: @escaping @Sendable () -> Int64,
        batchHealthcheckConcurrencyLimit: Int = ManagedProxyRuntime.defaultBatchHealthcheckConcurrency
    ) {
        self.dataDirectory = dataDirectory
        self.secretStore = secretStore
        self.session = session
        self.nodeHealthcheckProbeHandler = nodeHealthcheckProbeHandler
        self.healthcheckTimestampProvider = healthcheckTimestampProvider
        self.batchHealthcheckConcurrencyLimit = max(batchHealthcheckConcurrencyLimit, 1)
    }

    public func snapshot(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
        let rawSubscriptionURL = Self.normalizedSubscriptionURL(subscriptionURL)
        let summary = Self.normalizedManagedProxySummary(
            config.managedProxySummary,
            subscriptionConfigured: rawSubscriptionURL != nil
        )
        let normalizedURL: String?
        do {
            normalizedURL = try Self.validatedSubscriptionURL(subscriptionURL)
        } catch {
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: rawSubscriptionURL,
                summary: summary,
                lastError: error.localizedDescription
            )
        }

        guard let normalizedURL else {
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: nil,
                summary: summary,
                lastError: "订阅地址未配置。"
            )
        }

        guard let runtimeState = self.loadRuntimeState() else {
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: normalizedURL,
                summary: summary,
                lastError: self.lastRuntimeErrorSummary() ?? "内置代理内核尚未启动。"
            )
        }

        let secret = try self.secretStore.mihomoControllerSecret()
        guard let controllerSnapshot = try await self.fetchControllerSnapshotIfReachable(
            runtimeState: runtimeState,
            secret: secret
        ) else {
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: normalizedURL,
                summary: summary,
                mixedPort: runtimeState.mixedPort,
                controllerPort: runtimeState.controllerPort,
                lastError: self.lastRuntimeErrorSummary() ?? "内置代理 controller 不可达。"
            )
        }

        return self.makeSnapshot(
            mode: config.outboundProxyMode,
            subscriptionURL: normalizedURL,
            summary: summary,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot
        )
    }

    public func applyConfiguration(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
        let rawSubscriptionURL = Self.normalizedSubscriptionURL(subscriptionURL)
        let summary = Self.normalizedManagedProxySummary(
            config.managedProxySummary,
            subscriptionConfigured: rawSubscriptionURL != nil
        )
        let normalizedURL: String?
        do {
            normalizedURL = try Self.validatedSubscriptionURL(subscriptionURL)
        } catch {
            await self.stop()
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: rawSubscriptionURL,
                summary: summary,
                lastError: error.localizedDescription
            )
        }

        guard let normalizedURL else {
            await self.stop()
            return self.baseSnapshot(
                mode: config.outboundProxyMode,
                subscriptionURL: nil,
                summary: summary,
                lastError: "订阅地址未配置。"
            )
        }

        let secret = try self.secretStore.mihomoControllerSecret()
        return try await self.reconfigureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            desiredNodeNames: self.desiredAccountNodeListenerNames
        )
    }

    public func effectiveProxySettings(config: AppConfig, subscriptionURL: String?) async throws -> OutboundProxySettings {
        guard config.outboundProxyMode == .subscription else {
            return .init()
        }

        guard let normalizedURL = try Self.validatedSubscriptionURL(subscriptionURL) else {
            throw ProxyError.message("订阅代理不可用：尚未配置订阅地址。")
        }

        let secret = try self.secretStore.mihomoControllerSecret()
        let runtimeState = try await self.ensureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret
        )
        let controllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        let snapshot = self.makeSnapshot(
            mode: .subscription,
            subscriptionURL: normalizedURL,
            summary: Self.normalizedManagedProxySummary(
                config.managedProxySummary,
                subscriptionConfigured: true
            ),
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot
        )

        guard snapshot.currentNodeName?.isEmpty == false else {
            throw ProxyError.message(
                snapshot.lastError ?? "订阅代理不可用：当前没有可用节点。"
            )
        }

        return OutboundProxySettings(
            scheme: .http,
            host: "127.0.0.1",
            port: runtimeState.mixedPort
        )
    }

    public func effectiveProxySettingsForAccountNode(
        name: String,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> OutboundProxySettings {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            throw ProxyError.message("请选择一个有效节点。")
        }

        if self.desiredAccountNodeListenerNames.contains(trimmedName) == false {
            self.desiredAccountNodeListenerNames = Self.normalizedAccountNodeNames(
                self.desiredAccountNodeListenerNames + [trimmedName]
            )
        }

        let normalizedURL = try Self.requireSubscriptionURL(subscriptionURL)
        let secret = try self.secretStore.mihomoControllerSecret()
        let runtimeState = try await self.ensureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            enforceSelectedNode: false
        )
        let controllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        let listenerDefinitions = try await self.applyAccountNodeListenerConfiguration(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot,
            desiredNodeNames: self.desiredAccountNodeListenerNames
        )

        if listenerDefinitions.contains(where: { $0.nodeName == trimmedName }) == false {
            let availableNodeNames = Set(
                self.nodes(
                    from: controllerSnapshot.provider,
                    currentNodeName: controllerSnapshot.group["now"] as? String,
                    pinnedNodeName: config.managedProxySummary.selectedNodeName
                ).map(\.name)
            )
            if availableNodeNames.contains(trimmedName) == false {
                throw ManagedProxyAccountNodeResolutionError.nodeUnavailable(trimmedName)
            }
            throw ManagedProxyAccountNodeResolutionError.listenerUnavailable(trimmedName)
        }

        guard let definition = listenerDefinitions.first(where: { $0.nodeName == trimmedName }) else {
            throw ManagedProxyAccountNodeResolutionError.listenerUnavailable(trimmedName)
        }

        return OutboundProxySettings(
            scheme: .http,
            host: "127.0.0.1",
            port: definition.port
        )
    }

    public func updateSubscription(config: AppConfig, subscriptionURL: String?) async throws -> ManagedProxySnapshot {
        let normalizedURL = try Self.requireSubscriptionURL(subscriptionURL)
        let secret = try self.secretStore.mihomoControllerSecret()
        let runtimeState = try await self.ensureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret
        )

        _ = try await self.controllerRequest(
            method: "PUT",
            runtimeState: runtimeState,
            secret: secret,
            path: "/providers/proxies/\(Self.providerName)"
        )
        guard let controllerSnapshot = try await self.waitForProviderAvailability(
            runtimeState: runtimeState,
            secret: secret
        ) else {
            throw ProxyError.message("订阅已刷新，但 provider 仍未返回任何节点。")
        }
        return try await self.reconfigureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            desiredNodeNames: self.desiredAccountNodeListenerNames,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot
        )
    }

    public func reconcileAccountNodeListeners(
        nodeNames: [String],
        config: AppConfig,
        subscriptionURL: String?
    ) async throws {
        self.desiredAccountNodeListenerNames = Self.normalizedAccountNodeNames(nodeNames)
        let runtimeState = self.loadRuntimeState()
        _ = try self.resolveAccountNodeListenerDefinitions(
            desiredNodeNames: self.desiredAccountNodeListenerNames,
            availableNodeNames: [],
            reservedPorts: [
                runtimeState?.mixedPort ?? Self.defaultMixedPort,
                runtimeState?.controllerPort ?? Self.defaultControllerPort,
            ]
        )

        let normalizedURL: String?
        do {
            normalizedURL = try Self.validatedSubscriptionURL(subscriptionURL)
        } catch {
            self.appliedAccountNodeListeners = []
            self.lastAppliedConfigFingerprint = nil
            await self.stop()
            return
        }

        guard let normalizedURL else {
            self.appliedAccountNodeListeners = []
            self.lastAppliedConfigFingerprint = nil
            await self.stop()
            return
        }

        let secret = try self.secretStore.mihomoControllerSecret()
        _ = try await self.reconfigureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            desiredNodeNames: self.desiredAccountNodeListenerNames
        )
    }

    public func selectNode(
        name: String,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> ManagedProxySnapshot {
        let normalizedURL = try Self.requireSubscriptionURL(subscriptionURL)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedName.isEmpty == false else {
            throw ProxyError.message("请选择一个有效节点。")
        }

        let secret = try self.secretStore.mihomoControllerSecret()
        let runtimeState = try await self.ensureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret
        )
        let controllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        let availableNodes = self.nodes(
            from: controllerSnapshot.provider,
            currentNodeName: controllerSnapshot.group["now"] as? String,
            pinnedNodeName: config.managedProxySummary.selectedNodeName
        )
        guard availableNodes.contains(where: { $0.name == trimmedName }) else {
            throw ProxyError.message("未找到要切换的节点：\(trimmedName)")
        }

        _ = try await self.controllerRequest(
            method: "PUT",
            runtimeState: runtimeState,
            secret: secret,
            path: "/proxies/\(Self.encodedPathComponent(Self.selectGroupName))",
            body: try Helpers.encodeJSON(["name": trimmedName])
        )

        let snapshot = try await self.snapshot(config: config, subscriptionURL: normalizedURL)
        guard snapshot.currentNodeName == trimmedName else {
            throw ProxyError.message("节点切换未生效，请稍后重试。")
        }
        return snapshot
    }

    public func healthcheck(
        nodeName: String?,
        config: AppConfig,
        subscriptionURL: String?
    ) async throws -> ManagedProxySnapshot {
        let normalizedURL = try Self.requireSubscriptionURL(subscriptionURL)
        let secret = try self.secretStore.mihomoControllerSecret()
        let runtimeState = try await self.ensureRuntime(
            config: config,
            subscriptionURL: normalizedURL,
            secret: secret,
            enforceSelectedNode: false
        )
        let controllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        let summary = Self.normalizedManagedProxySummary(
            config.managedProxySummary,
            subscriptionConfigured: true
        )
        let baselineSnapshot = self.makeSnapshot(
            mode: config.outboundProxyMode,
            subscriptionURL: normalizedURL,
            summary: summary,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot
        )
        let targetNodeNames = try self.healthcheckTargetNodeNames(
            requestedNodeName: nodeName,
            controllerSnapshot: controllerSnapshot,
            pinnedNodeName: config.managedProxySummary.selectedNodeName
        )
        let baseline = Dictionary(
            uniqueKeysWithValues: baselineSnapshot.nodes.map {
                ($0.name, (delay: $0.lastDelayMS, timestamp: $0.lastHealthcheckAt))
            }
        )
        let directResults = await self.batchNodeHealthcheckResults(
            nodeNames: targetNodeNames,
            runtimeState: runtimeState,
            secret: secret,
            healthcheckURLs: Self.healthcheckCandidateURLs(primaryURL: summary.healthcheckURL)
        )
        let refreshedSnapshot = await self.refreshedHealthcheckSnapshot(
            config: config,
            subscriptionURL: normalizedURL,
            runtimeState: runtimeState,
            secret: secret,
            summary: summary,
            fallbackSnapshot: baselineSnapshot
        )
        let reconciledResults = Self.healthcheckResults(
            directResults,
            reconciledWith: refreshedSnapshot,
            baseline: baseline
        )

        return Self.snapshot(
            refreshedSnapshot,
            applyingHealthcheckResults: reconciledResults,
            baseline: baseline,
            feedbackDetail: Self.healthcheckFeedbackDetail(from: reconciledResults)
        )
    }

    public func stop() async {
        let staleState = self.loadRuntimeState()

        if let process = self.process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        self.process = nil

        if let pid = staleState?.pid {
            Self.terminateProcess(pid)
        }

        self.appliedAccountNodeListeners = []
        self.lastAppliedConfigFingerprint = nil
        try? FileManager.default.removeItem(at: Paths.mihomoRuntimeStateURL(in: self.dataDirectory))
    }

    private func reconfigureRuntime(
        config: AppConfig,
        subscriptionURL: String,
        secret: String,
        desiredNodeNames: [String],
        runtimeState existingRuntimeState: RuntimeStateRecord? = nil,
        controllerSnapshot existingControllerSnapshot: ControllerSnapshot? = nil
    ) async throws -> ManagedProxySnapshot {
        let runtimeState: RuntimeStateRecord
        if let existingRuntimeState {
            runtimeState = existingRuntimeState
        } else {
            runtimeState = try await self.ensureRuntime(
                config: config,
                subscriptionURL: subscriptionURL,
                secret: secret
            )
        }

        let controllerSnapshot: ControllerSnapshot
        if let existingControllerSnapshot {
            controllerSnapshot = existingControllerSnapshot
        } else {
            controllerSnapshot = try await self.fetchControllerSnapshot(
                runtimeState: runtimeState,
                secret: secret
            )
        }
        let appliedListeners = try await self.applyAccountNodeListenerConfiguration(
            config: config,
            subscriptionURL: subscriptionURL,
            secret: secret,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot,
            desiredNodeNames: desiredNodeNames
        )
        self.appliedAccountNodeListeners = appliedListeners

        let refreshedControllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        let finalControllerSnapshot = try await self.enforceNodeIfNeeded(
            name: config.managedProxySummary.selectedNodeName,
            runtimeState: runtimeState,
            secret: secret,
            controllerSnapshot: refreshedControllerSnapshot
        )
        return self.makeSnapshot(
            mode: config.outboundProxyMode,
            subscriptionURL: subscriptionURL,
            summary: Self.normalizedManagedProxySummary(
                config.managedProxySummary,
                subscriptionConfigured: true
            ),
            runtimeState: runtimeState,
            controllerSnapshot: finalControllerSnapshot
        )
    }

    private func applyAccountNodeListenerConfiguration(
        config: AppConfig,
        subscriptionURL: String,
        secret: String,
        runtimeState: RuntimeStateRecord,
        controllerSnapshot: ControllerSnapshot,
        desiredNodeNames: [String]
    ) async throws -> [ManagedProxyNodeListenerDefinition] {
        let currentNodeName = (controllerSnapshot.group["now"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let availableNodeNames = Set(
            self.nodes(
                from: controllerSnapshot.provider,
                currentNodeName: currentNodeName,
                pinnedNodeName: config.managedProxySummary.selectedNodeName
            ).map(\.name)
        )
        let listenerDefinitions = try self.resolveAccountNodeListenerDefinitions(
            desiredNodeNames: desiredNodeNames,
            availableNodeNames: availableNodeNames,
            reservedPorts: [runtimeState.mixedPort, runtimeState.controllerPort]
        )
        let fingerprint = RuntimeConfigFingerprint(
            subscriptionURL: subscriptionURL,
            mixedPort: runtimeState.mixedPort,
            controllerPort: runtimeState.controllerPort,
            updateIntervalHours: max(1, config.managedProxySummary.autoUpdateIntervalHours),
            healthcheckURL: config.managedProxySummary.healthcheckURL,
            accountNodeListeners: listenerDefinitions
        )

        guard fingerprint != self.lastAppliedConfigFingerprint else {
            return listenerDefinitions
        }

        try self.writeConfig(
            subscriptionURL: subscriptionURL,
            secret: secret,
            mixedPort: runtimeState.mixedPort,
            controllerPort: runtimeState.controllerPort,
            updateIntervalHours: fingerprint.updateIntervalHours,
            healthcheckURL: fingerprint.healthcheckURL,
            accountNodeListeners: listenerDefinitions
        )
        try await self.reloadConfiguration(
            runtimeState: runtimeState,
            secret: secret
        )
        _ = try await self.waitForProviderAvailability(
            runtimeState: runtimeState,
            secret: secret
        )
        self.lastAppliedConfigFingerprint = fingerprint
        return listenerDefinitions
    }

    private func configureNodeListeners(
        desiredNodeNames: [String],
        preferredCurrentNodeName: String?,
        config: AppConfig,
        subscriptionURL: String,
        secret: String,
        runtimeState: RuntimeStateRecord,
        controllerSnapshot: ControllerSnapshot? = nil
    ) async throws -> ControllerSnapshot {
        let resolvedControllerSnapshot: ControllerSnapshot
        if let controllerSnapshot {
            resolvedControllerSnapshot = controllerSnapshot
        } else {
            resolvedControllerSnapshot = try await self.fetchControllerSnapshot(
                runtimeState: runtimeState,
                secret: secret
            )
        }

        let appliedListeners = try await self.applyAccountNodeListenerConfiguration(
            config: config,
            subscriptionURL: subscriptionURL,
            secret: secret,
            runtimeState: runtimeState,
            controllerSnapshot: resolvedControllerSnapshot,
            desiredNodeNames: desiredNodeNames
        )
        self.appliedAccountNodeListeners = appliedListeners

        let refreshedControllerSnapshot = try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
        return try await self.enforceNodeIfNeeded(
            name: preferredCurrentNodeName,
            runtimeState: runtimeState,
            secret: secret,
            controllerSnapshot: refreshedControllerSnapshot
        )
    }

    private func ensureRuntime(
        config: AppConfig,
        subscriptionURL: String,
        secret: String,
        enforceSelectedNode: Bool = true
    ) async throws -> RuntimeStateRecord {
        let previousState = self.loadRuntimeState()
        if let runtimeState = self.loadRuntimeState(),
           let controllerSnapshot = try await self.fetchControllerSnapshotIfReachable(
               runtimeState: runtimeState,
               secret: secret
           )
        {
            if enforceSelectedNode {
                try await self.enforceSelectedNodeIfNeeded(
                    config: config,
                    runtimeState: runtimeState,
                    secret: secret,
                    controllerSnapshot: controllerSnapshot
                )
            }
            return runtimeState
        }

        await self.stop()

        let preferredMixedPort = previousState?.mixedPort ?? Self.defaultMixedPort
        let preferredControllerPort = previousState?.controllerPort ?? Self.defaultControllerPort
        let mixedPort = try Self.findAvailablePort(preferred: preferredMixedPort)
        var controllerPort = try Self.findAvailablePort(preferred: preferredControllerPort)
        if controllerPort == mixedPort {
            controllerPort = try Self.findAvailablePort(preferred: 0)
        }

        try self.writeConfig(
            subscriptionURL: subscriptionURL,
            secret: secret,
            mixedPort: mixedPort,
            controllerPort: controllerPort,
            updateIntervalHours: max(
                1,
                config.managedProxySummary.autoUpdateIntervalHours
            ),
            healthcheckURL: config.managedProxySummary.healthcheckURL,
            accountNodeListeners: self.appliedAccountNodeListeners
        )

        let binaryURL = try self.resolveBinaryURL()
        let stdoutHandle = try self.openLogHandle(at: Paths.mihomoStdoutLogURL(in: self.dataDirectory))
        let stderrHandle = try self.openLogHandle(at: Paths.mihomoStderrLogURL(in: self.dataDirectory))

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "-d", Paths.mihomoDirectoryURL(in: self.dataDirectory).path,
            "-f", Paths.mihomoConfigURL(in: self.dataDirectory).path,
        ]
        process.currentDirectoryURL = Paths.mihomoDirectoryURL(in: self.dataDirectory)
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        try process.run()

        let runtimeState = RuntimeStateRecord(
            pid: Int32(process.processIdentifier),
            mixedPort: mixedPort,
            controllerPort: controllerPort,
            startedAt: Helpers.now()
        )

        self.process = process
        try self.saveRuntimeState(runtimeState)
        self.lastAppliedConfigFingerprint = RuntimeConfigFingerprint(
            subscriptionURL: subscriptionURL,
            mixedPort: mixedPort,
            controllerPort: controllerPort,
            updateIntervalHours: max(1, config.managedProxySummary.autoUpdateIntervalHours),
            healthcheckURL: config.managedProxySummary.healthcheckURL,
            accountNodeListeners: self.appliedAccountNodeListeners
        )
        try await self.waitForControllerAvailability(runtimeState: runtimeState, secret: secret, process: process)
        let controllerSnapshot = try await self.waitForProviderAvailability(
            runtimeState: runtimeState,
            secret: secret
        )

        if let controllerSnapshot, enforceSelectedNode {
            try await self.enforceSelectedNodeIfNeeded(
                config: config,
                runtimeState: runtimeState,
                secret: secret,
                controllerSnapshot: controllerSnapshot
            )
        }

        return runtimeState
    }

    private func fetchControllerSnapshotIfReachable(
        runtimeState: RuntimeStateRecord,
        secret: String
    ) async throws -> ControllerSnapshot? {
        guard try await self.controllerReachable(runtimeState: runtimeState, secret: secret) else {
            return nil
        }
        return try await self.fetchControllerSnapshot(runtimeState: runtimeState, secret: secret)
    }

    private func fetchControllerSnapshot(
        runtimeState: RuntimeStateRecord,
        secret: String
    ) async throws -> ControllerSnapshot {
        let provider = try await self.controllerJSON(
            runtimeState: runtimeState,
            secret: secret,
            path: "/providers/proxies/\(Self.providerName)"
        )
        let group = try await self.controllerJSON(
            runtimeState: runtimeState,
            secret: secret,
            path: "/proxies/\(Self.encodedPathComponent(Self.selectGroupName))"
        )
        return ControllerSnapshot(
            provider: self.providerPayload(from: provider),
            group: self.proxyPayload(from: group)
        )
    }

    private func controllerReachable(
        runtimeState: RuntimeStateRecord,
        secret: String
    ) async throws -> Bool {
        do {
            _ = try await self.controllerRequest(
                method: "GET",
                runtimeState: runtimeState,
                secret: secret,
                path: "/proxies/\(Self.encodedPathComponent(Self.selectGroupName))"
            )
            return true
        } catch {
            return false
        }
    }

    private func enforceSelectedNodeIfNeeded(
        config: AppConfig,
        runtimeState: RuntimeStateRecord,
        secret: String,
        controllerSnapshot: ControllerSnapshot
    ) async throws {
        _ = try await self.enforceNodeIfNeeded(
            name: config.managedProxySummary.selectedNodeName,
            runtimeState: runtimeState,
            secret: secret,
            controllerSnapshot: controllerSnapshot
        )
    }

    private func enforceNodeIfNeeded(
        name: String?,
        runtimeState: RuntimeStateRecord,
        secret: String,
        controllerSnapshot: ControllerSnapshot
    ) async throws -> ControllerSnapshot {
        let desiredNodeName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard desiredNodeName.isEmpty == false else {
            return controllerSnapshot
        }

        let currentNodeName = (controllerSnapshot.group["now"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if currentNodeName == desiredNodeName {
            return controllerSnapshot
        }

        let nodes = self.nodes(
            from: controllerSnapshot.provider,
            currentNodeName: currentNodeName,
            pinnedNodeName: nil
        )
        guard nodes.contains(where: { $0.name == desiredNodeName }) else {
            return controllerSnapshot
        }

        _ = try await self.controllerRequest(
            method: "PUT",
            runtimeState: runtimeState,
            secret: secret,
            path: "/proxies/\(Self.encodedPathComponent(Self.selectGroupName))",
            body: try Helpers.encodeJSON(["name": desiredNodeName])
        )
        return try await self.fetchControllerSnapshot(
            runtimeState: runtimeState,
            secret: secret
        )
    }

    private func waitForControllerAvailability(
        runtimeState: RuntimeStateRecord,
        secret: String,
        process: Process
    ) async throws {
        for _ in 0..<40 {
            if try await self.controllerReachable(runtimeState: runtimeState, secret: secret) {
                return
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(for: .milliseconds(250))
        }

        let summary = self.lastRuntimeErrorSummary() ?? "mihomo controller 启动失败。"
        await self.stop()
        throw ProxyError.message(summary)
    }

    private func waitForProviderAvailability(
        runtimeState: RuntimeStateRecord,
        secret: String
    ) async throws -> ControllerSnapshot? {
        for _ in 0..<24 {
            if let snapshot = try await self.fetchControllerSnapshotIfReachable(
                runtimeState: runtimeState,
                secret: secret
            ) {
                let nodes = self.nodes(
                    from: snapshot.provider,
                    currentNodeName: snapshot.group["now"] as? String,
                    pinnedNodeName: nil
                )
                if !nodes.isEmpty {
                    return snapshot
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private func controllerRequest(
        method: String,
        runtimeState: RuntimeStateRecord,
        secret: String,
        path: String,
        pathIsPercentEncoded: Bool = false,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = runtimeState.controllerPort
        if pathIsPercentEncoded {
            components.percentEncodedPath = path
        } else {
            components.path = path
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw ProxyError.message("构造 mihomo controller URL 失败。")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await self.session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProxyError.message("mihomo controller 未返回有效 HTTP 响应。")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProxyError.message(
                detail.isEmpty ? "mihomo controller 请求失败：HTTP \(httpResponse.statusCode)" : detail
            )
        }
        return (data, httpResponse)
    }

    private func controllerJSON(
        runtimeState: RuntimeStateRecord,
        secret: String,
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> [String: Any] {
        let response = try await self.controllerRequest(
            method: "GET",
            runtimeState: runtimeState,
            secret: secret,
            path: path,
            queryItems: queryItems
        )
        guard !response.data.isEmpty else { return [:] }
        return try JSONSerialization.jsonObject(with: response.data) as? [String: Any] ?? [:]
    }

    private func providerPayload(from raw: [String: Any]) -> [String: Any] {
        if let providers = raw["providers"] as? [String: Any],
           let provider = providers[Self.providerName] as? [String: Any] {
            return provider
        }
        if let provider = raw["provider"] as? [String: Any] {
            return provider
        }
        return raw
    }

    private func refreshedHealthcheckSnapshot(
        config: AppConfig,
        subscriptionURL: String,
        runtimeState: RuntimeStateRecord,
        secret: String,
        summary: ManagedProxyConfigSummary,
        fallbackSnapshot: ManagedProxySnapshot
    ) async -> ManagedProxySnapshot {
        guard
            let controllerSnapshot = try? await self.fetchControllerSnapshotIfReachable(
                runtimeState: runtimeState,
                secret: secret
            )
        else {
            return fallbackSnapshot
        }
        return self.makeSnapshot(
            mode: config.outboundProxyMode,
            subscriptionURL: subscriptionURL,
            summary: summary,
            runtimeState: runtimeState,
            controllerSnapshot: controllerSnapshot
        )
    }

    private func proxyPayload(from raw: [String: Any]) -> [String: Any] {
        if let proxies = raw["proxies"] as? [String: Any],
           let group = proxies[Self.selectGroupName] as? [String: Any] {
            return group
        }
        return raw
    }

    private func makeSnapshot(
        mode: OutboundProxyMode,
        subscriptionURL: String?,
        summary: ManagedProxyConfigSummary,
        runtimeState: RuntimeStateRecord,
        controllerSnapshot: ControllerSnapshot
    ) -> ManagedProxySnapshot {
        let currentNodeName = (controllerSnapshot.group["now"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedNodeName = summary.selectedNodeName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPinnedNodeName = pinnedNodeName.isEmpty ? nil : pinnedNodeName

        let nodes = self.nodes(
            from: controllerSnapshot.provider,
            currentNodeName: currentNodeName,
            pinnedNodeName: resolvedPinnedNodeName
        )
        let currentNodeAvailable = currentNodeName.map { name in
            nodes.contains(where: { $0.name == name })
        } ?? false
        let pinnedNodeAvailable = resolvedPinnedNodeName.map { name in
            nodes.contains(where: { $0.name == name })
        } ?? false

        let runtimePresentation: ManagedProxyRuntimeState = currentNodeAvailable ? .running : .degraded
        let lastError: String?
        if currentNodeAvailable == false {
            lastError = nodes.isEmpty
                ? "订阅已配置，但 provider 尚未返回任何节点。"
                : "订阅已配置，但当前没有可用的活动节点。"
        } else if let resolvedPinnedNodeName, !pinnedNodeAvailable {
            lastError = "订阅已配置，但固定节点 \(resolvedPinnedNodeName) 已失效或不存在，请重新选择。"
        } else {
            lastError = nil
        }

        return ManagedProxySnapshot(
            mode: mode,
            subscriptionConfigured: subscriptionURL != nil,
            subscriptionURL: subscriptionURL,
            providerName: summary.providerName,
            autoUpdateIntervalHours: summary.autoUpdateIntervalHours,
            healthcheckURL: summary.healthcheckURL,
            runtimeState: runtimePresentation,
            controllerReachable: true,
            mixedPort: runtimeState.mixedPort,
            controllerPort: runtimeState.controllerPort,
            currentNodeName: currentNodeName,
            pinnedNodeName: resolvedPinnedNodeName,
            pinnedNodeAvailable: pinnedNodeAvailable,
            providerUpdatedAt: Self.timestamp(from: controllerSnapshot.provider["updatedAt"])
                ?? Self.timestamp(from: controllerSnapshot.provider["updated_at"]),
            listeners: self.managedProxyListeners(
                mixedPort: runtimeState.mixedPort,
                currentNodeName: currentNodeName,
                nodeListeners: self.appliedAccountNodeListeners
            ),
            nodes: nodes,
            lastError: lastError,
            subscriptionUserinfo: Self.subscriptionUserinfo(from: controllerSnapshot.provider)
        )
    }

    private func baseSnapshot(
        mode: OutboundProxyMode,
        subscriptionURL: String?,
        summary: ManagedProxyConfigSummary,
        mixedPort: Int? = nil,
        controllerPort: Int? = nil,
        lastError: String? = nil
    ) -> ManagedProxySnapshot {
        let pinnedNodeName = summary.selectedNodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        return ManagedProxySnapshot(
            mode: mode,
            subscriptionConfigured: subscriptionURL != nil,
            subscriptionURL: subscriptionURL,
            providerName: summary.providerName,
            autoUpdateIntervalHours: summary.autoUpdateIntervalHours,
            healthcheckURL: summary.healthcheckURL,
            runtimeState: .stopped,
            controllerReachable: false,
            mixedPort: mixedPort,
            controllerPort: controllerPort,
            currentNodeName: nil,
            pinnedNodeName: pinnedNodeName.isEmpty ? nil : pinnedNodeName,
            pinnedNodeAvailable: false,
            providerUpdatedAt: nil,
            listeners: [],
            nodes: [],
            lastError: lastError,
            subscriptionUserinfo: nil
        )
    }

    private func managedProxyListeners(
        mixedPort: Int,
        currentNodeName: String?,
        nodeListeners: [ManagedProxyNodeListenerDefinition]
    ) -> [ManagedProxyListener] {
        var listeners: [ManagedProxyListener] = []
        if mixedPort > 0 {
            listeners.append(
                ManagedProxyListener(
                    kind: .mixedPort,
                    listenHost: "127.0.0.1",
                    port: mixedPort,
                    nodeName: currentNodeName
                )
            )
        }
        listeners.append(
            contentsOf: nodeListeners.map {
                ManagedProxyListener(
                    kind: .nodeListener,
                    listenHost: "127.0.0.1",
                    port: $0.port,
                    nodeName: $0.nodeName
                )
            }
        )
        return listeners
    }

    private func nodes(
        from provider: [String: Any],
        currentNodeName: String?,
        pinnedNodeName: String?
    ) -> [ManagedProxyNode] {
        let list: [[String: Any]]
        if let proxies = provider["proxies"] as? [[String: Any]] {
            list = proxies
        } else if let proxies = provider["proxies"] as? [String: [String: Any]] {
            list = proxies.map { key, value in
                var item = value
                if item["name"] == nil {
                    item["name"] = key
                }
                return item
            }
        } else {
            list = []
        }

        let currentNodeName = currentNodeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pinnedNodeName = pinnedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.sortedNodes(
            list.compactMap { item in
                let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else { return nil }
                guard Self.isSubscriptionMetadataNodeName(name) == false else { return nil }
                let latestHistory = Self.latestHistoryEntry(from: item["history"])
                return ManagedProxyNode(
                    name: name,
                    type: (item["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown",
                    isCurrent: currentNodeName == name,
                    isPinned: pinnedNodeName == name,
                    alive: item["alive"] as? Bool,
                    lastDelayMS: latestHistory.delay,
                    lastHealthcheckAt: latestHistory.timestamp
                )
            }
        )
    }

    private func writeConfig(
        subscriptionURL: String,
        secret: String,
        mixedPort: Int,
        controllerPort: Int,
        updateIntervalHours: Int,
        healthcheckURL: String,
        accountNodeListeners: [ManagedProxyNodeListenerDefinition]
    ) throws {
        let runtimeDirectory = Paths.mihomoDirectoryURL(in: self.dataDirectory)
        try Helpers.ensureDirectory(runtimeDirectory)
        try Helpers.ensureDirectory(Paths.mihomoProvidersDirectoryURL(in: self.dataDirectory))
        try Helpers.ensureDirectory(Paths.mihomoCacheDirectoryURL(in: self.dataDirectory))

        var lines: [String] = [
            "allow-lan: false",
            "bind-address: \"127.0.0.1\"",
            "mode: rule",
            "log-level: info",
            "mixed-port: \(mixedPort)",
            "external-controller: \"127.0.0.1:\(controllerPort)\"",
            "secret: \(Self.yamlQuoted(secret))",
            "profile:",
            "  store-selected: true",
            "proxy-providers:",
            "  \(Self.providerName):",
            "    type: http",
            "    url: \(Self.yamlQuoted(subscriptionURL))",
            "    path: \(Self.yamlQuoted(Paths.mihomoProviderStateURL(in: self.dataDirectory).path))",
            "    interval: \(updateIntervalHours * 3600)",
            "    health-check:",
            "      enable: true",
            "      url: \(Self.yamlQuoted(healthcheckURL))",
            "      interval: \(updateIntervalHours * 3600)",
            "proxy-groups:",
            "  - name: \(Self.yamlQuoted(Self.selectGroupName))",
            "    type: select",
            "    use:",
            "      - \(Self.yamlQuoted(Self.providerName))",
        ]

        for listener in accountNodeListeners {
            lines.append(contentsOf: [
                "  - name: \(Self.yamlQuoted(listener.groupName))",
                "    type: select",
                "    use:",
                "      - \(Self.yamlQuoted(Self.providerName))",
                "    filter: \(Self.yamlQuoted(Self.exactNodeFilter(listener.nodeName)))",
            ])
        }

        if accountNodeListeners.isEmpty == false {
            lines.append("listeners:")
            for listener in accountNodeListeners {
                lines.append(contentsOf: [
                    "  - name: \(Self.yamlQuoted(listener.listenerName))",
                    "    type: mixed",
                    "    listen: \"127.0.0.1\"",
                    "    port: \(listener.port)",
                    "    proxy: \(Self.yamlQuoted(listener.groupName))",
                ])
            }
        }

        lines.append(contentsOf: [
            "rules:",
            "  - \"MATCH,\(Self.selectGroupName)\"",
        ])

        let configYAML = lines.joined(separator: "\n") + "\n"

        try Helpers.writeFile(
            Paths.mihomoConfigURL(in: self.dataDirectory),
            data: Data(configYAML.utf8)
        )
    }

    private func resolveBinaryURL() throws -> URL {
        let fileManager = FileManager.default

        if let override = ProcessInfo.processInfo.environment["CODEX_PROXY_MIHOMO_PATH"],
           fileManager.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }

        let executableCandidates = [
            Bundle.main.executableURL,
            URL(fileURLWithPath: CommandLine.arguments[0], isDirectory: false).standardizedFileURL,
        ]
        for executableURL in executableCandidates.compactMap({ $0 }) {
            let sibling = executableURL.deletingLastPathComponent().appendingPathComponent("mihomo")
            if fileManager.isExecutableFile(atPath: sibling.path) {
                return sibling
            }
        }

        let workingDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let arch = Self.currentArchitectureFolderName()
        let candidates = [
            workingDirectory.appendingPathComponent("mihomo"),
            workingDirectory.appendingPathComponent(".build/debug/mihomo"),
            workingDirectory.appendingPathComponent("ThirdParty/mihomo/\(arch)/mihomo"),
            workingDirectory.appendingPathComponent("ThirdParty/mihomo/linux-\(arch)/mihomo"),
            workingDirectory.appendingPathComponent("Dist/mihomo-macos"),
        ]

        if let resolved = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return resolved
        }

        throw ProxyError.message("未找到 mihomo 可执行文件，请先运行 Scripts/fetch-mihomo.sh 或检查打包产物。")
    }

    private func openLogHandle(at url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Helpers.writeFile(url, data: Data())
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func saveRuntimeState(_ runtimeState: RuntimeStateRecord) throws {
        try Helpers.writeFile(
            Paths.mihomoRuntimeStateURL(in: self.dataDirectory),
            data: try Helpers.encodeJSON(runtimeState, pretty: true)
        )
    }

    private func loadRuntimeState() -> RuntimeStateRecord? {
        guard let data = try? Data(contentsOf: Paths.mihomoRuntimeStateURL(in: self.dataDirectory)) else {
            return nil
        }
        return try? Helpers.readJSON(RuntimeStateRecord.self, from: data)
    }

    private func lastRuntimeErrorSummary(maxLines: Int = 24) -> String? {
        let urls = [
            Paths.mihomoStderrLogURL(in: self.dataDirectory),
            Paths.mihomoStdoutLogURL(in: self.dataDirectory),
        ]
        for url in urls {
            guard
                let text = try? String(contentsOf: url, encoding: .utf8),
                !text.isEmpty
            else {
                continue
            }
            if let line = text
                .split(separator: "\n", omittingEmptySubsequences: false)
                .suffix(maxLines)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .last(where: { !$0.isEmpty })
            {
                return line
            }
        }
        return nil
    }

    private func reloadConfiguration(
        runtimeState: RuntimeStateRecord,
        secret: String
    ) async throws {
        _ = try await self.controllerRequest(
            method: "PUT",
            runtimeState: runtimeState,
            secret: secret,
            path: "/configs",
            queryItems: [URLQueryItem(name: "force", value: "true")],
            body: try Helpers.encodeJSON([
                "path": Paths.mihomoConfigURL(in: self.dataDirectory).path,
            ])
        )
    }

    private func loadNodeListenerPortMappings() -> [String: Int] {
        guard let data = try? Data(contentsOf: Paths.mihomoNodeListenerPortsURL(in: self.dataDirectory)),
              let record = try? Helpers.readJSON(NodeListenerPortMappingRecord.self, from: data)
        else {
            return [:]
        }
        return record.portsByNodeName.reduce(into: [:]) { partialResult, entry in
            let nodeName = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard nodeName.isEmpty == false, entry.value > 0 else {
                return
            }
            partialResult[nodeName] = entry.value
        }
    }

    private func saveNodeListenerPortMappings(_ portsByNodeName: [String: Int]) throws {
        try Helpers.writeFile(
            Paths.mihomoNodeListenerPortsURL(in: self.dataDirectory),
            data: try Helpers.encodeJSON(
                NodeListenerPortMappingRecord(portsByNodeName: portsByNodeName),
                pretty: true
            )
        )
    }

    private func resolveAccountNodeListenerDefinitions(
        desiredNodeNames: [String],
        availableNodeNames: Set<String>,
        reservedPorts: [Int]
    ) throws -> [ManagedProxyNodeListenerDefinition] {
        let normalizedDesired = Self.normalizedAccountNodeNames(desiredNodeNames)
        var mappings = self.loadNodeListenerPortMappings()
        mappings = mappings.filter { normalizedDesired.contains($0.key) }
        let reusableRuntimePorts = Dictionary(
            uniqueKeysWithValues: self.appliedAccountNodeListeners.map { ($0.nodeName, $0.port) }
        )

        var reserved = Set(reservedPorts.filter { $0 > 0 })
        for nodeName in normalizedDesired {
            let preferredPort = mappings[nodeName] ?? reusableRuntimePorts[nodeName] ?? 0
            let port: Int
            if let reusablePort = reusableRuntimePorts[nodeName],
               reusablePort == preferredPort,
               reserved.contains(reusablePort) == false
            {
                port = reusablePort
            } else {
                port = try Self.findAvailablePort(
                    preferred: preferredPort,
                    excluding: reserved
                )
            }
            mappings[nodeName] = port
            reserved.insert(port)
        }
        try self.saveNodeListenerPortMappings(mappings)

        return normalizedDesired.compactMap { nodeName in
            guard availableNodeNames.contains(nodeName), let port = mappings[nodeName] else {
                return nil
            }
            let hash = String(Helpers.sha256(nodeName).prefix(16))
            return ManagedProxyNodeListenerDefinition(
                nodeName: nodeName,
                groupName: "CodexProxyNodeGroup_\(hash)",
                listenerName: "CodexProxyNodeListener_\(hash)",
                port: port
            )
        }
    }

    private static func normalizedSubscriptionURL(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func validatedSubscriptionURL(_ value: String?) throws -> String? {
        guard let normalized = self.normalizedSubscriptionURL(value) else {
            return nil
        }
        guard
            let components = URLComponents(string: normalized),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            components.host?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        else {
            throw ProxyError.message("订阅地址必须是有效的 HTTP 或 HTTPS 绝对 URL。")
        }
        return normalized
    }

    public static func validatedHealthcheckURL(_ value: String?) throws -> String {
        try ManagedProxyConfigSummary.validatedHealthcheckURL(value)
    }

    private static func normalizedManagedProxySummary(
        _ summary: ManagedProxyConfigSummary,
        subscriptionConfigured: Bool
    ) -> ManagedProxyConfigSummary {
        ManagedProxyConfigSummary(
            subscriptionConfigured: subscriptionConfigured,
            selectedNodeName: summary.selectedNodeName,
            providerName: summary.providerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? ManagedProxyConfigSummary.defaultProviderName
                : summary.providerName,
            autoUpdateIntervalHours: max(1, summary.autoUpdateIntervalHours),
            healthcheckURL: ManagedProxyConfigSummary.sanitizedHealthcheckURL(summary.healthcheckURL)
        )
    }

    private static func requireSubscriptionURL(_ value: String?) throws -> String {
        guard let normalized = try self.validatedSubscriptionURL(value) else {
            throw ProxyError.message("订阅地址未配置。")
        }
        return normalized
    }

    private func healthcheckTargetNodeNames(
        requestedNodeName: String?,
        controllerSnapshot: ControllerSnapshot,
        pinnedNodeName: String?
    ) throws -> [String] {
        let nodes = self.nodes(
            from: controllerSnapshot.provider,
            currentNodeName: controllerSnapshot.group["now"] as? String,
            pinnedNodeName: pinnedNodeName
        )
        if let requestedNodeName = requestedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !requestedNodeName.isEmpty
        {
            guard nodes.contains(where: { $0.name == requestedNodeName }) else {
                throw ProxyError.message("未找到要测速的节点：\(requestedNodeName)")
            }
            return [requestedNodeName]
        }

        let names = nodes.map(\.name)
        guard !names.isEmpty else {
            throw ProxyError.message("订阅尚未返回任何节点，无法执行测速。")
        }
        return names
    }

    private func nodeHealthcheckResult(
        index: Int,
        nodeName: String,
        runtimeState: RuntimeStateRecord,
        secret: String,
        healthcheckURLs: [String]
    ) async -> NodeHealthcheckResult {
        let candidateURLs = healthcheckURLs.isEmpty
            ? [Self.defaultHealthcheckURL]
            : healthcheckURLs
        var failedAttempts: [String] = []

        for healthcheckURL in candidateURLs {
            do {
                let delayMS = try await self.controllerNodeDelay(
                    nodeName: nodeName,
                    runtimeState: runtimeState,
                    secret: secret,
                    healthcheckURL: healthcheckURL
                )
                guard delayMS > 0 else {
                    failedAttempts.append(
                        Self.healthcheckAttemptFailureSummary(
                            healthcheckURL: healthcheckURL,
                            error: HTTPProxyProbeError(kind: .timeout)
                        )
                    )
                    continue
                }
                return NodeHealthcheckResult(
                    index: index,
                    nodeName: nodeName,
                    status: .success,
                    delayMS: delayMS,
                    checkedAt: self.healthcheckTimestampProvider(),
                    failureSummary: nil
                )
            } catch {
                failedAttempts.append(
                    Self.healthcheckAttemptFailureSummary(
                        healthcheckURL: healthcheckURL,
                        error: error
                    )
                )
            }
        }

        return NodeHealthcheckResult(
            index: index,
            nodeName: nodeName,
            status: .failure,
            delayMS: nil,
            checkedAt: self.healthcheckTimestampProvider(),
            failureSummary: Self.combinedHealthcheckFailureSummary(from: failedAttempts)
        )
    }

    private func batchNodeHealthcheckResults(
        nodeNames: [String],
        runtimeState: RuntimeStateRecord,
        secret: String,
        healthcheckURLs: [String]
    ) async -> [NodeHealthcheckResult] {
        guard nodeNames.isEmpty == false else { return [] }

        let concurrencyLimit = Self.batchHealthcheckConcurrencyLimit(
            nodeCount: nodeNames.count,
            maxLimit: self.batchHealthcheckConcurrencyLimit
        )
        var nextIndex = 0
        var results: [NodeHealthcheckResult] = []

        await withTaskGroup(of: NodeHealthcheckResult.self) { group in
            let initialTaskCount = min(concurrencyLimit, nodeNames.count)
            for _ in 0..<initialTaskCount {
                let index = nextIndex
                let nodeName = nodeNames[index]
                nextIndex += 1
                group.addTask {
                    await self.nodeHealthcheckResult(
                        index: index,
                        nodeName: nodeName,
                        runtimeState: runtimeState,
                        secret: secret,
                        healthcheckURLs: healthcheckURLs
                    )
                }
            }

            while let result = await group.next() {
                results.append(result)
                guard nextIndex < nodeNames.count else { continue }
                let index = nextIndex
                let nodeName = nodeNames[index]
                nextIndex += 1
                group.addTask {
                    await self.nodeHealthcheckResult(
                        index: index,
                        nodeName: nodeName,
                        runtimeState: runtimeState,
                        secret: secret,
                        healthcheckURLs: healthcheckURLs
                    )
                }
            }
        }

        return results.sorted { $0.index < $1.index }
    }

    private func controllerNodeDelay(
        nodeName: String,
        runtimeState: RuntimeStateRecord,
        secret: String,
        healthcheckURL: String
    ) async throws -> Int64 {
        if let nodeHealthcheckProbeHandler {
            let response = try await nodeHealthcheckProbeHandler(
                nodeName,
                healthcheckURL,
                OutboundProxySettings(
                    scheme: .http,
                    host: "127.0.0.1",
                    port: runtimeState.mixedPort
                ),
                Self.defaultHealthcheckTimeoutMS
            )
            _ = response.statusCode
            return response.latencyMS
        }

        let response = try await self.controllerRequest(
            method: "GET",
            runtimeState: runtimeState,
            secret: secret,
            path: "/proxies/\(Self.encodedPathComponent(nodeName))/delay",
            pathIsPercentEncoded: true,
            queryItems: [
                URLQueryItem(name: "url", value: healthcheckURL),
                URLQueryItem(name: "timeout", value: "\(Self.defaultHealthcheckTimeoutMS)"),
            ]
        )
        let payload = try Helpers.readJSON(ControllerNodeDelayResponse.self, from: response.data)
        return payload.delay
    }

    private static func healthcheckCandidateURLs(primaryURL: String) -> [String] {
        let candidates = [primaryURL] + self.fallbackHealthcheckURLs
        var seen = Set<String>()
        return candidates.compactMap { rawURL in
            let normalized = ManagedProxyConfigSummary.sanitizedHealthcheckURL(rawURL)
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private static func healthcheckAttemptFailureSummary(
        healthcheckURL: String,
        error: Error
    ) -> String {
        let summary = self.healthcheckErrorSummary(error)
        return "\(healthcheckURL): \(summary)"
    }

    private static func combinedHealthcheckFailureSummary(from failedAttempts: [String]) -> String {
        let visibleAttempts = failedAttempts.prefix(3)
        let summary = visibleAttempts.joined(separator: "; ")
        let hiddenCount = failedAttempts.count - visibleAttempts.count
        if hiddenCount > 0 {
            return "\(summary); +\(hiddenCount) target\(hiddenCount == 1 ? "" : "s")"
        }
        return summary.isEmpty ? HTTPProxyProbeError(kind: .requestFailed).summary : summary
    }

    private static func healthcheckErrorSummary(_ error: Error) -> String {
        if let error = error as? HTTPProxyProbeError {
            return error.summary
        }
        let rawMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if let controllerMessage = self.controllerErrorMessage(from: rawMessage) {
            if controllerMessage.localizedCaseInsensitiveContains("timeout") {
                return HTTPProxyProbeError(kind: .timeout).summary
            }
            if controllerMessage.localizedCaseInsensitiveContains("delay test") {
                return "mihomo delay test failed"
            }
            return controllerMessage
        }
        let classified = HTTPProxyProbe.classify(error)
        guard rawMessage.isEmpty == false,
              rawMessage != classified.summary
        else {
            return classified.summary
        }
        return "\(classified.summary) (\(rawMessage))"
    }

    private static func controllerErrorMessage(from rawMessage: String) -> String? {
        guard rawMessage.first == "{",
              let data = rawMessage.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["message"] as? String
        else {
            return nil
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sortedNodes(_ nodes: [ManagedProxyNode]) -> [ManagedProxyNode] {
        nodes.sorted { lhs, rhs in
            let lhsRank = Self.nodeSortRank(lhs)
            let rhsRank = Self.nodeSortRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            if lhs.lastDelayMS != rhs.lastDelayMS {
                switch (lhs.lastDelayMS, rhs.lastDelayMS) {
                case let (.some(lhsDelay), .some(rhsDelay)):
                    return lhsDelay < rhsDelay
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    break
                }
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private static func nodeSortRank(_ node: ManagedProxyNode) -> Int {
        if node.isCurrent {
            return 0
        }
        if node.isPinned {
            return 1
        }
        if node.alive == false {
            return 4
        }
        if node.lastDelayMS != nil {
            return 2
        }
        return 3
    }

    private static func snapshot(
        _ snapshot: ManagedProxySnapshot,
        applyingHealthcheckResults results: [NodeHealthcheckResult],
        baseline: [String: (delay: Int64?, timestamp: Int64?)],
        feedbackDetail: String?
    ) -> ManagedProxySnapshot {
        var snapshot = snapshot
        snapshot.lastHealthcheckFeedbackDetail = feedbackDetail
        guard results.isEmpty == false else {
            return snapshot
        }
        let indexByNodeName = Dictionary(uniqueKeysWithValues: snapshot.nodes.enumerated().map { ($0.element.name, $0.offset) })

        for result in results {
            guard let nodeIndex = indexByNodeName[result.nodeName] else {
                continue
            }
            let previousTimestamp = snapshot.nodes[nodeIndex].lastHealthcheckAt
                ?? baseline[result.nodeName]?.timestamp
            snapshot.nodes[nodeIndex].lastHealthcheckStatus = result.status
            snapshot.nodes[nodeIndex].lastHealthcheckAt = Self.strictHealthcheckTimestamp(
                result.checkedAt,
                previousTimestamp: previousTimestamp
            )
            if result.status == .success, let delayMS = result.delayMS {
                snapshot.nodes[nodeIndex].lastDelayMS = delayMS
            }
        }
        snapshot.nodes = Self.sortedNodes(snapshot.nodes)
        return snapshot
    }

    private static func healthcheckResults(
        _ results: [NodeHealthcheckResult],
        reconciledWith snapshot: ManagedProxySnapshot,
        baseline: [String: (delay: Int64?, timestamp: Int64?)]
    ) -> [NodeHealthcheckResult] {
        guard results.isEmpty == false else { return results }
        let nodesByName = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.name, $0) })
        return results.map { result in
            guard result.status == .failure,
                  let node = nodesByName[result.nodeName],
                  let providerDelayMS = node.lastDelayMS,
                  providerDelayMS > 0,
                  let providerCheckedAt = node.lastHealthcheckAt,
                  Self.canUseProviderHealthcheckResult(
                    node: node,
                    baseline: baseline[result.nodeName]
                  )
            else {
                return result
            }
            return NodeHealthcheckResult(
                index: result.index,
                nodeName: result.nodeName,
                status: .success,
                delayMS: providerDelayMS,
                checkedAt: max(providerCheckedAt, result.checkedAt),
                failureSummary: nil
            )
        }
    }

    private static func canUseProviderHealthcheckResult(
        node: ManagedProxyNode,
        baseline: (delay: Int64?, timestamp: Int64?)?
    ) -> Bool {
        if node.alive != false, (node.lastDelayMS ?? 0) > 0 {
            return true
        }
        guard let currentTimestamp = node.lastHealthcheckAt else {
            return false
        }
        if let previousTimestamp = baseline?.timestamp {
            return currentTimestamp > previousTimestamp || node.lastDelayMS != baseline?.delay
        }
        return true
    }

    private static func healthcheckFeedbackDetail(
        from results: [NodeHealthcheckResult]
    ) -> String? {
        let failedResults = results.compactMap { result -> (String, String)? in
            guard result.status == .failure else { return nil }
            let summary = result.failureSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard summary.isEmpty == false else { return nil }
            return (result.nodeName, summary)
        }
        guard failedResults.isEmpty == false else {
            return nil
        }
        if results.count == 1 {
            return failedResults.first?.1
        }

        let visibleFailures = failedResults.prefix(3).map { "\($0.0): \($0.1)" }
        let hiddenCount = failedResults.count - visibleFailures.count
        if hiddenCount > 0 {
            return visibleFailures.joined(separator: "; ") + "; +\(hiddenCount) more"
        }
        return visibleFailures.joined(separator: "; ")
    }

    private static func strictHealthcheckTimestamp(
        _ checkedAt: Int64,
        previousTimestamp: Int64?
    ) -> Int64 {
        guard let previousTimestamp else {
            return checkedAt
        }
        return checkedAt > previousTimestamp ? checkedAt : previousTimestamp + 1
    }

    internal static func batchHealthcheckConcurrencyLimit(
        nodeCount: Int,
        maxLimit: Int = ManagedProxyRuntime.defaultBatchHealthcheckConcurrency
    ) -> Int {
        guard nodeCount > 0 else {
            return 0
        }
        return min(max(maxLimit, 1), nodeCount)
    }

    private static func isSubscriptionMetadataNodeName(_ name: String) -> Bool {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.isEmpty == false else { return true }

        let metadataPrefixes = [
            "剩余流量",
            "已用流量",
            "总流量",
            "套餐到期",
            "到期时间",
            "过期时间",
            "重置时间",
            "官网",
            "订阅",
            "traffic",
            "remaining traffic",
            "used traffic",
            "total traffic",
            "expire",
            "expires",
            "reset",
            "subscription",
        ]
        if metadataPrefixes.contains(where: { normalized.hasPrefix($0) }) {
            return true
        }

        let metadataNeedles = [
            "剩余流量：",
            "剩余流量:",
            "到期时间：",
            "到期时间:",
            "过期时间：",
            "过期时间:",
        ]
        return metadataNeedles.contains(where: { normalized.contains($0) })
    }

    private static func subscriptionUserinfo(from provider: [String: Any]) -> String? {
        if let text = provider["subscriptionInfo"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let text = provider["subscription_info"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        guard
            let object = provider["subscriptionInfo"] ?? provider["subscription_info"],
            JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(withJSONObject: object),
            let text = String(data: data, encoding: .utf8)
        else {
            return nil
        }
        return text
    }

    private static func latestHistoryEntry(from rawValue: Any?) -> (delay: Int64?, timestamp: Int64?) {
        guard let items = rawValue as? [[String: Any]] else {
            return (nil, nil)
        }

        for item in items.reversed() {
            let delay = Self.int64(from: item["delay"])
            let timestamp = Self.timestamp(from: item["time"])
            if delay != nil || timestamp != nil {
                return (delay, timestamp)
            }
        }
        return (nil, nil)
    }

    private static func timestamp(from value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let text = value as? String {
            if let integer = Int64(text) {
                return integer
            }
            let withFractional = ISO8601DateFormatter()
            withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = withFractional.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            if let date = plain.date(from: text) {
                return Int64(date.timeIntervalSince1970)
            }
        }
        return nil
    }

    private static func int64(from value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let text = value as? String {
            return Int64(text)
        }
        return nil
    }

    private static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }

    private static func normalizedAccountNodeNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.compactMap { rawValue in
            let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false, seen.insert(trimmed).inserted else {
                return nil
            }
            return trimmed
        }
        .sorted { lhs, rhs in
            lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }
    }

    private static func exactNodeFilter(_ nodeName: String) -> String {
        "^\(NSRegularExpression.escapedPattern(for: nodeName))$"
    }

    private static func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func encodedPathComponent(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func currentArchitectureFolderName() -> String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    private static func findAvailablePort(
        preferred: Int,
        excluding reservedPorts: Set<Int>
    ) throws -> Int {
        if preferred > 0, reservedPorts.contains(preferred) == false, self.canBind(port: preferred) {
            return preferred
        }

        for _ in 0..<64 {
            let port = try self.findAvailablePort(preferred: 0)
            if reservedPorts.contains(port) == false {
                return port
            }
        }

        throw ProxyError.message("无法为账号级订阅节点分配空闲监听端口。")
    }

    private static func findAvailablePort(preferred: Int) throws -> Int {
        if let port = POSIXCompat.availableTCPIPv4LoopbackPort(preferred: preferred) {
            return port
        }
        throw ProxyError.message("无法为 mihomo 分配空闲端口。")
    }

    private static func canBind(port: Int) -> Bool {
        POSIXCompat.canBindTCPIPv4Loopback(port: port)
    }

    private static func terminateProcess(_ pid: Int32) {
        POSIXCompat.terminateProcess(pid)
    }
}

extension ManagedProxyRuntime: ManagedProxyRuntimeControlling {}
