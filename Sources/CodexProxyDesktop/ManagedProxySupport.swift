#if os(macOS)
import CodexProxyCore
import Foundation
import SwiftUI

enum ManagedProxyOperation: Equatable {
    case idle
    case loading
    case saving
    case savingHealthcheckURL
    case updatingSubscription
    case selecting(String)
    case switchingCurrent(String)
    case updatingPinned(String?)
    case healthchecking(String?)
    case loadingLogs
}

private enum ManagedProxyHealthcheckSource {
    case row
    case drawerCurrent
    case drawerBatch
}

private struct ManagedProxyHealthcheckOutcome {
    let feedback: ManagedProxyHealthcheckFeedback
    let displayStates: [String: ManagedProxyNodeHealthcheckDisplayState]
    let focusNodeName: String?
    let clearSearchIfHidden: Bool
    let bannerTone: DesktopAppModel.BannerState.Tone
    let bannerTitle: String
    let bannerDetail: String?
}

@MainActor
extension DesktopAppModel {
    var visibleManagedProxyNodes: [ManagedProxyNode] {
        let query = self.managedProxyNodeSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else {
            return self.managedProxySnapshot.nodes
        }
        return self.managedProxySnapshot.nodes.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.type.localizedCaseInsensitiveContains(query)
        }
    }

    var managedProxyFocusedNode: ManagedProxyNode? {
        let nodes = self.visibleManagedProxyNodes
        guard let focusedName = self.managedProxyFocusedNodeName else {
            return self.preferredManagedProxyFocusedNode(in: nodes)
        }
        return nodes.first(where: { $0.name == focusedName }) ?? self.preferredManagedProxyFocusedNode(in: nodes)
    }

    var managedProxyWebsiteProbeTargets: [ManagedProxyWebsiteProbeTarget] {
        [.custom, .google, .github, .youtube, .wikipedia]
    }

    var canRunManagedProxyWebsiteProbes: Bool {
        self.managedProxyWebsiteProbeUnavailableReason == nil
    }

    var isManagedProxyWebsiteProbeBatchRunning: Bool {
        self.managedProxyWebsiteProbeRunningTargets.isEmpty == false
    }

    var managedProxyWebsiteProbeUnavailableReason: String? {
        guard self.adminCapabilities.supportsWebsiteProbes else {
            return self.localizedManagedProxyText(
                zh: "当前管理目标不支持网站探测能力。",
                en: "Website probes are unavailable for the current admin target."
            )
        }
        guard self.managedProxySnapshot.subscriptionConfigured else {
            return self.localizedManagedProxyText(
                zh: "先保存一个有效的订阅地址，再通过当前订阅节点测试网站连通性。",
                en: "Save a valid subscription URL before testing website reachability through the current subscription node."
            )
        }
        guard self.status?.running == true else {
            return self.localizedManagedProxyText(
                zh: "本地服务未运行。启动服务后，才可以通过 mihomo mixed-port 测试外部网站。",
                en: "The local service is offline. Start it before probing external websites through the mihomo mixed-port."
            )
        }
        guard self.managedProxySnapshot.mixedPort != nil else {
            return self.localizedManagedProxyText(
                zh: "当前 mixed-port 不可用，请先保存并应用订阅配置，等待 sidecar 就绪。",
                en: "The current mixed-port is unavailable. Save and apply the subscription configuration first, then wait for the sidecar to become ready."
            )
        }
        guard self.nonEmptyManagedProxyNodeName(self.managedProxySnapshot.currentNodeName) != nil else {
            return self.localizedManagedProxyText(
                zh: "当前没有有效活动节点。请先更新订阅或固定一个可用节点后再测试网站连通性。",
                en: "There is no active node right now. Refresh the provider or pin a working node before testing website reachability."
            )
        }
        return nil
    }

    var managedProxyWebsiteProbeLastBatchText: String {
        guard let timestamp = self.managedProxyWebsiteProbeLastBatchTestedAt else {
            return self.localizedManagedProxyText(zh: "尚未执行全量测试", en: "No batch test has been run yet")
        }
        return self.localizedManagedProxyText(
            zh: "最近全量测试：\(DesktopDateTimeFormat.string(from: timestamp))",
            en: "Last batch test: \(DesktopDateTimeFormat.string(from: timestamp))"
        )
    }

    var managedProxyNodesDrawerTitle: String {
        self.localizedManagedProxyText(zh: "节点列表", en: "Nodes")
    }

    func presentManagedProxyNodesDrawer() {
        self.syncManagedProxyFocus()
        self.isManagedProxyNodesDrawerPresented = true
    }

    func dismissManagedProxyNodesDrawer() {
        self.isManagedProxyNodesDrawerPresented = false
    }

    func focusManagedProxyNode(_ nodeName: String?) {
        guard let nodeName else {
            self.managedProxyFocusedNodeName = nil
            self.syncManagedProxyFocus(preserveCurrent: false)
            return
        }
        if self.visibleManagedProxyNodes.contains(where: { $0.name == nodeName }) {
            self.managedProxyFocusedNodeName = nodeName
        } else {
            self.managedProxyFocusedNodeName = nil
            self.syncManagedProxyFocus(preserveCurrent: false)
        }
    }

    func syncManagedProxyFocus(preserveCurrent: Bool = true) {
        let nodes = self.visibleManagedProxyNodes
        if preserveCurrent,
           let focusedName = self.managedProxyFocusedNodeName,
           nodes.contains(where: { $0.name == focusedName }) {
            return
        }
        self.managedProxyFocusedNodeName = self.preferredManagedProxyFocusedNode(in: nodes)?.name
    }

    var canHealthcheckCurrentManagedProxyNode: Bool {
        self.managedProxyCanRunRuntimeActions
            && self.managedProxySnapshot.currentNodeName != nil
            && !self.isManagedProxyHealthchecking(self.managedProxySnapshot.currentNodeName)
    }

    var canHealthcheckAllManagedProxyNodes: Bool {
        self.managedProxyCanRunRuntimeActions
            && !self.isManagedProxyHealthchecking(nil)
    }

    var managedProxyHealthcheckFeedbackText: String? {
        guard let feedback = self.managedProxyHealthcheckFeedback else { return nil }
        switch feedback.kind {
        case .node:
            guard let nodeName = feedback.nodeName else { return nil }
            let label = self.managedProxyHealthcheckNodeLabel(for: nodeName, snapshot: self.managedProxySnapshot)
            switch feedback.status {
            case .success:
                let latencyText = feedback.latencyMS.map(self.localization.requestLogsLatencyText)
                    ?? self.localizedManagedProxyText(zh: "失败", en: "Failed")
                return "\(label) \(nodeName) · \(latencyText)"
            case .failure:
                return self.localizedManagedProxyText(
                    zh: "\(label) \(nodeName) · 失败",
                    en: "\(label) \(nodeName) · Failed"
                )
            case .info:
                return self.localizedManagedProxyText(
                    zh: "\(label) \(nodeName) · 测速中",
                    en: "\(label) \(nodeName) · Checking"
                )
            case .warning:
                return self.localizedManagedProxyText(
                    zh: "\(label) \(nodeName) · 部分完成",
                    en: "\(label) \(nodeName) · Partial"
                )
            }

        case .batch:
            if feedback.status == .info {
                return self.localizedManagedProxyText(
                    zh: "正在测速 \(feedback.totalNodeCount) 个节点",
                    en: "Checking \(feedback.totalNodeCount) nodes"
                )
            }
            let targetHostText = self.managedProxyHealthcheckTargetHostText
            return self.localizedManagedProxyText(
                zh: "成功 \(feedback.succeededNodeCount) / 失败 \(feedback.failedNodeCount) · 目标 \(targetHostText)",
                en: "Succeeded \(feedback.succeededNodeCount) / Failed \(feedback.failedNodeCount) · Target \(targetHostText)"
            )
        }
    }

    var managedProxyHealthcheckFeedbackTone: StatusPill.Tone {
        guard let feedback = self.managedProxyHealthcheckFeedback else {
            return .neutral
        }
        switch feedback.status {
        case .info:
            return .neutral
        case .success:
            return .success
        case .warning:
            return .warning
        case .failure:
            return .danger
        }
    }

    func healthcheckCurrentManagedProxyNode() async {
        await self.healthcheckManagedProxy(
            nodeName: self.managedProxySnapshot.currentNodeName,
            source: .drawerCurrent
        )
    }

    func healthcheckAllManagedProxyNodes() async {
        await self.healthcheckManagedProxy(nodeName: nil, source: .drawerBatch)
    }

    func managedProxyWebsiteProbeResult(for target: ManagedProxyWebsiteProbeTarget) -> ManagedProxyWebsiteProbeResult {
        self.managedProxyWebsiteProbeResults[target] ?? ManagedProxyWebsiteProbeResult(target: target)
    }

    func managedProxyWebsiteProbeState(for target: ManagedProxyWebsiteProbeTarget) -> ManagedProxyWebsiteProbeState {
        if self.managedProxyWebsiteProbeRunningTargets.contains(target) {
            return .running
        }
        return self.managedProxyWebsiteProbeResult(for: target).state
    }

    func managedProxyWebsiteProbeDisplayName(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        switch target {
        case .custom:
            return self.localizedManagedProxyText(zh: "自定义测速目标", en: "Custom Target")
        case .google:
            return "Google"
        case .github:
            return "GitHub"
        case .youtube:
            return "YouTube"
        case .wikipedia:
            return "Wikipedia"
        }
    }

    func managedProxyWebsiteProbeHostText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        switch target {
        case .custom:
            return self.managedProxySnapshot.healthcheckURL
        case .google, .github, .youtube, .wikipedia:
            return target.fixedHostText ?? self.managedProxySnapshot.healthcheckURL
        }
    }

    var managedProxyHealthcheckTargetHostText: String {
        let rawValue = self.managedProxySnapshot.healthcheckURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = ManagedProxyConfigSummary.defaultHealthcheckURL

        guard
            let components = URLComponents(string: rawValue.isEmpty ? fallback : rawValue),
            let host = components.host?.trimmingCharacters(in: .whitespacesAndNewlines),
            host.isEmpty == false
        else {
            return rawValue.isEmpty ? fallback : rawValue
        }

        let path = components.percentEncodedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty || path == "/" ? host : "\(host)\(path)"
    }

    func managedProxyWebsiteProbeURL(_ target: ManagedProxyWebsiteProbeTarget) -> URL? {
        switch target {
        case .custom:
            return URL(string: self.managedProxySnapshot.healthcheckURL)
                ?? URL(string: ManagedProxyConfigSummary.defaultHealthcheckURL)
        case .google, .github, .youtube, .wikipedia:
            return target.fixedProbeURL
        }
    }

    func managedProxyWebsiteProbeStatusText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        switch self.managedProxyWebsiteProbeState(for: target) {
        case .idle:
            return self.localizedManagedProxyText(zh: "未测试", en: "Idle")
        case .running:
            return self.localizedManagedProxyText(zh: "测试中", en: "Running")
        case .succeeded:
            return self.localizedManagedProxyText(zh: "可达", en: "Reachable")
        case .reachableButUnexpected:
            return self.localizedManagedProxyText(zh: "响应异常", en: "Unexpected Response")
        case .failed:
            return self.localizedManagedProxyText(zh: "失败", en: "Failed")
        }
    }

    func managedProxyWebsiteProbeTone(_ target: ManagedProxyWebsiteProbeTarget) -> StatusPill.Tone {
        switch self.managedProxyWebsiteProbeState(for: target) {
        case .idle, .running:
            return .neutral
        case .succeeded:
            return .success
        case .reachableButUnexpected:
            return .warning
        case .failed:
            return .danger
        }
    }

    func managedProxyWebsiteProbeHTTPStatusText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        guard let statusCode = self.managedProxyWebsiteProbeResult(for: target).statusCode else {
            return "--"
        }
        return String(statusCode)
    }

    func managedProxyWebsiteProbeLatencyText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        guard let latency = self.managedProxyWebsiteProbeResult(for: target).latencyMilliseconds else {
            return "--"
        }
        return "\(latency) ms"
    }

    func managedProxyWebsiteProbeTestedAtText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        guard let testedAt = self.managedProxyWebsiteProbeResult(for: target).testedAt else {
            return "--"
        }
        return DesktopDateTimeFormat.string(from: testedAt)
    }

    func managedProxyWebsiteProbeDetailText(_ target: ManagedProxyWebsiteProbeTarget) -> String {
        let result = self.managedProxyWebsiteProbeResult(for: target)
        switch self.managedProxyWebsiteProbeState(for: target) {
        case .idle:
            if target == .custom {
                return self.localizedManagedProxyText(
                    zh: "这一项会使用当前保存的测速目标 URL；节点手动测速和全量测速也会共用同一个目标。",
                    en: "This row uses the saved health-check target URL, and the same target is shared by manual and batch node health checks."
                )
            }
            return self.localizedManagedProxyText(
                zh: "手动触发后，这里会显示通过当前订阅代理访问该站点的结果。",
                en: "Run the probe manually to show whether this site is reachable through the current subscription proxy."
            )
        case .running:
            return self.localizedManagedProxyText(
                zh: "正在通过当前 mixed-port 访问该站点，请稍候。",
                en: "The site is being tested through the current mixed-port."
            )
        case .succeeded:
            if let statusCode = result.statusCode {
                return self.localizedManagedProxyText(
                    zh: "已通过当前代理链路访问，返回 HTTP \(statusCode)。",
                    en: "The current proxy chain reached the site and returned HTTP \(statusCode)."
                )
            }
            return self.localizedManagedProxyText(
                zh: "已通过当前代理链路访问该站点。",
                en: "The current proxy chain reached the site."
            )
        case .reachableButUnexpected:
            if let statusCode = result.statusCode {
                return self.localizedManagedProxyText(
                    zh: "站点可达，但返回了 HTTP \(statusCode)。",
                    en: "The site is reachable, but it returned HTTP \(statusCode)."
                )
            }
            return self.localizedManagedProxyText(
                zh: "站点可达，但返回内容不符合预期。",
                en: "The site is reachable, but the response was unexpected."
            )
        case .failed:
            if let summary = result.errorSummary?.trimmingCharacters(in: .whitespacesAndNewlines), summary.isEmpty == false {
                return summary
            }
            return self.localizedManagedProxyText(
                zh: "当前代理链路未能完成该站点请求。",
                en: "The current proxy chain could not complete the request."
            )
        }
    }

    func resetManagedProxyWebsiteProbeResults() {
        self.managedProxyWebsiteProbeGeneration += 1
        self.managedProxyWebsiteProbeResults = [:]
        self.managedProxyWebsiteProbeRunningTargets = []
        self.managedProxyWebsiteProbeLastBatchTestedAt = nil
    }

    func resetManagedProxyHealthcheckFeedback() {
        self.managedProxyHealthcheckFeedback = nil
    }

    func resetManagedProxyNodeHealthcheckDisplayStates() {
        self.managedProxyNodeHealthcheckDisplayStates = [:]
    }

    func runManagedProxyWebsiteProbe(_ target: ManagedProxyWebsiteProbeTarget) async {
        guard self.canRunManagedProxyWebsiteProbes,
              let mixedPort = self.managedProxySnapshot.mixedPort,
              let probeURL = self.managedProxyWebsiteProbeURL(target) else {
            return
        }

        let generation = self.managedProxyWebsiteProbeGeneration
        self.managedProxyWebsiteProbeRunningTargets.insert(target)
        let result = await self.managedProxyWebsiteProbeClient.probe(target, url: probeURL, mixedPort: mixedPort)

        guard generation == self.managedProxyWebsiteProbeGeneration else { return }
        self.managedProxyWebsiteProbeRunningTargets.remove(target)
        self.managedProxyWebsiteProbeResults[target] = result
    }

    func runAllManagedProxyWebsiteProbes() async {
        guard self.canRunManagedProxyWebsiteProbes,
              let mixedPort = self.managedProxySnapshot.mixedPort else {
            return
        }

        let targets = self.managedProxyWebsiteProbeTargets.compactMap { target -> (ManagedProxyWebsiteProbeTarget, URL)? in
            guard let url = self.managedProxyWebsiteProbeURL(target) else { return nil }
            return (target, url)
        }
        guard targets.isEmpty == false else { return }
        let generation = self.managedProxyWebsiteProbeGeneration
        let client = self.managedProxyWebsiteProbeClient
        self.managedProxyWebsiteProbeRunningTargets.formUnion(targets.map { $0.0 })

        await withTaskGroup(of: ManagedProxyWebsiteProbeResult.self) { group in
            for (target, url) in targets {
                group.addTask {
                    await client.probe(target, url: url, mixedPort: mixedPort)
                }
            }

            for await result in group {
                guard generation == self.managedProxyWebsiteProbeGeneration else { continue }
                self.managedProxyWebsiteProbeRunningTargets.remove(result.target)
                self.managedProxyWebsiteProbeResults[result.target] = result
            }
        }

        guard generation == self.managedProxyWebsiteProbeGeneration else { return }
        self.managedProxyWebsiteProbeLastBatchTestedAt = Date()
    }

    var managedProxyRuntimeTone: StatusPill.Tone {
        switch self.managedProxySnapshot.runtimeState {
        case .stopped:
            return .neutral
        case .starting:
            return .accent
        case .running:
            return .success
        case .degraded:
            return .warning
        }
    }

    var managedProxyRuntimeStatusText: String {
        switch self.managedProxySnapshot.runtimeState {
        case .stopped:
            return self.localizedManagedProxyText(zh: "未运行", en: "Stopped")
        case .starting:
            return self.text(.statusStarting)
        case .running:
            return self.localizedManagedProxyText(zh: "就绪", en: "Ready")
        case .degraded:
            return self.localizedManagedProxyText(zh: "需处理", en: "Needs Attention")
        }
    }

    var managedProxySummaryText: String {
        self.managedProxySummaryText(for: self.settings.outboundProxyMode)
    }

    func managedProxySummaryText(for mode: OutboundProxyMode) -> String {
        guard mode == .subscription else {
            return self.localizedManagedProxyText(
                zh: "当前未启用订阅代理，daemon 将按你选择的模式决定是否走代理。",
                en: "Subscription proxy is not enabled. The daemon will follow the selected outbound mode."
            )
        }
        guard self.managedProxySnapshot.subscriptionConfigured else {
            return self.localizedManagedProxyText(
                zh: "订阅地址尚未配置，可在“管理订阅”窗口中保存并应用；只要本地服务正在运行，mihomo sidecar 就会自动就绪。",
                en: "The subscription URL has not been configured yet. Save it in the Manage Subscription window, and the mihomo sidecar will come up automatically whenever the local daemon is running."
            )
        }
        guard self.status?.running == true else {
            return self.localizedManagedProxyText(
                zh: "本地服务未运行。请前往总览或设置页恢复本地服务；只要服务恢复运行，mihomo 就会按已保存订阅自动拉起，随后你就可以更新订阅、切换当前节点、设置固定默认节点并执行测速。",
                en: "The local service is offline. Restart the local daemon from Overview or Settings, and mihomo will relaunch automatically with the saved subscription so you can refresh the provider, switch the current node, manage the pinned default, and run health checks."
            )
        }
        if let error = self.managedProxySnapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), error.isEmpty == false {
            return error
        }
        if self.managedProxySnapshot.currentNodeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return self.localizedManagedProxyText(
                zh: "订阅已加载，但当前没有活动节点。请先更新订阅或检查代理内核日志。",
                en: "The subscription is loaded, but there is no active node yet. Refresh the provider or inspect the mihomo logs."
            )
        }
        if self.managedProxySnapshot.pinnedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            return self.localizedManagedProxyText(
                zh: "当前已有可用节点，但还未设置固定默认节点。建议固定一个常用节点，避免出口地区发生漂移。",
                en: "A working node is available, but no pinned default is set yet. Pin a preferred node to avoid silent region drift."
            )
        }
        return self.localizedManagedProxyText(
            zh: "订阅代理会优先使用你设置的固定默认节点；如节点失效，管理窗口会提示你重新处理。",
            en: "Subscription proxying prefers the pinned default node, and the manager will flag it if that default becomes invalid."
        )
    }

    var managedProxyManagerSummaryText: String {
        let currentNodeName = self.nonEmptyManagedProxyNodeName(self.managedProxySnapshot.currentNodeName)
        let pinnedNodeName = self.nonEmptyManagedProxyNodeName(self.managedProxySnapshot.pinnedNodeName)

        guard self.managedProxySnapshot.subscriptionConfigured else {
            return self.localizedManagedProxyText(
                zh: "订阅地址尚未配置。你可以先在这里保存订阅地址；只要本地服务正在运行，mihomo 就会自动就绪，之后再决定是否回到设置页切换到订阅代理模式。",
                en: "No subscription URL is configured yet. Save it here first. Whenever the local daemon is running, mihomo will be kept ready, and you can decide later whether to switch the active outbound mode to Subscription."
            )
        }

        guard self.status?.running == true else {
            if self.settings.outboundProxyMode == .subscription {
                return self.localizedManagedProxyText(
                    zh: "本地服务未运行。你仍可保存订阅地址；请前往总览或设置页恢复本地服务。只要服务恢复运行，mihomo 就会按已保存订阅自动拉起，随后你就可以更新订阅、切换当前节点、设置固定默认节点、查看监听端口并执行测速。",
                    en: "The local service is offline. You can still save the subscription URL here, but please restart the local daemon from Overview or Settings. Once it is back, mihomo will relaunch automatically with the saved subscription so you can refresh the provider, switch the current node, manage the pinned default, inspect listener ports, and run health checks."
                )
            }
            return self.localizedManagedProxyText(
                zh: "当前全局未启用订阅代理，且本地服务未运行。你仍可在这里保存或查看订阅配置；请前往总览或设置页恢复本地服务。只要服务恢复运行，mihomo 就会按已保存订阅自动拉起；全局模式不会自动切换，但账号页里已设置的自定义出站节点会在恢复后继续可用。",
                en: "Subscription mode is not active globally right now, and the local service is offline. You can still save or review the subscription here; restart the local daemon from Overview or Settings and mihomo will relaunch automatically with the saved subscription. The global mode will not switch on its own, but saved account-level outbound nodes become usable again as soon as the service comes back."
            )
        }

        if let error = self.managedProxySnapshot.lastError?.trimmingCharacters(in: .whitespacesAndNewlines), error.isEmpty == false {
            return error
        }

        if let currentNodeName, let pinnedNodeName, currentNodeName != pinnedNodeName {
            return self.localizedManagedProxyText(
                zh: "当前节点 \(currentNodeName) 是临时切换；固定默认节点仍是 \(pinnedNodeName)，后续运行态刷新时它会重新接管默认出口。",
                en: "The current node \(currentNodeName) is a temporary switch. The pinned default remains \(pinnedNodeName), and it will take over again on a later runtime refresh."
            )
        }

        if self.settings.outboundProxyMode != .subscription {
            return self.localizedManagedProxyText(
                zh: "当前全局未启用订阅代理。你仍可在这里保存订阅、切换当前节点、设置固定默认节点、查看监听端口和执行测速；设置页当前模式仍决定默认出口，但账号页里已设置的自定义出站节点会优先覆盖。",
                en: "Subscription mode is not active globally right now. You can still save the subscription, switch the current node, manage the pinned default, inspect listener ports, and run health checks here. The Settings page still decides the default egress, but any saved account-level outbound node override takes priority."
            )
        }

        if currentNodeName == nil {
            return self.localizedManagedProxyText(
                zh: "订阅已加载，但当前没有活动节点。请先更新订阅或检查代理内核日志。",
                en: "The subscription is loaded, but there is no active node yet. Refresh the provider or inspect the mihomo logs."
            )
        }

        if pinnedNodeName == nil {
            return self.localizedManagedProxyText(
                zh: "当前已有可用节点，但还未设置固定默认节点。你可以先临时切换当前节点，也可以单独设置固定默认节点。",
                en: "A working node is available, but no pinned default is set yet. You can switch the current node temporarily or set a pinned default independently."
            )
        }

        return self.localizedManagedProxyText(
            zh: "当前订阅运行态已就绪。你可以临时切换当前节点，也可以单独维护固定默认节点和监听端口。",
            en: "The subscription runtime is ready. You can switch the current node temporarily while managing the pinned default and listener ports separately."
        )
    }

    var managedProxyCanRunRuntimeActions: Bool {
        self.status?.running == true
            && self.localServiceOperation == .idle
            && self.managedProxySnapshot.subscriptionConfigured
    }

    var isManagedProxyOperationRunning: Bool {
        self.managedProxyOperation != .idle
    }

    var managedProxyManagerWindowTitle: String {
        self.localizedManagedProxyText(zh: "管理订阅", en: "Manage Subscription")
    }

    var managedProxyManagerWindowSubtitle: String {
        self.localizedManagedProxyText(
            zh: "订阅地址、节点维护、监听端口、测速和 mihomo 日志都在这里完成；这里不会控制本地服务启停。",
            en: "Handle the subscription URL, node maintenance, listener ports, health checks, and mihomo diagnostics here. Local daemon start and stop stays in the global service pages."
        )
    }

    var managedProxyCurrentNodeText: String {
        let current = self.managedProxySnapshot.currentNodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current.isEmpty ? self.text(.statusNoData) : current
    }

    var managedProxyPinnedNodeText: String {
        let current = self.managedProxySnapshot.pinnedNodeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return current.isEmpty ? self.text(.statusNoData) : current
    }

    var managedProxySelectedNodeText: String { self.managedProxyPinnedNodeText }

    var managedProxyNodeCountText: String {
        "\(self.managedProxySnapshot.nodes.count)"
    }

    var managedProxyProviderUpdatedText: String {
        guard let timestamp = self.managedProxySnapshot.providerUpdatedAt else {
            return self.text(.statusNoData)
        }
        return DesktopDateTimeFormat.string(fromUnixSeconds: timestamp)
    }

    var managedProxyActionHelperText: String {
        if self.managedProxySnapshot.subscriptionConfigured == false {
            return self.localizedManagedProxyText(
                zh: "先保存一个有效的 HTTP/HTTPS 订阅地址；若本地服务正在运行，保存后 mihomo 会自动就绪，然后你就可以更新订阅并在右侧节点抽屉里维护节点。",
                en: "Save a valid HTTP/HTTPS subscription URL first. If the local daemon is already running, mihomo will come up automatically afterward, and then you can refresh the provider and manage nodes from the right-side drawer."
            )
        }
        if self.status?.running != true {
            return self.localizedManagedProxyText(
                zh: "本地服务未运行。你仍可保存订阅地址；请前往总览或设置页恢复本地服务。只要服务恢复运行，mihomo 就会按已保存订阅自动拉起，之后你就可以更新订阅、切换当前节点、设置固定默认节点，并在右侧节点抽屉里测速。",
                en: "The local service is offline. You can still save the subscription URL, but restart the local daemon from Overview or Settings first. Once it is back, mihomo will relaunch automatically with the saved subscription so you can refresh the provider, switch the current node, manage the pinned default, and run health checks from the right-side drawer."
            )
        }
        return self.localizedManagedProxyText(
            zh: "保存订阅后可手动更新节点；右侧节点抽屉里可切换当前节点、设置固定默认节点，并执行测速。",
            en: "After saving the subscription, you can refresh the provider here, then use the right-side nodes drawer to switch the current node, manage the pinned default, and run health checks."
        )
    }

    var managedProxyHealthcheckURLFieldFooterText: String {
        self.localizedManagedProxyText(
            zh: "节点手动测速、全量测速，以及下方“自定义测速目标”网站测试都会使用这里保存的 URL。留空保存会恢复默认值 \(ManagedProxyConfigSummary.defaultHealthcheckURL)。",
            en: "Manual and batch node health checks, plus the custom website probe below, all use this saved URL. Saving an empty value restores the default \(ManagedProxyConfigSummary.defaultHealthcheckURL)."
        )
    }

    var managedProxyHealthcheckActionHelperText: String {
        self.localizedManagedProxyText(
            zh: "只保存测速目标，不会修改订阅地址，也不会切换当前生效模式。",
            en: "This only saves the health-check target. It does not modify the subscription URL or switch the active outbound mode."
        )
    }

    var managedProxyListeners: [ManagedProxyListener] {
        self.managedProxySnapshot.listeners
    }

    var managedProxyListenerEmptyStateText: String {
        if self.managedProxySnapshot.subscriptionConfigured == false {
            return self.localizedManagedProxyText(
                zh: "先保存订阅地址，之后这里会显示 mihomo 当前全部代理监听地址和端口。",
                en: "Save a subscription URL first. This section will then show every active mihomo proxy listener address and port."
            )
        }
        if self.status?.running != true {
            return self.localizedManagedProxyText(
                zh: "本地服务未运行，当前无法读取 mihomo 代理监听。请前往总览或设置页恢复本地服务。",
                en: "The local service is offline, so mihomo proxy listeners cannot be read right now. Restart the local daemon from Overview or Settings."
            )
        }
        return self.localizedManagedProxyText(
            zh: "当前没有可展示的 mihomo 代理监听。请刷新订阅快照，或检查 mihomo 日志确认运行态。",
            en: "There are no mihomo proxy listeners to show right now. Refresh the subscription snapshot or inspect the mihomo logs to confirm the runtime state."
        )
    }

    func managedProxyListenerTitle(_ listener: ManagedProxyListener) -> String {
        switch listener.kind {
        case .mixedPort:
            return self.localizedManagedProxyText(zh: "mihomo Mixed Port", en: "mihomo Mixed Port")
        case .nodeListener:
            return self.localizedManagedProxyText(zh: "节点专用 Listener", en: "Dedicated Node Listener")
        }
    }

    func managedProxyListenerNodeText(_ listener: ManagedProxyListener) -> String {
        guard let nodeName = self.nonEmptyManagedProxyNodeName(listener.nodeName) else {
            return self.text(.statusNoData)
        }
        return nodeName
    }

    func managedProxyListenerDescription(_ listener: ManagedProxyListener) -> String {
        switch listener.kind {
        case .mixedPort:
            let nodeText = self.managedProxyListenerNodeText(listener)
            return self.localizedManagedProxyText(
                zh: "mihomo 当前默认节点：\(nodeText)",
                en: "mihomo current default node: \(nodeText)"
            )
        case .nodeListener:
            let nodeText = self.managedProxyListenerNodeText(listener)
            return self.localizedManagedProxyText(
                zh: "mihomo 绑定节点：\(nodeText)",
                en: "mihomo bound node: \(nodeText)"
            )
        }
    }

    func managedProxyListenerAddressText(_ listener: ManagedProxyListener) -> String {
        let host = listener.listenHost?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = (host?.isEmpty == false) ? host! : "127.0.0.1"
        return "\(normalizedHost):\(listener.port)"
    }

    func managedProxyListenerTerminalCommand(_ listener: ManagedProxyListener) -> String {
        let address = self.managedProxyListenerAddressText(listener)
        return "export https_proxy=http://\(address) http_proxy=http://\(address) all_proxy=socks5://\(address)"
    }

    func label(for mode: OutboundProxyMode) -> String {
        switch mode {
        case .disabled:
            return self.text(.optionDisabled)
        case .manual:
            return self.localizedManagedProxyText(zh: "手工代理", en: "Manual")
        case .subscription:
            return self.localizedManagedProxyText(zh: "订阅节点", en: "Subscription")
        }
    }

    var settingsOutboundProxyModeNeedsConfirmation: Bool {
        self.settingsOutboundProxyDraft.mode != self.settings.outboundProxyMode
    }

    var settingsOutboundProxyManualNeedsSave: Bool {
        self.settingsOutboundProxyDraft.outboundProxy != self.makeSettingsOutboundProxyDraft(from: self.settings).outboundProxy
    }

    var settingsOutboundProxyManualDraftIsValid: Bool {
        self.settingsOutboundProxyDraft.outboundProxy.isEnabled
    }

    var settingsOutboundProxySavedManualConfigurationIsValid: Bool {
        self.settings.outboundProxy.isEnabled
    }

    var settingsOutboundProxySubscriptionConfigured: Bool {
        self.managedProxySnapshot.subscriptionConfigured || self.settings.managedProxySummary.subscriptionConfigured
    }

    var settingsOutboundProxyCanConfirmModeChange: Bool {
        guard self.settingsOutboundProxyModeNeedsConfirmation else { return false }
        switch self.settingsOutboundProxyDraft.mode {
        case .disabled:
            return true
        case .subscription:
            return self.settingsOutboundProxySubscriptionConfigured
        case .manual:
            guard self.settingsOutboundProxySavedManualConfigurationIsValid else { return false }
            return self.settingsOutboundProxyManualNeedsSave == false
        }
    }

    var settingsOutboundProxyModeConfirmationRequirementText: String? {
        guard self.settingsOutboundProxyModeNeedsConfirmation else { return nil }
        switch self.settingsOutboundProxyDraft.mode {
        case .disabled:
            return nil
        case .subscription:
            guard self.settingsOutboundProxySubscriptionConfigured == false else { return nil }
            return self.text(.helperConfirmProxyModeChangeNeedsSubscription)
        case .manual:
            guard self.settingsOutboundProxyCanConfirmModeChange == false else { return nil }
            return self.text(.helperConfirmProxyModeChangeNeedsManualSave)
        }
    }

    func setSettingsOutboundProxyDraftMode(_ mode: OutboundProxyMode) {
        guard self.settingsOutboundProxyDraft.mode != mode else { return }
        self.settingsOutboundProxyDraft.mode = mode
        if mode == .manual, self.settingsOutboundProxyDraft.outboundProxy.scheme == .disabled {
            self.settingsOutboundProxyDraft.outboundProxy.scheme = .http
        }
    }

    func setOutboundProxyMode(_ mode: OutboundProxyMode) {
        self.setSettingsOutboundProxyDraftMode(mode)
    }

    @discardableResult
    func saveSettingsOutboundProxyManualConfiguration() async -> Bool {
        let host = self.settingsOutboundProxyDraft.outboundProxy.host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.isEmpty == false else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "请先填写代理地址", en: "Enter a proxy host first"),
                detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
            )
            return false
        }

        guard self.settingsOutboundProxyDraft.outboundProxy.port > 0 else {
            self.publishBanner(
                .warning,
                title: self.localized(zh: "请先填写代理端口", en: "Enter a proxy port first"),
                detail: self.localized(zh: "手工代理至少需要填写 host 和 port。", en: "Manual proxy mode needs at least a host and port.")
            )
            return false
        }

        var updatedSettings = self.settings
        updatedSettings.outboundProxy = self.settingsOutboundProxyDraft.outboundProxy
        if updatedSettings.outboundProxy.scheme == .disabled {
            updatedSettings.outboundProxy.scheme = .http
        }

        let saved = await self.persistSettingsUpdate(updatedSettings, noticeContext: .saveSettings)
        if saved {
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
            self.syncSettingsOutboundProxyManualDraftFromSettings()
        }
        return saved
    }

    @discardableResult
    func confirmSettingsOutboundProxyModeChange() async -> Bool {
        guard self.settingsOutboundProxyModeNeedsConfirmation else { return true }
        guard self.settingsOutboundProxyCanConfirmModeChange else {
            self.publishBanner(
                .warning,
                title: self.text(.errorConfigurationFailed),
                detail: self.settingsOutboundProxyModeConfirmationRequirementText
            )
            return false
        }

        var updatedSettings = self.settings
        updatedSettings.outboundProxyMode = self.settingsOutboundProxyDraft.mode
        let saved = await self.persistSettingsUpdate(updatedSettings, noticeContext: .saveSettings)
        if saved {
            self.syncMinimalProxyDraftFromSettingsIfNeeded(force: true)
            self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded(force: true)
        }
        return saved
    }

    func managedProxyNodeRoleText(_ node: ManagedProxyNode) -> String {
        switch (node.isCurrent, node.isPinned) {
        case (true, true):
            return self.localizedManagedProxyText(zh: "当前 / 固定默认", en: "Current / Pinned Default")
        case (true, false):
            return self.localizedManagedProxyText(zh: "当前", en: "Current")
        case (false, true):
            return self.localizedManagedProxyText(zh: "固定默认", en: "Pinned Default")
        case (false, false):
            return self.localizedManagedProxyText(zh: "候选", en: "Candidate")
        }
    }

    func managedProxyNodeAvailabilityText(_ node: ManagedProxyNode) -> String {
        if node.alive == false {
            return self.text(.statusUnavailable)
        }
        if node.alive == true || self.managedProxySuccessfulLatencyMS(node) != nil {
            return self.localizedManagedProxyText(zh: "在线", en: "Healthy")
        }
        return self.localizedManagedProxyText(zh: "未测速", en: "Unchecked")
    }

    func managedProxyNodeAvailabilityTone(_ node: ManagedProxyNode) -> StatusPill.Tone {
        if node.alive == false {
            return .warning
        }
        if node.alive == true || self.managedProxySuccessfulLatencyMS(node) != nil {
            return .success
        }
        return .neutral
    }

    func managedProxyNodeDelayText(_ node: ManagedProxyNode) -> String {
        if let state = self.managedProxyNodeHealthcheckDisplayStates[node.name] {
            switch state.status {
            case .running:
                return self.localizedManagedProxyText(zh: "测速中", en: "Checking")
            case .succeeded:
                if let latencyMS = state.latencyMS {
                    return self.localization.requestLogsLatencyText(latencyMS)
                }
                return self.managedProxySuccessfulLatencyMS(node).map(self.localization.requestLogsLatencyText)
                    ?? self.localizedManagedProxyText(zh: "失败", en: "Failed")
            case .failed:
                return self.localizedManagedProxyText(zh: "失败", en: "Failed")
            }
        }
        if let delay = self.managedProxySuccessfulLatencyMS(node) {
            return self.localization.requestLogsLatencyText(delay)
        }
        if self.managedProxyHasFailedLatency(node) {
            return self.localizedManagedProxyText(zh: "失败", en: "Failed")
        }
        return self.localizedManagedProxyText(zh: "未测速", en: "Unchecked")
    }

    func managedProxyNodeLastHealthcheckText(_ node: ManagedProxyNode) -> String {
        if let state = self.managedProxyNodeHealthcheckDisplayStates[node.name] {
            switch state.status {
            case .running:
                return self.localizedManagedProxyText(zh: "测速中", en: "Checking")
            case .succeeded, .failed:
                return DesktopDateTimeFormat.string(from: state.checkedAt)
            }
        }
        guard let timestamp = node.lastHealthcheckAt else {
            return self.localizedManagedProxyText(zh: "未测速", en: "Unchecked")
        }
        return DesktopDateTimeFormat.string(fromUnixSeconds: timestamp)
    }

    func managedProxyNodeDelayTone(_ node: ManagedProxyNode) -> StatusPill.Tone {
        if let state = self.managedProxyNodeHealthcheckDisplayStates[node.name] {
            switch state.status {
            case .running:
                return .accent
            case .succeeded:
                return .accent
            case .failed:
                return .danger
            }
        }
        if self.managedProxySuccessfulLatencyMS(node) != nil {
            return .accent
        }
        if self.managedProxyHasFailedLatency(node) {
            return .danger
        }
        return .neutral
    }

    func managedProxyNodeSwitchCurrentTitle(_ node: ManagedProxyNode) -> String {
        if node.isCurrent {
            return self.localizedManagedProxyText(zh: "当前使用中", en: "Current")
        }
        return self.localizedManagedProxyText(zh: "切换当前节点", en: "Use Current")
    }

    func managedProxyCanSwitchCurrentNode(_ node: ManagedProxyNode) -> Bool {
        self.managedProxyCanRunRuntimeActions
            && node.isCurrent == false
            && !self.isManagedProxySwitchingCurrent(node.name)
    }

    func managedProxyNodePinnedActionTitle(_ node: ManagedProxyNode) -> String {
        if node.isPinned {
            return self.localizedManagedProxyText(zh: "取消固定默认", en: "Clear Pinned Default")
        }
        return self.localizedManagedProxyText(zh: "设为固定默认", en: "Set Pinned Default")
    }

    func managedProxyCanUpdatePinnedNode(_ node: ManagedProxyNode) -> Bool {
        self.managedProxyCanRunRuntimeActions && !self.isManagedProxyUpdatingPinned(node.isPinned ? nil : node.name)
    }

    func managedProxyNodePrimaryActionTitle(_ node: ManagedProxyNode) -> String {
        if node.isCurrent && node.isPinned {
            return self.localizedManagedProxyText(zh: "已固定", en: "Pinned")
        }
        if node.isCurrent {
            return self.localizedManagedProxyText(zh: "固定当前", en: "Pin Current")
        }
        return self.localizedManagedProxyText(zh: "使用并固定", en: "Use & Pin")
    }

    func managedProxyCanApplyNode(_ node: ManagedProxyNode) -> Bool {
        if node.isCurrent && node.isPinned {
            return false
        }
        return self.managedProxyCanRunRuntimeActions && !self.isManagedProxySelecting(node.name)
    }

    func isManagedProxySelecting(_ nodeName: String) -> Bool {
        if case .selecting(let name) = self.managedProxyOperation {
            return name == nodeName
        }
        return false
    }

    func isManagedProxySwitchingCurrent(_ nodeName: String) -> Bool {
        if case .switchingCurrent(let currentName) = self.managedProxyOperation {
            return currentName == nodeName
        }
        return false
    }

    func isManagedProxyUpdatingPinned(_ nodeName: String?) -> Bool {
        if case .updatingPinned(let currentName) = self.managedProxyOperation {
            return currentName == nodeName
        }
        return false
    }

    var isManagedProxyUpdating: Bool {
        self.managedProxyOperation == .updatingSubscription
    }

    func isManagedProxyHealthchecking(_ nodeName: String?) -> Bool {
        if case .healthchecking(let currentName) = self.managedProxyOperation {
            return currentName == nodeName
        }
        return false
    }

    func refreshManagedProxySnapshot(showLoading: Bool = false) async {
        if showLoading {
            self.managedProxyOperation = .loading
        }
        defer {
            if self.managedProxyOperation == .loading {
                self.managedProxyOperation = .idle
            }
        }
        do {
            let snapshot = try await self.admin.getManagedProxySnapshot()
            self.syncManagedProxySnapshotState(snapshot)
            self.syncManagedProxyFocus()
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func openManagedProxyManagerWindow() {
        if self.managedProxyWindowController == nil {
            self.managedProxyWindowController = ManagedProxyWindowController(model: self)
        }
        self.isManagedProxyNodesDrawerPresented = false
        self.managedProxyFocusedNodeName = nil
        self.resetManagedProxyHealthcheckFeedback()
        self.resetManagedProxyNodeHealthcheckDisplayStates()
        self.resetManagedProxyWebsiteProbeResults()
        self.isManagedProxyLogsExpanded = false
        self.managedProxySubscriptionURLDraft = self.managedProxySnapshot.subscriptionURL ?? ""
        self.managedProxyHealthcheckURLDraft = self.managedProxySnapshot.healthcheckURL
        self.isManagedProxyManagerPresented = true
        self.managedProxyWindowController?.showWindow()
        Task { await self.refreshManagedProxySnapshot(showLoading: true) }
    }

    func dismissManagedProxyManagerWindow() {
        self.isManagedProxyManagerPresented = false
        self.managedProxyWindowController?.closeWindow()
    }

    func saveProxySettings() async {
        self.managedProxyOperation = .saving
        self.isBusy = true
        defer {
            self.managedProxyOperation = .idle
            self.isBusy = false
        }

        do {
            _ = try ManagedProxyRuntime.validatedSubscriptionURL(self.managedProxySubscriptionURLDraft)
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            self.settings = try await self.admin.saveSettings(self.settings)
            let snapshot = try await self.admin.saveManagedProxyConfig(
                ManagedProxyConfigPayload(subscriptionURL: self.managedProxySubscriptionURLDraft)
            )
            self.syncManagedProxySnapshotState(snapshot)
            self.settings = try await self.admin.getSettings()
            self.syncMinimalProxyDraftFromSettingsIfNeeded()
            self.syncSettingsOutboundProxyDraftFromSettingsIfNeeded()
            self.syncManagedProxyFocus()

            let applyOutcome = try await self.daemon.applyLaunchConfiguration(
                config: self.settings,
                preserveRunningService: true
            )
            await self.refreshLocalServiceSnapshot()
            self.syncSelectedRemoteHost()
            self.publishManagedProxyBanner(
                tone: applyOutcome == .appliedNow ? .success : .warning,
                title: self.text(.successSettingsSaved),
                detail: applyOutcome == .appliedNow
                    ? self.localizedManagedProxyText(
                        zh: "代理模式和订阅配置已应用。",
                        en: "Proxy mode and subscription settings have been applied."
                    )
                    : self.text(.warningLaunchConfigurationSavedRestartRequired)
            )
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func saveManagedProxyHealthcheckURL() async {
        self.managedProxyOperation = .savingHealthcheckURL
        defer { self.managedProxyOperation = .idle }

        do {
            _ = try ManagedProxyRuntime.validatedHealthcheckURL(self.managedProxyHealthcheckURLDraft)
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            let snapshot = try await self.admin.saveManagedProxyHealthcheckConfig(
                .init(healthcheckURL: self.managedProxyHealthcheckURLDraft)
            )
            self.syncManagedProxySnapshotState(snapshot)
            self.syncManagedProxyFocus()
            self.publishManagedProxyBanner(
                tone: .success,
                title: self.localizedManagedProxyText(zh: "测速目标已保存", en: "Healthcheck Target Saved"),
                detail: self.localizedManagedProxyText(
                    zh: "新的测速目标会立即用于节点测速和自定义网站测试，不会修改订阅地址，也不会切换当前生效模式。",
                    en: "The new target now drives node health checks and the custom website probe without changing the subscription URL or the active outbound mode."
                )
            )
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func updateManagedProxySubscription() async {
        guard self.managedProxyCanRunRuntimeActions else { return }
        self.managedProxyOperation = .updatingSubscription
        defer { self.managedProxyOperation = .idle }
        do {
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            let snapshot = try await self.admin.updateManagedProxySubscription()
            self.syncManagedProxySnapshotState(snapshot)
            self.syncManagedProxyFocus()
            self.publishManagedProxyBanner(
                tone: .success,
                title: self.localizedManagedProxyText(zh: "订阅已更新", en: "Subscription Updated"),
                detail: self.localizedManagedProxyText(
                    zh: "节点列表和最近更新时间已经刷新。",
                    en: "The node list and latest refresh timestamp have been updated."
                )
            )
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func switchManagedProxyCurrentNode(_ nodeName: String) async {
        guard self.managedProxyCanRunRuntimeActions else { return }
        self.managedProxyOperation = .switchingCurrent(nodeName)
        defer { self.managedProxyOperation = .idle }
        do {
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            let snapshot = try await self.admin.switchManagedProxyCurrentNode(.init(name: nodeName))
            self.syncManagedProxySnapshotState(snapshot)
            self.managedProxyFocusedNodeName = nodeName
            self.syncManagedProxyFocus()
            self.publishManagedProxyBanner(
                tone: .success,
                title: self.localizedManagedProxyText(zh: "当前节点已切换", en: "Current Node Switched"),
                detail: self.localizedManagedProxyText(
                    zh: "当前出口已临时切换到 \(nodeName)，固定默认节点保持不变。",
                    en: "Traffic now uses \(nodeName) temporarily, while the pinned default stays unchanged."
                )
            )
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func updateManagedProxyPinnedNode(_ nodeName: String?) async {
        guard self.managedProxyCanRunRuntimeActions else { return }
        let normalizedNodeName = self.nonEmptyManagedProxyNodeName(nodeName)
        self.managedProxyOperation = .updatingPinned(normalizedNodeName)
        defer { self.managedProxyOperation = .idle }
        do {
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            let snapshot = try await self.admin.updateManagedProxyPinnedNode(.init(name: normalizedNodeName))
            self.syncManagedProxySnapshotState(snapshot)
            if let normalizedNodeName {
                self.managedProxyFocusedNodeName = normalizedNodeName
            }
            self.syncManagedProxyFocus()
            if let normalizedNodeName {
                self.publishManagedProxyBanner(
                    tone: .success,
                    title: self.localizedManagedProxyText(zh: "固定默认节点已更新", en: "Pinned Default Updated"),
                    detail: self.localizedManagedProxyText(
                        zh: "固定默认节点已更新为 \(normalizedNodeName)，不会立即切换当前出口。",
                        en: "The pinned default is now \(normalizedNodeName), and the current egress stays unchanged for now."
                    )
                )
            } else {
                self.publishManagedProxyBanner(
                    tone: .success,
                    title: self.localizedManagedProxyText(zh: "固定默认节点已清空", en: "Pinned Default Cleared"),
                    detail: self.localizedManagedProxyText(
                        zh: "已取消固定默认节点，当前出口保持不变。",
                        en: "The pinned default was cleared, and the current egress stays unchanged."
                    )
                )
            }
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func selectManagedProxyNode(_ nodeName: String) async {
        guard self.managedProxyCanRunRuntimeActions else { return }
        self.managedProxyOperation = .selecting(nodeName)
        defer { self.managedProxyOperation = .idle }
        do {
            self.resetManagedProxyHealthcheckFeedback()
            self.resetManagedProxyNodeHealthcheckDisplayStates()
            self.resetManagedProxyWebsiteProbeResults()
            let snapshot = try await self.admin.selectManagedProxyNode(.init(name: nodeName))
            self.syncManagedProxySnapshotState(snapshot)
            self.managedProxyFocusedNodeName = nodeName
            self.syncManagedProxyFocus()
            self.publishManagedProxyBanner(
                tone: .success,
                title: self.localizedManagedProxyText(zh: "固定节点已更新", en: "Pinned Node Updated"),
                detail: self.localizedManagedProxyText(
                    zh: "当前出口已切换并固定到 \(nodeName)。",
                    en: "Traffic is now pinned to \(nodeName)."
                )
            )
        } catch {
            self.presentManagedProxyError(error)
        }
    }

    func healthcheckManagedProxy(nodeName: String?) async {
        await self.healthcheckManagedProxy(nodeName: nodeName, source: .row)
    }

    private func healthcheckManagedProxy(
        nodeName: String?,
        source: ManagedProxyHealthcheckSource
    ) async {
        guard self.managedProxyCanRunRuntimeActions else { return }
        let previousSnapshot = self.managedProxySnapshot
        let previousFocusedNodeName = self.managedProxyFocusedNodeName
        let normalizedRequestedNodeName = self.nonEmptyManagedProxyNodeName(nodeName)
        let targetNodeNames = self.managedProxyHealthcheckTargetNodeNames(
            source: source,
            requestedNodeName: normalizedRequestedNodeName,
            previousSnapshot: previousSnapshot,
            latestSnapshot: previousSnapshot
        )

        self.markManagedProxyNodesHealthchecking(targetNodeNames)
        self.managedProxyHealthcheckFeedback = self.makeManagedProxyRunningHealthcheckFeedback(
            source: source,
            targetNodeNames: targetNodeNames
        )
        self.managedProxyOperation = .healthchecking(nodeName)
        defer { self.managedProxyOperation = .idle }
        do {
            let snapshot = try await self.admin.healthcheckManagedProxy(.init(nodeName: nodeName))
            self.syncManagedProxySnapshotState(snapshot)
            let outcome = self.makeManagedProxyHealthcheckOutcome(
                source: source,
                requestedNodeName: normalizedRequestedNodeName,
                previousFocusedNodeName: previousFocusedNodeName,
                previousSnapshot: previousSnapshot,
                latestSnapshot: self.managedProxySnapshot
            )
            self.applyManagedProxyHealthcheckOutcome(outcome)
        } catch {
            let outcome = self.makeManagedProxyRequestFailedHealthcheckOutcome(
                source: source,
                requestedNodeName: normalizedRequestedNodeName,
                previousFocusedNodeName: previousFocusedNodeName,
                snapshot: previousSnapshot,
                errorDetail: self.localizedManagedProxyHealthcheckErrorDetail(error)
            )
            self.applyManagedProxyHealthcheckOutcome(outcome)
        }
    }

    func loadManagedProxyLogs() async {
        self.managedProxyOperation = .loadingLogs
        defer { self.managedProxyOperation = .idle }
        if self.adminCapabilities.supportsManagedProxyRemoteLogs {
            do {
                self.managedProxyLogs = try await self.admin.getManagedProxyLogs()
            } catch {
                self.presentManagedProxyError(error)
            }
        } else {
            self.managedProxyLogs = await self.daemon.managedProxyLogs()
        }
        self.isManagedProxyLogsExpanded = true
    }

    func copyManagedProxyListenerTerminalCommand(_ listener: ManagedProxyListener) {
        self.copyToPasteboard(
            self.managedProxyListenerTerminalCommand(listener),
            context: .copyManagedProxyTerminalCommand
        )
    }

    func localizedManagedProxyText(zh: String, en: String) -> String {
        self.localization.resolvedLanguage == .zhHans ? zh : en
    }

    func syncManagedProxySnapshotState(_ snapshot: ManagedProxySnapshot) {
        self.managedProxySnapshot = snapshot
        self.managedProxySubscriptionURLDraft = snapshot.subscriptionURL ?? ""
        self.managedProxyHealthcheckURLDraft = snapshot.healthcheckURL
        self.settings.managedProxySummary.healthcheckURL = snapshot.healthcheckURL
        self.reconcileManagedProxyNodeHealthcheckDisplayStates(with: snapshot)
    }

    private func publishManagedProxyBanner(
        tone: BannerState.Tone,
        title: String,
        detail: String?
    ) {
        self.publishBanner(tone, title: title, detail: detail)
    }

    private func presentManagedProxyError(_ error: Error) {
        self.publishManagedProxyBanner(
            tone: .error,
            title: self.localizedManagedProxyText(
                zh: "订阅代理操作失败",
                en: "Subscription Proxy Action Failed"
            ),
            detail: self.localizedManagedProxyErrorDetail(error)
        )
    }

    private func preferredManagedProxyFocusedNode(in nodes: [ManagedProxyNode]) -> ManagedProxyNode? {
        if let currentName = self.nonEmptyManagedProxyNodeName(self.managedProxySnapshot.currentNodeName),
           let currentNode = nodes.first(where: { $0.name == currentName }) {
            return currentNode
        }
        if let pinnedName = self.nonEmptyManagedProxyNodeName(self.managedProxySnapshot.pinnedNodeName),
           let pinnedNode = nodes.first(where: { $0.name == pinnedName }) {
            return pinnedNode
        }
        return nodes.first
    }

    private func nonEmptyManagedProxyNodeName(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private func localizedManagedProxyErrorDetail(_ error: Error) -> String {
        let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return self.localization.errorDetail(for: rawDetail, context: .saveSettings) ?? rawDetail
    }

    private func localizedManagedProxyHealthcheckErrorDetail(_ error: Error) -> String {
        let rawDetail = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if self.adminCapabilities.allowsLocalFallback == false,
           self.managedProxyHealthcheckRequiresRemoteRedeploy(rawDetail)
        {
            return self.localizedManagedProxyText(
                zh: "当前远端服务版本过旧，不支持节点测速接口。请重新部署或更新远端服务后再试。",
                en: "The remote proxy service is too old for node health checks. Redeploy or update the remote service and try again."
            )
        }
        return self.localization.errorDetail(for: rawDetail, context: .saveSettings) ?? rawDetail
    }

    private func managedProxyHealthcheckRequiresRemoteRedeploy(_ detail: String) -> Bool {
        let normalized = detail.lowercased()
        return normalized.contains("http 404")
            || normalized.contains("http 405")
            || normalized.contains("not found")
            || normalized.contains("unsupported")
            || normalized.contains("cannot post /admin/proxy/subscription/healthcheck")
            || normalized.contains("cannot get /admin/proxy/subscription/healthcheck")
    }

    private func managedProxyHealthcheckFeedbackDetail(
        from snapshot: ManagedProxySnapshot
    ) -> String? {
        let detail = snapshot.lastHealthcheckFeedbackDetail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return detail.isEmpty ? nil : detail
    }

    private func managedProxyHealthcheckNodeLabel(
        for nodeName: String,
        snapshot: ManagedProxySnapshot
    ) -> String {
        let currentNodeName = self.nonEmptyManagedProxyNodeName(snapshot.currentNodeName)
        return currentNodeName == nodeName
            ? self.localizedManagedProxyText(zh: "当前节点", en: "Current node")
            : self.localizedManagedProxyText(zh: "节点", en: "Node")
    }

    private func managedProxyHealthcheckBannerTitle(
        for source: ManagedProxyHealthcheckSource,
        status: ManagedProxyHealthcheckFeedbackStatus
    ) -> String {
        switch (source, status) {
        case (.drawerBatch, .success):
            return self.localizedManagedProxyText(zh: "全量测速完成", en: "Batch Health Check Complete")
        case (.drawerBatch, .warning):
            return self.localizedManagedProxyText(zh: "全量测速部分成功", en: "Batch Health Check Partially Complete")
        case (.drawerBatch, .failure):
            return self.localizedManagedProxyText(zh: "全量测速失败", en: "Batch Health Check Failed")
        case (.drawerBatch, .info):
            return self.localizedManagedProxyText(zh: "全量测速进行中", en: "Batch Health Check Running")
        case (_, .success):
            return self.localizedManagedProxyText(zh: "节点测速完成", en: "Node Health Check Complete")
        case (_, .warning):
            return self.localizedManagedProxyText(zh: "节点测速部分成功", en: "Node Health Check Partially Complete")
        case (_, .failure):
            return self.localizedManagedProxyText(zh: "节点测速失败", en: "Node Health Check Failed")
        case (_, .info):
            return self.localizedManagedProxyText(zh: "节点测速中", en: "Node Health Check Running")
        }
    }

    private func managedProxyHealthcheckTargetNodeNames(
        source: ManagedProxyHealthcheckSource,
        requestedNodeName: String?,
        previousSnapshot: ManagedProxySnapshot,
        latestSnapshot: ManagedProxySnapshot
    ) -> [String] {
        switch source {
        case .row:
            return requestedNodeName.map { [$0] } ?? []
        case .drawerCurrent:
            let currentNodeName = self.nonEmptyManagedProxyNodeName(latestSnapshot.currentNodeName)
                ?? self.nonEmptyManagedProxyNodeName(previousSnapshot.currentNodeName)
                ?? requestedNodeName
            return currentNodeName.map { [$0] } ?? []
        case .drawerBatch:
            let names = latestSnapshot.nodes.isEmpty ? previousSnapshot.nodes.map(\.name) : latestSnapshot.nodes.map(\.name)
            return self.uniqueManagedProxyNodeNames(names)
        }
    }

    private func makeManagedProxyRunningHealthcheckFeedback(
        source: ManagedProxyHealthcheckSource,
        targetNodeNames: [String]
    ) -> ManagedProxyHealthcheckFeedback {
        switch source {
        case .row, .drawerCurrent:
            return ManagedProxyHealthcheckFeedback(
                kind: .node,
                status: .info,
                nodeName: targetNodeNames.first,
                totalNodeCount: max(targetNodeNames.count, 1)
            )
        case .drawerBatch:
            return ManagedProxyHealthcheckFeedback(
                kind: .batch,
                status: .info,
                totalNodeCount: targetNodeNames.count
            )
        }
    }

    private func markManagedProxyNodesHealthchecking(_ nodeNames: [String]) {
        guard nodeNames.isEmpty == false else { return }
        let checkedAt = Date()
        var mergedStates = self.managedProxyNodeHealthcheckDisplayStates
        for nodeName in nodeNames {
            mergedStates[nodeName] = ManagedProxyNodeHealthcheckDisplayState(
                status: .running,
                checkedAt: checkedAt
            )
        }
        self.commitManagedProxyNodeHealthcheckDisplayStates(mergedStates)
    }

    private func applyManagedProxyHealthcheckOutcome(_ outcome: ManagedProxyHealthcheckOutcome) {
        self.managedProxyHealthcheckFeedback = outcome.feedback
        self.commitManagedProxyNodeHealthcheckDisplayStates(outcome.displayStates)
        self.focusManagedProxyHealthcheckResultNode(
            named: outcome.focusNodeName,
            clearSearchIfHidden: outcome.clearSearchIfHidden
        )
        self.publishManagedProxyBanner(
            tone: outcome.bannerTone,
            title: outcome.bannerTitle,
            detail: outcome.bannerDetail ?? self.managedProxyHealthcheckFeedbackText
        )
    }

    private func commitManagedProxyNodeHealthcheckDisplayStates(
        _ states: [String: ManagedProxyNodeHealthcheckDisplayState]
    ) {
        let knownNodeNames = Set(self.managedProxySnapshot.nodes.map(\.name))
        var mergedStates = self.managedProxyNodeHealthcheckDisplayStates.filter { knownNodeNames.contains($0.key) }
        for (nodeName, state) in states where knownNodeNames.contains(nodeName) {
            mergedStates[nodeName] = state
        }
        self.managedProxyNodeHealthcheckDisplayStates = mergedStates
    }

    private func reconcileManagedProxyNodeHealthcheckDisplayStates(with snapshot: ManagedProxySnapshot) {
        guard self.managedProxyNodeHealthcheckDisplayStates.isEmpty == false else {
            return
        }
        let nodesByName = Dictionary(uniqueKeysWithValues: snapshot.nodes.map { ($0.name, $0) })
        var reconciledStates: [String: ManagedProxyNodeHealthcheckDisplayState] = [:]
        for (nodeName, displayState) in self.managedProxyNodeHealthcheckDisplayStates {
            guard let node = nodesByName[nodeName] else {
                continue
            }
            if displayState.status != .running,
               let snapshotState = self.managedProxyNodeHealthcheckDisplayState(from: node)
            {
                reconciledStates[nodeName] = snapshotState
            } else {
                reconciledStates[nodeName] = displayState
            }
        }
        self.managedProxyNodeHealthcheckDisplayStates = reconciledStates
    }

    private func managedProxyNodeHealthcheckDisplayState(
        from node: ManagedProxyNode
    ) -> ManagedProxyNodeHealthcheckDisplayState? {
        let checkedAt = self.managedProxyHealthcheckDate(
            runtimeUnixSeconds: node.lastHealthcheckAt,
            fallback: Date()
        )
        if let status = node.lastHealthcheckStatus {
            switch status {
            case .success:
                if let latencyMS = self.managedProxySuccessfulLatencyMS(node) {
                    return ManagedProxyNodeHealthcheckDisplayState(
                        status: .succeeded,
                        latencyMS: latencyMS,
                        checkedAt: checkedAt
                    )
                }
                return ManagedProxyNodeHealthcheckDisplayState(status: .failed, checkedAt: checkedAt)
            case .failure:
                return ManagedProxyNodeHealthcheckDisplayState(status: .failed, checkedAt: checkedAt)
            }
        }
        if let latencyMS = self.managedProxySuccessfulLatencyMS(node), node.lastHealthcheckAt != nil {
            return ManagedProxyNodeHealthcheckDisplayState(
                status: .succeeded,
                latencyMS: latencyMS,
                checkedAt: checkedAt
            )
        }
        if self.managedProxyHasFailedLatency(node) {
            return ManagedProxyNodeHealthcheckDisplayState(status: .failed, checkedAt: checkedAt)
        }
        return nil
    }

    private func managedProxyNode(
        in snapshot: ManagedProxySnapshot,
        named nodeName: String?
    ) -> ManagedProxyNode? {
        guard let nodeName = self.nonEmptyManagedProxyNodeName(nodeName) else {
            return nil
        }
        return snapshot.nodes.first(where: { $0.name == nodeName })
    }

    private func makeManagedProxyHealthcheckOutcome(
        source: ManagedProxyHealthcheckSource,
        requestedNodeName: String?,
        previousFocusedNodeName: String?,
        previousSnapshot: ManagedProxySnapshot,
        latestSnapshot: ManagedProxySnapshot
    ) -> ManagedProxyHealthcheckOutcome {
        let checkedAt = Date()
        let targetNodeNames = self.managedProxyHealthcheckTargetNodeNames(
            source: source,
            requestedNodeName: requestedNodeName,
            previousSnapshot: previousSnapshot,
            latestSnapshot: latestSnapshot
        )
        let displayStates = Dictionary(uniqueKeysWithValues: targetNodeNames.map { nodeName in
            (
                nodeName,
                self.managedProxyHealthcheckDisplayState(
                    for: nodeName,
                    previousSnapshot: previousSnapshot,
                    latestSnapshot: latestSnapshot,
                    fallbackCheckedAt: checkedAt
                )
            )
        })
        let successfulNodeNames = targetNodeNames.filter {
            displayStates[$0]?.status == .succeeded
        }
        let failedNodeCount = targetNodeNames.count - successfulNodeNames.count
        let currentNodeName = self.nonEmptyManagedProxyNodeName(latestSnapshot.currentNodeName)
            ?? self.nonEmptyManagedProxyNodeName(previousSnapshot.currentNodeName)
        let singleTargetNodeName = targetNodeNames.first ?? requestedNodeName
        let singleTargetState = singleTargetNodeName.flatMap { displayStates[$0] }

        switch source {
        case .row:
            let status: ManagedProxyHealthcheckFeedbackStatus = singleTargetState?.status == .succeeded ? .success : .failure
            return ManagedProxyHealthcheckOutcome(
                feedback: ManagedProxyHealthcheckFeedback(
                    kind: .node,
                    status: status,
                    nodeName: singleTargetNodeName,
                    latencyMS: singleTargetState?.latencyMS,
                    succeededNodeCount: status == .success ? 1 : 0,
                    failedNodeCount: status == .failure ? 1 : 0,
                    totalNodeCount: max(targetNodeNames.count, 1),
                    checkedAt: checkedAt
                ),
                displayStates: displayStates,
                focusNodeName: singleTargetNodeName,
                clearSearchIfHidden: false,
                bannerTone: status == .success ? .success : .error,
                bannerTitle: self.managedProxyHealthcheckBannerTitle(for: source, status: status),
                bannerDetail: self.managedProxyHealthcheckFeedbackDetail(from: latestSnapshot)
            )

        case .drawerCurrent:
            let targetNodeName = currentNodeName ?? singleTargetNodeName ?? previousFocusedNodeName
            let targetState = targetNodeName.flatMap { displayStates[$0] }
            let status: ManagedProxyHealthcheckFeedbackStatus = targetState?.status == .succeeded ? .success : .failure
            return ManagedProxyHealthcheckOutcome(
                feedback: ManagedProxyHealthcheckFeedback(
                    kind: .node,
                    status: status,
                    nodeName: targetNodeName ?? singleTargetNodeName,
                    latencyMS: targetState?.latencyMS,
                    succeededNodeCount: status == .success ? 1 : 0,
                    failedNodeCount: status == .failure ? 1 : 0,
                    totalNodeCount: max(targetNodeNames.count, 1),
                    checkedAt: checkedAt
                ),
                displayStates: displayStates,
                focusNodeName: targetNodeName,
                clearSearchIfHidden: targetNodeName != nil,
                bannerTone: status == .success ? .success : .error,
                bannerTitle: self.managedProxyHealthcheckBannerTitle(for: source, status: status),
                bannerDetail: self.managedProxyHealthcheckFeedbackDetail(from: latestSnapshot)
            )

        case .drawerBatch:
            let feedbackStatus: ManagedProxyHealthcheckFeedbackStatus
            if successfulNodeNames.isEmpty {
                feedbackStatus = .failure
            } else if failedNodeCount == 0 {
                feedbackStatus = .success
            } else {
                feedbackStatus = .warning
            }

            let focusNodeName: String?
            if let currentNodeName, displayStates[currentNodeName]?.status == .succeeded {
                focusNodeName = currentNodeName
            } else if let firstSuccessfulNodeName = successfulNodeNames.first {
                focusNodeName = firstSuccessfulNodeName
            } else if let currentNodeName {
                focusNodeName = currentNodeName
            } else if let previousFocusedNodeName = self.nonEmptyManagedProxyNodeName(previousFocusedNodeName) {
                focusNodeName = previousFocusedNodeName
            } else {
                focusNodeName = targetNodeNames.first
            }

            return ManagedProxyHealthcheckOutcome(
                feedback: ManagedProxyHealthcheckFeedback(
                    kind: .batch,
                    status: feedbackStatus,
                    nodeName: focusNodeName,
                    latencyMS: focusNodeName.flatMap { displayStates[$0]?.latencyMS },
                    succeededNodeCount: successfulNodeNames.count,
                    failedNodeCount: failedNodeCount,
                    totalNodeCount: targetNodeNames.count,
                    checkedAt: checkedAt
                ),
                displayStates: displayStates,
                focusNodeName: focusNodeName,
                clearSearchIfHidden: focusNodeName != nil,
                bannerTone: self.managedProxyBannerTone(for: feedbackStatus),
                bannerTitle: self.managedProxyHealthcheckBannerTitle(for: source, status: feedbackStatus),
                bannerDetail: self.managedProxyHealthcheckFeedbackDetail(from: latestSnapshot)
            )
        }
    }

    private func makeManagedProxyRequestFailedHealthcheckOutcome(
        source: ManagedProxyHealthcheckSource,
        requestedNodeName: String?,
        previousFocusedNodeName: String?,
        snapshot: ManagedProxySnapshot,
        errorDetail: String
    ) -> ManagedProxyHealthcheckOutcome {
        let checkedAt = Date()
        let targetNodeNames = self.managedProxyHealthcheckTargetNodeNames(
            source: source,
            requestedNodeName: requestedNodeName,
            previousSnapshot: snapshot,
            latestSnapshot: snapshot
        )
        let displayStates = Dictionary(uniqueKeysWithValues: targetNodeNames.map { nodeName in
            (
                nodeName,
                ManagedProxyNodeHealthcheckDisplayState(status: .failed, checkedAt: checkedAt)
            )
        })

        switch source {
        case .row, .drawerCurrent:
            let targetNodeName = targetNodeNames.first
                ?? self.nonEmptyManagedProxyNodeName(snapshot.currentNodeName)
                ?? previousFocusedNodeName
            return ManagedProxyHealthcheckOutcome(
                feedback: ManagedProxyHealthcheckFeedback(
                    kind: .node,
                    status: .failure,
                    nodeName: targetNodeName,
                    succeededNodeCount: 0,
                    failedNodeCount: max(targetNodeNames.count, 1),
                    totalNodeCount: max(targetNodeNames.count, 1),
                    checkedAt: checkedAt
                ),
                displayStates: displayStates,
                focusNodeName: targetNodeName,
                clearSearchIfHidden: source == .drawerCurrent && targetNodeName != nil,
                bannerTone: .error,
                bannerTitle: self.managedProxyHealthcheckBannerTitle(for: source, status: .failure),
                bannerDetail: errorDetail
            )

        case .drawerBatch:
            let successfulNodeNames: [String] = []
            let currentNodeName = self.nonEmptyManagedProxyNodeName(snapshot.currentNodeName)
            let focusNodeName = currentNodeName ?? previousFocusedNodeName ?? targetNodeNames.first
            _ = successfulNodeNames
            return ManagedProxyHealthcheckOutcome(
                feedback: ManagedProxyHealthcheckFeedback(
                    kind: .batch,
                    status: .failure,
                    nodeName: focusNodeName,
                    succeededNodeCount: 0,
                    failedNodeCount: targetNodeNames.count,
                    totalNodeCount: targetNodeNames.count,
                    checkedAt: checkedAt
                ),
                displayStates: displayStates,
                focusNodeName: focusNodeName,
                clearSearchIfHidden: focusNodeName != nil,
                bannerTone: .error,
                bannerTitle: self.managedProxyHealthcheckBannerTitle(for: source, status: .failure),
                bannerDetail: errorDetail
            )
        }
    }

    private func managedProxyBannerTone(
        for status: ManagedProxyHealthcheckFeedbackStatus
    ) -> DesktopAppModel.BannerState.Tone {
        switch status {
        case .info:
            return .info
        case .success:
            return .success
        case .warning:
            return .warning
        case .failure:
            return .error
        }
    }

    private func managedProxyHealthcheckDate(
        runtimeUnixSeconds: Int64?,
        fallback: Date
    ) -> Date {
        guard let runtimeUnixSeconds else {
            return fallback
        }
        return Date(timeIntervalSince1970: TimeInterval(runtimeUnixSeconds))
    }

    private func uniqueManagedProxyNodeNames(_ nodeNames: [String]) -> [String] {
        var seen = Set<String>()
        return nodeNames.filter { seen.insert($0).inserted }
    }

    private func focusManagedProxyHealthcheckResultNode(
        named nodeName: String?,
        clearSearchIfHidden: Bool
    ) {
        guard let nodeName = self.nonEmptyManagedProxyNodeName(nodeName) else {
            self.syncManagedProxyFocus()
            return
        }
        guard self.managedProxySnapshot.nodes.contains(where: { $0.name == nodeName }) else {
            self.syncManagedProxyFocus()
            return
        }
        if clearSearchIfHidden,
           self.visibleManagedProxyNodes.contains(where: { $0.name == nodeName }) == false {
            self.managedProxyNodeSearchQuery = ""
        }
        self.managedProxyFocusedNodeName = nodeName
        self.syncManagedProxyFocus()
    }

    private func managedProxyHealthcheckDisplayState(
        for nodeName: String,
        previousSnapshot: ManagedProxySnapshot,
        latestSnapshot: ManagedProxySnapshot,
        fallbackCheckedAt: Date
    ) -> ManagedProxyNodeHealthcheckDisplayState {
        let latestNode = self.managedProxyNode(in: latestSnapshot, named: nodeName)
        let baselineNode = self.managedProxyNode(in: previousSnapshot, named: nodeName)
        guard let latestNode else {
            return ManagedProxyNodeHealthcheckDisplayState(
                status: .failed,
                checkedAt: fallbackCheckedAt
            )
        }
        let checkedAt = self.managedProxyHealthcheckDate(
            runtimeUnixSeconds: latestNode.lastHealthcheckAt,
            fallback: fallbackCheckedAt
        )
        if let status = latestNode.lastHealthcheckStatus {
            switch status {
            case .success:
                if let latencyMS = self.managedProxySuccessfulLatencyMS(latestNode) {
                    return ManagedProxyNodeHealthcheckDisplayState(
                        status: .succeeded,
                        latencyMS: latencyMS,
                        checkedAt: checkedAt
                    )
                }
                return ManagedProxyNodeHealthcheckDisplayState(
                    status: .failed,
                    checkedAt: checkedAt
                )
            case .failure:
                return ManagedProxyNodeHealthcheckDisplayState(
                    status: .failed,
                    checkedAt: checkedAt
                )
            }
        }
        guard self.managedProxyHasCompletedHealthcheckResult(latestNode, baseline: baselineNode) else {
            return ManagedProxyNodeHealthcheckDisplayState(
                status: .failed,
                checkedAt: fallbackCheckedAt
            )
        }
        guard let latencyMS = self.managedProxySuccessfulLatencyMS(latestNode) else {
            return ManagedProxyNodeHealthcheckDisplayState(
                status: .failed,
                checkedAt: checkedAt
            )
        }
        return ManagedProxyNodeHealthcheckDisplayState(
            status: .succeeded,
            latencyMS: latencyMS,
            checkedAt: checkedAt
        )
    }

    private func managedProxyHasCompletedHealthcheckResult(
        _ node: ManagedProxyNode,
        baseline: ManagedProxyNode?
    ) -> Bool {
        if let currentTimestamp = node.lastHealthcheckAt {
            let previousTimestamp = baseline?.lastHealthcheckAt ?? Int64.min
            if baseline?.lastHealthcheckAt == nil || currentTimestamp > previousTimestamp {
                return true
            }
        }
        return node.lastDelayMS != baseline?.lastDelayMS
    }

    private func managedProxySuccessfulLatencyMS(_ node: ManagedProxyNode) -> Int64? {
        if node.lastHealthcheckStatus == .failure {
            return nil
        }
        guard let delay = node.lastDelayMS, delay > 0 else {
            return nil
        }
        return delay
    }

    private func managedProxyHasFailedLatency(_ node: ManagedProxyNode) -> Bool {
        if let status = node.lastHealthcheckStatus {
            return status == .failure
        }
        if let delay = node.lastDelayMS {
            return delay <= 0
        }
        return node.lastHealthcheckAt != nil
    }
}
#endif
